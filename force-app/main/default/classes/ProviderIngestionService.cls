/**
 * Ingests one Provider roster CSV row: finds the matching Provider and either
 * creates it, updates it, or reports why the row cannot be ingested.
 *
 *     UNIQUE_MATCH  -> update the OVERWRITE / FILL_IF_BLANK fields that changed
 *     NO_MATCH      -> insert a Provider from every valid mapped value
 *     anything else -> ERROR (not persisted yet; returned to the caller)
 *
 * This is the single-row reference implementation. ProviderMatcher issues one
 * query per row, so processing a whole file needs a bulk variant.
 *
 * DML runs in system mode for the same reason ProviderMatcher queries in
 * system mode: ingestion writes Providers on behalf of the roster, not the
 * uploader, and the uploader's field access must not silently drop values.
 */
public with sharing class ProviderIngestionService {

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
     * What happened to one CSV row.
     */
    public class IngestResult {
        public Outcome outcome { get; private set; }
        public AccountMatchResult.Outcome matchOutcome { get; private set; }
        public Id accountId { get; private set; }
        public List<String> errors { get; private set; }
        public List<String> warnings { get; private set; }
        public Map<String, FieldChange> changesByField { get; private set; }

        private IngestResult() {
            errors = new List<String>();
            warnings = new List<String>();
            changesByField = new Map<String, FieldChange>();
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

        IngestResult result = new IngestResult();

        ProviderCsvMapping.MappedRow mapped = ProviderCsvMapping.mapRow(csvRow);
        result.warnings.addAll(mapped.warnings);

        AccountMatchResult match = ProviderMatcher.match(
            mapped.uniqueId,
            mapped.npi,
            ProviderCsvMapping.getUpdatableFieldNames()
        );
        result.matchOutcome = match.outcome;

        switch on match.outcome {
            when UNIQUE_MATCH {
                updateProvider(match.account, mapped, result);
            }
            when NO_MATCH {
                insertProvider(mapped, result);
            }
            when else {
                result.outcome = Outcome.ERROR;
                result.errors.add(match.message);
            }
        }

        return result;
    }

    private static void insertProvider(ProviderCsvMapping.MappedRow mapped, IngestResult result) {
        if (!mapped.valuesByField.containsKey(Account.LastName)) {
            result.outcome = Outcome.ERROR;
            result.errors.add('A valid Last Name is required to create a Provider.');
            return;
        }

        Account provider = new Account(RecordTypeId = ProviderMatcher.getProviderRecordTypeId());
        for (Schema.SObjectField field : mapped.valuesByField.keySet()) {
            provider.put(field, mapped.valuesByField.get(field));
        }

        Database.SaveResult saveResult = Database.insert(provider, false, AccessLevel.SYSTEM_MODE);
        applySaveResult(saveResult, Outcome.INSERTED, result);
    }

    private static void updateProvider(Account existing, ProviderCsvMapping.MappedRow mapped, IngestResult result) {
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

        Database.SaveResult saveResult = Database.update(changes, false, AccessLevel.SYSTEM_MODE);
        applySaveResult(saveResult, Outcome.UPDATED, result);
    }

    private static void applySaveResult(Database.SaveResult saveResult, Outcome successOutcome, IngestResult result) {
        if (saveResult.isSuccess()) {
            result.outcome = successOutcome;
            result.accountId = saveResult.getId();
            return;
        }

        result.outcome = Outcome.ERROR;
        result.changesByField.clear();
        for (Database.Error error : saveResult.getErrors()) {
            String fields = error.getFields().isEmpty() ? '' : ' (' + String.join(error.getFields(), ', ') + ')';
            result.errors.add(error.getMessage() + fields);
        }
    }
}
