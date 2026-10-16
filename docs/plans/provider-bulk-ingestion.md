# Plan: bulk Provider ingestion

Status: implemented, then **revised on 2026-10-15 to use Batch Apex** (see
section 11). Sections 1–9 describe the original Queueable-chain design and are
kept as history. For the current design, see
[docs/architecture/provider-bulk-ingestion.md](../architecture/provider-bulk-ingestion.md).

## 1. Summary

- **Processing:** a chain of Queueable jobs, not Batch Apex. Each job reads the
  next chunk of rows from the file, processes them with one query and at most
  two DML calls, saves its results, and enqueues the next job.
- **Persistence:** one `RosterIngestionRun__c` per processing of a file version,
  with one `RosterIngestionIssue__c` child per error or warning.
- **Code:** the row logic is bulk-first. The single-row service is a thin
  wrapper over it, so there is one implementation of the match and update
  rules. Only the orchestration is new.
- **Dry run:** the same pipeline, with each chunk's Provider DML rolled back
  (section 6).

## 2. Background: governor limits, Queueable and Batch

Limits apply **per transaction**: one synchronous request, or one execution of
an async job. Any DML or SOQL run by Account triggers and flows (including the
Verifiable package) during our DML counts against **our** transaction.

| Limit | Sync | Async | Relevance |
|---|---|---|---|
| CPU time | 10 s | 60 s | Parsing, mapping and Account automation. The most likely limit to hit. |
| Heap | 6 MB | 12 MB | The file content is loaded into memory |
| SOQL queries | 100 | 200 | The reference implementation runs 1 per row |
| DML statements / rows | 150 / 10,000 | same | The reference implementation runs 1 statement per row |
| Query rows | 50,000 | same | Matching candidates |

`System.LimitException` **cannot be caught**. The transaction dies and all of
its work is rolled back.

**Queueable.** A class implementing `Queueable`. `System.enqueueJob(new
Job(state))` serializes the object and later runs `execute()` as a new
transaction with async limits. A running Queueable may enqueue **one** child,
which forms a chain, and passes its state through the child's constructor. A
**Transaction Finalizer** (`System.attachFinalizer`) runs after the job, *even
if the job died from a LimitException*. It can record the failure and enqueue
a retry.

**Batch Apex.** `start()` returns the whole input, normally a QueryLocator over
up to 50M records. The platform then calls `execute()` with chunks of up to
2,000 records, each in its own transaction and one after another, and calls
`finish()` at the end. It suits input that is already records. Our input is a
**file**, so `start()` would have to parse the entire CSV in one transaction.

**Rejected alternatives**

- *Stage rows into a table, then run Batch over it.* Filling the table still
  needs chunked parsing. It also copies SSN and DOB into another table and costs
  about 2 KB of storage per row.
- *Parse in the browser (LWC).* The run dies if the tab closes.

## 3. Runs, chunks and jobs

**One user action creates one `RosterIngestionRun__c`.** Chunks are async
jobs, not records. Every job in the chain updates the **same** Run, writing its
counters, cursor and status, and parents its Issues to that Run.

A Run is pinned to one ContentVersion. A new run against the same or a newer
version creates a new Run, so a RosterIngestion's Runs form its history:
"version 3, dry run", then "version 3, real", then "version 4, real".

## 4. Flow

```
[Action on RosterIngestion] → RosterIngestionRunService.startRun(rosterIngestionId, dryRun)
   sync: lock the RosterIngestion row (FOR UPDATE); refuse if a Run is Queued/Running;
         pin the current ContentVersion; insert the Run (Status=Queued); enqueue job #1

[ProviderIngestionJob]  (Queueable + Finalizer), once per chunk
   1. Load the pinned ContentVersion.VersionData → String
   2. First chunk only: parse the header, check required headers
   3. Parse up to chunkSize records from the saved character offset → rows + nextOffset
   4. ProviderIngestionService.ingestAll(rows): map, bulk match (one query),
      partial-success DML
      (dry run: DML wrapped in a savepoint and rolled back)
   5. Insert Issues; update the Run's counters and cursor  ← same transaction as step 4
   6. Rows left? enqueue the next job : set Status = Completed / Completed with Errors

Finalizer: if the job died, nothing from that chunk was committed. Halve the
chunk size and re-enqueue from the same offset (floor of 10 rows); otherwise
set Status = Failed with the reason.
```

How this design behaves:

- **Each chunk is atomic.** Provider changes, Issues, counters and the cursor
  commit together.
- **Results do not depend on chunk size.** Only one chunk runs at a time, so the
  Run record is never written by two jobs at once.
- **Each Run is pinned to a file version.** Jobs read the stored ContentVersion
  Id, not the latest version, so a new upload during a Run has no effect on it.
