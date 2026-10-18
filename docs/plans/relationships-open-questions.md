# Relationships ingestion: open questions and provisional decisions

Status as of 2026-10-18. Relationships ingestion is built and deployed to the
`innovage` sandbox, but some of its behaviours rest on assumptions nobody has
confirmed yet. This document lists them, so they can be checked with the
people who know: the business owners of rosters, the Health Cloud / data model
owners, and the teams that own the org's automation. It also records the
questions already settled ([section 5](#5-settled-on-2026-10-18)).

How the feature works is in
[roster-ingestion.md](../architecture/roster-ingestion.md). Why it was built
this way is in [relationships-ingestion.md](relationships-ingestion.md).

Each open item gives what the code does **today**, why that is uncertain, and
what would change if the answer is different.

1. [Questions with no answer yet](#1-questions-with-no-answer-yet)
2. [Provisional decisions](#2-provisional-decisions): decided "for now", likely
   to be revisited.
3. [Data to check before real use](#3-data-to-check-before-real-use)
4. [Observations for other teams](#4-observations-for-other-teams)
5. [Settled on 2026-10-18](#5-settled-on-2026-10-18)

## 1. Questions with no answer yet

### 1.1 Facility found by NPI or address, but owned outside the roster's Organizations

- **Today:** reported as `FACILITY_NOT_FOUND`, because NPI and address searches
  only look at facilities inside the roster's Organizations. Only a facility
  found by **Unique ID** gets the more specific `FACILITY_NOT_IN_ORGANIZATION`,
  whose message names the facility's owner.
- **To decide:** whether NPI and address rows should also say "this facility
  exists but belongs to another Organization". That would mean searching every
  facility, not only those in scope, and would make a shared NPI ambiguous
  across Organizations as well as within one.
- **Where:** [FacilityMatcher.cls](../../force-app/main/default/classes/FacilityMatcher.cls#L391)

### 1.2 The final file format

- **Today:** the columns are taken from the first draft and must all be present
  (values may be blank): Provider Unique ID, Individual NPI, Facility Unique ID,
  Facility NPI, Facility Shipping Address, Relationship Start Date, Terminate.
  Dates are MM/DD/YYYY. Terminate accepts blank, `Single` or `All`, ignoring
  case.
- **Unsure because:** the column list was described as a rough draft, and no
  real relationships file exists yet.
- **What would change:** the header names in
  [RelationshipCsvMapping.cls](../../force-app/main/default/classes/RelationshipCsvMapping.cls),
  and possibly the matching rules if new columns appear.

## 2. Provisional decisions

### 2.1 What counts as an active relationship

- **Today:** a relationship is active when `IsActive = true` **and**
  `TerminationDate` is blank.
- **Unsure because:** decided "for now"; the org has no existing relationships
  to show how these fields are used in practice.
- **Side effect:** a relationship with `IsActive = true` but a termination date
  (for example a future date set by hand) counts as *not* active. A create row
  then adds a second relationship beside it, and a Terminate row leaves it
  alone.
- **Where:** [RelationshipIngestionService.cls](../../force-app/main/default/classes/RelationshipIngestionService.cls#L288) (the query that loads active relationships)

### 2.2 An address that disagrees with a facility found by ID

- **Today:** an **error** (`FACILITY_KEY_MISMATCH`), the same as a disagreeing
  NPI. This errs on the side of caution.
- **Unsure because:** addresses are often written differently ("St" vs
  "Street", suite numbers), so this may reject good rows. It may become a
  warning, or a fuzzier comparison.
- **Where:** [FacilityMatcher.cls](../../force-app/main/default/classes/FacilityMatcher.cls#L327) (marked REVISIT)

### 2.3 Blank stored address or NPI on a facility

- **Today:** once the Facility Unique ID and/or NPI has matched, a facility
  with no stored address (or no stored NPI) is **not** a mismatch, whatever the
  file says. In an address-only search, a facility with no address can never
  match.
- **Unsure because:** decided "for now". Facilities should all have an
  address, but nothing in the database guarantees it.
- **Where:** [FacilityMatcher.cls](../../force-app/main/default/classes/FacilityMatcher.cls#L287) (NPI) and [line 334](../../force-app/main/default/classes/FacilityMatcher.cls#L334) (address)

### 2.4 The facility address is a single line

- **Today:** one column, "Facility Shipping Address", compared with the first
  line of `Account.ShippingStreet`. Case, extra spaces and trailing punctuation
  are ignored; there are no abbreviation rules ("St" ≠ "Street").
- **Unsure because:** the format is not known yet; City, State, ZIP or a second
  line may follow.
- **Where:** [RelationshipCsvMapping.cls](../../force-app/main/default/classes/RelationshipCsvMapping.cls#L15), [FacilityMatcher.cls](../../force-app/main/default/classes/FacilityMatcher.cls#L167)

### 2.5 The termination date

- **Today:** a terminated relationship gets `TerminationDate` = the date the Run
  started, and `TerminationReason` is left blank. The file has no termination
  date column.
- **Unsure because:** the business may want the file to supply the real
  termination date, or a reason (the picklist has Facility Closed and Left
  Organization).
- **Where:** [RosterIngestionBatch.cls](../../force-app/main/default/classes/RosterIngestionBatch.cls#L101)

## 3. Data to check before real use

The `innovage` sandbox now has test Organizations and facilities (created
2026-10-18 by
[scripts/apex/createRelationshipTestData.apex](../../scripts/apex/createRelationshipTestData.apex)):
sub-organizations under Acme, an unrelated Beacon Health hierarchy, and 12
facilities with Legal Owners, including a shared NPI and a facility without an
address. This shows the code works on realistic shapes; it says nothing about
the quality of production data.

- **Legal Owners and the Organization hierarchy.** A facility with no Legal
  Owner is never covered by any roster, so every row for it fails. Today no
  sandbox facility has one. Production data quality is unknown.
- **Facility NPIs and addresses.** Both are empty on the one sandbox facility,
  so NPI and address matching are untested against real data.
- **Payer participation side effects.** Creating a relationship (`IsActive =
  true`) makes the org's `Provider_Plan_Participation_AutoCreate` flow create a
  plan participation record. Deactivating one makes
  `Provider_Plan_Participation_AutoEndDate` end it. Confirm that ingestion is
  meant to trigger both.
- **Cost per slice.** Each created or terminated relationship runs those two
  flows. Relationships runs use 200 rows per slice, like personnel runs, but
  have not been measured. A smaller slice may be needed.

## 4. Observations for other teams

- **`AARService` caches one role for every role name.** In the org's
  `AARService` class (not part of this project), `getFacilityOwnerRole(role_name)`
  stores the first role it looks up in a single static variable and returns it
  for every later call, whatever `role_name` is asked for. In a transaction that
  creates both an Organization-parent relationship ("Parent Organization") and
  a facility-owner relationship ("Facility Owner"), the second would get the
  first one's role. Worth passing to the team that owns NNVG-115.
- **Tests need setup data.** Inserting a child Organization, or a
  HealthcareFacility with a Legal Owner, fails in Apex tests unless the Health
  Cloud reciprocal roles "Parent Organization" and "Facility Owner" exist. Our
  tests create them (`RelationshipTestDataFactory.createOwnershipRoles`); other
  teams' tests that create such records will need to do the same.

## 5. Settled on 2026-10-18

These were open or provisional and are now decided. The code and tests follow
them.

**HealthcarePractitionerFacility fields**

| Field | Decision |
|---|---|
| `Name` | "&lt;Provider name&gt; @ &lt;Facility name&gt;" (as implemented) |
| `AccountId` | Not set |
| `PractitionerId` | Not set |
| `Predecessor_Record__c` | Not used |
| `EffectiveFrom` / `EffectiveTo` | Not used |
| Facility NPI | `Account.Group_Type_2_NPI__c` (not `HealthcareFacility.NPI_Type_2__c`) |
| HealthcareFacility per facility Account | Assumed one-to-one: no other HealthcareFacility points to the same Account through `AccountId`, so `Account.Healthcare_Facility__c` is the only link to consider |

**Behaviour**

| Situation | Decision |
|---|---|
| Re-creating a relationship that was terminated | Insert a new relationship; the terminated one is kept as is, not reactivated, and not linked |
| Organizations a roster covers | The roster's Organization and every Organization below it, never above (as implemented) |
| Start date on a relationship that already exists | Never set or changed; the start date is only written when a relationship is created |
| File's start date differs from an existing relationship's | Warning `START_DATE_DIFFERS` |
| Malformed start date on a create row | Error `INVALID_START_DATE`; the relationship is not created, so the user can fix the value |
| Start date on a Terminate row (Single or All) | Ignored, even if malformed; warning `START_DATE_IGNORED` (a start date has no meaning on a termination) |
| File gives a start date, existing relationship has none | Not applied; warning `START_DATE_DIFFERS` saying no change was made |
| Terminate Single, no active relationship | Nothing changes; warning `NO_ACTIVE_RELATIONSHIP` |
| Terminate All, no active relationship in scope | Nothing changes; warning `NO_ACTIVE_RELATIONSHIP` |
| Terminate All with facility columns filled in | Columns ignored; warning `FACILITY_COLUMNS_IGNORED` |
| Two or more active relationships already exist for one Provider and facility | Terminate ends all of them; a create row creates nothing. Either way, warning `MULTIPLE_ACTIVE_RELATIONSHIPS` so the anomaly can be investigated |
