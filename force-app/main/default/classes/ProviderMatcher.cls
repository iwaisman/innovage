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
    private static final String AUTO_NUMBER_FIELD = 'Unique__c';
    private static final List<String> BASE_FIELDS = new List<String>{ 'Id', UNIQUE_ID_FIELD, NPI_FIELD };

    private static final Pattern NPI_FORMAT = Pattern.compile('^\\d{10}$');

    // The NPI check digit is a Luhn check over '80840' + the first 9 digits; the prefix contributes 24.
    private static final Integer NPI_PREFIX_LUHN_SUM = 24;

    /*
     * Each key matches at most one Provider (NPI__c is unique; an auto-number is
     * unique unless an admin resets it, see CandidateIndex). The limit only guards
     * against unexpected data.
     */
    private static final Integer QUERY_LIMIT_PER_KEY = 5;

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
     * The key values of one incoming row.
     */
    public class MatchRequest {
        public String uniqueId { get; private set; }
        public String npi { get; private set; }

        public MatchRequest(String uniqueId, String npi) {
            this.uniqueId = uniqueId;
            this.npi = npi;
        }
    }

    /**
     * @param uniqueId The InnovAge Unique ID from the input, or blank
     * @param npi The NPI from the input, or blank
     * @param additionalFields Account field API names to also query on matched records
     * @return The match result
     * @throws IllegalArgumentException if an additional field does not exist on Account
     */
    public static AccountMatchResult match(String uniqueId, String npi, Set<String> additionalFields) {
        return matchAll(new List<MatchRequest>{ new MatchRequest(uniqueId, npi) }, additionalFields)[0];
    }

    /**
     * Matches many rows with a single query.
     *
     * Each result is exactly what match() would return for that row on its
     * own: rows do not see each other. Detecting two rows that refer to the
     * same Provider is the caller's job.
     *
     * @param requests The rows' key values
     * @param additionalFields Account field API names to also query on matched records
     * @return One result per request, in the same order
     * @throws IllegalArgumentException if requests is null, or an additional field does not exist on Account
     * @example
     * List<AccountMatchResult> results = ProviderMatcher.matchAll(requests, new Set<String>{ 'Phone' });
     */
    public static List<AccountMatchResult> matchAll(List<MatchRequest> requests, Set<String> additionalFields) {
        if (requests == null) {
            throw new IllegalArgumentException('Match requests cannot be null.');
        }

        // Pass 1: check each row's keys. Rows with missing or malformed keys already have their result.
        List<RowMatch> rows = new List<RowMatch>();
        Set<String> autoNumbers = new Set<String>();
        Set<String> npis = new Set<String>();

        for (MatchRequest request : requests) {
            RowMatch row = new RowMatch(request);
            rows.add(row);
            if (row.uniqueId != null) {
                autoNumbers.add(row.uniqueId.autoNumber);
            }
            if (row.npi != null) {
                npis.add(row.npi);
            }
        }

        // Pass 2: one query for every remaining row, then each is evaluated against the Providers its keys identify.
        if (!autoNumbers.isEmpty() || !npis.isEmpty()) {
            CandidateIndex candidates = new CandidateIndex(
                queryCandidates(autoNumbers, npis, additionalFields ?? new Set<String>())
            );
            for (RowMatch row : rows) {
                if (row.result == null) {
                    row.result = evaluate(
                        row.uniqueId,
                        row.npi,
                        candidates.byUniqueId(row.uniqueId),
                        candidates.byNpi(row.npi)
                    );
                }
            }
        }

        List<AccountMatchResult> results = new List<AccountMatchResult>();
        for (RowMatch row : rows) {
            results.add(row.result);
        }
        return results;
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

    /*
     * One request on its way through matchAll().
     *
     * The constructor checks the keys. When one is missing or malformed, result
     * is set to the error and the row is done. Otherwise uniqueId and npi hold the
     * well-formed keys (null when not supplied), and result stays null until
     * matchAll() evaluates the row against the query results.
     */
    private class RowMatch {
        InnovAgeUniqueId uniqueId;
        String npi;
        AccountMatchResult result;

        RowMatch(MatchRequest request) {
            String rawUniqueId = request?.uniqueId;
            String rawNpi = request?.npi;
            Boolean hasUniqueId = String.isNotBlank(rawUniqueId);
            Boolean hasNpi = String.isNotBlank(rawNpi);

            if (!hasUniqueId && !hasNpi) {
                reject(AccountMatchResult.Outcome.NO_KEY_VALUES, 'Neither a Provider Unique ID nor an NPI was provided.');
                return;
            }

            if (hasUniqueId) {
                uniqueId = InnovAgeUniqueId.parse(rawUniqueId);
                if (uniqueId == null || !InnovAgeUniqueId.PROVIDER_PREFIX.equals(uniqueId.prefix)) {
                    reject(
                        AccountMatchResult.Outcome.MALFORMED_UNIQUE_ID,
                        'Provider Unique ID "' + rawUniqueId.trim() + '" is not a valid Provider ID ' +
                        '(expected P, 9 digits, then 3 letters or digits).'
                    );
                    return;
                }
            }

            if (hasNpi) {
                npi = normalizeNpi(rawNpi);
                if (npi == null) {
                    reject(
                        AccountMatchResult.Outcome.MALFORMED_NPI,
                        'NPI "' + rawNpi.trim() + '" is not valid (expected 10 digits with a valid check digit).'
                    );
                }
            }
        }

        /* A rejected row has a result and no keys, so it is neither queried nor evaluated. */
        private void reject(AccountMatchResult.Outcome outcome, String message) {
            result = AccountMatchResult.error(outcome, message);
            uniqueId = null;
            npi = null;
        }
    }

    /*
     * The queried Providers, by full Unique ID and by NPI.
     *
     * The query filters on the auto-number (Unique__c) because the Unique ID
     * formula cannot be filtered efficiently, but a Provider is identified by its
     * full Unique ID. Map keys compare case-sensitively, as the Id suffix
     * requires, so a well-formed ID whose auto-number exists but whose suffix
     * does not match finds nothing.
     *
     * Both keys identify at most one Provider: NPI__c is a unique field, and a
     * full Unique ID includes part of the record Id. If two Providers ever shared
     * one (only possible after an admin resets the auto-number, and then only on
     * an Id-suffix collision), the later one in the query results wins.
     */
    private class CandidateIndex {
        private Map<String, Account> accountsByUniqueId = new Map<String, Account>();
        private Map<String, Account> accountsByNpi = new Map<String, Account>();

        CandidateIndex(List<Account> accounts) {
            for (Account account : accounts) {
                if (String.isNotBlank(account.InnovAge_Unique_ID__c)) {
                    accountsByUniqueId.put(account.InnovAge_Unique_ID__c, account);
                }
                if (String.isNotBlank(account.NPI__c)) {
                    accountsByNpi.put(account.NPI__c, account);
                }
            }
        }

        Account byUniqueId(InnovAgeUniqueId uniqueId) {
            return uniqueId == null ? null : accountsByUniqueId.get(uniqueId.value);
        }

        Account byNpi(String npi) {
            return npi == null ? null : accountsByNpi.get(npi);
        }
    }

    /*
     * Unique__c is not indexed (2026-10-14 query plan: the OR filter is
     * "unindexed"), so the query is driven by the RecordTypeId index and
     * scans every Provider. That is cheap at today's volumes; mark Unique__c
     * as an External ID if Provider counts grow large.
     */
    private static List<Account> queryCandidates(
        Set<String> autoNumbers,
        Set<String> npis,
        Set<String> additionalFields
    ) {
        Map<String, Object> bindsByName = new Map<String, Object>{
            'providerRecordTypeId' => getProviderRecordTypeId()
        };
        List<String> keyFilters = new List<String>();

        if (!autoNumbers.isEmpty()) {
            keyFilters.add(AUTO_NUMBER_FIELD + ' IN :autoNumbers');
            bindsByName.put('autoNumbers', autoNumbers);
        }
        if (!npis.isEmpty()) {
            keyFilters.add(NPI_FIELD + ' IN :npis');
            bindsByName.put('npis', npis);
        }

        String soql =
            'SELECT ' + String.join(fieldsToQuery(additionalFields), ', ') +
            ' FROM Account' +
            ' WHERE RecordTypeId = :providerRecordTypeId' +
            ' AND (' + String.join(keyFilters, ' OR ') + ')' +
            ' ORDER BY CreatedDate' +
            ' LIMIT ' + (QUERY_LIMIT_PER_KEY * (autoNumbers.size() + npis.size()));

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
     * Decides the outcome for one row. Both keys are well formed (or null when
     * not supplied); byUniqueId and byNpi are the Providers they identify, or null.
     *
     *     1. A supplied Unique ID must identify a Provider, otherwise
     *        UNKNOWN_UNIQUE_ID (even if the NPI matched something).
     *     2. The keys identify different Providers -> MULTIPLE_MATCHES.
     *     3. Neither key identifies a Provider -> NO_MATCH (only possible
     *        without a Unique ID, given step 1): the row is a new Provider.
     *     4. The Provider was found by Unique ID, but the input NPI matched
     *        nobody and differs from the Provider's stored NPI -> KEY_MISMATCH.
     *        A blank stored NPI is not a mismatch; the caller fills it in.
     *     5. Otherwise UNIQUE_MATCH. The same Provider matching both keys is the
     *        normal, good case.
     */
    private static AccountMatchResult evaluate(
        InnovAgeUniqueId uniqueId,
        String npi,
        Account byUniqueId,
        Account byNpi
    ) {
        if (uniqueId != null && byUniqueId == null) {
            return AccountMatchResult.error(
                AccountMatchResult.Outcome.UNKNOWN_UNIQUE_ID,
                'No Provider has the Unique ID "' + uniqueId.value + '".'
            );
        }

        if (byUniqueId != null && byNpi != null && byUniqueId.Id != byNpi.Id) {
            return AccountMatchResult.multipleMatches(
                new List<Account>{ byUniqueId, byNpi },
                'The Unique ID and NPI identify different Providers: ' + byUniqueId.Id + ', ' + byNpi.Id + '.'
            );
        }

        // If we don't have multiple matches then get whichever one did match
        Account matched = byUniqueId ?? byNpi;
        if (matched == null) {
            return AccountMatchResult.noMatch();
        }

        // A Provider found by NPI trivially passes this check.
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

        return AccountMatchResult.uniqueMatch(matched);
    }
}
