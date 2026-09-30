# 03 - Admin access runbook (Bastion, point-to-site VPN, jump host)

> Owning module(s): `modules/bastion.bicep`, `modules/vpnGateway.bicep`, `modules/hubNetwork.bicep`, `modules/networkIntegration.bicep`, `modules/virtualMachine.bicep`, `modules/firewallPolicyRules.bicep` (`admin-access` group, `entra-login` collection), wired by `modules/regionStamp.bicep` and `main.bicep`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Connectivity and network security", §5 Phase 3.

## 1. Purpose and scope

This runbook gives administrators a private path into each region stamp, plus a patched, Entra-signed-in jump host, and nothing else. Every path is private and authenticated with Microsoft Entra ID:

| Path | Route | Enforced by |
|---|---|---|
| Browser or `az network bastion` → jump host (SSH 22 / RDP 3389) | Bastion in the hub → hub↔spoke peering → `management` subnet | Bastion NSG (SSH/RDP egress to the `management` subnet only), `management` NSG, NIC NSG |
| Azure VPN Client → jump host (SSH/RDP) | VPN gateway → `GatewaySubnet` route table → **Azure Firewall** → `management` subnet | Firewall `admin-access` rule group (VPN pool → `management`, TCP 22/3389 only), `management` NSG, NIC NSG |
| Azure VPN Client → private endpoints (Key Vault, Storage, App Service, HTTPS 443) | VPN gateway → peering → `private-endpoints` subnet (**direct**, not through the firewall: see `ADR-013`) | `private-endpoints` NSG (VPN pool allowed on 443 only), Entra ID authentication and RBAC on each service |

**Created, per region stamp with `deployAdminAccess = true`** (dev and prod primary by default; the prod East US warm standby only during failover):

- **Azure Bastion Standard** `bas-defenstack-<env>-<region>`, zones 1/2/3, native client (tunneling) and IP-based connect enabled, 2 scale units. Its public IP is `pip-bas-defenstack-<env>-<region>`. Session audit logs go to the central workspace.
- **VPN gateway** `vpng-defenstack-<env>-<region>`: point-to-site only, OpenVPN, Microsoft Entra ID authentication, active-active across zones 1/2/3. The SKU is `VpnGw1AZ` in dev and `VpnGw2AZ` in prod (`ADR-015`). It has two public IPs, `pip-vpng-defenstack-<env>-<region>-1` and `-2`, and a customer-controlled maintenance window `vpng-...-maintenance` (Sundays 06:00 UTC, 5 hours).
- **Gateway transit** on the hub↔spoke peering (`allowGatewayTransit` on the hub side, `useRemoteGateways` on the spoke side), so VPN clients learn the spoke routes.

**Created in every stamp, regardless of the flag:**

- `AzureBastionSubnet` (/26) with the NSG `vnet-...-hub-bastion-nsg`, and `GatewaySubnet` (/27) with the route table `vnet-...-hub-gateway-rt`. The route table sends each spoke prefix to the firewall. Both subnets are free and always exist, so turning admin access on or off never reshapes the hub.
- Hub VNet DNS set to the firewall's private IP, so VPN clients resolve `privatelink.*` names through the firewall DNS proxy (`ADR-005` amendment).
- Firewall rule group `admin-access` (priority 120): VPN client pool → `management` subnet, TCP 22/3389. It also adds the collection `entra-login` in `platform-egress`: the `management` subnet → Entra ID sign-in endpoints over HTTPS.
- An outbound SSH/RDP deny (`deny-ssh-rdp-outbound`, priority 4000) on every spoke NSG and the jump host NIC NSG. No spoke host can open SSH/RDP to another host (PSRule `Azure.NSG.LateralTraversal`).
- Admin sources are derived: the `management` NSG and NIC NSG allow SSH/RDP from `AzureBastionSubnet` and the region VPN client pool, plus any extra `managementSourceCidrs`. The `private-endpoints` NSG allows the VPN client pool on 443.

**Jump host** (`enableVirtualMachine = true`, primary region only):

- Pinned to availability zone 1.
- The `AADSSHLoginForLinux` or `AADLoginForWindows` extension is installed, so admins sign in with Entra ID.
- `Virtual Machine Administrator Login` is granted to the admin group on the VM only, when `adminGroupObjectId` is set.
- Patching belongs to Azure Update Manager: `patchMode: AutomaticByPlatform`, daily assessment, and the maintenance configuration `<vm>-patch` (critical and security updates, Sundays 02:00 UTC, 3 hours, reboot if required).
- The local administrator is kept only for break-glass access (§5.6).

**Not in scope:**

