/**
 * Backs the rosterIntakeRunPanel LWC, the intake control panel on the
 * RosterIntake record page. The page has one panel per file type
 * (provider, relationships): each shows the roster's active Run of its type,
 * starts Runs and cancels them. Finished Runs are listed
 * by a standard Dynamic Related List on the same page, and each Run's Issues
 * by standard Errors and Warnings related lists on the Run record page.
 */
public with sharing class RosterIntakeRunController {

    /**
     * Fails any Run whose batch job has already ended (see
     * RosterIntakeRunService.failAbandonedRuns), so the panel never shows a
     * dead Run as active, then returns the active Run.
     *
     * @param recordId A Roster_Intake__c Id
     * @param fileType A Roster_Intake_Run__c.File_Type__c value
     * @return The roster's Queued or Running Run of that file type, or null when none is active
     */
    @AuraEnabled
    public static Roster_Intake_Run__c getActiveRun(Id recordId, String fileType) {
        try {
            RosterIntakeRunService.failAbandonedRuns(recordId);
            Set<String> activeStatuses = new Set<String>{
                RosterIntakeRunService.STATUS_QUEUED,
                RosterIntakeRunService.STATUS_RUNNING
            };
            List<Roster_Intake_Run__c> runs = [
                SELECT Id, Name, Status__c, Started_At__c, Rows_Total__c, Rows_Processed__c,
                    Rows_Inserted__c, Rows_Updated__c, Rows_Terminated__c, Rows_Unchanged__c, Rows_Errored__c, Rows_With_Warnings__c
                FROM Roster_Intake_Run__c
                WHERE Roster_Intake__c = :recordId
                    AND File_Type__c = :fileType
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
     * @param recordId A Roster_Intake__c Id
     * @param fileType A Roster_Intake_Run__c.File_Type__c value
     * @return The new Run Id
     */
    @AuraEnabled
    public static Id startRun(Id recordId, String fileType) {
        try {
            return RosterIntakeRunService.startRun(recordId, fileType);
        } catch (RosterIntakeRunService.RunException e) {
            throw newAuraException(e.getMessage());
        }
    }

    /**
     * @param runId A queued or running Run
     */
    @AuraEnabled
    public static void cancel(Id runId) {
        try {
            RosterIntakeRunService.cancel(runId);
        } catch (RosterIntakeRunService.RunException e) {
            throw newAuraException(e.getMessage());
        }
    }

    private static AuraHandledException newAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
