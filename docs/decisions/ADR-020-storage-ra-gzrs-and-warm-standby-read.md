# ADR-020: Prod primary storage is RA-GZRS; the warm standby reads it through the secondary endpoint

## Context
The spec (§3) asks for prod storage on **RA-GZRS**, geo-copied to East US, consumed by the DR stamp "through a private endpoint on the secondary endpoint (`blob-secondary` group ID)". Until Phase 5, every prod account was `Standard_GRS`, and PSRule's `Azure.Storage.UseReplication` rule was excluded globally until "Phase 5: storage moves to RA-GZRS". Each region also has its own account for its own state.

## Decision
- **SKU per stamp** (`modules/regionStamp.bicep`):
  - prod primary: `Standard_RAGZRS` (zone-redundant in West US 3, read access to the East US copy);
  - prod warm standby: `Standard_GRS` (its own state, geo-copied to its pair);
  - dev: `Standard_LRS` (`ADR-008`).
- **Read path:** the East US stamp creates a private endpoint on the primary account's `blob_secondary` sub-resource (`modules/storageSecondaryEndpoint.bicep`), registered in the shared `privatelink.blob` zone as `<account>-secondary`. It exists only when `main.bicep` passes the primary account to the secondary stamp, which happens only with `deploySecondaryRegion`.
- **Least privilege:** the East US App Service identity gets **Storage Blob Data Reader**, never a write role, on the primary `def-blob` container (`modules/storageReaderAssignment.bicep`, deployed into the primary resource group). The pipeline identity may now delegate that role (runbook 00b).
- **PSRule:** the global `Azure.Storage.UseReplication` exclusion is removed. The rule is suppressed only for `Standard_LRS` accounts (`DefenStack.DevLocallyRedundantStorage`, matched on `sku.name`, because storage names are hashed).
- Data protection from Phase 0 (F7) stays on every account: versioning, soft delete, change feed and point-in-time restore.

## Consequences
- In a West US 3 outage, the warm standby can read the primary's data up to the last geo-sync (typically under 15 minutes old) without any failover. Writes during the outage go to the East US account until a customer-managed account failover, which Phase 8 covers.
- The RA-GZRS premium and geo-replication transfer apply to the prod primary account only (`docs/cost.md` "Phase 5 delta").
- A PSRule failure on any future non-LRS account without replication is no longer hidden by a global exclusion.
- Combining RA-GZRS with point-in-time restore and change feed is first exercised by the prod deployment. If Azure rejects the combination, runbook 05 §9 says what to change and requires this ADR to be updated.

## Revisit when
Phase 8 designs account failover, or the application needs writable storage in East US during normal operation.