- **Defender just-in-time VM access.** It is deferred to Phase 7, which enables the Defender for Servers Plan 2 it requires (`ADR-014`).
- **PIM for the admin group.** It is tenant configuration, not Bicep, and is documented in §5.5.
- **Hub↔hub peering for cross-region admin access.** That arrives in Phase 8.

## 2. Prerequisites

- **Azure roles:**
  - The pipeline identity must be allowed to assign `Virtual Machine Administrator Login` (`1c0163c0-47e6-4577-8991-ea5c82e286e4`). `scripts/New-GitHubDeploymentIdentity.ps1` now delegates it by default, alongside `Storage Blob Data Contributor`. §4 step 3 re-applies the constrained RBAC Administrator assignment.
  - The operator running the validation steps needs `Reader` on the region resource group, plus membership of the admin group.
  - §5.3 step 4 and §5.4 (reading or setting Key Vault secrets over the VPN) also need Key Vault **data-plane** RBAC — `Key Vault Secrets Officer` (or `Key Vault Secrets User` for read-only) on the region's Key Vault, granted PIM-eligible to the admin group (§5.5). Network access alone returns `403 Forbidden`.
- **Microsoft Entra roles (tenant, one-time):**
  - `Groups Administrator` (or group owner) to create the admin group.
  - `Cloud Application Administrator` to require assignment on the Azure VPN Client enterprise application and assign the group. Assigning a group to an enterprise application requires **Microsoft Entra ID P1** on the tenant (or the assigned users).
  - `Privileged Role Administrator` to make the group PIM-eligible (§5.5; needs Microsoft Entra ID P2).
- **Provider registrations** (`Microsoft.Maintenance` is new in Phase 3):

  ```powershell
  foreach ($ns in 'Microsoft.Network', 'Microsoft.Compute', 'Microsoft.Maintenance') { az provider register --namespace $ns }
  az provider show --namespace Microsoft.Maintenance --query registrationState -o tsv
  ```

  Expected: `Registered`. Repeat until it is, which can take a few minutes.
- **Tools:**
  - Azure CLI 2.90+ with the `bastion` and `ssh` extensions: `az extension add --name bastion --upgrade; az extension add --name ssh --upgrade`.
  - Bicep CLI 0.47.16.
  - PowerShell 5.1 or 7.
  - **Azure VPN Client** on each admin workstation (§5.1).
- **Network path:** none. This runbook creates the admin path. Everything before §5 runs from any machine with Azure CLI access.
- **Stack deployed:** Phase 2 must already be deployed to the environment (runbook 01), with the firewall `afw-defenstack-<env>-<region>` provisioned.

## 3. Parameters

| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `deployPrimaryAdminAccess` (`main.bicep`) | `true` | `true` | Bastion and the VPN gateway in the primary region. Dev keeps it on so this runbook can be executed end-to-end in dev (spec §6 definition of done) |
| `deploySecondaryAdminAccess` (`main.bicep`) | `false` | `false` | The East US warm standby gets admin access only during failover (spec §1; runbook 08 in Phase 8). Flip it to `true` and redeploy to turn it on |
| `adminGroupObjectId` (`main.bicep`) | `''` | the prod admin group's object ID | The Entra group granted `Virtual Machine Administrator Login` on the jump host. Empty skips the role assignment. It is an identifier, not a secret, so commit it in `params/<env>.bicepparam` |
| `primaryAddressPlan.bastionSubnetPrefix` / `.gatewaySubnetPrefix` | *(required)* | `10.1.0.64/26` / `10.1.0.128/27` (EUS: `10.11.0.64/26` / `10.11.0.128/27`) | Hub subnets, sized to Azure's minimums. Dev: `10.21.0.64/26` / `10.21.0.128/27` |
| `primaryAddressPlan.vpnClientAddressPool` | *(required)* | `172.16.200.0/24` (EUS: `172.16.201.0/24`) | Outside every VNet, and unique per region and environment. Dev: `172.16.210.0/24` |
| `managementSourceCidrs` | `[]` | `[]` | *Extra* admin sources beyond Bastion and the VPN pool, which are always allowed. Keep it empty unless an ADR approves another source |
| `vpnGateway.bicep` `skuName` | `VpnGw2AZ` | `VpnGw2AZ` (stamp: `isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'`) | `ADR-015`; resizing within the AZ family is in place (§8) |
| `vpnGateway.bicep` `vpnClientAudience` | `c632b3df-fb67-4d84-bdcf-b95ad541b5c8` | *(default)* | The Microsoft-registered Azure VPN Client app. No app registration of our own |
| `vpnGateway.bicep` `maintenanceWindowStartDateTime` | `2026-10-04 06:00` | *(default)* | First gateway maintenance window (UTC); repeats every Sunday for 5 hours |
| `virtualMachine.bicep` `availabilityZone` | `1` | *(default)* | Zone pinning; fixed at creation |
| `virtualMachine.bicep` `patchWindowStartDateTime` | `2026-10-04 02:00` | *(default)* | First Update Manager window (UTC); repeats every Sunday for 3 hours |

