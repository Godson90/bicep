# Phase 4: Public Ingress (Front Door Premium, WAF, Private Link Origins) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the private App Service reachable by public internet users only through Azure Front Door Premium with a WAF in Prevention mode. Each region's app is reached over Private Link, in failover priority order. The deploy pipeline approves Front Door's private endpoint connections, and an optional custom domain is validated at an external DNS host.

**Architecture:**
- A new module, `modules/frontDoor.bicep`, holds one Premium profile per environment with:
  - an endpoint;
  - a WAF policy (Microsoft Default Rule Set 2.1, Bot Manager 1.1, per-IP rate limit, optional country allow-list);
  - an origin group probing `healthCheckPath`;
  - one Private Link origin (`sites`) per App Service, in priority order;
  - an HTTPS-redirecting route, a security policy, an optional custom domain with a managed certificate, diagnostics, and prod locks.
- `main.bicep` calls the module into `rg-defenstack-<env>-global` after both stamps, because the origins need the stamps' App Service IDs (ADR-018).
- `scripts/Approve-FrontDoorPrivateEndpoints.ps1` approves only connections carrying Front Door's request message `defenstack-frontdoor`. `deploy.yml` runs it after `az deployment sub create`.

**Tech Stack:** Bicep CLI 0.47.16, Azure CLI 2.90+, Windows PowerShell 5.1 / pwsh 7, Pester 5.x, PSRule.Rules.Azure 1.47.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`. The relevant parts are:
- §1 (target architecture)
- §3 "Ingress" (Front Door Premium, WAF, manual PE approval step) and "Connectivity and network security" (DDoS not selected)
- §4 (`frontDoor.bicep`, called from global)
- §5 Phase 4
- §6 documentation standard
- §7 verification ("A Front Door URL returns 200 and a WAF test payload (e.g. `?q=<script>`) returns 403. The direct `*.azurewebsites.net` is refused.")

This plan builds on Phase 3 (`docs/superpowers/plans/2026-09-30-phase3-admin-access.md`). The branch `phase4-ingress` is stacked on `phase3-admin-access` (commit `980ac2c`).

**Verification status of this plan:** every Bicep module, test, script, workflow and document below was prototyped and run before the plan was written. The reference commits are local branches, not for merge: `phase4-proto-t1` (Task 1 state), `phase4-proto-t2` (Task 2 state) and `phase4-prototype` (Task 3 state).
- `bicep lint` and `bicep build` are clean for every file.
- `main.json` is in sync with `bicep build main.bicep`.
- The full Pester suite passes: 267 → **294** (after Task 1) → **304** (Task 2) → **313** (Task 3).
- `Invoke-PSRule` evaluates **788** results with **0** failures, with no change to `ps-rule.yaml` or the suppressions.
- `deploy.yml` parses as YAML.

The embedded content is that verified content. Transcribe it exactly.

## Global Constraints

- **User decisions (binding, taken when this plan was written):**
  - The custom domain is hosted at an **external DNS provider**, and its hostname is **not chosen yet**. `customDomainHostName` is an optional parameter, `''` in both committed parameter files, and runbook 04 covers the TXT validation and CNAME cutover.
  - The WAF runs in **Prevention mode in every environment**, including dev.
  - Front Door's private endpoint connections are approved **by a pipeline step**, with a manual fallback in the runbook.
  - **No geo-filter:** `allowedCountryCodes` defaults to `[]`.
- **Spec values (verbatim):**
  - "Azure Front Door Premium: An origin group with the WUS3 App Service (priority 1) and EUS (priority 2), each reached over Private Link (`sites` group ID). App Service `publicNetworkAccess` stays `Disabled`."
  - "Health probes on `healthCheckPath`."
  - "A custom domain with a managed certificate, HTTPS redirect, and TLS 1.2 minimum."
  - "Front Door WAF policy: Prevention mode, Microsoft Default Rule Set 2.1 plus Bot Manager, rate-limit rule, geo-filter if required."
  - "Manual step (must be in the runbook): approve the Front Door private endpoint connection on each App Service. Script it: `az network private-endpoint-connection approve`."
  - "DDoS: not selected ... recorded in an ADR." ADRs named by the spec: "Front Door over App Gateway", "DDoS not selected".
- **Names:**
  - Profile `afd-defenstack-<env>`, endpoint `fde-defenstack-<env>`, WAF policy `wafdefenstack<env>` (letters and digits only).
  - Origin group `app`, origins `app-<regionCode>`, route `app`, security policy `waf`.
  - Private Link request message `defenstack-frontdoor`. This is a contract between `modules/frontDoor.bicep` and the approval script's `-RequestMessage` default.
- **Placement:** Front Door is deployed from `main.bicep` into `rg-defenstack-<env>-global` after both stamps, **not** from `global.bicep`, to avoid a dependency cycle (ADR-018).
- **Unchanged:** the App Service module, including `publicNetworkAccess: 'Disabled'`; the pipeline identity's roles (Contributor on each RG covers the Front Door resources and `privateEndpointConnectionsApproval/action`); `ps-rule.yaml` and the suppressions.
- **New API versions:**
  - `Microsoft.Cdn/profiles@2024-09-01` and its children (`afdEndpoints`, `originGroups`, `originGroups/origins`, `customDomains`, `afdEndpoints/routes`, `securityPolicies`)
  - `Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01`
- **main.json is generated:** after any `.bicep` change run `bicep build main.bicep` and commit `main.json`. To compare, run `diff --strip-trailing-cr <(bicep build main.bicep --stdout) main.json`; the working copy uses CRLF.
- **Docs are mandatory:** runbooks use the 9-section template.
- **Tests must run on both shells:** Windows PowerShell 5.1 and pwsh 7.
- **No live Azure/Entra/GitHub commands; no push.** Never run the approval script against Azure; its tests use a fake `az`.
- **Commit trailers:** `Co-Authored-By: Claude <model> <noreply@anthropic.com>`.
- **Build output:** never commit `modules/*.json`.
- **PowerShell editing gotchas:**
  - A helper `.ps1` that writes Bicep must not put `${...}` inside a double-quoted string, because PowerShell expands it and silently drops the interpolation. Use single-quoted here-strings (`@'...'@`).
  - A helper containing non-ASCII characters (—, →, ↔, §) must be saved with a UTF-8 BOM, or Windows PowerShell 5.1 misreads it.
  - In a single-quoted PowerShell string, `''` is one `'`.

## Review Focus

These are inputs and conditions the spec implies but no offline test can fully exercise, most likely first:

1. **The site stays down after a first deployment, because the Private Link connection is still Pending.** Front Door creates the connection minutes after the origin exists, so an approval run that finds nothing must wait instead of passing. Pinned by the Task 2 tests "fails when no Front Door connection is approved before the timeout" and "approves a pending Front Door connection", plus the 15-minute default wait.
2. **The pipeline approves a private endpoint request that is not Front Door's.** That would hand an unknown party private access to the app. Pinned by the Task 2 test "never approves a pending connection with a different request message", and by runbook 04 §5.2 (reject and raise an incident).
3. **The direct `*.azurewebsites.net` hostname becomes reachable.** Front Door must not need App Service public access. Pinned by the unchanged App Service module (`publicNetworkAccess: 'Disabled'`, existing tests), the Task 1 Private Link origin test, and runbook 04 §6 (direct → 403).
4. **Failover order is wrong, or the warm standby origin appears without the secondary region.** Pinned by the Task 1 Main test "puts the primary App Service first (priority 1) and the warm standby second, only when deployed" and the FrontDoor test "in failover priority order".
5. **The WAF silently logs instead of blocking.** Pinned by the Task 1 FrontDoor test "blocks in Prevention mode in every environment" and runbook 04 §6 (the `?q=<script>` request returns 403).

Known coverage gap: the custom-domain branch (`customDomainHostName` set) compiles and is asserted structurally, but no committed parameter file sets it, so PSRule never evaluates it. Runbook 04 §5.1 exercises it the first time a domain is added.

## Execution Notes

- **Full suite:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`. It prints `Tests Passed: N, Failed: 0`.
- **Some files only:**

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { `$f = @('tests/FrontDoor.Tests.ps1'); & ./tests/Invoke-Tests.ps1 -Path `$f }"
  ```

- **PSRule:**

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
  ```

  Expected: no failed rules.
- **YAML check:** `powershell.exe -NoProfile -Command "Import-Module powershell-yaml; ConvertFrom-Yaml (Get-Content .github/workflows/deploy.yml -Raw) | Out-Null; 'YAML-OK'"`

## File Map

| File | Responsibility | Task |
|---|---|---|
| `modules/frontDoor.bicep` (new) | Premium profile (system identity), endpoint, WAF policy, origin group, Private Link origins, custom domain (optional), route, security policy, diagnostics, prod locks | 1 |
| `modules/regionStamp.bicep` (replace) | + output `appServiceId` | 1 |
| `main.bicep` (replace), `main.json` (regenerate) | `customDomainHostName` param, origins in failover order, `frontDoor` module in the global RG, Front Door and `appServiceIds` outputs | 1 |
| `params/dev.bicepparam`, `params/prod.bicepparam` (replace) | `customDomainHostName = ''` | 1 |
| `tests/FrontDoor.Tests.ps1` (new); `tests/Main.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Params.Tests.ps1` (replace) | Task 1 tests | 1 |
| `scripts/Approve-FrontDoorPrivateEndpoints.ps1` (new) | Approve only Front Door's pending connections; wait; fail on timeout | 2 |
| `.github/workflows/deploy.yml` (replace) | Approval step after `az deployment sub create` | 2 |
| `tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1` (new); `tests/Workflows.Tests.ps1` (replace) | Task 2 tests | 2 |
| `docs/runbooks/04-ingress.md`, `docs/decisions/ADR-016-*`, `ADR-017-*`, `ADR-018-*` (new) | Phase 4 runbook and ADRs | 3 |
| `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/01-deploy-stack.md`, `README.md` (edit); `tests/Docs.Tests.ps1` (replace) | Phase 4 doc updates and docs tests | 3 |

---

### Task 1: Front Door Premium, WAF, and Private Link origins

**Files:**
- Create: `modules/frontDoor.bicep`, `tests/FrontDoor.Tests.ps1`
- Replace: `modules/regionStamp.bicep`, `main.bicep`, `params/dev.bicepparam`, `params/prod.bicepparam`, `tests/Main.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Params.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes (Phase 3):**
  - Region stamp outputs `appServiceHostName` and `appServiceName`, and the `appService` module output `appServiceAppId`.
  - `global` output `logAnalyticsWorkspaceId`; `main.bicep` variables `globalResourceGroupName`, `primaryRegionCode`, `secondaryRegionCode`, `isProd`; parameter `healthCheckPath`.
- **Produces:**
  - `frontDoor.bicep(profileName, endpointName, wafPolicyName, origins /* 1..5 of { name, appServiceId, hostName, location } */, healthProbePath = '/', customDomainHostName = '', rateLimitThresholdPerMinute = 1000, allowedCountryCodes = [], logAnalyticsWorkspaceId, enableDeleteLock = false)` → outputs `profileName`, `endpointHostName`, `frontDoorId`, `customDomainValidationToken`, `privateLinkRequestMessage`.
  - The variable `privateLinkRequestMessage = 'defenstack-frontdoor'`.
  - Region stamp output `appServiceId`.
  - `main.bicep`:
    - Param `customDomainHostName = ''`.
    - Module symbol `frontDoor`, deployment name `front-door-<env>`.
    - Outputs `frontDoorEndpointHostName`, `frontDoorCustomDomainValidationToken`, `frontDoorPrivateLinkRequestMessage`, and `appServiceIds` (array, primary first). Task 2 consumes `appServiceIds`.

- [ ] **Step 1: Confirm the branch**

  The worktree `.claude/worktrees/phase4-ingress` already exists, on branch `phase4-ingress` at `980ac2c` (the tip of `phase3-admin-access`) plus this plan's commit. Check it: `git log --oneline -2`.

- [ ] **Step 2: Write the failing tests**

  Create `tests/FrontDoor.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/frontDoor.bicep'
      function Get-One([string]$Type) { Get-TemplateResource -Template $template -Type $Type | Select-Object -First 1 }
      $frontDoorProfile = Get-One 'Microsoft.Cdn/profiles'
      $waf = Get-One 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies'
      $originGroup = Get-One 'Microsoft.Cdn/profiles/originGroups'
      $origins = Get-One 'Microsoft.Cdn/profiles/originGroups/origins'
      $route = Get-One 'Microsoft.Cdn/profiles/afdEndpoints/routes'
      $customDomain = Get-One 'Microsoft.Cdn/profiles/customDomains'
      $securityPolicy = Get-One 'Microsoft.Cdn/profiles/securityPolicies'
      $diagnostics = Get-One 'Microsoft.Insights/diagnosticSettings'
      $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks'
  }

  Describe 'Front Door profile (Phase 4)' {
      It 'is a global Premium profile (Private Link origins and managed WAF rule sets need Premium)' {
          $frontDoorProfile.sku.name | Should -Be 'Premium_AzureFrontDoor'
          $frontDoorProfile.location | Should -Be 'global'
      }

      It 'has a system-assigned identity (PSRule Azure.FrontDoor.ManagedIdentity)' {
          $frontDoorProfile.identity.type | Should -Be 'SystemAssigned'
      }

      It 'sends access, health probe and WAF logs to the central workspace' {
          $diagnostics.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
          $diagnostics.properties.logs[0].categoryGroup | Should -Be 'allLogs'
      }

      It 'locks the profile and the WAF policy only when requested' {
          $template.parameters.enableDeleteLock.defaultValue | Should -BeExactly $false
          $locks.Count | Should -Be 2
          foreach ($lock in $locks) {
              $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
              $lock.properties.level | Should -Be 'CanNotDelete'
          }
      }
  }

  Describe 'WAF policy (Phase 4)' {
      It 'blocks in Prevention mode in every environment and inspects request bodies' {
          $waf.sku.name | Should -Be 'Premium_AzureFrontDoor'
          $waf.properties.policySettings.enabledState | Should -Be 'Enabled'
          $waf.properties.policySettings.mode | Should -Be 'Prevention'
          $waf.properties.policySettings.requestBodyCheck | Should -Be 'Enabled'
      }

      It 'runs Microsoft Default Rule Set 2.1 (blocking) and Bot Manager 1.1' {
          $sets = @($waf.properties.managedRules.managedRuleSets)
          $drs = $sets | Where-Object { $_.ruleSetType -eq 'Microsoft_DefaultRuleSet' }
          $drs.ruleSetVersion | Should -Be '2.1'
          $drs.ruleSetAction | Should -Be 'Block'
          ($sets | Where-Object { $_.ruleSetType -eq 'Microsoft_BotManagerRuleSet' }).ruleSetVersion | Should -Be '1.1'
      }

      It 'rate-limits each client IP per minute, 1000 requests by default' {
          $rule = $template.variables.rateLimitRule
          $rule.ruleType | Should -Be 'RateLimitRule'
          $rule.rateLimitDurationInMinutes | Should -Be 1
          $rule.rateLimitThreshold | Should -Be "[parameters('rateLimitThresholdPerMinute')]"
          $rule.action | Should -Be 'Block'
          @($rule.matchConditions[0].matchValue) -join ',' | Should -Be '0.0.0.0/0,::/0'
          $template.parameters.rateLimitThresholdPerMinute.defaultValue | Should -Be 1000
          $waf.properties.customRules.rules | Should -Be "[concat(createArray(variables('rateLimitRule')), variables('geoFilterRules'))]"
      }

      It 'adds a geo-filter only when allowed countries are given (no filtering by default)' {
          @($template.parameters.allowedCountryCodes.defaultValue).Count | Should -Be 0
          $template.variables.geoFilterRules | Should -Match "^\[if\(empty\(parameters\('allowedCountryCodes'\)\), createArray\(\)"
          $template.variables.geoFilterRules | Should -Match "'GeoMatch', 'negateCondition', true\(\)"
      }

      It 'applies the WAF to the endpoint and, when set, the custom domain' {
          $securityPolicy.properties.parameters.type | Should -Be 'WebApplicationFirewall'
          $association = $securityPolicy.properties.parameters.associations[0]
          $association.domains | Should -Match "resourceId\('Microsoft.Cdn/profiles/afdEndpoints'"
          $association.domains | Should -Match "if\(variables\('hasCustomDomain'\)"
          @($association.patternsToMatch) -join ',' | Should -Be '/*'
      }
  }

  Describe 'Origins over Private Link (Phase 4)' {
      It 'creates one origin per entry, at most 5, in failover priority order' {
          $origins.copy.count | Should -Be "[length(parameters('origins'))]"
          $template.parameters.origins.maxLength | Should -Be 5
          $origins.properties.priority | Should -Be '[add(copyIndex(), 1)]'
      }

      It 'reaches each App Service through a sites private link with the approval request message' {
          $link = $origins.properties.sharedPrivateLinkResource
          $link.groupId | Should -Be 'sites'
          $link.privateLink.id | Should -Match 'appServiceId'
          $link.requestMessage | Should -Be "[variables('privateLinkRequestMessage')]"
          $template.variables.privateLinkRequestMessage | Should -Be 'defenstack-frontdoor'
          $template.outputs.privateLinkRequestMessage.value | Should -Be "[variables('privateLinkRequestMessage')]"
      }

      It 'checks the origin certificate name and sends the app hostname as the host header' {
          $origins.properties.enforceCertificateNameCheck | Should -BeExactly $true
          $origins.properties.originHostHeader | Should -Match 'hostName'
      }

      It 'probes the App Service health check path over HTTPS' {
          $originGroup.properties.healthProbeSettings.probePath | Should -Be "[parameters('healthProbePath')]"
          $originGroup.properties.healthProbeSettings.probeProtocol | Should -Be 'Https'
          $originGroup.properties.sessionAffinityState | Should -Be 'Disabled'
      }
  }

  Describe 'Route and custom domain (Phase 4)' {
      It 'redirects HTTP to HTTPS and forwards to origins over HTTPS only' {
          $route.properties.httpsRedirect | Should -Be 'Enabled'
          $route.properties.forwardingProtocol | Should -Be 'HttpsOnly'
          @($route.properties.patternsToMatch) -join ',' | Should -Be '/*'
          $route.properties.linkToDefaultDomain | Should -Be 'Enabled'
      }

      It 'waits for the origins (a route needs at least one origin in its group)' {
          @($route.dependsOn) | Should -Contain 'appOrigins'
      }

      It 'creates the custom domain only when a hostname is given, with a managed TLS 1.2 certificate' {
          $template.parameters.customDomainHostName.defaultValue | Should -Be ''
          $customDomain.condition | Should -Be "[variables('hasCustomDomain')]"
          $customDomain.properties.tlsSettings.certificateType | Should -Be 'ManagedCertificate'
          $customDomain.properties.tlsSettings.minimumTlsVersion | Should -Be 'TLS12'
          $route.properties.customDomains | Should -Match "^\[if\(variables\('hasCustomDomain'\)"
      }

      It 'outputs the endpoint hostname and the TXT validation token for the external DNS host' {
          $template.outputs.endpointHostName.value | Should -Match 'hostName'
          $template.outputs.customDomainValidationToken.value | Should -Match 'validationToken'
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

  Describe 'Public ingress (Phase 4)' {
      BeforeAll {
          $frontDoor = Get-TemplateResourceBySymbol -Template $main -Symbol 'frontDoor'
          $frontDoorParameters = $frontDoor.properties.parameters
      }

      It 'deploys one Front Door per environment into the global resource group, after both stamps' {
          $frontDoor.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $frontDoor.name | Should -Be "[format('front-door-{0}', parameters('environmentName'))]"
          @($frontDoor.dependsOn) | Should -Contain 'primaryStamp'
          @($frontDoor.dependsOn) | Should -Contain 'secondaryStamp'
      }

      It 'names the profile, endpoint and WAF policy with the environment' {
          $frontDoorParameters.profileName.value | Should -Be "[format('afd-defenstack-{0}', parameters('environmentName'))]"
          $frontDoorParameters.endpointName.value | Should -Be "[format('fde-defenstack-{0}', parameters('environmentName'))]"
          $frontDoorParameters.wafPolicyName.value | Should -Be "[format('wafdefenstack{0}', parameters('environmentName'))]"
      }

      It 'puts the primary App Service first (priority 1) and the warm standby second, only when deployed' {
          $value = $frontDoorParameters.origins.value
          $value | Should -Match "^\[concat\(createArray\(createObject\('name', format\('app-\{0\}', variables\('primaryRegionCode'\)\)"
          $value | Should -Match "reference\('primaryStamp'\)\.outputs\.appServiceId\.value"
          $value | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(createObject\('name', format\('app-\{0\}', variables\('secondaryRegionCode'\)\)"
          $value | Should -Match "reference\('secondaryStamp'\)\.outputs\.appServiceId\.value"
          $value.IndexOf('primaryStamp') | Should -BeLessThan $value.IndexOf('secondaryStamp')
      }

      It 'probes the App Service health check path and locks Front Door in prod only' {
          $frontDoorParameters.healthProbePath.value | Should -Be "[parameters('healthCheckPath')]"
          $frontDoorParameters.enableDeleteLock.value | Should -Be "[variables('isProd')]"
      }

      It 'takes an optional custom domain, empty by default' {
          $main.parameters.customDomainHostName.defaultValue | Should -Be ''
          $frontDoorParameters.customDomainHostName.value | Should -Be "[parameters('customDomainHostName')]"
      }

      It 'outputs the endpoint hostname, the TXT validation token, the request message and every App Service ID for approval' {
          foreach ($output in 'frontDoorEndpointHostName', 'frontDoorCustomDomainValidationToken', 'frontDoorPrivateLinkRequestMessage', 'appServiceIds') {
              $main.outputs.PSObject.Properties.Name | Should -Contain $output
          }
          $main.outputs.appServiceIds.type | Should -Be 'array'
          $main.outputs.appServiceIds.value | Should -Match "if\(parameters\('deploySecondaryRegion'\)"
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

  Describe 'Region stamp ingress output (Phase 4)' {
      It 'outputs the App Service resource ID for the Front Door Private Link origin' {
          $stamp.outputs.appServiceId.value | Should -Be "[reference('appService').outputs.appServiceAppId.value]"
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

  Describe 'Front Door custom domain (Phase 4)' {
      It 'leaves the custom domain empty in <_> until the external DNS records exist (runbook 04)' -ForEach 'dev', 'prod' {
          $parameters = if ($_ -eq 'dev') { $dev } else { $prod }
          $parameters.customDomainHostName.value | Should -Be ''
      }
  }
  ```

- [ ] **Step 3: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected failures:
  - `bicep build failed for modules/frontDoor.bicep` in the FrontDoor `BeforeAll`
  - `Resource with symbolic name 'frontDoor' was not found` in `Public ingress (Phase 4)`
  - the `appServiceId` output test
  - the `customDomainHostName` params tests

  Everything else passes.

- [ ] **Step 4: Create the Front Door module**

  Create `modules/frontDoor.bicep`:

  ```bicep
  // Global public ingress: Azure Front Door Premium with WAF, reaching each region's App Service over Private Link.

  @description('Front Door profile name.')
  @minLength(1)
  @maxLength(90)
  param profileName string

  @description('Front Door endpoint name. Azure appends a hash to form <name>-<hash>.z01.azurefd.net.')
  @minLength(1)
  @maxLength(46)
  param endpointName string

  @description('WAF policy name. Letters and digits only, starting with a letter.')
  @minLength(1)
  @maxLength(128)
  param wafPolicyName string

  @description('Origins in failover order: the first entry is priority 1 (active), the next priority 2 (standby). Each entry: { name, appServiceId, hostName, location }.')
  @minLength(1)
  @maxLength(5)
  param origins array

  @description('Relative path Front Door probes on every origin (the App Service health check path).')
  param healthProbePath string = '/'

  @description('Custom domain served by the endpoint, for example app.example.com. Empty serves only the azurefd.net hostname.')
  param customDomainHostName string = ''

  @description('Requests per minute from one client IP before the WAF blocks it.')
  @minValue(100)
  @maxValue(100000)
  param rateLimitThresholdPerMinute int = 1000

  @description('ISO 3166-1 alpha-2 country codes allowed to reach the app. Empty disables geo-filtering.')
  param allowedCountryCodes array = []

  @description('Log Analytics workspace resource ID for access, health probe and WAF logs.')
  param logAnalyticsWorkspaceId string

  @description('Apply CanNotDelete locks to the profile and the WAF policy.')
  param enableDeleteLock bool = false

  // The request message Front Door attaches to each private endpoint connection; the approval script matches on it.
  var privateLinkRequestMessage = 'defenstack-frontdoor'
  var hasCustomDomain = !empty(customDomainHostName)
  var customDomainName = replace(customDomainHostName, '.', '-')

  var rateLimitRule = {
    name: 'RateLimitPerClientIp'
    priority: 100
    enabledState: 'Enabled'
    ruleType: 'RateLimitRule'
    rateLimitDurationInMinutes: 1
    rateLimitThreshold: rateLimitThresholdPerMinute
    matchConditions: [
      {
        matchVariable: 'RemoteAddr'
        operator: 'IPMatch'
        negateCondition: false
        matchValue: [
          '0.0.0.0/0'
          '::/0'
        ]
      }
    ]
    action: 'Block'
  }
  var geoFilterRules = empty(allowedCountryCodes) ? [] : [
    {
      name: 'BlockOutsideAllowedCountries'
      priority: 200
      enabledState: 'Enabled'
      ruleType: 'MatchRule'
      matchConditions: [
        {
          matchVariable: 'SocketAddr'
          operator: 'GeoMatch'
          negateCondition: true
          matchValue: allowedCountryCodes
        }
      ]
      action: 'Block'
    }
  ]

  resource profile 'Microsoft.Cdn/profiles@2024-09-01' = {
    name: profileName
    location: 'global'
    sku: {
      name: 'Premium_AzureFrontDoor'
    }
    // Managed identity for future Key Vault certificate access (customer-managed TLS); managed certificates do not use it.
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      originResponseTimeoutSeconds: 60
    }
  }

  resource endpoint 'Microsoft.Cdn/profiles/afdEndpoints@2024-09-01' = {
    parent: profile
    name: endpointName
    location: 'global'
    properties: {
      enabledState: 'Enabled'
      autoGeneratedDomainNameLabelScope: 'TenantReuse'
    }
  }

  // Prevention mode in every environment: Microsoft Default Rule Set 2.1, Bot Manager 1.1, and a per-IP rate limit.
  resource wafPolicy 'Microsoft.Network/FrontDoorWebApplicationFirewallPolicies@2024-02-01' = {
    name: wafPolicyName
    location: 'Global'
    sku: {
      name: 'Premium_AzureFrontDoor'
    }
    properties: {
      policySettings: {
        enabledState: 'Enabled'
        mode: 'Prevention'
        requestBodyCheck: 'Enabled'
      }
      customRules: {
        rules: concat([
          rateLimitRule
        ], geoFilterRules)
      }
      managedRules: {
        managedRuleSets: [
          {
            ruleSetType: 'Microsoft_DefaultRuleSet'
            ruleSetVersion: '2.1'
            ruleSetAction: 'Block'
          }
          {
            ruleSetType: 'Microsoft_BotManagerRuleSet'
            ruleSetVersion: '1.1'
          }
        ]
      }
    }
  }

  resource originGroup 'Microsoft.Cdn/profiles/originGroups@2024-09-01' = {
    parent: profile
    name: 'app'
    properties: {
      loadBalancingSettings: {
        sampleSize: 4
        successfulSamplesRequired: 3
        additionalLatencyInMilliseconds: 50
      }
      healthProbeSettings: {
        probePath: healthProbePath
        probeRequestType: 'HEAD'
        probeProtocol: 'Https'
        probeIntervalInSeconds: 30
      }
      sessionAffinityState: 'Disabled'
    }
  }

  // Each origin is reached only over Private Link; App Service public network access stays disabled.
  resource appOrigins 'Microsoft.Cdn/profiles/originGroups/origins@2024-09-01' = [for (origin, i) in origins: {
    parent: originGroup
    name: origin.name
    properties: {
      hostName: origin.hostName
      originHostHeader: origin.hostName
      httpPort: 80
      httpsPort: 443
      priority: i + 1
      weight: 1000
      enabledState: 'Enabled'
      enforceCertificateNameCheck: true
      sharedPrivateLinkResource: {
        privateLink: {
          id: origin.appServiceId
        }
        groupId: 'sites'
        privateLinkLocation: origin.location
        requestMessage: privateLinkRequestMessage
      }
    }
  }]

  // Front Door-managed certificate; the domain is validated with a TXT record at the external DNS host (runbook 04).
  resource customDomain 'Microsoft.Cdn/profiles/customDomains@2024-09-01' = if (hasCustomDomain) {
    parent: profile
    name: hasCustomDomain ? customDomainName : 'unused'
    properties: {
      hostName: customDomainHostName
      tlsSettings: {
        certificateType: 'ManagedCertificate'
        minimumTlsVersion: 'TLS12'
      }
    }
  }

  resource route 'Microsoft.Cdn/profiles/afdEndpoints/routes@2024-09-01' = {
    parent: endpoint
    name: 'app'
    properties: {
      originGroup: {
        id: originGroup.id
      }
      customDomains: hasCustomDomain ? [
        {
          id: customDomain.id
        }
      ] : []
      supportedProtocols: [
        'Http'
        'Https'
      ]
      patternsToMatch: [
        '/*'
      ]
      forwardingProtocol: 'HttpsOnly'
      httpsRedirect: 'Enabled'
      linkToDefaultDomain: 'Enabled'
      enabledState: 'Enabled'
    }
    // A route needs at least one origin in its group.
    dependsOn: [
      appOrigins
    ]
  }

  resource securityPolicy 'Microsoft.Cdn/profiles/securityPolicies@2024-09-01' = {
    parent: profile
    name: 'waf'
    properties: {
      parameters: {
        type: 'WebApplicationFirewall'
        wafPolicy: {
          id: wafPolicy.id
        }
        associations: [
          {
            domains: concat([
              {
                id: endpoint.id
              }
            ], hasCustomDomain ? [
              {
                id: customDomain.id
              }
            ] : [])
            patternsToMatch: [
              '/*'
            ]
          }
        ]
      }
    }
  }

  // Access, health probe and WAF logs in the central workspace.
  resource profileDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: profile
    name: 'frontdoor-diagnostics'
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

  resource profileLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: profile
    name: '${profileName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  resource wafPolicyLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableDeleteLock) {
    scope: wafPolicy
    name: '${wafPolicyName}-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }

  output profileName string = profile.name
  output endpointHostName string = endpoint.properties.hostName
  output frontDoorId string = profile.properties.frontDoorId
  output customDomainValidationToken string = hasCustomDomain ? customDomain!.properties.validationProperties.validationToken : ''
  output privateLinkRequestMessage string = privateLinkRequestMessage
  ```

- [ ] **Step 5: Wire it into the stamp outputs, the entry point and the parameter files**

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
  output appServiceId string = appService.outputs.appServiceAppId
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

  @description('Custom domain served by Front Door, for example app.example.com, hosted at an external DNS provider. Empty serves only the azurefd.net hostname.')
  param customDomainHostName string = ''

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

  // Origins in failover order: the primary region first (priority 1), then the warm standby (priority 2).
  var primaryOrigin = {
    name: 'app-${primaryRegionCode}'
    appServiceId: primaryStamp.outputs.appServiceId
    hostName: primaryStamp.outputs.appServiceHostName
    location: primaryLocation
  }
  var secondaryOrigins = deploySecondaryRegion
    ? [
        {
          name: 'app-${secondaryRegionCode}'
          appServiceId: secondaryStamp!.outputs.appServiceId
          hostName: secondaryStamp!.outputs.appServiceHostName
          location: secondaryLocation
        }
      ]
    : []

  // Public ingress: one Front Door per environment in the global resource group, after both stamps exist.
  module frontDoor 'modules/frontDoor.bicep' = {
    name: 'front-door-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      profileName: 'afd-defenstack-${environmentName}'
      endpointName: 'fde-defenstack-${environmentName}'
      wafPolicyName: 'wafdefenstack${environmentName}'
      origins: concat([
        primaryOrigin
      ], secondaryOrigins)
      healthProbePath: healthCheckPath
      customDomainHostName: customDomainHostName
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      enableDeleteLock: isProd
    }
  }

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
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
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
  // Front Door custom domain at the external DNS host; empty until the domain exists (runbook 04).
  param customDomainHostName = ''
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
  // Front Door custom domain at the external DNS host; empty until the domain exists (runbook 04).
  param customDomainHostName = ''
  ```

- [ ] **Step 6: Build, lint, regenerate main.json**

  ```bash
  bicep build main.bicep
  for f in main.bicep modules/*.bicep; do bicep lint "$f" || echo "LINT FAIL $f"; done
  bicep build-params params/dev.bicepparam --stdout > /dev/null && bicep build-params params/prod.bicepparam --stdout > /dev/null && echo PARAMS-OK
  ```

  Expected: no `LINT FAIL` (in particular no `BCP330` warning on the origin `priority`; `@maxLength(5)` on `origins` prevents it), and `PARAMS-OK`.

- [ ] **Step 7: Run the full suite and PSRule**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: `Tests Passed: 294, Failed: 0`.

  Run PSRule (Execution Notes). Expected: 0 failures, 788 results. `Azure.FrontDoor.ManagedIdentity` passes because of the profile's system-assigned identity.

- [ ] **Step 8: Commit**

  ```bash
  git add modules/frontDoor.bicep modules/regionStamp.bicep main.bicep main.json params/dev.bicepparam params/prod.bicepparam tests/FrontDoor.Tests.ps1 tests/Main.Tests.ps1 tests/RegionStamp.Tests.ps1 tests/Params.Tests.ps1
  git commit -m "feat: Front Door Premium with WAF and Private Link origins in failover order" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 2: Private endpoint approval script and pipeline step

**Files:**
- Create: `scripts/Approve-FrontDoorPrivateEndpoints.ps1`, `tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1`
- Replace: `.github/workflows/deploy.yml`, `tests/Workflows.Tests.ps1`

**Interfaces:**
- **Consumes (Task 1):**
  - The `main.bicep` output `appServiceIds` (array of App Service resource IDs).
  - The Private Link request message `defenstack-frontdoor`, from the `frontDoor.bicep` variable `privateLinkRequestMessage`.
  - The deployment name `gh-${{ github.run_id }}-${{ github.run_attempt }}` used by `deploy.yml`'s `az deployment sub create`.
- **Produces:**
  - `Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId <string[]> [-RequestMessage 'defenstack-frontdoor'] [-TimeoutSeconds 900] [-PollIntervalSeconds 30] [-WhatIf]`.
    - It approves only Pending connections whose description equals the request message, with the description `<message> approved by Approve-FrontDoorPrivateEndpoints.ps1`.
    - It warns about any other pending connection and leaves it alone.
    - It throws `... no Front Door private endpoint connection was approved within N seconds ...` when the wait ends with nothing approved.
  - The `deploy.yml` step `Approve Front Door private endpoint connections`, in the `apply` job after `Deploy`.

- [ ] **Step 1: Write the failing tests**

  Create `tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $scriptPath = Get-RepoPath 'scripts/Approve-FrontDoorPrivateEndpoints.ps1'
      $appId = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/app-defenstack-dev-wus3-abc123'

      # Shadows the Azure CLI with a stateful fake: $global:FakeConnections holds the app's connections;
      # 'approve' flips one to Approved, and every call is recorded in $global:AzCalls.
      function Set-FakeConnections([object[]]$Connections) {
          $global:AzCalls = [System.Collections.Generic.List[string]]::new()
          $global:FakeConnections = [System.Collections.Generic.List[object]]::new()
          foreach ($c in $Connections) { $global:FakeConnections.Add($c) }
          function global:az {
              $joined = $args -join ' '
              $global:AzCalls.Add($joined)
              $global:LASTEXITCODE = 0
              if ($joined -like 'network private-endpoint-connection list*') {
                  return (ConvertTo-Json -InputObject @($global:FakeConnections) -Depth 6)
              }
              if ($joined -like 'network private-endpoint-connection approve*') {
                  $id = $args[[array]::IndexOf($args, '--id') + 1]
                  $description = $args[[array]::IndexOf($args, '--description') + 1]
                  foreach ($c in $global:FakeConnections) {
                      if ($c.id -eq $id) {
                          $c.properties.privateLinkServiceConnectionState.status = 'Approved'
                          $c.properties.privateLinkServiceConnectionState.description = $description
                      }
                  }
                  return ''
              }
              return ''
          }
      }

      function Remove-FakeConnections {
          Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
          Remove-Variable -Name FakeConnections -Scope Global -ErrorAction SilentlyContinue
      }

      function New-Connection([string]$Name, [string]$Status, [string]$Description) {
          [pscustomobject]@{
              id         = "$appId/privateEndpointConnections/$Name"
              name       = $Name
              properties = [pscustomobject]@{
                  privateLinkServiceConnectionState = [pscustomobject]@{ status = $Status; description = $Description }
              }
          }
      }

      function Get-Approvals { @($global:AzCalls | Where-Object { $_ -like 'network private-endpoint-connection approve*' }) }
  }

  Describe 'Approve-FrontDoorPrivateEndpoints.ps1 (Phase 4)' {
      AfterEach { Remove-FakeConnections }

      It 'exists, parses, and supports -WhatIf' {
          $scriptPath | Should -Exist
          $tokens = $null; $errors = $null
          [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
          $errors | Should -BeNullOrEmpty
          (Get-Command $scriptPath).Parameters.Keys | Should -Contain 'WhatIf'
      }

      It 'rejects an ID that is not an App Service' {
          { & $scriptPath -AppServiceId '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/kv' } |
              Should -Throw '*does not match*'
      }

      It 'approves a pending Front Door connection and keeps the request message as the description prefix' {
          Set-FakeConnections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
          & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null
          $approvals = @(Get-Approvals)
          $approvals.Count | Should -Be 1
          $approvals[0] | Should -BeLike "*--id $appId/privateEndpointConnections/fd-1 *"
          $global:FakeConnections[0].properties.privateLinkServiceConnectionState.description | Should -BeLike 'defenstack-frontdoor*'
      }

      It 'never approves a pending connection with a different request message' {
          Set-FakeConnections @(
              New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1'
              New-Connection 'someone-else' 'Pending' 'please approve me'
          )
          & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
          Get-Approvals | Should -BeNullOrEmpty
          $global:FakeConnections[1].properties.privateLinkServiceConnectionState.status | Should -Be 'Pending'
          ($warnings -join ' ') | Should -Match 'someone-else'
      }

      It 'returns without approving when the Front Door connection is already approved' {
          Set-FakeConnections @(New-Connection 'fd-1' 'Approved' 'defenstack-frontdoor approved by Approve-FrontDoorPrivateEndpoints.ps1')
          { & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null } | Should -Not -Throw
          Get-Approvals | Should -BeNullOrEmpty
      }

      It 'fails when no Front Door connection is approved before the timeout' {
          Set-FakeConnections @()
          { & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null } | Should -Throw '*no Front Door private endpoint connection was approved*'
      }

      It 'makes no approval under -WhatIf' {
          Set-FakeConnections @(New-Connection 'fd-1' 'Pending' 'defenstack-frontdoor')
          & $scriptPath -AppServiceId $appId -WhatIf | Out-Null
          Get-Approvals | Should -BeNullOrEmpty
      }

      It 'fails when the Azure CLI cannot list connections' {
          Set-FakeConnections @()
          function global:az { $global:LASTEXITCODE = 1; return '' }
          { & $scriptPath -AppServiceId $appId -TimeoutSeconds 0 | Out-Null } | Should -Throw '*Unable to list private endpoint connections*'
      }
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

      It 'runs validate and what-if in the plan job, gated to prod for prod and dev-plan otherwise' {
          $planJob | Should -Match "environment: \$\{\{ inputs\.environment == 'prod' && 'prod' \|\| 'dev-plan' \}\}"
          $planJob | Should -Match 'az deployment sub validate'
          $planJob | Should -Match 'az deployment sub what-if'
          $planJob | Should -Not -Match 'az deployment sub create'
      }

      It 'creates only in the apply job, which waits for plan and runs in the reviewer-gated {env} environment' {
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

      It 'has no prod-plan environment anywhere' {
          $deploy | Should -Not -Match 'prod-plan'
      }

      It 'retains the what-if artifact for 14 days' {
          $planJob | Should -Match 'retention-days: 14'
      }

      It 'overwrites the what-if artifact so a re-run of a failed plan job does not fail on an existing artifact name (Final review D.4)' {
          $planJob | Should -Match 'overwrite: true'
      }
  }

  Describe 'Front Door private endpoint approval (Phase 4)' {
      It 'approves Front Door connections after the deployment, from the deployment outputs' {
          $create = $deploy.IndexOf('az deployment sub create')
          $approve = $deploy.IndexOf('./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $ids')
          $approve | Should -BeGreaterThan $create
          $deploy | Should -Match ([regex]::Escape('--query properties.outputs.appServiceIds.value'))
          $deploy | Should -Match ([regex]::Escape('az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}"'))
      }

      It 'fails the job when the outputs cannot be read' {
          $deploy | Should -Match ([regex]::Escape("throw 'Could not read appServiceIds from the deployment outputs.'"))
      }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected failures:
  - the script tests: `Expected path ... Approve-FrontDoorPrivateEndpoints.ps1 to exist`, and the others because the script is missing;
  - the two `Front Door private endpoint approval (Phase 4)` workflow tests.

- [ ] **Step 3: Create the approval script**

  Create `scripts/Approve-FrontDoorPrivateEndpoints.ps1`:

  ```powershell
  <#
  .SYNOPSIS
  Approves the pending private endpoint connections that Azure Front Door creates on each App Service origin.

  .DESCRIPTION
  Front Door reaches every App Service over Private Link. Each origin creates a private endpoint connection on the
  app that stays Pending until someone approves it, and until then Front Door returns errors for that origin.
  This script approves only connections whose request message is the one modules/frontDoor.bicep sets
  (defenstack-frontdoor by default). Any other pending connection is reported and left alone.

  For each app it waits until a Front Door connection is Approved, approving pending ones as they appear,
  because Front Door creates the connection a few minutes after the origin is deployed.
  Runs in deploy.yml after the deployment, and by hand from runbook 04.

  .EXAMPLE
  ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId /subscriptions/<sub>/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/<app>
  #>
  [CmdletBinding(SupportsShouldProcess)]
  param(
      [Parameter(Mandatory)]
      [ValidateNotNullOrEmpty()]
      [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$')]
      [string[]]$AppServiceId,

      [Parameter()]
      [ValidatePattern('^[A-Za-z0-9-]{1,64}$')]
      [string]$RequestMessage = 'defenstack-frontdoor',

      [Parameter()]
      [ValidateRange(0, 3600)]
      [int]$TimeoutSeconds = 900,

      [Parameter()]
      [ValidateRange(1, 300)]
      [int]$PollIntervalSeconds = 30
  )

  $ErrorActionPreference = 'Stop'

  if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
      throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
  }

  # The approval description keeps the request message as a prefix, so an approved Front Door connection stays recognizable.
  $approvalDescription = "$RequestMessage approved by Approve-FrontDoorPrivateEndpoints.ps1"

  function Get-PrivateEndpointConnections([string]$ResourceId) {
      $json = az network private-endpoint-connection list --id $ResourceId --output json
      if ($LASTEXITCODE -ne 0) {
          throw "Unable to list private endpoint connections for $ResourceId."
      }
      @(($json -join "`n") | ConvertFrom-Json)
  }

  foreach ($id in $AppServiceId) {
      $appName = ($id -split '/')[-1]
      $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
      while ($true) {
          $connections = Get-PrivateEndpointConnections $id
          $states = $connections | ForEach-Object {
              [pscustomobject]@{
                  Id          = $_.id
                  Name        = $_.name
                  Status      = $_.properties.privateLinkServiceConnectionState.status
                  Description = [string]$_.properties.privateLinkServiceConnectionState.description
              }
          }

          foreach ($pending in @($states | Where-Object { $_.Status -eq 'Pending' })) {
              if ($pending.Description -ne $RequestMessage) {
                  Write-Warning "$appName`: leaving pending connection '$($pending.Name)' (request message '$($pending.Description)'): not a Front Door request from this deployment."
                  continue
              }
              if ($PSCmdlet.ShouldProcess($pending.Name, "Approve Front Door private endpoint connection on $appName")) {
                  az network private-endpoint-connection approve --id $pending.Id --description $approvalDescription --output none
                  if ($LASTEXITCODE -ne 0) {
                      throw "Approving private endpoint connection '$($pending.Name)' on $appName failed."
                  }
                  Write-Output "$appName`: approved Front Door connection '$($pending.Name)'."
              }
          }

          if ($WhatIfPreference) {
              break
          }

          $approved = @(Get-PrivateEndpointConnections $id | Where-Object {
                  $_.properties.privateLinkServiceConnectionState.status -eq 'Approved' -and
                  ([string]$_.properties.privateLinkServiceConnectionState.description).StartsWith($RequestMessage)
              })
          if ($approved.Count -gt 0) {
              Write-Output "$appName`: $($approved.Count) Front Door connection(s) approved."
              break
          }

          if ((Get-Date) -ge $deadline) {
              throw "$appName`: no Front Door private endpoint connection was approved within $TimeoutSeconds seconds. Check the origin in the Front Door profile, then re-run this script (runbook 04 §9)."
          }
          Write-Output "$appName`: waiting for Front Door to create its private endpoint connection..."
          Start-Sleep -Seconds $PollIntervalSeconds
      }
  }
  ```

- [ ] **Step 4: Add the pipeline step**

  Replace `.github/workflows/deploy.yml`. The only change from Phase 3 is the final step:

  ````yaml
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
    # Prod: runs in the reviewer-gated prod environment (approve plan, read the what-if, then approve apply) so every prod token needs approval.
    # Dev: runs in dev-plan (no reviewers).
    plan:
      if: github.ref == 'refs/heads/main'
      runs-on: ubuntu-latest
      environment: ${{ inputs.environment == 'prod' && 'prod' || 'dev-plan' }}
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
            retention-days: 14
            if-no-files-found: error
            overwrite: true

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

        # Front Door reaches each App Service over Private Link; its connections stay Pending until approved (runbook 04).
        - name: Approve Front Door private endpoint connections
          shell: pwsh
          run: |
            $ids = az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" --query properties.outputs.appServiceIds.value --output json | ConvertFrom-Json
            if ($LASTEXITCODE -ne 0 -or -not $ids) { throw 'Could not read appServiceIds from the deployment outputs.' }
            ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $ids
  ````

- [ ] **Step 5: Run the full suite and the YAML check**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: `Tests Passed: 304, Failed: 0`.

  Run the YAML check (Execution Notes). Expected: `YAML-OK`.

- [ ] **Step 6: Commit**

  ```bash
  git add scripts/Approve-FrontDoorPrivateEndpoints.ps1 tests/ApproveFrontDoorPrivateEndpoints.Tests.ps1 .github/workflows/deploy.yml tests/Workflows.Tests.ps1
  git commit -m "feat: approve Front Door private endpoint connections from the deploy pipeline" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

### Task 3: Runbook 04, ADR-016/017/018, and Phase 4 documentation updates

**Files:**
- Create: `docs/runbooks/04-ingress.md`, `docs/decisions/ADR-016-front-door-over-application-gateway.md`, `docs/decisions/ADR-017-ddos-network-protection-not-selected.md`, `docs/decisions/ADR-018-front-door-placement-and-private-link-approval.md`
- Replace: `tests/Docs.Tests.ps1`
- Modify: `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/01-deploy-stack.md`, `README.md`

**Interfaces:**
- **Consumes:** the names, outputs, parameters and script from Tasks 1–2 (`afd-defenstack-<env>`, `fde-defenstack-<env>`, `wafdefenstack<env>`, `app-<regionCode>`, `defenstack-frontdoor`, `appServiceIds`, `frontDoorCustomDomainValidationToken`, `Approve-FrontDoorPrivateEndpoints.ps1`). The runbook quotes them verbatim.
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

  Describe 'Phase 4 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/04-ingress.md', 'docs/decisions/ADR-016-front-door-over-application-gateway.md', 'docs/decisions/ADR-017-ddos-network-protection-not-selected.md', 'docs/decisions/ADR-018-front-door-placement-and-private-link-approval.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the ingress runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the ingress runbook covers DNS cutover, WAF tuning and exclusions, and PE approval (spec §5 Phase 4)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          foreach ($topic in 'Custom domain and DNS cutover', 'WAF tuning and exclusions', 'Approving a private endpoint connection by hand', 'az network private-endpoint-connection approve') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the ingress runbook validates the spec checks: Front Door 200, WAF 403, direct App Service 403' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          $text | Should -Match ([regex]::Escape('?q=<script>alert(1)</script>'))
          $text | Should -Match ([regex]::Escape('https://<app>.azurewebsites.net/'))
      }

      It 'the architecture overview draws the ingress flow and lists the Phase 4 ADRs' {
          $text = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          $text | Should -Match 'Azure Front Door Premium \(global'
          foreach ($adr in 'ADR-016', 'ADR-017', 'ADR-018') { $text | Should -Match $adr }
      }

      It 'the cost document has a Phase 4 delta' {
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 4 delta'
      }
  }
  ````

- [ ] **Step 2: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: the `Phase 4 documentation` tests fail (files missing); everything else passes.

- [ ] **Step 3: Create runbook 04**

  Create `docs/runbooks/04-ingress.md`:

  ````markdown
  # 04 - Ingress runbook (Front Door Premium, WAF, Private Link origins, custom domain)

  > Owning module(s): `modules/frontDoor.bicep`, wired by `main.bicep` (module `frontDoor`, deployed into `rg-defenstack-<env>-global` after both region stamps). Approval script: `scripts/Approve-FrontDoorPrivateEndpoints.ps1`, run by `.github/workflows/deploy.yml`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Ingress", §5 Phase 4.

  ## 1. Purpose and scope

  This runbook makes the private App Service reachable by **public internet users**, only through Azure Front Door Premium with a WAF. App Service public network access stays `Disabled`. Front Door reaches each region's app over **Private Link**, so the app's `*.azurewebsites.net` hostname keeps refusing direct requests.

  | Path | Route | Enforced by |
  |---|---|---|
  | User → `https://<endpoint>.azurefd.net` (or the custom domain) | Front Door edge → WAF → origin group `app` → Private Link → App Service (primary, priority 1) | WAF policy (Prevention), HTTPS redirect, TLS 1.2 minimum |
  | Failover | The same, to the East US App Service (priority 2) when the primary fails its health probes (prod only) | Origin group health probes on `healthCheckPath` |
  | User → `https://<app>.azurewebsites.net` | Refused (`403`) | App Service `publicNetworkAccess: Disabled` |

  **Created in `rg-defenstack-<env>-global`:**
  - Front Door profile `afd-defenstack-<env>`: `Premium_AzureFrontDoor`, with a system-assigned identity that is reserved for future customer-managed certificates.
  - Endpoint `fde-defenstack-<env>`, whose hostname is `fde-defenstack-<env>-<hash>.z01.azurefd.net`.
  - Origin group `app`:
    - Health probe: `HEAD` over HTTPS on `healthCheckPath`, every 30 s; 3 of 4 samples must succeed.
    - Origins `app-wus3` (priority 1) and, in prod, `app-eus` (priority 2). Each reaches its App Service over a `sites` Private Link with request message `defenstack-frontdoor`.
  - Route `app`: `/*`; HTTP and HTTPS accepted, HTTP redirected to HTTPS; forwarded to the origin over HTTPS only.
  - WAF policy `wafdefenstack<env>`:
    - **Prevention** mode in every environment, with request body inspection.
    - Managed rule sets: Microsoft Default Rule Set **2.1** (block) and Bot Manager **1.1**.
    - Custom rule `RateLimitPerClientIp`: 1000 requests per minute per client IP.
    - Optional country allow-list, empty by default (no geo-filter).
  - Security policy `waf`, which binds the WAF to the endpoint and to the custom domain when one is set.
  - Diagnostic setting `frontdoor-diagnostics`: access, health probe and WAF logs plus metrics, to `log-defenstack-<env>`.
  - Prod only: `CanNotDelete` locks on the profile and the WAF policy.
  - Custom domain, only when `customDomainHostName` is set: a Front Door-managed certificate, TLS 1.2 minimum, validated by a TXT record at the **external DNS host** (§5.1).

  **Created on each App Service (region resource group):** a private endpoint connection, made by Front Door in a Microsoft-managed network. It starts **Pending**. The deploy pipeline approves it (§4 step 4). Until then, Front Door returns errors for that origin.

  **Not in scope:**
  - Azure DDoS Network Protection (`ADR-017`).
  - Customer-managed certificates.
  - Caching and rules-engine rules.
  - The failover drill (runbook 08, Phase 8).
  - Moving traffic off the old `defenStack` resource group (runbook 01a).

  ## 2. Prerequisites

  - **Azure roles:**
    - The pipeline identity already has what it needs: `Contributor` on the global resource group (Front Door) and on each region resource group, where approving a connection uses `Microsoft.Web/sites/privateEndpointConnectionsApproval/action`.
    - An operator running §5 or §6 needs `Reader` on both resource group types, plus `Contributor` on the region resource group to approve by hand.
  - **Provider registration (new in Phase 4):**

    ```powershell
    az provider register --namespace Microsoft.Cdn
    az provider show --namespace Microsoft.Cdn --query registrationState -o tsv
    ```

    Expected: `Registered`. Repeat the `show` until it is.
  - **Tools:**
    - Azure CLI 2.90+, which includes the `az afd` commands, with the `front-door` extension for the WAF policy commands: `az extension add --name front-door --upgrade`.
    - Bicep CLI 0.47.16.
    - PowerShell 7 or 5.1.
    - `curl`.
  - **Custom domain only:** permission to create TXT and CNAME records at the domain's **external DNS host**. Lower the hostname's TTL to 300 s a day before the cutover (§5.1).
  - **Stack deployed:** Phase 3 (runbook 03) must be deployed to the environment, and the App Service must exist in each deployed region.

  ## 3. Parameters

  | Name | Default | Prod value | Rationale |
  |---|---|---|---|
  | `customDomainHostName` (`main.bicep`, set in `params/<env>.bicepparam`) | `''` | `''` until the domain exists | The hostname served by Front Door, for example `app.example.com`. Empty serves only the `azurefd.net` endpoint. Setting it starts the TXT validation in §5.1 |
  | `healthCheckPath` (`main.bicep`) | `/` | `/` | The App Service health check path. Front Door probes the same path (`ADR-006`) |
  | `rateLimitThresholdPerMinute` (`frontDoor.bicep`) | `1000` | `1000` | Requests per minute from one client IP before the WAF blocks it. Raise it only from measured traffic (§8) |
  | `allowedCountryCodes` (`frontDoor.bicep`) | `[]` | `[]` | No geo-filter (user decision). A non-empty ISO list blocks every other country |
  | WAF `mode` (`frontDoor.bicep`) | `Prevention` | `Prevention` | Prevention in every environment (user decision), so the §6 WAF test returns 403 in dev too |
  | `enableDeleteLock` (`main.bicep`: `isProd`) | `false` | `true` | Prod locks the profile and the WAF policy |

  ## 4. Step-by-step deployment

  1. **Register the provider** (§2) once per subscription.

  2. **Validate and preview** from the repository root:

     ```powershell
     az deployment sub validate --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
     az deployment sub what-if --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
     ```

     `validate` must end with `"provisioningState": "Succeeded"`. In the what-if, check that `rg-defenstack-dev-global` creates `afd-defenstack-dev` and its `afdEndpoints`, `originGroups/origins`, `routes` and `securityPolicies` children, plus `wafdefenstackdev` and `frontdoor-diagnostics`. Expect **no changes** to the App Service, firewall or network resources in the region resource group. Stop if any region resource shows Delete or recreate.

  3. **Deploy through the pipeline**: GitHub → Actions → `deploy` → **Run workflow** → environment `dev` (prod: the two-approval flow in `ADR-012`). Expect 10–20 minutes for the Front Door resources.

  4. **Approval runs automatically.** After `Deploy`, the job runs **Approve Front Door private endpoint connections**. It reads `appServiceIds` from the deployment outputs and calls the approval script, which:
     - waits, by default for up to 15 minutes, for Front Door to create its connection on each app;
     - approves only the connections whose request message is `defenstack-frontdoor`;
     - reports and leaves alone every other pending connection.

     Check: the step log ends with `<app>: 1 Front Door connection(s) approved.` for each app.

     **Deploying from a workstation instead** (or if the step failed), run the same script by hand:

     ```powershell
     $d = az deployment sub list --query "sort_by([?properties.outputs.appServiceIds], &properties.timestamp)[-1].name" -o tsv
     $ids = az deployment sub show --name $d --query properties.outputs.appServiceIds.value -o json | ConvertFrom-Json
     ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $ids
     ```

     Preview it first with `-WhatIf`, which approves nothing and does not wait.

  5. **Record the outputs:**

     ```powershell
     az deployment sub show --name $d --query "properties.outputs.{endpoint:frontDoorEndpointHostName.value, token:frontDoorCustomDomainValidationToken.value, message:frontDoorPrivateLinkRequestMessage.value}" -o table
     ```

     Expected: `endpoint` = `fde-defenstack-dev-<hash>.z01.azurefd.net`; `token` empty (no custom domain); `message` = `defenstack-frontdoor`.

  6. **Wait for propagation.** A new endpoint can return `404` or `Our services aren't available right now` for up to 20 minutes after deployment. Then run §6.

  ## 5. Manual and post-deployment steps

  ### 5.1 Custom domain and DNS cutover (external DNS host)

  Do this once per environment, when the domain exists. The example uses `app.example.com` and endpoint `fde-defenstack-prod-<hash>.z01.azurefd.net`.

  1. **A day before:** lower the TTL of the hostname's current record to 300 seconds at the DNS host, so the cutover propagates quickly.
  2. **Set the parameter** in a PR (`params/prod.bicepparam`):

     ```bicep
     param customDomainHostName = 'app.example.com'
     ```

     Deploy (§4 steps 2–4). The what-if adds `customDomains/app-example-com` and updates the route and security policy.
  3. **Create the validation TXT record** at the DNS host, using the token from the outputs (§4 step 5):

     | Type | Name | Value | TTL |
     |---|---|---|---|
     | TXT | `_dnsauth.app` (FQDN `_dnsauth.app.example.com`) | the `frontDoorCustomDomainValidationToken` output | 300 |

     Check from a workstation: `Resolve-DnsName _dnsauth.app.example.com -Type TXT` returns the token.
  4. **Wait for validation:**

     ```powershell
     az afd custom-domain show --profile-name afd-defenstack-prod --resource-group rg-defenstack-prod-global --custom-domain-name app-example-com --query "{validation:domainValidationState, provisioning:provisioningState}" -o table
     ```

     Expected: `validation` = `Approved`, usually within 10 minutes and up to a few hours. The token expires after 7 days. If it does, run `az afd custom-domain regenerate-validation-token ...`, update the TXT record, and wait again.
  5. **Cut over:** create or replace the hostname record at the DNS host:

     | Type | Name | Value | TTL |
     |---|---|---|---|
     | CNAME | `app` | `fde-defenstack-prod-<hash>.z01.azurefd.net` | 300 |

     An **apex** domain (`example.com`) cannot have a CNAME. Use the DNS host's ALIAS, ANAME or CNAME-flattening record, pointing at the same endpoint hostname. If the host has none, serve `www` and redirect the apex at the DNS host.
  6. **Check the certificate:** Front Door issues the managed certificate after the CNAME resolves, within about an hour. The certificate renews automatically; nothing to rotate.

     ```powershell
     curl.exe -sI https://app.example.com/
     ```

     Expected: `HTTP/1.1 200` (or `HTTP/2 200`), with a certificate issued to `app.example.com`.
  7. Raise the TTL back (3600 s) once traffic is confirmed (§6). Keep the TXT record; Front Door may use it for revalidation.

  ### 5.2 Approving a private endpoint connection by hand

  Use this when the pipeline step cannot run, for example when the pipeline is down.

  ```powershell
  $appId = az webapp show --name <app> --resource-group rg-defenstack-dev-wus3 --query id -o tsv
  az network private-endpoint-connection list --id $appId --query "[].{name:name, status:properties.privateLinkServiceConnectionState.status, message:properties.privateLinkServiceConnectionState.description}" -o table
  ```

  Approve only rows whose `message` is `defenstack-frontdoor`. Keep that text as the start of the description, so the script and §6 still recognize the connection afterwards:

  ```powershell
  az network private-endpoint-connection approve --id "$appId/privateEndpointConnections/<name>" --description "defenstack-frontdoor approved manually by <you>"
  ```

  **Never approve a pending connection with any other message.** Nothing in this project creates one, so it is an unknown party asking for private access to the app. Reject it (`az network private-endpoint-connection reject --id ... --description "unexpected request"`) and raise a security incident.

  ### 5.3 WAF tuning and exclusions

  1. **Find what the WAF blocked** (workspace `log-defenstack-<env>`):

     ```kusto
     AzureDiagnostics
     | where Category == "FrontDoorWebApplicationFirewallLog" and TimeGenerated > ago(24h)
     | where action_s in ("Block", "AnomalyScoring")
     | summarize hits = count() by ruleName_s, requestUri_s, clientIP_s
     | order by hits desc
     ```

  2. **Decide.** A hit is a false positive only when the request is legitimate application traffic. Scanners and probes are expected hits; leave them blocked.
  3. **Fix the narrowest thing first, through a PR to `modules/frontDoor.bicep`:**
     - **Exclusion** (preferred): stop inspecting one named request element for one rule set. Add it to the `Microsoft_DefaultRuleSet` entry:

       ```bicep
       exclusions: [
         {
           matchVariable: 'RequestBodyPostArgNames'
           selectorMatchOperator: 'Equals'
           selector: 'comment'
         }
       ]
       ```

     - **Rule override** (only when an exclusion cannot express it): set one rule to `Log`:

       ```bicep
       ruleGroupOverrides: [
         {
           ruleGroupName: 'SQLI'
           rules: [
             {
               ruleId: '942440'
               enabledState: 'Enabled'
               action: 'Log'
             }
           ]
         }
       ]
       ```

     - Never switch the whole policy to `Detection`, and never disable a rule set, to fix one false positive.
  4. Validate, check the what-if, deploy through the pipeline, then repeat the step 1 query. The hit must now show `action_s == "Log"` or disappear.
  5. Record every exclusion and override in the PR description: the rule ID, the request, and why it is safe.

  ## 6. Validation

  Run from any internet-connected workstation. `$fd` is the endpoint hostname from §4 step 5.

  | Check | Command | Expected result |
  |---|---|---|
  | Front Door serves the app | `curl.exe -s -o NUL -w "%{http_code}" https://$fd/` | `200` |
  | HTTP redirects to HTTPS | `curl.exe -s -o NUL -w "%{http_code} %{redirect_url}" http://$fd/` | `307 https://$fd/` (a 3xx to the HTTPS URL) |
  | WAF blocks an attack payload | `curl.exe -s -o NUL -w "%{http_code}" "https://$fd/?q=<script>alert(1)</script>"` | `403` |
  | WAF logged the block | KQL: `AzureDiagnostics \| where Category == "FrontDoorWebApplicationFirewallLog" and TimeGenerated > ago(1h) and action_s in ("Block","AnomalyScoring") \| project TimeGenerated, ruleName_s, requestUri_s` | A row for the `?q=<script>` request |
  | Direct App Service access is refused | `curl.exe -s -o NUL -w "%{http_code}" https://<app>.azurewebsites.net/` | `403` |
  | Private Link connection approved | `az network private-endpoint-connection list --id $appId --query "[].properties.privateLinkServiceConnectionState.{status:status, message:description}" -o table` | `Approved`, with a message starting `defenstack-frontdoor`; no `Pending` rows |
  | Origins and priorities | `az afd origin list --profile-name afd-defenstack-dev --resource-group rg-defenstack-dev-global --origin-group-name app --query "[].{name:name, priority:priority, enabled:enabledState, privateLink:sharedPrivateLinkResource.status}" -o table` | `app-wus3`, priority `1`, `Enabled`, `Approved` (prod adds `app-eus`, priority `2`) |
  | Origin health | `az monitor metrics list --resource $(az afd profile show -n afd-defenstack-dev -g rg-defenstack-dev-global --query id -o tsv) --metric OriginHealthPercentage --interval PT5M --query "value[0].timeseries[0].data[-1].average"` | `100` |
  | WAF policy settings | `az network front-door waf-policy show -n wafdefenstackdev -g rg-defenstack-dev-global --query "{mode:policySettings.mode, sets:managedRules.managedRuleSets[].[ruleSetType, ruleSetVersion]}" -o json` | `"mode": "Prevention"`; `sets` lists `["Microsoft_DefaultRuleSet", "2.1"]` and `["Microsoft_BotManagerRuleSet", "1.1"]` |
  | Logs arrive | KQL: `AzureDiagnostics \| where Category == "FrontDoorAccessLog" and TimeGenerated > ago(1h) \| summarize count() by httpStatusCode_d` | `200`, `403` and `307` rows from the checks above |
  | Custom domain (when set) | `az afd custom-domain show ... --query "{validation:domainValidationState, tls:tlsSettings.minimumTlsVersion}" -o table` and `Resolve-DnsName app.example.com` | `Approved`, `TLS12`; the name resolves through a CNAME to `$fd` |

  Paste every output into the Phase 4 PR (spec §6 definition of done).

  ## 7. Rollback

  - **Remove the custom domain:**
    1. Set `customDomainHostName = ''` and redeploy, which detaches the domain from the route and the security policy.
    2. Delete the domain resource, because incremental deployments do not delete it: `az afd custom-domain delete --profile-name afd-defenstack-<env> --resource-group rg-defenstack-<env>-global --custom-domain-name <name> --yes`.
    3. Point the CNAME back at the previous target **first**, if one existed, so users never hit a dead name.
  - **Take public ingress down entirely**, which makes the app private-only again:
    1. In prod, delete the two locks (`az lock list -g rg-defenstack-prod-global -o table`, then `az lock delete --ids <id>`).
    2. Run `az afd profile delete --profile-name afd-defenstack-<env> --resource-group rg-defenstack-<env>-global` and `az network front-door waf-policy delete -n wafdefenstack<env> -g rg-defenstack-<env>-global`.
    3. Deleting the profile removes Front Door's private endpoints. Each App Service connection becomes `Disconnected`. Delete those with `az network private-endpoint-connection delete --id <connection id>`.
    4. A later deployment of a Phase 4 commit recreates everything. The new endpoint gets a **new hash**, so update any CNAME.
  - **Revert a WAF change:** revert the PR and redeploy. WAF policy updates apply within minutes, without downtime.

  ## 8. Operations

  - **WAF tuning:** follow §5.3. Review the step 1 query weekly in dev and after every application release in prod.
  - **Rule set upgrades:** when Microsoft publishes a newer Default Rule Set, raise `ruleSetVersion` in a PR, deploy to dev, and run §5.3 for a week before prod. Existing exclusions carry over; overrides may need new rule IDs.
  - **Rate limit:** to size `rateLimitThresholdPerMinute`, check the busiest legitimate client: `AzureDiagnostics | where Category == "FrontDoorAccessLog" | summarize perMinute = count() by clientIp_s, bin(TimeGenerated, 1m) | summarize max(perMinute) by clientIp_s | top 10 by max_perMinute`. Keep the limit well above that.
  - **Adding a region:** a new stamp adds an origin automatically (`main.bicep` origins), and the pipeline approves its connection.
  - **Failover:** traffic moves to the priority 2 origin when the primary fails its health probes. The drill and RTO measurement are in runbook 08 (Phase 8).
  - **Certificates:** managed certificates renew automatically. Nothing to rotate. Check `az afd custom-domain show ... --query tlsSettings` quarterly.
  - **Cost drivers** (`docs/cost.md` "Phase 4 delta"): the Premium base fee per profile per month, requests, and data transfer out from the edge. WAF managed rules and Private Link origins are included in Premium.

  ## 9. Troubleshooting

  | Symptom / error text | Cause | Fix |
  |---|---|---|
  | `Our services aren't available right now` or `404` right after the first deployment | The endpoint and route are still propagating to the edge | Wait up to 20 minutes, then re-run §6 |
  | `502` / `504`, or the origin health metric at `0` | The Private Link connection is still `Pending` (not approved), or the App Service is stopped | Check the §6 Private Link row. Run the approval script (§4 step 4); start the app |
  | Pipeline step fails with `no Front Door private endpoint connection was approved within 900 seconds` | Front Door had not created its connection yet, or the origin failed to provision | `az afd origin show ... --query sharedPrivateLinkResource`, then re-run the script by hand (§4 step 4). If the origin shows `Failed`, redeploy |
  | Pipeline step: `AuthorizationFailed ... privateEndpointConnectionsApproval/action` | The pipeline identity lacks `Contributor` on the region resource group | Re-run the identity script (runbook 00b §4) |
  | Approval script warns `leaving pending connection ... not a Front Door request` | An unexpected private endpoint request on the app | Follow §5.2: reject it and raise a security incident |
  | `MissingSubscriptionRegistration ... Microsoft.Cdn` | Provider not registered | §2 |
  | `403` for legitimate requests; the WAF log shows `Block` | WAF false positive | §5.3 |
  | `429` or `403` from `RateLimitPerClientIp` for a legitimate client | The client exceeds 1000 requests per minute (shared NAT, load test) | Raise `rateLimitThresholdPerMinute` from measured traffic (§8) |
  | Custom domain stuck on `Pending` | The TXT record is missing or wrong, the token expired after 7 days, or the DNS host appended the zone twice (`_dnsauth.app.example.com.example.com`) | Check it with `Resolve-DnsName -Type TXT`; regenerate the token (§5.1 step 4) |
  | Custom domain `Approved`, but the certificate is still `Pending` | The CNAME does not point at the endpoint yet | §5.1 step 5; wait up to an hour |
  | Direct `https://<app>.azurewebsites.net` returns `200` | Someone set the App Service's `publicNetworkAccess` to `Enabled` | Redeploy; the template sets `Disabled`. Find out who changed it from the Activity Log |
  | `curl` to the endpoint shows an old certificate or the old site after the cutover | The client resolver still holds the old TTL | Wait out the TTL; check with `Resolve-DnsName -Server 1.1.1.1` |
  ````

- [ ] **Step 4: Create the ADRs**

  Create `docs/decisions/ADR-016-front-door-over-application-gateway.md`:

  ```markdown
  # ADR-016: Azure Front Door Premium for public ingress, not Application Gateway

  ## Context
  The app must serve **public internet users** through a WAF (spec, user decisions) and fail over from West US 3 to East US. Each region's App Service is private: `publicNetworkAccess: Disabled`, reachable only through private endpoints. Two Azure services fit the "WAF in front of App Service" pattern:

  - **Application Gateway WAF v2** is regional. Active/passive across two regions would need a gateway per region, a public IP per region, and a global DNS or traffic layer such as Traffic Manager on top. Failover would ride on DNS TTLs. Each gateway sits in a VNet subnet and is billed per instance-hour, including in the idle warm standby.
  - **Azure Front Door Premium** is global, at the Microsoft edge. A single origin group holds both regions with priorities, so failover happens within a probe interval and needs no DNS change. Premium can reach an App Service over **Private Link** (`sites`), so the app keeps public access disabled and no region needs an inbound public IP. The WAF (Default Rule Set and Bot Manager) runs at the edge.

  ## Decision
  Use **Azure Front Door Premium** (`Premium_AzureFrontDoor`), one profile per environment in `rg-defenstack-<env>-global` (`modules/frontDoor.bicep`), with:
  - a WAF policy in Prevention mode, with Microsoft Default Rule Set 2.1, Bot Manager 1.1 and a per-IP rate limit;
  - a Private Link origin per region, in priority order (primary 1, standby 2).

  Application Gateway is not deployed.

  ## Consequences
  - No region exposes an inbound public endpoint for the app. The firewall public IP stays egress-only, and Bastion and the VPN gateway serve admins only.
  - Failover is an origin-priority change at the edge, driven by health probes on `healthCheckPath`. The drill is in runbook 08 (Phase 8).
  - Each origin's Private Link connection must be approved on its App Service. The deploy pipeline does it (`ADR-018`).
  - Front Door Premium has a fixed monthly base fee per profile, plus requests and egress (`docs/cost.md` "Phase 4 delta"). Dev pays the base fee too, because the spec's definition of done runs runbook 04 in dev.
  - WAF logs land in `AzureDiagnostics` (`Category == "FrontDoorWebApplicationFirewallLog"`), not a resource-specific table. Runbook 04's KQL uses that table.

  ## Revisit when
  Traffic needs features that only a regional proxy offers (for example, mutual TLS to the client terminated inside the VNet), or a compliance rule requires TLS termination inside the customer's own network.
  ```

  Create `docs/decisions/ADR-017-ddos-network-protection-not-selected.md`:

  ```markdown
  # ADR-017: Azure DDoS Network Protection not selected

  ## Context
  Azure DDoS Network Protection is a per-VNet-plan add-on with a significant fixed monthly fee. It covers public IPs in protected VNets with adaptive tuning, attack telemetry, and cost protection. Every Azure public IP already gets **DDoS infrastructure protection** at no cost.

  After Phase 4, this project's public IPs are:
  - **Application traffic:** none in any region. Users reach the app only through Azure Front Door (`ADR-016`), whose edge absorbs volumetric L3/L4 attacks as part of the platform. The WAF handles L7: Default Rule Set, Bot Manager, and the per-IP rate limit.
  - **The firewall public IP** in each region is egress-only. There is no DNAT rule, so nothing listens on it inbound.
  - **The Bastion and VPN gateway public IPs** (Phase 3) are admin entry points. Both services are Microsoft-managed and authenticate with Entra ID. Losing them to an attack costs admin access, not application availability, and Bastion and the VPN back each other up (runbook 03 §5.6).

  The spec (§3) states: "DDoS: not selected. Front Door absorbs L3/4 attacks at the edge. The firewall PIP is egress-only (no DNAT), so this risk is accepted and recorded in an ADR."

  ## Decision
  Do not deploy a DDoS protection plan. Rely on Front Door edge protection for application traffic, and on the free infrastructure protection for the remaining public IPs.

  ## Consequences
  - No DDoS Network Protection fee.
  - A volumetric attack aimed at a regional public IP, rather than at Front Door, is mitigated only by the platform-level infrastructure protection. There is no adaptive tuning, no attack-analytics telemetry, and no cost-protection credit.
  - An attack on the Bastion or VPN gateway IPs can deny admin access in that region. The break-glass paths (runbook 03 §5.6) use the control plane: `az vm run-command` and serial console.

  ## Revisit when
  - A public IP starts serving application traffic directly, for example a DNAT rule, a public load balancer, or Application Gateway.
  - A regulator or customer contract requires DDoS Network Protection.
  - An incident shows the infrastructure-level protection was insufficient.
  ```

  Create `docs/decisions/ADR-018-front-door-placement-and-private-link-approval.md`:

  ```markdown
  # ADR-018: Front Door deploys from main.bicep after the stamps; the pipeline approves its Private Link connections

  ## Context
  The spec (§4) has `modules/global.bicep` create Front Door. In practice, each Front Door origin needs its App Service's resource ID and hostname, and those come from the region stamps. The stamps in turn need the global layer's workspace and DNS zone IDs. Creating Front Door inside `global.bicep` would therefore form a dependency cycle (global → stamps → global).

  Each Private Link origin also creates a private endpoint connection on its App Service that stays **Pending** until the app's owner approves it. The spec (§3) requires this manual step to be in the runbook and scripted with `az network private-endpoint-connection approve`. When Phase 4 was planned, the user chose to have the deploy pipeline run that script.

  ## Decision
  - `main.bicep` calls `modules/frontDoor.bicep` as a separate module, `frontDoor`, scoped to `rg-defenstack-<env>-global` and deployed after both stamps. Front Door therefore lives in the global resource group as the spec intends, but is not created by `global.bicep`.
  - Origins are built in `main.bicep`: the primary stamp's app first (priority 1), then the secondary stamp's app (priority 2) when `deploySecondaryRegion` is true.
  - Every origin sets the Private Link request message `defenstack-frontdoor`. `scripts/Approve-FrontDoorPrivateEndpoints.ps1` approves **only** pending connections carrying that exact message. It writes an approval description that starts with the same text, so approved connections stay recognizable. It waits up to 15 minutes for Front Door to create each connection, and fails the job if none is approved.
  - `deploy.yml` runs the script in the `apply` job right after `az deployment sub create`, reading the `appServiceIds` deployment output.
  - The custom domain is an optional parameter (`customDomainHostName`), empty in both committed parameter files until the domain exists. The domain is hosted at an external DNS provider, so the TXT validation and CNAME cutover are manual steps (runbook 04 §5.1).

  ## Consequences
  - A new region or a recreated profile becomes reachable without an operator. A Pending connection never sits unnoticed, because the job fails when no approval happens.
  - The pipeline identity approves connections using its existing `Contributor` on the region resource groups. No new role is needed.
  - A pending connection with any other message is never approved automatically. The script warns, and runbook 04 §5.2 treats it as a security incident.
  - The request message is a shared contract between `modules/frontDoor.bicep` (the `privateLinkRequestMessage` variable, also an output) and the script's `-RequestMessage` default. Changing one requires changing the other.

  ## Revisit when
  Azure supports auto-approval of Front Door Private Link connections for a trusted profile, or the custom domain moves to an Azure DNS zone (Bicep could then write the TXT and CNAME records).
  ```

- [ ] **Step 5: Update the existing documents**

  Each edit below is an exact find/replace. The find text occurs once in the file. If a find text is not found, stop and report it; do not paraphrase. These files contain non-ASCII characters (—, →, ↔, §): read and write them as UTF-8.

  **`docs/architecture/overview.md`, edit 1 of 8.** Find:

  ```markdown
  # Architecture overview: Phase 1-3 (subscription-scope, multi-region, Premium firewall, admin access)
  ```

  Replace with:

  ```markdown
  # Architecture overview: Phase 1-4 (subscription-scope, multi-region, Premium firewall, admin access, public ingress)
  ```

  **`docs/architecture/overview.md`, edit 2 of 8.** Find:

  ```markdown
  `modules/bastion.bicep`, `modules/vpnGateway.bicep`. Spec:
  ```

  Replace with:

  ```markdown
  `modules/bastion.bicep`, `modules/vpnGateway.bicep`, `modules/frontDoor.bicep`. Spec:
  ```

  **`docs/architecture/overview.md`, edit 3 of 8.** Find:

  ```markdown
  What later phases add (not present after Phase 3):

  | Phase | Adds |
  |---|---|
  | 4 | Azure Front Door Premium + WAF (public ingress) |
  ```

  Replace with:

  ```markdown
  **Phase 4** added public ingress: one Azure Front Door Premium profile per
  environment in the global resource group, with a WAF in Prevention mode
  (Default Rule Set 2.1, Bot Manager 1.1, per-IP rate limit). It reaches each
  region's App Service over Private Link: the primary first (priority 1), then
  the warm standby (priority 2). App Service public access stays disabled. The
  deploy pipeline approves Front Door's private endpoint connections
  (`ADR-016`, `ADR-018`). See §3 "Ingress" and
  [runbook 04](../runbooks/04-ingress.md).

  What later phases add (not present after Phase 4):

  | Phase | Adds |
  |---|---|
  ```

  **`docs/architecture/overview.md`, edit 4 of 8.** Find:

  ```markdown
  ### Ingress

  None yet. There is no public entry point in Phase 1 — App Service, Key Vault and Storage all have public network access disabled and only private endpoints reach them. The app remains private-only until Phase 4 adds Azure Front Door Premium with WAF.
  ```

  Replace with:

  ````markdown
  ### Ingress

  Public users reach the app only through Azure Front Door Premium (`ADR-016`); full procedures are in [runbook 04](../runbooks/04-ingress.md).

  ```mermaid
  flowchart LR
      USER["Internet user"]
      subgraph EDGE["Azure Front Door Premium (global, rg-defenstack-env-global)"]
          EP["Endpoint fde-defenstack-env (custom domain optional)"]
          WAF["WAF wafdefenstackenv: Prevention, DRS 2.1, Bot Manager 1.1, rate limit"]
          OG["Origin group app: health probe on healthCheckPath"]
      end
      subgraph WUS3["West US 3 (primary)"]
          APP1["App Service (public access disabled)"]
      end
      subgraph EUS["East US (warm standby, prod only)"]
          APP2["App Service (public access disabled)"]
      end
      USER -->|"HTTPS (HTTP redirected)"| EP
      EP --> WAF
      WAF --> OG
      OG -->|"priority 1, Private Link (sites)"| APP1
      OG -.->|"priority 2, Private Link (sites)"| APP2
      USER -.->|"direct *.azurewebsites.net: 403"| APP1
  ```

  - Each origin's private endpoint connection on its App Service is approved by the deploy pipeline (`scripts/Approve-FrontDoorPrivateEndpoints.ps1`), which approves only requests with the message `defenstack-frontdoor` (`ADR-018`).
  - The custom domain (`customDomainHostName`) is hosted at an external DNS provider. It is empty until the domain exists; runbook 04 §5.1 covers the TXT validation and CNAME cutover.
  - No region has an inbound public IP for the app, and DDoS Network Protection is not deployed (`ADR-017`).
  ````

  **`docs/architecture/overview.md`, edit 5 of 8.** Find:

  ```markdown
  | `names.vpnGatewayPublicIp` | `pip-vpng-defenstack-<env>-<regionCode>-<1\|2>` (one per active-active instance) | `pip-vpng-defenstack-dev-wus3-1` |
  ```

  Replace with:

  ```markdown
  | `names.vpnGatewayPublicIp` | `pip-vpng-defenstack-<env>-<regionCode>-<1\|2>` (one per active-active instance) | `pip-vpng-defenstack-dev-wus3-1` |
  | Front Door profile (`main.bicep`) | `afd-defenstack-<env>` | `afd-defenstack-dev` |
  | Front Door endpoint | `fde-defenstack-<env>` (hostname `fde-defenstack-<env>-<hash>.z01.azurefd.net`) | `fde-defenstack-dev-<hash>.z01.azurefd.net` |
  | WAF policy | `wafdefenstack<env>` | `wafdefenstackdev` |
  | Front Door origin | `app-<regionCode>` | `app-wus3` |
  ```

  **`docs/architecture/overview.md`, edit 6 of 8.** Find:

  ```markdown
  `privatelink.azurewebsites.net`, `privatelink.vaultcore.azure.net`, each with 2 VNet links (dev-wus3 hub and spoke) |
  ```

  Replace with:

  ```markdown
  `privatelink.azurewebsites.net`, `privatelink.vaultcore.azure.net`, each with 2 VNet links (dev-wus3 hub and spoke); Front Door Premium `afd-defenstack-dev` (endpoint `fde-defenstack-dev`, origin `app-wus3`, route `app`, security policy `waf`) and WAF policy `wafdefenstackdev` |
  ```

  **`docs/architecture/overview.md`, edit 7 of 8.** Find:

  ```markdown
  DNS zones, each with 4 VNet links (wus3 hub, wus3 spoke, eus hub, eus spoke); `enableDeleteLock: true` on the zones and the workspace |
  ```

  Replace with:

  ```markdown
  DNS zones, each with 4 VNet links (wus3 hub, wus3 spoke, eus hub, eus spoke); Front Door Premium `afd-defenstack-prod` with origins `app-wus3` (priority 1) and `app-eus` (priority 2), and WAF policy `wafdefenstackprod`; `enableDeleteLock: true` on the zones, the workspace, the Front Door profile and the WAF policy |
  ```

  **`docs/architecture/overview.md`, edit 8 of 8.** Find:

  ```markdown
  - [ADR-015: VPN gateway: VpnGw1AZ in dev, VpnGw2AZ in prod, always active-active](../decisions/ADR-015-vpn-gateway-sku-and-active-active.md)
  ```

  Replace with:

  ```markdown
  - [ADR-015: VPN gateway: VpnGw1AZ in dev, VpnGw2AZ in prod, always active-active](../decisions/ADR-015-vpn-gateway-sku-and-active-active.md)
  - [ADR-016: Azure Front Door Premium for public ingress, not Application Gateway](../decisions/ADR-016-front-door-over-application-gateway.md)
  - [ADR-017: Azure DDoS Network Protection not selected](../decisions/ADR-017-ddos-network-protection-not-selected.md)
  - [ADR-018: Front Door deploys from main.bicep after the stamps; the pipeline approves its Private Link connections](../decisions/ADR-018-front-door-placement-and-private-link-approval.md)
  ```

  **`docs/cost.md`, edit 1 of 1.** Find:

  ```markdown
  ## Dominant future cost drivers
  From `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §6, the
  resources expected to dominate spend in later phases (not present in Phase 0).
  The VPN gateway and Azure Bastion arrived in Phase 3 (see "Phase 3 delta"):
  - Azure Front Door Premium
  ```

  Replace with:

  ```markdown
  ## Phase 4 delta
  Phase 4 adds one Azure Front Door Premium profile per environment, in the
  global resource group, serving both regions. As with every phase, **fill in
  the actual dollar estimate from the Pricing Calculator; do not invent prices.**

  | Environment | Cost driver | What changed / why it costs more |
  |---|---|---|
  | Dev | Front Door **Premium** base fee ×1 | A fixed monthly fee per profile, billed even with no traffic. Dev needs it to run runbook 04 (`ADR-016`) |
  | Dev | Requests and data transfer out from the edge | Per 10,000 requests and per GB out; small in dev |
  | Prod | Front Door Premium base fee ×1 (one profile covers both regions) | The East US origin adds no Front Door fee; it is the same profile |
  | Prod | Requests and data transfer out from the edge | Scales with user traffic; measure with the access log (`AzureDiagnostics`, `Category == "FrontDoorAccessLog"`) |
  | Both | WAF managed rule sets, Bot Manager, Private Link origins | Included in the Premium SKU; no separate WAF policy or rule charges |
  | Both | Front Door log ingestion into Log Analytics | Access, health probe and WAF logs (`allLogs`); measure with the `Usage` KQL pattern on `AzureDiagnostics` |
  | Both | DDoS Network Protection | Not deployed (`ADR-017`), so no fee |

  **Estimate:** fill in from the Pricing Calculator (Azure Front Door: Premium
  tier, one profile; requests and outbound data from a week of dev access logs,
  scaled to expected prod traffic).

  ## Dominant future cost drivers
  From `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §6, the
  resources expected to dominate spend in later phases (not present in Phase 0).
  The VPN gateway and Azure Bastion arrived in Phase 3, and Azure Front Door
  Premium in Phase 4 (see their deltas):
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 1 of 1.** Find:

  ```markdown
  on the jump host (runbook 03 §4) |
  ```

  Replace with:

  ```markdown
  on the jump host (runbook 03 §4) |
  | `customDomainHostName` | `''` | `''` | `''` until the domain exists | Front Door custom domain at the external DNS host ([runbook 04](04-ingress.md) §5.1) |
  ```

  **`README.md`, edit 1 of 1.** Find:

  ```markdown
  jump host sign-in, break-glass)
  ```

  Replace with:

  ```markdown
  jump host sign-in, break-glass), and `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover)
  ```

- [ ] **Step 6: Run the full suite**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`
  Expected: `Tests Passed: 313, Failed: 0`.

  Encoding check: `grep -rln $'\xEF\xBF\xBD' docs README.md --exclude-dir=superpowers` prints nothing.

- [ ] **Step 7: Commit**

  ```bash
  git add docs/runbooks/04-ingress.md docs/decisions/ADR-016-front-door-over-application-gateway.md docs/decisions/ADR-017-ddos-network-protection-not-selected.md docs/decisions/ADR-018-front-door-placement-and-private-link-approval.md docs/architecture/overview.md docs/cost.md docs/runbooks/01-deploy-stack.md README.md tests/Docs.Tests.ps1
  git commit -m "docs: runbook 04 ingress, ADR-016/017/018, and Phase 4 documentation updates" -m "Co-Authored-By: Claude <model> <noreply@anthropic.com>"
  ```

---

## After the last task (human, not the implementer)

Run by a person following only runbook 04, in dev (spec §6 definition of done):

1. §2 provider registration; §4 steps 2–6 (validate/what-if, pipeline deploy, automatic approval, outputs, propagation).
2. Every §6 validation row: Front Door 200, HTTP→HTTPS redirect, WAF 403 and its log row, direct App Service 403, Private Link `Approved`, origin health 100.
3. Paste the outputs into the Phase 4 PR.
4. When the domain is chosen: §5.1 (set `customDomainHostName`, TXT validation, CNAME cutover) as its own PR.

