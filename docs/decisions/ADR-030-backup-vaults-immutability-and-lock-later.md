# ADR-030: Backup vaults start reversible: immutability unlocked, soft delete not always-on, locked after the first drill

## Context
Phase 8 adds a Recovery Services vault to every region stamp (`rsv-defenstack-<env>-<region>`) and, in prod West US 3, a Backup vault for blob vaulted backup (`bv-defenstack-prod-wus3`, `ADR-031`). The spec (§3 "Data and application resilience") asks for a Recovery Services vault per region. Azure Backup's strongest posture makes a vault's immutability **Locked** and its soft delete **always-on**. Both changes are irreversible: "Once you enable the always-on state for soft delete, it can't be disabled for that vault" ([enhanced soft delete](https://learn.microsoft.com/azure/backup/backup-azure-enhanced-soft-delete-about)), and "Immutability locking is irreversible" ([immutable vault](https://learn.microsoft.com/azure/backup/backup-azure-immutable-vault-concept#making-immutability-irreversible)). Locking a vault before the backup design is proven would freeze any mistake in a policy's retention or a protected item, because a locked vault refuses every operation that could shorten retention or delete recovery points.

PSRule for Azure's `Azure.RSV.ReplicationAlert` expects each Recovery Services vault to have a `vaults/replicationAlertSettings` child, which configures the classic Site Recovery email to the subscription owners.

## Decision
- **Every vault starts reversible.**
  - Recovery Services vaults: `softDeleteSettings.softDeleteState: 'Enabled'`, 14 days, `enhancedSecurityState: 'Enabled'`, and `immutabilitySettings.state: 'Unlocked'` with no `configuration` (immutability follows each policy's retention).
  - The Backup vault: `softDeleteSettings.state: 'On'`, 14 days, and `immutabilitySettings.state: 'Unlocked'`.
  - The two resource types spell these differently (`softDeleteState`/`AlwaysON` against `state`/`AlwaysOn`), so the modules keep separate blocks.
- **Locking happens after the first successful drill** (runbook 08 §5.3), and only with sign-off recorded in this ADR. Immutability goes to `Locked` and soft delete to `AlwaysON` (Recovery Services vault) or `AlwaysOn` (Backup vault) on every vault. The change is made **in Bicep** (`modules/recoveryServicesVault.bicep`, `modules/blobBackupVault.bicep`, and their tests) and deployed through the pipeline. Setting it only in the portal or with the CLI would leave the templates saying `Unlocked`, and the next deploy would try to unlock the vault and fail.
- **Storage is fixed before anything is protected.**
  - Each Recovery Services vault's `backupstorageconfig/vaultstorageconfig` sets `GeoRedundant` with `crossRegionRestoreFlag: true`, and the protected item depends on it. The storage type locks once an item is registered.
  - The Backup vault's `storageSettings` is `VaultStore`/`GeoRedundant`.
- **Alerts use Azure Monitor, not the classic channel.**
  - Every vault sets `monitoringSettings.azureMonitorAlertSettings.alertsForAllJobFailures: 'Enabled'`.
  - Recovery Services vaults turn the classic `alertsForCriticalOperations` and `emailNotificationsForSiteRecovery` off.
  - One alert processing rule per environment, `apr-defenstack-<env>-backup` (`MonitorService` = `Azure Backup`), adds the platform action group, so backup alerts reach `ALERT_EMAIL` with every other alert (runbook 06, runbook 08 §5.5).
- **`Azure.RSV.ReplicationAlert` is excluded** in `ps-rule.yaml`, with the comment `# ADR-030: no Site Recovery replication exists; backup alerts are Azure Monitor alerts routed to the action group.` The rule protects Site Recovery replication, and this platform replicates nothing with Site Recovery (the warm standby is a deployed stamp, `ADR-008`). Adding `replicationAlertSettings` would add back a classic email channel that this ADR turns off. Backup job failures are covered by the Azure Monitor alerts above.
- **Prod vaults carry a `CanNotDelete` lock** (`<vault>-lck`, `enableDeleteLock`), like every other prod resource. No lock is ever placed on `AzureBackupRG_<region>_1`, where Azure Backup keeps instant-restore snapshots and must be able to delete them.

## Consequences
- Until the lock, a principal with Backup Contributor on a vault can disable immutability or soft delete, and then delete recovery points. Soft delete still keeps deleted backup data for 14 days, and the vault lock stops the vault itself from being deleted. Accepted for the weeks before the first drill.
- After the lock, retention can only grow. A shorter policy needs a new policy name and a new vault, and the old recovery points live until they expire. Locked immutability also blocks stopping protection with delete data.
- Immutability does not cover operational (local) blob backups; the platform uses vaulted backup only.
- The PSRule baseline stays at zero failures with one more exclusion, justified here; a test pins the exclusion and its comment.
- **Follow-up (Phase 7 gap, not changed in Phase 8):** the Phase 7 diagnostic-settings audit (`diagnosticResourceTypes` in `governance.bicep`) does not list `Microsoft.RecoveryServices/vaults` or `Microsoft.DataProtection/backupVaults`, so the policy does not check the vaults' `rsv-diagnostics` and `bv-diagnostics` settings. Add both types in a governance change (runbook 07 §8).

## Revisit when
The first quarterly drill succeeds (runbook 08 §5.3): record the date, the sign-off and the commit that locks the vaults here. Revisit the exclusion if Site Recovery is ever adopted.
