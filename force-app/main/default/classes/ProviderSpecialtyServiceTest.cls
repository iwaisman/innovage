@IsTest
private class ProviderSpecialtyServiceTest {

    private static final String FAMILY = '207Q00000X';
    private static final String INTERNAL = '207R00000X';
    private static final String GERIATRIC = '207QG0300X';
    private static final String DUPLICATED = '390200000X';
    private static final String LAST_NAME = 'SpecialtyExisting';

    @TestSetup
    static void setup() {
        insert new List<verifiable__VfiNUCCTaxonomy__c>{
            taxonomy('Family Medicine Physician', FAMILY, 'v1'),
            taxonomy('Internal Medicine Physician', INTERNAL, 'v2'),
            taxonomy('Geriatric Medicine (Family Medicine) Physician', GERIATRIC, 'v3'),
            // The code is not unique in the schema; two records share this one.
            taxonomy('Student A', DUPLICATED, 'v4'),
            taxonomy('Student B', DUPLICATED, 'v5')
        };
        RelationshipTestDataFactory.createProvider(LAST_NAME, ProviderTestDataFactory.NPI_1);
    }

    private static verifiable__VfiNUCCTaxonomy__c taxonomy(String name, String code, String vuid) {
        return new verifiable__VfiNUCCTaxonomy__c(Name = name, verifiable__TaxonomyCode__c = code, verifiable__Vuid__c = vuid);
    }

    private static Id taxonomyId(String code) {
        return [SELECT Id FROM verifiable__VfiNUCCTaxonomy__c WHERE verifiable__TaxonomyCode__c = :code LIMIT 1].Id;
    }

    private static Account existing() {
        return [SELECT Id, Healthcare_Provider__c FROM Account WHERE LastName = :LAST_NAME];
    }

    private static Map<String, String> row(String primary, String secondary) {
        return new Map<String, String>{
            ProviderCsvMapping.NPI_HEADER => ProviderTestDataFactory.NPI_1,
            ProviderCsvMapping.PRIMARY_SPECIALTY_HEADER => primary,
            ProviderCsvMapping.SECONDARY_SPECIALTY_HEADER => secondary
        };
    }

    /* The Provider's links by code. */
    private static Map<String, HealthcareProviderTaxonomy> links(Id healthcareProviderId) {
        Map<String, HealthcareProviderTaxonomy> byCode = new Map<String, HealthcareProviderTaxonomy>();
        for (HealthcareProviderTaxonomy link : [
            SELECT Name, Taxonomy_Code__c, NUCC_Taxonomy__c, IsPrimaryTaxonomy, IsActive, AccountId
            FROM HealthcareProviderTaxonomy
            WHERE HealthcareProviderId = :healthcareProviderId
        ]) {
            byCode.put(link.Taxonomy_Code__c, link);
        }
        return byCode;
    }

    private static void link(String code, Boolean primary) {
        insert new HealthcareProviderTaxonomy(
            Name = code,
            HealthcareProviderId = existing().Healthcare_Provider__c,
            NUCC_Taxonomy__c = taxonomyId(code),
            Taxonomy_Code__c = code,
            IsActive = true,
            IsPrimaryTaxonomy = primary
        );
    }

    private static Boolean hasWarning(ProviderIngestionService.IngestResult result, String code) {
        for (ProviderCsvMapping.ValueWarning warning : result.valueWarnings) {
            if (warning.code == code) {
                return true;
            }
        }
        return false;
    }

    // ─── New Providers ─────────────────────────────────────────────────

    @IsTest
    static void shouldLinkBothSpecialties_WhenProviderInserted() {
        Map<String, String> newRow = ProviderTestDataFactory.createValidRow();
        newRow.put(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.NPI_3);
        newRow.put(ProviderCsvMapping.PRIMARY_SPECIALTY_HEADER, 'Family Medicine Physician:' + FAMILY);
        newRow.put(ProviderCsvMapping.SECONDARY_SPECIALTY_HEADER, 'Internal Medicine Physician:' + INTERNAL);

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(newRow);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Id healthcareProviderId = [SELECT Healthcare_Provider__c FROM Account WHERE Id = :result.accountId].Healthcare_Provider__c;
        Map<String, HealthcareProviderTaxonomy> byCode = links(healthcareProviderId);
        Assert.areEqual(new Set<String>{ FAMILY, INTERNAL }, byCode.keySet(), 'Both specialties linked');

        HealthcareProviderTaxonomy primary = byCode.get(FAMILY);
        Assert.isTrue(primary.IsPrimaryTaxonomy, 'Primary is marked');
        Assert.isTrue(primary.IsActive, 'Active (defaults to false)');
        Assert.areEqual(taxonomyId(FAMILY), primary.NUCC_Taxonomy__c, 'Linked by record Id');
        Assert.areEqual('Family Medicine Physician', primary.Name, 'Named after the taxonomy');
        Assert.isNull(primary.AccountId, 'AccountId left blank');
        Assert.isFalse(byCode.get(INTERNAL).IsPrimaryTaxonomy, 'Secondary is not primary');
    }

