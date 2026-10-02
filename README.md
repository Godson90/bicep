## Secure Azure deployment

This deployment is a **subscription-scope**, multi-region stack: `main.bicep` (`targetScope = 'subscription'`) fans out to pre-created resource groups, one per environment's global layer and one per deployed region. The environment's Log Analytics workspace and the three shared `privatelink.*` private DNS zones live once in the global resource group (`rg-defenstack-<env>-global`), not per region stamp. Each region stamp creates a private spoke VNet, a dedicated hub VNet, Azure Firewall Premium with IDPS (zone-redundant), private endpoints, private DNS links to the shared zones, subnet NSGs, and reciprocal hub/spoke peering. Storage and App Service public network access are disabled. Dev deploys one region (West US 3); prod deploys West US 3 as the active primary and East US as a warm standby (`docs/decisions/ADR-008-warm-standby-and-dev-single-region.md`). See `docs/architecture/overview.md` for the full topology, address plan, and naming convention.

### Documentation

- Design: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`
- Architecture: `docs/architecture/overview.md` - topology, traffic flows, address plan, naming convention, and resource inventory
- Runbooks: `docs/runbooks/` - start with `00-pipeline-and-identity.md`, `00b-configure-pipeline-credentials.md` (pipeline Azure login via OIDC), `00a-apply-phase0-fixes.md`, `01-deploy-stack.md` (deploy dev or prod), `01a-migrate-from-defenstack.md` (retire the Phase 0 resource group), `02-firewall.md` (Premium firewall rule changes and allowlist requests), and `03-admin-access.md` (Bastion, point-to-site VPN client setup, jump host sign-in, break-glass), `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover), and `05-app-and-data.md` (storage resilience, Application Insights, deploy-time Key Vault secrets, restore procedures)
- Runbook structure (mandatory for every change): `docs/runbooks/_template.md`

### Module layout

`main.bicep` is a subscription-scope entry point, limited to deployment parameters, module composition, and the app hostname outputs for both regions. Resource ownership is split into focused modules:

- `modules/global.bicep`: the environment's shared Log Analytics workspace and the three `privatelink.*` private DNS zones, deployed once per environment.
- `modules/regionStamp.bicep`: one region's full hub/spoke stack (composes every module below), deployed once for the primary region and again for the secondary region when `deploySecondaryRegion = true`.
- `modules/privateDnsZoneLinks.bicep`: links every deployed region's hub and spoke VNets to a shared private DNS zone.
- `modules/types.bicep`: shared parameter contracts (`regionAddressPlan`, `privateDnsZoneSet`, `virtualNetworkReference`) used by `main.bicep`, `modules/global.bicep`, and `modules/regionStamp.bicep`.

Each region stamp composes these existing building blocks:

- `modules/monitoring.bicep`: Log Analytics workspace (called from `modules/global.bicep`, not per region).
- `modules/storage.bicep`: Storage account, blob container, and storage diagnostics.
- `modules/hubNetwork.bicep`: Hub VNet and `AzureFirewallSubnet`.
- `modules/azureFirewall.bicep`: Premium Firewall, public IP, policy (with IDPS and threat intelligence), DNS proxy, and diagnostics; includes `modules/firewallPolicyRules.bicep`.
- `modules/firewallPolicyRules.bicep`: the three shared rule collection groups (`dns-egress`, `platform-egress`, `approved-https-egress`) applied to every stamp's policy (`docs/decisions/ADR-010-shared-firewall-rules-module.md`).
- `modules/spokeNetwork.bicep`: Spoke NSGs, App Service route table, and VNet/subnet associations.
- `modules/vnet.bicep`: Reusable spoke VNet resource and subnet contract.
- `modules/appService.bicep`: App Service plan, site, identity, route-all, and diagnostics.
- `modules/privateConnectivity.bicep`: Private DNS zone groups and private endpoints (the zones themselves live in `modules/global.bicep`).
- `modules/networkIntegration.bicep`: Reciprocal VNet peerings and storage RBAC.
- `modules/virtualMachine.bicep`: Optional private Linux or Windows VM (primary region only), NIC NSG, managed identity, trusted launch, and diagnostics.
- `modules/keyVault.bicep`: RBAC-enabled private Key Vault with soft delete, purge protection, and diagnostics.

