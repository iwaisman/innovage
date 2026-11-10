@IsTest
private class RelationshipIntakeServiceTest {

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

    private static RosterIntakeRow.Result ingest(Map<String, String> row) {
        return RelationshipIntakeService.ingest(row, organizationId(ROSTER_ORG));
    }

    private static Map<String, String> createRow(String facilityName) {
        return RelationshipTestDataFactory.row(ALPHA_NPI, facility(facilityName).InnovAge_Unique_ID__c, '');
    }

    private static void assertError(RosterIntakeRow.Result result, String code) {
        Assert.areEqual(RosterIntakeRow.Outcome.ERROR, result.outcome, 'Expected an error: ' + result.errors);
        Assert.areEqual(code, result.errorCode, 'Error code: ' + result.errors);
    }

    private static Boolean hasWarning(RosterIntakeRow.Result result, String code) {
        for (RosterIntakeRow.Warning warning : result.warnings) {
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
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(1, relationships.size(), 'One relationship');
        HealthcarePractitionerFacility relationship = relationships[0];
        Assert.isFalse(relationship.IsActive, 'IsActive is never set (it defaults to false)');
        Assert.isNull(relationship.TerminationDate, 'Not ended');
        Assert.isTrue(relationship.Active__c, 'Active by the org\'s formula: started, not ended');
        Assert.areEqual(Date.newInstance(2026, 3, 15), relationship.InitialStartDate, 'Start date from the file');
        Assert.areEqual(facility(MAIN).Healthcare_Facility__c, relationship.HealthcareFacilityId, 'Linked to the facility');
        Assert.areEqual(provider('Alpha').Name + ' @ ' + MAIN, relationship.Name, 'Name is "<Provider> @ <Facility>"');
        Assert.areEqual(provider('Alpha').Id, result.issueValuesByField.get(Roster_Intake_Issue__c.Provider__c), 'Issue links the Provider');
        Assert.areEqual(facility(MAIN).Id, result.issueValuesByField.get(Roster_Intake_Issue__c.Facility__c), 'Issue links the facility');
    }

    @IsTest
    static void shouldInsert_WhenFacilityBelongsToSubOrganization() {
        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRow(OAK));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Sub-organizations are in scope: ' + result.errors);
    }

