# 01 - Deploy the stack (Phases 1-2, subscription scope, multi-region)

> Owning module(s): `main.bicep`, `modules/global.bicep`, `modules/regionStamp.bicep`, `modules/privateDnsZoneLinks.bicep`, `modules/types.bicep`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §1. Related: `docs/architecture/overview.md`, [runbook 00b](00b-configure-pipeline-credentials.md), [ADR-008](../decisions/ADR-008-warm-standby-and-dev-single-region.md), [ADR-009](../decisions/ADR-009-subscription-scope-pipeline-identity.md).

## 1. Purpose and scope

Deploys or updates one environment (`dev` or `prod`) of the Phase 1 stack: a single `az deployment sub create` against `main.bicep` that fans out, by `resourceGroup(name)`, to resource groups the operator pre-created. It creates or updates:

- The global layer (`modules/global.bicep`) in `rg-defenstack-<env>-global`: the Log Analytics workspace and the three shared private DNS zones.
- The primary region stamp (`modules/regionStamp.bicep`), always, in `rg-defenstack-<env>-wus3`.
- The secondary region stamp, only when `deploySecondaryRegion = true` (prod), in `rg-defenstack-<env>-eus`.
- The private DNS zone VNet links for every deployed stamp's hub and spoke.

It does **not** create resource groups (§4 step 2, a human operator action) or the pipeline identity (runbook 00b). See `docs/architecture/overview.md` for what each resource group ends up containing.

## 2. Prerequisites

- **Roles:** subscription `Owner` or `User Access Administrator` for the one-time pipeline-identity setup (runbook 00b, first run only); `Contributor` to create the resource groups in §4 step 2. Once the resource groups exist, the pipeline identity itself needs only the three grants runbook 00b makes it (`ADR-009`): the subscription-scope custom role `DefenStack Subscription Deployment Operator`; per-resource-group `Contributor`; and per-resource-group, ABAC-constrained `Role Based Access Control Administrator`. It never creates or deletes resource groups.
- **Register the resource providers** this stack uses, then verify each is `Registered`:

  ```powershell
  foreach ($ns in 'Microsoft.Network','Microsoft.Web','Microsoft.Storage','Microsoft.KeyVault','Microsoft.OperationalInsights','Microsoft.Insights') {
    az provider register --namespace $ns
  }
  foreach ($ns in 'Microsoft.Network','Microsoft.Web','Microsoft.Storage','Microsoft.KeyVault','Microsoft.OperationalInsights','Microsoft.Insights') {
    az provider show -n $ns --query registrationState -o tsv
  }
  ```

  Expect `Registered` for all six.
- **EncryptionAtHost**, only if a VM is enabled (`enableVirtualMachine = true`): register once per subscription, then wait for `Registered`.

  ```powershell
  az feature register --namespace Microsoft.Compute --name EncryptionAtHost
  az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv
  az provider register --namespace Microsoft.Compute
  ```

## 3. Parameters

