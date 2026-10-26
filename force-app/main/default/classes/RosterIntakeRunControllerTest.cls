@IsTest
private class RosterIntakeRunControllerTest {

    private static final String USER_LAST_NAME = 'RunControllerTestUser';

    @TestSetup
    static void setup() {
        User user = ProviderTestDataFactory.createIntakeUser(USER_LAST_NAME);
        Account organization = ProviderTestDataFactory.createOrganization();
        System.runAs(user) {
            Roster_Intake__c roster = ProviderTestDataFactory.createRoster(organization.Id);
            ProviderTestDataFactory.uploadProviderFile(
                roster,
                Blob.valueOf('Provider Unique ID,Individual NPI,Last Name\r\n,' + ProviderTestDataFactory.NPI_1 + ',ControllerNew\r\n')
            );
        }
    }

    private static Id rosterId() {
        return [SELECT Id FROM Roster_Intake__c LIMIT 1].Id;
    }

    @IsTest
    static void shouldReturnActiveRun_WhenRunQueued() {
        System.runAs(ProviderTestDataFactory.intakeUser(USER_LAST_NAME)) {
            Id runId = RosterIntakeRunController.startRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);

            Test.startTest();
            Roster_Intake_Run__c active = RosterIntakeRunController.getActiveRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);
            Test.stopTest();

            Assert.areEqual(runId, active?.Id, 'The queued run is active');
            Assert.areEqual(RosterIntakeRunService.STATUS_QUEUED, active.Status__c, 'Not started yet');
        }
    }

    @IsTest
    static void shouldReturnNoActiveRun_WhenRunFinished() {
        System.runAs(ProviderTestDataFactory.intakeUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIntakeRunController.startRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);
            Test.stopTest();

            Assert.isNull(RosterIntakeRunController.getActiveRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER), 'A finished run is not active');
            Roster_Intake_Run__c run = [SELECT Status__c, Rows_Inserted__c FROM Roster_Intake_Run__c WHERE Id = :runId];
            Assert.areEqual(RosterIntakeRunService.STATUS_COMPLETED, run.Status__c, 'Job completed it');
            Assert.areEqual(1, run.Rows_Inserted__c, 'Inserted one Provider');
        }
    }

    @IsTest
    static void shouldFailStuckRun_WhenActiveRunRequested() {
        System.runAs(ProviderTestDataFactory.intakeUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIntakeRunController.startRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);
            Test.stopTest();
            // As if the batch job had died without recording it.
            Database.update(
                new Roster_Intake_Run__c(Id = runId, Status__c = RosterIntakeRunService.STATUS_RUNNING),
                AccessLevel.SYSTEM_MODE
            );

            Roster_Intake_Run__c active = RosterIntakeRunController.getActiveRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);

            Assert.isNull(active, 'The stuck run is no longer shown as active');
            Assert.areEqual(
                RosterIntakeRunService.STATUS_FAILED,
                [SELECT Status__c FROM Roster_Intake_Run__c WHERE Id = :runId].Status__c,
                'The stuck run was marked failed'
            );
        }
    }

    @IsTest
    static void shouldThrowAuraException_WhenStartFails() {
        System.runAs(ProviderTestDataFactory.intakeUser(USER_LAST_NAME)) {
            RosterIntakeRunController.startRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);

            Test.startTest();
            try {
                RosterIntakeRunController.startRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('already in progress'), 'Passes the reason on: ' + e.getMessage());
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void shouldCancelRun_WhenRequested() {
        System.runAs(ProviderTestDataFactory.intakeUser(USER_LAST_NAME)) {
            Id runId = RosterIntakeRunController.startRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);

            Test.startTest();
            RosterIntakeRunController.cancel(runId);
            Test.stopTest();

            Roster_Intake_Run__c run = [SELECT Status__c, Rows_Processed__c FROM Roster_Intake_Run__c WHERE Id = :runId];
            Assert.areEqual(RosterIntakeRunService.STATUS_CANCELLED, run.Status__c, 'Cancelled');
            Assert.areEqual(0, run.Rows_Processed__c, 'The batch job processed nothing');
        }
    }

    @IsTest
    static void shouldThrowAuraException_WhenCancellingFinishedRun() {
        System.runAs(ProviderTestDataFactory.intakeUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIntakeRunController.startRun(rosterId(), RosterIntakeRunService.FILE_TYPE_PROVIDER);
            Test.stopTest();

            try {
                RosterIntakeRunController.cancel(runId);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('queued or running'), 'Passes the reason on: ' + e.getMessage());
            }
        }
    }
}
