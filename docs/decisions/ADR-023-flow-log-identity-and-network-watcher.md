# ADR-023: VNet flow logs write with a managed identity to a regional keyless account, from NetworkWatcherRG

## Context
The spec (§3) asks for VNet flow logs and Traffic Analytics. Flow logs are child resources of the region's Network Watcher, which Azure keeps as `NetworkWatcher_<region>` in `NetworkWatcherRG`, one per region per subscription, outside the environment's resource groups. Flow logs need a storage account in the same region as the VNet. Every storage account in this platform disables shared keys and public network access, and by default Network Watcher writes with the account key.

## Decision
- **One flow-log storage account per region,** `stfl<region><suffix>`, in the region's resource group (`modules/flowLogStorage.bicep`):
  - shared key disabled; public network access `Enabled` with the `networkAcls` firewall at default `Deny`, the `AzureServices` bypass, and no IP or VNet rules. With public network access fully `Disabled`, the trusted-services exception is likely ignored and Network Watcher's writes would fail, so the documented fallback is applied from the start (final review). No network reaches the data plane; only trusted Azure services do;
  - prod `Standard_ZRS`, dev `Standard_LRS` (`ADR-008`); no geo copy, because flow logs are regional telemetry and Traffic Analytics already lands in the replicated workspace;
  - 7-day blob and container soft delete; no lock and no diagnostic settings (the account is itself a log sink).
- **A user-assigned identity per region,** `id-flowlogs-defenstack-<env>-<region>`, holds **Storage Blob Data Contributor** on that account only. The flow logs authenticate with it (API version `2024-07-01`; identity support starts at `2024-01-01`).
- **Flow logs for the hub and spoke VNets,** `<vnet>-flowlog`, are deployed by a module scoped to `NetworkWatcherRG` (`modules/flowLogs.bicep`). It references the existing `NetworkWatcher_<region>`, keeps 90 days, and sends Traffic Analytics to the central workspace every 10 minutes.
- **The pipeline identity gets Network Contributor on `NetworkWatcherRG`** and nothing else there (`scripts/New-GitHubDeploymentIdentity.ps1 -NetworkWatcherResourceGroupName`, default `NetworkWatcherRG`). It needs no role-assignment rights there.
- **Network Watcher is not created by the template.** An operator makes sure `NetworkWatcherRG` and `NetworkWatcher_<region>` exist before the identity script and the deployment run (runbook 06 §2, runbook 00b, runbook 01).

## Consequences
- No flow-log write uses a shared key, and the account accepts no public data-plane traffic: the firewall default is `Deny` and it lists no IP or VNet rule.
- PSRule passes on the account with `publicNetworkAccess: 'Enabled'`; no suppression was needed.
- Phase 7's Azure Policy assignment that denies public network access on Storage will flag the `stfl*` accounts. Phase 7 needs a policy exemption for them, with this ADR as the reason.
- `NetworkWatcherRG` holds resources of every environment that shares the subscription, so the flow-log names and deployment names include the environment and region.
- **Accepted risk: shared Network Contributor scope.** Network Contributor on the shared `NetworkWatcherRG` lets each environment's pipeline identity change or delete the other environment's flow logs when dev and prod share a subscription. Accepted: the flow logs of both environments are children of the same `NetworkWatcher_<region>`, so creating them needs write access on that shared watcher, and RBAC cannot narrow it to one environment's children. The exposure is flow-log configuration, not workload data, and every change lands in the Activity Log. Follow-up: a Sentinel analytics rule on the `AzureActivity` table (from the subscription Activity Log) that alerts when a pipeline identity writes or deletes a flow log that does not carry its own environment name.
- Two behaviours are first exercised by a live deployment (runbook 06 §9 "Live-only risks"):
  - **Flow-log writes through the trusted services exception.** Confirm the writes succeed. Symptom of a failure: 403s in the account's activity log and no `insights-logs-flowlogflowevent` container. Fallback: check the identity's role assignment and the `AzureServices` bypass, then raise it with Microsoft; do not add IP or VNet rules.
  - **Traffic Analytics writing into a workspace with `PrivateOnly` ingestion.** Symptom: `NTANetAnalytics` stays empty after 30 minutes. Fallback: keep the flow logs in storage, turn Traffic Analytics off, and raise it with Microsoft. Do not reopen public ingestion on the workspace without a new ADR.
- A new identity's role assignment can take minutes to propagate. The first deploy may fail on storage access and succeed on a re-run.

## Revisit when
Microsoft documents whether Traffic Analytics honours AMPLS `PrivateOnly` ingestion, or Phase 7 adds Defender for Storage to the flow-log accounts.
