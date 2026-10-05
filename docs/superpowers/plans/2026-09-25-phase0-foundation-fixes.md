# Phase 0: Foundation Fixes, Tests, and CI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix review defects F1–F13 from the spec in place, add a template test harness and linter policy, and add GitHub Actions CI/CD with OIDC. Every change ships with step-by-step runbooks.

**Architecture:** The existing resource-group-scoped modules are fixed in place. Tests compile each Bicep file to ARM JSON (`bicep build --stdout`) and assert properties with Pester 5. CI runs those tests, PSRule for Azure, and a what-if posted to the PR. Deployment uses an Entra app with a GitHub-environment federated credential, so no stored secrets are needed.

**Tech Stack:** Bicep CLI 0.47.16, Azure CLI 2.90+, PowerShell (Windows PowerShell 5.1 locally, pwsh 7 in CI), Pester 5.5+, PSRule.Rules.Azure, GitHub Actions (`azure/login@v2`).

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` (§2 findings F1–F13, §5 Phase 0, §6 documentation standard).

## Global Constraints

- **In-place safety:** every Phase 0 change must be safe to redeploy onto the existing `defenStack` resource group (treated as **dev**). These greenfield-only changes are deferred to Phase 1:
  - Availability zones actually enabled.
  - App Service plan rename or zone redundancy on.
  - `virtual-machines` → `management` subnet rename.
  - Subscription scope.
- **API versions:** do not change existing resource API versions. The README's API version policy applies. New resource types use the versions given in this plan; each one has been compiled against Bicep 0.47.16.
- **Secrets:** no secrets in `.bicep`, `.bicepparam` (committed), `main.json`, outputs, workflow files, or command history.
- **main.json is generated:** every task that edits any `.bicep` file must run `bicep build main.bicep` and commit `main.json`. The drift test from Task 1 enforces this.
- **Docs are mandatory:** every task updates `docs/runbooks/00a-apply-phase0-fixes.md` (or `00-pipeline-and-identity.md`) using the section structure from `docs/runbooks/_template.md`. A task is not complete without its doc changes.
- **Tests run on both shells:**
  - `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1` (Windows PowerShell 5.1).
  - `pwsh ./tests/Invoke-Tests.ps1` (PowerShell 7).
- **Git:** work on branch `phase0-foundation-fixes`, created from `docs/secure-connectivity-design`. Every commit message ends with:
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`
- **Shell note:** in Bicep strings a literal backslash is written `\\` (e.g. `'Processor(*)\\% Processor Time'`).

## File Map

| File | Responsibility | Tasks |
|---|---|---|
| `bicepconfig.json` (new) | Linter policy; security rules at error level | 1 |
| `.gitignore` (new) | Ignore secret param overlays and tool output | 1 |
| `tests/Bicep.TestHelpers.psm1` (new) | Compile Bicep → JSON; resource and module lookup helpers | 1 |
| `tests/Invoke-Tests.ps1` (new) | Pester 5 bootstrap and runner (local + CI) | 1 |
| `tests/Lint.Tests.ps1` (new) | Lint every `.bicep`, config assertions, `main.json` drift | 1 |
| `tests/SpokeNetwork.Tests.ps1` (new) | F1/F2 routing and NSG isolation | 2 |
| `tests/Main.Tests.ps1` (new) | Wiring assertions on `main.bicep` | 2,3,4,6,8 |
| `tests/AzureFirewall.Tests.ps1` (new) | F9 and the AzureMonitor egress rule | 4 |
| `tests/VirtualMachine.Tests.ps1` (new) | F3 AMA/DCR, management NSG parameter | 2,5 |
| `tests/KeyVault.Tests.ps1` (new) | F4/F12 | 6 |
| `tests/Storage.Tests.ps1` (new) | F6/F7 | 7 |
| `tests/NetworkIntegration.Tests.ps1` (new) | F11 | 8 |
| `tests/AppService.Tests.ps1` (new) | F8 | 9 |
| `tests/Monitoring.Tests.ps1` (new) | F10 | 10 |
| `tests/Params.Tests.ps1` (new) | `.bicepparam` files build | 11 |
| `tests/Scripts.Tests.ps1` (new) | Identity script parse and `-WhatIf` safety | 12 |
| `modules/spokeNetwork.bicep` | Management NSG and route table; BGP propagation off; required PE CIDRs | 2,3 |
| `modules/virtualMachine.bicep` | Management inbound param; AMA + DCR; metrics-only diagnostics | 2,5 |
| `modules/azureFirewall.bicep` | Zones param, threat-intel param, SKU, AzureMonitor rule, dedicated tables | 4 |
| `modules/keyVault.bicep` | `enabledForTemplateDeployment` | 6 |
| `modules/privateConnectivity.bicep` | Key Vault PE output | 6 |
| `modules/storage.bicep` | Blob data protection, blob logs, container output | 7,8 |
| `modules/networkIntegration.bicep` | Container-scoped role assignment | 8 |
| `modules/appService.bicep` | Basic auth off, health check, alwaysOn, SCM TLS, ZR/capacity params | 9 |
| `modules/monitoring.bicep` | 90-day retention | 10 |
| `main.bicep` / `main.json` | Wiring for all of the above | 2–10 |
| `params/dev.bicepparam` (new) | Non-secret dev parameters for CI/PSRule/deploy | 11 |
| `ps-rule.yaml` (new) | PSRule for Azure configuration | 11 |
| `.github/workflows/bicep-ci.yml` (new) | PR/push validation + PR what-if comment | 11 |
| `.github/workflows/deploy.yml` (new) | Gated deployment to dev via OIDC | 12 |
| `scripts/New-GitHubDeploymentIdentity.ps1` (new) | Entra app, federated credential, least-privilege RBAC | 12 |
| `docs/runbooks/_template.md` (new) | Mandatory runbook structure | 1 |
| `docs/runbooks/00a-apply-phase0-fixes.md` (new) | Procedure, validation, rollback for F1–F12 | 1–10,13 |
| `docs/runbooks/00-pipeline-and-identity.md` (new) | OIDC identity, GitHub environments, pipelines | 11,12 |
| `README.md` | Corrections and links to `docs/` | 3,4,5,6,13 |

---

### Task 1: Test harness, linter policy, ignore rules, runbook scaffolding (F13 part 1)

**Files:**
- Create: `tests/Bicep.TestHelpers.psm1`, `tests/Invoke-Tests.ps1`, `tests/Lint.Tests.ps1`
- Create: `bicepconfig.json`, `.gitignore`
- Create: `docs/runbooks/_template.md`, `docs/runbooks/00a-apply-phase0-fixes.md`

**Interfaces:**
- Produces (used by every later test file):
  - `Get-RepoPath -RelativePath <string>` → absolute path string.
  - `Get-BicepTemplate -RelativePath <string>` → compiled ARM template (PSCustomObject); throws if the build fails.
  - `Get-TemplateResource -Template <object> -Type <string>` → array of non-`existing` resources whose `type` matches (case-insensitive). Works for both array and symbolic-name (languageVersion 2.0) templates.
  - `Get-ModuleDeployment -Template <object> -Name <string>` → the `Microsoft.Resources/deployments` resource with that literal name (e.g. `'spoke-network'`); throws if missing.
- Every test file starts with:
  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
  }
  ```

- [ ] **Step 1: Create the branch**

```bash
git checkout docs/secure-connectivity-design
git checkout -b phase0-foundation-fixes
```

- [ ] **Step 2: Write the helper module**

Create `tests/Bicep.TestHelpers.psm1`:

```powershell
Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    Join-Path $script:RepoRoot $RelativePath
}

function Get-BicepTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $json = & bicep build (Get-RepoPath $RelativePath) --stdout
    if ($LASTEXITCODE -ne 0) {
        throw "bicep build failed for $RelativePath"
    }

    ($json -join "`n") | ConvertFrom-Json
}

function Get-TemplateResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Template,

        [Parameter(Mandatory)]
        [string]$Type
    )

    # languageVersion 2.0 templates store resources as an object keyed by symbolic name.
    $resources = if ($Template.resources -is [array]) {
        $Template.resources
    }
    else {
        $Template.resources.PSObject.Properties | ForEach-Object { $_.Value }
    }

    @($resources | Where-Object {
            $isExisting = ($_.PSObject.Properties.Name -contains 'existing') -and $_.existing
            ($_.type -eq $Type) -and -not $isExisting
        })
}

function Get-ModuleDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Template,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $deployment = Get-TemplateResource -Template $Template -Type 'Microsoft.Resources/deployments' |
        Where-Object { $_.name -eq $Name }
    if (-not $deployment) {
        throw "Module deployment '$Name' was not found."
    }

    $deployment
}

Export-ModuleMember -Function Get-RepoPath, Get-BicepTemplate, Get-TemplateResource, Get-ModuleDeployment
```

- [ ] **Step 3: Write the runner**

Create `tests/Invoke-Tests.ps1`:

```powershell
[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Path = @($PSScriptRoot),

    [Parameter()]
    [switch]$CI
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    throw 'Bicep CLI is required on PATH. Install it with "az bicep install" and add its folder to PATH.'
}

$minimumPester = [version]'5.5.0'
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge $minimumPester })) {
    Install-Module -Name Pester -MinimumVersion $minimumPester -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module -Name Pester -MinimumVersion $minimumPester

$configuration = New-PesterConfiguration
$configuration.Run.Path = $Path
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'

if ($CI) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.TestResult.OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test-results.xml'
}

# Native tools write warnings to stderr; Stop would turn those into terminating errors under Windows PowerShell.
$ErrorActionPreference = 'Continue'
Invoke-Pester -Configuration $configuration
```

- [ ] **Step 4: Write the failing lint and config tests**

Create `tests/Lint.Tests.ps1`:

```powershell
BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $bicepFiles = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.bicep' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); FullName = $_.FullName } }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
}

Describe 'Repository linter configuration' {
    It 'has bicepconfig.json at the repository root' {
        Get-RepoPath 'bicepconfig.json' | Should -Exist
    }

    It 'raises security rules to error level' {
        $config = Get-Content (Get-RepoPath 'bicepconfig.json') -Raw | ConvertFrom-Json
        foreach ($rule in 'secure-parameter-default', 'outputs-should-not-contain-secrets', 'use-secure-value-for-secure-inputs', 'no-hardcoded-env-urls', 'secure-secrets-in-params') {
            $config.analyzers.core.rules.$rule.level | Should -Be 'error' -Because "$rule protects secrets and portability"
        }
    }

    It 'ignores local secret parameter overlays' {
        Get-Content (Get-RepoPath '.gitignore') | Should -Contain '*.local.bicepparam'
    }
}

Describe 'Bicep lint' {
    It '<Name> lints without errors' -ForEach $bicepFiles {
        $output = & bicep lint $FullName 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }
}

