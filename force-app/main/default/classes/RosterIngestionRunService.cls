/**
 * The user-facing actions on a RosterIngestionRun__c: start a Run over a
 * roster's personnel file, promote a dry run to a real one, and cancel a Run.
 * The processing itself is ProviderIngestionBatch.
 *
 * A Run is pinned to one file version (ContentVersion) when it starts, so
 * uploading a new version while it runs has no effect on it. Only one Run per
 * roster may be active (Queued or Running) at a time.
 *
 * See docs/architecture/provider-bulk-ingestion.md for how the pieces fit
 * together.
 *
 * Starting, promoting and cancelling check the user's access to the roster.
 * After that, Run and Issue records are written in system mode: they are
 * processing records owned by the roster, and the user needs no field access
 * to their internal fields.
 */
public with sharing class RosterIngestionRunService {

    public class RunException extends Exception {}

    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_RUNNING = 'Running';
    public static final String STATUS_COMPLETED = 'Completed';
    public static final String STATUS_COMPLETED_WITH_ERRORS = 'Completed with Errors';
    public static final String STATUS_FAILED = 'Failed';
    public static final String STATUS_CANCELLED = 'Cancelled';

    public static final String FILE_TYPE_PERSONNEL = 'Personnel';

    public static final String SEVERITY_ERROR = 'Error';
    public static final String SEVERITY_WARNING = 'Warning';
    public static final String CODE_COLUMN_COUNT = 'COLUMN_COUNT';
    public static final String CODE_INVALID_VALUE = 'INVALID_VALUE';

    /*
     * Rows per execute() of ProviderIngestionBatch. 200 rows cost about 3 s of
     * the 60 s async CPU limit in the innovage sandbox (2026-10-14), including
     * the org's Account automation.
     */
    public static final Integer BATCH_SIZE = 200;

    /*
     * A guard against files too large to parse in one transaction, checked
     * before the job starts. The real limit is the row count, checked by
     * ProviderIngestionBatch.start().
     */
    @TestVisible
    private static Integer maxFileBytes = 3 * 1024 * 1024;

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{ STATUS_QUEUED, STATUS_RUNNING };
    private static final Set<String> PROMOTABLE_STATUSES = new Set<String>{ STATUS_COMPLETED, STATUS_COMPLETED_WITH_ERRORS };
    private static final Set<String> ENDED_JOB_STATUSES = new Set<String>{ 'Completed', 'Failed', 'Aborted' };

    /**
     * Starts a Run over the current version of the roster's personnel file.
     *
     * @param rosterIngestionId The RosterIngestion__c record
     * @param dryRun true to roll back all Provider changes (see ProviderIngestionService.ingestAll)
     * @return The new RosterIngestionRun__c Id
     * @throws RunException if the user cannot edit the roster, it has no personnel file,
     *         the file is too large, or a Run is already active
     * @example
     * Id runId = RosterIngestionRunService.startRun(rosterIngestionId, true);
     */
    public static Id startRun(Id rosterIngestionId, Boolean dryRun) {
        RosterIngestion__c roster = lockRoster(rosterIngestionId);
        if (String.isBlank(roster.Personnel_File__c)) {
            throw new RunException('This roster has no personnel file.');
        }

        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId, VersionNumber, Checksum, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId = :roster.Personnel_File__c AND IsLatest = TRUE
            WITH USER_MODE
        ];
        if (versions.isEmpty()) {
            throw new RunException('The personnel file was not found or is not accessible.');
        }

        return createRun(roster.Id, versions[0], dryRun == true);
    }

    /**
     * Starts a real Run over the exact file version a completed dry run processed,
     * even if a newer version has been uploaded since.
     *
     * @param dryRunId A completed dry-run RosterIngestionRun__c
     * @return The new RosterIngestionRun__c Id
     * @throws RunException if the Run is not a completed dry run, its file version
     *         is gone, or a Run is already active
     */
    public static Id promote(Id dryRunId) {
        List<RosterIngestionRun__c> dryRuns = [
            SELECT Id, RosterIngestion__c, Dry_Run__c, Status__c, Content_Version_Id__c
            FROM RosterIngestionRun__c
            WHERE Id = :dryRunId
            WITH USER_MODE
        ];
        if (dryRuns.isEmpty()) {
            throw new RunException('Run not found or not accessible.');
        }
        RosterIngestionRun__c dryRun = dryRuns[0];
        if (!dryRun.Dry_Run__c || !PROMOTABLE_STATUSES.contains(dryRun.Status__c)) {
            throw new RunException('Only a completed dry run can be run for real.');
        }

        RosterIngestion__c roster = lockRoster(dryRun.RosterIngestion__c);
        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId, VersionNumber, Checksum, ContentSize
            FROM ContentVersion
            WHERE Id = :dryRun.Content_Version_Id__c
            WITH USER_MODE
        ];
        if (versions.isEmpty()) {
            throw new RunException('The file version of this dry run no longer exists.');
        }

        return createRun(roster.Id, versions[0], false);
    }

    /**
     * Stops a Queued or Running Run. The slice in progress, if any, still
     * commits; later slices do nothing.
     *
     * @param runId The RosterIngestionRun__c to cancel
     * @throws RunException if the user cannot edit the roster or the Run is not active
     */
    public static void cancel(Id runId) {
        List<RosterIngestionRun__c> runs = [
            SELECT Id, RosterIngestion__c
            FROM RosterIngestionRun__c
            WHERE Id = :runId
            WITH USER_MODE
        ];
        if (runs.isEmpty()) {
            throw new RunException('Run not found or not accessible.');
        }
        lockRoster(runs[0].RosterIngestion__c);

        RosterIngestionRun__c run = [
            SELECT Id, Status__c, Last_Job_Id__c
            FROM RosterIngestionRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (!ACTIVE_STATUSES.contains(run.Status__c)) {
            throw new RunException('Only a queued or running run can be cancelled.');
        }
        finish(run, STATUS_CANCELLED, 'Cancelled by ' + UserInfo.getName() + '.');
        abortJob(run.Last_Job_Id__c);
    }

    /**
     * Fails active Runs whose batch job has already ended. This happens only when
     * a job dies where ProviderIngestionBatch cannot record it, such as a governor
     * limit in start(). Without this, such a Run would stay active and block new
     * Runs on its roster.
     *
     * @param rosterIngestionId The roster whose Runs to check
     */
    public static void failAbandonedRuns(Id rosterIngestionId) {
        List<RosterIngestionRun__c> activeRuns = [
            SELECT Id, Status__c, Last_Job_Id__c
            FROM RosterIngestionRun__c
            WHERE RosterIngestion__c = :rosterIngestionId AND Status__c IN :ACTIVE_STATUSES
            WITH SYSTEM_MODE
        ];
        Set<Id> jobIds = new Set<Id>();
        for (RosterIngestionRun__c run : activeRuns) {
            if (run.Last_Job_Id__c != null) {
                jobIds.add(run.Last_Job_Id__c);
            }
        }
        if (jobIds.isEmpty()) {
            return;
        }

        Map<Id, AsyncApexJob> endedJobsById = new Map<Id, AsyncApexJob>([
            SELECT Id, Status, ExtendedStatus
            FROM AsyncApexJob
            WHERE Id IN :jobIds AND Status IN :ENDED_JOB_STATUSES
            WITH SYSTEM_MODE
        ]);
        List<RosterIngestionRun__c> abandoned = new List<RosterIngestionRun__c>();
        for (RosterIngestionRun__c run : activeRuns) {
            AsyncApexJob job = endedJobsById.get(run.Last_Job_Id__c);
            if (job != null) {
                run.Status__c = STATUS_FAILED;
                run.Completed_At__c = System.now();
                run.Failure_Message__c = ('The batch job ended (' + job.Status + ') before the run was finished' +
                    (String.isBlank(job.ExtendedStatus) ? '.' : ': ' + job.ExtendedStatus)).left(32768);
                abandoned.add(run);
            }
        }
        Database.update(abandoned, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Sets a Run's final status and saves it, with any other changes made to it.
     *
     * @param run The Run, queried with the fields being saved
     * @param status One of the STATUS_ values
     * @param message Why the Run failed or was cancelled; null otherwise
     */
    public static void finish(RosterIngestionRun__c run, String status, String message) {
        run.Status__c = status;
        run.Completed_At__c = System.now();
        if (message != null) {
            run.Failure_Message__c = message.left(32768);
        }
        Database.update(run, AccessLevel.SYSTEM_MODE);
    }

    private static Id createRun(Id rosterIngestionId, ContentVersion version, Boolean dryRun) {
        if (version.ContentSize > maxFileBytes) {
            throw new RunException('The file is ' + (version.ContentSize / 1024) + ' KB; files over ' +
                (maxFileBytes / 1024) + ' KB cannot be ingested.');
        }

        failAbandonedRuns(rosterIngestionId);
        Integer activeRuns = [
            SELECT COUNT()
            FROM RosterIngestionRun__c
            WHERE RosterIngestion__c = :rosterIngestionId AND Status__c IN :ACTIVE_STATUSES
            WITH SYSTEM_MODE
        ];
        if (activeRuns > 0) {
            throw new RunException('A run is already in progress for this roster.');
        }

        RosterIngestionRun__c run = new RosterIngestionRun__c(
            RosterIngestion__c = rosterIngestionId,
            File_Type__c = FILE_TYPE_PERSONNEL,
            Dry_Run__c = dryRun,
            Content_Document_Id__c = version.ContentDocumentId,
            Content_Version_Id__c = version.Id,
            Version_Number__c = version.VersionNumber,
            File_Checksum__c = version.Checksum,
            Status__c = STATUS_QUEUED,
            Rows_Processed__c = 0,
            Inserted__c = 0,
            Updated__c = 0,
            Unchanged__c = 0,
            Errored__c = 0,
            Rows_With_Warnings__c = 0
        );
        Database.insert(run, AccessLevel.SYSTEM_MODE);

        run.Last_Job_Id__c = Database.executeBatch(new ProviderIngestionBatch(run.Id, dryRun), BATCH_SIZE);
        Database.update(run, AccessLevel.SYSTEM_MODE);
        return run.Id;
    }

    /*
     * Checks the user may edit the roster, then locks it. The lock lasts only for
     * this transaction: it stops two simultaneous requests from both passing the
     * "no active Run" check in createRun() before either has inserted its Run.
     * That check is what keeps a second Run from starting while one is running.
     */
    private static RosterIngestion__c lockRoster(Id rosterIngestionId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :rosterIngestionId
        ];
        if (access.isEmpty() || !access[0].HasEditAccess) {
            throw new RunException('You do not have permission to run ingestion on this roster.');
        }

        List<RosterIngestion__c> rosters = [
            SELECT Id, Personnel_File__c
            FROM RosterIngestion__c
            WHERE Id = :rosterIngestionId
            WITH USER_MODE
            FOR UPDATE
        ];
        if (rosters.isEmpty()) {
            throw new RunException('Roster Ingestion record not found or not accessible.');
        }
        return rosters[0];
    }

    /*
     * Stops the Run's batch job. The job may already have finished, in which case
     * there is nothing to stop.
     */
    private static void abortJob(Id jobId) {
        if (jobId == null) {
            return;
        }
        try {
            System.abortJob(jobId);
        } catch (Exception e) {
            // Already finished or aborted; the Run is marked Cancelled either way.
            return;
        }
    }
}
