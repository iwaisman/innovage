@IsTest
private class RosterIngestionRunControllerTest {

    private static final String USER_LAST_NAME = 'RunControllerTestUser';

    @TestSetup
    static void setup() {
        User user = ProviderTestDataFactory.createIngestionUser(USER_LAST_NAME);
        Account organization = ProviderTestDataFactory.createOrganization();
        System.runAs(user) {
            RosterIngestion__c roster = ProviderTestDataFactory.createRoster(organization.Id);
            ProviderTestDataFactory.uploadPersonnelFile(
                roster,
                Blob.valueOf('Provider Unique ID,Individual NPI,Last Name\r\n,' + ProviderTestDataFactory.NPI_1 + ',ControllerNew\r\n')
            );
        }
    }

    private static Id rosterId() {
        return [SELECT Id FROM RosterIngestion__c LIMIT 1].Id;
    }

    @IsTest
    static void shouldListRuns_WhenRunStarted() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIngestionRunController.startRun(rosterId());
            Test.stopTest();

            List<RosterIngestionRun__c> runs = RosterIngestionRunController.getRuns(rosterId());
            Assert.areEqual(1, runs.size(), 'One run');
            Assert.areEqual(runId, runs[0].Id, 'The started run');
            Assert.areEqual(RosterIngestionRunService.STATUS_COMPLETED, runs[0].Status__c, 'Job completed it: ' + runs[0].Failure_Message__c);
            Assert.areEqual(1, runs[0].Inserted__c, 'Inserted one Provider');
        }
    }

    @IsTest
    static void shouldThrowAuraException_WhenStartFails() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestionRunController.startRun(rosterId());

            Test.startTest();
            try {
                RosterIngestionRunController.startRun(rosterId());
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('already in progress'), 'Passes the reason on: ' + e.getMessage());
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void shouldCancelRun_WhenRequested() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunController.startRun(rosterId());

            Test.startTest();
            RosterIngestionRunController.cancel(runId);
            Test.stopTest();

            RosterIngestionRun__c run = [SELECT Status__c, Rows_Processed__c FROM RosterIngestionRun__c WHERE Id = :runId];
            Assert.areEqual(RosterIngestionRunService.STATUS_CANCELLED, run.Status__c, 'Cancelled');
            Assert.areEqual(0, run.Rows_Processed__c, 'The batch job processed nothing');
        }
    }

    @IsTest
    static void shouldThrowAuraException_WhenCancellingFinishedRun() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIngestionRunController.startRun(rosterId());
            Test.stopTest();

            try {
                RosterIngestionRunController.cancel(runId);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('queued or running'), 'Passes the reason on: ' + e.getMessage());
            }
        }
    }
}
