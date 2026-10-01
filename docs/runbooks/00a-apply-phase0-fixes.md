# 00a - Apply Phase 0 foundation fixes

> Owning modules: all files under `modules/` and `main.bicep`. Spec: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §2 (F1–F13).

## 1. Purpose and scope
Applies the Phase 0 defect fixes to the existing `defenStack` resource group (dev) **in place**. No resource is replaced. The fixes are listed per finding in §5–§7. Greenfield-only changes (zones, plan rename, subnet rename, subscription scope) are **not** part of this runbook; they arrive with Phase 1.

## 2. Prerequisites
- Azure CLI 2.90 or later: `az version`.
- Bicep CLI 0.47.16 or later: `bicep --version`.
- PowerShell 5.1 or 7.
- Operator role on `defenStack`: `Owner`, or `Contributor` plus `Role Based Access Control Administrator`. Role assignments are created and one is deleted in §5.
- F4 step 1 (`az keyvault secret set`) additionally needs the **Key Vault Secrets Officer** data-plane role scoped to the vault — the vault uses RBAC authorization, so `Owner` alone (a management-plane role) does not grant secret access:

  ```powershell
  az role assignment create `
    --assignee-object-id <operator-object-id> `
    --assignee-principal-type User `
    --role "Key Vault Secrets Officer" `
    --scope <key-vault-resource-id>
  ```
- Signed in to the correct subscription:

  ```powershell
  az login
  az account set --subscription <subscription-id>
  az account show --query "{subscription:id,tenant:tenantId}" -o table
  ```
- Only if deploying the VM: register host encryption once per subscription, then wait for `Registered`:

  ```powershell
  az feature register --namespace Microsoft.Compute --name EncryptionAtHost
  az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv
  az provider register --namespace Microsoft.Compute
  ```

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `managementSourceCidrs` | `[]` | `[]` until Phase 3 (then AzureBastionSubnet + P2S pool) | Only named admin sources may reach SSH/RDP; empty = deny all |
| `spokeVnetAddressSpace` | `['10.0.0.0/16']` | same | Single source for spoke VNet and firewall source ranges |
| `privateEndpointSubnetAddressPrefix` | `10.0.1.0/24` | same | Must stay inside `spokeVnetAddressSpace` |
| `appServiceIntegrationSubnetAddressPrefix` | `10.0.2.0/24` | same | Also an approved PE source |
| `virtualMachineSubnetAddressPrefix` | `10.0.3.0/24` | same | Also an approved PE source (jump host reaches Key Vault/Storage) |
| `additionalPrivateEndpointSourceCidrs` | `[]` | `[]` | Replaces removed `approvedPrivateEndpointSourceCidrs` |
| `threatIntelMode` (firewall module) | `Deny` | `Deny` (main passes `Alert` for dev/test) | Block known-malicious IPs/FQDNs in prod |
| `availabilityZones` (firewall module) | `[]` | `['1','2','3']` in Phase 1 greenfield | Zones cannot be added to an existing firewall/PIP in place |
| `enabledForTemplateDeployment` (Key Vault) | `false` (module) | `true` (composed stack) | Required for `az.getSecret()` Key Vault references |
| `blobSoftDeleteRetentionDays` (storage) | `14` | `14` or higher per data retention policy | Recovery window; PITR = value − 1 |
| `healthCheckPath` (App Service) | `/` | Application health endpoint, e.g. `/healthz` | Unhealthy instances are removed from rotation |
| `zoneRedundant` (App Service) | `false` | `true` in Phase 1 greenfield | Set at plan creation only |
| `instanceCount` (App Service) | `1` | `3` with zone redundancy | Zone-redundant minimum |
| `retentionInDays` (monitoring) | `90` | `90` (longer via archive tier in Phase 6) | Investigation window; included free once Sentinel is enabled |

