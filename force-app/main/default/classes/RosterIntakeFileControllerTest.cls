@IsTest
private class RosterIntakeFileControllerTest {
    private static final String TEST_USER_LAST_NAME = 'RosterIntakeFilesTestUser';

    @TestSetup
    static void setup() {
        // The controller runs in user mode, so tests run as a user with the component's permission set.
        User user = new User(
            ProfileId = UserInfo.getProfileId(),
            LastName = TEST_USER_LAST_NAME,
            Username = 'roster.intake.files.' + Datetime.now().getTime() + '@test.invalid',
            Email = 'roster.intake.files@test.invalid',
            Alias = 'rifiles',
            TimeZoneSidKey = 'America/Denver',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert user;
        // runAs separates this setup-object DML from the Account insert below (MIXED_DML_OPERATION).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert new PermissionSetAssignment(
                AssigneeId = user.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Roster_Intake_Files'].Id
            );
        }

        // Roster_Intake__c.Organization__c only accepts Organization accounts
        Account organization = new Account(
            Name = 'Test Organization',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
                .get('Organization')
                .getRecordTypeId()
        );
        insert organization;

        System.runAs(user) {
            insert new Roster_Intake__c(Organization__c = organization.Id);
        }
    }

    private static User testUser() {
        return [SELECT Id FROM User WHERE LastName = :TEST_USER_LAST_NAME LIMIT 1];
    }

    private static Roster_Intake__c getRecord() {
        return [SELECT Id, Provider_File_ID__c, Relationships_File_ID__c FROM Roster_Intake__c LIMIT 1];
    }

    /** Simulates what lightning-file-upload does: a new document linked to the record. */
    private static ContentVersion upload(Id recordId, String fileName, String body) {
        ContentVersion version = new ContentVersion(
            Title = fileName.substringBeforeLast('.'),
            PathOnClient = fileName,
            VersionData = Blob.valueOf(body),
            FirstPublishLocationId = recordId
        );
        insert version;
        return [SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id = :version.Id];
    }

    /** Simulates "Upload New Version" on the standard file page. */
    private static ContentVersion uploadNewVersion(Id contentDocumentId, String fileName, String body) {
        ContentVersion version = new ContentVersion(
            ContentDocumentId = contentDocumentId,
            Title = fileName.substringBeforeLast('.'),
            PathOnClient = fileName,
            VersionData = Blob.valueOf(body)
        );
        insert version;
        return version;
    }

    @IsTest
    static void firstUploadIsStoredOnRecord() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion uploaded = upload(recordId, 'provider.csv', 'a,b');

            Test.startTest();
            RosterIntakeFileController.attachUploadedFile(
                recordId, RosterIntakeFileController.PROVIDER, uploaded.ContentDocumentId
            );
            Test.stopTest();

            Assert.areEqual(uploaded.ContentDocumentId, getRecord().Provider_File_ID__c);
            Assert.isNull(getRecord().Relationships_File_ID__c);
        }
    }

    @IsTest
    static void secondUploadOfSameTypeIsRejected() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion first = upload(recordId, 'provider.csv', 'v1');
            RosterIntakeFileController.attachUploadedFile(
                recordId, RosterIntakeFileController.PROVIDER, first.ContentDocumentId
            );
            ContentVersion second = upload(recordId, 'provider.csv', 'v2');

            try {
                RosterIntakeFileController.attachUploadedFile(
                    recordId, RosterIntakeFileController.PROVIDER, second.ContentDocumentId
                );
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('already has a file'));
            }
            Assert.areEqual(first.ContentDocumentId, getRecord().Provider_File_ID__c);
        }
    }

    @IsTest
    static void getFilesReturnsLatestVersion() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion provider = upload(recordId, 'provider.csv', 'p');
            ContentVersion relationships = upload(recordId, 'relationships.csv', 'r');
            RosterIntakeFileController.attachUploadedFile(
                recordId, RosterIntakeFileController.PROVIDER, provider.ContentDocumentId
            );
            RosterIntakeFileController.attachUploadedFile(
                recordId, RosterIntakeFileController.RELATIONSHIPS, relationships.ContentDocumentId
            );
            ContentVersion providerV2 = uploadNewVersion(provider.ContentDocumentId, 'provider.csv', 'p2');

            Test.startTest();
            Map<String, RosterIntakeFileController.FileInfo> files = RosterIntakeFileController.getFiles(recordId);
            Test.stopTest();

            Assert.areEqual(2, files.size());
            RosterIntakeFileController.FileInfo providerInfo = files.get(RosterIntakeFileController.PROVIDER);
            Assert.areEqual(providerV2.Id, providerInfo.latestVersionId);
            Assert.areEqual('2', providerInfo.versionNumber);
            Assert.areEqual(relationships.Id, files.get(RosterIntakeFileController.RELATIONSHIPS).latestVersionId);
        }
    }

    @IsTest
    static void deletedFileCanBeReplaced() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion old = upload(recordId, 'provider.csv', 'old');
            RosterIntakeFileController.attachUploadedFile(
                recordId, RosterIntakeFileController.PROVIDER, old.ContentDocumentId
            );
            delete new ContentDocument(Id = old.ContentDocumentId);
            ContentVersion uploaded = upload(recordId, 'provider.csv', 'new');

            Test.startTest();
            RosterIntakeFileController.attachUploadedFile(
                recordId, RosterIntakeFileController.PROVIDER, uploaded.ContentDocumentId
            );
            Test.stopTest();

            Assert.areEqual(uploaded.ContentDocumentId, getRecord().Provider_File_ID__c);
            Assert.isTrue(
                RosterIntakeFileController.getFiles(recordId).containsKey(RosterIntakeFileController.PROVIDER)
            );
        }
    }

    @IsTest
    static void getFilesReturnsEmptyMapWhenNoFiles() {
        System.runAs(testUser()) {
            Assert.isTrue(RosterIntakeFileController.getFiles(getRecord().Id).isEmpty());
        }
    }

    @IsTest
    static void unknownFileTypeThrows() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion uploaded = upload(recordId, 'x.csv', 'x');
            try {
                RosterIntakeFileController.attachUploadedFile(recordId, 'bogus', uploaded.ContentDocumentId);
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('Unknown file type'));
            }
        }
    }

    @IsTest
    static void discardUploadDeletesDocument() {
        System.runAs(testUser()) {
            ContentVersion uploaded = upload(getRecord().Id, 'x.csv', 'x');

            Test.startTest();
            RosterIntakeFileController.discardUpload(uploaded.ContentDocumentId);
            Test.stopTest();

            Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :uploaded.ContentDocumentId]);
        }
    }
}
