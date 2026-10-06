# ADR-033: Recovery Services vaults keep public network access Enabled, with no private endpoint, to keep cross-region restore

## Context
The platform keeps every PaaS service off public networks where it can (spec §3, the Phase 7 deny policies). A Recovery Services vault exposes `publicNetworkAccess`. The spec asks for "**Recovery Services vault** per region: GRS, cross-region restore, soft delete, immutability" (§3). The only workload in these vaults is the Azure VM backup of the jump host.

The first Phase 8 design denied public access and added no private endpoint. Microsoft documents that this combination cannot keep cross-region restore working. The Azure Backup FAQ, "Why is Cross Region Restore not supported when Public Network access is set to Deny?", answers: "When you deny public access and use a private endpoint, the system expects data sync to occur over a private network. However, the secondary region currently doesn't support private endpoint configuration, which is essential for replication. Without a private connection in the secondary region, CRR can't perform the required replication." ([Azure Backup FAQ](https://learn.microsoft.com/azure/backup/backup-azure-backup-faq))

So "public access denied" and "cross-region restore" cannot both hold today. Adding a private endpoint would not help either: the secondary region has no private endpoint support. Private endpoints also need about 11 private IPs and three more DNS zones per vault, and can be created only on a vault that has never protected an item ([private endpoints](https://learn.microsoft.com/azure/backup/private-endpoints-overview#considerations-before-you-start)).

## Decision
- Every Recovery Services vault sets **`publicNetworkAccess: 'Enabled'`** and has **no private endpoint**, to keep the spec's cross-region restore (`crossRegionRestoreFlag: true` on `vaultstorageconfig`). `modules/recoveryServicesVault.bicep` carries a comment citing the FAQ and this ADR, and a test pins the value.
- No Backup DNS zones are added to the shared zone set.

**Why this is acceptable:**
- **Azure VM backup is snapshot-based, and its data path is Microsoft-internal.** The snapshot is taken on the platform and transferred to the vault by the Backup service; no data moves through the vault's network endpoint from our networks. "A VM backup doesn't require you to allow access to any IPs or FQDNs. So, it doesn't require private endpoints for backup and restore of disks." ([scenarios](https://learn.microsoft.com/azure/backup/private-endpoints-overview#recommended-and-supported-scenarios))
- **Access stays Entra/RBAC-authorised.** "Public network access" opens the vault's endpoint to the network, not to anonymous callers. Every management and restore call needs an Entra identity with a Backup role on the vault (runbook 08 §2, PIM-activated).
- **The recovery points are protected by more than the network:** soft delete (14 days, `Enabled`, `ADR-030`), immutability (`Unlocked` now, `Locked` after the first drill, `ADR-030`), the prod `CanNotDelete` lock, Azure Monitor security alerts for deleted backup data or disabled soft delete (runbook 08 §5.5), and the multi-user-authorisation option if it is added later.
- **The Phase 7 policies do not deny it.** None of the Phase 7 public-access deny assignments (`modules/governance/policies.bicep`) targets `Microsoft.RecoveryServices/vaults`. The audit-only Microsoft cloud security benchmark initiative may report the vault's private-link recommendations as non-compliant; this ADR is the justification.

## Consequences
- **Supported:** VM backup, full VM restore and disk restore, including **cross-region restore to East US** while West US 3 is down (runbook 08 §5.4).
- **The trade-off:** the vault's endpoint is reachable from the internet, so the control is identity, not network. An attacker with stolen Backup credentials is not stopped by network isolation; soft delete, immutability, the lock and the security alerts are what limit the damage. This is weaker than a fully private vault, and it is the only option that keeps cross-region restore.
- **File-level (item-level) recovery may now be possible**, because the denied-access failure no longer applies ("If public access is denied and a private endpoint isn't enabled, … Virtual Machine item-level recovery also fails", [deny public network access](https://learn.microsoft.com/azure/backup/private-endpoints#deny-public-network-access-to-the-vault)). It is **unverified** here: the recovery script still has to reach the vault from the host that runs it, through the East US firewall's outbound rules. Verify it in the first drill; until then, restore disks.
- **Adding a private endpoint later needs a new vault**, and would cost cross-region restore unless Microsoft adds private endpoint support in the secondary region. The steps would be: create the vault, stop protection on the old one (retain data), protect in the new one, and let the old recovery points expire.
- **Not proved by a live run.** Each live risk has its fallback in runbook 08 §9:
  - the jump host is the first VM protected this way, so backup and restore are not yet proven;
  - the `vaultstorageconfig` PUT with `crossRegionRestoreFlag` before any item is protected, and its identical re-PUT on later deploys once an item is protected and the setting is locked;
  - restore staging through an East US account, since the app accounts have public access disabled.

## Revisit when
Microsoft supports private endpoints in the secondary region for cross-region restore, a workload that needs private endpoints (SQL Server or SAP HANA in a VM, the MARS agent) is added, or the owner decides cross-region restore matters less than a private-only vault.
