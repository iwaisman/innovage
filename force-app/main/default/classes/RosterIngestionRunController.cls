/**
 * Backs the providerIngestionRuns LWC, the Provider ingestion control panel on
 * the RosterIngestion record page: it shows the roster's active Provider
 * (personnel file) Run, starts Runs and cancels them. Finished Runs are listed
 * by a standard Dynamic Related List on the same page, and each Run's Issues
 * by standard Errors and Warnings related lists on the Run record page.
 */
public with sharing class RosterIngestionRunController {

    /**
     * Fails any Run whose batch job has already ended (see
     * RosterIngestionRunService.failAbandonedRuns), so the panel never shows a
     * dead Run as active, then returns the active Run.
     *
     * @param recordId A RosterIngestion__c Id
     * @return The roster's Queued or Running Provider Run, or null when none is active
     */
    @AuraEnabled
    public static RosterIngestionRun__c getActiveRun(Id recordId) {
        try {
            RosterIngestionRunService.failAbandonedRuns(recordId);
            Set<String> activeStatuses = new Set<String>{
                RosterIngestionRunService.STATUS_QUEUED,
                RosterIngestionRunService.STATUS_RUNNING
            };
            List<RosterIngestionRun__c> runs = [
                SELECT Id, Name, Status__c, Started_At__c, Total_Rows__c, Rows_Processed__c,
                    Inserted__c, Updated__c, Unchanged__c, Errored__c, Rows_With_Warnings__c
                FROM RosterIngestionRun__c
                WHERE RosterIngestion__c = :recordId
                    AND File_Type__c = :RosterIngestionRunService.FILE_TYPE_PERSONNEL
                    AND Status__c IN :activeStatuses
                WITH USER_MODE
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];
            return runs.isEmpty() ? null : runs[0];
        } catch (QueryException e) {
            throw newAuraException('The active run could not be loaded: ' + e.getMessage());
        }
    }

    /**
     * @param recordId A RosterIngestion__c Id
     * @return The new Run Id
     */
    @AuraEnabled
    public static Id startRun(Id recordId) {
        try {
            return RosterIngestionRunService.startRun(recordId);
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
