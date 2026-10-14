/**
 * A parsed InnovAge Unique ID.
 *
 * The ID is the formula field Account.InnovAge_Unique_ID__c:
 *
 *     <record type prefix> & Unique__c & RIGHT(Id, 3)
 *
 * for example P000012345aB3. The formula is not indexed, so filtering on it
 * scans every Account. Callers should filter on the auto-number (Unique__c)
 * instead, then confirm the full ID against InnovAge_Unique_ID__c with a
 * case-sensitive comparison (the Id suffix is case-sensitive).
 */
public inherited sharing class InnovAgeUniqueId {

    public static final String PROVIDER_PREFIX = 'P';
    public static final String PROVIDER_GROUP_PREFIX = 'PG';
    public static final String PARTICIPANT_FACILITY_PREFIX = 'MF';
    public static final String ORGANIZATION_PREFIX = 'O';

    /*
     * Prefix + 9-digit auto-number + last 3 characters of the record Id.
     * The auto-number width assumes Unique__c is displayed as 9 digits.
     */
    private static final Pattern FORMAT = Pattern.compile('^(MF|PG|O|P)(\\d{9})([a-zA-Z0-9]{3})$');

    public String value { get; private set; }
    public String prefix { get; private set; }
    public String autoNumber { get; private set; }
    public String idSuffix { get; private set; }

    private InnovAgeUniqueId(String value, String prefix, String autoNumber, String idSuffix) {
        this.value = value;
        this.prefix = prefix;
        this.autoNumber = autoNumber;
        this.idSuffix = idSuffix;
    }

    /**
     * @param value A candidate InnovAge Unique ID; surrounding whitespace is ignored
     * @return The parsed ID, or null when the value is blank or malformed
     * @example
     * InnovAgeUniqueId id = InnovAgeUniqueId.parse('P000012345aB3');
     * // id.prefix == 'P', id.autoNumber == '000012345', id.idSuffix == 'aB3'
     */
    public static InnovAgeUniqueId parse(String value) {
        if (String.isBlank(value)) {
            return null;
        }

        String trimmed = value.trim();
        Matcher matcher = FORMAT.matcher(trimmed);
        if (!matcher.matches()) {
            return null;
        }

        return new InnovAgeUniqueId(trimmed, matcher.group(1), matcher.group(2), matcher.group(3));
    }

    /**
     * @param fullId The InnovAge_Unique_ID__c value of an Account
     * @return true when fullId is exactly this ID (case-sensitive)
     */
    public Boolean isSameAs(String fullId) {
        return value.equals(fullId);
    }
}
