@IsTest
private class RelationshipIngestionServiceTest {

    /*
     * Organizations:  Roster Org (the roster's) > Sub Org;  Other Org (unrelated).
     * Facilities:     Main (Roster Org), Oak (Sub Org), Elsewhere (Other Org),
     *                 Unowned (no Legal Owner), Shared A + Shared B (Roster Org, same NPI).
     * Providers:      Alpha, Beta (each with a HealthcareProvider).
     */
    private static final String ROSTER_ORG = 'Roster Org';
    private static final String SUB_ORG = 'Sub Org';
    private static final String OTHER_ORG = 'Other Org';

    private static final String MAIN = 'Main Facility';
    private static final String OAK = 'Oak Facility';
    private static final String ELSEWHERE = 'Elsewhere Facility';
    private static final String UNOWNED = 'Unowned Facility';
    private static final String SHARED_A = 'Shared Facility A';
    private static final String SHARED_B = 'Shared Facility B';

    private static final String MAIN_NPI = ProviderTestDataFactory.npi(5001);
    private static final String OAK_NPI = ProviderTestDataFactory.npi(5002);
    private static final String SHARED_NPI = ProviderTestDataFactory.npi(5003);
    private static final String MAIN_STREET = '100 Main St.\nSuite 5';

    private static final String ALPHA_NPI = ProviderTestDataFactory.npi(6001);
    private static final String BETA_NPI = ProviderTestDataFactory.npi(6002);

    @TestSetup
    static void setup() {
        RelationshipTestDataFactory.createOwnershipRoles();
        Account rosterOrg = RelationshipTestDataFactory.createOrganization(ROSTER_ORG, null);
        Account subOrg = RelationshipTestDataFactory.createOrganization(SUB_ORG, rosterOrg.Id);
        Account otherOrg = RelationshipTestDataFactory.createOrganization(OTHER_ORG, null);

        RelationshipTestDataFactory.createFacility(MAIN, rosterOrg.Id, MAIN_NPI, MAIN_STREET);
        RelationshipTestDataFactory.createFacility(OAK, subOrg.Id, OAK_NPI, '200 Oak Ave');
        RelationshipTestDataFactory.createFacility(ELSEWHERE, otherOrg.Id, null, '300 Pine Rd');
        RelationshipTestDataFactory.createFacility(UNOWNED, null, null, null);
        RelationshipTestDataFactory.createFacility(SHARED_A, rosterOrg.Id, SHARED_NPI, '1 Shared Way');
        RelationshipTestDataFactory.createFacility(SHARED_B, rosterOrg.Id, SHARED_NPI, '2 Shared Way');

        RelationshipTestDataFactory.createProvider('Alpha', ALPHA_NPI);
        RelationshipTestDataFactory.createProvider('Beta', BETA_NPI);
    }

    // ─── Helpers ───────────────────────────────────────────────────────

    private static Id organizationId(String name) {
        return [SELECT Id FROM Account WHERE Name = :name LIMIT 1].Id;
    }

    private static Account facility(String name) {
        return [
            SELECT Id, Name, InnovAge_Unique_ID__c, Healthcare_Facility__c
            FROM Account
            WHERE Name = :name
            LIMIT 1
        ];
    }

    private static Account provider(String lastName) {
        return [
            SELECT Id, Name, NPI__c, InnovAge_Unique_ID__c, Healthcare_Provider__c
            FROM Account
            WHERE LastName = :lastName
            LIMIT 1
        ];
    }

    private static RosterIngestionRow.Result ingest(Map<String, String> row) {
        return RelationshipIngestionService.ingest(row, organizationId(ROSTER_ORG));
    }

    private static Map<String, String> createRow(String facilityName) {
        return RelationshipTestDataFactory.row(ALPHA_NPI, facility(facilityName).InnovAge_Unique_ID__c, '');
    }

    private static void assertError(RosterIngestionRow.Result result, String code) {
        Assert.areEqual(RosterIngestionRow.Outcome.ERROR, result.outcome, 'Expected an error: ' + result.errors);
        Assert.areEqual(code, result.errorCode, 'Error code: ' + result.errors);
    }

