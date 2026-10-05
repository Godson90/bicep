# Phase 1: Multi-Region Subscription-Scope Restructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the deployment from one resource-group-scoped stack into a subscription-scoped entry point. The entry point deploys a shared global layer plus one region stamp per region: West US 3 primary and East US warm standby for prod, primary-only for dev.

**Architecture:**
- `main.bicep` targets the subscription. It deploys into pre-created resource groups (`rg-defenstack-<env>-global`, `rg-defenstack-<env>-<region>`), so the pipeline identity never needs subscription-wide resource rights.
- `modules/global.bicep` owns the shared resources: the Log Analytics workspace (replicated to East US in prod) and the private DNS zones.
- `modules/regionStamp.bicep` composes the existing Phase 0 modules for one region, with availability zones on.
- `modules/privateDnsZoneLinks.bicep` links every stamp's hub and spoke VNets to the shared zones.

**Tech Stack:** Bicep CLI 0.47.16 (user-defined types and `import`), Azure CLI 2.90+, Windows PowerShell 5.1 / pwsh 7, Pester 5.x, PSRule.Rules.Azure 1.47.0, GitHub Actions (`azure/login@v2`, OIDC).

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` — §1 (target architecture, address plan), §4 (code structure changes), §5 Phase 1, §6 (documentation standard). Phase 0 plan for context: `docs/superpowers/plans/2026-09-25-phase0-foundation-fixes.md`.

**Verification status of this plan:** every Bicep file, parameter file, test file, the identity script and the PSRule configuration below were prototyped and run before the plan was written:
- `bicep lint` / `bicep build` / `bicep build-params` are clean.
- The full Pester suite passes: 129/129.
- `Assert-PSRule` reports 0 failures.

The embedded content is that verified content. Transcribe it exactly.

## Global Constraints

- **Greenfield:** Phase 1 deploys new resource groups; it is **not** an in-place change to `defenStack`. `defenStack` stays until the migration runbook (Task 6) retires it.
- **User decisions (binding):**
  - Dev is **primary region only**.
  - Dev and prod share **one subscription** in separate resource groups.
  - `defenStack` is **kept until cutover, then torn down**.
- **Regions:** primary `westus3` (code `wus3`), secondary `eastus` (code `eus`). Resource groups follow `rg-defenstack-<env>-global` and `rg-defenstack-<env>-<code>`, and are **pre-created by an operator** (runbook 01); templates never create them.
- **Address plan:**
  - Prod: WUS3 hub `10.1.0.0/16` (firewall `10.1.0.0/26`), spoke `10.0.0.0/16` (`10.0.1.0/24` PE, `10.0.2.0/24` App Service, `10.0.3.0/24` management). EUS hub `10.11.0.0/16`, spoke `10.10.0.0/16`, same subnet pattern.
  - Dev: hub `10.21.0.0/16`, spoke `10.20.0.0/16`, so dev and prod never overlap.
  - Reserved in every hub for Phase 3: `AzureBastionSubnet` `x.x.1.0/26`, `GatewaySubnet` `x.x.2.0/27`.
- **Availability:**
  - Firewall and its public IP use zones `1,2,3` in every stamp.
  - The App Service plan is zone-redundant with 3 instances **only in prod primary**; the EUS warm standby and dev run 1 instance.
  - Storage is `Standard_GRS` in prod and `Standard_LRS` in dev (RA-GZRS is Phase 5).
  - The prod workspace replicates to `eastus`.
- **Deletion protection:** `CanNotDelete` locks in prod only, on the spoke VNet, the DNS zones and the workspace.
- **API versions:** reuse the versions already in the repo. New resource types use exactly the versions in this plan.
- **Secrets:** none in `.bicep`, committed `.bicepparam`, `main.json`, outputs, workflows or command history.
- **main.json is generated:** after any `.bicep` change run `bicep build main.bicep` and commit `main.json`. The drift test enforces this.
- **Docs are mandatory:** runbooks use the 9-section structure in `docs/runbooks/_template.md`. A task is not complete without its doc changes.
- **Tests must run on both shells:**
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  - `pwsh ./tests/Invoke-Tests.ps1`
- **Git:**
  - Work on branch `phase1-multi-region`, which is stacked on `phase0-foundation-fixes`; its PR targets `phase0-foundation-fixes` until Phase 0 merges.
  - Commit messages end with a `Co-Authored-By: Claude <model> <noreply@anthropic.com>` trailer.
  - No live Azure/Entra/GitHub commands during implementation; live steps are documented for the operator.
- **Bicep strings:** a literal backslash is written `\\`.
- **Compiled-expression gotcha:** Bicep hoists a ternary module parameter into `[if(cond, createObject('value', a), createObject('value', b))]` on the parameter itself, with no `.value`. The tests below already account for this.

## File Map

| File | Responsibility | Task |
|---|---|---|
| `tests/Bicep.TestHelpers.psm1` | + `Get-TemplateResourceBySymbol` (module names in `main` are expressions) | 1 |
| `tests/Lint.Tests.ps1` | Exclusion regex also matches top-level `.git`/`.claude`/`.superpowers` | 1 |
| `tests/VirtualMachine.Tests.ps1` | + Windows DCR branch coverage | 1 |
| `modules/types.bicep` (new) | Exported types: `regionAddressPlan`, `privateDnsZoneSet`, `virtualNetworkReference` | 2 |
| `modules/monitoring.bicep` | + `replicationLocation`, `enableDeleteLock` | 2 |
| `modules/global.bicep` (new) | Workspace (via monitoring) + 3 private DNS zones + prod locks | 2 |
| `modules/privateDnsZoneLinks.bicep` (new) | One zone → N VNet links | 2 |
| `tests/Global.Tests.ps1`, `tests/PrivateDnsZoneLinks.Tests.ps1` (new), `tests/Monitoring.Tests.ps1` | Tests | 2 |
| `modules/appService.bicep` | Plan name becomes a parameter | 3 |
| `modules/spokeNetwork.bicep`, `modules/vnet.bicep` | `virtual-machines` subnet renamed to `management` | 3 |
| `modules/privateConnectivity.bicep` | Private endpoints only; consumes global zone IDs | 3 |
| `modules/regionStamp.bicep` (new) | Per-region composition, names, availability policy | 3 |
| `main.bicep`, `main.json` | Subscription-scope entry point | 3 |
| `params/dev.bicepparam`, `params/prod.bicepparam` (new) | Environment topology and address plans | 3 |
| `tests/RegionStamp.Tests.ps1`, `tests/PrivateConnectivity.Tests.ps1` (new); `tests/Main.Tests.ps1`, `tests/Params.Tests.ps1` (rewritten); `tests/AppService.Tests.ps1`, `tests/SpokeNetwork.Tests.ps1` | Tests | 3 |
| `ps-rule.yaml`, `.ps-rule/Suppression.Rule.yaml` (new), `docs/decisions/ADR-008-*.md` (new) | Per-target PSRule baseline | 4 |
| `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Scripts.Tests.ps1`, `tests/Workflows.Tests.ps1` (new) | Subscription-scope identity + hardening | 5 |
| `.github/workflows/bicep-ci.yml`, `.github/workflows/deploy.yml` | `az deployment sub`, prod option | 5 |
| `docs/decisions/ADR-009-*.md` (new), `docs/runbooks/00-*.md`, `docs/runbooks/00b-*.md` | Identity docs | 5 |
| `docs/architecture/overview.md`, `docs/runbooks/01-deploy-stack.md`, `docs/runbooks/01a-migrate-from-defenstack.md`, `tests/Docs.Tests.ps1` (new); `docs/cost.md`, `README.md` | Phase 1 docs | 6 |

---

### Task 1: Test harness carry-forwards

**Files:**
- Modify: `tests/Bicep.TestHelpers.psm1`, `tests/Lint.Tests.ps1`, `tests/VirtualMachine.Tests.ps1`

**Interfaces:**
- Produces: `Get-TemplateResourceBySymbol -Template <object> -Symbol <string>`, which returns the resource with that symbolic name from a languageVersion 2.0 template. It throws if the template has array-form resources or the symbol is missing. Task 3's `tests/Main.Tests.ps1` uses it.

- [ ] **Step 1: Create the branch**

  The worktree already exists at `C:\Workspace\Bicep\.claude\worktrees\phase1-multi-region` on branch `phase1-multi-region`; work there.

- [ ] **Step 2: Fix the lint exclusion so it also matches a top-level excluded directory**

  In `tests/Lint.Tests.ps1`, replace the three `Where-Object { $_.Name -notmatch '[\\/]\.… ' }` lines with the single line:

  ```powershell
          Where-Object { $_.Name -notmatch '(^|[\\/])\.(git|claude|superpowers)([\\/]|$)' }
  ```

  The old patterns required a separator before the dot-segment, so they missed `.superpowers\sdd\x.bicep` relative to the repo root.

- [ ] **Step 3: Add the symbolic-name helper**

  In `tests/Bicep.TestHelpers.psm1`, insert this function before `Export-ModuleMember`, and add `Get-TemplateResourceBySymbol` to the exported list:

  ```powershell
  function Get-TemplateResourceBySymbol {
      [CmdletBinding()]
      param(
          [Parameter(Mandatory)]
          $Template,

          [Parameter(Mandatory)]
          [string]$Symbol
      )

      # Module names in the subscription entry point are expressions, so look them up by symbolic name.
      if ($Template.resources -is [array]) {
          throw 'Template has no symbolic resource names; languageVersion 2.0 is required.'
      }

      $property = $Template.resources.PSObject.Properties[$Symbol]
      if (-not $property) {
          throw "Resource with symbolic name '$Symbol' was not found."
      }

      $property.Value
  }
  ```

- [ ] **Step 4: Add Windows DCR coverage**

  Append to `tests/VirtualMachine.Tests.ps1`:

  ```powershell
  Describe 'VM monitoring on Windows (F3)' {
      It 'installs the Windows agent and collects System and Application events when osType is Windows' {
          $template.variables.azureMonitorAgentName | Should -Match "'AzureMonitorWindowsAgent'"
          $template.variables.osLogSource | Should -Match 'windowsEventLogs'
          $template.variables.osLogSource | Should -Match 'Microsoft-Event'
          $template.variables.osLogSource | Should -Match 'Application!'
      }
  }
  ```

  This is a coverage test for existing behaviour, so it passes immediately. Confirm it would fail by temporarily changing `'Application!*…'` in `modules/virtualMachine.bicep` to another string, running the test (expect FAIL), then reverting.

- [ ] **Step 5: Run the full suite**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected: all pass, and 12 `lints without errors` cases are still discovered.

- [ ] **Step 6: Commit**

  ```bash
  git add tests/Bicep.TestHelpers.psm1 tests/Lint.Tests.ps1 tests/VirtualMachine.Tests.ps1
  git commit -m "test: symbolic-name helper, top-level lint exclusions, Windows DCR coverage" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 2: Global layer — shared types, workspace replication, DNS zones and links

