# Provider specialties in personnel ingestion: plan

Status: **implemented (2026-10-20)** and deployed to `innovage`; how it works is in
[roster-ingestion.md](../architecture/roster-ingestion.md) section 6.1. The decisions are in
section 9; they replace the defaults in section 8 where they differ.

## 1. Goal

Two new personnel-file columns, **Primary Provider Specialty** and **Secondary
Provider Specialty**, link a Provider to specialties in the NUCC taxonomy.

| Piece | Object | Notes |
|---|---|---|
| Specialty | `verifiable__VfiNUCCTaxonomy__c` | Verifiable's copy of the NUCC taxonomy. Key: `verifiable__TaxonomyCode__c`, e.g. `207Q00000X` |
| Link | `HealthcareProviderTaxonomy` (HPT) | Standard Health Cloud join object, repurposed with a new lookup to the NUCC record |
| Provider | `HealthcareProvider` | Through `HPT.HealthcareProviderId`; found from the Provider Account's `Healthcare_Provider__c` |

## 2. What the org looks like (checked 2026-10-20, `innovage` sandbox)

**`verifiable__VfiNUCCTaxonomy__c`**
- 866 records. All were **created today (2026-10-20 17:19) by Alon Waisman**, so this was a data load, not an ongoing sync. `verifiable__SyncDate__c` is 06:30 the same day.
- `verifiable__TaxonomyCode__c` is not declared unique, but all 866 codes are distinct today.
- `verifiable__Vuid__c` is a unique external ID, probably Verifiable's stable key.
- `Name` holds the display name, e.g. "Family Medicine Physician" (80 chars).

**`HealthcareProviderTaxonomy`**
- **0 records**, and `CareTaxonomy` is empty too, so no existing data or convention constrains us.
- `Name` is **required** (255).
- `IsActive` **defaults to false**, as on HealthcarePractitionerFacility. `IsPrimaryTaxonomy` also defaults to false.
- It already has a custom **`Taxonomy_Code__c`** (text 25).
- Other fields: `AccountId`, `PractitionerId` (Contact), `TaxonomyId` (CareTaxonomy), `EffectiveFrom/To`, `SourceSystem`, `SourceSystemIdentifier` (unique).
- One active flow, **Taxonomy_Created_Create_Relationship_with_HCP**. On create, *when `PractitionerId` is set*, it fills in `AccountId` and `HealthcareProviderId`. We would set `HealthcareProviderId` directly, so this flow won't fire.

**`HealthcareProvider`** already has specialty fields of its own: `Primary_Specialty__c`, `Secondary_Specialty__c` and two "(2)" variants (picklists), plus `Taxonomy_Code__c` and `Taxonomy_Description__c`. This plan doesn't touch them, but they overlap with what it stores (Q9).

## 3. Objections

1. **The field can't be called `NuccTaxonomyId`.** Custom fields always end in
   `__c`; names like `TaxonomyId` are reserved for standard fields. Proposal:
   **`NUCC_Taxonomy__c`** (label "NUCC Taxonomy"), a lookup to
   `verifiable__VfiNUCCTaxonomy__c`.
2. **Linking by record Id is fragile, given how the taxonomy got here.** The
   table was bulk-loaded today. If it's ever reloaded (delete and re-insert),
   every lookup is cleared, or the reload is blocked, depending on the lookup's
   delete setting. Recommendation:
   - Keep the Id lookup, as specified.
   - **Also write the code into the existing `HPT.Taxonomy_Code__c`.** Then a
     reload can be repaired by matching codes, at the cost of one extra field
     assignment.
   - Use delete behaviour **Clear the value** (SetNull), so a reload isn't
     blocked.
3. **"The code isn't unique" is a risk, not a fact, today.** It is unique
   now. If duplicates appear (a second load, a sync), ingestion can't know
   which record is right. Simplest safe behaviour: ignore that value with a
   warning (Q3).
4. **The value format is unknown.** Parsing has to be in exactly one small,
   obviously-named place (a constant plus one method in `ProviderCsvMapping`),
   so it's easy to change when the real format arrives.
5. **The generator's header differs from yours.**
   `scripts/generate_roster_csv.py` writes "Additional Provider Specialty",
   with plain names like "Cardiology". The spec says "Secondary Provider
   Specialty". The example file you were given should settle which name is
   right (Q1).

## 4. Proposed behaviour (one row)

### 4.1 Reading the value

