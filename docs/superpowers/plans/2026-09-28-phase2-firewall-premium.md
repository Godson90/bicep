# Phase 2: Firewall Premium, Shared Rules, Deletion Protection, and Gated Deploys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade every region stamp's Azure Firewall to Premium with IDPS (Deny in prod, Alert in dev). Move the rule collection groups into one shared, dependency-chained rules module that adds OS-update egress for the management subnet only. Lock prod network and secret resources against deletion. Split the deploy workflow so prod reviewers approve after seeing the what-if.

**Architecture:**
- `modules/azureFirewall.bicep` keeps the policy, firewall, public IP, diagnostics and new prod locks. Its rule collection groups move into `modules/firewallPolicyRules.bicep`, which every regional policy uses. This replaces the spec's cross-region parent policy, because Azure requires a parent and its child policies to be in the same region (ADR-010).
- `deploy.yml` becomes a `plan` job (validate + what-if, environment `<env>-plan`, no approval) followed by an `apply` job (create, environment `<env>`, reviewer-gated in prod).
- The identity script creates a federated credential for both environments.

**Tech Stack:** Bicep CLI 0.47.16, Azure CLI 2.90+, Windows PowerShell 5.1 / pwsh 7, Pester 5.x, PSRule.Rules.Azure 1.47.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` — §3 (Azure Firewall Premium, resource locks), §5 Phase 2, §6 documentation standard. Builds on Phase 1 (`docs/superpowers/plans/2026-09-28-phase1-multi-region.md`); branch `phase2-firewall-premium` stacked on `phase1-multi-region`.

**Verification status of this plan:** every Bicep module, test, workflow and script below was prototyped and run before the plan was written:
- `bicep lint` / `bicep build` are clean.
- The full Pester suite passes: 178/178.
- `Invoke-PSRule` evaluates 628 results with 0 failures (Premium resources included), with no change to `ps-rule.yaml` or the suppressions.
- Both workflows parse as YAML.

The embedded content is that verified content. Transcribe it exactly.

## Global Constraints

- **User decisions (binding):**
  - Premium in **every** environment.
  - IDPS **Alert in dev, Deny in prod**.
  - **TLS inspection deferred** (ADR-011).
  - Shared **rules module instead of parent/child inheritance** (ADR-010).
  - **Split the deploy workflow** into plan and apply.
- **Greenfield:** no Phase 1 stack is deployed yet, so the Standard → Premium change is not an in-place migration. Do not write an upgrade procedure.
- **Unchanged from Phase 1:** the regions, resource-group names and address plan; firewall zones `1,2,3`; threat intelligence `Deny` in prod and `Alert` in dev (ADR-003); the identity's least-privilege roles (9-action subscription role; `Contributor` and ABAC-constrained RBAC Administrator per resource group).
- **Deletion protection:** `CanNotDelete` locks in prod only. They cover the hub VNet, Key Vault, firewall, firewall policy and firewall public IP (Phase 2 adds these), in addition to the Phase 1 locks on the spoke VNet, DNS zones and workspace.
- **Firewall rules:** rule collection groups on one policy must never update concurrently, so each group `dependsOn` the previous one and the firewall `dependsOn` the rules module. OS-update egress (Windows Update FQDN tag, Ubuntu archives) is allowed from the **management subnet only**.
- **API versions:** reuse the existing ones (`Microsoft.Network/firewallPolicies@2025-01-01`, `.../ruleCollectionGroups@2025-01-01`, `Microsoft.Authorization/locks@2020-05-01`).
- **main.json is generated:** after any `.bicep` change run `bicep build main.bicep` and commit `main.json`.
- **Docs are mandatory:** runbooks use the 9-section template.
- **Tests must run on both shells:** Windows PowerShell 5.1 and pwsh 7.
- **No live Azure/Entra/GitHub commands; no push.**
- **Commit trailers:** `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
- **Build output:** never commit `modules/*.json`, which is git-ignored.
- **Compiled-expression gotcha:** a ternary module parameter compiles to `[if(cond, createObject('value', a), createObject('value', b))]` with no `.value`. The tests already account for this.

## File Map

| File | Responsibility | Task |
|---|---|---|
| `modules/firewallPolicyRules.bicep` (new) | Baseline rule collection groups (`dns-egress` 100, `platform-egress` 150, `approved-https-egress` 200), dependency-chained | 1 |
| `modules/azureFirewall.bicep` (replace) | Premium tier parameter, IDPS, rules module, firewall after rules, prod locks | 1 |
| `modules/hubNetwork.bicep`, `modules/keyVault.bicep` (replace) | + `enableDeleteLock` | 1 |
| `modules/regionStamp.bicep` (replace) | Premium, IDPS mode, management prefixes, locks wiring | 1 |
| `tests/FirewallPolicyRules.Tests.ps1`, `tests/HubNetwork.Tests.ps1` (new); `tests/AzureFirewall.Tests.ps1`, `tests/KeyVault.Tests.ps1`, `tests/RegionStamp.Tests.ps1` (replace) | Tests | 1 |
| `.github/workflows/deploy.yml`, `.github/workflows/bicep-ci.yml` (replace) | Plan/apply split; PR what-if in `dev-plan` | 2 |
| `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Scripts.Tests.ps1`, `tests/Workflows.Tests.ps1` (replace) | Credentials for `<env>` and `<env>-plan`; case-sensitive subject check | 2 |
| `docs/runbooks/02-firewall.md`, `docs/decisions/ADR-010-*.md`, `docs/decisions/ADR-011-*.md` (new); `tests/Docs.Tests.ps1`; ADR-003, runbooks 00, 00b, 01, overview, `docs/cost.md`, `README.md` | Phase 2 docs | 3 |

---

### Task 1: Firewall Premium, shared rules module, IDPS, and prod deletion locks

