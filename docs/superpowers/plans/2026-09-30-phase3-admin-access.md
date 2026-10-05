# Phase 3: Admin Access (Bastion, Point-to-Site VPN, Jump Host) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give administrators a private, Entra ID-authenticated way into each region stamp. That means Azure Bastion, an active-active point-to-site VPN gateway, VPN routing through the firewall, and a jump host that signs admins in with Entra ID and is patched by Update Manager. No spoke host can open SSH/RDP to another host.

**Architecture:**
- `modules/hubNetwork.bicep` gains two subnets, which always exist:
  - `AzureBastionSubnet`, with an NSG holding Microsoft's required rules. Its SSH/RDP egress is narrowed to the `management` subnet.
  - `GatewaySubnet`, with a route table that sends each spoke prefix to the firewall.
- The hub's DNS server becomes the firewall IP. That IP is computed as `cidrHost(firewallSubnetPrefix, 3)`, because the hub exists before the firewall (ADR-013).
- Two new modules, `modules/bastion.bicep` and `modules/vpnGateway.bicep`, are deployed per stamp behind `deployAdminAccess`. It is on in the primary region and off in the East US warm standby.
- The hub↔spoke peering turns on gateway transit when the gateway exists.
- The shared firewall rules gain an `admin-access` group (VPN pool → `management`, 22/3389) and an `entra-login` collection for the jump host.
- The jump host (`modules/virtualMachine.bicep`) gains:
  - zone pinning
  - the Entra login extension
  - `Virtual Machine Administrator Login` for an admin group
  - Update Manager patching
- VPN traffic to private endpoints goes direct and is NSG-enforced (ADR-013).

**Tech Stack:** Bicep CLI 0.47.16, Azure CLI 2.90+, Windows PowerShell 5.1 / pwsh 7, Pester 5.x, PSRule.Rules.Azure 1.47.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`. The relevant parts are:
- §1 (address plan, availability balance)
- §2 F1/F2 (management isolation, GatewaySubnet route table)
- §3 "Connectivity and network security" (Bastion, VPN gateway, management jump host)
- §5 Phase 3
- §6 documentation standard

This plan builds on Phase 2 (`docs/superpowers/plans/2026-09-28-phase2-firewall-premium.md`). The branch `phase3-admin-access` is stacked on `phase2-firewall-premium` (commit `0f87b21`).

**Verification status of this plan:** every Bicep module, test, script and document below was prototyped and run before the plan was written. The reference commits are `phase3-proto-t1` (Task 1 state) and `phase3-prototype` (Task 2 and Task 3 state); they are local branches, not for merge.
- `bicep lint` and `bicep build` are clean for every file.
- `main.json` is in sync with `bicep build main.bicep`.
- The full Pester suite passes: 191 → **245** (after Task 1) → **257** (Task 2) → **266** (Task 3).
- `Invoke-PSRule` evaluates **752** results with **0** failures after Task 1 and after Task 3.

The embedded content is that verified content. Transcribe it exactly.

## Global Constraints

- **User decisions (binding, taken when this plan was written):**
  - Dev gets **Bastion Standard plus a `VpnGw1AZ` gateway**; prod uses `VpnGw2AZ` (ADR-015).
  - **Defender JIT is deferred to Phase 7** (ADR-014).
  - **VPN traffic to private endpoints goes direct and is NSG-enforced**, not forced through the firewall (ADR-013).
- **Spec values (verbatim):**
  - Hub subnets `AzureFirewallSubnet` /26, `AzureBastionSubnet` /26, `GatewaySubnet` /27.
  - P2S client pool `172.16.200.0/24` (prod WUS3).
  - VPN: OpenVPN with **Microsoft Entra ID authentication**, restricted to an admin security group through app assignment.
  - Hub-to-spoke peering switched to `allowGatewayTransit` / `useRemoteGateways`.
  - "The VPN client profile uses the firewall private IP as its DNS server".
  - Bastion Standard: zone-redundant, native-client and IP-based connect, Bastion NSG with the Microsoft-required rules.
  - Jump host: Entra ID login extension (`AADSSHLoginForLinux` / `AADLoginForWindows`) with the `Virtual Machine Administrator Login` role for the admin group; Azure Update Manager maintenance configuration; availability zone pinning.
  - DR region: Bastion and the VPN gateway sit behind a flag and are switched on during failover.
- **Address plan (derived, fixed by this plan):**
  - Bastion = `<hub>.0.64/26`, Gateway = `<hub>.0.128/27`.
  - VPN pools: prod WUS3 `172.16.200.0/24`, prod EUS `172.16.201.0/24`, dev `172.16.210.0/24`.
  - The firewall IP is always `cidrHost(firewallSubnetPrefix, 3)` (`.4`).
- **Greenfield:** no stack is deployed yet (Phase 0's dev rollout is still pending), so zone pinning the VM and adding required address-plan fields are not migrations. Do not write an upgrade procedure.
- **Unchanged from Phase 2:**
  - Firewall Premium, IDPS and threat-intel modes.
  - Rule collection groups on one policy update one at a time (`dependsOn` chain).
  - Prod-only `CanNotDelete` locks.
  - The two-approval prod deploy flow.
  - API versions for existing resource types.
- **New API versions:**
  - `Microsoft.Network/bastionHosts@2024-07-01`
  - `Microsoft.Network/virtualNetworkGateways@2024-07-01`
  - `Microsoft.Maintenance/maintenanceConfigurations@2023-04-01`
  - `Microsoft.Maintenance/configurationAssignments@2023-04-01`
  - `Microsoft.Authorization/roleAssignments@2022-04-01`
  - Public IPs keep `@2025-01-01`.
- **Linter:** `no-hardcoded-env-urls` is an error. Derive Entra hosts from `environment().authentication.loginEndpoint`; never write `login.microsoftonline.com` literally.
- **main.json is generated:** after any `.bicep` change run `bicep build main.bicep` and commit `main.json`.
- **PSRule:** 0 failures. Remove the `Azure.NSG.LateralTraversal` exclusion; only the Bastion NSGs are suppressed, by name. Keep `AZURE_BICEP_FILE_EXPANSION_TIMEOUT: 60`, because the 5 s default times out once the Phase 3 modules are included.
- **Docs are mandatory:** runbooks use the 9-section template (`docs/runbooks/_template.md`).
- **Tests must run on both shells:** Windows PowerShell 5.1 and pwsh 7.
- **No live Azure/Entra/GitHub commands; no push.** Runbook 03 §4–§6 are executed later by a human in dev (spec §6 definition of done).
- **Commit trailers:** `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
- **Build output:** never commit `modules/*.json`, which is git-ignored.
- **Compiled-expression gotchas:**
  - A ternary module parameter compiles to `[if(cond, createObject('value', a), createObject('value', b))]`, with no `.value`.
  - Hub subnet names compile to `[variables('<x>SubnetName')]`.
  - Resource-level loops land in `.copy`; property loops land in `properties.copy[]`.
  - An NSG whose rules use `concat()` compiles to a single string.
  - `ConvertTo-Json` escapes `'` as `'`, so never regex-match `ConvertTo-Json` output for quoted expressions.
- **Windows PowerShell 5.1 file encoding:** a helper `.ps1` containing non-ASCII characters (—, →, ↔) must be saved with a UTF-8 BOM, or 5.1 misreads it.

## Review Focus

These are inputs and conditions the spec implies but no offline test can fully exercise, most likely first:

1. **The deployed firewall IP is not `.4`.** The `GatewaySubnet` route and the hub DNS target the computed `cidrHost(firewallSubnetPrefix, 3)`; if the firewall lands elsewhere, VPN-to-spoke traffic and VPN DNS black-hole. Pinned by the Task 1 stamp test "routes GatewaySubnet spoke traffic to the first usable firewall address", plus the runbook 03 §4 step 7 / §6 runtime check (Task 3).
2. **Turning admin access on or off in the wrong order.** Setting `useRemoteGateways` without a gateway fails the deployment, and deleting a gateway that a peering still uses fails. Pinned by the Task 1 tests "turns on gateway transit only with admin access, after the gateway is provisioned" and "is off by default"; the rollback order is in runbook 03 §7.
3. **A tenant user who is not an admin connects to the VPN.** The Microsoft-registered VPN app admits every tenant user unless assignment is required. Pinned by the Task 3 docs test "restricts the VPN app to the admin group" (`appRoleAssignmentRequired=true`).
4. **Overlapping VPN pools.** An admin connected to dev and prod at once, or a pool inside a VNet range, breaks routing. Pinned by the Task 1 Params tests "gives every region and environment its own VPN client pool" and "keeps every VPN client pool outside every VNet".
5. **Bastion NSG missing a Microsoft-required rule.** Bastion creation fails with `NetworkSecurityGroupNotCompliantForAzureBastionSubnet`. Pinned by the Task 1 HubNetwork tests on each required rule.

Known coverage gap: PSRule does not evaluate the jump host, because the committed parameter files set `enableVirtualMachine = false`. The jump host's Azure rules are therefore checked only by Pester (Task 2) and the dev rollout (runbook 03 §6).

## Execution Notes

- **Full suite:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`. It prints `Tests Passed: N, Failed: 0`.
- **Some files only:** `-File` passes a comma list as one string, so use `-Command`:

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { `$f = @('tests/Bastion.Tests.ps1','tests/VpnGateway.Tests.ps1'); & ./tests/Invoke-Tests.ps1 -Path `$f }"
  ```

- **PSRule** (same as runbook 00 §8):

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
  ```

  Expected: no failed rules. `Invoke-PSRule` (the same arguments without `-Outcome`) counts 752 results.
- **Drift check:** `bicep build main.bicep --stdout | diff - main.json` must print nothing.

## File Map

| File | Responsibility | Task |
|---|---|---|
| `modules/types.bicep` (replace) | `regionAddressPlan` + `bastionSubnetPrefix`, `gatewaySubnetPrefix`, `vpnClientAddressPool` | 1 |
| `params/dev.bicepparam`, `params/prod.bicepparam` (replace) | New subnet prefixes and VPN pools | 1 |
| `modules/hubNetwork.bicep` (replace) | Bastion subnet + NSG, GatewaySubnet + route table, hub DNS = firewall IP | 1 |
| `modules/bastion.bicep` (new) | Bastion Standard, zonal public IP, diagnostics | 1 |
| `modules/vpnGateway.bicep` (new) | Active-active P2S gateway (OpenVPN, Entra ID), 2 public IPs, maintenance window, diagnostics | 1 |
| `modules/spokeNetwork.bicep` (replace) | `deny-ssh-rdp-outbound` on every spoke NSG | 1 |
| `modules/networkIntegration.bicep` (replace) | `useHubGateway` → gateway transit on the peerings | 1 |
| `modules/azureFirewall.bicep` (replace) | `vpnClientAddressPrefixes` passed to the rules module | 1 |
| `modules/firewallPolicyRules.bicep` (replace) | `admin-access` group (120) in the chain; Task 2 adds `entra-login` | 1, 2 |
| `modules/regionStamp.bicep` (replace) | Admin access wiring, derived admin sources, computed firewall IP, outputs; Task 2 adds `adminGroupObjectId` | 1, 2 |
| `main.bicep` (replace), `main.json` (regenerate) | `deployPrimaryAdminAccess`, `deploySecondaryAdminAccess`, outputs; Task 2 adds `adminGroupObjectId` | 1, 2 |
| `ps-rule.yaml`, `.ps-rule/Suppression.Rule.yaml` (replace) | Drop the LateralTraversal exclusion, expansion timeout, Bastion NSG suppression | 1 |
| `tests/Bastion.Tests.ps1`, `tests/VpnGateway.Tests.ps1` (new); `tests/HubNetwork.Tests.ps1`, `tests/SpokeNetwork.Tests.ps1`, `tests/NetworkIntegration.Tests.ps1`, `tests/FirewallPolicyRules.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Main.Tests.ps1`, `tests/Params.Tests.ps1` (replace) | Task 1 tests | 1 |
| `modules/virtualMachine.bicep` (replace) | Zone pin, Entra login, VM Administrator Login role, Update Manager, NIC outbound deny | 2 |
| `scripts/New-GitHubDeploymentIdentity.ps1` (edit) | Default delegatable roles + `Virtual Machine Administrator Login` | 2 |
| `tests/VirtualMachine.Tests.ps1`, `tests/FirewallPolicyRules.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Main.Tests.ps1` (replace); `tests/Scripts.Tests.ps1` (edit) | Task 2 tests | 2 |
| `docs/runbooks/03-admin-access.md`, `docs/decisions/ADR-013-*`, `ADR-014-*`, `ADR-015-*` (new) | Phase 3 runbook and ADRs | 3 |
| `docs/architecture/overview.md`, `docs/cost.md`, `docs/decisions/ADR-005-*`, `docs/runbooks/00-*`, `00b-*`, `01-*`, `README.md` (edit); `tests/Docs.Tests.ps1` (replace) | Phase 3 doc updates and docs tests | 3 |

---

### Task 1: Hub admin subnets, Bastion, point-to-site VPN gateway, gateway transit, and VPN routing through the firewall

**Files:**
- Create: `modules/bastion.bicep`, `modules/vpnGateway.bicep`, `tests/Bastion.Tests.ps1`, `tests/VpnGateway.Tests.ps1`
- Replace: `modules/types.bicep`, `params/dev.bicepparam`, `params/prod.bicepparam`, `modules/hubNetwork.bicep`, `modules/spokeNetwork.bicep`, `modules/networkIntegration.bicep`, `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`, `modules/regionStamp.bicep`, `main.bicep`, `ps-rule.yaml`, `.ps-rule/Suppression.Rule.yaml`, `tests/HubNetwork.Tests.ps1`, `tests/SpokeNetwork.Tests.ps1`, `tests/NetworkIntegration.Tests.ps1`, `tests/FirewallPolicyRules.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Main.Tests.ps1`, `tests/Params.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes (Phase 2):** `azureFirewall.bicep` outputs `privateIp`; `firewallPolicyRules.bicep` params `firewallPolicyName`, `spokeAddressPrefixes`, `managementAddressPrefixes`, `allowedOutboundFqdns`; `hubNetwork.bicep` param `enableDeleteLock`.
- **Produces:**
  - `regionAddressPlan` fields: `bastionSubnetPrefix`, `gatewaySubnetPrefix`, `vpnClientAddressPool` (string).
  - `hubNetwork.bicep` new params: `bastionSubnetAddressPrefix`, `gatewaySubnetAddressPrefix`, `firewallPrivateIp`, `spokeAddressPrefixes`, `bastionTargetAddressPrefixes`. New outputs: `bastionSubnetId`, `gatewaySubnetId`.
  - `bastion.bicep(location, bastionName, publicIpName, subnetId, availabilityZones = [], logAnalyticsWorkspaceId)` → outputs `id`, `name`.
  - `vpnGateway.bicep(location, gatewayName, publicIpNamePrefix, gatewaySubnetId, skuName = 'VpnGw2AZ', availabilityZones = ['1','2','3'], vpnClientAddressPool, tenantId = tenant().tenantId, vpnClientAudience = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8', maintenanceWindowStartDateTime = '2026-10-04 06:00', logAnalyticsWorkspaceId)` → outputs `id`, `name`.
  - `networkIntegration.bicep` new param: `useHubGateway = false`.
  - `azureFirewall.bicep` / `firewallPolicyRules.bicep` new param: `vpnClientAddressPrefixes`.
  - `regionStamp.bicep`:
    - New param `deployAdminAccess = false`.
    - New variables `firewallPrivateIp` and `adminSourceCidrs`.
    - New `names` keys `bastion`, `bastionPublicIp`, `vpnGateway`, `vpnGatewayPublicIp`.
    - Module deployments named `bastion` and `vpn-gateway`.
    - New outputs `expectedFirewallPrivateIp`, `bastionName`, `vpnGatewayName`.
  - `main.bicep`:
    - New params `deployPrimaryAdminAccess = true` and `deploySecondaryAdminAccess = false`.
    - New outputs `primaryResourceGroupName`, `primaryBastionName`, `primaryVpnGatewayName`, `primaryFirewallPrivateIp`.

- [ ] **Step 1: Confirm the branch**

  The worktree `.claude/worktrees/phase3-admin-access` already exists, on branch `phase3-admin-access` at `0f87b21` (the tip of `phase2-firewall-premium`) plus this plan's commit. Check it:

  ```bash
  cd /c/Workspace/Bicep/.claude/worktrees/phase3-admin-access
  git log --oneline -2
  ```

  Expected: the plan commit on top of `0f87b21`.

