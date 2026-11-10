/**
 * The catalog of every Issue code roster intake can record on a
 * Roster_Intake_Issue__c: its severity, the file type(s) that raise it, and
 * when it is raised. Start here to see, add or change what intake reports.
 *
 *     Error    the row was not ingested
 *     Warning  the row was ingested, but a value was ignored or something needs attention
 *
 * The conditions themselves live in the logic that detects them; "find usages"
 * on an entry leads to every place it is raised. Issues are raised with an
 * entry, never a bare code:
 *
 *     result.fail(RosterIntakeIssues.SAVE_ERROR, message)                  RosterIntakeRow.Result
 *     result.warn(RosterIntakeIssues.START_DATE_IGNORED, column, message)   RosterIntakeRow.Result
 *     new RosterIntakeRow.Warning(RosterIntakeIssues.INVALID_VALUE, column, message)
 *
 * The severity declared here is enforced there (requireSeverity), and
 * RosterIntakeBatch writes each Issue's Code__c and Severity__c from its entry.
 * Messages are written where the Issue is raised, since many depend on what
 * was found; they must never contain sensitive values (SSN, date of birth).
 *
 * ADDING A CODE: declare it below, add it to ALL, and add the same value to the
 * restricted Roster_Intake_Issue__c.Code__c picklist. A code missing from the
 * picklist makes the Issue insert, and so the whole slice, fail;
 * RosterIntakeIssuesTest checks the two lists match.
 *
 * The matching codes (NO_KEY_VALUES ... KEY_MISMATCH) are the names of the
 * AccountMatchResult.Outcome error values, which are recorded as they are.
 */