Module outputs carry resource IDs between ownership boundaries so deployment dependencies remain explicit without a resource-heavy entry point.

### Query a resource ID

Use the helper script to return a resource ID by name. Add `-ResourceType` when the name is not unique within the resource group:

```powershell
.\scripts\Get-AzureResourceId.ps1 `
	-ResourceGroupName defenStack `
	-ResourceName defenstack-mvp4mm7irhbhmhtw `
	-ResourceType Microsoft.Web/sites
```

For example, query the Azure Firewall resource ID with its resource type:

```powershell
.\scripts\Get-AzureResourceId.ps1 `
	-ResourceGroupName defenStack `
	-ResourceName <firewall-name> `
	-ResourceType Microsoft.Network/azureFirewalls
```

Without `-ResourceType`, the script returns every resource with the matching name and warns when multiple matches exist.

### API version policy

Resource API versions use the newest stable version that is both available from the target Azure provider and typed by the installed Bicep CLI. The Azure provider can expose newer versions before the local Bicep type catalog supports them; using those versions would remove compile-time property validation. Review provider metadata and the Bicep CLI catalog together before upgrading, then run lint, build, Azure deployment validation, and what-if.

### Resource-group budget

The project includes `scripts/Set-AzureResourceGroupBudget.ps1` to create or update a monthly Azure Cost Management budget for the resource group. The budget sends actual-cost and forecasted-cost notifications; it does not stop deployments or automatically shut down resources.

Use `scripts/Grant-AzureResourceGroupBudgetAccess.ps1` to grant the budget-management role to a user, service principal, group, or managed identity. The script requires the Entra **principal object ID**, which is a GUID; an email address or UPN such as `aadeol3@wgu.edu` is not an object ID.

An administrator can find a user object ID with:

```powershell
az ad user show `
	--id <user-upn-or-email> `
	--query id `
	--output tsv
```

Assign resource-group budget access with the object ID:

```powershell
.\scripts\Grant-AzureResourceGroupBudgetAccess.ps1 `
	-ResourceGroupName defenStack `
	-PrincipalObjectId <principal-object-id> `
	-PrincipalType User
```

Preview the role assignment without changing Azure:

```powershell
.\scripts\Grant-AzureResourceGroupBudgetAccess.ps1 `
	-ResourceGroupName defenStack `
	-PrincipalObjectId <principal-object-id> `
	-PrincipalType User `
	-WhatIf
```

The administrator running this helper needs permission to create role assignments at the resource-group scope, such as `Owner`, `User Access Administrator`, or `Role Based Access Control Administrator`. The recipient receives `Cost Management Contributor`; this role is separate from permissions required to deploy the Bicep infrastructure.

Prerequisites:

- Azure CLI installed and authenticated with `az login`.
- Access to the target subscription and resource group.
- A role that can manage Cost Management budgets at the resource-group scope, such as `Cost Management Contributor` or an equivalent custom role.
- At least one administrator email address. Do not put credentials, tokens, or secret values in the script.

Preview the request without changing Azure:

```powershell
.\scripts\Set-AzureResourceGroupBudget.ps1 `
	-ResourceGroupName defenStack `
	-BudgetName defenstack-monthly `
	-MonthlyAmount 500 `
	-ContactEmail platform@example.com `
	-WhatIf
```

Create or update the budget:

```powershell
.\scripts\Set-AzureResourceGroupBudget.ps1 `
	-ResourceGroupName defenStack `
	-BudgetName defenstack-monthly `
	-MonthlyAmount 500 `
	-ContactEmail platform@example.com `
	-ActualThresholdPercent 80 `
	-ForecastedThresholdPercent 100