    // ─── Existing Providers ────────────────────────────────────────────

    @IsTest
    static void shouldLinkPrimaryAndReportUpdate_WhenExistingProviderHasNone() {
        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row('Family:' + FAMILY, ''));
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, result.outcome, 'A specialty change is an update');
        Assert.isTrue(result.changesByField.containsKey(ProviderSpecialtyService.PRIMARY_SPECIALTY), 'Reported as a change');
        Assert.isTrue(links(existing().Healthcare_Provider__c).get(FAMILY).IsPrimaryTaxonomy, 'Linked as primary');
    }

    @IsTest
    static void shouldBeUnchanged_WhenPrimaryAlreadyPrimary() {
        link(FAMILY, true);

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row('Family:' + FAMILY, ''));
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UNCHANGED, result.outcome, 'Changes: ' + result.changesByField);
        Assert.areEqual(1, links(existing().Healthcare_Provider__c).size(), 'No duplicate link');
    }

    @IsTest
    static void shouldKeepOldPrimaryUnmarked_WhenPrimaryChanges() {
        link(FAMILY, true);

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row('Internal:' + INTERNAL, ''));
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(FAMILY, result.changesByField.get(ProviderSpecialtyService.PRIMARY_SPECIALTY).oldValue, 'Reports the previous primary');
        Map<String, HealthcareProviderTaxonomy> byCode = links(existing().Healthcare_Provider__c);
        Assert.isFalse(byCode.get(FAMILY).IsPrimaryTaxonomy, 'Old primary stays linked, unmarked');
        Assert.isTrue(byCode.get(INTERNAL).IsPrimaryTaxonomy, 'New primary');
    }

    @IsTest
    static void shouldPromoteExistingSecondary_WhenItBecomesPrimary() {
        link(FAMILY, true);
        link(INTERNAL, false);

        Test.startTest();
        ProviderIngestionService.ingest(row(INTERNAL, ''));
        Test.stopTest();

        Map<String, HealthcareProviderTaxonomy> byCode = links(existing().Healthcare_Provider__c);
        Assert.areEqual(2, byCode.size(), 'No duplicate link');
        Assert.isTrue(byCode.get(INTERNAL).IsPrimaryTaxonomy, 'Promoted');
        Assert.isFalse(byCode.get(FAMILY).IsPrimaryTaxonomy, 'Old primary unmarked');
    }

    @IsTest
    static void shouldAddSecondaryOnly_WhenPrimaryBlank() {
        link(FAMILY, true);

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row('', 'Geriatric:' + GERIATRIC));
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Map<String, HealthcareProviderTaxonomy> byCode = links(existing().Healthcare_Provider__c);
        Assert.isTrue(byCode.get(FAMILY).IsPrimaryTaxonomy, 'Primary untouched');
        Assert.isFalse(byCode.get(GERIATRIC).IsPrimaryTaxonomy, 'Secondary added, not primary');
    }

    @IsTest
    static void shouldNotDemote_WhenSecondaryIsCurrentPrimary() {
        link(FAMILY, true);

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row('', FAMILY));
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UNCHANGED, result.outcome, 'Changes: ' + result.changesByField);
        Assert.isTrue(links(existing().Healthcare_Provider__c).get(FAMILY).IsPrimaryTaxonomy, 'Still primary');
    }

    @IsTest
    static void shouldLinkOnce_WhenSecondaryEqualsPrimary() {
        Test.startTest();
        ProviderIngestionService.ingest(row('A:' + FAMILY, 'B:' + FAMILY));
        Test.stopTest();

        Map<String, HealthcareProviderTaxonomy> byCode = links(existing().Healthcare_Provider__c);
        Assert.areEqual(1, byCode.size(), 'One link');
        Assert.isTrue(byCode.get(FAMILY).IsPrimaryTaxonomy, 'As primary');
    }

    @IsTest
    static void shouldRefillLookup_WhenLinkLostItAfterTaxonomyReload() {
        link(FAMILY, true);
        HealthcareProviderTaxonomy orphan = [SELECT Id FROM HealthcareProviderTaxonomy LIMIT 1];
        update new HealthcareProviderTaxonomy(Id = orphan.Id, NUCC_Taxonomy__c = null); // as SetNull leaves it

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row(FAMILY, ''));
        Test.stopTest();

        Map<String, HealthcareProviderTaxonomy> byCode = links(existing().Healthcare_Provider__c);
        Assert.areEqual(1, byCode.size(), 'Found by code: no second link');
        Assert.areEqual(taxonomyId(FAMILY), byCode.get(FAMILY).NUCC_Taxonomy__c, 'Lookup refilled');
        Assert.areEqual(ProviderIngestionService.Outcome.UNCHANGED, result.outcome, 'A repair is not a reported change');
    }

    // ─── Values that cannot be used ────────────────────────────────────

    @IsTest
    static void shouldWarnAndStillUpdate_WhenCodeUnknown() {
        Map<String, String> unknown = row('Nope:999999999X', '');
        unknown.put('Provider Phone', '720-555-0177');

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(unknown);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, result.outcome, 'The rest of the row is ingested');
        Assert.isTrue(hasWarning(result, ProviderSpecialtyService.UNKNOWN_SPECIALTY), 'Warns: ' + result.warnings);
        Assert.isTrue(links(existing().Healthcare_Provider__c).isEmpty(), 'Nothing linked');
    }

    @IsTest
    static void shouldWarn_WhenValueHasNoCode() {
        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row('Cardiology:', ''));
        Test.stopTest();

        Assert.isTrue(hasWarning(result, ProviderSpecialtyService.UNKNOWN_SPECIALTY), 'Warns: ' + result.warnings);
    }

    @IsTest
    static void shouldWarn_WhenCodeAmbiguous() {
        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row('Student:' + DUPLICATED, ''));
        Test.stopTest();

        Assert.isTrue(hasWarning(result, ProviderSpecialtyService.AMBIGUOUS_SPECIALTY), 'Warns: ' + result.warnings);
        Assert.isTrue(links(existing().Healthcare_Provider__c).isEmpty(), 'Nothing linked');
    }

    @IsTest
    static void shouldCarryWarningCodeIntoBatchResult() {
        ProviderIngestionService.Processor processor = new ProviderIngestionService.Processor();

        Test.startTest();
        RosterIngestionRow.Result result = processor.ingestAll(
            new List<RosterIngestionRow.Input>{ new RosterIngestionRow.Input(2, row('X:999999999X', '')) },
            new RosterIngestionRow.Context()
        )[0];
        Test.stopTest();

        Assert.areEqual(ProviderSpecialtyService.UNKNOWN_SPECIALTY, result.warnings[0].code, 'Issue gets the specialty code, not INVALID_VALUE');
        Assert.areEqual(ProviderCsvMapping.PRIMARY_SPECIALTY_HEADER, result.warnings[0].column, 'Names the column');
    }

    // ─── Rows in one slice ─────────────────────────────────────────────

    @IsTest
    static void shouldApplyRowsInOrder_WhenSameProviderTwiceInSlice() {
        Test.startTest();
        ProviderIngestionService.ingestAll(new List<ProviderIngestionService.RowInput>{
            new ProviderIngestionService.RowInput(2, row(FAMILY, '')),
            new ProviderIngestionService.RowInput(3, row(INTERNAL, FAMILY))
        });
        Test.stopTest();

        Map<String, HealthcareProviderTaxonomy> byCode = links(existing().Healthcare_Provider__c);
        Assert.areEqual(2, byCode.size(), 'No duplicate links: ' + byCode.keySet());
        Assert.isTrue(byCode.get(INTERNAL).IsPrimaryTaxonomy, 'The last row\'s primary wins');
        Assert.isFalse(byCode.get(FAMILY).IsPrimaryTaxonomy, 'The first row\'s primary is unmarked');
    }

    @IsTest
    static void shouldSkipSpecialties_WhenRowErrors() {
        Map<String, String> bad = row(FAMILY, '');
        bad.put(ProviderCsvMapping.NPI_HEADER, '1234567890'); // bad check digit

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(bad);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.ERROR, result.outcome, 'Malformed NPI');
        Assert.isTrue(links(existing().Healthcare_Provider__c).isEmpty(), 'Nothing linked');
    }
}