Describe 'Generated ARM template' {
    It 'main.json matches a fresh build of main.bicep' {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $expected = ((& bicep build (Get-RepoPath 'main.bicep') --stdout) -join "`n").Trim()
        $actual = ((Get-Content (Get-RepoPath 'main.json') -Raw -Encoding UTF8) -replace "`r`n", "`n").Trim()
        $actual | Should -BeExactly $expected -Because 'run "bicep build main.bicep" and commit main.json'
    }
}
```

- [ ] **Step 5: Run the tests to confirm they fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Lint.Tests.ps1`

The first run installs Pester 5 into CurrentUser.

Expected: FAIL on `has bicepconfig.json…`, `raises security rules…` and `ignores local secret parameter overlays`. PASS on every `lints without errors` case and on `main.json matches…`.

- [ ] **Step 6: Add the linter policy and ignore file**

Create `bicepconfig.json`:

```json
{
  "analyzers": {
    "core": {
      "enabled": true,
      "rules": {
        "adminusername-should-not-be-literal": { "level": "error" },
        "no-hardcoded-env-urls": { "level": "error" },
        "outputs-should-not-contain-secrets": { "level": "error" },
        "protect-commandtoexecute-secrets": { "level": "error" },
        "secure-parameter-default": { "level": "error" },
        "secure-params-in-nested-deploy": { "level": "error" },
        "secure-secrets-in-params": { "level": "error" },
        "use-secure-value-for-secure-inputs": { "level": "error" },
        "no-unused-params": { "level": "error" },
        "no-unused-vars": { "level": "error" },
        "no-unused-existing-resources": { "level": "error" },
        "use-parent-property": { "level": "error" },
        "prefer-interpolation": { "level": "error" },
        "simplify-interpolation": { "level": "error" },
        "no-unnecessary-dependson": { "level": "error" },
        "use-stable-resource-identifiers": { "level": "error" },
        "use-recent-api-versions": { "level": "off" }
      }
    }
  }
}
```

`use-recent-api-versions` is off because the README's API version policy governs upgrades. This config was verified to lint the current code with zero errors.

Create `.gitignore`:

```gitignore
# Local parameter overlays that reference or contain secrets. Never commit these.
*.local.bicepparam
*.secrets.bicepparam

# Test and tool output
test-results.xml
whatif.txt
whatif.md
reports/
```

- [ ] **Step 7: Run the tests to confirm they pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Lint.Tests.ps1`
Expected: all PASS.

- [ ] **Step 8: Create the runbook template**

Create `docs/runbooks/_template.md`:

````markdown
# NN - <Component> runbook

> Owning module(s): `modules/<file>.bicep`. Spec section: <link>.

## 1. Purpose and scope
What this runbook deploys or changes, and which resources it creates, modifies, or deletes.

## 2. Prerequisites
- Azure roles (scope and role name) for the operator or pipeline identity.
- Provider or feature registrations (with the `az` command to register and verify).
- Tools and minimum versions (Azure CLI, Bicep CLI, PowerShell, gh).
- Network path required (for example: "must run from P2S VPN or Bastion jump host").

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|

## 4. Step-by-step deployment
Numbered steps. Every command is copy-pasteable PowerShell. Each step says what to check in its output before continuing.

## 5. Manual and post-deployment steps
Anything the template cannot do (approvals, role cleanup, client configuration).

## 6. Validation
| Check | Command | Expected result |
|---|---|---|

## 7. Rollback
Exact steps to return to the previous state, including what cannot be rolled back.

## 8. Operations
Day-2 tasks: rotation, scaling, rule changes, cost drivers.

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
````

- [ ] **Step 9: Create the Phase 0 rollout runbook skeleton**

Create `docs/runbooks/00a-apply-phase0-fixes.md`. Later tasks append subsections under §3, §5, §6, §7 and §9.

````markdown
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

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|

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

## 6. Validation
| Check | Command | Expected result |
|---|---|---|

## 7. Rollback
General rollback: redeploy the last good commit from `main` with the same commands in §4. Per-fix exceptions are listed below.

## 8. Operations
See the per-fix notes in §5.

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
````

- [ ] **Step 10: Commit**

```bash
git add tests/Bicep.TestHelpers.psm1 tests/Invoke-Tests.ps1 tests/Lint.Tests.ps1 bicepconfig.json .gitignore docs/runbooks/_template.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "test: add Bicep template test harness, linter policy, and runbook scaffolding

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Management subnet isolation and forced tunnelling (F1, F2)

**Files:**
- Modify: `modules/spokeNetwork.bicep` (params after line 44, vars lines 46-48, route table lines 110-126, subnets lines 153-160)
- Modify: `modules/virtualMachine.bicep` (params, NSG lines 47-67)
- Modify: `main.bicep` (new param, `spokeNetwork` and `virtualMachine` module params)
- Create: `tests/SpokeNetwork.Tests.ps1`, `tests/Main.Tests.ps1`, `tests/VirtualMachine.Tests.ps1`
- Modify: `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces:
  - `spokeNetwork.bicep` param `managementSourceCidrs array = []`.
  - `virtualMachine.bicep` param `managementSourceCidrs array = []`.
  - `main.bicep` param `managementSourceCidrs array = []`, passed to both modules.
  - Phase 3 will pass the Bastion subnet and P2S pool CIDRs through this param.

- [ ] **Step 1: Write the failing tests**

Create `tests/SpokeNetwork.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/spokeNetwork.bicep'
    $routeTables = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables'
    $vnetModule = Get-TemplateResource -Template $template -Type 'Microsoft.Resources/deployments' | Select-Object -First 1
    # Subnet order in spokeNetwork.bicep: 0 private-endpoints, 1 appservice-integration, 2 virtual-machines.
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
```

Create `tests/VirtualMachine.Tests.ps1`:

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
```

Create `tests/Main.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $main = Get-BicepTemplate -RelativePath 'main.bicep'
}

Describe 'Management access wiring (F1)' {
    It 'passes managementSourceCidrs to <_>' -ForEach 'spoke-network', 'virtual-machine' {
        $deployment = Get-ModuleDeployment -Template $main -Name $_
        $deployment.properties.parameters.managementSourceCidrs.value | Should -Be "[parameters('managementSourceCidrs')]"
    }
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/SpokeNetwork.Tests.ps1, tests/VirtualMachine.Tests.ps1, tests/Main.Tests.ps1"`
Expected: FAIL. There is only 1 route table, `disableBgpRoutePropagation` is `False`, the NSG and UDR IDs are equal, and the `managementSourceCidrs` parameter is missing.

- [ ] **Step 3: Implement in `modules/spokeNetwork.bicep`**

Add after `param enableDeleteLock bool = false`:

```bicep
@description('CIDR ranges allowed to reach management VMs over SSH (22) and RDP (3389), such as AzureBastionSubnet or the P2S VPN client pool. An empty list denies all administrative inbound traffic.')
param managementSourceCidrs array = []
```

Replace the three `var` lines (46-48) with:

```bicep
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
```

In `appServiceRouteTable`, change `disableBgpRoutePropagation: false` to `disableBgpRoutePropagation: true`.

Add after the `appServiceRouteTable` resource:

```bicep
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
```

In the `vnet` module `subnets` array, change the `virtualMachineSubnetName` entry to:

```bicep
      {
        name: virtualMachineSubnetName
        addressPrefix: virtualMachineSubnetAddressPrefix
        nsgId: virtualMachineNsg.id
        udrId: virtualMachineRouteTable.id
        privateEndpointNetworkPolicies: 'Disabled'
        privateLinkServiceNetworkPolicies: 'Enabled'
      }
```

- [ ] **Step 4: Implement in `modules/virtualMachine.bicep`**

Add after `param logAnalyticsWorkspaceId string`:

```bicep
@description('CIDR ranges allowed to reach the VM over SSH (22) and RDP (3389). Must match the management subnet NSG; an empty list denies all administrative inbound traffic.')
param managementSourceCidrs array = []
```

Add after the existing `var networkSecurityGroupName` line:

```bicep
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
```

In `networkSecurityGroup`, replace `securityRules: [ … ]` with `securityRules: concat(managementInboundRules, [ … ])`, keeping the existing `deny-unsolicited-inbound` object unchanged inside the second array.

- [ ] **Step 5: Wire it through `main.bicep`**

Add after the `approvedPrivateEndpointSourceCidrs` param:

```bicep
@description('CIDR ranges allowed to administer management VMs over SSH/RDP, such as AzureBastionSubnet or the P2S client pool. Empty denies all administrative inbound traffic.')
param managementSourceCidrs array = []
```

Add `managementSourceCidrs: managementSourceCidrs` to the `params` of both the `spokeNetwork` and `virtualMachine` modules.

- [ ] **Step 6: Rebuild and run the tests**

Run:

```powershell
bicep build main.bicep
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
```

Expected: all PASS, including the `main.json` drift test and lint.

- [ ] **Step 7: Document F1/F2 in `00a-apply-phase0-fixes.md`**

Append to §3 Parameters table:

```markdown
| `managementSourceCidrs` | `[]` | `[]` until Phase 3 (then AzureBastionSubnet + P2S pool) | Only named admin sources may reach SSH/RDP; empty = deny all |
```

Append to §5:

````markdown
### F1/F2 - Management subnet isolation and forced tunnelling
**Change:** the `virtual-machines` subnet gets its own NSG (`<spoke>-virtual-machines-nsg`) and its own route table (`<spoke>-virtual-machines-egress-rt`). BGP route propagation is disabled on both spoke route tables so that future VPN gateway routes cannot bypass the firewall.

**Expected what-if:**
- `+ Create` for the new NSG and the new route table.
- `~ Modify` on the spoke VNet: the `virtual-machines` subnet's `networkSecurityGroup.id` and `routeTable.id` change.
- `~ Modify` on `<spoke>-appservice-egress-rt`: `disableBgpRoutePropagation` goes false → true.

**Manual steps:** none.
````

Append to §6 Validation table:

```markdown
| Management subnet has its own NSG | `az network vnet subnet show -g defenStack --vnet-name <spoke-vnet> -n virtual-machines --query "{nsg:networkSecurityGroup.id,rt:routeTable.id}" -o json` | `nsg` ends `-virtual-machines-nsg`; `rt` ends `-virtual-machines-egress-rt` |
| BGP propagation disabled | `az network route-table list -g defenStack --query "[].{name:name,bgpOff:disableBgpRoutePropagation}" -o table` | `bgpOff` = `True` for both spoke route tables |
| No admin inbound yet | `az network nsg rule list -g defenStack --nsg-name <spoke-vnet>-virtual-machines-nsg -o table` | Only `deny-unsolicited-inbound` (4096) |
```

Append to §7:

```markdown
- **F1/F2:** redeploy the previous commit. ARM re-points the subnet to the App Service NSG and route table; the new NSG and route table remain and can be deleted afterwards with `az network nsg delete` / `az network route-table delete`.
```

- [ ] **Step 8: Commit**