    private static Boolean hasWarning(RosterIngestionRow.Result result, String code) {
        for (RosterIngestionRow.Warning warning : result.warnings) {
            if (warning.code == code) {
                return true;
            }
        }
        return false;
    }

    // ─── Create ────────────────────────────────────────────────────────

    @IsTest
    static void shouldInsertActiveRelationship_WhenNoneExists() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, '03/15/2026');

        Test.startTest();
        RosterIngestionRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(1, relationships.size(), 'One relationship');
        HealthcarePractitionerFacility relationship = relationships[0];
        Assert.isTrue(relationship.IsActive, 'Created active, so the payer participation flow sees it');
        Assert.areEqual(Date.newInstance(2026, 3, 15), relationship.InitialStartDate, 'Start date from the file');
        Assert.areEqual(facility(MAIN).Healthcare_Facility__c, relationship.HealthcareFacilityId, 'Linked to the facility');
        Assert.areEqual(provider('Alpha').Name + ' @ ' + MAIN, relationship.Name, 'Name is "<Provider> @ <Facility>"');
        Assert.areEqual(provider('Alpha').Id, result.issueValuesByField.get(RosterIngestionIssue__c.Provider__c), 'Issue links the Provider');
        Assert.areEqual(facility(MAIN).Id, result.issueValuesByField.get(RosterIngestionIssue__c.Facility__c), 'Issue links the facility');
    }

    @IsTest
    static void shouldInsert_WhenFacilityBelongsToSubOrganization() {
        Test.startTest();
        RosterIngestionRow.Result result = ingest(createRow(OAK));
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'Sub-organizations are in scope: ' + result.errors);
    }

    @IsTest
    static void shouldBeUnchanged_WhenRelationshipAlreadyActive() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);

        Test.startTest();
        RosterIngestionRow.Result result = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'No duplicate');
    }

    @IsTest
    static void shouldNotSetStartDate_WhenRelationshipAlreadyActive() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, '1/2/2025');

        Test.startTest();
        RosterIngestionRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RelationshipIngestionService.START_DATE_DIFFERS), 'Warns it was not applied: ' + result.warnings);
        Assert.isTrue(result.warnings[0].message.contains('No change was made'), 'Says so: ' + result.warnings[0].message);
        Assert.isNull(RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].InitialStartDate, 'Only set when created');
    }

    @IsTest
    static void shouldWarn_WhenStartDateDiffersFromActiveRelationship() {
        HealthcarePractitionerFacility existing = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        update new HealthcarePractitionerFacility(Id = existing.Id, InitialStartDate = Date.newInstance(2024, 6, 1));
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, '01/02/2025');

        Test.startTest();
        RosterIngestionRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RelationshipIngestionService.START_DATE_DIFFERS), 'Warns: ' + result.warnings);
        Assert.areEqual(Date.newInstance(2024, 6, 1), RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].InitialStartDate, 'Not overwritten');
    }

    @IsTest
    static void shouldInsertNewRelationship_WhenPreviousRelationshipTerminated() {
        HealthcarePractitionerFacility old = RelationshipTestDataFactory.createRelationship(
            provider('Alpha'), facility(MAIN), Date.today().addDays(-30)
        );

        Test.startTest();
        RosterIngestionRow.Result result = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(2, relationships.size(), 'The old one is kept, not reactivated');
        Assert.areNotEqual(old.Id, relationships[0].Id, 'A new relationship');
        Assert.isTrue(relationships[0].IsActive, 'The new one is active');
    }

    @IsTest
    static void shouldInsert_WhenOnlyRelationshipHasTerminationDateButIsActive() {
        // Not active by our definition (IsActive and no TerminationDate), so a new one is created.
        HealthcarePractitionerFacility odd = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        update new HealthcarePractitionerFacility(Id = odd.Id, TerminationDate = Date.today().addDays(10));

        Test.startTest();
        RosterIngestionRow.Result result = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
    }

    @IsTest
    static void shouldFail_WhenStartDateInvalid() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, '2026-03-15');

        RosterIngestionRow.Result result = ingest(row);

        assertError(result, RelationshipIngestionService.INVALID_START_DATE);
        Assert.isTrue(result.errors[0].contains('"2026-03-15"'), 'Shows the value to fix: ' + result.errors[0]);
        Assert.isTrue(RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).isEmpty(), 'Not created');
    }

    @IsTest
    static void shouldWarn_WhenSeveralActiveRelationshipsForSamePair() {
        Account alpha = provider('Alpha');
        RelationshipTestDataFactory.createRelationship(alpha, facility(MAIN), null);
        RelationshipTestDataFactory.createRelationship(alpha, facility(MAIN), null);
        Map<String, String> terminate = createRow(MAIN);
        terminate.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        RosterIngestionRow.Result created = ingest(createRow(MAIN));
        RosterIngestionRow.Result terminated = ingest(terminate);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.UNCHANGED, created.outcome, 'No third one: ' + created.errors);
        Assert.isTrue(hasWarning(created, RelationshipIngestionService.MULTIPLE_ACTIVE_RELATIONSHIPS), 'Create warns: ' + created.warnings);
        Assert.areEqual(RosterIngestionRow.Outcome.TERMINATED, terminated.outcome, 'Errors: ' + terminated.errors);
        Assert.isTrue(hasWarning(terminated, RelationshipIngestionService.MULTIPLE_ACTIVE_RELATIONSHIPS), 'Terminate warns: ' + terminated.warnings);
        for (HealthcarePractitionerFacility relationship : RelationshipTestDataFactory.relationshipsOf(alpha)) {
            Assert.isFalse(relationship.IsActive, 'Both terminated');
        }
    }

    // ─── Terminate ─────────────────────────────────────────────────────

    @IsTest
    static void shouldTerminate_WhenSingleAndRelationshipActive() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'single');

        Test.startTest();
        RosterIngestionRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        HealthcarePractitionerFacility relationship = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0];
        Assert.isFalse(relationship.IsActive, 'Deactivated, so the payer participation flow sees it');
        Assert.areEqual(Date.today(), relationship.TerminationDate, 'Terminated as of the run date');
    }

    @IsTest
    static void shouldIgnoreStartDateWithWarning_WhenTerminating() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> single = createRow(MAIN);
        single.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');
        single.put(RelationshipCsvMapping.START_DATE_HEADER, 'not a date');
        Map<String, String> all = RelationshipTestDataFactory.row(BETA_NPI, '', 'All');
        all.put(RelationshipCsvMapping.START_DATE_HEADER, '01/01/2026');

        Test.startTest();
        RosterIngestionRow.Result singleResult = ingest(single);
        RosterIngestionRow.Result allResult = ingest(all);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.TERMINATED, singleResult.outcome, 'Even a malformed date is ignored: ' + singleResult.errors);
        Assert.isTrue(hasWarning(singleResult, RelationshipIngestionService.START_DATE_IGNORED), 'Warns: ' + singleResult.warnings);
        Assert.isTrue(hasWarning(allResult, RelationshipIngestionService.START_DATE_IGNORED), 'All warns too: ' + allResult.warnings);
    }

    @IsTest
    static void shouldWarn_WhenSingleAndNoActiveRelationship() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        RosterIngestionRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RelationshipIngestionService.NO_ACTIVE_RELATIONSHIP), 'Warns: ' + result.warnings);
    }

    @IsTest
    static void shouldTerminateOnlyInScope_WhenAll() {
        Account alpha = provider('Alpha');
        RelationshipTestDataFactory.createRelationship(alpha, facility(MAIN), null);
        RelationshipTestDataFactory.createRelationship(alpha, facility(OAK), null);
        RelationshipTestDataFactory.createRelationship(alpha, facility(ELSEWHERE), null);
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', 'All');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, MAIN_NPI);

        Test.startTest();
        RosterIngestionRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RelationshipIngestionService.FACILITY_COLUMNS_IGNORED), 'Warns about the facility column');
        Id elsewhere = facility(ELSEWHERE).Healthcare_Facility__c;
        for (HealthcarePractitionerFacility relationship : RelationshipTestDataFactory.relationshipsOf(alpha)) {
            Boolean outOfScope = relationship.HealthcareFacilityId == elsewhere;
            Assert.areEqual(outOfScope, relationship.IsActive, 'Only out-of-scope relationships stay active');
        }
    }

    @IsTest
    static void shouldWarn_WhenAllAndNoActiveRelationshipInScope() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(ELSEWHERE), null);

        Test.startTest();
        RosterIngestionRow.Result result = ingest(RelationshipTestDataFactory.row(ALPHA_NPI, '', 'ALL'));
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RelationshipIngestionService.NO_ACTIVE_RELATIONSHIP), 'Warns: ' + result.warnings);
    }

    @IsTest
    static void shouldFail_WhenTerminateValueUnknown() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Yes');

        RosterIngestionRow.Result result = ingest(row);

        assertError(result, RelationshipIngestionService.INVALID_TERMINATE_VALUE);
    }

    // ─── Provider matching ─────────────────────────────────────────────

    @IsTest
    static void shouldFail_WhenProviderUnknown() {
        RosterIngestionRow.Result result = ingest(RelationshipTestDataFactory.row(
            ProviderTestDataFactory.NPI_UNUSED, facility(MAIN).InnovAge_Unique_ID__c, ''
        ));

        assertError(result, RelationshipIngestionService.UNKNOWN_PROVIDER);
    }

    @IsTest
    static void shouldMatchProviderByUniqueId() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.PROVIDER_NPI_HEADER, '');
        row.put(RelationshipCsvMapping.PROVIDER_UNIQUE_ID_HEADER, provider('Beta').InnovAge_Unique_ID__c);

        RosterIngestionRow.Result result = ingest(row);

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Beta')).size(), 'Beta got the relationship');
    }

    @IsTest
    static void shouldFail_WhenProviderKeysDisagree() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.PROVIDER_UNIQUE_ID_HEADER, provider('Beta').InnovAge_Unique_ID__c);

        RosterIngestionRow.Result result = ingest(row);

        assertError(result, AccountMatchResult.Outcome.MULTIPLE_MATCHES.name());
    }

    @IsTest
    static void shouldFail_WhenProviderHasNoHealthcareProvider() {
        update new Account(Id = provider('Alpha').Id, Healthcare_Provider__c = null);

        RosterIngestionRow.Result result = ingest(createRow(MAIN));

        assertError(result, RelationshipIngestionService.PROVIDER_NOT_SET_UP);
    }

    // ─── Facility matching ─────────────────────────────────────────────

    @IsTest
    static void shouldFailNamingOwner_WhenFacilityOutsideScope() {
        RosterIngestionRow.Result result = ingest(createRow(ELSEWHERE));

        assertError(result, FacilityMatcher.FACILITY_NOT_IN_ORGANIZATION);
        String message = result.errors[0];
        Assert.isTrue(message.contains('"' + OTHER_ORG + '"'), 'Names the owner: ' + message);
        Assert.isTrue(message.contains('"' + ROSTER_ORG + '"'), 'Names the roster Organization: ' + message);
        Assert.areEqual(facility(ELSEWHERE).Id, result.issueValuesByField.get(RosterIngestionIssue__c.Facility__c), 'Issue still links the facility');
    }

    @IsTest
    static void shouldFail_WhenFacilityHasNoLegalOwner() {
        RosterIngestionRow.Result result = ingest(createRow(UNOWNED));

        assertError(result, FacilityMatcher.FACILITY_NOT_IN_ORGANIZATION);
        Assert.isTrue(result.errors[0].contains('no Legal Owner'), 'Says so: ' + result.errors[0]);
    }

    @IsTest
    static void shouldFail_WhenFacilityOfParentOrganization() {
        // A roster for the sub-organization cannot touch its parent's facilities.
        RosterIngestionRow.Result result = RelationshipIngestionService.ingest(createRow(MAIN), organizationId(SUB_ORG));

        assertError(result, FacilityMatcher.FACILITY_NOT_IN_ORGANIZATION);
    }

    @IsTest
    static void shouldMatchFacilityByNpi_WhenNoUniqueId() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, OAK_NPI);

        RosterIngestionRow.Result result = ingest(row);

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(facility(OAK).Healthcare_Facility__c, RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].HealthcareFacilityId, 'Oak');
    }

    @IsTest
    static void shouldFail_WhenFacilityNpiSharedBySeveralFacilities() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, SHARED_NPI);

        RosterIngestionRow.Result result = ingest(row);

        assertError(result, FacilityMatcher.MULTIPLE_FACILITY_MATCHES);
        Assert.isTrue(result.errors[0].contains(SHARED_A) && result.errors[0].contains(SHARED_B), 'Lists them: ' + result.errors[0]);
    }

    @IsTest
    static void shouldMatchFacility_WhenUniqueIdGivenAlongsideSharedNpi() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, facility(SHARED_B).InnovAge_Unique_ID__c, '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, SHARED_NPI);

        RosterIngestionRow.Result result = ingest(row);

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'The Unique ID decides: ' + result.errors);
    }

    @IsTest
    static void shouldFail_WhenFacilityNpiFoundNowhereInScope() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, ProviderTestDataFactory.NPI_UNUSED);

        assertError(ingest(row), FacilityMatcher.FACILITY_NOT_FOUND);
    }

    @IsTest
    static void shouldMatchFacilityByAddress_WhenNoIds() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '  100  MAIN st ');

        RosterIngestionRow.Result result = ingest(row);

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'First line, whitespace, case and trailing dot ignored: ' + result.errors);
    }

    @IsTest
    static void shouldNotMatchAddressOutsideScope() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '300 Pine Rd');

        assertError(ingest(row), FacilityMatcher.FACILITY_NOT_FOUND);
    }

    @IsTest
    static void shouldFail_WhenAddressDisagreesWithUniqueId() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '101 Main St');

        assertError(ingest(row), FacilityMatcher.FACILITY_KEY_MISMATCH);
    }

    @IsTest
    static void shouldFail_WhenNpiDisagreesWithUniqueId() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, OAK_NPI);

        assertError(ingest(row), FacilityMatcher.FACILITY_KEY_MISMATCH);
    }

    @IsTest
    static void shouldMatch_WhenStoredAddressAndNpiBlank() {
        // A facility missing its address or NPI is not a mismatch once its Unique ID matched.
        Account unownedButInScope = facility(UNOWNED);
        update new HealthcareFacility(Id = unownedButInScope.Healthcare_Facility__c, Legal_Owner__c = organizationId(ROSTER_ORG));
        Map<String, String> row = createRow(UNOWNED);
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '1 Anywhere St');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, OAK_NPI);

        RosterIngestionRow.Result result = ingest(row);

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
    }

    @IsTest
    static void shouldFail_WhenFacilityKeysMissingOrMalformed() {
        assertError(ingest(RelationshipTestDataFactory.row(ALPHA_NPI, '', '')), FacilityMatcher.NO_FACILITY_KEY_VALUES);
        assertError(ingest(RelationshipTestDataFactory.row(ALPHA_NPI, 'P000000001abc', '')), FacilityMatcher.MALFORMED_FACILITY_UNIQUE_ID);
        assertError(ingest(RelationshipTestDataFactory.row(ALPHA_NPI, 'MF999999999zzz', '')), FacilityMatcher.UNKNOWN_FACILITY_UNIQUE_ID);

        Map<String, String> badNpi = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        badNpi.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, '1234567890');
        assertError(ingest(badNpi), FacilityMatcher.MALFORMED_FACILITY_NPI);
    }

    // FACILITY_NOT_SET_UP is not tested: a validation rule stops Healthcare_Facility__c being
    // cleared, and the org's automation sets it when a facility Account is created.

    // ─── Rows in one slice ─────────────────────────────────────────────

    private static List<RosterIngestionRow.Result> ingestSlice(List<Map<String, String>> rows) {
        RosterIngestionRow.Context context = new RosterIngestionRow.Context();
        context.organizationId = organizationId(ROSTER_ORG);
        context.runDate = Date.today();
        new RelationshipIngestionService.Processor().prepare(context);

        List<RosterIngestionRow.Input> inputs = new List<RosterIngestionRow.Input>();
        for (Integer i = 0; i < rows.size(); i++) {
            inputs.add(new RosterIngestionRow.Input(i + 2, rows[i]));
        }
        return RelationshipIngestionService.ingestAll(inputs, context);
    }

    @IsTest
    static void shouldCreateOnce_WhenSameRelationshipTwiceInSlice() {
        Test.startTest();
        List<RosterIngestionRow.Result> results = ingestSlice(new List<Map<String, String>>{ createRow(MAIN), createRow(MAIN) });
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, results[0].outcome, 'First creates: ' + results[0].errors);
        Assert.areEqual(RosterIngestionRow.Outcome.UNCHANGED, results[1].outcome, 'Second sees it: ' + results[1].errors);
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'No duplicate');
    }

    @IsTest
    static void shouldInsertTerminated_WhenCreatedThenTerminatedInSlice() {
        Map<String, String> terminate = createRow(MAIN);
        terminate.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        List<RosterIngestionRow.Result> results = ingestSlice(new List<Map<String, String>>{ createRow(MAIN), terminate });
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, results[0].outcome, 'Errors: ' + results[0].errors);
        Assert.areEqual(RosterIngestionRow.Outcome.TERMINATED, results[1].outcome, 'Errors: ' + results[1].errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(1, relationships.size(), 'One record');
        Assert.isFalse(relationships[0].IsActive, 'Saved in its final state');
        Assert.areEqual(Date.today(), relationships[0].TerminationDate, 'Terminated on the run date');
    }

    @IsTest
    static void shouldInsertNew_WhenTerminatedThenCreatedInSlice() {
        HealthcarePractitionerFacility old = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> terminate = createRow(MAIN);
        terminate.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        List<RosterIngestionRow.Result> results = ingestSlice(new List<Map<String, String>>{ terminate, createRow(MAIN) });
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.TERMINATED, results[0].outcome, 'Errors: ' + results[0].errors);
        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, results[1].outcome, 'Errors: ' + results[1].errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(2, relationships.size(), 'Old and new');
        Assert.areNotEqual(old.Id, relationships[0].Id, 'Newest is the new one');
        Assert.isTrue(relationships[0].IsActive, 'New is active');
        Assert.isFalse(relationships[1].IsActive, 'Old is terminated');
    }

    @IsTest
    static void shouldTerminatePendingCreates_WhenAllFollowsInSlice() {
        Test.startTest();
        List<RosterIngestionRow.Result> results = ingestSlice(new List<Map<String, String>>{
            createRow(MAIN),
            createRow(OAK),
            RelationshipTestDataFactory.row(ALPHA_NPI, '', 'All')
        });
        Test.stopTest();

        Assert.areEqual(RosterIngestionRow.Outcome.TERMINATED, results[2].outcome, 'Errors: ' + results[2].errors);
        for (HealthcarePractitionerFacility relationship : RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))) {
            Assert.isFalse(relationship.IsActive, 'Both inserted already terminated');
        }
    }

    @IsTest
    static void shouldKeepRowsIndependent_WhenOneRowFails() {
        Test.startTest();
        List<RosterIngestionRow.Result> results = ingestSlice(new List<Map<String, String>>{
            createRow(ELSEWHERE),
            createRow(MAIN)
        });
        Test.stopTest();

        assertError(results[0], FacilityMatcher.FACILITY_NOT_IN_ORGANIZATION);
        Assert.areEqual(RosterIngestionRow.Outcome.INSERTED, results[1].outcome, 'Errors: ' + results[1].errors);
    }
}
