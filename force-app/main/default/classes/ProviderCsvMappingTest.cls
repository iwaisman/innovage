@IsTest
private class ProviderCsvMappingTest {

    private static ProviderCsvMapping.MappedRow mapWith(String header, String value) {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        row.put(header, value);
        return ProviderCsvMapping.mapRow(row);
    }

    private static void assertDropped(String header, String value, Schema.SObjectField field) {
        ProviderCsvMapping.MappedRow mapped = mapWith(header, value);

        Assert.isFalse(mapped.valuesByField.containsKey(field), header + ' "' + value + '" should be dropped');
        Assert.areEqual(1, mapped.warnings.size(), 'One warning for the dropped value: ' + mapped.warnings);
        Assert.isTrue(mapped.warnings[0].contains(header), 'Warning names the header');
    }

    // ─── Valid values ──────────────────────────────────────────────────

    @IsTest
    static void shouldNormalizeValidValues_WhenRowIsValid() {
        Test.startTest();
        ProviderCsvMapping.MappedRow mapped = ProviderCsvMapping.mapRow(ProviderTestDataFactory.createValidRow());
        Test.stopTest();

        Map<Schema.SObjectField, Object> values = mapped.valuesByField;
        Assert.areEqual(0, mapped.warnings.size(), 'A valid row has no warnings: ' + mapped.warnings);
        Assert.areEqual('Dr.', values.get(Account.Salutation), 'Picklist value takes the defined casing');
        Assert.areEqual('(303) 555-0142', values.get(Account.Phone), 'Phone is formatted');
        Assert.areEqual('(303) 555-0143', values.get(Account.Fax), 'Leading country code 1 is removed');
        Assert.areEqual('912-34-5678', values.get(Account.Social_Security_Number_Provider__pc), 'SSN is formatted');
        Assert.areEqual(Date.newInstance(1980, 4, 17), values.get(Account.PersonBirthdate), 'DOB is parsed');
        Assert.areEqual('CO', values.get(Account.PersonMailingState), 'State is upper-cased');
        Assert.areEqual('100 Main St\nSuite 200', values.get(Account.PersonMailingStreet), 'Address lines are joined');
        Assert.areEqual('200 Oak Ave', values.get(Account.BillingStreet), 'A blank second line is omitted');
        Assert.areEqual('80202-1234', values.get(Account.PersonMailingPostalCode), 'ZIP+4 is accepted');
    }

    @IsTest
    static void shouldPassRawKeysThrough() {
        Map<String, String> row = ProviderTestDataFactory.createValidRow();
        row.put(ProviderCsvMapping.UNIQUE_ID_HEADER, ' P000000001abc ');
        row.put(ProviderCsvMapping.NPI_HEADER, ' 1234567890 ');

        Test.startTest();
        ProviderCsvMapping.MappedRow mapped = ProviderCsvMapping.mapRow(row);
        Test.stopTest();

        Assert.areEqual('P000000001abc', mapped.uniqueId, 'Unique ID is trimmed but otherwise unchanged');
        Assert.areEqual('1234567890', mapped.npi, 'NPI is passed through even when invalid; the matcher reports it');
    }

    @IsTest
    static void shouldMapValidNpi() {
        Test.startTest();
        ProviderCsvMapping.MappedRow mapped = mapWith(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.NPI_1);
        Test.stopTest();

        Assert.areEqual(ProviderTestDataFactory.NPI_1, mapped.valuesByField.get(Account.NPI__c), 'NPI is mapped');
    }

    @IsTest
    static void shouldIgnoreBlankAndMissingValues_WithoutWarnings() {
        Map<String, String> row = new Map<String, String>{ 'Last Name' => 'Only', 'Provider Phone' => '   ' };

        Test.startTest();
        ProviderCsvMapping.MappedRow mapped = ProviderCsvMapping.mapRow(row);
        Test.stopTest();

        Assert.areEqual(new Set<Schema.SObjectField>{ Account.LastName }, mapped.valuesByField.keySet(), 'Only Last Name is mapped');
        Assert.areEqual(0, mapped.warnings.size(), 'Blank or missing values are not warnings');
    }

