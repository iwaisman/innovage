/**
 * Backs the rosterIngestionRuns LWC: lists a roster's Runs and starts, promotes
 * and cancels them. Issues are shown on the Run record page.
 */
public with sharing class RosterIngestionRunController {

    /**
     * @param recordId A RosterIngestion__c Id
     * @return Its Runs, newest first
     */
    @AuraEnabled
    public static List<RosterIngestionRun__c> getRuns(Id recordId) {
        try {
            RosterIngestionRunService.failAbandonedRuns(recordId);
            return [
                SELECT Id, Name, Status__c, Dry_Run__c, Version_Number__c, CreatedDate, CreatedBy.Name,
                    Started_At__c, Completed_At__c, Total_Rows__c, Rows_Processed__c, Inserted__c, Updated__c,
                    Unchanged__c, Errored__c, Rows_With_Warnings__c, Failure_Message__c
                FROM RosterIngestionRun__c
                WHERE RosterIngestion__c = :recordId
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 50
            ];
        } catch (QueryException e) {
            throw newAuraException('Runs could not be loaded: ' + e.getMessage());
        }
    }

    /**
     * @param recordId A RosterIngestion__c Id
     * @param dryRun true for a dry run
     * @return The new Run Id
     */
    @AuraEnabled
    public static Id startRun(Id recordId, Boolean dryRun) {
        try {
            return RosterIngestionRunService.startRun(recordId, dryRun);
        } catch (RosterIngestionRunService.RunException e) {
            throw newAuraException(e.getMessage());
        }
    }

    /**
     * @param runId A completed dry-run Run
     * @return The new Run Id
     */
    @AuraEnabled
    public static Id promote(Id runId) {
        try {
            return RosterIngestionRunService.promote(runId);
        } catch (RosterIngestionRunService.RunException e) {
            throw newAuraException(e.getMessage());
        }
    }

    /**
     * @param runId A queued or running Run
     */
    @AuraEnabled
    public static void cancel(Id runId) {
        try {
            RosterIngestionRunService.cancel(runId);
        } catch (RosterIngestionRunService.RunException e) {
            throw newAuraException(e.getMessage());
        }
    }

    private static AuraHandledException newAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