- [ ] **Step 2: Write the failing tests**

  Create `tests/Bastion.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/bastion.bicep'
      $bastion = Get-TemplateResource -Template $template -Type 'Microsoft.Network/bastionHosts' | Select-Object -First 1
      $publicIp = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
      $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
  }

  Describe 'Azure Bastion (Phase 3)' {
      It 'uses the Standard SKU so native client and IP-based connect work' {
          $bastion.sku.name | Should -Be 'Standard'
          $bastion.properties.enableTunneling | Should -BeExactly $true
          $bastion.properties.enableIpConnect | Should -BeExactly $true
      }

      It 'spreads Bastion and its public IP across the requested zones' {
          $bastion.zones | Should -Be "[if(empty(parameters('availabilityZones')), null(), parameters('availabilityZones'))]"
          $publicIp.zones | Should -Be "[if(empty(parameters('availabilityZones')), null(), parameters('availabilityZones'))]"
          $publicIp.sku.name | Should -Be 'Standard'
      }

      It 'sends the session audit logs to the central workspace' {
          $diagnostics.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
          $diagnostics.properties.logs[0].categoryGroup | Should -Be 'allLogs'
      }
  }
  ```

  Create `tests/VpnGateway.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/vpnGateway.bicep'
      $gateway = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworkGateways' | Select-Object -First 1
      $publicIps = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
      $maintenance = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/maintenanceConfigurations' | Select-Object -First 1
      $assignment = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/configurationAssignments' | Select-Object -First 1
      $client = $gateway.properties.vpnClientConfiguration
  }

  Describe 'Point-to-site VPN gateway (Phase 3)' {
      It 'accepts only zone-redundant (AZ) SKUs' {
          @($template.parameters.skuName.allowedValues) -join ',' | Should -Be 'VpnGw1AZ,VpnGw2AZ,VpnGw3AZ'
      }

      It 'runs a route-based Generation2 gateway, active-active with one zonal public IP per instance (PSRule Azure.VNG.VPNActiveActive)' {
          $gateway.properties.vpnType | Should -Be 'RouteBased'
          $gateway.properties.vpnGatewayGeneration | Should -Be 'Generation2'
          $gateway.properties.activeActive | Should -BeExactly $true
          @($template.variables.instances).Count | Should -Be 2
          $publicIps.copy.count | Should -Be "[length(variables('instances'))]"
          $publicIps.zones | Should -Be "[parameters('availabilityZones')]"
          ($gateway.properties.copy | Where-Object { $_.name -eq 'ipConfigurations' }).count | Should -Be "[length(variables('instances'))]"
      }

      It 'accepts only OpenVPN clients authenticated by Microsoft Entra ID' {
          @($client.vpnClientProtocols) -join ',' | Should -Be 'OpenVPN'
          @($client.vpnAuthenticationTypes) -join ',' | Should -Be 'AAD'
          $client.aadAudience | Should -Be "[parameters('vpnClientAudience')]"
          $template.parameters.vpnClientAudience.defaultValue | Should -Be 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'
      }

      It 'builds the tenant and issuer URLs from the tenant ID and the cloud login endpoint' {
          $client.aadTenant | Should -Be "[format('{0}{1}/', environment().authentication.loginEndpoint, parameters('tenantId'))]"
          $client.aadIssuer | Should -Be "[format('https://sts.windows.net/{0}/', parameters('tenantId'))]"
          $template.parameters.tenantId.defaultValue | Should -Be '[tenant().tenantId]'
      }

      It 'assigns clients addresses from the region pool' {
          @($client.vpnClientAddressPool.addressPrefixes) | Should -Be @("[parameters('vpnClientAddressPool')]")
      }

      It 'patches the gateway only inside a weekly customer-controlled window of at least 5 hours (PSRule Azure.VNG.MaintenanceConfig)' {
          $maintenance.properties.maintenanceScope | Should -Be 'Resource'
          $maintenance.properties.maintenanceWindow.duration | Should -Be '05:00'
          $maintenance.properties.maintenanceWindow.recurEvery | Should -Be 'Week Sunday'
          $assignment.scope | Should -Match 'virtualNetworkGateways'
      }
  }
  ```

  Replace `tests/HubNetwork.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/hubNetwork.bicep'
      $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
      $vnet = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworks' | Select-Object -First 1
      $routeTable = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables' | Select-Object -First 1
      $bastionNsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' | Select-Object -First 1
      # Subnet names compile to variable references, for example [variables('gatewaySubnetName')].
      function Get-Subnet([string]$Name) {
          $variable = ($template.variables.PSObject.Properties | Where-Object { $_.Name -like '*SubnetName' -and $_.Value -ceq $Name }).Name
          $vnet.properties.subnets | Where-Object { $_.name -eq "[variables('$variable')]" }
      }
      function Get-NsgRule([string]$Name) { $bastionNsg.properties.securityRules | Where-Object { $_.name -eq $Name } }
  }

  Describe 'Hub network deletion protection (Phase 2)' {
      It 'locks the hub VNet only when requested' {
          $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
          $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
          $lock.properties.level | Should -Be 'CanNotDelete'
          $lock.scope | Should -Be "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]"
      }
  }

  Describe 'Hub subnets (Phase 3)' {
      It 'always creates the exact-case AzureFirewallSubnet, AzureBastionSubnet and GatewaySubnet' {
          $template.variables.firewallSubnetName | Should -BeExactly 'AzureFirewallSubnet'
          $template.variables.bastionSubnetName | Should -BeExactly 'AzureBastionSubnet'
          $template.variables.gatewaySubnetName | Should -BeExactly 'GatewaySubnet'
          @($vnet.properties.subnets.name) -join ',' | Should -Be "[variables('firewallSubnetName')],[variables('bastionSubnetName')],[variables('gatewaySubnetName')]"
          $vnet.PSObject.Properties.Name | Should -Not -Contain 'condition'
      }

      It 'outputs the Bastion and gateway subnet IDs' {
          foreach ($output in 'bastionSubnetId', 'gatewaySubnetId') {
              $template.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }

  Describe 'Hub DNS (ADR-005, Phase 3)' {
      It 'points the hub, and so every VPN client, at the firewall DNS proxy' {
          @($vnet.properties.dhcpOptions.dnsServers) | Should -Be @("[parameters('firewallPrivateIp')]")
      }
  }

  Describe 'GatewaySubnet routing (F2, Phase 3)' {
      It 'attaches the gateway route table to GatewaySubnet only' {
          (Get-Subnet 'GatewaySubnet').properties.routeTable.id | Should -Match 'gatewayRouteTableName'
          (Get-Subnet 'AzureFirewallSubnet').properties.PSObject.Properties.Name | Should -Not -Contain 'routeTable'
          (Get-Subnet 'AzureBastionSubnet').properties.PSObject.Properties.Name | Should -Not -Contain 'routeTable'
      }

      It 'sends every spoke prefix from VPN clients to the firewall' {
          $routes = $routeTable.properties.copy | Where-Object { $_.name -eq 'routes' }
          $routes.count | Should -Be "[length(parameters('spokeAddressPrefixes'))]"
          $routes.input.properties.nextHopType | Should -Be 'VirtualAppliance'
          $routes.input.properties.nextHopIpAddress | Should -Be "[parameters('firewallPrivateIp')]"
      }

      It 'keeps BGP route propagation on (GatewaySubnet requires it)' {
          $routeTable.properties.disableBgpRoutePropagation | Should -BeExactly $false
      }
  }

  Describe 'Bastion NSG (Phase 3)' {
      It 'is attached to AzureBastionSubnet' {
          (Get-Subnet 'AzureBastionSubnet').properties.networkSecurityGroup.id | Should -Match 'bastionNsgName'
      }

      It 'allows the inbound rule Bastion requires: <Rule>' -ForEach @(
          @{ Rule = 'allow-https-inbound'; Source = 'Internet' }
          @{ Rule = 'allow-gateway-manager-inbound'; Source = 'GatewayManager' }
          @{ Rule = 'allow-load-balancer-inbound'; Source = 'AzureLoadBalancer' }
      ) {
          $rule = Get-NsgRule $Rule
          $rule.properties.access | Should -Be 'Allow'
          $rule.properties.direction | Should -Be 'Inbound'
          $rule.properties.sourceAddressPrefix | Should -Be $Source
          $rule.properties.destinationPortRange | Should -Be '443'
      }

      It 'allows Bastion data-plane traffic on 8080 and 5701 in both directions' {
          foreach ($name in 'allow-bastion-host-communication-inbound', 'allow-bastion-host-communication-outbound') {
              @((Get-NsgRule $name).properties.destinationPortRanges) -join ',' | Should -Be '8080,5701'
          }
      }

      It 'allows the AzureCloud and session-information egress Bastion requires' {
          (Get-NsgRule 'allow-azure-cloud-outbound').properties.destinationAddressPrefix | Should -Be 'AzureCloud'
          (Get-NsgRule 'allow-session-information-outbound').properties.destinationPortRange | Should -Be '80'
      }

      It 'opens SSH/RDP only to the management subnets, then denies all other SSH/RDP egress' {
          $allow = Get-NsgRule 'allow-ssh-rdp-to-management-outbound'
          $allow.properties.destinationAddressPrefixes | Should -Be "[parameters('bastionTargetAddressPrefixes')]"
          @($allow.properties.destinationPortRanges) -join ',' | Should -Be '22,3389'
          $deny = Get-NsgRule 'deny-other-ssh-rdp-outbound'
          $deny.properties.access | Should -Be 'Deny'
          $deny.properties.direction | Should -Be 'Outbound'
          $deny.properties.priority | Should -BeGreaterThan $allow.properties.priority
      }

      It 'denies all other inbound traffic' {
          (Get-NsgRule 'deny-unsolicited-inbound').properties.priority | Should -Be 4096
      }
  }
  ```

  Replace `tests/SpokeNetwork.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/spokeNetwork.bicep'
      $routeTables = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables'
      $vnetModule = Get-TemplateResource -Template $template -Type 'Microsoft.Resources/deployments' | Select-Object -First 1
      # Subnet order in spokeNetwork.bicep: 0 private-endpoints, 1 appservice-integration, 2 management.
      $subnets = @($vnetModule.properties.parameters.subnets.value)
  }

  Describe 'Spoke routing (F2)' {
      It 'has one route table for App Service and one for the management subnet' {
          $routeTables.Count | Should -Be 2
      }

      It 'disables BGP route propagation on every spoke route table so gateway routes cannot bypass the firewall' {
          foreach ($routeTable in $routeTables) {
              $routeTable.properties.disableBgpRoutePropagation | Should -BeTrue
          }
      }
  }

  Describe 'Management subnet isolation (F1)' {
      It 'uses its own NSG, not the App Service integration NSG' {
          $subnets[2].nsgId | Should -Not -Be $subnets[1].nsgId
      }

      It 'uses its own route table, not the App Service route table' {
          $subnets[2].udrId | Should -Not -Be $subnets[1].udrId
      }

      It 'defaults to no management source CIDRs (deny all admin inbound)' {
          @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
      }
  }

  Describe 'Subnet default outbound access (PSRule Azure.VNET.PrivateSubnet)' {
      It 'disables default outbound internet access on the private endpoint and management subnets' {
          $subnets[0].defaultOutboundAccess | Should -Be $false
          $subnets[2].defaultOutboundAccess | Should -Be $false
      }

      It 'leaves the delegated App Service integration subnet unset (delegation manages its own egress)' {
          $subnets[1].PSObject.Properties.Name | Should -Not -Contain 'defaultOutboundAccess'
      }
  }

  Describe 'Management subnet naming (Phase 1)' {
      It 'names the third subnet management' {
          $template.parameters.virtualMachineSubnetName.defaultValue | Should -Be 'management'
      }
  }

  Describe 'Lateral traversal (PSRule Azure.NSG.LateralTraversal, Phase 3)' {
      It 'denies outbound SSH and RDP from every spoke subnet' {
          $template.variables.denyLateralTraversalRule.properties.access | Should -Be 'Deny'
          $template.variables.denyLateralTraversalRule.properties.direction | Should -Be 'Outbound'
          @($template.variables.denyLateralTraversalRule.properties.destinationPortRanges) -join ',' | Should -Be '22,3389'
          $nsgs = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups'
          $nsgs.Count | Should -Be 3
          foreach ($nsg in $nsgs) {
              # Plain NSGs list the variable as an array element; the management NSG compiles to one concat() expression.
              (@($nsg.properties.securityRules) -join ' ').Contains("variables('denyLateralTraversalRule')") | Should -BeTrue
          }
      }
  }
  ```

  Replace `tests/NetworkIntegration.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/networkIntegration.bicep'
      $peerings = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings'
      $hubToSpoke = $peerings | Where-Object { $_.name -like "*'hub-to-spoke')]" }
      $spokeToHub = $peerings | Where-Object { $_.name -like "*'spoke-to-hub')]" }
      $roleAssignment = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
  }

  Describe 'App Service storage RBAC scope (F11)' {
      It 'assigns Storage Blob Data Contributor at container scope, not account scope' {
          $roleAssignment.scope | Should -Match 'containers'
      }

      It 'includes the container in the deterministic assignment name' {
          $roleAssignment.name | Should -Match 'storageContainerName'
      }
  }

  Describe 'Gateway transit (Phase 3)' {
      It 'is off by default (the spoke peering fails when the hub has no gateway)' {
          $template.parameters.useHubGateway.defaultValue | Should -BeExactly $false
      }

      It 'offers the hub gateway to the spoke and lets the spoke use it when enabled' {
          $hubToSpoke.properties.allowGatewayTransit | Should -Be "[parameters('useHubGateway')]"
          $hubToSpoke.properties.useRemoteGateways | Should -BeExactly $false
          $spokeToHub.properties.useRemoteGateways | Should -Be "[parameters('useHubGateway')]"
          $spokeToHub.properties.allowGatewayTransit | Should -BeExactly $false
      }
  }
  ```

  Replace `tests/FirewallPolicyRules.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/firewallPolicyRules.bicep'
      $groups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
      function Get-Group([string]$Name) {
          $groups | Where-Object { $_.name -like "*'$Name')]" }
      }
      $dns = Get-Group 'dns-egress'
      $admin = Get-Group 'admin-access'
      $platform = Get-Group 'platform-egress'
      $approved = Get-Group 'approved-https-egress'
  }

  Describe 'Baseline firewall rules (ADR-010)' {
      It 'defines the dns-egress, admin-access, platform-egress and approved-https-egress groups at priorities 100, 120, 150, 200' {
          $groups.Count | Should -Be 4
          $dns.properties.priority | Should -Be 100
          $admin.properties.priority | Should -Be 120
          $platform.properties.priority | Should -Be 150
          $approved.properties.priority | Should -Be 200
      }

      It 'updates the groups one at a time (a policy rejects concurrent rule collection group updates)' {
          @($dns.PSObject.Properties.Name) | Should -Not -Contain 'dependsOn'
          @($admin.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'dns-egress')]"
          @($platform.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'admin-access')]"
          @($approved.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'platform-egress')]"
      }

      It 'allows spoke DNS to the Azure resolver through the proxy' {
          $rule = $dns.properties.ruleCollections[0].rules[0]
          @($rule.destinationAddresses) | Should -Contain '168.63.129.16'
          @($rule.destinationPorts) | Should -Contain '53'
          $rule.sourceAddresses | Should -Be "[parameters('spokeAddressPrefixes')]"
      }

      It 'allows spoke traffic to the AzureMonitor and AzureResourceManager service tags on 443' {
          $rule = $dns.properties.ruleCollections[1].rules[0]
          @($rule.destinationAddresses) | Should -Contain 'AzureMonitor'
          @($rule.destinationAddresses) | Should -Contain 'AzureResourceManager'
          @($rule.destinationPorts) | Should -Contain '443'
      }
  }

  Describe 'Admin sessions from VPN clients (Phase 3)' {
      BeforeAll {
          $rule = $admin.properties.ruleCollections[0].rules[0]
      }

      It 'is always deployed so enabling admin access never reorders the group chain' {
          $admin.PSObject.Properties.Name | Should -Not -Contain 'condition'
      }

      It 'allows only SSH and RDP from the VPN client pools to the management subnet' {
          $admin.properties.ruleCollections[0].action.type | Should -Be 'Allow'
          $rule.ruleType | Should -Be 'NetworkRule'
          @($rule.ipProtocols) -join ',' | Should -Be 'TCP'
          $rule.sourceAddresses | Should -Be "[parameters('vpnClientAddressPrefixes')]"
          $rule.destinationAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
          @($rule.destinationPorts) -join ',' | Should -Be '22,3389'
      }
  }


  Describe 'OS update egress for management VMs only' {
      BeforeAll {
          $rules = @($platform.properties.ruleCollections[0].rules)
          $windows = $rules | Where-Object { $_.name -eq 'windows-update' }
          $ubuntu = $rules | Where-Object { $_.name -eq 'ubuntu-archives' }
      }

      It 'sources every OS update rule from the management subnet, never the whole spoke' {
          foreach ($rule in $rules) {
              $rule.sourceAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
          }
      }

      It 'allows Windows Update through its FQDN tag' {
          @($windows.fqdnTags) | Should -Contain 'WindowsUpdate'
      }

      It 'allows the Ubuntu archives over HTTP and HTTPS' {
          @($ubuntu.targetFqdns) | Should -Contain 'archive.ubuntu.com'
          @($ubuntu.targetFqdns) | Should -Contain 'security.ubuntu.com'
          @($ubuntu.targetFqdns) | Should -Contain 'azure.archive.ubuntu.com'
          @($ubuntu.protocols.port) -join ',' | Should -Be '80,443'
      }
  }

  Describe 'Application allowlist' {
      It 'is deployed only when allowedOutboundFqdns is not empty' {
          $approved.condition | Should -Be "[not(empty(parameters('allowedOutboundFqdns')))]"
          $approved.properties.ruleCollections[0].rules[0].targetFqdns | Should -Be "[parameters('allowedOutboundFqdns')]"
      }
  }
  ```

  Replace `tests/RegionStamp.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
      function Get-StampModuleParameters([string]$Name) {
          (Get-ModuleDeployment -Template $stamp -Name $Name).properties.parameters
      }
  }

  Describe 'Region stamp naming' {
      It 'names every resource with environment and region so stamps never collide' {
          foreach ($key in 'hubVnet', 'spokeVnet', 'firewall', 'firewallPolicy', 'firewallPublicIp', 'appServicePlan', 'appService') {
              $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
          }
      }

      It 'derives globally unique names from subscription, environment, and region' {
          $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
          $stamp.variables.names.storageAccount | Should -Be "[format('st{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
          $stamp.variables.names.keyVault | Should -Be "[format('kv-{0}-{1}', parameters('regionCode'), variables('nameSuffix'))]"
      }

      It 'passes the stamp names to the modules' {
          (Get-StampModuleParameters 'app-service').appServicePlanName.value | Should -Be "[variables('names').appServicePlan]"
          (Get-StampModuleParameters 'azure-firewall').firewallName.value | Should -Be "[variables('names').firewall]"
      }
  }

  Describe 'Region stamp availability' {
      It 'deploys the firewall and its public IP across zones 1-3 in every stamp' {
          @($stamp.variables.availabilityZones) -join ',' | Should -Be '1,2,3'
          (Get-StampModuleParameters 'azure-firewall').availabilityZones.value | Should -Be "[variables('availabilityZones')]"
      }

      It 'makes the App Service plan zone-redundant with 3 instances only in the prod primary region' {
          $parameters = Get-StampModuleParameters 'app-service'
          $parameters.zoneRedundant.value | Should -Be "[and(variables('isProd'), variables('isPrimary'))]"
          $parameters.instanceCount | Should -Be "[if(and(variables('isProd'), variables('isPrimary')), createObject('value', 3), createObject('value', 1))]"
      }

      It 'uses geo-redundant storage in prod and locally redundant storage in dev' {
          (Get-StampModuleParameters 'storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), createObject('value', 'Standard_GRS'), createObject('value', 'Standard_LRS'))]"
      }

      It 'deploys the optional management VM in the primary region only' {
          (Get-ModuleDeployment -Template $stamp -Name 'virtual-machine').condition |
              Should -Be "[and(parameters('enableVirtualMachine'), variables('isPrimary'))]"
      }
  }

  Describe 'Region stamp wiring carried from Phase 0' {
      It 'passes the admin source ranges (Bastion subnet, VPN pool, extra managementSourceCidrs) to <_> (F1, Phase 3)' -ForEach 'spoke-network', 'virtual-machine' {
          (Get-StampModuleParameters $_).managementSourceCidrs.value | Should -Be "[variables('adminSourceCidrs')]"
      }

      It 'uses the address plan spoke range for both the spoke VNet and firewall sources (F5)' {
          (Get-StampModuleParameters 'azure-firewall').spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
          (Get-StampModuleParameters 'spoke-network').vnetAddressSpace.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
      }

      It 'derives private endpoint sources from the App Service and management subnet prefixes (F5)' {
          $value = (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value
          $value | Should -Match "addressPlan'\)\.appServiceIntegrationSubnetPrefix"
          $value | Should -Match "addressPlan'\)\.managementSubnetPrefix"
          $value | Should -Match "addressPlan'\)\.vpnClientAddressPool"
          $value | Should -Match 'additionalPrivateEndpointSourceCidrs'
      }

      It 'uses firewall threat intelligence Deny in prod and Alert in dev (F9)' {
          (Get-StampModuleParameters 'azure-firewall').threatIntelMode |
              Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
      }

      It 'enables Key Vault template deployment so az.getSecret() references resolve (F4)' {
          (Get-StampModuleParameters 'key-vault').enabledForTemplateDeployment.value | Should -BeExactly $true
      }

      It 'passes the container name from the storage module output (F11)' {
          (Get-StampModuleParameters 'network-integration').storageContainerName.value | Should -Match 'outputs.blobContainerName'
      }

      It 'registers private endpoints in the shared zones from the global layer' {
          (Get-StampModuleParameters 'private-connectivity').privateDnsZoneIds.value | Should -Be "[parameters('privateDnsZoneIds')]"
      }

      It 'locks the spoke VNet in prod only' {
          (Get-StampModuleParameters 'spoke-network').enableDeleteLock.value | Should -Be "[variables('isProd')]"
      }
  }

  Describe 'Region stamp outputs' {
      It 'exposes the VNets the entry point links to the shared DNS zones' {
          foreach ($output in 'hubVnetName', 'hubVnetId', 'spokeVnetName', 'spokeVnetId', 'appServiceHostName') {
              $stamp.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }

  Describe 'Region stamp firewall security (Phase 2)' {
      It 'deploys Azure Firewall Premium in every stamp' {
          (Get-StampModuleParameters 'azure-firewall').firewallTier.value | Should -Be 'Premium'
      }

      It 'runs IDPS in Deny in prod and Alert in dev' {
          (Get-StampModuleParameters 'azure-firewall').idpsMode |
              Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
      }

      It 'limits OS update egress to the management subnet' {
          @((Get-StampModuleParameters 'azure-firewall').managementAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
      }

      It 'locks the hub VNet, Key Vault and firewall resources in prod only (<_>)' -ForEach 'hub-network', 'key-vault', 'azure-firewall' {
          (Get-StampModuleParameters $_).enableDeleteLock.value | Should -Be "[variables('isProd')]"
      }
  }

  Describe 'Region stamp admin access (Phase 3)' {
      It 'derives admin sources from the Bastion subnet and VPN client pool, plus any extra managementSourceCidrs' {
          $stamp.variables.adminSourceCidrs |
              Should -Be "[concat(createArray(parameters('addressPlan').bastionSubnetPrefix, parameters('addressPlan').vpnClientAddressPool), parameters('managementSourceCidrs'))]"
      }

      It 'deploys <_> only when deployAdminAccess is true' -ForEach 'bastion', 'vpn-gateway' {
          (Get-ModuleDeployment -Template $stamp -Name $_).condition | Should -Be "[parameters('deployAdminAccess')]"
          $stamp.parameters.deployAdminAccess.defaultValue | Should -BeExactly $false
      }

      It 'uses VpnGw2AZ in prod and VpnGw1AZ in dev' {
          (Get-StampModuleParameters 'vpn-gateway').skuName |
              Should -Be "[if(variables('isProd'), createObject('value', 'VpnGw2AZ'), createObject('value', 'VpnGw1AZ'))]"
      }

      It 'deploys <_> after the firewall, whose DNS proxy the hub uses' -ForEach 'bastion', 'vpn-gateway' {
          @((Get-ModuleDeployment -Template $stamp -Name $_).dependsOn) | Should -Contain 'azureFirewall'
      }

      It 'spreads <_> across zones 1-3' -ForEach 'bastion', 'vpn-gateway' {
          (Get-StampModuleParameters $_).availabilityZones.value | Should -Be "[variables('availabilityZones')]"
      }

      It 'gives the gateway the region VPN client pool' {
          (Get-StampModuleParameters 'vpn-gateway').vpnClientAddressPool.value | Should -Be "[parameters('addressPlan').vpnClientAddressPool]"
      }

      It 'routes GatewaySubnet spoke traffic to the first usable firewall address, computed before the firewall exists' {
          $stamp.variables.firewallPrivateIp | Should -Be "[cidrHost(parameters('addressPlan').firewallSubnetPrefix, 3)]"
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.firewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
          $hub.spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
          @((Get-ModuleDeployment -Template $stamp -Name 'hub-network').dependsOn) | Should -Not -Contain 'azureFirewall'
      }

      It 'lets Bastion reach only the management subnet' {
          @((Get-StampModuleParameters 'hub-network').bastionTargetAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
      }

      It 'passes the Bastion and gateway subnet prefixes from the address plan' {
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.bastionSubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').bastionSubnetPrefix]"
          $hub.gatewaySubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').gatewaySubnetPrefix]"
      }

      It 'allows the VPN client pool through the firewall admin-access rules' {
          @((Get-StampModuleParameters 'azure-firewall').vpnClientAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').vpnClientAddressPool]")
      }

      It 'turns on gateway transit only with admin access, after the gateway is provisioned' {
          (Get-StampModuleParameters 'network-integration').useHubGateway.value | Should -Be "[parameters('deployAdminAccess')]"
          @((Get-ModuleDeployment -Template $stamp -Name 'network-integration').dependsOn) | Should -Contain 'vpnGateway'
      }


      It 'outputs the Bastion and gateway names (empty without admin access) and the expected firewall IP' {
          $stamp.outputs.bastionName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').bastion, '')]"
          $stamp.outputs.vpnGatewayName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').vpnGateway, '')]"
          $stamp.outputs.expectedFirewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
      }

      It 'names Bastion and the gateway with environment and region' {
          foreach ($key in 'bastion', 'bastionPublicIp', 'vpnGateway', 'vpnGatewayPublicIp') {
              $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
          }
      }
  }
  ```

  Replace `tests/Main.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $main = Get-BicepTemplate -RelativePath 'main.bicep'
      $global = Get-TemplateResourceBySymbol -Template $main -Symbol 'global'
      $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
      $secondary = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStamp'
      $dnsLinks = Get-TemplateResourceBySymbol -Template $main -Symbol 'privateDnsLinks'
  }

  Describe 'Subscription-scope entry point' {
      It 'targets the subscription' {
          $main.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
      }

      It 'accepts only dev and prod environments' {
          @($main.parameters.environmentName.allowedValues) -join ',' | Should -Be 'dev,prod'
      }

      It 'maps each allowed region to a short code used in names' {
          @($main.parameters.primaryLocation.allowedValues) -join ',' | Should -Be 'westus3,eastus'
          $main.variables.regionCodes.westus3 | Should -Be 'wus3'
          $main.variables.regionCodes.eastus | Should -Be 'eus'
      }

      It 'names resource groups rg-defenstack-<env>-global and rg-defenstack-<env>-<region>' {
          $main.variables.globalResourceGroupName | Should -Be "[format('rg-defenstack-{0}-global', parameters('environmentName'))]"
          $main.variables.primaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('primaryRegionCode'))]"
      }
  }

  Describe 'Composition' {
      It 'deploys the global layer into the global resource group' {
          $global.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
      }

      It 'replicates the workspace to the secondary region only for prod with DR enabled' {
          $global.properties.parameters.workspaceReplicationLocation |
              Should -Be "[if(and(variables('isProd'), parameters('deploySecondaryRegion')), createObject('value', parameters('secondaryLocation')), createObject('value', ''))]"
      }

      It 'deploys the primary stamp as primary into the primary resource group' {
          $primary.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $primary.properties.parameters.regionRole.value | Should -Be 'primary'
          $primary.properties.parameters.addressPlan.value | Should -Be "[parameters('primaryAddressPlan')]"
      }

      It 'deploys the secondary stamp only when deploySecondaryRegion is true' {
          $secondary.condition | Should -Be "[parameters('deploySecondaryRegion')]"
          $secondary.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
          $secondary.properties.parameters.regionRole.value | Should -Be 'secondary'
      }

      It 'feeds both stamps the shared workspace and DNS zone IDs' {
          foreach ($stamp in $primary, $secondary) {
              $stamp.properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[reference('global').outputs.logAnalyticsWorkspaceId.value]"
              $stamp.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
          }
      }
  }

  Describe 'Shared private DNS' {
      It 'defines the three zone names once' {
          @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault'
          $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
          $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
      }

      It 'links every zone in the global resource group' {
          $dnsLinks.copy.count | Should -Be "[length(items(variables('privateDnsZoneNames')))]"
          $dnsLinks.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
      }

      It 'links the hub and spoke VNets of the primary and (when deployed) the secondary stamp' {
          $value = $dnsLinks.properties.parameters.virtualNetworks.value
          foreach ($output in 'hubVnetId', 'spokeVnetId') {
              $value | Should -Match "reference\('primaryStamp'\)\.outputs\.$output"
              $value | Should -Match "reference\('secondaryStamp'\)\.outputs\.$output"
          }
          $value | Should -Match "parameters\('deploySecondaryRegion'\)"
      }
  }

  Describe 'Admin access (Phase 3)' {
      It 'deploys admin access in the primary region by default and keeps the warm standby off until failover' {
          $main.parameters.deployPrimaryAdminAccess.defaultValue | Should -BeExactly $true
          $main.parameters.deploySecondaryAdminAccess.defaultValue | Should -BeExactly $false
          $primary.properties.parameters.deployAdminAccess.value | Should -Be "[parameters('deployPrimaryAdminAccess')]"
          $secondary.properties.parameters.deployAdminAccess.value | Should -Be "[parameters('deploySecondaryAdminAccess')]"
      }


      It 'outputs what runbook 03 needs to connect' {
          foreach ($output in 'primaryResourceGroupName', 'primaryBastionName', 'primaryVpnGatewayName', 'primaryFirewallPrivateIp') {
              $main.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }
  ```

  Replace `tests/Params.Tests.ps1`:

  ```powershell
  BeforeDiscovery {
      $repoRoot = Split-Path -Parent $PSScriptRoot
      $paramFiles = Get-ChildItem -Path (Join-Path $repoRoot 'params') -Filter '*.bicepparam' -ErrorAction SilentlyContinue |
          ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
  }

  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force

      function Get-BuiltParameters([string]$RelativePath) {
          [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
          $built = (& bicep build-params (Get-RepoPath $RelativePath) --stdout) -join "`n" | ConvertFrom-Json
          ($built.parametersJson | ConvertFrom-Json).parameters
      }

      # True when every prefix in $Prefixes shares the first two octets of $Space (all ranges here are /16 spaces).
      function Test-InsideSixteen([string]$Space, [string[]]$Prefixes) {
          $root = ($Space -split '\.')[0..1] -join '.'
          -not ($Prefixes | Where-Object { -not $_.StartsWith("$root.") })
      }

      $dev = Get-BuiltParameters 'params/dev.bicepparam'
      $prod = Get-BuiltParameters 'params/prod.bicepparam'
  }

  Describe 'Committed parameter files' {
      It 'includes dev and prod parameter files' {
          Get-RepoPath 'params/dev.bicepparam' | Should -Exist
          Get-RepoPath 'params/prod.bicepparam' | Should -Exist
      }

      It '<Name> builds against main.bicep' -ForEach $paramFiles {
          $output = & bicep build-params $FullName --stdout 2>&1
          $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
      }

      It '<Name> contains no az.getSecret references (secrets belong in *.local.bicepparam)' -ForEach $paramFiles {
          Get-Content $FullName -Raw | Should -Not -Match 'getSecret'
      }
  }

  Describe 'Environment topology' {
      It 'runs dev in the primary region only' {
          $dev.environmentName.value | Should -Be 'dev'
          $dev.deploySecondaryRegion.value | Should -BeExactly $false
      }

      It 'runs prod in both regions with a secondary address plan' {
          $prod.environmentName.value | Should -Be 'prod'
          $prod.deploySecondaryRegion.value | Should -BeExactly $true
          $prod.secondaryAddressPlan.value | Should -Not -BeNullOrEmpty
      }
  }

  Describe 'Address plan' {
      It 'uses the spec ranges for prod (WUS3 hub 10.1/16, spoke 10.0/16; EUS hub 10.11/16, spoke 10.10/16)' {
          $prod.primaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.1.0.0/16'
          $prod.primaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.0.0.0/16'
          $prod.secondaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.11.0.0/16'
          $prod.secondaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.10.0.0/16'
      }

      It 'gives dev its own ranges so dev and prod never overlap' {
          $prodRanges = @($prod.primaryAddressPlan.value.hubAddressSpace + $prod.primaryAddressPlan.value.spokeAddressSpace +
              $prod.secondaryAddressPlan.value.hubAddressSpace + $prod.secondaryAddressPlan.value.spokeAddressSpace)
          foreach ($range in @($dev.primaryAddressPlan.value.hubAddressSpace + $dev.primaryAddressPlan.value.spokeAddressSpace)) {
              $prodRanges | Should -Not -Contain $range
          }
      }

      It 'keeps every subnet inside its VNet in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          Test-InsideSixteen $plan.hubAddressSpace[0] @($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Should -BeTrue
          Test-InsideSixteen $plan.spokeAddressSpace[0] @($plan.privateEndpointSubnetPrefix, $plan.appServiceIntegrationSubnetPrefix, $plan.managementSubnetPrefix) | Should -BeTrue
      }
  }

  Describe 'Admin access address plan (Phase 3)' {
      BeforeAll {
          $plans = @($dev.primaryAddressPlan.value, $prod.primaryAddressPlan.value, $prod.secondaryAddressPlan.value)
      }

      It 'sizes the hub subnets for Azure (Bastion /26, GatewaySubnet /27) in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          $plan.bastionSubnetPrefix | Should -Match '/26$'
          $plan.gatewaySubnetPrefix | Should -Match '/27$'
          @(@($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'uses the spec pool 172.16.200.0/24 for the prod primary region' {
          $prod.primaryAddressPlan.value.vpnClientAddressPool | Should -Be '172.16.200.0/24'
      }

      It 'gives every region and environment its own VPN client pool' {
          @($plans | ForEach-Object { $_.vpnClientAddressPool } | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'keeps every VPN client pool outside every VNet (clients must never overlap Azure ranges)' {
          $vnetRoots = @($plans | ForEach-Object { @($_.hubAddressSpace) + @($_.spokeAddressSpace) } | ForEach-Object { ($_ -split '\.')[0..1] -join '.' })
          foreach ($plan in $plans) {
              $poolRoot = ($plan.vpnClientAddressPool -split '\.')[0..1] -join '.'
              $vnetRoots | Should -Not -Contain $poolRoot
          }
      }
  }
  ```

- [ ] **Step 3: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected: failures, for example:
  - `bicep build failed for modules/bastion.bicep` in the Bastion and VpnGateway `BeforeAll` blocks
  - `Expected 4, but got 3` (rule groups)
  - string mismatches on `adminSourceCidrs`
  - Params failures on `bastionSubnetPrefix`

  The Phase 2 tests that these files do not touch still pass.

- [ ] **Step 4: Replace the shared type and parameter files**

  Replace `modules/types.bicep`:

  ```bicep
  // Shared parameter contracts between the subscription entry point, the global layer, and region stamps.

  @export()
  @description('Address plan for one region: hub VNet with the firewall, Bastion and gateway subnets, spoke VNet with its three subnets, and the P2S VPN client pool.')
  type regionAddressPlan = {
    @description('Hub VNet address space.')
    hubAddressSpace: string[]

    @description('AzureFirewallSubnet prefix (at least /26) inside hubAddressSpace.')
    firewallSubnetPrefix: string

    @description('AzureBastionSubnet prefix (at least /26) inside hubAddressSpace.')
    bastionSubnetPrefix: string

    @description('GatewaySubnet prefix (at least /27) inside hubAddressSpace.')
    gatewaySubnetPrefix: string

    @description('Point-to-site VPN client address pool. Must not overlap any VNet in any region or environment.')
    vpnClientAddressPool: string

    @description('Spoke VNet address space. Also the firewall source range for spoke egress rules.')
    spokeAddressSpace: string[]

    @description('private-endpoints subnet prefix inside spokeAddressSpace.')
    privateEndpointSubnetPrefix: string

    @description('appservice-integration subnet prefix inside spokeAddressSpace.')
    appServiceIntegrationSubnetPrefix: string

    @description('management subnet prefix inside spokeAddressSpace.')
    managementSubnetPrefix: string
  }

  @export()
  @description('Private DNS zone names (or resource IDs) keyed by private endpoint group.')
  type privateDnsZoneSet = {
    @description('Blob storage zone.')
    blob: string

    @description('App Service (sites) zone.')
    sites: string

    @description('Key Vault zone.')
    vault: string
  }

  @export()
  @description('A virtual network to link to a private DNS zone.')
  type virtualNetworkReference = {
    @description('VNet name; used to build a unique link name.')
    name: string

    @description('VNet resource ID.')
    id: string
  }
  ```

  Replace `params/dev.bicepparam`:

  ```bicep
  using '../main.bicep'

  // Non-secret dev parameters: primary region only (rg-defenstack-dev-global, rg-defenstack-dev-wus3).
  // Secret values go in a git-ignored *.local.bicepparam overlay, never here.
  // VPN client pools: prod WUS3 172.16.200.0/24, prod EUS 172.16.201.0/24, dev 172.16.210.0/24 (never reuse across environments).
  param environmentName = 'dev'
  param deploySecondaryRegion = false
  param primaryAddressPlan = {
    hubAddressSpace: [
      '10.21.0.0/16'
    ]
    firewallSubnetPrefix: '10.21.0.0/26'
    bastionSubnetPrefix: '10.21.0.64/26'
    gatewaySubnetPrefix: '10.21.0.128/27'
    vpnClientAddressPool: '172.16.210.0/24'
    spokeAddressSpace: [
      '10.20.0.0/16'
    ]
    privateEndpointSubnetPrefix: '10.20.1.0/24'
    appServiceIntegrationSubnetPrefix: '10.20.2.0/24'
    managementSubnetPrefix: '10.20.3.0/24'
  }
  param allowedOutboundFqdns = []
  ```

  Replace `params/prod.bicepparam`:

  ```bicep
  using '../main.bicep'

  // Non-secret prod parameters: West US 3 active, East US warm standby
  // (rg-defenstack-prod-global, rg-defenstack-prod-wus3, rg-defenstack-prod-eus).
  // Secret values go in a git-ignored *.local.bicepparam overlay, never here.
  // VPN client pools: prod WUS3 172.16.200.0/24, prod EUS 172.16.201.0/24, dev 172.16.210.0/24 (never reuse across environments).
  param environmentName = 'prod'
  param deploySecondaryRegion = true
  param primaryAddressPlan = {
    hubAddressSpace: [
      '10.1.0.0/16'
    ]
    firewallSubnetPrefix: '10.1.0.0/26'
    bastionSubnetPrefix: '10.1.0.64/26'
    gatewaySubnetPrefix: '10.1.0.128/27'
    vpnClientAddressPool: '172.16.200.0/24'
    spokeAddressSpace: [
      '10.0.0.0/16'
    ]
    privateEndpointSubnetPrefix: '10.0.1.0/24'
    appServiceIntegrationSubnetPrefix: '10.0.2.0/24'
    managementSubnetPrefix: '10.0.3.0/24'
  }
  param secondaryAddressPlan = {
    hubAddressSpace: [
      '10.11.0.0/16'
    ]
    firewallSubnetPrefix: '10.11.0.0/26'
    bastionSubnetPrefix: '10.11.0.64/26'
    gatewaySubnetPrefix: '10.11.0.128/27'
    vpnClientAddressPool: '172.16.201.0/24'
    spokeAddressSpace: [
      '10.10.0.0/16'
    ]
    privateEndpointSubnetPrefix: '10.10.1.0/24'
    appServiceIntegrationSubnetPrefix: '10.10.2.0/24'
    managementSubnetPrefix: '10.10.3.0/24'
  }
  param allowedOutboundFqdns = []
  ```

- [ ] **Step 5: Replace the hub network and create the admin-access modules**

  Replace `modules/hubNetwork.bicep`:

  ```bicep
  @description('Azure region for the hub network.')
  param location string

  @description('Hub virtual network name.')
  @minLength(2)
  @maxLength(64)
  param vnetName string

  @description('Non-overlapping hub address space.')
  param addressSpace array

  @description('Address prefix for the exact-case AzureFirewallSubnet. It must be at least /26 and contained in addressSpace.')
  param firewallSubnetAddressPrefix string

  @description('Address prefix for the exact-case AzureBastionSubnet. It must be at least /26 and contained in addressSpace.')
  param bastionSubnetAddressPrefix string

  @description('Address prefix for the exact-case GatewaySubnet. It must be at least /27 and contained in addressSpace.')
  param gatewaySubnetAddressPrefix string

  @description('Azure Firewall private IP. The GatewaySubnet route table sends spoke traffic from VPN clients to it, and the hub (and so every VPN client) uses its DNS proxy.')
  param firewallPrivateIp string

  @description('Spoke address prefixes that VPN client traffic must reach through the firewall.')
  param spokeAddressPrefixes array

  @description('Management subnet prefixes Bastion may open SSH/RDP sessions to.')
  param bastionTargetAddressPrefixes array

  @description('Apply a CanNotDelete lock to the hub VNet.')
  param enableDeleteLock bool = false

  var firewallSubnetName = 'AzureFirewallSubnet'
  var bastionSubnetName = 'AzureBastionSubnet'
  var gatewaySubnetName = 'GatewaySubnet'
  var bastionNsgName = '${vnetName}-bastion-nsg'
  var gatewayRouteTableName = '${vnetName}-gateway-rt'

  // Rules Microsoft requires on AzureBastionSubnet; SSH/RDP egress is narrowed to the management subnets.
  resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: bastionNsgName
    location: location
    properties: {
      securityRules: [
        {
          name: 'allow-https-inbound'
          properties: {
            priority: 100
            access: 'Allow'
            direction: 'Inbound'
            protocol: 'Tcp'
            sourceAddressPrefix: 'Internet'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '443'
          }
        }
        {
          name: 'allow-gateway-manager-inbound'
          properties: {
            priority: 110
            access: 'Allow'
            direction: 'Inbound'
            protocol: 'Tcp'
            sourceAddressPrefix: 'GatewayManager'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '443'
          }
        }
        {
          name: 'allow-load-balancer-inbound'
          properties: {
            priority: 120
            access: 'Allow'
            direction: 'Inbound'
            protocol: 'Tcp'
            sourceAddressPrefix: 'AzureLoadBalancer'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '443'
          }
        }
        {
          name: 'allow-bastion-host-communication-inbound'
          properties: {
            priority: 130
            access: 'Allow'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            sourcePortRange: '*'
            destinationAddressPrefix: 'VirtualNetwork'
            destinationPortRanges: [
              '8080'
              '5701'
            ]
          }
        }
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        {
          name: 'allow-ssh-rdp-to-management-outbound'
          properties: {
            priority: 100
            access: 'Allow'
            direction: 'Outbound'
            protocol: 'Tcp'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefixes: bastionTargetAddressPrefixes
            destinationPortRanges: [
              '22'
              '3389'
            ]
          }
        }
        {
          name: 'allow-azure-cloud-outbound'
          properties: {
            priority: 110
            access: 'Allow'
            direction: 'Outbound'
            protocol: 'Tcp'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: 'AzureCloud'
            destinationPortRange: '443'
          }
        }
        {
          name: 'allow-bastion-host-communication-outbound'
          properties: {
            priority: 120
            access: 'Allow'
            direction: 'Outbound'
            protocol: '*'
            sourceAddressPrefix: 'VirtualNetwork'
            sourcePortRange: '*'
            destinationAddressPrefix: 'VirtualNetwork'
            destinationPortRanges: [
              '8080'
              '5701'
            ]
          }
        }
        {
          name: 'allow-session-information-outbound'
          properties: {
            priority: 130
            access: 'Allow'
            direction: 'Outbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: 'Internet'
            destinationPortRange: '80'
          }
        }
        {
          name: 'deny-other-ssh-rdp-outbound'
          properties: {
            priority: 4000
            access: 'Deny'
            direction: 'Outbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRanges: [
              '22'
              '3389'
            ]
          }
        }
      ]
    }
  }

  // VPN client traffic to the spoke goes through the firewall. BGP propagation stays on: GatewaySubnet requires it.
  resource gatewayRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
    name: gatewayRouteTableName
    location: location
    properties: {
      disableBgpRoutePropagation: false
      routes: [for (prefix, i) in spokeAddressPrefixes: {
        name: 'spoke-${i}-through-firewall'
        properties: {
          addressPrefix: prefix
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: firewallPrivateIp
        }
      }]
    }
  }

  // Dedicated hub network hosting the firewall, Bastion and the VPN gateway. The Bastion and gateway
  // subnets always exist (they are free) so turning admin access on or off never reshapes the VNet.
  resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
    name: vnetName
    location: location
    properties: {
      addressSpace: {
        addressPrefixes: addressSpace
      }
      // VPN clients receive the hub DNS servers, so they resolve privatelink zones through the firewall DNS proxy (ADR-005).
      dhcpOptions: {
        dnsServers: [
          firewallPrivateIp
        ]
      }
      subnets: [
        {
          name: firewallSubnetName
          properties: {
            addressPrefix: firewallSubnetAddressPrefix
          }
        }
        {
          name: bastionSubnetName
          properties: {
            addressPrefix: bastionSubnetAddressPrefix
            networkSecurityGroup: {
              id: bastionNsg.id
            }
          }
        }
        {
          name: gatewaySubnetName
          properties: {
            addressPrefix: gatewaySubnetAddressPrefix
            routeTable: {
              id: gatewayRouteTable.id
            }
          }
        }
      ]
    }
  }

  resource hubVnetLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: hubVnet
    name: '${vnetName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  output id string = hubVnet.id
  output name string = hubVnet.name
  output firewallSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnet.name, firewallSubnetName)
  output bastionSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnet.name, bastionSubnetName)
  output gatewaySubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', hubVnet.name, gatewaySubnetName)
  ```

  Create `modules/bastion.bicep`:

  ```bicep
  @description('Azure region for Bastion.')
  param location string

  @description('Bastion host name.')
  @minLength(1)
  @maxLength(80)
  param bastionName string

  @description('Bastion public IP name.')
  @minLength(1)
  @maxLength(80)
  param publicIpName string

  @description('AzureBastionSubnet resource ID.')
  param subnetId string

  @description('Availability zones for Bastion and its public IP, for example [\'1\', \'2\', \'3\']. Zones are fixed at creation.')
  param availabilityZones array = []

  @description('Log Analytics workspace resource ID for Bastion audit logs.')
  param logAnalyticsWorkspaceId string

  // Static Standard public IP; Bastion is the only inbound internet entry point for admin sessions.
  resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
    name: publicIpName
    location: location
    zones: empty(availabilityZones) ? null : availabilityZones
    sku: {
      name: 'Standard'
    }
    properties: {
      publicIPAllocationMethod: 'Static'
    }
  }

  // Standard SKU: native client (az network bastion ssh/rdp) and IP-based connect need it.
  resource bastion 'Microsoft.Network/bastionHosts@2024-07-01' = {
    name: bastionName
    location: location
    zones: empty(availabilityZones) ? null : availabilityZones
    sku: {
      name: 'Standard'
    }
    properties: {
      enableTunneling: true
      enableIpConnect: true
      scaleUnits: 2
      ipConfigurations: [
        {
          name: 'bastion-ipconfig'
          properties: {
            subnet: {
              id: subnetId
            }
            publicIPAddress: {
              id: bastionPublicIp.id
            }
          }
        }
      ]
    }
  }

  // Session audit trail (who connected to which VM, when) in the central workspace.
  resource bastionDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: bastion
    name: 'bastion-diagnostics'
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logs: [
        {
          categoryGroup: 'allLogs'
          enabled: true
        }
      ]
      metrics: [
        {
          category: 'AllMetrics'
          enabled: true
        }
      ]
    }
  }

  output id string = bastion.id
  output name string = bastion.name
  ```

  Create `modules/vpnGateway.bicep`:

  ```bicep
  @description('Azure region for the VPN gateway.')
  param location string

  @description('VPN gateway name.')
  @minLength(1)
  @maxLength(80)
  param gatewayName string

  @description('Name prefix for the two public IPs of the active-active gateway; -1 and -2 are appended.')
  @minLength(1)
  @maxLength(78)
  param publicIpNamePrefix string

  @description('GatewaySubnet resource ID.')
  param gatewaySubnetId string

  @description('Zone-redundant VPN gateway SKU.')
  @allowed([
    'VpnGw1AZ'
    'VpnGw2AZ'
    'VpnGw3AZ'
  ])
  param skuName string = 'VpnGw2AZ'

  @description('Availability zones for the gateway public IP. AZ gateway SKUs spread across the zones of their public IP.')
  param availabilityZones array = [
    '1'
    '2'
    '3'
  ]

  @description('Point-to-site client address pool.')
  param vpnClientAddressPool string

  @description('Microsoft Entra tenant ID that authenticates VPN users.')
  param tenantId string = tenant().tenantId

  @description('Application (audience) ID of the Microsoft-registered Azure VPN Client app.')
  param vpnClientAudience string = 'c632b3df-fb67-4d84-bdcf-b95ad541b5c8'

  @description('First customer-controlled gateway maintenance window, in UTC (yyyy-MM-dd HH:mm). It repeats every Sunday; Azure requires at least 5 hours.')
  param maintenanceWindowStartDateTime string = '2026-10-04 06:00'

  @description('Log Analytics workspace resource ID for gateway and P2S logs.')
  param logAnalyticsWorkspaceId string

  var instances = [
    1
    2
  ]

  // One public IP per active-active instance.
  resource gatewayPublicIps 'Microsoft.Network/publicIPAddresses@2025-01-01' = [for instance in instances: {
    name: '${publicIpNamePrefix}-${instance}'
    location: location
    zones: availabilityZones
    sku: {
      name: 'Standard'
    }
    properties: {
      publicIPAllocationMethod: 'Static'
    }
  }]

  // Point-to-site only: OpenVPN with Microsoft Entra ID authentication, no certificates or RADIUS.
  resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-07-01' = {
    name: gatewayName
    location: location
    properties: {
      gatewayType: 'Vpn'
      vpnType: 'RouteBased'
      vpnGatewayGeneration: 'Generation2'
      sku: {
        name: skuName
        tier: skuName
      }
      // Active-active: two instances, so planned maintenance or an instance failure drops only half the sessions.
      activeActive: true
      enableBgp: false
      ipConfigurations: [for (instance, i) in instances: {
        name: 'gateway-ipconfig-${instance}'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: gatewaySubnetId
          }
          publicIPAddress: {
            id: gatewayPublicIps[i].id
          }
        }
      }]
      vpnClientConfiguration: {
        vpnClientAddressPool: {
          addressPrefixes: [
            vpnClientAddressPool
          ]
        }
        vpnClientProtocols: [
          'OpenVPN'
        ]
        vpnAuthenticationTypes: [
          'AAD'
        ]
        aadTenant: '${environment().authentication.loginEndpoint}${tenantId}/'
        aadAudience: vpnClientAudience
        aadIssuer: 'https://sts.windows.net/${tenantId}/'
      }
    }
  }

  resource gatewayDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: vpnGateway
    name: 'vpn-gateway-diagnostics'
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logs: [
        {
          categoryGroup: 'allLogs'
          enabled: true
        }
      ]
      metrics: [
        {
          category: 'AllMetrics'
          enabled: true
        }
      ]
    }
  }

  // Customer-controlled maintenance: Azure patches the gateway only inside this weekly window.
  resource gatewayMaintenance 'Microsoft.Maintenance/maintenanceConfigurations@2023-04-01' = {
    name: '${gatewayName}-maintenance'
    location: location
    properties: {
      maintenanceScope: 'Resource'
      maintenanceWindow: {
        startDateTime: maintenanceWindowStartDateTime
        duration: '05:00'
        timeZone: 'UTC'
        recurEvery: 'Week Sunday'
      }
    }
  }

  resource gatewayMaintenanceAssignment 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = {
    name: '${gatewayName}-maintenance'
    scope: vpnGateway
    location: location
    properties: {
      maintenanceConfigurationId: gatewayMaintenance.id
      resourceId: vpnGateway.id
    }
  }

  output id string = vpnGateway.id
  output name string = vpnGateway.name
  ```

- [ ] **Step 6: Replace the spoke network, peering, and firewall modules**

  Replace `modules/spokeNetwork.bicep`:

  ```bicep
  @description('Azure region for the spoke network resources.')
  param location string

  @description('Spoke virtual network name.')
  @minLength(2)
  @maxLength(64)
  param vnetName string

  @description('Non-overlapping spoke address space.')
  param vnetAddressSpace array = [
    '10.0.0.0/16'
  ]

  @description('Firewall private IP used for App Service egress and VNet DNS proxy traffic.')
  param firewallPrivateIp string

  @description('Log Analytics workspace resource ID for VNet diagnostics.')
  param logAnalyticsWorkspaceId string

  @description('CIDR ranges allowed to reach private endpoints over HTTPS. The caller derives these from subnet prefixes so they cannot drift.')
  param approvedPrivateEndpointSourceCidrs array

  @description('Private endpoint subnet name.')
  param privateEndpointSubnetName string = 'private-endpoints'

  @description('App Service integration subnet name.')
  param appServiceIntegrationSubnetName string = 'appservice-integration'

  @description('Private endpoint subnet address prefix.')
  param privateEndpointSubnetAddressPrefix string = '10.0.1.0/24'

  @description('App Service integration subnet address prefix.')
  param appServiceIntegrationSubnetAddressPrefix string = '10.0.2.0/24'

  @description('Virtual machine subnet name.')
  param virtualMachineSubnetName string = 'management'

  @description('Virtual machine subnet address prefix.')
  param virtualMachineSubnetAddressPrefix string = '10.0.3.0/24'

  @description('Apply a CanNotDelete lock to the spoke VNet.')
  param enableDeleteLock bool = false

  @description('CIDR ranges allowed to reach management VMs over SSH (22) and RDP (3389), such as AzureBastionSubnet or the P2S VPN client pool. An empty list denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  var appServiceRouteTableName = '${vnetName}-appservice-egress-rt'
  var virtualMachineRouteTableName = '${vnetName}-${virtualMachineSubnetName}-egress-rt'
  var privateEndpointNsgName = '${vnetName}-${privateEndpointSubnetName}-nsg'
  var appServiceIntegrationNsgName = '${vnetName}-${appServiceIntegrationSubnetName}-nsg'
  var virtualMachineNsgName = '${vnetName}-${virtualMachineSubnetName}-nsg'

  // Administrative inbound is only rendered when approved management sources are supplied.
  var managementInboundRules = empty(managementSourceCidrs) ? [] : [
    {
      name: 'allow-management-ssh-rdp'
      properties: {
        priority: 100
        access: 'Allow'
        direction: 'Inbound'
        protocol: 'Tcp'
        sourceAddressPrefixes: managementSourceCidrs
        sourcePortRange: '*'
        destinationAddressPrefix: virtualMachineSubnetAddressPrefix
        destinationPortRanges: [
          '22'
          '3389'
        ]
      }
    }
  ]
  // No spoke subnet opens SSH/RDP sessions to other hosts (PSRule Azure.NSG.LateralTraversal).
  var denyLateralTraversalRule = {
    name: 'deny-ssh-rdp-outbound'
    properties: {
      priority: 4000
      access: 'Deny'
      direction: 'Outbound'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }

  // NSG for the private endpoint subnet; source CIDRs are explicit deployment inputs.
  resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: privateEndpointNsgName
    location: location
    properties: {
      securityRules: [
        {
          name: 'allow-approved-https'
          properties: {
            priority: 100
            access: 'Allow'
            direction: 'Inbound'
            protocol: 'Tcp'
            sourceAddressPrefixes: approvedPrivateEndpointSourceCidrs
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '443'
          }
        }
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        denyLateralTraversalRule
      ]
    }
  }

  // NSG for the delegated App Service integration subnet.
  resource appServiceIntegrationNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: appServiceIntegrationNsgName
    location: location
    properties: {
      securityRules: [
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        denyLateralTraversalRule
      ]
    }
  }

  // Route only App Service integration egress through Azure Firewall.
  resource appServiceRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
    name: appServiceRouteTableName
    location: location
    properties: {
      disableBgpRoutePropagation: true
      routes: [
        {
          name: 'default-through-firewall'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopIpAddress: firewallPrivateIp
          }
        }
      ]
    }
  }

  // Dedicated NSG for the management subnet; denies everything except approved admin sources.
  resource virtualMachineNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: virtualMachineNsgName
    location: location
    properties: {
      securityRules: concat(managementInboundRules, [
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        denyLateralTraversalRule
      ])
    }
  }

  // Route management subnet egress through Azure Firewall; gateway routes are not propagated.
  resource virtualMachineRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
    name: virtualMachineRouteTableName
    location: location
    properties: {
      disableBgpRoutePropagation: true
      routes: [
        {
          name: 'default-through-firewall'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopIpAddress: firewallPrivateIp
          }
        }
      ]
    }
  }

  module vnet 'vnet.bicep' = {
    params: {
      vnetName: vnetName
      location: location
      vnetAddressSpace: vnetAddressSpace
      dnsServer: [
        firewallPrivateIp
      ]
      subnets: [
        {
          name: privateEndpointSubnetName
          addressPrefix: privateEndpointSubnetAddressPrefix
          nsgId: privateEndpointNsg.id
          privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
        {
          name: appServiceIntegrationSubnetName
          addressPrefix: appServiceIntegrationSubnetAddressPrefix
          delegation: 'Microsoft.Web/serverFarms'
          nsgId: appServiceIntegrationNsg.id
          udrId: appServiceRouteTable.id
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
        {
          name: virtualMachineSubnetName
          addressPrefix: virtualMachineSubnetAddressPrefix
          nsgId: virtualMachineNsg.id
          udrId: virtualMachineRouteTable.id
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      ]
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      virtualMachineSubnetName: virtualMachineSubnetName
      enableDeleteLock: enableDeleteLock
      enableDiagnostics: true
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  output id string = vnet.outputs.id
  output name string = vnet.outputs.name
  output privateEndpointSubnetId string = vnet.outputs.privateEndpointSubnetId
  output appServiceIntegrationSubnetId string = vnet.outputs.appServiceIntegrationSubnetId
  output virtualMachineSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.outputs.name, virtualMachineSubnetName)
  ```

  Replace `modules/networkIntegration.bicep`:

  ```bicep
  @description('Hub VNet name.')
  @minLength(2)
  @maxLength(64)
  param hubVnetName string

  @description('Hub VNet resource ID. Creates an explicit deployment dependency.')
  param hubVnetId string

  @description('Spoke VNet name.')
  @minLength(2)
  @maxLength(64)
  param spokeVnetName string

  @description('Spoke VNet resource ID. Creates an explicit deployment dependency.')
  param spokeVnetId string

  @description('Storage account name receiving the application identity role assignment.')
  @minLength(3)
  @maxLength(24)
  param storageAccountName string

  @description('Storage account resource ID. Creates an explicit deployment dependency.')
  param storageAccountId string

  @description('Blob container that receives the application identity role assignment.')
  @minLength(3)
  @maxLength(63)
  param storageContainerName string

  @description('App Service managed identity principal ID.')
  param appServicePrincipalId string

  @description('App Service name used to make the role assignment GUID deterministic.')
  @minLength(2)
  @maxLength(60)
  param appServiceName string

  @description('Allow forwarded traffic across the hub/spoke peering for firewall service chaining.')
  param allowForwardedTraffic bool = true

  @description('Share the hub VPN gateway with the spoke (gateway transit). Only set when the gateway exists; the spoke peering fails otherwise.')
  param useHubGateway bool = false

  resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
    name: hubVnetName
  }

  resource spokeVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
    name: spokeVnetName
  }

  resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
    name: storageAccountName

    resource blobService 'blobServices' existing = {
      name: 'default'

      resource container 'containers' existing = {
        name: storageContainerName
      }
    }
  }

  // Hub-side peering for centralized firewall service chaining; offers the VPN gateway when it exists.
  resource hubToSpokePeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
    parent: hubVnet
    name: 'hub-to-spoke'
    properties: {
      allowVirtualNetworkAccess: true
      allowForwardedTraffic: allowForwardedTraffic
      allowGatewayTransit: useHubGateway
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: spokeVnetId
      }
    }
  }

  // Spoke-side reciprocal peering; learns the VPN client pool through the hub gateway.
  resource spokeToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
    parent: spokeVnet
    name: 'spoke-to-hub'
    properties: {
      allowVirtualNetworkAccess: true
      allowForwardedTraffic: allowForwardedTraffic
      allowGatewayTransit: false
      useRemoteGateways: useHubGateway
      remoteVirtualNetwork: {
        id: hubVnetId
      }
    }
  }

  // Least-privilege data-plane access for the App Service managed identity, limited to the application container.
  resource storageBlobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: guid(storageAccountId, storageContainerName, appServiceName, 'Storage Blob Data Contributor')
    scope: storageAccount::blobService::container
    properties: {
      principalId: appServicePrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    }
  }
  ```

  Replace `modules/azureFirewall.bicep`:

  ```bicep
  @description('Azure region for the firewall resources.')
  param location string

  @description('Azure Firewall name.')
  @minLength(1)
  @maxLength(56)
  param firewallName string

  @description('Azure Firewall Policy name.')
  @minLength(1)
  @maxLength(80)
  param firewallPolicyName string

  @description('Azure Firewall public IP name.')
  @minLength(1)
  @maxLength(80)
  param publicIpName string

  @description('Azure Firewall subnet resource ID.')
  param firewallSubnetId string

  @description('Log Analytics workspace resource ID.')
  param logAnalyticsWorkspaceId string

  @description('Spoke CIDR ranges permitted to use the firewall DNS proxy and application rules.')
  param spokeAddressPrefixes array

  @description('Management subnet CIDR ranges permitted to reach OS update endpoints.')
  param managementAddressPrefixes array

  @description('Point-to-site VPN client pools permitted to reach the management subnet over SSH/RDP.')
  param vpnClientAddressPrefixes array = []

  @description('Approved outbound FQDNs for App Service traffic. An empty list denies application traffic by default.')
  param allowedOutboundFqdns array = []

  @description('Availability zones for the firewall and its public IP, for example [\'1\', \'2\', \'3\']. Zones are fixed at creation, so leave empty when updating an existing non-zonal firewall.')
  param availabilityZones array = []

  @description('Firewall and policy tier. Premium adds IDPS (and TLS inspection, deferred by ADR-011).')
  @allowed([
    'Standard'
    'Premium'
  ])
  param firewallTier string = 'Premium'

  @description('Threat intelligence mode for the firewall policy.')
  @allowed([
    'Alert'
    'Deny'
    'Off'
  ])
  param threatIntelMode string = 'Deny'

  @description('IDPS mode for Premium policies: Alert logs signature hits, Deny also blocks them. Ignored for Standard.')
  @allowed([
    'Alert'
    'Deny'
    'Off'
  ])
  param idpsMode string = 'Deny'

  @description('Per-signature IDPS overrides for Premium policies, for example to Alert-only on one signature that false-positives against legitimate traffic. Find the signature ID in the AZFWIdpsSignature table\'s SignatureId column. Each entry: { id: \'<signatureId>\', mode: \'Alert\' | \'Deny\' | \'Off\' }. Empty by default; never used to disable IDPS as a whole (use idpsMode = \'Off\' for that, which this project does not do).')
  param idpsSignatureOverrides array = []

  @description('Apply CanNotDelete locks to the firewall, its policy, and its public IP.')
  param enableDeleteLock bool = false

  var isPremium = firewallTier == 'Premium'

  // Static Standard public IP used by Azure Firewall for controlled egress.
  resource firewallPublicIp 'Microsoft.Network/publicIPAddresses@2025-01-01' = {
    name: publicIpName
    location: location
    zones: empty(availabilityZones) ? null : availabilityZones
    sku: {
      name: 'Standard'
    }
    properties: {
      publicIPAllocationMethod: 'Static'
    }
  }

  // Regional policy: threat intelligence, IDPS (Premium) and the DNS proxy. Rules come from firewallPolicyRules.bicep.
  resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' = {
    name: firewallPolicyName
    location: location
    properties: {
      sku: {
        tier: firewallTier
      }
      threatIntelMode: threatIntelMode
      intrusionDetection: isPremium ? {
        mode: idpsMode
        configuration: {
          signatureOverrides: idpsSignatureOverrides
        }
      } : null
      dnsSettings: {
        enableProxy: true
      }
    }
  }

  // Baseline rule collection groups shared by every regional policy (ADR-010).
  module policyRules 'firewallPolicyRules.bicep' = {
    // One firewall per resource group, so a fixed deployment name is unique (policy names can exceed the 64-character limit).
    name: 'firewall-policy-rules'
    params: {
      firewallPolicyName: firewallPolicy.name
      spokeAddressPrefixes: spokeAddressPrefixes
      managementAddressPrefixes: managementAddressPrefixes
      vpnClientAddressPrefixes: vpnClientAddressPrefixes
      allowedOutboundFqdns: allowedOutboundFqdns
    }
  }

  // Firewall attached only to the dedicated hub subnet; applied after every rule collection group exists.
  resource firewall 'Microsoft.Network/azureFirewalls@2025-01-01' = {
    name: firewallName
    location: location
    zones: empty(availabilityZones) ? null : availabilityZones
    properties: {
      sku: {
        name: 'AZFW_VNet'
        tier: firewallTier
      }
      firewallPolicy: {
        id: firewallPolicy.id
      }
      ipConfigurations: [
        {
          name: 'firewall-ipconfig'
          properties: {
            publicIPAddress: {
              id: firewallPublicIp.id
            }
            subnet: {
              id: firewallSubnetId
            }
          }
        }
      ]
    }
    dependsOn: [
      policyRules
    ]
  }

  // Firewall activity and metrics sent to the central workspace.
  resource firewallDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: firewall
    name: 'firewall-diagnostics'
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logAnalyticsDestinationType: 'Dedicated'
      logs: [
        {
          categoryGroup: 'allLogs'
          enabled: true
        }
      ]
      metrics: [
        {
          category: 'AllMetrics'
          enabled: true
        }
      ]
    }
  }

  resource firewallLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: firewall
    name: '${firewallName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  resource firewallPolicyLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: firewallPolicy
    name: '${firewallPolicyName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  resource firewallPublicIpLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: firewallPublicIp
    name: '${publicIpName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  output id string = firewall.id
  output privateIp string = firewall.properties.ipConfigurations[0].properties.privateIPAddress
  output publicIpId string = firewallPublicIp.id
  output policyId string = firewallPolicy.id
  ```

  Replace `modules/firewallPolicyRules.bicep`:

  ```bicep
  // Baseline rule collection groups shared by every regional firewall policy (ADR-010).
  // Rule collection groups on one policy must not update concurrently, so each group depends on the previous one.

  @description('Existing firewall policy name in this resource group.')
  param firewallPolicyName string

  @description('Spoke CIDR ranges permitted to use the firewall DNS proxy, Azure Monitor egress, and approved application rules.')
  param spokeAddressPrefixes array

  @description('Management subnet CIDR ranges permitted to reach OS update endpoints (Windows Update, Ubuntu archives).')
  param managementAddressPrefixes array

  @description('Point-to-site VPN client pools permitted to open SSH/RDP sessions to the management subnet.')
  param vpnClientAddressPrefixes array

  @description('Approved outbound FQDNs for application traffic. An empty list deploys no application allowlist.')
  param allowedOutboundFqdns array = []


  resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' existing = {
    name: firewallPolicyName
  }

  // Platform egress for the spoke VNet: DNS proxy and Azure Monitor Agent ingestion.
  resource dnsEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
    parent: firewallPolicy
    name: 'dns-egress'
    properties: {
      priority: 100
      ruleCollections: [
        {
          name: 'dns'
          priority: 100
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              // With the firewall's DNS proxy on (dnsSettings.enableProxy in
              // azureFirewall.bicep), spoke clients query the firewall's own
              // private IP for DNS, which the firewall's DNS proxy itself
              // resolves and never appears as network traffic evaluated by this
              // rule collection group. This rule instead covers a spoke client
              // that bypasses the proxy and queries 168.63.129.16 (Azure's
              // recursive resolver) directly — a supported but non-default
              // configuration. Under the normal, proxied path this rule is
              // inert (nothing matches it); it exists as a fallback, not the
              // primary DNS path.
              ruleType: 'NetworkRule'
              name: 'azure-dns'
              ipProtocols: [
                'UDP'
                'TCP'
              ]
              sourceAddresses: spokeAddressPrefixes
              destinationAddresses: [
                '168.63.129.16'
              ]
              destinationPorts: [
                '53'
              ]
            }
          ]
        }
        {
          name: 'azure-monitor'
          priority: 110
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'azure-monitor-agent'
              ipProtocols: [
                'TCP'
              ]
              sourceAddresses: spokeAddressPrefixes
              destinationAddresses: [
                'AzureMonitor'
                'AzureResourceManager'
              ]
              destinationPorts: [
                '443'
              ]
            }
          ]
        }
      ]
    }
  }

  // Admin sessions from VPN clients to the management subnet. GatewaySubnet routes spoke traffic here, so
  // the firewall logs every SSH/RDP session. Private endpoint traffic is direct and NSG-enforced (ADR-013).
  resource adminAccess 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
    parent: firewallPolicy
    name: 'admin-access'
    properties: {
      priority: 120
      ruleCollections: [
        {
          name: 'vpn-to-management'
          priority: 120
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'vpn-ssh-rdp'
              ipProtocols: [
                'TCP'
              ]
              sourceAddresses: vpnClientAddressPrefixes
              destinationAddresses: managementAddressPrefixes
              destinationPorts: [
                '22'
                '3389'
              ]
            }
          ]
        }
      ]
    }
    dependsOn: [
      dnsEgress
    ]
  }

  // OS update endpoints for management VMs only; the App Service subnet never gets these.
  resource platformEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
    parent: firewallPolicy
    name: 'platform-egress'
    properties: {
      priority: 150
      ruleCollections: [
        {
          name: 'os-updates'
          priority: 150
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'windows-update'
              sourceAddresses: managementAddressPrefixes
              protocols: [
                {
                  protocolType: 'Http'
                  port: 80
                }
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: [
                'WindowsUpdate'
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'ubuntu-archives'
              sourceAddresses: managementAddressPrefixes
              protocols: [
                {
                  protocolType: 'Http'
                  port: 80
                }
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              targetFqdns: [
                'archive.ubuntu.com'
                'security.ubuntu.com'
                'azure.archive.ubuntu.com'
                '*.azure.archive.ubuntu.com'
              ]
            }
          ]
        }
      ]
    }
    dependsOn: [
      adminAccess
    ]
  }

  // Optional application allowlist; no group is deployed when the allowlist is empty.
  resource approvedHttpsEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = if (!empty(allowedOutboundFqdns)) {
    parent: firewallPolicy
    name: 'approved-https-egress'
    properties: {
      priority: 200
      ruleCollections: [
        {
          name: 'approved-https'
          priority: 200
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'approved-fqdns'
              sourceAddresses: spokeAddressPrefixes
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              targetFqdns: allowedOutboundFqdns
            }
          ]
        }
      ]
    }
    dependsOn: [
      platformEgress
    ]
  }
  ```

- [ ] **Step 7: Replace the region stamp and the entry point**

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet } from 'types.bicep'

  @description('Deployment environment.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Role of this region in the active/passive design. Only the primary gets zone-redundant App Service capacity and the optional management VM.')
  @allowed([
    'primary'
    'secondary'
  ])
  param regionRole string

  @description('Azure region for this stamp.')
  param location string

  @description('Short lowercase region code used in resource names, for example wus3 or eus.')
  @minLength(2)
  @maxLength(4)
  param regionCode string

  @description('Hub and spoke address plan for this region.')
  param addressPlan regionAddressPlan

  @description('Central Log Analytics workspace resource ID from the global layer.')
  param logAnalyticsWorkspaceId string

  @description('Shared private DNS zone resource IDs from the global layer.')
  param privateDnsZoneIds privateDnsZoneSet

  @description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('Relative path probed by App Service health check.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM (primary region only).')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in this region. The warm standby leaves it off until failover.')
  param deployAdminAccess bool = false


  var isProd = environmentName == 'prod'
  var isPrimary = regionRole == 'primary'
  var nameSuffix = uniqueString(subscription().id, environmentName, location)
  var availabilityZones = [
    '1'
    '2'
    '3'
  ]
  var names = {
    hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
    spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
    firewall: 'afw-defenstack-${environmentName}-${regionCode}'
    firewallPolicy: 'afwp-defenstack-${environmentName}-${regionCode}'
    firewallPublicIp: 'pip-afw-defenstack-${environmentName}-${regionCode}'
    storageAccount: 'st${regionCode}${nameSuffix}'
    keyVault: 'kv-${regionCode}-${nameSuffix}'
    appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
    appService: 'app-defenstack-${environmentName}-${regionCode}-${take(nameSuffix, 6)}'
    virtualMachine: 'vm${regionCode}${take(nameSuffix, 7)}'
    bastion: 'bas-defenstack-${environmentName}-${regionCode}'
    bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
    vpnGateway: 'vpng-defenstack-${environmentName}-${regionCode}'
    vpnGatewayPublicIp: 'pip-vpng-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      storageAccountSkuName: isProd ? 'Standard_GRS' : 'Standard_LRS'
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module keyVault 'keyVault.bicep' = {
    name: 'key-vault'
    params: {
      location: location
      keyVaultName: names.keyVault
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      enablePurgeProtection: true
      enabledForTemplateDeployment: true
      enableDeleteLock: isProd
    }
  }

  module hubNetwork 'hubNetwork.bicep' = {
    name: 'hub-network'
    params: {
      location: location
      vnetName: names.hubVnet
      addressSpace: addressPlan.hubAddressSpace
      firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
      bastionSubnetAddressPrefix: addressPlan.bastionSubnetPrefix
      gatewaySubnetAddressPrefix: addressPlan.gatewaySubnetPrefix
      firewallPrivateIp: firewallPrivateIp
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      bastionTargetAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      enableDeleteLock: isProd
    }
  }

  module azureFirewall 'azureFirewall.bicep' = {
    name: 'azure-firewall'
    params: {
      location: location
      firewallName: names.firewall
      firewallPolicyName: names.firewallPolicy
      publicIpName: names.firewallPublicIp
      firewallSubnetId: hubNetwork.outputs.firewallSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      managementAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      vpnClientAddressPrefixes: [
        addressPlan.vpnClientAddressPool
      ]
      allowedOutboundFqdns: allowedOutboundFqdns
      threatIntelMode: isProd ? 'Deny' : 'Alert'
      availabilityZones: availabilityZones
      firewallTier: 'Premium'
      idpsMode: isProd ? 'Deny' : 'Alert'
      enableDeleteLock: isProd
    }
  }

  module spokeNetwork 'spokeNetwork.bicep' = {
    name: 'spoke-network'
    params: {
      location: location
      vnetName: names.spokeVnet
      firewallPrivateIp: azureFirewall.outputs.privateIp
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      vnetAddressSpace: addressPlan.spokeAddressSpace
      privateEndpointSubnetAddressPrefix: addressPlan.privateEndpointSubnetPrefix
      appServiceIntegrationSubnetAddressPrefix: addressPlan.appServiceIntegrationSubnetPrefix
      virtualMachineSubnetAddressPrefix: addressPlan.managementSubnetPrefix
      approvedPrivateEndpointSourceCidrs: concat([
        addressPlan.appServiceIntegrationSubnetPrefix
        addressPlan.managementSubnetPrefix
        addressPlan.vpnClientAddressPool
      ], additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  module appService 'appService.bicep' = {
    name: 'app-service'
    params: {
      location: location
      appServiceAppName: names.appService
      appServicePlanName: names.appServicePlan
      environmentType: environmentName
      vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      healthCheckPath: healthCheckPath
      zoneRedundant: isProd && isPrimary
      instanceCount: isProd && isPrimary ? 3 : 1
    }
  }

  module virtualMachine 'virtualMachine.bicep' = if (enableVirtualMachine && isPrimary) {
    name: 'virtual-machine'
    params: {
      location: location
      vmName: names.virtualMachine
      osType: virtualMachineOsType
      subnetId: spokeNetwork.outputs.virtualMachineSubnetId
      adminUsername: virtualMachineAdminUsername
      adminSshPublicKey: virtualMachineAdminSshPublicKey
      adminPassword: virtualMachineAdminPassword
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      managementSourceCidrs: adminSourceCidrs
    }
  }

  module bastion 'bastion.bicep' = if (deployAdminAccess) {
    name: 'bastion'
    params: {
      location: location
      bastionName: names.bastion
      publicIpName: names.bastionPublicIp
      subnetId: hubNetwork.outputs.bastionSubnetId
      availabilityZones: availabilityZones
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    // The hub resolves DNS through the firewall, so admin access waits for it.
    dependsOn: [
      azureFirewall
    ]
  }

  module vpnGateway 'vpnGateway.bicep' = if (deployAdminAccess) {
    name: 'vpn-gateway'
    params: {
      location: location
      gatewayName: names.vpnGateway
      publicIpNamePrefix: names.vpnGatewayPublicIp
      gatewaySubnetId: hubNetwork.outputs.gatewaySubnetId
      skuName: isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'
      availabilityZones: availabilityZones
      vpnClientAddressPool: addressPlan.vpnClientAddressPool
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    dependsOn: [
      azureFirewall
    ]
  }

  module networkIntegration 'networkIntegration.bicep' = {
    name: 'network-integration'
    params: {
      hubVnetName: names.hubVnet
      hubVnetId: hubNetwork.outputs.id
      spokeVnetName: names.spokeVnet
      spokeVnetId: spokeNetwork.outputs.id
      storageAccountName: names.storageAccount
      storageAccountId: storage.outputs.id
      storageContainerName: storage.outputs.blobContainerName
      appServicePrincipalId: appService.outputs.appServicePrincipalId
      appServiceName: names.appService
      useHubGateway: deployAdminAccess
    }
    // Gateway transit on the peering needs a provisioned gateway.
    dependsOn: [
      vpnGateway
    ]
  }

  module privateConnectivity 'privateConnectivity.bicep' = {
    name: 'private-connectivity'
    params: {
      location: location
      storageAccountId: storage.outputs.id
      storageAccountName: names.storageAccount
      appServiceId: appService.outputs.appServiceAppId
      appServiceName: names.appService
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      keyVaultId: keyVault.outputs.id
      keyVaultName: names.keyVault
      privateDnsZoneIds: privateDnsZoneIds
    }
  }

  output hubVnetName string = names.hubVnet
  output hubVnetId string = hubNetwork.outputs.id
  output spokeVnetName string = names.spokeVnet
  output spokeVnetId string = spokeNetwork.outputs.id
  output firewallPrivateIp string = azureFirewall.outputs.privateIp
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  ```

  Replace `main.bicep`:

  ```bicep
  targetScope = 'subscription'

  import { regionAddressPlan, privateDnsZoneSet } from 'modules/types.bicep'

  @description('Deployment environment. Selects resource group names, redundancy, and deletion protection.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Primary (active) Azure region. Each allowed region has a short code in regionCodes.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param primaryLocation string = 'westus3'

  @description('Secondary (warm standby) Azure region, the platform pair of the primary.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param secondaryLocation string = 'eastus'

  @description('Deploy the secondary region stamp. Prod enables it; dev runs primary-only to halve cost.')
  param deploySecondaryRegion bool = false

  @description('Address plan for the primary region.')
  param primaryAddressPlan regionAddressPlan

  @description('Address plan for the secondary region. Required when deploySecondaryRegion is true.')
  param secondaryAddressPlan regionAddressPlan?

  @description('Approved outbound HTTPS destinations for both regions. Empty keeps application traffic denied.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges allowed to reach private endpoints over HTTPS in every region.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('Extra CIDR ranges allowed to administer management VMs over SSH/RDP, beyond the AzureBastionSubnet and VPN client pool of each region.')
  param managementSourceCidrs array = []

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the primary region.')
  param deployPrimaryAdminAccess bool = true

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the secondary region. Off in steady state; turned on during failover.')
  param deploySecondaryAdminAccess bool = false


  @description('Relative path probed by App Service health check in every region.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM in the primary region.')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  var isProd = environmentName == 'prod'
  var regionCodes = {
    westus3: 'wus3'
    eastus: 'eus'
  }
  var primaryRegionCode = regionCodes[toLower(primaryLocation)]
  var secondaryRegionCode = regionCodes[toLower(secondaryLocation)]
  var globalResourceGroupName = 'rg-defenstack-${environmentName}-global'
  var primaryResourceGroupName = 'rg-defenstack-${environmentName}-${primaryRegionCode}'
  var secondaryResourceGroupName = 'rg-defenstack-${environmentName}-${secondaryRegionCode}'
  var privateDnsZoneNames privateDnsZoneSet = {
    blob: 'privatelink.blob.${environment().suffixes.storage}'
    sites: 'privatelink.azurewebsites.net'
    vault: 'privatelink.vaultcore.azure.net'
  }

  // Shared layer: Log Analytics and private DNS zones. Resource groups are pre-created (runbook 01).
  module global 'modules/global.bicep' = {
    name: 'global-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      location: primaryLocation
      workspaceName: 'log-defenstack-${environmentName}'
      privateDnsZoneNames: privateDnsZoneNames
      workspaceReplicationLocation: isProd && deploySecondaryRegion ? secondaryLocation : ''
      enableDeleteLock: isProd
    }
  }

  module primaryStamp 'modules/regionStamp.bicep' = {
    name: 'region-${primaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'primary'
      location: primaryLocation
      regionCode: primaryRegionCode
      addressPlan: primaryAddressPlan
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      enableVirtualMachine: enableVirtualMachine
      virtualMachineOsType: virtualMachineOsType
      virtualMachineAdminUsername: virtualMachineAdminUsername
      virtualMachineAdminSshPublicKey: virtualMachineAdminSshPublicKey
      virtualMachineAdminPassword: virtualMachineAdminPassword
      deployAdminAccess: deployPrimaryAdminAccess
    }
  }

  module secondaryStamp 'modules/regionStamp.bicep' = if (deploySecondaryRegion) {
    name: 'region-${secondaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'secondary'
      location: secondaryLocation
      regionCode: secondaryRegionCode
      addressPlan: secondaryAddressPlan!
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      deployAdminAccess: deploySecondaryAdminAccess
    }
  }

  var primaryVirtualNetworks = [
    {
      name: primaryStamp.outputs.hubVnetName
      id: primaryStamp.outputs.hubVnetId
    }
    {
      name: primaryStamp.outputs.spokeVnetName
      id: primaryStamp.outputs.spokeVnetId
    }
  ]
  var secondaryVirtualNetworks = deploySecondaryRegion
    ? [
        {
          name: secondaryStamp!.outputs.hubVnetName
          id: secondaryStamp!.outputs.hubVnetId
        }
        {
          name: secondaryStamp!.outputs.spokeVnetName
          id: secondaryStamp!.outputs.spokeVnetId
        }
      ]
    : []

  // Link every region's hub (firewall DNS proxy) and spoke to each shared zone.
  module privateDnsLinks 'modules/privateDnsZoneLinks.bicep' = [for zone in items(privateDnsZoneNames): {
    name: 'dns-links-${zone.key}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      zoneName: zone.value
      virtualNetworks: concat(primaryVirtualNetworks, secondaryVirtualNetworks)
    }
  }]

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  ```

