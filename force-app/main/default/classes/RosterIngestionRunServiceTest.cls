@IsTest
private class RosterIngestionRunServiceTest {

    private static final String USER_LAST_NAME = 'RunServiceTestUser';
    private static final String EXISTING = 'RunExisting';
    private static final Integer NEW_NPI = 10;
    private static final Integer WARNING_NPI = 11;

    /*
     * The personnel file used by most tests (spreadsheet rows; header is row 1):
     *   2: new Provider              -> INSERTED
     *   3: existing Provider, phone  -> UPDATED
     *   4: same NPI as row 2         -> ERROR DUPLICATE_IN_FILE
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

        Map<String, String> withWarning = template.clone();
        withWarning.put(ProviderCsvMapping.NPI_HEADER, ProviderTestDataFactory.npi(WARNING_NPI));
        withWarning.put('Last Name', 'RunNew2');
        withWarning.put('Provider Email', 'not-an-email');

        return ProviderTestDataFactory.toCsv(headers, new List<Map<String, String>>{
            newProvider, updateRow, newProvider, withWarning
        }) + '"only one column"\r\n';
    }

    private static RosterIngestion__c roster() {
        return [SELECT Id, Personnel_File__c FROM RosterIngestion__c LIMIT 1];
    }

    private static RosterIngestionRun__c reload(Id runId) {
        return [
            SELECT Id, Status__c, Dry_Run__c, Content_Version_Id__c, Version_Number__c, Failure_Message__c,
                Rows_Processed__c, Inserted__c, Updated__c, Unchanged__c, Errored__c, Rows_With_Warnings__c,
                Chunk_Size__c, Chunk_Count__c, Next_Row_Number__c, Started_At__c, Completed_At__c
            FROM RosterIngestionRun__c
            WHERE Id = :runId
        ];
    }

    /*
     * Drives the chain the way ProviderIngestionJob does; chaining is disabled in tests.
     */
    private static void runToCompletion(Id runId, Integer chunkSize) {
        // Internal field; users can only read it.
        Database.update(new RosterIngestionRun__c(Id = runId, Chunk_Size__c = chunkSize), AccessLevel.SYSTEM_MODE);
        ProviderIngestionService.DuplicateTracker tracker = new ProviderIngestionService.DuplicateTracker();
        for (Integer i = 0; i < 20; i++) {
            if (RosterIngestionRunService.processChunk(runId, tracker) != RosterIngestionRunService.ChunkOutcome.MORE) {
                return;
            }
        }
        Assert.fail('Run did not complete');
    }