Every dev example below uses `rg-defenstack-dev-wus3`, `bas-defenstack-dev-wus3`, `vpng-defenstack-dev-wus3`, firewall IP `10.21.0.4`, `management` subnet `10.20.3.0/24`, and VPN pool `172.16.210.0/24`. For prod, substitute `prod` and the prod ranges.

## 4. Step-by-step deployment

1. **Create the admin group**, once per environment. Skip this step if the group already exists.

   ```powershell
   $group = az ad group create --display-name 'sg-defenstack-dev-admins' --mail-nickname 'sg-defenstack-dev-admins' --query id -o tsv
   $group
   ```

   Check: a GUID is printed. Record it as the environment's `adminGroupObjectId`. Add the administrators, or make them PIM-eligible (§5.5) instead of permanent members.

2. **Restrict the Azure VPN Client application to the admin group.** The gateway trusts the Microsoft-registered Azure VPN Client app (`c632b3df-fb67-4d84-bdcf-b95ad541b5c8`). Unless you require assignment, **any** user in the tenant can connect.

   **Tenant-wide warning:** there is only **one** Azure VPN Client service principal per tenant, so setting `appRoleAssignmentRequired=true` applies to **every** P2S gateway in the tenant that uses audience `c632b3df-fb67-4d84-bdcf-b95ad541b5c8`, not just this project's. Before running the command below, confirm no other gateway shares that service principal:

   ```powershell
   az extension add --name resource-graph
   az graph query -q "resources | where type =~ 'microsoft.network/virtualnetworkgateways' | where properties.vpnClientConfiguration.aadAudience =~ 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8' | project name, resourceGroup, subscriptionId" -o table
   ```

   Expected: only this project's gateways are listed. If any other gateway appears, **stop** and agree with the tenant owner that every listed gateway's users are already assigned (or are members of an assigned group) before setting the flag — otherwise you lock other teams' admins out. A per-environment custom-audience app registration is the alternative that restricts assignment per gateway; it is deferred to a future ADR.

   ```powershell
   $appId = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
   $sp = az ad sp list --filter "appId eq '$appId'" --query '[0].id' -o tsv
   if (-not $sp) { $sp = az ad sp create --id $appId --query id -o tsv }
   az ad sp update --id $sp --set appRoleAssignmentRequired=true
   $body = @{ principalId = $group; resourceId = $sp; appRoleId = '00000000-0000-0000-0000-000000000000' } | ConvertTo-Json -Compress
   $body | Set-Content -Path assignment.json -Encoding ascii
   az rest --method POST --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$sp/appRoleAssignedTo" --headers 'Content-Type=application/json' --body '@assignment.json'
   Remove-Item assignment.json
   az ad sp show --id $sp --query appRoleAssignmentRequired -o tsv
   ```

   Check: the last command prints `true`, and the `az rest` call returns a JSON object whose `principalId` is the group. One service principal serves every environment, so run the `az rest` line once per environment's admin group. It is safe to repeat; a duplicate assignment returns `Permission being assigned already exists`.

3. **Let the pipeline identity assign `Virtual Machine Administrator Login`.** Follow `docs/runbooks/00b-configure-pipeline-credentials.md` §8 "Assigning an extra role from Bicep". The script's default `-DelegatableRoleDefinitionIds` already contains the role, so steps 2–3 there are all you need:
   1. Delete the existing RBAC Administrator assignment on each resource group of the environment.
   2. Re-run `scripts/New-GitHubDeploymentIdentity.ps1` with the same arguments as before.

   Check:

   ```powershell
   az role assignment list --assignee <pipeline-app-id> --resource-group rg-defenstack-dev-wus3 --role 'Role Based Access Control Administrator' --query '[0].condition' -o tsv
   ```

   Expected: the condition contains both `ba92f5b4-2d11-453d-a403-e96b0029c9fe` and `1c0163c0-47e6-4577-8991-ea5c82e286e4`.

4. **Set the environment's parameters** in a PR. Add the group to `params/dev.bicepparam` (or `prod.bicepparam`):

   ```bicep
   param adminGroupObjectId = '<group object ID from step 1>'
   ```

   To deploy the jump host, also set `enableVirtualMachine = true`. Supply its SSH public key (Linux) or password (Windows) only through a git-ignored `params/dev.local.bicepparam` overlay, never in the committed file (runbook 01 §3).

