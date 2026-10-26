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
 * DUPLICATES: rows are not checked against each other. Several rows referring
 * to the same Provider are accepted (a stakeholder decision, see
 * docs/plans/provider-bulk-intake.md); what happens depends on whether they
 * are in the same ingestAll() call (one slice of RosterIntakeBatch) or not:
 *
 *   - Different calls: each row is matched against the database as it is at
 *     that moment, so a row that inserts a Provider is followed by later rows
 *     that update it (or find it unchanged).
 *   - Same call, new Provider: every such row is planned as an insert, and
 *     the database rejects all but the first for the duplicate NPI
 *     (SAVE_ERROR).
 *   - Same call, existing Provider: the rows' changes are merged into a single
 *     update (Salesforce rejects a DML list holding the same Id twice). Each
 *     row is compared with the Provider as stored before the call and reports
 *     its own changes; where several rows change the same field, the last
 *     row's value is saved.
 *
 * DML runs in system mode for the same reason ProviderMatcher queries in
 * system mode: intake writes Providers on behalf of the roster, not the
 * uploader, and the uploader's field access must not silently drop values.
 */
public with sharing class ProviderIntakeService {

    public enum Outcome { INSERTED, UPDATED, UNCHANGED, ERROR }

    /*
     * Error codes besides the AccountMatchResult.Outcome names. These are the
     * values of Roster_Intake_Issue__c.Code__c.
     */
    public static final String MISSING_LAST_NAME = 'MISSING_LAST_NAME';
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

        /** The Provider updated, matched, or inserted. */
        public Id accountId { get; private set; }

        /** Why the row is an ERROR: an AccountMatchResult.Outcome name or one of this class's codes. */
        public String errorCode { get; private set; }
        public List<String> errors { get; private set; }
        public List<String> warnings { get; private set; }
        public List<ProviderCsvMapping.ValueWarning> valueWarnings { get; private set; }
        public Map<String, FieldChange> changesByField { get; private set; }

        /* This row's specialties, while applySpecialties runs. */
        private ProviderSpecialtyService.Request specialties;

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
            outcome = ProviderIntakeService.Outcome.ERROR;
            errorCode = code;
            errors.add(message);
        }

        /* A specialty change makes an otherwise unchanged existing Provider UPDATED. */
        private void addSpecialtyOutcome(ProviderSpecialtyService.Outcome specialtyOutcome) {
            for (ProviderCsvMapping.ValueWarning warning : specialtyOutcome.warnings) {
                warnings.add((warning.column == null ? '' : '"' + warning.column + '": ') + warning.message);
                valueWarnings.add(warning);
            }
            changesByField.putAll(specialtyOutcome.changesByLabel);
            if (outcome == ProviderIntakeService.Outcome.UNCHANGED && !specialtyOutcome.changesByLabel.isEmpty()) {
                outcome = ProviderIntakeService.Outcome.UPDATED;
            }
        }
    }

    /**
     * Provider file rows for RosterIntakeBatch: runs ingestAll() and turns
     * each IngestResult into the shared result the batch records.
     */
    public class Processor implements RosterRowProcessor {
        public List<String> requiredHeaders() {
            return new List<String>{ ProviderCsvMapping.UNIQUE_ID_HEADER, ProviderCsvMapping.NPI_HEADER, 'Last Name' };
        }

        public void prepare(RosterIntakeRow.Context context) {
            // Providers are global: they need nothing about the Run.
            return;
        }

        public List<RosterIntakeRow.Result> ingestAll(
            List<RosterIntakeRow.Input> rows,
            RosterIntakeRow.Context context
        ) {
            List<RowInput> inputs = new List<RowInput>();
            for (RosterIntakeRow.Input row : rows) {
                inputs.add(new RowInput(row.rowNumber, row.values));
            }

            List<RosterIntakeRow.Result> results = new List<RosterIntakeRow.Result>();
            for (IngestResult result : ProviderIntakeService.ingestAll(inputs)) {
                results.add(toRowResult(result));
            }
            return results;
        }
    }

    private static RosterIntakeRow.Result toRowResult(IngestResult result) {
        RosterIntakeRow.Result row = new RosterIntakeRow.Result(result.rowNumber);
        switch on result.outcome {
            when INSERTED {
                row.succeed(RosterIntakeRow.Outcome.INSERTED);
            }
            when UPDATED {
                row.succeed(RosterIntakeRow.Outcome.UPDATED);
            }
            when UNCHANGED {
                row.succeed(RosterIntakeRow.Outcome.UNCHANGED);
            }
            when else {
                for (String error : result.errors) {
                    row.fail(result.errorCode, error);
                }
            }
        }

        for (ProviderCsvMapping.ValueWarning warning : result.valueWarnings) {
            row.warn(warning.code ?? RosterIntakeRunService.CODE_INVALID_VALUE, warning.column, warning.message);
        }

        row.putIssueValue(Roster_Intake_Issue__c.Provider__c, result.accountId);
        row.putIssueValue(Roster_Intake_Issue__c.Provider_Unique_ID__c, result.uniqueId);
        row.putIssueValue(Roster_Intake_Issue__c.Provider_NPI__c, result.npi);
        return row;
    }

    /**
     * @param csvRow One CSV row, header => value (see CsvParser.parseWithHeaders)
     * @return What happened to the row
     * @throws IllegalArgumentException if csvRow is null
     * @example
     * CsvParser.ParsedWithHeaders parsed = CsvParser.parseWithHeaders(csv);
     * ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(parsed.rows[0]);
     */
    public static IngestResult ingest(Map<String, String> csvRow) {
        if (csvRow == null) {
            throw new IllegalArgumentException('CSV row cannot be null.');
        }
        return ingestAll(new List<RowInput>{ new RowInput(2, csvRow) })[0];
    }

    /**
     * Ingests many rows with one matching query and at most one insert and one update.
     *
     * @param rows The rows to ingest, in file order
     * @return One result per row, in the same order
     * @throws IllegalArgumentException if rows is null, or a row has no values
     */
    public static List<IngestResult> ingestAll(List<RowInput> rows) {
        if (rows == null) {
            throw new IllegalArgumentException('Rows cannot be null.');
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

        List<ProviderMatcher.MatchRequest> requests = new List<ProviderMatcher.MatchRequest>();
        for (IngestResult result : results) {
            requests.add(new ProviderMatcher.MatchRequest(result.uniqueId, result.npi));
        }
        List<AccountMatchResult> matches = ProviderMatcher.matchAll(
            requests,
            ProviderCsvMapping.getUpdatableFieldNames()
        );

        PendingSaves saves = new PendingSaves();
        for (Integer i = 0; i < results.size(); i++) {
            planRow(results[i], mappedRows[i], matches[i], saves);
        }

        saves.execute();
        applySpecialties(results, mappedRows);
        return results;
    }

    /*
     * Links the saved Providers to the specialties in their rows (see
     * ProviderSpecialtyService). Runs after the Provider saves, so new Providers
     * already have their HealthcareProvider; rows that errored are skipped.
     */
    private static void applySpecialties(List<IngestResult> results, List<ProviderCsvMapping.MappedRow> mappedRows) {
        List<ProviderSpecialtyService.Request> requests = new List<ProviderSpecialtyService.Request>();
        for (Integer i = 0; i < results.size(); i++) {
            IngestResult result = results[i];
            result.specialties = new ProviderSpecialtyService.Request(
                result.outcome == Outcome.ERROR ? null : result.accountId,
                mappedRows[i].primarySpecialtyCode,
                mappedRows[i].secondarySpecialtyCode
            );
            requests.add(result.specialties);
        }

        ProviderSpecialtyService.apply(requests);
        for (IngestResult result : results) {
            result.addSpecialtyOutcome(result.specialties.outcome);
        }
    }

    /*
     * Decides what to do with one matched row: queue an insert or update, or fail it.
     */
    private static void planRow(
        IngestResult result,
        ProviderCsvMapping.MappedRow mapped,
        AccountMatchResult match,
        PendingSaves saves
    ) {
        result.matchOutcome = match.outcome;

        switch on match.outcome {
            when UNIQUE_MATCH {
                planUpdate(match.account, mapped, result, saves);
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

        Map<Schema.SObjectField, Object> changedValuesByField = new Map<Schema.SObjectField, Object>();
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

            changedValuesByField.put(mapping.field, incomingValue);
            result.changesByField.put(mapping.getFieldName(), new FieldChange(storedValue, incomingValue));
        }

        if (result.changesByField.isEmpty()) {
            result.outcome = Outcome.UNCHANGED;
            return;
        }

        saves.addUpdate(existing.Id, changedValuesByField, result);
    }

    /*
     * The inserts and updates of one ingestAll() call. Each insert is paired with
     * the result of its row (same index); each update with the results of every
     * row that changes that Provider (see DUPLICATES in the class comment).
     */
    private class PendingSaves {
        List<Account> inserts = new List<Account>();
        List<IngestResult> insertResults = new List<IngestResult>();
        Map<Id, Account> updatesById = new Map<Id, Account>();
        Map<Id, List<IngestResult>> updateResultsById = new Map<Id, List<IngestResult>>();

        /*
         * Merges a row's changes into the Provider's pending update, in row order,
         * so a later row's value for a field replaces an earlier row's.
         */
        void addUpdate(Id accountId, Map<Schema.SObjectField, Object> changedValuesByField, IngestResult result) {
            if (!updatesById.containsKey(accountId)) {
                updatesById.put(accountId, new Account(Id = accountId));
                updateResultsById.put(accountId, new List<IngestResult>());
            }
            Account changes = updatesById.get(accountId);
            for (Schema.SObjectField field : changedValuesByField.keySet()) {
                changes.put(field, changedValuesByField.get(field));
            }
            updateResultsById.get(accountId).add(result);
        }

        void execute() {
            if (inserts.isEmpty() && updatesById.isEmpty()) {
                return;
            }
            List<Account> updates = updatesById.values();

            List<Database.SaveResult> insertSaveResults = Database.insert(inserts, false, AccessLevel.SYSTEM_MODE);
            List<Database.SaveResult> updateSaveResults = Database.update(updates, false, AccessLevel.SYSTEM_MODE);

            for (Integer i = 0; i < insertSaveResults.size(); i++) {
                applySaveResult(insertSaveResults[i], Outcome.INSERTED, insertResults[i]);
            }
            for (Integer i = 0; i < updateSaveResults.size(); i++) {
                for (IngestResult result : updateResultsById.get(updates[i].Id)) {
                    applySaveResult(updateSaveResults[i], Outcome.UPDATED, result);
                }
            }
        }
    }

    private static void applySaveResult(
        Database.SaveResult saveResult,
        Outcome successOutcome,
        IngestResult result
    ) {
        if (saveResult.isSuccess()) {
            result.outcome = successOutcome;
            result.accountId = saveResult.getId();
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
