/**
 * Processes one chunk of a RosterIngestionRun__c; each chunk enqueues the
 * next, so a Run is a chain of these jobs (see RosterIngestionRunService).
 *
 * A ProviderIngestionJobFinalizer is attached first. It runs even when the
 * job dies on an uncatchable LimitException, and retries the chunk with
 * fewer rows. Catchable exceptions are handled here instead: the chunk is
 * rolled back and the Run fails, since retrying would fail the same way.
 */
public with sharing class ProviderIngestionJob implements Queueable {

    private final Id runId;
    private final ProviderIngestionService.DuplicateTracker tracker;

    /**
     * @param runId The RosterIngestionRun__c to continue
     * @param tracker Keys and Providers claimed by the Run's earlier rows
     */
    public ProviderIngestionJob(Id runId, ProviderIngestionService.DuplicateTracker tracker) {
        this.runId = runId;
        this.tracker = tracker;
    }

    /**
     * @param context The Queueable context
     */
    public void execute(QueueableContext context) {
        // The finalizer gets its own copy: the tracker as it was before this chunk.
        System.attachFinalizer(new ProviderIngestionJobFinalizer(runId, tracker.copy()));

        Savepoint beforeChunk = Database.setSavepoint();
        try {
            RosterIngestionRunService.processChunk(runId, tracker);
        } catch (Exception e) {
            Database.rollback(beforeChunk);
            RosterIngestionRunService.failRun(runId, 'Unexpected error: ' + e.getTypeName() + ': ' + e.getMessage());
        }
    }
}