    private static void assertStandardCounts(RosterIngestionRun__c run) {
        Assert.areEqual(RosterIngestionRunService.STATUS_COMPLETED_WITH_ERRORS, run.Status__c, 'Failure: ' + run.Failure_Message__c);
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
    static void shouldCompleteRun_WhenJobProcessesFile() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Test.startTest();
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            assertStandardCounts(run);
            Assert.areEqual(1, run.Chunk_Count__c, 'Small file fits in one chunk');
            Assert.areEqual(INSERTED, [SELECT COUNT() FROM Account WHERE LastName LIKE 'RunNew%'], 'Providers inserted');
            Assert.areEqual('(720) 555-0166', [SELECT Phone FROM Account WHERE LastName = :EXISTING].Phone, 'Provider updated');
        }
    }

    @IsTest
    static void shouldRecordIssuesWithRowNumbers_WhenRowsHaveProblems() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            runToCompletion(runId, 500);
            Test.stopTest();

            Map<Integer, RosterIngestionIssue__c> issuesByRow = new Map<Integer, RosterIngestionIssue__c>();
            for (RosterIngestionIssue__c issue : [
                SELECT Row_Number__c, Severity__c, Code__c, Column__c, NPI__c, Message__c
                FROM RosterIngestionIssue__c
                WHERE RosterIngestionRun__c = :runId
            ]) {
                issuesByRow.put(issue.Row_Number__c.intValue(), issue);
            }

            Assert.areEqual(new Set<Integer>{ 4, 5, 6 }, issuesByRow.keySet(), 'One issue each for rows 4, 5 and 6');
            Assert.areEqual(ProviderIngestionService.DUPLICATE_IN_FILE, issuesByRow.get(4).Code__c, 'Row 4 duplicates row 2');
            Assert.areEqual(ProviderTestDataFactory.npi(NEW_NPI), issuesByRow.get(4).NPI__c, 'Issue keeps the row key');
            Assert.areEqual(RosterIngestionRunService.SEVERITY_WARNING, issuesByRow.get(5).Severity__c, 'Row 5 is a warning');
            Assert.areEqual('Provider Email', issuesByRow.get(5).Column__c, 'Warning names the column');
            Assert.areEqual(RosterIngestionRunService.CODE_COLUMN_COUNT, issuesByRow.get(6).Code__c, 'Row 6 has the wrong column count');
        }
    }

    @IsTest
    static void shouldGiveSameResults_WhenProcessedInSmallChunks() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            runToCompletion(runId, 2);
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            assertStandardCounts(run);
            Assert.areEqual(3, run.Chunk_Count__c, 'Five rows in chunks of two');
            Assert.areEqual(3, [SELECT COUNT() FROM RosterIngestionIssue__c WHERE RosterIngestionRun__c = :runId], 'Same issues');
        }
    }

    @IsTest
    static void shouldReportButRollBack_WhenDryRun() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, true);

            Test.startTest();
            runToCompletion(runId, 500);
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
        runToCompletion(runId, 500);
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

    // ─── Starting ──────────────────────────────────────────────────────

    @IsTest
    static void shouldPinLatestVersion_WhenStarting() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            ContentVersion latest = ProviderTestDataFactory.uploadPersonnelFile(roster(), Blob.valueOf(standardCsv()));

            Test.startTest();
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            RosterIngestionRun__c run = reload(runId);
            Test.stopTest();

            Assert.areEqual(latest.Id, run.Content_Version_Id__c, 'Pinned to the latest version');
            Assert.areEqual(latest.VersionNumber, run.Version_Number__c, 'Records the version number');
            Assert.areEqual(RosterIngestionRunService.STATUS_QUEUED, run.Status__c, 'Queued until its first chunk runs');
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

    // ─── Promote and cancel ────────────────────────────────────────────

    @IsTest
    static void shouldPromoteToSameVersion_WhenNewerVersionUploaded() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id dryRunId = RosterIngestionRunService.startRun(roster().Id, true);
            runToCompletion(dryRunId, 500);
            ProviderTestDataFactory.uploadPersonnelFile(roster(), Blob.valueOf('Provider Unique ID,Individual NPI,Last Name\r\n'));

            Test.startTest();
            Id realRunId = RosterIngestionRunService.promote(dryRunId);
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
            runToCompletion(runId, 500);

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
    static void shouldStopProcessing_WhenCancelled() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            RosterIngestionRunService.cancel(runId);
            RosterIngestionRunService.ChunkOutcome outcome = RosterIngestionRunService.processChunk(
                runId,
                new ProviderIngestionService.DuplicateTracker()
            );
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_CANCELLED, run.Status__c, 'Cancelled');
            Assert.areEqual(RosterIngestionRunService.ChunkOutcome.STOPPED, outcome, 'Pending chunk does nothing');
            Assert.areEqual(0, run.Rows_Processed__c, 'No rows processed');
        }
    }

    @IsTest
    static void shouldRefuseToCancel_WhenRunFinished() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            runToCompletion(runId, 500);

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

    // ─── Chunk failures (finalizer) ────────────────────────────────────

    @IsTest
    static void shouldHalveChunkSize_WhenChunkDies() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            new ProviderIngestionJobFinalizer(runId, new ProviderIngestionService.DuplicateTracker())
                .handleFailure('System.LimitException: Apex CPU time limit exceeded');
            // Checked before stopTest(), which would run the queued chunk to completion.
            RosterIngestionRun__c run = reload(runId);
            Test.stopTest();

            Assert.areEqual(RosterIngestionRunService.STATUS_QUEUED, run.Status__c, 'Still active; the chunk is retried');
            Assert.areEqual(250, run.Chunk_Size__c, 'Half of the default 500');
        }
    }

    @IsTest
    static void shouldFailRun_WhenMinimumChunkDies() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);
            Database.update(new RosterIngestionRun__c(Id = runId, Chunk_Size__c = RosterIngestionRunService.MIN_CHUNK_SIZE), AccessLevel.SYSTEM_MODE);

            Test.startTest();
            RosterIngestionRunService.handleChunkFailure(runId, new ProviderIngestionService.DuplicateTracker(), 'CPU limit');
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'Cannot shrink further');
            Assert.isTrue(run.Failure_Message__c.contains('CPU limit'), 'Keeps the reason: ' + run.Failure_Message__c);
            Assert.isTrue(run.Failure_Message__c.contains('row 2'), 'Says where: ' + run.Failure_Message__c);
        }
    }

    @IsTest
    static void shouldFailActiveRun_WhenJobReportsError() {
        System.runAs(ProviderTestDataFactory.ingestionUser(USER_LAST_NAME)) {
            Id runId = RosterIngestionRunService.startRun(roster().Id, false);

            Test.startTest();
            RosterIngestionRunService.failRun(runId, 'Unexpected error: boom');
            Test.stopTest();

            RosterIngestionRun__c run = reload(runId);
            Assert.areEqual(RosterIngestionRunService.STATUS_FAILED, run.Status__c, 'Failed');
            Assert.areEqual('Unexpected error: boom', run.Failure_Message__c, 'Keeps the reason');
        }
    }
}
