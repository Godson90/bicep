# ADR-023: VNet flow logs write with a managed identity to a regional keyless account, from NetworkWatcherRG

## Context
The spec (§3) asks for VNet flow logs and Traffic Analytics. Flow logs are child resources of the region's Network Watcher, which Azure keeps as `NetworkWatcher_<region>` in `NetworkWatcherRG`, one per region per subscription, outside the environment's resource groups. Flow logs need a storage account in the same region as the VNet. Every storage account in this platform disables shared keys and public network access, and by default Network Watcher writes with the account key.

## Decision
- **One flow-log storage account per region,** `stfl<region><suffix>`, in the region's resource group (`modules/flowLogStorage.bicep`):
  - shared key disabled, public network access disabled, `networkAcls` default `Deny` with the `AzureServices` bypass;
  - prod `Standard_ZRS`, dev `Standard_LRS` (`ADR-008`); no geo copy, because flow logs are regional telemetry and Traffic Analytics already lands in the replicated workspace;
  - 7-day blob and container soft delete; no lock and no diagnostic settings (the account is itself a log sink).
- **A user-assigned identity per region,** `id-flowlogs-defenstack-<env>-<region>`, holds **Storage Blob Data Contributor** on that account only. The flow logs authenticate with it (API version `2024-07-01`; identity support starts at `2024-01-01`).
- **Flow logs for the hub and spoke VNets,** `<vnet>-flowlog`, are deployed by a module scoped to `NetworkWatcherRG` (`modules/flowLogs.bicep`). It references the existing `NetworkWatcher_<region>`, keeps 90 days, and sends Traffic Analytics to the central workspace every 10 minutes.
- **The pipeline identity gets Network Contributor on `NetworkWatcherRG`** and nothing else there (`scripts/New-GitHubDeploymentIdentity.ps1 -NetworkWatcherResourceGroupName`, default `NetworkWatcherRG`). It needs no role-assignment rights there.
- **Network Watcher is not created by the template.** An operator makes sure `NetworkWatcherRG` and `NetworkWatcher_<region>` exist before the identity script and the deployment run (runbook 06 §2, runbook 00b, runbook 01).

## Consequences
- No flow-log write uses a shared key, and the account accepts no public data-plane traffic.
- `NetworkWatcherRG` holds resources of every environment that shares the subscription, so the flow-log names and deployment names include the environment and region.
- Two behaviours are first exercised by a live deployment (runbook 06 §9 "Live-only risks"):
  - **The trusted-services exception with public network access fully `Disabled`.** Symptom: 403s in the account's activity log and no `insights-logs-flowlogflowevent` container. Fallback: set `publicNetworkAccess: 'Enabled'` and keep `defaultAction: 'Deny'` with the `AzureServices` bypass. There is still no public data-plane access, because the firewall default is Deny. Record the change here.
  - **Traffic Analytics writing into a workspace with `PrivateOnly` ingestion.** Symptom: `NTANetAnalytics` stays empty after 30 minutes. Fallback: keep the flow logs in storage, turn Traffic Analytics off, and raise it with Microsoft. Do not reopen public ingestion on the workspace without a new ADR.
- A new identity's role assignment can take minutes to propagate. The first deploy may fail on storage access and succeed on a re-run.

## Revisit when
Microsoft documents whether Traffic Analytics honours AMPLS `PrivateOnly` ingestion, or Phase 7 adds Defender for Storage to the flow-log accounts.
