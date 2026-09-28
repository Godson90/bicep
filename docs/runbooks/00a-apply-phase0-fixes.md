# 00a - Apply Phase 0 foundation fixes

> Owning modules: all files under `modules/` and `main.bicep`. Spec: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §2 (F1–F13).

## 1. Purpose and scope
Applies the Phase 0 defect fixes to the existing `defenStack` resource group (dev) **in place**. No resource is replaced. The fixes are listed per finding in §5–§7. Greenfield-only changes (zones, plan rename, subnet rename, subscription scope) are **not** part of this runbook; they arrive with Phase 1.

## 2. Prerequisites
- Azure CLI 2.90 or later: `az version`.
- Bicep CLI 0.47.16 or later: `bicep --version`.
- PowerShell 5.1 or 7.
- Operator role on `defenStack`: `Owner`, or `Contributor` plus `Role Based Access Control Administrator`. Role assignments are created and one is deleted in §5.
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

Until Task 11 creates `params/dev.bicepparam`, use `--template-file main.bicep --parameters environmentType=dev` instead.

## 5. Manual and post-deployment steps

### F1/F2 - Management subnet isolation and forced tunnelling
**Change:** the `virtual-machines` subnet gets its own NSG (`<spoke>-virtual-machines-nsg`) and its own route table (`<spoke>-virtual-machines-egress-rt`). BGP route propagation is disabled on both spoke route tables so that future VPN gateway routes cannot bypass the firewall.

**Expected what-if:**
- `+ Create` for the new NSG and the new route table.
- `~ Modify` on the spoke VNet: the `virtual-machines` subnet's `networkSecurityGroup.id` and `routeTable.id` change.
- `~ Modify` on `<spoke>-appservice-egress-rt`: `disableBgpRoutePropagation` goes false → true.

**Manual steps:** none.

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
- A platform rule allows the spoke to reach the `AzureMonitor` service tag on 443.
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
**Change:** the vault now allows Resource Manager to read secrets for deployments. Without this, the README's `az.getSecret()` flow cannot resolve.

**Expected what-if:** `~ Modify` on the Key Vault, where `enabledForTemplateDeployment` goes to `true`.

**Manual verification (required once per environment):** confirm that ARM can resolve a reference while `publicNetworkAccess` is `Disabled`.

1. From an approved network path, create a test secret. Until Phase 3 adds Bastion/VPN there is no private path, so temporarily add your IP:

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

   Delete the test secret during the next private-path session (Phase 3), or now while the temporary IP rule is in place.

5. **If step 3 fails with `ForbiddenByFirewall` or `KeyVaultParameterReferenceSecretRetrieveFailed`:** ARM cannot reach the private vault. Record this in `docs/decisions/ADR-001-keyvault-deployment-references.md` and switch the secret flow to pipeline-side retrieval: the GitHub runner reads the secret over the private path (Phase 3) and passes it with `--parameters` from an environment variable. Do **not** enable public access as a workaround.

### F12 - Key Vault private endpoint output
**Change:** `privateConnectivity` now outputs `keyVaultPrivateEndpointId`, which later alerting phases use. No Azure change.

### F6/F7 - Blob data protection and audit logs
**Change:** versioning, change feed, blob and container soft delete (14 days) and point-in-time restore (13 days) are enabled. A new `blob-diagnostics` setting sends `StorageRead/StorageWrite/StorageDelete` to Log Analytics.

**Expected what-if:**
- `~ Modify` on `blobServices/default` (data protection properties).
- `+ Create` for diagnostic setting `blob-diagnostics`.

**Cost:** versions and soft-deleted data are billed as stored capacity, and change feed and logs add small ingestion costs. Review `docs/cost.md` after one week.

**Restore procedure (point in time), run from an approved private path:**

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
| (VM enabled only) agent healthy | `az vm extension show -g defenStack --vm-name <vm> -n AzureMonitorLinuxAgent --query provisioningState -o tsv` | `Succeeded` |
| (VM enabled only) data arriving | Log Analytics: `Heartbeat \| where Computer == "<vm>" \| take 1` after 10 minutes | One row |
| Template deployment enabled | `az keyvault show -n <key-vault-name> --query "{tmpl:properties.enabledForTemplateDeployment,public:properties.publicNetworkAccess}" -o table` | `tmpl` True, `public` Disabled |
| Data protection on | `az storage account blob-service-properties show -g defenStack -n <storage-account> --query "{ver:isVersioningEnabled,soft:deleteRetentionPolicy.days,pitr:restorePolicy.days}" -o table` | `ver` True, `soft` 14, `pitr` 13 |
| Blob logs arriving | Log Analytics: `StorageBlobLogs \| take 5` after blob activity | Rows returned |
| Only container-scoped access | `az role assignment list --assignee <app-principal-id> --all --query "[?roleDefinitionName=='Storage Blob Data Contributor'].scope" -o tsv` | Exactly one scope ending `/containers/def-blob` |
| App still reads/writes | Application smoke test against `def-blob` | Success; `StorageBlobLogs` shows `AuthenticationType == "OAuth"` |

## 7. Rollback
General rollback: redeploy the last good commit from `main` with the same commands in §4. Per-fix exceptions are listed below.

- **F1/F2:** redeploy the previous commit. ARM re-points the subnet to the App Service NSG and route table; the new NSG and route table remain and can be deleted afterwards with `az network nsg delete` / `az network route-table delete`.
- **F4:** set `enabledForTemplateDeployment: false` in `main.bicep` and redeploy, or run `az keyvault update -n <vault> --enabled-for-template-deployment false`.
- **F7:** point-in-time restore must be disabled **before** change feed or versioning (Azure rejects the reverse order). Set `restorePolicy.enabled: false`, deploy, then disable the others.
- **F11:** redeploy the previous commit (recreates the account-scope assignment), then delete the container-scope assignment with `az role assignment delete --ids <id>`.

## 8. Operations
See the per-fix notes in §5.

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
| `AnotherOperationInProgress` on firewall policy | Two rule collection groups updated concurrently | Re-run the deployment; groups are serialised by `parent` dependency on retry |
| `Firewall zones cannot be changed` | `availabilityZones` passed for an existing non-zonal firewall | Leave `availabilityZones` empty for in-place updates; zones arrive with Phase 1 greenfield |
| No `Heartbeat` rows | Firewall blocking agent egress | Check `AZFWNetworkRule \| where DestinationPort == 443 and Action == "Deny"`; confirm the `azure-monitor` collection exists |
| App gets `AuthorizationPermissionMismatch` on another container | Access is now limited to `def-blob` | Add a container-scoped assignment for the extra container through Bicep; do not widen to account scope |
