@IsTest
private class OrganizationScopeTest {

    /*
     * Top > Middle > Bottom, Middle > Sibling;  Unrelated;  a non-Organization child of Middle.
     */
    @TestSetup
    static void setup() {
        RelationshipTestDataFactory.createOwnershipRoles();
        Account top = RelationshipTestDataFactory.createOrganization('Top', null);
        Account middle = RelationshipTestDataFactory.createOrganization('Middle', top.Id);
        RelationshipTestDataFactory.createOrganization('Bottom', middle.Id);
        RelationshipTestDataFactory.createOrganization('Sibling', middle.Id);
        RelationshipTestDataFactory.createOrganization('Unrelated', null);
        Account facility = new Account(
            Name = 'Child Facility',
            ParentId = middle.Id,
            Type = 'Hospital',
            RecordTypeId = FacilityMatcher.getFacilityRecordTypeId()
        );
        Database.DMLOptions options = new Database.DMLOptions();
        options.DuplicateRuleHeader.allowSave = true;
        options.optAllOrNone = true; // DMLOptions otherwise saves partially and hides failures
        Database.insert(facility, options);
    }

    private static Map<String, Id> idsByName() {
        Map<String, Id> ids = new Map<String, Id>();
        for (Account account : [SELECT Id, Name FROM Account]) {
            ids.put(account.Name, account.Id);
        }
        return ids;
    }

    @IsTest
    static void shouldIncludeOrganizationAndEveryLevelBelow() {
        Map<String, Id> ids = idsByName();

        Set<Id> scope = OrganizationScope.forOrganization(ids.get('Middle'));

        Assert.areEqual(
            new Set<Id>{ ids.get('Middle'), ids.get('Bottom'), ids.get('Sibling') },
            scope,
            'Middle and its sub-organizations, not its parent, unrelated Organizations or other record types'
        );
    }

    @IsTest
    static void shouldWalkSeveralLevels() {
        Map<String, Id> ids = idsByName();

        Set<Id> scope = OrganizationScope.forOrganization(ids.get('Top'));

        Assert.areEqual(4, scope.size(), 'Top, Middle, Bottom, Sibling: ' + scope);
        Assert.isFalse(scope.contains(ids.get('Unrelated')), 'Unrelated is out');
    }

    @IsTest
    static void shouldStopAtMaxDepth() {
        Map<String, Id> ids = idsByName();
        OrganizationScope.maxDepth = 1;

        Set<Id> scope = OrganizationScope.forOrganization(ids.get('Top'));

        Assert.areEqual(new Set<Id>{ ids.get('Top'), ids.get('Middle') }, scope, 'One level below only');
    }

    @IsTest
    static void shouldRejectNullOrganization() {
        try {
            OrganizationScope.forOrganization(null);
            Assert.fail('Expected IllegalArgumentException');
        } catch (IllegalArgumentException e) {
            Assert.isTrue(e.getMessage().contains('Organization'), 'Explains why');
        }
    }
}