public inherited sharing class RosterIntakeIssues {

    /* Roster_Intake_Issue__c.Severity__c values. */
    public static final String SEVERITY_ERROR = 'Error';
    public static final String SEVERITY_WARNING = 'Warning';

    public enum FileType { BOTH, PROVIDER, RELATIONSHIPS }

    /**
     * One Issue code.
     */
    public class Issue {
        /** The Roster_Intake_Issue__c.Code__c value. */
        public String code { get; private set; }
        /** SEVERITY_ERROR or SEVERITY_WARNING. */
        public String severity { get; private set; }
        public FileType fileType { get; private set; }
        /** When the Issue is raised, for people reading the catalog. */
        public String raisedWhen { get; private set; }

        private Issue(String code, String severity, FileType fileType, String raisedWhen) {
            this.code = code;
            this.severity = severity;
            this.fileType = fileType;
            this.raisedWhen = raisedWhen;
        }
    }

    // ─── Both files: file format ───────────────────────────────────────

    public static final Issue COLUMN_COUNT = new Issue('COLUMN_COUNT', SEVERITY_ERROR, FileType.BOTH,
        'A row has a different number of columns from the header (RosterIntakeBatch).');

    // ─── Both files: Provider matching (AccountMatchResult.Outcome names) ──

    public static final Issue NO_KEY_VALUES = new Issue('NO_KEY_VALUES', SEVERITY_ERROR, FileType.BOTH,
        'Neither a Provider Unique ID nor an NPI is given (ProviderMatcher).');
    public static final Issue MALFORMED_UNIQUE_ID = new Issue('MALFORMED_UNIQUE_ID', SEVERITY_ERROR, FileType.BOTH,
        'The Provider Unique ID is not a well-formed Provider ID (ProviderMatcher).');
    public static final Issue MALFORMED_NPI = new Issue('MALFORMED_NPI', SEVERITY_ERROR, FileType.BOTH,
        'The Individual NPI is not 10 digits with a valid check digit (ProviderMatcher).');
    public static final Issue UNKNOWN_UNIQUE_ID = new Issue('UNKNOWN_UNIQUE_ID', SEVERITY_ERROR, FileType.BOTH,
        'No Provider has the given Provider Unique ID (ProviderMatcher).');
    public static final Issue MULTIPLE_MATCHES = new Issue('MULTIPLE_MATCHES', SEVERITY_ERROR, FileType.BOTH,
        'The Unique ID and the NPI identify different Providers (ProviderMatcher).');
    public static final Issue KEY_MISMATCH = new Issue('KEY_MISMATCH', SEVERITY_ERROR, FileType.BOTH,
        'The Provider found by Unique ID has a different stored NPI (ProviderMatcher).');

    // ─── Both files: saving ────────────────────────────────────────────

    public static final Issue SAVE_ERROR = new Issue('SAVE_ERROR', SEVERITY_ERROR, FileType.BOTH,
        'Salesforce rejected the save of the Provider (ProviderIntakeService) or the relationship '
        + '(RelationshipIntakeService), e.g. a validation rule, a duplicate value or a failing flow.');

    // ─── Provider file ─────────────────────────────────────────────────

    public static final Issue MISSING_LAST_NAME = new Issue('MISSING_LAST_NAME', SEVERITY_ERROR, FileType.PROVIDER,
        'A new Provider would be created without a valid Last Name (ProviderIntakeService).');
    public static final Issue LAST_NAME_DIFFERS = new Issue('LAST_NAME_DIFFERS', SEVERITY_WARNING, FileType.PROVIDER,
        'An existing Provider\'s Last Name differs from the file\'s, compared exactly; Last Name is insert-only, '
        + 'so it is not changed (ProviderIntakeService.warnIfLastNameDiffers).');
    public static final Issue INVALID_VALUE = new Issue('INVALID_VALUE', SEVERITY_WARNING, FileType.BOTH,
        'A value fails its column\'s validation (ValueType) or is longer than its field, and is ignored '
        + '(ProviderCsvMapping.check, from ProviderCsvMapping.mapRow and RelationshipCsvMapping.mapRow).');
    public static final Issue ADDRESS_NOT_UPDATED = new Issue('ADDRESS_NOT_UPDATED', SEVERITY_WARNING, FileType.PROVIDER,
        'An existing Provider\'s address is not updated because a part is invalid, blank in the file but not '
        + 'on the Provider, or Line 2 is given without Line 1 (ProviderCsvMapping.AddressGroup, '
        + 'ProviderIntakeService.rejectAddresses).');
    public static final Issue HEALTHCARE_PROVIDER_NOT_SAVED = new Issue(
        'HEALTHCARE_PROVIDER_NOT_SAVED', SEVERITY_WARNING, FileType.PROVIDER,
        'A HealthcareProvider column could not be written: the Provider has no HealthcareProvider, or it failed '
        + 'to save (HealthcareProviderFieldService). The Provider itself is saved.');
    public static final Issue UNKNOWN_SPECIALTY = new Issue('UNKNOWN_SPECIALTY', SEVERITY_WARNING, FileType.PROVIDER,
        'A specialty value has no taxonomy code, or no NUCC taxonomy has the code (ProviderSpecialtyService).');
    public static final Issue AMBIGUOUS_SPECIALTY = new Issue('AMBIGUOUS_SPECIALTY', SEVERITY_WARNING, FileType.PROVIDER,
        'Several NUCC taxonomy records share the specialty\'s code (ProviderSpecialtyService).');
    public static final Issue SPECIALTY_NOT_SAVED = new Issue('SPECIALTY_NOT_SAVED', SEVERITY_WARNING, FileType.PROVIDER,
        'A specialty link could not be saved, or the Provider has no HealthcareProvider '
        + '(ProviderSpecialtyService). The Provider itself is saved.');

    // ─── Relationships file: the row ───────────────────────────────────

    public static final Issue INVALID_TERMINATE_VALUE = new Issue(
        'INVALID_TERMINATE_VALUE', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'Terminate is not blank, Single or All (RelationshipIntakeService).');
    public static final Issue INVALID_START_DATE = new Issue('INVALID_START_DATE', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'A create row has a malformed Relationship Start Date (RelationshipIntakeService).');
    public static final Issue TERMINATION_COLUMNS_ON_CREATE_ROW = new Issue(
        'TERMINATION_COLUMNS_ON_CREATE_ROW', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'A create row (Terminate blank) gives a Termination Date or Termination Notes (RelationshipIntakeService).');
    public static final Issue INVALID_TERMINATION_DATE = new Issue(
        'INVALID_TERMINATION_DATE', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'A terminate row has a malformed Termination Date (RelationshipIntakeService).');
    public static final Issue TERMINATION_BEFORE_START = new Issue(
        'TERMINATION_BEFORE_START', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'A termination would end a relationship before its start date; with Terminate = All, nothing is '
        + 'terminated if any relationship would (RelationshipIntakeService).');
    public static final Issue START_DATE_IGNORED = new Issue('START_DATE_IGNORED', SEVERITY_WARNING, FileType.RELATIONSHIPS,
        'A terminate row gives a Relationship Start Date, which terminations ignore (RelationshipIntakeService).');
    public static final Issue RELATIONSHIP_COLUMNS_IGNORED = new Issue(
        'RELATIONSHIP_COLUMNS_IGNORED', SEVERITY_WARNING, FileType.RELATIONSHIPS,
        'A terminate row fills in relationship field columns (Limitations, Practitioner Scheduling URL, '
        + 'Telemedicine Capability), which terminations ignore (RelationshipIntakeService).');
    public static final Issue FACILITY_COLUMNS_IGNORED = new Issue(
        'FACILITY_COLUMNS_IGNORED', SEVERITY_WARNING, FileType.RELATIONSHIPS,
        'A Terminate = All row fills in facility columns, which it ignores (RelationshipIntakeService).');

    // ─── Relationships file: the Provider ──────────────────────────────

    public static final Issue UNKNOWN_PROVIDER = new Issue('UNKNOWN_PROVIDER', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'No Provider matches the row; this file never creates Providers (RelationshipIntakeService).');
    public static final Issue PROVIDER_NOT_SET_UP = new Issue('PROVIDER_NOT_SET_UP', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'The Provider has no HealthcareProvider (RelationshipIntakeService).');

    // ─── Relationships file: the facility (FacilityMatcher) ────────────

    public static final Issue NO_FACILITY_KEY_VALUES = new Issue(
        'NO_FACILITY_KEY_VALUES', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'A create or Terminate = Single row gives no Facility Unique ID, Facility NPI or address (FacilityMatcher).');
    public static final Issue MALFORMED_FACILITY_UNIQUE_ID = new Issue(
        'MALFORMED_FACILITY_UNIQUE_ID', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'The Facility Unique ID is not a well-formed facility ID (FacilityMatcher).');
    public static final Issue MALFORMED_FACILITY_NPI = new Issue(
        'MALFORMED_FACILITY_NPI', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'The Facility NPI is not 10 digits with a valid check digit (FacilityMatcher).');
    public static final Issue UNKNOWN_FACILITY_UNIQUE_ID = new Issue(
        'UNKNOWN_FACILITY_UNIQUE_ID', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'No facility has the given Facility Unique ID (FacilityMatcher).');
    public static final Issue FACILITY_KEY_MISMATCH = new Issue(
        'FACILITY_KEY_MISMATCH', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'The facility found by the first key disagrees with another key given (FacilityMatcher).');
    public static final Issue MULTIPLE_FACILITY_MATCHES = new Issue(
        'MULTIPLE_FACILITY_MATCHES', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'The Facility NPI or address matches several facilities in the roster\'s scope (FacilityMatcher).');
    public static final Issue FACILITY_NOT_FOUND = new Issue('FACILITY_NOT_FOUND', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'No facility in the roster\'s scope has the Facility NPI or address (FacilityMatcher).');
    public static final Issue FACILITY_NOT_SET_UP = new Issue('FACILITY_NOT_SET_UP', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'The facility has no HealthcareFacility (FacilityMatcher).');
    public static final Issue FACILITY_NOT_IN_ORGANIZATION = new Issue(
        'FACILITY_NOT_IN_ORGANIZATION', SEVERITY_ERROR, FileType.RELATIONSHIPS,
        'The facility\'s Legal Owner is blank or outside the roster\'s Organization scope (FacilityMatcher).');

    // ─── Relationships file: the relationship ──────────────────────────

    public static final Issue NO_ACTIVE_RELATIONSHIP = new Issue(
        'NO_ACTIVE_RELATIONSHIP', SEVERITY_WARNING, FileType.RELATIONSHIPS,
        'A terminate row finds no active relationship to end (RelationshipIntakeService).');
    public static final Issue MULTIPLE_ACTIVE_RELATIONSHIPS = new Issue(
        'MULTIPLE_ACTIVE_RELATIONSHIPS', SEVERITY_WARNING, FileType.RELATIONSHIPS,
        'Several active relationships exist for one Provider and facility (RelationshipIntakeService).');
    public static final Issue START_DATE_DIFFERS = new Issue('START_DATE_DIFFERS', SEVERITY_WARNING, FileType.RELATIONSHIPS,
        'A create row\'s start date differs from the existing active relationship\'s and cannot replace it: '
        + 'the relationship has already started (or has no start date), or would then start after its '
        + 'Termination Date (RelationshipIntakeService.updateStartDate).');

    /** Every entry above. */
    public static final List<Issue> ALL = new List<Issue>{
        COLUMN_COUNT,
        NO_KEY_VALUES, MALFORMED_UNIQUE_ID, MALFORMED_NPI, UNKNOWN_UNIQUE_ID, MULTIPLE_MATCHES, KEY_MISMATCH,
        SAVE_ERROR,
        MISSING_LAST_NAME, LAST_NAME_DIFFERS, INVALID_VALUE, ADDRESS_NOT_UPDATED, HEALTHCARE_PROVIDER_NOT_SAVED,
        UNKNOWN_SPECIALTY, AMBIGUOUS_SPECIALTY, SPECIALTY_NOT_SAVED,
        INVALID_TERMINATE_VALUE, INVALID_START_DATE, START_DATE_IGNORED, FACILITY_COLUMNS_IGNORED,
        TERMINATION_COLUMNS_ON_CREATE_ROW, INVALID_TERMINATION_DATE, TERMINATION_BEFORE_START,
        RELATIONSHIP_COLUMNS_IGNORED,
        UNKNOWN_PROVIDER, PROVIDER_NOT_SET_UP,
        NO_FACILITY_KEY_VALUES, MALFORMED_FACILITY_UNIQUE_ID, MALFORMED_FACILITY_NPI, UNKNOWN_FACILITY_UNIQUE_ID,
        FACILITY_KEY_MISMATCH, MULTIPLE_FACILITY_MATCHES, FACILITY_NOT_FOUND, FACILITY_NOT_SET_UP,
        FACILITY_NOT_IN_ORGANIZATION,
        NO_ACTIVE_RELATIONSHIP, MULTIPLE_ACTIVE_RELATIONSHIPS, START_DATE_DIFFERS
    };

    /**
     * Guards the places that record Issues: an error must be raised as an error,
     * a warning as a warning, as the catalog declares.
     *
     * @param issue The entry being raised
     * @param severity SEVERITY_ERROR or SEVERITY_WARNING, the way it is being raised
     * @throws IllegalArgumentException if issue is null or has another severity (a programming error)
     */
    public static void requireSeverity(Issue issue, String severity) {
        if (issue?.severity != severity) {
            throw new IllegalArgumentException(
                (issue?.code ?? 'null') + ' is declared as ' + issue?.severity + ' in RosterIntakeIssues, '
                + 'but is being raised as ' + severity + '.'
            );
        }
    }

    /**
     * @param outcome An AccountMatchResult error outcome (not UNIQUE_MATCH or NO_MATCH)
     * @return Its catalog entry
     * @throws IllegalArgumentException if the outcome has no entry
     */
    public static Issue forMatchOutcome(AccountMatchResult.Outcome outcome) {
        Issue issue = forCode(outcome?.name());
        if (issue == null) {
            throw new IllegalArgumentException('No Issue for match outcome ' + outcome + '.');
        }
        return issue;
    }

    private static Map<String, Issue> issuesByCode;

    /**
     * @param code A Roster_Intake_Issue__c.Code__c value
     * @return The catalog entry, or null when the code is not in the catalog
     */
    public static Issue forCode(String code) {
        if (issuesByCode == null) {
            issuesByCode = new Map<String, Issue>();
            for (Issue issue : ALL) {
                issuesByCode.put(issue.code, issue);
            }
        }
        return issuesByCode.get(code);
    }
}
