/**
 * The user-facing actions on a Roster_Intake_Run__c: start a Run over one of
 * a roster's files (provider or relationships), and cancel a Run.
 * The processing itself is RosterIntakeBatch, with the file type's
 * RosterRowProcessor (processorFor).
 *
 * A Run is pinned to one file version (ContentVersion) when it starts, so
 * uploading a new version while it runs has no effect on it. Only one Run per
 * roster may be active (Queued or Running) at a time, whatever its file type;
 * different rosters run independently.
 *
 * See docs/architecture/roster-intake.md for how the pieces fit
 * together.
 *
 * Starting and cancelling check the user's access to the roster.
 * After that, Run and Issue records are written in system mode: they are
 * processing records owned by the roster, and the user needs no field access
 * to their internal fields.
 */
public with sharing class RosterIntakeRunService {

    public class RunException extends Exception {}

    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_RUNNING = 'Running';
    public static final String STATUS_COMPLETED = 'Completed';
    public static final String STATUS_COMPLETED_WITH_ERRORS = 'Completed with Errors';
    public static final String STATUS_FAILED = 'Failed';
    public static final String STATUS_CANCELLED = 'Cancelled';

    public static final String FILE_TYPE_PROVIDER = 'Provider';
    public static final String FILE_TYPE_RELATIONSHIPS = 'Relationships';

    /* The Roster_Intake__c field holding each file type's ContentDocument Id. */
    private static final Map<String, Schema.SObjectField> FILE_FIELDS_BY_TYPE = new Map<String, Schema.SObjectField>{
        FILE_TYPE_PROVIDER => Roster_Intake__c.Provider_File_ID__c,
        FILE_TYPE_RELATIONSHIPS => Roster_Intake__c.Relationships_File_ID__c
    };

    public static final String SEVERITY_ERROR = 'Error';
    public static final String SEVERITY_WARNING = 'Warning';
    public static final String CODE_COLUMN_COUNT = 'COLUMN_COUNT';
    public static final String CODE_INVALID_VALUE = 'INVALID_VALUE';

    /*
     * Rows per execute() of RosterIntakeBatch. 200 rows cost about 3 s of
     * the 60 s async CPU limit in the innovage sandbox (2026-10-14), including
     * the org's Account automation.
     */
    public static final Integer BATCH_SIZE = 200;

    /*
     * A guard against files too large to parse in one transaction, checked
     * before the job starts. The real limit is the row count, checked by
     * RosterIntakeBatch.start().
     */
    @TestVisible
    private static Integer maxFileBytes = 3 * 1024 * 1024;

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{ STATUS_QUEUED, STATUS_RUNNING };
    private static final Set<String> ENDED_JOB_STATUSES = new Set<String>{ 'Completed', 'Failed', 'Aborted' };

    /**
     * Starts a Run over the current version of the roster's provider file.
     *
     * @param rosterIntakeId The Roster_Intake__c record
     * @return The new Roster_Intake_Run__c Id
     * @throws RunException see startRun(Id, String)
     */
    public static Id startRun(Id rosterIntakeId) {
        return startRun(rosterIntakeId, FILE_TYPE_PROVIDER);
    }

    /**
     * Starts a Run over the current version of one of the roster's files.
     *
     * @param rosterIntakeId The Roster_Intake__c record
     * @param fileType FILE_TYPE_PROVIDER or FILE_TYPE_RELATIONSHIPS
     * @return The new Roster_Intake_Run__c Id
     * @throws RunException if the file type is unknown, the user cannot edit the roster,
     *         it has no file of that type, the file is too large, or a Run is already active
     * @example
     * Id runId = RosterIntakeRunService.startRun(rosterIntakeId, RosterIntakeRunService.FILE_TYPE_RELATIONSHIPS);
     */
    public static Id startRun(Id rosterIntakeId, String fileType) {
        Schema.SObjectField fileField = FILE_FIELDS_BY_TYPE.get(fileType);
        if (fileField == null) {
            throw new RunException('Unknown file type "' + fileType + '".');
        }

        Roster_Intake__c roster = lockRoster(rosterIntakeId);
        String documentId = (String) roster.get(fileField);
        String fileName = fileType.toLowerCase() + ' file';
        if (String.isBlank(documentId)) {
            throw new RunException('This roster has no ' + fileName + '.');
        }

        List<ContentVersion> versions = [
            SELECT Id, ContentDocumentId, VersionNumber, Checksum, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId = :documentId AND IsLatest = TRUE
            WITH USER_MODE
        ];
        if (versions.isEmpty()) {
            throw new RunException('The ' + fileName + ' was not found or is not accessible.');
        }

        return createRun(roster.Id, fileType, versions[0]);
    }

    /**
     * @param fileType A Run's File_Type__c
     * @return The row processing for that file type
     * @throws RunException if the file type is unknown
     */
    public static RosterRowProcessor processorFor(String fileType) {
        if (fileType == FILE_TYPE_PROVIDER) {
            return new ProviderIntakeService.Processor();
        }
        if (fileType == FILE_TYPE_RELATIONSHIPS) {
            return new RelationshipIntakeService.Processor();
        }
        throw new RunException('Unknown file type "' + fileType + '".');
    }

    private static Id createRun(Id rosterIntakeId, String fileType, ContentVersion version) {
        if (version.ContentSize > maxFileBytes) {
            throw new RunException('The file is ' + (version.ContentSize / 1024) + ' KB; files over ' +
                (maxFileBytes / 1024) + ' KB cannot be ingested.');
        }

        failAbandonedRuns(rosterIntakeId);
        Integer activeRuns = [
            SELECT COUNT()
            FROM Roster_Intake_Run__c
            WHERE Roster_Intake__c = :rosterIntakeId AND Status__c IN :ACTIVE_STATUSES
            WITH SYSTEM_MODE
        ];
        if (activeRuns > 0) {
            throw new RunException('A run is already in progress for this roster.');
        }

        Roster_Intake_Run__c run = new Roster_Intake_Run__c(
            Roster_Intake__c = rosterIntakeId,
            File_Type__c = fileType,
            Content_Document_ID__c = version.ContentDocumentId,
            Content_Version_ID__c = version.Id,
            Version_Number__c = version.VersionNumber,
            File_Checksum__c = version.Checksum,
            Status__c = STATUS_QUEUED,
            Rows_Processed__c = 0,
            Rows_Inserted__c = 0,
            Rows_Updated__c = 0,
            Rows_Terminated__c = 0,
            Rows_Unchanged__c = 0,
            Rows_Errored__c = 0,
            Rows_With_Warnings__c = 0
        );
        Database.insert(run, AccessLevel.SYSTEM_MODE);

        run.Last_Job_ID__c = Database.executeBatch(new RosterIntakeBatch(run.Id), BATCH_SIZE);
        Database.update(run, AccessLevel.SYSTEM_MODE);
        return run.Id;
    }

    /*
     * Checks the user may edit the roster, then locks it. The lock lasts only for
     * this transaction: it stops two simultaneous requests from both passing the
     * "no active Run" check in createRun() before either has inserted its Run.
     * That check is what keeps a second Run from starting while one is running.
     */
    private static Roster_Intake__c lockRoster(Id rosterIntakeId) {
        // This query is the access check itself, so it runs as the user: a user can
        // always read their own UserRecordAccess. USER_MODE is the default for API
        // 67.0, but Code Analyzer (ApexCRUDViolation) flags SOQL that doesn't state its
        // access mode, and stating it makes the intent explicit to the reader.
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :rosterIntakeId
            WITH USER_MODE
        ];
        if (access.isEmpty() || !access[0].HasEditAccess) {
            throw new RunException('You do not have permission to run intake on this roster.');
        }

        List<Roster_Intake__c> rosters = [
            SELECT Id, Provider_File_ID__c, Relationships_File_ID__c
            FROM Roster_Intake__c
            WHERE Id = :rosterIntakeId
            WITH USER_MODE
            FOR UPDATE
        ];
        if (rosters.isEmpty()) {
            throw new RunException('Roster Intake record not found or not accessible.');
        }
        return rosters[0];
    }

    /**
     * Stops a Queued or Running Run. The slice in progress, if any, still
     * commits; later slices do nothing.
     *
     * @param runId The Roster_Intake_Run__c to cancel
     * @throws RunException if the user cannot edit the roster or the Run is not active
     */
    public static void cancel(Id runId) {
        List<Roster_Intake_Run__c> runs = [
            SELECT Id, Roster_Intake__c
            FROM Roster_Intake_Run__c
            WHERE Id = :runId
            WITH USER_MODE
        ];
        if (runs.isEmpty()) {
            throw new RunException('Run not found or not accessible.');
        }
        lockRoster(runs[0].Roster_Intake__c);

        Roster_Intake_Run__c run = [
            SELECT Id, Status__c, Last_Job_ID__c
            FROM Roster_Intake_Run__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (!ACTIVE_STATUSES.contains(run.Status__c)) {
            throw new RunException('Only a queued or running run can be cancelled.');
        }
        finish(run, STATUS_CANCELLED, 'Cancelled by ' + UserInfo.getName() + '.');
        abortJob(run.Last_Job_ID__c);
    }

    /**
     * Fails active Runs whose batch job has already ended. This happens only when
     * a job dies where RosterIntakeBatch cannot record it, such as a governor
     * limit in start(). Without this, such a Run would stay active and block new
     * Runs on its roster.
     *
     * @param rosterIntakeId The roster whose Runs to check
     */
    public static void failAbandonedRuns(Id rosterIntakeId) {
        List<Roster_Intake_Run__c> activeRuns = [
            SELECT Id, Status__c, Last_Job_ID__c
            FROM Roster_Intake_Run__c
            WHERE Roster_Intake__c = :rosterIntakeId AND Status__c IN :ACTIVE_STATUSES
            WITH SYSTEM_MODE
        ];
        Set<Id> jobIds = new Set<Id>();
        for (Roster_Intake_Run__c run : activeRuns) {
            if (run.Last_Job_ID__c != null) {
                jobIds.add(run.Last_Job_ID__c);
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
        List<Roster_Intake_Run__c> abandoned = new List<Roster_Intake_Run__c>();
        for (Roster_Intake_Run__c run : activeRuns) {
            AsyncApexJob job = endedJobsById.get(run.Last_Job_ID__c);
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
    public static void finish(Roster_Intake_Run__c run, String status, String message) {
        run.Status__c = status;
        run.Completed_At__c = System.now();
        if (message != null) {
            run.Failure_Message__c = message.left(32768);
        }
        Database.update(run, AccessLevel.SYSTEM_MODE);
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
