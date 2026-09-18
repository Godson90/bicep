## Secure Azure deployment

This deployment creates a private spoke VNet, a dedicated hub VNet, Azure Firewall Standard, a Log Analytics workspace, private endpoints, private DNS links, subnet NSGs, and reciprocal hub/spoke peering. Storage and App Service public network access are disabled.

### Module layout

`main.bicep` is intentionally limited to deployment parameters, module composition, and the application hostname output. Resource ownership is split into focused modules:

- `modules/monitoring.bicep`: Log Analytics workspace.
- `modules/storage.bicep`: Storage account, blob container, and storage diagnostics.
- `modules/hubNetwork.bicep`: Hub VNet and `AzureFirewallSubnet`.
- `modules/azureFirewall.bicep`: Firewall, public IP, policy, DNS proxy, rules, and diagnostics.
- `modules/spokeNetwork.bicep`: Spoke NSGs, App Service route table, and VNet/subnet associations.
- `modules/vnet.bicep`: Reusable spoke VNet resource and subnet contract.
- `modules/appService.bicep`: App Service plan, site, identity, route-all, and diagnostics.
- `modules/privateConnectivity.bicep`: Private DNS zones, VNet links, private endpoints, and zone groups.
- `modules/networkIntegration.bicep`: Reciprocal VNet peerings and storage RBAC.
- `modules/virtualMachine.bicep`: Optional private Linux or Windows VM, NIC NSG, managed identity, trusted launch, and diagnostics.
- `modules/keyVault.bicep`: RBAC-enabled private Key Vault with soft delete, purge protection, and diagnostics.

Module outputs carry resource IDs between ownership boundaries so deployment dependencies remain explicit without a resource-heavy entry point.

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

The Key Vault module creates an RBAC-enabled vault with public access disabled, soft delete, configurable retention, optional purge protection, and a private endpoint in the private endpoint subnet. It intentionally does not accept secret values. Secret values must not be placed in Bicep source, generated `main.json`, or ordinary command-line arguments.

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

3. Use a local, ignored `.bicepparam` file for the follow-up deployment:

```bicep
using './main.bicep'

param environmentType = 'dev'
param enableVirtualMachine = true
param virtualMachineOsType = 'Windows'
param virtualMachineAdminUsername = 'azureadmin'
param virtualMachineAdminPassword = az.getSecret(
	'<subscription-id>',
	'<resource-group-name>',
	'<key-vault-name>',
	'vm-admin-password'
)
param allowedOutboundFqdns = [
	'management.azure.com'
]
```

Deploy the parameter file with `az deployment group create --parameters <file>.bicepparam`. The deployment caller needs permission to read the named secret (`Key Vault Secrets User` is sufficient for read-only use), and the caller must be able to resolve and reach the private Key Vault endpoint. `az.getSecret()` is evaluated by the deployment tooling before ARM deployment; it is not a mechanism for a Bicep file to read a vault created in the same deployment.

For Linux, replace the password parameter with `virtualMachineAdminSshPublicKey` and retrieve an SSH public key only if it is intentionally stored in Key Vault. Prefer keeping public keys in a non-secret parameter file and storing only private credentials as secrets.

### Virtual machine module

The VM module is disabled by default through `enableVirtualMachine=false`. When enabled, it creates a private-only VM in the dedicated `virtual-machines` subnet with no public IP, a NIC-level deny-by-default NSG, a system-assigned managed identity, Premium managed OS disk, trusted launch, secure boot, vTPM, and boot/Log Analytics diagnostics.

- Set `virtualMachineOsType=Linux` and provide `virtualMachineAdminSshPublicKey` for SSH-only administration.
- Set `virtualMachineOsType=Windows` and provide `virtualMachineAdminPassword` through a secure parameter mechanism. Do not place passwords in source control or generated templates.
- The VM name is limited to 15 characters because Azure also uses it as the computer hostname.
- The VM subnet has no public ingress path. Use approved private connectivity, Bastion, or a controlled management path for administration; do not add a public IP as a shortcut.
- VM size and image defaults are defined in `modules/virtualMachine.bicep` and should be reviewed for the target region and workload.

### Prerequisites

