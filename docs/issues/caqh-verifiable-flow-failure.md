# Provider insert fails when CAQH ID is set (Verifiable flow)

**Status:** resolved in `innovage` on 2026-10-20 by deactivating the flow; see [Resolution](#resolution)
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

## Resolution

On 2026-10-20, as directed, the flow **"VFY_Account | Auto Create CAQH"**
(`VFY_Account_Auto_Create_CAQH`, record-triggered on Account) was deactivated by
hand in the `innovage` sandbox (its active version was 1 of 3). It is not part of
a managed package. It used to create a `verifiable__External_Provider_Profile__c`
whenever an Account was created or updated with a CAQH ID, username or password;
that no longer happens automatically for anyone.

The `CAQH ID` mapping was restored in `ProviderCsvMapping` (INSERT_ONLY). The
reproduction above now saves, and no External Provider Profile is created.
`ProviderIngestionServiceTest.shouldInsertProvider_WhenNoMatch` checks the CAQH
ID is stored.

**Production:** the flow must be deactivated there too before this mapping is
released, or Provider inserts with a CAQH ID will fail as they did here.

## Follow-up: duplicate CAQH IDs

Found while re-enabling the mapping (2026-10-20). The org's flow **"Sync
Individual Provider to Healthcare Provider"** copies `CAQH_ID__pc` to the
Provider's `HealthcareProvider.CaqhIdentifier`, which is a **unique** field. The
flow runs on Account **update** only, so:

1. Two Providers created with the same CAQH ID both save.
2. The first one's next update copies the ID to its HealthcareProvider.
3. Every later update of the second one fails with `DUPLICATE_VALUE ...
   CaqhIdentifier` from that flow: ingestion updates (e.g. a new phone) and
   manual edits alike.

**Decision (2026-10-20): accept the risk.** CAQH IDs in real roster files are
expected to be unique, so ingestion does not check them for duplicates. The
risk is documented where people will look when it happens: the
`ProviderCsvMapping` comment, the architecture doc (section 6, "Known risk",
and the failure table), and both personnel specs in `docs/specs/`.

Its symptom is easy to misread. A later roster row that only changes, say, the
second Provider's phone fails with a SAVE_ERROR naming the "Sync Individual
Provider to Healthcare Provider" flow and `DUPLICATE_VALUE … CaqhIdentifier`,
pointing at the *other* Provider's HealthcareProvider. Fix it by correcting or
clearing the CAQH ID on one of the two Providers.

Options considered and not taken: drop the duplicate CAQH ID with a warning
(one extra query per slice), or reject the row.
