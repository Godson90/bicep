# ADR-031: Blob vaulted backup of the prod application container

## Context
The prod application account (`st<wus3><suffix>`, `Standard_RAGZRS`, `ADR-020`) already has soft delete, versioning, change feed and point-in-time restore. All of these live **in the account**. They recover from mistakes, but not from a compromise that deletes the account or turns its protection off. The user asked for an offsite copy in addition to the spec's Recovery Services vaults. Azure Backup's **vaulted** backup for blobs copies the chosen containers into a Backup vault on a schedule and keeps them under the vault's own soft delete, immutability and lock (`ADR-030`).

## Decision
- **Where:** prod West US 3 only. `regionStamp.bicep` gates it with `enableBlobVaultedBackup`, default `environmentName == 'prod' && regionRole == 'primary'`. Dev and the East US standby have no Backup vault.
- **Vault:** `Microsoft.DataProtection/backupVaults@2026-06-01`, named `bv-defenstack-prod-wus3`.
  - Identity: system-assigned only. "Backup vaults with User-Assigned Managed Identity (UAMI) aren't compatible with Azure Blob Vaulted backups" ([support matrix](https://learn.microsoft.com/azure/backup/blob-backup-support-matrix)).
  - Storage: `VaultStore`/`GeoRedundant`.
  - Security settings: soft delete `On`, 14 days, and immutability `Unlocked`, until the first drill (`ADR-030`).
  - Cross-region restore: `Disabled`, because blobs are not in the cross-region restore support table ([support matrix](https://learn.microsoft.com/azure/backup/backup-support-matrix#cross-region-restore)).
  - Alerts, diagnostics and lock: Azure Monitor job-failure alerts, the four Backup vault diagnostic tables (resource-specific), and a `CanNotDelete` lock.
- **Policy `blob-daily-vaulted`:** one `AzureBackupRule` at 02:00 UTC daily into `VaultStore`, and one `AzureRetentionRule` keeping 30 days (`P30D`). Azure Backup does not support modifying an existing policy, so a different schedule or retention needs a **new policy name** and an update of the backup instance to point at it.
- **Access:** the vault's identity gets **Storage Account Backup Contributor** (`e5e2a7ff-d759-4cd2-bb51-3152d37e2eb1`) on the account only, under a deterministic `guid(account, vault, role)` name. The pipeline may assign it because the role is in `New-GitHubDeploymentIdentity.ps1`'s delegatable list and ABAC condition (runbook 00b).
- **Backup instance:** named after the account. It protects the containers listed by `regionStamp.bicep`, which is `def-blob` (`storage.outputs.blobContainerName`), and depends on the role assignment.
- **Datasource parameters: `BlobBackupDatasourceParameters`, not `AdlsBlobBackupDatasourceParameters`.**
  - Our Phase 8 research proposed the Data Lake name as a "correction". That correction was wrong. The REST guide's request for vaulted backup with an explicit container list uses `"objectType": "BlobBackupDatasourceParameters"` with `containersList` ([REST: back up blobs](https://learn.microsoft.com/azure/backup/backup-azure-dataprotection-use-rest-api-backup-blobs)). `AdlsBlobBackupDatasourceParameters` is its subtype for Data Lake (hierarchical namespace) accounts, and this account has no hierarchical namespace.
  - Bicep 0.47.16's types list only the subtypes, so that one line carries `#disable-next-line BCP036`, with a comment.
  - **Fallback**, only if ARM rejects the base type live: switch to `AdlsBlobBackupDatasourceParameters` and record it here (runbook 08 §9).
- **Effects on the protected account, checked against this repository.** The REST guide warns that "Once a storage account is configured for blobs backup, a few capabilities are affected, such as change feed and delete lock" ([REST: back up blobs](https://learn.microsoft.com/azure/backup/backup-azure-dataprotection-use-rest-api-backup-blobs)). Per "Effects on backed-up storage accounts" ([configure and manage](https://learn.microsoft.com/azure/backup/blob-backup-configure-manage#effects-on-backed-up-storage-accounts)):
  - **Vaulted backup** creates **object replication** rules on the account. It also turns on **versioning and change feed**, because object replication needs them.
  - **Operational backup** (not used here) would instead turn on point-in-time restore and blob soft delete with policy-driven retention, and apply a **Backup-owned delete lock** to the account.
  - **Stopping protection does not delete the object replication policy**: "If you stop protection (vaulted backup) on a storage account, it doesn't delete the object replication policy created on the storage account. In these scenarios, you need to manually delete the OR policies." Only **removing the backups** deletes it automatically, unless custom locks exist ([support matrix](https://learn.microsoft.com/azure/backup/blob-backup-support-matrix), vaulted backup limitations 9 and 11). Neither turns off point-in-time restore, versioning or change feed.

  **No conflict in this repository:**
  - `storage.bicep` already enables versioning and change feed (14-day retention), so Azure Backup finds them on.
  - `storage.bicep` does not manage object replication policies, so a redeploy leaves Backup's policy alone.
  - No template puts a lock on the storage account or its resource group (the prod locks are on the VNets, Key Vault, firewall, zones, workspace, Front Door and the vaults).
  - Operational backup is not configured, so no Backup-owned delete lock appears.

  The compliant option is therefore the current one: no change to `storage.bicep`.
- **The one real interaction is failover.** A **planned** storage failover is refused while change feed, object replication or point-in-time restore is on ([failover FAQ](https://learn.microsoft.com/azure/storage/common/storage-failover-faq#what-are-the-conflicting-features-or-scenarios-for-failovers)). So failback pauses blob backup, deletes the object replication policy, and turns off point-in-time restore and change feed before the planned failover. The pipeline then restores them, and protection resumes (runbook 08 §5.2).
- **The unplanned failover removes the object replication policy too.** Microsoft's storage docs contradict each other. The object replication overview says "Customer-managed failover isn't supported for either the source or the destination account in an object replication policy" ([object replication](https://learn.microsoft.com/azure/storage/blobs/object-replication-overview)), while the disaster recovery guidance table lists object replication as supported for an unplanned failover ([disaster recovery guidance](https://learn.microsoft.com/azure/storage/common/storage-disaster-recovery-guidance#plan-for-failover)). We take the safe reading. Runbook 08 §4 step 2 suspends the backup instance and deletes the policy before the unplanned failover, which is the sequence the support matrix documents: "pause the backup, remove the object replication policy at the storage account level, complete the failover, and then resume the backup" ([support matrix](https://learn.microsoft.com/azure/backup/blob-backup-support-matrix), limitation 10). Resuming re-creates the policy and "triggers a full backup" (limitation 16), so the first backup after failback is a full re-replication.
- **Pre-production validation (owner, not yet run).** Runbook 08 §2 asks the owner to test an unplanned failover of a scratch GPv2 GRS account with an object replication policy, in a sandbox subscription, never in prod. Record the result here:

  | Date | Account SKU | OR policy present | Failover accepted? | Error text (if refused) | Recorded by |
  |---|---|---|---|---|---|
  | | | | | | |
- **Pipeline identity reach.** Storage Account Backup Contributor is in the pipeline identity's delegatable list (runbook 00b). The ABAC condition limits role IDs, not principals, so the pipeline identity can assign this role within its resource groups, **including to itself**. Beyond Contributor, which the identity already has, the role adds only lock management (`Microsoft.Authorization/locks/write` and `delete`, [built-in roles](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/storage#storage-account-backup-contributor)). The prod identity already holds lock management (`-GrantLockManagement`, runbook 00b §8), so the net new reach is the **dev** identity's: it could lift locks in its own resource groups. Accepted, because dev has no locks to protect and the identity is already Contributor there.
  - **Optional tightening, not applied:** add an ABAC clause that refuses assignments to the pipeline's own principal, for example `@Request[Microsoft.Authorization/roleAssignments:PrincipalId] StringNotEquals '<pipeline object ID>'`, in `New-GitHubDeploymentIdentity.ps1`'s condition. No code changes in Phase 8.

## Consequences
- **Limits:**
  - Restores go to a **different** storage account only, which must not already hold a container with the same name.
  - There is no cross-region restore: during a West US 3 outage the vaulted copies are not restorable until the region returns. RA-GZRS read access and the storage failover (runbook 08) cover that case instead.
  - The recovery point is at most one day old (one backup a day).
  - At most 1000 containers can be protected.
- **Costs:** protected-instance and vault-storage charges, plus object replication traffic on the source (`docs/cost.md` "Phase 8 delta").
- **Change feed and object replication add append blobs** to the account. That makes it ineligible for the Geo priority replication SLA ([Geo priority replication](https://learn.microsoft.com/azure/storage/common/storage-redundancy-priority-replication#sla-eligibility-and-exclusions)), so the 15-minute storage RPO stays an expectation, not an SLA (runbook 08 §1).
- **Live-only risks**, with fallbacks in runbook 08 §9:
  - backup with `publicNetworkAccess: 'Disabled'`;
  - a role-propagation race on the first deploy;
  - idempotent re-PUTs of the policy (fallback: deploy once, then reference the policy as `existing`);
  - a vaulted-only policy with no operational rule (fallback: the documented combined operational and vaulted policy);
  - object replication and the unplanned failover (the owner's sandbox test above);
  - the change-feed retention that `storage.bicep` re-asserts.

## Revisit when
Azure adds cross-region restore for blobs, when the containers or the retention change (new policy name), or if ARM rejects the base datasource type.