- **Re-running is safe.** Re-ingesting a file produces mostly UNCHANGED rows.

## 5. Data model

Both relationships are Master-Detail. Deleting a RosterIngestion deletes its
Runs and Issues. These are temporary processing artifacts, kept for weeks.

### `RosterIngestionRun__c` (Master-Detail → `RosterIngestion__c`)

| Field | Purpose |
|---|---|
| File_Type__c (Personnel; Relationships later) | One object for both files |
| Dry_Run__c | Section 6 |
| Content_Document_Id__c, Content_Version_Id__c, Version_Number__c, File_Checksum__c | The pinned version (custom lookups to Content objects are not allowed) |
| Status__c | Queued → Running → Completed / Completed with Errors / Failed |
| Started_At__c, Completed_At__c | |
| Rows_Processed__c, Inserted__c, Updated__c, Unchanged__c, Errored__c, Rows_With_Warnings__c | Updated at each chunk commit. In a dry run these mean "would insert", "would update" and so on. |
| Next_Offset__c, Next_Row_Number__c, Chunk_Size__c, Chunk_Count__c | Resume cursor and chunking state |
| Failure_Message__c | Run-level fatal error |
| Last_Job_Id__c | AsyncApexJob Id |

### `RosterIngestionIssue__c` (Master-Detail → `RosterIngestionRun__c`)

One record per issue, not per row.

| Field | Purpose |
|---|---|
| Row_Number__c | Spreadsheet row number, with the header as row 1 |
| Severity__c | Error / Warning |
| Code__c | Match outcomes, INVALID_VALUE, MISSING_LAST_NAME, SAVE_ERROR, COLUMN_COUNT |
| Column__c | CSV header (for warnings) |
| Message__c | **Never contains values.** This keeps the existing rule that SSN and DOB never appear in messages. |
| Provider__c | Lookup to Account, when known |
| Unique_ID__c, NPI__c | The row's key values, for search |

## 6. Dry run

A dry run uses the same Run and Issue records, with `Dry_Run__c = true`. The
chunk performs its real DML inside a savepoint, collects the results, and rolls
back. The Issues and the Run update are written after the rollback, so they
commit and the Provider changes do not. This catches everything a real run
would, including validation rules, `DUPLICATE_VALUE`, and Account flow
failures.

Caveats, for the team to review (also documented in the code):

- **Auto-numbers are consumed.** Rolled-back inserts still advance `Unique__c`,
  so dry runs leave gaps in Provider Unique IDs.
- **Some side effects are not rolled back.** Platform events published with
  "Publish Immediately" survive the rollback. Emails and enqueued jobs are
  discarded.
- **A dry run costs as much as a real run** in CPU and time.
- **Later chunks do not see earlier chunks' inserts.** A row for a Provider
  that an earlier chunk would insert is reported as another insert, where a
  real run would update it (see rule 1 in section 7).

**Promote:** "Run for real" on a dry run creates a new Run pinned to the same
ContentVersion.

## 7. Behavior rules

1. **Duplicate rows are not detected.** The stakeholder decided (2026-10-15)
   that several rows for the same Provider are acceptable, so rows are not
   checked against each other and no state is carried between chunks. The
   outcome depends on whether the rows land in the same chunk:
   - **Different chunks:** each row is matched against the database as it is
     then, so the first row inserts the Provider and later rows update it (or
     find it unchanged).
   - **Same chunk, new Provider:** all such rows are planned as inserts; the
     database rejects all but the first for the duplicate NPI (SAVE_ERROR).
   - **Same chunk, existing Provider:** the rows' changes are merged into one
     update (Salesforce rejects a DML list holding the same Id twice, which
     would otherwise fail the whole chunk). Each row reports its own changes
     against the stored Provider; where several rows change the same field,
     the last row's value is saved.

   Chunks still run one after another, not in parallel: a chunk's start is
   only known once the previous chunk is parsed, an async job can enqueue only
   one job, and parallel chunks would contend for locks on the Run and on
   records touched by Account automation.
   The full arguments, and the plan if we ever switch, are in
   [parallel-chunk-processing.md](parallel-chunk-processing.md).
2. **Row numbers** are spreadsheet rows, with the header as row 1.
3. **Missing required headers** (Provider Unique ID, Individual NPI, Last Name)
   fail the Run up front. Unknown headers are ignored, including "Roster Line
   Type".
4. **One active Run per RosterIngestion**, enforced with `FOR UPDATE`.
5. **File size ceiling:** about 5 MB, accepted for now.
6. **Encoding:** UTF-8 only. Anything else fails the Run with a clear message.

## 8. Removals

`RosterIngestion__c.Personnel_File_Structure_Errors__c` and
`Relationships_File_Structure_Errors__c` are defunct. They exist only in the
org and are removed with a destructive deploy.