```

For a fixed planning period or an explicit subscription:

```powershell
.\scripts\Set-AzureResourceGroupBudget.ps1 `
	-SubscriptionId <subscription-id> `
	-ResourceGroupName defenStack `
	-BudgetName defenstack-fy27 `
	-MonthlyAmount 500 `
	-ContactEmail platform@example.com `
	-StartDate '2026-10-01' `
	-EndDate '2027-09-30'
```

Inspect the resulting budget:

```powershell
az consumption budget show `
	--resource-group defenStack `
	--name defenstack-monthly `
	--output json
```

Budget notifications can lag actual usage, and budget alerts are not a replacement for Azure Monitor alerts or deployment governance. Use Cost Analysis to review actual resource-group spend after deployment.

### Key Vault and deployment secrets

The Key Vault module creates an RBAC-enabled vault with public access disabled, soft delete, configurable retention, purge protection, and a private endpoint in the private endpoint subnet. Purge protection is intentionally enabled for the composed stack because Azure does not allow it to be disabled after it has been enabled. The module parameter remains available for standalone module reuse. It intentionally does not accept secret values. Secret values must not be placed in Bicep source, generated `main.json`, or ordinary command-line arguments.

Bicep reads deployment secrets through a `.bicepparam` file, using `az.getSecret()`. The vault and secret must already exist before the parameter file is evaluated; deploy the infrastructure in two phases:

1. Deploy the base stack with `enableVirtualMachine=false`.
2. From an approved network path with Key Vault DNS resolution, grant the deployment identity `Key Vault Secrets Officer` or another least-privilege role, then create the secret:

```powershell
az role assignment create `
	--assignee-object-id <deployment-principal-object-id> `
	--assignee-principal-type ServicePrincipal `
	--role "Key Vault Secrets Officer" `
	--scope <key-vault-resource-id>

az keyvault secret set `
	--vault-name <key-vault-name> `
	--name vm-admin-password `
	--value <secret-value>
```

3. Copy `params/dev.bicepparam` to a local, ignored `params/dev.local.bicepparam` file (matched by `.gitignore`) and add the VM parameters for the follow-up deployment. The Key Vault for the dev primary stamp lives in `rg-defenstack-dev-wus3`:

```bicep
using './main.bicep'

param environmentName = 'dev'
param deploySecondaryRegion = false
param primaryAddressPlan = { /* same object as params/dev.bicepparam */ }
param allowedOutboundFqdns = [
	'management.azure.com'
]
param enableVirtualMachine = true
param virtualMachineOsType = 'Windows'
param virtualMachineAdminUsername = 'azureadmin'
param virtualMachineAdminPassword = az.getSecret(
	'<subscription-id>',
	'rg-defenstack-dev-wus3',
	'<key-vault-name>',
	'vm-admin-password'
)
```

Deploy the parameter file with `az deployment sub create --location westus3 --parameters params/dev.local.bicepparam`. `az.getSecret()` compiles to a Key Vault reference that Azure Resource Manager resolves at deployment time, so:

- The vault must have `enabledForTemplateDeployment = true` (the composed stack sets this).
- The deploying identity needs `Microsoft.KeyVault/vaults/deploy/action` on the vault, which is included in `Contributor` and `Owner`.
- `az.getSecret()` cannot read a vault created in the same deployment; use the two-phase flow above.

Resolution through a vault with public network access disabled must be confirmed once per environment: `modules/keyVault.bicep` sets `networkAcls.bypass: 'AzureServices'` whenever `enabledForTemplateDeployment` is `true`, so Resource Manager can resolve the `az.getSecret()` reference while the vault otherwise stays closed to the public internet.

For Linux, replace the password parameter with `virtualMachineAdminSshPublicKey` and retrieve an SSH public key only if it is intentionally stored in Key Vault. Prefer keeping public keys in a non-secret parameter file and storing only private credentials as secrets.

### Virtual machine module

