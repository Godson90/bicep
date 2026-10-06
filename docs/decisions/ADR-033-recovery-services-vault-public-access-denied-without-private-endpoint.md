# ADR-033: Recovery Services vaults deny public network access and have no private endpoint

## Context
The platform keeps every PaaS service off public networks (spec §3, the Phase 7 deny policies). A Recovery Services vault exposes `publicNetworkAccess`. Private endpoints for Azure Backup exist, but each needs about 11 private IPs and three more DNS zones (`privatelink.<geo>.backup.windowsazure.com`, blob and queue). They can be created only on a vault that has never had an item protected or registered ([private endpoints](https://learn.microsoft.com/azure/backup/private-endpoints-overview#considerations-before-you-start)). The only workload in these vaults is the Azure VM backup of the jump host.

Microsoft's guidance for that workload:
- "A VM backup doesn't require you to allow access to any IPs or FQDNs. So, it doesn't require private endpoints for backup and restore of disks." ([scenarios](https://learn.microsoft.com/azure/backup/private-endpoints-overview#recommended-and-supported-scenarios))
- "If public access is denied and a private endpoint isn't enabled, backups succeed, but restore operations fail for all workloads except Virtual Machines. However, Virtual Machine item-level recovery also fails." ([deny public network access](https://learn.microsoft.com/azure/backup/private-endpoints#deny-public-network-access-to-the-vault))

## Decision
- Every Recovery Services vault sets `publicNetworkAccess: 'Disabled'` and has **no private endpoint**.
- Recovery of the jump host uses full VM or disk restore only (runbook 08 §5.4), never item-level (file) recovery.
- No Backup DNS zones are added to the shared zone set.

## Consequences
- **Supported:** VM backup, full VM restore and disk restore, including cross-region restore to East US.
- **Not available:** file-level recovery from a VM recovery point. Fallback: restore the disks and attach them to a VM to copy files.
- **Adding a private endpoint later needs a new vault.** A vault that has protected an item cannot get one. The steps would be: create the vault, stop protection on the old one (retain data), protect in the new one, and let the old recovery points expire.
- **Not proved by a live run.** Each live risk below has its fallback in runbook 08 §9:
  - The jump host is the first VM protected this way, so backup and restore are not yet proven.
  - Backup and restore work with a denied vault and no private endpoint (Microsoft's documented behaviour, but untested here).
  - Restore staging through the East US account, which has public access disabled.

## Revisit when
A workload that needs private endpoints (SQL Server or SAP HANA in a VM, the MARS agent) is added, or item-level recovery becomes a requirement.
