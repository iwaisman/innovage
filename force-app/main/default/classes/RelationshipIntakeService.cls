/**
 * Ingests relationships-file rows: each row creates a relationship between a
 * Provider and a facility, terminates one, or terminates all of the Provider's
 * relationships at facilities of the roster's Organization scope.
 *
 * A relationship is a HealthcarePractitionerFacility (HPF) linking the
 * Provider's HealthcareProvider to the facility's HealthcareFacility. For
 * intake it is ACTIVE when it has not ended: TerminationDate is blank or after
 * the run date (decided 2026-11-06). This follows the org's Active__c formula
 * (started, and not past its TerminationDate) except that:
 *   - an HPF that starts in the future counts as active, so a create row does
 *     not duplicate it and a terminate row can end it;
 *   - an HPF whose TerminationDate is the run date counts as ended, although
 *     Active__c stays true through that day, so a same-day re-run does not
 *     terminate it again or treat it as existing.
 *
 * IsActive is neither read nor written (decided 2026-11-06). The org's
 * Provider_Plan_Participation flows react to IsActive only, so intake no
 * longer triggers them.
 *
 *     Terminate blank   no active HPF  -> insert one                       INSERTED
 *                       active HPF     -> update the relationship fields
 *                                         that differ (RELATIONSHIP_
 *                                         MAPPINGS), and the start date if
 *                                         the HPF has not started yet      UPDATED
 *                                         or nothing (a start date that
 *                                         can't be changed gets a warning) UNCHANGED
 *     Terminate Single  active HPF     -> TerminationDate = the file's      TERMINATED
 *                                         Termination Date, or the run
 *                                         date; Termination_Notes__c if
 *                                         given (UNCHANGED if both already
 *                                         had these values)
 *                       none           -> nothing (warning)                UNCHANGED
 *     Terminate All     every active HPF of the Provider at an in-scope
 *                       facility is terminated; facility columns ignored   TERMINATED / UNCHANGED
 *
 * A termination may be dated in the past or the future (decided 2026-11-06).
 * One dated after the run date leaves the HPF active (for intake and for
 * Active__c) until that date; terminating it again replaces the date. A
 * termination dated before an HPF's start date is an error, and a Terminate
 * All row then terminates nothing. Termination Date and Termination Notes on
 * a create row are an error; a malformed Termination Date is an error.
 *
 * On a create row, a malformed start date is an error, so the row can be
 * corrected rather than ingested without its date. A blank one becomes the
 * run date on a new HPF, since Active__c is never true without a start date. Terminate rows ignore the
 * start date and the relationship field columns, with a warning. A terminated relationship is never reactivated: a
 * Provider who returns to a facility gets a new HPF. Several active HPFs for
 * one pair are an anomaly: rows touching them warn so it can be investigated.
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

        Ledger ledger = new Ledger(queryRelationships(states, context.runDate), context.organizationScope);
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
                result.fail(RosterIntakeIssues.INVALID_TERMINATE_VALUE, 'Terminate must be blank, "Single" or "All", not "' +
                    mapped.terminateValue + '".');
                return;
            }

            if (mapped.action == RelationshipCsvMapping.Action.CREATE) {
                if (mapped.hasTerminationValues()) {
                    result.fail(RosterIntakeIssues.TERMINATION_COLUMNS_ON_CREATE_ROW,
                        'Termination Date and Termination Notes are only used when Terminate is "Single" or "All"; ' +
                        'this row has Terminate blank, so nothing was created.');
                    return;
                }
                for (RosterIntakeRow.Warning warning : mapped.warnings) {
                    result.warn(warning);
                }
                if (mapped.hasInvalidStartDate()) {
                    result.fail(RosterIntakeIssues.INVALID_START_DATE, 'Relationship Start Date "' + mapped.rawStartDate +
                        '" is not a valid MM/DD/YYYY date.');
                }
                return;
            }

            if (mapped.hasInvalidTerminationDate()) {
                result.fail(RosterIntakeIssues.INVALID_TERMINATION_DATE, 'Termination Date "' + mapped.rawTerminationDate +
                    '" is not a valid MM/DD/YYYY date.');
                return;
            }
            if (mapped.terminationNotesWarning != null) {
                result.warn(mapped.terminationNotesWarning);
            }

            // A termination uses neither the start date nor (for All) the facility columns.
            if (String.isNotBlank(mapped.rawStartDate)) {
                result.warn(RosterIntakeIssues.START_DATE_IGNORED, RelationshipCsvMapping.START_DATE_HEADER,
                    'A start date has no meaning on a termination; the Relationship Start Date was ignored.');
            }
            if (!mapped.relationshipColumnsGiven.isEmpty()) {
                result.warn(RosterIntakeIssues.RELATIONSHIP_COLUMNS_IGNORED, String.join(mapped.relationshipColumnsGiven, ', '),
                    'A termination does not change the relationship\'s other fields; "' +
                    String.join(mapped.relationshipColumnsGiven, '", "') + '" ignored.');
            }
            if (mapped.action == RelationshipCsvMapping.Action.TERMINATE_ALL && mapped.hasFacilityValues()) {
                result.warn(RosterIntakeIssues.FACILITY_COLUMNS_IGNORED, null,
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
                        state.result.fail(RosterIntakeIssues.PROVIDER_NOT_SET_UP, 'Provider "' + match.account.Name +
                            '" has no Healthcare Provider record.');
                    }
                }
                when NO_MATCH {
                    // Only possible without a Unique ID: the NPI matched no one.
                    state.result.fail(RosterIntakeIssues.UNKNOWN_PROVIDER, 'No Provider has NPI ' + state.mapped.providerNpi +
                        '. Ingest the Provider from the provider file first.');
                }
                when else {
                    state.result.fail(RosterIntakeIssues.forMatchOutcome(match.outcome), match.message);
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
                state.result.fail(match.error, match.message);
            } else {
                state.facility = match.facility;
            }
        }
    }

    /*
     * The active relationships of the slice's Providers. Terminated ones are never
     * changed, so they are not needed.
     */
    private static List<HealthcarePractitionerFacility> queryRelationships(List<RowState> states, Date runDate) {
        Set<Id> healthcareProviderIds = new Set<Id>();
        for (RowState state : states) {
            if (!state.result.isError()) {
                healthcareProviderIds.add(state.healthcareProviderId());
            }
        }
        if (healthcareProviderIds.isEmpty()) {
            return new List<HealthcarePractitionerFacility>();
        }
        // The relationship field mappings' fields too, to compare with the file's values.
        // Their names come from Schema tokens, never from the file.
        Set<String> fields = new Set<String>{
            'Id', 'HealthcareProviderId', 'HealthcareFacilityId', 'HealthcareFacility.Name',
            'HealthcareFacility.Legal_Owner__c', 'InitialStartDate', 'TerminationDate', 'Termination_Notes__c'
        };
        for (ProviderCsvMapping.FieldMapping mapping : RelationshipCsvMapping.RELATIONSHIP_MAPPINGS) {
            fields.add(mapping.getFieldName());
        }
        return (List<HealthcarePractitionerFacility>) Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') +
            ' FROM HealthcarePractitionerFacility' +
            ' WHERE HealthcareProviderId IN :healthcareProviderIds' +
            ' AND (TerminationDate = NULL OR TerminationDate > :runDate)' +
            ' ORDER BY CreatedDate, Id',
            new Map<String, Object>{ 'healthcareProviderIds' => healthcareProviderIds, 'runDate' => runDate },
            AccessLevel.SYSTEM_MODE
        );
    }

    /*
     * Applies one row to the ledger. The outcome set here stands unless saving
     * the records it depends on fails (Ledger.save).
     */
    private static void plan(RowState state, Ledger ledger, Date runDate) {
        RosterIntakeRow.Result result = state.result;
        Termination termination = new Termination(
            state.mapped.terminationDate ?? runDate,
            state.mapped.terminationNotes,
            runDate
        );
        switch on state.mapped.action {
            when CREATE {
                planCreate(state, ledger, runDate);
            }
            when TERMINATE_SINGLE {
                Pair pair = ledger.find(state.healthcareProviderId(), state.healthcareFacilityId());
                if (pair == null || pair.active.isEmpty()) {
                    result.warn(RosterIntakeIssues.NO_ACTIVE_RELATIONSHIP, null, 'Provider "' + state.provider.Name +
                        '" has no active relationship with facility "' + state.facility.Name + '"; nothing was terminated.');
                    result.succeed(RosterIntakeRow.Outcome.UNCHANGED);
                    return;
                }
                if (failIfBeforeStart(new List<Pair>{ pair }, termination, state)) {
                    return;
                }
                warnIfSeveralActive(pair, state, result, 'all were terminated');
                Boolean changed = pair.terminate(termination, result);
                result.succeed(changed ? RosterIntakeRow.Outcome.TERMINATED : RosterIntakeRow.Outcome.UNCHANGED);
            }
            when TERMINATE_ALL {
                List<Pair> pairs = new List<Pair>();
                for (Pair pair : ledger.pairsOf(state.healthcareProviderId())) {
                    if (pair.inScope && !pair.active.isEmpty()) {
                        pairs.add(pair);
                    }
                }
                if (failIfBeforeStart(pairs, termination, state)) {
                    return;
                }
                Boolean changed = false;
                for (Pair pair : pairs) {
                    warnIfSeveralActive(pair, state, result, 'all were terminated');
                    changed = pair.terminate(termination, result) || changed;
                }
                if (!pairs.isEmpty()) {
                    result.succeed(changed ? RosterIntakeRow.Outcome.TERMINATED : RosterIntakeRow.Outcome.UNCHANGED);
                } else {
                    result.warn(RosterIntakeIssues.NO_ACTIVE_RELATIONSHIP, null, 'Provider "' + state.provider.Name +
                        '" has no active relationships at facilities of this Organization; nothing was terminated.');
                    result.succeed(RosterIntakeRow.Outcome.UNCHANGED);
                }
            }
        }
    }

    private static void planCreate(RowState state, Ledger ledger, Date runDate) {
        RosterIntakeRow.Result result = state.result;
        Date startDate = state.mapped.startDate;
        Pair pair = ledger.findOrAdd(
            state.healthcareProviderId(),
            state.healthcareFacilityId(),
            state.facility.Name
        );

        if (pair.active.isEmpty()) {
            ledger.addNew(pair, newRelationship(state, runDate), result);
            result.succeed(RosterIntakeRow.Outcome.INSERTED);
            return;
        }

        // Already active (in the database, or created by an earlier row of this slice).
        warnIfSeveralActive(pair, state, result, 'no new one was created');
        Boolean changed = updateStartDate(pair, state, runDate);
        changed = updateRelationshipFields(pair, state) || changed;
        result.succeed(changed ? RosterIntakeRow.Outcome.UPDATED : RosterIntakeRow.Outcome.UNCHANGED);
    }

    /*
     * A start date can be changed only before the relationship starts (decided
     * 2026-11-06): when the stored one is after the run date, a different date in
     * the file replaces it, unless the relationship would then start after its
     * Termination Date. Otherwise a different date gets a START_DATE_DIFFERS
     * warning and is not applied. Returns whether anything changed.
     */
    private static Boolean updateStartDate(Pair pair, RowState state, Date runDate) {
        Date incoming = state.mapped.startDate;
        if (incoming == null) {
            return false;
        }
        RosterIntakeRow.Result result = state.result;
        Boolean changed = false;
        for (Entry entry : pair.active) {
            Date stored = entry.record.InitialStartDate;
            Date endDate = entry.record.TerminationDate;
            if (incoming == stored) {
                continue;
            }
            if (stored == null) {
                result.warn(RosterIntakeIssues.START_DATE_DIFFERS, RelationshipCsvMapping.START_DATE_HEADER,
                    'The relationship already exists without a start date; the file\'s ' + incoming.format() +
                    ' was not applied (a start date can only be changed before the relationship starts).');
            } else if (stored <= runDate) {
                result.warn(RosterIntakeIssues.START_DATE_DIFFERS, RelationshipCsvMapping.START_DATE_HEADER,
                    'The relationship already started on ' + stored.format() + '; the file\'s ' + incoming.format() +
                    ' was not applied (a start date can only be changed before the relationship starts).');
            } else if (endDate != null && incoming > endDate) {
                result.warn(RosterIntakeIssues.START_DATE_DIFFERS, RelationshipCsvMapping.START_DATE_HEADER,
                    'The relationship ends on ' + endDate.format() + ', so it cannot start on ' + incoming.format() +
                    '; its start date ' + stored.format() + ' was kept.');
            } else {
                entry.set(HealthcarePractitionerFacility.InitialStartDate, incoming, result);
                changed = true;
            }
        }
        return changed;
    }

    /*
     * Writes the row's relationship field values (RelationshipCsvMapping.RELATIONSHIP_MAPPINGS)
     * that differ, compared exactly, to each active relationship of the pair, as each
     * mapping's UpdatePolicy allows. Blank values were never mapped, so they change
     * nothing. Returns whether anything changed.
     */
    private static Boolean updateRelationshipFields(Pair pair, RowState state) {
        Boolean changed = false;
        for (Entry entry : pair.active) {
            for (ProviderCsvMapping.FieldMapping mapping : RelationshipCsvMapping.RELATIONSHIP_MAPPINGS) {
                if (!state.mapped.valuesByField.containsKey(mapping.field)) {
                    continue;
                }
                Object storedValue = entry.record.get(mapping.field);
                Object incomingValue = state.mapped.valuesByField.get(mapping.field);
                if (!ProviderCsvMapping.mayWrite(mapping, storedValue, entry.isNew())
                    || ProviderCsvMapping.isSameValue(mapping.valueType, storedValue, incomingValue)) {
                    continue;
                }
                entry.set(mapping.field, incomingValue, state.result);
                changed = true;
            }
        }
        return changed;
    }

    /*
     * Only these fields are set (decided 2026-10-18): not AccountId or PractitionerId
     * (the older Health Cloud link fields), Predecessor_Record__c, EffectiveFrom,
     * EffectiveTo or IsActive.
     */
    private static HealthcarePractitionerFacility newRelationship(RowState state, Date runDate) {
        HealthcarePractitionerFacility relationship = new HealthcarePractitionerFacility(
            Name = (state.provider.Name + ' @ ' + state.facility.Name).left(255),
            HealthcareProviderId = state.healthcareProviderId(),
            HealthcareFacilityId = state.healthcareFacilityId(),
            // Active__c needs a start date; a blank one becomes the run date.
            InitialStartDate = state.mapped.startDate ?? runDate
        );
        for (Schema.SObjectField field : state.mapped.valuesByField.keySet()) {
            relationship.put(field, state.mapped.valuesByField.get(field));
        }
        return relationship;
    }

    /*
     * What a terminate row sets: the end date (the file's Termination Date, or the
     * run date) and the notes (null when the file gives none).
     */
    private class Termination {
        Date endDate;
        String notes;
        Date runDate;

        Termination(Date endDate, String notes, Date runDate) {
            this.endDate = endDate;
            this.notes = notes;
            this.runDate = runDate;
        }

        /* Whether the relationship has ended for intake once terminated (see the class comment). */
        Boolean endsByRunDate() {
            return endDate <= runDate;
        }
    }

    /*
     * A termination may not end a relationship before it starts (decided 2026-11-06).
     * Checks every relationship the row would end before ending any, so a Terminate
     * All row is all or nothing. Returns whether the row failed.
     */
    private static Boolean failIfBeforeStart(List<Pair> pairs, Termination termination, RowState state) {
        for (Pair pair : pairs) {
            for (Entry entry : pair.active) {
                Date startDate = entry.record.InitialStartDate;
                if (startDate != null && termination.endDate < startDate) {
                    state.result.fail(RosterIntakeIssues.TERMINATION_BEFORE_START, 'Provider "' + state.provider.Name +
                        '"\'s relationship with facility "' + pair.facilityName + '" starts on ' + startDate.format() +
                        ', so it cannot end on ' + termination.endDate.format() + '. Nothing was terminated.');
                    return true;
                }
            }
        }
        return false;
    }

    /*
     * Several active relationships for one Provider and facility should not exist;
     * the row still proceeds, with a warning so the data can be investigated.
     * Only records already in the database can be duplicates: the ledger never
     * plans a second insert for a pair.
     */
    private static void warnIfSeveralActive(Pair pair, RowState state, RosterIntakeRow.Result result, String consequence) {
        if (pair.active.size() > 1) {
            result.warn(RosterIntakeIssues.MULTIPLE_ACTIVE_RELATIONSHIPS, null, 'Provider "' + state.provider.Name + '" has ' +
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

        /*
         * Ends the pair's active relationships as the termination says; returns
         * whether anything changed (a re-run with the same date and notes changes
         * nothing). A relationship ending after the run date stays active until then,
         * for later rows of the slice as for later runs.
         */
        Boolean terminate(Termination termination, RosterIntakeRow.Result result) {
            Boolean changed = false;
            for (Entry entry : active) {
                if (entry.record.TerminationDate != termination.endDate) {
                    entry.set(HealthcarePractitionerFacility.TerminationDate, termination.endDate, result);
                    changed = true;
                }
                if (termination.notes != null && !termination.notes.equals(entry.record.Termination_Notes__c)) {
                    entry.set(HealthcarePractitionerFacility.Termination_Notes__c, termination.notes, result);
                    changed = true;
                }
            }
            if (termination.endsByRunDate()) {
                active.clear();
            }
            return changed;
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

        /* Only active relationships (not ended; see the class comment) are loaded. */
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
                result.fail(RosterIntakeIssues.SAVE_ERROR, 'The relationship could not be saved: ' + String.join(messages, '; '));
            }
        }
    }
}