**Files:**
- Create: `modules/firewallPolicyRules.bicep`, `tests/FirewallPolicyRules.Tests.ps1`, `tests/HubNetwork.Tests.ps1`
- Replace: `modules/azureFirewall.bicep`, `modules/hubNetwork.bicep`, `modules/keyVault.bicep`, `modules/regionStamp.bicep`, `tests/AzureFirewall.Tests.ps1`, `tests/KeyVault.Tests.ps1`, `tests/RegionStamp.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **`firewallPolicyRules.bicep` params:** `firewallPolicyName`, `spokeAddressPrefixes`, `managementAddressPrefixes`, `allowedOutboundFqdns = []`.
- **`azureFirewall.bicep` new params:** `managementAddressPrefixes` (required), `firewallTier = 'Premium'` (`Standard`|`Premium`), `idpsMode = 'Deny'` (`Alert`|`Deny`|`Off`), `enableDeleteLock = false`. The rules module deployment is named `firewall-policy-rules`, and its outputs are unchanged.
- **`hubNetwork.bicep` / `keyVault.bicep`:** new param `enableDeleteLock = false`.
- **Stamp passes:** `firewallTier: 'Premium'`, `idpsMode: isProd ? 'Deny' : 'Alert'`, `managementAddressPrefixes: [addressPlan.managementSubnetPrefix]`, `enableDeleteLock: isProd` to the hub, Key Vault and firewall.

- [ ] **Step 1: Create the branch**

  ```bash
  cd /c/Workspace/Bicep
  git worktree add .claude/worktrees/phase2-firewall-premium -b phase2-firewall-premium phase1-multi-region
  ```

  Work in that worktree. The controller may already have created it.

- [ ] **Step 2: Write the failing tests**

  Create `tests/FirewallPolicyRules.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/firewallPolicyRules.bicep'
      $groups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
      function Get-Group([string]$Name) {
          $groups | Where-Object { $_.name -like "*'$Name')]" }
      }
      $dns = Get-Group 'dns-egress'
      $platform = Get-Group 'platform-egress'
      $approved = Get-Group 'approved-https-egress'
  }

  Describe 'Baseline firewall rules (ADR-010)' {
      It 'defines the dns-egress, platform-egress and approved-https-egress groups at priorities 100, 150, 200' {
          $groups.Count | Should -Be 3
          $dns.properties.priority | Should -Be 100
          $platform.properties.priority | Should -Be 150
          $approved.properties.priority | Should -Be 200
      }

      It 'updates the groups one at a time (a policy rejects concurrent rule collection group updates)' {
          @($dns.PSObject.Properties.Name) | Should -Not -Contain 'dependsOn'
          @($platform.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'dns-egress')]"
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

  Create `tests/HubNetwork.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/hubNetwork.bicep'
      $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
  }

  Describe 'Hub network deletion protection (Phase 2)' {
      It 'locks the hub VNet only when requested' {
          $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
          $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
          $lock.properties.level | Should -Be 'CanNotDelete'
          $lock.scope | Should -Be "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetName'))]"
      }
  }
  ```

  Replace `tests/AzureFirewall.Tests.ps1`. The Azure Monitor egress assertions move to `FirewallPolicyRules.Tests.ps1`.

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/azureFirewall.bicep'
      $firewall = Get-TemplateResource -Template $template -Type 'Microsoft.Network/azureFirewalls' | Select-Object -First 1
      $publicIp = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
      $policy = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies' | Select-Object -First 1
      $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
      $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks'
      $rules = Get-ModuleDeployment -Template $template -Name 'firewall-policy-rules'
  }

  Describe 'Azure Firewall availability (F9)' {
      It 'accepts availability zones for the firewall and public IP, defaulting to none for in-place safety' {
          @($template.parameters.availabilityZones.defaultValue).Count | Should -Be 0
          $firewall.zones | Should -Match 'availabilityZones'
          $publicIp.zones | Should -Match 'availabilityZones'
      }

      It 'declares the firewall SKU explicitly' {
          $firewall.properties.sku.name | Should -Be 'AZFW_VNet'
      }
  }

  Describe 'Azure Firewall Premium (Phase 2)' {
      It 'defaults the firewall and its policy to the Premium tier, from one parameter' {
          $template.parameters.firewallTier.defaultValue | Should -Be 'Premium'
          $firewall.properties.sku.tier | Should -Be "[parameters('firewallTier')]"
          $policy.properties.sku.tier | Should -Be "[parameters('firewallTier')]"
      }

      It 'enables IDPS on Premium policies only, defaulting to Deny' {
          $template.parameters.idpsMode.defaultValue | Should -Be 'Deny'
          $policy.properties.intrusionDetection | Should -Be "[if(variables('isPremium'), createObject('mode', parameters('idpsMode')), null())]"
      }
  }

  Describe 'Azure Firewall threat protection (F9)' {
      It 'defaults threat intelligence to Deny' {
          $template.parameters.threatIntelMode.defaultValue | Should -Be 'Deny'
          $policy.properties.threatIntelMode | Should -Be "[parameters('threatIntelMode')]"
      }
  }

  Describe 'Azure Firewall rules wiring (ADR-010)' {
      It 'takes its rule collection groups from the shared rules module' {
          $rules.properties.parameters.firewallPolicyName.value | Should -Be "[parameters('firewallPolicyName')]"
          $rules.properties.parameters.managementAddressPrefixes.value | Should -Be "[parameters('managementAddressPrefixes')]"
          @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups').Count | Should -Be 0
      }

      It 'attaches the firewall only after every rule collection group exists' {
          @($firewall.dependsOn) | Should -Contain "[resourceId('Microsoft.Resources/deployments', 'firewall-policy-rules')]"
      }
  }

  Describe 'Azure Firewall logging (F9)' {
      It 'writes to resource-specific (dedicated) Log Analytics tables' {
          $diagnostics.properties.logAnalyticsDestinationType | Should -Be 'Dedicated'
      }
  }

  Describe 'Azure Firewall deletion protection (Phase 2)' {
      It 'locks the firewall, its policy and its public IP only when requested' {
          $locks.Count | Should -Be 3
          foreach ($lock in $locks) {
              $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
              $lock.properties.level | Should -Be 'CanNotDelete'
          }
          $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
      }
  }
  ```

  Replace `tests/KeyVault.Tests.ps1`. This adds the `Key Vault deletion protection (Phase 2)` block.

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/keyVault.bicep'
      $vault = Get-TemplateResource -Template $template -Type 'Microsoft.KeyVault/vaults' | Select-Object -First 1
      $privateConnectivity = Get-BicepTemplate -RelativePath 'modules/privateConnectivity.bicep'
  }

  Describe 'Key Vault template deployment access (F4)' {
      It 'is off by default for standalone reuse' {
          $template.parameters.enabledForTemplateDeployment.defaultValue | Should -BeExactly $false
          $vault.properties.enabledForTemplateDeployment | Should -Be "[parameters('enabledForTemplateDeployment')]"
      }

      It 'keeps public network access disabled' {
          $vault.properties.publicNetworkAccess | Should -Be 'Disabled'
      }

      It 'bypasses the firewall for trusted Azure services only when template deployment is enabled, otherwise denies by default' {
          $vault.properties.networkAcls.bypass | Should -Match 'enabledForTemplateDeployment'
          $vault.properties.networkAcls.bypass | Should -Match 'AzureServices'
          $vault.properties.networkAcls.defaultAction | Should -Be 'Deny'
      }
  }

  Describe 'Private connectivity outputs (F12)' {
      It 'outputs the Key Vault private endpoint ID' {
          $privateConnectivity.outputs.PSObject.Properties.Name | Should -Contain 'keyVaultPrivateEndpointId'
      }
  }

  Describe 'Key Vault deletion protection (Phase 2)' {
      It 'locks the vault only when requested' {
          $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
          $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
          $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
          $lock.properties.level | Should -Be 'CanNotDelete'
      }
  }
  ```

  Replace `tests/RegionStamp.Tests.ps1`. This adds the `Region stamp firewall security (Phase 2)` block.

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
      It 'passes managementSourceCidrs to <_> (F1)' -ForEach 'spoke-network', 'virtual-machine' {
          (Get-StampModuleParameters $_).managementSourceCidrs.value | Should -Be "[parameters('managementSourceCidrs')]"
      }

      It 'uses the address plan spoke range for both the spoke VNet and firewall sources (F5)' {
          (Get-StampModuleParameters 'azure-firewall').spokeAddressPrefixes.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
          (Get-StampModuleParameters 'spoke-network').vnetAddressSpace.value | Should -Be "[parameters('addressPlan').spokeAddressSpace]"
      }

      It 'derives private endpoint sources from the App Service and management subnet prefixes (F5)' {
          $value = (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value
          $value | Should -Match "addressPlan'\)\.appServiceIntegrationSubnetPrefix"
          $value | Should -Match "addressPlan'\)\.managementSubnetPrefix"
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
  ```

- [ ] **Step 3: Run them to confirm they fail**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/FirewallPolicyRules.Tests.ps1, tests/HubNetwork.Tests.ps1, tests/AzureFirewall.Tests.ps1, tests/KeyVault.Tests.ps1, tests/RegionStamp.Tests.ps1"`

  Expected: FAIL.
  - `firewallPolicyRules.bicep` is missing.
  - `firewallTier`, `idpsMode` and `enableDeleteLock` are missing.
  - The rule groups are still in `azureFirewall.bicep`.
  - The stamp passes no Premium, IDPS or lock values.

- [ ] **Step 4: Create `modules/firewallPolicyRules.bicep`**

  ```bicep
  // Baseline rule collection groups shared by every regional firewall policy (ADR-010).
  // Rule collection groups on one policy must not update concurrently, so each group depends on the previous one.

  @description('Existing firewall policy name in this resource group.')
  param firewallPolicyName string

  @description('Spoke CIDR ranges permitted to use the firewall DNS proxy, Azure Monitor egress, and approved application rules.')
  param spokeAddressPrefixes array

  @description('Management subnet CIDR ranges permitted to reach OS update endpoints (Windows Update, Ubuntu archives).')
  param managementAddressPrefixes array

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
      dnsEgress
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

- [ ] **Step 5: Replace `modules/azureFirewall.bicep`**

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

- [ ] **Step 6: Replace `modules/hubNetwork.bicep` and `modules/keyVault.bicep`**

  `modules/hubNetwork.bicep`:

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

  @description('Apply a CanNotDelete lock to the hub VNet.')
  param enableDeleteLock bool = false

  var firewallSubnetName = 'AzureFirewallSubnet'

  // Dedicated hub network hosting the centralized firewall.
  resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' = {
    name: vnetName
    location: location
    properties: {
      addressSpace: {
        addressPrefixes: addressSpace
      }
      subnets: [
        {
          name: firewallSubnetName
          properties: {
            addressPrefix: firewallSubnetAddressPrefix
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
  ```

  `modules/keyVault.bicep`:

  ```bicep
  @description('Azure region for the Key Vault.')
  param location string

  @description('Globally unique Key Vault name. Use only letters, numbers, and hyphens.')
  @minLength(3)
  @maxLength(24)
  param keyVaultName string

  @description('Tenant ID that owns the Key Vault.')
  param tenantId string = tenant().tenantId

  @description('Log Analytics workspace resource ID for Key Vault diagnostics.')
  param logAnalyticsWorkspaceId string

  @description('Number of days soft-deleted objects are retained.')
  @minValue(7)
  @maxValue(90)
  param softDeleteRetentionInDays int = 90

  @description('Enable purge protection. Keep enabled for production workloads.')
  param enablePurgeProtection bool = true

  @description('Allow Azure Resource Manager to retrieve secrets during deployments, required for az.getSecret() in .bicepparam files. Keep false for vaults that never back deployment parameters.')
  param enabledForTemplateDeployment bool = false

  @description('Apply a CanNotDelete lock to the vault (in addition to soft delete and purge protection).')
  param enableDeleteLock bool = false

  // RBAC-based vault with public access disabled; clients use its private endpoint.
  resource keyVault 'Microsoft.KeyVault/vaults@2025-05-01' = {
    name: keyVaultName
    location: location
    properties: {
      tenantId: tenantId
      enableRbacAuthorization: true
      enableSoftDelete: true
      softDeleteRetentionInDays: softDeleteRetentionInDays
      enablePurgeProtection: enablePurgeProtection
      enabledForTemplateDeployment: enabledForTemplateDeployment
      publicNetworkAccess: 'Disabled'
      sku: {
        family: 'A'
        name: 'standard'
      }
      networkAcls: {
        bypass: enabledForTemplateDeployment ? 'AzureServices' : 'None'
        defaultAction: 'Deny'
      }
    }
  }

  // Key Vault audit events are centralized with the other platform diagnostics.
  resource keyVaultDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: keyVault
    name: 'keyvault-diagnostics'
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

  resource keyVaultLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: keyVault
    name: '${keyVaultName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  output id string = keyVault.id
  output name string = keyVault.name
  output vaultUri string = keyVault.properties.vaultUri
  ```

- [ ] **Step 7: Replace `modules/regionStamp.bicep`**

  The only changes from Phase 1 are in the `keyVault`, `hubNetwork` and `azureFirewall` module parameters.

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
  }
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
      ], additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: managementSourceCidrs
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
      managementSourceCidrs: managementSourceCidrs
    }
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
    }
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
  output appServiceName string = names.appService
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  ```

- [ ] **Step 8: Rebuild and run the full suite**

  Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected: all pass, including lint of 17 `.bicep` files and the `main.json` drift test.

- [ ] **Step 9: Run PSRule; expect no change**

  ```powershell
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  if (-not (Get-Module -ListAvailable PSRule.Rules.Azure | Where-Object Version -eq '1.47.0')) { Install-Module PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force }
  $env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source
  Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error
  ```

  Expected: 0 failures (verified during planning). If any rule fails, report it; do not add exclusions in this task.

- [ ] **Step 10: Commit**

  ```bash
  git add modules/firewallPolicyRules.bicep modules/azureFirewall.bicep modules/hubNetwork.bicep modules/keyVault.bicep modules/regionStamp.bicep main.json tests/FirewallPolicyRules.Tests.ps1 tests/HubNetwork.Tests.ps1 tests/AzureFirewall.Tests.ps1 tests/KeyVault.Tests.ps1 tests/RegionStamp.Tests.ps1
  git commit -m "feat: Azure Firewall Premium with IDPS, shared rules module, and prod deletion locks" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 2: Plan/apply deploy workflow and plan-environment credentials