- [ ] **Step 8: Update the PSRule configuration**

  Replace `ps-rule.yaml`:

  ```yaml
  # PSRule for Azure: https://azure.github.io/PSRule.Rules.Azure/
  include:
    module:
      - PSRule.Rules.Azure

  input:
    pathIgnore:
      - '**'
      - '!params/*.bicepparam'

  configuration:
    AZURE_BICEP_PARAMS_FILE_EXPANSION: true
    # Expanding main.bicep takes ~10 s once Phase 3 modules are included; the 5 s default times out.
    AZURE_BICEP_FILE_EXPANSION_TIMEOUT: 60

  rule:
    # Exclusions apply to every environment and target. Each must name the phase that resolves it or
    # the ADR that accepts it. Gaps that apply only to some targets (dev, the East US warm standby)
    # are suppressed per target in .ps-rule/Suppression.Rule.yaml instead.
    exclude:
      # Phase 5: storage moves to RA-GZRS.
      - Azure.Storage.UseReplication
      # ADR-002: no organization-wide tagging convention exists yet.
      - Azure.Resource.UseTags
      # ADR-004: zero-trust default-deny-all-inbound is the intended design for these NSGs.
      - Azure.NSG.DenyAllInbound
      # ADR-005: the VNet DNS proxy points at Azure Firewall's single private IP by design.
      - Azure.VNET.SingleDNS
      # ADR-006: no application code is deployed yet, so no dedicated health endpoint exists.
      - Azure.AppService.WebProbePath
  ```

  Replace `.ps-rule/Suppression.Rule.yaml`:

  ```yaml
  ---
  # Synopsis: Dev and the East US warm standby run one App Service instance without zone redundancy (ADR-008).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.SingleInstanceAppServicePlans
  spec:
    rule:
      - Azure.AppService.AvailabilityZone
      - Azure.AppService.PlanInstanceCount
    if:
      name: '.'
      in:
        - asp-defenstack-dev-wus3
        - asp-defenstack-prod-eus
  ---
  # Synopsis: The dev workspace is single-region; only prod replicates to the secondary region (ADR-008).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.DevWorkspaceReplication
  spec:
    rule:
      - Azure.Log.Replication
    if:
      name: '.'
      equals: log-defenstack-dev
  ---
  # Synopsis: Dev firewall policy runs threat intelligence in Alert mode; prod runs Deny (ADR-003).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.DevFirewallAlertMode
  spec:
    rule:
      - Azure.Firewall.PolicyMode
    if:
      name: '.'
      equals: afwp-defenstack-dev-wus3
  ---
  # Synopsis: Bastion must open SSH/RDP sessions to the management subnet; its NSG allows exactly that and denies all other SSH/RDP egress (ADR-013).
  apiVersion: github.com/microsoft/PSRule/v1
  kind: SuppressionGroup
  metadata:
    name: DefenStack.BastionSessionEgress
  spec:
    rule:
      - Azure.NSG.LateralTraversal
    if:
      name: '.'
      in:
        - vnet-defenstack-dev-wus3-hub-bastion-nsg
        - vnet-defenstack-prod-wus3-hub-bastion-nsg
        - vnet-defenstack-prod-eus-hub-bastion-nsg
  ```