The VM module is disabled by default through `enableVirtualMachine=false`. When enabled, it creates a private-only VM in the dedicated `management` subnet with no public IP, a NIC-level deny-by-default NSG, a system-assigned managed identity, Premium managed OS disk, trusted launch, secure boot, vTPM, boot diagnostics, platform metrics, and the Azure Monitor Agent with a data collection rule that sends syslog (Linux) or System/Application events (Windows) plus CPU, memory, and disk counters to the Log Analytics workspace. The firewall's `AzureMonitor` service-tag rule allows the agent's egress.

- Set `virtualMachineOsType=Linux` and provide `virtualMachineAdminSshPublicKey` for SSH-only administration.
- Set `virtualMachineOsType=Windows` and provide `virtualMachineAdminPassword` through a secure parameter mechanism. Do not place passwords in source control or generated templates.
- The VM name is limited to 15 characters because Azure also uses it as the computer hostname.
- The VM subnet has no public ingress path. Use approved private connectivity, Bastion, or a controlled management path for administration; do not add a public IP as a shortcut.
- VM size and image defaults are defined in `modules/virtualMachine.bicep` and should be reviewed for the target region and workload.

### Prerequisites

- Azure CLI with an authenticated account and the operator-created resource groups for the environment (`docs/runbooks/01-deploy-stack.md` §4).
- Bicep CLI 0.47 or later.
- A subscription and region that support the selected App Service plan SKU.
- Network clients that need the storage account or App Service must run in the linked VNet or a connected network with DNS forwarding configured.
- Non-overlapping spoke and hub address spaces. The shipped address plans (`params/*.bicepparam`) use dev `10.20.0.0/16` spoke / `10.21.0.0/16` hub, and prod `10.0.0.0/16` spoke / `10.1.0.0/16` hub (primary) plus `10.10.0.0/16` spoke / `10.11.0.0/16` hub (secondary).
- Azure RBAC permissions to create VNets, peerings, NSGs, route tables, Azure Firewall resources, role assignments, diagnostics, and private DNS links.

### Firewall behavior

- The hub contains an exact-case `AzureFirewallSubnet` using `10.1.0.0/26` by default. The configured prefix must be at least `/26` and contained in the hub address space. Do not attach a workload NSG to this subnet.
- Azure Firewall uses the **Premium** SKU (`firewallTier: 'Premium'` for every environment), with a Standard static public IP, DNS proxy, and a Firewall Policy. Premium adds **IDPS** (`Alert` in dev, `Deny` in prod) on top of Standard's capabilities; TLS inspection is deliberately deferred (`docs/decisions/ADR-011-tls-inspection-deferred.md`), so IDPS and threat intelligence see unencrypted traffic and TLS metadata only, not decrypted HTTPS payloads.
- Rule content comes from a shared module (`modules/firewallPolicyRules.bicep`, `docs/decisions/ADR-010-shared-firewall-rules-module.md`) included by every stamp's policy, as three dependency-chained rule collection groups:
  - `dns-egress` (priority 100): DNS to Azure's resolver (`168.63.129.16:53`), and HTTPS to the `AzureMonitor`/`AzureResourceManager` service tags for the Azure Monitor Agent.
  - `platform-egress` (priority 150): OS update endpoints (`WindowsUpdate` FQDN tag, Ubuntu archive FQDNs) — **management subnet only**, never the App Service subnet.
  - `approved-https-egress` (priority 200, optional): the application allowlist from `allowedOutboundFqdns`; not deployed at all while that list is empty.
