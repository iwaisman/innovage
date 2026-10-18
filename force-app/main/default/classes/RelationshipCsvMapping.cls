/**
 * Reads a relationships-file row (header => value): the Provider keys, the
 * facility keys, the start date and what to do (Terminate column).
 *
 * Key values are passed on as supplied (trimmed); the matchers report
 * malformed keys themselves. A malformed start date is reported
 * (hasInvalidStartDate) so the row can be rejected and corrected.
 */
public inherited sharing class RelationshipCsvMapping {

    public static final String PROVIDER_UNIQUE_ID_HEADER = ProviderCsvMapping.UNIQUE_ID_HEADER;
    public static final String PROVIDER_NPI_HEADER = ProviderCsvMapping.NPI_HEADER;
    public static final String FACILITY_UNIQUE_ID_HEADER = 'Facility Unique ID';
    public static final String FACILITY_NPI_HEADER = 'Facility NPI';
    /* A single address line for now; may become several columns (line 2, city, state, ZIP). */
    public static final String FACILITY_ADDRESS_HEADER = 'Facility Shipping Address';
    public static final String START_DATE_HEADER = 'Relationship Start Date';
    public static final String TERMINATE_HEADER = 'Terminate';

    /**
     * Every column is required in the header, although any value may be blank,
     * so a misspelt header fails the file instead of silently reading as blank.
     */
    public static final List<String> HEADERS = new List<String>{
        PROVIDER_UNIQUE_ID_HEADER,
        PROVIDER_NPI_HEADER,
        FACILITY_UNIQUE_ID_HEADER,
        FACILITY_NPI_HEADER,
        FACILITY_ADDRESS_HEADER,
        START_DATE_HEADER,
        TERMINATE_HEADER
    };

    /** What a row asks for: blank Terminate = CREATE, "Single", "All". */
    public enum Action { CREATE, TERMINATE_SINGLE, TERMINATE_ALL }

    private static final Map<String, Action> ACTIONS_BY_TERMINATE_VALUE = new Map<String, Action>{
        'single' => Action.TERMINATE_SINGLE,
        'all' => Action.TERMINATE_ALL
    };

    /**
     * The result of reading one row.
     */
    public class MappedRow {
        public String providerUniqueId { get; private set; }
        public String providerNpi { get; private set; }
        public String facilityUniqueId { get; private set; }
        public String facilityNpi { get; private set; }
        public String facilityAddress { get; private set; }
        /** Null when blank or invalid. */
        public Date startDate { get; private set; }
        /** The start date as supplied (trimmed), or null. */
        public String rawStartDate { get; private set; }
        /** Null when the Terminate value is not recognized (see terminateValue). */
        public Action action { get; private set; }
        public String terminateValue { get; private set; }

        public Boolean hasInvalidStartDate() {
            return String.isNotBlank(rawStartDate) && startDate == null;
        }

        public Boolean hasFacilityValues() {
            return String.isNotBlank(facilityUniqueId) || String.isNotBlank(facilityNpi) ||
                String.isNotBlank(facilityAddress);
        }
    }

    /**
     * @param row One CSV row, header => value
     * @return The row's keys, start date, action and warnings
     * @throws IllegalArgumentException if row is null
     */
    public static MappedRow mapRow(Map<String, String> row) {
        if (row == null) {
            throw new IllegalArgumentException('CSV row cannot be null.');
        }

        MappedRow mapped = new MappedRow();
        mapped.providerUniqueId = row.get(PROVIDER_UNIQUE_ID_HEADER)?.trim();
        mapped.providerNpi = row.get(PROVIDER_NPI_HEADER)?.trim();
        mapped.facilityUniqueId = row.get(FACILITY_UNIQUE_ID_HEADER)?.trim();
        mapped.facilityNpi = row.get(FACILITY_NPI_HEADER)?.trim();
        mapped.facilityAddress = row.get(FACILITY_ADDRESS_HEADER)?.trim();

        mapped.rawStartDate = row.get(START_DATE_HEADER)?.trim();
        mapped.startDate = ProviderCsvMapping.parseDate(mapped.rawStartDate);

        mapped.terminateValue = row.get(TERMINATE_HEADER)?.trim();
        mapped.action = String.isBlank(mapped.terminateValue)
            ? Action.CREATE
            : ACTIONS_BY_TERMINATE_VALUE.get(mapped.terminateValue.toLowerCase());
        return mapped;
    }
}
