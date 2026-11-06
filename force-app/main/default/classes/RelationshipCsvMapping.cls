/**
 * Reads a relationships-file row (header => value): the Provider keys, the
 * facility keys, the start date, what to do (Terminate column), and the
 * relationship's own fields (RELATIONSHIP_MAPPINGS).
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

    /* Optional columns: see RELATIONSHIP_MAPPINGS. */
    public static final String LIMITATIONS_HEADER = 'Limitations';
    public static final String SCHEDULING_URL_HEADER = 'Practitioner Scheduling URL';
    public static final String TELEMEDICINE_HEADER = 'Telemedicine Capability';

    /* Optional columns, used only by terminate rows; a create row that fills them in is an error. */
    public static final String TERMINATION_DATE_HEADER = 'Termination Date';
    public static final String TERMINATION_NOTES_HEADER = 'Termination Notes';

    /*
     * Termination Notes is checked like a relationship field (only its length can
     * fail), but written by terminations only, overwriting any stored notes.
     */
    public static final ProviderCsvMapping.FieldMapping TERMINATION_NOTES_MAPPING = new ProviderCsvMapping.FieldMapping(
        TERMINATION_NOTES_HEADER, HealthcarePractitionerFacility.Termination_Notes__c,
        ProviderCsvMapping.ValueType.TEXT, ProviderCsvMapping.UpdatePolicy.OVERWRITE
    );

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

    /**
     * Fields of the relationship (HealthcarePractitionerFacility) itself. The
     * columns are optional in the header. A create row writes them to a new
     * relationship, and to an existing active one as each mapping's UpdatePolicy
     * allows (compared exactly; blank values change nothing). Terminate rows
     * ignore them. Values are checked like the provider file's
     * (ProviderCsvMapping.check); an invalid one is ignored with a warning.
     *
     * "Include in Directory?" is not mapped: Include_in_Directory__c is a formula.
     */
    public static final List<ProviderCsvMapping.FieldMapping> RELATIONSHIP_MAPPINGS = new List<ProviderCsvMapping.FieldMapping>{
        new ProviderCsvMapping.FieldMapping(
            LIMITATIONS_HEADER, HealthcarePractitionerFacility.Limitations__c,
            ProviderCsvMapping.ValueType.TEXT, ProviderCsvMapping.UpdatePolicy.OVERWRITE
        ),
        // A URL field, but the value is not checked as a URL (decided 2026-11-06): only its length.
        new ProviderCsvMapping.FieldMapping(
            SCHEDULING_URL_HEADER, HealthcarePractitionerFacility.Scheduling_Site__c,
            ProviderCsvMapping.ValueType.TEXT, ProviderCsvMapping.UpdatePolicy.OVERWRITE
        ),
        new ProviderCsvMapping.FieldMapping(
            TELEMEDICINE_HEADER, HealthcarePractitionerFacility.Telemedicine_Capability__c,
            ProviderCsvMapping.ValueType.YES_NO, ProviderCsvMapping.UpdatePolicy.OVERWRITE
        )
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

        /** Valid, normalized, non-blank values of RELATIONSHIP_MAPPINGS. */
        public Map<Schema.SObjectField, Object> valuesByField { get; private set; }
        /** One INVALID_VALUE warning per invalid value of RELATIONSHIP_MAPPINGS. */
        public List<RosterIntakeRow.Warning> warnings { get; private set; }
        /** The RELATIONSHIP_MAPPINGS headers with a value, valid or not. */
        public List<String> relationshipColumnsGiven { get; private set; }

        /** Null when blank or invalid. */
        public Date terminationDate { get; private set; }
        /** The Termination Date as supplied (trimmed), or null. */
        public String rawTerminationDate { get; private set; }
        /** Valid Termination Notes (trimmed); null when blank or too long. */
        public String terminationNotes { get; private set; }
        /** Why the Termination Notes were ignored (too long), or null. */
        public RosterIntakeRow.Warning terminationNotesWarning { get; private set; }
        private Boolean hasTerminationNotes = false;

        private MappedRow() {
            valuesByField = new Map<Schema.SObjectField, Object>();
            warnings = new List<RosterIntakeRow.Warning>();
            relationshipColumnsGiven = new List<String>();
        }

        public Boolean hasInvalidTerminationDate() {
            return String.isNotBlank(rawTerminationDate) && terminationDate == null;
        }

        /** Whether the Termination Date or Termination Notes column has a value, valid or not. */
        public Boolean hasTerminationValues() {
            return String.isNotBlank(rawTerminationDate) || hasTerminationNotes;
        }

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

        mapped.rawTerminationDate = row.get(TERMINATION_DATE_HEADER)?.trim();
        mapped.terminationDate = ProviderCsvMapping.parseDate(mapped.rawTerminationDate);
        String rawNotes = row.get(TERMINATION_NOTES_HEADER)?.trim();
        if (String.isNotBlank(rawNotes)) {
            mapped.hasTerminationNotes = true;
            ProviderCsvMapping.CheckedValue checked = ProviderCsvMapping.check(TERMINATION_NOTES_MAPPING, rawNotes);
            if (checked.invalidReason != null) {
                mapped.terminationNotesWarning = new RosterIntakeRow.Warning(
                    RosterIntakeIssues.INVALID_VALUE, TERMINATION_NOTES_HEADER, 'Ignored: ' + checked.invalidReason + '.'
                );
            } else {
                mapped.terminationNotes = (String) checked.value;
            }
        }

        for (ProviderCsvMapping.FieldMapping mapping : RELATIONSHIP_MAPPINGS) {
            String header = mapping.headers[0];
            String rawValue = row.get(header)?.trim();
            if (String.isBlank(rawValue)) {
                continue;
            }
            mapped.relationshipColumnsGiven.add(header);
            ProviderCsvMapping.CheckedValue checked = ProviderCsvMapping.check(mapping, rawValue);
            if (checked.invalidReason != null) {
                mapped.warnings.add(new RosterIntakeRow.Warning(
                    RosterIntakeIssues.INVALID_VALUE, header, 'Ignored: ' + checked.invalidReason + '.'
                ));
            } else {
                mapped.valuesByField.put(mapping.field, checked.value);
            }
        }
        return mapped;
    }
}