- App Service integration traffic uses a `0.0.0.0/0` route through the firewall private IP and App Service route-all is enabled.
- Private endpoint traffic remains on the private endpoint subnet and is not routed through the firewall.
- No inbound DNAT rules are created. Public exposure must remain disabled unless a separate reviewed design adds explicit rules.
- `allowedOutboundFqdns` defaults to an empty list, so application HTTPS traffic is denied until administrators provide an approved FQDN allowlist (see `docs/runbooks/02-firewall.md` §5 for the request process). OS update egress is available to the management subnet only, never to App Service.
- Threat intelligence runs in `Deny` mode for `prod` and `Alert` mode for `dev`/`test`. IDPS follows the identical split. Firewall logs are written to resource-specific tables (`AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWDnsQuery`, `AZFWThreatIntel`, `AZFWIdpsSignature`, …), not `AzureDiagnostics`.
- NSGs deny unsolicited inbound traffic on the private endpoint, App Service integration, and management subnets. Private endpoint network security policy is enabled. By default only the App Service integration and management subnets can reach private endpoints over HTTPS; the allowed sources are derived from `appServiceIntegrationSubnetAddressPrefix` and `virtualMachineSubnetAddressPrefix`. Add narrowly scoped administrator/client CIDRs through `additionalPrivateEndpointSourceCidrs` when required. Spoke CIDRs are defined once, in each environment's `primaryAddressPlan` / `secondaryAddressPlan` object in `params/*.bicepparam` (`modules/types.bicep`'s `regionAddressPlan`), and reused by the firewall rules.
- Forwarded traffic is enabled on the reciprocal peerings for firewall service chaining. Gateway transit is enabled on the hub↔spoke peering when admin access is deployed (`docs/runbooks/03-admin-access.md`), so VPN clients on the hub gateway can reach the spoke.
- **Prod locks:** in prod (`enableDeleteLock: true`), `CanNotDelete` locks are applied to the hub VNet, the spoke VNet, the Key Vault, the firewall, the firewall policy, and the firewall public IP — see `docs/runbooks/02-firewall.md` §6/§7 for the validation and removal procedure.

Azure Firewall Premium has ongoing hourly and data-processing charges, higher than Standard's (`docs/cost.md` "Phase 2 delta"). Regional VNet peering and Log Analytics ingestion also incur charges. Phase 3 adds a point-to-site VPN gateway, Azure Bastion and their three public IPs in each region with admin access (`docs/cost.md` "Phase 3 delta"). This design intentionally avoids global peering, NAT gateways, site-to-site VPN or ExpressRoute, other public IPs, and Azure Firewall Manager unless separately approved.

### Validate and build

Run all local checks: lint every Bicep file, compile, template assertions, and verify `main.json` is current:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
```

After changing any `.bicep` file, regenerate the committed ARM template:

```powershell
bicep build main.bicep
```

CI (`.github/workflows/bicep-ci.yml`) runs the same tests plus PSRule for Azure on every pull request.

### Validate against Azure

```powershell
az deployment sub validate `
	--location westus3 `
	--parameters params/dev.bicepparam

az deployment sub what-if `
	--location westus3 `
	--parameters params/dev.bicepparam
```

Use `params/prod.bicepparam` for the two-region prod stack (Premium V3, zone-redundant primary). Review the what-if output before deployment, especially the firewall subnet size, route-table association, reciprocal peerings, private endpoint placement, DNS links, and disabled public network access. Do not copy the example FQDNs into production without confirming the application's actual dependencies.

The optional management VM is only ever enabled through a git-ignored `*.local.bicepparam` overlay (matched by `.gitignore`), never in a committed parameter file. Copy `params/dev.bicepparam` to `params/dev.local.bicepparam` and add `enableVirtualMachine = true` plus the VM parameters. For Linux, with an SSH public key:

```bicep
using './main.bicep'

param environmentName = 'dev'
param deploySecondaryRegion = false
param primaryAddressPlan = { /* same object as params/dev.bicepparam */ }
param allowedOutboundFqdns = [
	'management.azure.com'
]
param enableVirtualMachine = true
param virtualMachineOsType = 'Linux'
param virtualMachineAdminSshPublicKey = '<ssh-public-key>'
```

```powershell
az deployment sub validate `
	--location westus3 `
	--parameters params/dev.local.bicepparam

az deployment sub create `
	--location westus3 `
	--parameters params/dev.local.bicepparam
```

For Windows, never pass `virtualMachineAdminPassword` as a command-line argument — it would be visible in shell history and process listings. Use `az.getSecret()` in the same overlay, as described in [Key Vault and deployment secrets](#key-vault-and-deployment-secrets):

```bicep
using './main.bicep'

