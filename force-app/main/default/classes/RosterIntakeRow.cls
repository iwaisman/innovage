/**
 * The types shared by every roster file type's row processing (see
 * RosterRowProcessor): what a row processor receives and what it returns.
 *
 * RosterIntakeBatch turns Inputs into Results through a processor, and
 * Results into Issues and Run counts. It knows nothing about the file type.
 */
public inherited sharing class RosterIntakeRow {

    /** What happened to one row. The batch counts each into the Run field of the same meaning. */
    public enum Outcome { INSERTED, UPDATED, TERMINATED, UNCHANGED, ERROR }

    /**
     * One CSV row and its position in the file.
     */
    public class Input {
        /** The spreadsheet row number (the header is row 1); used in messages and Issues. */
        public Integer rowNumber { get; private set; }
        public Map<String, String> values { get; private set; }

        public Input(Integer rowNumber, Map<String, String> values) {
            this.rowNumber = rowNumber;
            this.values = values;
        }
    }

    /**
     * Facts about the Run that every slice needs. RosterIntakeBatch builds it
     * once in start(), lets the processor add to it (RosterRowProcessor.prepare),
     * and keeps it for every execute().
     */
    public class Context {
        public Id rosterIntakeId;
        /** The roster's Organization. */
        public Id organizationId;
        /** The date the Run started; relationships are terminated on this date. */
        public Date runDate;
        /** Relationships only: the Organization and every Organization below it (see OrganizationScope). */
        public Set<Id> organizationScope;
    }

    /**
     * A warning about one row: the row was still processed. Every file type's
     * warnings use this type, from the moment they are raised.
     */
    public class Warning {
        /** The catalog entry; its severity is always Warning. */
        public RosterIntakeIssues.Issue issue { get; private set; }
        /** The CSV column(s) concerned, or null. */
        public String column { get; private set; }
        public String message { get; private set; }

        /**
         * @throws IllegalArgumentException if issue is null or not a warning (a programming error)
         */
        public Warning(RosterIntakeIssues.Issue issue, String column, String message) {
            RosterIntakeIssues.requireSeverity(issue, RosterIntakeIssues.SEVERITY_WARNING);
            this.issue = issue;
            this.column = column;
            this.message = message;
        }

        /** The Roster_Intake_Issue__c.Code__c value. */
        public String code {
            get { return issue.code; }
        }
    }

    /**
     * What happened to one row, in the form the batch records: an outcome, the
     * error (if any), the warnings, and the key values to copy onto every Issue
     * of the row.
     */
    public class Result {
        public Integer rowNumber { get; private set; }
        public Outcome outcome { get; private set; }
        /** Why the row is an ERROR: the catalog entry; its severity is always Error. */
        public RosterIntakeIssues.Issue error { get; private set; }
        public List<String> errors { get; private set; }
        public List<Warning> warnings { get; private set; }
        /** Issue field => value, e.g. the Provider matched and the row's key values. */
        public Map<Schema.SObjectField, Object> issueValuesByField { get; private set; }

        public Result(Integer rowNumber) {
            this.rowNumber = rowNumber;
            errors = new List<String>();
            warnings = new List<Warning>();
            issueValuesByField = new Map<Schema.SObjectField, Object>();
        }

        public Boolean isError() {
            return outcome == RosterIntakeRow.Outcome.ERROR;
        }

        public void succeed(Outcome outcome) {
            this.outcome = outcome;
        }

        /** The error's Roster_Intake_Issue__c.Code__c value, or null. */
        public String errorCode {
            get { return error?.code; }
        }

        /**
         * @throws IllegalArgumentException if issue is null or not an error (a programming error)
         */
        public void fail(RosterIntakeIssues.Issue issue, String message) {
            RosterIntakeIssues.requireSeverity(issue, RosterIntakeIssues.SEVERITY_ERROR);
            outcome = RosterIntakeRow.Outcome.ERROR;
            error = issue;
            errors.add(message);
        }

        public void warn(RosterIntakeIssues.Issue issue, String column, String message) {
            warnings.add(new Warning(issue, column, message));
        }

        public void warn(Warning warning) {
            warnings.add(warning);
        }

        /** Records a value to copy onto the row's Issues; blank values are ignored. */
        public void putIssueValue(Schema.SObjectField field, Object value) {
            if (value != null && String.isNotBlank(String.valueOf(value))) {
                issueValuesByField.put(field, value);
            }
        }
    }
}
