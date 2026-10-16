/**
 * Backs the rosterIngestionIssues LWC on the Run record page: returns a Run's
 * Issues one page at a time, in row order, optionally only Errors or Warnings.
 *
 * Pages continue after the last Issue already shown (its row number and Id)
 * rather than using OFFSET, because SOQL caps OFFSET at 2,000 rows and a large
 * file can produce more Issues than that.
 */
public with sharing class RosterIngestionIssueController {

    @TestVisible
    private static Integer pageSize = 500;

    private static final Set<String> SEVERITIES = new Set<String>{
        RosterIngestionRunService.SEVERITY_ERROR,
        RosterIngestionRunService.SEVERITY_WARNING
    };

    /**
     * One page of Issues and how many Issues match the filter in total.
     */
    public class IssuePage {
        @AuraEnabled
        public List<RosterIngestionIssue__c> issues;
        @AuraEnabled
        public Integer totalCount;
    }

    /**
     * @param runId The RosterIngestionRun__c
     * @param severity 'Error' or 'Warning' to show only those; blank for all
     * @param afterRowNumber Row number of the last Issue already shown; null for the first page
     * @param afterIssueId Id of the last Issue already shown; null for the first page
     * @return The next page of Issues, ordered by row number
     */
    @AuraEnabled
    public static IssuePage getIssues(Id runId, String severity, Decimal afterRowNumber, Id afterIssueId) {
        if (String.isNotBlank(severity) && !SEVERITIES.contains(severity)) {
            throw newAuraException('Unknown severity: ' + severity);
        }

        Map<String, Object> bindsByName = new Map<String, Object>{
            'runId' => runId,
            'severity' => severity,
            'afterRowNumber' => afterRowNumber,
            'afterIssueId' => afterIssueId,
            'pageSize' => pageSize
        };
        String filter = ' WHERE RosterIngestionRun__c = :runId' +
            (String.isBlank(severity) ? '' : ' AND Severity__c = :severity');
        String after = afterIssueId == null
            ? ''
            : ' AND (Row_Number__c > :afterRowNumber OR (Row_Number__c = :afterRowNumber AND Id > :afterIssueId))';

        try {
            IssuePage page = new IssuePage();
            page.issues = Database.queryWithBinds(
                'SELECT Id, Row_Number__c, Severity__c, Code__c, Column__c, Message__c, Provider__c, Provider__r.Name' +
                ' FROM RosterIngestionIssue__c' + filter + after +
                ' ORDER BY Row_Number__c, Id LIMIT :pageSize',
                bindsByName,
                AccessLevel.USER_MODE
            );
            page.totalCount = Database.countQueryWithBinds(
                'SELECT COUNT() FROM RosterIngestionIssue__c' + filter,
                bindsByName,
                AccessLevel.USER_MODE
            );
            return page;
        } catch (QueryException e) {
            throw newAuraException('Issues could not be loaded: ' + e.getMessage());
        }
    }

    private static AuraHandledException newAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
