/**
 * Ingests relationships-file rows: each row creates a relationship between a
 * Provider and a facility, terminates one, or terminates all of the Provider's
 * relationships at facilities of the roster's Organization scope.
 *
 * A relationship is a HealthcarePractitionerFacility (HPF) linking the
 * Provider's HealthcareProvider to the facility's HealthcareFacility. It is
 * ACTIVE when IsActive is true and TerminationDate is blank.
 *
 *     Terminate blank   no active HPF  -> insert one                       INSERTED
 *                       active HPF     -> nothing; the start date is only
 *                                         set on insert (warning if the
 *                                         file gives one)                  UNCHANGED
 *     Terminate Single  active HPF     -> IsActive = false, TerminationDate TERMINATED
 *                       none           -> nothing (warning)                UNCHANGED
 *     Terminate All     every active HPF of the Provider at an in-scope
 *                       facility is terminated; facility columns ignored   TERMINATED / UNCHANGED
 *
 * On a create row, a malformed start date is an error, so the row can be
 * corrected rather than ingested without its date. Terminate rows ignore the
 * start date, with a warning. A terminated relationship is never reactivated: a
 * Provider who returns to a facility gets a new HPF. Several active HPFs for
 * one pair are an anomaly: rows touching them warn so it can be investigated.
 *
 * Terminations set IsActive as well as TerminationDate: the org's
 * Provider_Plan_Participation flows react to IsActive only.
 *
 * ROWS TOUCHING THE SAME RELATIONSHIP: nothing in the database makes a
 * (Provider, facility) pair unique, so ingestAll() keeps a ledger of the
 * slice's relationships and applies rows to it in file order: a second create
 * of the same pair is UNCHANGED, and a create then terminate in one slice
 * inserts the relationship already terminated. Rows in different slices see
 * each other through the database.
 *
 * Queries and DML run in system mode, like Provider intake: intake acts
 * for the roster, not for the uploader.
 */
