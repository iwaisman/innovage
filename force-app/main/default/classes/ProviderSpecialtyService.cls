/**
 * Links ingested Providers to their NUCC specialties (the Primary / Secondary
 * Provider Specialty columns). A link is a HealthcareProviderTaxonomy (HPT)
 * between the Provider's HealthcareProvider and a verifiable__VfiNUCCTaxonomy__c
 * record (HPT.NUCC_Taxonomy__c), with the code also kept in Taxonomy_Code__c.
 *
 *     Primary P      P not linked           -> new link, primary
 *                    P linked, not primary  -> marked primary
 *                    another link primary   -> that one stays linked, unmarked
 *     Secondary S    S not linked           -> new link, not primary
 *                    S already linked       -> nothing (secondary never changes "primary")
 *
 * Links are never removed. An unknown or ambiguous code is ignored with a
 * warning; a link that fails to save is a warning too. The Provider has already
 * been saved by then, so neither makes the row an error.
 *
 * EXISTING LINKS ARE FOUND BY Taxonomy_Code__c, not by the lookup. If the
 * taxonomy is deleted and reloaded, the lookup is cleared (SetNull) but the code
 * stays, so the link is found again here and its lookup refilled.
 *
 * Rows are applied in order against one map of the slice's links, so two rows
 * for one Provider never create the same link twice; the last row's primary wins.
 *
 * Queries and DML run in system mode, like the rest of Provider ingestion.
 */
