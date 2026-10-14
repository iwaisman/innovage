// Runs ProviderIngestionService over the rows of the inline CSV below and prints one result per row.
//
// Run from VS Code ("SFDX: Execute Anonymous Apex with Editor Contents"), or:
//     sf apex run --file scripts/apex/ingestProviderRow.apex -o innovage | grep USER_DEBUG
//
// With DRY_RUN = true everything is rolled back at the end, so the same rows can be
// re-run; the accountId of an INSERTED row then refers to a record that no longer exists.
// Rows are processed in order, so with DRY_RUN = true a later row DOES see an earlier
// row's insert (e.g. ingesting the same NPI twice gives INSERTED, then UNCHANGED).

Boolean DRY_RUN = true;

String csv = String.join(new List<String>{
    'Provider Unique ID,Individual NPI,Salutation,First Name,Middle Name,Last Name,"Suffix (MD, DO, NP, RN etc)",Date of Birth,Social Security Number,Provider Phone,Provider Fax,Provider Email,Provider Mailing Address Line 1,Provider Mailing Address Line 2,Provider Mailing City,Provider Mailing State,Provider Mailing Zip,Provider Billing Address Line 1,Provider Billing Address Line 2,Provider Billing City,Provider Billing State,Provider Billing Zip,CAQH ID,Medicare ID,Medicaid ID State',
    // New provider -> INSERTED
    ',1234567893,Dr.,Jane,Q,Example,MD,04/17/1980,912-34-5678,(303) 555-0101,,jane.example@example.com,100 Main St,Suite 200,Denver,CO,80202,100 Main St,,Denver,CO,80202,12345678,CO1234567,CO',
    // Same NPI, new phone and email -> UPDATED (Phone, PersonEmail)
    ',1234567893,Dr.,Jane,Q,Example,MD,04/17/1980,912-34-5678,(303) 555-0199,,jane.q.example@example.com,,,,,,,,,,,,,',
    // Same NPI, same values, blank email -> UNCHANGED (blank values never overwrite)
    ',1234567893,,,,,,,,303.555.0199,,,,,,,,,,,,,,,',
    // Bad email -> warning; the remaining values are still applied
    ',1234567893,,,,,,,,,,not-an-email,,,,,,,,,,,,,',
    // Neither key -> NO_KEY_VALUES
    ',,,Nobody,,Keyless,,,,,,,,,,,,,,,,,,,',
    // Bad check digit -> MALFORMED_NPI
    ',1234567890,,Bad,,Npi,,,,,,,,,,,,,,,,,,,',
    // Wrong prefix -> MALFORMED_UNIQUE_ID
    'PG000000001abc,,,,,,,,,,,,,,,,,,,,,,,,',
    // Well-formed but unknown -> UNKNOWN_UNIQUE_ID
    'P999999999zzz,,,,,,,,,,,,,,,,,,,,,,,,'
}, '\n');

Savepoint savepoint = DRY_RUN ? Database.setSavepoint() : null;

try {
    CsvParser.ParsedWithHeaders parsed = CsvParser.parseWithHeaders(csv);
    for (Integer i = 0; i < parsed.rows.size(); i++) {
        ProviderIngestionService.IngestResult result = ProviderIngestionService.ingest(parsed.rows[i]);
        System.debug(LoggingLevel.ERROR, 'Row ' + (i + 1) + ': ' + JSON.serializePretty(result));
    }
} finally {
    if (DRY_RUN) {
        Database.rollback(savepoint);
        System.debug(LoggingLevel.ERROR, 'DRY_RUN: all changes rolled back.');
    }
}
