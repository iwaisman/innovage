/**
 * Backs the providerIngestionRuns LWC: lists a roster's Provider (personnel
 * file) Runs, starts them and cancels them. Issues are shown on the Run record
 * page, in standard Errors and Warnings related lists.
 */
public with sharing class RosterIngestionRunController {

    /**
     * @param recordId A RosterIngestion__c Id
     * @return Its Provider (personnel file) Runs, newest first. Runs of other
     *         file types, such as a future relationships ingestion, are not listed.
     */
    @AuraEnabled
    public static List<RosterIngestionRun__c> getRuns(Id recordId) {
        try {
            RosterIngestionRunService.failAbandonedRuns(recordId);
            return [
                SELECT Id, Name, Status__c, Version_Number__c, CreatedDate, CreatedBy.Name,
                    Started_At__c, Completed_At__c, Total_Rows__c, Rows_Processed__c, Inserted__c, Updated__c,
                    Unchanged__c, Errored__c, Rows_With_Warnings__c, Failure_Message__c
                FROM RosterIngestionRun__c
                WHERE RosterIngestion__c = :recordId
                    AND File_Type__c = :RosterIngestionRunService.FILE_TYPE_PERSONNEL
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