param environmentName = 'dev'
param deploySecondaryRegion = false
param primaryAddressPlan = { /* same object as params/dev.bicepparam */ }
param enableVirtualMachine = true
param virtualMachineOsType = 'Windows'
param virtualMachineAdminUsername = '<admin-username>'
param virtualMachineAdminPassword = az.getSecret(
	'<subscription-id>',
	'<resource-group-name>',
	'<key-vault-name>',
	'vm-admin-password'
)
```

### Azure CLI administrator commands

Register and verify the network provider:

```powershell
az provider register --namespace Microsoft.Network
az provider show --namespace Microsoft.Network --query registrationState -o tsv
az account show --query "{subscription:id,tenant:tenantId}" -o table
```

Deploy after reviewing what-if (see `docs/runbooks/01-deploy-stack.md` §4 for the full subscription-scope procedure):

```powershell
az deployment sub create `
	--location westus3 `
	--name "manual-$(Get-Date -Format yyyyMMddHHmm)" `
	--parameters params/dev.bicepparam
```

Inspect the hub, firewall, policy, and public IP, using the dev primary stamp's names as an example (substitute `rg-defenstack-<env>-<regionCode>` and the matching resource names for another stamp):

```powershell
az network vnet show -g rg-defenstack-dev-wus3 -n vnet-defenstack-dev-wus3-hub -o table
az network vnet subnet show -g rg-defenstack-dev-wus3 --vnet-name vnet-defenstack-dev-wus3-hub -n AzureFirewallSubnet -o table
az network firewall show -g rg-defenstack-dev-wus3 -n afw-defenstack-dev-wus3 `
	--query "{sku:sku.tier,privateIp:ipConfigurations[0].properties.privateIPAddress,policy:firewallPolicy.id}" -o json
az network firewall policy show -g rg-defenstack-dev-wus3 -n afwp-defenstack-dev-wus3 -o json
az network public-ip show -g rg-defenstack-dev-wus3 -n pip-afw-defenstack-dev-wus3 `
	--query "{sku:sku.name,allocation:publicIPAllocationMethod,ip:ipAddress}" -o table
```

Inspect subnet NSGs and App Service routing:

```powershell
az network vnet subnet list -g rg-defenstack-dev-wus3 --vnet-name vnet-defenstack-dev-wus3-spoke -o table
az network nsg list -g rg-defenstack-dev-wus3 -o table
az network nsg rule list -g rg-defenstack-dev-wus3 --nsg-name <nsg-name> -o table
az network route-table show -g rg-defenstack-dev-wus3 -n <route-table-name> -o json
az network route-table route list -g rg-defenstack-dev-wus3 --route-table-name <route-table-name> -o table
```

Inspect reciprocal peering and DNS links:

```powershell
az network vnet peering list -g rg-defenstack-dev-wus3 --vnet-name vnet-defenstack-dev-wus3-hub -o table
az network vnet peering list -g rg-defenstack-dev-wus3 --vnet-name vnet-defenstack-dev-wus3-spoke -o table
az network vnet peering show -g rg-defenstack-dev-wus3 --vnet-name vnet-defenstack-dev-wus3-hub -n hub-to-spoke `
	--query "{state:peeringState,forwarded:allowForwardedTraffic,gatewayTransit:allowGatewayTransit}" -o table
az network private-dns link vnet list -g rg-defenstack-dev-global --zone-name privatelink.vaultcore.azure.net -o table
```

For an approved test NIC, inspect effective routes and security rules:

```powershell
az network nic show-effective-route-table -g rg-defenstack-dev-wus3 -n <nic-name> -o table
az network nic list-effective-nsg -g rg-defenstack-dev-wus3 -n <nic-name> -o json
```

### Safe teardown

Applies to the legacy `defenStack` resource group (see runbook 01a). For the Phase 1 stacks, see runbook 01 §7.

Use this order when removing the deployment. Replace placeholders before running commands, and run each step from an authenticated administrator session.

#### 1. Select the subscription and confirm the target

```powershell
$subscriptionId = '<subscription-id>'
$resourceGroup = 'defenStack'
$spokeVnet = '<spoke-vnet-name>'
$hubVnet = '<hub-vnet-name>'

