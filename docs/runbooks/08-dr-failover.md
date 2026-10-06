# 08 - Disaster recovery runbook (backup, regional failover and failback, restores, drills)

> Owning module(s):
> - **Pipeline side** (deployed by `deploy.yml`): `modules/recoveryServicesVault.bicep` and `modules/blobBackupVault.bicep`, wired by `modules/regionStamp.bicep`; `modules/backupAlertRouting.bicep`, wired by `main.bicep`.
> - **Operator side** (never the pipeline): `failover.bicep` with `params/failover.bicepparam`, `modules/failover/appServicePlanScale.bicep`, `modules/failover/storagePrivateEndpoint.bicep`, and the reused `modules/bastion.bicep` and `modules/monitorPrivateEndpoint.bicep`.
>
> Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Data and application resilience", §5 Phase 8, §6. Decisions: `ADR-030`, `ADR-031`, `ADR-032`, `ADR-033`; also `ADR-008` (warm standby) and `ADR-020` (RA-GZRS).

## 1. Purpose and scope

This runbook protects prod's data and brings prod back in **East US** when **West US 3** is down. It covers:
- the backups the pipeline deploys;
- the operator-driven failover and the planned failback;
- restores;
- the quarterly drill.

**Targets, for a declared West US 3 regional outage in prod:**