**Files:**
- Replace: `.github/workflows/deploy.yml`, `.github/workflows/bicep-ci.yml`, `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Scripts.Tests.ps1`, `tests/Workflows.Tests.ps1`

**Interfaces:**
- **`deploy.yml`:**
  - Job `plan`: `if: main`, environment `<env>-plan`. It runs validate and what-if, writes the step summary, and uploads the `whatif-<env>` artifact.
  - Job `apply`: `needs: plan`, `if: main`, environment `<env>`. It runs create.
- **`bicep-ci.yml`:** the PR `what-if` job uses environment `dev-plan`.
- **Script:**
  - Creates federated credentials `github-<env>` (subject `…:environment:<env>`) and `github-<env>-plan` (subject `…:environment:<env>-plan`) on the same app registration.
  - Existing subjects are compared **case-sensitively** (`-cne`).
  - Prints `gh variable set` commands for both environments.
  - Parameters and roles are unchanged.

- [ ] **Step 1: Write the failing tests**

  Replace `tests/Scripts.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $scriptPath = Get-RepoPath 'scripts/New-GitHubDeploymentIdentity.ps1'
      $resourceGroups = @('rg-defenstack-dev-global', 'rg-defenstack-dev-wus3')

      # Shadows the Azure CLI for one test. $Responses maps a -like pattern (matched against the joined
      # arguments, first match wins) to the value to return; every call is recorded in $global:AzCalls.
      function Set-AzShadow([System.Collections.Specialized.OrderedDictionary]$Responses) {
          $global:AzCalls = [System.Collections.Generic.List[string]]::new()
          $global:FederatedCredentialPayloads = [System.Collections.Generic.List[string]]::new()
          $global:AzResponses = $Responses
          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              $global:LASTEXITCODE = 0
              if ($joined -like 'role definition create*') {
                  $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                  $global:RoleDefinitionPayload = Get-Content $file -Raw
              }
              if ($joined -like 'ad app federated-credential create*') {
                  $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                  $global:FederatedCredentialPayloads.Add((Get-Content $file -Raw))
              }
              foreach ($pattern in $global:AzResponses.Keys) {
                  if ($joined -like $pattern) { return $global:AzResponses[$pattern] }
              }
              return ''
          }
      }

      function Remove-AzShadow {
          Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
          Remove-Variable -Name AzResponses -Scope Global -ErrorAction SilentlyContinue
      }

      function New-BaseResponses {
          $responses = [ordered]@{}
          $responses['account show*tenantId*'] = '11111111-1111-1111-1111-111111111111'
          $responses['account show*'] = '22222222-2222-2222-2222-222222222222'
          $responses
      }
  }

  Describe 'New-GitHubDeploymentIdentity.ps1' {
      It 'exists and parses without errors' {
          $scriptPath | Should -Exist
          $tokens = $null
          $errors = $null
          [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
          $errors | Should -BeNullOrEmpty
      }

      It 'supports -WhatIf' {
          (Get-Command $scriptPath).Parameters.Keys | Should -Contain 'WhatIf'
      }

      It 'makes no Azure or Entra changes under -WhatIf' {
          Set-AzShadow (New-BaseResponses)
          try {
              & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
          }
          finally {
              Remove-AzShadow
          }
          $mutations = $global:AzCalls | Where-Object { $_ -match '\b(create|delete|update|reset|add|remove)\b' }
          $mutations | Should -BeNullOrEmpty
      }

      It 'rejects delegating privileged role <_>' -ForEach @(
          '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
          '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
          'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
          'b24988ac-6180-42a0-ab88-20f7382dd24c'
      ) {
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds $_ -WhatIf } |
                  Should -Throw -ExpectedMessage '*privileged*'
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'rejects a delegatable role ID that is not a GUID' {
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -DelegatableRoleDefinitionIds 'Owner' -WhatIf } |
                  Should -Throw
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses to proceed when multiple applications share the display name' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = @('aaaaaaaa-1111-1111-1111-111111111111', 'bbbbbbbb-2222-2222-2222-222222222222')
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage '*Multiple Entra applications*'
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses an existing federated credential with a different subject' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
          $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
          $responses['*federated-credential list*'] = 'repo:someone-else/bicep:environment:dev'
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
          }
          finally {
              Remove-AzShadow
          }
      }

      It 'refuses an existing unconditioned RBAC Administrator assignment' {
          $responses = New-BaseResponses
          $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
          $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
          $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
          $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
          $responses['*role definition list*'] = 'existing-custom-role'
          $responses['*role assignment list*condition*'] = ''
          $responses['*role assignment list*'] = 'eeeeeeee-5555-5555-5555-555555555555'
          Set-AzShadow $responses
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                  Should -Throw -ExpectedMessage '*unconditioned*'
          }
          finally {
              Remove-AzShadow
          }
      }

      Context 'when creating assignments (non-WhatIf run against the shadow)' {
          BeforeAll {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
              $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $creates = @($global:AzCalls | Where-Object { $_ -like 'role assignment create*' })
          }

          It 'assigns the subscription deployment role at subscription scope only' {
              $deploymentAssignments = @($creates | Where-Object { $_ -like "*--role DefenStack Subscription Deployment Operator*" })
              $deploymentAssignments.Count | Should -Be 1
              $deploymentAssignments[0] | Should -BeLike '*--scope /subscriptions/22222222-2222-2222-2222-222222222222 *'
          }

          It 'assigns Contributor and constrained RBAC Administrator on each resource group, never at subscription scope' {
              foreach ($resourceGroup in $resourceGroups) {
                  $scope = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/$resourceGroup"
                  @($creates | Where-Object { $_ -like "*--role Contributor --scope $scope *" }).Count | Should -Be 1
                  @($creates | Where-Object { $_ -like "*--role Role Based Access Control Administrator --scope $scope *" }).Count | Should -Be 1
              }
              @($creates | Where-Object { $_ -like '*--role Contributor --scope /subscriptions/22222222-2222-2222-2222-222222222222 *' }).Count | Should -Be 0
          }

          It 'constrains RBAC Administrator with the exact ABAC condition for Storage Blob Data Contributor' {
              $expected = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe}))"
              $rbacAdmin = @($creates | Where-Object { $_ -like '*--role Role Based Access Control Administrator*' })
              $rbacAdmin.Count | Should -Be 2
              foreach ($call in $rbacAdmin) {
                  # Literal match: the condition contains [ and ], which -like would treat as wildcards.
                  $call.Contains("--condition $expected --condition-version 2.0") | Should -BeTrue -Because $call
              }
          }
      }

      Context 'when creating the subscription deployment role (role definition missing)' {
          BeforeAll {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
              $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
              $responses['*role definition list*'] = ''
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $script:roleDefinitionPayload = $global:RoleDefinitionPayload | ConvertFrom-Json
          }

          It 'grants exactly the 9 deployment-operation and read-only actions, no wildcard' {
              $expectedActions = @(
                  'Microsoft.Resources/deployments/read',
                  'Microsoft.Resources/deployments/write',
                  'Microsoft.Resources/deployments/validate/action',
                  'Microsoft.Resources/deployments/whatIf/action',
                  'Microsoft.Resources/deployments/operations/read',
                  'Microsoft.Resources/deployments/operationstatuses/read',
                  'Microsoft.Resources/subscriptions/read',
                  'Microsoft.Resources/subscriptions/resourceGroups/read',
                  'Microsoft.Resources/subscriptions/operationresults/read'
              )
              @($script:roleDefinitionPayload.Actions | Sort-Object) | Should -Be @($expectedActions | Sort-Object)
              $script:roleDefinitionPayload.Actions | Should -Not -Contain '*'
          }

          It 'is assignable only at the subscription scope' {
              @($script:roleDefinitionPayload.AssignableScopes) | Should -Be @('/subscriptions/22222222-2222-2222-2222-222222222222')
          }
      }

      Context 'federated credentials for the plan and apply environments (Phase 2)' {
          It 'creates github-<env> and github-<env>-plan with their exact environment subjects' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'prod' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 2
              ($credentials | Where-Object { $_.name -eq 'github-prod' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:prod'
              ($credentials | Where-Object { $_.name -eq 'github-prod-plan' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:prod-plan'
              foreach ($credential in $credentials) {
                  $credential.issuer | Should -BeExactly 'https://token.actions.githubusercontent.com'
                  @($credential.audiences) | Should -Be @('api://AzureADTokenExchange')
              }
          }

          It 'refuses an existing credential whose subject differs only in case' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*'] = 'repo:godson90/bicep:environment:dev'
              Set-AzShadow $responses
              try {
                  { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf } |
                      Should -Throw -ExpectedMessage "*expected 'repo:Godson90/bicep:environment:dev'*"
              }
              finally {
                  Remove-AzShadow
              }
          }
      }
  }

  AfterAll {
      Remove-Variable -Name AzCalls, FederatedCredentialPayloads, RoleDefinitionPayload -Scope Global -ErrorAction SilentlyContinue
  }
  ```

  Replace `tests/Workflows.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $ci = Get-Content (Get-RepoPath '.github/workflows/bicep-ci.yml') -Raw
      $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
  }

  Describe 'Workflows target the subscription scope' {
      It '<Name> uses az deployment sub, never az deployment group' -ForEach @(
          @{ Name = 'bicep-ci.yml'; Key = 'ci' },
          @{ Name = 'deploy.yml'; Key = 'deploy' }
      ) {
          $text = if ($Key -eq 'ci') { $ci } else { $deploy }
          $text | Should -Match 'az deployment sub '
          $text | Should -Not -Match 'az deployment group '
          $text | Should -Match 'DEPLOYMENT_LOCATION: westus3'
      }

      It '<Name> no longer reads the removed AZURE_RESOURCE_GROUP variable' -ForEach @(
          @{ Name = 'bicep-ci.yml'; Key = 'ci' },
          @{ Name = 'deploy.yml'; Key = 'deploy' }
      ) {
          $text = if ($Key -eq 'ci') { $ci } else { $deploy }
          $text | Should -Not -Match 'AZURE_RESOURCE_GROUP'
      }
  }

  Describe 'Deploy workflow gating' {
      It 'offers dev and prod and deploys only from main' {
          $deploy | Should -Match 'options: \[dev, prod\]'
          $deploy | Should -Match "if: github\.ref == 'refs/heads/main'"
          $deploy | Should -Match "environment: \$\{\{ inputs\.environment \|\| 'dev' \}\}"
      }

      It 'runs validate and what-if before create' {
          $validate = $deploy.IndexOf('az deployment sub validate')
          $whatIf = $deploy.IndexOf('az deployment sub what-if')
          $create = $deploy.IndexOf('az deployment sub create')
          $validate | Should -BeGreaterThan -1
          $whatIf | Should -BeGreaterThan $validate
          $create | Should -BeGreaterThan $whatIf
      }
  }

  Describe 'Deploy workflow plan/apply split (Phase 2)' {
      BeforeAll {
          $planStart = $deploy.IndexOf('  plan:')
          $applyStart = $deploy.IndexOf('  apply:')
          $planJob = $deploy.Substring($planStart, $applyStart - $planStart)
          $applyJob = $deploy.Substring($applyStart)
      }

      It 'has a plan job before an apply job' {
          $planStart | Should -BeGreaterThan -1
          $applyStart | Should -BeGreaterThan $planStart
      }

      It 'runs validate and what-if in the plan job, in the ungated <env>-plan environment' {
          $planJob | Should -Match "environment: \$\{\{ inputs\.environment \|\| 'dev' \}\}-plan"
          $planJob | Should -Match 'az deployment sub validate'
          $planJob | Should -Match 'az deployment sub what-if'
          $planJob | Should -Not -Match 'az deployment sub create'
      }

      It 'creates only in the apply job, which waits for plan and runs in the reviewer-gated <env> environment' {
          $applyJob | Should -Match 'needs: plan'
          $applyJob | Should -Match "environment: \$\{\{ inputs\.environment \|\| 'dev' \}\}\s"
          $applyJob | Should -Match 'az deployment sub create'
          $applyJob | Should -Not -Match 'az deployment sub what-if'
      }

      It 'runs both jobs from main only' {
          ([regex]::Matches($deploy, "if: github\.ref == 'refs/heads/main'")).Count | Should -Be 2
      }

      It 'runs the PR what-if in dev-plan' {
          $ci | Should -Match 'environment: dev-plan'
      }
  }
  ```

