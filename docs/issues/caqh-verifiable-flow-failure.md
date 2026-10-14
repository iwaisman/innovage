# Provider insert fails when CAQH ID is set (Verifiable flow)

**Status:** open, worked around
**Found:** 2026-10-13, while building the Provider CSV ingestion reference implementation
**Org:** `innovage` sandbox

## Symptom

Inserting a Provider person Account (`RecordType = Provider`) with
`CAQH_ID__pc` populated fails. The record-triggered flow
**"VFY_Account | Auto Create CAQH"** tries to create a record in the Verifiable
managed package, and the package's own trigger throws:

```
We can't save this record because the "VFY_Account | Auto Create CAQH" process failed.
Give your Salesforce admin these details.
CANNOT_EXECUTE_FLOW_TRIGGER: This error occurred when the flow tried to create records:
CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY: verifiable.ExtProvProfileVerifiableTrigger:
execution of AfterInsert

caused by: System.NullPointerException: Attempt to de-reference a null object

(verifiable). You can look up ExceptionCode values in the SOAP API Developer Guide.
Error ID: 1905343236-109954 (1703329780)
```

The same error occurs in:

- the real sandbox context (anonymous Apex, `scripts/apex/ingestProviderRow.apex`,
  which produced the Error ID above), and
- Apex tests (`ProviderIngestionServiceTest.shouldInsertProvider_WhenNoMatch`
  while the row still mapped `CAQH ID`).

Providers inserted **without** `CAQH_ID__pc` save normally.

## Installed Verifiable packages (at time of discovery)

| Package | Namespace | Version |
|---|---|---|
| Verifiable | `verifiable` | 1.111.4.1 |
| Verifiable Extension | `verifiable_ext` | 1.189.0.1 |
| Verifiable Implementation | `verifiable_impl` | 1.9.0.1 |

## Reproduce

Anonymous Apex in the sandbox (rolls back):

```apex
Savepoint sp = Database.setSavepoint();
try {
    insert new Account(
        RecordTypeId = Schema.SObjectType.Account.getRecordTypeInfosByDeveloperName().get('Provider').getRecordTypeId(),
        LastName = 'CaqhRepro',
        CAQH_ID__pc = '12345678'
    );
} finally {
    Database.rollback(sp);
}
```

## Current workaround

`ProviderCsvMapping` does not map the `CAQH ID` CSV header (see the comment in
`MAPPINGS`). CAQH IDs in roster files are therefore not ingested.

To re-enable once fixed, restore this entry in `ProviderCsvMapping.MAPPINGS`.
`ProviderTestDataFactory.createValidRow()` still supplies a CAQH ID, so
`ProviderIngestionServiceTest.shouldInsertProvider_WhenNoMatch` will exercise it again:

```apex
new FieldMapping('CAQH ID', Account.CAQH_ID__pc, ValueType.TEXT, UpdatePolicy.INSERT_ONLY),
```

## Open questions

- Is the Verifiable integration expected to be configured in this sandbox
  (credentials / custom settings)? The NPE may just be missing setup after a
  sandbox refresh.
- Does the same insert fail in production, or only here?
- What does "Auto Create CAQH" create, and is it acceptable for roster
  ingestion to trigger it at all (e.g. for bulk loads)?
- Does it also fire on update when `CAQH_ID__pc` changes from blank? Relevant
  if CAQH ID ever becomes `FILL_IF_BLANK`.