5. **Validate and preview**, from the repository root:

   ```powershell
   az deployment sub validate --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
   az deployment sub what-if --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
   ```

   `validate` must end with `"provisioningState": "Succeeded"`. In the what-if, check for exactly these changes in `rg-defenstack-dev-wus3`:
   - **Create:**
     - `bas-defenstack-dev-wus3`, `pip-bas-defenstack-dev-wus3`.
     - `vpng-defenstack-dev-wus3`, `pip-vpng-defenstack-dev-wus3-1`, `pip-vpng-defenstack-dev-wus3-2`, `vpng-defenstack-dev-wus3-maintenance`.
     - `vnet-defenstack-dev-wus3-hub-bastion-nsg`, `vnet-defenstack-dev-wus3-hub-gateway-rt`.
     - Rule collection group `admin-access`.
     - With the VM: the `AADSSHLoginForLinux` extension, `<vm>-patch`, and a role assignment.
   - **Modify:**
     - The hub VNet (`dhcpOptions.dnsServers` = `10.21.0.4`; subnets `AzureBastionSubnet`, `GatewaySubnet`).
     - Both peerings (`allowGatewayTransit` / `useRemoteGateways` → `true`).
     - The three spoke NSGs (new `deny-ssh-rdp-outbound`; `management` sources now `10.21.0.64/26`, `172.16.210.0/24`; `private-endpoints` sources now include `172.16.210.0/24`).
     - `platform-egress` (new `entra-login` collection).
   - **No Delete** anywhere, and no change to the firewall, App Service, Key Vault or Storage.
   - If the jump host already exists from before Phase 3, the what-if shows a zone change on the VM: it cannot be applied in place (§9).

   Stop if the what-if shows the firewall or the spoke VNet being **recreated**.

6. **Deploy through the pipeline**: GitHub → Actions → `deploy` → **Run workflow** → environment `dev` (prod: the two-approval flow in `ADR-012`). Or deploy from a workstation:

   ```powershell
   az deployment sub create --name "admin-access-$(Get-Date -Format yyyyMMddHHmm)" --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
   ```

   Expect 30–45 minutes; the VPN gateway dominates. Check: `"provisioningState": "Succeeded"`.

7. **Record the outputs** for §5 and §6:

   ```powershell
   # Newest subscription deployment that has the Phase 3 outputs (pipeline runs are named gh-<run id>-<attempt>).
   $d = az deployment sub list --query "sort_by([?properties.outputs.primaryBastionName], &properties.timestamp)[-1].name" -o tsv
   az deployment sub show --name $d --query "properties.outputs.{rg:primaryResourceGroupName.value, bastion:primaryBastionName.value, gateway:primaryVpnGatewayName.value, firewallIp:primaryFirewallPrivateIp.value}" -o table
   ```

   Expected: `rg-defenstack-dev-wus3`, `bas-defenstack-dev-wus3`, `vpng-defenstack-dev-wus3`, `10.21.0.4`. **The firewall IP must be the `.4` address of `AzureFirewallSubnet`.** The `GatewaySubnet` route table and the hub DNS were built for that address before the firewall existed (`ADR-013`). If the output shows any other address, stop and follow §9, row "firewall IP is not `.4`".

## 5. Manual and post-deployment steps

### 5.1 VPN client setup (per operating system)

1. **Generate the profile.** Run this once after each deployment that changes the gateway, DNS or pool:

   ```powershell
   $url = az network vnet-gateway vpn-client generate --name vpng-defenstack-dev-wus3 --resource-group rg-defenstack-dev-wus3 -o tsv
   Invoke-WebRequest -Uri $url -OutFile vpn-profile.zip
   Expand-Archive vpn-profile.zip -DestinationPath vpn-profile -Force
   Get-Content vpn-profile\AzureVPN\azurevpnconfig.xml | Select-String 'dnsserver|audience|issuer'
   ```

   Check: the file shows audience `c632b3df-fb67-4d84-bdcf-b95ad541b5c8`, an issuer ending in your tenant ID, and `<dnsserver>10.21.0.4</dnsserver>`. If `dnsserver` is missing, the hub DNS change had not applied when the profile was generated. Regenerate it. If it is still missing, add this inside `<clientconfig>` by hand: `<dnsservers><dnsserver>10.21.0.4</dnsserver></dnsservers>`.
2. **Windows 10/11:**
   1. Install **Azure VPN Client** from the Microsoft Store (`winget install 9NP355QT2SQB`).
   2. Open it, choose **+** → **Import**, pick `azurevpnconfig.xml`, then **Save**.
   3. Choose **Connect** and sign in with your Entra account.
3. **macOS:**
   1. Install **Azure VPN Client** from the Mac App Store.
   2. Choose **Import**, pick `azurevpnconfig.xml`, then **Save**.
   3. Choose **Connect** and approve the system VPN prompt the first time.
