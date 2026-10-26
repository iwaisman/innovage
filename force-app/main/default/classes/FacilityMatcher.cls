/**
 * Finds the facility (an Account with the Participant_Facility record type)
 * that a relationships-file row refers to, and checks that it belongs to the
 * roster's Organization scope (see OrganizationScope).
 *
 * Keys, in order of authority:
 *
 *     1. Facility Unique ID (InnovAge_Unique_ID__c, prefix MF): when present it
 *        must identify a facility, and any NPI or address given must agree.
 *     2. Facility NPI (Account.Group_Type_2_NPI__c, not unique): used when no
 *        Unique ID is given; must identify exactly one facility in scope.
 *     3. Address (first line of Account.ShippingStreet): used when neither ID
 *        is given; must identify exactly one facility in scope.
 *
 * A blank stored NPI or address is not a disagreement: nothing guarantees
 * that facilities have them.
 *
 * The facility's HealthcareFacility is found through Account.Healthcare_Facility__c,
 * the pointer the org's automation maintains (as Healthcare_Provider__c is for
 * Providers). Its Legal_Owner__c decides whether the facility is in scope.
 * HealthcareFacility is assumed to be one-to-one with its Account (decided
 * 2026-10-18): no other HealthcareFacility points to the same Account through
 * AccountId, so the pointer is the only one to consider.
 *
 * Runs without sharing and queries in system mode, like ProviderMatcher:
 * matching must not depend on which facilities the uploader can see.
 */
