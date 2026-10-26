/**
 * Test data for the Provider intake tests.
 */
@IsTest
public class ProviderTestDataFactory {

    /** NPIs with valid check digits that no test Provider is created with unless a test says so. */
    public static final String NPI_1 = '1234567893';
    public static final String NPI_2 = '1987654328';
    public static final String NPI_3 = '1111111112';
    public static final String NPI_UNUSED = '1000000004';

    /**
     * @param lastName Last name; also makes the record distinct for duplicate rules
     * @param npi NPI__c value, or null
     * @param doInsert Whether to insert the record
     * @return The Provider person Account
     */
    public static Account createProvider(String lastName, String npi, Boolean doInsert) {
        return createProviders(new List<String>{ lastName }, new List<String>{ npi }, doInsert)[0];
    }

    /**
     * @param lastNames Last names, one per Provider
     * @param npis NPI__c values (null allowed), parallel to lastNames
     * @param doInsert Whether to insert the records
     * @return The Provider person Accounts
     */
    public static List<Account> createProviders(List<String> lastNames, List<String> npis, Boolean doInsert) {
        Id providerRecordTypeId = ProviderMatcher.getProviderRecordTypeId();

        List<Account> providers = new List<Account>();
        for (Integer i = 0; i < lastNames.size(); i++) {
            providers.add(new Account(
                RecordTypeId = providerRecordTypeId,
                FirstName = 'Test' + i,
                LastName = lastNames[i],
                NPI__c = npis[i],
                Phone = '(303) 555-01' + String.valueOf(i).leftPad(2, '0'),
                PersonEmail = 'provider' + i + '.' + lastNames[i].toLowerCase() + '@example.com'
            ));
        }

        if (doInsert) {
            Database.DMLOptions options = new Database.DMLOptions();
            options.DuplicateRuleHeader.allowSave = true;
            Database.insert(providers, options);
        }
        return providers;
    }

    /**
     * @param accountId A Provider Account Id
     * @return Its InnovAge_Unique_ID__c formula value
     */
    public static String getUniqueId(Id accountId) {
        return [SELECT InnovAge_Unique_ID__c FROM Account WHERE Id = :accountId].InnovAge_Unique_ID__c;
    }

    /**
     * @return A CSV row (header => value) with a valid value for every mapped header
     *         and no keys; callers set 'Provider Unique ID' / 'Individual NPI' as needed.
     */
    public static Map<String, String> createValidRow() {
        return new Map<String, String>{
            'Provider Unique ID' => '',
            'Individual NPI' => '',
            'Salutation' => 'dr.',
            'First Name' => 'Jane',
            'Middle Name' => 'Q',
            'Last Name' => 'Ingested',
            'Suffix (MD, DO, NP, RN etc)' => 'MD',
            'Date of Birth' => '04/17/1980',
            'Social Security Number' => '912345678',
            'Provider Phone' => '303.555.0142',
            'Provider Fax' => '1 (303) 555-0143',
            'Provider Email' => 'jane.ingested@example.com',
            'Provider Mailing Address Line 1' => '100 Main St',
            'Provider Mailing Address Line 2' => 'Suite 200',
            'Provider Mailing City' => 'Denver',
            'Provider Mailing State' => 'co',
            'Provider Mailing Zip' => '80202-1234',
            'Provider Billing Address Line 1' => '200 Oak Ave',
            'Provider Billing Address Line 2' => '',
            'Provider Billing City' => 'Boulder',
            'Provider Billing State' => 'CO',
            'Provider Billing Zip' => '80301',
            'CAQH ID' => '12345678',
            'Medicare ID' => 'CO1234567',
            'Medicaid ID' => 'MCD12345',
            'Medicaid ID State' => 'CO',
            'Gender Identification' => 'female',
            'Pronouns' => 'She/Her',
            'Primary Provider Language' => 'polish',
            'Secondary Provider Language(s)' => 'Spanish;German',
            'Provider Effective Date' => '01/01/2026'
        };
    }