4. **Linux (Ubuntu 20.04 / 22.04):**

   ```bash
   curl -sSL https://packages.microsoft.com/keys/microsoft.asc | sudo tee /etc/apt/trusted.gpg.d/microsoft.asc
   sudo apt-add-repository "https://packages.microsoft.com/ubuntu/$(lsb_release -rs)/prod"
   sudo apt-get update && sudo apt-get install -y microsoft-azurevpnclient
   ```

   Open **Azure VPN Client**, choose **Import**, pick `azurevpnconfig.xml`, then **Connect**.
5. **Distribute the profile.** It contains no secrets (authentication is Entra ID), but share it only through the team's internal channel. Tell admins to delete old profiles whenever you regenerate one.

### 5.2 Connect through Bastion

- **Portal:** open the VM → **Connect** → **Bastion**. Choose **Microsoft Entra ID** authentication (Linux; Windows needs the native client below).
- **Native client, Linux jump host (Entra ID):**

  ```powershell
  $vmId = az vm list --resource-group rg-defenstack-dev-wus3 --query '[0].id' -o tsv
  az network bastion ssh --name bas-defenstack-dev-wus3 --resource-group rg-defenstack-dev-wus3 --target-resource-id $vmId --auth-type AAD
  ```

- **Native client, Windows jump host (Entra ID; Windows workstation only):**

  ```powershell
  az network bastion rdp --name bas-defenstack-dev-wus3 --resource-group rg-defenstack-dev-wus3 --target-resource-id $vmId --enable-mfa
  ```

- Besides `Virtual Machine Administrator Login`, the admin needs `Reader` on the Bastion host, the VM and its NIC. Grant `Reader` on `rg-defenstack-<env>-<region>` to the admin group through PIM (§5.5).

### 5.3 Connect over the VPN

1. Connect the Azure VPN Client (§5.1).
2. Linux jump host (Entra ID; `az ssh` fetches a short-lived certificate):

   ```powershell
   $ip = az vm list-ip-addresses --resource-group rg-defenstack-dev-wus3 --query '[0].virtualMachine.network.privateIpAddresses[0]' -o tsv
   az ssh vm --ip $ip
   ```

3. Windows jump host: `mstsc` → **Show Options** → **Advanced** → check **Use a web account to sign in to the remote computer**, computer = the private IP, then sign in with your Entra account.
4. Private endpoints are reachable directly, for example `az keyvault secret list --vault-name <kv>` from the admin workstation while connected.

### 5.4 Deploy-time secrets through the VPN

The README's `az keyvault secret set` flow needs a network path to the Key Vault private endpoint. Run it from a workstation connected to the VPN (§5.3). No temporary public-access exception is needed any more.

### 5.5 Just-in-time membership with PIM (tenant configuration)

1. In Entra admin center → **Identity Governance** → **Privileged Identity Management** → **Groups**, onboard `sg-defenstack-<env>-admins`.
2. Set the **Member** role settings:
   - Maximum activation **4 hours**.
   - Require **MFA**.
   - Require **justification**.
   - Prod only: require **approval** by a second admin.
3. **Assignments** → **Add assignments** → role **Member** → type **Eligible** for each administrator. Remove any permanent (active) members except the break-glass review (§5.6).
4. To also grant `Reader` on the region resource group (for Bastion), add an **eligible** Azure role assignment on `rg-defenstack-<env>-<region>` for the group. Resource-group RBAC outside the template is intentionally not managed by Bicep.
5. Admins activate before connecting: **My roles** → **Groups** → **Activate**. Tokens pick up the new membership at the next sign-in, so reconnect the VPN after activating.

### 5.6 Break-glass

Use these procedures only when the normal paths fail. Record every use in the incident log, and rotate the local credential afterwards.

| Failure | Path | Procedure |
|---|---|---|
| Entra sign-in to the VM fails, but Entra ID itself is up (extension broken, role missing) | Bastion with the **local administrator** | Linux: `az network bastion ssh ... --auth-type ssh-key --username azureadmin --ssh-key <private key file>`. The private key is kept offline by the platform owner, never in the repository. Windows: `az network bastion rdp` with the local password from Key Vault (read it over the VPN) |
| VPN gateway down or misconfigured | Bastion (portal or native client) | §5.2 |
| Bastion down | VPN, then SSH with the local key to the private IP | `ssh -i <key> azureadmin@<private IP>` over the VPN |
| Both network paths down | Control plane only | `az vm run-command invoke --resource-group rg-defenstack-dev-wus3 --name <vm> --command-id RunShellScript --scripts 'systemctl status sshd'` (Windows: `RunPowerShellScript`), or the portal **Serial console**. Boot diagnostics are managed, so the serial console needs no storage account |
| Entra ID outage (no user can sign in) | Tenant emergency-access accounts | Use the organisation's cloud-only emergency-access accounts, which are excluded from Conditional Access, to reach the portal, then the row above. Creating and testing those accounts is a tenant responsibility, reviewed quarterly |
| Local credential lost | Reset through the control plane | Linux: `az vm user update --resource-group rg-defenstack-dev-wus3 --name <vm> --username azureadmin --ssh-key-value <new public key>`. Windows: the same command with `--password` |