**Files:**
- Create: `modules/types.bicep`, `modules/global.bicep`, `modules/privateDnsZoneLinks.bicep`, `tests/Global.Tests.ps1`, `tests/PrivateDnsZoneLinks.Tests.ps1`
- Modify: `modules/monitoring.bicep`, `tests/Monitoring.Tests.ps1`, `main.json`

**Interfaces:**
- Produces from `modules/types.bicep`, all `@export()`:
  - `regionAddressPlan` `{ hubAddressSpace: string[], firewallSubnetPrefix: string, spokeAddressSpace: string[], privateEndpointSubnetPrefix: string, appServiceIntegrationSubnetPrefix: string, managementSubnetPrefix: string }`
  - `privateDnsZoneSet` `{ blob: string, sites: string, vault: string }`
  - `virtualNetworkReference` `{ name: string, id: string }`
- Produces from `modules/global.bicep`:
  - params: `location`, `workspaceName`, `privateDnsZoneNames privateDnsZoneSet`, `workspaceReplicationLocation = ''`, `enableDeleteLock = false`
  - outputs: `logAnalyticsWorkspaceId string`, `privateDnsZoneIds privateDnsZoneSet`
- Produces from `modules/privateDnsZoneLinks.bicep`: params `zoneName string`, `virtualNetworks virtualNetworkReference[]`. Links are named `<vnet-name>-link`.
- Produces from `modules/monitoring.bicep`: new params `replicationLocation string = ''` and `enableDeleteLock bool = false`.

- [ ] **Step 1: Write the failing tests**

  Create `tests/Global.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/global.bicep'
      $zones = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones'
      $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks'
      $monitoring = Get-ModuleDeployment -Template $template -Name 'monitoring'
  }

  Describe 'Global layer private DNS zones' {
      It 'creates exactly the blob, sites, and vault zones named by the entry point' {
          $zones.Count | Should -Be 3
          foreach ($key in 'blob', 'sites', 'vault') {
              @($zones.name) | Should -Contain "[parameters('privateDnsZoneNames').$key]"
          }
      }

      It 'locks every zone only when deletion protection is requested' {
          $locks.Count | Should -Be 3
          foreach ($lock in $locks) {
              $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
              $lock.properties.level | Should -Be 'CanNotDelete'
          }
      }

      It 'outputs the zone IDs keyed by private endpoint group' {
          @($template.outputs.privateDnsZoneIds.value.PSObject.Properties.Name) | Should -Be @('blob', 'sites', 'vault')
      }
  }

  Describe 'Global layer workspace' {
      It 'passes replication and deletion protection through to the monitoring module' {
          $monitoring.properties.parameters.replicationLocation.value | Should -Be "[parameters('workspaceReplicationLocation')]"
          $monitoring.properties.parameters.enableDeleteLock.value | Should -Be "[parameters('enableDeleteLock')]"
      }

      It 'disables workspace replication by default' {
          $template.parameters.workspaceReplicationLocation.defaultValue | Should -BeExactly ''
      }
  }
  ```

  Create `tests/PrivateDnsZoneLinks.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/privateDnsZoneLinks.bicep'
      $links = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones/virtualNetworkLinks' | Select-Object -First 1
  }

  Describe 'Private DNS zone links' {
      It 'creates one link per virtual network' {
          $links.copy.count | Should -Be "[length(parameters('virtualNetworks'))]"
          $links.properties.virtualNetwork.id | Should -Be "[parameters('virtualNetworks')[copyIndex()].id]"
      }

      It 'names each link after its VNet so links from several regions never collide' {
          $links.name | Should -Match "format\('\{0\}-link', parameters\('virtualNetworks'\)\[copyIndex\(\)\]\.name\)"
      }

      It 'links for resolution only (private endpoint zone groups own the records)' {
          $links.properties.registrationEnabled | Should -BeExactly $false
      }

      It 'does not create the zone (the global layer owns zones)' {
          @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones').Count | Should -Be 0
      }
  }
  ```

  Append to `tests/Monitoring.Tests.ps1`:

  ```powershell
  Describe 'Log Analytics resilience (Phase 1)' {
      BeforeAll {
          $workspace = Get-TemplateResource -Template $template -Type 'Microsoft.OperationalInsights/workspaces' | Select-Object -First 1
          $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
      }

      It 'replicates the workspace only when a replication region is supplied' {
          $template.parameters.replicationLocation.defaultValue | Should -BeExactly ''
          $workspace.properties.replication | Should -Match "if\(empty\(parameters\('replicationLocation'\)\), null\(\)"
          $workspace.properties.replication | Should -Match "'location', parameters\('replicationLocation'\)"
      }

      It 'locks the workspace only when deletion protection is requested' {
          $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
          $lock.properties.level | Should -Be 'CanNotDelete'
      }
  }
  ```

