// Creates Organizations, facilities and Legal Owners in the sandbox for testing
// relationships ingestion. Everything created has Description = TAG, so people
// can tell it is test data; the script refuses to run if any of the Accounts it
// creates (by name) already exist. (Description cannot be filtered in SOQL.)
//
// Run:
//     sf apex run --file scripts/apex/createRelationshipTestData.apex -o innovage | grep USER_DEBUG
//
// Hierarchy (the rosters' Organization is the existing "Acme"):
//
//     Acme (existing)                       in scope for Acme rosters
//     ├── Acme West
//     │   └── Acme West Clinics
//     └── Acme East
//     Beacon Health                         another Organization: out of scope
//     └── Beacon North
//
// Facilities (Participant_Facility Accounts; Legal Owner on their HealthcareFacility):
//
//     Acme                Acme Main Hospital, Acme Rehab Center,
//                         Acme Shared NPI Clinic 1 + 2 (same NPI: MULTIPLE_FACILITY_MATCHES),
//                         Acme No Address Clinic (no ShippingStreet)
//     Acme West           West Valley Hospital, West Skilled Nursing
//     Acme West Clinics   West Clinic One
//     Acme East           East Assisted Living
//     Beacon Health       Beacon General, Beacon Shared NPI (same NPI as the Acme shared pair)
//     Beacon North        Beacon North Clinic
//
// The existing facility "General Hospital" is left alone: it has no Legal Owner,
// so it is the FACILITY_NOT_IN_ORGANIZATION "no Legal Owner" case.

String TAG = 'Roster ingestion test data (scripts/apex/createRelationshipTestData.apex)';
String ROSTER_ORGANIZATION = 'Acme';

Set<String> NAMES = new Set<String>{
    'Acme West', 'Acme East', 'Acme West Clinics', 'Beacon Health', 'Beacon North',
    'Acme Main Hospital', 'Acme Rehab Center', 'Acme Shared NPI Clinic 1', 'Acme Shared NPI Clinic 2',
    'Acme No Address Clinic', 'West Valley Hospital', 'West Skilled Nursing', 'West Clinic One',
    'East Assisted Living', 'Beacon General', 'Beacon Shared NPI', 'Beacon North Clinic'
};
if ([SELECT COUNT() FROM Account WHERE Name IN :NAMES] > 0) {
    System.debug('Test data already exists (an Account with one of the test names). Nothing created.');
    return;
}

Id organizationRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Organization').getRecordTypeId();
Id facilityRecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Participant_Facility').getRecordTypeId();

Account acme = [SELECT Id, Name FROM Account WHERE RecordTypeId = :organizationRecordTypeId AND Name = :ROSTER_ORGANIZATION LIMIT 1];
Map<String, Id> organizationIds = new Map<String, Id>{ acme.Name => acme.Id };

Database.DMLOptions allowDuplicates = new Database.DMLOptions();
allowDuplicates.DuplicateRuleHeader.allowSave = true;
allowDuplicates.optAllOrNone = true;

// Organizations, parents before children (each level is inserted after its parents exist).
List<List<String>> organizationLevels = new List<List<String>>{
    new List<String>{ 'Acme West|Acme', 'Acme East|Acme', 'Beacon Health|' },
    new List<String>{ 'Acme West Clinics|Acme West', 'Beacon North|Beacon Health' }
};
for (List<String> level : organizationLevels) {
    List<Account> organizations = new List<Account>();
    for (String spec : level) {
        List<String> parts = spec.split('\\|', -1);
        organizations.add(new Account(
            Name = parts[0],
            ParentId = String.isBlank(parts[1]) ? null : organizationIds.get(parts[1]),
            RecordTypeId = organizationRecordTypeId,
            Description = TAG
        ));
    }
    Database.insert(organizations, allowDuplicates);
    for (Account organization : organizations) {
        organizationIds.put(organization.Name, organization.Id);
    }
}

// Valid NPIs (Luhn check digit over '80840' + the first 9 digits), distinct from the personnel test files.
Map<Integer, String> npis = new Map<Integer, String>();
for (Integer n = 1; n <= 12; n++) {
    String base = '17' + String.valueOf(n).leftPad(7, '0');
    Integer total = 24;
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
    npis.put(n, base + Math.mod(10 - Math.mod(total, 10), 10));
}

