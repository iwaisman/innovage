@IsTest
private class ProviderMatcherTest {

    private static final String WITH_NPI = 'MatcherWithNpi';
    private static final String WITHOUT_NPI = 'MatcherWithoutNpi';
    private static final String OTHER = 'MatcherOther';

    @TestSetup
    static void setup() {
        ProviderTestDataFactory.createProviders(
            new List<String>{ WITH_NPI, WITHOUT_NPI, OTHER },
            new List<String>{ ProviderTestDataFactory.NPI_1, null, ProviderTestDataFactory.NPI_2 },
            true
        );
    }

    private static Account provider(String lastName) {
        return [SELECT Id, InnovAge_Unique_ID__c, NPI__c FROM Account WHERE LastName = :lastName];
    }

    // ─── Malformed / missing keys ──────────────────────────────────────

    @IsTest
    static void shouldReturnNoKeyValues_WhenBothKeysBlank() {
        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match('  ', null);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.NO_KEY_VALUES, result.outcome, 'Blank keys cannot be matched');
        Assert.isTrue(result.isError(), 'NO_KEY_VALUES is an error');
    }

    @IsTest
    static void shouldReturnMalformedUniqueId_WhenFormatInvalid() {
        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match('P123', ProviderTestDataFactory.NPI_1);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.MALFORMED_UNIQUE_ID, result.outcome, 'P123 is not a valid ID');
    }

    @IsTest
    static void shouldReturnMalformedUniqueId_WhenPrefixIsNotProvider() {
        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match('PG000000001abc', null);
        Test.stopTest();

        Assert.areEqual(
            AccountMatchResult.Outcome.MALFORMED_UNIQUE_ID,
            result.outcome,
            'A Provider Group ID is not a valid Provider ID'
        );
    }

    @IsTest
    static void shouldReturnMalformedNpi_WhenCheckDigitInvalid() {
        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(null, '1234567890');
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.MALFORMED_NPI, result.outcome, 'Check digit of 1234567890 is wrong');
    }

    @IsTest
    static void shouldReturnMalformedNpi_WhenUniqueIdValidButNpiWrongLength() {
        String uniqueId = provider(WITH_NPI).InnovAge_Unique_ID__c;

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(uniqueId, '12345678');
        Test.stopTest();

        Assert.areEqual(
            AccountMatchResult.Outcome.MALFORMED_NPI,
            result.outcome,
            'A malformed NPI is an error even when the Unique ID is valid'
        );
    }

    // ─── Unique ID ─────────────────────────────────────────────────────

    @IsTest
    static void shouldParseExistingProviderUniqueIds() {
        String uniqueId = provider(WITH_NPI).InnovAge_Unique_ID__c;

        Test.startTest();
        InnovAgeUniqueId parsed = InnovAgeUniqueId.parse(uniqueId);
        Test.stopTest();

        Assert.isNotNull(parsed, 'Generated Provider ID "' + uniqueId + '" should parse; check the Unique__c auto-number width');
        Assert.areEqual(InnovAgeUniqueId.PROVIDER_PREFIX, parsed.prefix, 'Provider IDs start with P');
    }

    @IsTest
    static void shouldMatchByUniqueId() {
        Account expected = provider(WITH_NPI);

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(expected.InnovAge_Unique_ID__c, null);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.UNIQUE_MATCH, result.outcome, 'The Unique ID identifies one Provider');
        Assert.areEqual(expected.Id, result.account.Id, 'Matched the Provider with that Unique ID');
    }

    @IsTest
    static void shouldReturnUnknownUniqueId_WhenIdSuffixDiffers() {
        String uniqueId = provider(WITH_NPI).InnovAge_Unique_ID__c;
        String otherSuffix = uniqueId.right(3) == 'zzz' ? 'yyy' : 'zzz';

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(uniqueId.left(uniqueId.length() - 3) + otherSuffix, null);
        Test.stopTest();

        Assert.areEqual(
            AccountMatchResult.Outcome.UNKNOWN_UNIQUE_ID,
            result.outcome,
            'Same auto-number with a different Id suffix is not that Provider'
        );
    }

    @IsTest
    static void shouldReturnUnknownUniqueId_WhenNpiMatchesButUniqueIdUnknown() {
        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match('P999999999zzz', ProviderTestDataFactory.NPI_1);
        Test.stopTest();

        Assert.areEqual(
            AccountMatchResult.Outcome.UNKNOWN_UNIQUE_ID,
            result.outcome,
            'A supplied Unique ID must match even when the NPI does'
        );
    }

    @IsTest
    static void shouldCompareIdSuffixCaseSensitively() {
        InnovAgeUniqueId parsed = InnovAgeUniqueId.parse(' P000000001aBc ');

        Test.startTest();
        Boolean sameCase = parsed.isSameAs('P000000001aBc');
        Boolean otherCase = parsed.isSameAs('P000000001abc');
        Test.stopTest();

        Assert.isTrue(sameCase, 'Identical IDs match');
        Assert.isFalse(otherCase, 'Record Id suffixes are case-sensitive');
        Assert.areEqual('000000001', parsed.autoNumber, 'Auto-number is the 9 digits after the prefix');
    }

    // ─── NPI ───────────────────────────────────────────────────────────

    @IsTest
    static void shouldMatchByNpi() {
        Account expected = provider(OTHER);

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(null, ' ' + ProviderTestDataFactory.NPI_2 + ' ');
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.UNIQUE_MATCH, result.outcome, 'The NPI identifies one Provider');
        Assert.areEqual(expected.Id, result.account.Id, 'Matched the Provider with that NPI');
    }

    @IsTest
    static void shouldReturnNoMatch_WhenNpiUnknown() {
        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(null, ProviderTestDataFactory.NPI_UNUSED);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.NO_MATCH, result.outcome, 'No Provider has that NPI');
        Assert.isFalse(result.isError(), 'NO_MATCH is not an error');
    }

    // ─── Both keys ─────────────────────────────────────────────────────

    @IsTest
    static void shouldMatch_WhenUniqueIdAndNpiAgree() {
        Account expected = provider(WITH_NPI);

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(expected.InnovAge_Unique_ID__c, expected.NPI__c);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.UNIQUE_MATCH, result.outcome, 'Both keys identify the same Provider');
        Assert.areEqual(expected.Id, result.account.Id, 'Matched that Provider');
    }

    @IsTest
    static void shouldReturnMultipleMatches_WhenKeysIdentifyDifferentProviders() {
        Account byUniqueId = provider(WITHOUT_NPI);
        Account byNpi = provider(WITH_NPI);

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(byUniqueId.InnovAge_Unique_ID__c, byNpi.NPI__c);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.MULTIPLE_MATCHES, result.outcome, 'Keys point at different Providers');
        Set<Id> candidateIds = new Map<Id, Account>(result.candidates).keySet();
        Assert.areEqual(new Set<Id>{ byUniqueId.Id, byNpi.Id }, candidateIds, 'Both Providers are reported');
    }

    @IsTest
    static void shouldReturnKeyMismatch_WhenUniqueIdProviderHasDifferentNpi() {
        Account expected = provider(WITH_NPI);

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(expected.InnovAge_Unique_ID__c, ProviderTestDataFactory.NPI_UNUSED);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.KEY_MISMATCH, result.outcome, 'Stored NPI differs from the input');
        AccountMatchResult.KeyMismatch mismatch = result.keyMismatchesByField.get(ProviderMatcher.NPI_FIELD);
        Assert.areEqual(ProviderTestDataFactory.NPI_UNUSED, mismatch.inputValue, 'Reports the input NPI');
        Assert.areEqual(ProviderTestDataFactory.NPI_1, mismatch.accountValue, 'Reports the stored NPI');
    }

    @IsTest
    static void shouldMatch_WhenUniqueIdProviderHasBlankNpi() {
        Account expected = provider(WITHOUT_NPI);

        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(expected.InnovAge_Unique_ID__c, ProviderTestDataFactory.NPI_UNUSED);
        Test.stopTest();

        Assert.areEqual(
            AccountMatchResult.Outcome.UNIQUE_MATCH,
            result.outcome,
            'A blank stored NPI is not a mismatch; it can be filled in'
        );
        Assert.areEqual(expected.Id, result.account.Id, 'Matched the Provider with that Unique ID');
    }

    // ─── Additional fields ─────────────────────────────────────────────

    @IsTest
    static void shouldQueryAdditionalFields() {
        Test.startTest();
        AccountMatchResult result = ProviderMatcher.match(null, ProviderTestDataFactory.NPI_1, new Set<String>{ 'phone', 'PersonEmail' });
        Test.stopTest();

        Assert.isNotNull(result.account.Phone, 'Phone was queried');
        Assert.isNotNull(result.account.PersonEmail, 'PersonEmail was queried');
    }

    @IsTest
    static void shouldThrow_WhenAdditionalFieldUnknown() {
        Test.startTest();
        try {
            ProviderMatcher.match(null, ProviderTestDataFactory.NPI_1, new Set<String>{ 'Not_A_Field__c' });
            Assert.fail('Expected IllegalArgumentException for an unknown field');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('Not_A_Field__c'), 'Message names the unknown field');
        }
        Test.stopTest();
    }

    // ─── Bulk (matchAll) ───────────────────────────────────────────────

    @IsTest
    static void shouldMatchEachRowIndependently_WhenMatchingInBulk() {
        Account withNpi = provider(WITH_NPI);
        List<ProviderMatcher.MatchRequest> requests = new List<ProviderMatcher.MatchRequest>{
            new ProviderMatcher.MatchRequest(null, ProviderTestDataFactory.NPI_1),
            new ProviderMatcher.MatchRequest(null, ProviderTestDataFactory.NPI_UNUSED),
            new ProviderMatcher.MatchRequest('P123', null),
            new ProviderMatcher.MatchRequest(withNpi.InnovAge_Unique_ID__c, ProviderTestDataFactory.NPI_2),
            new ProviderMatcher.MatchRequest(null, null)
        };

        Test.startTest();
        List<AccountMatchResult> results = ProviderMatcher.matchAll(requests, null);
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.UNIQUE_MATCH, results[0].outcome, 'NPI match');
        Assert.areEqual(withNpi.Id, results[0].account.Id, 'Matched the right Provider');
        Assert.areEqual(AccountMatchResult.Outcome.NO_MATCH, results[1].outcome, 'Unused NPI');
        Assert.areEqual(AccountMatchResult.Outcome.MALFORMED_UNIQUE_ID, results[2].outcome, 'Malformed Unique ID');
        Assert.areEqual(AccountMatchResult.Outcome.MULTIPLE_MATCHES, results[3].outcome, 'Keys point at different Providers');
        Assert.areEqual(AccountMatchResult.Outcome.NO_KEY_VALUES, results[4].outcome, 'No keys');
    }

    @IsTest
    static void shouldQueryOnce_WhenMatchingManyRows() {
        List<ProviderMatcher.MatchRequest> requests = new List<ProviderMatcher.MatchRequest>();
        for (Integer i = 0; i < 251; i++) {
            requests.add(new ProviderMatcher.MatchRequest(null, ProviderTestDataFactory.npi(i)));
        }

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<AccountMatchResult> results = ProviderMatcher.matchAll(requests, null);
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(251, results.size(), 'One result per request');
        Assert.areEqual(1, queriesUsed, 'One query regardless of the number of rows');
        Assert.areEqual(AccountMatchResult.Outcome.NO_MATCH, results[250].outcome, 'Unused NPIs do not match');
    }

    @IsTest
    static void shouldNotQuery_WhenNoRowHasValidKeys() {
        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        List<AccountMatchResult> results = ProviderMatcher.matchAll(
            new List<ProviderMatcher.MatchRequest>{ new ProviderMatcher.MatchRequest(null, '123') },
            null
        );
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(AccountMatchResult.Outcome.MALFORMED_NPI, results[0].outcome, 'Malformed NPI');
        Assert.areEqual(0, queriesUsed, 'Nothing to query');
    }
}