```bash
git add modules/spokeNetwork.bicep modules/virtualMachine.bicep main.bicep main.json tests/SpokeNetwork.Tests.ps1 tests/VirtualMachine.Tests.ps1 tests/Main.Tests.ps1 docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: isolate management subnet NSG/route table and stop BGP route propagation (F1, F2)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Single source of truth for spoke CIDRs (F5)

**Files:**
- Modify: `main.bicep` (params lines 79-82, `azureFirewall` params lines 152-154, `spokeNetwork` params)
- Modify: `modules/spokeNetwork.bicep` (`approvedPrivateEndpointSourceCidrs` default removed)
- Modify: `tests/Main.Tests.ps1`, `README.md` (Firewall behavior bullet mentioning `approvedPrivateEndpointSourceCidrs`), `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Produces these `main.bicep` params, reused by Phase 1 `regionStamp.bicep`:
  - `spokeVnetAddressSpace array = ['10.0.0.0/16']`
  - `privateEndpointSubnetAddressPrefix string = '10.0.1.0/24'`
  - `appServiceIntegrationSubnetAddressPrefix string = '10.0.2.0/24'`
  - `virtualMachineSubnetAddressPrefix string = '10.0.3.0/24'`
  - `additionalPrivateEndpointSourceCidrs array = []`
- **Breaking:** `approvedPrivateEndpointSourceCidrs` is removed from `main.bicep`.

- [ ] **Step 1: Write the failing test**

Append to `tests/Main.Tests.ps1`:

```powershell
Describe 'Spoke CIDR single source of truth (F5)' {
    It 'firewall spoke source ranges come from spokeVnetAddressSpace' {
        (Get-ModuleDeployment -Template $main -Name 'azure-firewall').properties.parameters.spokeAddressPrefixes.value |
            Should -Be "[parameters('spokeVnetAddressSpace')]"
    }

    It 'spoke VNet address space comes from spokeVnetAddressSpace' {
        (Get-ModuleDeployment -Template $main -Name 'spoke-network').properties.parameters.vnetAddressSpace.value |
            Should -Be "[parameters('spokeVnetAddressSpace')]"
    }

    It 'private endpoint sources are derived from the App Service and management subnet prefixes' {
        $value = (Get-ModuleDeployment -Template $main -Name 'spoke-network').properties.parameters.approvedPrivateEndpointSourceCidrs.value
        $value | Should -Match 'appServiceIntegrationSubnetAddressPrefix'
        $value | Should -Match 'virtualMachineSubnetAddressPrefix'
        $value | Should -Match 'additionalPrivateEndpointSourceCidrs'
    }

    It 'no longer exposes approvedPrivateEndpointSourceCidrs' {
        $main.parameters.PSObject.Properties.Name | Should -Not -Contain 'approvedPrivateEndpointSourceCidrs'
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Main.Tests.ps1`
Expected: FAIL. `spokeAddressPrefixes` is the literal array `10.0.0.0/16`, and the old parameter still exists.

- [ ] **Step 3: Implement in `main.bicep`**

Replace the `approvedPrivateEndpointSourceCidrs` param block with:

```bicep
@description('Spoke VNet address space. Also used as the firewall source range for spoke egress rules.')
param spokeVnetAddressSpace array = [
  '10.0.0.0/16'
]

@description('Private endpoint subnet prefix inside spokeVnetAddressSpace.')
param privateEndpointSubnetAddressPrefix string = '10.0.1.0/24'

@description('App Service integration subnet prefix inside spokeVnetAddressSpace.')
param appServiceIntegrationSubnetAddressPrefix string = '10.0.2.0/24'

@description('Management VM subnet prefix inside spokeVnetAddressSpace.')
param virtualMachineSubnetAddressPrefix string = '10.0.3.0/24'

@description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
param additionalPrivateEndpointSourceCidrs array = []
```

In the `azureFirewall` module, replace the `spokeAddressPrefixes: [ '10.0.0.0/16' ]` block with `spokeAddressPrefixes: spokeVnetAddressSpace`.

In the `spokeNetwork` module params, replace `approvedPrivateEndpointSourceCidrs: approvedPrivateEndpointSourceCidrs` with:

```bicep
    vnetAddressSpace: spokeVnetAddressSpace
    privateEndpointSubnetAddressPrefix: privateEndpointSubnetAddressPrefix
    appServiceIntegrationSubnetAddressPrefix: appServiceIntegrationSubnetAddressPrefix
    virtualMachineSubnetAddressPrefix: virtualMachineSubnetAddressPrefix
    approvedPrivateEndpointSourceCidrs: concat([
      appServiceIntegrationSubnetAddressPrefix
      virtualMachineSubnetAddressPrefix
    ], additionalPrivateEndpointSourceCidrs)
```

- [ ] **Step 4: Make the module input explicit in `modules/spokeNetwork.bicep`**

Replace:

```bicep
@description('CIDR ranges allowed to reach private endpoints over HTTPS.')
param approvedPrivateEndpointSourceCidrs array = [
  '10.0.2.0/24'
]
```

with:

```bicep
@description('CIDR ranges allowed to reach private endpoints over HTTPS. The caller derives these from subnet prefixes so they cannot drift.')
param approvedPrivateEndpointSourceCidrs array
```

- [ ] **Step 5: Update the README**

In `README.md`, replace the Firewall behavior sentence that begins "NSGs deny unsolicited inbound traffic on the private endpoint…" with:

```markdown
- NSGs deny unsolicited inbound traffic on the private endpoint, App Service integration, and management subnets. Private endpoint network security policy is enabled. By default only the App Service integration and management subnets can reach private endpoints over HTTPS; the allowed sources are derived from `appServiceIntegrationSubnetAddressPrefix` and `virtualMachineSubnetAddressPrefix`. Add narrowly scoped administrator/client CIDRs through `additionalPrivateEndpointSourceCidrs` when required. Spoke CIDRs are defined once (`spokeVnetAddressSpace` and the subnet prefix parameters) and reused by the firewall rules.
```

- [ ] **Step 6: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 7: Document F5 in `00a-apply-phase0-fixes.md`**

Append to §3 Parameters table:

```markdown
| `spokeVnetAddressSpace` | `['10.0.0.0/16']` | same | Single source for spoke VNet and firewall source ranges |
| `privateEndpointSubnetAddressPrefix` | `10.0.1.0/24` | same | Must stay inside `spokeVnetAddressSpace` |
| `appServiceIntegrationSubnetAddressPrefix` | `10.0.2.0/24` | same | Also an approved PE source |
| `virtualMachineSubnetAddressPrefix` | `10.0.3.0/24` | same | Also an approved PE source (jump host reaches Key Vault/Storage) |
| `additionalPrivateEndpointSourceCidrs` | `[]` | `[]` | Replaces removed `approvedPrivateEndpointSourceCidrs` |
```

Append to §5:

````markdown
### F5 - Spoke CIDRs defined once
**Change:** the firewall source ranges and the private endpoint NSG sources are derived from the spoke address parameters instead of repeated literals. The management subnet (`10.0.3.0/24`) is now an approved private endpoint source, so the future jump host can reach Key Vault and Storage.

**Breaking parameter change:** `approvedPrivateEndpointSourceCidrs` no longer exists. If you passed it before, pass only the *extra* ranges through `additionalPrivateEndpointSourceCidrs`.

**Expected what-if:** `~ Modify` on `<spoke>-private-endpoints-nsg` rule `allow-approved-https`: `sourceAddressPrefixes` gains `10.0.3.0/24`. No firewall policy change with default values.

**Manual steps:** none.
````

Append to §6 Validation table:

```markdown
| PE NSG sources | `az network nsg rule show -g defenStack --nsg-name <spoke-vnet>-private-endpoints-nsg -n allow-approved-https --query sourceAddressPrefixes -o tsv` | `10.0.2.0/24` and `10.0.3.0/24` |
```

- [ ] **Step 8: Commit**

```bash
git add main.bicep main.json modules/spokeNetwork.bicep tests/Main.Tests.ps1 README.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: derive firewall and private endpoint CIDRs from spoke parameters (F5)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Firewall hardening and Azure Monitor egress (F9)

**Files:**
- Modify: `modules/azureFirewall.bicep` (params, public IP lines 32-41, policy lines 44-56, DNS rule collection group lines 59-92, firewall lines 128-149, diagnostics lines 152-170)
- Modify: `main.bicep` (`azureFirewall` params)
- Create: `tests/AzureFirewall.Tests.ps1`
- Modify: `tests/Main.Tests.ps1`, `README.md` (Firewall behavior), `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Produces:
  - `azureFirewall.bicep` param `availabilityZones array = []`; Phase 1 passes `['1','2','3']` on new deployments.
  - `azureFirewall.bicep` param `threatIntelMode string = 'Deny'`, allowed `Alert|Deny|Off`.
  - A network rule allowing `spokeAddressPrefixes` → service tag `AzureMonitor` on TCP 443. Task 5's Azure Monitor Agent needs it.

- [ ] **Step 1: Write the failing tests**

Create `tests/AzureFirewall.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/azureFirewall.bicep'
    $firewall = Get-TemplateResource -Template $template -Type 'Microsoft.Network/azureFirewalls' | Select-Object -First 1
    $publicIp = Get-TemplateResource -Template $template -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
    $policy = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies' | Select-Object -First 1
    $ruleGroups = Get-TemplateResource -Template $template -Type 'Microsoft.Network/firewallPolicies/ruleCollectionGroups'
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
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

Describe 'Azure Firewall threat protection (F9)' {
    It 'defaults threat intelligence to Deny' {
        $template.parameters.threatIntelMode.defaultValue | Should -Be 'Deny'
        $policy.properties.threatIntelMode | Should -Be "[parameters('threatIntelMode')]"
    }
}

Describe 'Azure Firewall logging (F9)' {
    It 'writes to resource-specific (dedicated) Log Analytics tables' {
        $diagnostics.properties.logAnalyticsDestinationType | Should -Be 'Dedicated'
    }
}

Describe 'Azure Monitor egress' {
    It 'allows spoke traffic to the AzureMonitor service tag on 443' {
        $rules = @($ruleGroups.properties.ruleCollections.rules | Where-Object { $_.ruleType -eq 'NetworkRule' })
        $monitorRule = $rules | Where-Object { @($_.destinationAddresses) -contains 'AzureMonitor' }
        $monitorRule | Should -Not -BeNullOrEmpty
        @($monitorRule.destinationPorts) | Should -Contain '443'
    }
}
```

Append to `tests/Main.Tests.ps1`:

```powershell
Describe 'Firewall threat intelligence wiring (F9)' {
    It 'uses Deny in prod and Alert elsewhere' {
        (Get-ModuleDeployment -Template $main -Name 'azure-firewall').properties.parameters.threatIntelMode.value |
            Should -Be "[if(equals(parameters('environmentType'), 'prod'), 'Deny', 'Alert')]"
    }
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/AzureFirewall.Tests.ps1, tests/Main.Tests.ps1"`
Expected: FAIL on every new `It`.

- [ ] **Step 3: Implement in `modules/azureFirewall.bicep`**

Add after `param allowedOutboundFqdns array = []`:

```bicep
@description('Availability zones for the firewall and its public IP, for example [\'1\', \'2\', \'3\']. Zones are fixed at creation, so leave empty when updating an existing non-zonal firewall.')
param availabilityZones array = []

@description('Threat intelligence mode for the firewall policy.')
@allowed([
  'Alert'
  'Deny'
  'Off'
])
param threatIntelMode string = 'Deny'
```

In `firewallPublicIp`, add after `location: location`:

```bicep
  zones: empty(availabilityZones) ? null : availabilityZones
```

In `firewallPolicy`, change `threatIntelMode: 'Alert'` to `threatIntelMode: threatIntelMode`.

Change the comment above `firewallDnsRuleCollectionGroup` to `// Platform egress for the spoke VNet: DNS proxy and Azure Monitor Agent ingestion.` Then add this second entry to its `ruleCollections` array, after the `dns` collection:

```bicep
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
            ]
            destinationPorts: [
              '443'
            ]
          }
        ]
      }
```

The group name stays `dns-egress` to avoid a delete and recreate. A new rule collection group would also race with the existing groups on the same policy.

In `firewall`, add after `location: location`:

```bicep
  zones: empty(availabilityZones) ? null : availabilityZones
```

Add as the first entry inside `firewall.properties`:

```bicep
    sku: {
      name: 'AZFW_VNet'
      tier: 'Standard'
    }
```

In `firewallDiagnostics.properties`, add after `workspaceId: logAnalyticsWorkspaceId`:

```bicep
    logAnalyticsDestinationType: 'Dedicated'
```

- [ ] **Step 4: Wire it through `main.bicep`**

Add to the `azureFirewall` module params:

```bicep
    threatIntelMode: environmentType == 'prod' ? 'Deny' : 'Alert'
```

- [ ] **Step 5: Update the README Firewall behavior section**

In `README.md`, replace the bullet beginning "`allowedOutboundFqdns` defaults to an empty list" with:

```markdown
- `allowedOutboundFqdns` defaults to an empty list, so application HTTPS traffic is denied until administrators provide an approved FQDN allowlist. The default platform egress rules are DNS to Azure's resolver (`168.63.129.16:53`) and HTTPS to the `AzureMonitor` service tag for the Azure Monitor Agent.
- Threat intelligence runs in `Deny` mode for `prod` and `Alert` mode for `dev`/`test`. Firewall logs are written to resource-specific tables (`AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWDnsQuery`, `AZFWThreatIntel`, …), not `AzureDiagnostics`.
```

- [ ] **Step 6: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 7: Document F9 in `00a-apply-phase0-fixes.md`**

Append to §3 Parameters table:

```markdown
| `threatIntelMode` (firewall module) | `Deny` | `Deny` (main passes `Alert` for dev/test) | Block known-malicious IPs/FQDNs in prod |
| `availabilityZones` (firewall module) | `[]` | `['1','2','3']` in Phase 1 greenfield | Zones cannot be added to an existing firewall/PIP in place |
```

Append to §5:

````markdown
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
````

Append to §6 Validation table:

```markdown
| Threat intel mode | `az network firewall policy show -g defenStack -n <firewall-policy> --query threatIntelMode -o tsv` | `Alert` (dev) |
| Azure Monitor rule | `az network firewall policy rule-collection-group show -g defenStack --policy-name <firewall-policy> -n dns-egress --query "ruleCollections[].name" -o tsv` | `dns` and `azure-monitor` |
| Dedicated tables | In Log Analytics: `AZFWNetworkRule \| take 5` (after 15 minutes of traffic) | Rows returned |
```

Append to §9 Troubleshooting table:

```markdown
| `AnotherOperationInProgress` on firewall policy | Two rule collection groups updated concurrently | Re-run the deployment; groups are serialised by `parent` dependency on retry |
| `Firewall zones cannot be changed` | `availabilityZones` passed for an existing non-zonal firewall | Leave `availabilityZones` empty for in-place updates; zones arrive with Phase 1 greenfield |
```

- [ ] **Step 8: Commit**

```bash
git add modules/azureFirewall.bicep main.bicep main.json tests/AzureFirewall.Tests.ps1 tests/Main.Tests.ps1 README.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: parameterise firewall zones/threat intel, add Azure Monitor egress, use dedicated log tables (F9)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: VM monitoring through Azure Monitor Agent and a Data Collection Rule (F3)

**Files:**
- Modify: `modules/virtualMachine.bicep` (vars, diagnostics lines 172-190, new resources)
- Modify: `tests/VirtualMachine.Tests.ps1`, `README.md` (Virtual machine module section), `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Consumes: Task 4's AzureMonitor firewall rule, so the agent can reach ingestion endpoints.
- Produces: `virtualMachine.bicep` output `dataCollectionRuleId string`. Phase 6 adds a DCE/AMPLS association to this DCR.

- [ ] **Step 1: Write the failing tests**

Append to `tests/VirtualMachine.Tests.ps1`:

```powershell
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
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/VirtualMachine.Tests.ps1`
Expected: FAIL. `logs` is present, and the DCR, association and extension are all missing.

- [ ] **Step 3: Implement in `modules/virtualMachine.bicep`**

Add after the `managementInboundRules` var from Task 2:

```bicep
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
        'Processor(*)\\% Processor Time'
        'Memory(*)\\% Used Memory'
        'Logical Disk(*)\\% Used Space'
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
```

Replace the whole `virtualMachineDiagnostics` resource with:

```bicep
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
```

Add at the end of the file:

```bicep
output dataCollectionRuleId string = dataCollectionRule.id
```

- [ ] **Step 4: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Validate against Azure with the VM enabled**

This confirms F3 is fixed. The VM stays disabled by default, so this is a validate only, not a deploy.

```powershell
az deployment group validate `
  --resource-group defenStack `
  --template-file main.bicep `
  --parameters environmentType=dev enableVirtualMachine=true virtualMachineOsType=Linux `
               virtualMachineAdminSshPublicKey="$(Get-Content ~/.ssh/id_ed25519.pub)" `
  --output table
```

Expected: `Succeeded`. If it fails with `EncryptionAtHost feature is not enabled`, run the registration in the §2 addition below, then retry.

Record the result in the PR description.

- [ ] **Step 6: Update the README Virtual machine module section**

In `README.md`, replace "Premium managed OS disk, trusted launch, secure boot, vTPM, and boot/Log Analytics diagnostics." with:

```markdown
Premium managed OS disk, trusted launch, secure boot, vTPM, boot diagnostics, platform metrics, and the Azure Monitor Agent with a data collection rule that sends syslog (Linux) or System/Application events (Windows) plus CPU, memory, and disk counters to the Log Analytics workspace. The firewall's `AzureMonitor` service-tag rule allows the agent's egress.
```

- [ ] **Step 7: Document F3 in `00a-apply-phase0-fixes.md`**

Append to §2 Prerequisites:

````markdown
- Only if deploying the VM: register host encryption once per subscription, then wait for `Registered`:

  ```powershell
  az feature register --namespace Microsoft.Compute --name EncryptionAtHost
  az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv
  az provider register --namespace Microsoft.Compute
  ```
````

Append to §5:

````markdown
### F3 - VM monitoring via Azure Monitor Agent
**Change:** the VM diagnostic setting no longer requests `allLogs`. Compute VMs expose no log categories, so that request made VM deployments fail. Guest telemetry now flows through the Azure Monitor Agent extension and a data collection rule (`<vm>-dcr`) associated with the VM.

**Expected what-if:** no change while `enableVirtualMachine=false`. With the VM enabled:
- `+ Create` for the extension, the DCR and the DCR association.
- `~ Modify` for the diagnostic setting.

**Manual steps:** none.
````

Append to §6 Validation table:

```markdown
| (VM enabled only) agent healthy | `az vm extension show -g defenStack --vm-name <vm> -n AzureMonitorLinuxAgent --query provisioningState -o tsv` | `Succeeded` |
| (VM enabled only) data arriving | Log Analytics: `Heartbeat \| where Computer == "<vm>" \| take 1` after 10 minutes | One row |
```

Append to §9 Troubleshooting table:

```markdown
| No `Heartbeat` rows | Firewall blocking agent egress | Check `AZFWNetworkRule \| where DestinationPort == 443 and Action == "Deny"`; confirm the `azure-monitor` collection exists |
```

- [ ] **Step 8: Commit**

```bash
git add modules/virtualMachine.bicep main.json tests/VirtualMachine.Tests.ps1 README.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: replace invalid VM log diagnostics with Azure Monitor Agent and DCR (F3)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Key Vault template-deployment access and PE output (F4, F12)

**Files:**
- Modify: `modules/keyVault.bicep` (params, properties lines 27-41)
- Modify: `modules/privateConnectivity.bicep` (outputs line 247-248)
- Modify: `main.bicep` (`keyVault` params)
- Create: `tests/KeyVault.Tests.ps1`
- Modify: `tests/Main.Tests.ps1`, `README.md` ("Key Vault and deployment secrets" section), `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Produces:
  - `keyVault.bicep` param `enabledForTemplateDeployment bool = false`; `main.bicep` passes `true`.
  - `privateConnectivity.bicep` output `keyVaultPrivateEndpointId string`.

- [ ] **Step 1: Write the failing tests**

Create `tests/KeyVault.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/keyVault.bicep'
    $vault = Get-TemplateResource -Template $template -Type 'Microsoft.KeyVault/vaults' | Select-Object -First 1
    $privateConnectivity = Get-BicepTemplate -RelativePath 'modules/privateConnectivity.bicep'
}

Describe 'Key Vault template deployment access (F4)' {
    It 'is off by default for standalone reuse' {
        $template.parameters.enabledForTemplateDeployment.defaultValue | Should -BeFalse
        $vault.properties.enabledForTemplateDeployment | Should -Be "[parameters('enabledForTemplateDeployment')]"
    }

    It 'keeps public network access disabled' {
        $vault.properties.publicNetworkAccess | Should -Be 'Disabled'
    }
}

