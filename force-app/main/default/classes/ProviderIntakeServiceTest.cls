@IsTest
private class ProviderIntakeServiceTest {

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
                PersonBirthdate, PersonMailingStreet, PersonMailingState, InnovAge_Unique_ID__c, CAQH_ID__pc
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
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(AccountMatchResult.Outcome.NO_MATCH, result.matchOutcome, 'No Provider had the NPI');

        Account inserted = reload(result.accountId);
        Assert.areEqual(ProviderMatcher.getProviderRecordTypeId(), inserted.RecordTypeId, 'Provider record type');
        Assert.isTrue(inserted.IsPersonAccount, 'Providers are person accounts');
        Assert.areEqual('Ingested', inserted.LastName, 'Last name from the row');
        Assert.areEqual(ProviderTestDataFactory.NPI_3, inserted.NPI__c, 'NPI from the row');
        Assert.areEqual('(303) 555-0142', inserted.Phone, 'Normalized phone');
        Assert.areEqual(Date.newInstance(1980, 4, 17), inserted.PersonBirthdate, 'DOB from the row');
        Assert.areEqual('100 Main St\nSuite 200', inserted.PersonMailingStreet, 'Joined mailing street');
        Assert.areEqual('12345678', inserted.CAQH_ID__pc, 'CAQH ID from the row');
    }

    @IsTest
    static void shouldReturnError_WhenInsertHasNoLastName() {
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_3);
        row.put('First Name', 'Nameless');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.ERROR, result.outcome, 'Last Name is required to insert');
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
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(new Set<String>{ 'Phone', 'PersonEmail' }, result.changesByField.keySet(), 'Only the changed fields');
        Assert.areEqual(before.Phone, result.changesByField.get('Phone').oldValue, 'Reports the previous phone');

        Account after = reload(before.Id);
        Assert.areEqual('(720) 555-0199', after.Phone, 'Phone updated');
        Assert.areEqual('new.address@example.com', after.PersonEmail, 'Email updated');
    }

    @IsTest
    static void shouldUpdateCredentialingDates_WhenMatchedByNpi() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Initial Credentialing Date', '03/01/2020');
        row.put('Last Credentialing Date', '03/01/2023');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(
            new Set<String>{ 'Initial_Credentialing_Approval__pc', 'Last_Credentialing_Approval_Date__pc' },
            result.changesByField.keySet(),
            'Both dates changed'
        );

        Account after = [
            SELECT Initial_Credentialing_Approval__pc, Last_Credentialing_Approval_Date__pc FROM Account WHERE Id = :before.Id
        ];
        Assert.areEqual(Date.newInstance(2020, 3, 1), after.Initial_Credentialing_Approval__pc, 'Initial date saved');
        Assert.areEqual(Date.newInstance(2023, 3, 1), after.Last_Credentialing_Approval_Date__pc, 'Last date saved');
    }

    @IsTest
    static void shouldReturnUnchanged_WhenValuesDifferOnlyInFormat() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Provider Phone', before.Phone.replaceAll('[^0-9]', ''));
        row.put('Provider Email', before.PersonEmail.toUpperCase());

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'Changes: ' + result.changesByField);
        Assert.areEqual(before.Id, result.accountId, 'Reports the matched Provider');
    }

    @IsTest
    static void shouldNotOverwrite_WhenIncomingValuesBlankOrInvalid() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Provider Phone', '');
        row.put('Provider Email', 'not-an-email');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'Nothing valid to change');
        Assert.areEqual(1, result.warnings.size(), 'The invalid email is reported: ' + result.warnings);

        Account after = reload(before.Id);
        Assert.areEqual(before.Phone, after.Phone, 'Blank phone did not clear the stored phone');
        Assert.areEqual(before.PersonEmail, after.PersonEmail, 'Invalid email did not replace the stored email');
    }

    // ─── Addresses on update ───────────────────────────────────────────

    private static final String MAILING_LINE_1 = 'Provider Mailing Address Line 1';
    private static final String MAILING_LINE_2 = 'Provider Mailing Address Line 2';
    private static final String MAILING_CITY = 'Provider Mailing City';
    private static final String MAILING_STATE = 'Provider Mailing State';
    private static final String MAILING_ZIP = 'Provider Mailing Zip';

    /* Gives the existing Provider the mailing address 100 Main St / Suite 200, Denver, CO 80202. */
    private static Account existingWithMailingAddress() {
        Account provider = existing(EXISTING);
        update new Account(
            Id = provider.Id,
            PersonMailingStreet = '100 Main St\nSuite 200',
            PersonMailingCity = 'Denver',
            PersonMailingState = 'CO',
            PersonMailingPostalCode = '80202'
        );
        return provider;
    }

    private static Account mailingAddress(Id accountId) {
        return [
            SELECT PersonMailingStreet, PersonMailingCity, PersonMailingState, PersonMailingPostalCode, Phone
            FROM Account
            WHERE Id = :accountId
        ];
    }

    private static Map<String, String> mailingRow(String line1, String line2, String city, String state, String zip) {
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put(MAILING_LINE_1, line1);
        row.put(MAILING_LINE_2, line2);
        row.put(MAILING_CITY, city);
        row.put(MAILING_STATE, state);
        row.put(MAILING_ZIP, zip);
        return row;
    }

    private static void assertAddressNotUpdated(ProviderIntakeService.IngestResult result, Id accountId, String expectedMessage) {
        Assert.areEqual(1, result.warnings.size(), 'One warning for the address: ' + result.warnings);
        Assert.areEqual(RosterIntakeIssues.ADDRESS_NOT_UPDATED.code, result.warnings[0].code, 'Address code');
        Assert.areEqual(expectedMessage, result.warnings[0].message, 'Message');

        Account after = mailingAddress(accountId);
        Assert.areEqual('100 Main St\nSuite 200', after.PersonMailingStreet, 'Street kept');
        Assert.areEqual('Denver', after.PersonMailingCity, 'City kept');
        Assert.areEqual('CO', after.PersonMailingState, 'State kept');
        Assert.areEqual('80202', after.PersonMailingPostalCode, 'ZIP kept');
    }

    @IsTest
    static void shouldUpdateWholeAddress_WhenLine2Blank() {
        Account provider = existingWithMailingAddress();

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(mailingRow('200 Oak Ave', '', 'Boulder', 'co', '80301'));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(0, result.warnings.size(), 'No warnings: ' + result.warnings);
        Account after = mailingAddress(provider.Id);
        Assert.areEqual('200 Oak Ave', after.PersonMailingStreet, 'Line 2 removed with the blank Line 2');
        Assert.areEqual('Boulder', after.PersonMailingCity, 'City updated');
        Assert.areEqual('CO', after.PersonMailingState, 'State unchanged (same value)');
        Assert.areEqual('80301', after.PersonMailingPostalCode, 'ZIP updated');
        Assert.isFalse(result.changesByField.containsKey('PersonMailingState'), 'Same state is not a change');
    }

    @IsTest
    static void shouldNotUpdateAddress_WhenBlankWouldOverwriteValue() {
        Account provider = existingWithMailingAddress();
        Map<String, String> row = mailingRow('200 Oak Ave', '', 'Boulder', 'CO', '');
        row.put('Provider Phone', '720-555-0199');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, result.outcome, 'The phone is still updated');
        Assert.areEqual(new Set<String>{ 'Phone' }, result.changesByField.keySet(), 'Only the phone changed');
        Assert.areEqual(MAILING_ZIP, result.warnings[0].column, 'Names the blank column');
        assertAddressNotUpdated(
            result, provider.Id,
            'Mailing address not updated: incoming blank "Provider Mailing Zip" cannot overwrite the existing value.'
        );
        Assert.areEqual('(720) 555-0199', mailingAddress(provider.Id).Phone, 'Phone saved');
    }

    @IsTest
    static void shouldNotUpdateAddress_WhenAnyPartInvalid() {
        Account provider = existingWithMailingAddress();

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(mailingRow('200 Oak Ave', '', 'Boulder', 'CO', '8030'));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'Nothing else changed');
        assertAddressNotUpdated(
            result, provider.Id,
            'Mailing address not updated: "Provider Mailing Zip" is not a valid ZIP code (12345 or 12345-6789).'
        );
    }

    @IsTest
    static void shouldNotUpdateAddress_WhenLine2WithoutLine1() {
        Account provider = existingWithMailingAddress();

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(mailingRow('', 'Suite 300', 'Denver', 'CO', '80202'));
        Test.stopTest();

        assertAddressNotUpdated(
            result, provider.Id,
            'Mailing address not updated: "Provider Mailing Address Line 2" is given without "Provider Mailing Address Line 1".'
        );
    }

    @IsTest
    static void shouldListEveryProblem_WhenSeveralPartsFail() {
        Account provider = existingWithMailingAddress();

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(mailingRow('200 Oak Ave', '', '', 'Colorado', '80301'));
        Test.stopTest();

        Assert.areEqual(MAILING_CITY + ', ' + MAILING_STATE, result.warnings[0].column, 'Names both columns');
        assertAddressNotUpdated(
            result, provider.Id,
            'Mailing address not updated: incoming blank "Provider Mailing City" cannot overwrite the existing value; '
                + '"Provider Mailing State" is not a 2-letter US state code.'
        );
    }

    @IsTest
    static void shouldLeaveAddress_WhenAllColumnsBlank() {
        Account provider = existingWithMailingAddress();

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(mailingRow('', ' ', '', '', ''));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'No address given');
        Assert.areEqual(0, result.warnings.size(), 'No warnings: ' + result.warnings);
        Assert.areEqual('Denver', mailingAddress(provider.Id).PersonMailingCity, 'Address kept');
    }

    @IsTest
    static void shouldUpdateAddress_WhenBlankPartIsBlankOnRecordToo() {
        Account provider = existingWithMailingAddress();
        update new Account(Id = provider.Id, PersonMailingPostalCode = null);

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(mailingRow('200 Oak Ave', '', 'Boulder', 'CO', ''));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, result.outcome, 'Warnings: ' + result.warnings);
        Assert.areEqual('Boulder', mailingAddress(provider.Id).PersonMailingCity, 'City updated');
    }

    @IsTest
    static void shouldCompareAddressVerbatim() {
        Account provider = existingWithMailingAddress();

        Test.startTest();
        ProviderIntakeService.IngestResult same = ProviderIntakeService.ingest(mailingRow('100 Main St', 'Suite 200', 'Denver', 'CO', '80202'));
        ProviderIntakeService.IngestResult recased = ProviderIntakeService.ingest(mailingRow('100 Main St', 'Suite 200', 'DENVER', 'CO', '80202'));
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, same.outcome, 'Identical address: ' + same.changesByField);
        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, recased.outcome, 'A case difference is a change');
        Assert.areEqual(new Set<String>{ 'PersonMailingCity' }, recased.changesByField.keySet(), 'Only the city changed');
        Assert.areEqual('DENVER', mailingAddress(provider.Id).PersonMailingCity, 'Written as given');
    }

    @IsTest
    static void shouldInsertGivenAddressParts_WhenProviderNew() {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        row.put(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.NPI_3);
        row.put(MAILING_ZIP, '');
        row.put(MAILING_STATE, 'Colorado');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.INSERTED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(1, result.warnings.size(), 'Only the invalid state warns: ' + result.warnings);
        Assert.areEqual(RosterIntakeIssues.INVALID_VALUE.code, result.warnings[0].code, 'A plain INVALID_VALUE warning');
        Account inserted = mailingAddress(result.accountId);
        Assert.areEqual('Denver', inserted.PersonMailingCity, 'Valid parts written');
        Assert.isNull(inserted.PersonMailingState, 'Invalid state dropped');
        Assert.isNull(inserted.PersonMailingPostalCode, 'Blank ZIP left blank');
    }

    @IsTest
    static void shouldNotUpdateInsertOnlyFields() {
        Account before = existing(EXISTING);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('First Name', 'Renamed');
        row.put('Last Name', 'Renamed');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UNCHANGED, result.outcome, 'Names are insert-only');
        Assert.areEqual(before.LastName, reload(before.Id).LastName, 'Last name unchanged');
    }

    @IsTest
    static void shouldFillBlankNpi_WhenMatchedByUniqueId() {
        Account before = existing(WITHOUT_NPI);
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_3);
        row.put(ProviderCsvMapping.UNIQUE_ID_HEADER, before.InnovAge_Unique_ID__c);

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, result.outcome, 'Errors: ' + result.errors);
        Assert.areEqual(ProviderTestDataFactory.NPI_3, reload(before.Id).NPI__c, 'Blank NPI filled in');
    }

    // ─── Errors ────────────────────────────────────────────────────────

    @IsTest
    static void shouldReturnError_WhenMatchIsError() {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        Integer accountsBefore = [SELECT COUNT() FROM Account];

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.ERROR, result.outcome, 'A row without keys is not ingested');
        Assert.areEqual(AccountMatchResult.Outcome.NO_KEY_VALUES, result.matchOutcome, 'Reports why');
        Assert.areEqual(1, result.errors.size(), 'Carries the matcher message');
        Assert.areEqual(accountsBefore, [SELECT COUNT() FROM Account], 'Nothing inserted');
    }

    @IsTest
    static void shouldReturnError_WhenUniqueIdUnknownEvenIfNpiMatches() {
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put(ProviderCsvMapping.UNIQUE_ID_HEADER, 'P999999999zzz');

        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(row);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.ERROR, result.outcome, 'Unknown Unique ID is an error');
        Assert.areEqual(AccountMatchResult.Outcome.UNKNOWN_UNIQUE_ID, result.matchOutcome, 'Reports why');
    }

    @IsTest
    static void shouldThrow_WhenRowNull() {
        Test.startTest();
        try {
            ProviderIntakeService.ingest(null);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('null'), 'Message explains the null row');
        }
        Test.stopTest();
    }

    // ─── Bulk (ingestAll) ──────────────────────────────────────────────

    private static ProviderIntakeService.RowInput newProviderRow(Integer rowNumber, String npi) {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        row.put(ProviderCsvMapping.NPI_HEADER, npi);
        row.put('Last Name', 'Bulk' + rowNumber);
        return new ProviderIntakeService.RowInput(rowNumber, row);
    }

    private static List<ProviderIntakeService.IngestResult> ingestAll(List<ProviderIntakeService.RowInput> rows) {
        return ProviderIntakeService.ingestAll(rows);
    }

    @IsTest
    static void shouldInsertAndUpdateInBulk_WhenManyRows() {
        List<ProviderIntakeService.RowInput> rows = new List<ProviderIntakeService.RowInput>();
        for (Integer i = 0; i < 251; i++) {
            rows.add(newProviderRow(i + 2, ProviderTestDataFactory.npi(i)));
        }
        Map<String, String> updateRow = rowWithNpi(ProviderTestDataFactory.NPI_1);
        updateRow.put('Provider Phone', '720-555-0177');
        rows.add(new ProviderIntakeService.RowInput(253, updateRow));

        Test.startTest();
        List<ProviderIntakeService.IngestResult> results = ingestAll(rows);
        Test.stopTest();

        Assert.areEqual(252, results.size(), 'One result per row');
        for (Integer i = 0; i < 251; i++) {
            Assert.areEqual(ProviderIntakeService.Outcome.INSERTED, results[i].outcome, 'Row ' + results[i].rowNumber + ': ' + results[i].errors);
        }
        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, results[251].outcome, 'Existing Provider updated: ' + results[251].errors);
        Assert.areEqual(253, results[251].rowNumber, 'Results keep their row numbers');
        Assert.areEqual(251, [SELECT COUNT() FROM Account WHERE LastName LIKE 'Bulk%'], 'All new Providers inserted');
        Assert.areEqual('(720) 555-0177', existing(EXISTING).Phone, 'Phone updated');
    }

    // ─── Duplicate rows (see DUPLICATES in ProviderIntakeService) ───

    @IsTest
    static void shouldFailLaterInsert_WhenNewNpiRepeatsInSameCall() {
        String npi = ProviderTestDataFactory.npi(1);
        List<ProviderIntakeService.RowInput> rows = new List<ProviderIntakeService.RowInput>{
            newProviderRow(2, npi),
            newProviderRow(3, npi)
        };

        Test.startTest();
        List<ProviderIntakeService.IngestResult> results = ingestAll(rows);
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.INSERTED, results[0].outcome, 'First row inserts: ' + results[0].errors);
        Assert.areEqual(ProviderIntakeService.Outcome.ERROR, results[1].outcome, 'Second insert is rejected');
        Assert.areEqual(RosterIntakeIssues.SAVE_ERROR.code, results[1].errorCode, 'By the database (NPI__c is unique)');
        Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE NPI__c = :npi], 'One Provider inserted');
    }

    @IsTest
    static void shouldUpdateInsertedProvider_WhenNpiRepeatsInLaterCall() {
        String npi = ProviderTestDataFactory.npi(2);
        Id insertedId = ingestAll(new List<ProviderIntakeService.RowInput>{ newProviderRow(2, npi) })[0].accountId;
        ProviderIntakeService.RowInput laterRow = newProviderRow(900, npi);
        laterRow.values.put('Provider Phone', '720-555-0199');

        Test.startTest();
        List<ProviderIntakeService.IngestResult> results = ingestAll(new List<ProviderIntakeService.RowInput>{ laterRow });
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, results[0].outcome, 'Later chunk updates the Provider: ' + results[0].errors);
        Assert.areEqual(insertedId, results[0].accountId, 'The Provider the earlier chunk inserted');
        Assert.areEqual('(720) 555-0199', reload(insertedId).Phone, 'Later row\'s value saved');
    }

    @IsTest
    static void shouldMergeUpdates_WhenRowsInSameCallChangeSameProvider() {
        Account provider = existing(EXISTING);
        Map<String, String> byUniqueId = new Map<String, String>{
            ProviderCsvMapping.UNIQUE_ID_HEADER => provider.InnovAge_Unique_ID__c,
            'Provider Phone' => '720-555-0101'
        };
        Map<String, String> byNpi = rowWithNpi(ProviderTestDataFactory.NPI_1);
        byNpi.put('Provider Phone', '720-555-0102');
        byNpi.put('Provider Email', 'merged@example.com');

        Test.startTest();
        List<ProviderIntakeService.IngestResult> results = ingestAll(
            new List<ProviderIntakeService.RowInput>{
                new ProviderIntakeService.RowInput(2, byUniqueId),
                new ProviderIntakeService.RowInput(3, byNpi)
            }
        );
        Test.stopTest();

        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, results[0].outcome, 'First row updated: ' + results[0].errors);
        Assert.areEqual(ProviderIntakeService.Outcome.UPDATED, results[1].outcome, 'Second row updated: ' + results[1].errors);
        Assert.areEqual(new Set<String>{ 'Phone' }, results[0].changesByField.keySet(), 'Each row reports its own changes');
        Assert.areEqual(new Set<String>{ 'Phone', 'PersonEmail' }, results[1].changesByField.keySet(), 'Each row reports its own changes');
        Account updated = reload(provider.Id);
        Assert.areEqual('(720) 555-0102', updated.Phone, 'The later row wins a field both rows change');
        Assert.areEqual('merged@example.com', updated.PersonEmail, 'Fields only one row changes are saved');
    }

    @IsTest
    static void shouldReportWarningColumn_WhenValueInvalid() {
        Map<String, String> row = rowWithNpi(ProviderTestDataFactory.NPI_1);
        row.put('Provider Email', 'not-an-email');

        Test.startTest();
        List<ProviderIntakeService.IngestResult> results = ingestAll(
            new List<ProviderIntakeService.RowInput>{ new ProviderIntakeService.RowInput(2, row) }
        );
        Test.stopTest();

        Assert.areEqual(1, results[0].warnings.size(), 'One structured warning');
        Assert.areEqual('Provider Email', results[0].warnings[0].column, 'Names the column');
        Assert.isFalse(results[0].warnings[0].message.contains('not-an-email'), 'Never echoes the value');
    }

    @IsTest
    static void shouldThrow_WhenRowsNull() {
        Test.startTest();
        try {
            ProviderIntakeService.ingestAll(null);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('null'), 'Message explains the null argument');
        }
        Test.stopTest();
    }

    @IsTest
    static void shouldReportMalformedNpiOnce_WhenNpiInvalid() {
        Test.startTest();
        ProviderIntakeService.IngestResult result = ProviderIntakeService.ingest(rowWithNpi('1234567890'));
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.MALFORMED_NPI.name(), result.errorCode, 'Reported as an error');
        Assert.areEqual(0, result.warnings.size(), 'Not repeated as a warning: ' + result.warnings);
    }
}
