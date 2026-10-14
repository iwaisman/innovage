/**
 * Finds the existing Provider (person) Account that an incoming roster row refers to.
 *
 * Keys:
 *
 *     - InnovAge Unique ID: when present it must identify an existing Provider.
 *     - NPI (Account.NPI__c, unique): identifies the Provider when no Unique ID
 *       is given, and is cross-checked against the Unique ID match otherwise.
 *       A matched Provider with a blank NPI is not a mismatch; the caller may
 *       fill the NPI in.
 *
 * Runs without sharing and queries in system mode: ingestion has to see every
 * Provider regardless of who uploaded the roster, otherwise it would insert
 * duplicates of records the uploader cannot see.
 */
public without sharing class ProviderMatcher {

    public static final String PROVIDER_RECORD_TYPE = 'Provider';
    public static final String NPI_FIELD = 'NPI__c';

    private static final String UNIQUE_ID_FIELD = 'InnovAge_Unique_ID__c';
    private static final List<String> BASE_FIELDS = new List<String>{ 'Id', UNIQUE_ID_FIELD, NPI_FIELD };

    private static final Pattern NPI_FORMAT = Pattern.compile('^\\d{10}$');

    // The NPI check digit is a Luhn check over '80840' + the first 9 digits; the prefix contributes 24.
    private static final Integer NPI_PREFIX_LUHN_SUM = 24;

    /*
     * At most two Providers can match (one per key, since NPI__c is unique), plus
     * Providers sharing the auto-number but not the Id suffix. The limit only
     * guards against unexpected data.
     */
    private static final Integer QUERY_LIMIT = 10;

    /**
     * @return The Id of the Account Provider record type
     * @throws Utilities.RecordTypeException if the org has no Provider record type
     */
    public static Id getProviderRecordTypeId() {
        return Utilities.record_type_id('Account', PROVIDER_RECORD_TYPE);
    }

    /**
     * @param uniqueId The InnovAge Unique ID from the input, or blank
     * @param npi The NPI from the input, or blank
     * @return The match result
     * @example
     * AccountMatchResult result = ProviderMatcher.match('P000012345aB3', '1234567893');
     */
    public static AccountMatchResult match(String uniqueId, String npi) {
        return match(uniqueId, npi, new Set<String>());
    }

    /**
     * @param uniqueId The InnovAge Unique ID from the input, or blank
     * @param npi The NPI from the input, or blank
     * @param additionalFields Account field API names to also query on matched records
     * @return The match result
     * @throws IllegalArgumentException if an additional field does not exist on Account
     */
    public static AccountMatchResult match(String uniqueId, String npi, Set<String> additionalFields) {
        Boolean hasUniqueId = String.isNotBlank(uniqueId);
        Boolean hasNpi = String.isNotBlank(npi);

        if (!hasUniqueId && !hasNpi) {
            return AccountMatchResult.error(
                AccountMatchResult.Outcome.NO_KEY_VALUES,
                'Neither a Provider Unique ID nor an NPI was provided.'
            );
        }

        InnovAgeUniqueId parsedUniqueId = null;
        if (hasUniqueId) {
            parsedUniqueId = InnovAgeUniqueId.parse(uniqueId);
            if (parsedUniqueId == null || !InnovAgeUniqueId.PROVIDER_PREFIX.equals(parsedUniqueId.prefix)) {
                return AccountMatchResult.error(
                    AccountMatchResult.Outcome.MALFORMED_UNIQUE_ID,
                    'Provider Unique ID "' + uniqueId.trim() + '" is not a valid Provider ID ' +
                    '(expected P, 9 digits, then 3 letters or digits).'
                );
            }
        }

        String normalizedNpi = null;
        if (hasNpi) {
            normalizedNpi = normalizeNpi(npi);
            if (normalizedNpi == null) {
                return AccountMatchResult.error(
                    AccountMatchResult.Outcome.MALFORMED_NPI,
                    'NPI "' + npi.trim() + '" is not valid (expected 10 digits with a valid check digit).'
                );
            }
        }

        List<Account> accounts = queryCandidates(parsedUniqueId, normalizedNpi, additionalFields ?? new Set<String>());
        return evaluate(parsedUniqueId, normalizedNpi, accounts);
    }

    /**
     * @param npi A candidate NPI; surrounding whitespace is ignored
     * @return The NPI when it is 10 digits with a valid check digit, otherwise null
     */
    public static String normalizeNpi(String npi) {
        if (String.isBlank(npi)) {
            return null;
        }

        String trimmed = npi.trim();
        if (!NPI_FORMAT.matcher(trimmed).matches()) {
            return null;
        }

        return hasValidNpiCheckDigit(trimmed) ? trimmed : null;
    }

    private static Boolean hasValidNpiCheckDigit(String npi) {
        Integer total = NPI_PREFIX_LUHN_SUM;
        for (Integer i = 0; i < 9; i++) {
            Integer digit = Integer.valueOf(npi.substring(i, i + 1));
            if (Math.mod(i, 2) == 0) {
                digit *= 2;
                if (digit > 9) {
                    digit -= 9;
                }
            }
            total += digit;
        }

        Integer expectedCheckDigit = Math.mod(10 - Math.mod(total, 10), 10);
        return Integer.valueOf(npi.substring(9, 10)) == expectedCheckDigit;
    }

    private static List<Account> queryCandidates(
        InnovAgeUniqueId uniqueId,
        String npi,
        Set<String> additionalFields
    ) {
        Map<String, Object> bindsByName = new Map<String, Object>{
            'providerRecordTypeId' => getProviderRecordTypeId()
        };
        List<String> keyFilters = new List<String>();

        if (uniqueId != null) {
            keyFilters.add('Unique__c = :autoNumber');
            bindsByName.put('autoNumber', uniqueId.autoNumber);
        }
        if (npi != null) {
            keyFilters.add(NPI_FIELD + ' = :npi');
            bindsByName.put('npi', npi);
        }

        String soql =
            'SELECT ' + String.join(fieldsToQuery(additionalFields), ', ') +
            ' FROM Account' +
            ' WHERE RecordTypeId = :providerRecordTypeId' +
            ' AND (' + String.join(keyFilters, ' OR ') + ')' +
            ' ORDER BY CreatedDate' +
            ' LIMIT ' + QUERY_LIMIT;

        return Database.queryWithBinds(soql, bindsByName, AccessLevel.SYSTEM_MODE);
    }

    /*
     * Returns BASE_FIELDS plus additionalFields, each field listed once.
     *
     * SOQL fails on a field selected twice ("duplicate field selected"), and it
     * compares field names ignoring case, so 'NPI__c' and 'npi__c' count as the
     * same field. Apex Sets compare strings case-sensitively, so duplicates are
     * detected by comparing lower-cased names (selectedLowerCaseNames).
     */
    private static List<String> fieldsToQuery(Set<String> additionalFields) {
        Map<String, Schema.SObjectField> accountFieldsByName = Schema.SObjectType.Account.fields.getMap();

        List<String> fields = new List<String>();
        Set<String> selectedLowerCaseNames = new Set<String>();

        for (String field : BASE_FIELDS) {
            fields.add(field);
            selectedLowerCaseNames.add(field.toLowerCase());
        }

        for (String field : additionalFields) {
            String lowerCaseName = field.toLowerCase();

            // Only real Account fields may be spliced into the dynamic SOQL.
            if (!accountFieldsByName.containsKey(lowerCaseName)) {
                throw new IllegalArgumentException('Account has no field named "' + field + '".');
            }

            Boolean alreadySelected = selectedLowerCaseNames.contains(lowerCaseName);
            if (!alreadySelected) {
                fields.add(field);
                selectedLowerCaseNames.add(lowerCaseName);
            }
        }

        return fields;
    }

    /*
     * Decides the outcome from the query results. By this point both keys are
     * well formed (or null when not supplied).
     *
     * "accounts" is a superset of the real matches: the query filtered on the
     * auto-number (Unique__c) OR the NPI, so it can contain:
     *
     *     - the Provider whose full Unique ID matches         -> the Unique ID match
     *     - Providers sharing the auto-number but not the
     *       Id suffix (i.e. a different full Unique ID)        -> not a match; ignored
     *     - the Provider whose NPI matches                    -> the NPI match
     *
     * The same Provider may satisfy both keys; that is the normal, good case.
     *
     * Steps:
     *     1. Sort the results into "matched by Unique ID" and "matched by NPI".
     *     2. A supplied Unique ID must match, otherwise UNKNOWN_UNIQUE_ID
     *        (even if the NPI matched something).
     *     3. Combine both kinds of match into a set of distinct Providers:
     *            0 -> NO_MATCH (only possible when no Unique ID was supplied)
     *            2+ -> MULTIPLE_MATCHES (the keys point at different Providers)
     *            1 -> continue
     *     4. If the single Provider was found by Unique ID, its stored NPI may
     *        still disagree with the input NPI -> KEY_MISMATCH. A blank stored
     *        NPI is not a mismatch; the caller fills it in.
     *     5. Otherwise UNIQUE_MATCH.
     */
    private static AccountMatchResult evaluate(InnovAgeUniqueId uniqueId, String npi, List<Account> accounts) {
        // Step 1: classify each returned Provider by which key(s) it actually matches.
        Account uniqueIdAccount = null;
        List<Account> npiAccounts = new List<Account>(); // at most one in practice: NPI__c is unique

        for (Account account : accounts) {
            // Full, case-sensitive comparison: sharing the auto-number is not enough.
            if (uniqueId != null && uniqueId.isSameAs(account.InnovAge_Unique_ID__c)) {
                uniqueIdAccount = account;
            }
            if (npi != null && npi.equals(account.NPI__c)) {
                npiAccounts.add(account);
            }
        }

        // Step 2: a supplied Unique ID is authoritative; if it identifies nobody, stop here.
        if (uniqueId != null && uniqueIdAccount == null) {
            return AccountMatchResult.error(
                AccountMatchResult.Outcome.UNKNOWN_UNIQUE_ID,
                'No Provider has the Unique ID "' + uniqueId.value + '".'
            );
        }

        // Step 3: merge both kinds of match, keyed by record Id. A Provider matched by
        // BOTH keys has one Id, so it lands in the map once, not twice; the map only
        // grows past 1 when the keys lead to different records.
        Map<Id, Account> matchedAccountsById = new Map<Id, Account>(npiAccounts);
        if (uniqueIdAccount != null) {
            matchedAccountsById.put(uniqueIdAccount.Id, uniqueIdAccount);
        }

        if (matchedAccountsById.size() > 1) {
            return AccountMatchResult.multipleMatches(
                matchedAccountsById.values(),
                'The Unique ID and NPI identify different Providers: ' +
                String.join(new List<Id>(matchedAccountsById.keySet()), ', ') + '.'
            );
        }

        // Only reachable without a Unique ID (step 2 handled the other case): a new Provider.
        if (matchedAccountsById.isEmpty()) {
            return AccountMatchResult.noMatch();
        }

        Account matched = matchedAccountsById.values()[0];

        // Step 4: exactly one Provider. If it was found by Unique ID and the input also has
        // an NPI that matched nobody, its stored NPI may differ. A Provider found by NPI
        // trivially passes this check.
        if (npi != null && String.isNotBlank(matched.NPI__c) && !npi.equals(matched.NPI__c)) {
            return AccountMatchResult.keyMismatch(
                matched,
                new Map<String, AccountMatchResult.KeyMismatch>{
                    NPI_FIELD => new AccountMatchResult.KeyMismatch(npi, matched.NPI__c)
                },
                'Provider ' + matched.Id + ' matches the Unique ID but has NPI ' + matched.NPI__c +
                ', not ' + npi + '.'
            );
        }

        // Step 5: every supplied key agrees with this one Provider.
        return AccountMatchResult.uniqueMatch(matched);
    }
}