// name | legal owner | NPI number (0 = none) | street (blank = none) | type
List<String> facilitySpecs = new List<String>{
    'Acme Main Hospital|Acme|1|100 Main St|Hospital',
    'Acme Rehab Center|Acme|2|110 Main St|Skilled Nursing',
    'Acme Shared NPI Clinic 1|Acme|3|120 Elm St|Practice/Specialty Office',
    'Acme Shared NPI Clinic 2|Acme|3|130 Elm St|Practice/Specialty Office',
    'Acme No Address Clinic|Acme|4||Practice/Specialty Office',
    'West Valley Hospital|Acme West|5|200 Valley Rd|Hospital',
    'West Skilled Nursing|Acme West|6|210 Valley Rd|Skilled Nursing',
    'West Clinic One|Acme West Clinics|7|220 Oak Ave|Practice/Specialty Office',
    'East Assisted Living|Acme East|8|300 River St|Assisted Living',
    'Beacon General|Beacon Health|9|400 Lake Dr|Hospital',
    'Beacon Shared NPI|Beacon Health|3|410 Lake Dr|Practice/Specialty Office',
    'Beacon North Clinic|Beacon North|10|500 Hill St|Practice/Specialty Office'
};

List<Account> facilities = new List<Account>();
Map<String, String> ownerByFacility = new Map<String, String>();
for (String spec : facilitySpecs) {
    List<String> parts = spec.split('\\|', -1);
    Integer npiNumber = Integer.valueOf(parts[2]);
    facilities.add(new Account(
        Name = parts[0],
        RecordTypeId = facilityRecordTypeId,
        Type = parts[4],
        Group_Type_2_NPI__c = npiNumber == 0 ? null : npis.get(npiNumber),
        ShippingStreet = String.isBlank(parts[3]) ? null : parts[3],
        ShippingCity = String.isBlank(parts[3]) ? null : 'Denver',
        ShippingState = String.isBlank(parts[3]) ? null : 'CO',
        ShippingPostalCode = String.isBlank(parts[3]) ? null : '80202',
        Description = TAG
    ));
    ownerByFacility.put(parts[0], parts[1]);
}
Database.insert(facilities, allowDuplicates);

// The org's automation normally creates each facility's HealthcareFacility and sets
// Account.Healthcare_Facility__c; create whatever it did not.
Map<Id, Account> facilitiesById = new Map<Id, Account>([
    SELECT Id, Name, Healthcare_Facility__c FROM Account WHERE Id IN :facilities
]);
List<HealthcareFacility> missing = new List<HealthcareFacility>();
for (Account facility : facilitiesById.values()) {
    if (facility.Healthcare_Facility__c == null) {
        missing.add(new HealthcareFacility(Name = facility.Name, AccountId = facility.Id));
    }
}
if (!missing.isEmpty()) {
    insert missing;
    List<Account> pointers = new List<Account>();
    for (HealthcareFacility record : missing) {
        pointers.add(new Account(Id = record.AccountId, Healthcare_Facility__c = record.Id));
    }
    update pointers;
    facilitiesById = new Map<Id, Account>([SELECT Id, Name, Healthcare_Facility__c FROM Account WHERE Id IN :facilities]);
}
System.debug(missing.size() + ' HealthcareFacility records created by this script (the rest by org automation).');

// Legal Owners.
List<HealthcareFacility> owners = new List<HealthcareFacility>();
for (Account facility : facilitiesById.values()) {
    owners.add(new HealthcareFacility(
        Id = facility.Healthcare_Facility__c,
        Legal_Owner__c = organizationIds.get(ownerByFacility.get(facility.Name))
    ));
}
update owners;

// Summary.
for (Account organization : [
    SELECT Name, InnovAge_Unique_ID__c, Parent.Name FROM Account WHERE Id IN :organizationIds.values() ORDER BY Name
]) {
    System.debug('ORG | ' + organization.Name + ' | ' + organization.InnovAge_Unique_ID__c + ' | parent: ' + organization.Parent?.Name);
}
for (Account facility : [
    SELECT Name, InnovAge_Unique_ID__c, Group_Type_2_NPI__c, ShippingStreet, Healthcare_Facility__r.Legal_Owner__r.Name
    FROM Account WHERE Id IN :facilities ORDER BY Name
]) {
    System.debug('FACILITY | ' + facility.Name + ' | ' + facility.InnovAge_Unique_ID__c + ' | NPI ' +
        facility.Group_Type_2_NPI__c + ' | ' + facility.ShippingStreet + ' | owner: ' +
        facility.Healthcare_Facility__r?.Legal_Owner__r?.Name);
}
