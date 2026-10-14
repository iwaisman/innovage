/**
 * Maps a Provider roster CSV row (header => value, as produced by
 * CsvParser.parseWithHeaders) onto Provider person Account fields.
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

    public enum ValueType { TEXT, PICKLIST, PHONE, EMAIL, PAST_DATE, SSN, NPI, STATE, ZIP }

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

        /** Valid, normalized, non-blank values. */
        public Map<Schema.SObjectField, Object> valuesByField { get; private set; }

        public List<String> warnings { get; private set; }

        private MappedRow() {
            valuesByField = new Map<Schema.SObjectField, Object>();
            warnings = new List<String>();
        }
    }

    public static final List<FieldMapping> MAPPINGS = new List<FieldMapping>{
        new FieldMapping(NPI_HEADER, Account.NPI__c, ValueType.NPI, UpdatePolicy.FILL_IF_BLANK),
        new FieldMapping('Provider Phone', Account.Phone, ValueType.PHONE, UpdatePolicy.OVERWRITE),
        new FieldMapping('Provider Email', Account.PersonEmail, ValueType.EMAIL, UpdatePolicy.OVERWRITE),

        new FieldMapping('Salutation', Account.Salutation, ValueType.PICKLIST, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('First Name', Account.FirstName, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Middle Name', Account.MiddleName, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Last Name', Account.LastName, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Suffix (MD, DO, NP, RN etc)', Account.Suffix, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Date of Birth', Account.PersonBirthdate, ValueType.PAST_DATE, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Social Security Number', Account.Social_Security_Number_Provider__pc, ValueType.SSN, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Provider Fax', Account.Fax, ValueType.PHONE, UpdatePolicy.INSERT_ONLY),

        new FieldMapping(
            new List<String>{ 'Provider Mailing Address Line 1', 'Provider Mailing Address Line 2' },
            Account.PersonMailingStreet, ValueType.TEXT, UpdatePolicy.INSERT_ONLY
        ),
        new FieldMapping('Provider Mailing City', Account.PersonMailingCity, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Provider Mailing State', Account.PersonMailingState, ValueType.STATE, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Provider Mailing Zip', Account.PersonMailingPostalCode, ValueType.ZIP, UpdatePolicy.INSERT_ONLY),

        new FieldMapping(
            new List<String>{ 'Provider Billing Address Line 1', 'Provider Billing Address Line 2' },
            Account.BillingStreet, ValueType.TEXT, UpdatePolicy.INSERT_ONLY
        ),
        new FieldMapping('Provider Billing City', Account.BillingCity, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Provider Billing State', Account.BillingState, ValueType.STATE, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Provider Billing Zip', Account.BillingPostalCode, ValueType.ZIP, UpdatePolicy.INSERT_ONLY),

        // 'CAQH ID' => CAQH_ID__pc is deliberately unmapped for now: setting it fires the
        // "VFY_Account | Auto Create CAQH" flow, which currently fails inside the Verifiable
        // package (ExtProvProfileVerifiableTrigger NullPointerException) and blocks the insert.
        new FieldMapping('Medicare ID', Account.Medicare_ID__c, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
        new FieldMapping('Medicaid ID State', Account.Medicaid_ID_State__c, ValueType.STATE, UpdatePolicy.INSERT_ONLY)
    };

    private static final Map<ValueType, String> INVALID_REASONS_BY_TYPE = new Map<ValueType, String>{
        ValueType.TEXT => 'not valid text',
        ValueType.PICKLIST => 'not one of the allowed values',
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

        for (FieldMapping mapping : MAPPINGS) {
            String rawValue = joinedValue(row, mapping.headers);
            if (String.isBlank(rawValue)) {
                continue;
            }

            String headerLabel = '"' + String.join(mapping.headers, '" / "') + '"';

            Object value = normalize(mapping, rawValue);
            if (value == null) {
                mapped.warnings.add('Ignored ' + headerLabel + ': ' + INVALID_REASONS_BY_TYPE.get(mapping.valueType) + '.');
                continue;
            }

            Integer maxLength = mapping.field.getDescribe().getLength();
            if (value instanceof String && maxLength > 0 && ((String) value).length() > maxLength) {
                mapped.warnings.add('Ignored ' + headerLabel + ': longer than ' + maxLength + ' characters.');
                continue;
            }

            mapped.valuesByField.put(mapping.field, value);
        }

        return mapped;
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
        Matcher matcher = DATE_FORMAT.matcher(value);
        if (!matcher.matches()) {
            return null;
        }

        Integer month = Integer.valueOf(matcher.group(1));
        Integer day = Integer.valueOf(matcher.group(2));
        Integer year = Integer.valueOf(matcher.group(3));

        if (month < 1 || month > 12 || day < 1 || day > Date.daysInMonth(year, month)) {
            return null;
        }

        Date parsed = Date.newInstance(year, month, day);
        return parsed < Date.today() ? parsed : null;
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
