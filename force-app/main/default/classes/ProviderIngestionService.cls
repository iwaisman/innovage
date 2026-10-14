/**
 * Ingests Provider roster CSV rows: finds the matching Provider for each row and
 * either creates it, updates it, or reports why the row cannot be ingested.
 *
 *     UNIQUE_MATCH  -> update the OVERWRITE / FILL_IF_BLANK fields that changed
 *     NO_MATCH      -> insert a Provider from every valid mapped value
 *     anything else -> ERROR (returned to the caller)
 *
 * ingestAll() is the bulk entry point: one matching query and at most one insert
 * and one update for the whole list. ingest() is the single-row form of it.
 *
 * Rows in one file must not refer to the same Provider twice; the first
 * occurrence wins and later ones are DUPLICATE_IN_FILE errors. A
 * DuplicateTracker remembers what earlier rows claimed, so the rule also holds
 * when a file is ingested in several chunks (see RosterIngestionRunService).
 *
 * DML runs in system mode for the same reason ProviderMatcher queries in
 * system mode: ingestion writes Providers on behalf of the roster, not the
 * uploader, and the uploader's field access must not silently drop values.
 */
public with sharing class ProviderIngestionService {

    public enum Outcome { INSERTED, UPDATED, UNCHANGED, ERROR }

    /*
     * Error codes besides the AccountMatchResult.Outcome names. These are the
     * values of RosterIngestionIssue__c.Code__c.
     */
    public static final String MISSING_LAST_NAME = 'MISSING_LAST_NAME';
    public static final String DUPLICATE_IN_FILE = 'DUPLICATE_IN_FILE';
    public static final String SAVE_ERROR = 'SAVE_ERROR';

    /**
     * The before and after value of one updated field.
     */
    public class FieldChange {
        public Object oldValue { get; private set; }
        public Object newValue { get; private set; }

        public FieldChange(Object oldValue, Object newValue) {
            this.oldValue = oldValue;
            this.newValue = newValue;
        }
    }

    /**
     * One CSV row and its position in the file.
     */
    public class RowInput {
        /** The spreadsheet row number (the header is row 1); used in messages and results. */
        public Integer rowNumber { get; private set; }
        public Map<String, String> values { get; private set; }

        public RowInput(Integer rowNumber, Map<String, String> values) {
            this.rowNumber = rowNumber;
            this.values = values;
        }
    }

    /**
     * What happened to one CSV row.
     */
    public class IngestResult {
        public Integer rowNumber { get; private set; }
        public Outcome outcome { get; private set; }
        public AccountMatchResult.Outcome matchOutcome { get; private set; }

        /** The row's raw key values (trimmed), for reporting. */
        public String uniqueId { get; private set; }
        public String npi { get; private set; }

        /** The Provider updated, matched, or inserted. Null for a dry-run insert, which was rolled back. */
        public Id accountId { get; private set; }

        /** Why the row is an ERROR: an AccountMatchResult.Outcome name or one of this class's codes. */
        public String errorCode { get; private set; }
        public List<String> errors { get; private set; }
        public List<String> warnings { get; private set; }
        public List<ProviderCsvMapping.ValueWarning> valueWarnings { get; private set; }
        public Map<String, FieldChange> changesByField { get; private set; }

        private IngestResult(Integer rowNumber, ProviderCsvMapping.MappedRow mapped) {
            this.rowNumber = rowNumber;
            this.uniqueId = mapped.uniqueId;
            this.npi = mapped.npi;
            errors = new List<String>();
            warnings = new List<String>(mapped.warnings);
            valueWarnings = new List<ProviderCsvMapping.ValueWarning>(mapped.valueWarnings);
            changesByField = new Map<String, FieldChange>();
        }

        /*
         * Drops the warnings for one column, e.g. when the row's error already says
         * the value is invalid.
         */
        private void removeWarningsFor(String column) {
            for (Integer i = valueWarnings.size() - 1; i >= 0; i--) {
                if (valueWarnings[i].column == column) {
                    valueWarnings.remove(i);
                    warnings.remove(i);
                }
            }
        }

        private void fail(String code, String message) {
            outcome = ProviderIngestionService.Outcome.ERROR;
            errorCode = code;
            errors.add(message);
        }
    }

    /**
     * Remembers which row first used each key value and each matched Provider.
     *
     * Carried from chunk to chunk when a file is ingested in several
     * transactions, so it is plain serializable state.
     */
    public class DuplicateTracker {
        private Map<String, Integer> firstRowByKey = new Map<String, Integer>();

        /**
         * @return A copy that later claims do not affect
         */
        public DuplicateTracker copy() {
            DuplicateTracker copied = new DuplicateTracker();
            copied.firstRowByKey.putAll(firstRowByKey);
            return copied;
        }

        /*
         * Returns the row that already claimed one of the keys, or null after
         * claiming all of them for rowNumber. Blank keys are skipped.
         */
        private Integer claim(List<String> keys, Integer rowNumber) {
            for (String key : keys) {
                if (key != null && firstRowByKey.containsKey(key)) {
                    return firstRowByKey.get(key);
                }
            }
            for (String key : keys) {
                if (key != null) {
                    firstRowByKey.put(key, rowNumber);
                }
            }
            return null;
        }
    }

    /**
     * @param csvRow One CSV row, header => value (see CsvParser.parseWithHeaders)
     * @return What happened to the row
     * @throws IllegalArgumentException if csvRow is null
     * @example
     * CsvParser.ParsedWithHeaders parsed = CsvParser.parseWithHeaders(csv);
     * ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(parsed.rows[0]);
     */
    public static IngestResult ingest(Map<String, String> csvRow) {
        if (csvRow == null) {
            throw new IllegalArgumentException('CSV row cannot be null.');
        }
        return ingestAll(new List<RowInput>{ new RowInput(2, csvRow) }, new DuplicateTracker(), false)[0];
    }

    /**
     * Ingests many rows with one matching query and at most one insert and one update.
     *
     * DRY RUN: when dryRun is true, the inserts and updates are really
     * performed and then rolled back to a savepoint, so the results report
     * exactly what a real run would do, including errors raised by validation
     * rules, duplicate checks and Account flows/triggers. Caveats (team to review):
     *
     *   - Auto-numbers are consumed. Salesforce does not roll back auto-number
     *     values, so every would-be insert advances Account.Unique__c and the
     *     InnovAge Unique IDs issued afterwards skip those numbers. IDs stay
     *     unique, but there are gaps.
     *   - Not every side effect is transactional. Platform events published
     *     with "Publish Immediately" by Account automation are delivered even
     *     though the save is rolled back. Emails, enqueued jobs and other DML
     *     are rolled back. Check Account automation before relying on dry runs.
     *   - A dry run costs as much CPU and time as a real run, because the same
     *     triggers and flows execute.
     *   - Rows of later calls (chunks) do not see Providers inserted by earlier
     *     calls, since those were rolled back. The tracker's first-occurrence-wins
     *     rule makes the outcome the same as a real run anyway.
     *   - The savepoint and the rollback each count as one DML statement.
     *
     * @param rows The rows to ingest, in file order
     * @param tracker Keys and Providers claimed by earlier rows; updated with these rows' claims
     * @param dryRun true to roll back all Provider changes (see above)
     * @return One result per row, in the same order
     * @throws IllegalArgumentException if rows or tracker is null, or a row has no values
     */
    public static List<IngestResult> ingestAll(List<RowInput> rows, DuplicateTracker tracker, Boolean dryRun) {
        if (rows == null || tracker == null) {
            throw new IllegalArgumentException('Rows and tracker cannot be null.');
        }

        List<IngestResult> results = new List<IngestResult>();
        List<ProviderCsvMapping.MappedRow> mappedRows = new List<ProviderCsvMapping.MappedRow>();
        for (RowInput row : rows) {
            if (row?.values == null) {
                throw new IllegalArgumentException('CSV row cannot be null.');
            }
            ProviderCsvMapping.MappedRow mapped = ProviderCsvMapping.mapRow(row.values);
            mappedRows.add(mapped);
            results.add(new IngestResult(row.rowNumber, mapped));
        }

        List<Integer> matchableIndexes = claimKeys(results, tracker);

        List<ProviderMatcher.MatchRequest> requests = new List<ProviderMatcher.MatchRequest>();
        for (Integer index : matchableIndexes) {
            requests.add(new ProviderMatcher.MatchRequest(results[index].uniqueId, results[index].npi));
        }
        List<AccountMatchResult> matches = ProviderMatcher.matchAll(
            requests,
            ProviderCsvMapping.getUpdatableFieldNames()
        );

        PendingSaves saves = new PendingSaves();
        for (Integer i = 0; i < matchableIndexes.size(); i++) {
            Integer index = matchableIndexes[i];
            planRow(results[index], mappedRows[index], matches[i], tracker, saves);
        }

        saves.execute(dryRun == true);
        return results;
    }

    /*
     * Claims each row's key values in file order. A row whose Unique ID or NPI
     * was already used by an earlier row is a DUPLICATE_IN_FILE error. Returns
     * the indexes of the rows that go on to matching.
     */
    private static List<Integer> claimKeys(List<IngestResult> results, DuplicateTracker tracker) {
        List<Integer> matchableIndexes = new List<Integer>();
        for (Integer i = 0; i < results.size(); i++) {
            IngestResult result = results[i];
            List<String> keys = new List<String>{
                String.isBlank(result.uniqueId) ? null : 'UID:' + result.uniqueId,
                String.isBlank(result.npi) ? null : 'NPI:' + result.npi
            };

            Integer earlierRow = tracker.claim(keys, result.rowNumber);
            if (earlierRow != null) {
                result.fail(DUPLICATE_IN_FILE, 'Row ' + earlierRow + ' has the same Provider Unique ID or NPI; only the first row is ingested.');
            } else {
                matchableIndexes.add(i);
            }
        }
        return matchableIndexes;
    }

    /*
     * Decides what to do with one matched row: queue an insert or update, or fail it.
     */
    private static void planRow(
        IngestResult result,
        ProviderCsvMapping.MappedRow mapped,
        AccountMatchResult match,
        DuplicateTracker tracker,
        PendingSaves saves
    ) {
        result.matchOutcome = match.outcome;

        switch on match.outcome {
            when UNIQUE_MATCH {
                Integer earlierRow = tracker.claim(new List<String>{ 'ACC:' + match.account.Id }, result.rowNumber);
                if (earlierRow != null) {
                    result.accountId = match.account.Id;
                    result.fail(DUPLICATE_IN_FILE, 'Row ' + earlierRow + ' refers to the same Provider; only the first row is ingested.');
                } else {
                    planUpdate(match.account, mapped, result, saves);
                }
            }
            when NO_MATCH {
                planInsert(mapped, result, saves);
            }
            when MALFORMED_NPI {
                // The error already reports the invalid NPI; the mapping's warning would repeat it.
                result.removeWarningsFor(ProviderCsvMapping.NPI_HEADER);
                result.fail(match.outcome.name(), match.message);
            }
            when else {
                result.fail(match.outcome.name(), match.message);
            }
        }
    }

    private static void planInsert(ProviderCsvMapping.MappedRow mapped, IngestResult result, PendingSaves saves) {
        if (!mapped.valuesByField.containsKey(Account.LastName)) {
            result.fail(MISSING_LAST_NAME, 'A valid Last Name is required to create a Provider.');
            return;
        }

        Account provider = new Account(RecordTypeId = ProviderMatcher.getProviderRecordTypeId());
        for (Schema.SObjectField field : mapped.valuesByField.keySet()) {
            provider.put(field, mapped.valuesByField.get(field));
        }
        saves.inserts.add(provider);
        saves.insertResults.add(result);
    }

    private static void planUpdate(
        Account existing,
        ProviderCsvMapping.MappedRow mapped,
        IngestResult result,
        PendingSaves saves
    ) {
        result.accountId = existing.Id;

        Account changes = new Account(Id = existing.Id);
        for (ProviderCsvMapping.FieldMapping mapping : ProviderCsvMapping.getUpdatableMappings()) {
            if (!mapped.valuesByField.containsKey(mapping.field)) {
                continue;
            }

            Object storedValue = existing.get(mapping.field);
            Object incomingValue = mapped.valuesByField.get(mapping.field);

            Boolean storedIsBlank = storedValue == null || String.isBlank(String.valueOf(storedValue));
            if (mapping.updatePolicy == ProviderCsvMapping.UpdatePolicy.FILL_IF_BLANK && !storedIsBlank) {
                continue;
            }
            if (ProviderCsvMapping.isSameValue(mapping.valueType, storedValue, incomingValue)) {
                continue;
            }

            changes.put(mapping.field, incomingValue);
            result.changesByField.put(mapping.getFieldName(), new FieldChange(storedValue, incomingValue));
        }

        if (result.changesByField.isEmpty()) {
            result.outcome = Outcome.UNCHANGED;
            return;
        }

        saves.updates.add(changes);
        saves.updateResults.add(result);
    }

    /*
     * The inserts and updates of one ingestAll() call, each paired with the
     * result of the row it came from (same index).
     */
    private class PendingSaves {
        List<Account> inserts = new List<Account>();
        List<IngestResult> insertResults = new List<IngestResult>();
        List<Account> updates = new List<Account>();
        List<IngestResult> updateResults = new List<IngestResult>();

        void execute(Boolean dryRun) {
            if (inserts.isEmpty() && updates.isEmpty()) {
                return;
            }

            // See the DRY RUN notes on ingestAll() before changing this.
            Savepoint beforeSaves = dryRun ? Database.setSavepoint() : null;
            try {
                List<Database.SaveResult> insertSaveResults = Database.insert(inserts, false, AccessLevel.SYSTEM_MODE);
                List<Database.SaveResult> updateSaveResults = Database.update(updates, false, AccessLevel.SYSTEM_MODE);

                for (Integer i = 0; i < insertSaveResults.size(); i++) {
                    applySaveResult(insertSaveResults[i], Outcome.INSERTED, insertResults[i], dryRun);
                }
                for (Integer i = 0; i < updateSaveResults.size(); i++) {
                    applySaveResult(updateSaveResults[i], Outcome.UPDATED, updateResults[i], dryRun);
                }
            } finally {
                if (dryRun) {
                    Database.rollback(beforeSaves);
                }
            }
        }
    }

    private static void applySaveResult(
        Database.SaveResult saveResult,
        Outcome successOutcome,
        IngestResult result,
        Boolean dryRun
    ) {
        if (saveResult.isSuccess()) {
            result.outcome = successOutcome;
            // A dry-run insert was rolled back; its Id refers to nothing.
            result.accountId = dryRun && successOutcome == Outcome.INSERTED ? null : saveResult.getId();
            return;
        }

        result.changesByField.clear();
        List<String> messages = new List<String>();
        for (Database.Error error : saveResult.getErrors()) {
            String fields = error.getFields().isEmpty() ? '' : ' (' + String.join(error.getFields(), ', ') + ')';
            messages.add(error.getMessage() + fields);
        }
        result.fail(SAVE_ERROR, String.join(messages, '; '));
    }
}