- [ ] **Step 9: Build, lint and regenerate main.json**

  ```bash
  bicep build main.bicep
  for f in main.bicep modules/*.bicep; do bicep lint "$f" || echo "LINT FAIL $f"; done
  bicep build-params params/dev.bicepparam --stdout > /dev/null && bicep build-params params/prod.bicepparam --stdout > /dev/null && echo PARAMS-OK
  ```

  Expected: no `LINT FAIL` line, and `PARAMS-OK`.

- [ ] **Step 10: Run the full suite and PSRule**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: `Tests Passed: 245, Failed: 0`.

  Run the PSRule command from Execution Notes.
  Expected: 0 failures, and 752 results with `Invoke-PSRule`. If you see `Bicep compilation hasn't completed within the timeout window`, `ps-rule.yaml` lost `AZURE_BICEP_FILE_EXPANSION_TIMEOUT: 60`.

- [ ] **Step 11: Commit**

  ```bash
  git add modules/types.bicep params/dev.bicepparam params/prod.bicepparam modules/hubNetwork.bicep modules/bastion.bicep modules/vpnGateway.bicep modules/spokeNetwork.bicep modules/networkIntegration.bicep modules/azureFirewall.bicep modules/firewallPolicyRules.bicep modules/regionStamp.bicep main.bicep main.json ps-rule.yaml .ps-rule/Suppression.Rule.yaml tests/Bastion.Tests.ps1 tests/VpnGateway.Tests.ps1 tests/HubNetwork.Tests.ps1 tests/SpokeNetwork.Tests.ps1 tests/NetworkIntegration.Tests.ps1 tests/FirewallPolicyRules.Tests.ps1 tests/RegionStamp.Tests.ps1 tests/Main.Tests.ps1 tests/Params.Tests.ps1
  git commit -m "feat: Bastion, active-active P2S VPN gateway, gateway transit and VPN routing through the firewall" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 2: Jump host Entra login, admin role, Update Manager patching, and pipeline role delegation

**Files:**
- Replace: `modules/virtualMachine.bicep`, `modules/firewallPolicyRules.bicep`, `modules/regionStamp.bicep`, `main.bicep`, `tests/VirtualMachine.Tests.ps1`, `tests/FirewallPolicyRules.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Main.Tests.ps1`
- Modify: `scripts/New-GitHubDeploymentIdentity.ps1:37`, `tests/Scripts.Tests.ps1:176-177`, `main.json` (regenerate)

**Interfaces:**
- **Consumes (Task 1):**
  - `regionStamp.bicep` variable `adminSourceCidrs`, already passed as the VM's `managementSourceCidrs`.
  - `firewallPolicyRules.bicep` group `platform-egress` (its `os-updates` collection).
  - `main.bicep` symbols `primaryStamp` and `secondaryStamp`.
- **Produces:**
  - `virtualMachine.bicep` new params: `availabilityZone = '1'` (`'1'|'2'|'3'`), `adminGroupObjectId = ''`, `patchWindowStartDateTime = '2026-10-04 02:00'`. New variables: `entraLoginExtensionName`, `virtualMachineAdministratorLoginRoleId`, `patchSettings`.
  - `firewallPolicyRules.bicep`: variable `entraLoginHost`, and collection `entra-login` (priority 160) in `platform-egress`.
  - `regionStamp.bicep` and `main.bicep`: param `adminGroupObjectId = ''`, passed to the primary stamp only and on to the `virtual-machine` module.
  - `New-GitHubDeploymentIdentity.ps1` default `-DelegatableRoleDefinitionIds` = Storage Blob Data Contributor + Virtual Machine Administrator Login.

- [ ] **Step 1: Write the failing tests**

  Replace `tests/VirtualMachine.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/virtualMachine.bicep'
  }

  Describe 'VM NIC NSG management access (F1)' {
      It 'exposes managementSourceCidrs defaulting to an empty list' {
          $template.parameters.PSObject.Properties.Name | Should -Contain 'managementSourceCidrs'
          @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
      }
  }

  Describe 'VM monitoring (F3)' {
      BeforeAll {
          $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
          $dcr = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRules' | Select-Object -First 1
          $association = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRuleAssociations' | Select-Object -First 1
          $agent = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines/extensions' | Select-Object -First 1
      }

      It 'sends only metrics through the VM diagnostic setting (VMs expose no log categories)' {
          $diagnostics.properties.PSObject.Properties.Name | Should -Not -Contain 'logs'
          $diagnostics.properties.metrics[0].category | Should -Be 'AllMetrics'
      }

      It 'installs the Azure Monitor Agent' {
          $agent.properties.publisher | Should -Be 'Microsoft.Azure.Monitor'
          $agent.properties.enableAutomaticUpgrade | Should -BeTrue
      }

      It 'sends guest logs and performance counters to the workspace through a DCR' {
          $dcr.properties.destinations.logAnalytics[0].workspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
      }

      It 'associates the DCR with the VM' {
          $association.scope | Should -Match 'virtualMachines'
      }

      It 'outputs the DCR ID' {
          $template.outputs.PSObject.Properties.Name | Should -Contain 'dataCollectionRuleId'
      }

      It 'uses Azure Monitor counter paths with a leading backslash' {
          # dataSources compiles to the expression '[union(variables(...), variables(...))]' rather than
          # an inline object, so the literal counter text lives in the performanceCounterSource variable.
          $dcrText = $template.variables.performanceCounterSource | ConvertTo-Json -Depth 10
          $dcrText | Should -Match ([regex]::Escape('\\Processor(*)\\% Processor Time'))
      }
  }

  Describe 'VM monitoring on Windows (F3)' {
      It 'installs the Windows agent and collects System and Application events when osType is Windows' {
          $template.variables.azureMonitorAgentName | Should -Match "'AzureMonitorWindowsAgent'"
          $template.variables.osLogSource | Should -Match 'windowsEventLogs'
          $template.variables.osLogSource | Should -Match 'Microsoft-Event'
          $template.variables.osLogSource | Should -Match 'Application!'
      }
  }

  Describe 'Jump host access (Phase 3)' {
      BeforeAll {
          $vm = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines' | Select-Object -First 1
          $extensions = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines/extensions'
          $entraLogin = $extensions | Where-Object { $_.properties.publisher -eq 'Microsoft.Azure.ActiveDirectory' }
          $roleAssignment = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
          $nsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' | Select-Object -First 1
      }

      It 'pins the VM to one availability zone, zone 1 by default' {
          @($vm.zones) | Should -Be @("[parameters('availabilityZone')]")
          $template.parameters.availabilityZone.defaultValue | Should -Be '1'
      }

      It 'installs the Entra ID login extension that matches the OS' {
          $template.variables.entraLoginExtensionName | Should -Be "[if(equals(parameters('osType'), 'Linux'), 'AADSSHLoginForLinux', 'AADLoginForWindows')]"
          $entraLogin.properties.type | Should -Be "[variables('entraLoginExtensionName')]"
      }

      It 'installs the Entra extension after the Azure Monitor Agent (one extension operation at a time)' {
          ($entraLogin.dependsOn -join ' ') | Should -Match 'azureMonitorAgentName'
      }

      It 'grants the admin group Virtual Machine Administrator Login on this VM only, when a group is given' {
          $roleAssignment.condition | Should -Be "[not(empty(parameters('adminGroupObjectId')))]"
          $roleAssignment.scope | Should -Match 'virtualMachines'
          $roleAssignment.properties.principalType | Should -Be 'Group'
          $template.variables.virtualMachineAdministratorLoginRoleId | Should -Be '1c0163c0-47e6-4577-8991-ea5c82e286e4'
          $template.parameters.adminGroupObjectId.defaultValue | Should -Be ''
      }

      It 'hands patching to Update Manager on both operating systems' {
          $template.variables.patchSettings.patchMode | Should -Be 'AutomaticByPlatform'
          $template.variables.patchSettings.assessmentMode | Should -Be 'AutomaticByPlatform'
          $template.variables.patchSettings.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule | Should -BeExactly $true
          # osProfile compiles to one if() expression; both the Linux and Windows branches carry the settings.
          ([regex]::Matches($vm.properties.osProfile, [regex]::Escape("'patchSettings', variables('patchSettings')"))).Count | Should -Be 2
      }

      It 'installs critical and security updates in a weekly window and assigns it to the VM' {
          $schedule = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/maintenanceConfigurations' | Select-Object -First 1
          $assignment = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/configurationAssignments' | Select-Object -First 1
          $schedule.properties.maintenanceScope | Should -Be 'InGuestPatch'
          $schedule.properties.maintenanceWindow.recurEvery | Should -Be 'Week Sunday'
          @($schedule.properties.installPatches.linuxParameters.classificationsToInclude) -join ',' | Should -Be 'Critical,Security'
          @($schedule.properties.installPatches.windowsParameters.classificationsToInclude) -join ',' | Should -Be 'Critical,Security'
          $assignment.scope | Should -Match 'virtualMachines'
      }

      It 'denies outbound SSH and RDP from the NIC (PSRule Azure.NSG.LateralTraversal)' {
          ($nsg.properties.securityRules | ConvertTo-Json -Depth 10) | Should -Match 'deny-ssh-rdp-outbound'
      }
  }
  ```

  Replace `tests/FirewallPolicyRules.Tests.ps1` (Task 1's version plus the `Entra ID sign-in egress` block):

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/firewallPolicyRules.bicep'
      $groups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
      function Get-Group([string]$Name) {
          $groups | Where-Object { $_.name -like "*'$Name')]" }
      }
      $dns = Get-Group 'dns-egress'
      $admin = Get-Group 'admin-access'
      $platform = Get-Group 'platform-egress'
      $approved = Get-Group 'approved-https-egress'
  }

  Describe 'Baseline firewall rules (ADR-010)' {
      It 'defines the dns-egress, admin-access, platform-egress and approved-https-egress groups at priorities 100, 120, 150, 200' {
          $groups.Count | Should -Be 4
          $dns.properties.priority | Should -Be 100
          $admin.properties.priority | Should -Be 120
          $platform.properties.priority | Should -Be 150
          $approved.properties.priority | Should -Be 200
      }

      It 'updates the groups one at a time (a policy rejects concurrent rule collection group updates)' {
          @($dns.PSObject.Properties.Name) | Should -Not -Contain 'dependsOn'
          @($admin.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'dns-egress')]"
          @($platform.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'admin-access')]"
          @($approved.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'platform-egress')]"
      }

      It 'allows spoke DNS to the Azure resolver through the proxy' {
          $rule = $dns.properties.ruleCollections[0].rules[0]
          @($rule.destinationAddresses) | Should -Contain '168.63.129.16'
          @($rule.destinationPorts) | Should -Contain '53'
          $rule.sourceAddresses | Should -Be "[parameters('spokeAddressPrefixes')]"
      }

      It 'allows spoke traffic to the AzureMonitor and AzureResourceManager service tags on 443' {
          $rule = $dns.properties.ruleCollections[1].rules[0]
          @($rule.destinationAddresses) | Should -Contain 'AzureMonitor'
          @($rule.destinationAddresses) | Should -Contain 'AzureResourceManager'
          @($rule.destinationPorts) | Should -Contain '443'
      }
  }

  Describe 'Admin sessions from VPN clients (Phase 3)' {
      BeforeAll {
          $rule = $admin.properties.ruleCollections[0].rules[0]
      }

      It 'is always deployed so enabling admin access never reorders the group chain' {
          $admin.PSObject.Properties.Name | Should -Not -Contain 'condition'
      }

      It 'allows only SSH and RDP from the VPN client pools to the management subnet' {
          $admin.properties.ruleCollections[0].action.type | Should -Be 'Allow'
          $rule.ruleType | Should -Be 'NetworkRule'
          @($rule.ipProtocols) -join ',' | Should -Be 'TCP'
          $rule.sourceAddresses | Should -Be "[parameters('vpnClientAddressPrefixes')]"
          $rule.destinationAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
          @($rule.destinationPorts) -join ',' | Should -Be '22,3389'
      }
  }

  Describe 'Entra ID sign-in egress for the jump host (Phase 3)' {
      BeforeAll {
          $collection = $platform.properties.ruleCollections | Where-Object { $_.name -eq 'entra-login' }
          $rule = $collection.rules[0]
      }

      It 'allows the Entra login endpoints from the management subnet only, over HTTPS' {
          $rule.sourceAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
          @($rule.protocols.protocolType) -join ',' | Should -Be 'Https'
      }

      It 'derives the login host from the cloud environment instead of hardcoding it' {
          $template.variables.entraLoginHost | Should -Be "[split(environment().authentication.loginEndpoint, '/')[2]]"
          @($rule.targetFqdns) | Should -Contain "[variables('entraLoginHost')]"
          @($rule.targetFqdns) | Should -Contain "[format('device.{0}', variables('entraLoginHost'))]"
      }

      It 'allows the device registration, pas.windows.net and extension package endpoints' {
          foreach ($fqdn in 'pas.windows.net', 'packages.microsoft.com', 'enterpriseregistration.windows.net') {
              @($rule.targetFqdns) | Should -Contain $fqdn
          }
      }
  }

  Describe 'OS update egress for management VMs only' {
      BeforeAll {
          $rules = @($platform.properties.ruleCollections[0].rules)
          $windows = $rules | Where-Object { $_.name -eq 'windows-update' }
          $ubuntu = $rules | Where-Object { $_.name -eq 'ubuntu-archives' }
      }

      It 'sources every OS update rule from the management subnet, never the whole spoke' {
          foreach ($rule in $rules) {
              $rule.sourceAddresses | Should -Be "[parameters('managementAddressPrefixes')]"
          }
      }

      It 'allows Windows Update through its FQDN tag' {
          @($windows.fqdnTags) | Should -Contain 'WindowsUpdate'
      }

      It 'allows the Ubuntu archives over HTTP and HTTPS' {
          @($ubuntu.targetFqdns) | Should -Contain 'archive.ubuntu.com'
          @($ubuntu.targetFqdns) | Should -Contain 'security.ubuntu.com'
          @($ubuntu.targetFqdns) | Should -Contain 'azure.archive.ubuntu.com'
          @($ubuntu.protocols.port) -join ',' | Should -Be '80,443'
      }
  }

  Describe 'Application allowlist' {
      It 'is deployed only when allowedOutboundFqdns is not empty' {
          $approved.condition | Should -Be "[not(empty(parameters('allowedOutboundFqdns')))]"
          $approved.properties.ruleCollections[0].rules[0].targetFqdns | Should -Be "[parameters('allowedOutboundFqdns')]"
      }
  }
  ```

  Replace `tests/RegionStamp.Tests.ps1` (Task 1's version plus `passes the admin group to the management VM`):

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
      function Get-StampModuleParameters([string]$Name) {
          (Get-ModuleDeployment -Template $stamp -Name $Name).properties.parameters
      }
  }

  Describe 'Region stamp naming' {
      It 'names every resource with environment and region so stamps never collide' {
          foreach ($key in 'hubVnet', 'spokeVnet', 'firewall', 'firewallPolicy', 'firewallPublicIp', 'appServicePlan', 'appService') {
              $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
          }
      }

      It 'derives globally unique names from subscription, environment, and region' {
          $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
          $stamp.variables.names.storageAccount | Should -Be "[format('st{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
          $stamp.variables.names.keyVault | Should -Be "[format('kv-{0}-{1}', parameters('regionCode'), variables('nameSuffix'))]"
      }

      It 'passes the stamp names to the modules' {
          (Get-StampModuleParameters 'app-service').appServicePlanName.value | Should -Be "[variables('names').appServicePlan]"
          (Get-StampModuleParameters 'azure-firewall').firewallName.value | Should -Be "[variables('names').firewall]"
      }
  }

  Describe 'Region stamp availability' {
      It 'deploys the firewall and its public IP across zones 1-3 in every stamp' {
          @($stamp.variables.availabilityZones) -join ',' | Should -Be '1,2,3'
          (Get-StampModuleParameters 'azure-firewall').availabilityZones.value | Should -Be "[variables('availabilityZones')]"
      }

      It 'makes the App Service plan zone-redundant with 3 instances only in the prod primary region' {
          $parameters = Get-StampModuleParameters 'app-service'
          $parameters.zoneRedundant.value | Should -Be "[and(variables('isProd'), variables('isPrimary'))]"
          $parameters.instanceCount | Should -Be "[if(and(variables('isProd'), variables('isPrimary')), createObject('value', 3), createObject('value', 1))]"
      }

      It 'uses geo-redundant storage in prod and locally redundant storage in dev' {
          (Get-StampModuleParameters 'storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), createObject('value', 'Standard_GRS'), createObject('value', 'Standard_LRS'))]"
      }

      It 'deploys the optional management VM in the primary region only' {
          (Get-ModuleDeployment -Template $stamp -Name 'virtual-machine').condition |
              Should -Be "[and(parameters('enableVirtualMachine'), variables('isPrimary'))]"
      }
  }

  Describe 'Region stamp wiring carried from Phase 0' {
      It 'passes the admin source ranges (Bastion subnet, VPN pool, extra managementSourceCidrs) to <_> (F1, Phase 3)' -ForEach 'spoke-network', 'virtual-machine' {
          (Get-StampModuleParameters $_).managementSourceCidrs.value | Should -Be "[variables('adminSourceCidrs')]"
      }

      It 'uses the address plan spoke range for both the spoke VNet and firewall sources (F5)' {
          (Get-StampModuleParameters 'azure-firewall').spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
          (Get-StampModuleParameters 'spoke-network').vnetAddressSpace.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
      }

      It 'derives private endpoint sources from the App Service and management subnet prefixes (F5)' {
          $value = (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value
          $value | Should -Match "addressPlan'\)\.appServiceIntegrationSubnetPrefix"
          $value | Should -Match "addressPlan'\)\.managementSubnetPrefix"
          $value | Should -Match "addressPlan'\)\.vpnClientAddressPool"
          $value | Should -Match 'additionalPrivateEndpointSourceCidrs'
      }

      It 'uses firewall threat intelligence Deny in prod and Alert in dev (F9)' {
          (Get-StampModuleParameters 'azure-firewall').threatIntelMode |
              Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
      }

      It 'enables Key Vault template deployment so az.getSecret() references resolve (F4)' {
          (Get-StampModuleParameters 'key-vault').enabledForTemplateDeployment.value | Should -BeExactly $true
      }

      It 'passes the container name from the storage module output (F11)' {
          (Get-StampModuleParameters 'network-integration').storageContainerName.value | Should -Match 'outputs.blobContainerName'
      }

      It 'registers private endpoints in the shared zones from the global layer' {
          (Get-StampModuleParameters 'private-connectivity').privateDnsZoneIds.value | Should -Be "[parameters('privateDnsZoneIds')]"
      }

      It 'locks the spoke VNet in prod only' {
          (Get-StampModuleParameters 'spoke-network').enableDeleteLock.value | Should -Be "[variables('isProd')]"
      }
  }

  Describe 'Region stamp outputs' {
      It 'exposes the VNets the entry point links to the shared DNS zones' {
          foreach ($output in 'hubVnetName', 'hubVnetId', 'spokeVnetName', 'spokeVnetId', 'appServiceHostName') {
              $stamp.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }

  Describe 'Region stamp firewall security (Phase 2)' {
      It 'deploys Azure Firewall Premium in every stamp' {
          (Get-StampModuleParameters 'azure-firewall').firewallTier.value | Should -Be 'Premium'
      }

      It 'runs IDPS in Deny in prod and Alert in dev' {
          (Get-StampModuleParameters 'azure-firewall').idpsMode |
              Should -Be "[if(variables('isProd'), createObject('value', 'Deny'), createObject('value', 'Alert'))]"
      }

      It 'limits OS update egress to the management subnet' {
          @((Get-StampModuleParameters 'azure-firewall').managementAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
      }

      It 'locks the hub VNet, Key Vault and firewall resources in prod only (<_>)' -ForEach 'hub-network', 'key-vault', 'azure-firewall' {
          (Get-StampModuleParameters $_).enableDeleteLock.value | Should -Be "[variables('isProd')]"
      }
  }

  Describe 'Region stamp admin access (Phase 3)' {
      It 'derives admin sources from the Bastion subnet and VPN client pool, plus any extra managementSourceCidrs' {
          $stamp.variables.adminSourceCidrs |
              Should -Be "[concat(createArray(parameters('addressPlan').bastionSubnetPrefix, parameters('addressPlan').vpnClientAddressPool), parameters('managementSourceCidrs'))]"
      }

      It 'deploys <_> only when deployAdminAccess is true' -ForEach 'bastion', 'vpn-gateway' {
          (Get-ModuleDeployment -Template $stamp -Name $_).condition | Should -Be "[parameters('deployAdminAccess')]"
          $stamp.parameters.deployAdminAccess.defaultValue | Should -BeExactly $false
      }

      It 'uses VpnGw2AZ in prod and VpnGw1AZ in dev' {
          (Get-StampModuleParameters 'vpn-gateway').skuName |
              Should -Be "[if(variables('isProd'), createObject('value', 'VpnGw2AZ'), createObject('value', 'VpnGw1AZ'))]"
      }

      It 'deploys <_> after the firewall, whose DNS proxy the hub uses' -ForEach 'bastion', 'vpn-gateway' {
          @((Get-ModuleDeployment -Template $stamp -Name $_).dependsOn) | Should -Contain 'azureFirewall'
      }

      It 'spreads <_> across zones 1-3' -ForEach 'bastion', 'vpn-gateway' {
          (Get-StampModuleParameters $_).availabilityZones.value | Should -Be "[variables('availabilityZones')]"
      }

      It 'gives the gateway the region VPN client pool' {
          (Get-StampModuleParameters 'vpn-gateway').vpnClientAddressPool.value | Should -Be "[parameters('addressPlan').vpnClientAddressPool]"
      }

      It 'routes GatewaySubnet spoke traffic to the first usable firewall address, computed before the firewall exists' {
          $stamp.variables.firewallPrivateIp | Should -Be "[cidrHost(parameters('addressPlan').firewallSubnetPrefix, 3)]"
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.firewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
          $hub.spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
          @((Get-ModuleDeployment -Template $stamp -Name 'hub-network').dependsOn) | Should -Not -Contain 'azureFirewall'
      }

      It 'lets Bastion reach only the management subnet' {
          @((Get-StampModuleParameters 'hub-network').bastionTargetAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').managementSubnetPrefix]")
      }

      It 'passes the Bastion and gateway subnet prefixes from the address plan' {
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.bastionSubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').bastionSubnetPrefix]"
          $hub.gatewaySubnetAddressPrefix.value | Should -Be "[parameters('addressPlan').gatewaySubnetPrefix]"
      }

      It 'allows the VPN client pool through the firewall admin-access rules' {
          @((Get-StampModuleParameters 'azure-firewall').vpnClientAddressPrefixes.value) | Should -Be @("[parameters('addressPlan').vpnClientAddressPool]")
      }

      It 'turns on gateway transit only with admin access, after the gateway is provisioned' {
          (Get-StampModuleParameters 'network-integration').useHubGateway.value | Should -Be "[parameters('deployAdminAccess')]"
          @((Get-ModuleDeployment -Template $stamp -Name 'network-integration').dependsOn) | Should -Contain 'vpnGateway'
      }

      It 'passes the admin group to the management VM' {
          (Get-StampModuleParameters 'virtual-machine').adminGroupObjectId.value | Should -Be "[parameters('adminGroupObjectId')]"
      }

      It 'outputs the Bastion and gateway names (empty without admin access) and the expected firewall IP' {
          $stamp.outputs.bastionName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').bastion, '')]"
          $stamp.outputs.vpnGatewayName.value | Should -Be "[if(parameters('deployAdminAccess'), variables('names').vpnGateway, '')]"
          $stamp.outputs.expectedFirewallPrivateIp.value | Should -Be "[variables('firewallPrivateIp')]"
      }

      It 'names Bastion and the gateway with environment and region' {
          foreach ($key in 'bastion', 'bastionPublicIp', 'vpnGateway', 'vpnGatewayPublicIp') {
              $stamp.variables.names.$key | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
          }
      }
  }
  ```

  Replace `tests/Main.Tests.ps1` (Task 1's version plus `passes the admin group to the primary stamp only`):

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $main = Get-BicepTemplate -RelativePath 'main.bicep'
      $global = Get-TemplateResourceBySymbol -Template $main -Symbol 'global'
      $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
      $secondary = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryStamp'
      $dnsLinks = Get-TemplateResourceBySymbol -Template $main -Symbol 'privateDnsLinks'
  }

  Describe 'Subscription-scope entry point' {
      It 'targets the subscription' {
          $main.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
      }

      It 'accepts only dev and prod environments' {
          @($main.parameters.environmentName.allowedValues) -join ',' | Should -Be 'dev,prod'
      }

      It 'maps each allowed region to a short code used in names' {
          @($main.parameters.primaryLocation.allowedValues) -join ',' | Should -Be 'westus3,eastus'
          $main.variables.regionCodes.westus3 | Should -Be 'wus3'
          $main.variables.regionCodes.eastus | Should -Be 'eus'
      }

      It 'names resource groups rg-defenstack-<env>-global and rg-defenstack-<env>-<region>' {
          $main.variables.globalResourceGroupName | Should -Be "[format('rg-defenstack-{0}-global', parameters('environmentName'))]"
          $main.variables.primaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('primaryRegionCode'))]"
      }
  }

  Describe 'Composition' {
      It 'deploys the global layer into the global resource group' {
          $global.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
      }

      It 'replicates the workspace to the secondary region only for prod with DR enabled' {
          $global.properties.parameters.workspaceReplicationLocation |
              Should -Be "[if(and(variables('isProd'), parameters('deploySecondaryRegion')), createObject('value', parameters('secondaryLocation')), createObject('value', ''))]"
      }

      It 'deploys the primary stamp as primary into the primary resource group' {
          $primary.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $primary.properties.parameters.regionRole.value | Should -Be 'primary'
          $primary.properties.parameters.addressPlan.value | Should -Be "[parameters('primaryAddressPlan')]"
      }

      It 'deploys the secondary stamp only when deploySecondaryRegion is true' {
          $secondary.condition | Should -Be "[parameters('deploySecondaryRegion')]"
          $secondary.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
          $secondary.properties.parameters.regionRole.value | Should -Be 'secondary'
      }

      It 'feeds both stamps the shared workspace and DNS zone IDs' {
          foreach ($stamp in $primary, $secondary) {
              $stamp.properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[reference('global').outputs.logAnalyticsWorkspaceId.value]"
              $stamp.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
          }
      }
  }

  Describe 'Shared private DNS' {
      It 'defines the three zone names once' {
          @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault'
          $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
          $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
      }

      It 'links every zone in the global resource group' {
          $dnsLinks.copy.count | Should -Be "[length(items(variables('privateDnsZoneNames')))]"
          $dnsLinks.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
      }

      It 'links the hub and spoke VNets of the primary and (when deployed) the secondary stamp' {
          $value = $dnsLinks.properties.parameters.virtualNetworks.value
          foreach ($output in 'hubVnetId', 'spokeVnetId') {
              $value | Should -Match "reference\('primaryStamp'\)\.outputs\.$output"
              $value | Should -Match "reference\('secondaryStamp'\)\.outputs\.$output"
          }
          $value | Should -Match "parameters\('deploySecondaryRegion'\)"
      }
  }

  Describe 'Admin access (Phase 3)' {
      It 'deploys admin access in the primary region by default and keeps the warm standby off until failover' {
          $main.parameters.deployPrimaryAdminAccess.defaultValue | Should -BeExactly $true
          $main.parameters.deploySecondaryAdminAccess.defaultValue | Should -BeExactly $false
          $primary.properties.parameters.deployAdminAccess.value | Should -Be "[parameters('deployPrimaryAdminAccess')]"
          $secondary.properties.parameters.deployAdminAccess.value | Should -Be "[parameters('deploySecondaryAdminAccess')]"
      }

      It 'passes the admin group to the primary stamp only (the jump host is primary-only)' {
          $main.parameters.adminGroupObjectId.defaultValue | Should -Be ''
          $primary.properties.parameters.adminGroupObjectId.value | Should -Be "[parameters('adminGroupObjectId')]"
          $secondary.properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'adminGroupObjectId'
      }

      It 'outputs what runbook 03 needs to connect' {
          foreach ($output in 'primaryResourceGroupName', 'primaryBastionName', 'primaryVpnGatewayName', 'primaryFirewallPrivateIp') {
              $main.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }
  ```

  In `tests/Scripts.Tests.ps1`, replace the `It` line and the `$expected = ...` line of the ABAC condition test (lines 176–177) with:

  ```powershell
          It 'constrains RBAC Administrator with the exact ABAC condition for Storage Blob Data Contributor and Virtual Machine Administrator Login' {
              $expected = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4}))"
  ```

  The rest of that `It` block is unchanged.

- [ ] **Step 2: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected: failures in these blocks:
  - `Jump host access (Phase 3)`, for example `Expected @('[parameters('availabilityZone')]')` or `$null`
  - `Entra ID sign-in egress`
  - `passes the admin group`
  - the ABAC condition test (`Expected $true, but got $false`)

  Everything else passes.

- [ ] **Step 3: Replace the jump host module**

  Replace `modules/virtualMachine.bicep`:

  ```bicep
  @description('Azure region for the VM resources.')
  param location string

  @description('Virtual machine name. Use 1-15 characters because the name is also used for the computer hostname.')
  @minLength(1)
  @maxLength(15)
  param vmName string

  @description('Operating system image to deploy.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param osType string = 'Linux'

  @description('Subnet resource ID for the VM network interface.')
  param subnetId string

  @description('Local administrator username. Do not use reserved Windows administrator names.')
  @minLength(1)
  @maxLength(64)
  param adminUsername string

  @description('SSH public key for Linux deployments. Required when osType is Linux.')
  param adminSshPublicKey string = ''

  @description('Local administrator password for Windows deployments. Required when osType is Windows.')
  @secure()
  param adminPassword string = ''

  @description('VM size selected for the workload.')
  param vmSize string = 'Standard_B2s'

  @description('Log Analytics workspace resource ID for VM diagnostics.')
  param logAnalyticsWorkspaceId string

  @description('CIDR ranges allowed to reach the VM over SSH (22) and RDP (3389). Must match the management subnet NSG; an empty list denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('Availability zone the VM is pinned to. Fixed at creation.')
  @allowed([
    '1'
    '2'
    '3'
  ])
  param availabilityZone string = '1'

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('First Update Manager patch window, in UTC (yyyy-MM-dd HH:mm). The window then repeats every Sunday at the same time.')
  param patchWindowStartDateTime string = '2026-10-04 02:00'

  var linuxImagePublisher = 'Canonical'
  var linuxImageOffer = '0001-com-ubuntu-server-jammy'
  var linuxImageSku = '22_04-lts-gen2'
  var windowsImagePublisher = 'MicrosoftWindowsServer'
  var windowsImageOffer = 'WindowsServer'
  var windowsImageSku = '2022-datacenter-g2'
  var networkInterfaceName = '${vmName}-nic'
  var networkSecurityGroupName = '${vmName}-nsg'
  var managementInboundRules = empty(managementSourceCidrs) ? [] : [
    {
      name: 'allow-management-ssh-rdp'
      properties: {
        priority: 100
        access: 'Allow'
        direction: 'Inbound'
        protocol: 'Tcp'
        sourceAddressPrefixes: managementSourceCidrs
        sourcePortRange: '*'
        destinationAddressPrefix: '*'
        destinationPortRanges: [
          '22'
          '3389'
        ]
      }
    }
  ]

  var entraLoginExtensionName = osType == 'Linux' ? 'AADSSHLoginForLinux' : 'AADLoginForWindows'
  var virtualMachineAdministratorLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
  // Update Manager owns patching: platform-orchestrated installs inside the maintenance window, daily assessment.
  var patchSettings = {
    patchMode: 'AutomaticByPlatform'
    assessmentMode: 'AutomaticByPlatform'
    automaticByPlatformSettings: {
      bypassPlatformSafetyChecksOnUserSchedule: true
    }
  }
  var dataCollectionRuleName = '${vmName}-dcr'
  var azureMonitorAgentName = osType == 'Linux' ? 'AzureMonitorLinuxAgent' : 'AzureMonitorWindowsAgent'
  var performanceCounterSource = {
    performanceCounters: [
      {
        name: 'perf'
        streams: [
          'Microsoft-Perf'
        ]
        samplingFrequencyInSeconds: 60
        counterSpecifiers: osType == 'Linux' ? [
          '\\Processor(*)\\% Processor Time'
          '\\Memory(*)\\% Used Memory'
          '\\Logical Disk(*)\\% Used Space'
        ] : [
          '\\Processor Information(_Total)\\% Processor Time'
          '\\Memory\\% Committed Bytes In Use'
          '\\LogicalDisk(_Total)\\% Free Space'
        ]
      }
    ]
  }
  var osLogSource = osType == 'Linux' ? {
    syslog: [
      {
        name: 'syslog'
        streams: [
          'Microsoft-Syslog'
        ]
        facilityNames: [
          'auth'
          'authpriv'
          'daemon'
          'kern'
          'syslog'
        ]
        logLevels: [
          'Warning'
          'Error'
          'Critical'
          'Alert'
          'Emergency'
        ]
      }
    ]
  } : {
    windowsEventLogs: [
      {
        name: 'windows-events'
        streams: [
          'Microsoft-Event'
        ]
        xPathQueries: [
          'System!*[System[(Level=1 or Level=2 or Level=3)]]'
          'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
        ]
      }
    ]
  }

  // NIC-level NSG keeps the VM boundary explicit without changing shared subnet policy.
  resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: networkSecurityGroupName
    location: location
    properties: {
      securityRules: concat(managementInboundRules, [
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        {
          name: 'deny-ssh-rdp-outbound'
          properties: {
            priority: 4000
            access: 'Deny'
            direction: 'Outbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRanges: [
              '22'
              '3389'
            ]
          }
        }
      ])
    }
  }

  // Dynamic private IP NIC with a managed identity and no public IP.
  resource networkInterface 'Microsoft.Network/networkInterfaces@2024-07-01' = {
    name: networkInterfaceName
    location: location
    properties: {
      ipConfigurations: [
        {
          name: 'ipconfig'
          properties: {
            privateIPAllocationMethod: 'Dynamic'
            subnet: {
              id: subnetId
            }
          }
        }
      ]
      networkSecurityGroup: {
        id: networkSecurityGroup.id
      }
    }
  }

  // OS-specific VM with trusted launch, host encryption, and boot diagnostics.
  resource virtualMachine 'Microsoft.Compute/virtualMachines@2026-04-01' = {
    name: vmName
    location: location
    zones: [
      availabilityZone
    ]
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      storageProfile: {
        imageReference: osType == 'Linux' ? {
          publisher: linuxImagePublisher
          offer: linuxImageOffer
          sku: linuxImageSku
          version: 'latest'
        } : {
          publisher: windowsImagePublisher
          offer: windowsImageOffer
          sku: windowsImageSku
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          deleteOption: 'Delete'
        }
      }
      osProfile: osType == 'Linux' ? {
        computerName: vmName
        adminUsername: adminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: adminSshPublicKey
              }
            ]
          }
          patchSettings: patchSettings
        }
      } : {
        computerName: vmName
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          enableAutomaticUpdates: true
          provisionVMAgent: true
          patchSettings: patchSettings
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: networkInterface.id
            properties: {
              primary: true
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
        }
      }
      securityProfile: {
        securityType: 'TrustedLaunch'
        encryptionAtHost: true
        uefiSettings: {
          secureBootEnabled: true
          vTpmEnabled: true
        }
      }
    }
  }

  // Platform metrics only; Compute VMs expose no diagnostic log categories. Guest logs use the DCR below.
  resource virtualMachineDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: virtualMachine
    name: 'vm-diagnostics'
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      metrics: [
        {
          category: 'AllMetrics'
          enabled: true
        }
      ]
    }
  }

  // Azure Monitor Agent authenticates with the VM's system-assigned identity.
  resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = {
    parent: virtualMachine
    name: azureMonitorAgentName
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Monitor'
      type: azureMonitorAgentName
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
    }
  }

  // Guest OS logs and performance counters routed to the central workspace.
  resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
    name: dataCollectionRuleName
    location: location
    kind: osType
    properties: {
      dataSources: union(performanceCounterSource, osLogSource)
      destinations: {
        logAnalytics: [
          {
            name: 'workspace'
            workspaceResourceId: logAnalyticsWorkspaceId
          }
        ]
      }
      dataFlows: [
        {
          streams: osType == 'Linux' ? [
            'Microsoft-Syslog'
            'Microsoft-Perf'
          ] : [
            'Microsoft-Event'
            'Microsoft-Perf'
          ]
          destinations: [
            'workspace'
          ]
        }
      ]
    }
  }

  resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
    name: '${vmName}-dcra'
    scope: virtualMachine
    properties: {
      dataCollectionRuleId: dataCollectionRule.id
    }
  }

  // Entra ID sign-in (az ssh vm / Bastion native client with --auth-type AAD); local admin stays for break-glass.
  resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = {
    parent: virtualMachine
    name: entraLoginExtensionName
    location: location
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: entraLoginExtensionName
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
    }
    // One extension operation at a time per VM.
    dependsOn: [
      azureMonitorAgent
    ]
  }

  // The admin group signs in as administrator; PIM makes the membership just-in-time (runbook 03).
  resource administratorLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminGroupObjectId)) {
    name: guid(virtualMachine.id, adminGroupObjectId, virtualMachineAdministratorLoginRoleId)
    scope: virtualMachine
    properties: {
      principalId: adminGroupObjectId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineAdministratorLoginRoleId)
    }
  }

  // Weekly Update Manager window for critical and security updates.
  resource patchSchedule 'Microsoft.Maintenance/maintenanceConfigurations@2023-04-01' = {
    name: '${vmName}-patch'
    location: location
    properties: {
      maintenanceScope: 'InGuestPatch'
      extensionProperties: {
        InGuestPatchMode: 'User'
      }
      maintenanceWindow: {
        startDateTime: patchWindowStartDateTime
        duration: '03:00'
        timeZone: 'UTC'
        recurEvery: 'Week Sunday'
      }
      installPatches: {
        rebootSetting: 'IfRequired'
        linuxParameters: {
          classificationsToInclude: [
            'Critical'
            'Security'
          ]
        }
        windowsParameters: {
          classificationsToInclude: [
            'Critical'
            'Security'
          ]
        }
      }
    }
  }

  resource patchScheduleAssignment 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = {
    name: '${vmName}-patch'
    scope: virtualMachine
    location: location
    properties: {
      maintenanceConfigurationId: patchSchedule.id
      resourceId: virtualMachine.id
    }
  }

  output id string = virtualMachine.id
  output name string = virtualMachine.name
  output networkInterfaceId string = networkInterface.id
  output dataCollectionRuleId string = dataCollectionRule.id
  ```

- [ ] **Step 4: Add the Entra sign-in egress and the admin group wiring**

  Replace `modules/firewallPolicyRules.bicep`:

  ```bicep
  // Baseline rule collection groups shared by every regional firewall policy (ADR-010).
  // Rule collection groups on one policy must not update concurrently, so each group depends on the previous one.

  @description('Existing firewall policy name in this resource group.')
  param firewallPolicyName string

  @description('Spoke CIDR ranges permitted to use the firewall DNS proxy, Azure Monitor egress, and approved application rules.')
  param spokeAddressPrefixes array

  @description('Management subnet CIDR ranges permitted to reach OS update endpoints (Windows Update, Ubuntu archives).')
  param managementAddressPrefixes array

  @description('Point-to-site VPN client pools permitted to open SSH/RDP sessions to the management subnet.')
  param vpnClientAddressPrefixes array

  @description('Approved outbound FQDNs for application traffic. An empty list deploys no application allowlist.')
  param allowedOutboundFqdns array = []

  // Entra ID sign-in host for this cloud, for example login.microsoftonline.com.
  var entraLoginHost = split(environment().authentication.loginEndpoint, '/')[2]

  resource firewallPolicy 'Microsoft.Network/firewallPolicies@2025-01-01' existing = {
    name: firewallPolicyName
  }

  // Platform egress for the spoke VNet: DNS proxy and Azure Monitor Agent ingestion.
  resource dnsEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
    parent: firewallPolicy
    name: 'dns-egress'
    properties: {
      priority: 100
      ruleCollections: [
        {
          name: 'dns'
          priority: 100
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              // With the firewall's DNS proxy on (dnsSettings.enableProxy in
              // azureFirewall.bicep), spoke clients query the firewall's own
              // private IP for DNS, which the firewall's DNS proxy itself
              // resolves and never appears as network traffic evaluated by this
              // rule collection group. This rule instead covers a spoke client
              // that bypasses the proxy and queries 168.63.129.16 (Azure's
              // recursive resolver) directly — a supported but non-default
              // configuration. Under the normal, proxied path this rule is
              // inert (nothing matches it); it exists as a fallback, not the
              // primary DNS path.
              ruleType: 'NetworkRule'
              name: 'azure-dns'
              ipProtocols: [
                'UDP'
                'TCP'
              ]
              sourceAddresses: spokeAddressPrefixes
              destinationAddresses: [
                '168.63.129.16'
              ]
              destinationPorts: [
                '53'
              ]
            }
          ]
        }
        {
          name: 'azure-monitor'
          priority: 110
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'azure-monitor-agent'
              ipProtocols: [
                'TCP'
              ]
              sourceAddresses: spokeAddressPrefixes
              destinationAddresses: [
                'AzureMonitor'
                'AzureResourceManager'
              ]
              destinationPorts: [
                '443'
              ]
            }
          ]
        }
      ]
    }
  }

  // Admin sessions from VPN clients to the management subnet. GatewaySubnet routes spoke traffic here, so
  // the firewall logs every SSH/RDP session. Private endpoint traffic is direct and NSG-enforced (ADR-013).
  resource adminAccess 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
    parent: firewallPolicy
    name: 'admin-access'
    properties: {
      priority: 120
      ruleCollections: [
        {
          name: 'vpn-to-management'
          priority: 120
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'NetworkRule'
              name: 'vpn-ssh-rdp'
              ipProtocols: [
                'TCP'
              ]
              sourceAddresses: vpnClientAddressPrefixes
              destinationAddresses: managementAddressPrefixes
              destinationPorts: [
                '22'
                '3389'
              ]
            }
          ]
        }
      ]
    }
    dependsOn: [
      dnsEgress
    ]
  }

  // OS update endpoints for management VMs only; the App Service subnet never gets these.
  resource platformEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = {
    parent: firewallPolicy
    name: 'platform-egress'
    properties: {
      priority: 150
      ruleCollections: [
        {
          name: 'os-updates'
          priority: 150
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'windows-update'
              sourceAddresses: managementAddressPrefixes
              protocols: [
                {
                  protocolType: 'Http'
                  port: 80
                }
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              fqdnTags: [
                'WindowsUpdate'
              ]
            }
            {
              ruleType: 'ApplicationRule'
              name: 'ubuntu-archives'
              sourceAddresses: managementAddressPrefixes
              protocols: [
                {
                  protocolType: 'Http'
                  port: 80
                }
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              targetFqdns: [
                'archive.ubuntu.com'
                'security.ubuntu.com'
                'azure.archive.ubuntu.com'
                '*.azure.archive.ubuntu.com'
              ]
            }
          ]
        }
        {
          // Endpoints the AADSSHLoginForLinux / AADLoginForWindows extensions call to sign admins in with Entra ID.
          name: 'entra-login'
          priority: 160
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'entra-sign-in'
              sourceAddresses: managementAddressPrefixes
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              targetFqdns: [
                entraLoginHost
                'device.${entraLoginHost}'
                'enterpriseregistration.windows.net'
                'pas.windows.net'
                'packages.microsoft.com'
              ]
            }
          ]
        }
      ]
    }
    dependsOn: [
      adminAccess
    ]
  }

  // Optional application allowlist; no group is deployed when the allowlist is empty.
  resource approvedHttpsEgress 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = if (!empty(allowedOutboundFqdns)) {
    parent: firewallPolicy
    name: 'approved-https-egress'
    properties: {
      priority: 200
      ruleCollections: [
        {
          name: 'approved-https'
          priority: 200
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'approved-fqdns'
              sourceAddresses: spokeAddressPrefixes
              protocols: [
                {
                  protocolType: 'Https'
                  port: 443
                }
              ]
              targetFqdns: allowedOutboundFqdns
            }
          ]
        }
      ]
    }
    dependsOn: [
      platformEgress
    ]
  }
  ```

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet } from 'types.bicep'

  @description('Deployment environment.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Role of this region in the active/passive design. Only the primary gets zone-redundant App Service capacity and the optional management VM.')
  @allowed([
    'primary'
    'secondary'
  ])
  param regionRole string

  @description('Azure region for this stamp.')
  param location string

  @description('Short lowercase region code used in resource names, for example wus3 or eus.')
  @minLength(2)
  @maxLength(4)
  param regionCode string

  @description('Hub and spoke address plan for this region.')
  param addressPlan regionAddressPlan

  @description('Central Log Analytics workspace resource ID from the global layer.')
  param logAnalyticsWorkspaceId string

  @description('Shared private DNS zone resource IDs from the global layer.')
  param privateDnsZoneIds privateDnsZoneSet

  @description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('Relative path probed by App Service health check.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM (primary region only).')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in this region. The warm standby leaves it off until failover.')
  param deployAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  var isProd = environmentName == 'prod'
  var isPrimary = regionRole == 'primary'
  var nameSuffix = uniqueString(subscription().id, environmentName, location)
  var availabilityZones = [
    '1'
    '2'
    '3'
  ]
  var names = {
    hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
    spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
    firewall: 'afw-defenstack-${environmentName}-${regionCode}'
    firewallPolicy: 'afwp-defenstack-${environmentName}-${regionCode}'
    firewallPublicIp: 'pip-afw-defenstack-${environmentName}-${regionCode}'
    storageAccount: 'st${regionCode}${nameSuffix}'
    keyVault: 'kv-${regionCode}-${nameSuffix}'
    appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
    appService: 'app-defenstack-${environmentName}-${regionCode}-${take(nameSuffix, 6)}'
    virtualMachine: 'vm${regionCode}${take(nameSuffix, 7)}'
    bastion: 'bas-defenstack-${environmentName}-${regionCode}'
    bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
    vpnGateway: 'vpng-defenstack-${environmentName}-${regionCode}'
    vpnGatewayPublicIp: 'pip-vpng-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      storageAccountSkuName: isProd ? 'Standard_GRS' : 'Standard_LRS'
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module keyVault 'keyVault.bicep' = {
    name: 'key-vault'
    params: {
      location: location
      keyVaultName: names.keyVault
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      enablePurgeProtection: true
      enabledForTemplateDeployment: true
      enableDeleteLock: isProd
    }
  }

  module hubNetwork 'hubNetwork.bicep' = {
    name: 'hub-network'
    params: {
      location: location
      vnetName: names.hubVnet
      addressSpace: addressPlan.hubAddressSpace
      firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
      bastionSubnetAddressPrefix: addressPlan.bastionSubnetPrefix
      gatewaySubnetAddressPrefix: addressPlan.gatewaySubnetPrefix
      firewallPrivateIp: firewallPrivateIp
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      bastionTargetAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      enableDeleteLock: isProd
    }
  }

  module azureFirewall 'azureFirewall.bicep' = {
    name: 'azure-firewall'
    params: {
      location: location
      firewallName: names.firewall
      firewallPolicyName: names.firewallPolicy
      publicIpName: names.firewallPublicIp
      firewallSubnetId: hubNetwork.outputs.firewallSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      managementAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      vpnClientAddressPrefixes: [
        addressPlan.vpnClientAddressPool
      ]
      allowedOutboundFqdns: allowedOutboundFqdns
      threatIntelMode: isProd ? 'Deny' : 'Alert'
      availabilityZones: availabilityZones
      firewallTier: 'Premium'
      idpsMode: isProd ? 'Deny' : 'Alert'
      enableDeleteLock: isProd
    }
  }

  module spokeNetwork 'spokeNetwork.bicep' = {
    name: 'spoke-network'
    params: {
      location: location
      vnetName: names.spokeVnet
      firewallPrivateIp: azureFirewall.outputs.privateIp
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      vnetAddressSpace: addressPlan.spokeAddressSpace
      privateEndpointSubnetAddressPrefix: addressPlan.privateEndpointSubnetPrefix
      appServiceIntegrationSubnetAddressPrefix: addressPlan.appServiceIntegrationSubnetPrefix
      virtualMachineSubnetAddressPrefix: addressPlan.managementSubnetPrefix
      approvedPrivateEndpointSourceCidrs: concat([
        addressPlan.appServiceIntegrationSubnetPrefix
        addressPlan.managementSubnetPrefix
        addressPlan.vpnClientAddressPool
      ], additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  module appService 'appService.bicep' = {
    name: 'app-service'
    params: {
      location: location
      appServiceAppName: names.appService
      appServicePlanName: names.appServicePlan
      environmentType: environmentName
      vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      healthCheckPath: healthCheckPath
      zoneRedundant: isProd && isPrimary
      instanceCount: isProd && isPrimary ? 3 : 1
    }
  }

  module virtualMachine 'virtualMachine.bicep' = if (enableVirtualMachine && isPrimary) {
    name: 'virtual-machine'
    params: {
      location: location
      vmName: names.virtualMachine
      osType: virtualMachineOsType
      subnetId: spokeNetwork.outputs.virtualMachineSubnetId
      adminUsername: virtualMachineAdminUsername
      adminSshPublicKey: virtualMachineAdminSshPublicKey
      adminPassword: virtualMachineAdminPassword
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      managementSourceCidrs: adminSourceCidrs
      adminGroupObjectId: adminGroupObjectId
    }
  }

  module bastion 'bastion.bicep' = if (deployAdminAccess) {
    name: 'bastion'
    params: {
      location: location
      bastionName: names.bastion
      publicIpName: names.bastionPublicIp
      subnetId: hubNetwork.outputs.bastionSubnetId
      availabilityZones: availabilityZones
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    // The hub resolves DNS through the firewall, so admin access waits for it.
    dependsOn: [
      azureFirewall
    ]
  }

  module vpnGateway 'vpnGateway.bicep' = if (deployAdminAccess) {
    name: 'vpn-gateway'
    params: {
      location: location
      gatewayName: names.vpnGateway
      publicIpNamePrefix: names.vpnGatewayPublicIp
      gatewaySubnetId: hubNetwork.outputs.gatewaySubnetId
      skuName: isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'
      availabilityZones: availabilityZones
      vpnClientAddressPool: addressPlan.vpnClientAddressPool
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    dependsOn: [
      azureFirewall
    ]
  }

  module networkIntegration 'networkIntegration.bicep' = {
    name: 'network-integration'
    params: {
      hubVnetName: names.hubVnet
      hubVnetId: hubNetwork.outputs.id
      spokeVnetName: names.spokeVnet
      spokeVnetId: spokeNetwork.outputs.id
      storageAccountName: names.storageAccount
      storageAccountId: storage.outputs.id
      storageContainerName: storage.outputs.blobContainerName
      appServicePrincipalId: appService.outputs.appServicePrincipalId
      appServiceName: names.appService
      useHubGateway: deployAdminAccess
    }
    // Gateway transit on the peering needs a provisioned gateway.
    dependsOn: [
      vpnGateway
    ]
  }

  module privateConnectivity 'privateConnectivity.bicep' = {
    name: 'private-connectivity'
    params: {
      location: location
      storageAccountId: storage.outputs.id
      storageAccountName: names.storageAccount
      appServiceId: appService.outputs.appServiceAppId
      appServiceName: names.appService
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      keyVaultId: keyVault.outputs.id
      keyVaultName: names.keyVault
      privateDnsZoneIds: privateDnsZoneIds
    }
  }

  output hubVnetName string = names.hubVnet
  output hubVnetId string = hubNetwork.outputs.id
  output spokeVnetName string = names.spokeVnet
  output spokeVnetId string = spokeNetwork.outputs.id
  output firewallPrivateIp string = azureFirewall.outputs.privateIp
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  ```

  Replace `main.bicep`:

  ```bicep
  targetScope = 'subscription'

  import { regionAddressPlan, privateDnsZoneSet } from 'modules/types.bicep'

  @description('Deployment environment. Selects resource group names, redundancy, and deletion protection.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Primary (active) Azure region. Each allowed region has a short code in regionCodes.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param primaryLocation string = 'westus3'

  @description('Secondary (warm standby) Azure region, the platform pair of the primary.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param secondaryLocation string = 'eastus'

  @description('Deploy the secondary region stamp. Prod enables it; dev runs primary-only to halve cost.')
  param deploySecondaryRegion bool = false

  @description('Address plan for the primary region.')
  param primaryAddressPlan regionAddressPlan

  @description('Address plan for the secondary region. Required when deploySecondaryRegion is true.')
  param secondaryAddressPlan regionAddressPlan?

  @description('Approved outbound HTTPS destinations for both regions. Empty keeps application traffic denied.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges allowed to reach private endpoints over HTTPS in every region.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('Extra CIDR ranges allowed to administer management VMs over SSH/RDP, beyond the AzureBastionSubnet and VPN client pool of each region.')
  param managementSourceCidrs array = []

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the primary region.')
  param deployPrimaryAdminAccess bool = true

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the secondary region. Off in steady state; turned on during failover.')
  param deploySecondaryAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Relative path probed by App Service health check in every region.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM in the primary region.')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  var isProd = environmentName == 'prod'
  var regionCodes = {
    westus3: 'wus3'
    eastus: 'eus'
  }
  var primaryRegionCode = regionCodes[toLower(primaryLocation)]
  var secondaryRegionCode = regionCodes[toLower(secondaryLocation)]
  var globalResourceGroupName = 'rg-defenstack-${environmentName}-global'
  var primaryResourceGroupName = 'rg-defenstack-${environmentName}-${primaryRegionCode}'
  var secondaryResourceGroupName = 'rg-defenstack-${environmentName}-${secondaryRegionCode}'
  var privateDnsZoneNames privateDnsZoneSet = {
    blob: 'privatelink.blob.${environment().suffixes.storage}'
    sites: 'privatelink.azurewebsites.net'
    vault: 'privatelink.vaultcore.azure.net'
  }

  // Shared layer: Log Analytics and private DNS zones. Resource groups are pre-created (runbook 01).
  module global 'modules/global.bicep' = {
    name: 'global-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      location: primaryLocation
      workspaceName: 'log-defenstack-${environmentName}'
      privateDnsZoneNames: privateDnsZoneNames
      workspaceReplicationLocation: isProd && deploySecondaryRegion ? secondaryLocation : ''
      enableDeleteLock: isProd
    }
  }

  module primaryStamp 'modules/regionStamp.bicep' = {
    name: 'region-${primaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'primary'
      location: primaryLocation
      regionCode: primaryRegionCode
      addressPlan: primaryAddressPlan
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      enableVirtualMachine: enableVirtualMachine
      virtualMachineOsType: virtualMachineOsType
      virtualMachineAdminUsername: virtualMachineAdminUsername
      virtualMachineAdminSshPublicKey: virtualMachineAdminSshPublicKey
      virtualMachineAdminPassword: virtualMachineAdminPassword
      deployAdminAccess: deployPrimaryAdminAccess
      adminGroupObjectId: adminGroupObjectId
    }
  }

  module secondaryStamp 'modules/regionStamp.bicep' = if (deploySecondaryRegion) {
    name: 'region-${secondaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'secondary'
      location: secondaryLocation
      regionCode: secondaryRegionCode
      addressPlan: secondaryAddressPlan!
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      deployAdminAccess: deploySecondaryAdminAccess
    }
  }

  var primaryVirtualNetworks = [
    {
      name: primaryStamp.outputs.hubVnetName
      id: primaryStamp.outputs.hubVnetId
    }
    {
      name: primaryStamp.outputs.spokeVnetName
      id: primaryStamp.outputs.spokeVnetId
    }
  ]
  var secondaryVirtualNetworks = deploySecondaryRegion
    ? [
        {
          name: secondaryStamp!.outputs.hubVnetName
          id: secondaryStamp!.outputs.hubVnetId
        }
        {
          name: secondaryStamp!.outputs.spokeVnetName
          id: secondaryStamp!.outputs.spokeVnetId
        }
      ]
    : []

  // Link every region's hub (firewall DNS proxy) and spoke to each shared zone.
  module privateDnsLinks 'modules/privateDnsZoneLinks.bicep' = [for zone in items(privateDnsZoneNames): {
    name: 'dns-links-${zone.key}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      zoneName: zone.value
      virtualNetworks: concat(primaryVirtualNetworks, secondaryVirtualNetworks)
    }
  }]

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  ```

- [ ] **Step 5: Let the pipeline identity delegate the new role**

  In `scripts/New-GitHubDeploymentIdentity.ps1`, replace line 37:

  ```powershell
      [string[]]$DelegatableRoleDefinitionIds = @('ba92f5b4-2d11-453d-a403-e96b0029c9fe'),
  ```

  with:

  ```powershell
      [string[]]$DelegatableRoleDefinitionIds = @(
          'ba92f5b4-2d11-453d-a403-e96b0029c9fe', # Storage Blob Data Contributor (app identity, container scope)
          '1c0163c0-47e6-4577-8991-ea5c82e286e4'  # Virtual Machine Administrator Login (admin group, jump host; Phase 3)
      ),
  ```

  The script already joins the list with `, ` into `GuidEquals {...}`, so the condition needs no other change.

- [ ] **Step 6: Build, lint, test**

  ```bash
  bicep build main.bicep
  for f in main.bicep modules/*.bicep; do bicep lint "$f" || echo "LINT FAIL $f"; done
  ```

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: no `LINT FAIL`, and `Tests Passed: 257, Failed: 0`.

  PSRule is unchanged from Task 1: 0 failures. It does not evaluate the VM (Review Focus).

- [ ] **Step 7: Commit**

  ```bash
  git add modules/virtualMachine.bicep modules/firewallPolicyRules.bicep modules/regionStamp.bicep main.bicep main.json scripts/New-GitHubDeploymentIdentity.ps1 tests/VirtualMachine.Tests.ps1 tests/FirewallPolicyRules.Tests.ps1 tests/RegionStamp.Tests.ps1 tests/Main.Tests.ps1 tests/Scripts.Tests.ps1
  git commit -m "feat: jump host Entra login, VM Administrator Login for the admin group, Update Manager patching" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 3: Runbook 03, ADR-013/014/015, and Phase 3 documentation updates

**Files:**
- Create: `docs/runbooks/03-admin-access.md`, `docs/decisions/ADR-013-admin-access-network-paths.md`, `docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md`, `docs/decisions/ADR-015-vpn-gateway-sku-and-active-active.md`
- Replace: `tests/Docs.Tests.ps1`
- Modify: `docs/architecture/overview.md`, `docs/cost.md`, `docs/decisions/ADR-005-single-firewall-dns-proxy.md`, `docs/runbooks/00-pipeline-and-identity.md`, `docs/runbooks/00b-configure-pipeline-credentials.md`, `docs/runbooks/01-deploy-stack.md`, `README.md`

**Interfaces:**
- **Consumes:** the resource names, parameters, outputs and rule names from Tasks 1–2 (`bas-`/`vpng-`/`pip-vpng-...-1|2`, `admin-access`, `vpn-ssh-rdp`, `entra-login`, `<vm>-patch`, `vpng-...-maintenance`, `primaryBastionName`, and so on). The runbook quotes them verbatim.
- **Produces:** the documents that the spec §6 definition of done requires a human to execute in dev.

- [ ] **Step 1: Write the failing docs tests**

  Replace `tests/Docs.Tests.ps1`:

  ````powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
  }

  Describe 'Phase 1 documentation' {
      It '<_> exists' -ForEach 'docs/architecture/overview.md', 'docs/runbooks/01-deploy-stack.md', 'docs/runbooks/01a-migrate-from-defenstack.md', 'docs/decisions/ADR-008-warm-standby-and-dev-single-region.md', 'docs/decisions/ADR-009-subscription-scope-pipeline-identity.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It '<_> follows the 9-section runbook template' -ForEach 'docs/runbooks/01-deploy-stack.md', 'docs/runbooks/01a-migrate-from-defenstack.md' {
          $text = Get-Content (Get-RepoPath $_) -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the architecture overview contains mermaid diagrams' {
          Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw | Should -Match '```mermaid'
      }
  }

  Describe 'README reflects the subscription-scope layout' {
      BeforeAll {
          $script:readmeText = Get-Content (Get-RepoPath 'README.md') -Raw
          $script:teardownHeading = '### Safe teardown'
          $script:beforeTeardown = $script:readmeText.Substring(0, $script:readmeText.IndexOf($script:teardownHeading))
      }

      It 'does not contain a param environmentType assignment before the legacy Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'param environmentType'
      }

      It 'does not contain an environmentType= CLI argument before the legacy Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'environmentType='
      }

      It 'does not mention spokeVnetAddressSpace' {
          $script:readmeText | Should -Not -Match 'spokeVnetAddressSpace'
      }

      It 'does not mention a virtual-machines subnet' {
          $script:readmeText | Should -Not -Match 'virtual-machines'
      }

      It 'only uses az deployment group inside or after the Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'az deployment group'
      }
  }

  Describe 'Phase 2 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/02-firewall.md', 'docs/decisions/ADR-010-shared-firewall-rules-module.md', 'docs/decisions/ADR-011-tls-inspection-deferred.md', 'docs/decisions/ADR-012-prod-two-approval-deploys.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the firewall runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/02-firewall.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the firewall runbook documents the rule change and allowlist request procedures' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/02-firewall.md') -Raw
          $text | Should -Match 'Rule change procedure'
          $text | Should -Match 'Allowlist request'
      }

      It 'runbook 00b documents the dev-plan environment and the prod two-approval design' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
          $text | Should -Match 'dev-plan'
          $text | Should -Match 'two approvals'
          $text | Should -Match 'no `?prod-plan`? environment'
      }
  }

  Describe 'Phase 3 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/03-admin-access.md', 'docs/decisions/ADR-013-admin-access-network-paths.md', 'docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md', 'docs/decisions/ADR-015-vpn-gateway-sku-and-active-active.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the admin access runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the admin access runbook covers VPN client setup per OS, Bastion connect, and break-glass (spec §5 Phase 3)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
          foreach ($topic in 'Windows 10/11', 'macOS', 'Linux (Ubuntu', 'Connect through Bastion', 'Break-glass') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the admin access runbook restricts the VPN app to the admin group' {
          Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw | Should -Match 'appRoleAssignmentRequired=true'
      }

      It 'the architecture overview draws the admin flow and lists the Phase 3 ADRs' {
          $text = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          $text | Should -Match 'VPN gateway \(GatewaySubnet'
          foreach ($adr in 'ADR-013', 'ADR-014', 'ADR-015') { $text | Should -Match $adr }
      }

      It 'the cost document has a Phase 3 delta' {
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 3 delta'
      }
  }
  ````

- [ ] **Step 2: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: the six `Phase 3 documentation` tests fail (files missing); everything else passes.

- [ ] **Step 3: Create runbook 03**

  Create `docs/runbooks/03-admin-access.md`:

  ````markdown
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
  - **Microsoft Entra roles (tenant, one-time):**
    - `Groups Administrator` (or group owner) to create the admin group.
    - `Cloud Application Administrator` to require assignment on the Azure VPN Client enterprise application and assign the group.
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

  1. Set `param deployPrimaryAdminAccess = false` (or `deploySecondaryAdminAccess = false`) in the environment's param file, and redeploy (§4 steps 5–6). This switches the peerings back to `useRemoteGateways: false`. **Do this first:** Azure refuses to delete a gateway that a peering still uses.
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
  ````

- [ ] **Step 4: Create the ADRs**

  Create `docs/decisions/ADR-013-admin-access-network-paths.md`:

  ```markdown
  # ADR-013: Admin access network paths: SSH/RDP through the firewall, private endpoints direct

  ## Context
  Phase 3 adds two admin entry points per region: Azure Bastion in `AzureBastionSubnet`, and a point-to-site VPN gateway in `GatewaySubnet`. Admins need to reach two kinds of targets in the spoke: the jump host in `management` (SSH 22 / RDP 3389), and the private endpoints in `private-endpoints` (HTTPS 443 to Key Vault, Storage and App Service). F2 already disabled BGP route propagation on the spoke route tables. The spec (§2 F2) adds a `GatewaySubnet` route table that sends spoke prefixes to the firewall.

  Three platform behaviours shape what is possible:

  1. **Private endpoint /32 routes.** Every private endpoint injects a /32 system route into its VNet and every peered VNet, including `GatewaySubnet`. A /32 is more specific than the `GatewaySubnet` UDR for the whole spoke prefix, so VPN traffic to a private endpoint skips the firewall. The /32 can be overridden only by enabling route-table network policies on `private-endpoints`. That would also override it for App Service integration and the jump host, whose `0.0.0.0/0 → firewall` routes would then pull all their private endpoint traffic through the firewall. The firewall has no rules for that traffic, and Microsoft recommends SNAT (application rules) for it to keep flows symmetric. That is a redesign of the Phase 0–2 data path, not an admin-access change.
  2. **Bastion must open SSH/RDP.** Its NSG needs outbound 22/3389. PSRule `Azure.NSG.LateralTraversal` flags any NSG that allows this.
  3. **The firewall IP is needed before the firewall exists.** The hub VNet (and so `GatewaySubnet` and its route table) is created before the firewall, which is attached to `AzureFirewallSubnet`. Reading the firewall's IP from its output would create a dependency cycle.

  ## Decision
  - **VPN → jump host (22/3389) goes through the firewall.** The `GatewaySubnet` route table sends each spoke prefix to the firewall. The `management` route table (`0.0.0.0/0 → firewall`, BGP propagation off) sends the replies back through it, so the flow is symmetric. The shared rule group `admin-access` (priority 120) allows only the region VPN client pool to the `management` subnet on TCP 22/3389, and the firewall logs every session.
  - **VPN → private endpoints (443) goes direct**, over the /32 routes. The `private-endpoints` NSG admits the VPN client pool on 443 only. Every service behind a private endpoint still requires Entra ID authentication and RBAC, since Storage shared keys are disabled and Key Vault uses RBAC. No firewall rule is added for this path; it would never match.
  - **Bastion → jump host goes direct** over the hub↔spoke peering. `AzureBastionSubnet` does not support UDRs. The replies follow the more specific hub peering route, so the flow is symmetric without the firewall. The Bastion NSG allows SSH/RDP egress **only to the `management` subnet**, and denies all other SSH/RDP egress. `Azure.NSG.LateralTraversal` is suppressed for the Bastion NSGs by name (`.ps-rule/Suppression.Rule.yaml`, `DefenStack.BastionSessionEgress`). Every other NSG now carries `deny-ssh-rdp-outbound`, and the global `ps-rule.yaml` exclusion is removed.
  - **The firewall IP is computed as `cidrHost(firewallSubnetPrefix, 3)`**, the `.4` address, which Azure Firewall always takes in an empty `AzureFirewallSubnet`. The hub uses it for the `GatewaySubnet` route and the hub DNS server (`ADR-005`). Runbook 03 §4 step 7 and §6 check it against the deployed firewall.
  - **Admin sources are derived, not configured.** The `management` NSG and the jump host NIC NSG allow `AzureBastionSubnet` and the region VPN client pool; `managementSourceCidrs` only adds extra sources.
  - **The Bastion and gateway subnets always exist**, even with `deployAdminAccess = false`, so that turning admin access on or off never adds or removes hub subnets. The spec (§4) describes them as conditional; they cost nothing, and a conditional subnet would fail to delete while in use.

  ## Consequences
  - Admin SSH/RDP from the VPN is visible in `AZFWNetworkRule`, and subject to IDPS and threat intelligence. Admin HTTPS to private endpoints is visible only in each service's own logs (Key Vault `AuditEvent`, Storage `StorageRead`/`StorageWrite`, App Service HTTP logs), not in the firewall logs.
  - A compromised admin workstation on the VPN can reach private endpoints on 443 without passing the firewall. It still needs a valid Entra token with data-plane RBAC on each service.
  - Bastion sessions to the jump host are audited in `MicrosoftAzureBastionAuditLogs`, not in the firewall.
  - If a firewall is ever created at a different address (for example in a non-empty subnet), VPN-to-spoke traffic and VPN DNS break until the computed IP is corrected (runbook 03 §9).

  ## Revisit when
  - A phase moves private endpoint traffic through the firewall for every source (route-table network policies plus SNAT application rules). VPN traffic to private endpoints would then join it.
  - Azure Firewall exposes its private IP in a way that can be referenced before the firewall is created, or supports a static private IP.
  ```

  Create `docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md`:

  ```markdown
  # ADR-014: Defender just-in-time VM access deferred to Phase 7

  ## Context
  The spec (§3, "Management jump host") lists Defender for Cloud just-in-time (JIT) VM access for the jump host, in Phase 3. JIT needs **Microsoft Defender for Servers Plan 2** enabled on the subscription. The spec schedules the Defender plans for Phase 7. JIT also works by adding and removing rules on the VM's NSGs at request time, while this project manages every NSG rule in Bicep. Every redeploy replaces the rule list, so it would remove any active JIT allow rules and could fight JIT's own deny rules.

  Phase 3 already gives the jump host a least-privilege, time-bound access model without JIT:
  - Only Bastion and the VPN client pool can reach 22/3389.
  - Both paths authenticate with Microsoft Entra ID.
  - The `Virtual Machine Administrator Login` role is held by a group whose membership is PIM-eligible, activated for at most 4 hours with MFA and a justification (runbook 03 §5.5).

  ## Decision
  Do not deploy a JIT policy in Phase 3. Phase 7, which enables Defender for Servers Plan 2, adds the `Microsoft.Security/locations/jitNetworkAccessPolicies` resource for the jump host. It also decides how JIT coexists with Bicep-managed NSGs, for example by keeping the JIT-managed rules on a NIC NSG that Bicep creates without inline rules.

  ## Consequences
  - Until Phase 7, network reachability to the jump host is standing (from Bastion and VPN clients only). The time-bound control is PIM on the admin group, not JIT on the port.
  - There is no Defender for Servers cost in Phase 3.
  - Phase 7's plan must add JIT and resolve the NSG ownership question above. It is recorded in the "Revisit when" below.

  ## Revisit when
  Phase 7 enables Defender for Servers Plan 2.
  ```

  Create `docs/decisions/ADR-015-vpn-gateway-sku-and-active-active.md`:

  ```markdown
  # ADR-015: VPN gateway: VpnGw1AZ in dev, VpnGw2AZ in prod, always active-active

  ## Context
  The spec (§3) selects `VpnGw2AZ` for point-to-site access. The spec's definition of done (§6) requires every runbook to be executed end-to-end in dev, so dev needs a working VPN gateway too, not only Bastion. Dev carries a handful of admin sessions. The spec sizes `VpnGw2AZ` for prod, and in dev it would add cost without adding anything the runbook tests.

  PSRule for Azure flags a non-active-active gateway (`Azure.VNG.VPNActiveActive`), and a gateway without a customer-controlled maintenance window (`Azure.VNG.MaintenanceConfig`). Point-to-site works on active-active gateways. The only extra resource is a second Standard public IP, since the gateway's hourly rate does not change.

  ## Decision
  - The stamp uses `VpnGw2AZ` in prod and `VpnGw1AZ` in dev (`isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'` in `modules/regionStamp.bicep`). `modules/vpnGateway.bicep` accepts only the zone-redundant `VpnGw1AZ`–`VpnGw3AZ` SKUs.
  - Every gateway is **active-active**, with one zonal Standard public IP per instance (zones 1/2/3).
  - Every gateway has a customer-controlled maintenance window: Sundays 06:00 UTC, 5 hours (the minimum Azure accepts). The jump host's Update Manager window (Sundays 02:00 UTC, 3 hours) ends before it starts.
  - The user chose this option when Phase 3 was planned (dev: Bastion plus a smaller VPN gateway).

  ## Consequences
  - Dev tests the same gateway type, generation, authentication and topology as prod. Only the throughput and connection limits differ.
  - Planned maintenance or an instance failure drops only the sessions on one instance, and the clients reconnect.
  - Each region with admin access has three Standard public IPs: Bastion, plus two for the gateway (`docs/cost.md` "Phase 3 delta").
  - Resizing within the AZ family (runbook 03 §8) happens in place, so dev can be raised to `VpnGw2AZ` without redeploying the gateway.

  ## Revisit when
  Dev needs to load-test VPN throughput, or prod session counts approach the `VpnGw2AZ` point-to-site connection limit (review the monthly P2S connection counts in runbook 03 §8).
  ```

  Append to `docs/decisions/ADR-005-single-firewall-dns-proxy.md`, after its last line, with one blank line between:

  ```markdown
  ## Amendment (Phase 3): the hub VNet uses the firewall DNS proxy too
  Phase 3 sets the **hub** VNet's DNS server to the same single firewall IP (`modules/hubNetwork.bicep`, `dhcpOptions.dnsServers`). Point-to-site VPN clients receive the hub's DNS servers, and this is how they resolve `privatelink.*` names to private endpoint IPs (spec §3: "The VPN client profile uses the firewall private IP as its DNS server"). The hub is created before the firewall, so the stamp computes the address as `cidrHost(firewallSubnetPrefix, 3)`, the firewall's `.4` address (`ADR-013`). Bastion and the VPN gateway deploy only after the firewall exists. The same single-server trade-off applies: while the firewall is unavailable, VPN clients cannot resolve private names, which matches their SSH/RDP path through the firewall. The `Azure.VNET.SingleDNS` exclusion covers the hub as well.
  ```

- [ ] **Step 5: Update the existing documents**

  Each edit below is an exact find/replace. The find text occurs once in the file. If a find text is not found, stop and report it; do not paraphrase.

  **`docs/architecture/overview.md`, edit 1 of 16.** Find:

  ```markdown
  # Architecture overview: Phase 1-2 (subscription-scope, multi-region, Premium firewall)
  ```

  Replace with:

  ```markdown
  # Architecture overview: Phase 1-3 (subscription-scope, multi-region, Premium firewall, admin access)
  ```

  **`docs/architecture/overview.md`, edit 2 of 16.** Find:

  ```markdown
  `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`. Spec:
  ```

  Replace with:

  ```markdown
  `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`, `modules/hubNetwork.bicep`, `modules/bastion.bicep`, `modules/vpnGateway.bicep`. Spec:
  ```

  **`docs/architecture/overview.md`, edit 3 of 16.** Find:

  ```markdown
  What later phases add (not present after Phase 2):

  | Phase | Adds |
  |---|---|
  | 3 | Azure Bastion, Point-to-Site VPN, and the `deployAdminAccess` flag; a `GatewaySubnet` route table |
  | 4 |
  ```

  Replace with:

  ```markdown
  **Phase 3** added the admin path: Azure Bastion Standard and an active-active,
  Entra ID-authenticated point-to-site VPN gateway per region, behind the
  `deployPrimaryAdminAccess` / `deploySecondaryAdminAccess` flags (on in the
  primary region, off in the East US warm standby). It also added a
  `GatewaySubnet` route table that sends VPN traffic for the spoke through the
  firewall, gateway transit on the hub-spoke peering, and hub DNS pointing at the
  firewall DNS proxy. The jump host signs admins in with Entra ID and is patched
  by Update Manager. Every spoke NSG now denies outbound SSH/RDP. See §3
  "Admin access" and [runbook 03](../runbooks/03-admin-access.md).

  What later phases add (not present after Phase 3):

  | Phase | Adds |
  |---|---|
  | 4 |
  ```

  **`docs/architecture/overview.md`, edit 4 of 16.** Find:

  ```markdown
              subgraph HUB1["Hub VNet"]
                  AFS1["AzureFirewallSubnet"]
              end
              FW1["Firewall afw-defenstack-env-wus3"]
  ```

  Replace with:

  ```markdown
              subgraph HUB1["Hub VNet"]
                  AFS1["AzureFirewallSubnet"]
                  ABS1["AzureBastionSubnet"]
                  GWS1["GatewaySubnet"]
              end
              FW1["Firewall afw-defenstack-env-wus3"]
              BAS1["Bastion bas-defenstack-env-wus3"]
              VPNG1["VPN gateway vpng-defenstack-env-wus3"]
  ```

  **`docs/architecture/overview.md`, edit 5 of 16.** Find:

  ```markdown
              subgraph HUB2["Hub VNet"]
                  AFS2["AzureFirewallSubnet"]
              end
  ```

  Replace with:

  ```markdown
              subgraph HUB2["Hub VNet"]
                  AFS2["AzureFirewallSubnet"]
                  ABS2["AzureBastionSubnet (empty until failover)"]
                  GWS2["GatewaySubnet (empty until failover)"]
              end
  ```

  **`docs/architecture/overview.md`, edit 6 of 16.** Find:

  ```markdown
      FW1 --- AFS1
      FW2 --- AFS2
  ```

  Replace with:

  ```markdown
      FW1 --- AFS1
      FW2 --- AFS2
      BAS1 --- ABS1
      VPNG1 --- GWS1
  ```

  **`docs/architecture/overview.md`, edit 7 of 16.** Find:

  ```markdown
  - The East US subgraph (`EUS`) and its links exist only when `deploySecondaryRegion = true` (prod).
  ```

  Replace with:

  ```markdown
  - The East US subgraph (`EUS`) and its links exist only when `deploySecondaryRegion = true` (prod).
  - Bastion and the VPN gateway exist only where `deployAdminAccess` is true for that stamp: dev and prod primary by default. The East US hub has its Bastion and gateway subnets, but no Bastion or gateway until failover (`deploySecondaryAdminAccess`).
  ```

  **`docs/architecture/overview.md`, edit 8 of 16.** Find:

  ```markdown
  ### Admin access

  None yet (Phase 3 adds Azure Bastion and Point-to-Site VPN). `managementSourceCidrs` defaults to empty, so the management subnet accepts no administrative inbound traffic today.
  ```

  Replace with:

  ````markdown
  ### Admin access

  Two private, Entra ID-authenticated entry points per region (`ADR-013`); full procedures are in [runbook 03](../runbooks/03-admin-access.md).

  ```mermaid
  flowchart LR
      ADMIN["Admin workstation"]
      subgraph HUB["Hub VNet"]
          BAS["Bastion (AzureBastionSubnet)"]
          GW["VPN gateway (GatewaySubnet, route table: spoke -> firewall)"]
          FW["Azure Firewall (admin-access: VPN pool -> management, 22/3389)"]
      end
      subgraph SPOKE["Spoke VNet"]
          VM["Jump host (management subnet)"]
          PE["Private endpoints (Key Vault, Storage, App Service)"]
      end
      ADMIN -->|"HTTPS 443 + Entra ID (portal or az network bastion)"| BAS
      ADMIN -->|"OpenVPN + Entra ID (Azure VPN Client)"| GW
      BAS -->|"SSH/RDP over peering (Bastion NSG allows only the management subnet)"| VM
      GW -->|"SSH/RDP (UDR)"| FW
      FW --> VM
      GW -->|"HTTPS 443 direct (/32 private endpoint routes; NSG allows the VPN pool)"| PE
      VM -.->|"Entra sign-in, OS updates via firewall"| FW
  ```

  - The `management` NSG and the jump host NIC NSG allow SSH/RDP only from `AzureBastionSubnet` and the region's VPN client pool (plus any `managementSourceCidrs`).
  - The `management` route table sends replies back through the firewall (`0.0.0.0/0`, BGP propagation off), so the VPN-to-jump-host flow is symmetric.
  - VPN clients use the hub DNS server, the firewall DNS proxy, so `privatelink.*` names resolve to private endpoint IPs.
  - Admin rights on the jump host come from the `Virtual Machine Administrator Login` role held by a PIM-eligible Entra group (`adminGroupObjectId`). Defender JIT is deferred to Phase 7 (`ADR-014`).
  ````

  **`docs/architecture/overview.md`, edit 9 of 16.** Find:

  ```markdown
  | Env | Region | Hub address space | Firewall subnet | Spoke address space | `private-endpoints` | `appservice-integration` | `management` | Reserved (not yet allocated) |
  |---|---|---|---|---|---|---|---|---|
  | dev | westus3 (primary only) | `10.21.0.0/16` | `10.21.0.0/26` | `10.20.0.0/16` | `10.20.1.0/24` | `10.20.2.0/24` | `10.20.3.0/24` | `AzureBastionSubnet` /26, `GatewaySubnet` /27 (Phase 3; dev has no admin-access path) |
  | prod | westus3 (primary) | `10.1.0.0/16` | `10.1.0.0/26` | `10.0.0.0/16` | `10.0.1.0/24` | `10.0.2.0/24` | `10.0.3.0/24` | `AzureBastionSubnet` /26, `GatewaySubnet` /27 in the hub; P2S VPN client pool `172.16.200.0/24` (outside the VNet) |
  | prod | eastus (secondary, warm standby) | `10.11.0.0/16` | `10.11.0.0/26` | `10.10.0.0/16` | `10.10.1.0/24` | `10.10.2.0/24` | `10.10.3.0/24` | `AzureBastionSubnet` /26, `GatewaySubnet` /27 (deployed only during failover, per ADR-008) |

  Every stamp's three spoke subnet prefixes come from `regionAddressPlan` (`modules/types.bicep`) and are supplied per region by `primaryAddressPlan` / `secondaryAddressPlan` in `main.bicep`; nothing is hard-coded in a module.
  ```

  Replace with:

  ```markdown
  | Env | Region | Hub address space | `AzureFirewallSubnet` (firewall IP) | `AzureBastionSubnet` | `GatewaySubnet` | P2S VPN client pool | Spoke address space | `private-endpoints` | `appservice-integration` | `management` |
  |---|---|---|---|---|---|---|---|---|---|---|
  | dev | westus3 (primary only) | `10.21.0.0/16` | `10.21.0.0/26` (`10.21.0.4`) | `10.21.0.64/26` | `10.21.0.128/27` | `172.16.210.0/24` | `10.20.0.0/16` | `10.20.1.0/24` | `10.20.2.0/24` | `10.20.3.0/24` |
  | prod | westus3 (primary) | `10.1.0.0/16` | `10.1.0.0/26` (`10.1.0.4`) | `10.1.0.64/26` | `10.1.0.128/27` | `172.16.200.0/24` | `10.0.0.0/16` | `10.0.1.0/24` | `10.0.2.0/24` | `10.0.3.0/24` |
  | prod | eastus (secondary, warm standby) | `10.11.0.0/16` | `10.11.0.0/26` (`10.11.0.4`) | `10.11.0.64/26` | `10.11.0.128/27` | `172.16.201.0/24` (used only during failover) | `10.10.0.0/16` | `10.10.1.0/24` | `10.10.2.0/24` | `10.10.3.0/24` |

  Every stamp's subnet prefixes and its VPN client pool come from `regionAddressPlan` (`modules/types.bicep`), and are supplied per region by `primaryAddressPlan` / `secondaryAddressPlan` in `main.bicep`; nothing is hard-coded in a module. VPN client pools sit outside every VNet and are unique per region and environment, so an admin connected to dev and prod at once never sees overlapping routes (`tests/Params.Tests.ps1`). The firewall IP is always the `.4` address of `AzureFirewallSubnet` (`ADR-013`).
  ```

  **`docs/architecture/overview.md`, edit 10 of 16.** Find:

  ```markdown
  | `names.virtualMachine` | `vm<regionCode><hash, first 7>` | `vmwus3<hash7>` |
  ```

  Replace with:

  ```markdown
  | `names.virtualMachine` | `vm<regionCode><hash, first 7>` | `vmwus3<hash7>` |
  | `names.bastion` | `bas-defenstack-<env>-<regionCode>` | `bas-defenstack-dev-wus3` |
  | `names.bastionPublicIp` | `pip-bas-defenstack-<env>-<regionCode>` | `pip-bas-defenstack-dev-wus3` |
  | `names.vpnGateway` | `vpng-defenstack-<env>-<regionCode>` | `vpng-defenstack-dev-wus3` |
  | `names.vpnGatewayPublicIp` | `pip-vpng-defenstack-<env>-<regionCode>-<1\|2>` (one per active-active instance) | `pip-vpng-defenstack-dev-wus3-1` |
  ```

  **`docs/architecture/overview.md`, edit 11 of 16.** Find:

  ```markdown
  | `rg-defenstack-dev-wus3` | Hub VNet with `AzureFirewallSubnet`; Firewall
  ```

  Replace with:

  ```markdown
  | `rg-defenstack-dev-wus3` | Hub VNet with `AzureFirewallSubnet`, `AzureBastionSubnet` (Bastion NSG) and `GatewaySubnet` (route table spoke → firewall), DNS server = firewall IP; Bastion Standard `bas-defenstack-dev-wus3` and active-active VPN gateway `vpng-defenstack-dev-wus3` (`VpnGw1AZ`, `ADR-015`) with three public IPs and a gateway maintenance configuration; Firewall
  ```

  **`docs/architecture/overview.md`, edit 12 of 16.** Find:

  ```markdown
  firewall policy with three rule collection groups — `dns-egress`, `platform-egress`, and `approved-https-egress` when `allowedOutboundFqdns` is non-empty (`ADR-010`) — and public IP;
  ```

  Replace with:

  ```markdown
  firewall policy with four rule collection groups — `dns-egress`, `admin-access`, `platform-egress`, and `approved-https-egress` when `allowedOutboundFqdns` is non-empty (`ADR-010`) — and public IP;
  ```

  **`docs/architecture/overview.md`, edit 13 of 16.** Find:

  ```markdown
  hub↔spoke peering |
  ```

  Replace with:

  ```markdown
  hub↔spoke peering with gateway transit; when `enableVirtualMachine = true`, the jump host (zone 1, Entra login extension, Update Manager schedule `<vm>-patch`) |
  ```

  **`docs/architecture/overview.md`, edit 14 of 16.** Find:

  ```markdown
  | `rg-defenstack-prod-wus3` (primary) | Same shape as dev's region resource group, but: Firewall Premium with IDPS `Deny`, `threatIntelMode: Deny`;
  ```

  Replace with:

  ```markdown
  | `rg-defenstack-prod-wus3` (primary) | Same shape as dev's region resource group, but: VPN gateway `VpnGw2AZ`; Firewall Premium with IDPS `Deny`, `threatIntelMode: Deny`;
  ```

  **`docs/architecture/overview.md`, edit 15 of 16.** Find:

  ```markdown
  | `rg-defenstack-prod-eus` (secondary, warm standby) | Same resource types as `rg-defenstack-prod-wus3`, deployed only when `deploySecondaryRegion = true`:
  ```

  Replace with:

  ```markdown
  | `rg-defenstack-prod-eus` (secondary, warm standby) | Same resource types as `rg-defenstack-prod-wus3`, deployed only when `deploySecondaryRegion = true`, except Bastion and the VPN gateway (their subnets exist; the resources arrive with `deploySecondaryAdminAccess = true` during failover):
  ```

  **`docs/architecture/overview.md`, edit 16 of 16.** Find:

  ```markdown
  - [ADR-012: Prod plan and apply both run in the gated `prod` environment](../decisions/ADR-012-prod-two-approval-deploys.md)
  ```

  Replace with:

  ```markdown
  - [ADR-012: Prod plan and apply both run in the gated `prod` environment](../decisions/ADR-012-prod-two-approval-deploys.md)
  - [ADR-013: Admin access network paths: SSH/RDP through the firewall, private endpoints direct](../decisions/ADR-013-admin-access-network-paths.md)
  - [ADR-014: Defender just-in-time VM access deferred to Phase 7](../decisions/ADR-014-jit-access-deferred-to-phase-7.md)
  - [ADR-015: VPN gateway: VpnGw1AZ in dev, VpnGw2AZ in prod, always active-active](../decisions/ADR-015-vpn-gateway-sku-and-active-active.md)
  ```

  **`docs/cost.md`, edit 1 of 1.** Find:

  ```markdown
  ## Dominant future cost drivers
  From `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §6, the
  resources expected to dominate spend in later phases (not present in Phase 0):
  - VPN gateway
  - Azure Bastion
  - Azure Front Door Premium
  ```

  Replace with:

  ```markdown
  ## Phase 3 delta
  Phase 3 adds admin access to every stamp with `deployAdminAccess = true`: dev
  and the prod primary region. The East US warm standby gets it only during
  failover. As with every phase, **fill in the actual dollar estimate from the
  Pricing Calculator; do not invent prices.**

  | Environment | Cost driver | What changed / why it costs more |
  |---|---|---|
  | Dev | VPN gateway `VpnGw1AZ` ×1 (active-active) | Billed hourly per gateway, whether or not a client is connected (`ADR-015`); active-active does not change the hourly rate |
  | Dev | Azure Bastion Standard ×1, 2 scale units | Billed hourly per Bastion plus per scale unit above the base 2 |
  | Dev | Standard public IPs ×3 (Bastion, two for the gateway) | Billed hourly per static IP |
  | Prod | VPN gateway `VpnGw2AZ` ×1, Bastion Standard ×1, public IPs ×3 | West US 3 only; the same drivers as dev at the `VpnGw2AZ` rate |
  | Prod (failover only) | The same set in East US | Billed only from the moment `deploySecondaryAdminAccess = true` is deployed |
  | Both | Outbound data for admin sessions; Bastion and P2S diagnostic log ingestion | Small; measured with the `Usage` KQL pattern (tables `MicrosoftAzureBastionAuditLogs`, `AzureDiagnostics` for `P2SDiagnosticLog`/`GatewayDiagnosticLog`) |
  | Both | Jump host: no new resource cost | Update Manager for Azure VMs is free; the Entra login extension and maintenance configuration have no charge |

  **Estimate:** fill in from the Pricing Calculator (VPN Gateway: SKU `VpnGw1AZ`
  or `VpnGw2AZ`, 730 hours; Azure Bastion: Standard, 2 scale units, 730 hours;
  Public IP: 3 × Standard static). In dev, turning admin access off between test
  windows (runbook 03 §7) removes the gateway and Bastion charges, which are the
  two largest items.

  ## Dominant future cost drivers
  From `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §6, the
  resources expected to dominate spend in later phases (not present in Phase 0).
  The VPN gateway and Azure Bastion arrived in Phase 3 (see "Phase 3 delta"):
  - Azure Front Door Premium
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 1 of 2.** Find:

  ```markdown
  | Delegatable role | `Storage Blob Data Contributor` (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`) | RBAC Administrator condition | No |
  ```

  Replace with:

  ```markdown
  | Delegatable roles | `Storage Blob Data Contributor` (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`); `Virtual Machine Administrator Login` (`1c0163c0-47e6-4577-8991-ea5c82e286e4`, Phase 3: admin group on the jump host) | RBAC Administrator condition | No |
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 2 of 2.** Find:

  ```markdown
  - **Assigning an extra role from Bicep** (for example Key Vault Secrets User in a later phase):
  ```

  Replace with:

  ```markdown
  - **Assigning an extra role from Bicep** (for example Key Vault Secrets User in a later phase). Phase 3 did this for `Virtual Machine Administrator Login`, which is now in the script's default list, so an identity created before Phase 3 needs only steps 2–3 (runbook 03 §4 step 3):
  ```

  **`docs/runbooks/00-pipeline-and-identity.md`, edit 1 of 1.** Find:

  ```markdown
  | `-DelegatableRoleDefinitionIds` | Storage Blob Data Contributor | extended per phase |
  ```

  Replace with:

  ```markdown
  | `-DelegatableRoleDefinitionIds` | Storage Blob Data Contributor, Virtual Machine Administrator Login (Phase 3) | extended per phase |
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 1 of 3.** Find:

  ```markdown
  | `primaryAddressPlan` | *(required)* | `10.21.0.0/16` hub / `10.20.0.0/16` spoke | `10.1.0.0/16` hub / `10.0.0.0/16` spoke | See `docs/architecture/overview.md` §4 |
  ```

  Replace with:

  ```markdown
  | `primaryAddressPlan` | *(required)* | `10.21.0.0/16` hub / `10.20.0.0/16` spoke / VPN pool `172.16.210.0/24` | `10.1.0.0/16` hub / `10.0.0.0/16` spoke / VPN pool `172.16.200.0/24` | Includes the Bastion and gateway subnets and the VPN client pool (Phase 3). See `docs/architecture/overview.md` §4 |
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 2 of 3.** Find:

  ```markdown
  | `secondaryAddressPlan` | *(none)* | not set | `10.11.0.0/16` hub / `10.10.0.0/16` spoke |
  ```

  Replace with:

  ```markdown
  | `secondaryAddressPlan` | *(none)* | not set | `10.11.0.0/16` hub / `10.10.0.0/16` spoke / VPN pool `172.16.201.0/24` |
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 3 of 3.** Find:

  ```markdown
  | `managementSourceCidrs` | `[]` | *(default)* | *(default)* | Empty denies all admin SSH/RDP inbound; populated in Phase 3 |
  ```

  Replace with:

  ```markdown
  | `managementSourceCidrs` | `[]` | *(default)* | *(default)* | Extra admin sources only. The Bastion subnet and VPN client pool are always allowed (Phase 3, `ADR-013`) |
  | `deployPrimaryAdminAccess` | `true` | *(default)* | *(default)* | Bastion and the VPN gateway in the primary region ([runbook 03](03-admin-access.md)) |
  | `deploySecondaryAdminAccess` | `false` | *(default)* | *(default)* | Turned on only during failover |
  | `adminGroupObjectId` | `''` | dev admin group | prod admin group | Entra group granted `Virtual Machine Administrator Login` on the jump host (runbook 03 §4) |
  ```

  **`README.md`, edit 1 of 2.** Find:

  ```markdown
  and `02-firewall.md` (Premium firewall rule changes and allowlist requests)
  ```

  Replace with:

  ```markdown
  `02-firewall.md` (Premium firewall rule changes and allowlist requests), and `03-admin-access.md` (Bastion, point-to-site VPN client setup, jump host sign-in, break-glass)
  ```

  **`README.md`, edit 2 of 2.** Find:

  ```markdown
  This design intentionally avoids global peering, NAT gateways, VPN/ExpressRoute gateways, extra public IPs, and Azure Firewall Manager unless separately approved.
  ```

  Replace with:

  ```markdown
  Phase 3 adds a point-to-site VPN gateway, Azure Bastion and their three public IPs in each region with admin access (`docs/cost.md` "Phase 3 delta"). This design intentionally avoids global peering, NAT gateways, site-to-site VPN or ExpressRoute, other public IPs, and Azure Firewall Manager unless separately approved.
  ```

- [ ] **Step 6: Run the full suite**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: `Tests Passed: 266, Failed: 0`.

  Confirm the encoding survived: `grep -c "↔\|→" docs/architecture/overview.md` prints a non-zero count, and `grep -n "�" docs README.md -r` prints nothing.

- [ ] **Step 7: Commit**

  ```bash
  git add docs/runbooks/03-admin-access.md docs/decisions/ADR-013-admin-access-network-paths.md docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md docs/decisions/ADR-015-vpn-gateway-sku-and-active-active.md docs/decisions/ADR-005-single-firewall-dns-proxy.md docs/architecture/overview.md docs/cost.md docs/runbooks/00-pipeline-and-identity.md docs/runbooks/00b-configure-pipeline-credentials.md docs/runbooks/01-deploy-stack.md README.md tests/Docs.Tests.ps1
  git commit -m "docs: runbook 03 admin access, ADR-013/014/015, and Phase 3 documentation updates" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

## After the last task (human, not the implementer)

Run by a person following only runbook 03, in dev (spec §6 definition of done):

1. Runbook 03 §4 steps 1–7: admin group, VPN app assignment, pipeline identity re-run, parameters, validate/what-if, deploy, outputs.
2. §5.1 VPN client on at least one OS; §5.2 Bastion connect; §5.3 VPN connect.
3. Every §6 validation row, with the outputs pasted into the Phase 3 PR.
4. Confirm the deployed firewall IP is `.4` (Review Focus 1).