- [ ] **Step 2: Run them to confirm they fail**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/Scripts.Tests.ps1, tests/Workflows.Tests.ps1"`

  Expected: FAIL.
  - Scripts: only one credential is created, and the case-only mismatch is accepted.
  - Workflows: no `plan`/`apply` jobs, and no `dev-plan`.

- [ ] **Step 3: Replace `scripts/New-GitHubDeploymentIdentity.ps1`**

  ```powershell
  [CmdletBinding(SupportsShouldProcess)]
  param(
      [Parameter(Mandatory)]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^[-\w._()]{1,90}$')]
      [string[]]$ResourceGroupNames,

      [Parameter(Mandatory)]
      [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
      [string]$GitHubRepository,

      [Parameter(Mandatory)]
      [ValidatePattern('^[A-Za-z0-9_-]+$')]
      [string]$EnvironmentName,

      [Parameter()]
      [string]$SubscriptionId,

      [Parameter()]
      [ValidatePattern('^[A-Za-z0-9._-]{1,120}$')]
      [string]$DisplayName,

      [Parameter()]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
      [ValidateScript({
              # Owner, User Access Administrator, RBAC Administrator, Contributor: never delegable.
              $privileged = @(
                  '8e3af657-a8ff-443c-a75c-2fe8c4bcb635',
                  '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9',
                  'f58310d9-a9f6-439a-9e8d-f62e7b41a168',
                  'b24988ac-6180-42a0-ab88-20f7382dd24c'
              )
              if ($privileged -contains $_.ToLowerInvariant()) { throw "Role definition $_ is privileged and cannot be delegated to the pipeline." }
              $true
          })]
      [string[]]$DelegatableRoleDefinitionIds = @('ba92f5b4-2d11-453d-a403-e96b0029c9fe'),

      [Parameter()]
      [switch]$GrantLockManagement,

      [Parameter()]
      [ValidateRange(0, 600)]
      [int]$RoleReplicationWaitSeconds = 20
  )

  $ErrorActionPreference = 'Stop'

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
      throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
  }

  if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
      $SubscriptionId = az account show --query id --output tsv
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
          throw 'No active Azure subscription was found. Run az login or provide -SubscriptionId.'
      }
  }

  $tenantId = az account show --subscription $SubscriptionId --query tenantId --output tsv
  if ($LASTEXITCODE -ne 0) {
      throw 'Unable to read the tenant ID for the subscription.'
  }

  if ([string]::IsNullOrWhiteSpace($DisplayName)) {
      $DisplayName = "gh-$($GitHubRepository.Replace('/', '-'))-$EnvironmentName-deploy"
  }

  $subscriptionScope = "/subscriptions/$SubscriptionId"
  $resourceGroupScopes = @($ResourceGroupNames | ForEach-Object { "$subscriptionScope/resourceGroups/$_" })
  # The deploy workflow's plan job runs in '<env>-plan' (no reviewers) and its apply job in '<env>' (reviewers in prod).
  $credentialEnvironments = @($EnvironmentName, "$EnvironmentName-plan")

  Write-Host "Application: $DisplayName"
  Write-Host "Federated subjects: $(($credentialEnvironments | ForEach-Object { "repo:${GitHubRepository}:environment:$_" }) -join ', ')"
  Write-Host "Resource group scopes: $($resourceGroupScopes -join ', ')"

  # 1. Application registration (idempotent by exact display name match).
  $appMatches = @(az ad app list --display-name $DisplayName --query "[?displayName=='$DisplayName'].appId" --output tsv | Where-Object { $_ })
  if ($LASTEXITCODE -ne 0) {
      throw "Failed to query Entra applications named '$DisplayName'."
  }
  if ($appMatches.Count -gt 1) {
      throw "Multiple Entra applications are named '$DisplayName'. Resolve the duplicates or pass a unique -DisplayName."
  }
  $appId = if ($appMatches.Count -eq 1) { $appMatches[0] } else { $null }
  if ([string]::IsNullOrWhiteSpace($appId)) {
      if ($PSCmdlet.ShouldProcess($DisplayName, 'Create Entra application registration')) {
          $appId = az ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg --query appId --output tsv
          if ($LASTEXITCODE -ne 0) { throw 'Failed to create the application registration.' }
      }
      else {
          $appId = '<new-application-id>'
      }
  }

  # 2. Service principal.
  $servicePrincipalId = $null
  if ($appId -ne '<new-application-id>') {
      $servicePrincipalId = az ad sp list --filter "appId eq '$appId'" --query '[0].id' --output tsv
  }
  if ([string]::IsNullOrWhiteSpace($servicePrincipalId)) {
      if ($PSCmdlet.ShouldProcess($appId, 'Create service principal')) {
          $servicePrincipalId = az ad sp create --id $appId --query id --output tsv
          if ($LASTEXITCODE -ne 0) { throw 'Failed to create the service principal.' }
      }
      else {
          $servicePrincipalId = '<new-service-principal-object-id>'
      }
  }

  # 3. Federated credentials bound to the GitHub environments; an existing one must have exactly the same subject.
  function Set-FederatedCredential {
      param(
          [string]$GitHubEnvironment
      )

      $credentialName = "github-$GitHubEnvironment"
      $subject = "repo:${GitHubRepository}:environment:$GitHubEnvironment"

      $existingSubject = $null
      if ($appId -ne '<new-application-id>') {
          $existingSubject = az ad app federated-credential list --id $appId --query "[?name=='$credentialName'].subject" --output tsv
      }
      if (-not [string]::IsNullOrWhiteSpace($existingSubject)) {
          # Entra matches subjects case-sensitively, so compare case-sensitively too.
          if ($existingSubject -cne $subject) {
              throw "Federated credential '$credentialName' exists with subject '$existingSubject', expected '$subject'. Delete it (az ad app federated-credential delete --id $appId --federated-credential-id $credentialName) and re-run."
          }
          Write-Host "Federated credential '$credentialName' already present."
          return
      }

      if ($PSCmdlet.ShouldProcess($subject, 'Create federated credential')) {
          $credentialFile = New-TemporaryFile
          try {
              @{
                  name        = $credentialName
                  issuer      = 'https://token.actions.githubusercontent.com'
                  subject     = $subject
                  audiences   = @('api://AzureADTokenExchange')
                  description = "GitHub Actions environment '$GitHubEnvironment' for $GitHubRepository"
              } | ConvertTo-Json | Set-Content -Path $credentialFile -Encoding ASCII

              az ad app federated-credential create --id $appId --parameters "@$credentialFile" --output none
              if ($LASTEXITCODE -ne 0) { throw "Failed to create the federated credential '$credentialName'." }
          }
          finally {
              Remove-Item $credentialFile -Force
          }
      }
  }

  foreach ($credentialEnvironment in $credentialEnvironments) {
      Set-FederatedCredential -GitHubEnvironment $credentialEnvironment
  }

  function Set-RoleAssignment {
      param(
          [string]$Role,
          [string]$Scope,
          [string]$Condition,
          [switch]$AllowReplicationRetry
      )

      $existing = $null
      if ($servicePrincipalId -notlike '<*>') {
          $existing = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].id' --output tsv
      }
      if (-not [string]::IsNullOrWhiteSpace($existing)) {
          if ($Condition) {
              $existingCondition = az role assignment list --assignee $servicePrincipalId --role $Role --scope $Scope --query '[0].condition' --output tsv
              $normalizedExisting = ($existingCondition -replace '\s+', ' ').Trim()
              $normalizedDesired = ($Condition -replace '\s+', ' ').Trim()
              if ([string]::IsNullOrWhiteSpace($normalizedExisting)) {
                  throw "An unconditioned '$Role' assignment already exists at $Scope. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
              }
              if ($normalizedExisting -ne $normalizedDesired) {
                  throw "An existing '$Role' assignment at $Scope has a different condition than expected. Delete it (az role assignment delete --ids <id>) and re-run so the constrained assignment can be created."
              }
          }
          Write-Host "Role '$Role' already assigned at $Scope."
          return
      }

      if ($PSCmdlet.ShouldProcess($Scope, "Assign '$Role' to $servicePrincipalId")) {
          $arguments = @(
              'role', 'assignment', 'create',
              '--assignee-object-id', $servicePrincipalId,
              '--assignee-principal-type', 'ServicePrincipal',
              '--role', $Role,
              '--scope', $Scope,
              '--output', 'none'
          )
          if ($Condition) {
              $arguments += @('--condition', $Condition, '--condition-version', '2.0')
          }

          # A just-created custom role can take minutes to replicate before it can be assigned.
          $attempts = if ($AllowReplicationRetry) { 6 } else { 1 }
          for ($attempt = 1; $attempt -le $attempts; $attempt++) {
              az @arguments
              if ($LASTEXITCODE -eq 0) { return }
              if ($attempt -lt $attempts) {
                  Write-Host "Assignment of '$Role' failed (attempt $attempt of $attempts); waiting $RoleReplicationWaitSeconds s for role replication."
                  Start-Sleep -Seconds $RoleReplicationWaitSeconds
              }
          }
          throw "Failed to assign '$Role' at $Scope."
      }
  }

  function Set-CustomRole {
      param(
          [string]$Name,
          [string]$Description,
          [string[]]$Actions
      )

      $existingRole = az role definition list --name $Name --custom-role-only true --query '[0].name' --output tsv
      if (-not [string]::IsNullOrWhiteSpace($existingRole)) { return }

      if ($PSCmdlet.ShouldProcess($Name, 'Create custom role')) {
          $roleFile = New-TemporaryFile
          try {
              @{
                  Name             = $Name
                  Description      = $Description
                  Actions          = $Actions
                  NotActions       = @()
                  AssignableScopes = @($subscriptionScope)
              } | ConvertTo-Json | Set-Content -Path $roleFile -Encoding ASCII

              az role definition create --role-definition "@$roleFile" --output none
              if ($LASTEXITCODE -ne 0) { throw "Failed to create the custom role '$Name'." }
          }
          finally {
              Remove-Item $roleFile -Force
          }
      }
  }

  # 4. Subscription-scope deployments only (no resource rights): the entry point targets the subscription,
  #    while every resource lands in a pre-created resource group granted below.
  $deploymentRoleName = 'DefenStack Subscription Deployment Operator'
  Set-CustomRole -Name $deploymentRoleName -Description 'Run subscription-scope ARM deployments (validate, what-if, create) and read resource groups. Grants no resource permissions and cannot cancel or delete deployments.' -Actions @(
      'Microsoft.Resources/deployments/read',
      'Microsoft.Resources/deployments/write',
      'Microsoft.Resources/deployments/validate/action',
      'Microsoft.Resources/deployments/whatIf/action',
      'Microsoft.Resources/deployments/operations/read',
      'Microsoft.Resources/deployments/operationstatuses/read',
      'Microsoft.Resources/subscriptions/read',
      'Microsoft.Resources/subscriptions/resourceGroups/read',
      'Microsoft.Resources/subscriptions/operationresults/read'
  )
  Set-RoleAssignment -Role $deploymentRoleName -Scope $subscriptionScope -AllowReplicationRetry

  # 5. Per resource group: deploy resources, and assign only the listed data-plane roles.
  $roleList = ($DelegatableRoleDefinitionIds | ForEach-Object { $_.ToLowerInvariant() }) -join ', '
  $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))"

  if ($GrantLockManagement) {
      $lockRoleName = 'DefenStack Resource Lock Operator'
      Set-CustomRole -Name $lockRoleName -Description 'Create, read, and delete management locks for DefenStack deployments.' -Actions @(
          'Microsoft.Authorization/locks/read',
          'Microsoft.Authorization/locks/write',
          'Microsoft.Authorization/locks/delete'
      )
  }

  foreach ($resourceGroupScope in $resourceGroupScopes) {
      Set-RoleAssignment -Role 'Contributor' -Scope $resourceGroupScope
      Set-RoleAssignment -Role 'Role Based Access Control Administrator' -Scope $resourceGroupScope -Condition $condition
      if ($GrantLockManagement) {
          Set-RoleAssignment -Role $lockRoleName -Scope $resourceGroupScope -AllowReplicationRetry
      }
  }

  $result = [pscustomobject]@{
      AZURE_CLIENT_ID       = $appId
      AZURE_TENANT_ID       = $tenantId
      AZURE_SUBSCRIPTION_ID = $SubscriptionId
  }

  Write-Host ''
  Write-Host "Create these variables on both GitHub environments '$($credentialEnvironments -join "' and '")' (Settings > Environments), or run:"
  foreach ($credentialEnvironment in $credentialEnvironments) {
      foreach ($property in $result.PSObject.Properties) {
          Write-Host "gh variable set $($property.Name) --env $credentialEnvironment --repo $GitHubRepository --body '$($property.Value)'"
      }
  }

  $result
  ```