public without sharing class FacilityMatcher {

    public static final String FACILITY_RECORD_TYPE = 'Participant_Facility';

    /* Error codes; these are Roster_Intake_Issue__c.Code__c values. */
    public static final String NO_FACILITY_KEY_VALUES = 'NO_FACILITY_KEY_VALUES';
    public static final String MALFORMED_FACILITY_UNIQUE_ID = 'MALFORMED_FACILITY_UNIQUE_ID';
    public static final String MALFORMED_FACILITY_NPI = 'MALFORMED_FACILITY_NPI';
    public static final String UNKNOWN_FACILITY_UNIQUE_ID = 'UNKNOWN_FACILITY_UNIQUE_ID';
    public static final String FACILITY_KEY_MISMATCH = 'FACILITY_KEY_MISMATCH';
    public static final String MULTIPLE_FACILITY_MATCHES = 'MULTIPLE_FACILITY_MATCHES';
    public static final String FACILITY_NOT_FOUND = 'FACILITY_NOT_FOUND';
    public static final String FACILITY_NOT_SET_UP = 'FACILITY_NOT_SET_UP';
    public static final String FACILITY_NOT_IN_ORGANIZATION = 'FACILITY_NOT_IN_ORGANIZATION';

    /*
     * The facility NPI is Account.Group_Type_2_NPI__c, not HealthcareFacility.NPI_Type_2__c
     * (confirmed 2026-10-18).
     */
    private static final String FACILITY_FIELDS =
        'Id, Name, InnovAge_Unique_ID__c, Group_Type_2_NPI__c, ShippingStreet, Healthcare_Facility__c, ' +
        'Healthcare_Facility__r.Legal_Owner__c, Healthcare_Facility__r.Legal_Owner__r.Name, ' +
        'Healthcare_Facility__r.Legal_Owner__r.InnovAge_Unique_ID__c';

    /* Facilities per Organization scope are expected in the hundreds at most; this only guards the heap. */
    private static final Integer MAX_FACILITIES_IN_SCOPE = 10000;

    /* Messages list at most this many of the facilities an ambiguous key matched. */
    private static final Integer MAX_LISTED_MATCHES = 5;

    /**
     * The facility key values of one row, as supplied (blank when not given).
     */
    public class MatchRequest {
        public String uniqueId { get; private set; }
        public String npi { get; private set; }
        public String address { get; private set; }

        public MatchRequest(String uniqueId, String npi, String address) {
            this.uniqueId = uniqueId;
            this.npi = npi;
            this.address = address;
        }
    }

    /**
     * The outcome of matching one row: the facility, or why there is none.
     */
    public class FacilityMatch {
        /** Null when the facility was found and is in scope. */
        public String errorCode { get; private set; }
        public String message { get; private set; }

        /**
         * The facility Account, when one was identified, even if it is then
         * rejected (key mismatch, not in scope), so Issues can link to it.
         */
        public Account facility { get; private set; }

        public Boolean isError() {
            return errorCode != null;
        }

        /** The facility's HealthcareFacility; set only when there is no error. */
        public Id getHealthcareFacilityId() {
            return isError() ? null : facility.Healthcare_Facility__c;
        }

        private void fail(String errorCode, String message) {
            this.errorCode = errorCode;
            this.message = message;
        }
    }

    /**
     * Matches many rows with at most two queries (by Unique ID, and the facilities
     * in scope for NPI or address matching).
     *
     * @param requests The rows' facility keys
     * @param organizationId The roster's Organization, named in error messages
     * @param scope The Organization scope (see OrganizationScope)
     * @return One result per request, in the same order
     * @throws IllegalArgumentException if requests or scope is null
     */
    public static List<FacilityMatch> matchAll(List<MatchRequest> requests, Id organizationId, Set<Id> scope) {
        if (requests == null || scope == null) {
            throw new IllegalArgumentException('Match requests and scope cannot be null.');
        }

        // Pass 1: check each row's keys and collect what to query.
        List<RowKeys> rows = new List<RowKeys>();
        Set<String> autoNumbers = new Set<String>();
        Boolean needsScopeSearch = false;
        for (MatchRequest request : requests) {
            RowKeys row = new RowKeys(request);
            rows.add(row);
            if (row.uniqueId != null) {
                autoNumbers.add(row.uniqueId.autoNumber);
            } else if (row.npi != null || row.address != null) {
                needsScopeSearch = true;
            }
        }

        // Pass 2: query, then decide each row.
        Map<String, Account> facilitiesByUniqueId = new Map<String, Account>();
        for (Account facility : queryByAutoNumber(autoNumbers)) {
            facilitiesByUniqueId.put(facility.InnovAge_Unique_ID__c, facility);
        }
        FacilitiesInScope inScope = new FacilitiesInScope(needsScopeSearch ? queryInScope(scope) : new List<Account>());
        OrganizationLabel organization = new OrganizationLabel(organizationId);

        List<FacilityMatch> results = new List<FacilityMatch>();
        for (RowKeys row : rows) {
            FacilityMatch result = row.result;
            if (result == null) {
                result = evaluate(row, facilitiesByUniqueId, inScope, organization);
            }
            if (!result.isError()) {
                checkSetUpAndScope(result, scope, organization);
            }
            results.add(result);
        }
        return results;
    }

    /**
     * Normalizes an address for comparison: only the first line counts; it is
     * trimmed, runs of whitespace become one space, trailing punctuation is
     * dropped and case is ignored. There are no abbreviation rules, so
     * "100 Main St" and "100 Main Street" differ.
     *
     * @param address An address line, or a multi-line street
     * @return The normalized first line, or null when blank
     */
    public static String normalizeAddress(String address) {
        if (String.isBlank(address)) {
            return null;
        }
        String firstLine = address.trim().split('\\r?\\n')[0];
        String normalized = firstLine.normalizeSpace().toLowerCase().replaceAll('[\\s.,;:]+$', '');
        return String.isBlank(normalized) ? null : normalized;
    }

    /*
     * One request on its way through matchAll(). The constructor checks the keys;
     * a missing or malformed key sets result and the row is done.
     */
    private class RowKeys {
        InnovAgeUniqueId uniqueId;
        String npi;
        String address;
        String rawAddress;
        FacilityMatch result;

        RowKeys(MatchRequest request) {
            String rawUniqueId = request?.uniqueId;
            String rawNpi = request?.npi;
            rawAddress = request?.address?.trim();

            if (String.isBlank(rawUniqueId) && String.isBlank(rawNpi) && String.isBlank(rawAddress)) {
                reject(NO_FACILITY_KEY_VALUES, 'No Facility Unique ID, Facility NPI or Facility Shipping Address was provided.');
                return;
            }
            if (String.isNotBlank(rawUniqueId)) {
                uniqueId = InnovAgeUniqueId.parse(rawUniqueId);
                if (uniqueId == null || !InnovAgeUniqueId.PARTICIPANT_FACILITY_PREFIX.equals(uniqueId.prefix)) {
                    reject(MALFORMED_FACILITY_UNIQUE_ID, 'Facility Unique ID "' + rawUniqueId.trim() +
                        '" is not a valid facility ID (expected MF, 9 digits, then 3 letters or digits).');
                    return;
                }
            }
            if (String.isNotBlank(rawNpi)) {
                npi = ProviderMatcher.normalizeNpi(rawNpi);
                if (npi == null) {
                    reject(MALFORMED_FACILITY_NPI, 'Facility NPI "' + rawNpi.trim() +
                        '" is not valid (expected 10 digits with a valid check digit).');
                    return;
                }
            }
            address = normalizeAddress(rawAddress);
        }

        private void reject(String code, String message) {
            result = new FacilityMatch();
            result.fail(code, message);
        }
    }

    /*
     * The facilities in scope, by NPI and by normalized address. Several
     * facilities may share either key.
     */
    private class FacilitiesInScope {
        Map<String, List<Account>> byNpi = new Map<String, List<Account>>();
        Map<String, List<Account>> byAddress = new Map<String, List<Account>>();

        FacilitiesInScope(List<Account> facilities) {
            for (Account facility : facilities) {
                add(byNpi, facility.Group_Type_2_NPI__c?.trim(), facility);
                add(byAddress, normalizeAddress(facility.ShippingStreet), facility);
            }
        }

        private void add(Map<String, List<Account>> index, String key, Account facility) {
            if (String.isBlank(key)) {
                return;
            }
            if (!index.containsKey(key)) {
                index.put(key, new List<Account>());
            }
            index.get(key).add(facility);
        }
    }

    /*
     * The roster's Organization as named in messages, queried only when a
     * message needs it.
     */
    private class OrganizationLabel {
        private final Id organizationId;
        private String label;

        OrganizationLabel(Id organizationId) {
            this.organizationId = organizationId;
        }

        String get() {
            if (label == null) {
                List<Account> organizations = [
                    SELECT Name, InnovAge_Unique_ID__c
                    FROM Account
                    WHERE Id = :organizationId
                    WITH SYSTEM_MODE
                ];
                label = organizations.isEmpty()
                    ? 'the roster\'s Organization'
                    : describe(organizations[0].Name, organizations[0].InnovAge_Unique_ID__c);
            }
            return label;
        }
    }

    private static FacilityMatch evaluate(
        RowKeys row,
        Map<String, Account> facilitiesByUniqueId,
        FacilitiesInScope inScope,
        OrganizationLabel organization
    ) {
        FacilityMatch result = new FacilityMatch();

        // 1. Unique ID: authoritative; the other keys must agree with it.
        if (row.uniqueId != null) {
            Account facility = facilitiesByUniqueId.get(row.uniqueId.value);
            if (facility == null) {
                result.fail(UNKNOWN_FACILITY_UNIQUE_ID, 'No facility has the Unique ID "' + row.uniqueId.value + '".');
                return result;
            }
            result.facility = facility;
            String storedNpi = facility.Group_Type_2_NPI__c?.trim();
            if (row.npi != null && String.isNotBlank(storedNpi) && !row.npi.equals(storedNpi)) {
                result.fail(FACILITY_KEY_MISMATCH, 'Facility ' + describe(facility) + ' matches the Unique ID but has NPI ' +
                    storedNpi + ', not ' + row.npi + '.');
                return result;
            }
            checkAddressAgrees(row, result);
            return result;
        }

        // 2. NPI, then 3. address: must identify exactly one facility in scope.
        List<Account> candidates;
        String keyDescription;
        if (row.npi != null) {
            candidates = inScope.byNpi.get(row.npi);
            keyDescription = 'NPI ' + row.npi;
        } else {
            candidates = inScope.byAddress.get(row.address);
            keyDescription = 'the address "' + row.rawAddress + '"';
        }

        if (candidates == null || candidates.isEmpty()) {
            result.fail(FACILITY_NOT_FOUND, 'No facility of ' + organization.get() +
                ' or its sub-organizations has ' + keyDescription + '.');
            return result;
        }
        if (candidates.size() > 1) {
            result.fail(MULTIPLE_FACILITY_MATCHES, candidates.size() + ' facilities of ' + organization.get() +
                ' or its sub-organizations have ' + keyDescription + ': ' + describeAll(candidates) +
                '. Give the Facility Unique ID to choose one.');
            return result;
        }

        result.facility = candidates[0];
        if (row.npi != null) {
            checkAddressAgrees(row, result);
        }
        return result;
    }

    /*
     * REVISIT: an address that disagrees with a facility found by ID is treated
     * as an error, to err on the side of caution while real roster data is
     * unknown. Addresses are often formatted differently ("St" / "Street"), so
     * this may need to become a warning, or a fuzzier comparison.
     */
    private static void checkAddressAgrees(RowKeys row, FacilityMatch result) {
        String storedAddress = normalizeAddress(result.facility.ShippingStreet);
        if (row.address != null && storedAddress != null && !row.address.equals(storedAddress)) {
            result.fail(FACILITY_KEY_MISMATCH, 'Facility ' + describe(result.facility) + ' matches the ' +
                (row.uniqueId != null ? 'Unique ID' : 'NPI') + ' but its address "' +
                result.facility.ShippingStreet.trim().split('\\r?\\n')[0].trim() + '" is not "' + row.rawAddress + '".');
        }
    }

    /*
     * A facility that matched must have a HealthcareFacility whose Legal Owner is
     * in scope. Facilities found by NPI or address are in scope already (they were
     * searched only there); one found by Unique ID may not be.
     */
    private static void checkSetUpAndScope(FacilityMatch result, Set<Id> scope, OrganizationLabel organization) {
        Account facility = result.facility;
        // The org's automation sets Healthcare_Facility__c and a validation rule keeps it set;
        // this guards against data loaded around them.
        if (facility.Healthcare_Facility__c == null) {
            result.fail(FACILITY_NOT_SET_UP, 'Facility ' + describe(facility) + ' has no Healthcare Facility record.');
            return;
        }

        Id legalOwnerId = facility.Healthcare_Facility__r.Legal_Owner__c;
        if (legalOwnerId == null) {
            result.fail(FACILITY_NOT_IN_ORGANIZATION, 'Facility ' + describe(facility) +
                ' has no Legal Owner Organization, so it is not part of ' + organization.get() + '.');
        } else if (!scope.contains(legalOwnerId)) {
            Account owner = facility.Healthcare_Facility__r.Legal_Owner__r;
            result.fail(FACILITY_NOT_IN_ORGANIZATION, 'Facility ' + describe(facility) + ' belongs to Organization ' +
                describe(owner.Name, owner.InnovAge_Unique_ID__c) + ', which is not ' + organization.get() +
                ' or one of its sub-organizations.');
        }
    }

    private static List<Account> queryByAutoNumber(Set<String> autoNumbers) {
        if (autoNumbers.isEmpty()) {
            return new List<Account>();
        }
        // Filters on the auto-number because the Unique ID formula cannot be filtered
        // efficiently; callers compare the full, case-sensitive ID (see InnovAgeUniqueId).
        return Database.queryWithBinds(
            'SELECT ' + FACILITY_FIELDS + ' FROM Account' +
            ' WHERE RecordTypeId = :facilityRecordTypeId AND Unique__c IN :autoNumbers',
            new Map<String, Object>{
                'facilityRecordTypeId' => getFacilityRecordTypeId(),
                'autoNumbers' => autoNumbers
            },
            AccessLevel.SYSTEM_MODE
        );
    }

    /*
     * Every facility in scope. Addresses are compared after normalization, which
     * SOQL cannot do, so the comparison happens in Apex.
     */
    private static List<Account> queryInScope(Set<Id> scope) {
        return Database.queryWithBinds(
            'SELECT ' + FACILITY_FIELDS + ' FROM Account' +
            ' WHERE RecordTypeId = :facilityRecordTypeId AND Healthcare_Facility__r.Legal_Owner__c IN :scope' +
            ' ORDER BY Name LIMIT ' + MAX_FACILITIES_IN_SCOPE,
            new Map<String, Object>{
                'facilityRecordTypeId' => getFacilityRecordTypeId(),
                'scope' => scope
            },
            AccessLevel.SYSTEM_MODE
        );
    }

    /**
     * @return The Id of the Account Participant_Facility (Medical Facility) record type
     */
    public static Id getFacilityRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get(FACILITY_RECORD_TYPE)
            .getRecordTypeId();
    }

    private static String describe(Account account) {
        return describe(account.Name, account.InnovAge_Unique_ID__c);
    }

    private static String describe(String name, String uniqueId) {
        return '"' + name + '"' + (String.isBlank(uniqueId) ? '' : ' (' + uniqueId + ')');
    }

    private static String describeAll(List<Account> facilities) {
        List<String> labels = new List<String>();
        for (Integer i = 0; i < Math.min(facilities.size(), MAX_LISTED_MATCHES); i++) {
            labels.add(describe(facilities[i]));
        }
        if (facilities.size() > MAX_LISTED_MATCHES) {
            labels.add('…');
        }
        return String.join(labels, ', ');
    }
}
