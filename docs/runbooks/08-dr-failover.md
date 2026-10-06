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
| **RTO** (users served again) | **1 hour** from the declaration, for **read serving**. **Writes: expected around 75–90 minutes**, measured in every drill | **Reads (1 hour):** Front Door already has the East US origin at priority 2 and probes every 30 s with 4 samples, so it moves traffic on its own within minutes. §4 step 3 disables the West US 3 origin so nothing flaps back. The East US app is already running and reads the primary container through the RA-GZRS secondary endpoint (`ADR-020`) **until the storage failover completes**. `failover.bicep` (§4 step 5) scales the plan to 3 instances in minutes. **Writes (about 75–90 minutes):** they return only when the storage failover completes, through the East US blob endpoint from `failover.bicep` and the DR write grant (§4 step 6). Microsoft says unplanned failover "typically takes about an hour" ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)), and §4 step 2 starts it about 10 minutes after T0, once the object replication policy is removed. Record the write RTO (T0 to the first successful write in §4 step 8) separately from the read RTO |
| **RPO** (data lost) | **15 minutes** | Application blobs replicate asynchronously to East US. Microsoft says "You can expect the replication lag to be less than 15 minutes, but this time is an estimate and not guaranteed" ([Blob Storage reliability](https://learn.microsoft.com/azure/reliability/reliability-storage-blob#resilience-to-region-wide-failures)). §4 step 2 reads the **Last Sync Time** before failing over and records the gap. Change feed and object replication on this account rule out the Geo priority replication SLA (`ADR-031`), so 15 minutes stays an expectation. Logs replicate through workspace replication. Key Vault secrets come from the pipeline into each regional vault (`ADR-019`), so they have no RPO |
| Backups (not the RTO/RPO path) | daily | VM backup of the jump host: daily, cross-region restore to East US, whose secondary RPO "can be up to 36 hours" ([restore VMs](https://learn.microsoft.com/azure/backup/backup-azure-arm-restore-vms#cross-region-restore)). Blob vaulted backup of `def-blob`: daily, kept 30 days, restore to another account, **no cross-region restore** (`ADR-031`) |

**Owner decision pending: confirm the write RTO.** The 1-hour target holds for reads only. Writes depend on the unplanned storage failover, which Microsoft expects to take about an hour, so the write RTO is expected around 75–90 minutes from T0. The platform owner should confirm whether that is acceptable, or change the target; record the decision here and in `ADR-032`.

**The read path changes when the storage failover completes.** The account is then LRS in East US and "no longer geo-redundant" ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)), so it has **no secondary endpoint**: reads through `<st>-secondary.blob.core.windows.net` (and the standby's `<st>-secondary-pe`) stop. From then on the app must use the **primary hostname** `<st>.blob.core.windows.net`, which resolves to `<st>-eus-pe`. The app has no storage settings yet (`ADR-006`), so app teams must use the primary hostname, with the secondary only as a read fallback (`ADR-032`).

**What the pipeline deploys (Phase 8):**

| Resource | Where | Settings |
|---|---|---|
| Recovery Services vault `rsv-defenstack-<env>-<region>` | Every stamp | RS0/Standard, system identity, public access `Enabled` with no private endpoint, because cross-region restore fails when public access is denied ([Azure Backup FAQ](https://learn.microsoft.com/azure/backup/backup-azure-backup-faq), `ADR-033`); storage `GeoRedundant` + cross-region restore; soft delete `Enabled` 14 days; immutability `Unlocked` (`ADR-030`); Azure Monitor job-failure alerts on, classic alerts off; diagnostics to the workspace (resource-specific); prod `CanNotDelete` lock |
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

  Contributor includes the `privateEndpointConnectionsApproval/action` permission on the target resources (`Microsoft.Storage/storageAccounts/…` and `Microsoft.Insights/privateLinkScopes/…`), which is why the East US endpoints auto-approve ([private endpoint approval](https://learn.microsoft.com/azure/private-link/private-endpoint-overview#access-to-a-private-link-resource-using-approval-workflow)); a narrower operator role must include it, or the endpoints stay `Pending`.

  §4 step 6 (the DR write grant), §4 step 8 (the verification VM's login role) and §5.2 step 3 (removing the grant) also need **Role Based Access Control Administrator** or **User Access Administrator**. Restores (§5.4) need **Backup Contributor** on the vaults. Activate the roles with a justification that names the incident.
- **Who declares:** the platform owner, or the on-call lead when the owner cannot be reached within 15 minutes. Both are named in the incident channel. Declare when Service Health (`alert-defenstack-prod-service-health`) or Front Door origin health (`front-door-origin-health`) confirms a West US 3 regional problem, and Microsoft gives no recovery time inside the RTO.
- **Steady-state preconditions.** Check them each quarter in the drill:
  - Workspace replication `Succeeded` for **at least 24 hours**. Microsoft: "wait at least 24 hours after enabling workspace replication… Azure Monitor rejects earlier switchover requests" ([workspace replication](https://learn.microsoft.com/azure/azure-monitor/logs/workspace-replication#switch-over-to-your-secondary-workspace)). `main.bicep` turns replication on with the secondary stamp, so this holds from a day after the first prod deploy.
  - The East US stamp is deployed (`deploySecondaryRegion = true`).
  - The Front Door East US origin reports its private link `Approved` (runbook 04).
  - The recovery points exist (§6).
  - **The prod primary account's name and ID are recorded** in the incident template, so §4 step 1 needs no lookup in West US 3. Record them in steady state, and check them each quarter:

    ```powershell
    $st = az storage account list -g rg-defenstack-prod-wus3 --query "[?starts_with(name,'stwus3')].name | [0]" -o tsv
    $stId = az storage account show -g rg-defenstack-prod-wus3 -n $st --query id -o tsv
    "$st  $stId"
    ```
- **Tools:**
  - Azure CLI 2.90+ with the `storage-preview` extension (`az extension add -n storage-preview`) for `--failover-type`, and the `dataprotection` extension;
  - Bicep CLI 0.47.16;
  - PowerShell 7 or 5.1;
  - `gh`, for the pipeline freeze.
- **Network path:** none for the control-plane steps. Data-plane checks (§4 step 8) run from inside the East US network: a **temporary verification VM** that §4 step 8 creates in the East US spoke's `management` subnet, reached through the East US Bastion. `enableVirtualMachine` is `false` in both environments, so there is no jump host to restore.

### Pre-production validation (owner, sandbox only)

Microsoft's storage docs contradict each other on object replication and an unplanned failover: the object replication overview says "Customer-managed failover isn't supported for either the source or the destination account in an object replication policy" ([object replication](https://learn.microsoft.com/azure/storage/blobs/object-replication-overview#prerequisites-and-caveats-for-object-replication)), while the disaster recovery guidance table lists object replication as "Supported" for unplanned failover ([disaster recovery guidance](https://learn.microsoft.com/azure/storage/common/storage-disaster-recovery-guidance#plan-for-failover)). §4 step 2 therefore removes the policy before failing over. To learn which reading is true, **the platform owner should run this test once, in a sandbox subscription, never in prod**, and record the result in `ADR-031` ("Pre-production validation"). It is an operator activity; nothing in this repository runs it.

```powershell
az account set --subscription <sandbox subscription id>
az group create -n rg-dr-or-test -l westus3
az storage account create -g rg-dr-or-test -n <srcaccount> -l westus3 --kind StorageV2 --sku Standard_GRS --allow-blob-public-access false
az storage account create -g rg-dr-or-test -n <dstaccount> -l westus3 --kind StorageV2 --sku Standard_LRS --allow-blob-public-access false
az storage account blob-service-properties update -g rg-dr-or-test --account-name <srcaccount> --enable-versioning true --enable-change-feed true
az storage account blob-service-properties update -g rg-dr-or-test --account-name <dstaccount> --enable-versioning true
az storage container create --account-name <srcaccount> -n src --auth-mode login
az storage container create --account-name <dstaccount> -n dst --auth-mode login
az storage account or-policy create -g rg-dr-or-test --account-name <dstaccount> --source-account <srcaccount> --destination-account <dstaccount> --source-container src --destination-container dst --min-creation-time '2026-01-01T00:00:00Z'
$policyId = az storage account or-policy list -g rg-dr-or-test --account-name <dstaccount> --query "[0].policyId" -o tsv
az storage account or-policy show -g rg-dr-or-test --account-name <dstaccount> --policy-id $policyId | az storage account or-policy create -g rg-dr-or-test --account-name <srcaccount> --policy "@-"
az storage account show -g rg-dr-or-test -n <srcaccount> --expand geoReplicationStats --query "geoReplicationStats.{status:status, canFailover:canFailover}" -o json
az storage account failover -g rg-dr-or-test -n <srcaccount> --failover-type Unplanned --yes
az group delete -n rg-dr-or-test --yes --no-wait
```

The policy commands follow [configure object replication](https://learn.microsoft.com/azure/storage/blobs/object-replication-configure#configure-object-replication-with-access-to-both-storage-accounts). Wait until `canFailover` is `true` before the failover. Record whether the failover was accepted, and the exact error text if it was refused. If it is accepted with the policy in place, §4 step 2 may keep the policy in a later change; until then, keep removing it.

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

1. **Declare the outage** (§2, "Who declares"). Post T0 and "DR failover started, pipeline frozen" in the incident channel; the freeze applies from now (§5.1), and step 3 disables the workflow. Activate the §2 roles through PIM, then set the account name and ID recorded in steady state (§2, steady-state preconditions), so nothing here waits on West US 3:

   ```powershell
   az login
   az account set --subscription <subscription id>
   $st = '<recorded prod primary account name, stwus3…>'
   $stId = "/subscriptions/<subscription id>/resourceGroups/rg-defenstack-prod-wus3/providers/Microsoft.Storage/storageAccounts/$st"
   ```

2. **Storage: fail the primary account over to East US (unplanned).** Start it first: it is the longest step, and writes wait for it (§1).
   1. **Remove the object replication policy.** Microsoft's docs contradict each other on object replication and an unplanned failover (§2, "Pre-production validation"), so take the sequence the blob backup support matrix documents for a failover: "pause the backup, remove the object replication policy at the storage account level, complete the failover, and then resume the backup" ([support matrix](https://learn.microsoft.com/azure/backup/blob-backup-support-matrix)):

      ```powershell
      az dataprotection backup-instance suspend-backup -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $st
      az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st --query "[].policyId" -o tsv
      az storage account or-policy delete -g rg-defenstack-prod-wus3 --account-name $st --policy-id <policyId>
      ```

      These are control-plane calls on the West US 3 vault and account, like the failover call itself, so they depend on the same ARM rerouting (§9, the global resource group row). If the suspend fails, still delete the policy. If the policy delete fails too, go on with the failover and record the result (§9, "Object replication and an unplanned failover"). Suspending keeps the existing recovery points. Resuming after failback re-creates the policy and starts a **full** re-backup: "If you suspend and resume protection or delete the Object Replication policy on the source storage account, the policy triggers a full backup" (same source).
   2. **Read the Last Sync Time, then fail over.** Everything written after the Last Sync Time may be lost, which is the measured RPO:

      ```powershell
      az storage account show -g rg-defenstack-prod-wus3 -n $st --expand geoReplicationStats --query "{sku:sku.name, primary:primaryLocation, lastSync:geoReplicationStats.lastSyncTime, status:geoReplicationStats.status}" -o json
      az storage account failover -g rg-defenstack-prod-wus3 -n $st --failover-type Unplanned --yes --no-wait
      ```

   Record `lastSync`, T0 − `lastSync`, and the time the failover started (expected about T0 + 10 minutes). Change feed and point-in-time restore do **not** block an **unplanned** failover; they block only a planned one ([disaster recovery guidance](https://learn.microsoft.com/azure/storage/common/storage-disaster-recovery-guidance#plan-for-failover)). The account's private endpoints follow the new primary on their own ([storage private endpoints](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints#creating-a-private-endpoint)). However, the West US 3 primary endpoint is unreachable while its region is down, so step 5 adds an East US endpoint. Continue with step 3 while this runs. Poll:

   ```powershell
   az storage account show -g rg-defenstack-prod-wus3 -n $st --query "{sku:sku.name, primary:primaryLocation, failoverInProgress:failoverInProgress}" -o json
   ```

   Expected when done: `primary` `eastus` and `sku` `Standard_LRS`. **An unplanned failover leaves the account LRS in East US** ("After the failover, your storage account type is automatically converted to locally redundant storage (LRS)", [initiate a failover](https://learn.microsoft.com/azure/storage/common/storage-initiate-account-failover)). **From then on there is no secondary endpoint**, so the `-secondary` read path ends and the app must use the primary hostname `<st>.blob.core.windows.net` (§1). When West US 3 is healthy again, re-enable geo-redundancy. The effective redundancy is RA-GRS until failback, because the current primary is LRS ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)):

   ```powershell
   az storage account update -g rg-defenstack-prod-wus3 -n $st --sku Standard_RAGRS
   ```

   Point-in-time restore cannot go back before the failover ([PITR interactions](https://learn.microsoft.com/azure/storage/blobs/point-in-time-restore-overview#feature-interactions)).

3. **Freeze the pipeline and disable the West US 3 Front Door origin.** Freeze first (§5.1):

   ```powershell
   gh workflow disable deploy --repo Godson90/bicep
   ```

   Then disable the West US 3 origin, so no traffic goes there even if its probes flap. A disabled origin is excluded first, before health probes are evaluated ([Front Door health probes](https://learn.microsoft.com/azure/frontdoor/health-probes#how-front-door-determines-origin-health)). Front Door's probes have usually moved traffic to `app-eus` already (§1).

   ```powershell
   az afd origin update -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --origin-group-name app --origin-name app-wus3 --enabled-state Disabled
   az afd origin list -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --origin-group-name app --query "[].{origin:name, enabled:enabledState, priority:priority}" -o table
   ```

   Check: `app-wus3` is `Disabled` and `app-eus` is `Enabled`. If the update fails because ARM cannot reach the global resource group, go on: Front Door's probes already route to `app-eus` (§9, live-only risks).

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

8. **Verify**, and record T(verify) − T0 as the measured RTO: the read RTO at the Front Door check, the write RTO at the first successful write:
   - **Front Door 200 from East US:**

     ```powershell
     $endpoint = az afd endpoint show -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --endpoint-name fde-defenstack-prod --query hostName -o tsv
     (Invoke-WebRequest -Uri "https://$endpoint/" -Method Head -UseBasicParsing).StatusCode
     $afdId = az afd profile show -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --query id -o tsv
     az monitor metrics list --resource $afdId --metric OriginHealthPercentage --dimension Origin --interval PT5M --query "value[0].timeseries[].{origin:metadatavalues[0].value, health:data[-1].average}" -o table
     ```

     Expected: `200`; `app-eus` healthy (100). Also add your custom domain if it is in use.
   - **Create the temporary verification VM** (drills and real incidents). There is no jump host to restore (`enableVirtualMachine` is `false` in both environments), so the in-network checks below need a host in East US. It is a **manual, dated, temporary** resource: post its name and creation time in the incident channel, and delete it at failback (§5.2 step 7) or in the drill clean-up (§5.3). It follows `modules/virtualMachine.bicep`: Ubuntu 22.04 Gen2 (`Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest`), `Standard_B2s`, Trusted Launch, zone 1, Premium SSD, a system-assigned identity and the Entra login extension `AADSSHLoginForLinux`. It goes in `rg-defenstack-prod-eus`, in the East US spoke's `management` subnet, with **no public IP** and no NIC NSG (the subnet NSG applies), and is reached only through `bas-defenstack-prod-eus`:

     ```powershell
     $drVm = 'vmeusdrcheck'
     az vm create -g rg-defenstack-prod-eus -n $drVm --location eastus --zone 1 --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest --size Standard_B2s --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true --storage-sku Premium_LRS --vnet-name vnet-defenstack-prod-eus-spoke --subnet management --public-ip-address '""' --nsg '""' --assign-identity '[system]' --admin-username azureadmin --generate-ssh-keys --os-disk-delete-option Delete --nic-delete-option Delete --tags purpose=dr-verification created=$(Get-Date -Format yyyy-MM-dd) deleteAt=failback
     az vm extension set -g rg-defenstack-prod-eus --vm-name $drVm --publisher Microsoft.Azure.ActiveDirectory --name AADSSHLoginForLinux
     $drVmId = az vm show -g rg-defenstack-prod-eus -n $drVm --query id -o tsv
     az role assignment create --assignee-object-id <admin group object ID> --assignee-principal-type Group --role "Virtual Machine Administrator Login" --scope $drVmId
     az network bastion ssh --name bas-defenstack-prod-eus --resource-group rg-defenstack-prod-eus --target-resource-id $drVmId --auth-type AAD
     ```

     - `'""'` passes an empty value through Windows PowerShell 5.1; in PowerShell 7.3 or later, write `""`. Both mean "none": no public IP and no NIC NSG. The role assignment needs the PIM-activated RBAC role (§2). The local SSH key is a break-glass only; Entra login is the normal path ([Entra login for Linux](https://learn.microsoft.com/entra/identity/devices/howto-vm-sign-in-azure-ad-linux)).
     - **Phase 7 policies.** The VM has no public IP, so the public IP allowlist (`defenstack-deny-public-ip-except-allowlist`) does not apply; East US is an allowed location. The other deny assignments cover Storage, Key Vault and App Service public access only, so the VM and its NIC are not denied (runbook 07). Defender for Servers may list it; it is deleted at failback.
     - The extension reaches `packages.microsoft.com` through the East US firewall's `platform-egress` rules for the `management` subnet. If it fails, check `AZFWApplicationRule` for denies (runbook 03 §9).
   - **Telemetry.** On the verification VM, check that the Azure Monitor names resolve to East US endpoint IPs (`10.10.1.x`):

     ```bash
     nslookup api.monitor.azure.com
     nslookup <st>.blob.core.windows.net
     ```

     Then check that data arrives. Run the query from the operator's machine as well; it needs the workspace's customer ID (`az monitor log-analytics workspace show -g rg-defenstack-prod-global -n log-defenstack-prod --query customerId -o tsv`). Queries are `PrivateOnly` (`ADR-022`), so a query from outside the network is refused, and that refusal is itself expected:

     ```powershell
     az monitor log-analytics query -w <workspace customer ID> --analytics-query "AppRequests | where TimeGenerated > ago(15m) | summarize count() by AppRoleName" -o table
     ```

     Expected: rows for the East US app when run from inside the network (for example from the verification VM after `az login --use-device-code`).
   - **Storage writes:** on the verification VM, `<st>.blob.core.windows.net` resolves to a `10.10.1.x` address (`<st>-eus-pe`). Then, signed in as an operator who holds a data role on `def-blob` (Contributor has no data actions):

     ```bash
     az storage blob upload --account-name <st> --container-name def-blob --name "dr-check-$(date +%Y%m%d%H%M).txt" --data "failover check" --auth-mode login
     ```

     It succeeds.
   - **App-level write check** (the fallback when no operator has a data role, and the real proof): the app's own write path succeeds in `AppRequests`. Run it where the query is allowed (above):

     ```powershell
     az monitor log-analytics query -w <workspace customer ID> --analytics-query "AppRequests | where TimeGenerated > ago(15m) | where Name matches regex '^(POST|PUT|PATCH|DELETE) ' | summarize total=count(), failed=countif(Success == false) by AppRoleName, Name" -o table
     ```

     Expected: the East US app's write operations with `failed` at 0, or falling to 0 once the storage failover completes. The first successful write is the write RTO.

## 5. Manual and post-deployment steps

### 5.1 Pipeline freeze during DR

**From §4 step 1 until §5.2 step 9, the pipeline does not deploy prod or dev** (`ADR-032`). Disable the workflow (§4 step 3, minutes after the declaration, once the storage failover has started), and tell the team not to merge to `main`. Three reasons:
- A run of `main.bicep` deploys the West US 3 stamp first, and fails there.
- If it got further, it would scale East US back to 1 instance, re-enable `app-wus3`, try to reset the failed-over storage account to `westus3` and `Standard_RAGZRS`, and rewrite the Azure Monitor records to the dead West US 3 endpoint.
- `failover.bicep` itself is never in the pipeline.

During the freeze:
- Make urgent changes by hand in East US only.
- Write each one down, and back-port it to Bicep after failback.
- Do not run `governance.bicep` either: its flow-log exemptions target the West US 3 resource group.

### 5.2 Failback (planned)

Start only after Microsoft reports West US 3 healthy and the West US 3 stamp's resources show healthy (`az resource list -g rg-defenstack-prod-wus3 --query "[?provisioningState!='Succeeded'].name"` is empty).

Before step 1, re-enable geo-redundancy (§4 step 2) if you have not already. Then wait for the initial sync, until `geoReplicationStats.status` is `Live`. A planned failover needs it, and it "might take a significant amount of time" ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)).

1. **Check that blob backup is suspended and that no object replication policy exists.** §4 step 2 suspended the backup instance and deleted the policy before the unplanned failover; nothing re-creates it while backup stays suspended. A planned failover is refused while an OR policy exists ([failover FAQ](https://learn.microsoft.com/azure/storage/common/storage-failover-faq#what-are-the-conflicting-features-or-scenarios-for-failovers)). If §4 step 2 could not remove it, or backup was resumed during DR, do it now:

   ```powershell
   az dataprotection backup-instance show -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $st --query "properties.currentProtectionState" -o tsv
   az dataprotection backup-instance suspend-backup -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $st
   az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st --query "[].policyId" -o tsv
   az storage account or-policy delete -g rg-defenstack-prod-wus3 --account-name $st --policy-id <policyId>
   ```

   Run the suspend only if the state is not already `BackupsSuspended`, and the delete only if the list is not empty. Suspending keeps the existing recovery points (immutability and soft delete still apply, `ADR-030`).
2. **Disable point-in-time restore and change feed.** Both block a planned failover:

   ```powershell
   az storage account blob-service-properties update -g rg-defenstack-prod-wus3 --account-name $st --enable-restore-policy false --enable-change-feed false
   ```

   Versioning and soft delete stay on.
3. **Run the planned failover back to West US 3, convert the account back to RA-GZRS, then remove the East US blob endpoint.** Do the sub-steps in this order:
   1. **Planned failover.** No data loss is expected: replication completes before the switch ([planned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-planned)):

      ```powershell
      az storage account failover -g rg-defenstack-prod-wus3 -n $st --failover-type Planned --yes
      az storage account show -g rg-defenstack-prod-wus3 -n $st --query "{sku:sku.name, primary:primaryLocation}" -o json
      ```

      Expected: `primary` `westus3`. A planned failover keeps the redundancy, so the account is `Standard_RAGRS`.
   2. **Precondition for deleting `<st>-eus-pe`: the account is `Standard_RAGZRS` again.** Run the zone conversion with runbook 05 §4 step 4 and wait until `az storage account migration show` reports `Complete`. Do it now, before step 4: the pipeline's storage PUT with `Standard_RAGZRS` fails until the conversion is done (runbook 05 §9, the row "Prod **Deploy** fails at the storage account update with an error about changing to `Standard_RAGZRS`"), and until that pipeline run succeeds nothing restores the West US 3 record. The conversion can take hours to days; the account stays usable, and the app keeps writing through `<st>-eus-pe` meanwhile. Check:

      ```powershell
      az storage account show -g rg-defenstack-prod-wus3 -n $st --query sku.name -o tsv
      az storage account migration show -g rg-defenstack-prod-wus3 --account-name $st --migration-name default --query "{status: properties.migrationStatus || migrationStatus}" -o json
      ```

      Go on only when the SKU is `Standard_RAGZRS` or the status is `Complete`. Backup stays suspended and point-in-time restore stays off until step 4; versioning and soft delete still protect the data.
   3. **Lift the prod `CanNotDelete` locks on the five shared zones** (the four Azure Monitor zones and the blob zone). Prod always has them (`enableDeleteLock`, runbook 01 §9), so deleting an endpoint whose zone group holds records there fails with `ScopeLocked` otherwise. The step 4 pipeline run restores them:

      ```powershell
      $zoneLocks = az lock list -g rg-defenstack-prod-global --query "[?name=='blob-zone-lck' || name=='monitor-zone-lck' || name=='oms-zone-lck' || name=='ods-zone-lck' || name=='agentsvc-zone-lck'].id" -o tsv
      $zoneLocks | ForEach-Object { az lock delete --ids $_ }
      ```

      Expected: five lock IDs, then none listed.
   4. **Remove the DR write grant and the East US blob endpoint, then re-add the West US 3 record at once.** Deleting the endpoint removes its record from the shared blob zone, so add the West US 3 address back by hand straight away; the blob path then resolves to `<st>-pe` without waiting for the pipeline, whose re-PUT of `<st>-pe`'s zone group takes the record over in step 4:

      ```powershell
      $eusApp = az webapp list -g rg-defenstack-prod-eus --query "[0].id" -o tsv
      $eusPrincipal = az webapp identity show --ids $eusApp --query principalId -o tsv
      az role assignment delete --assignee $eusPrincipal --role "Storage Blob Data Contributor" --scope "$stId/blobServices/default/containers/def-blob"
      az network private-endpoint delete -g rg-defenstack-prod-eus -n "$st-eus-pe"
      $nicId = az network private-endpoint show -g rg-defenstack-prod-wus3 -n "$st-pe" --query "networkInterfaces[0].id" -o tsv
      $peIp = az network nic show --ids $nicId --query "ipConfigurations[0].privateIPAddress" -o tsv
      az network private-dns record-set a add-record -g rg-defenstack-prod-global -z privatelink.blob.core.windows.net -n $st -a $peIp
      ```

      `add-record` creates the record set if the delete removed it. Expect a short window of blob errors between the delete and the add.
4. **Resume blob backup, then re-enable the features through the pipeline.** Resume before the pipeline runs, so its re-PUT meets a protected instance rather than a suspended one (what a re-PUT does to a suspended instance is not documented, §9). Object replication needs change feed, which step 2 turned off, so turn it and point-in-time restore back on first, with the values `storage.bicep` sets (14 and 13 days):

   ```powershell
   az storage account blob-service-properties update -g rg-defenstack-prod-wus3 --account-name $st --enable-change-feed true --change-feed-days 14 --enable-restore-policy true --restore-days 13
   az dataprotection backup-instance resume-protection -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $st
   ```

   Resuming re-creates the object replication policy in the next backup cycle and starts a **full** re-backup: "If you suspend and resume protection or delete the Object Replication policy on the source storage account, the policy triggers a full backup" ([support matrix](https://learn.microsoft.com/azure/backup/blob-backup-support-matrix)). Expect the first backup to take longer.

   Then enable the workflow and dispatch **prod** only (two approvals, `ADR-012`). Merges stay frozen until step 9.

   ```powershell
   gh workflow enable deploy --repo Godson90/bicep
   gh workflow run deploy --repo Godson90/bicep -f environment=prod
   ```

   Check the what-if: no SKU change on the primary account (step 3.2), no change to `restorePolicy` or `changeFeed`, and `asp-defenstack-prod-eus` back to 1 instance. The run also sets `app-wus3` back to `Enabled`, re-creates the zone locks, re-PUTs `<st>-pe`'s zone group (taking over the hand-added record) and rewrites `ampls-defenstack-prod-pe`'s zone group (step 6 checks the records). After the next scheduled backup, check the policy and the instance:

   ```powershell
   az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st --query "[].policyId" -o tsv
   az dataprotection backup-instance show -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --backup-instance-name $st --query "properties.protectionStatus.status" -o tsv
   ```

   Expected: one policy, and `ProtectionConfigured`.

   **Check the blob record (§9, live-only).** The account's A record in the shared blob zone must hold `<st>-pe`'s West US 3 address:

   ```powershell
   az network private-dns record-set a show -g rg-defenstack-prod-global -z privatelink.blob.core.windows.net -n $st --query "aRecords[].ipv4Address" -o tsv
   ```

   Expected: exactly `$peIp` (a `10.0.1.x` address, step 3.4). A missing record set, or an East US (`10.10.1.x`) address: §9, "The blob record after failback".
5. **Workspace failback.** First confirm that the primary workspace is healthy and has ingested the switchover period:

   ```powershell
   az monitor log-analytics workspace failback -g rg-defenstack-prod-global --workspace-name log-defenstack-prod
   ```

6. **Delete the East US AMPLS endpoint, then restore the West US 3 records.** The step 4 run restored the zone locks, so lift the same five again (step 3.3 commands) first, or the delete fails with `ScopeLocked`:

   ```powershell
   az network private-endpoint delete -g rg-defenstack-prod-eus -n ampls-defenstack-prod-eus-pe
   az network private-dns record-set a list -g rg-defenstack-prod-global -z privatelink.monitor.azure.com --query "[].{name:name, ip:aRecords[0].ipv4Address}" -o table
   ```

   Expected: every record holds a West US 3 (`10.0.1.x`) address; check the `oms`, `ods` and `agentsvc` zones the same way. **If records are missing**, add them back by hand at once from the West US 3 endpoint's own list (each FQDN's first label is the record name in its zone):

   ```powershell
   az network private-endpoint show -g rg-defenstack-prod-wus3 -n ampls-defenstack-prod-pe --query "customDnsConfigs[].{fqdn:fqdn, ip:ipAddresses[0]}" -o table
   az network private-dns record-set a add-record -g rg-defenstack-prod-global -z <zone> -n <record name> -a <ip>
   ```

   Then dispatch the prod pipeline again (step 4 commands): it re-PUTs `ampls-defenstack-prod-pe`'s zone group, taking the records over, and re-creates the locks. If the records are still wrong after that, delete that zone group (`az network private-endpoint dns-zone-group delete -g rg-defenstack-prod-wus3 --endpoint-name ampls-defenstack-prod-pe -n default`) and dispatch once more.
7. **Scale East US back down, and remove the East US Bastion and the verification VM.** The step 4 pipeline run already set the plan to 1 instance. Confirm it, then delete the temporary verification VM (§4 step 8, with its login role assignment), Bastion and its IP:

   ```powershell
   az appservice plan show -g rg-defenstack-prod-eus -n asp-defenstack-prod-eus --query "sku.capacity" -o tsv
   $drVmId = az vm show -g rg-defenstack-prod-eus -n vmeusdrcheck --query id -o tsv
   az role assignment delete --scope $drVmId
   az vm delete -g rg-defenstack-prod-eus -n vmeusdrcheck --yes
   az network bastion delete -g rg-defenstack-prod-eus -n bas-defenstack-prod-eus
   az network public-ip delete -g rg-defenstack-prod-eus -n pip-bas-defenstack-prod-eus
   ```

   The VM was created with its OS disk and NIC set to delete with it; check that `az resource list -g rg-defenstack-prod-eus --query "[?contains(name,'vmeusdrcheck')].name"` is empty. Also delete any VM restored into East US for the DR (and stop its protection, §8).
8. **Re-enable the Front Door West US 3 origin.** Step 4 normally did it already; check, and set it if needed:

   ```powershell
   az afd origin update -g rg-defenstack-prod-global --profile-name afd-defenstack-prod --origin-group-name app --origin-name app-wus3 --enabled-state Enabled
   ```

9. **Lift the freeze.** Post it in the incident channel and allow merges. Back-port every manual change from §5.1. Fill in the drill log row (§5.3).

### 5.3 Quarterly drill, drill log and irreversible hardening

**Drill procedure (once a quarter, in a change window).** The drill uses **planned** failovers only, so no data is lost:
1. Check the §2 preconditions and the §6 rows.
2. Run §4 steps 1 and 3–8, including the temporary verification VM (§4 step 8). For step 2, suspend backup and delete the object replication policy as §4 step 2.1 does, disable point-in-time restore and change feed (§5.2 step 2), then run `az storage account failover --failover-type Planned` to East US. Write throughput is unchanged and redundancy stays geo-redundant.
3. Measure the read RTO and the write RTO separately (T0 to the Front Door check, and T0 to the first successful write, §4 step 8) and the RPO (the Last Sync Time gap; expected 0 for a planned failover).
4. Fail back with §5.2.
5. Prove alert routing: trigger an on-demand backup of a stopped or missing item, or follow Microsoft's test-alert guidance. Check that `ALERT_EMAIL` receives an Azure Backup alert through `apr-defenstack-prod-backup` (§5.5).
6. Restore test (§5.4): one VM cross-region restore of the jump host's disks (when `enableVirtualMachine` is on) and one blob vaulted restore, both to scratch targets, then delete them.
7. Clean up: confirm the verification VM, its role assignment and the East US Bastion are gone (§5.2 step 7), and that the zone locks are back (`az lock list -g rg-defenstack-prod-global -o table`).

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
- File-level recovery **may now be possible**: the vaults keep public access enabled (`ADR-033`), so the documented failure for denied vaults no longer applies, but the recovery script must still reach the vault through the East US firewall. **Verify it** in the first drill and record the result; until then, restore disks.

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
| Vaults | `az backup vault list --query "[].{name:name, rg:resourceGroup, pna:properties.publicNetworkAccess}" -o table` | `rsv-defenstack-dev-wus3`, `-prod-wus3`, `-prod-eus`; `Enabled` (`ADR-033`: cross-region restore needs it) |
| Vault storage | `az backup vault backup-properties show -g rg-defenstack-prod-wus3 -n rsv-defenstack-prod-wus3 --query "[0].{type:storageModelType, crr:crossRegionRestoreFlag}" -o json` | `GeoRedundant`, `true` |
| Security settings | `az resource show --ids <rsv id> --query "properties.securitySettings.{softDelete:softDeleteSettings.softDeleteState, days:softDeleteSettings.softDeleteRetentionPeriodInDays, immutability:immutabilitySettings.state}" -o json` | `Enabled`, `14`, `Unlocked` (after §5.3 hardening: `AlwaysON`, `Locked`) |
| Jump host protected (with `enableVirtualMachine`) | `az backup item list -g rg-defenstack-<env>-wus3 --vault-name rsv-defenstack-<env>-wus3 --query "[].{item:properties.friendlyName, state:properties.protectionState, last:properties.lastBackupTime}" -o table` | `Protected` and a last backup within 24 hours |
| Secondary-region recovery points | §5.4 `recoverypoint list --use-secondary-region` | At least one point (from up to 48 hours after the first backup) |
| Blob backup | `az dataprotection backup-instance list -g rg-defenstack-prod-wus3 --vault-name bv-defenstack-prod-wus3 --query "[].{name:name, status:properties.protectionStatus.status}" -o table` | `ProtectionConfigured` |
| Object replication | `az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st -o table` | One policy, created by Azure Backup |
| Alert routing | `az monitor alert-processing-rule show -g rg-defenstack-prod-global -n apr-defenstack-prod-backup --query "{scopes:properties.scopes, enabled:properties.enabled}" -o json` | The two regional resource group IDs, `true` |
| Workspace replication | `az monitor log-analytics workspace show -g rg-defenstack-prod-global -n log-defenstack-prod --query "replication" -o json` | `enabled: true`, `location: eastus`, `provisioningState: Succeeded` |
| After failover | §4 step 8 | Front Door `200` from `app-eus`; East US telemetry and a storage write from the temporary verification VM; the app's write operations succeed in `AppRequests` |
| After failback: verification VM | `az vm list -g rg-defenstack-prod-eus --query "[?name=='vmeusdrcheck'].name" -o tsv` | Empty (§5.2 step 7) |
| After failback: blob record | §5.2 step 4, "Check the blob record" | Only `<st>-pe`'s West US 3 address; no `<st>-eus-pe` in `rg-defenstack-prod-eus` and no DR write grant on `def-blob` |

## 7. Rollback

- **Abandon a failover before the storage failover is submitted (§4 step 2.2).** If §4 step 2.1 already ran, resume blob backup (`az dataprotection backup-instance resume-protection`, §5.2 step 4), which re-creates the object replication policy and starts a full backup. Re-enable `app-wus3` (§5.2 step 8). Remove what `failover.bicep` created: the blob endpoint and any write grant (§5.2 step 3.4 commands, after lifting the zone locks in step 3.3), then §5.2 steps 6–7, including the verification VM. Lift the freeze.
- **After an unplanned storage failover there is no rollback, only failback (§5.2).** The West US 3 copy is deleted when the failover completes.
- **A wrong `failover.bicep` run:** redeploy with corrected parameters, or remove its resources by hand (§5.2 step 3 for the blob endpoint, steps 6–7). Deployments are incremental and remove nothing.
- **Backups (pipeline side):** revert the Phase 8 commit and remove resources by hand, in this order:
  1. Stop protection, keeping the data: `az backup protection disable … --delete-backup-data false` and `az dataprotection backup-instance stop-protection`. Stopping protection does **not** delete the object replication policy on the app account ([support matrix](https://learn.microsoft.com/azure/backup/blob-backup-support-matrix)), so delete it too: `az storage account or-policy list -g rg-defenstack-prod-wus3 --account-name $st --query "[].policyId" -o tsv`, then `az storage account or-policy delete -g rg-defenstack-prod-wus3 --account-name $st --policy-id <policyId>`.
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
| **Cross-region restore storage settings** (`ADR-033`). The vaults keep public access `Enabled` because "Without a private connection in the secondary region, CRR can't perform the required replication" ([Azure Backup FAQ](https://learn.microsoft.com/azure/backup/backup-azure-backup-faq)). The `vaultstorageconfig` PUT with `crossRegionRestoreFlag: true` is first exercised live, and so is its identical **re-PUT on every later deploy, after an item is protected**, when the storage setting is locked | A deploy fails on `vaultstorageconfig` (first deploy, or a later one once the jump host is protected), naming the storage type or cross-region restore | **Fallback:** first deploy: set it once by CLI (`az backup vault backup-properties set -g <rg> -n <rsv> --backup-storage-redundancy GeoRedundant --cross-region-restore-flag true`) and redeploy. A later re-PUT refused while locked: switch `storageConfig` in `recoveryServicesVault.bicep` to an `existing` reference after its first creation (deploy-once), with a test and an `ADR-033` note. Check the flag names with `--help` first |
| **Restore staging account.** Disk restore needs a staging account in East US, and the app accounts deny public access | `restore-disks` fails writing the VM config or template | **Fallback:** create a temporary `Standard_LRS` staging account in `rg-defenstack-prod-eus` with a dated policy waiver (runbook 07 §5.3 emergency path), restore, then delete both |
| **The global resource group lives in westus3** (runbook 01). The shared zones, the AMPLS, the workspace, Front Door and the action group are all there. Microsoft says ARM "automatically reroutes ARM control plane requests to a backup region" ([ARM overview](https://learn.microsoft.com/azure/azure-resource-manager/management/overview#which-location-should-i-use-for-my-resource-group)), but this is **unverified** here. The East US endpoints' zone group writes are the critical ones. Other West US 3–homed writes during DR: the East US Bastion's diagnostic setting `bastion-diagnostics` (its workspace is in the global resource group), the §4 step 6 role assignment (scoped to the account in `rg-defenstack-prod-wus3`), and the §4 step 2 calls on the West US 3 Backup vault and account | `failover.bicep` fails on `failover-monitor-private-endpoint-eus`, `failover-storage-private-endpoint-eus` or `failover-bastion-eus` (`ResourceGroupNotFound`, timeouts); §4 step 2, 3, 4 or 6 fails | **Fallback:** rely on Front Door's automatic probe failover for step 3. For DNS, use either of these, keeping a list to undo after failback: (a) a temporary hosts-file entry on the temporary verification VM (§4 step 8) mapping the Azure Monitor FQDNs (the four zones' records) and `<st>.blob.core.windows.net` to the East US endpoints' IPs; or (b) a conditional forwarder for those names on the DNS server that the East US firewall's DNS proxy forwards to. Azure Firewall's proxy only forwards, so this needs a DNS server or Private Resolver set in the firewall policy. Or create the A records by hand (`az network private-dns record-set a add-record`) as soon as the resource group accepts writes. App Service telemetry may be lost until then. If only the Bastion diagnostic setting fails, Bastion still works; re-run §4 step 5 later. If the step 6 grant fails, retry until ARM accepts it: writes from East US wait for it |
| **Private link after the workspace switchover.** Private links are "Supported", but the docs do not say whether the secondary needs its own pre-provisioned AMPLS path | §4 step 8 shows no East US telemetry although DNS resolves to East US | **Fallback:** check the scope still lists the workspace (`az monitor private-link-scope scoped-resource list`). Wait 30 minutes for the switchover. If nothing arrives, accept a telemetry gap. Logs ingested in West US 3 before the outage are in the replica, and App Insights is per region (`ADR-021`) |
| **Bastion deploy time against the RTO.** Bastion often takes 10 minutes or more | §4 step 5 still running near T0 + 45 minutes | **Fallback:** Bastion is not on the user-facing path. Let it finish; the RTO is measured at §4 step 8 on Front Door and storage |
| **Storage failover duration.** Unplanned failover "typically takes about an hour" ([unplanned failover](https://learn.microsoft.com/azure/storage/common/storage-failover-customer-managed-unplanned)), and §4 step 2 starts it about 10 minutes after T0, so the expected write RTO is 75–90 minutes (§1) | Writes still fail past T0 + 90 minutes | **Fallback:** serve reads from the secondary until the failover completes (`ADR-020`; the secondary endpoint ends with it), record the measured write RTO, and revisit the write RTO with the owner (§1) |
| **Object replication and an unplanned failover.** The OR overview says customer-managed failover isn't supported for accounts in an OR policy; the DR guidance table lists OR as supported for unplanned. §4 step 2.1 therefore suspends backup and deletes the policy first. Those calls go to the West US 3 Backup vault and account, so they depend on the same ARM rerouting as the failover call. The owner's sandbox test (§2, "Pre-production validation") settles which reading holds | §4 step 2.1 fails (the suspend or the policy delete), or §4 step 2.2 is refused, naming object replication | **Fallback:** if the suspend fails, still delete the policy. If the delete fails, submit the failover anyway (the DR guidance table says it is supported) and record the outcome in `ADR-031`. If the failover is refused, retry the policy delete until ARM accepts it, then retry the failover. Blob backup resumes after failback with a full re-backup (§5.2 step 4) |
| **Records restored after failback.** Whether a zone-group re-PUT restores records that a second endpoint overwrote | §5.2 step 6 resolves to no address or to East US | **Fallback:** delete and re-create `ampls-defenstack-prod-pe`'s zone group (§5.2 step 6), then dispatch the pipeline |
| **The blob record after failback.** The East US endpoint's zone group overwrote the account's A record in the shared blob zone (`<st>.privatelink.blob.core.windows.net`). §5.2 step 3.4 deletes that endpoint and re-adds the West US 3 record by hand at once; the next pipeline deploy's re-PUT of `<st>-pe`'s zone group then takes it over. Whether that re-PUT rewrites a record another zone group overwrote, or adopts a hand-added one, is unverified | The §5.2 step 4 check (`az network private-dns record-set a show … -z privatelink.blob.core.windows.net -n $st`) finds no record set or an East US address; West US 3 blob calls fail with `AuthorizationFailure`, since public access is disabled | **Fallback:** delete `<st>-pe`'s zone group (`az network private-endpoint dns-zone-group delete -g rg-defenstack-prod-wus3 --endpoint-name "$st-pe" -n default`) and dispatch the prod pipeline again, which re-creates it with its record. If the pipeline cannot run, add the record by hand again (`az network private-dns record-set a add-record -g rg-defenstack-prod-global -z privatelink.blob.core.windows.net -n $st -a $peIp`) and let the next deploy take it over. `ScopeLocked`: the zone-lock row in the table above |
| **The blob endpoint during the storage failover.** §4 step 5 may run while the account's unplanned failover (§4 step 2) is still in progress. Whether the storage provider accepts a new private endpoint connection then is not documented | `failover.bicep` fails only on `failover-storage-private-endpoint-eus`, or `<st>-eus-pe` stays `Pending` | **Fallback:** once `az storage account show -g rg-defenstack-prod-wus3 -n $st --query primaryLocation` reports `eastus`, re-run §4 step 5 (incremental: the other modules are unchanged). Approve a `Pending` connection with `az network private-endpoint-connection approve --id <connection id>` |
| **Planned failback after an unplanned failover** leaves `Standard_RAGRS` | §5.2 step 3.1 output | **Fallback:** none needed: §5.2 step 3.2 runs the runbook 05 §4 step 4 conversion to `Standard_RAGZRS` before the endpoint is deleted and the pipeline runs |
| **Resuming blob backup before the failback pipeline run** (§5.2 step 4). Resume needs change feed, which §5.2 step 2 turned off, so step 4 turns it back on by hand first. What the pipeline's re-PUT of the backup instance does to an instance that is still **suspended** is not documented | `resume-protection` fails; or the step 4 deploy fails on the backup instance, or leaves it `BackupsSuspended` | **Fallback:** if the resume fails, check change feed and versioning are on (`az storage account blob-service-properties show`) and retry. If it still fails, dispatch the pipeline anyway, then check the instance's `currentProtectionState`; resume it after the deploy. A resume always starts a full re-backup ([support matrix](https://learn.microsoft.com/azure/backup/blob-backup-support-matrix)) |
| **Policy re-PUT.** A redeploy sends an identical body for `vm-daily-enhanced` and `blob-daily-vaulted`; "updating an existing policy" is not supported | A redeploy fails on a policy with an update error | **Fallback: deploy once.** Expected to be idempotent. If ARM refuses an identical re-PUT, change the module so it creates the policy only on the first deploy and references it as `existing` afterwards (for example behind a parameter set after the first creation), with a test. Do not rename the policy to work around it: a new name is a new policy, and the item or instance would move to it (§8). Not implemented now |
| **Vaulted-only blob policy.** `blob-daily-vaulted` has a `VaultStore` backup rule and retention rule only, with no operational (`OperationalStore`) rule. Microsoft documents vaulted-only policies, but this shape is first exercised by the first prod deploy | The policy or the backup instance is refused, naming a missing operational datastore or rule | **Fallback:** switch to the documented combined operational and vaulted policy ([configure and manage](https://learn.microsoft.com/azure/backup/blob-backup-configure-manage)): add an `OperationalStore` retention rule to `blob-daily-vaulted` under a **new policy name** (`ADR-031`), with its test. Operational backup adds a Backup-owned delete lock on the account (`ADR-031`), so record the change there |
| **Change feed retention.** `storage.bicep` re-asserts change feed with 14-day retention on every deploy | Backup jobs fail after a deploy, naming change feed | **Fallback:** remove `retentionInDays` (unlimited) from `storage.bicep` and record it in `ADR-031` |
| **End-to-end alert routing** through `apr-defenstack-<env>-backup` | No email for a failed test job (§5.3 step 5) | **Fallback:** check the alert's `monitorService` and target resource group in the portal, and widen the rule's scope to the vault IDs if the alert targets something outside the regional resource groups |