- Azure CLI with an authenticated account and a target resource group.
- Bicep CLI 0.47 or later.
- A subscription and region that support the selected App Service plan SKU.
- Network clients that need the storage account or App Service must run in the linked VNet or a connected network with DNS forwarding configured.
- Non-overlapping spoke and hub address spaces. The default spoke is `10.0.0.0/16`; the default hub is `10.1.0.0/16`.
- Azure RBAC permissions to create VNets, peerings, NSGs, route tables, Azure Firewall resources, role assignments, diagnostics, and private DNS links.

### Firewall behavior

- The hub contains an exact-case `AzureFirewallSubnet` using `10.1.0.0/26` by default. The configured prefix must be at least `/26` and contained in the hub address space. Do not attach a workload NSG to this subnet.
- Azure Firewall uses the Standard SKU, a Standard static public IP, DNS proxy, and a Firewall Policy.
- App Service integration traffic uses a `0.0.0.0/0` route through the firewall private IP and App Service route-all is enabled.
- Private endpoint traffic remains on the private endpoint subnet and is not routed through the firewall.
- No inbound DNAT rules are created. Public exposure must remain disabled unless a separate reviewed design adds explicit rules.
- `allowedOutboundFqdns` defaults to an empty list, so application HTTPS traffic is denied until administrators provide an approved FQDN allowlist. DNS to Azure's resolver is the only default firewall egress rule.
- NSGs deny unsolicited inbound traffic on the private endpoint and App Service integration subnets. Private endpoint network security policy is enabled, and by default only the App Service integration subnet can reach private endpoints over HTTPS; add narrowly scoped administrator/client CIDRs through `approvedPrivateEndpointSourceCidrs` when required.
- Forwarded traffic is enabled on the reciprocal peerings for firewall service chaining. Gateway transit and remote gateways remain disabled.

Azure Firewall has ongoing hourly and data-processing charges. Regional VNet peering and Log Analytics ingestion also incur charges. This design intentionally avoids Premium Firewall, global peering, NAT gateways, VPN/ExpressRoute gateways, extra public IPs, and Azure Firewall Manager unless separately approved.

### Validate and build

```powershell
bicep lint main.bicep
bicep lint modules/azureFirewall.bicep
bicep lint modules/monitoring.bicep
bicep lint modules/storage.bicep
bicep lint modules/hubNetwork.bicep
bicep lint modules/spokeNetwork.bicep
bicep lint modules/privateConnectivity.bicep
bicep lint modules/networkIntegration.bicep
bicep lint modules/virtualMachine.bicep
bicep lint modules/keyVault.bicep
bicep lint modules/appService.bicep
bicep lint modules/vnet.bicep

bicep build main.bicep
bicep build modules/azureFirewall.bicep --stdout
bicep build modules/monitoring.bicep --stdout
bicep build modules/storage.bicep --stdout
bicep build modules/hubNetwork.bicep --stdout
bicep build modules/spokeNetwork.bicep --stdout
bicep build modules/privateConnectivity.bicep --stdout
bicep build modules/networkIntegration.bicep --stdout
bicep build modules/virtualMachine.bicep --stdout
bicep build modules/keyVault.bicep --stdout
bicep build modules/appService.bicep --stdout
bicep build modules/vnet.bicep --stdout
```

### Validate against Azure

```powershell
az deployment group validate `
	--resource-group <resource-group> `
	--template-file main.bicep `
	--parameters environmentType=dev `
							 allowedOutboundFqdns='["management.azure.com","*.azurewebsites.net"]'

az deployment group what-if `
	--resource-group <resource-group> `
	--template-file main.bicep `
	--parameters environmentType=dev `
							 allowedOutboundFqdns='["management.azure.com","*.azurewebsites.net"]'
```

Use `environmentType=prod` for the Premium V3 App Service plan and production deletion protection behavior. Review the what-if output before deployment, especially the firewall subnet size, route-table association, reciprocal peerings, private endpoint placement, DNS links, and disabled public network access. Do not copy the example FQDNs into production without confirming the application's actual dependencies.

Deploy a Linux VM with an SSH public key supplied from a secure parameter file:

