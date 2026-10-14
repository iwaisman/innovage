/**
 * Runs the ingestion of a RosterIngestion__c's personnel file as a
 * RosterIngestionRun__c, one chunk of rows per async transaction.
 *
 *     startRun()     sync: pins the file's current version, creates the Run, enqueues the first chunk
 *     processChunk() async (ProviderIngestionJob): parses and ingests the next chunk, records
 *                    Issues and counters, then enqueues the next chunk or completes the Run
 *     handleChunkFailure()  (ProviderIngestionJobFinalizer): a chunk died on a governor limit;
 *                    retry it with half as many rows, or fail the Run
 *
 * Every chunk commits its Provider changes, Issues, counters and cursor
 * (Next_Offset__c) together, so a Run's records always describe exactly the
 * rows that were committed. Chunks run one at a time, so the Run is never
 * written by two transactions at once.
 *
 * See docs/plans/provider-bulk-ingestion.md for the design.
 *
 * Starting, promoting and cancelling check the user's access to the roster.
 * After that, Run and Issue records are written in system mode: they are
 * processing records owned by the roster, and the uploader needs no field
 * access to their internal fields.
 */
public with sharing class RosterIngestionRunService {

    public class RunException extends Exception {}

    public enum ChunkOutcome { MORE, DONE, STOPPED }

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
     * 200 rows cost about 3 s of the 60 s async CPU limit in the innovage sandbox
     * (2026-10-14: parsing + mapping ~3 ms per row, inserting 200 Providers through
     * Account automation ~1.2 s, updating 200 ~1.7 s). 500 leaves wide headroom;
     * the finalizer halves it if a chunk still hits a limit.
     */
    @TestVisible
    private static final Integer DEFAULT_CHUNK_SIZE = 500;
    public static final Integer MIN_CHUNK_SIZE = 10;

    /*
     * Every chunk holds the whole file in the 12 MB async heap (about one byte
     * per character, plus the Blob while it is converted).
     */
    @TestVisible
    private static Integer maxFileBytes = 5 * 1024 * 1024;

    /* The first data row; the header is spreadsheet row 1. */
    private static final Integer FIRST_DATA_ROW = 2;

    private static final List<String> REQUIRED_HEADERS = new List<String>{
        ProviderCsvMapping.UNIQUE_ID_HEADER,
        ProviderCsvMapping.NPI_HEADER,
        'Last Name'
    };

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{ STATUS_QUEUED, STATUS_RUNNING };
    private static final Set<String> PROMOTABLE_STATUSES = new Set<String>{ STATUS_COMPLETED, STATUS_COMPLETED_WITH_ERRORS };

    /*
     * Chained Queueables cannot be enqueued from a test (the platform throws), so
     * tests drive the chain by calling processChunk() repeatedly.
     */
    @TestVisible
    private static Boolean chainingEnabled = !Test.isRunningTest();

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
     * Stops a Queued or Running Run after the chunk in progress, if any, commits.
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

        RosterIngestionRun__c run = queryRunForUpdate(runId);
        if (!ACTIVE_STATUSES.contains(run.Status__c)) {
            throw new RunException('Only a queued or running run can be cancelled.');
        }
        finish(run, STATUS_CANCELLED, 'Cancelled by ' + UserInfo.getName() + '.');
    }

    /**
     * Processes the Run's next chunk; called once per ProviderIngestionJob.
     *
     * Unexpected exceptions propagate: the job rolls the chunk back and fails the Run.
     *
     * @param runId The RosterIngestionRun__c
     * @param tracker Keys and Providers claimed by the Run's earlier rows; updated in place
     * @return MORE when another chunk was enqueued (or is due), DONE when the Run completed,
     *         STOPPED when the Run is no longer active or failed on a file-level problem
     */
    public static ChunkOutcome processChunk(Id runId, ProviderIngestionService.DuplicateTracker tracker) {
        RosterIngestionRun__c run = queryRunForUpdate(runId);
        if (!ACTIVE_STATUSES.contains(run.Status__c)) {
            return ChunkOutcome.STOPPED;
        }
        if (run.Status__c == STATUS_QUEUED) {
            run.Status__c = STATUS_RUNNING;
            run.Started_At__c = System.now();
        }

        CsvParser.Chunk chunk;
        List<String> headers;
        try {
            String csv = loadFile(run.Content_Version_Id__c);
            headers = readHeaders(csv);

            Integer offset = (run.Next_Offset__c ?? 0).intValue();
            if (offset == 0) {
                offset = CsvParser.parseChunk(csv, 0, 1, csvOptions()).nextOffset;
            }
            chunk = CsvParser.parseChunk(csv, offset, (run.Chunk_Size__c ?? DEFAULT_CHUNK_SIZE).intValue(), csvOptions());
        } catch (RunException e) {
            finish(run, STATUS_FAILED, e.getMessage());
            return ChunkOutcome.STOPPED;
        } catch (CsvParser.CsvParseException e) {
            finish(run, STATUS_FAILED, 'The file is not valid CSV: ' + e.getMessage());
            return ChunkOutcome.STOPPED;
        }

        ChunkResults chunkResults = ingestChunk(run, headers, chunk.records, tracker);
        applyCounters(run, chunkResults);
        run.Next_Offset__c = chunk.nextOffset;
        run.Next_Row_Number__c = (run.Next_Row_Number__c ?? FIRST_DATA_ROW) + chunk.records.size();
        run.Chunk_Count__c = (run.Chunk_Count__c ?? 0) + 1;

        Database.insert(chunkResults.issues, AccessLevel.SYSTEM_MODE);

        if (chunk.isEndOfInput) {
            finish(run, run.Errored__c > 0 ? STATUS_COMPLETED_WITH_ERRORS : STATUS_COMPLETED, null);
            return ChunkOutcome.DONE;
        }

        enqueueChunk(run, tracker);
        Database.update(run, AccessLevel.SYSTEM_MODE);
        return ChunkOutcome.MORE;
    }

    /**
     * Called by the finalizer when a chunk's transaction died, typically on an
     * uncatchable LimitException. Nothing from that chunk was committed, so it
     * is retried from the same offset with half as many rows, down to
     * MIN_CHUNK_SIZE; below that the Run fails.
     *
     * @param runId The RosterIngestionRun__c
     * @param tracker The tracker as it was when the failed chunk started
     * @param failure Why the chunk died
     */
    public static void handleChunkFailure(Id runId, ProviderIngestionService.DuplicateTracker tracker, String failure) {
        RosterIngestionRun__c run = queryRunForUpdate(runId);
        if (!ACTIVE_STATUSES.contains(run.Status__c)) {
            return;
        }

        Integer chunkSize = (run.Chunk_Size__c ?? DEFAULT_CHUNK_SIZE).intValue();
        if (chunkSize <= MIN_CHUNK_SIZE) {
            finish(run, STATUS_FAILED, 'A chunk of ' + chunkSize + ' rows starting at row ' +
                run.Next_Row_Number__c + ' could not be processed: ' + failure);
            return;
        }

        run.Chunk_Size__c = Math.max(MIN_CHUNK_SIZE, chunkSize / 2);
        enqueueChunk(run, tracker);
        Database.update(run, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Marks a Run as failed; used by the job when a chunk throws.
     *
     * @param runId The RosterIngestionRun__c
     * @param message Why it failed
     */
    public static void failRun(Id runId, String message) {
        RosterIngestionRun__c run = queryRunForUpdate(runId);
        if (ACTIVE_STATUSES.contains(run.Status__c)) {
            finish(run, STATUS_FAILED, message);
        }
    }

    private static Id createRun(Id rosterIngestionId, ContentVersion version, Boolean dryRun) {
        if (version.ContentSize > maxFileBytes) {
            throw new RunException('The file is ' + (version.ContentSize / 1024) + ' KB; files over ' +
                (maxFileBytes / 1024) + ' KB cannot be ingested.');
        }

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
            Rows_With_Warnings__c = 0,
            Next_Offset__c = 0,
            Next_Row_Number__c = FIRST_DATA_ROW,
            Chunk_Size__c = DEFAULT_CHUNK_SIZE,
            Chunk_Count__c = 0
        );
        Database.insert(run, AccessLevel.SYSTEM_MODE);

        run.Last_Job_Id__c = System.enqueueJob(new ProviderIngestionJob(run.Id, new ProviderIngestionService.DuplicateTracker()));
        Database.update(run, AccessLevel.SYSTEM_MODE);
        return run.Id;
    }

    /*
     * Locks the roster so two users cannot start Runs at the same moment, after
     * checking the user may edit it.
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

    private static RosterIngestionRun__c queryRunForUpdate(Id runId) {
        return [
            SELECT Id, Status__c, Dry_Run__c, Content_Version_Id__c, Started_At__c,
                Rows_Processed__c, Inserted__c, Updated__c, Unchanged__c, Errored__c, Rows_With_Warnings__c,
                Next_Offset__c, Next_Row_Number__c, Chunk_Size__c, Chunk_Count__c
            FROM RosterIngestionRun__c
            WHERE Id = :runId
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
    }

    /*
     * Returns the pinned file version as text. The Blob goes out of scope on
     * return, so only the String stays on the heap.
     */
    private static String loadFile(String contentVersionId) {
        List<ContentVersion> versions = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :contentVersionId
            WITH SYSTEM_MODE
        ];
        if (versions.isEmpty()) {
            throw new RunException('The file version this run was started on no longer exists.');
        }

        try {
            return versions[0].VersionData.toString();
        } catch (StringException e) {
            throw new RunException('The file is not UTF-8 text. Save it as "CSV UTF-8" and upload a new version.');
        }
    }

    /*
     * The header is re-read by every chunk; it is one record, so this is cheap
     * and keeps the Run free of parser state.
     */
    private static List<String> readHeaders(String csv) {
        CsvParser.Chunk headerChunk = CsvParser.parseChunk(csv, 0, 1, csvOptions());
        if (headerChunk.records.isEmpty()) {
            throw new RunException('The file is empty.');
        }

        List<String> headers = CsvParser.toHeaders(headerChunk.records[0]);
        List<String> missing = new List<String>();
        for (String required : REQUIRED_HEADERS) {
            if (!headers.contains(required)) {
                missing.add('"' + required + '"');
            }
        }
        if (!missing.isEmpty()) {
            throw new RunException('The file is missing required columns: ' + String.join(missing, ', ') + '.');
        }
        return headers;
    }

    private static CsvParser.Options csvOptions() {
        return new CsvParser.Options(false, true);
    }

    /*
     * What one chunk produced: its Issue records and its outcome counts.
     */
    private class ChunkResults {
        List<RosterIngestionIssue__c> issues = new List<RosterIngestionIssue__c>();
        Map<String, Integer> countsByCounter = new Map<String, Integer>();

        void count(String counter) {
            countsByCounter.put(counter, (countsByCounter.get(counter) ?? 0) + 1);
        }
    }

    private static ChunkResults ingestChunk(
        RosterIngestionRun__c run,
        List<String> headers,
        List<List<String>> records,
        ProviderIngestionService.DuplicateTracker tracker
    ) {
        ChunkResults chunkResults = new ChunkResults();
        List<ProviderIngestionService.RowInput> rows = new List<ProviderIngestionService.RowInput>();
        Integer rowNumber = (run.Next_Row_Number__c ?? FIRST_DATA_ROW).intValue();

        for (List<String> record : records) {
            chunkResults.count('Rows_Processed__c');
            if (record.size() != headers.size()) {
                chunkResults.count('Errored__c');
                chunkResults.issues.add(newIssue(run.Id, rowNumber, SEVERITY_ERROR, CODE_COLUMN_COUNT,
                    'The row has ' + record.size() + ' columns; the header has ' + headers.size() + '.'));
            } else {
                Map<String, String> values = new Map<String, String>();
                for (Integer column = 0; column < headers.size(); column++) {
                    values.put(headers[column], record[column]);
                }
                rows.add(new ProviderIngestionService.RowInput(rowNumber, values));
            }
            rowNumber++;
        }

        for (ProviderIngestionService.IngestResult result : ProviderIngestionService.ingestAll(rows, tracker, run.Dry_Run__c)) {
            recordResult(run.Id, result, chunkResults);
        }
        return chunkResults;
    }

    private static void recordResult(Id runId, ProviderIngestionService.IngestResult result, ChunkResults chunkResults) {
        switch on result.outcome {
            when INSERTED {
                chunkResults.count('Inserted__c');
            }
            when UPDATED {
                chunkResults.count('Updated__c');
            }
            when UNCHANGED {
                chunkResults.count('Unchanged__c');
            }
            when else {
                chunkResults.count('Errored__c');
            }
        }

        for (String error : result.errors) {
            chunkResults.issues.add(withRow(newIssue(runId, result.rowNumber, SEVERITY_ERROR, result.errorCode, error), result));
        }
        for (ProviderCsvMapping.ValueWarning warning : result.valueWarnings) {
            RosterIngestionIssue__c issue = newIssue(runId, result.rowNumber, SEVERITY_WARNING, CODE_INVALID_VALUE, warning.message);
            issue.Column__c = warning.column.left(255);
            chunkResults.issues.add(withRow(issue, result));
        }
        if (!result.valueWarnings.isEmpty()) {
            chunkResults.count('Rows_With_Warnings__c');
        }
    }

    private static RosterIngestionIssue__c newIssue(Id runId, Integer rowNumber, String severity, String code, String message) {
        return new RosterIngestionIssue__c(
            RosterIngestionRun__c = runId,
            Row_Number__c = rowNumber,
            Severity__c = severity,
            Code__c = code,
            Message__c = message?.left(32768)
        );
    }

    private static RosterIngestionIssue__c withRow(RosterIngestionIssue__c issue, ProviderIngestionService.IngestResult result) {
        issue.Provider__c = result.accountId;
        issue.Unique_ID__c = result.uniqueId?.left(80);
        issue.NPI__c = result.npi?.left(80);
        return issue;
    }

    private static void applyCounters(RosterIngestionRun__c run, ChunkResults chunkResults) {
        for (String counter : chunkResults.countsByCounter.keySet()) {
            Decimal current = (Decimal) run.get(counter) ?? 0;
            run.put(counter, current + chunkResults.countsByCounter.get(counter));
        }
    }

    private static void enqueueChunk(RosterIngestionRun__c run, ProviderIngestionService.DuplicateTracker tracker) {
        if (chainingEnabled) {
            run.Last_Job_Id__c = System.enqueueJob(new ProviderIngestionJob(run.Id, tracker));
        }
    }

    private static void finish(RosterIngestionRun__c run, String status, String message) {
        run.Status__c = status;
        run.Completed_At__c = System.now();
        if (message != null) {
            run.Failure_Message__c = message.left(32768);
        }
        Database.update(run, AccessLevel.SYSTEM_MODE);
    }
}
