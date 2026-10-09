@IsTest
private class RosterIngestionFileControllerTest {
    private static final String TEST_USER_LAST_NAME = 'RosterIngestionFilesTestUser';

    @TestSetup
    static void setup() {
        // The controller runs in user mode, so tests run as a user with the component's permission set.
        User user = new User(
            ProfileId = UserInfo.getProfileId(),
            LastName = TEST_USER_LAST_NAME,
            Username = 'roster.ingestion.files.' + Datetime.now().getTime() + '@test.invalid',
            Email = 'roster.ingestion.files@test.invalid',
            Alias = 'rifiles',
            TimeZoneSidKey = 'America/Denver',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        insert user;
        insert new PermissionSetAssignment(
            AssigneeId = user.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Roster_Ingestion_Files'].Id
        );

        // RosterIngestion__c.Organization__c only accepts Organization accounts
        Account organization = new Account(
            Name = 'Test Organization',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
                .get('Organization')
                .getRecordTypeId()
        );
        insert organization;

        System.runAs(user) {
            insert new RosterIngestion__c(Organization__c = organization.Id);
        }
    }

    private static User testUser() {
        return [SELECT Id FROM User WHERE LastName = :TEST_USER_LAST_NAME LIMIT 1];
    }

    private static RosterIngestion__c getRecord() {
        return [SELECT Id, Personnel_File__c, Relationships_File__c FROM RosterIngestion__c LIMIT 1];
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
            ContentVersion uploaded = upload(recordId, 'personnel.csv', 'a,b');

            Test.startTest();
            RosterIngestionFileController.attachUploadedFile(
                recordId, RosterIngestionFileController.PERSONNEL, uploaded.ContentDocumentId
            );
            Test.stopTest();

            Assert.areEqual(uploaded.ContentDocumentId, getRecord().Personnel_File__c);
            Assert.isNull(getRecord().Relationships_File__c);
        }
    }

    @IsTest
    static void secondUploadOfSameTypeIsRejected() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion first = upload(recordId, 'personnel.csv', 'v1');
            RosterIngestionFileController.attachUploadedFile(
                recordId, RosterIngestionFileController.PERSONNEL, first.ContentDocumentId
            );
            ContentVersion second = upload(recordId, 'personnel.csv', 'v2');

            try {
                RosterIngestionFileController.attachUploadedFile(
                    recordId, RosterIngestionFileController.PERSONNEL, second.ContentDocumentId
                );
                Assert.fail('Expected AuraHandledException');
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('already has a file'));
            }
            Assert.areEqual(first.ContentDocumentId, getRecord().Personnel_File__c);
        }
    }

    @IsTest
    static void getFilesReturnsLatestVersion() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion personnel = upload(recordId, 'personnel.csv', 'p');
            ContentVersion relationships = upload(recordId, 'relationships.csv', 'r');
            RosterIngestionFileController.attachUploadedFile(
                recordId, RosterIngestionFileController.PERSONNEL, personnel.ContentDocumentId
            );
            RosterIngestionFileController.attachUploadedFile(
                recordId, RosterIngestionFileController.RELATIONSHIPS, relationships.ContentDocumentId
            );
            ContentVersion personnelV2 = uploadNewVersion(personnel.ContentDocumentId, 'personnel.csv', 'p2');

            Test.startTest();
            Map<String, RosterIngestionFileController.FileInfo> files = RosterIngestionFileController.getFiles(recordId);
            Test.stopTest();

            Assert.areEqual(2, files.size());
            RosterIngestionFileController.FileInfo personnelInfo = files.get(RosterIngestionFileController.PERSONNEL);
            Assert.areEqual(personnelV2.Id, personnelInfo.latestVersionId);
            Assert.areEqual('2', personnelInfo.versionNumber);
            Assert.areEqual(relationships.Id, files.get(RosterIngestionFileController.RELATIONSHIPS).latestVersionId);
        }
    }

    @IsTest
    static void deletedFileCanBeReplaced() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion old = upload(recordId, 'personnel.csv', 'old');
            RosterIngestionFileController.attachUploadedFile(
                recordId, RosterIngestionFileController.PERSONNEL, old.ContentDocumentId
            );
            delete new ContentDocument(Id = old.ContentDocumentId);
            ContentVersion uploaded = upload(recordId, 'personnel.csv', 'new');

            Test.startTest();
            RosterIngestionFileController.attachUploadedFile(
                recordId, RosterIngestionFileController.PERSONNEL, uploaded.ContentDocumentId
            );
            Test.stopTest();

            Assert.areEqual(uploaded.ContentDocumentId, getRecord().Personnel_File__c);
            Assert.isTrue(
                RosterIngestionFileController.getFiles(recordId).containsKey(RosterIngestionFileController.PERSONNEL)
            );
        }
    }

    @IsTest
    static void getFilesReturnsEmptyMapWhenNoFiles() {
        System.runAs(testUser()) {
            Assert.isTrue(RosterIngestionFileController.getFiles(getRecord().Id).isEmpty());
        }
    }

    @IsTest
    static void unknownFileTypeThrows() {
        System.runAs(testUser()) {
            Id recordId = getRecord().Id;
            ContentVersion uploaded = upload(recordId, 'x.csv', 'x');
            try {
                RosterIngestionFileController.attachUploadedFile(recordId, 'bogus', uploaded.ContentDocumentId);
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
            RosterIngestionFileController.discardUpload(uploaded.ContentDocumentId);
            Test.stopTest();

            Assert.areEqual(0, [SELECT COUNT() FROM ContentDocument WHERE Id = :uploaded.ContentDocumentId]);
        }
    }
}
