@IsTest
private class ProviderIngestionServiceTest {

    private static final String EXISTING = 'IngestExisting';
    private static final String WITHOUT_NPI = 'IngestWithoutNpi';

    @TestSetup
    static void setup() {
        ProviderTestDataFactory.createProviders(
            new List<String>{ EXISTING, WITHOUT_NPI },
            new List<String>{ ProviderTestDataFactory.NPI_1, null },
            true
        );
    }

    private static Account reload(Id accountId) {
        return [
            SELECT Id, RecordTypeId, IsPersonAccount, FirstName, LastName, NPI__c, Phone, PersonEmail,
                PersonBirthdate, PersonMailingStreet, PersonMailingState, InnovAge_Unique_ID__c
            FROM Account
            WHERE Id = :accountId
        ];
    }

    private static Account existing(String lastName) {
        return reload([SELECT Id FROM Account WHERE LastName = :lastName].Id);
    }

    private static Map<String, String> rowWithNpi(String npi) {
        return new Map<String, String>{ ProviderCsvMapping.NPI_HEADER => npi };
    }

    // ─── Insert ────────────────────────────────────────────────────────

    @IsTest
    static void shouldInsertProvider_WhenNoMatch() {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        row.put(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.NPI_3);

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(AccountMatchResult.Outcome.NO_MATCH, result.matchOutcome, 'No Provider had the NPI');

        Account inserted = reload(result.accountId);
        Assert.areEqual(ProviderMatcher.getProviderRecordTypeId(), inserted.RecordTypeId, 'Provider record type');
        Assert.isTrue(inserted.IsPersonAccount, 'Providers are person accounts');
        Assert.areEqual('Ingested', inserted.LastName, 'Last name from the row');
        Assert.areEqual(ProviderTestDataFactory.NPI_3, inserted.NPI__c, 'NPI from the row');
        Assert.areEqual('(303) 555-0142', inserted.Phone, 'Normalized phone');
        Assert.areEqual(Date.newInstance(1980, 4, 17), inserted.PersonBirthdate, 'DOB from the row');
        Assert.areEqual('100 Main St\nSuite 200', inserted.PersonMailingStreet, 'Joined mailing street');
    }