Every `main.bicep` parameter, with the value each committed `.bicepparam` file supplies (blank means the file does not set it, so the parameter's default applies).

| Name | Default | `params/dev.bicepparam` | `params/prod.bicepparam` | Rationale |
|---|---|---|---|---|
| `environmentName` | *(required)* | `dev` | `prod` | Selects resource group names, redundancy, and deletion protection |
| `primaryLocation` | `westus3` | *(default)* | *(default)* | Active region for both environments |
| `secondaryLocation` | `eastus` | *(default)* | *(default)* | Warm-standby region pair; only used when `deploySecondaryRegion` is `true` |
| `deploySecondaryRegion` | `false` | `false` | `true` | Dev runs primary-only to halve cost (`ADR-008`); prod runs both regions |
| `primaryAddressPlan` | *(required)* | `10.21.0.0/16` hub / `10.20.0.0/16` spoke / VPN pool `172.16.210.0/24` | `10.1.0.0/16` hub / `10.0.0.0/16` spoke / VPN pool `172.16.200.0/24` | Includes the Bastion and gateway subnets and the VPN client pool (Phase 3). See `docs/architecture/overview.md` §4 |
| `secondaryAddressPlan` | *(none)* | not set | `10.11.0.0/16` hub / `10.10.0.0/16` spoke / VPN pool `172.16.201.0/24` | Required only when `deploySecondaryRegion = true` (§9) |
| `allowedOutboundFqdns` | `[]` | `[]` | `[]` | Empty denies all application egress until an operator allowlists FQDNs |
| `additionalPrivateEndpointSourceCidrs` | `[]` | *(default)* | *(default)* | Extra CIDRs allowed to reach private endpoints, beyond the two spoke subnets |
| `managementSourceCidrs` | `[]` | *(default)* | *(default)* | Extra admin sources only. The Bastion subnet and VPN client pool are always allowed (Phase 3, `ADR-013`) |
| `deployPrimaryAdminAccess` | `true` | *(default)* | *(default)* | Bastion and the VPN gateway in the primary region ([runbook 03](03-admin-access.md)) |
| `deploySecondaryAdminAccess` | `false` | *(default)* | *(default)* | Turned on only during failover |
| `adminGroupObjectId` | `''` | dev admin group | prod admin group | Entra group granted `Virtual Machine Administrator Login` on the jump host (runbook 03 §4) |
| `healthCheckPath` | `/` | *(default)* | *(default)* | No application code yet (`ADR-006`) |
| `enableVirtualMachine` | `false` | *(default)* | *(default)* | Optional management VM, primary region only |
| `virtualMachineOsType` | `Linux` | *(default)* | *(default)* | Only relevant if `enableVirtualMachine = true` |
| `virtualMachineAdminUsername` | `azureadmin` | *(default)* | *(default)* | Only relevant if `enableVirtualMachine = true` |
| `virtualMachineAdminSshPublicKey` | `''` | *(default)* | *(default)* | Linux VM admin; supply through a `*.local.bicepparam` overlay |
| `virtualMachineAdminPassword` | `''` (`@secure()`) | *(default)* | *(default)* | Windows VM admin; supply through `az.getSecret()` in a `*.local.bicepparam` overlay, never in a committed file |

## 4. Step-by-step

1. Select the subscription:

   ```powershell
   az account set --subscription <subscription-id>
   ```

2. Create the resource groups for the environment. The global resource group lives in `westus3` regardless of environment, since it is created once and never moves:

   ```powershell
   $env = 'dev'   # or 'prod'
   az group create -n "rg-defenstack-$env-global" -l westus3 -o table
   az group create -n "rg-defenstack-$env-wus3" -l westus3 -o table
   if ($env -eq 'prod') { az group create -n 'rg-defenstack-prod-eus' -l eastus -o table }
   ```

3. Run [runbook 00b](00b-configure-pipeline-credentials.md) for the environment's identity, passing every resource group just created as `-ResourceGroupNames` (dev: the two `dev` groups; prod: all three `prod` groups, plus `-GrantLockManagement`). This grants the identity the subscription-scope custom role (`DefenStack Subscription Deployment Operator`), per-resource-group `Contributor`, and per-resource-group ABAC-constrained `Role Based Access Control Administrator`.

4. Validate:

   ```powershell
   az deployment sub validate --location westus3 --parameters params/<env>.bicepparam -o table
   ```

   Expected: `provisioningState` `Succeeded`.

5. Preview the changes:

   ```powershell
   az deployment sub what-if --location westus3 --parameters params/<env>.bicepparam
   ```

   Expected, for a new environment: only `+ Create` lines. **Stop** on any `Delete`, or on any change under `defenStack` (this deployment must never touch the Phase 0 resource group — see runbook 01a for the migration path).

6. Deploy, either manually or through the pipeline:

   ```powershell
   az deployment sub create --location westus3 --name "manual-$(Get-Date -Format yyyyMMddHHmm)" --parameters params/<env>.bicepparam -o table
   ```

   or merge to `main` for dev, or run the `deploy` workflow with `environment=prod` for prod.

7. Run the budget script once per new resource group:

   ```powershell
   .\scripts\Set-AzureResourceGroupBudget.ps1 -ResourceGroupName "rg-defenstack-$env-global" -BudgetName "defenstack-$env-global-monthly" -MonthlyAmount <amount> -ContactEmail <email>
   .\scripts\Set-AzureResourceGroupBudget.ps1 -ResourceGroupName "rg-defenstack-$env-wus3" -BudgetName "defenstack-$env-wus3-monthly" -MonthlyAmount <amount> -ContactEmail <email>
   if ($env -eq 'prod') { .\scripts\Set-AzureResourceGroupBudget.ps1 -ResourceGroupName 'rg-defenstack-prod-eus' -BudgetName 'defenstack-prod-eus-monthly' -MonthlyAmount <amount> -ContactEmail <email> }
   ```

## 5. Manual and post-deployment steps

- Grant budget access to the operators who need to see cost alerts, with `scripts/Grant-AzureResourceGroupBudgetAccess.ps1`, once per resource group.
- For prod, confirm the GitHub `prod` environment has **Required reviewers** and **Deployment branches and tags: Selected branches → `main`** (runbook 00b §5 "Prod").
- If `enableVirtualMachine = true`, follow the README's "Key Vault and deployment secrets" two-phase flow before the VM parameter is set.

## 6. Validation

| Check | Command | Expected result |
|---|---|---|
| Firewall zones | `az network firewall show -g rg-defenstack-<env>-wus3 -n afw-defenstack-<env>-wus3 --query zones -o tsv` | `1 2 3` |
| Firewall tier, IDPS, rule groups, prod locks | See [runbook 02](02-firewall.md) §6 | Premium tier; IDPS `Alert` (dev) / `Deny` (prod); `dns-egress`/`platform-egress`/`approved-https-egress` rule collection groups; locks on the hub VNet, spoke VNet, Key Vault, firewall, firewall policy and firewall public IP in prod |
| App Service plan (prod WUS3) | `az appservice plan show -g rg-defenstack-prod-wus3 -n asp-defenstack-prod-wus3 --query "{zr:zoneRedundant,capacity:sku.capacity}"` | `true`, `3` |
| DNS links | `az network private-dns link vnet list -g rg-defenstack-<env>-global -z privatelink.vaultcore.azure.net --query "[].name" -o tsv` | The hub and spoke link of every deployed stamp (dev: 2 links; prod: 4 links) |
| Peering | `az network vnet peering list -g rg-defenstack-<env>-wus3 --vnet-name vnet-defenstack-<env>-wus3-hub --query "[].peeringState" -o tsv` | `Connected` |
| Workspace replication (prod) | `az monitor log-analytics workspace show -g rg-defenstack-prod-global -n log-defenstack-prod --query replication` | `enabled: true, location: eastus` |
| Private endpoint records | `az network private-dns record-set a list -g rg-defenstack-<env>-global -z privatelink.vaultcore.azure.net --query "[].name" -o tsv` | One record per stamp's Key Vault |
| Firewall zones (prod East US) | `az network firewall show -g rg-defenstack-prod-eus -n afw-defenstack-prod-eus --query zones -o tsv` | `1 2 3` |
| Peering (prod East US) | `az network vnet peering list -g rg-defenstack-prod-eus --vnet-name vnet-defenstack-prod-eus-hub --query "[].peeringState" -o tsv` | `Connected` |
| App Service plan (prod East US, warm standby) | `az appservice plan show -g rg-defenstack-prod-eus -n asp-defenstack-prod-eus --query "{zr:zoneRedundant,capacity:sku.capacity}"` | `false`, `1` |

## 7. Rollback

- **New environment, before it holds real data:** delete the new resource groups. Prod's resource groups carry `CanNotDelete` locks (`enableDeleteLock` when `isProd`) on individual **resources**, not on the resource groups themselves, so list and remove every locked resource's lock first. In prod this is the spoke VNet, the hub VNet, the Key Vault, the firewall, the firewall policy, and the firewall public IP (per stamp — [runbook 02](02-firewall.md) §6), plus the shared private DNS zones and the Log Analytics workspace in the global resource group:

  ```powershell
  az lock list -g <resource-group> -o table
  az lock delete --ids <lock-id>   # repeat for every listed lock
  az group delete --name <resource-group> --yes --no-wait
  ```

- **Key Vault soft delete and purge protection reserve the vault name for 90 days.** Every Key Vault name is deterministic (`kv-<regionCode>-<uniqueString(subscription().id, environmentName, location)>` — `modules/regionStamp.bicep`), and every vault has purge protection on with 90-day soft-delete retention (`modules/keyVault.bicep`). Consequently, deleting a resource group and immediately redeploying the same stamp fails: the redeploy's Key Vault create hits `A vault with the same name already exists in deleted state` (a soft-deleted, purge-protected vault blocks reuse of its name). Recovery options, in order of speed:
  1. Recover the soft-deleted vault: first recreate the resource group (§4 step 2), then `az keyvault recover --name <key-vault-name>`, then redeploy (the redeploy then updates the recovered vault in place).
  2. Wait out the 90-day retention window before redeploying.

  `environmentName` cannot be used to work around this: it is `@allowed(['dev', 'prod'])` in `main.bicep`, and every deterministic resource name (including the Key Vault name) is seeded from `subscription().id`, `environmentName`, and `location` (`modules/regionStamp.bicep`). Changing the name seed to avoid a name collision would require a code change, not a parameter change.

  `az keyvault purge` does **not** help here: purge protection blocks it by design (that is the point of enabling it), so it always fails against these vaults.

## 8. Operations

- **Never change `primaryLocation` or `secondaryLocation` after the first deploy of an environment.** The Log Analytics workspace's region is fixed at creation and cannot be changed in place; and swapping which region is "primary" would try to relocate the workspace and would flip which App Service plan is zone-redundant versus single-instance on already-provisioned plans — neither is a supported in-place change. Regional failover (making East US active) is an operational procedure for Phase 8, not a parameter swap in this template.
- **To scale East US for a failover exercise or a real failover,** scale out its App Service plan (the rest of the DR runbook, including DNS/traffic cutover, lands in Phase 8):

  ```powershell
  az appservice plan update -g rg-defenstack-prod-eus -n asp-defenstack-prod-eus --number-of-workers 3
  ```

- **To add approved egress FQDNs,** add them to `allowedOutboundFqdns` in the environment's `.bicepparam` file and redeploy (§4 steps 4–6).

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| `ResourceGroupNotFound` | A referenced resource group was not pre-created, or the wrong subscription is selected | Run §4 step 2 first; confirm `az account show` |
| `The template parameter 'secondaryAddressPlan' is null. Assign a value to this parameter …` (a type error on `addressPlan`) | `deploySecondaryRegion = true` without also setting `secondaryAddressPlan` | `params/prod.bicepparam` already supplies `secondaryAddressPlan`; if you copy `dev.bicepparam` and only flip `deploySecondaryRegion`, you must also add `secondaryAddressPlan` |
| Deployment fails with a duplicate-deployment or resource-conflict error, both stamps writing what looks like the same names | `primaryLocation` equals `secondaryLocation` while `deploySecondaryRegion = true` | The two regions must differ; use the shipped defaults (`westus3` / `eastus`) or another distinct pair |
| Key Vault create fails: `A vault with the same name already exists in deleted state`, or `ConflictError` mentioning soft-deleted | Deterministic Key Vault name collides with a soft-deleted, purge-protected vault from a prior deploy of the same environment/region (§7) | `az keyvault recover --name <name>`, then redeploy; or wait out the 90-day retention; `az keyvault purge` is blocked by purge protection |
| `az keyvault list-deleted` shows the name you need | Confirms the §7/above scenario | Recover it (`az keyvault recover`), or wait out the 90-day retention; `environmentName` cannot be changed to work around this without a code change (§7) |
| Zone-redundant App Service plan create fails on SKU/zone quota | The subscription or region lacks quota for `P2V3` with `zoneRedundant: true` | `az appservice list-locations --sku P2V3`; request a quota increase or choose a supported region |
| `ScopeLocked` when removing a stamp's private DNS zone VNet link or record set, or when removing a region stamp | Prod's `CanNotDelete` lock on the global resource group's zones/workspace (`enableDeleteLock`) also protects the zones' child VNet links and record sets, not only the zone resources themselves | Lift the zone lock temporarily (`az lock list -g rg-defenstack-prod-global -o table`, then `az lock delete --ids <lock-id>`), apply the change, then re-create the lock by redeploying (§4 step 6) |