az account set --subscription $subscriptionId
az group show --name $resourceGroup --query "{name:name,location:location,provisioningState:properties.provisioningState}" -o table
```

Never run teardown commands against a production resource group until the resource group name and subscription are confirmed.

#### 2. Capture the current deployment and preview deletion

```powershell
az resource list --resource-group $resourceGroup `
	--query "[].{name:name,type:type,id:id}" -o table

git show phase0-foundation-fixes:main.json > $env:TEMP\defenstack-phase0-main.json

az deployment group what-if `
	--resource-group $resourceGroup `
	--template-file $env:TEMP\defenstack-phase0-main.json `
	--parameters environmentType=dev
```

This legacy teardown section applies only to `defenStack`: `main.bicep` on this branch is subscription-scoped and no longer accepts `environmentType` or deploys to a single resource group, so the what-if must run against the last Phase 0 template (`phase0-foundation-fixes:main.json`), not the current `main.bicep`.

Export any required resource IDs, Key Vault secrets, diagnostic settings, and application data before continuing. A what-if of the unchanged template is not a deletion plan; use the explicit commands below or a reviewed resource-group deletion plan.

#### 3. Stop or detach application consumers

Disable application traffic and stop any clients that use Storage, Key Vault, or App Service. If the optional VM is deployed, remove or stop it first:

```powershell
az vm list -g $resourceGroup -o table
az vm deallocate -g $resourceGroup -n <vm-name>
az vm delete -g $resourceGroup -n <vm-name> --yes
```

Do not delete the VM before capturing required disks, snapshots, or application data.

#### 4. Remove the App Service route association

Detach the firewall route table from the App Service integration subnet before deleting the firewall or route table:

```powershell
az network vnet subnet update `
	--resource-group $resourceGroup `
	--vnet-name $spokeVnet `
	--name appservice-integration `
	--remove routeTable
```

Confirm that the subnet no longer references the route table:

```powershell
az network vnet subnet show `
	--resource-group $resourceGroup `
	--vnet-name $spokeVnet `
	--name appservice-integration `
	--query "{routeTable:routeTable.id}" -o json
```

#### 5. Remove both peering directions

Delete both sides together. Do not leave one side of a peering behind:

```powershell
az network vnet peering delete -g $resourceGroup --vnet-name $hubVnet -n hub-to-spoke
az network vnet peering delete -g $resourceGroup --vnet-name $spokeVnet -n spoke-to-hub
```

#### 6. Remove private endpoints before DNS zones

List and delete the Storage, App Service, and Key Vault private endpoints first. Private DNS zone groups are removed with their parent private endpoints:

```powershell
az network private-endpoint list -g $resourceGroup -o table
az network private-endpoint delete -g $resourceGroup -n <storage-private-endpoint>
az network private-endpoint delete -g $resourceGroup -n <appservice-private-endpoint>
az network private-endpoint delete -g $resourceGroup -n <keyvault-private-endpoint>
```

Then remove the private DNS links before removing the zones:

```powershell
az network private-dns link vnet list -g $resourceGroup --zone-name privatelink.blob.core.windows.net -o table
az network private-dns link vnet delete -g $resourceGroup --zone-name privatelink.blob.core.windows.net -n storage-link
az network private-dns link vnet delete -g $resourceGroup --zone-name privatelink.blob.core.windows.net -n hub-storage-link

az network private-dns link vnet delete -g $resourceGroup --zone-name privatelink.azurewebsites.net -n appservice-link
az network private-dns link vnet delete -g $resourceGroup --zone-name privatelink.azurewebsites.net -n hub-appservice-link

