# Decision: chained or parallel chunk processing

Status: **keep serial processing**, decided 2026-10-15. Revisit when the
triggers in section 5 are met.

> **Update 2026-10-15:** processing now uses Batch Apex
> (`ProviderIngestionBatch`), not a Queueable chain, with a 5,000-row limit.
> Batch slices also run one after another, so the question is unchanged.
> Arguments 3–7 still apply. Argument 1 no longer does: `start()` parses the
> whole file, so slice boundaries are known up front. Argument 2 now reads:
> Batch Apex has no built-in parallelism, so parallel processing would mean
> leaving Batch Apex for a custom fan-out. The plan in section 4 was written
> for the Queueable chain and would need reworking.

Related: [provider-bulk-ingestion.md](provider-bulk-ingestion.md), which
describes the current design.

## 1. Context

A Provider roster file is ingested as one `RosterIngestionRun__c`, processed in
chunks of rows (500 by default). Today each chunk is a `ProviderIngestionJob`
(a Queueable). When a chunk finishes, it enqueues the job for the next chunk,
so chunks run one after another.

The chain originally also carried a duplicate tracker, so that a Provider
appearing on several rows was ingested only once. On 2026-10-15 the
stakeholder decided that duplicate rows are acceptable. The tracker was
removed (see rule 1 in section 7 of the bulk ingestion plan). The only state
now passed between chunks is the character offset where the next chunk
starts.

That raised the question of whether chunks could instead be queued
independently and run in parallel.

## 2. Arguments for parallel processing

