/**
 * Runs after every ProviderIngestionJob. When the job died (typically on a
 * governor limit, which cannot be caught), the chunk's work was rolled back;
 * RosterIngestionRunService.handleChunkFailure retries it with fewer rows or
 * fails the Run.
 */
public with sharing class ProviderIngestionJobFinalizer implements Finalizer {

    private final Id runId;
    private final ProviderIngestionService.DuplicateTracker tracker;

    /**
     * @param runId The RosterIngestionRun__c the job processed
     * @param tracker The tracker as it was before the job's chunk
     */
    public ProviderIngestionJobFinalizer(Id runId, ProviderIngestionService.DuplicateTracker tracker) {
        this.runId = runId;
        this.tracker = tracker;
    }

    /**
     * @param context The finalizer context of the completed job
     */
    public void execute(FinalizerContext context) {
        if (context.getResult() == ParentJobResult.SUCCESS) {
            return;
        }
        Exception failure = context.getException();
        handleFailure(failure == null ? 'unknown error' : failure.getTypeName() + ': ' + failure.getMessage());
    }

    @TestVisible
    private void handleFailure(String failure) {
        RosterIngestionRunService.handleChunkFailure(runId, tracker, failure);
    }
}
