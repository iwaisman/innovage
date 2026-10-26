/**
 * Test data for the relationship intake tests: Organizations, facilities
 * (Participant_Facility Accounts with a HealthcareFacility and Legal Owner),
 * Providers with a HealthcareProvider, and relationships.
 *
 * The org's automation may or may not create the HealthcareProvider /
 * HealthcareFacility and set the Account pointers to them; these methods
 * create whatever is missing, so tests work either way.
 */
@IsTest
public class RelationshipTestDataFactory {

    /**
     * Creates the Health Cloud reciprocal roles the org's ownership automation
     * (AARService, NNVG-115) needs: inserting an Organization with a parent, or a
     * HealthcareFacility with a Legal Owner, creates Account-Account Relations with
     * these roles and fails if they are missing. In the org they are setup data;
     * tests (SeeAllData=false) must create them. Call once in @TestSetup.
     */
    public static void createOwnershipRoles() {
        Id accountRoleRecordTypeId = Schema.SObjectType.HealthCloudGA__ReciprocalRole__c.getRecordTypeInfosByDeveloperName()
            .get('AccountRole')
            .getRecordTypeId();
        insert new List<HealthCloudGA__ReciprocalRole__c>{
            new HealthCloudGA__ReciprocalRole__c(
                Name = 'Parent Organization',
                HealthCloudGA__InverseRole__c = 'Member Organization',
                HealthCloudGA__CreateInverseRole__c = true,
                RecordTypeId = accountRoleRecordTypeId
            ),
            new HealthCloudGA__ReciprocalRole__c(
                Name = 'Facility Owner',
                HealthCloudGA__InverseRole__c = 'Member Facility',
                HealthCloudGA__CreateInverseRole__c = true,
                RecordTypeId = accountRoleRecordTypeId
            )
        };
    }

    /**
     * @param name Account name
     * @param parentId The parent Organization, or null
     * @return The inserted Organization
     */
    public static Account createOrganization(String name, Id parentId) {
        Account organization = new Account(
            Name = name,
            ParentId = parentId,
            RecordTypeId = OrganizationScope.getOrganizationRecordTypeId()
        );
        insertAllowingDuplicates(organization);
        return organization;
    }

    /**
     * @param name Account name
     * @param legalOwnerId The HealthcareFacility's Legal Owner, or null
     * @param npi Group_Type_2_NPI__c, or null
     * @param street ShippingStreet, or null
     * @return The facility Account, re-queried with the fields FacilityMatcher uses
     */
    public static Account createFacility(String name, Id legalOwnerId, String npi, String street) {
        Account facility = new Account(
            Name = name,
            RecordTypeId = FacilityMatcher.getFacilityRecordTypeId(),
            Type = 'Hospital', // a validation rule requires a Type on facility Accounts
            Group_Type_2_NPI__c = npi,
            ShippingStreet = street
        );
        insertAllowingDuplicates(facility);

        Id healthcareFacilityId = queryFacility(facility.Id).Healthcare_Facility__c;
        if (healthcareFacilityId == null) {
            HealthcareFacility record = new HealthcareFacility(Name = name, AccountId = facility.Id, Legal_Owner__c = legalOwnerId);
            insert record;
            healthcareFacilityId = record.Id;
        } else {
            update new HealthcareFacility(Id = healthcareFacilityId, Legal_Owner__c = legalOwnerId);
        }
        if (queryFacility(facility.Id).Healthcare_Facility__c == null) {
            update new Account(Id = facility.Id, Healthcare_Facility__c = healthcareFacilityId);
        }
        return queryFacility(facility.Id);
    }

    /**
     * @param lastName Last name
     * @param npi NPI__c, or null
     * @return The Provider Account, re-queried with Name, NPI, Unique ID and Healthcare_Provider__c
     */
    public static Account createProvider(String lastName, String npi) {
        Account provider = ProviderTestDataFactory.createProvider(lastName, npi, true);

        Id healthcareProviderId = queryProvider(provider.Id).Healthcare_Provider__c;
        if (healthcareProviderId == null) {
            HealthcareProvider record = new HealthcareProvider(Name = 'Test ' + lastName, AccountId = provider.Id);
            insert record;
            healthcareProviderId = record.Id;
            if (queryProvider(provider.Id).Healthcare_Provider__c == null) {
                update new Account(Id = provider.Id, Healthcare_Provider__c = healthcareProviderId);
            }
        }
        return queryProvider(provider.Id);
    }

