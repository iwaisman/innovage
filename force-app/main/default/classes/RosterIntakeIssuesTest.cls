@IsTest
private class RosterIntakeIssuesTest {

    private static Set<String> activePicklistValues(Schema.SObjectField field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry entry : field.getDescribe().getPicklistValues()) {
            if (entry.isActive()) {
                values.add(entry.getValue());
            }
        }
        return values;
    }

    private static Set<String> catalogCodes() {
        Set<String> codes = new Set<String>();
        for (RosterIntakeIssues.Issue issue : RosterIntakeIssues.ALL) {
            codes.add(issue.code);
        }
        return codes;
    }

    /*
     * A code raised but missing from the restricted picklist makes the Issue insert,
     * and so the whole slice, fail. A picklist value missing from the catalog is
     * usually an entry declared but not added to ALL.
     */
    @IsTest
    static void shouldMatchCodePicklist_InBothDirections() {
        Set<String> picklist = activePicklistValues(Roster_Intake_Issue__c.Code__c);
        Set<String> catalog = catalogCodes();

        Set<String> missingFromPicklist = new Set<String>(catalog);
        missingFromPicklist.removeAll(picklist);
        Set<String> missingFromCatalog = new Set<String>(picklist);
        missingFromCatalog.removeAll(catalog);

        Assert.isTrue(missingFromPicklist.isEmpty(), 'Add to the Code__c picklist: ' + missingFromPicklist);
        Assert.isTrue(missingFromCatalog.isEmpty(), 'Add to RosterIntakeIssues (and ALL): ' + missingFromCatalog);
    }

    @IsTest
    static void shouldUseSeverityPicklistValues() {
        Set<String> severities = activePicklistValues(Roster_Intake_Issue__c.Severity__c);

        Assert.areEqual(
            new Set<String>{ RosterIntakeIssues.SEVERITY_ERROR, RosterIntakeIssues.SEVERITY_WARNING },
            severities,
            'The Severity__c picklist values'
        );
        for (RosterIntakeIssues.Issue issue : RosterIntakeIssues.ALL) {
            Assert.isTrue(severities.contains(issue.severity), issue.code + ' has severity ' + issue.severity);
        }
    }

    @IsTest
    static void shouldDeclareEachCodeOnceWithItsCondition() {
        Set<String> seen = new Set<String>();
        for (RosterIntakeIssues.Issue issue : RosterIntakeIssues.ALL) {
            Assert.isNotNull(issue, 'ALL lists an entry declared after it');
            Assert.isTrue(seen.add(issue.code), 'Duplicate code ' + issue.code);
            Assert.isTrue(String.isNotBlank(issue.raisedWhen), issue.code + ' says when it is raised');
            Assert.isNotNull(issue.fileType, issue.code + ' has a file type');
        }
    }

    /* ProviderMatcher's error outcomes are recorded under their names. */
    @IsTest
    static void shouldCatalogEveryMatchErrorOutcome() {
        for (AccountMatchResult.Outcome outcome : AccountMatchResult.Outcome.values()) {
            if (outcome == AccountMatchResult.Outcome.UNIQUE_MATCH || outcome == AccountMatchResult.Outcome.NO_MATCH) {
                continue;
            }
            RosterIntakeIssues.Issue issue = RosterIntakeIssues.forCode(outcome.name());
            Assert.isNotNull(issue, outcome.name() + ' is in the catalog');
            Assert.areEqual(RosterIntakeIssues.SEVERITY_ERROR, issue.severity, outcome.name() + ' is an error');
        }
    }

    // ─── Severity is enforced where Issues are raised ──────────────────

    @IsTest
    static void shouldRejectError_WhenRaisedAsWarning() {
        try {
            new RosterIntakeRow.Warning(RosterIntakeIssues.SAVE_ERROR, null, 'message');
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('SAVE_ERROR'), 'Names the code: ' + e.getMessage());
        }
    }

    @IsTest
    static void shouldRejectWarning_WhenRaisedAsError() {
        RosterIntakeRow.Result result = new RosterIntakeRow.Result(2);
        try {
            result.fail(RosterIntakeIssues.INVALID_VALUE, 'message');
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('INVALID_VALUE'), 'Names the code: ' + e.getMessage());
        }
        Assert.isFalse(result.isError(), 'The row is not failed');
    }

    @IsTest
    static void shouldRecordIssueOnResult_WhenSeverityMatches() {
        RosterIntakeRow.Result result = new RosterIntakeRow.Result(2);

        result.warn(RosterIntakeIssues.INVALID_VALUE, 'Provider Email', 'Ignored.');
        result.fail(RosterIntakeIssues.SAVE_ERROR, 'Rejected.');

        Assert.areEqual('INVALID_VALUE', result.warnings[0].code, 'Warning code');
        Assert.areEqual(RosterIntakeIssues.SAVE_ERROR, result.error, 'Error entry');
        Assert.areEqual('SAVE_ERROR', result.errorCode, 'Error code');
    }

    @IsTest
    static void shouldRejectNullIssue() {
        try {
            RosterIntakeIssues.requireSeverity(null, RosterIntakeIssues.SEVERITY_ERROR);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('null'), 'Message: ' + e.getMessage());
        }
    }

    @IsTest
    static void shouldMapMatchOutcomeToIssue() {
        Assert.areEqual(
            RosterIntakeIssues.KEY_MISMATCH,
            RosterIntakeIssues.forMatchOutcome(AccountMatchResult.Outcome.KEY_MISMATCH),
            'Error outcome'
        );
        try {
            RosterIntakeIssues.forMatchOutcome(AccountMatchResult.Outcome.UNIQUE_MATCH);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('UNIQUE_MATCH'), 'Message: ' + e.getMessage());
        }
    }

    @IsTest
    static void shouldFindIssueByCode() {
        Assert.areEqual(RosterIntakeIssues.SAVE_ERROR, RosterIntakeIssues.forCode('SAVE_ERROR'), 'Known code');
        Assert.isNull(RosterIntakeIssues.forCode('NOT_A_CODE'), 'Unknown code');
    }
}