- **Shorter wall-clock time.** A 5 MB file is about 14,000 rows, or roughly 30
  chunks of 500. Serially, that is about 30 × (≈9 s of processing + queue
  delay), so several minutes. With *K* chunks running at a time, it could
  approach 1/*K* of that.
- **No cross-chunk state is needed** now that duplicates are allowed. Any chunk
  can be processed once its row range is known.
- **Failures are isolated.** A chunk that keeps failing does not hold up the
  chunks after it.
- **Headroom for larger rosters.** Run time would not grow linearly with file
  size. The file-size ceiling would not change, though: every job still holds
  the whole file in its 12 MB heap.

## 3. Arguments against

1. **Chunk boundaries must be known up front.** A quoted field can contain line
   breaks, so a row cannot be found by counting lines. Today, parsing chunk N
   reveals where chunk N+1 starts. Independent chunks need a separate pass over
   the whole file before any chunk is queued.
   - That pass cannot run when the user clicks the button. The synchronous
     heap is 6 MB, and a 5 MB file is held twice while loading (once as the
     file data, once as text).
   - So it needs its own async job.
2. **Starting jobs in parallel is awkward.** An async job may enqueue only one
   Queueable. The workarounds add moving parts:
   - A Batch job whose only purpose is to enqueue one worker per chunk.
   - Platform events, one per chunk. An event trigger processes events one
     batch after another unless *parallel subscriptions* are configured, and
     those allow at most 10 partitions. A trigger that dies on a governor limit
     loses its events: there is no Finalizer to retry. Triggers also run as the
     Automated Process user by default.
3. **The shared Run record becomes a contention point.** Each chunk would
   update the Run's counters. Each Issue insert also locks the Run, because it
   is the Issue's master record. We would also need something to detect that
   the last chunk has finished. The chain gets all of this for free.
4. **Lock contention in Account automation.** This is the biggest unknown.
   Inserting a Provider runs the org's flows and the Verifiable package, which
   create related records. Parallel chunks that touch the same parent records
   (the same Organization account, shared owners, sharing recalculation) can
   fail with `UNABLE_TO_LOCK_ROW`. Such failures may be intermittent. Only a
   load test can show whether this happens.
5. **Outcomes depend on timing.** Duplicate rows in chunks that run at the same
   time would both try to insert, and one would fail on the unique NPI. Updates
   to the same Provider from concurrent chunks would race, so the last write
   wins. In serial runs, the documented behavior holds: the first row inserts
   and later rows update.
6. **Parallelism is not guaranteed.** Salesforce runs queued jobs according to
   its own capacity, so the speed-up in practice may be smaller than *K*.
7. **More code to test.** Fan-out cannot be exercised in Apex tests (chained
   jobs do not run in tests), and concurrency bugs are hard to reproduce.
   Cancelling a run, retrying a failed chunk and reporting progress all become
   more involved.
8. **Performance is not a problem today.** The 1,200-row dry run took 27 s.
   There is also a cheaper lever: raising the chunk size from 500 to
   1,500–2,000 rows. A 500-row chunk uses about 9 s of the 60 s CPU limit, so
   this cuts the number of job hand-offs by a factor of 3–4. The existing
   Finalizer already halves any chunk that hits a limit.

## 4. Plan, if we switch

This design keeps the Queueable + Finalizer retry and bounds concurrency to
*K* parallel workers. Bounding concurrency also limits lock contention.

**Data model**

- **New `RosterIngestionChunk__c`**, a Master-Detail child of the Run.

  | Field | Purpose |
  |---|---|
  | Sequence | Position of the chunk in the file |
  | Start Offset, End Offset | Character range of the chunk in the file |
  | First Row Number | Spreadsheet row number of the chunk's first row |
  | Next Offset | Resume point within the chunk |
  | Status | Pending, Running, Done or Failed |
  | Max Rows Per Transaction | Halved by the Finalizer when a transaction hits a limit |
  | Inserted, Updated, Unchanged, Errored, Rows With Warnings | Counters |
  | Attempts | How many times the chunk has been tried |
  | Last Job Id | The most recent job that processed the chunk |
  | Failure Message | Why the chunk failed |
- **Issues move to the Chunk** as their Master-Detail parent. Inserting Issues
  then locks only that chunk's record, not the shared Run. A Run's issues are
  still shown together by querying through the chunks.
- **Run totals are calculated, not stored per chunk.** They are aggregated over
  the chunk records when the run completes, and on demand for progress.
  Roll-up summary fields are not used, because recalculating them would lock
  the Run again.

**Processing**

1. **Planner job** (one Queueable):
   - Loads the pinned file version.
   - Checks the encoding and the required headers.
   - Scans for record boundaries every *N* rows. A line break ends a record
     only if an even number of quote characters comes before it. The scan uses
     native `indexOf` rather than character-by-character parsing.
   - Inserts one Pending chunk record per range.
   - Measure the cost of this scan on a 5 MB file before relying on it.
2. **Dispatcher** (a Batch job over the Run's chunk records, scope 1):
   - Each `execute()` enqueues one worker. A Batch `execute()` may enqueue one
     Queueable.
   - The dispatcher starts only *K* workers, with *K* configurable and starting
     at 2–4. It does not start one worker per chunk.
3. **Worker** (Queueable + Finalizer), a loop:
   1. Claim the next Pending chunk with `SELECT … FOR UPDATE` and mark it
      Running.
   2. Process its rows, resuming from its Next Offset, as today's
      `processChunk` does within one chunk.
   3. Write Issues and counters to the chunk, and mark it Done.
   4. Enqueue itself again to claim the next chunk.

   *K* workers therefore form *K* chains working through one shared queue of
   chunks.
4. **Finalizer**: on a limit failure it halves the chunk's Max Rows Per
   Transaction and re-enqueues the worker. This is today's behavior, applied
   per chunk. Below the minimum it marks the chunk Failed. The other chunks and
   the run continue.
5. **Completion**: a worker that finds no Pending chunk locks the Run briefly.
   If no chunk is still Running, it aggregates the chunk counters into the Run
   and sets the final status. The status is Completed with Errors if any chunk
   failed or any row errored.
6. **Cancel**: set the Run to Cancelled. Workers check the Run's status before
   claiming a chunk, and stop.
7. **UI**: progress is shown as Done chunks out of total chunks. Issues are
   listed across the Run's chunks.

**Rollout**

1. Build the planner and measure the boundary scan on a 5 MB file.
2. Run a load test in a sandbox with realistic Account automation, at *K* = 1,
   2, 4 and 8. Record wall-clock time and any `UNABLE_TO_LOCK_ROW` errors. If
   lock errors appear at the *K* that would be worth it, stop here and stay
   serial.
3. Test the worker, planner and completion logic synchronously. The test
   infrastructure supports that, and fan-out cannot run in tests anyway.
4. Make *K* configurable (*K* = 1 is effectively today's behavior). Roll out
   with a low *K*.

## 5. When to revisit

Reconsider parallel processing if any of these holds:

- Typical files approach the 5 MB ceiling and run times become a complaint.
- The stakeholder sets a turnaround time that serial processing cannot meet,
  even after raising the chunk size.
- A load test shows that Account automation does not contend for locks at a
  useful *K*.
