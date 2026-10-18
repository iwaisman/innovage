/**
 * The row processing for one roster file type. RosterIngestionBatch handles
 * everything else (the file, slices, Run status, Issues and counts) the same
 * way for every type.
 *
 * Implementations hold no state: one instance serves the whole Run.
 */
public interface RosterRowProcessor {

    /**
     * @return The columns the file must have; a file without them fails the Run
     */
    List<String> requiredHeaders();

    /**
     * Called once per Run, before any row is processed, to add what this file
     * type needs to the context.
     *
     * @param context The Run's context; roster, Organization and run date are set
     * @throws RosterIngestionRunService.RunException to fail the Run
     */
    void prepare(RosterIngestionRow.Context context);

    /**
     * @param rows One slice of rows, in file order
     * @param context The Run's context, as prepared
     * @return One result per row, in the same order
     */
    List<RosterIngestionRow.Result> ingestAll(List<RosterIngestionRow.Input> rows, RosterIngestionRow.Context context);
}