```powershell
az deployment group create `
	--resource-group <resource-group> `
	--template-file main.bicep `
	--parameters environmentType=dev `
							 enableVirtualMachine=true `
							 virtualMachineOsType=Linux `
							 virtualMachineAdminSshPublicKey="<ssh-public-key>" `
							 allowedOutboundFqdns='["management.azure.com"]'
```

For Windows, use an Azure CLI parameter file or interactive secure input for `virtualMachineAdminPassword`; never add the password to `main.bicep`, `main.json`, shell history, or source control. Validate the VM deployment before creating it:

```powershell
az deployment group validate `
	--resource-group <resource-group> `
	--template-file main.bicep `
	--parameters environmentType=dev `
							 enableVirtualMachine=true `
							 virtualMachineOsType=Windows `
							 virtualMachineAdminUsername=<admin-username> `
							 virtualMachineAdminPassword=<secure-password>
```

### Azure CLI administrator commands

Register and verify the network provider:

```powershell
az provider register --namespace Microsoft.Network
az provider show --namespace Microsoft.Network --query registrationState -o tsv
az account show --query "{subscription:id,tenant:tenantId}" -o table
```

Deploy after reviewing what-if:

```powershell
az deployment group create `
	--resource-group <resource-group> `
	--template-file main.bicep `
	--parameters environmentType=dev `
							 allowedOutboundFqdns='["management.azure.com","*.azurewebsites.net"]'
```

Inspect the hub, firewall, policy, and public IP:

```powershell
az network vnet show -g <resource-group> -n <hub-vnet-name> -o table
az network vnet subnet show -g <resource-group> --vnet-name <hub-vnet-name> -n AzureFirewallSubnet -o table
az network firewall show -g <resource-group> -n <firewall-name> `
	--query "{sku:sku.tier,privateIp:ipConfigurations[0].properties.privateIPAddress,policy:firewallPolicy.id}" -o json
az network firewall policy show -g <resource-group> -n <firewall-policy-name> -o json
az network public-ip show -g <resource-group> -n <firewall-public-ip-name> `
	--query "{sku:sku.name,allocation:publicIPAllocationMethod,ip:ipAddress}" -o table
```

Inspect subnet NSGs and App Service routing:

```powershell
az network vnet subnet list -g <resource-group> --vnet-name <spoke-vnet-name> -o table
az network nsg list -g <resource-group> -o table
az network nsg rule list -g <resource-group> --nsg-name <nsg-name> -o table
az network route-table show -g <resource-group> -n <route-table-name> -o json
az network route-table route list -g <resource-group> --route-table-name <route-table-name> -o table
```

Inspect reciprocal peering and DNS links:

```powershell
az network vnet peering list -g <resource-group> --vnet-name <hub-vnet-name> -o table
az network vnet peering list -g <resource-group> --vnet-name <spoke-vnet-name> -o table
az network vnet peering show -g <resource-group> --vnet-name <hub-vnet-name> -n hub-to-spoke `
	--query "{state:peeringState,forwarded:allowForwardedTraffic,gatewayTransit:allowGatewayTransit}" -o table
az network private-dns link vnet list -g <resource-group> --zone-name <private-zone-name> -o table
```

For an approved test NIC, inspect effective routes and security rules:

```powershell
az network nic show-effective-route-table -g <resource-group> -n <nic-name> -o table
az network nic list-effective-nsg -g <resource-group> -n <nic-name> -o json
```

### Safe teardown

Remove the App Service subnet route-table association first, then remove both peering resources, private DNS links, private endpoints, the firewall policy/firewall/public IP, and finally the hub VNet. Do not delete only one side of a peering. Use `az deployment group what-if` after changing the template to review destructive operations before applying them.

### Security notes

- The storage account denies public network access, blob public access, shared-key access, and TLS versions below 1.2.
- The App Service uses a system-assigned managed identity, HTTPS-only access, TLS 1.2, HTTP/2, disabled FTPS, VNet integration, and a private endpoint.
- Diagnostics are sent to the Log Analytics workspace created by the deployment.
- Do not place plaintext secrets in source-controlled Bicep parameter files, outputs, command history, or generated ARM templates. Secure references such as `az.getSecret()` in a local, ignored `.bicepparam` file are supported; use managed identity and Key Vault references for application secrets.
