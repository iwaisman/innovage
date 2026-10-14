@IsTest
private class RosterIngestionRunServiceTest {

    private static final String USER_LAST_NAME = 'RunServiceTestUser';
    private static final String EXISTING = 'RunExisting';
    private static final Integer NEW_NPI = 10;
    private static final Integer WARNING_NPI = 11;
    private static final String UNKNOWN_UNIQUE_ID = 'P999999999zzz';

    /*
     * The personnel file used by most tests (spreadsheet rows; header is row 1):
     *   2: new Provider              -> INSERTED
     *   3: existing Provider, phone  -> UPDATED
     *   4: unknown Unique ID         -> ERROR UNKNOWN_UNIQUE_ID
     *   5: new Provider, bad email   -> INSERTED + WARNING
     *   6: one column only           -> ERROR COLUMN_COUNT
     */
    private static final Integer ROWS = 5;
    private static final Integer INSERTED = 2;
    private static final Integer UPDATED = 1;
    private static final Integer ERRORED = 2;

    @TestSetup
    static void setup() {
        User user = ProviderTestDataFactory.createIngestionUser(USER_LAST_NAME);
        ProviderTestDataFactory.createProvider(EXISTING, ProviderTestDataFactory.NPI_1, true);
        Account organization = ProviderTestDataFactory.createOrganization();
        System.runAs(user) {
            RosterIngestion__c roster = ProviderTestDataFactory.createRoster(organization.Id);
            ProviderTestDataFactory.uploadPersonnelFile(roster, Blob.valueOf(standardCsv()));
        }
    }

    private static String standardCsv() {
        Map<String, String> template = ProviderTestDataFactory.createValidRow();
        List<String> headers = new List<String>(template.keySet());

        Map<String, String> newProvider = template.clone();
        newProvider.put(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.npi(NEW_NPI));
        newProvider.put('Last Name', 'RunNew1');

        Map<String, String> updateRow = new Map<String, String>{
            ProviderCsvMapping.NPI_HEADER => ProviderTestDataFactory.NPI_1,
            'Provider Phone' => '720-555-0166'
        };

        Map<String, String> unknown = new Map<String, String>{ ProviderCsvMapping.UNIQUE_ID_HEADER => UNKNOWN_UNIQUE_ID };

        Map<String, String> withWarning = template.clone();
        withWarning.put(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.npi(WARNING_NPI));
        withWarning.put('Last Name', 'RunNew2');
        withWarning.put('Provider Email', 'not-an-email');

        return ProviderTestDataFactory.toCsv(headers, new List<Map<String, String>>{
            newProvider, updateRow, unknown, withWarning
        }) + '"only one column"\r\n';
    }

    private static RosterIngestion__c roster() {
        return [SELECT Id, Personnel_File__c FROM RosterIngestion__c LIMIT 1];
    }

    private static RosterIngestionRun__c reload(Id runId) {
        return [
            SELECT Id, Status__c, Dry_Run__c, Content_Version_Id__c, Version_Number__c, Failure_Message__c,
                Total_Rows__c, Rows_Processed__c, Inserted__c, Updated__c, Unchanged__c, Errored__c,
                Rows_With_Warnings__c, Started_At__c, Completed_At__c
            FROM RosterIngestionRun__c
            WHERE Id = :runId
        ];
    }

    /*
     * Runs ProviderIngestionBatch the way Salesforce does (start, execute per
     * slice, finish), but directly: a test may run only one execute() of a real
     * batch job. Slices listed in skippedSlices are not executed, as if they had
     * failed. The job queued by startRun() still runs at Test.stopTest(), finds the
     * Run already finished and does nothing.
     */
    private static void runToCompletion(Id runId, Integer sliceSize, Set<Integer> skippedSlices) {
        Boolean dryRun = [SELECT Dry_Run__c FROM RosterIngestionRun__c WHERE Id = :runId].Dry_Run__c;
        ProviderIngestionBatch batch = new ProviderIngestionBatch(runId, dryRun);

        List<ProviderIngestionBatch.RowItem> rows = (List<ProviderIngestionBatch.RowItem>) batch.start(null);
        Integer sliceCount = (rows.size() + sliceSize - 1) / sliceSize;
        for (Integer slice = 0; slice < sliceCount; slice++) {
            List<ProviderIngestionBatch.RowItem> scope = new List<ProviderIngestionBatch.RowItem>();
            for (Integer i = slice * sliceSize; i < Math.min((slice + 1) * sliceSize, rows.size()); i++) {
                scope.add(rows[i]);
            }
            if (!skippedSlices.contains(slice)) {
                batch.execute(null, scope);
            }
        }
        batch.finish(null);
    }

