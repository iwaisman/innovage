@IsTest
private class RosterIngestionIssueControllerTest {

    private static final String USER_LAST_NAME = 'IssueControllerTestUser';
    private static final String PROVIDER = 'IssueProvider';

    /*
     * Issues of the test Run: row numbers and their severities, by position.
     * Row 3 has two Issues, so paging must order ties by Id.
     */
    private static final List<Integer> ISSUE_ROWS = new List<Integer>{ 2, 3, 3, 5, 6 };
    private static final List<String> ISSUE_SEVERITIES = new List<String>{
        RosterIngestionRunService.SEVERITY_ERROR,
        RosterIngestionRunService.SEVERITY_ERROR,
        RosterIngestionRunService.SEVERITY_WARNING,
        RosterIngestionRunService.SEVERITY_WARNING,
        RosterIngestionRunService.SEVERITY_ERROR
    };

    @TestSetup
    static void setup() {
        User user = ProviderTestDataFactory.createIngestionUser(USER_LAST_NAME);
        Account provider = ProviderTestDataFactory.createProvider(PROVIDER, ProviderTestDataFactory.NPI_1, true);
        Account organization = ProviderTestDataFactory.createOrganization();
        System.runAs(user) {
            RosterIngestion__c roster = ProviderTestDataFactory.createRoster(organization.Id);
            // Runs and Issues are written by the ingestion code in system mode; users can only read them.
            RosterIngestionRun__c run = new RosterIngestionRun__c(
                RosterIngestion__c = roster.Id,
                File_Type__c = RosterIngestionRunService.FILE_TYPE_PERSONNEL,
                Status__c = RosterIngestionRunService.STATUS_COMPLETED_WITH_ERRORS
            );
            Database.insert(run, AccessLevel.SYSTEM_MODE);

            List<RosterIngestionIssue__c> issues = new List<RosterIngestionIssue__c>();
            for (Integer i = 0; i < ISSUE_ROWS.size(); i++) {
                issues.add(new RosterIngestionIssue__c(
                    RosterIngestionRun__c = run.Id,
                    Row_Number__c = ISSUE_ROWS[i],
                    Severity__c = ISSUE_SEVERITIES[i],
                    Code__c = 'INVALID_VALUE',
                    Message__c = 'Issue on row ' + ISSUE_ROWS[i],
                    Provider__c = ISSUE_ROWS[i] == 2 ? provider.Id : null
                ));
            }
            Database.insert(issues, AccessLevel.SYSTEM_MODE);
        }
    }

    private static Id runId() {
        return [SELECT Id FROM RosterIngestionRun__c LIMIT 1].Id;
    }

    private static List<Integer> rowNumbers(List<RosterIngestionIssue__c> issues) {
        List<Integer> rows = new List<Integer>();
        for (RosterIngestionIssue__c issue : issues) {
            rows.add(issue.Row_Number__c.intValue());
        }
        return rows;
    }

    @IsTest
    static void shouldReturnAllIssuesInRowOrder_WhenNoFilter() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            RosterIngestionIssueController.IssuePage page = RosterIngestionIssueController.getIssues(runId(), '', null, null);
            Test.stopTest();

            Assert.areEqual(new List<Integer>{ 2, 3, 3, 5, 6 }, rowNumbers(page.issues), 'Every Issue, in row order');
            Assert.areEqual(5, page.totalCount, 'Total count');
            Assert.isTrue(page.issues[0].Provider__r.Name.contains(PROVIDER), 'Provider name is returned: ' + page.issues[0].Provider__r?.Name);
        }
    }

    @IsTest
    static void shouldReturnOnlyErrors_WhenFilteredBySeverity() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            RosterIngestionIssueController.IssuePage page = RosterIngestionIssueController.getIssues(
                runId(),
                RosterIngestionRunService.SEVERITY_ERROR,
                null,
                null
            );
            Test.stopTest();

            Assert.areEqual(new List<Integer>{ 2, 3, 6 }, rowNumbers(page.issues), 'Only the errors');
            Assert.areEqual(3, page.totalCount, 'Total counts only the errors');
        }
    }

    @IsTest
    static void shouldContinueAfterLastIssue_WhenLoadingMore() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestionIssueController.pageSize = 2;
            Set<Id> seen = new Set<Id>();
            List<Integer> rows = new List<Integer>();

            Test.startTest();
            RosterIngestionIssueController.IssuePage page = RosterIngestionIssueController.getIssues(runId(), '', null, null);
            while (!page.issues.isEmpty()) {
                for (RosterIngestionIssue__c issue : page.issues) {
                    Assert.isTrue(seen.add(issue.Id), 'No Issue is returned twice');
                }
                rows.addAll(rowNumbers(page.issues));
                RosterIngestionIssue__c last = page.issues[page.issues.size() - 1];
                page = RosterIngestionIssueController.getIssues(runId(), '', last.Row_Number__c, last.Id);
            }
            Test.stopTest();

            Assert.areEqual(new List<Integer>{ 2, 3, 3, 5, 6 }, rows, 'Pages cover every Issue in order, including the tie on row 3');
        }
    }

    @IsTest
    static void shouldThrowAuraException_WhenSeverityUnknown() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            try {
                RosterIngestionIssueController.getIssues(runId(), 'Fatal', null, null);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Fatal'), 'Names the bad value: ' + e.getMessage());
            }
            Test.stopTest();
        }
    }
}
