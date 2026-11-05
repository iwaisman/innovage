/**
 * Ingests Provider roster CSV rows: finds the matching Provider for each row and
 * either creates it, updates it, or reports why the row cannot be ingested.
 *
 *     UNIQUE_MATCH  -> update the OVERWRITE / FILL_IF_BLANK fields that changed
 *     NO_MATCH      -> insert a Provider from every valid mapped value
 *     anything else -> ERROR (returned to the caller)
 *
 * Then, for every saved Provider, HealthcareProviderFieldService writes the
 * HealthcareProvider fields and ProviderSpecialtyService links the specialties.
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

        /** Why the row is an ERROR (see RosterIntakeIssues). */
        public RosterIntakeIssues.Issue error { get; private set; }
        public List<String> errors { get; private set; }
        public List<RosterIntakeRow.Warning> warnings { get; private set; }
        public Map<String, FieldChange> changesByField { get; private set; }

        /* This row's specialties and HealthcareProvider fields, while they are applied. */
        private ProviderSpecialtyService.Request specialties;
        private HealthcareProviderFieldService.Request healthcareProviderFields;

        private IngestResult(Integer rowNumber, ProviderCsvMapping.MappedRow mapped) {
            this.rowNumber = rowNumber;
            this.uniqueId = mapped.uniqueId;
            this.npi = mapped.npi;
            errors = new List<String>();
            warnings = new List<RosterIntakeRow.Warning>(mapped.warnings);
            changesByField = new Map<String, FieldChange>();
        }

        /*
         * Drops the warnings for one column, e.g. when the row's error already says
         * the value is invalid.
         */
        private void removeWarningsFor(String column) {
            for (Integer i = warnings.size() - 1; i >= 0; i--) {
                if (warnings[i].column == column) {
                    warnings.remove(i);
                }
            }
        }

        /** The error's Roster_Intake_Issue__c.Code__c value, or null. */
        public String errorCode {
            get { return error?.code; }
        }

        private void warn(RosterIntakeIssues.Issue issue, String column, String message) {
            warnings.add(new RosterIntakeRow.Warning(issue, column, message));
        }

        private void fail(RosterIntakeIssues.Issue issue, String message) {
            RosterIntakeIssues.requireSeverity(issue, RosterIntakeIssues.SEVERITY_ERROR);
            outcome = ProviderIntakeService.Outcome.ERROR;
            error = issue;
            errors.add(message);
        }

        /*
         * Adds what happened after the Provider saved (specialties, HealthcareProvider
         * fields). A change makes an otherwise unchanged existing Provider UPDATED.
         */
        private void addLaterOutcome(
            List<RosterIntakeRow.Warning> laterWarnings,
            Map<String, FieldChange> laterChanges
        ) {
            warnings.addAll(laterWarnings);
            changesByField.putAll(laterChanges);
            if (outcome == ProviderIntakeService.Outcome.UNCHANGED && !laterChanges.isEmpty()) {
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
                    row.fail(result.error, error);
                }
            }
        }

        for (RosterIntakeRow.Warning warning : result.warnings) {
            row.warn(warning);
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
        applyHealthcareProviderFields(results, mappedRows);
        applySpecialties(results, mappedRows);
        return results;
    }

    /*
     * Writes the rows' HealthcareProvider fields (see HealthcareProviderFieldService).
     * Runs after the Provider saves, so new Providers already have their
     * HealthcareProvider; rows that errored are skipped.
     */
    private static void applyHealthcareProviderFields(
        List<IngestResult> results,
        List<ProviderCsvMapping.MappedRow> mappedRows
    ) {
        List<HealthcareProviderFieldService.Request> requests = new List<HealthcareProviderFieldService.Request>();
        for (Integer i = 0; i < results.size(); i++) {
            IngestResult result = results[i];
            result.healthcareProviderFields = new HealthcareProviderFieldService.Request(
                result.outcome == Outcome.ERROR ? null : result.accountId,
                result.outcome == Outcome.INSERTED,
                mappedRows[i].healthcareProviderValuesByField
            );
            requests.add(result.healthcareProviderFields);
        }

        HealthcareProviderFieldService.apply(requests);
        for (IngestResult result : results) {
            HealthcareProviderFieldService.Outcome fieldOutcome = result.healthcareProviderFields.outcome;
            result.addLaterOutcome(fieldOutcome.warnings, fieldOutcome.changesByLabel);
        }
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
            result.addLaterOutcome(result.specialties.outcome.warnings, result.specialties.outcome.changesByLabel);
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
                result.fail(RosterIntakeIssues.forMatchOutcome(match.outcome), match.message);
            }
            when else {
                result.fail(RosterIntakeIssues.forMatchOutcome(match.outcome), match.message);
            }
        }
    }

    private static void planInsert(ProviderCsvMapping.MappedRow mapped, IngestResult result, PendingSaves saves) {
        if (!mapped.valuesByField.containsKey(Account.LastName)) {
            result.fail(RosterIntakeIssues.MISSING_LAST_NAME, 'A valid Last Name is required to create a Provider.');
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
        Set<Schema.SObjectField> rejectedFields = rejectAddresses(existing, mapped, result);

        Map<Schema.SObjectField, Object> changedValuesByField = new Map<Schema.SObjectField, Object>();
        for (ProviderCsvMapping.FieldMapping mapping : ProviderCsvMapping.getUpdatableMappings()) {
            if (!mapped.valuesByField.containsKey(mapping.field) || rejectedFields.contains(mapping.field)) {
                continue;
            }

            Object storedValue = existing.get(mapping.field);
            Object incomingValue = mapped.valuesByField.get(mapping.field);

            if (!ProviderCsvMapping.mayWrite(mapping, storedValue, false)) {
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
     * Checks each address the row gives (see ProviderCsvMapping.AddressGroup). An
     * address with problems is not written at all: its per-column warnings are
     * replaced by one ADDRESS_NOT_UPDATED warning listing them.
     *
     * Returns the fields of the rejected addresses.
     */
    private static Set<Schema.SObjectField> rejectAddresses(
        Account existing,
        ProviderCsvMapping.MappedRow mapped,
        IngestResult result
    ) {
        Set<Schema.SObjectField> rejectedFields = new Set<Schema.SObjectField>();
        for (ProviderCsvMapping.AddressGroup address : ProviderCsvMapping.ADDRESS_GROUPS) {
            if (address.mappings[0].updatePolicy == ProviderCsvMapping.UpdatePolicy.INSERT_ONLY || !address.isGivenIn(mapped)) {
                continue;
            }
            Map<String, String> problemsByColumn = address.problems(mapped, existing);
            if (problemsByColumn.isEmpty()) {
                continue;
            }

            for (ProviderCsvMapping.FieldMapping mapping : address.mappings) {
                rejectedFields.add(mapping.field);
                result.removeWarningsFor(String.join(mapping.headers, ' / '));
            }
            result.warn(
                RosterIntakeIssues.ADDRESS_NOT_UPDATED,
                String.join(new List<String>(problemsByColumn.keySet()), ', '),
                address.name + ' address not updated: ' + String.join(problemsByColumn.values(), '; ') + '.'
            );
        }
        return rejectedFields;
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
        result.fail(RosterIntakeIssues.SAVE_ERROR, String.join(messages, '; '));
    }
}