- [ ] **Step 4: Replace `.github/workflows/deploy.yml`**

  ```yaml
  name: deploy

  on:
    push:
      branches: [main]
      paths:
        - 'main.bicep'
        - 'modules/**'
        - 'params/**'
    workflow_dispatch:
      inputs:
        environment:
          description: Target environment
          type: choice
          options: [dev, prod]
          default: dev

  permissions:
    contents: read
    id-token: write

  concurrency:
    group: deploy-${{ inputs.environment || 'dev' }}
    cancel-in-progress: false

  env:
    BICEP_VERSION: v0.47.16
    DEPLOYMENT_LOCATION: westus3
    TARGET_ENV: ${{ inputs.environment || 'dev' }}

  jobs:
    # Validate and what-if without approval, so reviewers can read the change before approving apply.
    plan:
      if: github.ref == 'refs/heads/main'
      runs-on: ubuntu-latest
      environment: ${{ inputs.environment || 'dev' }}-plan
      steps:
        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"

        - name: Validate
          run: |
            az deployment sub validate \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --output none

        - name: What-if
          run: |
            set -o pipefail
            az deployment sub what-if \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --exclude-change-types Ignore NoChange 2>&1 \
              | sed -r 's/\x1B\[[0-9;]*[mK]//g' > whatif.txt
            {
              echo "### What-if: ${TARGET_ENV} (subscription scope, rg-defenstack-${TARGET_ENV}-*)"
              echo '```'
              head -c 60000 whatif.txt
              echo '```'
            } >> "$GITHUB_STEP_SUMMARY"

        - name: Keep the what-if for reviewers
          uses: actions/upload-artifact@v4
          with:
            name: whatif-${{ inputs.environment || 'dev' }}
            path: whatif.txt

    # Gated by the target environment's required reviewers (prod); reviewers read the plan job summary first.
    apply:
      needs: plan
      if: github.ref == 'refs/heads/main'
      runs-on: ubuntu-latest
      environment: ${{ inputs.environment || 'dev' }}
      steps:
        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"

        - name: Deploy
          run: |
            az deployment sub create \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --output table
  ```

- [ ] **Step 5: Replace `.github/workflows/bicep-ci.yml`**

  The only change from Phase 1 is `environment: dev` → `environment: dev-plan` on the `what-if` job.

  ```yaml
  name: bicep-ci

  on:
    pull_request:
      branches: [main]
    push:
      branches: [main]
    workflow_dispatch:

  permissions:
    contents: read

  env:
    BICEP_VERSION: v0.47.16
    DEPLOYMENT_LOCATION: westus3

  jobs:
    validate:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"
            echo "$HOME/.azure/bin" >> "$GITHUB_PATH"

        - name: Lint, build, template assertions, main.json drift
          shell: pwsh
          run: ./tests/Invoke-Tests.ps1 -CI

        - name: PSRule for Azure
          shell: pwsh
          run: |
            Install-Module -Name PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force
            New-Item -ItemType Directory -Path reports -Force | Out-Null
            Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error -OutputFormat Sarif -OutputPath reports/ps-rule.sarif

        - name: Upload results
          if: always()
          uses: actions/upload-artifact@v4
          with:
            name: validation-results
            path: |
              test-results.xml
              reports/

    what-if:
      if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
      needs: validate
      runs-on: ubuntu-latest
      environment: dev-plan
      permissions:
        contents: read
        id-token: write
        pull-requests: write
      steps:
        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: What-if against dev
          run: |
            set -o pipefail
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"
            az deployment sub what-if \
              --location "$DEPLOYMENT_LOCATION" \
              --name "pr-${{ github.event.pull_request.number }}-${{ github.run_attempt }}" \
              --parameters params/dev.bicepparam \
              --exclude-change-types Ignore NoChange 2>&1 \
              | sed -r 's/\x1B\[[0-9;]*[mK]//g' > whatif.txt
            {
              echo "### What-if: dev (subscription scope, rg-defenstack-dev-*)"
              echo '```'
              head -c 60000 whatif.txt
              echo '```'
            } > whatif.md
            cat whatif.md >> "$GITHUB_STEP_SUMMARY"

        - name: Comment what-if on PR
          env:
            GH_TOKEN: ${{ github.token }}
          run: |
            gh pr comment "${{ github.event.pull_request.number }}" --body-file whatif.md --edit-last \
              || gh pr comment "${{ github.event.pull_request.number }}" --body-file whatif.md
  ```

- [ ] **Step 6: Run the full suite and parse the workflows**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1` (all pass).

  Then parse both workflows with `powershell-yaml` (`Import-Module powershell-yaml; ConvertFrom-Yaml (Get-Content .github/workflows/deploy.yml -Raw)`). Expected: jobs `apply,plan` in deploy, `validate,what-if` in bicep-ci, and `apply.needs = plan`.

  Never run the script outside its Pester test.

