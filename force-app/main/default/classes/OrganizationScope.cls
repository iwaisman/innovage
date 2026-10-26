/**
 * Which Organizations a roster speaks for: the roster's Organization and every
 * Organization below it (children through Account.ParentId, their children,
 * and so on). Organizations above it are never included.
 *
 * A facility belongs to the scope when its HealthcareFacility's Legal Owner is
 * one of these Organizations. Relationship intake only changes
 * relationships at facilities in the scope.
 *
 * Runs without sharing and queries in system mode: the scope must not depend on
 * which Organizations the uploader happens to be able to see.
 */
public without sharing class OrganizationScope {

    public static final String ORGANIZATION_RECORD_TYPE = 'Organization';

    /* A guard against bad data; real hierarchies are a few levels deep. */
    @TestVisible
    private static Integer maxDepth = 10;

    /**
     * @param organizationId The roster's Organization
     * @return organizationId and the Ids of every Organization below it
     * @throws IllegalArgumentException if organizationId is null
     * @example
     * Set<Id> scope = OrganizationScope.forOrganization(roster.Organization__c);
     */
    public static Set<Id> forOrganization(Id organizationId) {
        if (organizationId == null) {
            throw new IllegalArgumentException('Organization Id cannot be null.');
        }

        Id organizationRecordTypeId = getOrganizationRecordTypeId();
        Set<Id> scope = new Set<Id>{ organizationId };
        Set<Id> level = new Set<Id>{ organizationId };

        // One query per level of the hierarchy. The visited check (scope) stops a ParentId cycle.
        for (Integer depth = 0; depth < maxDepth && !level.isEmpty(); depth++) {
            Set<Id> children = new Set<Id>();
            for (Account child : [
                SELECT Id
                FROM Account
                WHERE ParentId IN :level AND RecordTypeId = :organizationRecordTypeId
                WITH SYSTEM_MODE
            ]) {
                if (scope.add(child.Id)) {
                    children.add(child.Id);
                }
            }
            level = children;
        }
        return scope;
    }

    /**
     * @return The Id of the Account Organization record type
     */
    public static Id getOrganizationRecordTypeId() {
        return Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName()
            .get(ORGANIZATION_RECORD_TYPE)
            .getRecordTypeId();
    }
}