| Objective | Target | How it is met |
|---|---|---|
| **RTO** (users served again) | **1 hour** from the declaration | Front Door already has the East US origin at priority 2 and probes every 30 s with 4 samples, so it moves traffic on its own within minutes. §4 step 2 disables the West US 3 origin so nothing flaps back. The East US app is already running and reads the primary container through the RA-GZRS secondary endpoint (`ADR-020`) at once. `failover.bicep` (§4 step 5) scales the plan to 3 instances in minutes. Writes return when the storage failover completes, through the East US blob endpoint from `failover.bicep` and the DR write grant (§4 step 6). Microsoft says unplanned failover "typically takes about an hour" ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)), so §4 step 3 starts it first. **Write availability is the tightest part of the RTO**: measure it in every drill |
| **RPO** (data lost) | **15 minutes** | Application blobs replicate asynchronously to East US. Microsoft says "You can expect the replication lag to be less than 15 minutes, but this time is an estimate and not guaranteed" ([Blob Storage reliability](https://learn.microsoft.com/azure/reliability/reliability-storage-blob#resilience-to-region-wide-failures)). §4 step 3 reads the **Last Sync Time** before failing over and records the gap. Change feed and object replication on this account rule out the Geo priority replication SLA (`ADR-031`), so 15 minutes stays an expectation. Logs replicate through workspace replication. Key Vault secrets come from the pipeline into each regional vault (`ADR-019`), so they have no RPO |
| Backups (not the RTO/RPO path) | daily | VM backup of the jump host: daily, cross-region restore to East US, whose secondary RPO "can be up to 36 hours" ([restore VMs](https://learn.microsoft.com/azure/backup/backup-azure-arm-restore-vms#cross-region-restore)). Blob vaulted backup of `def-blob`: daily, kept 30 days, restore to another account, **no cross-region restore** (`ADR-031`) |

**What the pipeline deploys (Phase 8):**

| Resource | Where | Settings |
|---|---|---|
| Recovery Services vault `rsv-defenstack-<env>-<region>` | Every stamp | RS0/Standard, system identity, public access `Disabled`, no private endpoint (`ADR-033`); storage `GeoRedundant` + cross-region restore; soft delete `Enabled` 14 days; immutability `Unlocked` (`ADR-030`); Azure Monitor job-failure alerts on, classic alerts off; diagnostics to the workspace (resource-specific); prod `CanNotDelete` lock |
| Policy `vm-daily-enhanced` and the jump host's protected item | The stamp with the jump host (`enableVirtualMachine`, primary) | Enhanced (V2), daily 02:00 UTC, 30 daily + 12 weekly (Sunday), 7 days instant restore |
| Backup vault `bv-defenstack-prod-wus3` | Prod West US 3 only | Policy `blob-daily-vaulted` (02:00 UTC, 30 days), backup instance of the app account's `def-blob`, Storage Account Backup Contributor for the vault's identity (`ADR-031`) |
| Alert processing rule `apr-defenstack-<env>-backup` | `rg-defenstack-<env>-global` | Scope: the regional resource groups. Condition: `MonitorService` = `Azure Backup`. Action: the platform action group (§5.5) |

**What `failover.bicep` deploys (operator only, `ADR-032`), into `rg-defenstack-prod-eus`:**
- `asp-defenstack-prod-eus` scaled to `appServicePlanCapacity` (3), P2V3;
- Bastion `bas-defenstack-prod-eus` with `pip-bas-defenstack-prod-eus`;
- the Azure Monitor endpoint `ampls-defenstack-prod-eus-pe`, whose zone group points the shared Azure Monitor records at East US;
- the blob endpoint `<st>-eus-pe` in the East US spoke's `private-endpoints` subnet, connected to the prod primary app account (`primaryStorageAccountId`). Its zone group points the account's record in the shared blob zone at East US, so the East US app reaches the account once it has failed over. It grants no data role: write access stays a manual, PIM-gated step (§4 step 6), so the standby is read-only outside DR (`ADR-020`).

**Not in scope:**
- dev, which has no warm standby (`ADR-008`);
- the VPN gateway in East US, which is too slow for the RTO (Bastion is used instead);
- Site Recovery;
- automatic failover of anything except Front Door.

## 2. Prerequisites

- **Operator roles, activated through PIM** for §4 and §5.2: **Contributor** at subscription scope. It covers:
  - the subscription deployment;
  - the East US and global resource groups (zone records, the AMPLS endpoint connection, Front Door);
  - `Microsoft.Storage/storageAccounts/failover/action` on the primary account;
  - the workspace switchover. Microsoft requires Log Analytics Contributor "on the resource group of the workspace" ([workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication#switch-over-to-your-secondary-workspace)), and Contributor includes it.

  §4 step 6 (the DR write grant) and §5.2 step 3 (its removal) also need **Role Based Access Control Administrator** or **User Access Administrator**. Restores (§5.4) need **Backup Contributor** on the vaults. Activate the roles with a justification that names the incident.
- **Who declares:** the platform owner, or the on-call lead when the owner cannot be reached within 15 minutes. Both are named in the incident channel. Declare when Service Health (`alert-defenstack-prod-service-health`) or Front Door origin health (`front-door-origin-health`) confirms a West US 3 regional problem, and Microsoft gives no recovery time inside the RTO.
- **Steady-state preconditions.** Check them each quarter in the drill:
  - Workspace replication `Succeeded` for **at least 24 hours**. Microsoft: "wait at least 24 hours after enabling workspace replication… Azure Monitor rejects earlier switchover requests" ([workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication#switch-over-to-your-secondary-workspace)). `main.bicep` turns replication on with the secondary stamp, so this holds from a day after the first prod deploy.
  - The East US stamp is deployed (`deploySecondaryRegion = true`).
  - The Front Door East US origin reports its private link `Approved` (runbook 04).
  - The recovery points exist (§6).
- **Tools:**
  - Azure CLI 2.90+ with the `storage-preview` extension (`az extension add -n storage-preview`) for `--failover-type`, and the `dataprotection` extension;
  - Bicep CLI 0.47.16;
  - PowerShell 7 or 5.1;
  - `gh`, for the pipeline freeze.
- **Network path:** none for the control-plane steps. Data-plane checks (§4 step 8) run from inside the East US network: a jump host restored into East US, reached through the East US Bastion.

## 3. Parameters

`failover.bicep`, set in `params/failover.bicepparam`:

| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `environmentName` | `prod` | `prod` | Only prod has a warm standby; `@allowed(['prod'])` |
| `location` | `eastus` | `eastus` | The region that takes over; `@allowed(['eastus'])` |
| `appServicePlanCapacity` | `3` | `3` | The primary plan's instance count. P2V3; zone redundancy stays off (fixed at creation) |
| `failoverActive` | `true` | `true` | `false` deploys nothing |
| `primaryStorageAccountId` | The prod primary app account: `stwus3<uniqueString(subscription ID, 'prod', 'westus3')>` in `rg-defenstack-prod-wus3` | *(default)* | The blob endpoint's target. A parameter file cannot call `subscription()`, so the template computes the ID as `regionStamp.bicep` names the account, and a test pins the parity. Override it only if the account was renamed. It is the only West US 3 value in `failover.bicep`; no deployment targets West US 3 |

Pipeline side (`regionStamp.bicep`, fixed in code):
- `enableBlobVaultedBackup`: default prod primary only.
- The VM backup is deployed only where the jump host exists.
- Vault names: `rsv-defenstack-<env>-<region>` and `bv-defenstack-prod-wus3`.

## 4. Step-by-step deployment

The failover procedure. Record the time at each step in the drill log (§5.3); the declaration time is T0. Run from the repository root.

1. **Declare the outage** (§2, "Who declares"). Post T0 and "DR failover started, pipeline frozen" in the incident channel. **Freeze the pipeline** (§5.1):

   ```powershell
   gh workflow disable deploy --repo Godson90/bicep
   ```

   Activate the §2 roles through PIM, then:

   ```powershell
   az login
   az account set --subscription <subscription id>
   $st = az storage account list -g rg-defenstack-prod-wus3 --query "[?starts_with(name,'stwus3')].name | [0]" -o tsv
   $stId = az storage account show -g rg-defenstack-prod-wus3 -n $st --query id -o tsv
   ```

2. **Front Door: disable the West US 3 origin**, so no traffic goes there even if its probes flap. A disabled origin is excluded first, before health probes are evaluated ([Front Door health probes](https://learn.microsoft.com/azure/frontdoor/health-probes#how-front-door-determines-origin-health)).

   ```powershell
   az afd origin update -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --origin-group-name app --origin-name app-wus3 --enabled-state Disabled
   az afd origin list -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --origin-group-name app --query "[].{origin:name, enabled:enabledState, priority:priority}" -o table
   ```

   Check: `app-wus3` is `Disabled` and `app-eus` is `Enabled`. If the update fails because ARM cannot reach the global resource group, go on: Front Door's probes already route to `app-eus` (§9, live-only risks).

3. **Storage: fail the primary account over to East US (unplanned).** First read the Last Sync Time. Everything written after it may be lost, which is the measured RPO:

   ```powershell
   az storage account show -g rg-defenstack-prod-wus3 -n $st --expand geoReplicationStats --query "{sku:sku.name, primary:primaryLocation, lastSync:geoReplicationStats.lastSyncTime, status:geoReplicationStats.status}" -o json
   az storage account failover -g rg-defenstack-prod-wus3 -n $st --failover-type Unplanned --yes --no-wait
   ```

   Record `lastSync` and T0 − `lastSync`. Change feed, object replication and point-in-time restore do **not** block an **unplanned** failover; they block only a planned one ([disaster recovery guidance](https://learn.microsoft.com/azure/storage/common/storage-disaster-recovery-guidance#plan-for-failover)). The account's private endpoints follow the new primary on their own ([storage private endpoints](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints#creating-a-private-endpoint)). However, the West US 3 primary endpoint is unreachable while its region is down, so §4 step 6 adds an East US endpoint. Continue with step 4 while this runs. Poll:

   ```powershell
   az storage account show -g rg-defenstack-prod-wus3 -n $st --query "{sku:sku.name, primary:primaryLocation, failoverInProgress:failoverInProgress}" -o json
   ```

   Expected when done: `primary` `eastus` and `sku` `Standard_LRS`. **An unplanned failover leaves the account LRS in East US** ("After the failover, your storage account type is automatically converted to locally redundant storage (LRS)", [initiate a failover](https://learn.microsoft.com/azure/storage/common/storage-initiate-account-failover)). When West US 3 is healthy again, re-enable geo-redundancy. The effective redundancy is RA-GRS until failback, because the current primary is LRS ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)):

   ```powershell
   az storage account update -g rg-defenstack-prod-wus3 -n $st --sku Standard_RAGRS
   ```

   Point-in-time restore cannot go back before the failover ([PITR interactions](https://learn.microsoft.com/azure/storage/blobs/point-in-time-restore-overview#feature-interactions)).

4. **Log Analytics workspace switchover.** This needs the 24-hour prerequisite (§2):

   ```powershell
   az monitor log-analytics workspace show -g rg-defenstack-prod-global -n log-defenstack-prod --query "replication.{enabled:enabled, location:location, state:provisioningState}" -o json
   az monitor log-analytics workspace failover -g rg-defenstack-prod-global --workspace-name log-defenstack-prod --location eastus --no-wait
   ```

   Check first: `enabled` `true`, `location` `eastus`, `state` `Succeeded`. The switchover "can take up to 30 minutes" ([CLI reference](https://learn.microsoft.com/cli/azure/monitor/log-analytics/workspace#az-monitor-log-analytics-workspace-failover)). The workspace's private link support is documented as "Supported" ([workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication#deployment-considerations)). How the AMPLS path behaves after switchover is checked in step 8 (§9).

5. **Run `failover.bicep`.** Validate, preview, then create. Use deployment location **`eastus`**, not West US 3:

   ```powershell
   az deployment sub validate --location eastus --name defenstack-failover --template-file failover.bicep --parameters params/failover.bicepparam
   az deployment sub what-if --location eastus --name defenstack-failover --template-file failover.bicep --parameters params/failover.bicepparam
   az deployment sub create --location eastus --name defenstack-failover --template-file failover.bicep --parameters params/failover.bicepparam
   ```

   Check the what-if:
   - **Modify** `asp-defenstack-prod-eus` (`sku.capacity` 1 → 3; nothing else).
   - **Create** `bas-defenstack-prod-eus`, `pip-bas-defenstack-prod-eus` and `bastion-diagnostics`.
   - **Create** `ampls-defenstack-prod-eus-pe` and its zone group `default`.
   - **Create** `<st>-eus-pe` and its zone group `default` (blob).
   - **Stop** on any delete, or on any change in `rg-defenstack-prod-wus3`. None is possible by design, and a test pins it: West US 3 appears only as the storage account the blob endpoint connects to.

   Expected: `Succeeded`, with outputs `appServicePlanName`, `bastionName`, `monitorPrivateEndpointId` and `storagePrivateEndpointId`. Bastion usually takes the longest (§9, live-only risks); the plan scales within minutes.

6. **Private endpoint connections and storage writes from East US.**
   - **Front Door East US origin.** It was approved in steady state by `deploy.yml` (runbook 04), so normally nothing is needed. Check:

     ```powershell
     az afd origin show -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --origin-group-name app --origin-name app-eus --query "sharedPrivateLinkResource.status" -o tsv
     ```

     Expected: `Approved`. If it shows `Pending`, run the Phase 4 approval script for the East US app only:

     ```powershell
     $eusApp = az webapp list -g rg-defenstack-prod-eus --query "[0].id" -o tsv
     ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $eusApp -FrontDoorProfileName afd-defenstack-prod -FrontDoorResourceGroupName rg-defenstack-prod-global
     ```

   - **AMPLS endpoint:** `az network private-endpoint show -g rg-defenstack-prod-eus -n ampls-defenstack-prod-eus-pe --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState.status" -o tsv` should print `Approved` (same subscription, auto-approved).
   - **Storage writes from East US.** The account's own blob endpoint `<st>-pe` sits in the West US 3 spoke, which is down. `failover.bicep` created `<st>-eus-pe` in the East US spoke (step 5), and its zone group rewrote the account's A record in the shared blob zone to the East US IP (the same "last one applies" behaviour as AMPLS). Check its connection, then grant the East US app write access on `def-blob` for the duration of DR. **The grant is the one manual step.** It stays out of Bicep, so the standby holds only Storage Blob Data Reader outside DR (`ADR-020`, `ADR-032`), and it needs the PIM-activated RBAC role (§2):

     ```powershell
     az network private-endpoint show -g rg-defenstack-prod-eus -n "$st-eus-pe" --query "privateLinkServiceConnections[0].privateLinkServiceConnectionState.status" -o tsv
     $eusApp = az webapp list -g rg-defenstack-prod-eus --query "[0].id" -o tsv
     $eusPrincipal = az webapp identity show --ids $eusApp --query principalId -o tsv
     az role assignment create --assignee-object-id $eusPrincipal --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope "$stId/blobServices/default/containers/def-blob"
     ```

     Expected: `Approved` (same subscription, auto-approved). Failback removes the grant, then the endpoint (§5.2 step 3).

7. **Key Vault: no action.** Each region has its own vault, `kv-eus-…`, with the same secrets from the pipeline (`ADR-019`). The East US app already uses it.

8. **Verify**, and record T(verify) − T0 as the measured RTO:
   - **Front Door 200 from East US:**

     ```powershell
     $endpoint = az afd endpoint show -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --endpoint-name fde-defenstack-prod --query hostName -o tsv
     (Invoke-WebRequest -Uri "https://$endpoint/" -Method Head -UseBasicParsing).StatusCode
     $afdId = az afd profile show -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --query id -o tsv
     az monitor metrics list --resource $afdId --metric OriginHealthPercentage --dimension Origin --interval PT5M --query "value[0].timeseries[].{origin:metadatavalues[0].value, health:data[-1].average}" -o table
     ```

     Expected: `200`; `app-eus` healthy (100). Also add your custom domain if it is in use.
   - **Telemetry.** From the East US network (a restored jump host through `bas-defenstack-prod-eus`), check that the Azure Monitor names resolve to East US endpoint IPs (`10.10.1.x`), then that data arrives:

     ```powershell
     Resolve-DnsName api.monitor.azure.com
     az monitor log-analytics query -w (az monitor log-analytics workspace show -g rg-defenstack-prod-global -n log-defenstack-prod --query customerId -o tsv) --analytics-query "AppRequests | where TimeGenerated > ago(15m) | summarize count() by AppRoleName" -o table
     ```

     Expected: rows for the East US app. Queries are `PrivateOnly` (`ADR-022`), so they work only from inside the network.
   - **Storage writes:** from the same host, `Resolve-DnsName "$st.blob.core.windows.net"` returns a `10.10.1.x` address. Then:

     ```powershell
     az storage blob upload --account-name $st --container-name def-blob --name "dr-check-$(Get-Date -Format yyyyMMddHHmm).txt" --data "failover check" --auth-mode login
     ```

     It succeeds, and the app's own write path returns no errors in `AppRequests`.

## 5. Manual and post-deployment steps

### 5.1 Pipeline freeze during DR

**From §4 step 1 until §5.2 step 9, the pipeline does not deploy prod or dev** (`ADR-032`). Disable the workflow, and tell the team not to merge to `main`. Three reasons:
- A run of `main.bicep` deploys the West US 3 stamp first, and fails there.
- If it got further, it would scale East US back to 1 instance, re-enable `app-wus3`, try to reset the failed-over storage account to `westus3` and `Standard_RAGZRS`, and rewrite the Azure Monitor records to the dead West US 3 endpoint.
- `failover.bicep` itself is never in the pipeline.

During the freeze:
- Make urgent changes by hand in East US only.
- Write each one down, and back-port it to Bicep after failback.
- Do not run `governance.bicep` either: its flow-log exemptions target the West US 3 resource group.

### 5.2 Failback (planned)

Start only after Microsoft reports West US 3 healthy and the West US 3 stamp's resources show healthy (`az resource list -g rg-defenstack-prod-wus3 --query "[?provisioningState!='Succeeded'].name"` is empty).

Before step 1, re-enable geo-redundancy (§4 step 3) if you have not already. Then wait for the initial sync, until `geoReplicationStats.status` is `Live`. A planned failover needs it, and it "might take a significant amount of time" ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)).

1. **Pause blob backup and delete the object replication policy.** A planned failover is refused while an OR policy exists ([failover FAQ](https://learn.microsoft.com/azure/storage/common/storage-failover-faq#what-are-the-conflicting-features-or-scenarios-for-failovers)):

   ```powershell
   az dataprotection backup-instance suspend-backup -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $st
   az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st --query "[].policyId" -o tsv
   az storage account or-policy delete -g rg-defenstack-prod-wus3 --account-name $st --policy-id <policyId>
   ```

   Suspending keeps the existing recovery points (immutability and soft delete still apply, `ADR-030`).
2. **Disable point-in-time restore and change feed.** Both block a planned failover:

   ```powershell
   az storage account blob-service-properties update -g rg-defenstack-prod-wus3 --account-name $st --enable-restore-policy false --enable-change-feed false
   ```

   Versioning and soft delete stay on.
3. **Run the planned failover back to West US 3.** No data loss is expected: replication completes before the switch ([planned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-planned)):

   ```powershell
   az storage account failover -g rg-defenstack-prod-wus3 -n $st --failover-type Planned --yes
   az storage account show -g rg-defenstack-prod-wus3 -n $st --query "{sku:sku.name, primary:primaryLocation}" -o json
   ```

   Expected: `primary` `westus3`. A planned failover keeps the redundancy, so the account is `Standard_RAGRS`. Bring it back to `Standard_RAGZRS` with runbook 05 §4 step 4 (a zone conversion; the account stays usable while it runs).

   Now remove the DR write grant (§4 step 6), then delete the East US blob endpoint that `failover.bicep` created:

   ```powershell
   $eusApp = az webapp list -g rg-defenstack-prod-eus --query "[0].id" -o tsv
   $eusPrincipal = az webapp identity show --ids $eusApp --query principalId -o tsv
   az role assignment delete --assignee $eusPrincipal --role "Storage Blob Data Contributor" --scope "$stId/blobServices/default/containers/def-blob"
   az network private-endpoint delete -g rg-defenstack-prod-eus -n "$st-eus-pe"
   ```

   Deleting the endpoint removes its record from the shared blob zone. The account's name stops resolving privately until step 4, whose pipeline deploy re-PUTs `<st>-pe`'s zone group and restores the West US 3 record. Expect blob write errors until then, and do not re-create a record by hand.
4. **Re-enable the features through the pipeline.** Enable the workflow and dispatch **prod** only (two approvals, `ADR-012`). Merges stay frozen until step 9.

   ```powershell
   gh workflow enable deploy --repo Godson90/bicep
   gh workflow run deploy --repo Godson90/bicep -f environment=prod
   ```

   Check the what-if: `restorePolicy` and `changeFeed` return on the primary account, and `asp-defenstack-prod-eus` goes back to 1 instance. The run also sets `app-wus3` back to `Enabled`, and rewrites `ampls-defenstack-prod-pe`'s zone group (step 6 checks the records). Then resume blob backup, which re-creates the object replication policy, and check it:

   ```powershell
   az dataprotection backup-instance resume-protection -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $st
   az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st --query "[].policyId" -o tsv
   ```

   Expected: one policy, and the instance's `protectionStatus` `ProtectionConfigured`.

   **Check the blob record (§9, live-only).** The account's A record in the shared blob zone must hold `<st>-pe`'s West US 3 address again:

   ```powershell
   $nicId = az network private-endpoint show -g rg-defenstack-prod-wus3 -n "$st-pe" --query "networkInterfaces[0].id" -o tsv
   $peIp = az network nic show --ids $nicId --query "ipConfigurations[0].privateIPAddress" -o tsv
   az network private-dns record-set a show -g rg-defenstack-prod-global -z privatelink.blob.core.windows.net -n $st --query "aRecords[].ipv4Address" -o tsv
   ```

   Expected: exactly `$peIp` (a `10.0.1.x` address). A missing record set, or an East US (`10.10.1.x`) address: §9, "The blob record after failback".
5. **Workspace failback.** First confirm that the primary workspace is healthy and has ingested the switchover period:

   ```powershell
   az monitor log-analytics workspace failback -g rg-defenstack-prod-global --workspace-name log-defenstack-prod
   ```

6. **Delete the East US AMPLS endpoint, then restore the West US 3 records:**

   ```powershell
   az network private-endpoint delete -g rg-defenstack-prod-eus -n ampls-defenstack-prod-eus-pe
   Resolve-DnsName api.monitor.azure.com
   ```

   Expected, from a West US 3 host: a `10.0.1.x` address. If the records are missing or still East US, dispatch the prod pipeline again (step 4): it re-PUTs `ampls-defenstack-prod-pe`'s zone group. If they are still wrong after that, delete that zone group (`az network private-endpoint dns-zone-group delete -g rg-defenstack-prod-wus3 --endpoint-name ampls-defenstack-prod-pe -n default`) and dispatch once more. A `ScopeLocked` error: §9.
7. **Scale East US back down and remove the East US Bastion.** The step 4 pipeline run already set the plan to 1 instance. Confirm it, then delete Bastion and its IP:

   ```powershell
   az appservice plan show -g rg-defenstack-prod-eus -n asp-defenstack-prod-eus --query "sku.capacity" -o tsv
   az network bastion delete -g rg-defenstack-prod-eus -n bas-defenstack-prod-eus
   az network public-ip delete -g rg-defenstack-prod-eus -n pip-bas-defenstack-prod-eus
   ```

   Also delete any VM restored into East US for the DR (and stop its protection, §8).
8. **Re-enable the Front Door West US 3 origin.** Step 4 normally did it already; check, and set it if needed:

   ```powershell
   az afd origin update -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --origin-group-name app --origin-name app-wus3 --enabled-state Enabled
   ```

9. **Lift the freeze.** Post it in the incident channel and allow merges. Back-port every manual change from §5.1. Fill in the drill log row (§5.3).

### 5.3 Quarterly drill, drill log and irreversible hardening

**Drill procedure (once a quarter, in a change window).** The drill uses **planned** failovers only, so no data is lost:
1. Check the §2 preconditions and the §6 rows.
2. Run §4 steps 1, 2 and 4–8. For step 3, use the same pre-steps as failback (§5.2 steps 1–2), then `az storage account failover --failover-type Planned` to East US. Write throughput is unchanged and redundancy stays geo-redundant.
3. Measure the RTO (T0 to §4 step 8) and the RPO (the Last Sync Time gap; expected 0 for a planned failover).
4. Fail back with §5.2.
5. Prove alert routing: trigger an on-demand backup of a stopped or missing item, or follow Microsoft's test-alert guidance. Check that `ALERT_EMAIL` receives an Azure Backup alert through `apr-defenstack-prod-backup` (§5.5).
6. Restore test (§5.4): one VM cross-region restore of the jump host's disks and one blob vaulted restore, both to scratch targets, then delete them.

**Drill log.** Add a row for every drill and every real failover:

| Date | Type (drill / real) | RTO measured | RPO measured | Issues | Sign-off |
|---|---|---|---|---|---|
| | | | | | |

**Irreversible hardening, after the first successful drill only.** It needs a sign-off recorded in `ADR-030` (date, approver, drill row). Lock immutability and make soft delete always-on, on every vault: `rsv-defenstack-dev-wus3`, `rsv-defenstack-prod-wus3`, `rsv-defenstack-prod-eus` and `bv-defenstack-prod-wus3`.
1. **Change the Bicep in one pull request**, so the pipeline never tries to undo it:
   - `modules/recoveryServicesVault.bicep`: `immutabilitySettings.state: 'Locked'`, `enhancedSecurityState: 'AlwaysON'`;
   - `modules/blobBackupVault.bicep`: `immutabilitySettings.state: 'Locked'`, `softDeleteSettings.state: 'AlwaysOn'`;
   - their tests.

   Deploy dev, then prod, through the pipeline.
2. If the template refuses to lock in one step (a vault must already be immutable before it locks), first set the state by CLI, then deploy the same values:

   ```powershell
   az backup vault backup-properties set -g rg-defenstack-prod-wus3 -n rsv-defenstack-prod-wus3 --immutability-state Locked --soft-delete-feature-state AlwaysON
   az dataprotection backup-vault update -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --immutability-state Locked --soft-delete-state AlwaysOn
   ```

   Check the flag names with `--help` first. Microsoft: "Immutability locking is irreversible" ([immutable vault](https://learn.microsoft.com/azure/backup/backup-azure-immutable-vault-concept#making-immutability-irreversible)). After this, retention can only grow, and a shorter policy needs a new vault.

### 5.4 Restores

**VM cross-region restore (the jump host into East US).** The vault keeps the West US 3 jump host's recovery points in East US (`crossRegionRestoreFlag`), so this works while West US 3 is down. Restore the disks, then create the VM from the template the job writes:

```powershell
$vm = '<jump host name, vmwus3…>'
az backup recoverypoint list -g rg-defenstack-prod-wus3 --vault-name rsv-defenstack-prod-wus3 --backup-management-type AzureIaasVM --container-name $vm --item-name $vm --use-secondary-region --query "[].{name:name, time:properties.recoveryPointTime}" -o table
az backup restore restore-disks -g rg-defenstack-prod-wus3 --vault-name rsv-defenstack-prod-wus3 --container-name $vm --item-name $vm --rp-name <name> --storage-account <East US staging account ID> --target-resource-group rg-defenstack-prod-eus --use-secondary-region
az backup job list -g rg-defenstack-prod-wus3 --vault-name rsv-defenstack-prod-wus3 --use-secondary-region -o table
```

- `--use-secondary-region` restores "from a recoverypoint in secondary region" ([CLI](https://learn.microsoft.com/cli/azure/backup/restore)). Confirm the `recoverypoint list` flag with `--help`: it is not quoted in Microsoft's docs.
- The secondary-region RPO can be up to 36 hours.
- Put the restored VM in `vnet-defenstack-prod-eus-spoke` / `management` with no public IP, and reach it through `bas-defenstack-prod-eus`.
- File-level recovery is not available, because the vaults deny public access and have no private endpoint (`ADR-033`). Restore disks instead.

**Blob vaulted restore to an alternate account.** Vaulted backup restores to a **different** account only, which must not already contain `def-blob`. There is **no cross-region restore for blobs**, so this needs West US 3 up (`ADR-031`):

```powershell
$bi = az dataprotection backup-instance list -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --query "[0].name" -o tsv
az dataprotection recovery-point list -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $bi --query "[].{id:name, time:properties.recoveryPointTime}" -o table
az dataprotection backup-instance restore initialize-for-item-recovery --datasource-type AzureBlob --restore-location westus3 --source-datastore VaultStore --target-resource-id <alternate account ID> --recovery-point-id <id> --container-list def-blob > restore.json
az dataprotection backup-instance restore trigger -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $bi --restore-request-object restore.json
```

Commands from [restore blobs with the CLI](https://learn.microsoft.com/azure/backup/restore-blobs-storage-account-cli#prepare-the-restore-request). Then copy what you need back into `def-blob` with `az storage blob copy start-batch --auth-mode login`. For a single blob, or within 13 days, runbook 05 §5.2 (soft delete, versioning, point-in-time restore) is faster.

### 5.5 Backup alert triage

Azure Backup's built-in Azure Monitor alerts reach `ALERT_EMAIL` through `apr-defenstack-<env>-backup`. They cover job failures, plus security alerts such as backup data deleted or soft delete disabled. List them:

```powershell
az graph query -q "alertsmanagementresources | where properties.essentials.monitorService == 'Azure Backup' and todatetime(properties.essentials.startDateTime) > ago(7d) | project name, severity=properties.essentials.severity, target=properties.essentials.targetResourceName, state=properties.essentials.alertState" -o table
```

| Alert | Likely cause | Action |
|---|---|---|
| Backup failure on the jump host (`rsv-…`) | VM stopped or deallocated during the window, agent or extension problem, snapshot quota | `az backup job list -g <rg> --vault-name <rsv> --status Failed -o table`, then `az backup job show` for the error code; fix it, then `az backup protection backup-now` |
| Backup failure on the blob instance (`bv-…`) | Missing permission (the role, §9), object replication refused, or a container renamed | `az dataprotection job list-from-resourcegraph --datasource-type AzureBlob --status Failed`; fix it, then `az dataprotection backup-instance adhoc-backup` |
| Restore failure | Target conflict (a `def-blob` already exists), or a network-restricted staging account | §5.4; choose another target |
| **Security**: backup data deleted, soft delete disabled, immutability changed | Possible compromise | Treat it as a security incident: check the Activity Log for the caller, undelete within 14 days, and re-enable soft delete in Bicep |

## 6. Validation

| Check | Command | Expected result |
|---|---|---|
| Vaults | `az backup vault list --query "[].{name:name, rg:resourceGroup, pna:properties.publicNetworkAccess}" -o table` | `rsv-defenstack-dev-wus3`, `-prod-wus3`, `-prod-eus`; `Disabled` |
| Vault storage | `az backup vault backup-properties show -g rg-defenstack-prod-wus3 -n rsv-defenstack-prod-wus3 --query "[0].{type:storageModelType, crr:crossRegionRestoreFlag}" -o json` | `GeoRedundant`, `true` |
| Security settings | `az resource show --ids <rsv id> --query "properties.securitySettings.{softDelete:softDeleteSettings.softDeleteState, days:softDeleteSettings.softDeleteRetentionPeriodInDays, immutability:immutabilitySettings.state}" -o json` | `Enabled`, `14`, `Unlocked` (after §5.3 hardening: `AlwaysON`, `Locked`) |
| Jump host protected (with `enableVirtualMachine`) | `az backup item list -g rg-defenstack-<env>-wus3 --vault-name rsv-defenstack-<env>-wus3 --query "[].{item:properties.friendlyName, state:properties.protectionState, last:properties.lastBackupTime}" -o table` | `Protected` and a last backup within 24 hours |
| Secondary-region recovery points | §5.4 `recoverypoint list --use-secondary-region` | At least one point (from up to 48 hours after the first backup) |
| Blob backup | `az dataprotection backup-instance list -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --query "[].{name:name, status:properties.protectionStatus.status}" -o table` | `ProtectionConfigured` |
| Object replication | `az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st -o table` | One policy, created by Azure Backup |
| Alert routing | `az monitor alert-processing-rule show -g rg-defenstack-prod-global -n apr-defenstack-prod-backup --query "{scopes:properties.scopes, enabled:properties.enabled}" -o json` | The two regional resource group IDs, `true` |
| Workspace replication | `az monitor log-analytics workspace show -g rg-defenstack-prod-global -n log-defenstack-prod --query "replication" -o json` | `enabled: true`, `location: eastus`, `provisioningState: Succeeded` |
| After failover | §4 step 8 | Front Door `200` from `app-eus`, East US telemetry, storage write |
| After failback: blob record | §5.2 step 4, "Check the blob record" | Only `<st>-pe`'s West US 3 address; no `<st>-eus-pe` in `rg-defenstack-prod-eus` and no DR write grant on `def-blob` |

## 7. Rollback

- **Abandon a failover before storage (§4 step 3).** Re-enable `app-wus3` (§5.2 step 8). Remove what `failover.bicep` created: the blob endpoint and any write grant (§5.2 step 3 commands), then §5.2 steps 6–7. Lift the freeze.
- **After an unplanned storage failover there is no rollback, only failback (§5.2).** The West US 3 copy is deleted when the failover completes.
- **A wrong `failover.bicep` run:** redeploy with corrected parameters, or remove its resources by hand (§5.2 step 3 for the blob endpoint, steps 6–7). Deployments are incremental and remove nothing.
- **Backups (pipeline side):** revert the Phase 8 commit and remove resources by hand, in this order:
  1. Stop protection, keeping the data: `az backup protection disable … --delete-backup-data false` and `az dataprotection backup-instance stop-protection`.
  2. Delete the locks.
  3. Delete the vaults once their soft-deleted data has expired.

  An unlocked immutable vault refuses deletion of unexpired recovery points. **After §5.3 hardening nothing can be undone.**

## 8. Operations

- **Quarterly:** the drill (§5.3), including the restore test and the alert check.
- **Weekly:** §6 rows "Jump host protected" and "Blob backup". Failed jobs alert by email (§5.5).
- **Removing the jump host** (`enableVirtualMachine = false`) does **not** stop its backup: Bicep never deletes the protected item. Stop it by hand:

  ```powershell
  az backup protection disable -g rg-defenstack-<env>-wus3 --vault-name rsv-defenstack-<env>-wus3 --container-name <vm> --item-name <vm> --backup-management-type AzureIaasVM --delete-backup-data false --yes
  ```

- **Never lock `AzureBackupRG_<region>_1`.** Azure Backup keeps instant-restore snapshots there and must delete them on schedule. Phase 7's allowed resource-group locations include both regions, so Azure can create it.
- **Changing a backup policy:** neither policy type is edited in place. Create the policy under a new name, point the item or instance at it, and leave the old one until it is unused. After hardening, retention can only grow.
- **Identity script:** the pipeline assigns Storage Account Backup Contributor. Re-run `scripts/New-GitHubDeploymentIdentity.ps1` before the first Phase 8 deploy (runbook 00b).
- **Cost drivers** (`docs/cost.md` "Phase 8 delta"): protected instances, vault storage, and DR-time Bastion and plan instances.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| Phase 8 deploy: `AuthorizationFailed` on `roleAssignments/write` for role `e5e2a7ff-…` | The identity script was not re-run, so the ABAC condition lacks Storage Account Backup Contributor | Runbook 00b: re-run `New-GitHubDeploymentIdentity.ps1`, then re-run the deploy |
| Backup instance fails with `UserErrorMissingRequiredPermissions` on the first deploy | The new role assignment has not propagated ("might take up to 30 minutes", [configure and manage](https://learn.microsoft.com/azure/backup/blob-backup-configure-manage#grant-permissions-to-the-backup-vault-on-storage-accounts)) | Re-run the deploy after 30 minutes |
| Protected item fails with a container-not-found error | The vault has not discovered the jump host yet | Re-run the deploy; if it still fails, run `az backup protection enable-for-vm` once by hand, then redeploy |
| `az storage account failover --failover-type Planned` refused, naming change feed, object replication or point-in-time restore | §5.2 steps 1–2 were skipped | Do them, then retry |
| `az monitor log-analytics workspace failover` rejected | Replication is less than 24 hours old, or `--location` is not the replication location | §2 prerequisite; use `eastus` |
| `ScopeLocked` when the East US endpoint's zone group writes or deletes records | The prod `CanNotDelete` locks on the shared zones | Lift the five Azure Monitor and blob zone locks (`az lock list -g rg-defenstack-prod-global -o table`), retry, then let the next pipeline run restore them (runbook 01 §9) |
| Prod pipeline run fails in West US 3 during DR | The freeze was not applied | §5.1; cancel the run |
| Blob restore fails with a conflict | The target account already has `def-blob` | Restore into an account without it |

### Live-only risks

These cannot be proved offline. Each is first exercised by the first deploy, drill or incident that uses it; record the outcome in the drill log.

| Risk | How it shows | Fallback |
|---|---|---|
| **Blob vaulted backup with `publicNetworkAccess: 'Disabled'`** on the account and a deny-all firewall (bypass `AzureServices`). Microsoft documents support with private endpoints, and vaulted backup runs on object replication; no quote covers Disabled with no exceptions (research A.1, "likely") | Backup instance stuck in `ConfiguringProtection`, or jobs failing with a network or OR error | **Fallback:** keep public access Disabled and add the Backup vault as a resource-instance rule on the account's firewall in `storage.bicep`. If that is refused, record it in `ADR-031` and accept daily backups failing until Microsoft supports it, relying on soft delete, versioning and point-in-time restore |
| **The datasource object type.** `BlobBackupDatasourceParameters` follows the REST guide but is not in the Bicep types (`ADR-031`) | Deploy fails on the backup instance with an `objectType` error | **Fallback:** switch to `AdlsBlobBackupDatasourceParameters` in `blobBackupVault.bicep` and its test, and record it in `ADR-031` |
| **RBAC race for the backup instance** | §9 table, first deploy | **Fallback:** re-run the deploy after 30 minutes |
| **Protected item container discovery.** The item is PUT without an explicit container | §9 table | **Fallback:** re-run; or enable protection once with `az backup protection enable-for-vm` and redeploy |
| **Recovery Services vault with public access denied and no private endpoint** (`ADR-033`) | VM backup or restore fails with a network error; file recovery unavailable (expected) | **Fallback:** restore disks rather than items. If VM backup itself fails, set `publicNetworkAccess: 'Enabled'` on the vault with an ADR note (a private endpoint needs a new vault) |
| **Restore staging account.** Disk restore needs a staging account in East US, and the app accounts deny public access | `restore-disks` fails writing the VM config or template | **Fallback:** create a temporary `Standard_LRS` staging account in `rg-defenstack-prod-eus` with a dated policy waiver (runbook 07 §5.3 emergency path), restore, then delete both |
| **The global resource group lives in westus3** (runbook 01). The shared zones, the AMPLS, the workspace, Front Door and the action group are all there. Microsoft says ARM "automatically reroutes ARM control plane requests to a backup region" ([ARM overview](https://learn.microsoft.com/azure/azure-resource-manager/management/overview#which-location-should-i-use-for-my-resource-group)), but this is **unverified** here. The East US endpoints' zone group writes are the critical ones | `failover.bicep` fails on `failover-monitor-private-endpoint-eus` or `failover-storage-private-endpoint-eus` (`ResourceGroupNotFound`, timeouts); §4 step 2 or 4 fails | **Fallback:** rely on Front Door's automatic probe failover for step 2. For DNS, use either of these, keeping a list to undo after failback: (a) a temporary hosts-file entry on the East US hosts you control (the restored jump host) mapping the Azure Monitor FQDNs (the four zones' records, §4 step 8) and `<st>.blob.core.windows.net` to the East US endpoints' IPs; or (b) a conditional forwarder for those names on the DNS server that the East US firewall's DNS proxy forwards to. Azure Firewall's proxy only forwards, so this needs a DNS server or Private Resolver set in the firewall policy. Or create the A records by hand (`az network private-dns record-set a add-record`) as soon as the resource group accepts writes. App Service telemetry may be lost until then |
| **Private link after the workspace switchover.** Private links are "Supported", but the docs do not say whether the secondary needs its own pre-provisioned AMPLS path | §4 step 8 shows no East US telemetry although DNS resolves to East US | **Fallback:** check the scope still lists the workspace (`az monitor private-link-scope scoped-resource list`). Wait 30 minutes for the switchover. If nothing arrives, accept a telemetry gap. Logs ingested in West US 3 before the outage are in the replica, and App Insights is per region (`ADR-021`) |
| **Bastion deploy time against the RTO.** Bastion often takes 10 minutes or more | §4 step 5 still running near T0 + 45 minutes | **Fallback:** Bastion is not on the user-facing path. Let it finish; the RTO is measured at §4 step 8 on Front Door and storage |
| **Storage failover duration.** Unplanned failover "typically takes about an hour" | Writes fail past T0 + 1 h | **Fallback:** serve reads from the secondary (`ADR-020`), record the measured write RTO, and revisit the RTO with the owner |
| **Object replication and an unplanned failover.** The OR overview says customer-managed failover isn't supported for accounts in an OR policy; the DR guidance table lists OR as supported for unplanned | §4 step 3 refused, naming object replication | **Fallback:** delete the OR policy (§5.2 step 1 commands), retry the failover; blob backup resumes after failback |
| **Records restored after failback.** Whether a zone-group re-PUT restores records that a second endpoint overwrote | §5.2 step 6 resolves to no address or to East US | **Fallback:** delete and re-create `ampls-defenstack-prod-pe`'s zone group (§5.2 step 6), then dispatch the pipeline |
| **The blob record after failback.** The East US endpoint's zone group overwrote the account's A record in the shared blob zone (`<st>.privatelink.blob.core.windows.net`). §5.2 step 3 deletes that endpoint, and only the next pipeline deploy's re-PUT of `<st>-pe`'s zone group restores the West US 3 record. Whether that re-PUT rewrites a record another zone group overwrote is unverified | The §5.2 step 4 check (`az network private-dns record-set a show … -z privatelink.blob.core.windows.net -n $st`) finds no record set or an East US address; West US 3 blob calls fail with `AuthorizationFailure`, since public access is disabled | **Fallback:** delete `<st>-pe`'s zone group (`az network private-endpoint dns-zone-group delete -g rg-defenstack-prod-wus3 --endpoint-name "$st-pe" -n default`) and dispatch the prod pipeline again, which re-creates it with its record. If the pipeline cannot run, add the record by hand (`az network private-dns record-set a add-record -g rg-defenstack-prod-global -z privatelink.blob.core.windows.net -n $st -a $peIp`) and let the next deploy take it over. `ScopeLocked`: the zone-lock row in the table above |
| **The blob endpoint during the storage failover.** §4 step 5 may run while the account's unplanned failover (§4 step 3) is still in progress. Whether the storage provider accepts a new private endpoint connection then is not documented | `failover.bicep` fails only on `failover-storage-private-endpoint-eus`, or `<st>-eus-pe` stays `Pending` | **Fallback:** once `az storage account show -g rg-defenstack-prod-wus3 -n $st --query primaryLocation` reports `eastus`, re-run §4 step 5 (incremental: the other modules are unchanged). Approve a `Pending` connection with `az network private-endpoint-connection approve --id <connection id>` |
| **Planned failback after an unplanned failover** leaves `Standard_RAGRS` | §5.2 step 3 output | **Fallback:** runbook 05 §4 step 4 conversion to `Standard_RAGZRS` |
| **Policy re-PUT.** A redeploy sends an identical body for `vm-daily-enhanced` and `blob-daily-vaulted`; "updating an existing policy" is not supported | A redeploy fails on a policy with an update error | **Fallback:** expected to be idempotent; if not, rename the policy (§8, changing a backup policy) |
| **Change feed retention.** `storage.bicep` re-asserts change feed with 14-day retention on every deploy | Backup jobs fail after a deploy, naming change feed | **Fallback:** remove `retentionInDays` (unlimited) from `storage.bicep` and record it in `ADR-031` |
| **End-to-end alert routing** through `apr-defenstack-<env>-backup` | No email for a failed test job (§5.3 step 5) | **Fallback:** check the alert's `monitorService` and target resource group in the portal, and widen the rule's scope to the vault IDs if the alert targets something outside the regional resource groups |
