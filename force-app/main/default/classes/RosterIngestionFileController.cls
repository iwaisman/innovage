/**
 * Backs the rosterIngestionFiles LWC. Each RosterIngestion__c record holds one file per
 * file type (personnel / relationships), stored as the file's ContentDocument Id. The component
 * uploads the first file of each type; later versions are uploaded from the standard file page
 * ("Upload New Version"). Consumers read the current content via
 * ContentDocument.LatestPublishedVersionId.
 */
public with sharing class RosterIngestionFileController {
    public static final String PERSONNEL = 'personnel';
    public static final String RELATIONSHIPS = 'relationships';

    private static final Map<String, SObjectField> FIELD_BY_TYPE = new Map<String, SObjectField>{
        PERSONNEL => RosterIngestion__c.Personnel_File__c,
        RELATIONSHIPS => RosterIngestion__c.Relationships_File__c
    };

    public class FileInfo {
        @AuraEnabled
        public String fileType;
        @AuraEnabled
        public Id contentDocumentId;
        @AuraEnabled
        public Id latestVersionId;
        @AuraEnabled
        public String title;
        @AuraEnabled
        public String fileExtension;
        @AuraEnabled
        public String versionNumber;
        @AuraEnabled
        public Datetime lastModifiedDate;
    }

    /**
     * Returns the latest version of each file-type's file, keyed by file type.
     * Types with no file (or whose file was deleted) are omitted.
     */
    @AuraEnabled
    public static Map<String, FileInfo> getFiles(Id recordId) {
        RosterIngestion__c record = queryRecord(recordId);

        Map<Id, String> typeByDocumentId = new Map<Id, String>();
        for (String fileType : FIELD_BY_TYPE.keySet()) {
            String documentId = (String) record.get(FIELD_BY_TYPE.get(fileType));
            if (String.isNotBlank(documentId)) {
                typeByDocumentId.put(documentId, fileType);
            }
        }

        Map<String, FileInfo> result = new Map<String, FileInfo>();
        if (typeByDocumentId.isEmpty()) {
            return result;
        }
        for (ContentDocument document : [
            SELECT Id, Title, FileExtension, LatestPublishedVersionId,
                LatestPublishedVersion.VersionNumber, LatestPublishedVersion.LastModifiedDate
            FROM ContentDocument
            WHERE Id IN :typeByDocumentId.keySet()
            WITH USER_MODE
        ]) {
            FileInfo info = new FileInfo();
            info.fileType = typeByDocumentId.get(document.Id);
            info.contentDocumentId = document.Id;
            info.latestVersionId = document.LatestPublishedVersionId;
            info.title = document.Title;
            info.fileExtension = document.FileExtension;
            info.versionNumber = document.LatestPublishedVersion.VersionNumber;
            info.lastModifiedDate = document.LatestPublishedVersion.LastModifiedDate;
            result.put(info.fileType, info);
        }
        return result;
    }

    /**
     * Called after lightning-file-upload finishes the first upload of a file type. New versions
     * of an existing file must be uploaded from the standard file page instead.
     */
    @AuraEnabled
    public static void attachUploadedFile(Id recordId, String fileType, Id contentDocumentId) {
        SObjectField field = fieldFor(fileType);
        RosterIngestion__c record = queryRecord(recordId);
        if (documentExists((String) record.get(field))) {
            throw newAuraException(
                'This record already has a file of this type. Upload a new version from the file page instead.'
            );
        }
        if (!documentExists(contentDocumentId)) {
            throw newAuraException('Uploaded file not found or not accessible.');
        }

        record.put(field, contentDocumentId);
        update as user record;
    }

    /**
     * Deletes an upload that could not be attached (attachUploadedFile failed and rolled back),
     * so it doesn't linger on the record as a stray file. Only the uploader's own file is removed.
     */
    @AuraEnabled
    public static void discardUpload(Id contentDocumentId) {
        List<ContentDocument> documents = [
            SELECT Id
            FROM ContentDocument
            WHERE Id = :contentDocumentId AND CreatedById = :UserInfo.getUserId()
            WITH USER_MODE
        ];
        delete as user documents;
    }

    private static SObjectField fieldFor(String fileType) {
        SObjectField field = FIELD_BY_TYPE.get(fileType);
        if (field == null) {
            throw newAuraException('Unknown file type: ' + fileType);
        }
        return field;
    }

    private static RosterIngestion__c queryRecord(Id recordId) {
        List<RosterIngestion__c> records = [
            SELECT Id, Personnel_File__c, Relationships_File__c
            FROM RosterIngestion__c
            WHERE Id = :recordId
            WITH USER_MODE
        ];
        if (records.isEmpty()) {
            throw newAuraException('Roster Ingestion record not found or not accessible.');
        }
        return records[0];
    }

    private static Boolean documentExists(String contentDocumentId) {
        return String.isNotBlank(contentDocumentId) &&
            [SELECT COUNT() FROM ContentDocument WHERE Id = :contentDocumentId WITH USER_MODE] > 0;
    }

    private static AuraHandledException newAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }
}