    @IsTest
    static void shouldBeUnchanged_WhenRelationshipAlreadyActive() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'No duplicate');
    }

    @IsTest
    static void shouldNotSetStartDate_WhenRelationshipAlreadyActive() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, '1/2/2025');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RosterIntakeIssues.START_DATE_DIFFERS.code), 'Warns it was not applied: ' + result.warnings);
        Assert.isTrue(result.warnings[0].message.contains('a start date can only be changed before the relationship starts'), 'Says why: ' + result.warnings[0].message);
        Assert.isNull(RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].InitialStartDate, 'Only set when created');
    }

    @IsTest
    static void shouldWarn_WhenStartDateDiffersFromActiveRelationship() {
        HealthcarePractitionerFacility existing = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        update new HealthcarePractitionerFacility(Id = existing.Id, InitialStartDate = Date.newInstance(2024, 6, 1));
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, '01/02/2025');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RosterIntakeIssues.START_DATE_DIFFERS.code), 'Warns: ' + result.warnings);
        Assert.areEqual(Date.newInstance(2024, 6, 1), RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].InitialStartDate, 'Not overwritten');
    }

    @IsTest
    static void shouldInsertNewRelationship_WhenPreviousRelationshipTerminated() {
        HealthcarePractitionerFacility old = RelationshipTestDataFactory.createRelationship(
            provider('Alpha'), facility(MAIN), Date.today().addDays(-30)
        );

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(2, relationships.size(), 'The old one is kept, not reactivated');
        Assert.areNotEqual(old.Id, relationships[0].Id, 'A new relationship');
        Assert.areEqual(Date.today(), relationships[0].InitialStartDate, 'A blank start date becomes the run date');
        Assert.isTrue(relationships[0].Active__c, 'So the new one is active');
    }

    @IsTest
    static void shouldTreatAsExisting_WhenTerminationDateInFuture() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), Date.today().addDays(10));

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Not ended yet: ' + result.errors);
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'No duplicate');
    }

    @IsTest
    static void shouldTreatAsExisting_WhenStartDateInFuture() {
        HealthcarePractitionerFacility future = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        update new HealthcarePractitionerFacility(Id = future.Id, InitialStartDate = Date.today().addDays(30));

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Existing although Active__c is false: ' + result.errors);
        HealthcarePractitionerFacility relationship = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0];
        Assert.isFalse(relationship.Active__c, 'Not started, so not active by the formula');
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'No duplicate');
    }

    @IsTest
    static void shouldTreatAsEnded_WhenTerminationDateIsRunDate() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), Date.today());
        Map<String, String> terminate = createRow(MAIN);
        terminate.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        RosterIntakeRow.Result terminated = ingest(terminate);
        RosterIntakeRow.Result created = ingest(createRow(MAIN));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, terminated.outcome, 'Already ended: ' + terminated.errors);
        Assert.isTrue(hasWarning(terminated, RosterIntakeIssues.NO_ACTIVE_RELATIONSHIP.code), 'Nothing to terminate');
        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, created.outcome, 'A new one: ' + created.errors);
    }

    @IsTest
    static void shouldFail_WhenStartDateInvalid() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, '2026-03-15');

        RosterIntakeRow.Result result = ingest(row);

        assertError(result, RosterIntakeIssues.INVALID_START_DATE.code);
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
        RosterIntakeRow.Result created = ingest(createRow(MAIN));
        RosterIntakeRow.Result terminated = ingest(terminate);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, created.outcome, 'No third one: ' + created.errors);
        Assert.isTrue(hasWarning(created, RosterIntakeIssues.MULTIPLE_ACTIVE_RELATIONSHIPS.code), 'Create warns: ' + created.warnings);
        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, terminated.outcome, 'Errors: ' + terminated.errors);
        Assert.isTrue(hasWarning(terminated, RosterIntakeIssues.MULTIPLE_ACTIVE_RELATIONSHIPS.code), 'Terminate warns: ' + terminated.warnings);
        for (HealthcarePractitionerFacility relationship : RelationshipTestDataFactory.relationshipsOf(alpha)) {
            Assert.areEqual(Date.today(), relationship.TerminationDate, 'Both terminated');
        }
    }

    // ─── Terminate ─────────────────────────────────────────────────────

    @IsTest
    static void shouldTerminate_WhenSingleAndRelationshipActive() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'single');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        HealthcarePractitionerFacility relationship = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0];
        Assert.isTrue(relationship.IsActive, 'IsActive is left as it was');
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
        RosterIntakeRow.Result singleResult = ingest(single);
        RosterIntakeRow.Result allResult = ingest(all);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, singleResult.outcome, 'Even a malformed date is ignored: ' + singleResult.errors);
        Assert.isTrue(hasWarning(singleResult, RosterIntakeIssues.START_DATE_IGNORED.code), 'Warns: ' + singleResult.warnings);
        Assert.isTrue(hasWarning(allResult, RosterIntakeIssues.START_DATE_IGNORED.code), 'All warns too: ' + allResult.warnings);
    }

    @IsTest
    static void shouldWarn_WhenSingleAndNoActiveRelationship() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RosterIntakeIssues.NO_ACTIVE_RELATIONSHIP.code), 'Warns: ' + result.warnings);
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
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RosterIntakeIssues.FACILITY_COLUMNS_IGNORED.code), 'Warns about the facility column');
        Id elsewhere = facility(ELSEWHERE).Healthcare_Facility__c;
        for (HealthcarePractitionerFacility relationship : RelationshipTestDataFactory.relationshipsOf(alpha)) {
            Boolean outOfScope = relationship.HealthcareFacilityId == elsewhere;
            Assert.areEqual(outOfScope, relationship.TerminationDate == null, 'Only out-of-scope relationships are not terminated');
        }
    }

    @IsTest
    static void shouldWarn_WhenAllAndNoActiveRelationshipInScope() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(ELSEWHERE), null);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(RelationshipTestDataFactory.row(ALPHA_NPI, '', 'ALL'));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.isTrue(hasWarning(result, RosterIntakeIssues.NO_ACTIVE_RELATIONSHIP.code), 'Warns: ' + result.warnings);
    }

    @IsTest
    static void shouldFail_WhenTerminateValueUnknown() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Yes');

        RosterIntakeRow.Result result = ingest(row);

        assertError(result, RosterIntakeIssues.INVALID_TERMINATE_VALUE.code);
    }

    // ─── Provider matching ─────────────────────────────────────────────

    @IsTest
    static void shouldFail_WhenProviderUnknown() {
        RosterIntakeRow.Result result = ingest(RelationshipTestDataFactory.row(
            ProviderTestDataFactory.NPI_UNUSED, facility(MAIN).InnovAge_Unique_ID__c, ''
        ));

        assertError(result, RosterIntakeIssues.UNKNOWN_PROVIDER.code);
    }

    @IsTest
    static void shouldMatchProviderByUniqueId() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.PROVIDER_NPI_HEADER, '');
        row.put(RelationshipCsvMapping.PROVIDER_UNIQUE_ID_HEADER, provider('Beta').InnovAge_Unique_ID__c);

        RosterIntakeRow.Result result = ingest(row);

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Beta')).size(), 'Beta got the relationship');
    }

    @IsTest
    static void shouldFail_WhenProviderKeysDisagree() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.PROVIDER_UNIQUE_ID_HEADER, provider('Beta').InnovAge_Unique_ID__c);

        RosterIntakeRow.Result result = ingest(row);

        assertError(result, AccountMatchResult.Outcome.MULTIPLE_MATCHES.name());
    }

    @IsTest
    static void shouldFail_WhenProviderHasNoHealthcareProvider() {
        update new Account(Id = provider('Alpha').Id, Healthcare_Provider__c = null);

        RosterIntakeRow.Result result = ingest(createRow(MAIN));

        assertError(result, RosterIntakeIssues.PROVIDER_NOT_SET_UP.code);
    }

    // ─── Facility matching ─────────────────────────────────────────────

    @IsTest
    static void shouldFailNamingOwner_WhenFacilityOutsideScope() {
        RosterIntakeRow.Result result = ingest(createRow(ELSEWHERE));

        assertError(result, RosterIntakeIssues.FACILITY_NOT_IN_ORGANIZATION.code);
        String message = result.errors[0];
        Assert.isTrue(message.contains('"' + OTHER_ORG + '"'), 'Names the owner: ' + message);
        Assert.isTrue(message.contains('"' + ROSTER_ORG + '"'), 'Names the roster Organization: ' + message);
        Assert.areEqual(facility(ELSEWHERE).Id, result.issueValuesByField.get(Roster_Intake_Issue__c.Facility__c), 'Issue still links the facility');
    }

    @IsTest
    static void shouldFail_WhenFacilityHasNoLegalOwner() {
        RosterIntakeRow.Result result = ingest(createRow(UNOWNED));

        assertError(result, RosterIntakeIssues.FACILITY_NOT_IN_ORGANIZATION.code);
        Assert.isTrue(result.errors[0].contains('no Legal Owner'), 'Says so: ' + result.errors[0]);
    }

    @IsTest
    static void shouldFail_WhenFacilityOfParentOrganization() {
        // A roster for the sub-organization cannot touch its parent's facilities.
        RosterIntakeRow.Result result = RelationshipIntakeService.ingest(createRow(MAIN), organizationId(SUB_ORG));

        assertError(result, RosterIntakeIssues.FACILITY_NOT_IN_ORGANIZATION.code);
    }

    @IsTest
    static void shouldMatchFacilityByNpi_WhenNoUniqueId() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, OAK_NPI);

        RosterIntakeRow.Result result = ingest(row);

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(facility(OAK).Healthcare_Facility__c, RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].HealthcareFacilityId, 'Oak');
    }

    @IsTest
    static void shouldFail_WhenFacilityNpiSharedBySeveralFacilities() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, SHARED_NPI);

        RosterIntakeRow.Result result = ingest(row);

        assertError(result, RosterIntakeIssues.MULTIPLE_FACILITY_MATCHES.code);
        Assert.isTrue(result.errors[0].contains(SHARED_A) && result.errors[0].contains(SHARED_B), 'Lists them: ' + result.errors[0]);
    }

    @IsTest
    static void shouldMatchFacility_WhenUniqueIdGivenAlongsideSharedNpi() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, facility(SHARED_B).InnovAge_Unique_ID__c, '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, SHARED_NPI);

        RosterIntakeRow.Result result = ingest(row);

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'The Unique ID decides: ' + result.errors);
    }

    @IsTest
    static void shouldFail_WhenFacilityNpiFoundNowhereInScope() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, ProviderTestDataFactory.NPI_UNUSED);

        assertError(ingest(row), RosterIntakeIssues.FACILITY_NOT_FOUND.code);
    }

    @IsTest
    static void shouldMatchFacilityByAddress_WhenNoIds() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '  100  MAIN st ');

        RosterIntakeRow.Result result = ingest(row);

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'First line, whitespace, case and trailing dot ignored: ' + result.errors);
    }

    @IsTest
    static void shouldNotMatchAddressOutsideScope() {
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '300 Pine Rd');

        assertError(ingest(row), RosterIntakeIssues.FACILITY_NOT_FOUND.code);
    }

    @IsTest
    static void shouldFail_WhenAddressDisagreesWithUniqueId() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '101 Main St');

        assertError(ingest(row), RosterIntakeIssues.FACILITY_KEY_MISMATCH.code);
    }

    @IsTest
    static void shouldFail_WhenNpiDisagreesWithUniqueId() {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, OAK_NPI);

        assertError(ingest(row), RosterIntakeIssues.FACILITY_KEY_MISMATCH.code);
    }

    @IsTest
    static void shouldMatch_WhenStoredAddressAndNpiBlank() {
        // A facility missing its address or NPI is not a mismatch once its Unique ID matched.
        Account unownedButInScope = facility(UNOWNED);
        update new HealthcareFacility(Id = unownedButInScope.Healthcare_Facility__c, Legal_Owner__c = organizationId(ROSTER_ORG));
        Map<String, String> row = createRow(UNOWNED);
        row.put(RelationshipCsvMapping.FACILITY_ADDRESS_HEADER, '1 Anywhere St');
        row.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, OAK_NPI);

        RosterIntakeRow.Result result = ingest(row);

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
    }

    @IsTest
    static void shouldFail_WhenFacilityKeysMissingOrMalformed() {
        assertError(ingest(RelationshipTestDataFactory.row(ALPHA_NPI, '', '')), RosterIntakeIssues.NO_FACILITY_KEY_VALUES.code);
        assertError(ingest(RelationshipTestDataFactory.row(ALPHA_NPI, 'P000000001abc', '')), RosterIntakeIssues.MALFORMED_FACILITY_UNIQUE_ID.code);
        assertError(ingest(RelationshipTestDataFactory.row(ALPHA_NPI, 'MF999999999zzz', '')), RosterIntakeIssues.UNKNOWN_FACILITY_UNIQUE_ID.code);

        Map<String, String> badNpi = RelationshipTestDataFactory.row(ALPHA_NPI, '', '');
        badNpi.put(RelationshipCsvMapping.FACILITY_NPI_HEADER, '1234567890');
        assertError(ingest(badNpi), RosterIntakeIssues.MALFORMED_FACILITY_NPI.code);
    }

    // FACILITY_NOT_SET_UP is not tested: a validation rule stops Healthcare_Facility__c being
    // cleared, and the org's automation sets it when a facility Account is created.

    // ─── Rows in one slice ─────────────────────────────────────────────

    private static List<RosterIntakeRow.Result> ingestSlice(List<Map<String, String>> rows) {
        RosterIntakeRow.Context context = new RosterIntakeRow.Context();
        context.organizationId = organizationId(ROSTER_ORG);
        context.runDate = Date.today();
        new RelationshipIntakeService.Processor().prepare(context);

        List<RosterIntakeRow.Input> inputs = new List<RosterIntakeRow.Input>();
        for (Integer i = 0; i < rows.size(); i++) {
            inputs.add(new RosterIntakeRow.Input(i + 2, rows[i]));
        }
        return RelationshipIntakeService.ingestAll(inputs, context);
    }

    @IsTest
    static void shouldCreateOnce_WhenSameRelationshipTwiceInSlice() {
        Test.startTest();
        List<RosterIntakeRow.Result> results = ingestSlice(new List<Map<String, String>>{ createRow(MAIN), createRow(MAIN) });
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, results[0].outcome, 'First creates: ' + results[0].errors);
        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, results[1].outcome, 'Second sees it: ' + results[1].errors);
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'No duplicate');
    }

    @IsTest
    static void shouldInsertTerminated_WhenCreatedThenTerminatedInSlice() {
        Map<String, String> terminate = createRow(MAIN);
        terminate.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        List<RosterIntakeRow.Result> results = ingestSlice(new List<Map<String, String>>{ createRow(MAIN), terminate });
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, results[0].outcome, 'Errors: ' + results[0].errors);
        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, results[1].outcome, 'Errors: ' + results[1].errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(1, relationships.size(), 'One record');
        Assert.areEqual(Date.today(), relationships[0].InitialStartDate, 'Saved in its final state: started');
        Assert.areEqual(Date.today(), relationships[0].TerminationDate, 'Terminated on the run date');
    }

    @IsTest
    static void shouldInsertNew_WhenTerminatedThenCreatedInSlice() {
        HealthcarePractitionerFacility old = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> terminate = createRow(MAIN);
        terminate.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        List<RosterIntakeRow.Result> results = ingestSlice(new List<Map<String, String>>{ terminate, createRow(MAIN) });
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, results[0].outcome, 'Errors: ' + results[0].errors);
        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, results[1].outcome, 'Errors: ' + results[1].errors);
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(2, relationships.size(), 'Old and new');
        Assert.areNotEqual(old.Id, relationships[0].Id, 'Newest is the new one');
        Assert.isNull(relationships[0].TerminationDate, 'New is not ended');
        Assert.areEqual(Date.today(), relationships[1].TerminationDate, 'Old is terminated');
    }

    @IsTest
    static void shouldTerminatePendingCreates_WhenAllFollowsInSlice() {
        Test.startTest();
        List<RosterIntakeRow.Result> results = ingestSlice(new List<Map<String, String>>{
            createRow(MAIN),
            createRow(OAK),
            RelationshipTestDataFactory.row(ALPHA_NPI, '', 'All')
        });
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, results[2].outcome, 'Errors: ' + results[2].errors);
        for (HealthcarePractitionerFacility relationship : RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))) {
            Assert.areEqual(Date.today(), relationship.TerminationDate, 'Both inserted already terminated');
        }
    }

    @IsTest
    static void shouldKeepRowsIndependent_WhenOneRowFails() {
        Test.startTest();
        List<RosterIntakeRow.Result> results = ingestSlice(new List<Map<String, String>>{
            createRow(ELSEWHERE),
            createRow(MAIN)
        });
        Test.stopTest();

        assertError(results[0], RosterIntakeIssues.FACILITY_NOT_IN_ORGANIZATION.code);
        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, results[1].outcome, 'Errors: ' + results[1].errors);
    }

    // ─── Relationship fields ───────────────────────────────────────────

    private static HealthcarePractitionerFacility fieldsOf(String providerLastName) {
        return [
            SELECT Limitations__c, Scheduling_Site__c, Telemedicine_Capability__c, TerminationDate
            FROM HealthcarePractitionerFacility
            WHERE HealthcareProviderId = :provider(providerLastName).Healthcare_Provider__c
            ORDER BY CreatedDate DESC, Id DESC
            LIMIT 1
        ];
    }

    private static Map<String, String> createRowWithFields(String limitations, String url, String telemedicine) {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.LIMITATIONS_HEADER, limitations);
        row.put(RelationshipCsvMapping.SCHEDULING_URL_HEADER, url);
        row.put(RelationshipCsvMapping.TELEMEDICINE_HEADER, telemedicine);
        return row;
    }

    @IsTest
    static void shouldSetRelationshipFields_WhenCreated() {
        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRowWithFields('Adults only', 'example.com/book', 'yes'));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(0, result.warnings.size(), 'No warnings: ' + result.warnings);
        HealthcarePractitionerFacility saved = fieldsOf('Alpha');
        Assert.areEqual('Adults only', saved.Limitations__c, 'Limitations');
        Assert.areEqual('example.com/book', saved.Scheduling_Site__c, 'URL taken as given, without an http(s) prefix');
        Assert.isTrue(saved.Telemedicine_Capability__c, 'Telemedicine "yes"');
    }

    @IsTest
    static void shouldUpdateDifferingFields_WhenRelationshipActive() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);

        Test.startTest();
        RosterIntakeRow.Result first = ingest(createRowWithFields('Adults only', '', 'Yes'));
        RosterIntakeRow.Result again = ingest(createRowWithFields('Adults only', '', 'YES'));
        RosterIntakeRow.Result recased = ingest(createRowWithFields('ADULTS ONLY', '', ''));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UPDATED, first.outcome, 'Errors: ' + first.errors);
        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, again.outcome, 'Same values');
        Assert.areEqual(RosterIntakeRow.Outcome.UPDATED, recased.outcome, 'Compared exactly: a case difference is a change');
        HealthcarePractitionerFacility saved = fieldsOf('Alpha');
        Assert.areEqual('ADULTS ONLY', saved.Limitations__c, 'Overwritten');
        Assert.isTrue(saved.Telemedicine_Capability__c, 'A blank Telemedicine kept the stored value');
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'No new relationship');
    }

    @IsTest
    static void shouldWarnAndSkipValue_WhenTelemedicineNotYesOrNo() {
        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRowWithFields('Adults only', '', 'Maybe'));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Still created: ' + result.errors);
        Assert.areEqual(1, result.warnings.size(), 'One warning: ' + result.warnings);
        Assert.areEqual(RosterIntakeIssues.INVALID_VALUE.code, result.warnings[0].code, 'Code');
        Assert.areEqual(RelationshipCsvMapping.TELEMEDICINE_HEADER, result.warnings[0].column, 'Column');
        HealthcarePractitionerFacility saved = fieldsOf('Alpha');
        Assert.isFalse(saved.Telemedicine_Capability__c, 'Left at its default');
        Assert.areEqual('Adults only', saved.Limitations__c, 'Other values still set');
    }

    @IsTest
    static void shouldWarnAndSkipValue_WhenTextTooLong() {
        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRowWithFields('x'.repeat(256), '', ''));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, result.outcome, 'Still created: ' + result.errors);
        Assert.areEqual(RosterIntakeIssues.INVALID_VALUE.code, result.warnings[0].code, 'Code');
        Assert.isTrue(result.warnings[0].message.contains('longer than 255'), 'Message: ' + result.warnings[0].message);
        Assert.isNull(fieldsOf('Alpha').Limitations__c, 'Not written');
    }

    @IsTest
    static void shouldIgnoreRelationshipFields_WhenTerminating() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Map<String, String> row = createRowWithFields('Adults only', '', 'Maybe');
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(1, result.warnings.size(), 'One warning, not one per column: ' + result.warnings);
        Assert.areEqual(RosterIntakeIssues.RELATIONSHIP_COLUMNS_IGNORED.code, result.warnings[0].code, 'Code');
        Assert.areEqual(
            RelationshipCsvMapping.LIMITATIONS_HEADER + ', ' + RelationshipCsvMapping.TELEMEDICINE_HEADER,
            result.warnings[0].column,
            'Names the columns given'
        );
        Assert.isNull(fieldsOf('Alpha').Limitations__c, 'Not written');
    }

    @IsTest
    static void shouldApplyFieldsInFileOrder_WhenSameRelationshipTwiceInSlice() {
        Test.startTest();
        List<RosterIntakeRow.Result> results = ingestSlice(new List<Map<String, String>>{
            createRowWithFields('First', '', 'No'),
            createRowWithFields('Second', '', 'No')
        });
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.INSERTED, results[0].outcome, 'Errors: ' + results[0].errors);
        Assert.areEqual(RosterIntakeRow.Outcome.UPDATED, results[1].outcome, 'Changes the relationship the first row creates');
        Assert.areEqual('Second', fieldsOf('Alpha').Limitations__c, 'The last row wins');
        Assert.areEqual(1, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'One relationship');
    }

    // ─── Termination Date and Termination Notes ────────────────────────

    private static String mmddyyyy(Date value) {
        return value.month() + '/' + value.day() + '/' + value.year();
    }

    private static Map<String, String> terminateRow(String facilityName, String terminationDate, String notes) {
        Map<String, String> row = createRow(facilityName);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, 'Single');
        row.put(RelationshipCsvMapping.TERMINATION_DATE_HEADER, terminationDate);
        row.put(RelationshipCsvMapping.TERMINATION_NOTES_HEADER, notes);
        return row;
    }

    @IsTest
    static void shouldUseFileTerminationDateAndNotes_WhenGiven() {
        HealthcarePractitionerFacility existing = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        update new HealthcarePractitionerFacility(Id = existing.Id, Termination_Notes__c = 'Old notes');
        Date lastMonth = Date.today().addDays(-30);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(terminateRow(MAIN, mmddyyyy(lastMonth), 'Moved away'));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        HealthcarePractitionerFacility relationship = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0];
        Assert.areEqual(lastMonth, relationship.TerminationDate, 'The file\'s date, back-dated');
        Assert.areEqual('Moved away', relationship.Termination_Notes__c, 'Notes overwritten');
    }

    @IsTest
    static void shouldKeepNotes_WhenFileNotesBlank() {
        HealthcarePractitionerFacility existing = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        update new HealthcarePractitionerFacility(Id = existing.Id, Termination_Notes__c = 'Old notes');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(terminateRow(MAIN, '', ''));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        HealthcarePractitionerFacility relationship = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0];
        Assert.areEqual(Date.today(), relationship.TerminationDate, 'The run date when none is given');
        Assert.areEqual('Old notes', relationship.Termination_Notes__c, 'Kept');
    }

    @IsTest
    static void shouldStayExisting_WhenTerminatedWithFutureDate() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Date nextMonth = Date.today().addDays(30);

        Test.startTest();
        List<RosterIntakeRow.Result> results = ingestSlice(new List<Map<String, String>>{
            terminateRow(MAIN, mmddyyyy(nextMonth), ''),
            createRow(MAIN)
        });
        RosterIntakeRow.Result again = ingest(terminateRow(MAIN, mmddyyyy(nextMonth), ''));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, results[0].outcome, 'Errors: ' + results[0].errors);
        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, results[1].outcome, 'Still existing until then, so no new one');
        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, again.outcome, 'Same date again: nothing to change');
        List<HealthcarePractitionerFacility> relationships = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'));
        Assert.areEqual(1, relationships.size(), 'No duplicate');
        Assert.areEqual(nextMonth, relationships[0].TerminationDate, 'Scheduled end');
    }

    @IsTest
    static void shouldReplaceScheduledEnd_WhenTerminatedAgain() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), Date.today().addDays(30));

        Test.startTest();
        RosterIntakeRow.Result result = ingest(terminateRow(MAIN, '', ''));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(Date.today(), RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].TerminationDate, 'Replaced by the run date');
    }

    @IsTest
    static void shouldFail_WhenTerminationBeforeStart() {
        HealthcarePractitionerFacility future = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        update new HealthcarePractitionerFacility(Id = future.Id, InitialStartDate = Date.today().addDays(30));

        Test.startTest();
        RosterIntakeRow.Result result = ingest(terminateRow(MAIN, '', ''));
        Test.stopTest();

        assertError(result, RosterIntakeIssues.TERMINATION_BEFORE_START.code);
        Assert.isNull(RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].TerminationDate, 'Not terminated');
    }

    @IsTest
    static void shouldTerminateNothing_WhenAllAndOneWouldEndBeforeStart() {
        Account alpha = provider('Alpha');
        RelationshipTestDataFactory.createRelationship(alpha, facility(MAIN), null);
        HealthcarePractitionerFacility future = RelationshipTestDataFactory.createRelationship(alpha, facility(OAK), null);
        update new HealthcarePractitionerFacility(Id = future.Id, InitialStartDate = Date.today().addDays(30));
        Map<String, String> row = RelationshipTestDataFactory.row(ALPHA_NPI, '', 'All');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        assertError(result, RosterIntakeIssues.TERMINATION_BEFORE_START.code);
        for (HealthcarePractitionerFacility relationship : RelationshipTestDataFactory.relationshipsOf(alpha)) {
            Assert.isNull(relationship.TerminationDate, 'All or nothing');
        }
    }

    @IsTest
    static void shouldAllowTermination_WhenOnStartDate() {
        HealthcarePractitionerFacility future = RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);
        Date start = Date.today().addDays(30);
        update new HealthcarePractitionerFacility(Id = future.Id, InitialStartDate = start);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(terminateRow(MAIN, mmddyyyy(start), ''));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Ending on the start date is allowed: ' + result.errors);
    }

    @IsTest
    static void shouldFail_WhenCreateRowHasTerminationColumns() {
        Map<String, String> withDate = createRow(MAIN);
        withDate.put(RelationshipCsvMapping.TERMINATION_DATE_HEADER, '01/01/2026');
        Map<String, String> withNotes = createRow(OAK);
        withNotes.put(RelationshipCsvMapping.TERMINATION_NOTES_HEADER, 'Leaving');

        Test.startTest();
        RosterIntakeRow.Result dateResult = ingest(withDate);
        RosterIntakeRow.Result notesResult = ingest(withNotes);
        Test.stopTest();

        assertError(dateResult, RosterIntakeIssues.TERMINATION_COLUMNS_ON_CREATE_ROW.code);
        assertError(notesResult, RosterIntakeIssues.TERMINATION_COLUMNS_ON_CREATE_ROW.code);
        Assert.areEqual(0, RelationshipTestDataFactory.relationshipsOf(provider('Alpha')).size(), 'Nothing created');
    }

    @IsTest
    static void shouldFail_WhenTerminationDateInvalid() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(terminateRow(MAIN, '2026-01-01', ''));
        Test.stopTest();

        assertError(result, RosterIntakeIssues.INVALID_TERMINATION_DATE.code);
        Assert.isNull(RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].TerminationDate, 'Not terminated');
    }

    @IsTest
    static void shouldTerminateAndWarn_WhenNotesTooLong() {
        RelationshipTestDataFactory.createRelationship(provider('Alpha'), facility(MAIN), null);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(terminateRow(MAIN, '', 'x'.repeat(256)));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.TERMINATED, result.outcome, 'Still terminated: ' + result.errors);
        Assert.areEqual(RosterIntakeIssues.INVALID_VALUE.code, result.warnings[0].code, 'Code');
        Assert.areEqual(RelationshipCsvMapping.TERMINATION_NOTES_HEADER, result.warnings[0].column, 'Column');
        Assert.isNull(RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].Termination_Notes__c, 'Not written');
    }

    // ─── Start date on an existing relationship ────────────────────────

    private static HealthcarePractitionerFacility startingIn(Integer days, Date terminationDate) {
        HealthcarePractitionerFacility relationship = RelationshipTestDataFactory.createRelationship(
            provider('Alpha'), facility(MAIN), terminationDate
        );
        update new HealthcarePractitionerFacility(Id = relationship.Id, InitialStartDate = Date.today().addDays(days));
        return relationship;
    }

    private static Map<String, String> createRowStarting(Date startDate) {
        Map<String, String> row = createRow(MAIN);
        row.put(RelationshipCsvMapping.START_DATE_HEADER, mmddyyyy(startDate));
        return row;
    }

    @IsTest
    static void shouldChangeStartDate_WhenNotStartedYet() {
        startingIn(30, null);
        Date earlier = Date.today().addDays(10);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRowStarting(earlier));
        RosterIntakeRow.Result again = ingest(createRowStarting(earlier));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(0, result.warnings.size(), 'No warning: ' + result.warnings);
        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, again.outcome, 'Same date again');
        Assert.areEqual(earlier, RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].InitialStartDate, 'Moved');
    }

    @IsTest
    static void shouldChangeStartDateToPast_WhenNotStartedYet() {
        startingIn(30, null);
        Date lastWeek = Date.today().addDays(-7);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRowStarting(lastWeek));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        HealthcarePractitionerFacility relationship = RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0];
        Assert.areEqual(lastWeek, relationship.InitialStartDate, 'Back-dated');
        Assert.isTrue(relationship.Active__c, 'So now active');
    }

    @IsTest
    static void shouldKeepStartDate_WhenAlreadyStarted() {
        startingIn(-10, null);

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRowStarting(Date.today().addDays(-20)));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(RosterIntakeIssues.START_DATE_DIFFERS.code, result.warnings[0].code, 'Warns');
        Assert.areEqual(Date.today().addDays(-10), RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].InitialStartDate, 'Kept');
    }

    @IsTest
    static void shouldKeepStartDate_WhenItWouldFollowTermination() {
        startingIn(30, Date.today().addDays(60));

        Test.startTest();
        RosterIntakeRow.Result result = ingest(createRowStarting(Date.today().addDays(90)));
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UNCHANGED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(RosterIntakeIssues.START_DATE_DIFFERS.code, result.warnings[0].code, 'Warns');
        Assert.isTrue(result.warnings[0].message.contains('so it cannot start on'), 'Says why: ' + result.warnings[0].message);
        Assert.areEqual(Date.today().addDays(30), RelationshipTestDataFactory.relationshipsOf(provider('Alpha'))[0].InitialStartDate, 'Kept');
    }

    @IsTest
    static void shouldUpdateOtherFields_WhenStartDateKept() {
        startingIn(-10, null);
        Map<String, String> row = createRowStarting(Date.today().addDays(-20));
        row.put(RelationshipCsvMapping.LIMITATIONS_HEADER, 'Adults only');

        Test.startTest();
        RosterIntakeRow.Result result = ingest(row);
        Test.stopTest();

        Assert.areEqual(RosterIntakeRow.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(RosterIntakeIssues.START_DATE_DIFFERS.code, result.warnings[0].code, 'Start date warning');
        Assert.areEqual('Adults only', fieldsOf('Alpha').Limitations__c, 'Other fields still updated');
    }
}
