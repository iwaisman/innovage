/**
 * Maps a Provider roster CSV row (header => value, as produced by
 * CsvParser.parseWithHeaders) onto Provider person Account fields (MAPPINGS)
 * and fields of the Provider's HealthcareProvider (HEALTHCARE_PROVIDER_MAPPINGS,
 * written by HealthcareProviderFieldService).
 *
 * Each mapping declares how the value is validated and normalized, and how it
 * may be applied to an existing Provider:
 *
 *     OVERWRITE      replaces the stored value when it differs
 *     FILL_IF_BLANK  is only written when the stored value is blank
 *     INSERT_ONLY    is only written when the Provider is created
 *
 * Blank values are ignored. Values that fail validation are dropped and
 * reported as warnings; they are never written. Warnings never include the
 * value itself, since some values (SSN, DOB) are sensitive.
 */
public inherited sharing class ProviderCsvMapping {

    public static final String UNIQUE_ID_HEADER = 'Provider Unique ID';
    public static final String NPI_HEADER = 'Individual NPI';
    public static final String LAST_NAME_HEADER = 'Last Name';

    /* Specialty columns: not Account fields; ProviderSpecialtyService links them (see specialtyCode). */
    public static final String PRIMARY_SPECIALTY_HEADER = 'Primary Provider Specialty';
    public static final String SECONDARY_SPECIALTY_HEADER = 'Secondary Provider Specialty';

    /*
     * A specialty value is "<label><separator><NUCC taxonomy code>", e.g.
     * "Family Medicine Physician:207Q00000X"; only the code is used. Assumed format
     * (2026-10-20) until real files arrive; change it here (and in specialtyCode).
     */
    public static final String SPECIALTY_CODE_SEPARATOR = ':';

    /*
     * Separates the values of a multi-select picklist column in the CSV, e.g.
     * "Polish;Spanish". Agreed as ";" for now (2026-10-19); change it here if the
     * file format changes. Salesforce itself always stores multi-select values
     * separated by ";", whatever this is.
     */
    public static final String MULTI_PICKLIST_SEPARATOR = ';';

    public enum ValueType { TEXT, PICKLIST, MULTI_PICKLIST, PHONE, EMAIL, PAST_DATE, SSN, NPI, STATE, ZIP }

    public enum UpdatePolicy { OVERWRITE, FILL_IF_BLANK, INSERT_ONLY }

    /**
     * One Account field and the CSV header(s) it is populated from.
     */
    public class FieldMapping {
        /** Multiple headers (e.g. address lines) are joined with a newline. */
        public List<String> headers { get; private set; }
        public Schema.SObjectField field { get; private set; }
        public ValueType valueType { get; private set; }
        public UpdatePolicy updatePolicy { get; private set; }

        public FieldMapping(String header, Schema.SObjectField field, ValueType valueType, UpdatePolicy updatePolicy) {
            this(new List<String>{ header }, field, valueType, updatePolicy);
        }

        public FieldMapping(
            List<String> headers,
            Schema.SObjectField field,
            ValueType valueType,
            UpdatePolicy updatePolicy
        ) {
            this.headers = headers;
            this.field = field;
            this.valueType = valueType;
            this.updatePolicy = updatePolicy;
        }

        public String getFieldName() {
            return field.getDescribe().getName();
        }
    }

    /**
     * The result of mapping one CSV row.
     */
    public class MappedRow {
        /** Raw key values, passed to ProviderMatcher, which reports malformed keys itself. */
        public String uniqueId { get; private set; }
        public String npi { get; private set; }

        /**
         * The NUCC taxonomy codes from the specialty columns (see specialtyCode), or
         * null when blank. A secondary equal to the primary is null.
         */
        public String primarySpecialtyCode { get; private set; }
        public String secondarySpecialtyCode { get; private set; }

        /** Valid, normalized, non-blank Account values. */
        public Map<Schema.SObjectField, Object> valuesByField { get; private set; }

        /** Valid, normalized, non-blank HealthcareProvider values. */
        public Map<Schema.SObjectField, Object> healthcareProviderValuesByField { get; private set; }

        /**
         * One INVALID_VALUE warning per dropped value. Its column is the value's
         * header(s), e.g. "Provider Email" or "Line 1 / Line 2"; its message never
         * contains the value.
         */
        public List<RosterIntakeRow.Warning> warnings { get; private set; }

        /** Why each dropped value was dropped, e.g. "not a valid ZIP code (12345 or 12345-6789)". */
        public Map<Schema.SObjectField, String> invalidReasonsByField { get; private set; }

        /** The mapped headers whose cell is blank or missing. */
        public Set<String> blankHeaders { get; private set; }

        private MappedRow() {
            valuesByField = new Map<Schema.SObjectField, Object>();
            healthcareProviderValuesByField = new Map<Schema.SObjectField, Object>();
            warnings = new List<RosterIntakeRow.Warning>();
            invalidReasonsByField = new Map<Schema.SObjectField, String>();
            blankHeaders = new Set<String>();
        }

        private void drop(FieldMapping mapping, String reason) {
            invalidReasonsByField.put(mapping.field, reason);
            warnings.add(new RosterIntakeRow.Warning(
                RosterIntakeIssues.INVALID_VALUE, String.join(mapping.headers, ' / '), 'Ignored: ' + reason + '.'
            ));
        }
    }

    /* An address's mappings: street (Line 1 and Line 2), city, state, ZIP. Declared before MAPPINGS, which uses them. */
    private static final List<FieldMapping> MAILING_ADDRESS = new List<FieldMapping>{
        new FieldMapping(
            new List<String>{ 'Provider Mailing Address Line 1', 'Provider Mailing Address Line 2' },
            Account.PersonMailingStreet, ValueType.TEXT, UpdatePolicy.OVERWRITE
        ),
        new FieldMapping('Provider Mailing City', Account.PersonMailingCity, ValueType.TEXT, UpdatePolicy.OVERWRITE),
        new FieldMapping('Provider Mailing State', Account.PersonMailingState, ValueType.STATE, UpdatePolicy.OVERWRITE),
        new FieldMapping('Provider Mailing Zip', Account.PersonMailingPostalCode, ValueType.ZIP, UpdatePolicy.OVERWRITE)
    };

    private static final List<FieldMapping> BILLING_ADDRESS = new List<FieldMapping>{
        new FieldMapping(
            new List<String>{ 'Provider Billing Address Line 1', 'Provider Billing Address Line 2' },
            Account.BillingStreet, ValueType.TEXT, UpdatePolicy.OVERWRITE
        ),
        new FieldMapping('Provider Billing City', Account.BillingCity, ValueType.TEXT, UpdatePolicy.OVERWRITE),
        new FieldMapping('Provider Billing State', Account.BillingState, ValueType.STATE, UpdatePolicy.OVERWRITE),
        new FieldMapping('Provider Billing Zip', Account.BillingPostalCode, ValueType.ZIP, UpdatePolicy.OVERWRITE)
    };

    public static final List<FieldMapping> MAPPINGS = new List<FieldMapping>{
        new FieldMapping(NPI_HEADER, Account.NPI__c, ValueType.NPI, UpdatePolicy.FILL_IF_BLANK),
        new FieldMapping('Provider Phone', Account.Phone, ValueType.PHONE, UpdatePolicy.OVERWRITE),
        new FieldMapping('Provider Email', Account.PersonEmail, ValueType.EMAIL, UpdatePolicy.OVERWRITE),
        new FieldMapping('Gender Identification', Account.PersonGender, ValueType.PICKLIST, UpdatePolicy.OVERWRITE),
        new FieldMapping('Pronouns', Account.PersonPronouns, ValueType.PICKLIST, UpdatePolicy.OVERWRITE),
        // Both language fields default to English, so they are never blank: FILL_IF_BLANK would never apply.
        new FieldMapping('Primary Provider Language', Account.Primary_Language__c, ValueType.PICKLIST, UpdatePolicy.OVERWRITE),
        new FieldMapping(
            'Secondary Provider Language(s)', Account.Secondary_Languages__c, ValueType.MULTI_PICKLIST, UpdatePolicy.OVERWRITE
        ),

        new FieldMapping('Salutation', Account.Salutation, ValueType.PICKLIST, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('First Name', Account.FirstName, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Middle Name', Account.MiddleName, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping(LAST_NAME_HEADER, Account.LastName, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Suffix (MD, DO, NP, RN etc)', Account.Suffix, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Date of Birth', Account.PersonBirthdate, ValueType.PAST_DATE, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Social Security Number', Account.Social_Security_Number_Provider__pc, ValueType.SSN, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Provider Fax', Account.Fax, ValueType.PHONE, UpdatePolicy.OVERWRITE),

        // Addresses: see AddressGroup and ADDRESS_GROUPS below.
        MAILING_ADDRESS[0], MAILING_ADDRESS[1], MAILING_ADDRESS[2], MAILING_ADDRESS[3],
        BILLING_ADDRESS[0], BILLING_ADDRESS[1], BILLING_ADDRESS[2], BILLING_ADDRESS[3],

        // The "VFY_Account | Auto Create CAQH" flow, which failed inside the Verifiable package
        // when this was set, was deactivated on 2026-10-20 (docs/issues/caqh-verifiable-flow-failure.md).
        // KNOWN RISK (accepted 2026-10-20): CAQH IDs are not checked for duplicates. The org's
        // "Sync Individual Provider to Healthcare Provider" flow copies CAQH_ID__pc to the unique
        // HealthcareProvider.CaqhIdentifier on every Account update, so if two Providers share a CAQH
        // ID, any later update of the second (even a phone change) fails with DUPLICATE_VALUE on
        // CaqhIdentifier, reported as a SAVE_ERROR naming that flow.
        new FieldMapping('CAQH ID', Account.CAQH_ID__pc, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Medicare ID', Account.Medicare_ID__c, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Medicaid ID', Account.Medicaid_ID__pc, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Medicaid ID State', Account.Medicaid_ID_State__c, ValueType.STATE, UpdatePolicy.INSERT_ONLY),

        // Setting Initial_Credentialing_Approval__pc starts the Verifiable credentialing flows
        // (Auto Verify NPI and Sanctions; Credentialing Event Creation).
        new FieldMapping(
            'Initial Credentialing Date', Account.Initial_Credentialing_Approval__pc, ValueType.PAST_DATE, UpdatePolicy.OVERWRITE
        ),
        new FieldMapping(
            'Last Credentialing Date', Account.Last_Credentialing_Approval_Date__pc, ValueType.PAST_DATE, UpdatePolicy.OVERWRITE
        )
    };

    /**
     * Fields of the Provider's HealthcareProvider (found through Account.Healthcare_Provider__c).
     * Each mapping's UpdatePolicy applies as it does for Account fields.
     */
    public static final List<FieldMapping> HEALTHCARE_PROVIDER_MAPPINGS = new List<FieldMapping>{
        // A Yes / No picklist.
        new FieldMapping(
            'Provider Attests to Providing Gender Affirming Care?',
            HealthcareProvider.Offers_Offered_Gender_Affirming_Services__c,
            ValueType.PICKLIST,
            UpdatePolicy.OVERWRITE
        )
    };

    /**
     * One address: its street (mapped from Line 1 and Line 2), city, state and ZIP.
     *
     * On an insert each valid part is written, like any other field. On an update
     * the address is written as a group: when problems() finds anything, none of
     * its parts are written. The parts must share one update policy.
     */
    public class AddressGroup {
        /** e.g. "Mailing", as used in warnings. */
        public String name { get; private set; }
        /** The street's mapping first; its headers are Line 1 and Line 2. */
        public List<FieldMapping> mappings { get; private set; }

        private AddressGroup(String name, List<FieldMapping> mappings) {
            this.name = name;
            this.mappings = mappings;
        }

        /**
         * @param mapped A mapped row
         * @return false when every column of the address is blank (the address is then left as it is)
         */
        public Boolean isGivenIn(MappedRow mapped) {
            for (FieldMapping mapping : mappings) {
                for (String header : mapping.headers) {
                    if (!mapped.blankHeaders.contains(header)) {
                        return true;
                    }
                }
            }
            return false;
        }

        /**
         * Why the row's address cannot replace the stored one. A part is a problem when:
         *   - Line 2 is given without Line 1,
         *   - its value is invalid, or
         *   - it is blank in the row but not on the record.
         * Line 2 may be blank when Line 1 is given.
         *
         * @param mapped A mapped row in which the address is given (see isGivenIn)
         * @param stored The record as stored, with the address fields queried
         * @return Column => reason, e.g. "Provider Mailing Zip" => "incoming blank "Provider
         *         Mailing Zip" cannot overwrite the existing value"; empty when the address may be written
         */
        public Map<String, String> problems(MappedRow mapped, SObject stored) {
            Map<String, String> problemsByColumn = new Map<String, String>();
            for (FieldMapping mapping : mappings) {
                String first = mapping.headers[0];
                String column = String.join(mapping.headers, ' / ');
                Boolean hasSecondLineOnly = mapping.headers.size() > 1
                    && mapped.blankHeaders.contains(first)
                    && !mapped.blankHeaders.contains(mapping.headers[1]);

                if (hasSecondLineOnly) {
                    problemsByColumn.put(column, '"' + mapping.headers[1] + '" is given without "' + first + '"');
                } else if (mapped.invalidReasonsByField.containsKey(mapping.field)) {
                    problemsByColumn.put(
                        column, '"' + String.join(mapping.headers, '" / "') + '" is ' + mapped.invalidReasonsByField.get(mapping.field)
                    );
                } else if (!mapped.valuesByField.containsKey(mapping.field) && String.isNotBlank((String) stored.get(mapping.field))) {
                    problemsByColumn.put(first, 'incoming blank "' + first + '" cannot overwrite the existing value');
                }
            }
            return problemsByColumn;
        }
    }

    public static final List<AddressGroup> ADDRESS_GROUPS = new List<AddressGroup>{
        new AddressGroup('Mailing', MAILING_ADDRESS),
        new AddressGroup('Billing', BILLING_ADDRESS)
    };

    private static final Map<ValueType, String> INVALID_REASONS_BY_TYPE = new Map<ValueType, String>{
        ValueType.TEXT => 'not valid text',
        ValueType.PICKLIST => 'not one of the allowed values',
        ValueType.MULTI_PICKLIST => 'not a list of allowed values separated by "' + MULTI_PICKLIST_SEPARATOR + '"',
        ValueType.PHONE => 'not a 10-digit US phone number',
        ValueType.EMAIL => 'not a valid email address',
        ValueType.PAST_DATE => 'not a valid MM/DD/YYYY date in the past',
        ValueType.SSN => 'not a valid Social Security Number',
        ValueType.NPI => 'not a 10-digit NPI with a valid check digit',
        ValueType.STATE => 'not a 2-letter US state code',
        ValueType.ZIP => 'not a valid ZIP code (12345 or 12345-6789)'
    };

    private static final Pattern PHONE_CHARACTERS = Pattern.compile('^[0-9()+.\\-\\s]+$');
    private static final Pattern EMAIL_FORMAT = Pattern.compile('^[A-Za-z0-9._%+\'-]+@[A-Za-z0-9-]+(\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}$');
    private static final Pattern DATE_FORMAT = Pattern.compile('^(\\d{1,2})/(\\d{1,2})/(\\d{4})$');
    private static final Pattern SSN_FORMAT = Pattern.compile('^(\\d{3})-?(\\d{2})-?(\\d{4})$');
    private static final Pattern ZIP_FORMAT = Pattern.compile('^\\d{5}(-\\d{4})?$');

    private static final Set<String> US_STATE_CODES = new Set<String>{
        'AL', 'AK', 'AZ', 'AR', 'CA', 'CO', 'CT', 'DE', 'FL', 'GA', 'HI', 'ID', 'IL', 'IN', 'IA', 'KS', 'KY',
        'LA', 'ME', 'MD', 'MA', 'MI', 'MN', 'MS', 'MO', 'MT', 'NE', 'NV', 'NH', 'NJ', 'NM', 'NY', 'NC', 'ND',
        'OH', 'OK', 'OR', 'PA', 'RI', 'SC', 'SD', 'TN', 'TX', 'UT', 'VT', 'VA', 'WA', 'WV', 'WI', 'WY',
        'DC', 'PR', 'VI', 'GU', 'AS', 'MP'
    };

    // Transaction-scoped cache: field => (lower-case value => active picklist value)
    private static Map<Schema.SObjectField, Map<String, String>> picklistValuesByField =
        new Map<Schema.SObjectField, Map<String, String>>();

    /**
     * @param row One CSV row, header => value
     * @return The key values, the valid field values, and warnings for dropped values
     * @throws IllegalArgumentException if row is null
     * @example
     * ProviderCsvMapping.MappedRow mapped = ProviderCsvMapping.mapRow(parsed.rows[0]);
     */
    public static MappedRow mapRow(Map<String, String> row) {
        if (row == null) {
            throw new IllegalArgumentException('CSV row cannot be null.');
        }

        MappedRow mapped = new MappedRow();
        mapped.uniqueId = row.get(UNIQUE_ID_HEADER)?.trim();
        mapped.npi = row.get(NPI_HEADER)?.trim();
        mapped.primarySpecialtyCode = specialtyCode(row.get(PRIMARY_SPECIALTY_HEADER));
        String secondary = specialtyCode(row.get(SECONDARY_SPECIALTY_HEADER));
        mapped.secondarySpecialtyCode = secondary == mapped.primarySpecialtyCode ? null : secondary;

        mapValues(row, MAPPINGS, mapped, mapped.valuesByField);
        mapValues(row, HEALTHCARE_PROVIDER_MAPPINGS, mapped, mapped.healthcareProviderValuesByField);
        return mapped;
    }

    /*
     * Puts each mapping's valid value into valuesByField; warns about invalid ones.
     */
    private static void mapValues(
        Map<String, String> row,
        List<FieldMapping> mappings,
        MappedRow mapped,
        Map<Schema.SObjectField, Object> valuesByField
    ) {
        for (FieldMapping mapping : mappings) {
            for (String header : mapping.headers) {
                if (String.isBlank(row.get(header))) {
                    mapped.blankHeaders.add(header);
                }
            }

            String rawValue = joinedValue(row, mapping.headers);
            if (String.isBlank(rawValue)) {
                continue;
            }

            Object value = normalize(mapping, rawValue);
            if (value == null) {
                mapped.drop(mapping, INVALID_REASONS_BY_TYPE.get(mapping.valueType));
                continue;
            }

            Integer maxLength = mapping.field.getDescribe().getLength();
            if (value instanceof String && maxLength > 0 && ((String) value).length() > maxLength) {
                mapped.drop(mapping, 'longer than ' + maxLength + ' characters');
                continue;
            }

            valuesByField.put(mapping.field, value);
        }
    }

    /**
     * Whether a mapping's update policy lets it write over a stored value.
     *
     * @param mapping The mapping
     * @param storedValue The value currently on the record
     * @param isNewProvider true when the row created the Provider
     * @return false for INSERT_ONLY on an existing Provider, and for FILL_IF_BLANK over a non-blank value
     */
    public static Boolean mayWrite(FieldMapping mapping, Object storedValue, Boolean isNewProvider) {
        switch on mapping.updatePolicy {
            when INSERT_ONLY {
                return isNewProvider;
            }
            when FILL_IF_BLANK {
                return storedValue == null || String.isBlank(String.valueOf(storedValue));
            }
            when else {
                return true;
            }
        }
    }

    /**
     * The NUCC taxonomy code in a specialty value: the text after the last
     * SPECIALTY_CODE_SEPARATOR, or the whole value when there is none. Taking the
     * last one lets the label contain the separator.
     *
     * @param value A specialty column value, e.g. "Family Medicine Physician:207Q00000X"
     * @return The code, trimmed (e.g. "207Q00000X"); null when the value is blank;
     *         '' when the value has a label but no code (e.g. "Cardiology:")
     */
    public static String specialtyCode(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        // substringAfterLast returns '' when the separator is missing, so a bare code is handled here.
        return value.contains(SPECIALTY_CODE_SEPARATOR)
            ? value.substringAfterLast(SPECIALTY_CODE_SEPARATOR).trim()
            : value.trim();
    }

    /**
     * @return The mappings that may change an existing Provider
     */
    public static List<FieldMapping> getUpdatableMappings() {
        List<FieldMapping> updatable = new List<FieldMapping>();
        for (FieldMapping mapping : MAPPINGS) {
            if (mapping.updatePolicy != UpdatePolicy.INSERT_ONLY) {
                updatable.add(mapping);
            }
        }
        return updatable;
    }

    /**
     * @return API names of the fields that may change an existing Provider
     */
    public static Set<String> getUpdatableFieldNames() {
        Set<String> fieldNames = new Set<String>();
        for (FieldMapping mapping : getUpdatableMappings()) {
            fieldNames.add(mapping.getFieldName());
        }
        return fieldNames;
    }

    /**
     * Compares a stored value with a normalized incoming value the way the value
     * type is meant to be compared (phone numbers by digits, emails ignoring case).
     *
     * @param valueType The mapping's value type
     * @param storedValue The value currently on the Account
     * @param incomingValue The normalized value from the CSV
     * @return true when writing incomingValue would not change anything meaningful
     */
    public static Boolean isSameValue(ValueType valueType, Object storedValue, Object incomingValue) {
        if (storedValue == null || incomingValue == null) {
            return storedValue == incomingValue;
        }

        String stored = String.valueOf(storedValue);
        String incoming = String.valueOf(incomingValue);

        switch on valueType {
            when PHONE {
                return digitsOnly(stored).right(10).equals(digitsOnly(incoming).right(10));
            }
            when EMAIL, PICKLIST, STATE {
                return stored.equalsIgnoreCase(incoming);
            }
            when MULTI_PICKLIST {
                // The same values in any order are not a change.
                return new Set<String>(stored.toLowerCase().split(';')).equals(new Set<String>(incoming.toLowerCase().split(';')));
            }
            when else {
                return stored.equals(incoming);
            }
        }
    }

    private static String joinedValue(Map<String, String> row, List<String> headers) {
        List<String> parts = new List<String>();
        for (String header : headers) {
            String part = row.get(header);
            if (String.isNotBlank(part)) {
                parts.add(part.trim());
            }
        }
        return String.join(parts, '\n');
    }

    /*
     * Returns the normalized value, or null when the value is invalid for its type.
     */
    private static Object normalize(FieldMapping mapping, String value) {
        switch on mapping.valueType {
            when PICKLIST {
                return activePicklistValue(mapping.field, value);
            }
            when MULTI_PICKLIST {
                return multiPicklistValue(mapping.field, value);
            }
            when PHONE {
                return normalizePhone(value);
            }
            when EMAIL {
                return EMAIL_FORMAT.matcher(value).matches() ? value : null;
            }
            when PAST_DATE {
                return parsePastDate(value);
            }
            when SSN {
                return normalizeSsn(value);
            }
            when NPI {
                return ProviderMatcher.normalizeNpi(value);
            }
            when STATE {
                String code = value.toUpperCase();
                return US_STATE_CODES.contains(code) ? code : null;
            }
            when ZIP {
                return ZIP_FORMAT.matcher(value).matches() ? value : null;
            }
            when else {
                return value;
            }
        }
    }

    private static String activePicklistValue(Schema.SObjectField field, String value) {
        if (!picklistValuesByField.containsKey(field)) {
            Map<String, String> valuesByLowerCase = new Map<String, String>();
            for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
                if (entry.isActive()) {
                    valuesByLowerCase.put(entry.getValue().toLowerCase(), entry.getValue());
                }
            }
            picklistValuesByField.put(field, valuesByLowerCase);
        }
        return picklistValuesByField.get(field).get(value.toLowerCase());
    }

    /*
     * Splits the CSV value on MULTI_PICKLIST_SEPARATOR and matches each part to an
     * active value, ignoring case, blanks and repeats. Returns the values joined the
     * way Salesforce stores them (";"), or null when any part is not allowed: the
     * whole value is then dropped rather than written partly.
     */
    private static String multiPicklistValue(Schema.SObjectField field, String value) {
        List<String> values = new List<String>();
        Set<String> seen = new Set<String>();
        for (String part : value.split(Pattern.quote(MULTI_PICKLIST_SEPARATOR))) {
            if (String.isBlank(part)) {
                continue;
            }
            String allowed = activePicklistValue(field, part.trim());
            if (allowed == null) {
                return null;
            }
            if (seen.add(allowed)) {
                values.add(allowed);
            }
        }
        return values.isEmpty() ? null : String.join(values, ';');
    }

    private static String normalizePhone(String value) {
        if (!PHONE_CHARACTERS.matcher(value).matches()) {
            return null;
        }

        String digits = digitsOnly(value);
        if (digits.length() == 11 && digits.startsWith('1')) {
            digits = digits.substring(1);
        }
        if (digits.length() != 10) {
            return null;
        }

        return '(' + digits.substring(0, 3) + ') ' + digits.substring(3, 6) + '-' + digits.substring(6);
    }

    private static Date parsePastDate(String value) {
        Date parsed = parseDate(value);
        return parsed != null && parsed < Date.today() ? parsed : null;
    }

    /**
     * @param value A date as MM/DD/YYYY (leading zeros optional); surrounding whitespace is ignored
     * @return The date, or null when the value is blank or not a real date
     */
    public static Date parseDate(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        Matcher matcher = DATE_FORMAT.matcher(value.trim());
        if (!matcher.matches()) {
            return null;
        }

        Integer month = Integer.valueOf(matcher.group(1));
        Integer day = Integer.valueOf(matcher.group(2));
        Integer year = Integer.valueOf(matcher.group(3));

        if (month < 1 || month > 12 || day < 1 || day > Date.daysInMonth(year, month)) {
            return null;
        }
        return Date.newInstance(year, month, day);
    }

    private static String normalizeSsn(String value) {
        Matcher matcher = SSN_FORMAT.matcher(value);
        if (!matcher.matches()) {
            return null;
        }

        String area = matcher.group(1);
        String groupNumber = matcher.group(2);
        String serial = matcher.group(3);

        // Never-issued patterns. Areas 900-999 are allowed because the synthetic test data uses them.
        if (area == '000' || area == '666' || groupNumber == '00' || serial == '0000') {
            return null;
        }

        return area + '-' + groupNumber + '-' + serial;
    }

    private static String digitsOnly(String value) {
        return value.replaceAll('[^0-9]', '');
    }
}