## 9. Risks

1. **Parser CPU:** measured in the spike, and bounded per job by chunking.
2. **Account automation cost:** sets the real chunk size; the finalizer adapts it.
3. **Index on `Unique__c`:** not indexed (see section 10). Cheap at today's
   volumes; mark it External ID if Provider counts grow large.

## 10. Implementation notes (2026-10-14)

**Spike measurements (innovage sandbox):**

| Step | Cost |
|---|---|
| Load a 1.7 MB file | 10 ms CPU; heap is about 1 byte per character |
| Parse + map | about 3.2 ms per row |
| Insert 200 Providers | 1.2 s CPU (automation added 2 DML statements, 400 related rows and about 9 managed-package queries) |
| Update 200 Providers | 1.7 s CPU |

Based on these, the default chunk size is 500 rows.

**Query plan:** the bulk match query uses the RecordTypeId index. `Unique__c`
is not indexed.

**End-to-end dry run:** 1,200 generated rows ran in 3 chunks and took 27 s.
The run reported 1,177 would-be inserts and 23 MALFORMED_NPI errors (exactly
the injected bad NPIs). It also reported 27 value warnings. No Providers were
persisted.

**Access:** classes at API 67.0 run SOQL in user mode by default, so users need
the `Roster_Ingestion_Files` permission set to see Runs and Issues. That
permission set now also grants Read/Edit on RosterIngestion__c.

**UI:**
- The `rosterIngestionRuns` LWC must be added to the RosterIngestion record
  page in Lightning App Builder (the page is not in the repo).
- Run records show their Issues in a related list, sorted by row.

**Test data:** `scripts/generate_roster_csv.py` leaves Provider Unique ID
blank, so its rows are new Providers. Use `--existing-ids` with exported
Provider keys to generate update rows. The 2026-10-14 runs predate this fix,
when the generator wrote invalid `PRV-000001` IDs.

**Removed:** the defunct `*_File_Structure_Errors__c` fields were deleted with a
destructive deploy. They can be recovered from Deleted Fields for 15 days.

## 11. Revision: Batch Apex (2026-10-15)

The Queueable chain was replaced with Batch Apex (`ProviderIngestionBatch`).

**Why.** The code is maintained by engineers for whom simplicity matters more
than file-size headroom. The stakeholder accepts a limit of **5,000 rows per
file**, which is expected to be reached rarely, if ever. At that size the whole
file can be parsed in one transaction: about 1.7 MB of text and an estimated
5 MB of heap. Batch Apex then provides the chunking, the sequencing and the
completion that the chain implemented by hand. Batch Apex is also a pattern
most Salesforce engineers already know.

**What changed**

- **Removed:**
  - `ProviderIngestionJob` and `ProviderIngestionJobFinalizer`.
  - The resumable `CsvParser.parseChunk`.
  - The Run's cursor fields (Next Offset, Next Row Number, Chunk Size, Chunk
    Count).
- **Added:**
  - `ProviderIngestionBatch`: `start()` parses the whole file; `execute()`
    ingests 200 rows at a time; `finish()` sets the status.
  - The Run's Total Rows field.
  - `RosterIngestionRunService.failAbandonedRuns()`, which fails a Run whose
    batch job ended without finishing it, so the Run cannot block new runs.
- **Given up:** the automatic retry of a chunk that hit a governor limit. A
  failed slice is now reported as missing rows (Completed with Errors), and
  re-running the file is safe.
- **Limits:** 5,000 rows, plus a 3 MB file-size guard checked before the job
  starts.

**Measured** with a 5,000-row dry run in the `innovage` sandbox:

- 3½ minutes in total, in 25 slices.
- `start()` took 9.7 s from start to finish.
- Each slice used 0.5–0.6 s of CPU.

## 12. Revision: dry run removed (2026-10-16)

The dry-run option was removed from the code and the UI. It was useful in
principle, but for this project it added a choice the user has to think about
without serving their purpose. The goal is the simplest possible feature for
end users and for maintainers.

**Removed:**

- The *Dry Run* and *Ingest This Version* buttons, the "Dry run" badge, and
  the "would be inserted / updated" wording in the `rosterIngestionRuns`
  component.
- `RosterIngestionRunService.promote` and the controller's `promote`.
- The `dryRun` parameter of `startRun`, `ProviderIngestionBatch` and
  `ProviderIngestionService.ingestAll`, along with the savepoint and rollback
  in `ingestAll`.
- The `Dry_Run__c` field on the Run.
- The three dry-run Runs in the `innovage` sandbox, which were all test runs
  (their Issues were deleted with them).

The *Ingest* button still asks for confirmation before starting, since a run
creates and updates Providers.

Sections 1–11 above still describe the dry run (section 6, and section 11's
measurements); those are history.