- [ ] **Step 2: Run them to confirm they fail**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/Global.Tests.ps1, tests/PrivateDnsZoneLinks.Tests.ps1, tests/Monitoring.Tests.ps1"`

  Expected: FAIL. `bicep build failed for modules/global.bicep` / `privateDnsZoneLinks.bicep`, because the files don't exist yet. The `replicationLocation` / lock assertions also fail.

- [ ] **Step 3: Create `modules/types.bicep`**

  ```bicep
  // Shared parameter contracts between the subscription entry point, the global layer, and region stamps.

  @export()
  @description('Address plan for one region: hub VNet with the firewall subnet, and spoke VNet with its three subnets.')
  type regionAddressPlan = {
    @description('Hub VNet address space.')
    hubAddressSpace: string[]

    @description('AzureFirewallSubnet prefix (at least /26) inside hubAddressSpace.')
    firewallSubnetPrefix: string

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

- [ ] **Step 4: Replace `modules/monitoring.bicep`**

  ```bicep
  @description('Azure region for the Log Analytics workspace.')
  param location string

  @description('Globally unique Log Analytics workspace name within the resource group.')
  @minLength(4)
  @maxLength(63)
  param workspaceName string

  @description('Number of days to retain workspace data. 90 days matches the retention included with Microsoft Sentinel.')
  @minValue(30)
  @maxValue(730)
  param retentionInDays int = 90

  @description('Region that holds the workspace replica for regional failover. Empty disables replication.')
  param replicationLocation string = ''

  @description('Apply a CanNotDelete lock to the workspace.')
  param enableDeleteLock bool = false

  // Central workspace for platform, network, storage, and application diagnostics.
  resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
    name: workspaceName
    location: location
    properties: {
      retentionInDays: retentionInDays
      sku: {
        name: 'PerGB2018'
      }
      replication: empty(replicationLocation) ? null : {
        enabled: true
        location: replicationLocation
      }
    }
  }

  resource workspaceLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: logAnalyticsWorkspace
    name: '${workspaceName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  output id string = logAnalyticsWorkspace.id
  output name string = logAnalyticsWorkspace.name
  ```

- [ ] **Step 5: Create `modules/global.bicep`**

  ```bicep
  import { privateDnsZoneSet } from 'types.bicep'

  @description('Azure region for the Log Analytics workspace (the primary region).')
  param location string

  @description('Log Analytics workspace name.')
  @minLength(4)
  @maxLength(63)
  param workspaceName string

  @description('Private DNS zone names shared by every region stamp.')
  param privateDnsZoneNames privateDnsZoneSet

  @description('Region that receives the workspace replica. Empty disables workspace replication.')
  param workspaceReplicationLocation string = ''

  @description('Apply CanNotDelete locks to the shared DNS zones and the workspace.')
  param enableDeleteLock bool = false

  // Central workspace for every region's diagnostics.
  module monitoring 'monitoring.bicep' = {
    name: 'monitoring'
    params: {
      location: location
      workspaceName: workspaceName
      replicationLocation: workspaceReplicationLocation
      enableDeleteLock: enableDeleteLock
    }
  }

  // One set of private DNS zones for all regions; each region links its hub and spoke VNets.
  resource blobZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
    name: privateDnsZoneNames.blob
    location: 'global'
  }

  resource sitesZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
    name: privateDnsZoneNames.sites
    location: 'global'
  }

  resource vaultZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
    name: privateDnsZoneNames.vault
    location: 'global'
  }

  resource blobZoneLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: blobZone
    name: 'blob-zone-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  resource sitesZoneLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: sitesZone
    name: 'sites-zone-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  resource vaultZoneLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: vaultZone
    name: 'vault-zone-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  output logAnalyticsWorkspaceId string = monitoring.outputs.id
  output privateDnsZoneIds privateDnsZoneSet = {
    blob: blobZone.id
    sites: sitesZone.id
    vault: vaultZone.id
  }
  ```

- [ ] **Step 6: Create `modules/privateDnsZoneLinks.bicep`**

  ```bicep
  import { virtualNetworkReference } from 'types.bicep'

  @description('Existing private DNS zone name in this resource group.')
  param zoneName string

  @description('Virtual networks that resolve this zone. Each gets one link named <vnet>-link.')
  param virtualNetworks virtualNetworkReference[]

  resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = {
    name: zoneName
  }

  // Resolution-only links: private endpoints register records through their DNS zone groups.
  resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for vnet in virtualNetworks: {
    parent: zone
    name: '${vnet.name}-link'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnet.id
      }
    }
  }]
  ```

- [ ] **Step 7: Rebuild and run the full suite**

  Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected: all pass. The old `main.bicep` still uses `monitoring.bicep` with its new optional params defaulted.

- [ ] **Step 8: Commit**

  ```bash
  git add modules/types.bicep modules/global.bicep modules/privateDnsZoneLinks.bicep modules/monitoring.bicep main.json tests/Global.Tests.ps1 tests/PrivateDnsZoneLinks.Tests.ps1 tests/Monitoring.Tests.ps1
  git commit -m "feat: add global layer with shared DNS zones, zone links, and workspace replication" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 3: Region stamp and subscription-scope entry point

This task is one reviewable unit. Changing `privateConnectivity.bicep` breaks the old resource-group-scoped `main.bicep`, so the stamp, the new `main.bicep` and both parameter files must land together. Use as many commits as you like, but the suite must be green at the task's last commit.

**Files:**
- Modify: `modules/appService.bicep`, `modules/spokeNetwork.bicep`, `modules/vnet.bicep`, `modules/privateConnectivity.bicep` (full replacement), `main.bicep` (full replacement), `main.json`, `params/dev.bicepparam` (full replacement), `tests/Main.Tests.ps1` (full replacement), `tests/Params.Tests.ps1` (full replacement), `tests/AppService.Tests.ps1`, `tests/SpokeNetwork.Tests.ps1`
- Create: `modules/regionStamp.bicep`, `params/prod.bicepparam`, `tests/RegionStamp.Tests.ps1`, `tests/PrivateConnectivity.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 types, the `global.bicep` outputs, and `privateDnsZoneLinks.bicep`; Task 1 `Get-TemplateResourceBySymbol`.
- Produces:
  - **`main.bicep` params:** `environmentName` (`dev`|`prod`), `primaryLocation`/`secondaryLocation` (`westus3`|`eastus`), `deploySecondaryRegion`, `primaryAddressPlan`, `secondaryAddressPlan?`, `allowedOutboundFqdns`, `additionalPrivateEndpointSourceCidrs`, `managementSourceCidrs`, `healthCheckPath`, `enableVirtualMachine`, `virtualMachineOsType`, `virtualMachineAdminUsername`, `virtualMachineAdminSshPublicKey`, `virtualMachineAdminPassword` (`@secure()`).
  - **`main.bicep` outputs:** `primaryAppServiceHostName`, `secondaryAppServiceHostName`.
  - **Symbolic module names** that tests rely on: `global`, `primaryStamp`, `secondaryStamp`, `privateDnsLinks`.
  - **`regionStamp.bicep` outputs:** `hubVnetName`, `hubVnetId`, `spokeVnetName`, `spokeVnetId`, `firewallPrivateIp`, `appServiceName`, `appServiceHostName`, `keyVaultName`, `storageAccountName`. Later phases add Bastion, VPN and Front Door origins to this stamp.
  - **`appService.bicep`:** new required param `appServicePlanName`.
  - **`spokeNetwork.bicep` / `vnet.bicep`:** the third subnet defaults to `management`.
- **Breaking:** the old `main.bicep` parameters (`location`, `storageAccountName`, `hubVnetName`, `spokeVnetAddressSpace`, …) are removed, and `az deployment group` is replaced by `az deployment sub`.

- [ ] **Step 1: Write the failing tests**

  Create `tests/RegionStamp.Tests.ps1`:

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
  ```

  Create `tests/PrivateConnectivity.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/privateConnectivity.bicep'
      $zoneGroups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups'
  }

  Describe 'Region private connectivity' {
      It 'creates private endpoints for blob, App Service, and Key Vault' {
          @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateEndpoints').Count | Should -Be 3
      }

      It 'no longer creates private DNS zones or VNet links (moved to the global layer)' {
          @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones').Count | Should -Be 0
          @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones/virtualNetworkLinks').Count | Should -Be 0
      }

      It 'registers each endpoint in the shared zone for its group' {
          $zoneIds = @($zoneGroups | ForEach-Object { $_.properties.privateDnsZoneConfigs[0].properties.privateDnsZoneId })
          foreach ($key in 'blob', 'sites', 'vault') {
              $zoneIds | Should -Contain "[parameters('privateDnsZoneIds').$key]"
          }
      }
  }
  ```

  Replace `tests/Main.Tests.ps1` entirely. Its Phase 0 wiring assertions now live in `RegionStamp.Tests.ps1`.

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
  ```

  Replace `tests/Params.Tests.ps1` entirely:

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
          Test-InsideSixteen $plan.hubAddressSpace[0] @($plan.firewallSubnetPrefix) | Should -BeTrue
          Test-InsideSixteen $plan.spokeAddressSpace[0] @($plan.privateEndpointSubnetPrefix, $plan.appServiceIntegrationSubnetPrefix, $plan.managementSubnetPrefix) | Should -BeTrue
      }
  }
  ```

  Append to `tests/AppService.Tests.ps1`:

  ```powershell
  Describe 'App Service plan naming (Phase 1)' {
      It 'takes the plan name from the caller so every region stamp has its own plan' {
          $template.parameters.appServicePlanName.type | Should -Be 'string'
          $plan.name | Should -Be "[parameters('appServicePlanName')]"
      }
  }
  ```

  Append to `tests/SpokeNetwork.Tests.ps1`, and change its comment `2 virtual-machines.` to `2 management.`:

  ```powershell
  Describe 'Management subnet naming (Phase 1)' {
      It 'names the third subnet management' {
          $template.parameters.virtualMachineSubnetName.defaultValue | Should -Be 'management'
      }
  }
  ```