Describe 'Private connectivity outputs (F12)' {
    It 'outputs the Key Vault private endpoint ID' {
        $privateConnectivity.outputs.PSObject.Properties.Name | Should -Contain 'keyVaultPrivateEndpointId'
    }
}
```

Append to `tests/Main.Tests.ps1`:

```powershell
Describe 'Key Vault wiring (F4)' {
    It 'enables template deployment for the composed stack so az.getSecret() references resolve' {
        (Get-ModuleDeployment -Template $main -Name 'key-vault').properties.parameters.enabledForTemplateDeployment.value | Should -BeTrue
    }
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/KeyVault.Tests.ps1, tests/Main.Tests.ps1"`
Expected: FAIL on the new tests.

- [ ] **Step 3: Implement**

In `modules/keyVault.bicep`, add after `param enablePurgeProtection bool = true`:

```bicep
@description('Allow Azure Resource Manager to retrieve secrets during deployments, required for az.getSecret() in .bicepparam files. Keep false for vaults that never back deployment parameters.')
param enabledForTemplateDeployment bool = false
```

Then add to `keyVault.properties` after `enablePurgeProtection: enablePurgeProtection`:

```bicep
    enabledForTemplateDeployment: enabledForTemplateDeployment
```

In `modules/privateConnectivity.bicep`, append:

```bicep
output keyVaultPrivateEndpointId string = keyVaultPrivateEndpoint.id
```

In `main.bicep`, add to the `keyVault` module params:

```bicep
    enabledForTemplateDeployment: true
```

- [ ] **Step 4: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Correct the README Key Vault section**

In `README.md`, replace the paragraph beginning "Deploy the parameter file with `az deployment group create --parameters <file>.bicepparam`." with:

```markdown
Deploy the parameter file with `az deployment group create --parameters <file>.bicepparam`. `az.getSecret()` compiles to a Key Vault reference that Azure Resource Manager resolves at deployment time, so:

- The vault must have `enabledForTemplateDeployment = true` (the composed stack sets this).
- The deploying identity needs `Microsoft.KeyVault/vaults/deploy/action` on the vault, which is included in `Contributor` and `Owner`.
- `az.getSecret()` cannot read a vault created in the same deployment; use the two-phase flow above.

Resolution through a vault with public network access disabled must be confirmed once per environment; see `docs/runbooks/00a-apply-phase0-fixes.md` (F4).
```

Also change the name used in step 3 of the two-phase flow, "Use a local, ignored `.bicepparam` file", to "Use a local, ignored `*.local.bicepparam` file (matched by `.gitignore`)".

- [ ] **Step 6: Document F4/F12 in `00a-apply-phase0-fixes.md`**

Append to §3 Parameters table:

```markdown
| `enabledForTemplateDeployment` (Key Vault) | `false` (module) | `true` (composed stack) | Required for `az.getSecret()` Key Vault references |
```

Append to §5:

````markdown
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
````

Append to §6 Validation table:

```markdown
| Template deployment enabled | `az keyvault show -n <key-vault-name> --query "{tmpl:properties.enabledForTemplateDeployment,public:properties.publicNetworkAccess}" -o table` | `tmpl` True, `public` Disabled |
```

Append to §7:

```markdown
- **F4:** set `enabledForTemplateDeployment: false` in `main.bicep` and redeploy, or run `az keyvault update -n <vault> --enabled-for-template-deployment false`.
```

- [ ] **Step 7: Commit**

```bash
git add modules/keyVault.bicep modules/privateConnectivity.bicep main.bicep main.json tests/KeyVault.Tests.ps1 tests/Main.Tests.ps1 README.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: enable Key Vault template deployment references and output KV private endpoint (F4, F12)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Blob data protection and blob audit logs (F6, F7)

**Files:**
- Modify: `modules/storage.bicep` (params, `blobServices` lines 32-39, new diagnostic setting)
- Create: `tests/Storage.Tests.ps1`
- Modify: `docs/runbooks/00a-apply-phase0-fixes.md`, `README.md` (Security notes storage bullet), `main.json`

**Interfaces:**
- Produces: `storage.bicep` param `blobSoftDeleteRetentionDays int = 14` (7–365). Point-in-time restore is always `blobSoftDeleteRetentionDays - 1` days.

- [ ] **Step 1: Write the failing tests**

Create `tests/Storage.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/storage.bicep'
    $blobService = Get-TemplateResource -Template $template -Type 'Microsoft.Storage/storageAccounts/blobServices' | Select-Object -First 1
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings'
}

Describe 'Blob data protection (F7)' {
    It 'enables versioning, change feed, blob and container soft delete, and point-in-time restore' {
        $blobService.properties.isVersioningEnabled | Should -BeTrue
        $blobService.properties.changeFeed.enabled | Should -BeTrue
        $blobService.properties.deleteRetentionPolicy.enabled | Should -BeTrue
        $blobService.properties.containerDeleteRetentionPolicy.enabled | Should -BeTrue
        $blobService.properties.restorePolicy.enabled | Should -BeTrue
    }

    It 'keeps the restore window shorter than soft delete retention' {
        $blobService.properties.restorePolicy.days | Should -Be "[sub(parameters('blobSoftDeleteRetentionDays'), 1)]"
        $template.parameters.blobSoftDeleteRetentionDays.defaultValue | Should -Be 14
    }
}

Describe 'Blob audit logs (F6)' {
    It 'has an account-level and a blob-service-level diagnostic setting' {
        $diagnostics.Count | Should -Be 2
    }

    It 'collects all blob read/write/delete logs' {
        $blobDiagnostics = $diagnostics | Where-Object { $_.scope -match 'blobServices' }
        $blobDiagnostics.properties.logs[0].categoryGroup | Should -Be 'allLogs'
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Storage.Tests.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement in `modules/storage.bicep`**

Add after `param logAnalyticsWorkspaceId string`:

```bicep
@description('Days that deleted blobs and containers are recoverable. Point-in-time restore covers one day less.')
@minValue(7)
@maxValue(365)
param blobSoftDeleteRetentionDays int = 14
```

Replace the `resource service 'blobServices' = { … }` block with:

```bicep
  resource service 'blobServices' = {
    name: 'default'
    properties: {
      isVersioningEnabled: true
      changeFeed: {
        enabled: true
        retentionInDays: blobSoftDeleteRetentionDays
      }
      deleteRetentionPolicy: {
        enabled: true
        days: blobSoftDeleteRetentionDays
      }
      containerDeleteRetentionPolicy: {
        enabled: true
        days: blobSoftDeleteRetentionDays
      }
      restorePolicy: {
        enabled: true
        days: blobSoftDeleteRetentionDays - 1
      }
    }

    // Application container for deployment-managed blob data.
    resource blob 'containers' = {
      name: 'def-blob'
    }
  }
```

Add after `storageDiagnostics`:

```bicep
// Blob read, write, and delete audit logs; account-level settings expose metrics only.
resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: storageAccount::service
  name: 'blob-diagnostics'
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
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}
```

- [ ] **Step 4: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Update the README Security notes**

Replace the storage bullet with:

```markdown
- The storage account denies public network access, blob public access, shared-key access, and TLS versions below 1.2. Blob versioning, change feed, 14-day blob and container soft delete, and 13-day point-in-time restore are enabled, and blob read/write/delete logs go to Log Analytics (`StorageBlobLogs`).
```

- [ ] **Step 6: Document F6/F7 in `00a-apply-phase0-fixes.md`**

Append to §3 Parameters table:

```markdown
| `blobSoftDeleteRetentionDays` (storage) | `14` | `14` or higher per data retention policy | Recovery window; PITR = value − 1 |
```

Append to §5:

````markdown
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
````

Append to §6 Validation table:

```markdown
| Data protection on | `az storage account blob-service-properties show -g defenStack -n <storage-account> --query "{ver:isVersioningEnabled,soft:deleteRetentionPolicy.days,pitr:restorePolicy.days}" -o table` | `ver` True, `soft` 14, `pitr` 13 |
| Blob logs arriving | Log Analytics: `StorageBlobLogs \| take 5` after blob activity | Rows returned |
```

Append to §7:

```markdown
- **F7:** point-in-time restore must be disabled **before** change feed or versioning (Azure rejects the reverse order). Set `restorePolicy.enabled: false`, deploy, then disable the others.
```

- [ ] **Step 7: Commit**

```bash
git add modules/storage.bicep main.json tests/Storage.Tests.ps1 README.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: enable blob data protection and blob audit logs (F6, F7)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Container-scoped storage RBAC (F11)

**Files:**
- Modify: `modules/storage.bicep` (outputs), `modules/networkIntegration.bicep` (params, existing resource, role assignment lines 44-87), `main.bicep` (`networkIntegration` params)
- Create: `tests/NetworkIntegration.Tests.ps1`
- Modify: `tests/Main.Tests.ps1`, `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Produces:
  - `storage.bicep` output `blobContainerName string`.
  - `networkIntegration.bicep` param `storageContainerName string`.
  - The role assignment name becomes `guid(storageAccountId, storageContainerName, appServiceName, 'Storage Blob Data Contributor')`.

- [ ] **Step 1: Write the failing tests**

Create `tests/NetworkIntegration.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/networkIntegration.bicep'
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
```

Append to `tests/Main.Tests.ps1`:

```powershell
Describe 'Storage RBAC wiring (F11)' {
    It 'passes the container name from the storage module output' {
        (Get-ModuleDeployment -Template $main -Name 'network-integration').properties.parameters.storageContainerName.value |
            Should -Match "outputs.blobContainerName"
    }
}
```

- [ ] **Step 2: Run them to confirm they fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "& ./tests/Invoke-Tests.ps1 -Path tests/NetworkIntegration.Tests.ps1, tests/Main.Tests.ps1"`
Expected: FAIL.

- [ ] **Step 3: Implement**

In `modules/storage.bicep`, append:

```bicep
output blobContainerName string = storageAccount::service::blob.name
```

In `modules/networkIntegration.bicep`, add after the `storageAccountId` param:

```bicep
@description('Blob container that receives the application identity role assignment.')
@minLength(3)
@maxLength(63)
param storageContainerName string
```

Replace the `storageAccount` existing resource with:

```bicep
resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
  name: storageAccountName

  resource blobService 'blobServices' existing = {
    name: 'default'

    resource container 'containers' existing = {
      name: storageContainerName
    }
  }
}
```

Replace the `storageBlobDataContributor` resource with:

```bicep
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

In `main.bicep`, add to the `networkIntegration` module params:

```bicep
    storageContainerName: storage.outputs.blobContainerName
```

- [ ] **Step 4: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Document F11 in `00a-apply-phase0-fixes.md`**

Append to §5:

````markdown
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
````

Append to §6 Validation table:

```markdown
| Only container-scoped access | `az role assignment list --assignee <app-principal-id> --all --query "[?roleDefinitionName=='Storage Blob Data Contributor'].scope" -o tsv` | Exactly one scope ending `/containers/def-blob` |
| App still reads/writes | Application smoke test against `def-blob` | Success; `StorageBlobLogs` shows `AuthenticationType == "OAuth"` |
```

Append to §7:

```markdown
- **F11:** redeploy the previous commit (recreates the account-scope assignment), then delete the container-scope assignment with `az role assignment delete --ids <id>`.
```

Append to §9 Troubleshooting table:

```markdown
| App gets `AuthorizationPermissionMismatch` on another container | Access is now limited to `def-blob` | Add a container-scoped assignment for the extra container through Bicep; do not widen to account scope |
```

- [ ] **Step 6: Commit**

```bash
git add modules/storage.bicep modules/networkIntegration.bicep main.bicep main.json tests/NetworkIntegration.Tests.ps1 tests/Main.Tests.ps1 docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: scope App Service storage role assignment to its container (F11)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: App Service hardening (F8)

**Files:**
- Modify: `modules/appService.bicep` (params, plan lines 31-38, site config lines 53-58, new child resources)
- Create: `tests/AppService.Tests.ps1`
- Modify: `README.md` (Security notes App Service bullet), `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Produces these `appService.bicep` params (Phase 1 sets `zoneRedundant: true, instanceCount: 3` for prod greenfield):
  - `healthCheckPath string = '/'`
  - `zoneRedundant bool = false`
  - `instanceCount int = 1` (1–30)
- The plan name is unchanged in Phase 0.

- [ ] **Step 1: Write the failing tests**

Create `tests/AppService.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/appService.bicep'
    $plan = Get-TemplateResource -Template $template -Type 'Microsoft.Web/serverfarms' | Select-Object -First 1
    $site = Get-TemplateResource -Template $template -Type 'Microsoft.Web/sites' | Select-Object -First 1
    $basicAuth = Get-TemplateResource -Template $template -Type 'Microsoft.Web/sites/basicPublishingCredentialsPolicies'
}

Describe 'App Service publishing credentials (F8)' {
    It 'disables basic authentication for FTP and SCM' {
        $basicAuth.Count | Should -Be 2
        foreach ($policy in $basicAuth) {
            $policy.properties.allow | Should -BeFalse
        }
    }
}

Describe 'App Service site configuration (F8)' {
    It 'keeps the instance warm and health-probed' {
        $site.properties.siteConfig.alwaysOn | Should -BeTrue
        $site.properties.siteConfig.healthCheckPath | Should -Be "[parameters('healthCheckPath')]"
    }

    It 'requires TLS 1.2 on the SCM endpoint and disables remote debugging' {
        $site.properties.siteConfig.scmMinTlsVersion | Should -Be '1.2'
        $site.properties.siteConfig.remoteDebuggingEnabled | Should -BeFalse
    }
}

Describe 'App Service plan resilience parameters (F8)' {
    It 'exposes zone redundancy and instance count, defaulting to in-place-safe values' {
        $template.parameters.zoneRedundant.defaultValue | Should -BeFalse
        $template.parameters.instanceCount.defaultValue | Should -Be 1
        $plan.properties.zoneRedundant | Should -Be "[parameters('zoneRedundant')]"
        $plan.sku.capacity | Should -Be "[parameters('instanceCount')]"
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/AppService.Tests.ps1`
Expected: FAIL.

- [ ] **Step 3: Implement in `modules/appService.bicep`**

Add after `param environmentType string`:

```bicep
@description('Relative path probed by App Service health check; it must return 200-299 when the instance is healthy.')
param healthCheckPath string = '/'

@description('Spread plan instances across availability zones. Zone redundancy is set when a plan is created, so enable it only for new plans.')
param zoneRedundant bool = false

@description('Number of plan instances. Zone-redundant plans require at least 3.')
@minValue(1)
@maxValue(30)
param instanceCount int = 1
```

In `appServiceplan`, replace the `sku` block and add `properties`:

```bicep
  sku: {
    name: appServicePlanSkuName
    tier: appServicePlanSkuTier
    capacity: instanceCount
  }
  properties: {
    zoneRedundant: zoneRedundant
  }
```

In `appServiceApp.properties.siteConfig`, add after `vnetRouteAllEnabled: true`:

```bicep
      alwaysOn: true
      healthCheckPath: healthCheckPath
      scmMinTlsVersion: '1.2'
      remoteDebuggingEnabled: false
```

Add after `appServiceApp`:

```bicep
// Basic (username/password) publishing is disabled; deployments use Entra ID tokens.
resource ftpBasicPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: appServiceApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmBasicPublishing 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2025-03-01' = {
  parent: appServiceApp
  name: 'scm'
  properties: {
    allow: false
  }
}
```

- [ ] **Step 4: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Update the README Security notes**

Replace the App Service bullet with:

```markdown
- The App Service uses a system-assigned managed identity, HTTPS-only access, TLS 1.2 (site and SCM), HTTP/2, disabled FTPS, disabled FTP/SCM basic authentication, disabled remote debugging, Always On, a health check probe (`healthCheckPath`, default `/`), VNet integration, and a private endpoint.
```

- [ ] **Step 6: Document F8 in `00a-apply-phase0-fixes.md`**

Append to §3 Parameters table:

```markdown
| `healthCheckPath` (App Service) | `/` | Application health endpoint, e.g. `/healthz` | Unhealthy instances are removed from rotation |
| `zoneRedundant` (App Service) | `false` | `true` in Phase 1 greenfield | Set at plan creation only |
| `instanceCount` (App Service) | `1` | `3` with zone redundancy | Zone-redundant minimum |
```

Append to §5:

````markdown
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
````

Append to §6 Validation table:

```markdown
| Basic auth off | `az resource show -g defenStack --namespace Microsoft.Web --parent sites/<app-service-name> --resource-type basicPublishingCredentialsPolicies -n scm --query properties.allow -o tsv` | `false` (repeat with `-n ftp`) |
| Site config | `az webapp config show -g defenStack -n <app-service-name> --query "{alwaysOn:alwaysOn,health:healthCheckPath,scmTls:scmMinTlsVersion,debug:remoteDebuggingEnabled}" -o table` | `True`, `/`, `1.2`, `False` |
```

Append to §9 Troubleshooting table:

```markdown
| Instances marked unhealthy after deploy | App returns non-2xx on `healthCheckPath` | Set `healthCheckPath` to a real health endpoint and redeploy |
| `401` from publish profile deploy | Basic auth disabled by F8 | Use `az webapp deploy` with Entra ID credentials |
```

- [ ] **Step 7: Commit**

```bash
git add modules/appService.bicep main.json tests/AppService.Tests.ps1 README.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: harden App Service publishing, health, and TLS settings (F8)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Log Analytics retention (F10)

**Files:**
- Modify: `modules/monitoring.bicep` (retention param lines 9-10)
- Create: `tests/Monitoring.Tests.ps1`
- Modify: `docs/runbooks/00a-apply-phase0-fixes.md`, `main.json`

**Interfaces:**
- Produces: `monitoring.bicep` param `retentionInDays int = 90` (30–730). AMPLS and public access lockdown are Phase 6.

- [ ] **Step 1: Write the failing test**

Create `tests/Monitoring.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/monitoring.bicep'
}