## 6. Validation

Run everything from the repository root in PowerShell. VPN rows need the Azure VPN Client connected.

| Check | Command | Expected result |
|---|---|---|
| Bastion SKU and features | `az network bastion show -n bas-defenstack-dev-wus3 -g rg-defenstack-dev-wus3 --query "{sku:sku.name,tunneling:enableTunneling,ipConnect:enableIpConnect,zones:zones}" -o json` | `"sku": "Standard"`, `"tunneling": true`, `"ipConnect": true`, zones `1,2,3` |
| Gateway configuration | `az network vnet-gateway show -n vpng-defenstack-dev-wus3 -g rg-defenstack-dev-wus3 --query "{sku:sku.name,activeActive:activeActive,auth:vpnClientConfiguration.vpnAuthenticationTypes,protocols:vpnClientConfiguration.vpnClientProtocols,pool:vpnClientConfiguration.vpnClientAddressPool.addressPrefixes}" -o json` | `VpnGw1AZ` (prod `VpnGw2AZ`), `true`, `["AAD"]`, `["OpenVPN"]`, `["172.16.210.0/24"]` |
| Gateway maintenance window | `az maintenance assignment list --resource-group rg-defenstack-dev-wus3 --provider-name Microsoft.Network --resource-type virtualNetworkGateways --resource-name vpng-defenstack-dev-wus3 --query "[].maintenanceConfigurationId" -o tsv` | Ends in `/vpng-defenstack-dev-wus3-maintenance` |
| Firewall IP matches the precomputed route/DNS target | `az network firewall show -n afw-defenstack-dev-wus3 -g rg-defenstack-dev-wus3 --query "ipConfigurations[0].privateIPAddress" -o tsv` | `10.21.0.4` |
| Hub DNS | `az network vnet show -n vnet-defenstack-dev-wus3-hub -g rg-defenstack-dev-wus3 --query dhcpOptions.dnsServers -o tsv` | `10.21.0.4` |
| GatewaySubnet route | `az network route-table route list --route-table-name vnet-defenstack-dev-wus3-hub-gateway-rt -g rg-defenstack-dev-wus3 --query "[].{prefix:addressPrefix,hop:nextHopIpAddress}" -o table` | `10.20.0.0/16` → `10.21.0.4` |
| Gateway transit | `az network vnet peering show -g rg-defenstack-dev-wus3 --vnet-name vnet-defenstack-dev-wus3-spoke -n spoke-to-hub --query "{useRemoteGateways:useRemoteGateways,state:peeringState}" -o json` | `true`, `Connected` |
| Jump host routes skip the gateway | `az network nic show-effective-route-table -g rg-defenstack-dev-wus3 -n <vm>-nic --query "value[?source=='User' \|\| source=='VirtualNetworkGateway'].{source:source,prefix:addressPrefix[0],hop:nextHopIpAddress[0]}" -o table` | Only `User  0.0.0.0/0  10.21.0.4`; **no** `VirtualNetworkGateway` rows (BGP propagation is disabled, F2) |
| VPN: DNS resolves privately | `Resolve-DnsName <kv>.vault.azure.net` | Final `A` record in `10.20.1.0/24` (a `privatelink.vaultcore.azure.net` CNAME in the chain) |
| VPN: private endpoint reachable | `Test-NetConnection <kv>.vault.azure.net -Port 443` | `TcpTestSucceeded : True` |
| VPN: SSH to the jump host through the firewall | `az ssh vm --ip <vm private IP>` then `exit` | Shell prompt as your Entra UPN |
| VPN: only 22/3389 reach the jump host | `Test-NetConnection <vm private IP> -Port 80` | `TcpTestSucceeded : False` |
| Firewall logged the admin session | Workspace KQL: `AZFWNetworkRule \| where TimeGenerated > ago(1h) and SourceIp startswith "172.16.210." and DestinationPort == 22 \| project TimeGenerated, SourceIp, DestinationIp, Action, Rule` | At least one row, `Action == "Allow"`, `Rule == "vpn-ssh-rdp"` |
| Bastion: Entra SSH works | §5.2 native client command | Shell prompt as your Entra UPN |
| Bastion session audited | `MicrosoftAzureBastionAuditLogs \| where TimeGenerated > ago(1h) \| project TimeGenerated, UserName, TargetVMIPAddress, Protocol` | A row for your session |
| Entra login extension | `az vm extension list -g rg-defenstack-dev-wus3 --vm-name <vm> --query "[].{name:name,state:provisioningState}" -o table` | `AADSSHLoginForLinux` (or `AADLoginForWindows`) and `AzureMonitorLinuxAgent`, both `Succeeded` |
| Update Manager schedule | `az maintenance assignment list --resource-group rg-defenstack-dev-wus3 --provider-name Microsoft.Compute --resource-type virtualMachines --resource-name <vm> --query "[].maintenanceConfigurationId" -o tsv` | Ends in `/<vm>-patch` |
| Admin role on the VM only | `az role assignment list --scope $vmId --role 'Virtual Machine Administrator Login' --query "[].principalId" -o tsv` | The admin group object ID |
| No lateral SSH/RDP from the spoke | `az network nsg rule show -g rg-defenstack-dev-wus3 --nsg-name vnet-defenstack-dev-wus3-spoke-private-endpoints-nsg -n deny-ssh-rdp-outbound --query "{access:access,dir:direction,ports:destinationPortRanges}" -o json` | `Deny`, `Outbound`, `["22","3389"]` |