    @IsTest
    static void shouldThrow_WhenRowNull() {
        Test.startTest();
        try {
            ProviderCsvMapping.mapRow(null);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('null'), 'Message explains the null row');
        }
        Test.stopTest();
    }

    // ─── Invalid values are dropped with a warning ─────────────────────

    @IsTest
    static void shouldDropPhone_WhenTooFewDigits() {
        assertDropped('Provider Phone', '555-0142', Account.Phone);
    }

    @IsTest
    static void shouldDropPhone_WhenLettersPresent() {
        assertDropped('Provider Phone', '303-555-CALL', Account.Phone);
    }

    @IsTest
    static void shouldDropEmail_WhenNoAtSign() {
        assertDropped('Provider Email', 'jane.example.com', Account.PersonEmail);
    }

    @IsTest
    static void shouldDropDate_WhenIsoFormat() {
        assertDropped('Date of Birth', '1980-04-17', Account.PersonBirthdate);
    }

    @IsTest
    static void shouldDropDate_WhenImpossible() {
        assertDropped('Date of Birth', '02/30/1980', Account.PersonBirthdate);
    }

    @IsTest
    static void shouldDropDate_WhenInFuture() {
        Date tomorrow = Date.today().addDays(1);
        assertDropped('Date of Birth', String.valueOf(tomorrow.month()) + '/' + tomorrow.day() + '/' + tomorrow.year(), Account.PersonBirthdate);
    }

    @IsTest
    static void shouldDropSsn_WhenNeverIssuedPattern() {
        assertDropped('Social Security Number', '000-00-0000', Account.Social_Security_Number_Provider__pc);
    }

    @IsTest
    static void shouldDropSsn_WhenNotNumeric() {
        assertDropped('Social Security Number', '12345678A', Account.Social_Security_Number_Provider__pc);
    }

    @IsTest
    static void shouldNotIncludeValue_InWarnings() {
        Test.startTest();
        ProviderCsvMapping.MappedRow mapped = mapWith('Social Security Number', '666-12-3456');
        Test.stopTest();

        Assert.isFalse(mapped.warnings[0].contains('666'), 'Sensitive values are not echoed in warnings');
    }

    @IsTest
    static void shouldDropState_WhenFullName() {
        assertDropped('Provider Mailing State', 'Colorado', Account.PersonMailingState);
    }

    @IsTest
    static void shouldDropZip_WhenFourDigits() {
        assertDropped('Provider Mailing Zip', '8020', Account.PersonMailingPostalCode);
    }

    @IsTest
    static void shouldDropPicklist_WhenNotAnAllowedValue() {
        assertDropped('Salutation', 'Captain', Account.Salutation);
    }

    @IsTest
    static void shouldDropNpi_WhenCheckDigitInvalid() {
        assertDropped(ProviderCsvMapping.NPI_HEADER, '1234567890', Account.NPI__c);
    }

    @IsTest
    static void shouldDropText_WhenLongerThanField() {
        assertDropped('Medicare ID', 'X'.repeat(21), Account.Medicare_ID__c);
    }

    // ─── Update support ────────────────────────────────────────────────

    @IsTest
    static void shouldExposeOnlyUpdatableFields() {
        Test.startTest();
        Set<String> fieldNames = ProviderCsvMapping.getUpdatableFieldNames();
        Test.stopTest();

        Assert.areEqual(new Set<String>{ 'NPI__c', 'Phone', 'PersonEmail' }, fieldNames, 'Only NPI, Phone and Email can change');
    }

    @IsTest
    static void shouldComparePhonesByDigits() {
        Test.startTest();
        Boolean same = ProviderCsvMapping.isSameValue(ProviderCsvMapping.ValueType.PHONE, '303.555.0142', '(303) 555-0142');
        Boolean different = ProviderCsvMapping.isSameValue(ProviderCsvMapping.ValueType.PHONE, '303.555.0142', '(303) 555-0143');
        Test.stopTest();

        Assert.isTrue(same, 'Formatting differences are not changes');
        Assert.isFalse(different, 'Different digits are a change');
    }

    @IsTest
    static void shouldCompareEmailsIgnoringCase() {
        Test.startTest();
        Boolean same = ProviderCsvMapping.isSameValue(ProviderCsvMapping.ValueType.EMAIL, 'Jane@Example.com', 'jane@example.com');
        Test.stopTest();

        Assert.isTrue(same, 'Email case is not a change');
    }

    @IsTest
    static void shouldTreatNullAsDifferentFromValue() {
        Test.startTest();
        Boolean same = ProviderCsvMapping.isSameValue(ProviderCsvMapping.ValueType.TEXT, null, 'value');
        Test.stopTest();

        Assert.isFalse(same, 'A blank stored value differs from an incoming value');
    }
}