- [ ] **Step 7: Commit**

  ```bash
  git add .github/workflows/deploy.yml .github/workflows/bicep-ci.yml scripts/New-GitHubDeploymentIdentity.ps1 tests/Scripts.Tests.ps1 tests/Workflows.Tests.ps1
  git commit -m "ci: split deploy into ungated plan and gated apply jobs; plan-environment credentials" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 3: Firewall runbook, ADR-010/011, and Phase 2 documentation updates

**Files:**
- Create: `docs/runbooks/02-firewall.md`, `docs/decisions/ADR-010-shared-firewall-rules-module.md`, `docs/decisions/ADR-011-tls-inspection-deferred.md`
- Modify: `tests/Docs.Tests.ps1`, `docs/decisions/ADR-003-dev-threat-intel-alert-mode.md`, `docs/runbooks/00-pipeline-and-identity.md`, `docs/runbooks/00b-configure-pipeline-credentials.md`, `docs/runbooks/01-deploy-stack.md`, `docs/architecture/overview.md`, `docs/cost.md`, `README.md`

**Interfaces:** none produced. This task documents Tasks 1–2. Ground truth is the Task 1–2 code; read it, don't invent.

- [ ] **Step 1: Add the docs test (TDD)**

  Append to `tests/Docs.Tests.ps1`:

  ```powershell

  Describe 'Phase 2 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/02-firewall.md', 'docs/decisions/ADR-010-shared-firewall-rules-module.md', 'docs/decisions/ADR-011-tls-inspection-deferred.md' {
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

      It 'runbook 00b documents the <env>-plan environments' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
          $text | Should -Match 'dev-plan'
          $text | Should -Match 'prod-plan'
      }
  }
  ```

  Run it (`-Path tests/Docs.Tests.ps1`) and confirm the new cases FAIL.

- [ ] **Step 2: `docs/decisions/ADR-010-shared-firewall-rules-module.md`**

  Sections: Context / Decision / Consequences / Revisit when.

  - **Context:**
    - Spec §3 asked for a parent Firewall Policy in `rg-defenstack-<env>-global` with a child policy per region.
    - Azure requires a parent and its child policies to be in the **same region**, so one parent cannot serve West US 3 and East US.
    - The user chose a shared rules module over one parent per region.
  - **Decision:**
    - Each stamp's policy includes `modules/firewallPolicyRules.bicep`: `dns-egress` 100, `platform-egress` 150, and the optional `approved-https-egress` 200.
    - Regional differences are expressed through parameters (`spokeAddressPrefixes`, `managementAddressPrefixes`, `allowedOutboundFqdns`).
    - The groups are dependency-chained, and the firewall is applied last.
  - **Consequences:**
    - One source of truth, and no cross-region constraint.
    - There is no Firewall Manager "base policy" view, and rules can't be delegated to a separate team via policy RBAC.
    - A baseline rule change redeploys every stamp's policy.
  - **Revisit when:** a separate team must own baseline rules, or the design moves to Virtual WAN / Firewall Manager secured hubs.
  - Link: https://learn.microsoft.com/en-us/azure/firewall-manager/policy-overview

- [ ] **Step 3: `docs/decisions/ADR-011-tls-inspection-deferred.md`**

  Sections: Context / Decision / Consequences / Revisit when.

  - **Context:**
    - Premium TLS inspection needs an intermediate CA certificate in Key Vault, a user-assigned identity for the firewall with access to that vault, and every client trusting the CA.
    - No enterprise CA is available.
  - **Decision:**
    - Ship Premium with IDPS and SNI-based FQDN filtering.
    - No `transportSecurity`, no firewall identity, and no certificate.
  - **Consequences:**
    - IDPS sees unencrypted traffic and TLS metadata only; HTTPS payload signatures are not inspected, and URL (path) filtering is unavailable.
    - Threat intelligence and FQDN allowlists still apply.
  - **Revisit when:**
    - an enterprise CA is available, or a compliance requirement demands payload inspection;
    - then plan the Key Vault certificate import, the firewall identity plus Key Vault role, the client trust distribution, and the `transportSecurity` block.

- [ ] **Step 4: `docs/runbooks/02-firewall.md`**

  Use the 9-section template.

  - **§1 Purpose and scope:** what each stamp's firewall enforces, namely the rule groups, IDPS, threat intelligence and the DNS proxy, plus the owning files.
  - **§2 Prerequisites:**
    - Roles to read the firewall and run deploys.
    - The Log Analytics workspace `log-defenstack-<env>`.
  - **§3 Parameters table:**

    | Parameter | Dev | Prod |
    |---|---|---|
    | `firewallTier` | `Premium` | `Premium` |
    | `idpsMode` | `Alert` | `Deny` |
    | `threatIntelMode` | `Alert` | `Deny` |
    | `allowedOutboundFqdns` | params file | params file |
    | `managementAddressPrefixes` | from the address plan | from the address plan |
    | `enableDeleteLock` | `false` | `true` |

  - **§4 Step-by-step:** the **Rule change procedure**.
    1. Edit `modules/firewallPolicyRules.bicep` for a baseline rule, or `allowedOutboundFqdns` in `params/<env>.bicepparam` for an application allowlist.
    2. Add or adjust a test in `tests/FirewallPolicyRules.Tests.ps1`.
    3. Run the suite and PSRule.
    4. Open a PR and read the PR what-if (`dev-plan`).
    5. Merge; `deploy` runs `plan`, then `apply` for dev.
    6. For prod, run `deploy` with `environment=prod`. Reviewers read the `plan` job summary / `whatif-prod` artifact, then approve `apply`.
  - **§5 Manual steps:** the **Allowlist request** process.
    - The requester supplies: FQDN, port/protocol, source (app or management), business justification, owner and expiry.
    - The reviewer checks that it is the least specific wildcard needed and that there is no overlap with existing rules.
    - Record the request in the PR description.
    - Remove expired entries quarterly.
  - **§6 Validation:** commands with expected output.
    - `az network firewall show -g rg-defenstack-<env>-wus3 -n afw-defenstack-<env>-wus3 --query "{tier:sku.tier,zones:zones}"` → `Premium`, `1 2 3`.
    - `az network firewall policy show -g … -n afwp-defenstack-<env>-wus3 --query "{tier:sku.tier,idps:intrusionDetection.mode,ti:threatIntelMode}"` → Premium / Alert|Deny / Alert|Deny.
    - `az network firewall policy rule-collection-group list -g … --policy-name afwp-defenstack-<env>-wus3 --query "[].{name:name,priority:priority}" -o table` → dns-egress 100, platform-egress 150, and approved-https-egress 200 when the allowlist is non-empty.
    - Prod locks: `az lock list -g rg-defenstack-prod-wus3 -o table` → locks on the hub VNet, spoke VNet, Key Vault, firewall, policy and PIP.
    - KQL: `AZFWIdpsSignature | take 20`, `AZFWThreatIntel | take 20`, and `AZFWApplicationRule | where Action == "Deny" | take 20`.
  - **§7 Rollback:**
    - Revert the commit and redeploy.
    - A tier change Premium → Standard is not supported in place. It needs a new firewall, and Phase 2 is greenfield, so don't do it.
    - In prod, lift a lock with `az lock delete --ids` before any delete, then re-create it by redeploying.
  - **§8 Operations:**
    - **IDPS tuning:** review `AZFWIdpsSignature` in dev weekly. If a signature false-positives, add a signature override in Bicep in a follow-up change; there is no portal drift.
    - **Moving dev IDPS to Deny:** change the stamp expression.
    - **OS update egress:** management subnet only.
    - **Cost:** Premium hourly rate plus data processing (see `docs/cost.md`).
  - **§9 Troubleshooting:**
    - `AnotherOperationInProgress` / `FirewallPolicyUpdateNotAllowedWhenUpdatingOrDeleting` → the rule groups are chained, so re-run.
    - VM updates fail → check `AZFWApplicationRule` denies from the management subnet and confirm the FQDN is in `platform-egress`.
    - An app call is denied → the allowlist request process.
    - IDPS blocks legitimate prod traffic → temporarily set that signature to Alert via an override (runbook change), never disable IDPS.
    - `ScopeLocked` on delete in prod → §7.

- [ ] **Step 5: Update the existing docs**

  - **ADR-003:** add a "Phase 2" note. IDPS follows the same dev Alert / prod Deny split, for the same reason.
  - **Runbook 00b:**
    1. Add the `dev-plan` and `prod-plan` GitHub environments. Each needs the same three `AZURE_*` variables as its apply environment.
       - `dev-plan`: deployment branches **No restriction** (the PR what-if).
       - `prod-plan`: **Selected branches → `main`**, no reviewers.
    2. The script now creates two federated credentials per environment (`github-<env>`, `github-<env>-plan`). Update the Step 3 expected output (two subjects) and Method B (add the second credential).
    3. Add a §9 row: `AADSTS70021` on the plan job → the `-plan` credential or environment is missing.
    4. Add a prod-approval note: reviewers read the `plan` job summary / `whatif-prod` artifact before approving `apply`.
  - **Runbook 00:** §1 describes the plan/apply split.
  - **Runbook 01:**
    - §6: add the Premium/IDPS checks and the new prod locks, by reference to runbook 02 §6.
    - §7: add the new prod locks to the lock-removal note.
  - **`docs/architecture/overview.md`:**
    - The firewall is Premium with IDPS.
    - Replace the rule description with the three groups and their sources.
    - Update the lock inventory.
    - Link ADR-010 and ADR-011.
  - **`docs/cost.md`:** add a "Phase 2 delta" section: Firewall **Premium** hourly rate instead of Standard (dev ×1, prod ×2) plus data processing. "Fill from the Pricing Calculator; do not invent prices."
  - **`README.md`:** update the Firewall behavior section with Premium, IDPS modes, the three rule groups, management-only OS-update egress and prod locks, and add runbook 02 to the Documentation list.

- [ ] **Step 6: Run the full suite and commit**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1` (all pass).

  ```bash
  git add docs/runbooks/02-firewall.md docs/decisions/ADR-010-shared-firewall-rules-module.md docs/decisions/ADR-011-tls-inspection-deferred.md docs/decisions/ADR-003-dev-threat-intel-alert-mode.md docs/runbooks/00-pipeline-and-identity.md docs/runbooks/00b-configure-pipeline-credentials.md docs/runbooks/01-deploy-stack.md docs/architecture/overview.md docs/cost.md README.md tests/Docs.Tests.ps1
  git commit -m "docs: firewall runbook, ADR-010/011, and Phase 2 documentation updates" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

## Deferred live steps (operator)

1. Create GitHub environments `dev-plan` (no branch restriction) and `prod-plan` (main only). Add the `AZURE_*` variables to them.
2. Re-run runbook 00b for dev and prod so each app registration gets its `-plan` credential.
3. Deploy dev (runbook 01) and run runbook 02 §6. Watch `AZFWIdpsSignature` for a week before relying on prod Deny.
4. Deploy prod through `deploy` (`environment=prod`): read the `plan` summary, then approve `apply`.

## Self-review

- **Spec coverage:**

  | Spec item (§3 / §5 Phase 2) | Task |
  |---|---|
  | Premium | 1 |
  | Zones | already in Phase 1 |
  | IDPS Alert/Deny | 1 |
  | Threat intelligence Deny (prod) | unchanged |
  | Parent/child policy | replaced by the shared rules module (1, ADR-010) |
  | Platform FQDN tags / Windows Update / Ubuntu for management VMs | 1 |
  | TLS inspection gated | ADR-011 |
  | Locks on hubs, firewalls, Key Vaults | 1; DNS zones and workspace were done in Phase 1 |
  | Runbook `02-firewall.md` with rule change and allowlist request procedures | 3 |

- **Phase 1 carry-forwards resolved:**

  | Carry-forward | Task |
  |---|---|
  | Prod reviewers approve before seeing the what-if | 2 |
  | Case-sensitive credential subject check | 2 |
  | Lock management used by prod | 1, with the `-GrantLockManagement` role already in place |

- **Still deferred:**
  - ABAC principal-type clause;
  - `Set-CustomRole` drift check in code;
  - runtime privileged-role check;
  - issuer/audience comparison on existing credentials;
  - retry-loop tests.

- **Names used consistently:**
  - deployment `firewall-policy-rules`;
  - groups `dns-egress` / `platform-egress` / `approved-https-egress`;
  - params `firewallTier`, `idpsMode`, `managementAddressPrefixes`, `enableDeleteLock`;
  - environments `<env>` / `<env>-plan`;
  - credentials `github-<env>` / `github-<env>-plan`.