Describe 'Log Analytics retention (F10)' {
    It 'retains 90 days by default (Sentinel free retention window)' {
        $template.parameters.retentionInDays.defaultValue | Should -Be 90
    }

    It 'bounds retention to supported values' {
        $template.parameters.retentionInDays.minValue | Should -Be 30
        $template.parameters.retentionInDays.maxValue | Should -Be 730
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Monitoring.Tests.ps1`
Expected: FAIL (the default is 30 and there are no bounds).

- [ ] **Step 3: Implement**

In `modules/monitoring.bicep`, replace:

```bicep
@description('Number of days to retain workspace data.')
param retentionInDays int = 30
```

with:

```bicep
@description('Number of days to retain workspace data. 90 days matches the retention included with Microsoft Sentinel.')
@minValue(30)
@maxValue(730)
param retentionInDays int = 90
```

- [ ] **Step 4: Rebuild and run all tests**

Run: `bicep build main.bicep; powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 5: Document F10 in `00a-apply-phase0-fixes.md`**

Append to §3 Parameters table:

```markdown
| `retentionInDays` (monitoring) | `90` | `90` (longer via archive tier in Phase 6) | Investigation window; included free once Sentinel is enabled |
```

Append to §5:

````markdown
### F10 - Log Analytics retention
**Change:** workspace retention goes from 30 to 90 days. Public ingestion and query lockdown through AMPLS is **Phase 6**; it is not included here because it would cut off agents that have no private path yet.

**Expected what-if:** `~ Modify` on the workspace, where `retentionInDays` goes 30 → 90.

**Cost:** until Sentinel is enabled (Phase 6), days 31–90 are billed as data retention per GB-month. Record the workspace's daily ingestion so the cost can be estimated:

```kusto
Usage | where TimeGenerated > ago(7d) | summarize GB = sum(Quantity) / 1000
```
````

Append to §6 Validation table:

```markdown
| Retention | `az monitor log-analytics workspace show -g defenStack -n <workspace> --query retentionInDays -o tsv` | `90` |
```

- [ ] **Step 6: Commit**

```bash
git add modules/monitoring.bicep main.json tests/Monitoring.Tests.ps1 docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "fix: raise Log Analytics retention to 90 days (F10)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 11: CI validation pipeline, dev parameter file, and PSRule (F13 part 2)

**Files:**
- Create: `params/dev.bicepparam`, `ps-rule.yaml`, `.github/workflows/bicep-ci.yml`, `tests/Params.Tests.ps1`
- Create: `docs/runbooks/00-pipeline-and-identity.md` (sections 1–4; Task 12 completes it)

**Interfaces:**
- Consumes: `tests/Invoke-Tests.ps1 -CI` from Task 1.
- Produces:
  - The GitHub status check named `validate`, used for branch protection in Task 12.
  - `params/dev.bicepparam`, the single dev parameter source for CI, PSRule, what-if and deploy.
  - The GitHub environment `dev` and the variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and `AZURE_RESOURCE_GROUP`. Task 12's identity script creates the values.

- [ ] **Step 1: Write the failing test**

Create `tests/Params.Tests.ps1`:

```powershell
BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $paramFiles = Get-ChildItem -Path (Join-Path $repoRoot 'params') -Filter '*.bicepparam' -ErrorAction SilentlyContinue |
        ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
}

Describe 'Committed parameter files' {
    It 'includes a dev parameter file' {
        Get-RepoPath 'params/dev.bicepparam' | Should -Exist
    }

    It '<Name> builds against main.bicep' -ForEach $paramFiles {
        $output = & bicep build-params $FullName --stdout 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }

    It '<Name> contains no az.getSecret references (secrets belong in *.local.bicepparam)' -ForEach $paramFiles {
        Get-Content $FullName -Raw | Should -Not -Match 'getSecret'
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Params.Tests.ps1`
Expected: FAIL on `includes a dev parameter file`.

- [ ] **Step 3: Create `params/dev.bicepparam`**

```bicep
using '../main.bicep'

// Non-secret dev parameters for the existing defenStack resource group.
// Secret values go in a git-ignored *.local.bicepparam overlay, never here.
param environmentType = 'dev'
param allowedOutboundFqdns = []
```

- [ ] **Step 4: Run it to confirm it passes**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Params.Tests.ps1`
Expected: PASS.

- [ ] **Step 5: Create `ps-rule.yaml`**

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
  # Each exclusion must name the phase that resolves it or the ADR that accepts it.
  exclude: []
```

- [ ] **Step 6: Run PSRule locally and record the baseline**

```powershell
Install-Module -Name PSRule.Rules.Azure -Scope CurrentUser -Force
Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error
```

For each failing rule, pick exactly one of:

- **(a) Fixed by a later phase:** add it to `rule.exclude` with a comment, for example:

  ```yaml
    exclude:
      # Phase 2: firewall moves to Premium with IDPS.
      - Azure.Firewall.PolicyMode
  ```

- **(b) Trivially fixable in place:** fix it now in this task, with a test in the matching `tests/*.Tests.ps1` file.
- **(c) Accepted risk:** exclude it and add an ADR under `docs/decisions/`.

Re-run until `Assert-PSRule` reports zero failures. Paste the final rule list and its classification into `00-pipeline-and-identity.md` §8 (Step 8).

- [ ] **Step 7: Create `.github/workflows/bicep-ci.yml`**

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

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Bicep CLI
        run: |
          az bicep install --version "$BICEP_VERSION"
          echo "$HOME/.azure/bin" >> "$GITHUB_PATH"

      - name: Lint, build, template assertions, main.json drift
        shell: pwsh
        run: ./tests/Invoke-Tests.ps1 -CI

      - name: PSRule for Azure
        shell: pwsh
        run: |
          Install-Module -Name PSRule.Rules.Azure -Scope CurrentUser -Force
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
    environment: dev
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
          az bicep install --version "$BICEP_VERSION"
          az deployment group what-if \
            --resource-group "${{ vars.AZURE_RESOURCE_GROUP }}" \
            --parameters params/dev.bicepparam \
            --exclude-change-types Ignore NoChange 2>&1 \
            | sed -r 's/\x1B\[[0-9;]*[mK]//g' > whatif.txt
          {
            echo "### What-if: dev (\`${{ vars.AZURE_RESOURCE_GROUP }}\`)"
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

The `head.repo.full_name` guard keeps fork PRs from requesting Azure tokens.

- [ ] **Step 8: Write runbook 00 sections 1–4 and 8**

Create `docs/runbooks/00-pipeline-and-identity.md`:

````markdown
# 00 - Pipeline and deployment identity

> Owning files: `.github/workflows/bicep-ci.yml`, `.github/workflows/deploy.yml`, `scripts/New-GitHubDeploymentIdentity.ps1`, `ps-rule.yaml`, `params/*.bicepparam`, `tests/`.

## 1. Purpose and scope
- `bicep-ci` runs on every PR and push to `main`: lint, build, Pester template assertions, the `main.json` drift check and PSRule for Azure. On same-repo PRs it also posts a what-if against dev as a PR comment.
- `deploy` deploys `main` to dev through a gated GitHub environment.
- Azure access uses an Entra application with a **federated credential** bound to the GitHub environment. No client secret exists anywhere.

## 2. Prerequisites
- GitHub CLI signed in with admin rights on `Godson90/bicep`: `gh auth status`.
- Entra role able to create app registrations: `Application Developer`, or `Cloud Application Administrator`.
- Azure role able to create role assignments on the target resource group: `Owner`, or `Role Based Access Control Administrator` + `Contributor`.
- Azure CLI 2.90 or later and PowerShell 5.1 or 7.

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `-GitHubRepository` | none | `Godson90/bicep` | Federated credential subject |
| `-EnvironmentName` | none | `dev` now; `prod` in Phase 1 | One identity per environment limits blast radius |
| `-ResourceGroupName` | none | `defenStack` (dev) | Role assignment scope |
| `-DelegatableRoleDefinitionIds` | Storage Blob Data Contributor | extended per phase | Roles the pipeline may assign; all others are blocked by the ABAC condition |
| `-GrantLockManagement` | off | on for prod | Needed only where `CanNotDelete` locks are deployed |

## 4. Step-by-step setup
(completed in Task 12)

## 8. Operations
### PSRule baseline
| Rule | Classification | Resolving phase / ADR |
|---|---|---|
(paste the table produced in Task 11 Step 6)
````

When writing the file, replace the "paste the table" line with the actual rows from Step 6.

- [ ] **Step 9: Run all tests, then commit**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

```bash
git add params/dev.bicepparam ps-rule.yaml .github/workflows/bicep-ci.yml tests/Params.Tests.ps1 docs/runbooks/00-pipeline-and-identity.md
git commit -m "ci: add Bicep validation, PSRule, and PR what-if workflow with dev parameters (F13)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 10: Verify the workflow on GitHub**

```bash
git push -u origin phase0-foundation-fixes
gh pr create --draft --base main --title "Phase 0: foundation fixes, tests, CI" --body "Implements docs/superpowers/plans/2026-09-25-phase0-foundation-fixes.md"
gh pr checks --watch
```

Expected: `validate` passes. `what-if` fails at `azure/login` with a missing client-id until Task 12 sets the variables. That failure is expected; note it in the PR.

---

### Task 12: OIDC deployment identity, deploy workflow, and runbook 00

**Files:**
- Create: `scripts/New-GitHubDeploymentIdentity.ps1`, `.github/workflows/deploy.yml`, `tests/Scripts.Tests.ps1`
- Modify: `docs/runbooks/00-pipeline-and-identity.md` (§4–§9)

**Interfaces:**
- Consumes: the GitHub environment name `dev` and the variable names from Task 11.
- Produces: `New-GitHubDeploymentIdentity.ps1`, which Phase 1 reuses with `-EnvironmentName prod -GrantLockManagement`.
  - Parameters: `-ResourceGroupName`, `-GitHubRepository`, `-EnvironmentName`, `[-SubscriptionId]`, `[-DisplayName]`, `[-DelegatableRoleDefinitionIds]`, `[-GrantLockManagement]`. Supports `-WhatIf`.
  - Output: a PSCustomObject with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and `AZURE_RESOURCE_GROUP`.

- [ ] **Step 1: Write the failing tests**

Create `tests/Scripts.Tests.ps1`:

```powershell
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $scriptPath = Get-RepoPath 'scripts/New-GitHubDeploymentIdentity.ps1'
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
        $global:AzCalls = [System.Collections.Generic.List[string]]::new()
        function global:az {
            $joined = $args -join ' '
            $global:AzCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'account show*') { if ($joined -like '*tenantId*') { return '11111111-1111-1111-1111-111111111111' } return '22222222-2222-2222-2222-222222222222' }
            return ''
        }
        try {
            & $scriptPath -ResourceGroupName 'defenStack' -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
        }
        finally {
            Remove-Item -Path Function:\az
        }
        $mutations = $global:AzCalls | Where-Object { $_ -match '\b(create|delete|update)\b' }
        Remove-Variable -Name AzCalls -Scope Global
        $mutations | Should -BeNullOrEmpty
    }
}
```

The global `az` function shadows the Azure CLI for the duration of the test, so nothing reaches Azure.

- [ ] **Step 2: Run them to confirm they fail**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Scripts.Tests.ps1`
Expected: FAIL (the script does not exist).

- [ ] **Step 3: Write `scripts/New-GitHubDeploymentIdentity.ps1`**

```powershell
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$GitHubRepository,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$EnvironmentName,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$DisplayName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string[]]$DelegatableRoleDefinitionIds = @('ba92f5b4-2d11-453d-a403-e96b0029c9fe'),

    [Parameter()]
    [switch]$GrantLockManagement
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

$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$credentialName = "github-$EnvironmentName"
$subject = "repo:${GitHubRepository}:environment:$EnvironmentName"

Write-Host "Application: $DisplayName"
Write-Host "Federated subject: $subject"
Write-Host "Role assignment scope: $scope"

# 1. Application registration (idempotent by display name).
$appId = az ad app list --display-name $DisplayName --query '[0].appId' --output tsv
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

# 3. Federated credential bound to the GitHub environment.
$existingCredential = $null
if ($appId -ne '<new-application-id>') {
    $existingCredential = az ad app federated-credential list --id $appId --query "[?name=='$credentialName'].name" --output tsv
}
if ([string]::IsNullOrWhiteSpace($existingCredential)) {
    if ($PSCmdlet.ShouldProcess($subject, 'Create federated credential')) {
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
}

function Set-RoleAssignment {
    param(
        [string]$Role,
        [string]$Condition
    )

    $existing = $null
    if ($servicePrincipalId -notlike '<*>') {
        $existing = az role assignment list --assignee $servicePrincipalId --role $Role --scope $scope --query '[0].id' --output tsv
    }
    if (-not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Host "Role '$Role' already assigned at $scope."
        return
    }

    if ($PSCmdlet.ShouldProcess($scope, "Assign '$Role' to $servicePrincipalId")) {
        $arguments = @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $servicePrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $Role,
            '--scope', $scope,
            '--output', 'none'
        )
        if ($Condition) {
            $arguments += @('--condition', $Condition, '--condition-version', '2.0')
        }
        az @arguments
        if ($LASTEXITCODE -ne 0) { throw "Failed to assign '$Role'." }
    }
}

# 4. Least-privilege roles: deploy resources, and assign only the listed data-plane roles.
Set-RoleAssignment -Role 'Contributor'

$roleList = ($DelegatableRoleDefinitionIds | ForEach-Object { $_.ToLowerInvariant() }) -join ', '
$condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))"
Set-RoleAssignment -Role 'Role Based Access Control Administrator' -Condition $condition

# 5. Optional: manage CanNotDelete locks (Contributor cannot write Microsoft.Authorization/locks).
if ($GrantLockManagement) {
    $lockRoleName = 'DefenStack Resource Lock Operator'
    $lockRole = az role definition list --name $lockRoleName --custom-role-only true --query '[0].name' --output tsv
    if ([string]::IsNullOrWhiteSpace($lockRole)) {
        if ($PSCmdlet.ShouldProcess($lockRoleName, 'Create custom role')) {
            $roleFile = New-TemporaryFile
            try {
                @{
                    Name             = $lockRoleName
                    Description      = 'Create, read, and delete management locks for DefenStack deployments.'
                    Actions          = @('Microsoft.Authorization/locks/read', 'Microsoft.Authorization/locks/write', 'Microsoft.Authorization/locks/delete')
                    NotActions       = @()
                    AssignableScopes = @("/subscriptions/$SubscriptionId")
                } | ConvertTo-Json | Set-Content -Path $roleFile -Encoding ASCII

                az role definition create --role-definition "@$roleFile" --output none
                if ($LASTEXITCODE -ne 0) { throw 'Failed to create the lock operator role.' }
            }
            finally {
                Remove-Item $roleFile -Force
            }
        }
    }
    Set-RoleAssignment -Role $lockRoleName
}

$result = [pscustomobject]@{
    AZURE_CLIENT_ID       = $appId
    AZURE_TENANT_ID       = $tenantId
    AZURE_SUBSCRIPTION_ID = $SubscriptionId
    AZURE_RESOURCE_GROUP  = $ResourceGroupName
}

Write-Host ''
Write-Host 'Set these GitHub environment variables:'
foreach ($property in $result.PSObject.Properties) {
    Write-Host "gh variable set $($property.Name) --env $EnvironmentName --repo $GitHubRepository --body '$($property.Value)'"
}

$result
```

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1 -Path tests/Scripts.Tests.ps1`
Expected: PASS. If `makes no Azure or Entra changes under -WhatIf` fails, the failure message lists the mutating `az` call that is not guarded by `ShouldProcess`; guard it.

- [ ] **Step 5: Create `.github/workflows/deploy.yml`**

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
        description: Target environment (prod is added in Phase 1)
        type: choice
        options: [dev]
        default: dev

permissions:
  contents: read
  id-token: write

concurrency:
  group: deploy-${{ inputs.environment || 'dev' }}
  cancel-in-progress: false

env:
  BICEP_VERSION: v0.47.16
  TARGET_ENV: ${{ inputs.environment || 'dev' }}

jobs:
  deploy:
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
        run: az bicep install --version "$BICEP_VERSION"

      - name: Validate
        run: |
          az deployment group validate \
            --resource-group "${{ vars.AZURE_RESOURCE_GROUP }}" \
            --parameters "params/${TARGET_ENV}.bicepparam" \
            --output none

      - name: What-if
        run: |
          az deployment group what-if \
            --resource-group "${{ vars.AZURE_RESOURCE_GROUP }}" \
            --parameters "params/${TARGET_ENV}.bicepparam" \
            --exclude-change-types Ignore NoChange | tee -a "$GITHUB_STEP_SUMMARY"

      - name: Deploy
        run: |
          az deployment group create \
            --resource-group "${{ vars.AZURE_RESOURCE_GROUP }}" \
            --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
            --parameters "params/${TARGET_ENV}.bicepparam" \
            --output table
```

- [ ] **Step 6: Complete runbook 00, §4–§9**

In `docs/runbooks/00-pipeline-and-identity.md`, replace `(completed in Task 12)` under §4 with the following, and add §5, §6, §7 and §9 before the existing §8:

````markdown
1. **Create the GitHub environment `dev`:**

   ```powershell
   gh api --method PUT repos/Godson90/bicep/environments/dev
   ```

   Expected: a JSON response containing `"name": "dev"`.

2. **Preview the identity changes:**

   ```powershell
   az login
   az account set --subscription <subscription-id>
   .\scripts\New-GitHubDeploymentIdentity.ps1 `
     -ResourceGroupName defenStack `
     -GitHubRepository Godson90/bicep `
     -EnvironmentName dev `
     -WhatIf
   ```

   Expected: `What if:` lines for the app registration, service principal, federated credential, `Contributor`, and `Role Based Access Control Administrator`. No changes are made.

3. **Create the identity:** run the same command without `-WhatIf`. Expected: the output object with the four `AZURE_*` values, plus four `gh variable set …` commands.

4. **Set the GitHub environment variables:** run the four printed `gh variable set` commands. They are identifiers, not secrets. Verify:

   ```powershell
   gh variable list --env dev --repo Godson90/bicep
   ```

   Expected: all four variables are listed.

5. **Re-run CI on the Phase 0 PR:**

   ```powershell
   gh run rerun --failed <run-id>
   ```

   Expected: the `what-if` job signs in and posts a "What-if: dev" comment on the PR.

6. **Protect `main`:** this requires a public repo or a paid plan for private repos. Create `protection.json`:

   ```json
   {
     "required_status_checks": { "strict": true, "contexts": ["validate"] },
     "enforce_admins": false,
     "required_pull_request_reviews": { "required_approving_review_count": 0 },
     "restrictions": null
   }
   ```

   Apply it and remove the file:

   ```powershell
   gh api --method PUT repos/Godson90/bicep/branches/main/protection --input protection.json
   Remove-Item protection.json
   ```

## 5. Manual and post-deployment steps
- After merging to `main`, the `deploy` workflow runs automatically for changes under `main.bicep`, `modules/` or `params/`. To deploy manually:

  ```powershell
  gh workflow run deploy -f environment=dev
  ```

- The first merged deployment is the Phase 0 rollout. Complete `docs/runbooks/00a-apply-phase0-fixes.md` §5 manual steps (the F11 role cleanup and F4 verification) after it finishes.

## 6. Validation
| Check | Command | Expected result |
|---|---|---|
| Federated credential | `az ad app federated-credential list --id <AZURE_CLIENT_ID> --query "[].subject" -o tsv` | `repo:Godson90/bicep:environment:dev` |
| Role assignments | `az role assignment list --assignee <AZURE_CLIENT_ID> --scope /subscriptions/<sub>/resourceGroups/defenStack --query "[].{role:roleDefinitionName,condition:condition!=null}" -o table` | `Contributor` (condition False) and `Role Based Access Control Administrator` (condition True) |
| No secrets | `az ad app credential list --id <AZURE_CLIENT_ID>` | `[]` |
| CI gate | `gh pr checks <pr-number>` | `validate` pass, `what-if` pass |

## 7. Rollback
- Disable the pipeline: `gh workflow disable deploy`.
- Remove access:

  ```powershell
  $sp = az ad sp list --filter "appId eq '<AZURE_CLIENT_ID>'" --query "[0].id" -o tsv
  az role assignment list --assignee $sp --all --query "[].id" -o tsv | ForEach-Object { az role assignment delete --ids $_ }
  az ad app delete --id <AZURE_CLIENT_ID>
  ```

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | Job not running in the `dev` environment, or repo name/case mismatch | Confirm `environment: dev` in the job and that the subject equals `repo:Godson90/bicep:environment:dev` |
| `AuthorizationFailed … roleAssignments/write` with condition | Template assigns a role not in `-DelegatableRoleDefinitionIds` | Re-run the script with the role's GUID added (this updates nothing already assigned; delete and recreate the RBAC Administrator assignment to change its condition) |
| `AuthorizationFailed … locks/write` | Prod lock deployed without `-GrantLockManagement` | Re-run the script with `-GrantLockManagement` |
| What-if job skipped | PR is from a fork | Expected; forks never receive Azure tokens |
| Validate fails `params/prod.bicepparam not found` | Prod is not available until Phase 1 | Deploy dev only |

**Security note:** any collaborator who can push a branch can run the `what-if` job with the **dev** identity. That identity can only modify the dev resource group. The prod identity (Phase 1) is bound to the `prod` environment, which has required reviewers and a `main`-only branch policy.
````

- [ ] **Step 7: Run all tests and commit**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

```bash
git add scripts/New-GitHubDeploymentIdentity.ps1 .github/workflows/deploy.yml tests/Scripts.Tests.ps1 docs/runbooks/00-pipeline-and-identity.md
git commit -m "ci: add OIDC deployment identity script, gated deploy workflow, and pipeline runbook (F13)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 8: Execute runbook 00 §4 end-to-end**

Follow runbook 00 §4 steps 1–6 exactly as written, using only the doc. Paste the §6 validation outputs into the PR. Fix the doc if any step was unclear or wrong, and commit the fix with the message `docs: correct runbook 00 after dry run`.

---

### Task 13: README consolidation and Phase 0 rollout to dev

**Files:**
- Modify: `README.md` ("Validate and build" section, new "Documentation" section at the top)
- Modify: `docs/runbooks/00a-apply-phase0-fixes.md` (§8 and the execution record)

**Interfaces:**
- Consumes: all previous tasks.

- [ ] **Step 1: Update the README**

Insert after the first paragraph of `README.md`:

```markdown
### Documentation

- Design: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`
- Runbooks: `docs/runbooks/` - start with `00-pipeline-and-identity.md` and `00a-apply-phase0-fixes.md`
- Runbook structure (mandatory for every change): `docs/runbooks/_template.md`
```

Replace the entire "### Validate and build" section body (the lint/build command list) with:

````markdown
Run all local checks: lint every Bicep file, compile, template assertions, and verify `main.json` is current:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
```

After changing any `.bicep` file, regenerate the committed ARM template:

```powershell
bicep build main.bicep
```

CI (`.github/workflows/bicep-ci.yml`) runs the same tests plus PSRule for Azure on every pull request.
````

In "### Validate against Azure", replace the `--template-file main.bicep --parameters environmentType=dev allowedOutboundFqdns=…` examples with `--parameters params/dev.bicepparam`.

- [ ] **Step 2: Run all tests**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
Expected: all PASS.

- [ ] **Step 3: Execute runbook 00a against dev**

This happens after the Phase 0 PR is reviewed and merged, so the `deploy` workflow performs step 4. Follow `docs/runbooks/00a-apply-phase0-fixes.md` §4–§6 exactly:
1. Compare the what-if from the PR comment or deploy summary line by line with the "Expected what-if" lists in §5. **Stop** if there is any unexpected `Delete`/`Create`, any VNet or subnet prefix change, or any firewall public IP change.
2. After deployment, run the F11 role cleanup and the F4 Key Vault reference verification.
3. Run every §6 validation command.

- [ ] **Step 4: Record the execution in the runbook**

Append to `docs/runbooks/00a-apply-phase0-fixes.md`:

```markdown
## Execution record
| Date (UTC) | Environment | Deployment name | Operator | Result | Notes |
|---|---|---|---|---|---|
```

Add one row for the dev run, with the deployment name from `az deployment group list -g defenStack --query "[0].name" -o tsv`. Paste the §6 outputs into the PR.

Replace the §8 Operations line with:

```markdown
- Firewall saved queries: use `AZFW*` tables (F9).
- Blob restore: see F6/F7 in §5.
- Key Vault deployment references: result of the F4 verification is recorded in the execution record; if it failed, see ADR-001.
- Storage access for new containers: add container-scoped role assignments in Bicep (F11).
- Health check path must track the application's health endpoint (F8).
```

- [ ] **Step 5: Commit and finish**

```bash
git add README.md docs/runbooks/00a-apply-phase0-fixes.md
git commit -m "docs: consolidate README validation steps and record Phase 0 dev rollout

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
git push
```

Mark the PR ready for review with `gh pr ready`. The next step is the Phase 1 plan, written against the merged Phase 0 code.

---

## Self-review (completed while writing)

- **Spec coverage:**

  | Finding | Task |
  |---|---|
  | F1 | 2 |
  | F2 | 2 |
  | F3 | 5 |
  | F4 | 6 |
  | F5 | 3 |
  | F6 | 7 |
  | F7 | 7 |
  | F8 | 9 (plan rename and ZR-on deferred to Phase 1 by the in-place constraint; parameters added) |
  | F9 | 4 (zones param added; enabled in Phase 1) |
  | F10 | 10 (retention; AMPLS in Phase 6 per spec) |
  | F11 | 8 |
  | F12 | 6 |
  | F13 | 1, 11, 12 |

  Runbook 00 is covered by Tasks 11–12, and the §6 documentation standard by Task 1 plus the doc steps in every task.
- **Placeholder scan:** runtime values the engineer supplies (`<storage-account>`, `<subscription-id>`) are marked as environment placeholders. The only dynamic content is the PSRule baseline, which is discovered by a concrete procedure (Task 11 Step 6) because it depends on the PSRule version at execution time.
- **Name consistency checks:**
  - `managementSourceCidrs` is used in Tasks 2 and 3.
  - `blobContainerName` / `storageContainerName` are used in Task 8.
  - `threatIntelMode` and `availabilityZones` are used in Task 4.
  - `enabledForTemplateDeployment` is used in Task 6.
  - Helper function names are defined in Task 1 and used unchanged.
