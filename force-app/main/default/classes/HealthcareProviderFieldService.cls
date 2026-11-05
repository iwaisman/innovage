/**
 * Writes the Provider file's HealthcareProvider columns
 * (ProviderCsvMapping.HEALTHCARE_PROVIDER_MAPPINGS) to each saved Provider's
 * HealthcareProvider, found through Account.Healthcare_Provider__c. Runs after
 * the Provider saves, so new Providers already have theirs.
 *
 * Each field follows its mapping's UpdatePolicy, as Account fields do. A
 * Provider with no HealthcareProvider, or a HealthcareProvider that fails to
 * save, is a warning: the Provider has already been saved by then, so neither
 * makes the row an error.
 *
 * Rows are applied in order: each is compared with the values left by the rows
 * before it, and each HealthcareProvider's changes are saved in one update, the
 * last row's value winning.
 *
 * Queries and DML run in system mode, like the rest of Provider intake.
 */
public with sharing class HealthcareProviderFieldService {

    /* Warning code; a Roster_Intake_Issue__c.Code__c value. */
    public static final String HEALTHCARE_PROVIDER_NOT_SAVED = 'HEALTHCARE_PROVIDER_NOT_SAVED';

    /* How a change is reported in IngestResult.changesByField: this prefix + the field's API name. */
    public static final String CHANGE_PREFIX = 'HealthcareProvider.';

    /**
     * One saved Provider, the HealthcareProvider values from its row, and (after apply) what happened.
     */
    public class Request {
        /** The Provider Account; null when the row was not saved (nothing is written). */
        public Id accountId { get; private set; }
        /** true when the row created the Provider (INSERT_ONLY fields may then be written). */
        public Boolean isNewProvider { get; private set; }
        /** Valid, normalized values (ProviderCsvMapping.MappedRow.healthcareProviderValuesByField). */
        public Map<Schema.SObjectField, Object> valuesByField { get; private set; }
        /** Filled in by apply(). */
        public Outcome outcome { get; private set; }

        public Request(Id accountId, Boolean isNewProvider, Map<Schema.SObjectField, Object> valuesByField) {
            this.accountId = accountId;
            this.isNewProvider = isNewProvider == true;
            this.valuesByField = valuesByField ?? new Map<Schema.SObjectField, Object>();
            outcome = new Outcome();
        }

        private Boolean hasWork() {
            return accountId != null && !valuesByField.isEmpty();
        }
    }

    /**
     * What happened to one request's HealthcareProvider fields.
     */
    public class Outcome {
        public List<ProviderCsvMapping.ValueWarning> warnings { get; private set; }
        /** CHANGE_PREFIX + field API name => old and new value. */
        public Map<String, ProviderIntakeService.FieldChange> changesByLabel { get; private set; }

        private Outcome() {
            warnings = new List<ProviderCsvMapping.ValueWarning>();
            changesByLabel = new Map<String, ProviderIntakeService.FieldChange>();
        }

        private void warn(String message) {
            warnings.add(new ProviderCsvMapping.ValueWarning(HEALTHCARE_PROVIDER_NOT_SAVED, null, message));
        }
    }

    /**
     * Writes the requests' values: two queries and at most one update for the
     * whole list. Each request's outcome is recorded on it (Request.outcome).
     *
     * @param requests One per row, in file order
     * @throws IllegalArgumentException if requests is null
     */
    public static void apply(List<Request> requests) {
        if (requests == null) {
            throw new IllegalArgumentException('Requests cannot be null.');
        }

        Set<Id> accountIds = new Set<Id>();
        for (Request request : requests) {
            if (request.hasWork()) {
                accountIds.add(request.accountId);
            }
        }
        if (accountIds.isEmpty()) {
            return;
        }

        Map<Id, Id> healthcareProviderByAccount = queryHealthcareProviders(accountIds);
        Map<Id, HealthcareProvider> currentById = queryCurrentValues(new Set<Id>(healthcareProviderByAccount.values()));

        PendingUpdates updates = new PendingUpdates();
        for (Request request : requests) {
            if (!request.hasWork()) {
                continue;
            }
            Id healthcareProviderId = healthcareProviderByAccount.get(request.accountId);
            if (healthcareProviderId == null) {
                request.outcome.warn(
                    'The Provider has no Healthcare Provider record, so ' + columns(request) + ' was not saved.'
                );
                continue;
            }
            plan(request, currentById.get(healthcareProviderId), updates);
        }
        updates.save();
    }

    /*
     * Queues the request's changed values. current holds the values left by the
     * rows before this one, and is updated so the next row compares with this one.
     */
    private static void plan(Request request, HealthcareProvider current, PendingUpdates updates) {
        Map<Schema.SObjectField, Object> changedValuesByField = new Map<Schema.SObjectField, Object>();
        for (ProviderCsvMapping.FieldMapping mapping : ProviderCsvMapping.HEALTHCARE_PROVIDER_MAPPINGS) {
            if (!request.valuesByField.containsKey(mapping.field)) {
                continue;
            }

            Object storedValue = current.get(mapping.field);
            Object incomingValue = request.valuesByField.get(mapping.field);
            if (!ProviderCsvMapping.mayWrite(mapping, storedValue, request.isNewProvider)) {
                continue;
            }
            if (ProviderCsvMapping.isSameValue(mapping.valueType, storedValue, incomingValue)) {
                continue;
            }

            current.put(mapping.field, incomingValue);
            changedValuesByField.put(mapping.field, incomingValue);
            request.outcome.changesByLabel.put(
                CHANGE_PREFIX + mapping.getFieldName(),
                new ProviderIntakeService.FieldChange(storedValue, incomingValue)
            );
        }

        if (!changedValuesByField.isEmpty()) {
            updates.add(current.Id, changedValuesByField, request);
        }
    }

    /*
     * One update per HealthcareProvider, each paired with the requests that change it.
     */
    private class PendingUpdates {
        Map<Id, HealthcareProvider> updatesById = new Map<Id, HealthcareProvider>();
        Map<Id, List<Request>> requestsById = new Map<Id, List<Request>>();

        void add(Id healthcareProviderId, Map<Schema.SObjectField, Object> changedValuesByField, Request request) {
            if (!updatesById.containsKey(healthcareProviderId)) {
                updatesById.put(healthcareProviderId, new HealthcareProvider(Id = healthcareProviderId));
                requestsById.put(healthcareProviderId, new List<Request>());
            }
            HealthcareProvider changes = updatesById.get(healthcareProviderId);
            for (Schema.SObjectField field : changedValuesByField.keySet()) {
                changes.put(field, changedValuesByField.get(field));
            }
            requestsById.get(healthcareProviderId).add(request);
        }

        void save() {
            if (updatesById.isEmpty()) {
                return;
            }
            List<HealthcareProvider> records = updatesById.values();
            List<Database.SaveResult> results = Database.update(records, false, AccessLevel.SYSTEM_MODE);
            for (Integer i = 0; i < results.size(); i++) {
                if (results[i].isSuccess()) {
                    continue;
                }
                for (Request request : requestsById.get(records[i].Id)) {
                    request.outcome.changesByLabel.clear();
                    request.outcome.warn(
                        'The Healthcare Provider could not be saved, so ' + columns(request) + ' was not saved: '
                        + messages(results[i].getErrors())
                    );
                }
            }
        }
    }

    /* The quoted headers of the request's values, e.g. "Provider Attests to ...?". */
    private static String columns(Request request) {
        List<String> headers = new List<String>();
        for (ProviderCsvMapping.FieldMapping mapping : ProviderCsvMapping.HEALTHCARE_PROVIDER_MAPPINGS) {
            if (request.valuesByField.containsKey(mapping.field)) {
                headers.add('"' + String.join(mapping.headers, '" / "') + '"');
            }
        }
        return String.join(headers, ', ');
    }

    private static String messages(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getMessage());
        }
        return String.join(messages, '; ');
    }

    private static Map<Id, Id> queryHealthcareProviders(Set<Id> accountIds) {
        Map<Id, Id> healthcareProviderByAccount = new Map<Id, Id>();
        for (Account provider : [
            SELECT Id, Healthcare_Provider__c FROM Account WHERE Id IN :accountIds WITH SYSTEM_MODE
        ]) {
            if (provider.Healthcare_Provider__c != null) {
                healthcareProviderByAccount.put(provider.Id, provider.Healthcare_Provider__c);
            }
        }
        return healthcareProviderByAccount;
    }

    /* The mapped fields of the HealthcareProviders, by Id. */
    private static Map<Id, HealthcareProvider> queryCurrentValues(Set<Id> healthcareProviderIds) {
        if (healthcareProviderIds.isEmpty()) {
            return new Map<Id, HealthcareProvider>();
        }
        Set<String> fieldNames = new Set<String>{ 'Id' };
        for (ProviderCsvMapping.FieldMapping mapping : ProviderCsvMapping.HEALTHCARE_PROVIDER_MAPPINGS) {
            fieldNames.add(mapping.getFieldName());
        }
        // The field names come from Schema tokens, never from the file.
        return new Map<Id, HealthcareProvider>((List<HealthcareProvider>) Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fieldNames), ', ')
                + ' FROM HealthcareProvider WHERE Id IN :healthcareProviderIds',
            new Map<String, Object>{ 'healthcareProviderIds' => healthcareProviderIds },
            AccessLevel.SYSTEM_MODE
        ));
    }
}