Paste the outputs of every row into the Phase 3 PR (spec §6 definition of done).

## 7. Rollback

What cannot be rolled back automatically: the hub subnets, hub DNS, NSG rules and firewall rules are part of every stamp from Phase 3 on. Deploying a Phase 2 commit leaves them in place, because incremental mode never deletes. They are inert without the gateway and Bastion.

**Turn admin access off** (for example, to stop gateway and Bastion charges in dev):

1. Set `param deployPrimaryAdminAccess = false` (or `deploySecondaryAdminAccess = false`) in the environment's param file, and redeploy (§4 steps 5–6). This switches the peerings back to `useRemoteGateways: false`. **Do this first:** Azure refuses to delete a gateway that a peering still uses. The hub and spoke peering updates can race when turning admin access off; if the deployment fails with a gateway-transit / `UseRemoteGateways` error, re-run the same deployment once (the second run sees the spoke already updated).
2. Delete the resources the template no longer manages:

   ```powershell
   $rg = 'rg-defenstack-dev-wus3'
   az network bastion delete -n bas-defenstack-dev-wus3 -g $rg --yes
   az network vnet-gateway delete -n vpng-defenstack-dev-wus3 -g $rg
   az maintenance configuration delete --resource-group $rg --resource-name vpng-defenstack-dev-wus3-maintenance --yes
   az network public-ip delete -g $rg -n pip-bas-defenstack-dev-wus3
   az network public-ip delete -g $rg -n pip-vpng-defenstack-dev-wus3-1
   az network public-ip delete -g $rg -n pip-vpng-defenstack-dev-wus3-2
   ```

   Check: `az resource list -g $rg --query "[?contains(name,'bas-') || contains(name,'vpng-')].name" -o tsv` prints nothing. The gateway delete takes up to 20 minutes.

**Remove the jump host's Phase 3 additions** (keep the VM):

```powershell
az vm extension delete -g $rg --vm-name <vm> -n AADSSHLoginForLinux
az role assignment delete --scope $vmId --role 'Virtual Machine Administrator Login'
az maintenance assignment delete --resource-group $rg --provider-name Microsoft.Compute --resource-type virtualMachines --resource-name <vm> --configuration-assignment-name <vm>-patch --yes
```

The VM's zone cannot be changed without recreating the VM.

## 8. Operations

- **Adding or removing an admin:** change PIM eligibility or group membership (§5.5). Nothing to redeploy; the change applies at the admin's next sign-in.
- **Profile redistribution:** regenerate and redistribute (§5.1) after any change to the gateway, pool, DNS or tenant. Old profiles keep working only until the gateway's public IPs or pool change.
- **Resizing the gateway:** change the stamp's SKU expression (`modules/regionStamp.bicep`) within the AZ family, for example `VpnGw1AZ` → `VpnGw2AZ`, and redeploy. The resize happens in place, with a short reconnect for clients. Moving between generations or to non-AZ SKUs is not supported in place.
- **Bastion scale:** `scaleUnits` (default 2, in `modules/bastion.bicep`) sets the number of concurrent sessions. Raise it only when `MicrosoftAzureBastionAuditLogs` shows sessions being refused.
- **Patch window changes:** edit `patchWindowStartDateTime` (VM) or `maintenanceWindowStartDateTime` (gateway) and redeploy. Check Update Manager → **History** the Monday after each window, and investigate any `Failed` run.
- **Rotating the local administrator:** rotate yearly, and after every break-glass use (§5.6, last row).
- **Failover:** set `deploySecondaryAdminAccess = true` and redeploy. Budget 45 minutes for the East US gateway (runbook 08 in Phase 8).
- **Monthly review:**
  - Bastion sessions: `MicrosoftAzureBastionAuditLogs | summarize count() by UserName, bin(TimeGenerated, 1d)`.
  - P2S connections: `AzureDiagnostics | where Category == "P2SDiagnosticLog"`.
  - Firewall admin sessions: `AZFWNetworkRule | where Rule == "vpn-ssh-rdp"`.
  - Confirm every user is a current, PIM-eligible admin.