    @IsTest
    static void shouldReturnError_WhenInsertHasNoLastName() {
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_3);
        row.put('First Name', 'Nameless');

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.ERROR, result.outcome, 'Last Name is required to insert');
        Assert.isTrue(result.errors[0].contains('Last Name'), 'Error explains the missing Last Name');
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE NPI__c = :ProviderTestDataFactory.NPI_3], 'Nothing inserted');
    }

    // ─── Update ────────────────────────────────────────────────────────

    @IsTest
    static void shouldUpdatePhoneAndEmail_WhenMatchedByNpi() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Provider Phone', '720-555-0199');
        row.put('Provider Email', 'new.address@example.com');

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(new Set<String>{ 'Phone', 'PersonEmail' }, result.changesByField.keySet(), 'Only the changed fields');
        Assert.areEqual(before.Phone, result.changesByField.get('Phone').oldValue, 'Reports the previous phone');

        Account after = reload(before.Id);
        Assert.areEqual('(720) 555-0199', after.Phone, 'Phone updated');
        Assert.areEqual('new.address@example.com', after.PersonEmail, 'Email updated');
    }

    @IsTest
    static void shouldReturnUnchanged_WhenValuesDifferOnlyInFormat() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Provider Phone', before.Phone.replaceAll('[^0-9]', ''));
        row.put('Provider Email', before.PersonEmail.toUpperCase());

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UNCHANGED, result.outcome, 'Changes: ' + result.changesByField);
        Assert.areEqual(before.Id, result.accountId, 'Reports the matched Provider');
    }

    @IsTest
    static void shouldNotOverwrite_WhenIncomingValuesBlankOrInvalid() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Provider Phone', '');
        row.put('Provider Email', 'not-an-email');

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UNCHANGED, result.outcome, 'Nothing valid to change');
        Assert.areEqual(1, result.warnings.size(), 'The invalid email is reported: ' + result.warnings);

        Account after = reload(before.Id);
        Assert.areEqual(before.Phone, after.Phone, 'Blank phone did not clear the stored phone');
        Assert.areEqual(before.PersonEmail, after.PersonEmail, 'Invalid email did not replace the stored email');
    }

    @IsTest
    static void shouldNotUpdateInsertOnlyFields() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('First Name', 'Renamed');
        row.put('Last Name', 'Renamed');

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UNCHANGED, result.outcome, 'Names are insert-only');
        Assert.areEqual(before.LastName, reload(before.Id).LastName, 'Last name unchanged');
    }

    @IsTest
    static void shouldFillBlankNpi_WhenMatchedByUniqueId() {
        Account before = existing(WITHOUT_NPI);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_3);
        row.put(ProviderCsvMapping.UNIQUE_ID_HEADER, before.InnovAge_Unique_ID__c);

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(ProviderTestDataFactory.NPI_3, reload(before.Id).NPI__c, 'Blank NPI filled in');
    }

    // ─── Errors ────────────────────────────────────────────────────────

    @IsTest
    static void shouldReturnError_WhenMatchIsError() {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.ERROR, result.outcome, 'A row without keys is not ingested');
        Assert.areEqual(AccountMatchResult.Outcome.NO_KEY_VALUES, result.matchOutcome, 'Reports why');
        Assert.areEqual(1, result.errors.size(), 'Carries the matcher message');
        Assert.areEqual(accountsBefore, [SELECT COUNT() FROM Account], 'Nothing inserted');
    }

    @IsTest
    static void shouldReturnError_WhenUniqueIdUnknownEvenIfNpiMatches() {
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put(ProviderCsvMapping.UNIQUE_ID_HEADER, 'P999999999zzz');

        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.ERROR, result.outcome, 'Unknown Unique ID is an error');
        Assert.areEqual(AccountMatchResult.Outcome.UNKNOWN_UNIQUE_ID, result.matchOutcome, 'Reports why');
    }

    @IsTest
    static void shouldThrow_WhenRowNull() {
        Test.startTest();
        try {
            ProviderIngestionService.ingest(null);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('null'), 'Message explains the null row');
        }
        Test.stopTest();
    }

    // ─── Bulk (ingestAll) ──────────────────────────────────────────────

    private static ProviderIngestionService.RowInput newProviderRow(Integer rowNumber, String npi) {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        row.put(ProviderCsvMapping.NPI_HEADER, npi);
        row.put('Last Name', 'Bulk' + rowNumber);
        return new ProviderIngestionService.RowInput(rowNumber, row);
    }

    private static List<ProviderIngestionService.IngestResult> ingestAll(
        List<ProviderIngestionService.RowInput> rows,
        Boolean dryRun
    ) {
        return ProviderIngestionService.ingestAll(rows, new ProviderIngestionService.DuplicateTracker(), dryRun);
    }

    @IsTest
    static void shouldInsertAndUpdateInBulk_WhenManyRows() {
        List<ProviderIngestionService.RowInput> rows = new List<ProviderIngestionService.RowInput>();
        for (Integer i = 0; i < 251; i++) {
            rows.add(newProviderRow(i + 2, ProviderTestDataFactory.npi(i)));
        }
        Map<String, String> updateRow = rowWithNpi(ProviderTestDataFactory.NPI_1);
        updateRow.put('Provider Phone', '720-555-0177');
        rows.add(new ProviderIngestionService.RowInput(253, updateRow));

        Test.startTest();
        List<ProviderIngestionService.IngestResult> results = ingestAll(rows, false);
        Test.stopTest();

        Assert.areEqual(252, results.size(), 'One result per row');
        for (Integer i = 0; i < 251; i++) {
            Assert.areEqual(ProviderIngestionService.Outcome.INSERTED, results[i].outcome, 'Row ' + results[i].rowNumber + ': ' + results[i].errors);
        }
        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, results[251].outcome, 'Existing Provider updated: ' + results[251].errors);
        Assert.areEqual(253, results[251].rowNumber, 'Results keep their row numbers');
        Assert.areEqual(251, [SELECT COUNT() FROM Account WHERE LastName LIKE 'Bulk%'], 'All new Providers inserted');
        Assert.areEqual('(720) 555-0177', existing(EXISTING).Phone, 'Phone updated');
    }

    @IsTest
    static void shouldRejectLaterRow_WhenNpiRepeatsInFile() {
        String npi = ProviderTestDataFactory.npi(1);
        List<ProviderIngestionService.RowInput> rows = new List<ProviderIngestionService.RowInput>{
            newProviderRow(2, npi),
            newProviderRow(3, npi)
        };

        Test.startTest();
        List<ProviderIngestionService.IngestResult> results = ingestAll(rows, false);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.INSERTED, results[0].outcome, 'First occurrence wins: ' + results[0].errors);
        Assert.areEqual(ProviderIngestionService.Outcome.ERROR, results[1].outcome, 'Later occurrence is an error');
        Assert.areEqual(ProviderIngestionService.DUPLICATE_IN_FILE, results[1].errorCode, 'Reported as a duplicate');
        Assert.isTrue(results[1].errors[0].contains('Row 2'), 'Names the first row: ' + results[1].errors);
    }

    @IsTest
    static void shouldRejectLaterRow_WhenDifferentKeysMatchSameProvider() {
        Account provider = existing(EXISTING);
        Map<String, String> byUniqueId = new Map<String, String>{ ProviderCsvMapping.UNIQUE_ID_HEADER => provider.InnovAge_Unique_ID__c };
        List<ProviderIngestionService.RowInput> rows = new List<ProviderIngestionService.RowInput>{
            new ProviderIngestionService.RowInput(2, byUniqueId),
            new ProviderIngestionService.RowInput(3, rowWithNpi(ProviderTestDataFactory.NPI_1))
        };

        Test.startTest();
        List<ProviderIngestionService.IngestResult> results = ingestAll(rows, false);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.UNCHANGED, results[0].outcome, 'First row matches the Provider');
        Assert.areEqual(ProviderIngestionService.DUPLICATE_IN_FILE, results[1].errorCode, 'Second row matches the same Provider');
        Assert.areEqual(provider.Id, results[1].accountId, 'Reports which Provider');
    }

    @IsTest
    static void shouldRejectRow_WhenEarlierCallWithSameTrackerClaimedKey() {
        ProviderIngestionService.DuplicateTracker tracker = new ProviderIngestionService.DuplicateTracker();
        String npi = ProviderTestDataFactory.npi(2);
        ProviderIngestionService.ingestAll(new List<ProviderIngestionService.RowInput>{ newProviderRow(2, npi) }, tracker, false);

        Test.startTest();
        List<ProviderIngestionService.IngestResult> results = ProviderIngestionService.ingestAll(
            new List<ProviderIngestionService.RowInput>{ newProviderRow(900, npi) },
            tracker,
            false
        );
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.DUPLICATE_IN_FILE, results[0].errorCode, 'The tracker spans calls (chunks)');
    }

    @IsTest
    static void shouldNotClaimKeys_WhenTrackerCopied() {
        ProviderIngestionService.DuplicateTracker tracker = new ProviderIngestionService.DuplicateTracker();
        ProviderIngestionService.DuplicateTracker snapshot = tracker.copy();
        String npi = ProviderTestDataFactory.npi(3);
        ProviderIngestionService.ingestAll(new List<ProviderIngestionService.RowInput>{ newProviderRow(2, npi) }, tracker, true);

        Test.startTest();
        List<ProviderIngestionService.IngestResult> results = ProviderIngestionService.ingestAll(
            new List<ProviderIngestionService.RowInput>{ newProviderRow(2, npi) },
            snapshot,
            true
        );
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.INSERTED, results[0].outcome, 'The copy did not see the later claim');
    }

    @IsTest
    static void shouldRollBackProviders_WhenDryRun() {
        Map<String, String> updateRow = rowWithNpi(ProviderTestDataFactory.NPI_1);
        updateRow.put('Provider Phone', '720-555-0188');
        List<ProviderIngestionService.RowInput> rows = new List<ProviderIngestionService.RowInput>{
            newProviderRow(2, ProviderTestDataFactory.NPI_3),
            new ProviderIngestionService.RowInput(3, updateRow)
        };
        String phoneBefore = existing(EXISTING).Phone;

        Test.startTest();
        List<ProviderIngestionService.IngestResult> results = ingestAll(rows, true);
        Test.stopTest();

        Assert.areEqual(ProviderIngestionService.Outcome.INSERTED, results[0].outcome, 'Reports the would-be insert: ' + results[0].errors);
        Assert.isNull(results[0].accountId, 'A rolled-back insert has no Provider');
        Assert.areEqual(ProviderIngestionService.Outcome.UPDATED, results[1].outcome, 'Reports the would-be update');
        Assert.areEqual(1, results[1].changesByField.size(), 'Reports the would-be change');
        Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE NPI__c = :ProviderTestDataFactory.NPI_3], 'Insert rolled back');
        Assert.areEqual(phoneBefore, existing(EXISTING).Phone, 'Update rolled back');
    }

    @IsTest
    static void shouldReportWarningColumn_WhenValueInvalid() {
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Provider Email', 'not-an-email');

        Test.startTest();
        List<ProviderIngestionService.IngestResult> results = ingestAll(
            new List<ProviderIngestionService.RowInput>{ new ProviderIngestionService.RowInput(2, row) },
            false
        );
        Test.stopTest();

        Assert.areEqual(1, results[0].valueWarnings.size(), 'One structured warning');
        Assert.areEqual('Provider Email', results[0].valueWarnings[0].column, 'Names the column');
        Assert.isFalse(results[0].valueWarnings[0].message.contains('not-an-email'), 'Never echoes the value');
    }

    @IsTest
    static void shouldThrow_WhenTrackerNull() {
        Test.startTest();
        try {
            ProviderIngestionService.ingestAll(new List<ProviderIngestionService.RowInput>(), null, false);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('null'), 'Message explains the null argument');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldReportMalformedNpiOnce_WhenNpiInvalid() {
        Test.startTest();
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(rowWithNpi('1234567890'));
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.MALFORMED_NPI.name(), result.errorCode, 'Reported as an error');
        Assert.areEqual(0, result.valueWarnings.size(), 'Not repeated as a warning: ' + result.warnings);
        Assert.areEqual(0, result.warnings.size(), 'Plain warnings stay in step');
    }
}
