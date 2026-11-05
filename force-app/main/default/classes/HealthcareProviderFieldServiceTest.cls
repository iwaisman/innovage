@IsTest
private class HealthcareProviderFieldServiceTest {

    private static final String GENDER_AFFIRMING_HEADER = 'Provider Attests to Providing Gender Affirming Care?';
    private static final String GENDER_AFFIRMING_CHANGE =
        HealthcareProviderFieldService.CHANGE_PREFIX + 'Offers_Offered_Gender_Affirming_Services__c';
    private static final String LAST_NAME = 'HealthcareProviderExisting';

    @TestSetup
    static void setup() {
        RelationshipTestDataFactory.createProvider(LAST_NAME, ProviderTestDataFactory.NPI_1);
    }

    private static Account existing() {
        return [SELECT Id, Healthcare_Provider__c FROM Account WHERE LastName = :LAST_NAME];
    }

    private static String genderAffirming(Id healthcareProviderId) {
        return [
            SELECT Offers_Offered_Gender_Affirming_Services__c FROM HealthcareProvider WHERE Id = :healthcareProviderId
        ].Offers_Offered_Gender_Affirming_Services__c;
    }

    private static Map<String, String> row(String genderAffirming) {
        return new Map<String, String>{
            ProviderCsvMapping.NPI_HEADER => ProviderTestDataFactory.NPI_1,
            GENDER_AFFIRMING_HEADER => genderAffirming
        };
    }

    private static HealthcareProviderFieldService.Request request(Id accountId, String genderAffirming) {
        return new HealthcareProviderFieldService.Request(
            accountId,
            false,
            new Map<Schema.SObjectField, Object>{ HealthcareProvider.Offers_Offered_Gender_Affirming_Services__c => genderAffirming }
        );
    }

    // ─── Through ProviderIntakeService ─────────────────────────────────

    @IsTest
    static void shouldSetValue_WhenProviderInserted() {
        Map<String, String> newRow = ProviderTestDataFactory.createValidRow();
        newRow.put(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.NPI_3);
        newRow.put(GENDER_AFFIRMING_HEADER, 'yes');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(newRow);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(0, result.valueWarnings.size(), 'No warnings: ' + result.warnings);
        Id healthcareProviderId = [SELECT Healthcare_Provider__c FROM Account WHERE Id = :result.accountId].Healthcare_Provider__c;
        Assert.areEqual('Yes', genderAffirming(healthcareProviderId), 'Value takes the defined casing');
    }

    @IsTest
    static void shouldOverwriteAndReportUpdate_WhenExistingValueDiffers() {
        Account provider = existing();
        update new HealthcareProvider(Id = provider.Healthcare_Provider__c, Offers_Offered_Gender_Affirming_Services__c = 'No');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row('Yes'));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, result.outcome, 'Only the HealthcareProvider changed: ' + result.errors);
        Assert.areEqual('Yes', genderAffirming(provider.Healthcare_Provider__c), 'Overwritten');
        ProviderIntakeService.FieldChange change = result.changesByField.get(GENDER_AFFIRMING_CHANGE);
        Assert.areEqual('No', change.oldValue, 'Old value reported');
        Assert.areEqual('Yes', change.newValue, 'New value reported');
    }

    @IsTest
    static void shouldReturnUnchanged_WhenValueSameIgnoringCase() {
        Account provider = existing();
        update new HealthcareProvider(Id = provider.Healthcare_Provider__c, Offers_Offered_Gender_Affirming_Services__c = 'Yes');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row('YES'));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'Same value');
        Assert.isTrue(result.changesByField.isEmpty(), 'No changes: ' + result.changesByField);
    }

    @IsTest
    static void shouldWarnAndKeepValue_WhenValueNotAllowed() {
        Account provider = existing();
        update new HealthcareProvider(Id = provider.Healthcare_Provider__c, Offers_Offered_Gender_Affirming_Services__c = 'No');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row('Maybe'));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'The invalid value is dropped');
        Assert.areEqual(1, result.valueWarnings.size(), 'One warning: ' + result.warnings);
        Assert.areEqual(GENDER_AFFIRMING_HEADER, result.valueWarnings[0].column, 'Warning names the column');
        Assert.areEqual('No', genderAffirming(provider.Healthcare_Provider__c), 'Stored value kept');
    }

    @IsTest
    static void shouldNotClear_WhenValueBlank() {
        Account provider = existing();
        update new HealthcareProvider(Id = provider.Healthcare_Provider__c, Offers_Offered_Gender_Affirming_Services__c = 'Yes');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row(' '));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'Blank changes nothing');
        Assert.areEqual('Yes', genderAffirming(provider.Healthcare_Provider__c), 'Stored value kept');
    }

    // ─── apply() ───────────────────────────────────────────────────────

    @IsTest
    static void shouldWarn_WhenProviderHasNoHealthcareProvider() {
        Account provider = ProviderTestDataFactory.createProvider('NoHealthcareProvider', ProviderTestDataFactory.NPI_2, true);
        // The org's automation may create one; this test needs a Provider without it.
        update new Account(Id = provider.Id, Healthcare_Provider__c = null);
        HealthcareProviderFieldService.Request request = request(provider.Id, 'Yes');

        Test.startTest();
        HealthcareProviderFieldService.apply(new List<HealthcareProviderFieldService.Request>{ request });
        Test.stopTest();

        Assert.areEqual(1, request.outcome.warnings.size(), 'One warning');
        Assert.areEqual(
            HealthcareProviderFieldService.HEALTHCARE_PROVIDER_NOT_SAVED,
            request.outcome.warnings[0].code,
            'Not-saved code'
        );
        Assert.isTrue(request.outcome.warnings[0].message.contains(GENDER_AFFIRMING_HEADER), 'Message names the column');
        Assert.isTrue(request.outcome.changesByLabel.isEmpty(), 'Nothing changed');
    }

    @IsTest
    static void shouldApplyRowsInOrder_WhenSameProviderTwice() {
        Account provider = existing();
        HealthcareProviderFieldService.Request first = request(provider.Id, 'Yes');
        HealthcareProviderFieldService.Request second = request(provider.Id, 'No');
        HealthcareProviderFieldService.Request repeat = request(provider.Id, 'No');

        Test.startTest();
        HealthcareProviderFieldService.apply(new List<HealthcareProviderFieldService.Request>{ first, second, repeat });
        Test.stopTest();

        Assert.areEqual('No', genderAffirming(provider.Healthcare_Provider__c), 'The last row wins');
        Assert.areEqual('Yes', first.outcome.changesByLabel.get(GENDER_AFFIRMING_CHANGE).newValue, 'First row set Yes');
        Assert.areEqual('Yes', second.outcome.changesByLabel.get(GENDER_AFFIRMING_CHANGE).oldValue, 'Second row compared with the first');
        Assert.isTrue(repeat.outcome.changesByLabel.isEmpty(), 'A repeat of the previous row changes nothing');
    }

    @IsTest
    static void shouldDoNothing_WhenRowNotSaved() {
        HealthcareProviderFieldService.Request request = request(null, 'Yes');

        Test.startTest();
        HealthcareProviderFieldService.apply(new List<HealthcareProviderFieldService.Request>{ request });
        Integer queries = Limits.getQueries();
        Test.stopTest();

        Assert.areEqual(0, queries, 'No queries for rows that were not saved');
        Assert.isTrue(request.outcome.warnings.isEmpty(), 'No warnings');
    }

    @IsTest
    static void shouldThrow_WhenRequestsNull() {
        try {
            HealthcareProviderFieldService.apply(null);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('cannot be null'), 'Message: ' + e.getMessage());
        }
    }
}