public with sharing class ProviderSpecialtyService {

    /* Warning codes; these are RosterIngestionIssue__c.Code__c values. */
    public static final String UNKNOWN_SPECIALTY = 'UNKNOWN_SPECIALTY';
    public static final String AMBIGUOUS_SPECIALTY = 'AMBIGUOUS_SPECIALTY';
    public static final String SPECIALTY_NOT_SAVED = 'SPECIALTY_NOT_SAVED';

    /* How a change is reported in IngestResult.changesByField. */
    public static final String PRIMARY_SPECIALTY = 'Primary Specialty';
    public static final String SECONDARY_SPECIALTY = 'Secondary Specialty';

    private static final Map<String, String> HEADERS_BY_CHANGE = new Map<String, String>{
        PRIMARY_SPECIALTY => ProviderCsvMapping.PRIMARY_SPECIALTY_HEADER,
        SECONDARY_SPECIALTY => ProviderCsvMapping.SECONDARY_SPECIALTY_HEADER
    };

    /**
     * One saved Provider, the codes from its row, and (after apply) what happened.
     */
    public class Request {
        /** The Provider Account; null when the row was not saved (nothing is linked). */
        public Id accountId { get; private set; }
        /** Codes as read by ProviderCsvMapping.specialtyCode: null = blank, '' = no code in the value. */
        public String primaryCode { get; private set; }
        public String secondaryCode { get; private set; }
        /** Filled in by apply(). */
        public Outcome outcome { get; private set; }

        public Request(Id accountId, String primaryCode, String secondaryCode) {
            this.accountId = accountId;
            this.primaryCode = primaryCode;
            this.secondaryCode = secondaryCode;
            outcome = new Outcome();
        }
    }

    /**
     * What happened to one request's specialties.
     */
    public class Outcome {
        public List<ProviderCsvMapping.ValueWarning> warnings { get; private set; }
        /** PRIMARY_SPECIALTY / SECONDARY_SPECIALTY => old and new code. */
        public Map<String, ProviderIngestionService.FieldChange> changesByLabel { get; private set; }

        private Outcome() {
            warnings = new List<ProviderCsvMapping.ValueWarning>();
            changesByLabel = new Map<String, ProviderIngestionService.FieldChange>();
        }

        private void warn(String code, String column, String message) {
            warnings.add(new ProviderCsvMapping.ValueWarning(code, column, message));
        }
    }

    /**
     * Links the Providers to their specialties: three queries and at most one
     * update and one insert for the whole list. Each request's outcome is
     * recorded on it (Request.outcome).
     *
     * @param requests One per row, in file order
     * @throws IllegalArgumentException if requests is null
     */
    public static void apply(List<Request> requests) {
        if (requests == null) {
            throw new IllegalArgumentException('Requests cannot be null.');
        }

        Set<Id> accountIds = new Set<Id>();
        Set<String> codes = new Set<String>();
        for (Request request : requests) {
            if (request.accountId != null && (request.primaryCode != null || request.secondaryCode != null)) {
                accountIds.add(request.accountId);
                addCode(codes, request.primaryCode);
                addCode(codes, request.secondaryCode);
            }
        }
        if (accountIds.isEmpty()) {
            return;
        }

        Map<Id, Id> healthcareProviderByAccount = queryHealthcareProviders(accountIds);
        Map<String, List<verifiable__VfiNUCCTaxonomy__c>> taxonomiesByCode = queryTaxonomies(codes);
        Links links = new Links(queryLinks(new Set<Id>(healthcareProviderByAccount.values())));

        for (Request request : requests) {
            plan(request, healthcareProviderByAccount, taxonomiesByCode, links);
        }
        links.save();
    }

    private static void plan(
        Request request,
        Map<Id, Id> healthcareProviderByAccount,
        Map<String, List<verifiable__VfiNUCCTaxonomy__c>> taxonomiesByCode,
        Links links
    ) {
        Outcome outcome = request.outcome;
        if (request.accountId == null || (request.primaryCode == null && request.secondaryCode == null)) {
            return;
        }
        Id healthcareProviderId = healthcareProviderByAccount.get(request.accountId);
        if (healthcareProviderId == null) {
            outcome.warn(SPECIALTY_NOT_SAVED, null, 'The Provider has no Healthcare Provider record, so its specialties were not saved.');
            return;
        }

        verifiable__VfiNUCCTaxonomy__c primary = resolve(
            request.primaryCode, ProviderCsvMapping.PRIMARY_SPECIALTY_HEADER, taxonomiesByCode, outcome
        );
        verifiable__VfiNUCCTaxonomy__c secondary = resolve(
            request.secondaryCode, ProviderCsvMapping.SECONDARY_SPECIALTY_HEADER, taxonomiesByCode, outcome
        );
        if (primary != null) {
            links.makePrimary(healthcareProviderId, primary, outcome);
        }
        if (secondary != null) {
            links.add(healthcareProviderId, secondary, outcome);
        }
    }

    /* The single NUCC record with the code, or null (with a warning) when there is none or several. */
    private static verifiable__VfiNUCCTaxonomy__c resolve(
        String code,
        String column,
        Map<String, List<verifiable__VfiNUCCTaxonomy__c>> taxonomiesByCode,
        Outcome outcome
    ) {
        if (code == null) {
            return null;
        }
        if (code == '') {
            outcome.warn(UNKNOWN_SPECIALTY, column, 'Ignored: the value has no taxonomy code (expected "<label>' +
                ProviderCsvMapping.SPECIALTY_CODE_SEPARATOR + '<code>").');
            return null;
        }
        List<verifiable__VfiNUCCTaxonomy__c> taxonomies = taxonomiesByCode.get(code.toUpperCase());
        if (taxonomies == null) {
            outcome.warn(UNKNOWN_SPECIALTY, column, 'Ignored: no NUCC taxonomy has the code "' + code + '".');
            return null;
        }
        if (taxonomies.size() > 1) {
            // verifiable__TaxonomyCode__c should be unique, but nothing enforces it.
            outcome.warn(AMBIGUOUS_SPECIALTY, column, 'Ignored: ' + taxonomies.size() +
                ' NUCC taxonomy records have the code "' + code + '"; it should identify exactly one.');
            return null;
        }
        return taxonomies[0];
    }

    /*
     * A row whose outcome depends on saving a link, and the change it reports
     * (PRIMARY_SPECIALTY / SECONDARY_SPECIALTY; null for a repair, which is not
     * reported).
     */
    private class Dependency {
        Outcome outcome;
        String label;

        Dependency(Outcome outcome, String label) {
            this.outcome = outcome;
            this.label = label;
        }
    }

    /*
     * One link (an existing HPT, or a new one to insert) and the rows that
     * depend on saving it.
     */
    private class Link {
        HealthcareProviderTaxonomy record;
        List<Dependency> dependencies = new List<Dependency>();

        Link(HealthcareProviderTaxonomy record) {
            this.record = record;
        }

        String code() {
            return record.Taxonomy_Code__c.toUpperCase();
        }

        Boolean isNew() {
            return record.Id == null;
        }

        /* Changed by this slice: an existing link with dependencies needs an update. */
        Boolean isChanged() {
            return !dependencies.isEmpty();
        }

        void dependOn(Outcome outcome, String label) {
            dependencies.add(new Dependency(outcome, label));
        }

        /* The fields an update of an existing link may change. */
        HealthcareProviderTaxonomy changes() {
            return new HealthcareProviderTaxonomy(
                Id = record.Id,
                IsPrimaryTaxonomy = record.IsPrimaryTaxonomy,
                NUCC_Taxonomy__c = record.NUCC_Taxonomy__c
            );
        }

        /* The save failed: every dependent row loses the change and gets a warning. */
        void fail(List<Database.Error> errors) {
            List<String> messages = new List<String>();
            for (Database.Error error : errors) {
                messages.add(error.getMessage());
            }
            for (Dependency dependency : dependencies) {
                if (dependency.label != null) {
                    dependency.outcome.changesByLabel.remove(dependency.label);
                }
                dependency.outcome.warn(SPECIALTY_NOT_SAVED, HEADERS_BY_CHANGE.get(dependency.label),
                    'Specialty ' + record.Taxonomy_Code__c + ' could not be saved: ' + String.join(messages, '; '));
            }
        }

        /* Refills a lookup cleared by a taxonomy reload (or pointing elsewhere); not a reported change. */
        void repoint(verifiable__VfiNUCCTaxonomy__c taxonomy, Outcome outcome) {
            if (record.NUCC_Taxonomy__c != taxonomy.Id) {
                record.NUCC_Taxonomy__c = taxonomy.Id;
                dependOn(outcome, null);
            }
        }
    }

    /*
     * The slice's links by HealthcareProvider and code, updated as rows are
     * planned, then saved.
     */
    private class Links {
        private Map<Id, Map<String, Link>> linksByProvider = new Map<Id, Map<String, Link>>();
        private List<Link> all = new List<Link>();

        Links(List<HealthcareProviderTaxonomy> records) {
            for (HealthcareProviderTaxonomy record : records) {
                put(record.HealthcareProviderId, new Link(record));
            }
        }

        private Map<String, Link> of(Id healthcareProviderId) {
            if (!linksByProvider.containsKey(healthcareProviderId)) {
                linksByProvider.put(healthcareProviderId, new Map<String, Link>());
            }
            return linksByProvider.get(healthcareProviderId);
        }

        private Link put(Id healthcareProviderId, Link link) {
            of(healthcareProviderId).put(link.code(), link);
            all.add(link);
            return link;
        }

        private Link newLink(Id healthcareProviderId, verifiable__VfiNUCCTaxonomy__c taxonomy, Boolean primary) {
            return put(healthcareProviderId, new Link(new HealthcareProviderTaxonomy(
                Name = (taxonomy.Name ?? taxonomy.verifiable__TaxonomyCode__c).left(255),
                HealthcareProviderId = healthcareProviderId,
                NUCC_Taxonomy__c = taxonomy.Id,
                Taxonomy_Code__c = taxonomy.verifiable__TaxonomyCode__c,
                // Both default to false.
                IsActive = true,
                IsPrimaryTaxonomy = primary
            )));
        }

        void makePrimary(Id healthcareProviderId, verifiable__VfiNUCCTaxonomy__c taxonomy, Outcome outcome) {
            Map<String, Link> links = of(healthcareProviderId);
            String code = taxonomy.verifiable__TaxonomyCode__c.toUpperCase();
            Link target = links.get(code);
            if (target != null && target.record.IsPrimaryTaxonomy) {
                target.repoint(taxonomy, outcome);
                return; // already the primary
            }

            // The previous primary (normally at most one) stays linked, no longer primary.
            String previousCode = null;
            for (Link link : links.values()) {
                if (link.record.IsPrimaryTaxonomy) {
                    previousCode = link.record.Taxonomy_Code__c;
                    link.record.IsPrimaryTaxonomy = false;
                    link.dependOn(outcome, PRIMARY_SPECIALTY);
                }
            }

            if (target == null) {
                target = newLink(healthcareProviderId, taxonomy, true);
            } else {
                target.record.IsPrimaryTaxonomy = true;
                target.repoint(taxonomy, outcome);
            }
            target.dependOn(outcome, PRIMARY_SPECIALTY);
            outcome.changesByLabel.put(
                PRIMARY_SPECIALTY,
                new ProviderIngestionService.FieldChange(previousCode, taxonomy.verifiable__TaxonomyCode__c)
            );
        }

        void add(Id healthcareProviderId, verifiable__VfiNUCCTaxonomy__c taxonomy, Outcome outcome) {
            Link existing = of(healthcareProviderId).get(taxonomy.verifiable__TaxonomyCode__c.toUpperCase());
            if (existing != null) {
                existing.repoint(taxonomy, outcome);
                return;
            }
            newLink(healthcareProviderId, taxonomy, false).dependOn(outcome, SECONDARY_SPECIALTY);
            outcome.changesByLabel.put(
                SECONDARY_SPECIALTY,
                new ProviderIngestionService.FieldChange(null, taxonomy.verifiable__TaxonomyCode__c)
            );
        }

        /* Updates (primary flags, refilled lookups) first, then inserts, each partial-success. */
        void save() {
            List<Link> updated = new List<Link>();
            List<Link> inserted = new List<Link>();
            for (Link link : all) {
                if (link.isNew()) {
                    inserted.add(link);
                } else if (link.isChanged()) {
                    updated.add(link);
                }
            }
            saveAll(updated, false);
            saveAll(inserted, true);
        }
    }

    /*
     * Inserts or updates the links' records. Salesforce returns one result per
     * record in the order given, so result i belongs to links[i]: the only place
     * this class pairs lists by index.
     */
    private static void saveAll(List<Link> links, Boolean asInsert) {
        if (links.isEmpty()) {
            return;
        }
        List<HealthcareProviderTaxonomy> records = new List<HealthcareProviderTaxonomy>();
        for (Link link : links) {
            records.add(asInsert ? link.record : link.changes());
        }
        List<Database.SaveResult> results = asInsert
            ? Database.insert(records, false, AccessLevel.SYSTEM_MODE)
            : Database.update(records, false, AccessLevel.SYSTEM_MODE);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                links[i].fail(results[i].getErrors());
            }
        }
    }

    private static void addCode(Set<String> codes, String code) {
        if (String.isNotBlank(code)) {
            codes.add(code.toUpperCase());
        }
    }

    private static Map<Id, Id> queryHealthcareProviders(Set<Id> accountIds) {
        Map<Id, Id> healthcareProviderByAccount = new Map<Id, Id>();
        for (Account provider : [
            SELECT Id, Healthcare_Provider__c FROM Account WHERE Id IN :accountIds WITH SYSTEM_MODE
        ]) {
            if (provider.Healthcare_Provider__c != null) {
                healthcareProviderByAccount.put(provider.Id, provider.Healthcare_Provider__c);
            }
        }
        return healthcareProviderByAccount;
    }

    /* Keyed by upper-case code: the file's case need not match (SOQL IN ignores case). */
    private static Map<String, List<verifiable__VfiNUCCTaxonomy__c>> queryTaxonomies(Set<String> codes) {
        Map<String, List<verifiable__VfiNUCCTaxonomy__c>> taxonomiesByCode = new Map<String, List<verifiable__VfiNUCCTaxonomy__c>>();
        if (codes.isEmpty()) {
            return taxonomiesByCode;
        }
        for (verifiable__VfiNUCCTaxonomy__c taxonomy : [
            SELECT Id, Name, verifiable__TaxonomyCode__c
            FROM verifiable__VfiNUCCTaxonomy__c
            WHERE verifiable__TaxonomyCode__c IN :codes
            WITH SYSTEM_MODE
        ]) {
            String code = taxonomy.verifiable__TaxonomyCode__c.toUpperCase();
            if (!taxonomiesByCode.containsKey(code)) {
                taxonomiesByCode.put(code, new List<verifiable__VfiNUCCTaxonomy__c>());
            }
            taxonomiesByCode.get(code).add(taxonomy);
        }
        return taxonomiesByCode;
    }

    /* The Providers' NUCC links, found by code (see the class comment). */
    private static List<HealthcareProviderTaxonomy> queryLinks(Set<Id> healthcareProviderIds) {
        if (healthcareProviderIds.isEmpty()) {
            return new List<HealthcareProviderTaxonomy>();
        }
        return [
            SELECT Id, HealthcareProviderId, NUCC_Taxonomy__c, Taxonomy_Code__c, IsPrimaryTaxonomy
            FROM HealthcareProviderTaxonomy
            WHERE HealthcareProviderId IN :healthcareProviderIds AND Taxonomy_Code__c != NULL
            WITH SYSTEM_MODE
            ORDER BY CreatedDate, Id
        ];
    }
}
