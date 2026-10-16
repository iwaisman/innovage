/**
 * Processes one RosterIngestionRun__c with Batch Apex. Salesforce calls:
 *
 *     start()    once: loads the Run's pinned file version, checks it, parses
 *                every row and returns the rows. Salesforce keeps that list.
 *     execute()  once per slice of rows (RosterIngestionRunService.BATCH_SIZE),
 *                each in its own transaction, one slice after another: ingests
 *                the rows and adds the slice's Issues and counts to the Run.
 *     finish()   once, after the last slice: sets the Run's final status.
 *
 * A slice that throws (including on a governor limit) is rolled back and the
 * job moves on to the next slice; finish() reports the rows that were not
 * processed. Re-running the file is safe: rows already ingested come out as
 * UNCHANGED.
 *
 * Database.Stateful keeps the header row, read in start(), available to every
 * execute(). The object holds nothing else that changes, so the cost of saving
 * it after each call is negligible.
 */
public with sharing class ProviderIngestionBatch implements Database.Batchable<ProviderIngestionBatch.RowItem>, Database.Stateful {

    /** The largest file accepted, in data rows. start() parses the whole file in one transaction. */
    @TestVisible
    private static Integer maxRows = 5000;

    private static final List<String> REQUIRED_HEADERS = new List<String>{
        ProviderCsvMapping.UNIQUE_ID_HEADER,
        ProviderCsvMapping.NPI_HEADER,
        'Last Name'
    };

    /**
     * One CSV record and its spreadsheet row number (the header is row 1).
     * Values are kept as a list, not a map, so the header names are stored
     * once (on the batch) rather than once per row.
     */
    public class RowItem {
        public Integer rowNumber;
        public List<String> values;

        public RowItem(Integer rowNumber, List<String> values) {
            this.rowNumber = rowNumber;
            this.values = values;
        }
    }

    private final Id runId;
    private List<String> headers;

    /**
     * @param runId The RosterIngestionRun__c to process
     */
    public ProviderIngestionBatch(Id runId) {
        this.runId = runId;
    }

    /**
     * Loads and parses the file. A problem with the file as a whole fails the
     * Run and returns no rows, so no slice runs.
     *
     * @param context The batch context
     * @return Every data row of the file
     */
    public Iterable<RowItem> start(Database.BatchableContext context) {
        RosterIngestionRun__c run = queryRunForUpdate();
        if (run.Status__c != RosterIngestionRunService.STATUS_QUEUED) {
            return new List<RowItem>(); // cancelled before it started
        }
        run.Status__c = RosterIngestionRunService.STATUS_RUNNING;
        run.Started_At__c = System.now();

        List<RowItem> rows = new List<RowItem>();
        try {
            List<List<String>> records = CsvParser.parse(
                loadFile(run.Content_Version_Id__c),
                new CsvParser.Options(false, true)
            );
            headers = readHeaders(records);

            Integer dataRows = records.size() - 1;
            if (dataRows > maxRows) {
                throw new RosterIngestionRunService.RunException('The file has ' + dataRows +
                    ' rows; at most ' + maxRows + ' can be ingested.');
            }
            for (Integer i = 1; i < records.size(); i++) {
                rows.add(new RowItem(i + 1, records[i]));
            }
            run.Total_Rows__c = dataRows;
        } catch (RosterIngestionRunService.RunException e) {
            RosterIngestionRunService.finish(run, RosterIngestionRunService.STATUS_FAILED, e.getMessage());
            return new List<RowItem>();
        } catch (CsvParser.CsvParseException e) {
            RosterIngestionRunService.finish(run, RosterIngestionRunService.STATUS_FAILED, 'The file is not valid CSV: ' + e.getMessage());
            return new List<RowItem>();
        }

        Database.update(run, AccessLevel.SYSTEM_MODE);
        return rows;
    }

    /**
     * Ingests one slice of rows and records its Issues and counts on the Run.
     *
     * @param context The batch context
     * @param scope The slice's rows, in file order
     */
    public void execute(Database.BatchableContext context, List<RowItem> scope) {
        RosterIngestionRun__c run = queryRunForUpdate();
        if (run.Status__c != RosterIngestionRunService.STATUS_RUNNING) {
            return; // cancelled
        }

        SliceResults sliceResults = new SliceResults(runId);
        List<ProviderIngestionService.RowInput> rows = new List<ProviderIngestionService.RowInput>();
        for (RowItem item : scope) {
            sliceResults.count('Rows_Processed__c');
            if (item.values.size() != headers.size()) {
                sliceResults.addColumnCountError(item, headers.size());
                continue;
            }
            Map<String, String> valuesByHeader = new Map<String, String>();
            for (Integer column = 0; column < headers.size(); column++) {
                valuesByHeader.put(headers[column], item.values[column]);
            }
            rows.add(new ProviderIngestionService.RowInput(item.rowNumber, valuesByHeader));
        }

        for (ProviderIngestionService.IngestResult result : ProviderIngestionService.ingestAll(rows)) {
            sliceResults.add(result);
        }

        Database.insert(sliceResults.issues, AccessLevel.SYSTEM_MODE);
        sliceResults.addCountsTo(run);
        Database.update(run, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Sets the Run's final status. Rows of a slice that failed were not counted,
     * so fewer processed rows than the file holds means part of the job failed.
     *
     * @param context The batch context; null when a test drives the batch directly
     */
    public void finish(Database.BatchableContext context) {
        RosterIngestionRun__c run = queryRunForUpdate();
        if (run.Status__c != RosterIngestionRunService.STATUS_RUNNING) {
            return; // failed in start() or cancelled
        }

        Integer total = (run.Total_Rows__c ?? 0).intValue();
        Integer missing = total - (run.Rows_Processed__c ?? 0).intValue();
        if (missing > 0) {
            String status = missing == total
                ? RosterIngestionRunService.STATUS_FAILED
                : RosterIngestionRunService.STATUS_COMPLETED_WITH_ERRORS;
            RosterIngestionRunService.finish(run, status, missing + ' of ' + total +
                ' rows were not processed because part of the batch job failed' + jobError(context) +
                ' Re-running the file is safe: rows already ingested will be unchanged.');
            return;
        }

        RosterIngestionRunService.finish(
            run,
            run.Errored__c > 0 ? RosterIngestionRunService.STATUS_COMPLETED_WITH_ERRORS : RosterIngestionRunService.STATUS_COMPLETED,
            null
        );
    }

    private RosterIngestionRun__c queryRunForUpdate() {
        return [
            SELECT Id, Status__c, Content_Version_Id__c, Started_At__c, Total_Rows__c,
                Rows_Processed__c, Inserted__c, Updated__c, Unchanged__c, Errored__c, Rows_With_Warnings__c
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
            throw new RosterIngestionRunService.RunException('The file version this run was started on no longer exists.');
        }

        try {
            return versions[0].VersionData.toString();
        } catch (StringException e) {
            throw new RosterIngestionRunService.RunException('The file is not UTF-8 text. Save it as "CSV UTF-8" and upload a new version.');
        }
    }

    private static List<String> readHeaders(List<List<String>> records) {
        if (records.isEmpty()) {
            throw new RosterIngestionRunService.RunException('The file is empty.');
        }

        List<String> headers = CsvParser.toHeaders(records[0]);
        List<String> missing = new List<String>();
        for (String required : REQUIRED_HEADERS) {
            if (!headers.contains(required)) {
                missing.add('"' + required + '"');
            }
        }
        if (!missing.isEmpty()) {
            throw new RosterIngestionRunService.RunException('The file is missing required columns: ' + String.join(missing, ', ') + '.');
        }
        return headers;
    }

    private static String jobError(Database.BatchableContext context) {
        if (context == null) {
            return '.';
        }
        List<AsyncApexJob> jobs = [
            SELECT ExtendedStatus
            FROM AsyncApexJob
            WHERE Id = :context.getJobId()
            WITH SYSTEM_MODE
        ];
        String error = jobs.isEmpty() ? null : jobs[0].ExtendedStatus;
        return String.isBlank(error) ? '.' : ': ' + error;
    }

    /*
     * What one slice produced: its Issue records and its outcome counts.
     */
    private class SliceResults {
        private final Id runId;
        private List<RosterIngestionIssue__c> issues = new List<RosterIngestionIssue__c>();
        private Map<String, Integer> countsByField = new Map<String, Integer>();

        SliceResults(Id runId) {
            this.runId = runId;
        }

        void count(String field) {
            countsByField.put(field, (countsByField.get(field) ?? 0) + 1);
        }

        void addColumnCountError(RowItem item, Integer headerCount) {
            count('Errored__c');
            issues.add(newIssue(item.rowNumber, RosterIngestionRunService.SEVERITY_ERROR, RosterIngestionRunService.CODE_COLUMN_COUNT,
                'The row has ' + item.values.size() + ' columns; the header has ' + headerCount + '.'));
        }

        void add(ProviderIngestionService.IngestResult result) {
            switch on result.outcome {
                when INSERTED {
                    count('Inserted__c');
                }
                when UPDATED {
                    count('Updated__c');
                }
                when UNCHANGED {
                    count('Unchanged__c');
                }
                when else {
                    count('Errored__c');
                }
            }

            for (String error : result.errors) {
                issues.add(withRowKeys(newIssue(result.rowNumber, RosterIngestionRunService.SEVERITY_ERROR, result.errorCode, error), result));
            }
            for (ProviderCsvMapping.ValueWarning warning : result.valueWarnings) {
                RosterIngestionIssue__c issue = newIssue(
                    result.rowNumber,
                    RosterIngestionRunService.SEVERITY_WARNING,
                    RosterIngestionRunService.CODE_INVALID_VALUE,
                    warning.message
                );
                issue.Column__c = warning.column.left(255);
                issues.add(withRowKeys(issue, result));
            }
            if (!result.valueWarnings.isEmpty()) {
                count('Rows_With_Warnings__c');
            }
        }

        void addCountsTo(RosterIngestionRun__c run) {
            for (String field : countsByField.keySet()) {
                Decimal current = (Decimal) run.get(field) ?? 0;
                run.put(field, current + countsByField.get(field));
            }
        }

        private RosterIngestionIssue__c newIssue(Integer rowNumber, String severity, String code, String message) {
            return new RosterIngestionIssue__c(
                RosterIngestionRun__c = runId,
                Row_Number__c = rowNumber,
                Severity__c = severity,
                Code__c = code,
                Message__c = message?.left(32768)
            );
        }

        private RosterIngestionIssue__c withRowKeys(RosterIngestionIssue__c issue, ProviderIngestionService.IngestResult result) {
            issue.Provider__c = result.accountId;
            issue.Unique_ID__c = result.uniqueId?.left(80);
            issue.NPI__c = result.npi?.left(80);
            return issue;
        }
    }
}