## 4. Step-by-step deployment
1. Run the local test suite and confirm every test passes:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
   ```

2. Validate the template against Azure:

   ```powershell
   $resourceGroup = 'defenStack'
   az deployment group validate `
     --resource-group $resourceGroup `
     --parameters params/dev.bicepparam `
     --output table
   ```

   Expected: `provisioningState` `Succeeded`.

3. Preview the changes:

   ```powershell
   az deployment group what-if `
     --resource-group $resourceGroup `
     --parameters params/dev.bicepparam `
     --exclude-change-types Ignore NoChange
   ```

   Compare every `~ Modify`, `+ Create` and `- Delete` line against the "Expected what-if" list in each §5 subsection. **Stop if the what-if shows a `Delete` or `Create` that is not listed, or any change to a VNet address space, a subnet prefix, or the firewall public IP.**

4. Deploy:

   ```powershell
   az deployment group create `
     --resource-group $resourceGroup `
     --name "phase0-$(Get-Date -Format yyyyMMddHHmm)" `
     --parameters params/dev.bicepparam `
     --output table
   ```

5. Run every manual step in §5, in order.
6. Run every validation in §6 and paste the outputs into the Phase 0 PR.

## 5. Manual and post-deployment steps

### F1/F2 - Management subnet isolation and forced tunnelling
**Change:** the `virtual-machines` subnet gets its own NSG (`<spoke>-virtual-machines-nsg`) and its own route table (`<spoke>-virtual-machines-egress-rt`). BGP route propagation is disabled on both spoke route tables so that future VPN gateway routes cannot bypass the firewall.

**Expected what-if:**
- `+ Create` for the new NSG and the new route table.
- `~ Modify` on the spoke VNet: the `virtual-machines` subnet's `networkSecurityGroup.id` and `routeTable.id` change.
- `~ Modify` on `<spoke>-appservice-egress-rt`: `disableBgpRoutePropagation` goes false → true.

**Manual steps:** none.

**Note:** the spec's F2 also calls for a `GatewaySubnet` route table that sends spoke prefixes to the firewall; no gateway exists yet, so this is delivered with the VPN gateway in Phase 3.

### F5 - Spoke CIDRs defined once
**Change:** the firewall source ranges and the private endpoint NSG sources are derived from the spoke address parameters instead of repeated literals. The management subnet (`10.0.3.0/24`) is now an approved private endpoint source, so the future jump host can reach Key Vault and Storage.

**Breaking parameter change:** `approvedPrivateEndpointSourceCidrs` no longer exists. If you passed it before, pass only the *extra* ranges through `additionalPrivateEndpointSourceCidrs`.

**Expected what-if:** `~ Modify` on `<spoke>-private-endpoints-nsg` rule `allow-approved-https`: `sourceAddressPrefixes` gains `10.0.3.0/24`. No firewall policy change with default values.

**Manual steps:** none.

### F9 - Firewall hardening
**Change:**
- Threat intelligence mode is now a parameter (`Alert` in dev).
- The firewall SKU is declared explicitly (`AZFW_VNet`/`Standard`, unchanged).
- A zones parameter exists but defaults to none.
- A platform rule allows the spoke to reach the `AzureMonitor` and `AzureResourceManager` service tags on 443 (Azure Monitor Agent ingestion and its Azure Resource Manager control-plane dependency).
- Firewall logs move to resource-specific tables.

**Expected what-if:**
- `~ Modify` on the firewall policy rule collection group `dns-egress`: adds collection `azure-monitor`.
- `~ Modify` on the diagnostic setting `firewall-diagnostics`: `logAnalyticsDestinationType` becomes `Dedicated`.
- The firewall itself may show `~ Modify` for `sku` (no-op). **The public IP must not show a zones change.**

**Manual step - update saved queries:** after deployment, new firewall logs land in `AZFW*` tables. Any saved query or workbook that reads `AzureDiagnostics | where Category == "AzureFirewallNetworkRule"` must be rewritten to use `AZFWNetworkRule`. Old data stays in `AzureDiagnostics` until its retention expires.

### F3 - VM monitoring via Azure Monitor Agent
**Change:** the VM diagnostic setting no longer requests `allLogs`. Compute VMs expose no log categories, so that request made VM deployments fail. Guest telemetry now flows through the Azure Monitor Agent extension and a data collection rule (`<vm>-dcr`) associated with the VM.

**Expected what-if:** no change while `enableVirtualMachine=false`. With the VM enabled:
- `+ Create` for the extension, the DCR and the DCR association.
- `~ Modify` for the diagnostic setting.

**Manual steps:** none.

### F4 - Key Vault template deployment access
**Change:** the vault now allows Resource Manager to read secrets for deployments. Without this, the README's `az.getSecret()` flow cannot resolve. ARM template-deployment secret retrieval is a Key Vault trusted service, so the composed stack also sets `networkAcls.bypass: 'AzureServices'` (only when `enabledForTemplateDeployment` is `true`; otherwise it stays `'None'`) so that Resource Manager can resolve the `az.getSecret()` reference while `publicNetworkAccess` and `defaultAction: 'Deny'` keep the vault otherwise closed to the public internet.

**Expected what-if:** `~ Modify` on the Key Vault, where `enabledForTemplateDeployment` goes to `true` and `properties.networkAcls.bypass` goes `None` → `AzureServices`.

**Manual verification (required once per environment):** confirm that ARM can resolve a reference while `publicNetworkAccess` is `Disabled`.

1. From an approved network path, create a test secret. Until Phase 3 adds Bastion/VPN there is no private path, so temporarily add your IP. This step also requires the **Key Vault Secrets Officer** data-plane role on the vault for the identity running `az keyvault secret set` (see §2 prerequisites — an RBAC vault does not grant secret access through `Owner` alone):

   ```powershell
   $vault = '<key-vault-name>'
   $myIp = (Invoke-RestMethod https://api.ipify.org)
   az keyvault update -n $vault --public-network-access Enabled --default-action Deny
   az keyvault network-rule add -n $vault --ip-address "$myIp/32"
   az keyvault secret set --vault-name $vault -n phase0-reference-test --value "not-a-real-secret"
   az keyvault network-rule remove -n $vault --ip-address "$myIp/32"
   az keyvault update -n $vault --public-network-access Disabled
   ```

   Confirm public access is `Disabled` again before continuing:

   ```powershell
   az keyvault show -n $vault --query properties.publicNetworkAccess -o tsv
   ```

   If the output is not `Disabled`, immediately re-run `az keyvault update -n $vault --public-network-access Disabled` and re-check before doing anything else.

2. Create `verify.local.bicepparam` (git-ignored) that references the secret, alongside a scratch template `verify.bicep` containing:

   ```bicep
   @secure()
   param probe string
   output length int = length(probe)
   ```

   `verify.local.bicepparam`:

   ```bicep
   using './verify.bicep'
   param probe = az.getSecret('<subscription-id>', 'defenStack', '<key-vault-name>', 'phase0-reference-test')
   ```

   `length()` on a secure value is allowed and does not reveal the secret.

3. Run:

   ```powershell
   az deployment group create -g defenStack --parameters verify.local.bicepparam --query properties.outputs
   ```

   **Expected:** `length.value` = `17`. Record the result in the PR.

4. Clean up:

   ```powershell
   az deployment group delete -g defenStack -n verify
   Remove-Item verify.bicep, verify.local.bicepparam
   ```

   Delete the test secret during the next private-path session (Phase 3), or re-add the temporary IP rule, delete the secret, and remove the rule again.

5. **If step 3 fails with `ForbiddenByFirewall` or `KeyVaultParameterReferenceSecretRetrieveFailed` while `networkAcls.bypass` is confirmed `AzureServices` and `enabledForTemplateDeployment` is confirmed `true`:** ARM cannot reach the private vault even with the trusted-service bypass in place. Record this in `docs/decisions/ADR-001-keyvault-deployment-references.md` and switch the secret flow to pipeline-side retrieval: the GitHub runner reads the secret over the private path (Phase 3) and passes it with `--parameters` from an environment variable. Do **not** enable public access as a workaround. If the failure occurs and `bypass` is not yet `AzureServices` (or `enabledForTemplateDeployment` is not yet `true`), fix that configuration and retry before falling back to ADR-001.

### F12 - Key Vault private endpoint output
**Change:** `privateConnectivity` now outputs `keyVaultPrivateEndpointId`, which later alerting phases use. No Azure change.

### F6/F7 - Blob data protection and audit logs
**Change:** versioning, change feed, blob and container soft delete (14 days) and point-in-time restore (13 days) are enabled. A new `blob-diagnostics` setting sends `StorageRead/StorageWrite/StorageDelete` to Log Analytics.

**Expected what-if:**
- `~ Modify` on `blobServices/default` (data protection properties).
- `+ Create` for diagnostic setting `blob-diagnostics`.

**Cost:** versions and soft-deleted data are billed as stored capacity, and change feed and logs add small ingestion costs. Review `docs/cost.md` after one week.

**Restore procedure (point in time):** `az storage blob restore` is a management-plane operation, so it does not need a private network path — the caller needs the **Storage Account Contributor** role (or equivalent) on the storage account:

```powershell
az storage blob restore `
  --account-name <storage-account> `
  --resource-group defenStack `
  --time-to-restore (Get-Date).ToUniversalTime().AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ssZ') `
  --blob-range def-blob/ def-blob/~
```

### F11 - Container-scoped storage role assignment
**Change:** the App Service identity's `Storage Blob Data Contributor` assignment moves from the whole storage account to the `def-blob` container.

**Expected what-if:** `+ Create` for a new role assignment at `…/blobServices/default/containers/def-blob`. ARM does **not** delete the old account-scope assignment, because it is a different resource.

**Manual step (required) - remove the old account-scope assignment after deployment:**

```powershell
$storageId = az storage account show -g defenStack -n <storage-account> --query id -o tsv
$principalId = az webapp identity show -g defenStack -n <app-service-name> --query principalId -o tsv

# List assignments exactly at account scope (inherited/container assignments are not included).
az role assignment list --scope $storageId --assignee $principalId --role "Storage Blob Data Contributor" --query "[?scope=='$storageId'].{id:id,scope:scope}" -o table
```

Confirm that exactly one row is shown and that its scope ends in the storage account name, not `/containers/def-blob`. Then delete it:

```powershell
$oldId = az role assignment list --scope $storageId --assignee $principalId --role "Storage Blob Data Contributor" --query "[?scope=='$storageId'].id" -o tsv
az role assignment delete --ids $oldId
```

### F8 - App Service hardening
**Change:**
- FTP and SCM basic-auth publishing are disabled.
- Always On, health check, SCM TLS 1.2 and remote debugging off are added.
- Zone redundancy and instance-count parameters are added with in-place-safe defaults.

**Expected what-if:**
- `~ Modify` on the site's `siteConfig`.
- `+ Create`/`~ Modify` for `basicPublishingCredentialsPolicies/ftp` and `/scm`.
- `~ Modify` on the plan (`capacity: 1`, `zoneRedundant: false`), which is a no-op.

**Manual steps:**
1. Confirm the application returns HTTP 200 on `healthCheckPath` before deploying. With health check on, an app that returns non-2xx on `/` will have instances marked unhealthy.
2. Any deployment tooling that used a publish profile (username/password) stops working. Deploy code with Entra ID auth instead:

   ```powershell
   az webapp deploy -g defenStack -n <app-service-name> --src-path app.zip --type zip
   ```

   This must run from a network path that can reach the SCM private endpoint (Phase 3).

### F10 - Log Analytics retention
**Change:** workspace retention goes from 30 to 90 days. Public ingestion and query lockdown through AMPLS is **Phase 6**; it is not included here because it would cut off agents that have no private path yet.

**Expected what-if:** `~ Modify` on the workspace, where `retentionInDays` goes 30 → 90.

**Cost:** until Sentinel is enabled (Phase 6), days 31–90 are billed as data retention per GB-month. Record the workspace's daily ingestion so the cost can be estimated:

```kusto
Usage | where TimeGenerated > ago(7d) | summarize GB = sum(Quantity) / 1000
```

### PSRule baseline fixes (Task 11)
**Change:** three properties were made explicit to satisfy PSRule for Azure rules
found while building the CI baseline (`docs/runbooks/00-pipeline-and-identity.md` §8).
None of these change effective behavior versus what was already deployed; they make an
implicit default explicit, except where noted.

1. **Storage account network firewall default** (`Azure.Storage.Firewall`,
   AZR-000202): `modules/storage.bicep` now sets `networkAcls.defaultAction: 'Deny'`
   (with `bypass: 'AzureServices'`) at the top level of the storage account, alongside
   the existing `publicNetworkAccess: 'Disabled'`.

   **Expected what-if:** `~ Modify` on `<storage-account>`:
   `properties.networkAcls.defaultAction` goes `(not set)` → `Deny`.

   **Manual steps:** none. `publicNetworkAccess` was already `Disabled`, so no client
   that could previously reach the account loses access.

2. **Subnet default outbound access** (`Azure.VNET.PrivateSubnet`, AZR-000447):
   `modules/vnet.bicep` and `modules/spokeNetwork.bicep` now set
   `defaultOutboundAccess: false` on the `private-endpoints` and `virtual-machines`
   subnets. The `appservice-integration` subnet is unchanged (delegation manages its
   own egress).

   **Expected what-if:** `~ Modify` on the spoke VNet: the `private-endpoints` and
   `virtual-machines` subnets' `properties.defaultOutboundAccess` goes `(not set)` →
   `false`.

   **Manual steps:** none for the `private-endpoints` subnet (no compute attaches
   there). **If a VM NIC already exists in the `virtual-machines` subnet when this
   change lands** (`enableVirtualMachine=true` was previously deployed), Azure only
   applies a `defaultOutboundAccess` change to existing NICs on their next IP
   allocation. **Stop (deallocate) the VM and start it again — a reboot is not
   enough** — immediately after this deployment, then confirm with the §6 validation
   command below. Both spoke subnets already route `0.0.0.0/0` through the firewall
   via their route tables, so no traffic path changes; this only removes each
   subnet's fallback default-outbound-access path if the route table were ever
   removed.

3. **App Service client affinity** (`Azure.AppService.ARRAffinity`, AZR-000083):
   `modules/appService.bicep` now sets `clientAffinityEnabled: false` at the top level
   of the site resource (a sibling of `serverFarmId` and `siteConfig`, not a
   `siteConfig` property).

   **Expected what-if:** `~ Modify` on `<app-service-name>`:
   `properties.clientAffinityEnabled` goes `(not set)` → `false`.

   **Manual steps (required before deploying):** confirm the application does not
   rely on Application Request Routing (ARR) sticky sessions to keep a client pinned
   to one instance. Any session state must already live outside the process (for
   example in Key Vault-backed config, the storage account, or a distributed cache) —
   disabling client affinity means requests from the same client can land on any
   instance.

## 6. Validation
| Check | Command | Expected result |
|---|---|---|
| Management subnet has its own NSG | `az network vnet subnet show -g defenStack --vnet-name <spoke-vnet> -n virtual-machines --query "{nsg:networkSecurityGroup.id,rt:routeTable.id}" -o json` | `nsg` ends `-virtual-machines-nsg`; `rt` ends `-virtual-machines-egress-rt` |
| BGP propagation disabled | `az network route-table list -g defenStack --query "[].{name:name,bgpOff:disableBgpRoutePropagation}" -o table` | `bgpOff` = `True` for both spoke route tables |
| No admin inbound yet | `az network nsg rule list -g defenStack --nsg-name <spoke-vnet>-virtual-machines-nsg -o table` | Only `deny-unsolicited-inbound` (4096) |
| PE NSG sources | `az network nsg rule show -g defenStack --nsg-name <spoke-vnet>-private-endpoints-nsg -n allow-approved-https --query sourceAddressPrefixes -o tsv` | `10.0.2.0/24` and `10.0.3.0/24` |
| Threat intel mode | `az network firewall policy show -g defenStack -n <firewall-policy> --query threatIntelMode -o tsv` | `Alert` (dev) |
| Azure Monitor rule | `az network firewall policy rule-collection-group show -g defenStack --policy-name <firewall-policy> -n dns-egress --query "ruleCollections[].name" -o tsv` | `dns` and `azure-monitor` |
| Dedicated tables | In Log Analytics: `AZFWNetworkRule \| take 5` (after 15 minutes of traffic) | Rows returned |
| (VM enabled only) agent healthy | `az vm extension show -g defenStack --vm-name <vm> -n AzureMonitorLinuxAgent --query provisioningState -o tsv` (Linux) or `-n AzureMonitorWindowsAgent` (Windows) | `Succeeded` |
| (VM enabled only) data arriving | Log Analytics: `Heartbeat \| where Computer == "<vm>" \| take 1` after 10 minutes | One row |
| Template deployment enabled | `az keyvault show -n <key-vault-name> --query "{tmpl:properties.enabledForTemplateDeployment,public:properties.publicNetworkAccess}" -o table` | `tmpl` True, `public` Disabled |
| Data protection on | `az storage account blob-service-properties show -g defenStack -n <storage-account> --query "{ver:isVersioningEnabled,soft:deleteRetentionPolicy.days,pitr:restorePolicy.days}" -o table` | `ver` True, `soft` 14, `pitr` 13 |
| Blob logs arriving | Log Analytics: `StorageBlobLogs \| take 5` after blob activity | Rows returned |
| Retention | `az monitor log-analytics workspace show -g defenStack -n <workspace> --query retentionInDays -o tsv` | `90` |
| Only container-scoped access | `az role assignment list --assignee <app-principal-id> --all --query "[?roleDefinitionName=='Storage Blob Data Contributor'].scope" -o tsv` | Exactly one scope ending `/containers/def-blob` |
| App still reads/writes | Application smoke test against `def-blob` | Success; `StorageBlobLogs` shows `AuthenticationType == "OAuth"` |
| Basic auth off | `az resource show -g defenStack --namespace Microsoft.Web --parent sites/<app-service-name> --resource-type basicPublishingCredentialsPolicies -n scm --query properties.allow -o tsv` | `false` (repeat with `-n ftp`) |
| Site config | `az webapp config show -g defenStack -n <app-service-name> --query "{alwaysOn:alwaysOn,health:healthCheckPath,scmTls:scmMinTlsVersion,debug:remoteDebuggingEnabled}" -o table` | `True`, `/`, `1.2`, `False` |
| Storage firewall default | `az storage account show -g defenStack -n <storage-account> --query networkRuleSet.defaultAction -o tsv` | `Deny` |
| Subnet default outbound access off | `az network vnet subnet show -g defenStack --vnet-name <spoke-vnet> -n private-endpoints --query defaultOutboundAccess -o tsv` | `false` (repeat with `-n virtual-machines`) |
| App Service client affinity off | `az webapp show -g defenStack -n <app-service-name> --query clientAffinityEnabled -o tsv` | `false` |

## 7. Rollback
General rollback: redeploy the last good commit from `main` with the same commands in §4. Per-fix exceptions are listed below.

- **F1/F2:** redeploy the previous commit. ARM re-points the subnet to the App Service NSG and route table; the new NSG and route table remain and can be deleted afterwards with `az network nsg delete` / `az network route-table delete`.
- **F4:** set `enabledForTemplateDeployment: false` in `main.bicep` and redeploy, or run `az keyvault update -n <vault> --enabled-for-template-deployment false`. `networkAcls.bypass` reverts to `None` automatically once `enabledForTemplateDeployment` is `false` (the two are tied together in `modules/keyVault.bicep`).
- **F7:** point-in-time restore must be disabled **before** change feed or versioning (Azure rejects the reverse order). Set `restorePolicy.enabled: false`, deploy, then disable the others.
- **F3/F6:** redeploying the previous commit does not remove the data collection rule (DCR), the DCR association, the Azure Monitor Agent extension, or the `blob-diagnostics` diagnostic setting — Bicep incremental mode does not delete resources that a rollback's template no longer declares. Delete them explicitly if required: `az monitor data-collection-rule delete`, `az monitor data-collection-rule association delete`, `az vm extension delete`, and `az monitor diagnostic-settings delete`.
- **F8:** `basicPublishingCredentialsPolicies` (`ftp`/`scm`) stay `allow: false` after redeploying an older commit, because incremental deployment mode does not revert a property the older template never set explicitly. Re-enable basic auth only by explicitly setting `allow: true` (in a template, or with `az resource update`) — rollback alone will not restore it.
- **F10:** reducing `retentionInDays` back to `30` purges Log Analytics data older than 30 days; export any data you need to keep before rolling back.
- **F11:** redeploy the previous commit (recreates the account-scope assignment), then delete the container-scope assignment with `az role assignment delete --ids <id>`.
- **PSRule baseline fixes (Task 11):** redeploy the previous commit. The storage
  firewall default and the App Service client affinity setting revert immediately.
  `defaultOutboundAccess` also reverts to unset, but if a VM NIC exists in the
  `virtual-machines` subnet, it needs the same stop (deallocate) and start cycle
  described in §5 before the reverted setting takes effect on that NIC.

## 8. Operations
- Firewall saved queries: use `AZFW*` tables (F9).
- Blob restore: see F6/F7 in §5.
- Key Vault deployment references: result of the F4 verification is recorded in the execution record; if it failed, see ADR-001.
- Storage access for new containers: add container-scoped role assignments in Bicep (F11).
- Health check path must track the application's health endpoint (F8).

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
| `AnotherOperationInProgress` on firewall policy | Two rule collection groups updated concurrently | Re-run the deployment; groups are serialised by `parent` dependency on retry |
| `Firewall zones cannot be changed` | `availabilityZones` passed for an existing non-zonal firewall | Leave `availabilityZones` empty for in-place updates; zones arrive with Phase 1 greenfield |
| No `Heartbeat` rows | Firewall blocking agent egress | Check `AZFWNetworkRule \| where DestinationPort == 443 and Action == "Deny"`; confirm the `azure-monitor` collection exists |
| App gets `AuthorizationPermissionMismatch` on another container | Access is now limited to `def-blob` | Add a container-scoped assignment for the extra container through Bicep; do not widen to account scope |
| Instances marked unhealthy after deploy | App returns non-2xx on `healthCheckPath` | Set `healthCheckPath` to a real health endpoint and redeploy |
| `401` from publish profile deploy | Basic auth disabled by F8 | Use `az webapp deploy` with Entra ID credentials |
| `ForbiddenByFirewall` on `az.getSecret()` reference resolution | Key Vault firewall is not bypassing the trusted-service (ARM) request | Check `networkAcls.bypass` is `AzureServices` and `enabledForTemplateDeployment` is `true` on the vault (`az keyvault show -n <vault> --query "{bypass:properties.networkAcls.bypass,tmpl:properties.enabledForTemplateDeployment}" -o table`) |

## Execution record
| Date (UTC) | Environment | Deployment name | Operator | Result | Notes |
|---|---|---|---|---|---|

_No executions yet — the first dev run is pending (see "Deferred live steps" in the Phase 0 PR)._
