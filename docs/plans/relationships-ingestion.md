# Relationships file ingestion: plan

Status: **phases 1–5 and 8 implemented (2026-10-17)** and deployed to the
`innovage` sandbox; 150 tests pass. Not done yet: phase 6 (synthetic
relationship files and sandbox facility data) and phase 7 (a 5,000-row
measurement). The implemented design is described in
[roster-ingestion.md](../architecture/roster-ingestion.md); this plan keeps the
decisions and their reasons.

Differences from the plan found while implementing:

- Facilities are reached through `Account.Healthcare_Facility__c` (the pointer
  the org's automation maintains, like `Healthcare_Provider__c`), so the
  `MULTIPLE_FACILITY_RECORDS` case cannot happen and was dropped.
- Malformed facility keys have their own codes: `MALFORMED_FACILITY_UNIQUE_ID`,
  `MALFORMED_FACILITY_NPI`.
- `sliceSize()` was not added to the processor interface; both file types use
  200 until relationships are measured.
- Tests must create the Health Cloud reciprocal roles the org's `AARService`
  needs, and facility Accounts need a `Type`.

## 1. Goal

A roster's **relationships file** says which Providers practise at which
Healthcare Facilities (HCFs). Each row creates a relationship, ends one, or ends
all of a Provider's relationships within the roster's Organization.

A relationship is a `HealthcarePractitionerFacility` (HPF) record that links a
`HealthcareProvider` to a `HealthcareFacility`.

The work reuses the Personnel ingestion's Roster / Run / Issue data model,
batch lifecycle and UI patterns. See
[provider-bulk-ingestion.md](../architecture/roster-ingestion.md).

Terms used below:

- **RIO**: the roster's Organization (`RosterIngestion__c.Organization__c`).
- **Organization scope**: the RIO plus every Organization below it (section 5).
  Only facilities in scope are ever changed.

## 2. What the org actually looks like (checked 2026-10-17, `innovage` sandbox)

### Objects and keys

| Thing | Where it lives | Notes |
|---|---|---|
| Provider | `Account`, record type `Provider` (person account) | Matched exactly as in Personnel: `InnovAge_Unique_ID__c` (prefix `P`) / `NPI__c` (unique, external ID). |
| Provider's HealthcareProvider | `HealthcareProvider` (`AccountId` → Provider Account). The Account also has `Healthcare_Provider__c` pointing back. | All 15 Provider Accounts have exactly one. Org automation creates it, not our ingestion. |
| Facility Account | `Account`, record type `Participant_Facility` | Unique ID prefix `MF`, e.g. `MF000702523t0K`. `InnovAgeUniqueId` already knows `MF`. |
| Facility NPI | `Account.Group_Type_2_NPI__c` | **Not unique.** `HealthcareFacility.NPI_Type_2__c` also exists; both are empty today. |
| Facility address | `Account.ShippingStreet` (textarea, may hold several lines) | Not required by any constraint. |
| HealthcareFacility | `HealthcareFacility.AccountId` (master-detail → facility Account) | Master-detail allows several HCFs per Account. There is 1 today. |
| Owning Organization | `HealthcareFacility.Legal_Owner__c` → Account (`Organization`); orgs nest through `Account.ParentId` | No HCF has a Legal Owner and no Organization has a parent today. |
| Relationship | `HealthcarePractitionerFacility` | **0 records in the sandbox**, so there is no existing convention to copy. |

### HealthcarePractitionerFacility fields that matter

| Field | Fact | Consequence |
|---|---|---|
| `Name` | Required (255), no default | We must generate one (section 6.3). |
| `HealthcareProviderId`, `HealthcareFacilityId` | The two link fields | The relationship's identity. |
| `AccountId` (Account), `PractitionerId` (Contact) | Older Health Cloud link fields, optional | Prepared but commented out (section 6.3). |
| `IsActive` | **Defaults to false** | It must be set to true on create. |
| `InitialStartDate` | Date | Gets the file's "Relationship Start Date". |
| `TerminationDate`, `TerminationReason` | The reason is a picklist: Facility Closed, Left Organization | We set the date (the run date) and leave the reason blank. |
| `Predecessor_Record__c` | Self lookup | Points a re-created relationship at the one it replaces. |

### Automation that fires when we write relationships

Both flows are after-save flows on HPF, and both key off **`IsActive`**:

- **Provider_Plan_Participation_AutoCreate** (create/update, `IsActive = true`)
  creates a `Provider_Plan_Participation__c` for the facility Account's
  `Primary_Payer_Network__c`, unless one is already open.
- **Provider_Plan_Participation_AutoEndDate** (update, `IsActive = false`)
  end-dates that participation when the Provider has no other active HPF in
  the network.

A termination therefore sets **both** `IsActive = false` and `TerminationDate`.
A creation sets `IsActive = true`.

## 3. File format

The header names follow the draft and are matched exactly, as in Personnel.

| Column | Value rules |
|---|---|
| Provider Unique ID | `P…` Unique ID, or blank |
| Individual NPI | 10-digit NPI with a valid check digit, or blank |
| Facility Unique ID | `MF…` Unique ID, or blank |
| Facility NPI | NPI, or blank |
| Facility Shipping Address | A single street line (address line 1), or blank. *May become several columns later.* |
| Relationship Start Date | Date in the formats `ProviderCsvMapping` accepts, or blank |
| Terminate | blank = create; `Single`; `All` (case-insensitive) |

Every column is required in the header, but any value may be blank. This makes
a misspelt header fail the file, instead of every row silently being read as
"no facility given".

## 4. Row behaviour (the single-row spec)

### 4.1 Provider (every row)

This reuses `ProviderMatcher` unchanged, with the same rules as Personnel
(Unique ID authoritative, then NPI, then cross-checks). Providers are global:
they are not limited to the Organization scope. The differences are:

- `NO_MATCH` is an **error** (`UNKNOWN_PROVIDER`), because this file never
  creates Providers.
- The matched Provider must have a HealthcareProvider. Otherwise the error is
  `PROVIDER_NOT_SET_UP`.

### 4.2 Facility (create and Terminate Single rows)

In order:

1. **Facility Unique ID given:** it must identify a `Participant_Facility`
   Account, otherwise `UNKNOWN_FACILITY_UNIQUE_ID`. Any other key given must
   agree with that facility:
   - An NPI that differs from a non-blank `Group_Type_2_NPI__c` is
     `FACILITY_KEY_MISMATCH`.
   - An address that differs from a non-blank `ShippingStreet` (see the
     comparison below) is also `FACILITY_KEY_MISMATCH`. *This is deliberately
     cautious and may be relaxed; the code carries a REVISIT comment.*
2. **Otherwise, Facility NPI given:** it must identify exactly one facility in
   scope. More than one is `MULTIPLE_FACILITY_MATCHES`, and none is
   `FACILITY_NOT_FOUND`. A given address must agree with the facility found,
   as in step 1.
3. **Otherwise, address given:** it must identify exactly one facility in
   scope, with the same errors as step 2.
4. **No facility key at all:** `NO_FACILITY_KEY_VALUES`.

After matching:

- The facility must be **in the Organization scope**: its HCF's
  `Legal_Owner__c` is in the scope set. A facility owned outside it, or with
  no Legal Owner, is `FACILITY_NOT_IN_ORGANIZATION`. (Steps 2–3 only search
  in scope, so in practice this catches step 1.) The message names the
  facility, the facility's Legal Owner Organization (name and Unique ID), and
  the roster's Organization. For example:
  - *Facility "General Hospital" (MF000702523t0K) belongs to Organization
    "Acme Health" (O000000123xY1), which is not "Beta Care" (O000000456zZ2) or
    one of its sub-organizations.*
  - *Facility "General Hospital" (MF000702523t0K) has no Legal Owner
    Organization, so it is not part of "Beta Care" (O000000456zZ2).*

  Showing the owner tells the person fixing the file whether the row is wrong
  (it names another Organization's facility) or the facility's data is wrong
  (the Legal Owner or Organization hierarchy needs fixing). Organization names
  are not sensitive, unlike the Provider values that Issue messages exclude.
- The facility Account must have exactly one HealthcareFacility. Otherwise the
  error is `FACILITY_NOT_SET_UP` or `MULTIPLE_FACILITY_RECORDS`.

**Blank stored values.** When an ID (Unique ID and/or NPI) has matched, a blank
`Group_Type_2_NPI__c` or `ShippingStreet` on the facility is **not** a
mismatch. This is the same rule as Provider NPIs. Nothing guarantees that
facilities have an address. In the address-only search (step 3), a facility
with a blank address can never match.

**Address comparison.** The file's value is compared with the **first line** of
`ShippingStreet`. Before comparing, both are trimmed, runs of whitespace become
one space, trailing punctuation is dropped, and case is ignored. There are no
abbreviation rules ("St" ≠ "Street").

**Facility NPI.** `Account.Group_Type_2_NPI__c` is used. A comment notes that
`HealthcareFacility.NPI_Type_2__c` also exists and may turn out to be the right
field.

### 4.3 Action

An **active** relationship is an HPF for this (HealthcareProvider,
HealthcareFacility) with `IsActive = true` **and** a blank `TerminationDate`.
The termination date written is the **run date**: the date the Run started.

| Terminate | Existing state | Result | Row outcome |
|---|---|---|---|
| blank | no active HPF | Insert an HPF (section 6.3), with `IsActive = true`, `InitialStartDate` if given, and `Predecessor_Record__c` = the most recent terminated HPF for the pair, if any | INSERTED |
| blank | active HPF exists | Nothing. If the file gives a start date and the stored one is blank, fill it in; if they differ, warn `START_DATE_DIFFERS` | UNCHANGED (UPDATED if filled) |
| Single | active HPF exists | `IsActive = false`, `TerminationDate` = run date | TERMINATED |
| Single | no active HPF | Nothing; warning `NO_ACTIVE_RELATIONSHIP` | UNCHANGED |
| All | — | Terminate every active HPF of the Provider whose HCF is in the Organization scope. Facility columns are ignored; if any is filled in, warn `FACILITY_COLUMNS_IGNORED` | TERMINATED, or UNCHANGED (with `NO_ACTIVE_RELATIONSHIP`) if there were none |
| anything else | — | — | ERROR `INVALID_TERMINATE_VALUE` |

An invalid **Relationship Start Date** is dropped with an `INVALID_VALUE`
warning, as in Personnel, and the relationship is still created.

Edge case: an HPF that has `IsActive = true` but a `TerminationDate` (for
example, set by hand) is **not** active under this definition. A create row
would then add a new HPF beside it, and a Terminate row would leave it alone.
This is acceptable until the definition of "active" is settled.

### 4.4 Rows in one slice that touch the same relationship

Nothing in the database makes a (Provider, Facility) relationship unique. Two
"create" rows processed together would therefore insert **two** HPFs. Section
7.2 explains how the service prevents this.

## 5. Organization scope

The Organization scope answers one question: **which facilities does this
roster speak for?**

Its value is a set of Organization Account Ids: the RIO, its children, their
children, and so on. A facility is in scope when its HealthcareFacility's
`Legal_Owner__c` is in that set. Organizations above the RIO are never
included.

```
Org E (A's parent)            ← not in scope
└── RIO (Org A)               ← in scope
    ├── Org B (ParentId = A)  ← in scope
    │   └── Org D (ParentId = B) ← in scope
    └── Org C (ParentId = A)  ← in scope
```

### What it is used for

1. **Terminate All:** only HPFs whose facility is in scope are terminated.
2. **Facility matching:** the NPI and address searches only consider
   facilities in scope. This also makes the non-unique NPI less ambiguous.
3. **Guarding single-facility rows:** a facility found by Unique ID but owned
   outside the scope, or by no one, is `FACILITY_NOT_IN_ORGANIZATION`. The
   message names the owning Organization, if any (section 4.2).

### How it is computed

`OrganizationScope.forOrganization(rioId)` returns the Id set.

- It walks **down** the hierarchy one level per query:
  `SELECT Id FROM Account WHERE ParentId IN :currentLevel AND RecordType = Organization`.
- It stops when a level is empty, or at a depth limit (10) as a guard against
  bad data. A visited set protects against a `ParentId` cycle.
- It runs in system mode, like the matchers, because the uploader may not see
  every Organization.

It is computed **once per Run**, in the batch's `start()`, and kept on the
Stateful batch alongside the headers. Every slice receives it through the
`IngestionContext` (section 7.1), so the whole Run works against one consistent
scope even if the hierarchy changes mid-run. The set is small (a handful of
Ids), so carrying it between slices costs nothing measurable.

The single-row `RelationshipIngestionService.ingest(row, organizationId)`, used
by tests and ad-hoc runs, computes the scope itself before calling `ingestAll`.

## 6. Data model and record details

### 6.1 Run and Issue changes

| Change | Why |
|---|---|
| `RosterIngestionRun__c.File_Type__c`: add `Relationships` | Distinguish Runs. |
| Run: add `Terminated__c` (Number); reuse Inserted / Updated / Unchanged / Errored / Rows With Warnings | Counts are **rows**, not records. A "Terminate All" row that ends 3 relationships counts once. |
| `Results__c` formula: add `term` | One formula; zero counts are already left out, so Personnel runs look the same. |
| `RosterIngestionIssue__c`: add `Facility__c` (Lookup Account), `Facility_Unique_ID__c`, `Facility_NPI__c` | The person fixing the file needs the facility keys. The existing `Unique_ID__c` / `NPI__c` stay Provider keys. |
| Issue `Code__c`: add the new codes from section 4 | Restricted picklist. |
| `RosterIngestion__c`: roll-ups `Relationship_Runs__c`, `Last_Relationship_Run__c` | Mirrors the Provider roll-ups. |
| `Roster_Ingestion_Files` permission set: the new fields | FLS (API 67.0 enforces it). |

### 6.2 Concurrency

There is **one active Run per roster**, across both file types. This is the
existing check, which filters by roster, so different rosters still run at the
same time.

If two rosters' runs update the same HPF at the same moment, the second may get
`UNABLE_TO_LOCK_ROW`. That is reported as a `SAVE_ERROR` on the row, and
re-running fixes it.

### 6.3 A new HPF

The new record gets:

- `Name`: `<Provider Account name> @ <Facility Account name>`, truncated to
  255. *A comment marks this as a placeholder until the proper naming
  convention is known.*
- `HealthcareProviderId`, `HealthcareFacilityId`, `IsActive = true`, and
  `InitialStartDate` when the file gives one.
- `Predecessor_Record__c` (see section 4.3). *A comment notes that its official
  meaning is unconfirmed.*
- `AccountId` (facility Account) and `PractitionerId` (Provider's
  PersonContactId): the code is written but **commented out**. A comment
  explains that the right behaviour is still to be investigated.

## 7. Code structure

### 7.1 Sharing the pipeline

The batch and run code are split into a generic part and a file-type part:

```apex
public interface RosterRowProcessor {
    List<String> requiredHeaders();
    Integer sliceSize();                     // Provider: 200; Relationships: measure (section 9)
    IngestionContext prepare(Id runId);      // once, in start(): e.g. the Organization scope
    List<IngestionRowResult> ingestAll(List<RowInput> rows, IngestionContext context);
}

public virtual class IngestionContext {    // per-Run facts, built in start(), kept on the batch
    public Id rosterIngestionId;
    public Date runDate;                    // the termination date
}
// RelationshipIngestionContext extends it with: Id organizationId; Set<Id> organizationScope;
```

| Class | Change |
|---|---|
| `RosterIngestionRunService` | `startRun(rosterId, fileType)` picks the file field (`Personnel_File__c` / `Relationships_File__c`) and the processor. Everything else (lock, active-run check, cancel, abandoned runs) is shared unchanged. |
| `ProviderIngestionBatch` → `RosterIngestionBatch` | The same start/execute/finish. Stateful fields: the Run Id, file type, headers (as today) and the `IngestionContext`. From the file type it creates the processor with a small factory in each transaction. |
| `IngestionRowResult` (new, shared) | Row number, outcome (INSERTED / UPDATED / TERMINATED / UNCHANGED / ERROR), error code and messages, value warnings, plus a map of key fields (Issue field → value) that the batch copies onto every Issue for the row. This replaces the Provider-specific fields `SliceResults` reads today. |
| `ProviderIngestionService` | Implements `RosterRowProcessor`; its `prepare` returns the base context. **Behaviour unchanged**; the existing 98 tests must stay green. |
| `RelationshipCsvMapping` (new) | Headers, Terminate parsing, start date (reusing `ProviderCsvMapping`'s date parser), key extraction. |
| `OrganizationScope` (new) | Section 5. |
| `FacilityMatcher` (new, `without sharing`) | Section 4.2. One query per slice for all keys, like `ProviderMatcher`. It also queries the Legal Owner's name and Unique ID for the out-of-scope message. |
| `RelationshipIngestionService` (new) | Sections 4.3–4.4 and 7.2. `ingestAll(rows, context)` plus a single-row `ingest(row, organizationId)`. |
| `providerIngestionRuns` LWC | Generalized to `rosterIngestionRunPanel`, with an App Builder property `fileType`, and placed twice on the roster page. A second Dynamic Related List shows Relationships runs. |

A file-level problem in `prepare` fails the Run in `start()`, just like a
missing column. For example, the roster has no Organization, which the lookup
already makes required.

### 7.2 Where the "in-memory record" lives

The record that prevents duplicate HPFs is a **local variable inside one
`ingestAll` call**. It is not batch state, and the shared pipeline never sees
it.

That is enough, because the problem only exists *within* a slice:

- **Across slices**, the database already does the job. Slices run one after
  another and each commits before the next starts. Each slice queries the
  existing HPFs for its rows, so it sees what earlier slices created or
  terminated.
- **Within a slice**, all rows are planned against one query result and saved
  together at the end. That is why two rows for the same pair could both
  decide "not there yet, insert".

The relationship service handles a slice like this:

1. Match the Providers and facilities for every row.
2. Query the active HPFs, plus the latest terminated HPF for each pair, for
   every Provider in the slice. One query.
3. Load them into a map keyed by `HealthcareProviderId + ':' + HealthcareFacilityId`
   (the ledger).
4. Walk the rows **in file order** and plan each against the ledger, then
   update the ledger:
   - A create puts a "pending insert" entry, so a later create of the same pair
     sees it and comes out UNCHANGED.
   - A terminate marks the entry terminated. If the entry is a pending insert,
     the insert is simply made with `IsActive = false` and the termination
     date, so the flows see the final state.
   - Terminate All marks every in-scope entry of that Provider.
5. Save once: one insert, one update, each partial-success, with each save
   result mapped back to the row or rows that produced it.

The ledger is discarded when `ingestAll` returns. It is the same idea as the
Provider service's merged updates (`PendingSaves`), made necessary because HPFs
have no unique key.

If a slice is rolled back after an error, its changes never reach the database.
Later slices therefore don't see them either, which is consistent.

## 8. Phases

1. **Refactor** (no behaviour change): the shared result, `RosterRowProcessor`,
   `IngestionContext`, `RosterIngestionBatch` and `startRun(fileType)`.
   Personnel tests green, then deploy.
2. **Matching:** `OrganizationScope` and `FacilityMatcher`, with unit tests and
   a test-data factory for Organization → child Organization → Facility Account
   → HCF (with Legal Owner) → Provider → HealthcareProvider (created as admin).
   Check whether org automation builds the HealthcareProvider / HCF in tests or
   the factory must.
3. **Row logic:** `RelationshipCsvMapping` and `RelationshipIngestionService`.
   Single-row tests for every line of the 4.3 table, then same-slice ledger
   tests.
4. **Data model and wiring:** fields, picklist values, permission set,
   `File_Type__c`, processor selection.
5. **UI:** the generalized panel and a second related list. Add facility
   columns to the Issue lists on the Run page.
6. **Synthetic data:** relationship files from `scripts/generate_roster_csv.py`
   or a sibling script, plus sandbox setup for Organizations, Legal Owners and
   facilities.
7. Run a 5,000-row file in the sandbox and measure.
8. Architecture doc: extend `provider-bulk-ingestion.md` or rename it to
   `roster-ingestion.md`.

## 9. Risks

- **Flow cost per slice.** Each created or terminated HPF runs two flows with
  lookups and an invocable action. If CPU is tight, the relationships processor
  declares a smaller `sliceSize()`.
- **Facility data quality.** No Legal Owners, Organization hierarchy or
  facility NPIs exist in the sandbox. A facility with no Legal Owner is never in
  scope, so **every** row for it fails with `FACILITY_NOT_IN_ORGANIZATION`
  until its Legal Owner is set.
- **Strict address agreement** (section 4.2) will reject rows whose address is
  formatted differently from Salesforce ("St" vs "Street").
- **Ordering dependency.** Relationships for Providers that are not ingested
  yet fail with `UNKNOWN_PROVIDER`. Re-running the file later is safe: creates
  and terminations that are already done come out UNCHANGED.

## 10. Decisions (review, 2026-10-17)

| # | Decision |
|---|---|
| 1 | The scope is the RIO and all Organizations below it, through `ParentId` (section 5). It is computed once per Run. |
| 2 | Active = `IsActive = true` and blank `TerminationDate`. Provisional. |
| 3 | The termination date is the run date. There is no termination date column and no reason. |
| 4 | Re-creating a relationship inserts a new HPF with `Predecessor_Record__c` set. Provisional. |
| 5 | Without a Facility Unique ID, an NPI matching several facilities is an error. |
| 6 | NPI **and** address disagreement are errors. The address rule is marked REVISIT. |
| 7 | `Name` = "Provider @ Facility" (placeholder comment); `AccountId` / `PractitionerId` are written but commented out. |
| 8 | Providers are global. |
| 9 | One active Run per **roster** (not global) across both file types. |
| 10 | The address is a single line-1 column for now. |
| 11 | Facility NPI = `Account.Group_Type_2_NPI__c`, with a comment about `HealthcareFacility.NPI_Type_2__c`. |
| 12 | The batch/run pipeline is refactored and shared; the de-duplication ledger is local to the relationship service (section 7.2). |
| 13 | Only in-scope facilities are ever changed. A facility outside the scope, or with no Legal Owner, is an error whose message names the facility's Legal Owner Organization (or says it has none) and the roster's Organization. |
| 14 | Once an ID has matched, a blank stored NPI or address is not a mismatch. |

### Later decisions (2026-10-18)

These replace parts of the decisions above (4 and 7) and of sections 4.3 and
6.3. The full list, with what is still open, is in
[relationships-open-questions.md](relationships-open-questions.md).

| # | Decision |
|---|---|
| 15 | `Predecessor_Record__c` is not used. Re-creating a terminated relationship inserts a new one and leaves the old one as it is. |
| 16 | `AccountId` and `PractitionerId` are not set. `Name` stays "Provider @ Facility". `EffectiveFrom` / `EffectiveTo` are not used. The facility NPI is `Account.Group_Type_2_NPI__c`. |
| 17 | The start date is only written when a relationship is created, never filled in or changed on an existing one. A differing date is a warning. |
| 18 | A malformed start date is an error (`INVALID_START_DATE`), not a dropped value. |
| 19 | Several active relationships for one pair: rows still proceed, with a `MULTIPLE_ACTIVE_RELATIONSHIPS` warning. |
| 20 | The Organization scope (decision 1) is confirmed. |
| 21 | Terminate rows ignore the start date (even a malformed one), with a `START_DATE_IGNORED` warning; decision 18 applies to create rows only. |
| 22 | A file start date given for an existing relationship that has none is not applied; `START_DATE_DIFFERS` warning saying no change was made. |
| 23 | HealthcareFacility is assumed to be one-to-one with its facility Account. |
