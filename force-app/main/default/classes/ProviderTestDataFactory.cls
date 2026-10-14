/**
 * Test data for the Provider ingestion tests.
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
            'Medicaid ID State' => 'CO',
            'Provider Effective Date' => '01/01/2026'
        };
    }
}