az network private-dns link vnet delete -g $resourceGroup --zone-name privatelink.vaultcore.azure.net -n keyvault-link
az network private-dns link vnet delete -g $resourceGroup --zone-name privatelink.vaultcore.azure.net -n hub-keyvault-link
```

Delete the zones only after all links and private endpoints are gone:

```powershell
az network private-dns zone delete -g $resourceGroup -n privatelink.blob.core.windows.net --yes
az network private-dns zone delete -g $resourceGroup -n privatelink.azurewebsites.net --yes
az network private-dns zone delete -g $resourceGroup -n privatelink.vaultcore.azure.net --yes
```

#### 7. Remove application resources and RBAC

Delete the App Service and Storage resources after their private endpoints are removed. Remove the managed identity role assignment if it is not needed elsewhere:

```powershell
az webapp list -g $resourceGroup -o table
az webapp delete -g $resourceGroup -n <app-service-name>
az storage account delete -g $resourceGroup -n <storage-account-name> --yes

az role assignment list --scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" -o table
az role assignment delete --ids <role-assignment-resource-id>
```

Storage deletion is destructive. Confirm retention, backup, replication, and data export requirements first.

#### 8. Remove the firewall and hub resources

Delete the Firewall before its policy and public IP, then delete the route table, NSGs, and hub VNet:

```powershell
az network firewall delete -g $resourceGroup -n <firewall-name>
az network firewall policy delete -g $resourceGroup -n <firewall-policy-name>
az network public-ip delete -g $resourceGroup -n <firewall-public-ip-name>
az network route-table delete -g $resourceGroup -n <route-table-name>
az network nsg delete -g $resourceGroup -n <private-endpoint-nsg-name>
az network nsg delete -g $resourceGroup -n <appservice-integration-nsg-name>
az network vnet delete -g $resourceGroup -n $hubVnet
```

The spoke VNet still owns subnet NSG associations. Remove the spoke VNet only after all private endpoints, App Service integration, and VM resources have been removed.

#### 9. Handle Key Vault retention and locks

If the production VNet delete lock is enabled, remove it before deleting the VNet:

```powershell
az lock list --resource-group $resourceGroup -o table
az lock delete --ids <lock-resource-id>
```

Key Vault soft delete and purge protection are intentional. Deleting the vault does not immediately make its name reusable, and purge protection prevents immediate purge. Verify the retention requirement before deleting it:

```powershell
az keyvault delete -g $resourceGroup -n <key-vault-name>
az keyvault list-deleted --query "[].{name:name,location:properties.location}" -o table
```

Do not run `az keyvault purge` for a purge-protected production vault.

#### 10. Verify and remove the budget separately

Budgets are Cost Management resources, not ARM resources in the deployment template. Review and remove the budget only if it is no longer needed:

```powershell
az consumption budget show -g $resourceGroup -n defenstack-monthly -o json
az consumption budget delete -g $resourceGroup -n defenstack-monthly
```

Verify that no managed resources remain:

```powershell
az resource list -g $resourceGroup --query "[].{name:name,type:type}" -o table
```

For a complete disposable environment only, and only after reviewing the resource list and retaining required data, the final option is:

```powershell
az group delete --name $resourceGroup --yes --no-wait
```

This removes unrelated resources in the resource group as well. Do not use it for a shared or production resource group. Budget alerts, soft-deleted Key Vault resources, and billing data may remain outside the normal resource list.

### Security notes

- The storage account denies public network access, blob public access, shared-key access, and TLS versions below 1.2. Blob versioning, change feed, 14-day blob and container soft delete, and 13-day point-in-time restore are enabled, and blob read/write/delete logs go to Log Analytics (`StorageBlobLogs`).
- The App Service uses a system-assigned managed identity, HTTPS-only access, TLS 1.2 (site and SCM), HTTP/2, disabled FTPS, disabled FTP/SCM basic authentication, disabled remote debugging, Always On, a health check probe (`healthCheckPath`, default `/`), VNet integration, and a private endpoint.
- Diagnostics are sent to the Log Analytics workspace created by the deployment.
- Do not place plaintext secrets in source-controlled Bicep parameter files, outputs, command history, or generated ARM templates. Secure references such as `az.getSecret()` in a local, ignored `.bicepparam` file are supported; use managed identity and Key Vault references for application secrets.