- The code is the text **after the last `:`**, trimmed. A value with no `:` is
  taken to be the code itself. Example: `Family Medicine Physician:207Q00000X`
  → `207Q00000X`. Splitting on the *last* colon tolerates a label containing
  colons. The separator lives in a constant, `SPECIALTY_CODE_SEPARATOR`.
- **Blank:** nothing changes.
- **No NUCC record has the code:** the value is ignored, with warning
  `UNKNOWN_SPECIALTY`. The rest of the row is ingested.
- **Several NUCC records have the code:** the value is ignored, with warning
  `AMBIGUOUS_SPECIALTY` (Q3).

This matches how every other invalid value is handled: dropped, warned about,
never fatal.

### 4.2 Applying it

Only HPT records with `NUCC_Taxonomy__c` set are considered. Any CareTaxonomy-
based records (none exist today) are left alone.

| File | Provider's current specialties | Result |
|---|---|---|
| Primary = P | no link to P | Insert an HPT for P: primary, active |
| Primary = P | P linked, not primary | Mark it primary (update) |
| Primary = P | P already primary | Nothing |
| Primary = P | another specialty Q is primary | **Q stays linked but is unmarked**; P becomes primary as above |
| Secondary = S | no link to S | Insert an HPT for S: not primary, active |
| Secondary = S | S already linked (primary or not) | Nothing. Secondary never changes the primary flag |
| Secondary = S, same as Primary | — | Treated as the primary only |
| Either column blank | — | Nothing for that column |

**Never removed:** specialties are never deleted or deactivated by ingestion
(Q4). A specialty that disappears from the file stays linked.

A new HPT gets:
- `Name` = the NUCC record's `Name`
- `HealthcareProviderId`
- `NUCC_Taxonomy__c`
- `Taxonomy_Code__c`
- `IsActive = true`
- `IsPrimaryTaxonomy` as above
- `AccountId` = the Provider Account (Q6)

### 4.3 Outcomes

- **New Provider:** INSERTED as today. The specialties are saved straight
  after the Provider.
- **Existing Provider:** a specialty change makes the row UPDATED, and it's
  reported like a field change ("Primary Specialty", "Secondary Specialty"). A
  row with no change at all stays UNCHANGED.
- **A specialty fails to save:** the Provider row has already been saved, so
  this is a **warning** (`SPECIALTY_NOT_SAVED`) with the reason, not an error
  (Q7).

## 5. Bulk (one slice) and code shape

Work added to `ProviderIngestionService.ingestAll`, **after** the Provider
saves:

1. Re-query `Healthcare_Provider__c` for the slice's Providers that have a
   specialty value. New Providers get their HealthcareProvider from org
   automation during the insert.
2. One query for the NUCC records with the slice's codes.
3. One query for those HealthcareProviders' existing NUCC HPT records.
4. Plan the rows **in file order** against a map keyed by HealthcareProvider +
   NUCC record. This is the same idea as the relationships ledger, so two rows
   for one Provider don't insert the same link twice. The last row's primary
   wins.
5. One update (primary flags) and one insert, both partial-success.

That's 3 queries and 2 DML per slice, which is small next to the Provider
work. Proposed classes:

| Change | Where |
|---|---|
| Read the two columns into codes; `SPECIALTY_CODE_SEPARATOR` | `ProviderCsvMapping` (new `MappedRow.primarySpecialtyCode` / `secondarySpecialtyCode`; not `FieldMapping`s, because they aren't Account fields) |
| Look up, plan and save the links | New class **`ProviderSpecialtyService`**, called once from `ingestAll` |
| `NUCC_Taxonomy__c` lookup on HealthcareProviderTaxonomy | New field metadata |
| Issue codes `UNKNOWN_SPECIALTY`, `AMBIGUOUS_SPECIALTY`, `SPECIALTY_NOT_SAVED` | Issue `Code__c` picklist |
| Docs | `docs/specs/personnel-file-mapping.csv` / `-rules.csv`, architecture doc |
| Generator | `Primary/Secondary Provider Specialty` columns as `<label>:<code>` with real codes |

Keeping the specialty logic in its own class keeps `ProviderIngestionService`
(already 380 lines) focused on Accounts, and makes the specialty rules testable
on their own.

## 6. Simplicity vs functionality: the trade-offs

| Decision | Simple choice (recommended) | Richer alternative | What the simple choice costs |
|---|---|---|---|
| Removing specialties | **Never remove**; additive only | Make the Provider's specialties match the file (remove ones not listed) | Stale secondaries accumulate; cleanup is manual |
| Ambiguous NUCC code | **Ignore with a warning** | Pick one (e.g. latest `SyncDate`) | A duplicate in the taxonomy blocks that specialty until fixed |
| Taxonomy lookup | **Query per slice** (one small query) | Load all 866 codes once per Run into the Context | ~25 extra small queries per 5,000-row run; nothing measurable |
| Specialty save failure | **Warning on an otherwise successful row** | Make Provider + specialties all-or-nothing per row | The Provider can exist without its specialty; the warning says so. All-or-nothing would need per-row savepoints, which don't fit the bulk save |
| Value parsing | **Text after the last ":"** in one method | A configurable pattern | Changing the format means changing one constant or method |
| Multiple secondaries | **One value** in the Secondary column | Several, `;`-separated like secondary languages | Can't add two secondaries in one row; easy to add later using the existing separator |
| Repair after a taxonomy reload | **Store the code too**; no repair tool | Automatic re-linking by code | A reload needs a one-off script |
| Change reporting | **Specialty changes count as UPDATED** | A separate counter | None worth noting |

## 7. Phases

1. Field `NUCC_Taxonomy__c` and the Issue codes. Deploy.
2. Parsing in `ProviderCsvMapping`, with tests.
3. `ProviderSpecialtyService`, with tests for every line of the 4.2 table and
   same-slice rows. Wire it into `ingestAll`. The existing tests must stay
   green.
4. Specs, architecture doc, generator.
5. Sandbox run with a generated file.

## 8. Open questions (recommended default in **bold**)

1. **Header names.** "Primary Provider Specialty" / "Secondary Provider
   Specialty" (your spec), or "… / Additional Provider Specialty" (the
   generator)? **Check the example file; default to your names.**
2. **Primary replaced: confirm the reading.** When a new primary arrives, the
   old primary **stays linked but is no longer primary**. Is that right? (The
   description said "the only specialty should remain"; I took "only" to mean
   "old".)
3. **Several NUCC records with one code:** **ignore with a warning**, or pick
   one?
4. **Removing specialties:** **never**, or make the Provider's specialties
   match the file?
5. **Field name:** **`NUCC_Taxonomy__c`**, with delete behaviour **Clear the
   value**, and also store the code in **`Taxonomy_Code__c`**?
6. **`AccountId` on the link:** **set it to the Provider Account** (the org's
   own flow fills it in for this object), or leave it blank as we did for
   relationships?
7. **A specialty that fails to save:** **warning**, or error on the row?
8. **Unknown code:** **warning and ignore**, like other invalid values, or
   reject the row?
9. **The `HealthcareProvider` specialty fields** (`Primary_Specialty__c`,
   `Taxonomy_Code__c`, …): **leave them alone**, or also fill them? Worth
   asking who uses them, since they overlap with this data.
10. **Only one Secondary value per row**, for now?

## 9. Decisions (2026-10-20)

| # | Decision |
|---|---|
| 1 | Headers: **Primary Provider Specialty** and **Secondary Provider Specialty**. |
| 2 | A new primary makes the old primary a non-primary link; it is not removed. |
| 3 | Several NUCC records with one code: the value is ignored with warning `AMBIGUOUS_SPECIALTY`. (The code should be unique; nothing enforces it.) |
| 4 | Ingestion never removes specialties. |
| 5 | Field `NUCC_Taxonomy__c`, lookup to `verifiable__VfiNUCCTaxonomy__c`, delete behaviour **Clear the value** (SetNull). The code is also stored in `Taxonomy_Code__c`. **Existing links are found by `Taxonomy_Code__c`**, not by the lookup, so a link whose lookup was cleared (taxonomy deleted and reloaded) is found again and its lookup refilled: a reload heals itself on the Provider's next ingestion. Better still, reload the taxonomy by upsert on `verifiable__Vuid__c` so Ids never change. |
| 6 | `AccountId` is left blank. |
| 7 | A specialty that fails to save is a warning (`SPECIALTY_NOT_SAVED`); the Provider row stands. |
| 8 | An unknown code is a warning (`UNKNOWN_SPECIALTY`) and is ignored. |
| 9 | The `HealthcareProvider` specialty fields are left alone (expected to be unused and removed). |
| 10 | Zero or one Secondary specialty per row. |