    /**
     * @param provider A Provider from createProvider
     * @param facility A facility from createFacility
     * @param terminationDate Null for an active relationship
     * @return The inserted relationship
     */
    public static HealthcarePractitionerFacility createRelationship(Account provider, Account facility, Date terminationDate) {
        HealthcarePractitionerFacility relationship = new HealthcarePractitionerFacility(
            Name = provider.Name + ' @ ' + facility.Name,
            HealthcareProviderId = provider.Healthcare_Provider__c,
            HealthcareFacilityId = facility.Healthcare_Facility__c,
            IsActive = terminationDate == null,
            TerminationDate = terminationDate
        );
        insert relationship;
        return relationship;
    }

    /**
     * @return A relationships-file row (header => value) with every column blank
     */
    public static Map<String, String> blankRow() {
        Map<String, String> row = new Map<String, String>();
        for (String header : RelationshipCsvMapping.HEADERS) {
            row.put(header, '');
        }
        return row;
    }

    /**
     * @param providerNpi The Provider's NPI
     * @param facilityUniqueId The facility's Unique ID, or blank
     * @param terminate The Terminate value ('' = create)
     * @return A row identifying the Provider by NPI and the facility by Unique ID
     */
    public static Map<String, String> row(String providerNpi, String facilityUniqueId, String terminate) {
        Map<String, String> row = blankRow();
        row.put(RelationshipCsvMapping.PROVIDER_NPI_HEADER, providerNpi);
        row.put(RelationshipCsvMapping.FACILITY_UNIQUE_ID_HEADER, facilityUniqueId);
        row.put(RelationshipCsvMapping.TERMINATE_HEADER, terminate);
        return row;
    }

    /**
     * @param provider A Provider from createProvider
     * @return Its relationships, newest first
     */
    public static List<HealthcarePractitionerFacility> relationshipsOf(Account provider) {
        return [
            SELECT Id, Name, HealthcareFacilityId, IsActive, InitialStartDate, TerminationDate
            FROM HealthcarePractitionerFacility
            WHERE HealthcareProviderId = :provider.Healthcare_Provider__c
            ORDER BY CreatedDate DESC, Id DESC
        ];
    }

    /**
     * Uploads a relationships file (or a new version of the existing one) for the roster.
     *
     * @param roster The roster; its Relationships_File_ID__c is set on the first upload
     * @param body The file content
     * @return The new ContentVersion
     */
    public static ContentVersion uploadRelationshipsFile(Roster_Intake__c roster, Blob body) {
        Roster_Intake__c current = [SELECT Id, Relationships_File_ID__c FROM Roster_Intake__c WHERE Id = :roster.Id];
        ContentVersion version = new ContentVersion(Title = 'relationships', PathOnClient = 'relationships.csv', VersionData = body);
        if (current.Relationships_File_ID__c == null) {
            version.FirstPublishLocationId = roster.Id;
        } else {
            version.ContentDocumentId = current.Relationships_File_ID__c;
        }
        insert version;

        version = [SELECT Id, ContentDocumentId, VersionNumber FROM ContentVersion WHERE Id = :version.Id];
        if (current.Relationships_File_ID__c == null) {
            current.Relationships_File_ID__c = version.ContentDocumentId;
            update current;
        }
        return version;
    }

    private static Account queryFacility(Id facilityId) {
        return [
            SELECT Id, Name, InnovAge_Unique_ID__c, Group_Type_2_NPI__c, ShippingStreet, Healthcare_Facility__c
            FROM Account
            WHERE Id = :facilityId
        ];
    }

    private static Account queryProvider(Id providerId) {
        return [
            SELECT Id, Name, NPI__c, InnovAge_Unique_ID__c, Healthcare_Provider__c
            FROM Account
            WHERE Id = :providerId
        ];
    }

    private static void insertAllowingDuplicates(Account account) {
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        options.optAllOrNone = true; // DMLOptions otherwise saves partially and hides failures
        Database.insert(account, options);
    }
}