public with sharing class RelationshipIntakeService {

    /* Error and warning codes besides the matchers'; these are Roster_Intake_Issue__c.Code__c values. */
    public static final String UNKNOWN_PROVIDER = 'UNKNOWN_PROVIDER';
    public static final String PROVIDER_NOT_SET_UP = 'PROVIDER_NOT_SET_UP';
    public static final String INVALID_TERMINATE_VALUE = 'INVALID_TERMINATE_VALUE';
    public static final String INVALID_START_DATE = 'INVALID_START_DATE';
    public static final String MULTIPLE_ACTIVE_RELATIONSHIPS = 'MULTIPLE_ACTIVE_RELATIONSHIPS';
    public static final String START_DATE_DIFFERS = 'START_DATE_DIFFERS';
    public static final String START_DATE_IGNORED = 'START_DATE_IGNORED';
    public static final String NO_ACTIVE_RELATIONSHIP = 'NO_ACTIVE_RELATIONSHIP';
    public static final String FACILITY_COLUMNS_IGNORED = 'FACILITY_COLUMNS_IGNORED';
    public static final String SAVE_ERROR = ProviderIntakeService.SAVE_ERROR;

    /* Provider fields used besides the keys. */
    private static final Set<String> PROVIDER_FIELDS = new Set<String>{ 'Name', 'Healthcare_Provider__c' };

    /**
     * Relationships file rows for RosterIntakeBatch.
     */
    public class Processor implements RosterRowProcessor {
        public List<String> requiredHeaders() {
            return RelationshipCsvMapping.HEADERS;
        }

        /* The Organization scope is worked out once per Run and kept for every slice. */
        public void prepare(RosterIntakeRow.Context context) {
            if (context.organizationId == null) {
                throw new RosterIntakeRunService.RunException('The roster has no Organization.');
            }
            context.organizationScope = OrganizationScope.forOrganization(context.organizationId);
        }

        public List<RosterIntakeRow.Result> ingestAll(
            List<RosterIntakeRow.Input> rows,
            RosterIntakeRow.Context context
        ) {
            return RelationshipIntakeService.ingestAll(rows, context);
        }
    }

    /**
     * Ingests one row on its own, terminating (if asked) as of today.
     *
     * @param csvRow One CSV row, header => value
     * @param organizationId The roster's Organization
     * @return What happened to the row
     * @throws IllegalArgumentException if csvRow or organizationId is null
     * @example
     * RosterIntakeRow.Result result = RelationshipIntakeService.ingest(row, roster.Organization__c);
     */
    public static RosterIntakeRow.Result ingest(Map<String, String> csvRow, Id organizationId) {
        if (csvRow == null || organizationId == null) {
            throw new IllegalArgumentException('CSV row and Organization Id cannot be null.');
        }
        RosterIntakeRow.Context context = new RosterIntakeRow.Context();
        context.organizationId = organizationId;
        context.runDate = Date.today();
        new Processor().prepare(context);
        return ingestAll(new List<RosterIntakeRow.Input>{ new RosterIntakeRow.Input(2, csvRow) }, context)[0];
    }

    /**
     * Ingests many rows with one query each for Providers, facilities and
     * relationships, and at most one update and one insert.
     *
     * @param rows The rows, in file order
     * @param context The Run's context; organizationId, organizationScope and runDate must be set
     * @return One result per row, in the same order
     * @throws IllegalArgumentException if rows or the context is incomplete, or a row has no values
     */
    public static List<RosterIntakeRow.Result> ingestAll(
        List<RosterIntakeRow.Input> rows,
        RosterIntakeRow.Context context
    ) {
        if (rows == null || context?.organizationScope == null || context.runDate == null) {
            throw new IllegalArgumentException('Rows and a prepared context (Organization scope, run date) are required.');
        }

        List<RowState> states = new List<RowState>();
        for (RosterIntakeRow.Input row : rows) {
            if (row?.values == null) {
                throw new IllegalArgumentException('CSV row cannot be null.');
            }
            states.add(new RowState(row.rowNumber, RelationshipCsvMapping.mapRow(row.values)));
        }

        matchProviders(states);
        matchFacilities(states, context);

        Ledger ledger = new Ledger(queryRelationships(states), context.organizationScope);
        for (RowState state : states) {
            if (!state.result.isError()) {
                plan(state, ledger, context.runDate);
            }
        }
        ledger.save();

        List<RosterIntakeRow.Result> results = new List<RosterIntakeRow.Result>();
        for (RowState state : states) {
            results.add(state.result);
        }
        return results;
    }

    /*
     * One row on its way through ingestAll().
     */
    private class RowState {
        RosterIntakeRow.Result result;
        RelationshipCsvMapping.MappedRow mapped;
        Account provider;
        Account facility;

        RowState(Integer rowNumber, RelationshipCsvMapping.MappedRow mapped) {
            this.mapped = mapped;
            result = new RosterIntakeRow.Result(rowNumber);
            result.putIssueValue(Roster_Intake_Issue__c.Provider_Unique_ID__c, mapped.providerUniqueId);
            result.putIssueValue(Roster_Intake_Issue__c.Provider_NPI__c, mapped.providerNpi);
            result.putIssueValue(Roster_Intake_Issue__c.Facility_Unique_ID__c, mapped.facilityUniqueId);
            result.putIssueValue(Roster_Intake_Issue__c.Facility_NPI__c, mapped.facilityNpi);

            if (mapped.action == null) {
                result.fail(INVALID_TERMINATE_VALUE, 'Terminate must be blank, "Single" or "All", not "' +
                    mapped.terminateValue + '".');
                return;
            }

            if (mapped.action == RelationshipCsvMapping.Action.CREATE) {
                if (mapped.hasInvalidStartDate()) {
                    result.fail(INVALID_START_DATE, 'Relationship Start Date "' + mapped.rawStartDate +
                        '" is not a valid MM/DD/YYYY date.');
                }
                return;
            }

            // A termination uses neither the start date nor (for All) the facility columns.
            if (String.isNotBlank(mapped.rawStartDate)) {
                result.warn(START_DATE_IGNORED, RelationshipCsvMapping.START_DATE_HEADER,
                    'A start date has no meaning on a termination; the Relationship Start Date was ignored.');
            }
            if (mapped.action == RelationshipCsvMapping.Action.TERMINATE_ALL && mapped.hasFacilityValues()) {
                result.warn(FACILITY_COLUMNS_IGNORED, null,
                    'Terminate is "All", so the facility columns were ignored.');
            }
        }

        Boolean needsFacility() {
            return !result.isError() && mapped.action != RelationshipCsvMapping.Action.TERMINATE_ALL;
        }

        Id healthcareProviderId() {
            return provider.Healthcare_Provider__c;
        }

        Id healthcareFacilityId() {
            return facility.Healthcare_Facility__c;
        }
    }

    private static void matchProviders(List<RowState> states) {
        List<RowState> matching = new List<RowState>();
        List<ProviderMatcher.MatchRequest> requests = new List<ProviderMatcher.MatchRequest>();
        for (RowState state : states) {
            if (!state.result.isError()) {
                matching.add(state);
                requests.add(new ProviderMatcher.MatchRequest(state.mapped.providerUniqueId, state.mapped.providerNpi));
            }
        }
        if (requests.isEmpty()) {
            return;
        }

        List<AccountMatchResult> matches = ProviderMatcher.matchAll(requests, PROVIDER_FIELDS);
        for (Integer i = 0; i < matching.size(); i++) {
            RowState state = matching[i];
            AccountMatchResult match = matches[i];
            switch on match.outcome {
                when UNIQUE_MATCH {
                    state.provider = match.account;
                    state.result.putIssueValue(Roster_Intake_Issue__c.Provider__c, match.account.Id);
                    if (match.account.Healthcare_Provider__c == null) {
                        state.result.fail(PROVIDER_NOT_SET_UP, 'Provider "' + match.account.Name +
                            '" has no Healthcare Provider record.');
                    }
                }
                when NO_MATCH {
                    // Only possible without a Unique ID: the NPI matched no one.
                    state.result.fail(UNKNOWN_PROVIDER, 'No Provider has NPI ' + state.mapped.providerNpi +
                        '. Ingest the Provider from the provider file first.');
                }
                when else {
                    state.result.fail(match.outcome.name(), match.message);
                }
            }
        }
    }

    private static void matchFacilities(List<RowState> states, RosterIntakeRow.Context context) {
        List<RowState> matching = new List<RowState>();
        List<FacilityMatcher.MatchRequest> requests = new List<FacilityMatcher.MatchRequest>();
        for (RowState state : states) {
            if (state.needsFacility()) {
                matching.add(state);
                requests.add(new FacilityMatcher.MatchRequest(
                    state.mapped.facilityUniqueId,
                    state.mapped.facilityNpi,
                    state.mapped.facilityAddress
                ));
            }
        }
        if (requests.isEmpty()) {
            return;
        }

        List<FacilityMatcher.FacilityMatch> matches = FacilityMatcher.matchAll(
            requests,
            context.organizationId,
            context.organizationScope
        );
        for (Integer i = 0; i < matching.size(); i++) {
            RowState state = matching[i];
            FacilityMatcher.FacilityMatch match = matches[i];
            state.result.putIssueValue(Roster_Intake_Issue__c.Facility__c, match.facility?.Id);
            if (match.isError()) {
                state.result.fail(match.errorCode, match.message);
            } else {
                state.facility = match.facility;
            }
        }
    }

    /*
     * The active relationships of the slice's Providers. Terminated ones are never
     * changed, so they are not needed.
     */
    private static List<HealthcarePractitionerFacility> queryRelationships(List<RowState> states) {
        Set<Id> healthcareProviderIds = new Set<Id>();
        for (RowState state : states) {
            if (!state.result.isError()) {
                healthcareProviderIds.add(state.healthcareProviderId());
            }
        }
        if (healthcareProviderIds.isEmpty()) {
            return new List<HealthcarePractitionerFacility>();
        }
        return [
            SELECT Id, HealthcareProviderId, HealthcareFacilityId, HealthcareFacility.Name,
                HealthcareFacility.Legal_Owner__c, InitialStartDate
            FROM HealthcarePractitionerFacility
            WHERE HealthcareProviderId IN :healthcareProviderIds AND IsActive = TRUE AND TerminationDate = NULL
            WITH SYSTEM_MODE
            ORDER BY CreatedDate, Id
        ];
    }

    /*
     * Applies one row to the ledger. The outcome set here stands unless saving
     * the records it depends on fails (Ledger.save).
     */
    private static void plan(RowState state, Ledger ledger, Date runDate) {
        RosterIntakeRow.Result result = state.result;
        switch on state.mapped.action {
            when CREATE {
                planCreate(state, ledger);
            }
            when TERMINATE_SINGLE {
                Pair pair = ledger.find(state.healthcareProviderId(), state.healthcareFacilityId());
                if (pair == null || pair.active.isEmpty()) {
                    result.warn(NO_ACTIVE_RELATIONSHIP, null, 'Provider "' + state.provider.Name +
                        '" has no active relationship with facility "' + state.facility.Name + '"; nothing was terminated.');
                    result.succeed(RosterIntakeRow.Outcome.UNCHANGED);
                    return;
                }
                warnIfSeveralActive(pair, state, result, 'all were terminated');
                pair.terminate(runDate, result);
                result.succeed(RosterIntakeRow.Outcome.TERMINATED);
            }
            when TERMINATE_ALL {
                Boolean terminatedAny = false;
                for (Pair pair : ledger.pairsOf(state.healthcareProviderId())) {
                    if (pair.inScope && !pair.active.isEmpty()) {
                        warnIfSeveralActive(pair, state, result, 'all were terminated');
                        pair.terminate(runDate, result);
                        terminatedAny = true;
                    }
                }
                if (terminatedAny) {
                    result.succeed(RosterIntakeRow.Outcome.TERMINATED);
                } else {
                    result.warn(NO_ACTIVE_RELATIONSHIP, null, 'Provider "' + state.provider.Name +
                        '" has no active relationships at facilities of this Organization; nothing was terminated.');
                    result.succeed(RosterIntakeRow.Outcome.UNCHANGED);
                }
            }
        }
    }

    private static void planCreate(RowState state, Ledger ledger) {
        RosterIntakeRow.Result result = state.result;
        Date startDate = state.mapped.startDate;
        Pair pair = ledger.findOrAdd(
            state.healthcareProviderId(),
            state.healthcareFacilityId(),
            state.facility.Name
        );

        if (pair.active.isEmpty()) {
            ledger.addNew(pair, newRelationship(state), result);
            result.succeed(RosterIntakeRow.Outcome.INSERTED);
            return;
        }

        // Already active (in the database, or created by an earlier row of this slice).
        // The start date is only ever set when a relationship is created.
        warnIfSeveralActive(pair, state, result, 'no new one was created');
        Date storedStartDate = pair.active[0].record.InitialStartDate;
        if (startDate != null && storedStartDate == null) {
            result.warn(START_DATE_DIFFERS, RelationshipCsvMapping.START_DATE_HEADER,
                'The relationship already exists without a start date; the file\'s ' + startDate.format() +
                ' was not applied (start dates are only set when a relationship is created). No change was made.');
        } else if (startDate != null && startDate != storedStartDate) {
            result.warn(START_DATE_DIFFERS, RelationshipCsvMapping.START_DATE_HEADER,
                'The relationship already exists with start date ' + storedStartDate.format() +
                '; the file\'s ' + startDate.format() + ' was not applied. No change was made.');
        }
        result.succeed(RosterIntakeRow.Outcome.UNCHANGED);
    }

    /*
     * Only these fields are set (decided 2026-10-18): not AccountId or PractitionerId
     * (the older Health Cloud link fields), Predecessor_Record__c, EffectiveFrom or
     * EffectiveTo.
     */
    private static HealthcarePractitionerFacility newRelationship(RowState state) {
        return new HealthcarePractitionerFacility(
            Name = (state.provider.Name + ' @ ' + state.facility.Name).left(255),
            HealthcareProviderId = state.healthcareProviderId(),
            HealthcareFacilityId = state.healthcareFacilityId(),
            // IsActive defaults to false; the Provider_Plan_Participation_AutoCreate flow needs it true.
            IsActive = true,
            InitialStartDate = state.mapped.startDate
        );
    }

    /*
     * Several active relationships for one Provider and facility should not exist;
     * the row still proceeds, with a warning so the data can be investigated.
     * Only records already in the database can be duplicates: the ledger never
     * plans a second insert for a pair.
     */
    private static void warnIfSeveralActive(Pair pair, RowState state, RosterIntakeRow.Result result, String consequence) {
        if (pair.active.size() > 1) {
            result.warn(MULTIPLE_ACTIVE_RELATIONSHIPS, null, 'Provider "' + state.provider.Name + '" has ' +
                pair.active.size() + ' active relationships with facility "' + pair.facilityName + '"; ' +
                consequence + '. Check why there is more than one.');
        }
    }

    /*
     * One relationship record in the ledger: an existing HPF as queried, or a new
     * one waiting to be inserted. `changes` collects the fields to update on an
     * existing one; `results` are the rows that depend on saving it.
     */
    private class Entry {
        HealthcarePractitionerFacility record;
        HealthcarePractitionerFacility changes;
        List<RosterIntakeRow.Result> results = new List<RosterIntakeRow.Result>();

        Entry(HealthcarePractitionerFacility record) {
            this.record = record;
        }

        Boolean isNew() {
            return record.Id == null;
        }

        void set(Schema.SObjectField field, Object value, RosterIntakeRow.Result result) {
            record.put(field, value);
            if (!isNew()) {
                if (changes == null) {
                    changes = new HealthcarePractitionerFacility(Id = record.Id);
                }
                changes.put(field, value);
            }
            // A row setting several fields is listed once (its calls are consecutive).
            if (results.isEmpty() || results[results.size() - 1] !== result) {
                results.add(result);
            }
        }
    }

    /*
     * The active relationships (normally at most one) of one
     * (HealthcareProvider, HealthcareFacility) pair.
     */
    private class Pair {
        Boolean inScope;
        String facilityName;
        List<Entry> active = new List<Entry>();

        Pair(Boolean inScope, String facilityName) {
            this.inScope = inScope;
            this.facilityName = facilityName;
        }

        void terminate(Date runDate, RosterIntakeRow.Result result) {
            for (Entry entry : active) {
                entry.set(HealthcarePractitionerFacility.IsActive, false, result);
                entry.set(HealthcarePractitionerFacility.TerminationDate, runDate, result);
            }
            active.clear();
        }
    }

    /*
     * The slice's relationships by pair, updated as rows are planned, then saved.
     */
    private class Ledger {
        private Map<String, Pair> pairsByKey = new Map<String, Pair>();
        private Map<Id, List<Pair>> pairsByProvider = new Map<Id, List<Pair>>();
        private List<Entry> entries = new List<Entry>();

        Ledger(List<HealthcarePractitionerFacility> relationships, Set<Id> scope) {
            for (HealthcarePractitionerFacility relationship : relationships) {
                Pair pair = findOrAdd(
                    relationship.HealthcareProviderId,
                    relationship.HealthcareFacilityId,
                    relationship.HealthcareFacility?.Name
                );
                pair.inScope = scope.contains(relationship.HealthcareFacility?.Legal_Owner__c);
                Entry entry = new Entry(relationship);
                pair.active.add(entry);
                entries.add(entry);
            }
        }

        /* Active means IsActive and no TerminationDate; only active relationships are loaded. */
        Pair find(Id healthcareProviderId, Id healthcareFacilityId) {
            return pairsByKey.get(healthcareProviderId + ':' + healthcareFacilityId);
        }

        /* New pairs come from rows whose facility matched in scope. */
        Pair findOrAdd(Id healthcareProviderId, Id healthcareFacilityId, String facilityName) {
            Pair pair = find(healthcareProviderId, healthcareFacilityId);
            if (pair == null) {
                pair = new Pair(true, facilityName);
                pairsByKey.put(healthcareProviderId + ':' + healthcareFacilityId, pair);
                if (!pairsByProvider.containsKey(healthcareProviderId)) {
                    pairsByProvider.put(healthcareProviderId, new List<Pair>());
                }
                pairsByProvider.get(healthcareProviderId).add(pair);
            }
            return pair;
        }

        List<Pair> pairsOf(Id healthcareProviderId) {
            return pairsByProvider.get(healthcareProviderId) ?? new List<Pair>();
        }

        void addNew(Pair pair, HealthcarePractitionerFacility record, RosterIntakeRow.Result result) {
            Entry entry = new Entry(record);
            entry.results.add(result);
            pair.active.add(entry);
            entries.add(entry);
        }

        /*
         * Terminations first, then inserts, each partial-success.
         * A row whose record fails to save becomes a SAVE_ERROR.
         */
        void save() {
            List<Entry> updated = new List<Entry>();
            List<HealthcarePractitionerFacility> updates = new List<HealthcarePractitionerFacility>();
            List<Entry> inserted = new List<Entry>();
            List<HealthcarePractitionerFacility> inserts = new List<HealthcarePractitionerFacility>();
            for (Entry entry : entries) {
                if (entry.isNew()) {
                    inserted.add(entry);
                    inserts.add(entry.record);
                } else if (entry.changes != null) {
                    updated.add(entry);
                    updates.add(entry.changes);
                }
            }

            if (!updates.isEmpty()) {
                applySaveResults(Database.update(updates, false, AccessLevel.SYSTEM_MODE), updated);
            }
            if (!inserts.isEmpty()) {
                applySaveResults(Database.insert(inserts, false, AccessLevel.SYSTEM_MODE), inserted);
            }
        }
    }

    private static void applySaveResults(List<Database.SaveResult> saveResults, List<Entry> entries) {
        for (Integer i = 0; i < saveResults.size(); i++) {
            if (saveResults[i].isSuccess()) {
                continue;
            }
            List<String> messages = new List<String>();
            for (Database.Error error : saveResults[i].getErrors()) {
                String fields = error.getFields().isEmpty() ? '' : ' (' + String.join(error.getFields(), ', ') + ')';
                messages.add(error.getMessage() + fields);
            }
            for (RosterIntakeRow.Result result : entries[i].results) {
                result.fail(SAVE_ERROR, 'The relationship could not be saved: ' + String.join(messages, '; '));
            }
        }
    }
}