- [ ] **Step 2: Run them to confirm they fail**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/RegionStamp.Tests.ps1, tests/PrivateConnectivity.Tests.ps1, tests/Main.Tests.ps1, tests/Params.Tests.ps1, tests/AppService.Tests.ps1, tests/SpokeNetwork.Tests.ps1"`

  Expected: FAIL. `regionStamp.bicep` is missing; main is not subscription-scoped; `prod.bicepparam` is missing; the plan-name param is missing; the subnet default is `virtual-machines`; `privateConnectivity` still creates zones.

- [ ] **Step 3: Module interface changes**

  1. `modules/appService.bicep`: replace the line `var appServicePlanName string = 'defenstack-${environmentType}-plan'` with:

     ```bicep
     @description('App Service plan name. Include the environment and region so every stamp gets its own plan.')
     @minLength(1)
     @maxLength(60)
     param appServicePlanName string
     ```

  2. `modules/spokeNetwork.bicep` and `modules/vnet.bicep`: change every `'virtual-machines'` string literal to `'management'`. That is 1 occurrence in spokeNetwork and 2 in vnet: the default subnets entry and the `virtualMachineSubnetName` default. Parameter names stay the same.

  3. Replace `modules/privateConnectivity.bicep` entirely:

     ```bicep
     import { privateDnsZoneSet } from 'types.bicep'

     @description('Azure region for private endpoint resources.')
     param location string

     @description('Storage account resource ID.')
     param storageAccountId string

     @description('Storage account name used for deterministic private endpoint naming.')
     @minLength(3)
     @maxLength(24)
     param storageAccountName string

     @description('App Service resource ID.')
     param appServiceId string

     @description('App Service name used for deterministic private endpoint naming.')
     @minLength(2)
     @maxLength(60)
     param appServiceName string

     @description('Subnet resource ID for private endpoints.')
     param privateEndpointSubnetId string

     @description('Key Vault resource ID.')
     param keyVaultId string

     @description('Key Vault name used for deterministic private endpoint naming.')
     @minLength(3)
     @maxLength(24)
     param keyVaultName string

     @description('Resource IDs of the shared private DNS zones created by the global layer.')
     param privateDnsZoneIds privateDnsZoneSet

     // Private endpoint for Blob service access.
     resource storagePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
       name: '${storageAccountName}-pe'
       location: location
       properties: {
         privateLinkServiceConnections: [
           {
             name: 'blob'
             properties: {
               privateLinkServiceId: storageAccountId
               groupIds: [
                 'blob'
               ]
             }
           }
         ]
         subnet: {
           id: privateEndpointSubnetId
         }
       }
     }

     // Register the Storage private endpoint in the shared blob zone.
     resource storagePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
       parent: storagePrivateEndpoint
       name: 'default'
       properties: {
         privateDnsZoneConfigs: [
           {
             name: 'blob'
             properties: {
               privateDnsZoneId: privateDnsZoneIds.blob
             }
           }
         ]
       }
     }

     // Private endpoint for private App Service access.
     resource appServicePrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
       name: '${appServiceName}-pe'
       location: location
       properties: {
         privateLinkServiceConnections: [
           {
             name: 'appservice'
             properties: {
               privateLinkServiceId: appServiceId
               groupIds: [
                 'sites'
               ]
             }
           }
         ]
         subnet: {
           id: privateEndpointSubnetId
         }
       }
     }

     // Register the App Service private endpoint in the shared sites zone.
     resource appServicePrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
       parent: appServicePrivateEndpoint
       name: 'default'
       properties: {
         privateDnsZoneConfigs: [
           {
             name: 'appservice'
             properties: {
               privateDnsZoneId: privateDnsZoneIds.sites
             }
           }
         ]
       }
     }

     // Private endpoint for Key Vault secret access.
     resource keyVaultPrivateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
       name: '${keyVaultName}-pe'
       location: location
       properties: {
         privateLinkServiceConnections: [
           {
             name: 'vault'
             properties: {
               privateLinkServiceId: keyVaultId
               groupIds: [
                 'vault'
               ]
             }
           }
         ]
         subnet: {
           id: privateEndpointSubnetId
         }
       }
     }

     // Register the Key Vault private endpoint in the shared vault zone.
     resource keyVaultPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
       parent: keyVaultPrivateEndpoint
       name: 'default'
       properties: {
         privateDnsZoneConfigs: [
           {
             name: 'vault'
             properties: {
               privateDnsZoneId: privateDnsZoneIds.vault
             }
           }
         ]
       }
     }

     output storagePrivateEndpointId string = storagePrivateEndpoint.id
     output appServicePrivateEndpointId string = appServicePrivateEndpoint.id
     output keyVaultPrivateEndpointId string = keyVaultPrivateEndpoint.id
     ```