    private static void runToCompletion(Id runId, Integer sliceSize) {
        runToCompletion(runId, sliceSize, new Set<Integer>());
    }

    private static void assertStandardCounts(RosterIngestionRun__c run) {
        Assert.areEqual(RosterIngestionRunService.STATUS_COMPLETED_WITH_ERRORS, run.Status__c, 'Failure: ' + run.Failure_Message__c);
        Assert.areEqual(ROWS, run.Total_Rows__c, 'Total rows');
        Assert.areEqual(ROWS, run.Rows_Processed__c, 'Rows processed');
        Assert.areEqual(INSERTED, run.Inserted__c, 'Inserted');
        Assert.areEqual(UPDATED, run.Updated__c, 'Updated');
        Assert.areEqual(0, run.Unchanged__c, 'Unchanged');
        Assert.areEqual(ERRORED, run.Errored__c, 'Errored');
        Assert.areEqual(1, run.Rows_With_Warnings__c, 'Rows with warnings');
        Assert.isNotNull(run.Completed_At__c, 'Completion time recorded');
    }

    // ─── Whole runs ────────────────────────────────────────────────────

    @IsTest
    static void shouldCompleteRun_WhenBatchProcessesFile() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            Test.stopTest();

            assertStandardCounts(reload(runId));
            Assert.areEqual(INSERTED, [SELECT COUNT() FROM Account WHERE LastName LIKE 'RunNew%'], 'Providers inserted');
            Assert.areEqual('(720) 555-0166', [SELECT Phone FROM Account WHERE LastName = :EXISTING].Phone, 'Provider updated');
        }
    }

    @IsTest
    static void shouldRecordIssuesWithRowNumbers_WhenRowsHaveProblems() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE);
            Test.stopTest();

            Map<Integer, RosterIngestionIssue__c> issuesByRow = new Map<Integer, RosterIngestionIssue__c>();
            for (RosterIngestionIssue__c issue : [
                SELECT Row_Number__c, Severity__c, Code__c, Column__c, Unique_ID__c, NPI__c, Message__c
                FROM RosterIngestionIssue__c
                WHERE RosterIngestionRun__c = :runId
            ]) {
                issuesByRow.put(issue.Row_Number__c.intValue(), issue);
            }

            Assert.areEqual(new Set<Integer>{ 4, 5, 6 }, issuesByRow.keySet(), 'One issue each for rows 4, 5 and 6');
            Assert.areEqual(AccountMatchResult.Outcome.UNKNOWN_UNIQUE_ID.name(), issuesByRow.get(4).Code__c, 'Row 4 names no existing Provider');
            Assert.areEqual(UNKNOWN_UNIQUE_ID, issuesByRow.get(4).Unique_ID__c, 'Issue keeps the row key');
            Assert.areEqual(RosterIngestionRunService.SEVERITY_WARNING, issuesByRow.get(5).Severity__c, 'Row 5 is a warning');
            Assert.areEqual('Provider Email', issuesByRow.get(5).Column__c, 'Warning names the column');
            Assert.areEqual(RosterIngestionRunService.CODE_COLUMN_COUNT, issuesByRow.get(6).Code__c, 'Row 6 has the wrong column count');
        }
    }

    @IsTest
    static void shouldGiveSameResults_WhenProcessedInSmallSlices() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            runToCompletion(runId, 2);
            Test.stopTest();

            assertStandardCounts(reload(runId));
            Assert.areEqual(3, [SELECT COUNT() FROM RosterIngestionIssue__c WHERE RosterIngestionRun__c = :runId], 'Same issues');
        }
    }

    @IsTest
    static void shouldReportMissingRows_WhenSliceFails() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            runToCompletion(runId, 2, new Set<Integer>{ 1 }); // rows 4-5 fail
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_COMPLETED_WITH_ERRORS, run.Status__c, 'Other slices still complete');
            Assert.areEqual(3, run.Rows_Processed__c, 'Only the successful slices are counted');
            Assert.isTrue(run.Failure_Message__c.contains('2 of 5 rows were not processed'), 'Reports the gap: ' + run.Failure_Message__c);
        }
    }

    @IsTest
    static void shouldFailRun_WhenEverySliceFails() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE, new Set<Integer>{ 0 });
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'Nothing was processed');
            Assert.isTrue(run.Failure_Message__c.contains('5 of 5 rows'), 'Reports the gap: ' + run.Failure_Message__c);
        }
    }

    @IsTest
    static void shouldReportButRollBack_WhenDryRun() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, true);

            Test.startTest();
            runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE);
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.isTrue(run.Dry_Run__c, 'Flagged as a dry run');
            assertStandardCounts(run);
            Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE LastName LIKE 'RunNew%'], 'Inserts rolled back');
            Assert.areNotEqual('(720) 555-0166', [SELECT Phone FROM Account WHERE LastName = :EXISTING].Phone, 'Update rolled back');
        }
    }

    // ─── File-level failures ───────────────────────────────────────────

    private static RosterIngestionRun__c runFile(Blob body) {
        ProviderTestDataFactory.uploadPersonnelFile(roster(), body);
        Id runId = RosterIngestionRunService.startRun(roster().Id, false);
        Test.startTest();
        runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE);
        Test.stopTest();
        return reload(runId);
    }

    @IsTest
    static void shouldFailRun_WhenRequiredHeaderMissing() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestionRun__c run = runFile(Blob.valueOf('"Individual NPI","Provider Unique ID"\r\n"1234567893",""\r\n'));

            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'File-level problem fails the run');
            Assert.isTrue(run.Failure_Message__c.contains('"Last Name"'), 'Names the missing column: ' + run.Failure_Message__c);
            Assert.areEqual(0, run.Rows_Processed__c, 'No rows processed');
        }
    }

    @IsTest
    static void shouldFailRun_WhenCsvMalformed() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestionRun__c run = runFile(Blob.valueOf('Provider Unique ID,Individual NPI,Last Name\r\n,1234567893,ab"c\r\n'));

            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'Malformed CSV fails the run');
            Assert.isTrue(run.Failure_Message__c.contains('not valid CSV'), 'Explains why: ' + run.Failure_Message__c);
        }
    }

    @IsTest
    static void shouldFailRun_WhenFileNotUtf8() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            // "Café" in Windows-1252: the é byte (E9) is not valid UTF-8 on its own.
            RosterIngestionRun__c run = runFile(EncodingUtil.convertFromHex('436166E90D0A'));

            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'Non-UTF-8 file fails the run');
            Assert.isTrue(run.Failure_Message__c.contains('UTF-8'), 'Explains how to fix it: ' + run.Failure_Message__c);
        }
    }

    @IsTest
    static void shouldFailRun_WhenFileEmpty() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestionRun__c run = runFile(Blob.valueOf('\r\n'));

            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'Empty file fails the run');
            Assert.isTrue(run.Failure_Message__c.contains('empty'), 'Explains why: ' + run.Failure_Message__c);
        }
    }

    @IsTest
    static void shouldFailRun_WhenFileHasTooManyRows() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            ProviderIngestionBatch.maxRows = 3;
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE);
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'Too many rows fails the run');
            Assert.isTrue(run.Failure_Message__c.contains('at most 3'), 'States the limit: ' + run.Failure_Message__c);
            Assert.areEqual(0, run.Rows_Processed__c, 'No rows processed');
        }
    }

    // ─── Starting ──────────────────────────────────────────────────────

    @IsTest
    static void shouldPinLatestVersion_WhenStarting() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            ContentVersion latest = ProviderTestDataFactory.uploadPersonnelFile(roster(), Blob.valueOf(standardCsv()));

            Test.startTest();
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            // Checked before stopTest(), which runs the batch job.
            RosterIngestionRun__c run = reload(runId);
            Test.stopTest();

            Assert.areEqual(latest.Id, run.Content_Version_Id__c, 'Pinned to the latest version');
            Assert.areEqual(latest.VersionNumber, run.Version_Number__c, 'Records the version number');
            Assert.areEqual(RosterIngestionRunService.STATUS_QUEUED, run.Status__c, 'Queued until the batch job starts');
        }
    }

    @IsTest
    static void shouldRefuseToStart_WhenRunAlreadyActive() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            try {
                RosterIngestionRunService.startRun(roster().Id, false);
                Assert.fail('Expected RunException');
            } catch (RosterIngestionRunService.RunException e) {
                Assert.isTrue(e.getMessage().contains('already in progress'), 'Explains why');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void shouldRefuseToStart_WhenFileTooLarge() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestionRunService.maxFileBytes = 10;

            Test.startTest();
            try {
                RosterIngestionRunService.startRun(roster().Id, false);
                Assert.fail('Expected RunException');
            } catch (RosterIngestionRunService.RunException e) {
                Assert.isTrue(e.getMessage().contains('cannot be ingested'), 'Explains why');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void shouldRefuseToStart_WhenRosterHasNoFile() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            RosterIngestion__c empty = new RosterIngestion__c(Organization__c = [SELECT Organization__c FROM RosterIngestion__c LIMIT 1].Organization__c);
            insert empty;

            Test.startTest();
            try {
                RosterIngestionRunService.startRun(empty.Id, false);
                Assert.fail('Expected RunException');
            } catch (RosterIngestionRunService.RunException e) {
                Assert.isTrue(e.getMessage().contains('no personnel file'), 'Explains why');
            }
            Test.stopTest();
        }
    }

    // ─── Promote, cancel, abandoned runs ───────────────────────────────

    @IsTest
    static void shouldPromoteToSameVersion_WhenNewerVersionUploaded() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id dryRunId = RosterIngestionRunService.startRun(roster().Id, true);
            runToCompletion(dryRunId, RosterIngestionRunService.BATCH_SIZE);
            ProviderTestDataFactory.uploadPersonnelFile(roster(), Blob.valueOf('Provider Unique ID,Individual NPI,Last Name\r\n'));

            Test.startTest();
            Id realRunId = RosterIngestionRunService.promote(dryRunId);
            runToCompletion(realRunId, RosterIngestionRunService.BATCH_SIZE);
            Test.stopTest();

            RosterIngestionRun__c realRun = reload(realRunId);
            Assert.isFalse(realRun.Dry_Run__c, 'Promoted run is real');
            Assert.areEqual(reload(dryRunId).Content_Version_Id__c, realRun.Content_Version_Id__c, 'Same file version as the dry run');
            assertStandardCounts(realRun);
            Assert.areEqual(INSERTED, [SELECT COUNT() FROM Account WHERE LastName LIKE 'RunNew%'], 'Providers really inserted');
        }
    }

    @IsTest
    static void shouldRefuseToPromote_WhenRunIsNotDryRun() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE);

            Test.startTest();
            try {
                RosterIngestionRunService.promote(runId);
                Assert.fail('Expected RunException');
            } catch (RosterIngestionRunService.RunException e) {
                Assert.isTrue(e.getMessage().contains('dry run'), 'Explains why');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void shouldProcessNothing_WhenCancelledBeforeStart() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            RosterIngestionRunService.cancel(runId);
            runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE);
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_CANCELLED, run.Status__c, 'Stays cancelled');
            Assert.areEqual(0, run.Rows_Processed__c, 'No rows processed');
        }
    }

    @IsTest
    static void shouldRefuseToCancel_WhenRunFinished() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            runToCompletion(runId, RosterIngestionRunService.BATCH_SIZE);

            Test.startTest();
            try {
                RosterIngestionRunService.cancel(runId);
                Assert.fail('Expected RunException');
            } catch (RosterIngestionRunService.RunException e) {
                Assert.isTrue(e.getMessage().contains('queued or running'), 'Explains why');
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void shouldFailRun_WhenItsBatchJobEndedWithoutFinishingIt() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            Test.stopTest();
            // As if the job had died where the batch could not record it.
            Database.update(
                new RosterIngestionRun__c(Id = runId, Status__c = RosterIngestionRunService.STATUS_RUNNING),
                AccessLevel.SYSTEM_MODE
            );

            RosterIngestionRunService.failAbandonedRuns(roster().Id);

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'No longer blocks new runs');
            Assert.isTrue(run.Failure_Message__c.contains('batch job ended'), 'Explains why: ' + run.Failure_Message__c);
        }
    }

    @IsTest
    static void shouldLeaveRunActive_WhenItsBatchJobIsStillQueued() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            RosterIngestionRunService.failAbandonedRuns(roster().Id);
            // Checked before stopTest(), which runs the batch job.
            RosterIngestionRun__c run = reload(runId);
            Test.stopTest();

            Assert.areEqual(RosterIngestionRunService.STATUS_QUEUED, run.Status__c, 'Job has not ended');
        }
    }
}