- **Cost drivers:** the VPN gateway (hourly, per SKU), Bastion Standard (hourly, per scale unit), three Standard public IPs, and outbound data for sessions (`docs/cost.md` "Phase 3 delta"). In dev, turning admin access off between test windows (§7) removes the two largest items.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| Azure VPN Client: `AADSTS50105: ... not assigned to a role for the application` | The user is not an (active) member of the admin group, and assignment is required (§4 step 2) | Activate the PIM membership (§5.5), or add the user to the group; reconnect |
| Azure VPN Client connects, but `Resolve-DnsName <kv>.vault.azure.net` returns a public IP | The profile has no `dnsserver`, or the client is using the workstation's DNS | Regenerate the profile after the hub DNS change (§5.1); check `<dnsserver>10.21.0.4</dnsserver>` |
| Deployment: `UseRemoteGateways ... remote virtual network ... does not have any gateways` or `RemoteVnetHasNoGateways` | The spoke peering was updated before the gateway existed, for example after a manual gateway delete while the flag stayed `true` | Keep the flag and the gateway consistent: redeploy with the flag `true` (recreates the gateway first), or follow §7 step 1 |
| Deployment: `NetworkSecurityGroupNotCompliantForAzureBastionSubnet` | Someone edited the Bastion NSG, so a required rule is missing | Redeploy; the template restores the required rules in `modules/hubNetwork.bicep` |
| Deployment: `InUseSubnetCannotBeDeleted` for `GatewaySubnet` or `AzureBastionSubnet` | A Phase 2 (pre-Phase 3) commit was deployed after the admin resources existed | Deploy Phase 3 or later; never remove the hub subnets while a gateway or Bastion uses them |
| The firewall IP is not `.4` (§4 step 7) | The firewall was created in a non-empty `AzureFirewallSubnet`, or the subnet prefix changed | VPN traffic to the spoke would be black-holed. Set `firewallPrivateIp` in `modules/regionStamp.bicep` to the actual IP (temporary override), redeploy, and open an issue to revisit `ADR-013` |
| `az network bastion ssh`: `Bastion Host SKU must be Standard or Premium and Native Client must be enabled` | Wrong Bastion, or the Bastion was modified outside Bicep | Check the §6 Bastion row; redeploy |
| `az ssh vm` / Bastion Entra login: `Permission denied` or `not authorized` | The user lacks `Virtual Machine Administrator Login` (PIM not activated, or `adminGroupObjectId` empty), or the extension failed | Activate PIM; check the §6 role and extension rows. Extension failed on Linux: `packages.microsoft.com` is blocked, so check `AZFWApplicationRule` for denies from the `management` subnet |
| SSH over the VPN times out, but works over Bastion | The firewall is denying (`AZFWNetworkRule` shows `Deny`), or the client is outside the pool | Check the client IP is in `172.16.210.0/24`; check the `admin-access` group exists on the policy (`az network firewall policy rule-collection-group list --policy-name afwp-defenstack-dev-wus3 -g $rg -o table`) |
| A private endpoint is unreachable over the VPN, but DNS is correct | The `private-endpoints` NSG does not list the VPN pool, or the client has stale routes | Check the NSG `allow-approved-https` sources include the pool; disconnect and reconnect the VPN client |
| Update Manager run `Failed` with `ReadyForPatching` or `NotReady` | The VM was off or the agent was unhealthy during the window | Start the VM before the window, or trigger **One-time update** in Update Manager; check `AzureMonitorLinuxAgent` health |
| `az rest ... appRoleAssignedTo`: `Permission being assigned already exists on the object` | The group is already assigned | Nothing to do |
| Deployment error mentioning `allowGatewayTransit` / `UseRemoteGateways` while turning admin access off | The hub and spoke peering updates raced (§7) | Re-run the same deployment once; the second run sees the spoke already updated |
| Deployment error that `zones` cannot be changed / `PropertyChangeNotAllowed` on the VM | An existing jump host was created before Phase 3; the availability zone is fixed at creation | Delete and recreate the VM (the OS disk has `deleteOption: Delete`; nothing is stored on it by design), then redeploy |