- [ ] **Step 4: Create `modules/regionStamp.bicep`**

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
    }
  }

  module hubNetwork 'hubNetwork.bicep' = {
    name: 'hub-network'
    params: {
      location: location
      vnetName: names.hubVnet
      addressSpace: addressPlan.hubAddressSpace
      firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
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
      allowedOutboundFqdns: allowedOutboundFqdns
      threatIntelMode: isProd ? 'Deny' : 'Alert'
      availabilityZones: availabilityZones
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

- [ ] **Step 5: Replace `main.bicep` entirely**

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

  @description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

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
  ```

- [ ] **Step 6: Parameter files**

  Replace `params/dev.bicepparam`:

  ```bicep
  using '../main.bicep'

  // Non-secret dev parameters: primary region only (rg-defenstack-dev-global, rg-defenstack-dev-wus3).
  // Secret values go in a git-ignored *.local.bicepparam overlay, never here.
  param environmentName = 'dev'
  param deploySecondaryRegion = false
  param primaryAddressPlan = {
    hubAddressSpace: [
      '10.21.0.0/16'
    ]
    firewallSubnetPrefix: '10.21.0.0/26'
    spokeAddressSpace: [
      '10.20.0.0/16'
    ]
    privateEndpointSubnetPrefix: '10.20.1.0/24'
    appServiceIntegrationSubnetPrefix: '10.20.2.0/24'
    managementSubnetPrefix: '10.20.3.0/24'
  }
  param allowedOutboundFqdns = []
  ```

  Create `params/prod.bicepparam`:

  ```bicep
  using '../main.bicep'

  // Non-secret prod parameters: West US 3 active, East US warm standby
  // (rg-defenstack-prod-global, rg-defenstack-prod-wus3, rg-defenstack-prod-eus).
  // Secret values go in a git-ignored *.local.bicepparam overlay, never here.
  param environmentName = 'prod'
  param deploySecondaryRegion = true
  param primaryAddressPlan = {
    hubAddressSpace: [
      '10.1.0.0/16'
    ]
    firewallSubnetPrefix: '10.1.0.0/26'
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
    spokeAddressSpace: [
      '10.10.0.0/16'
    ]
    privateEndpointSubnetPrefix: '10.10.1.0/24'
    appServiceIntegrationSubnetPrefix: '10.10.2.0/24'
    managementSubnetPrefix: '10.10.3.0/24'
  }
  param allowedOutboundFqdns = []
  ```

- [ ] **Step 7: Rebuild and run the full suite**

  Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected: all pass, including lint of all 16 `.bicep` files and the `main.json` drift test. Then run `bicep build-params params/prod.bicepparam --stdout` and confirm exit code 0.

- [ ] **Step 8: Commit**

  ```bash
  git add modules/ main.bicep main.json params/ tests/
  git commit -m "feat: subscription-scope entry point with global layer and per-region stamps (WUS3 primary, EUS standby)" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 4: PSRule baseline for the multi-region layout

**Files:**
- Modify: `ps-rule.yaml`, `docs/runbooks/00-pipeline-and-identity.md` (§8 PSRule baseline table)
- Create: `.ps-rule/Suppression.Rule.yaml`, `docs/decisions/ADR-008-warm-standby-and-dev-single-region.md`

**Interfaces:**
- Consumes: the resource names from Task 3 (`asp-defenstack-dev-wus3`, `asp-defenstack-prod-eus`, `log-defenstack-dev`, `afwp-defenstack-dev-wus3`).
- Produces:
  - PSRule exclusions shrink to the rules that are still global.
  - By-design gaps are suppressed **per target**, so prod primary stays enforced.

- [ ] **Step 1: Confirm the current failures**

  Remove these five exclude lines and their comment lines from `ps-rule.yaml`: `Azure.Log.Replication`, `Azure.PublicIP.AvailabilityZone`, `Azure.Firewall.AvailabilityZone`, `Azure.AppService.PlanInstanceCount`, `Azure.AppService.AvailabilityZone`. Also remove `Azure.Firewall.PolicyMode` and its comment. Then run:

  ```powershell
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Install-Module -Name PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force
  $env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source
  Invoke-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error |
    ForEach-Object { '{0} | {1}' -f $_.RuleName, $_.TargetName } | Sort-Object -Unique
  ```

  Expected (verified during planning), exactly these six lines:

  ```
  Azure.AppService.AvailabilityZone | asp-defenstack-dev-wus3
  Azure.AppService.AvailabilityZone | asp-defenstack-prod-eus
  Azure.AppService.PlanInstanceCount | asp-defenstack-dev-wus3
  Azure.AppService.PlanInstanceCount | asp-defenstack-prod-eus
  Azure.Firewall.PolicyMode | afwp-defenstack-dev-wus3
  Azure.Log.Replication | log-defenstack-dev
  ```

  The prod primary resources (`asp-defenstack-prod-wus3`, `log-defenstack-prod`, `afwp-defenstack-prod-*`) and all public IPs and firewalls now **pass**. This proves Phase 1 resolved those rules. If the output differs, stop and report it.

- [ ] **Step 2: Write the final `ps-rule.yaml`**

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

  rule:
    # Exclusions apply to every environment and target. Each must name the phase that resolves it or
    # the ADR that accepts it. Gaps that apply only to some targets (dev, the East US warm standby)
    # are suppressed per target in .ps-rule/Suppression.Rule.yaml instead.
    exclude:
      # Phase 5: storage moves to RA-GZRS.
      - Azure.Storage.UseReplication
      # Phase 3: NSG lateral-movement (SSH/RDP) outbound rules land with the Bastion/VPN/jump-host admin access redesign.
      - Azure.NSG.LateralTraversal
      # ADR-002: no organization-wide tagging convention exists yet.
      - Azure.Resource.UseTags
      # ADR-004: zero-trust default-deny-all-inbound is the intended design for these NSGs.
      - Azure.NSG.DenyAllInbound
      # ADR-005: the VNet DNS proxy points at Azure Firewall's single private IP by design.
      - Azure.VNET.SingleDNS
      # ADR-006: no application code is deployed yet, so no dedicated health endpoint exists.
      - Azure.AppService.WebProbePath
  ```

- [ ] **Step 3: Create `.ps-rule/Suppression.Rule.yaml`**

  PSRule loads `.ps-rule/` automatically.

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
  ```

- [ ] **Step 4: Verify zero failures**

  Run the Step 1 `Invoke-PSRule` command again, then `Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error`.

  Expected: no failures; the three suppression groups are reported as applied.

  Also prove the suppressions are scoped: temporarily change `asp-defenstack-prod-eus` in the suppression file to a nonexistent name, re-run, and see `asp-defenstack-prod-eus` fail. Then revert.

- [ ] **Step 5: Write ADR-008**

  Create `docs/decisions/ADR-008-warm-standby-and-dev-single-region.md` with sections Context / Decision / Consequences / Revisit when.

  **Context:**
  - Spec §1 calls for an active/passive DR design: West US 3 active, East US warm.
  - The user chose to run dev in the primary region only.

  **Decision:**
  - Prod EUS runs a warm standby: firewall, 1-instance P-v3 App Service, Key Vault, storage and private endpoints are always deployed. Bastion and VPN come later, behind a flag, in Phase 3.
  - Prod WUS3 runs a zone-redundant 3-instance plan.
  - Dev runs WUS3 only, with S1 and 1 instance.
  - The prod workspace replicates to EUS; the dev workspace does not.
  - PSRule failures that follow from these choices are suppressed **only for those named targets** (`.ps-rule/Suppression.Rule.yaml`).

  **Consequences:**
  - Failover to EUS needs a scale-out: EUS runs 1 instance on a non-zonal plan until scaled.
  - Dev cannot rehearse failover.
  - Cost is roughly one firewall less in dev.

  **Revisit when:** the RTO target requires hot standby, or the DR drill (Phase 8) shows that scale-out time breaks the RTO.

- [ ] **Step 6: Update runbook 00 §8**

  Replace the PSRule baseline table with one row per remaining exclusion and one row per suppression group. Give each row its classification and phase or ADR. State that exclusions apply to every environment, while suppression groups apply only to their named targets.

- [ ] **Step 7: Run the full suite and commit**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1` (all pass).

  ```bash
  git add ps-rule.yaml .ps-rule/Suppression.Rule.yaml docs/decisions/ADR-008-warm-standby-and-dev-single-region.md docs/runbooks/00-pipeline-and-identity.md
  git commit -m "ci: per-target PSRule suppressions for warm standby and dev; drop exclusions resolved by Phase 1" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 5: Subscription-scope pipeline and hardened deployment identity

**Files:**
- Modify: `scripts/New-GitHubDeploymentIdentity.ps1` (full replacement), `tests/Scripts.Tests.ps1` (full replacement), `.github/workflows/bicep-ci.yml`, `.github/workflows/deploy.yml`, `docs/runbooks/00-pipeline-and-identity.md`, `docs/runbooks/00b-configure-pipeline-credentials.md`
- Create: `tests/Workflows.Tests.ps1`, `docs/decisions/ADR-009-subscription-scope-pipeline-identity.md`

**Interfaces:**
- Consumes: the resource group names from Task 3.
- Produces script params:
  - `-ResourceGroupNames string[]` (**replaces** `-ResourceGroupName`), `-GitHubRepository`, `-EnvironmentName`, `[-SubscriptionId]`, `[-DisplayName]` (validated), `[-DelegatableRoleDefinitionIds]` (GUIDs; Owner, UAA, RBAC Admin and Contributor are refused), `[-GrantLockManagement]`, `[-RoleReplicationWaitSeconds]`.
- Produces script output: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. **`AZURE_RESOURCE_GROUP` is removed.**
- Produces roles:
  - custom role `DefenStack Subscription Deployment Operator`, at subscription scope;
  - `Contributor` and constrained `Role Based Access Control Administrator` on each listed resource group;
  - `DefenStack Resource Lock Operator` on each resource group, only with `-GrantLockManagement`.

- [ ] **Step 1: Write the failing tests**

  Replace `tests/Scripts.Tests.ps1` entirely:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $scriptPath = Get-RepoPath 'scripts/New-GitHubDeploymentIdentity.ps1'
      $resourceGroups = @('rg-defenstack-dev-global', 'rg-defenstack-dev-wus3')

      # Shadows the Azure CLI for one test. $Responses maps a -like pattern (matched against the joined
      # arguments, first match wins) to the value to return; every call is recorded in $global:AzCalls.
      function Set-AzShadow([System.Collections.Specialized.OrderedDictionary]$Responses) {
          $global:AzCalls = [System.Collections.Generic.List[string]]::new()
          $global:AzResponses = $Responses
          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              $global:LASTEXITCODE = 0
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
  }

  AfterAll {
      Remove-Variable -Name AzCalls -Scope Global -ErrorAction SilentlyContinue
  }
  ```

  Create `tests/Workflows.Tests.ps1`:

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
  ```

- [ ] **Step 2: Run them to confirm they fail**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/Scripts.Tests.ps1, tests/Workflows.Tests.ps1"`

  Expected: FAIL.
  - Scripts: `-ResourceGroupNames` is an unknown parameter; privileged role IDs are accepted; no subscription deployment role.
  - Workflows: `az deployment group` / `AZURE_RESOURCE_GROUP` are still present, and there is no prod option.

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
  $credentialName = "github-$EnvironmentName"
  $subject = "repo:${GitHubRepository}:environment:$EnvironmentName"

  Write-Host "Application: $DisplayName"
  Write-Host "Federated subject: $subject"
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

  # 3. Federated credential bound to the GitHub environment; an existing one must have the same subject.
  $existingSubject = $null
  if ($appId -ne '<new-application-id>') {
      $existingSubject = az ad app federated-credential list --id $appId --query "[?name=='$credentialName'].subject" --output tsv
  }
  if (-not [string]::IsNullOrWhiteSpace($existingSubject)) {
      if ($existingSubject -ne $subject) {
          throw "Federated credential '$credentialName' exists with subject '$existingSubject', expected '$subject'. Delete it (az ad app federated-credential delete --id $appId --federated-credential-id $credentialName) and re-run."
      }
      Write-Host "Federated credential '$credentialName' already present."
  }
  elseif ($PSCmdlet.ShouldProcess($subject, 'Create federated credential')) {
      $credentialFile = New-TemporaryFile
      try {
          @{
              name        = $credentialName
              issuer      = 'https://token.actions.githubusercontent.com'
              subject     = $subject
              audiences   = @('api://AzureADTokenExchange')
              description = "GitHub Actions environment '$EnvironmentName' for $GitHubRepository"
          } | ConvertTo-Json | Set-Content -Path $credentialFile -Encoding ASCII

          az ad app federated-credential create --id $appId --parameters "@$credentialFile" --output none
          if ($LASTEXITCODE -ne 0) { throw 'Failed to create the federated credential.' }
      }
      finally {
          Remove-Item $credentialFile -Force
      }
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
  Set-CustomRole -Name $deploymentRoleName -Description 'Run subscription-scope ARM deployments (validate, what-if, create) and read resource groups. Grants no resource permissions.' -Actions @(
      'Microsoft.Resources/deployments/read',
      'Microsoft.Resources/deployments/write',
      'Microsoft.Resources/deployments/delete',
      'Microsoft.Resources/deployments/cancel/action',
      'Microsoft.Resources/deployments/validate/action',
      'Microsoft.Resources/deployments/whatIf/action',
      'Microsoft.Resources/deployments/exportTemplate/action',
      'Microsoft.Resources/deployments/operations/read',
      'Microsoft.Resources/deployments/operationstatuses/read',
      'Microsoft.Resources/subscriptions/read',
      'Microsoft.Resources/subscriptions/resourceGroups/read'
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
  Write-Host "Create these variables on the GitHub environment '$EnvironmentName' (Settings > Environments), or run:"
  foreach ($property in $result.PSObject.Properties) {
      Write-Host "gh variable set $($property.Name) --env $EnvironmentName --repo $GitHubRepository --body '$($property.Value)'"
  }

  $result
  ```

- [ ] **Step 4: Update `.github/workflows/bicep-ci.yml`**

  1. In the top-level `env:` block, add `DEPLOYMENT_LOCATION: westus3` under `BICEP_VERSION`.
  2. Replace the `What-if against dev` step's `run:` block with:

  ```yaml
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
  ```

- [ ] **Step 5: Update `.github/workflows/deploy.yml`**

  1. Set the `workflow_dispatch` input: `description: Target environment`; `options: [dev, prod]`.
  2. In `env:`, add `DEPLOYMENT_LOCATION: westus3`.
  3. Replace the `Validate`, `What-if` and `Deploy` steps with:

  ```yaml
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

        - name: Deploy
          run: |
            az deployment sub create \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --output table
  ```

  4. Keep `if: github.ref == 'refs/heads/main'` and the per-environment `environment:` / `concurrency`.

  Prod safety comes from the GitHub `prod` environment's **required reviewers** and **main-only deployment branch** policy (runbook 00b §5).

- [ ] **Step 6: Run the tests to confirm they pass**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected: all pass. Also parse both workflow files as YAML (the `powershell-yaml` module, if installed: `ConvertFrom-Yaml (Get-Content -Raw …)`) and report the result.

- [ ] **Step 7: ADR-009 and runbook updates**

  **ADR-009** (`docs/decisions/ADR-009-subscription-scope-pipeline-identity.md`), with Context / Decision / Consequences / Revisit when.

  - **Decision:**
    - Operators pre-create the resource groups (runbook 01), and templates reference them with `resourceGroup(name)`.
    - Each environment has its own app registration and federated credential.
    - At subscription scope, the pipeline identity holds only the custom **DefenStack Subscription Deployment Operator** role: deployment read, write, delete, cancel, validate, whatIf, exportTemplate and operations; subscription and resource-group read.
    - Resource rights (`Contributor` plus ABAC-constrained RBAC Administrator) are granted **only on that environment's resource groups**.
  - **Consequences:**
    - The dev identity can create *deployment records* anywhere in the subscription, because `deployments/write` is inherited. It cannot create or change resources outside its resource groups, since every nested resource write needs resource-group rights.
    - Resource groups must exist before the first deploy.
    - Contributor at subscription scope is deliberately **not** used, because dev and prod share the subscription.

  **Runbook 00 and 00b:**
  - Replace every `-ResourceGroupName defenStack` with `-ResourceGroupNames 'rg-defenstack-dev-global','rg-defenstack-dev-wus3'`.
  - Remove `AZURE_RESOURCE_GROUP` from the variable tables, Step 4 and the validation rows. Add a note: *delete the old `AZURE_RESOURCE_GROUP` variable from the `dev` environment*.
  - The Step 3 role query now lists `DefenStack Subscription Deployment Operator` at `/subscriptions/<sub>`. It also lists `Contributor` and `Role Based Access Control Administrator` (with a condition) on **each** of the two dev resource groups. Nothing else is expected.
  - The Method B (portal) instructions add a step to create the custom role. List the eleven actions from the script. Then assign it at subscription scope.
  - Add the **prod** procedure to 00b §5:
    1. Create `rg-defenstack-prod-global`, `rg-defenstack-prod-wus3` and `rg-defenstack-prod-eus` (runbook 01 §4 step 2).
    2. Run the script with `-EnvironmentName prod -ResourceGroupNames 'rg-defenstack-prod-global','rg-defenstack-prod-wus3','rg-defenstack-prod-eus' -GrantLockManagement`.
    3. Create GitHub environment `prod` with **Required reviewers** (at least 1) and **Deployment branches: Selected branches → `main`**.
    4. Add the three `AZURE_*` variables to `prod`.
  - Add §9 troubleshooting rows:
    - `AuthorizationFailed … Microsoft.Resources/deployments/write … /subscriptions/<id>` → the subscription deployment role is missing.
    - `ResourceGroupNotFound` → the resource group was not pre-created.
    - `Role definition 'DefenStack Subscription Deployment Operator' not found` on first run → role replication; the script retries 6 × `RoleReplicationWaitSeconds`.
    - `privileged and cannot be delegated` → by design.

- [ ] **Step 8: Run the full suite and commit**

  ```bash
  git add scripts/New-GitHubDeploymentIdentity.ps1 tests/Scripts.Tests.ps1 tests/Workflows.Tests.ps1 .github/workflows/ docs/decisions/ADR-009-subscription-scope-pipeline-identity.md docs/runbooks/00-pipeline-and-identity.md docs/runbooks/00b-configure-pipeline-credentials.md
  git commit -m "ci: subscription-scope deployments with least-privilege identity per environment; add prod" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 6: Architecture overview, deploy runbook, migration runbook, cost and README

**Files:**
- Create: `docs/architecture/overview.md`, `docs/runbooks/01-deploy-stack.md`, `docs/runbooks/01a-migrate-from-defenstack.md`
- Modify: `docs/cost.md`, `README.md`

**Interfaces:** none produced. This task documents Tasks 1–5.

- [ ] **Step 1: Add a docs test (TDD for documentation)**

  Create `tests/Docs.Tests.ps1`:

  ```powershell
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
  ```

  Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Docs.Tests.ps1`.

  Expected: 3 `exists` failures (overview, 01, 01a), plus the template and mermaid failures. ADR-008 and ADR-009 already exist from Tasks 4–5.

- [ ] **Step 2: `docs/architecture/overview.md`**

  It must contain:
  1. **Purpose and status.** What exists after Phase 1; which components later phases add (Firewall Premium P2, Bastion/VPN P3, Front Door P4, …).
  2. **Topology** as a ```` ```mermaid ```` `flowchart`. Show:
     - subscription → `rg-defenstack-<env>-global`: workspace `log-defenstack-<env>`, the three `privatelink.*` zones;
     - `rg-defenstack-<env>-wus3`: hub VNet with `AzureFirewallSubnet` and firewall `afw-…`; spoke VNet with the `private-endpoints`, `appservice-integration` and `management` subnets; App Service, Key Vault and storage with their private endpoints;
     - `rg-defenstack-prod-eus`: the same shape, marked "prod only, warm standby";
     - hub↔spoke peering; spoke DNS → firewall DNS proxy → the zones linked to every hub and spoke;
     - workspace replication WUS3 → EUS (prod).
  3. **Traffic flows:** a short mermaid `sequenceDiagram` for each of:
     - egress: App Service → UDR 0/0 → firewall → allowlisted FQDN;
     - private endpoint access: App Service → PE subnet (NSG allows `appservice-integration` and `management` prefixes only);
     - DNS resolution: client → firewall DNS proxy (VNet DNS) → Azure DNS → linked private zone;
     - ingress: none yet. The app is private-only until Phase 4 Front Door.
  4. **Address plan table:** env, region, hub, firewall subnet, spoke, the three subnets, and reserved Bastion/Gateway ranges, copied from Global Constraints.
  5. **Naming convention table:** one row per `names.*` key in `regionStamp.bicep`, plus the resource group, workspace and zone names. Include example values for dev WUS3.
  6. **Resource inventory per resource group,** by environment.
  7. **Design decisions:** links to ADR-003…ADR-009.

- [ ] **Step 3: `docs/runbooks/01-deploy-stack.md`**

  Use the 9-section template.

  - **§2 Prerequisites:**
    - Roles: subscription `Owner` or `User Access Administrator` for the one-time identity setup; `Contributor` to create resource groups.
    - Register the providers `Microsoft.Network`, `Microsoft.Web`, `Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`, `Microsoft.Insights` with `az provider register --namespace <ns>`, then verify with `az provider show -n <ns> --query registrationState -o tsv` (expect `Registered`).
    - The EncryptionAtHost feature, only if a VM is enabled (copy from 00a §2).
  - **§3 Parameters:** every `main.bicep` parameter with its dev and prod values.
  - **§4 Step-by-step:**
    1. `az account set --subscription <id>`.
    2. Create the resource groups (dev: global and wus3; prod: global, wus3 and eus). The global resource group lives in `westus3`:

       ```powershell
       $env = 'dev'   # or 'prod'
       az group create -n "rg-defenstack-$env-global" -l westus3 -o table
       az group create -n "rg-defenstack-$env-wus3" -l westus3 -o table
       if ($env -eq 'prod') { az group create -n 'rg-defenstack-prod-eus' -l eastus -o table }
       ```

    3. Run runbook 00b for the environment's identity (`-ResourceGroupNames` as listed there).
    4. `az deployment sub validate --location westus3 --parameters params/<env>.bicepparam -o table` (expect `Succeeded`).
    5. `az deployment sub what-if --location westus3 --parameters params/<env>.bicepparam`. Expect only `+ Create` for a new environment. **Stop** on any `Delete`, or on any change in `defenStack`.
    6. Deploy with `az deployment sub create --location westus3 --name "manual-$(Get-Date -Format yyyyMMddHHmm)" --parameters params/<env>.bicepparam -o table`, or merge to `main` for dev / run `deploy` with `environment=prod`.
    7. Run the budget script once per new resource group (`scripts/Set-AzureResourceGroupBudget.ps1`).
  - **§6 Validation,** with commands and expected results:
    - Firewall zones: `az network firewall show -g rg-defenstack-<env>-wus3 -n afw-defenstack-<env>-wus3 --query zones -o tsv` → `1 2 3`.
    - App Service plan (prod WUS3): `az appservice plan show -g rg-defenstack-prod-wus3 -n asp-defenstack-prod-wus3 --query "{zr:zoneRedundant,capacity:sku.capacity}"` → `true`, `3`.
    - DNS links: `az network private-dns link vnet list -g rg-defenstack-<env>-global -z privatelink.vaultcore.azure.net --query "[].name" -o tsv` → the hub and spoke link of every stamp (dev 2, prod 4).
    - Peering: `az network vnet peering list -g rg-defenstack-<env>-wus3 --vnet-name vnet-defenstack-<env>-wus3-hub --query "[].peeringState" -o tsv` → `Connected`.
    - Workspace replication (prod): `az monitor log-analytics workspace show -g rg-defenstack-prod-global -n log-defenstack-prod --query replication` → `enabled: true, location: eastus`.
    - Private endpoint records: `az network private-dns record-set a list -g rg-defenstack-<env>-global -z privatelink.vaultcore.azure.net --query "[].name" -o tsv` → one record per stamp's vault.
  - **§7 Rollback:**
    - New environment: delete the new resource groups. Prod needs the locks removed first: `az lock list -g <rg>`, then `az lock delete --ids`.
    - Key Vault soft delete and purge protection keep the names reserved for 90 days. Use a new `environmentName` suffix only if you must redeploy immediately.
  - **§8 Operations:**
    - To scale EUS for failover: `az appservice plan update -g rg-defenstack-prod-eus -n asp-defenstack-prod-eus --number-of-workers 3` (full DR runbook in Phase 8).
    - Add egress FQDNs through `allowedOutboundFqdns` in the parameter file and deploy.
  - **§9 Troubleshooting:**
    - `ResourceGroupNotFound`;
    - `The template parameter 'secondaryAddressPlan' is null` → prod needs `secondaryAddressPlan`;
    - Key Vault name conflict from soft delete: `az keyvault list-deleted`;
    - zone-redundant plan quota: `az appservice list-locations --sku P2V3`.

- [ ] **Step 4: `docs/runbooks/01a-migrate-from-defenstack.md`**

  Use the 9-section template. Procedure:
  1. Deploy the new dev stack (runbook 01) alongside `defenStack`. They don't conflict: they use different address ranges and names.
  2. **Inventory data in `defenStack`** from the management plane only; `defenStack` has no private admin path yet.
     - Storage `UsedCapacity`:

       ```powershell
       az monitor metrics list --resource <storage-id> --metric UsedCapacity --interval PT1H --query "value[0].timeseries[0].data[-1].average"
       ```

     - Key Vault secret count (names only): not possible through the management plane when the vault is private. Record the only secret known from Phase 0 (`phase0-reference-test`, test data).
     - App Service: `az webapp deployment list-publishing-profiles` must **not** be used. Confirm whether application code was deployed with `az webapp show --query "state"` and team knowledge.
  3. **Decide:** if storage `UsedCapacity` < 1 MiB and no app code was deployed, there is nothing to migrate; continue. Otherwise **stop teardown**, and migrate after Phase 3 provides a private admin path. Data-plane copy then uses `azcopy copy` between the two private accounts from the jump host, and secrets are copied with `az keyvault secret show/set` from the jump host.
  4. **Move the pipeline:**
     1. Run runbook 00b again with `-ResourceGroupNames 'rg-defenstack-dev-global','rg-defenstack-dev-wus3'`. The same app registration is reused.
     2. Delete the `AZURE_RESOURCE_GROUP` variable from GitHub `dev`.
     3. Remove the identity's old `defenStack` assignments:

        ```powershell
        az role assignment list --assignee <sp-id> --resource-group defenStack --query "[].id" -o tsv | % { az role assignment delete --ids $_ }
        ```

  5. Validate the new stack with runbook 01 §6.
  6. **Tear down `defenStack`** using the README's existing "Safe teardown" section, in order. Then delete the resource-group budget (`az consumption budget delete -g defenStack -n defenstack-monthly`).
  7. Record the migration in the runbook's execution record.

  - **§7 Rollback:** before step 6, re-add the `defenStack` role assignments by re-running the Phase 0 script version (`git show phase0-foundation-fixes:scripts/New-GitHubDeploymentIdentity.ps1 > $env:TEMP/old.ps1`). After step 6 there is no rollback; say so explicitly.

- [ ] **Step 5: `docs/cost.md`**

  Add a "Phase 1 delta" section with these drivers, and "fill from the Pricing Calculator; do not invent prices":
  - **Dev:** Firewall Standard ×1 (unchanged count; now zonal, which adds inter-zone data processing); S1 ×1.
  - **Prod:** Firewall Standard ×2; P2V3 ×3 (WUS3, zone-redundant) + P2V3 ×1 (EUS); GRS storage ×2; Key Vault ×2; private endpoints ×6; workspace replication (charged per GB replicated); cross-region replication traffic.
  - **Retired after migration:** `defenStack`'s firewall and plan.

  Keep the existing measurement queries.

- [ ] **Step 6: `README.md`**

  1. Rewrite the opening paragraph and "Module layout" for the new structure: `main.bicep` (subscription scope), `modules/global.bicep`, `modules/regionStamp.bicep`, `modules/privateDnsZoneLinks.bicep`, `modules/types.bicep`, and the existing modules as stamp building blocks.
  2. In "Validate against Azure", replace every `az deployment group validate|what-if|create --resource-group …` example with the `az deployment sub … --location westus3 --parameters params/<env>.bicepparam` form. The VM-enabled examples use a `*.local.bicepparam` overlay that sets `enableVirtualMachine = true` and the VM parameters.
  3. Remove the sentence "Use `environmentType=prod` for the Premium V3 App Service plan…". Replace it with: "Use `params/prod.bicepparam` for the two-region prod stack (Premium V3, zone-redundant primary)."
  4. Add runbooks 01 and 01a and `docs/architecture/overview.md` to the Documentation list.
  5. The "Safe teardown" section stays; add at its top: "Applies to the legacy `defenStack` resource group (see runbook 01a). For the Phase 1 stacks, see runbook 01 §7."

- [ ] **Step 7: Run the full suite and commit**

  Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1` (all pass, including the docs test).

  ```bash
  git add docs/architecture/overview.md docs/runbooks/01-deploy-stack.md docs/runbooks/01a-migrate-from-defenstack.md docs/cost.md README.md tests/Docs.Tests.ps1
  git commit -m "docs: architecture overview, deploy and migration runbooks, Phase 1 cost and README" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

## Deferred live steps (operator, after merge of Phase 0 and review of this PR)

1. Runbook 01 §4 for **dev**: create the resource groups; runbook 00b with the new resource-group list; validate, what-if, deploy; §6 validation.
2. Runbook 01a: migrate from and tear down `defenStack`.
3. Runbook 01 §4 for **prod**, including the GitHub `prod` environment with reviewers and main-only branches.
4. Paste the validation outputs into the PR.

## Self-review

- **Spec coverage (§4/§5 Phase 1):**

  | Spec item | Task |
  |---|---|
  | Subscription scope | 3 |
  | `global.bicep` | 2 |
  | `regionStamp.bicep` ×2 | 3 |
  | Address plan | 3 (param files + tests) |
  | Param files | 3 |
  | Architecture overview, deploy and migration runbooks | 6 |
  | `privateConnectivity` stops creating zones | 3 |
  | Budget per resource group | 6 (runbook 01 §4.7) |

- **Phase 0 carry-forwards:**

  | Carry-forward | Task |
  |---|---|
  | Zones on | 3 |
  | App Service zone redundancy in prod | 3 |
  | Plan rename | 3 |
  | Management subnet rename | 3 |
  | Prod identity | 5 |
  | PSRule per-environment scoping | 4 |
  | Identity hardening (privileged-role refusal, DisplayName validation, exit code, credential subject check, lock-role replication retry, exact ABAC test) | 5 |
  | Lint regex | 1 |
  | Windows DCR test | 1 |
  | `Azure.Log.Replication` attribution confirmed and resolved | 2, 4 |

- **Deliberately not in Phase 1 (per spec phases):**

  | Item | Phase |
  |---|---|
  | Parent firewall policy / Premium | 2 |
  | Bastion / VPN / `deployAdminAccess` flag / GatewaySubnet route table | 3 |
  | Front Door | 4 |
  | RA-GZRS storage / App Insights | 5 |
  | AMPLS / alerts / Sentinel | 6 |
  | Defender / Policy | 7 |
  | Recovery vaults / hub↔hub peering | 8 |

- **Names used consistently across tasks:**
  - symbols `global`, `primaryStamp`, `secondaryStamp`, `privateDnsLinks`;
  - types `regionAddressPlan`, `privateDnsZoneSet`, `virtualNetworkReference`;
  - outputs `privateDnsZoneIds`, `logAnalyticsWorkspaceId`, `hubVnetName`/`hubVnetId`/`spokeVnetName`/`spokeVnetId`;
  - role `DefenStack Subscription Deployment Operator`.
