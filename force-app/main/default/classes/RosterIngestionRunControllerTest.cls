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
    static void shouldReturnActiveRun_WhenRunQueued() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunController.startRun(rosterId());

            Test.startTest();
            RosterIngestionRun__c active = RosterIngestionRunController.getActiveRun(rosterId());
            Test.stopTest();

            Assert.areEqual(runId, active?.Id, 'The queued run is active');
            Assert.areEqual(RosterIngestionRunService.STATUS_QUEUED, active.Status__c, 'Not started yet');
        }
    }

    @IsTest
    static void shouldReturnNoActiveRun_WhenRunFinished() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIngestionRunController.startRun(rosterId());
            Test.stopTest();

            Assert.isNull(RosterIngestionRunController.getActiveRun(rosterId()), 'A finished run is not active');
            RosterIngestionRun__c run = [SELECT Status__c, Inserted__c FROM RosterIngestionRun__c WHERE Id = :runId];
            Assert.areEqual(RosterIngestionRunService.STATUS_COMPLETED, run.Status__c, 'Job completed it');
            Assert.areEqual(1, run.Inserted__c, 'Inserted one Provider');
        }
    }

    @IsTest
    static void shouldFailStuckRun_WhenActiveRunRequested() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIngestionRunController.startRun(rosterId());
            Test.stopTest();
            // As if the batch job had died without recording it.
            Database.update(
                new RosterIngestionRun__c(Id = runId, Status__c = RosterIngestionRunService.STATUS_RUNNING),
                AccessLevel.SYSTEM_MODE
            );

            RosterIngestionRun__c active = RosterIngestionRunController.getActiveRun(rosterId());

            Assert.isNull(active, 'The stuck run is no longer shown as active');
            Assert.areEqual(
                RosterIngestionRunService.STATUS_FAILED,
                [SELECT Status__c FROM RosterIngestionRun__c WHERE Id = :runId].Status__c,
                'The stuck run was marked failed'
            );
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