    /**
     * @param n Any number from 0 to 99,999,999
     * @return A 10-digit NPI with a valid check digit, distinct for each n
     */
    public static String npi(Integer n) {
        String base = '2' + String.valueOf(n).leftPad(8, '0');
        Integer total = 24; // Luhn contribution of the '80840' prefix, as in ProviderMatcher
        for (Integer i = 0; i < 9; i++) {
            Integer digit = Integer.valueOf(base.substring(i, i + 1));
            if (Math.mod(i, 2) == 0) {
                digit *= 2;
                if (digit > 9) {
                    digit -= 9;
                }
            }
            total += digit;
        }
        return base + Math.mod(10 - Math.mod(total, 10), 10);
    }

    /**
     * @param headers Column order
     * @param rows Rows, header => value; missing headers are blank
     * @return CSV text with every value quoted
     */
    public static String toCsv(List<String> headers, List<Map<String, String>> rows) {
        List<String> lines = new List<String>{ quoteAll(headers) };
        for (Map<String, String> row : rows) {
            List<String> values = new List<String>();
            for (String header : headers) {
                values.add(row.get(header) ?? '');
            }
            lines.add(quoteAll(values));
        }
        return String.join(lines, '\r\n') + '\r\n';
    }

    private static String quoteAll(List<String> values) {
        List<String> quoted = new List<String>();
        for (String value : values) {
            quoted.add('"' + value.replace('"', '""') + '"');
        }
        return String.join(quoted, ',');
    }

    /**
     * Creates a user with the Roster_Intake permission set. Classes at
     * API 67.0 query in user mode by default, and users get access to the Run and
     * Issue fields only through this permission set; it takes effect inside
     * System.runAs.
     *
     * @param lastName Distinguishes the user; look it up again with intakeUser()
     * @return The new user
     */
    public static User createIntakeUser(String lastName) {
        User user = new User(
            ProfileId = UserInfo.getProfileId(),
            LastName = lastName,
            Username = lastName.toLowerCase() + '.' + Datetime.now().getTime() + '@test.invalid',
            Email = 'roster.intake@test.invalid',
            Alias = 'ringest',
            TimeZoneSidKey = 'America/Denver',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        // runAs separates this setup-object DML from later non-setup DML (MIXED_DML_OPERATION).
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert user;
            insert new PermissionSetAssignment(
                AssigneeId = user.Id,
                PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'Roster_Intake'].Id
            );
        }
        return user;
    }

    /**
     * @param lastName The last name passed to createIntakeUser
     * @return That user
     */
    public static User intakeUser(String lastName) {
        return [SELECT Id FROM User WHERE LastName = :lastName LIMIT 1];
    }

    /**
     * @return An Organization account, which Roster_Intake__c.Organization__c requires
     */
    public static Account createOrganization() {
        Account organization = new Account(
            Name = 'Test Organization',
            RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
                .get('Organization')
                .getRecordTypeId()
        );
        insert organization;
        return organization;
    }

    /**
     * @param organizationId An Organization account (see createOrganization)
     * @return A new Roster_Intake__c
     */
    public static Roster_Intake__c createRoster(Id organizationId) {
        Roster_Intake__c roster = new Roster_Intake__c(Organization__c = organizationId);
        insert roster;
        return roster;
    }

    /**
     * Uploads a provider file (or a new version of the existing one) for the roster.
     *
     * @param roster The roster; its Provider_File_ID__c is set on the first upload
     * @param body The file content
     * @return The new ContentVersion
     */
    public static ContentVersion uploadProviderFile(Roster_Intake__c roster, Blob body) {
        Roster_Intake__c current = [SELECT Id, Provider_File_ID__c FROM Roster_Intake__c WHERE Id = :roster.Id];
        ContentVersion version = new ContentVersion(
            Title = 'provider',
            PathOnClient = 'provider.csv',
            VersionData = body
        );
        if (current.Provider_File_ID__c == null) {
            version.FirstPublishLocationId = roster.Id;
        } else {
            version.ContentDocumentId = current.Provider_File_ID__c;
        }
        insert version;

        version = [SELECT Id, ContentDocumentId, VersionNumber FROM ContentVersion WHERE Id = :version.Id];
        if (current.Provider_File_ID__c == null) {
            current.Provider_File_ID__c = version.ContentDocumentId;
            update current;
        }
        return version;
    }
}
