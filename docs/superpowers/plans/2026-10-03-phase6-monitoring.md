# Phase 6: Monitoring, Detection and Response (Private-Only Azure Monitor, Hub Peering, Flow Logs, Activity Log, Sentinel, Alerts) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the platform observable and defended without opening Azure Monitor to the internet:
- private-only ingestion and query for the workspace and every Application Insights component, through one Azure Monitor Private Link Scope (AMPLS);
- in prod with DR, hub-to-hub global peering so East US telemetry reaches the one AMPLS endpoint in West US 3;
- VNet flow logs with Traffic Analytics for both regions, written by a managed identity to a keyless account;
- the subscription Activity Log in the workspace, and Microsoft Sentinel on the workspace;
- one action group per environment, emailing `ALERT_EMAIL`, with platform metric, Front Door and Service Health alerts.

**Architecture:**
- **Private-only monitoring.** `modules/global.bicep` creates every private DNS zone (now seven, including the four Azure Monitor zones) and its prod lock in one loop. `modules/monitorPrivateLinkScope.bicep` creates the PrivateOnly/PrivateOnly scope `ampls-defenstack-<env>` in the global resource group and scopes the workspace and every component. `modules/monitorPrivateEndpoint.bicep` puts the single `azuremonitor` endpoint in the primary spoke's private-endpoint subnet. `modules/monitoring.bicep` and `modules/appInsights.bicep` disable public ingestion and query.
- **Cross-region path (prod with DR).** `modules/hubPeering.bicep` peers the hubs both ways from `main.bicep`. `modules/hubNetwork.bicep` gives `AzureFirewallSubnet` a route table to the other region's spoke through the other firewall, plus `0.0.0.0/0 → Internet`. `modules/firewallPolicyRules.bicep` adds the `cross-region-monitoring` group: a network rule in East US (Client) and an SNATing application rule to the Azure Monitor FQDNs in West US 3 (Host).
- **Flow logs.** `modules/flowLogStorage.bicep` creates a keyless, private regional account, a user-assigned identity and its Storage Blob Data Contributor assignment on that account. `modules/flowLogs.bicep` is deployed into `NetworkWatcherRG` under the existing `NetworkWatcher_<region>` and logs the hub and spoke VNets, with Traffic Analytics to the workspace.
- **Activity Log and Sentinel.** `modules/activityLog.bicep` (subscription scope) sends every Activity Log category to the workspace. `modules/monitoring.bicep` onboards the workspace to Sentinel through `Microsoft.SecurityInsights/onboardingStates`.
- **Alerts.** `modules/actionGroup.bicep`, a generic typed `modules/metricAlerts.bicep` (regional rules in each stamp, Front Door rules in `main.bicep`) and `modules/serviceHealthAlert.bicep`. `deploy.yml` and `bicep-ci.yml` pass `alertEmail` from `vars.ALERT_EMAIL`, and the prod apply stops when it is empty.
- **Pipeline identity.** `scripts/New-GitHubDeploymentIdentity.ps1` grants Network Contributor on `NetworkWatcherRG`, adds the three diagnostic-setting actions to the subscription custom role, and updates an existing custom role in place.

**Tech Stack:** Bicep CLI 0.47.16, Azure CLI 2.90+, Windows PowerShell 5.1 / pwsh 7, Pester 5.x, PSRule 2.9.0 with PSRule.Rules.Azure 1.47.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`. The relevant parts are §3 "Monitoring, detection and response", §5 Phase 6 (row 6), and §6 documentation standard.

This plan builds on Phase 5 (`docs/superpowers/plans/2026-10-02-phase5-app-data.md`). The branch `phase6-monitoring` is stacked on `phase5-app-data` (commit `31df32e`).

**Verification status of this plan:** every Bicep module, test, script, workflow and document below was prototyped and run before the plan was written. The reference commits are local branches, not for merge: `phase6-proto-t1` … `phase6-proto-t5` (the state after Tasks 1–5) and `phase6-prototype` (the state after Task 6).
- `bicep lint` and `bicep build` are clean for every file.
- `main.json` is in sync.
- The full Pester suite passes: 390 → **414** (Task 1) → **442** (Task 2) → **464** (Task 3) → **483** (Task 4) → **523** (Task 5) → **538** (Task 6).
- `Assert-PSRule` reports 0 failures and 0 errors: 871 → **971** rules processed (Task 1) → **993** (Task 2) → **1088** (Task 3) → **1104** (Task 4) → **1200** (Task 5 and Task 6). No new suppression was needed.
- `deploy.yml` and `bicep-ci.yml` parse as YAML.
- The prototype ran on Windows PowerShell 5.1 only, because pwsh 7 was not installed. The new tests use no 7-only syntax, but run them on pwsh 7 too (see Global Constraints).

The embedded content is that verified content. Transcribe it exactly.

## Global Constraints

- **User decisions (binding, taken when this plan was written):**
  - **AMPLS: private ingestion and private query.**
    - One AMPLS for the whole platform, `accessModeSettings` ingestion `PrivateOnly` and query `PrivateOnly`.
    - Scoped resources: the workspace plus every App Insights component, primary and, in prod, secondary.
    - One `azuremonitor` private endpoint, in the **primary spoke's existing private-endpoint subnet**.
    - Four zones added to the shared zone set and linked like the existing zones: `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net`. The existing blob zone is reused.
    - The workspace and the App Insights components use `publicNetworkAccessForIngestion: 'Disabled'` and `publicNetworkAccessForQuery: 'Disabled'`. This replaces Phase 5's "Enabled until Phase 6".
    - Prod locks apply wherever the existing pattern locks the DNS zones (ADR-022).
  - **Hub↔hub global VNet peering, prod only** (when `deploySecondaryRegion`), brought forward from Phase 8 (ADR-022).
    - Hub to hub both ways, `allowForwardedTraffic: true`, no gateway transit.
    - Each `AzureFirewallSubnet` gets a route table: the remote spoke prefix(es) to the remote firewall private IP, plus `0.0.0.0/0 → Internet`.
    - Minimal rules: only the East US spoke subnets reach the AMPLS private endpoint on TCP 443, in both policies as needed for symmetric traversal. Broader DR traffic waits for Phase 8.
  - **Microsoft Sentinel in dev and prod:** `Microsoft.SecurityInsights/onboardingStates` `default`, an extension resource on the workspace.
  - **Alerts go to the email in the GitHub variable `ALERT_EMAIL`.** One action group per environment, in the global resource group, with an email receiver when the address is non-empty. `deploy.yml` passes `alertEmail` from `vars.ALERT_EMAIL`, and a step fails the prod apply early when it is empty.
- **Approved design (binding):**
  - Flow logs per region to a dedicated account: shared key disabled, public network access disabled, `networkAcls.bypass: 'AzureServices'`, `defaultAction: 'Deny'`. A user-assigned identity gets **Storage Blob Data Contributor** (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`, already delegatable) on that account only. Managed identity auth, 90-day retention, Traffic Analytics to the central workspace every 10 minutes (ADR-023).
  - The subscription Activity Log diagnostic setting covers all categories. The subscription custom role gains `Microsoft.Insights/diagnosticSettings/read`, `/write` and `/delete`, named explicitly, never as a wildcard.
  - Sentinel connectors: Azure Activity comes through the Activity Log setting; firewall, Key Vault and WAF data already flows through the existing diagnostic settings. Content Hub solutions, analytics rule templates, the Entra ID connector (tenant admin) and the tenant-based Defender for Cloud connector are manual steps in runbook 06 (ADR-024).
  - Retention stays 90 days. The backup job alert is deferred to Phase 8, and the docs say so.
- **Spec values (verbatim):**
  - "**Azure Monitor Private Link Scope (AMPLS)**, one for the whole network, private-only ingestion and query mode."
  - "**VNet flow logs** (the NSG flow-log replacement) for both regions: to a dedicated flow-log storage account, plus **Traffic Analytics** to the workspace. Verify whether identity-based storage access is supported given shared key is disabled; otherwise document the exception." Identity-based access is supported from `flowLogs@2024-01-01`, so no exception is needed (ADR-023).
  - "**Subscription Activity Log** diagnostic setting to the workspace."
  - "**Microsoft Sentinel** on the central workspace. Data connectors: Azure Activity, Defender for Cloud, Azure Firewall, Key Vault, Front Door WAF, and Entra ID (tenant admin; a manual runbook step). Enable the analytics rule templates."
  - "Firewall health below 90% and SNAT utilisation", "Front Door origin health, and WAF block spikes", "App Service 5xx and health check", "Key Vault availability and denied requests", "VPN gateway P2S connection count", "Backup job failure" (deferred to Phase 8), "Service Health for both regions".
  - §5 row 6: "AMPLS, flow logs and Traffic Analytics, Activity Log, alerts, retention, Sentinel and connectors", doc `06-monitoring-and-sentinel.md` ("alert triage, Sentinel connector enablement").
- **New API versions:**
  - `Microsoft.Insights/privateLinkScopes@2021-09-01` and `.../scopedResources@2021-09-01` (last GA)
  - `Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01`, `Microsoft.Network/routeTables@2024-07-01`
  - `Microsoft.Network/networkWatchers@2024-07-01` (`existing`) and `Microsoft.Network/networkWatchers/flowLogs@2024-07-01`
  - `Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31`
  - `Microsoft.SecurityInsights/onboardingStates@2024-03-01`
  - `Microsoft.Insights/actionGroups@2023-01-01`, `Microsoft.Insights/metricAlerts@2018-03-01`, `Microsoft.Insights/activityLogAlerts@2020-10-01` (the last versions confirmed GA; newer unlabeled versions such as `metricAlerts@2026-01-01` are not used)
  - Existing versions for private endpoints and zone groups (`2024-07-01`), DNS zones (`2024-06-01`), locks (`2020-05-01`), storage (`2026-04-01`), role assignments (`2022-04-01`), firewall rule collection groups (`2025-01-01`), VNets (`2025-09-01`) and the workspace (`2026-03-01`).
- **Preview API exception (ADR-025):** the subscription Activity Log setting uses `Microsoft.Insights/diagnosticSettings@2021-05-01-preview`, the only version that supports subscription scope. No other preview version is allowed. The fallback, if ARM rejects it, is `az monitor diagnostic-settings subscription create` (runbook 06 §9).
- **Prerequisite: `NetworkWatcherRG` and `NetworkWatcher_<region>` must exist** in the subscription for `westus3` (and `eastus` in prod) before the identity script runs and before the first deployment. Azure creates them with the first VNet in a region unless the subscription opted out. Otherwise: `az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true`, after `az group create --name NetworkWatcherRG --location westus3` only if `az group exists --name NetworkWatcherRG` prints `false` (runbooks 06, 00b, 01).
- **`ALERT_EMAIL`** is a GitHub environment **variable** (not a secret) on `dev`, `dev-plan` and `prod`. The workflows pass it as `--parameters alertEmail="$ALERT_EMAIL"`. Empty is allowed in dev (no receiver) and refused in prod by the `Require ALERT_EMAIL for prod` step, before checkout and login.
- **Unchanged:** workspace retention (90 days); the Phase 1–5 zone names and lock names (`<key>-zone-lck`), so Azure replaces nothing; dev and prod-without-DR routing and firewall rules; regions and address plan.
- **PSRule:** no new suppression. The dev LRS flow-log account is covered by the existing `DefenStack.DevLocallyRedundantStorage` suppression. PSRule has no rules for AMPLS, the subscription diagnostic setting, `onboardingStates`, action groups or activity log alerts.
- **main.json is generated:** after any `.bicep` change, run `bicep build main.bicep`. Check with `diff --strip-trailing-cr <(bicep build main.bicep --stdout) main.json`.
- **Docs are mandatory:** runbooks use the 9-section template.
- **Tests must run on both shells:** Windows PowerShell 5.1 and pwsh 7. The prototype ran on 5.1 only; run the full suite on pwsh 7 too before the final commit and report the count.
- **No live Azure/Entra/GitHub commands; no push.** Script tests use a fake `az`.
- **Commit trailers:** every commit ends with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
- **Build output:** never commit `modules/*.json`.
- **PowerShell editing gotchas:**
  - Never write Bicep through a double-quoted PowerShell string, because `${...}` is expanded and dropped.
  - In single-quoted strings, `''` is one `'`.
  - A helper `.ps1` containing non-ASCII characters (—, →, ↔, §) needs a UTF-8 BOM.
  - Read and write docs as UTF-8.
  - Windows PowerShell 5.1 returns a JSON array from `ConvertFrom-Json` as one object; use `@(...)[0]`, as `Set-CustomRole` does.

## Review Focus

These are inputs and conditions the spec implies but no offline test can fully exercise, most likely first:

1. **Traffic Analytics cannot write into a PrivateOnly-ingestion workspace, or the flow-log account refuses the trusted-service write with public access Disabled.** Only a live deployment shows it (`NTANetAnalytics` stays empty, or 403s on the account). Pinned by the Task 3 tests "disables public network access and denies by default, letting only trusted Azure services through" and "sends Traffic Analytics to the central workspace every 10 minutes", and by the Task 6 test "the monitoring runbook lists each unverified item as a live-only risk with a fallback".
2. **East US telemetry never reaches the AMPLS endpoint**, because the FQDN application rule misses a multi-label host or the return path is asymmetric. Pinned by the Task 2 tests "Host (owns the AMPLS endpoint): allows the other region's spoke subnets to Azure Monitor FQDNs as an application rule, which SNATs for a symmetric return path", "Client (forwards to the peer region): allows only its spoke subnets to the AMPLS endpoint subnet on TCP 443 as a network rule" and "keeps 0.0.0.0/0 to Internet on the firewall subnet, as Azure Firewall requires once a route table is attached".
3. **Private-only mode silently drops telemetry** because a component is missing from the scope or the endpoint's DNS records predate it. Pinned by the Task 1 tests "scopes the workspace and the primary App Insights component, plus the secondary component only when deployed" and "creates the endpoint after the scope holds its resources, so the DNS records cover them all".
4. **The pipeline identity cannot deploy the new resources:** an existing custom role keeps its old actions, the preview API is rejected, or `NetworkWatcherRG` is missing. Pinned by the Task 4 tests "updates the existing role once and never re-creates it" and "pins 2021-05-01-preview, the only API version with subscription-scope settings (ADR-025)", and the Task 3 test "assigns Network Contributor on NetworkWatcherRG only, so the pipeline can manage VNet flow logs (Phase 6)".
5. **Prod alerts reach nobody, or a rule watches the wrong metric.** Pinned by the Task 5 tests "fails the prod apply before signing in to Azure when ALERT_EMAIL is empty", "emails ALERT_EMAIL with the common alert schema, and adds no receiver when it is empty" and the per-rule table test "alerts on <Metric> <Operator> <Threshold> (<Aggregation>) at Sev<Severity> as <Name>".

Known coverage gaps:
- PSRule has no rules for the AMPLS, the subscription diagnostic setting, `onboardingStates`, action groups or the Service Health alert.
- Metric aggregations (`Maximum` for `P2SConnectionCount`, `Count` for `ServiceApiResult`) and the Service Health region names (`West US 3`, `East US`) are checked only by a live deployment.
- The `az role definition update` payload and several runbook 06 §6 commands were proved only against the fake `az` or the CLI reference.
- The jump host is still not evaluated by PSRule (Phase 3).

## Execution Notes

- **Full suite:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`, then `pwsh -NoProfile -File tests/Invoke-Tests.ps1`. Each prints `Tests Passed: N, Failed: 0`.
- **Some files only:**

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { `$f = @('tests/MonitorPrivateLink.Tests.ps1'); & ./tests/Invoke-Tests.ps1 -Path `$f }"
  ```

- **PSRule:**

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
  ```

  The summary line reports the rules processed; the expected count is given per task.
- **YAML check:** `powershell.exe -NoProfile -Command "Import-Module powershell-yaml; foreach (`$f in '.github/workflows/deploy.yml', '.github/workflows/bicep-ci.yml') { ConvertFrom-Yaml (Get-Content `$f -Raw) | Out-Null }; 'YAML-OK'"`

## File Map

| File | Responsibility | Task |
|---|---|---|
| `modules/monitorPrivateLinkScope.bicep`, `modules/monitorPrivateEndpoint.bicep`, `tests/MonitorPrivateLink.Tests.ps1` (new) | AMPLS with scoped resources; the `azuremonitor` endpoint and its zone group | 1 |
| `modules/global.bicep`, `modules/monitoring.bicep` (replace in Tasks 1 and 4), `modules/appInsights.bicep` (replace) | Zone and lock loop (1); private-only workspace (1) and Sentinel (4); private-only components (1) | 1, 4 |
| `modules/types.bicep` (replace in Tasks 1, 2, 5) | Zone set (1); `hubPeeringPlan` (2); alert rule and threshold types (5) | 1, 2, 5 |
| `modules/regionStamp.bicep` (replace in Tasks 1, 2, 3, 5) | Outputs for AMPLS (1); hub peering wiring (2); flow logs (3); regional alerts (5) | 1, 2, 3, 5 |
| `main.bicep` (replace in Tasks 1, 2, 4, 5), `main.json` (regenerate in Tasks 1–5) | AMPLS (1); peering (2); Activity Log (4); action group and global alerts (5) | 1, 2, 4, 5 |
| `modules/hubPeering.bicep`, `tests/HubPeering.Tests.ps1` (new); `modules/hubNetwork.bicep`, `modules/firewallPolicyRules.bicep`, `modules/azureFirewall.bicep` (replace) | Peering; firewall subnet route table; `cross-region-monitoring` rules | 2 |
| `modules/flowLogStorage.bicep`, `modules/flowLogs.bicep`, `tests/FlowLogs.Tests.ps1` (new) | Keyless account, identity and role; flow logs in `NetworkWatcherRG` | 3 |
| `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Scripts.Tests.ps1` (replace in Tasks 3 and 4) | Network Contributor on `NetworkWatcherRG` (3); diagnostic-setting actions and the role update path (4) | 3, 4 |
| `modules/activityLog.bicep`, `tests/ActivityLog.Tests.ps1` (new) | Subscription Activity Log setting | 4 |
| `modules/actionGroup.bicep`, `modules/metricAlerts.bicep`, `modules/serviceHealthAlert.bicep`, `tests/Alerts.Tests.ps1` (new); `modules/frontDoor.bicep`, `.github/workflows/deploy.yml`, `.github/workflows/bicep-ci.yml` (replace) | Action group and alerts; Front Door `id` output; `ALERT_EMAIL` | 5 |
| `tests/AppInsights.Tests.ps1`, `tests/Global.Tests.ps1` (replace in Task 1); `tests/Monitoring.Tests.ps1` (1, 4); `tests/Main.Tests.ps1` (1, 2, 4, 5); `tests/RegionStamp.Tests.ps1` (1, 2, 3, 5); `tests/HubNetwork.Tests.ps1`, `tests/FirewallPolicyRules.Tests.ps1`, `tests/AzureFirewall.Tests.ps1` (2); `tests/FrontDoor.Tests.ps1`, `tests/Workflows.Tests.ps1` (5) | Updated tests | 1–5 |
| `docs/runbooks/06-monitoring-and-sentinel.md`, `docs/decisions/ADR-022/023/024/025-*` (new); `docs/decisions/ADR-021-*`, `tests/Docs.Tests.ps1` (replace); `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/00b-*`, `01-*`, `05-*`, `README.md` (edit) | Phase 6 docs | 6 |

---

### Task 1: Private-only Azure Monitor through one AMPLS

**Files:**
- Create: `modules/monitorPrivateLinkScope.bicep`, `modules/monitorPrivateEndpoint.bicep`, `tests/MonitorPrivateLink.Tests.ps1`
- Replace: `modules/types.bicep`, `modules/global.bicep`, `modules/monitoring.bicep`, `modules/appInsights.bicep`, `modules/regionStamp.bicep`, `main.bicep`, `tests/AppInsights.Tests.ps1`, `tests/Global.Tests.ps1`, `tests/Main.Tests.ps1`, `tests/Monitoring.Tests.ps1`, `tests/RegionStamp.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes (Phases 1–5):**
  - `main.bicep` variable `privateDnsZoneNames` and its existing `privateDnsLinks` loop over `items(privateDnsZoneNames)`, which links the new zones to every hub and spoke with no change.
  - `global.outputs.logAnalyticsWorkspaceId` and `global.outputs.privateDnsZoneIds`; the stamp modules `appInsights` and `spokeNetwork` (output `privateEndpointSubnetId`).
  - `main.bicep` symbols `primaryStamp` and `secondaryStamp`, and variables `globalResourceGroupName`, `primaryResourceGroupName` and `primaryLocation`.
- **Produces:**
  - `privateDnsZoneSet` keys `monitor`, `oms`, `ods` and `agentsvc` (seven keys in all). `global.bicep` creates zones and locks with one loop each; lock names stay `<key>-zone-lck`.
  - `monitorPrivateLinkScope.bicep(scopeName, scopedResourceIds)`, outputs `id` and `name`. Scope name `ampls-defenstack-<env>`, deployment `monitor-private-link-scope-<env>`.
  - `monitorPrivateEndpoint.bicep(location, privateLinkScopeId, privateLinkScopeName, privateEndpointSubnetId, privateDnsZoneIds)`, output `id`. Endpoint `ampls-defenstack-<env>-pe`, deployment `monitor-private-endpoint-<env>`, group `azuremonitor`, one `default` zone group with five configs (`monitor`, `oms`, `ods`, `agentsvc`, `blob`).
  - Stamp outputs `appInsightsId` and `privateEndpointSubnetId`; `main.bicep` output `monitorPrivateLinkScopeName`.
  - No lock on the AMPLS: a lock would block deleting a scoped resource when the secondary region is turned off (ADR-022).

- [ ] **Step 1: Confirm the branch**

  The worktree `.claude/worktrees/phase6-monitoring` is on branch `phase6-monitoring` at `31df32e` plus this plan's commit. Check it with `git log --oneline -2`. The baseline is `Tests Passed: 390, Failed: 0` and 871 PSRule rules processed.

- [ ] **Step 2: Write the failing tests**

  Create `tests/MonitorPrivateLink.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $scopeTemplate = Get-BicepTemplate -RelativePath 'modules/monitorPrivateLinkScope.bicep'
      $scope = Get-TemplateResource -Template $scopeTemplate -Type 'Microsoft.Insights/privateLinkScopes' | Select-Object -First 1
      $scopedResources = Get-TemplateResource -Template $scopeTemplate -Type 'Microsoft.Insights/privateLinkScopes/scopedResources' | Select-Object -First 1
      $endpointTemplate = Get-BicepTemplate -RelativePath 'modules/monitorPrivateEndpoint.bicep'
      $endpoint = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints' | Select-Object -First 1
      $zoneGroup = Get-TemplateResource -Template $endpointTemplate -Type 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups' | Select-Object -First 1
  }

  Describe 'Azure Monitor Private Link Scope (Phase 6)' {
      It 'is a global resource' {
          $scope.location | Should -Be 'global'
      }

      It 'accepts ingestion and queries from connected networks only through private links (PrivateOnly)' {
          $scope.properties.accessModeSettings.ingestionAccessMode | Should -Be 'PrivateOnly'
          $scope.properties.accessModeSettings.queryAccessMode | Should -Be 'PrivateOnly'
      }

      It 'pins the GA API version 2021-09-01' {
          $scope.apiVersion | Should -Be '2021-09-01'
          $scopedResources.apiVersion | Should -Be '2021-09-01'
      }

      It 'links one scoped resource per resource ID, named after the linked resource' {
          $scopedResources.copy.count | Should -Be "[length(parameters('scopedResourceIds'))]"
          $scopedResources.properties.linkedResourceId | Should -Be "[parameters('scopedResourceIds')[copyIndex()]]"
          $scopedResources.name | Should -Match "last\(split\(parameters\('scopedResourceIds'\)\[copyIndex\(\)\], '/'\)\)"
      }

      It 'outputs the scope ID and name' {
          $scopeTemplate.outputs.PSObject.Properties.Name | Should -Contain 'id'
          $scopeTemplate.outputs.PSObject.Properties.Name | Should -Contain 'name'
      }
  }

  Describe 'AMPLS private endpoint (Phase 6)' {
      It 'connects to the scope through the azuremonitor group' {
          $connection = $endpoint.properties.privateLinkServiceConnections[0]
          $connection.properties.privateLinkServiceId | Should -Be "[parameters('privateLinkScopeId')]"
          @($connection.properties.groupIds) | Should -Be @('azuremonitor')
      }

      It 'uses the existing <resource>-pe naming and the private-endpoint subnet passed in' {
          $endpoint.name | Should -Be "[format('{0}-pe', parameters('privateLinkScopeName'))]"
          $endpoint.properties.subnet.id | Should -Be "[parameters('privateEndpointSubnetId')]"
      }

      It 'registers records in the four Azure Monitor zones and the shared blob zone' {
          $zoneGroup.name | Should -Match "'default'\)\]$"
          $zoneIds = @($zoneGroup.properties.privateDnsZoneConfigs | ForEach-Object { $_.properties.privateDnsZoneId })
          $zoneIds.Count | Should -Be 5
          foreach ($key in 'monitor', 'oms', 'ods', 'agentsvc', 'blob') {
              $zoneIds | Should -Contain "[parameters('privateDnsZoneIds').$key]"
          }
      }
  }
  ```

  Replace `tests/Global.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/global.bicep'
      $zones = Get-TemplateResource -Template $template -Type 'Microsoft.Network/privateDnsZones' | Select-Object -First 1
      $locks = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
      $monitoring = Get-ModuleDeployment -Template $template -Name 'monitoring'
      $zoneKeys = 'agentsvc', 'blob', 'monitor', 'ods', 'oms', 'sites', 'vault'
  }

  Describe 'Global layer private DNS zones' {
      It 'creates one zone for every name in the shared zone set, so a new zone needs no new resource' {
          $zones.copy.count | Should -Be "[length(items(parameters('privateDnsZoneNames')))]"
          $zones.name | Should -Be "[items(parameters('privateDnsZoneNames'))[copyIndex()].value]"
          $zones.location | Should -Be 'global'
      }

      It 'locks every zone only when deletion protection is requested, keeping the existing per-group lock names' {
          $locks.copy.count | Should -Be "[length(items(parameters('privateDnsZoneNames')))]"
          $locks.condition | Should -Be "[parameters('enableDeleteLock')]"
          $locks.name | Should -Be "[format('{0}-zone-lck', items(parameters('privateDnsZoneNames'))[copyIndex()].key)]"
          $locks.properties.level | Should -Be 'CanNotDelete'
      }

      It 'outputs the zone IDs keyed by private endpoint group' {
          $template.outputs.privateDnsZoneIds.value | Should -Match "^\[toObject\(items\(parameters\('privateDnsZoneNames'\)\)"
          $template.outputs.privateDnsZoneIds.value | Should -Match "resourceId\('Microsoft.Network/privateDnsZones'"
      }

      It 'types the zone set with the application and Azure Monitor (AMPLS) groups (Phase 6)' {
          $properties = $template.definitions.privateDnsZoneSet.properties.PSObject.Properties.Name
          @($properties | Sort-Object) | Should -Be @($zoneKeys)
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

  Replace `tests/Monitoring.Tests.ps1`:

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

  Describe 'Log Analytics resilience (Phase 1)' {
      BeforeAll {
          $workspace = Get-TemplateResource -Template $template -Type 'Microsoft.OperationalInsights/workspaces' | Select-Object -First 1
          $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
      }

      It 'replicates the workspace only when a replication region is supplied' {
          $template.parameters.replicationLocation.defaultValue | Should -BeExactly ''
          $workspace.properties.replication.enabled | Should -Be "[not(empty(parameters('replicationLocation')))]"
          $workspace.properties.replication.location | Should -Be "[if(empty(parameters('replicationLocation')), null(), parameters('replicationLocation'))]"
      }

      It 'locks the workspace only when deletion protection is requested' {
          $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
          $lock.properties.level | Should -Be 'CanNotDelete'
      }
  }

  Describe 'Private-only workspace (Phase 6)' {
      BeforeAll {
          $workspace = Get-TemplateResource -Template $template -Type 'Microsoft.OperationalInsights/workspaces' | Select-Object -First 1
      }

      It 'accepts ingestion and queries only through the Azure Monitor Private Link Scope (F10)' {
          $workspace.properties.publicNetworkAccessForIngestion | Should -Be 'Disabled'
          $workspace.properties.publicNetworkAccessForQuery | Should -Be 'Disabled'
      }

      It 'keeps 90-day retention unchanged' {
          $workspace.properties.retentionInDays | Should -Be "[parameters('retentionInDays')]"
      }
  }
  ```

  Replace `tests/AppInsights.Tests.ps1` (the Phase 5 "Enabled until Phase 6" test becomes the private-only test):

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $componentTemplate = Get-BicepTemplate -RelativePath 'modules/appInsights.bicep'
      $component = Get-TemplateResource -Template $componentTemplate -Type 'Microsoft.Insights/components' | Select-Object -First 1
      $publisherTemplate = Get-BicepTemplate -RelativePath 'modules/appInsightsPublisher.bicep'
      $publisher = Get-TemplateResource -Template $publisherTemplate -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
      $appServiceTemplate = Get-BicepTemplate -RelativePath 'modules/appService.bicep'
      $site = Get-TemplateResource -Template $appServiceTemplate -Type 'Microsoft.Web/sites' | Select-Object -First 1
      $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
  }

  Describe 'Application Insights component (Phase 5)' {
      It 'is workspace-based, storing telemetry in the central workspace' {
          $component.kind | Should -Be 'web'
          $component.properties.WorkspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
          $component.properties.IngestionMode | Should -Be 'LogAnalytics'
      }

      It 'accepts only Entra ID-authenticated telemetry (no instrumentation-key ingestion)' {
          $component.properties.DisableLocalAuth | Should -BeExactly $true
      }

      It 'accepts ingestion and queries only through the Azure Monitor Private Link Scope (Phase 6)' {
          $component.properties.publicNetworkAccessForIngestion | Should -Be 'Disabled'
          $component.properties.publicNetworkAccessForQuery | Should -Be 'Disabled'
      }

      It 'outputs the connection string the App Service needs' {
          $componentTemplate.outputs.connectionString.value | Should -Match 'ConnectionString'
      }
  }

  Describe 'Telemetry publisher role (Phase 5)' {
      It 'grants Monitoring Metrics Publisher on the component only' {
          $publisherTemplate.variables.monitoringMetricsPublisherRoleId | Should -Be '3913510d-42f4-4e42-8a64-420c390055eb'
          $publisher.scope | Should -Be "[resourceId('Microsoft.Insights/components', parameters('componentName'))]"
          $publisher.properties.principalType | Should -Be 'ServicePrincipal'
          $publisher.properties.principalId | Should -Be "[parameters('publisherPrincipalId')]"
      }
  }

  Describe 'App Service telemetry and hardening (Phase 5)' {
      It 'sends telemetry with the connection string and Entra ID authentication only when a component is given' {
          $appServiceTemplate.parameters.applicationInsightsConnectionString.defaultValue | Should -Be ''
          $appServiceTemplate.variables.telemetrySettings | Should -Match "^\[if\(empty\(parameters\('applicationInsightsConnectionString'\)\), createArray\(\)"
          $appServiceTemplate.variables.telemetrySettings | Should -Match "'APPLICATIONINSIGHTS_CONNECTION_STRING'"
          $appServiceTemplate.variables.telemetrySettings | Should -Match "'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', 'value', 'Authorization=AAD'"
          $site.properties.siteConfig.appSettings | Should -Be "[variables('telemetrySettings')]"
      }

      It 'denies all public access to the site and Kudu by default even if public access is re-enabled' {
          $site.properties.siteConfig.ipSecurityRestrictionsDefaultAction | Should -Be 'Deny'
          $site.properties.siteConfig.scmIpSecurityRestrictionsDefaultAction | Should -Be 'Deny'
          $site.properties.publicNetworkAccess | Should -Be 'Disabled'
      }
  }

  Describe 'Region stamp telemetry wiring (Phase 5)' {
      It 'creates one component per region, named with environment and region' {
          $stamp.variables.names.appInsights | Should -Be "[format('appi-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
          (Get-ModuleDeployment -Template $stamp -Name 'app-insights').properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
      }

      It 'passes the regional connection string to the App Service' {
          (Get-ModuleDeployment -Template $stamp -Name 'app-service').properties.parameters.applicationInsightsConnectionString.value |
              Should -Be "[reference('appInsights').outputs.connectionString.value]"
      }

      It 'outputs the component ID so the entry point can scope it into AMPLS (Phase 6)' {
          $stamp.outputs.appInsightsId.value | Should -Be "[reference('appInsights').outputs.id.value]"
      }

      It 'grants the App Service identity the publisher role on its own component' {
          $parameters = (Get-ModuleDeployment -Template $stamp -Name 'app-insights-publisher').properties.parameters
          $parameters.publisherPrincipalId.value | Should -Be "[reference('appService').outputs.appServicePrincipalId.value]"
          $parameters.componentName.value | Should -Be "[reference('appInsights').outputs.name.value]"
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

      It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev (Phase 5)' {
          (Get-StampModuleParameters 'storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
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

      It 'outputs the private-endpoint subnet that hosts the AMPLS endpoint in the primary region (Phase 6)' {
          $stamp.outputs.privateEndpointSubnetId.value | Should -Be "[reference('spokeNetwork').outputs.privateEndpointSubnetId.value]"
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
      It 'defines the zone names once: three application zones and four Azure Monitor (AMPLS) zones' {
          @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault,monitor,oms,ods,agentsvc'
          $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
          $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
      }

      It 'adds the AMPLS zone <Key> = <Zone> (Phase 6)' -ForEach @(
          @{ Key = 'monitor'; Zone = 'privatelink.monitor.azure.com' }
          @{ Key = 'oms'; Zone = 'privatelink.oms.opinsights.azure.com' }
          @{ Key = 'ods'; Zone = 'privatelink.ods.opinsights.azure.com' }
          @{ Key = 'agentsvc'; Zone = 'privatelink.agentsvc.azure-automation.net' }
      ) {
          $main.variables.privateDnsZoneNames.$Key | Should -BeExactly $Zone
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

      It 'outputs the Front Door profile name and the global resource group name, so the pipeline can poll the origin group (final review A)' {
          foreach ($output in 'frontDoorProfileName', 'globalResourceGroupName') {
              $main.outputs.PSObject.Properties.Name | Should -Contain $output
          }
          $main.outputs.frontDoorProfileName.value | Should -Be "[reference('frontDoor').outputs.profileName.value]"
          $main.outputs.globalResourceGroupName.value | Should -Be "[variables('globalResourceGroupName')]"
      }
  }

  Describe 'Azure Monitor Private Link Scope (Phase 6)' {
      BeforeAll {
          $scope = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateLinkScope'
          $endpoint = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateEndpoint'
      }

      It 'deploys one scope per environment into the global resource group' {
          $scope.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $scope.properties.parameters.scopeName.value | Should -Be "[format('ampls-defenstack-{0}', parameters('environmentName'))]"
      }

      It 'scopes the workspace and the primary App Insights component, plus the secondary component only when deployed' {
          $value = $scope.properties.parameters.scopedResourceIds.value
          $value | Should -Match "^\[concat\(createArray\(reference\('global'\)\.outputs\.logAnalyticsWorkspaceId\.value, reference\('primaryStamp'\)\.outputs\.appInsightsId\.value\)"
          $value | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(reference\('secondaryStamp'\)\.outputs\.appInsightsId\.value\), createArray\(\)\)"
      }

      It 'puts the single azuremonitor endpoint in the primary spoke private-endpoint subnet' {
          $endpoint.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $endpoint.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
          $endpoint.properties.parameters.privateEndpointSubnetId.value | Should -Be "[reference('primaryStamp').outputs.privateEndpointSubnetId.value]"
          $endpoint.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
      }

      It 'creates the endpoint after the scope holds its resources, so the DNS records cover them all' {
          $endpoint.properties.parameters.privateLinkScopeId.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.id.value]"
          @($endpoint.dependsOn) | Should -Contain 'monitorPrivateLinkScope'
      }

      It 'outputs the scope name for runbook 06' {
          $main.outputs.monitorPrivateLinkScopeName.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.name.value]"
      }
  }
  ```

- [ ] **Step 3: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected failures:
  - `bicep build failed for modules/monitorPrivateLinkScope.bicep` and `modules/monitorPrivateEndpoint.bicep`
  - the zone loop, zone set and AMPLS zone tests in `Global.Tests.ps1` and `Main.Tests.ps1`
  - the `Disabled` ingestion and query tests for the workspace and the component
  - the new stamp outputs and the `Azure Monitor Private Link Scope (Phase 6)` wiring tests

- [ ] **Step 4: Create the two modules**

  Create `modules/monitorPrivateLinkScope.bicep`:

  ```bicep
  // One Azure Monitor Private Link Scope (AMPLS) for the whole platform. The shared private DNS zones are linked to
  // every VNet, so a second scope or endpoint would overwrite the first one's records (one AMPLS per DNS).

  @description('Azure Monitor Private Link Scope name.')
  @minLength(1)
  @maxLength(255)
  param scopeName string

  @description('Resource IDs of the Azure Monitor resources reachable through the scope: the Log Analytics workspace and every Application Insights component.')
  param scopedResourceIds array

  // PrivateOnly: networks connected to the scope reach only the scoped resources, for both ingestion and query.
  resource privateLinkScope 'Microsoft.Insights/privateLinkScopes@2021-09-01' = {
    name: scopeName
    location: 'global'
    properties: {
      accessModeSettings: {
        ingestionAccessMode: 'PrivateOnly'
        queryAccessMode: 'PrivateOnly'
      }
    }
  }

  resource scopedResources 'Microsoft.Insights/privateLinkScopes/scopedResources@2021-09-01' = [for linkedResourceId in scopedResourceIds: {
    parent: privateLinkScope
    name: last(split(linkedResourceId, '/'))
    properties: {
      linkedResourceId: linkedResourceId
    }
  }]

  output id string = privateLinkScope.id
  output name string = privateLinkScope.name
  ```

  Create `modules/monitorPrivateEndpoint.bicep`:

  ```bicep
  // The platform's single Azure Monitor private endpoint, in the primary spoke's private-endpoint subnet. Its NSG
  // already admits HTTPS from the approved sources, and the shared zones make it resolvable from every linked VNet.
  import { privateDnsZoneSet } from 'types.bicep'

  @description('Azure region for the private endpoint (the primary region).')
  param location string

  @description('Azure Monitor Private Link Scope resource ID.')
  param privateLinkScopeId string

  @description('Azure Monitor Private Link Scope name, used for deterministic private endpoint naming.')
  @minLength(1)
  @maxLength(255)
  param privateLinkScopeName string

  @description('Private-endpoint subnet resource ID in the primary spoke.')
  param privateEndpointSubnetId string

  @description('Resource IDs of the shared private DNS zones created by the global layer.')
  param privateDnsZoneIds privateDnsZoneSet

  resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
    name: '${privateLinkScopeName}-pe'
    location: location
    properties: {
      privateLinkServiceConnections: [
        {
          name: 'azuremonitor'
          properties: {
            privateLinkServiceId: privateLinkScopeId
            groupIds: [
              'azuremonitor'
            ]
          }
        }
      ]
      subnet: {
        id: privateEndpointSubnetId
      }
    }
  }

  // Azure Monitor needs its four zones plus the shared blob zone (agent solution packs); the blob records are
  // per storage account, so they sit beside the application's own blob records without conflict.
  resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
    parent: privateEndpoint
    name: 'default'
    properties: {
      privateDnsZoneConfigs: [
        {
          name: 'monitor'
          properties: {
            privateDnsZoneId: privateDnsZoneIds.monitor
          }
        }
        {
          name: 'oms'
          properties: {
            privateDnsZoneId: privateDnsZoneIds.oms
          }
        }
        {
          name: 'ods'
          properties: {
            privateDnsZoneId: privateDnsZoneIds.ods
          }
        }
        {
          name: 'agentsvc'
          properties: {
            privateDnsZoneId: privateDnsZoneIds.agentsvc
          }
        }
        {
          name: 'blob'
          properties: {
            privateDnsZoneId: privateDnsZoneIds.blob
          }
        }
      ]
    }
  }

  output id string = privateEndpoint.id
  ```

- [ ] **Step 5: Add the zones and switch monitoring to private-only**

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
  @description('Private DNS zone names (or resource IDs) keyed by private endpoint group: the application zones plus the Azure Monitor Private Link Scope zones (Phase 6).')
  type privateDnsZoneSet = {
    @description('Blob storage zone.')
    blob: string

    @description('App Service (sites) zone.')
    sites: string

    @description('Key Vault zone.')
    vault: string

    @description('Azure Monitor global endpoints zone (AMPLS).')
    monitor: string

    @description('Log Analytics workspace agent endpoints zone (AMPLS).')
    oms: string

    @description('Log Analytics workspace ingestion (ODS) endpoints zone (AMPLS).')
    ods: string

    @description('Log Analytics agent service endpoints zone (AMPLS).')
    agentsvc: string
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

  Replace `modules/global.bicep`:

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

  // One set of private DNS zones for all regions; each region links its hub and spoke VNets. The set holds the
  // application zones (blob, sites, vault) and, from Phase 6, the Azure Monitor Private Link Scope zones.
  resource zones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zone in items(privateDnsZoneNames): {
    name: zone.value
    location: 'global'
  }]

  resource zoneLocks 'Microsoft.Authorization/locks@2020-05-01' = [for (zone, i) in items(privateDnsZoneNames): if (enableDeleteLock) {
    scope: zones[i]
    name: '${zone.key}-zone-lck'
    properties: {
      level: 'CanNotDelete'
    }
  }]

  output logAnalyticsWorkspaceId string = monitoring.outputs.id
  output privateDnsZoneIds privateDnsZoneSet = toObject(
    items(privateDnsZoneNames),
    zone => zone.key,
    zone => resourceId('Microsoft.Network/privateDnsZones', zone.value)
  )
  ```

  Replace `modules/monitoring.bicep`:

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

  @description('Region that holds the workspace replica for regional failover. Empty disables replication (sends enabled: false).')
  param replicationLocation string = ''

  @description('Apply a CanNotDelete lock to the workspace.')
  param enableDeleteLock bool = false

  // Central workspace for platform, network, storage, and application diagnostics. Agents and queries reach it
  // only through the Azure Monitor Private Link Scope; diagnostic settings use Azure's internal path (F10, Phase 6).
  resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
    name: workspaceName
    location: location
    properties: {
      retentionInDays: retentionInDays
      publicNetworkAccessForIngestion: 'Disabled'
      publicNetworkAccessForQuery: 'Disabled'
      sku: {
        name: 'PerGB2018'
      }
      replication: {
        enabled: !empty(replicationLocation)
        location: empty(replicationLocation) ? null : replicationLocation
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

  Replace `modules/appInsights.bicep`:

  ```bicep
  @description('Azure region for the Application Insights component (the stamp region).')
  param location string

  @description('Application Insights component name.')
  @minLength(1)
  @maxLength(260)
  param componentName string

  @description('Central Log Analytics workspace resource ID; telemetry is stored there (workspace-based).')
  param logAnalyticsWorkspaceId string

  // Workspace-based, Entra ID-only ingestion: the App Service identity needs Monitoring Metrics Publisher (appInsightsPublisher.bicep).
  // Ingestion and query go only through the Azure Monitor Private Link Scope; the entry point scopes this component into it (Phase 6).
  resource component 'Microsoft.Insights/components@2020-02-02' = {
    name: componentName
    location: location
    kind: 'web'
    properties: {
      Application_Type: 'web'
      WorkspaceResourceId: logAnalyticsWorkspaceId
      IngestionMode: 'LogAnalytics'
      DisableLocalAuth: true
      publicNetworkAccessForIngestion: 'Disabled'
      publicNetworkAccessForQuery: 'Disabled'
    }
  }

  output id string = component.id
  output name string = component.name
  output connectionString string = component.properties.ConnectionString
  ```

- [ ] **Step 6: Wire the scope and the endpoint**

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

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  @description('Application secrets written to this region\'s Key Vault, as { name: value } (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

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
    appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
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
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
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
      secrets: keyVaultSecrets
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

  // One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
  module appInsights 'appInsights.bicep' = {
    name: 'app-insights'
    params: {
      location: location
      componentName: names.appInsights
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
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
      applicationInsightsConnectionString: appInsights.outputs.connectionString
    }
  }

  module appInsightsPublisher 'appInsightsPublisher.bicep' = {
    name: 'app-insights-publisher'
    params: {
      componentName: appInsights.outputs.name
      publisherPrincipalId: appService.outputs.appServicePrincipalId
      publisherAppServiceName: names.appService
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

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
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
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceId string = appService.outputs.appServiceAppId
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  output appInsightsName string = appInsights.outputs.name
  output appInsightsId string = appInsights.outputs.id
  output privateEndpointSubnetId string = spokeNetwork.outputs.privateEndpointSubnetId
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

  @description('Application secrets written to every regional Key Vault, as { name: value }. The pipeline supplies them from the KEYVAULT_SECRETS_JSON environment secret; never put values in a committed parameter file (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

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
    // Azure Monitor Private Link Scope zones (Phase 6); the AMPLS endpoint also registers in the blob zone above.
    monitor: 'privatelink.monitor.azure.com'
    oms: 'privatelink.oms.opinsights.azure.com'
    ods: 'privatelink.ods.opinsights.azure.com'
    agentsvc: 'privatelink.agentsvc.azure-automation.net'
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
      keyVaultSecrets: keyVaultSecrets
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
      primaryStorageAccountId: isProd ? primaryStamp.outputs.storageAccountId : ''
      primaryStorageAccountName: isProd ? primaryStamp.outputs.storageAccountName : ''
      keyVaultSecrets: keyVaultSecrets
    }
  }

  // The warm-standby App Service may read (never write) the primary application container (ADR-020).
  module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion && isProd) {
    name: 'storage-reader-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      storageAccountName: primaryStamp.outputs.storageAccountName
      storageContainerName: primaryStamp.outputs.storageContainerName
      readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
      readerAppServiceName: secondaryStamp!.outputs.appServiceName
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

  // Private-only monitoring (Phase 6): one scope holds the workspace and every regional App Insights component.
  module monitorPrivateLinkScope 'modules/monitorPrivateLinkScope.bicep' = {
    name: 'monitor-private-link-scope-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      scopeName: 'ampls-defenstack-${environmentName}'
      scopedResourceIds: concat([
        global.outputs.logAnalyticsWorkspaceId
        primaryStamp.outputs.appInsightsId
      ], deploySecondaryRegion ? [
        secondaryStamp!.outputs.appInsightsId
      ] : [])
    }
  }

  // The single azuremonitor endpoint, in the primary spoke, created once the scope holds every resource.
  module monitorPrivateEndpoint 'modules/monitorPrivateEndpoint.bicep' = {
    name: 'monitor-private-endpoint-${environmentName}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      location: primaryLocation
      privateLinkScopeId: monitorPrivateLinkScope.outputs.id
      privateLinkScopeName: monitorPrivateLinkScope.outputs.name
      privateEndpointSubnetId: primaryStamp.outputs.privateEndpointSubnetId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
    }
  }

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output frontDoorProfileName string = frontDoor.outputs.profileName
  output globalResourceGroupName string = globalResourceGroupName
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
  output monitorPrivateLinkScopeName string = monitorPrivateLinkScope.outputs.name
  ```

- [ ] **Step 7: Build, lint, test, PSRule**

  ```bash
  bicep build main.bicep
  for f in main.bicep modules/*.bicep; do bicep lint "$f" || echo "LINT FAIL $f"; done
  ```

  Expected: no `LINT FAIL`. Then run the full suite: `Tests Passed: 414, Failed: 0`. Then run PSRule: 0 failures, 971 rules processed. The increase comes from the four zones, their links and the endpoint.

- [ ] **Step 8: Commit**

  ```bash
  git add modules/monitorPrivateLinkScope.bicep modules/monitorPrivateEndpoint.bicep modules/types.bicep modules/global.bicep modules/monitoring.bicep modules/appInsights.bicep modules/regionStamp.bicep main.bicep main.json tests/MonitorPrivateLink.Tests.ps1 tests/AppInsights.Tests.ps1 tests/Global.Tests.ps1 tests/Main.Tests.ps1 tests/Monitoring.Tests.ps1 tests/RegionStamp.Tests.ps1
  git commit -m "feat: private-only Azure Monitor through one AMPLS with an azuremonitor endpoint" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 2: Hub-to-hub global peering and firewall-subnet routing (prod with DR)

**Files:**
- Create: `modules/hubPeering.bicep`, `tests/HubPeering.Tests.ps1`
- Replace: `modules/types.bicep`, `modules/hubNetwork.bicep`, `modules/firewallPolicyRules.bicep`, `modules/azureFirewall.bicep`, `modules/regionStamp.bicep`, `main.bicep`, `tests/HubNetwork.Tests.ps1`, `tests/FirewallPolicyRules.Tests.ps1`, `tests/AzureFirewall.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Main.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes (Task 1 and Phases 1–3):** stamp outputs `hubVnetName` and `hubVnetId`; address plan fields `firewallSubnetPrefix`, `spokeAddressSpace`, `appServiceIntegrationSubnetPrefix`, `managementSubnetPrefix` and `privateEndpointSubnetPrefix`; `deploySecondaryRegion`, `primaryRegionCode` and `secondaryRegionCode`; the firewall rule groups at priorities 100, 120, 150 and 200.
- **Produces:**
  - Exported type `hubPeeringPlan { remoteFirewallPrivateIp, remoteSpokeAddressPrefixes, monitorRole: 'Host' | 'Client', monitorClientPrefixes, monitorPrivateEndpointPrefixes }`.
  - `hubPeering.bicep(localVnetName, remoteVnetId, peeringName)`, output `id`. `main.bicep` modules `primaryHubPeering` (`hub-to-eus-hub`, deployment `hub-peering-wus3-to-eus`) and `secondaryHubPeering` (`hub-to-wus3-hub`), the second depending on the first.
  - `hubNetwork.bicep` params `remoteSpokeAddressPrefixes = []` and `remoteFirewallPrivateIp = ''`; route table `<hubVnet>-firewall-rt`, only when prefixes are given, with BGP propagation kept on.
  - `firewallPolicyRules.bicep` and `azureFirewall.bicep` params `monitorPeeringRole = 'None'`, `monitorClientPrefixes = []` and `monitorPrivateEndpointPrefixes = []`; group `cross-region-monitoring` at priority 250 with collection `peer-spoke-to-azure-monitor` (Host) or `spoke-to-peer-azure-monitor` (Client).
  - Stamp param `hubPeering hubPeeringPlan?`; variables `monitorPeeringRole` and `peerTrafficSourceCidrs` (the Host's private-endpoint NSG admits its own `AzureFirewallSubnet`, the SNAT source).
  - `main.bicep` variables `monitorClientPrefixes` and `monitorPrivateEndpointPrefixes`. The remote firewall IP is `cidrHost(<other plan>.firewallSubnetPrefix, 3)`, computed in `main.bicep` because the primary stamp cannot depend on the secondary.

- [ ] **Step 1: Write the failing tests**

  Create `tests/HubPeering.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/hubPeering.bicep'
      $peering = Get-TemplateResource -Template $template -Type 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings' | Select-Object -First 1
  }

  Describe 'Hub-to-hub global peering (Phase 6, brought forward from Phase 8)' {
      It 'peers this region''s hub with the other region''s hub' {
          $peering.name | Should -Be "[format('{0}/{1}', parameters('localVnetName'), parameters('peeringName'))]"
          $peering.properties.remoteVirtualNetwork.id | Should -Be "[parameters('remoteVnetId')]"
          $peering.properties.allowVirtualNetworkAccess | Should -BeExactly $true
      }

      It 'accepts traffic forwarded by the other region''s firewall' {
          $peering.properties.allowForwardedTraffic | Should -BeExactly $true
      }

      It 'never shares or uses a VPN gateway across regions (both hubs own one)' {
          $peering.properties.allowGatewayTransit | Should -BeExactly $false
          $peering.properties.useRemoteGateways | Should -BeExactly $false
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
      $routeTables = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables'
      $routeTable = $routeTables | Where-Object { $_.name -eq "[variables('gatewayRouteTableName')]" }
      $firewallRouteTable = $routeTables | Where-Object { $_.name -eq "[variables('firewallRouteTableName')]" }
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
          (Get-Subnet 'AzureFirewallSubnet').properties.routeTable | Should -Not -Match 'gatewayRouteTableName'
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

  Describe 'AzureFirewallSubnet routing for hub peering (Phase 6)' {
      It 'creates the firewall route table only when the other region''s spoke prefixes are given (prod with DR)' {
          $template.parameters.remoteSpokeAddressPrefixes.defaultValue.Count | Should -Be 0
          $template.parameters.remoteFirewallPrivateIp.defaultValue | Should -BeExactly ''
          $firewallRouteTable.condition | Should -Be "[not(empty(parameters('remoteSpokeAddressPrefixes')))]"
      }

      It 'attaches it to AzureFirewallSubnet only when it exists' {
          (Get-Subnet 'AzureFirewallSubnet').properties.routeTable |
              Should -Be "[if(empty(parameters('remoteSpokeAddressPrefixes')), null(), createObject('id', resourceId('Microsoft.Network/routeTables', variables('firewallRouteTableName'))))]"
      }

      It 'sends each remote spoke prefix to the remote firewall private IP' {
          $firewallRouteTable.properties.routes | Should -Be "[variables('firewallRoutes')]"
          $template.variables.firewallRoutes | Should -Match "map\(parameters\('remoteSpokeAddressPrefixes'\)"
          $template.variables.firewallRoutes | Should -Match "'nextHopType', 'VirtualAppliance', 'nextHopIpAddress', parameters\('remoteFirewallPrivateIp'\)"
      }

      It 'keeps 0.0.0.0/0 to Internet on the firewall subnet, as Azure Firewall requires once a route table is attached' {
          $template.variables.firewallRoutes | Should -Match "createObject\('name', 'default-to-internet', 'properties', createObject\('addressPrefix', '0.0.0.0/0', 'nextHopType', 'Internet'\)\)"
      }

      It 'keeps gateway route propagation on, so the firewall still returns traffic to VPN clients' {
          $firewallRouteTable.properties.disableBgpRoutePropagation | Should -BeExactly $false
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
      It 'defines the dns-egress, admin-access, platform-egress and approved-https-egress groups at priorities 100, 120, 150, 200 (plus the Phase 6 cross-region group)' {
          $groups.Count | Should -Be 5
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

  Describe 'Cross-region Azure Monitor traffic over the hub peering (Phase 6)' {
      BeforeAll {
          $crossRegion = Get-Group 'cross-region-monitoring'
          $collections = @($crossRegion.properties.ruleCollections)
          $hostCollection = $collections | Where-Object { $_.name -eq 'peer-spoke-to-azure-monitor' }
          $clientCollection = $collections | Where-Object { $_.name -eq 'spoke-to-peer-azure-monitor' }
      }

      It 'is deployed only when this region takes part (role Host or Client), after every other group' {
          $template.parameters.monitorPeeringRole.defaultValue | Should -Be 'None'
          @($template.parameters.monitorPeeringRole.allowedValues) -join ',' | Should -Be 'None,Host,Client'
          $crossRegion.condition | Should -Be "[not(equals(parameters('monitorPeeringRole'), 'None'))]"
          $crossRegion.properties.priority | Should -Be 250
          @($crossRegion.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'platform-egress')]"
          @($crossRegion.dependsOn) | Should -Contain "[resourceId('Microsoft.Network/firewallPolicies/ruleCollectionGroups', parameters('firewallPolicyName'), 'approved-https-egress')]"
      }

      It 'renders exactly one collection, chosen by role' {
          $crossRegion.properties.ruleCollections | Should -Match "^\[if\(equals\(parameters\('monitorPeeringRole'\), 'Host'\)"
      }

      It 'Host (owns the AMPLS endpoint): allows the other region''s spoke subnets to Azure Monitor FQDNs as an application rule, which SNATs for a symmetric return path' {
          $rule = $template.variables.monitorHostCollection.rules[0]
          $rule.ruleType | Should -Be 'ApplicationRule'
          $rule.sourceAddresses | Should -Be "[parameters('monitorClientPrefixes')]"
          @($rule.protocols.protocolType) -join ',' | Should -Be 'Https'
          @($rule.protocols.port) -join ',' | Should -Be '443'
          foreach ($fqdn in '*.applicationinsights.azure.com', '*.monitor.azure.com', '*.ods.opinsights.azure.com', '*.oms.opinsights.azure.com', '*.agentsvc.azure-automation.net') {
              @($rule.targetFqdns) | Should -Contain $fqdn
          }
      }

      It 'Client (forwards to the peer region): allows only its spoke subnets to the AMPLS endpoint subnet on TCP 443 as a network rule' {
          $rule = $template.variables.monitorClientCollection.rules[0]
          $rule.ruleType | Should -Be 'NetworkRule'
          @($rule.ipProtocols) -join ',' | Should -Be 'TCP'
          $rule.sourceAddresses | Should -Be "[parameters('monitorClientPrefixes')]"
          $rule.destinationAddresses | Should -Be "[parameters('monitorPrivateEndpointPrefixes')]"
          @($rule.destinationPorts) -join ',' | Should -Be '443'
      }

      It 'allows, never denies' {
          $template.variables.monitorHostCollection.action.type | Should -Be 'Allow'
          $template.variables.monitorClientCollection.action.type | Should -Be 'Allow'
      }
  }
  ```

  Replace `tests/AzureFirewall.Tests.ps1`:

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
          $policy.properties.intrusionDetection | Should -Be "[if(variables('isPremium'), createObject('mode', parameters('idpsMode'), 'configuration', createObject('signatureOverrides', parameters('idpsSignatureOverrides'))), null())]"
      }

      It 'accepts per-signature IDPS overrides on the policy resource, defaulting to none (Final review A)' {
          @($template.parameters.idpsSignatureOverrides.defaultValue).Count | Should -Be 0
          $policy.properties.intrusionDetection | Should -Match 'idpsSignatureOverrides'
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

  Describe 'Cross-region Azure Monitor rules pass-through (Phase 6)' {
      It 'passes <_> to the rules module, off by default' -ForEach 'monitorPeeringRole', 'monitorClientPrefixes', 'monitorPrivateEndpointPrefixes' {
          $rules.properties.parameters.$_.value | Should -Be "[parameters('$_')]"
      }

      It 'defaults to no cross-region role' {
          $template.parameters.monitorPeeringRole.defaultValue | Should -Be 'None'
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

      It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev (Phase 5)' {
          (Get-StampModuleParameters 'storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
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

      It 'outputs the private-endpoint subnet that hosts the AMPLS endpoint in the primary region (Phase 6)' {
          $stamp.outputs.privateEndpointSubnetId.value | Should -Be "[reference('spokeNetwork').outputs.privateEndpointSubnetId.value]"
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

  Describe 'Region stamp hub peering (Phase 6)' {
      It 'takes an optional hub peering plan, absent by default (dev, or prod without DR)' {
          $stamp.parameters.hubPeering.nullable | Should -BeExactly $true
          $stamp.parameters.hubPeering.'$ref' | Should -Be '#/definitions/hubPeeringPlan'
      }

      It 'routes the other region''s spoke from AzureFirewallSubnet to the other firewall' {
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.remoteSpokeAddressPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteSpokeAddressPrefixes'\)"
          $hub.remoteFirewallPrivateIp.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteFirewallPrivateIp'\)"
      }

      It 'passes the Azure Monitor role and prefixes to the firewall rules' {
          $firewall = Get-StampModuleParameters 'azure-firewall'
          $firewall.monitorPeeringRole.value | Should -Be "[variables('monitorPeeringRole')]"
          $firewall.monitorClientPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorClientPrefixes'\)"
          $firewall.monitorPrivateEndpointPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorPrivateEndpointPrefixes'\)"
          $stamp.variables.monitorPeeringRole | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorRole'\), 'None'\)"
      }

      It 'lets the local firewall reach the private endpoints only in the region that hosts the AMPLS endpoint (it SNATs peer traffic)' {
          $stamp.variables.peerTrafficSourceCidrs |
              Should -Be "[if(equals(variables('monitorPeeringRole'), 'Host'), createArray(parameters('addressPlan').firewallSubnetPrefix), createArray())]"
          (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value | Should -Match "variables\('peerTrafficSourceCidrs'\)"
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
      It 'defines the zone names once: three application zones and four Azure Monitor (AMPLS) zones' {
          @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault,monitor,oms,ods,agentsvc'
          $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
          $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
      }

      It 'adds the AMPLS zone <Key> = <Zone> (Phase 6)' -ForEach @(
          @{ Key = 'monitor'; Zone = 'privatelink.monitor.azure.com' }
          @{ Key = 'oms'; Zone = 'privatelink.oms.opinsights.azure.com' }
          @{ Key = 'ods'; Zone = 'privatelink.ods.opinsights.azure.com' }
          @{ Key = 'agentsvc'; Zone = 'privatelink.agentsvc.azure-automation.net' }
      ) {
          $main.variables.privateDnsZoneNames.$Key | Should -BeExactly $Zone
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

      It 'outputs the Front Door profile name and the global resource group name, so the pipeline can poll the origin group (final review A)' {
          foreach ($output in 'frontDoorProfileName', 'globalResourceGroupName') {
              $main.outputs.PSObject.Properties.Name | Should -Contain $output
          }
          $main.outputs.frontDoorProfileName.value | Should -Be "[reference('frontDoor').outputs.profileName.value]"
          $main.outputs.globalResourceGroupName.value | Should -Be "[variables('globalResourceGroupName')]"
      }
  }

  Describe 'Azure Monitor Private Link Scope (Phase 6)' {
      BeforeAll {
          $scope = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateLinkScope'
          $endpoint = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateEndpoint'
      }

      It 'deploys one scope per environment into the global resource group' {
          $scope.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $scope.properties.parameters.scopeName.value | Should -Be "[format('ampls-defenstack-{0}', parameters('environmentName'))]"
      }

      It 'scopes the workspace and the primary App Insights component, plus the secondary component only when deployed' {
          $value = $scope.properties.parameters.scopedResourceIds.value
          $value | Should -Match "^\[concat\(createArray\(reference\('global'\)\.outputs\.logAnalyticsWorkspaceId\.value, reference\('primaryStamp'\)\.outputs\.appInsightsId\.value\)"
          $value | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(reference\('secondaryStamp'\)\.outputs\.appInsightsId\.value\), createArray\(\)\)"
      }

      It 'puts the single azuremonitor endpoint in the primary spoke private-endpoint subnet' {
          $endpoint.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $endpoint.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
          $endpoint.properties.parameters.privateEndpointSubnetId.value | Should -Be "[reference('primaryStamp').outputs.privateEndpointSubnetId.value]"
          $endpoint.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
      }

      It 'creates the endpoint after the scope holds its resources, so the DNS records cover them all' {
          $endpoint.properties.parameters.privateLinkScopeId.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.id.value]"
          @($endpoint.dependsOn) | Should -Contain 'monitorPrivateLinkScope'
      }

      It 'outputs the scope name for runbook 06' {
          $main.outputs.monitorPrivateLinkScopeName.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.name.value]"
      }
  }

  Describe 'Hub-to-hub peering and firewall routing (Phase 6)' {
      BeforeAll {
          $primaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryHubPeering'
          $secondaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryHubPeering'
      }

      It 'peers the hubs both ways only when the secondary region is deployed' {
          foreach ($peering in $primaryPeering, $secondaryPeering) {
              $peering.condition | Should -Be "[parameters('deploySecondaryRegion')]"
          }
          $primaryPeering.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $secondaryPeering.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
      }

      It 'points each hub at the other hub' {
          $primaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('primaryStamp').outputs.hubVnetName.value]"
          $primaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetId.value]"
          $primaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('secondaryRegionCode'))]"
          $secondaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetName.value]"
          $secondaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('primaryStamp').outputs.hubVnetId.value]"
          $secondaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('primaryRegionCode'))]"
      }

      It 'creates the two sides one after the other' {
          @($secondaryPeering.dependsOn) | Should -Contain 'primaryHubPeering'
      }

      It 'makes the primary (AMPLS endpoint) region the Host and the secondary the Client, only with DR' {
          $primary.properties.parameters.hubPeering | Should -Match "^\[if\(parameters\('deploySecondaryRegion'\), createObject\('value', createObject\("
          $primary.properties.parameters.hubPeering | Should -Match "'monitorRole', 'Host'"
          $primary.properties.parameters.hubPeering | Should -Match "createObject\('value', null\(\)\)\)\]$"
          $secondary.properties.parameters.hubPeering.value.monitorRole | Should -Be 'Client'
      }

      It 'routes each region''s firewall to the other firewall at the first usable address of its AzureFirewallSubnet' {
          $primary.properties.parameters.hubPeering | Should -Match "'remoteFirewallPrivateIp', cidrHost\(parameters\('secondaryAddressPlan'\)\.firewallSubnetPrefix, 3\)"
          $primary.properties.parameters.hubPeering | Should -Match "'remoteSpokeAddressPrefixes', parameters\('secondaryAddressPlan'\)\.spokeAddressSpace"
          $secondary.properties.parameters.hubPeering.value.remoteFirewallPrivateIp | Should -Be "[cidrHost(parameters('primaryAddressPlan').firewallSubnetPrefix, 3)]"
          $secondary.properties.parameters.hubPeering.value.remoteSpokeAddressPrefixes | Should -Be "[parameters('primaryAddressPlan').spokeAddressSpace]"
          $secondary.properties.parameters.hubPeering.value.monitorClientPrefixes | Should -Be "[variables('monitorClientPrefixes')]"
          $primary.properties.parameters.hubPeering | Should -Match "'monitorClientPrefixes', variables\('monitorClientPrefixes'\)"
      }

      It 'allows only the East US App Service and management subnets to the primary private-endpoint subnet' {
          $main.variables.monitorClientPrefixes |
              Should -Be "[if(parameters('deploySecondaryRegion'), createArray(parameters('secondaryAddressPlan').appServiceIntegrationSubnetPrefix, parameters('secondaryAddressPlan').managementSubnetPrefix), createArray())]"
          @($main.variables.monitorPrivateEndpointPrefixes) | Should -Be @("[parameters('primaryAddressPlan').privateEndpointSubnetPrefix]")
      }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected failures: `bicep build failed for modules/hubPeering.bicep`, the firewall route table tests, the `cross-region-monitoring` group tests (the group count is now 5), the pass-through parameters, and the `Hub-to-hub peering and firewall routing (Phase 6)` and `Region stamp hub peering (Phase 6)` tests.

- [ ] **Step 3: Create the peering module and the shared type**

  Create `modules/hubPeering.bicep`:

  ```bicep
  // One side of the hub-to-hub global peering (prod with DR). main.bicep deploys it once in each region's resource group.

  @description('This region\'s hub VNet name, in this resource group.')
  @minLength(2)
  @maxLength(64)
  param localVnetName string

  @description('Resource ID of the other region\'s hub VNet.')
  param remoteVnetId string

  @description('Peering name, for example hub-to-eus-hub.')
  @minLength(1)
  @maxLength(80)
  param peeringName string

  resource hubVnet 'Microsoft.Network/virtualNetworks@2025-09-01' existing = {
    name: localVnetName
  }

  // Spoke traffic crosses the peering after a firewall has forwarded it, so forwarded traffic is accepted. Each hub
  // owns its own VPN gateway, so the peering neither offers nor uses a remote gateway.
  resource hubToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = {
    parent: hubVnet
    name: peeringName
    properties: {
      allowVirtualNetworkAccess: true
      allowForwardedTraffic: true
      allowGatewayTransit: false
      useRemoteGateways: false
      remoteVirtualNetwork: {
        id: remoteVnetId
      }
    }
  }

  output id string = hubToHubPeering.id
  ```

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
  @description('Private DNS zone names (or resource IDs) keyed by private endpoint group: the application zones plus the Azure Monitor Private Link Scope zones (Phase 6).')
  type privateDnsZoneSet = {
    @description('Blob storage zone.')
    blob: string

    @description('App Service (sites) zone.')
    sites: string

    @description('Key Vault zone.')
    vault: string

    @description('Azure Monitor global endpoints zone (AMPLS).')
    monitor: string

    @description('Log Analytics workspace agent endpoints zone (AMPLS).')
    oms: string

    @description('Log Analytics workspace ingestion (ODS) endpoints zone (AMPLS).')
    ods: string

    @description('Log Analytics agent service endpoints zone (AMPLS).')
    agentsvc: string
  }

  @export()
  @description('A virtual network to link to a private DNS zone.')
  type virtualNetworkReference = {
    @description('VNet name; used to build a unique link name.')
    name: string

    @description('VNet resource ID.')
    id: string
  }

  @export()
  @description('Prod with DR only: how this region\'s firewall carries traffic to and from the other region over the hub-to-hub global peering (Phase 6).')
  type hubPeeringPlan = {
    @description('Private IP of the other region\'s firewall, the next hop for the other region\'s spoke.')
    remoteFirewallPrivateIp: string

    @description('Spoke address prefixes of the other region, routed from this AzureFirewallSubnet to the other firewall.')
    remoteSpokeAddressPrefixes: string[]

    @description('This region\'s part in Azure Monitor traffic: Host owns the AMPLS private endpoint, Client forwards its spoke to it.')
    monitorRole: 'Host' | 'Client'

    @description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
    monitorClientPrefixes: string[]

    @description('Private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint. Used by the Client rule.')
    monitorPrivateEndpointPrefixes: string[]
  }
  ```

- [ ] **Step 4: Route the firewall subnet and add the cross-region rules**

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

  @description('Spoke address prefixes of the other region, reached through the hub-to-hub peering (prod with DR). Empty leaves AzureFirewallSubnet without a route table.')
  param remoteSpokeAddressPrefixes array = []

  @description('Private IP of the other region\'s firewall, the next hop for remoteSpokeAddressPrefixes.')
  param remoteFirewallPrivateIp string = ''

  var firewallSubnetName = 'AzureFirewallSubnet'
  var bastionSubnetName = 'AzureBastionSubnet'
  var gatewaySubnetName = 'GatewaySubnet'
  var bastionNsgName = '${vnetName}-bastion-nsg'
  var gatewayRouteTableName = '${vnetName}-gateway-rt'
  var firewallRouteTableName = '${vnetName}-firewall-rt'
  // The other region's spoke goes to the other firewall. Once AzureFirewallSubnet has a route table, Azure Firewall
  // requires 0.0.0.0/0 to Internet on it, so the firewall keeps its own egress whatever is learned over BGP.
  var firewallRoutes = concat(
    map(remoteSpokeAddressPrefixes, (prefix, i) => {
      name: 'remote-spoke-${i}-through-peer-firewall'
      properties: {
        addressPrefix: prefix
        nextHopType: 'VirtualAppliance'
        nextHopIpAddress: remoteFirewallPrivateIp
      }
    }),
    [
      {
        name: 'default-to-internet'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'Internet'
        }
      }
    ]
  )

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

  // Prod with DR: cross-region spoke traffic leaves this firewall for the other region's firewall over the hub peering.
  // Gateway route propagation stays on, so the firewall still learns the VPN client pool and can answer admin sessions.
  resource firewallRouteTable 'Microsoft.Network/routeTables@2024-07-01' = if (!empty(remoteSpokeAddressPrefixes)) {
    name: firewallRouteTableName
    location: location
    properties: {
      disableBgpRoutePropagation: false
      routes: firewallRoutes
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
            routeTable: empty(remoteSpokeAddressPrefixes) ? null : {
              id: firewallRouteTable.id
            }
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

  @description('This region\'s part in cross-region Azure Monitor traffic over the hub peering (prod with DR): Host owns the AMPLS private endpoint, Client forwards its spoke to it, None deploys no cross-region rules.')
  @allowed([
    'None'
    'Host'
    'Client'
  ])
  param monitorPeeringRole string = 'None'

  @description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
  param monitorClientPrefixes array = []

  @description('Client role: private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint.')
  param monitorPrivateEndpointPrefixes array = []

  // Entra ID sign-in host for this cloud, for example login.microsoftonline.com.
  var entraLoginHost = split(environment().authentication.loginEndpoint, '/')[2]

  // Host: an application rule, so the firewall SNATs the other region's traffic to its own address and the private
  // endpoint's replies return through it (a network rule would keep the remote source, which the spoke cannot route).
  var monitorHostCollection = {
    name: 'peer-spoke-to-azure-monitor'
    priority: 250
    ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
    action: {
      type: 'Allow'
    }
    rules: [
      {
        ruleType: 'ApplicationRule'
        name: 'azure-monitor-private-link'
        sourceAddresses: monitorClientPrefixes
        protocols: [
          {
            protocolType: 'Https'
            port: 443
          }
        ]
        targetFqdns: [
          '*.applicationinsights.azure.com'
          '*.monitor.azure.com'
          '*.ods.opinsights.azure.com'
          '*.oms.opinsights.azure.com'
          '*.agentsvc.azure-automation.net'
        ]
      }
    ]
  }

  // Client: a network rule that forwards, unchanged, only to the Host region's private-endpoint subnet; the AzureFirewallSubnet
  // route table sends it to the Host firewall over the peering.
  var monitorClientCollection = {
    name: 'spoke-to-peer-azure-monitor'
    priority: 250
    ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
    action: {
      type: 'Allow'
    }
    rules: [
      {
        ruleType: 'NetworkRule'
        name: 'azure-monitor-private-endpoint'
        ipProtocols: [
          'TCP'
        ]
        sourceAddresses: monitorClientPrefixes
        destinationAddresses: monitorPrivateEndpointPrefixes
        destinationPorts: [
          '443'
        ]
      }
    ]
  }

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

  // Prod with DR: the other region's spoke reaches the single AMPLS private endpoint through both firewalls. Broader
  // cross-region traffic waits for Phase 8.
  resource crossRegionMonitoring 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2025-01-01' = if (monitorPeeringRole != 'None') {
    parent: firewallPolicy
    name: 'cross-region-monitoring'
    properties: {
      priority: 250
      ruleCollections: monitorPeeringRole == 'Host' ? [
        monitorHostCollection
      ] : [
        monitorClientCollection
      ]
    }
    // approved-https-egress is optional, so wait for platform-egress too and never run beside another group.
    dependsOn: [
      platformEgress
      approvedHttpsEgress
    ]
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

  @description('This region\'s part in cross-region Azure Monitor traffic over the hub peering: Host, Client, or None (dev, or prod without DR).')
  @allowed([
    'None'
    'Host'
    'Client'
  ])
  param monitorPeeringRole string = 'None'

  @description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
  param monitorClientPrefixes array = []

  @description('Client role: private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint.')
  param monitorPrivateEndpointPrefixes array = []

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
      monitorPeeringRole: monitorPeeringRole
      monitorClientPrefixes: monitorClientPrefixes
      monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
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

- [ ] **Step 5: Wire the stamps and the peerings**

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet, hubPeeringPlan } from 'types.bicep'

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

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  @description('Application secrets written to this region\'s Key Vault, as { name: value } (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  @description('Prod with DR only: routing and Azure Monitor rules for the hub-to-hub peering with the other region. Absent in dev and in prod without DR.')
  param hubPeering hubPeeringPlan?

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
    appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var monitorPeeringRole = hubPeering.?monitorRole ?? 'None'
  // The region hosting the AMPLS endpoint SNATs the other region's monitoring traffic at its firewall, so the
  // private-endpoint NSG must admit the firewall subnet there (Phase 6).
  var peerTrafficSourceCidrs = monitorPeeringRole == 'Host' ? [
    addressPlan.firewallSubnetPrefix
  ] : []
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
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
      secrets: keyVaultSecrets
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
      remoteSpokeAddressPrefixes: hubPeering.?remoteSpokeAddressPrefixes ?? []
      remoteFirewallPrivateIp: hubPeering.?remoteFirewallPrivateIp ?? ''
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
      monitorPeeringRole: monitorPeeringRole
      monitorClientPrefixes: hubPeering.?monitorClientPrefixes ?? []
      monitorPrivateEndpointPrefixes: hubPeering.?monitorPrivateEndpointPrefixes ?? []
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
      ], peerTrafficSourceCidrs, additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  // One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
  module appInsights 'appInsights.bicep' = {
    name: 'app-insights'
    params: {
      location: location
      componentName: names.appInsights
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
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
      applicationInsightsConnectionString: appInsights.outputs.connectionString
    }
  }

  module appInsightsPublisher 'appInsightsPublisher.bicep' = {
    name: 'app-insights-publisher'
    params: {
      componentName: appInsights.outputs.name
      publisherPrincipalId: appService.outputs.appServicePrincipalId
      publisherAppServiceName: names.appService
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

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
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
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceId string = appService.outputs.appServiceAppId
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  output appInsightsName string = appInsights.outputs.name
  output appInsightsId string = appInsights.outputs.id
  output privateEndpointSubnetId string = spokeNetwork.outputs.privateEndpointSubnetId
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

  @description('Application secrets written to every regional Key Vault, as { name: value }. The pipeline supplies them from the KEYVAULT_SECRETS_JSON environment secret; never put values in a committed parameter file (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

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
    // Azure Monitor Private Link Scope zones (Phase 6); the AMPLS endpoint also registers in the blob zone above.
    monitor: 'privatelink.monitor.azure.com'
    oms: 'privatelink.oms.opinsights.azure.com'
    ods: 'privatelink.ods.opinsights.azure.com'
    agentsvc: 'privatelink.agentsvc.azure-automation.net'
  }

  // Prod with DR (Phase 6): the East US App Service and management subnets may reach the one AMPLS endpoint, in the
  // primary private-endpoint subnet, through both firewalls and the hub-to-hub peering. Nothing else crosses yet (Phase 8).
  var monitorClientPrefixes = deploySecondaryRegion ? [
    secondaryAddressPlan!.appServiceIntegrationSubnetPrefix
    secondaryAddressPlan!.managementSubnetPrefix
  ] : []
  var monitorPrivateEndpointPrefixes = [
    primaryAddressPlan.privateEndpointSubnetPrefix
  ]

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
      keyVaultSecrets: keyVaultSecrets
      // A firewall always takes the first usable address (.4) of its AzureFirewallSubnet (see regionStamp.bicep).
      hubPeering: deploySecondaryRegion ? {
        remoteFirewallPrivateIp: cidrHost(secondaryAddressPlan!.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: secondaryAddressPlan!.spokeAddressSpace
        monitorRole: 'Host'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      } : null
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
      primaryStorageAccountId: isProd ? primaryStamp.outputs.storageAccountId : ''
      primaryStorageAccountName: isProd ? primaryStamp.outputs.storageAccountName : ''
      keyVaultSecrets: keyVaultSecrets
      hubPeering: {
        remoteFirewallPrivateIp: cidrHost(primaryAddressPlan.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: primaryAddressPlan.spokeAddressSpace
        monitorRole: 'Client'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      }
    }
  }

  // Hub-to-hub global peering, both ways, once both hubs exist (brought forward from Phase 8). The sides are created
  // one after the other, since each peering operation updates both VNets.
  module primaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${primaryRegionCode}-to-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      localVnetName: primaryStamp.outputs.hubVnetName
      remoteVnetId: secondaryStamp!.outputs.hubVnetId
      peeringName: 'hub-to-${secondaryRegionCode}-hub'
    }
  }

  module secondaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${secondaryRegionCode}-to-${primaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      localVnetName: secondaryStamp!.outputs.hubVnetName
      remoteVnetId: primaryStamp.outputs.hubVnetId
      peeringName: 'hub-to-${primaryRegionCode}-hub'
    }
    dependsOn: [
      primaryHubPeering
    ]
  }

  // The warm-standby App Service may read (never write) the primary application container (ADR-020).
  module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion && isProd) {
    name: 'storage-reader-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      storageAccountName: primaryStamp.outputs.storageAccountName
      storageContainerName: primaryStamp.outputs.storageContainerName
      readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
      readerAppServiceName: secondaryStamp!.outputs.appServiceName
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

  // Private-only monitoring (Phase 6): one scope holds the workspace and every regional App Insights component.
  module monitorPrivateLinkScope 'modules/monitorPrivateLinkScope.bicep' = {
    name: 'monitor-private-link-scope-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      scopeName: 'ampls-defenstack-${environmentName}'
      scopedResourceIds: concat([
        global.outputs.logAnalyticsWorkspaceId
        primaryStamp.outputs.appInsightsId
      ], deploySecondaryRegion ? [
        secondaryStamp!.outputs.appInsightsId
      ] : [])
    }
  }

  // The single azuremonitor endpoint, in the primary spoke, created once the scope holds every resource.
  module monitorPrivateEndpoint 'modules/monitorPrivateEndpoint.bicep' = {
    name: 'monitor-private-endpoint-${environmentName}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      location: primaryLocation
      privateLinkScopeId: monitorPrivateLinkScope.outputs.id
      privateLinkScopeName: monitorPrivateLinkScope.outputs.name
      privateEndpointSubnetId: primaryStamp.outputs.privateEndpointSubnetId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
    }
  }

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output frontDoorProfileName string = frontDoor.outputs.profileName
  output globalResourceGroupName string = globalResourceGroupName
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
  output monitorPrivateLinkScopeName string = monitorPrivateLinkScope.outputs.name
  ```

- [ ] **Step 6: Build, lint, test, PSRule**

  Run `bicep build main.bicep` and lint every file (no `LINT FAIL`). The full suite should show `Tests Passed: 442, Failed: 0`. PSRule should show 0 failures out of 993 rules processed.

- [ ] **Step 7: Commit**

  ```bash
  git add modules/hubPeering.bicep modules/types.bicep modules/hubNetwork.bicep modules/firewallPolicyRules.bicep modules/azureFirewall.bicep modules/regionStamp.bicep main.bicep main.json tests/HubPeering.Tests.ps1 tests/HubNetwork.Tests.ps1 tests/FirewallPolicyRules.Tests.ps1 tests/AzureFirewall.Tests.ps1 tests/RegionStamp.Tests.ps1 tests/Main.Tests.ps1
  git commit -m "feat: hub-to-hub global peering with firewall-subnet routing for cross-region monitoring" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 3: VNet flow logs with Traffic Analytics through a keyless regional account

**Files:**
- Create: `modules/flowLogStorage.bicep`, `modules/flowLogs.bicep`, `tests/FlowLogs.Tests.ps1`
- Replace: `modules/regionStamp.bicep`, `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Scripts.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes:** the stamp's `names`, `nameSuffix`, `isProd`, `location`, `logAnalyticsWorkspaceId`, `environmentName` and `regionCode`; the hub and spoke VNet names and IDs; the `virtualNetworkReference` type; the existing delegatable role `ba92f5b4-2d11-453d-a403-e96b0029c9fe`.
- **Produces:**
  - `flowLogStorage.bicep(location, storageAccountName, storageAccountSkuName, identityName, softDeleteRetentionDays = 7)`, outputs `id` and `identityId`. Stamp deployment `flow-log-storage`; names `stfl<regionCode><nameSuffix>` and `id-flowlogs-defenstack-<env>-<regionCode>`; SKU `Standard_ZRS` in prod, `Standard_LRS` in dev.
  - `flowLogs.bicep(location, virtualNetworks, storageAccountId, identityId, logAnalyticsWorkspaceId, retentionDays = 90, trafficAnalyticsIntervalMinutes = 10)`, deployed as `flow-logs-<env>-<regionCode>` with `scope: resourceGroup('NetworkWatcherRG')`, one flow log `<vnetName>-flowlog` per VNet.
  - Identity script param `-NetworkWatcherResourceGroupName` (default `NetworkWatcherRG`) and step 6, which assigns **Network Contributor** on that resource group only.

- [ ] **Step 1: Write the failing tests**

  Create `tests/FlowLogs.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $storageTemplate = Get-BicepTemplate -RelativePath 'modules/flowLogStorage.bicep'
      $account = Get-TemplateResource -Template $storageTemplate -Type 'Microsoft.Storage/storageAccounts' | Select-Object -First 1
      $identity = Get-TemplateResource -Template $storageTemplate -Type 'Microsoft.ManagedIdentity/userAssignedIdentities' | Select-Object -First 1
      $assignments = @(Get-TemplateResource -Template $storageTemplate -Type 'Microsoft.Authorization/roleAssignments')
      $flowLogTemplate = Get-BicepTemplate -RelativePath 'modules/flowLogs.bicep'
      $flowLog = Get-TemplateResource -Template $flowLogTemplate -Type 'Microsoft.Network/networkWatchers/flowLogs' | Select-Object -First 1
      $existing = @($flowLogTemplate.resources.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { $_.PSObject.Properties.Name -contains 'existing' })
  }

  Describe 'Flow-log storage account (Phase 6)' {
      It 'disables shared key access, so writers must use Entra ID' {
          $account.properties.allowSharedKeyAccess | Should -BeExactly $false
          $account.properties.defaultToOAuthAuthentication | Should -BeExactly $true
      }

      It 'disables public network access and denies by default, letting only trusted Azure services through' {
          $account.properties.publicNetworkAccess | Should -Be 'Disabled'
          $account.properties.networkAcls.defaultAction | Should -Be 'Deny'
          $account.properties.networkAcls.bypass | Should -Be 'AzureServices'
      }

      It 'keeps the account hardening baseline (TLS 1.2, HTTPS only, no public blobs)' {
          $account.properties.minimumTlsVersion | Should -Be 'TLS1_2'
          $account.properties.supportsHttpsTrafficOnly | Should -BeExactly $true
          $account.properties.allowBlobPublicAccess | Should -BeExactly $false
      }

      It 'takes its redundancy from the caller' {
          $account.sku.name | Should -Be "[parameters('storageAccountSkuName')]"
      }
  }

  Describe 'Flow-log writer identity (Phase 6)' {
      It 'is a user-assigned managed identity in the same resource group' {
          $identity.name | Should -Be "[parameters('identityName')]"
          $identity.location | Should -Be "[parameters('location')]"
      }

      It 'gets Storage Blob Data Contributor on the flow-log account only' {
          $assignments.Count | Should -Be 1
          $assignment = $assignments[0]
          $storageTemplate.variables.storageBlobDataContributorRoleId | Should -Be 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
          $assignment.scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName'))]"
          $assignment.properties.principalType | Should -Be 'ServicePrincipal'
          $assignment.properties.principalId | Should -Match "userAssignedIdentities', parameters\('identityName'\)\), '2023-01-31'\)\.principalId\]$"
      }

      It 'outputs the account and identity IDs for the flow logs' {
          foreach ($output in 'id', 'identityId') {
              $storageTemplate.outputs.PSObject.Properties.Name | Should -Contain $output
          }
      }
  }

  Describe 'VNet flow logs (Phase 6)' {
      It 'uses the region''s existing NetworkWatcher_<region> as parent' {
          $watcher = $existing | Where-Object { $_.type -eq 'Microsoft.Network/networkWatchers' }
          $watcher.name | Should -Be "[format('NetworkWatcher_{0}', parameters('location'))]"
          $flowLog.name | Should -Match "^\[format\('\{0\}/\{1\}', format\('NetworkWatcher_\{0\}', parameters\('location'\)\)"
      }

      It 'logs every VNet passed in, one flow log each named after the VNet' {
          $flowLog.copy.count | Should -Be "[length(parameters('virtualNetworks'))]"
          $flowLog.name | Should -Match "format\('\{0\}-flowlog', parameters\('virtualNetworks'\)\[copyIndex\(\)\]\.name\)"
          $flowLog.properties.targetResourceId | Should -Be "[parameters('virtualNetworks')[copyIndex()].id]"
          $flowLog.properties.enabled | Should -BeExactly $true
      }

      It 'writes to the flow-log account with the user-assigned identity, not a key' {
          $flowLog.properties.storageId | Should -Be "[parameters('storageAccountId')]"
          $flowLog.identity.type | Should -Be 'UserAssigned'
          @($flowLog.identity.userAssignedIdentities.PSObject.Properties.Name) | Should -Be @("[format('{0}', parameters('identityId'))]")
      }

      It 'keeps 90 days of records in version 2 JSON' {
          $flowLogTemplate.parameters.retentionDays.defaultValue | Should -Be 90
          $flowLog.properties.retentionPolicy.enabled | Should -BeExactly $true
          $flowLog.properties.retentionPolicy.days | Should -Be "[parameters('retentionDays')]"
          $flowLog.properties.format.type | Should -Be 'JSON'
          $flowLog.properties.format.version | Should -Be 2
      }

      It 'sends Traffic Analytics to the central workspace every 10 minutes' {
          $analytics = $flowLog.properties.flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration
          $analytics.enabled | Should -BeExactly $true
          $analytics.workspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
          $analytics.workspaceId | Should -Match '\.customerId\]$'
          $analytics.workspaceRegion | Should -Match "'full'\)\.location\]$"
          $flowLogTemplate.parameters.trafficAnalyticsIntervalMinutes.defaultValue | Should -Be 10
          $analytics.trafficAnalyticsInterval | Should -Be "[parameters('trafficAnalyticsIntervalMinutes')]"
      }

      It 'pins the GA API version 2024-07-01 (identity support starts at 2024-01-01)' {
          $flowLog.apiVersion | Should -Be '2024-07-01'
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

      It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev (Phase 5)' {
          (Get-StampModuleParameters 'storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
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

      It 'outputs the private-endpoint subnet that hosts the AMPLS endpoint in the primary region (Phase 6)' {
          $stamp.outputs.privateEndpointSubnetId.value | Should -Be "[reference('spokeNetwork').outputs.privateEndpointSubnetId.value]"
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

  Describe 'Region stamp hub peering (Phase 6)' {
      It 'takes an optional hub peering plan, absent by default (dev, or prod without DR)' {
          $stamp.parameters.hubPeering.nullable | Should -BeExactly $true
          $stamp.parameters.hubPeering.'$ref' | Should -Be '#/definitions/hubPeeringPlan'
      }

      It 'routes the other region''s spoke from AzureFirewallSubnet to the other firewall' {
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.remoteSpokeAddressPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteSpokeAddressPrefixes'\)"
          $hub.remoteFirewallPrivateIp.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteFirewallPrivateIp'\)"
      }

      It 'passes the Azure Monitor role and prefixes to the firewall rules' {
          $firewall = Get-StampModuleParameters 'azure-firewall'
          $firewall.monitorPeeringRole.value | Should -Be "[variables('monitorPeeringRole')]"
          $firewall.monitorClientPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorClientPrefixes'\)"
          $firewall.monitorPrivateEndpointPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorPrivateEndpointPrefixes'\)"
          $stamp.variables.monitorPeeringRole | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorRole'\), 'None'\)"
      }

      It 'lets the local firewall reach the private endpoints only in the region that hosts the AMPLS endpoint (it SNATs peer traffic)' {
          $stamp.variables.peerTrafficSourceCidrs |
              Should -Be "[if(equals(variables('monitorPeeringRole'), 'Host'), createArray(parameters('addressPlan').firewallSubnetPrefix), createArray())]"
          (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value | Should -Match "variables\('peerTrafficSourceCidrs'\)"
      }
  }

  Describe 'Region stamp flow logs (Phase 6)' {
      BeforeAll {
          $flowLogs = Get-ModuleDeployment -Template $stamp -Name "[format('flow-logs-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
      }

      It 'names the flow-log account and identity per environment and region' {
          $stamp.variables.names.flowLogStorageAccount | Should -Be "[format('stfl{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
          $stamp.variables.names.flowLogIdentity | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
      }

      It 'keeps flow logs zone-redundant in prod and locally redundant in dev' {
          (Get-StampModuleParameters 'flow-log-storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), createObject('value', 'Standard_ZRS'), createObject('value', 'Standard_LRS'))]"
      }

      It 'deploys the flow logs into NetworkWatcherRG, where the region''s Network Watcher lives' {
          $flowLogs.resourceGroup | Should -Be 'NetworkWatcherRG'
          $flowLogs.properties.parameters.location.value | Should -Be "[parameters('location')]"
      }

      It 'logs both the hub and the spoke VNet' {
          $value = @($flowLogs.properties.parameters.virtualNetworks.value)
          $value[0].name | Should -Be "[variables('names').hubVnet]"
          $value[0].id | Should -Be "[reference('hubNetwork').outputs.id.value]"
          $value[1].name | Should -Be "[variables('names').spokeVnet]"
          $value[1].id | Should -Be "[reference('spokeNetwork').outputs.id.value]"
      }

      It 'writes with the flow-log identity to the flow-log account and analyses into the central workspace' {
          $parameters = $flowLogs.properties.parameters
          $parameters.storageAccountId.value | Should -Be "[reference('flowLogStorage').outputs.id.value]"
          $parameters.identityId.value | Should -Be "[reference('flowLogStorage').outputs.identityId.value]"
          $parameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
      }
  }
  ```

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

      It 'targets NetworkWatcherRG by default and accepts only a valid resource group name (Phase 6)' {
          $parameter = (Get-Command $scriptPath).Parameters['NetworkWatcherResourceGroupName']
          $parameter | Should -Not -BeNullOrEmpty
          (Get-Content $scriptPath -Raw) | Should -Match '\[string\]\$NetworkWatcherResourceGroupName = ''NetworkWatcherRG'''
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -NetworkWatcherResourceGroupName 'bad/name' -WhatIf } |
                  Should -Throw
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

          It 'assigns Network Contributor on NetworkWatcherRG only, so the pipeline can manage VNet flow logs (Phase 6)' {
              $networkWatcherScope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/NetworkWatcherRG'
              $networkContributor = @($creates | Where-Object { $_ -like '*--role Network Contributor *' })
              $networkContributor.Count | Should -Be 1
              $networkContributor[0] | Should -BeLike "*--scope $networkWatcherScope *"
              @($creates | Where-Object { $_ -like "*--scope $networkWatcherScope *" }).Count | Should -Be 1
          }

          It 'constrains RBAC Administrator with the exact ABAC condition for the delegatable roles (Storage Blob Data Contributor, Virtual Machine Administrator Login, Storage Blob Data Reader, Monitoring Metrics Publisher)' {
              $expected = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb}))"
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
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 2
              ($credentials | Where-Object { $_.name -eq 'github-dev' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev'
              ($credentials | Where-Object { $_.name -eq 'github-dev-plan' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev-plan'
              foreach ($credential in $credentials) {
                  $credential.issuer | Should -BeExactly 'https://token.actions.githubusercontent.com'
                  @($credential.audiences) | Should -Be @('api://AzureADTokenExchange')
              }
          }

          It 'creates only github-staging for an environment not on the ungated-plan allowlist, with no plan credential (Final review D.7, fail closed)' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = 'existing-custom-role'
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'staging' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-staging'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:staging'
          }

          It 'creates only github-prod for the prod environment, with no plan credential' {
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
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-prod'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:prod'
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

  Describe 'Role GUIDs are all delegatable' {
      It 'includes every role-definition GUID used in modules/*.bicep in the default -DelegatableRoleDefinitionIds list' {
          $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
          $roleGuids = [System.Collections.Generic.HashSet[string]]::new()
          foreach ($file in Get-ChildItem (Get-RepoPath 'modules') -Filter '*.bicep') {
              $text = Get-Content $file.FullName -Raw
              foreach ($match in [regex]::Matches($text, "subscriptionResourceId\('Microsoft\.Authorization/roleDefinitions',\s*'($guidPattern)'\)")) {
                  [void]$roleGuids.Add($match.Groups[1].Value.ToLowerInvariant())
              }
              foreach ($match in [regex]::Matches($text, "(?:roleDefinitionId|roleId|\w*RoleId)\s*=\s*'($guidPattern)'")) {
                  [void]$roleGuids.Add($match.Groups[1].Value.ToLowerInvariant())
              }
          }

          # The test must not pass vacuously: it has to find at least one GUID to check.
          $roleGuids.Count | Should -BeGreaterThan 0

          # Strip comments first, so a parenthesis inside one (e.g. "(app identity, container scope)")
          # cannot be mistaken for the end of the @(...) array below.
          $scriptTextNoComments = (Get-Content $scriptPath -Raw) -replace '#[^\r\n]*', ''
          $defaultBlock = [regex]::Match($scriptTextNoComments, '\$DelegatableRoleDefinitionIds\s*=\s*@\((.*?)\)', 'Singleline').Groups[1].Value
          $defaultBlock | Should -Not -BeNullOrEmpty

          foreach ($roleGuid in $roleGuids) {
              $defaultBlock | Should -Match ([regex]::Escape($roleGuid))
          }
      }
  }

  AfterAll {
      Remove-Variable -Name AzCalls, FederatedCredentialPayloads, RoleDefinitionPayload -Scope Global -ErrorAction SilentlyContinue
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected failures: `bicep build failed for modules/flowLogStorage.bicep` and `modules/flowLogs.bicep`, the `Region stamp flow logs (Phase 6)` tests, and the two script tests for `-NetworkWatcherResourceGroupName` and Network Contributor.

- [ ] **Step 3: Create the flow-log modules**

  Create `modules/flowLogStorage.bicep`:

  ```bicep
  // Regional destination for VNet flow logs: a dedicated keyless, private storage account and the user-assigned
  // identity Network Watcher writes with. Flow-log storage must be in the same region as the VNets it records.

  @description('Azure region for the account and identity (the VNets\' region).')
  param location string

  @description('Globally unique flow-log storage account name.')
  @minLength(3)
  @maxLength(24)
  param storageAccountName string

  @description('Storage redundancy SKU for the flow-log account.')
  param storageAccountSkuName string

  @description('User-assigned managed identity name used by the flow logs.')
  @minLength(3)
  @maxLength(128)
  param identityName string

  @description('Days that deleted flow-log blobs and containers stay recoverable.')
  @minValue(1)
  @maxValue(365)
  param softDeleteRetentionDays int = 7

  var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

  // No shared key and no public network access: Network Watcher reaches it as a trusted Azure service and
  // authenticates with the identity below (shared-key writes would fail).
  resource storageAccount 'Microsoft.Storage/storageAccounts@2026-04-01' = {
    name: storageAccountName
    location: location
    sku: {
      name: storageAccountSkuName
    }
    kind: 'StorageV2'
    properties: {
      accessTier: 'Hot'
      allowBlobPublicAccess: false
      allowSharedKeyAccess: false
      defaultToOAuthAuthentication: true
      minimumTlsVersion: 'TLS1_2'
      publicNetworkAccess: 'Disabled'
      supportsHttpsTrafficOnly: true
      networkAcls: {
        defaultAction: 'Deny'
        bypass: 'AzureServices'
      }
    }

    // Flow-log retention deletes old blobs; soft delete keeps a short window to recover from a mistaken delete.
    resource blobService 'blobServices' = {
      name: 'default'
      properties: {
        deleteRetentionPolicy: {
          enabled: true
          days: softDeleteRetentionDays
        }
        containerDeleteRetentionPolicy: {
          enabled: true
          days: softDeleteRetentionDays
        }
      }
    }
  }

  resource flowLogIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
    name: identityName
    location: location
  }

  // The only permission Network Watcher needs from the identity, scoped to this account alone.
  resource flowLogWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: guid(storageAccount.id, flowLogIdentity.id, storageBlobDataContributorRoleId)
    scope: storageAccount
    properties: {
      principalId: flowLogIdentity.properties.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    }
  }

  output id string = storageAccount.id
  output identityId string = flowLogIdentity.id
  ```

  Create `modules/flowLogs.bicep`:

  ```bicep
  // VNet flow logs with Traffic Analytics. Deployed into NetworkWatcherRG, which holds the subscription's single
  // Network Watcher per region (NetworkWatcher_<region>); the watcher is referenced, never created.
  import { virtualNetworkReference } from 'types.bicep'

  @description('Azure region of the VNets, their Network Watcher and the flow-log storage account.')
  param location string

  @description('VNets to record. Each gets one flow log named <vnet>-flowlog.')
  param virtualNetworks virtualNetworkReference[]

  @description('Flow-log storage account resource ID, in the same region as the VNets.')
  param storageAccountId string

  @description('User-assigned identity resource ID with Storage Blob Data Contributor on the flow-log account.')
  param identityId string

  @description('Central Log Analytics workspace resource ID that receives Traffic Analytics.')
  param logAnalyticsWorkspaceId string

  @description('Days of flow records kept in the storage account.')
  @minValue(1)
  @maxValue(365)
  param retentionDays int = 90

  @description('Traffic Analytics processing interval in minutes.')
  @allowed([
    10
    60
  ])
  param trafficAnalyticsIntervalMinutes int = 10

  resource networkWatcher 'Microsoft.Network/networkWatchers@2024-07-01' existing = {
    name: 'NetworkWatcher_${location}'
  }

  // Traffic Analytics needs the workspace's customer ID and region as well as its resource ID.
  resource workspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' existing = {
    name: last(split(logAnalyticsWorkspaceId, '/'))
    scope: resourceGroup(split(logAnalyticsWorkspaceId, '/')[2], split(logAnalyticsWorkspaceId, '/')[4])
  }

  // Shared key is disabled on the account, so the flow logs write with the user-assigned identity.
  resource flowLogs 'Microsoft.Network/networkWatchers/flowLogs@2024-07-01' = [for vnet in virtualNetworks: {
    parent: networkWatcher
    name: '${vnet.name}-flowlog'
    location: location
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${identityId}': {}
      }
    }
    properties: {
      targetResourceId: vnet.id
      storageId: storageAccountId
      enabled: true
      format: {
        type: 'JSON'
        version: 2
      }
      retentionPolicy: {
        enabled: true
        days: retentionDays
      }
      flowAnalyticsConfiguration: {
        networkWatcherFlowAnalyticsConfiguration: {
          enabled: true
          workspaceResourceId: logAnalyticsWorkspaceId
          workspaceId: workspace.properties.customerId
          workspaceRegion: workspace.location
          trafficAnalyticsInterval: trafficAnalyticsIntervalMinutes
        }
      }
    }
  }]
  ```

- [ ] **Step 4: Wire the stamp and grant the pipeline Network Contributor**

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet, hubPeeringPlan } from 'types.bicep'

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

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  @description('Application secrets written to this region\'s Key Vault, as { name: value } (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  @description('Prod with DR only: routing and Azure Monitor rules for the hub-to-hub peering with the other region. Absent in dev and in prod without DR.')
  param hubPeering hubPeeringPlan?

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
    appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
    flowLogStorageAccount: 'stfl${regionCode}${nameSuffix}'
    flowLogIdentity: 'id-flowlogs-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var monitorPeeringRole = hubPeering.?monitorRole ?? 'None'
  // The region hosting the AMPLS endpoint SNATs the other region's monitoring traffic at its firewall, so the
  // private-endpoint NSG must admit the firewall subnet there (Phase 6).
  var peerTrafficSourceCidrs = monitorPeeringRole == 'Host' ? [
    addressPlan.firewallSubnetPrefix
  ] : []
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
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
      secrets: keyVaultSecrets
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
      remoteSpokeAddressPrefixes: hubPeering.?remoteSpokeAddressPrefixes ?? []
      remoteFirewallPrivateIp: hubPeering.?remoteFirewallPrivateIp ?? ''
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
      monitorPeeringRole: monitorPeeringRole
      monitorClientPrefixes: hubPeering.?monitorClientPrefixes ?? []
      monitorPrivateEndpointPrefixes: hubPeering.?monitorPrivateEndpointPrefixes ?? []
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
      ], peerTrafficSourceCidrs, additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  // One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
  module appInsights 'appInsights.bicep' = {
    name: 'app-insights'
    params: {
      location: location
      componentName: names.appInsights
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
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
      applicationInsightsConnectionString: appInsights.outputs.connectionString
    }
  }

  module appInsightsPublisher 'appInsightsPublisher.bicep' = {
    name: 'app-insights-publisher'
    params: {
      componentName: appInsights.outputs.name
      publisherPrincipalId: appService.outputs.appServicePrincipalId
      publisherAppServiceName: names.appService
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

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
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

  // VNet flow logs with Traffic Analytics (Phase 6): a regional keyless account and the identity that writes to it.
  module flowLogStorage 'flowLogStorage.bicep' = {
    name: 'flow-log-storage'
    params: {
      location: location
      storageAccountName: names.flowLogStorageAccount
      // Zone-redundant in prod; flow logs are regional telemetry, so no geo copy. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? 'Standard_ZRS' : 'Standard_LRS'
      identityName: names.flowLogIdentity
    }
  }

  // Network Watcher lives in NetworkWatcherRG (one per region per subscription), so the flow logs are deployed there.
  module flowLogs 'flowLogs.bicep' = {
    name: 'flow-logs-${environmentName}-${regionCode}'
    scope: resourceGroup('NetworkWatcherRG')
    params: {
      location: location
      virtualNetworks: [
        {
          name: names.hubVnet
          id: hubNetwork.outputs.id
        }
        {
          name: names.spokeVnet
          id: spokeNetwork.outputs.id
        }
      ]
      storageAccountId: flowLogStorage.outputs.id
      identityId: flowLogStorage.outputs.identityId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
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
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  output appInsightsName string = appInsights.outputs.name
  output appInsightsId string = appInsights.outputs.id
  output privateEndpointSubnetId string = spokeNetwork.outputs.privateEndpointSubnetId
  ```

  Replace `scripts/New-GitHubDeploymentIdentity.ps1`:

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
      [string[]]$DelegatableRoleDefinitionIds = @(
          'ba92f5b4-2d11-453d-a403-e96b0029c9fe', # Storage Blob Data Contributor (app identity, container scope)
          '1c0163c0-47e6-4577-8991-ea5c82e286e4', # Virtual Machine Administrator Login (admin group, jump host; Phase 3)
          '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1', # Storage Blob Data Reader (warm-standby app on the primary container; Phase 5)
          '3913510d-42f4-4e42-8a64-420c390055eb'  # Monitoring Metrics Publisher (App Service identity on its App Insights component; Phase 5)
      ),

      [Parameter()]
      [ValidatePattern('^[-\w._()]{1,90}$')]
      [string]$NetworkWatcherResourceGroupName = 'NetworkWatcherRG',

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
  # The deploy workflow's plan job runs in '<env>-plan' (no reviewers) only for the environments listed here;
  # every other environment's plan job runs in the gated '<env>' environment alongside apply, so it gets no
  # ungated '-plan' credential. Fail closed: an environment must be explicitly opted in to get an ungated plan
  # credential. Today only dev is opted in; prod (ADR-012) and any future environment (for example a 'staging')
  # get no '-plan' credential unless deliberately added here.
  $ungatedPlanEnvironments = @('dev')
  $credentialEnvironments = if ($ungatedPlanEnvironments -contains $EnvironmentName) { @($EnvironmentName, "$EnvironmentName-plan") } else { @($EnvironmentName) }

  Write-Host "Application: $DisplayName"
  Write-Host "Federated subjects: $(($credentialEnvironments | ForEach-Object { "repo:${GitHubRepository}:environment:$_" }) -join ', ')"
  Write-Host "Resource group scopes: $($resourceGroupScopes -join ', ')"
  Write-Host "Flow-log scope (Network Contributor): $subscriptionScope/resourceGroups/$NetworkWatcherResourceGroupName"

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

  # 6. VNet flow logs (Phase 6) are child resources of the region's Network Watcher, which Azure keeps in NetworkWatcherRG.
  #    Network Contributor there lets the pipeline manage them; it grants no role-assignment rights.
  Set-RoleAssignment -Role 'Network Contributor' -Scope "$subscriptionScope/resourceGroups/$NetworkWatcherResourceGroupName"

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

- [ ] **Step 5: Build, lint, test, PSRule**

  Run `bicep build main.bicep` and lint every file. The full suite should show `Tests Passed: 464, Failed: 0`. PSRule should show 0 failures out of 1088 rules processed. Every storage rule passes on the new accounts; the dev LRS account is covered by `DefenStack.DevLocallyRedundantStorage`.

- [ ] **Step 6: Commit**

  ```bash
  git add modules/flowLogStorage.bicep modules/flowLogs.bicep modules/regionStamp.bicep main.json scripts/New-GitHubDeploymentIdentity.ps1 tests/FlowLogs.Tests.ps1 tests/RegionStamp.Tests.ps1 tests/Scripts.Tests.ps1
  git commit -m "feat: VNet flow logs with Traffic Analytics through a keyless regional account" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 4: Subscription Activity Log to the workspace and Microsoft Sentinel onboarding

**Files:**
- Create: `modules/activityLog.bicep`, `tests/ActivityLog.Tests.ps1`
- Replace: `modules/monitoring.bicep`, `main.bicep`, `scripts/New-GitHubDeploymentIdentity.ps1`, `tests/Monitoring.Tests.ps1`, `tests/Main.Tests.ps1`, `tests/Scripts.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes:** `global.outputs.logAnalyticsWorkspaceId`; the workspace symbol `logAnalyticsWorkspace` in `monitoring.bicep`; the identity script's `Set-CustomRole` and the subscription role "DefenStack Subscription Deployment Operator" (step 4).
- **Produces:**
  - `activityLog.bicep(settingName, logAnalyticsWorkspaceId)` at `targetScope = 'subscription'`, output `name`; the eight categories Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale and ResourceHealth. `main.bicep` module `activityLog`, deployment `activity-log-<env>`, setting `activity-log-defenstack-<env>`.
  - `monitoring.bicep` resource `sentinelOnboarding` (`onboardingStates` `default`, `scope: logAnalyticsWorkspace`) and output `name`.
  - The subscription role has 12 actions. `Set-CustomRole` reads the role with `az role definition list ... --output json`, compares actions lower-cased and sorted, and runs `az role definition update` only when they differ and `ShouldProcess` allows it.

- [ ] **Step 1: Write the failing tests**

  Create `tests/ActivityLog.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/activityLog.bicep'
      $setting = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
  }

  Describe 'Subscription Activity Log diagnostic setting (Phase 6)' {
      It 'deploys at subscription scope' {
          $template.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $setting | Should -Not -BeNullOrEmpty
      }

      It 'pins 2021-05-01-preview, the only API version with subscription-scope settings (ADR-025)' {
          $setting.apiVersion | Should -Be '2021-05-01-preview'
      }

      It 'sends the Activity Log to the central workspace only' {
          $setting.name | Should -Be "[parameters('settingName')]"
          $setting.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
          $setting.properties.PSObject.Properties.Name | Should -Not -Contain 'storageAccountId'
          $setting.properties.PSObject.Properties.Name | Should -Not -Contain 'eventHubAuthorizationRuleId'
      }

      It 'enables every Activity Log category' {
          $logs = @($setting.properties.logs)
          @($logs | ForEach-Object { $_.category } | Sort-Object) |
              Should -Be @('Administrative', 'Alert', 'Autoscale', 'Policy', 'Recommendation', 'ResourceHealth', 'Security', 'ServiceHealth')
          foreach ($log in $logs) {
              $log.enabled | Should -BeTrue -Because $log.category
          }
      }
  }
  ```

  Replace `tests/Monitoring.Tests.ps1`:

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

  Describe 'Log Analytics resilience (Phase 1)' {
      BeforeAll {
          $workspace = Get-TemplateResource -Template $template -Type 'Microsoft.OperationalInsights/workspaces' | Select-Object -First 1
          $lock = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/locks' | Select-Object -First 1
      }

      It 'replicates the workspace only when a replication region is supplied' {
          $template.parameters.replicationLocation.defaultValue | Should -BeExactly ''
          $workspace.properties.replication.enabled | Should -Be "[not(empty(parameters('replicationLocation')))]"
          $workspace.properties.replication.location | Should -Be "[if(empty(parameters('replicationLocation')), null(), parameters('replicationLocation'))]"
      }

      It 'locks the workspace only when deletion protection is requested' {
          $lock.condition | Should -Be "[parameters('enableDeleteLock')]"
          $lock.properties.level | Should -Be 'CanNotDelete'
      }
  }

  Describe 'Private-only workspace (Phase 6)' {
      BeforeAll {
          $workspace = Get-TemplateResource -Template $template -Type 'Microsoft.OperationalInsights/workspaces' | Select-Object -First 1
      }

      It 'accepts ingestion and queries only through the Azure Monitor Private Link Scope (F10)' {
          $workspace.properties.publicNetworkAccessForIngestion | Should -Be 'Disabled'
          $workspace.properties.publicNetworkAccessForQuery | Should -Be 'Disabled'
      }

      It 'keeps 90-day retention unchanged' {
          $workspace.properties.retentionInDays | Should -Be "[parameters('retentionInDays')]"
      }
  }

  Describe 'Microsoft Sentinel (Phase 6)' {
      BeforeAll {
          $onboarding = Get-TemplateResource -Template $template -Type 'Microsoft.SecurityInsights/onboardingStates' | Select-Object -First 1
      }

      It 'onboards the workspace to Sentinel in every environment' {
          $onboarding | Should -Not -BeNullOrEmpty
          $onboarding.PSObject.Properties.Name | Should -Not -Contain 'condition'
          $onboarding.name | Should -Be 'default'
      }

      It 'is an extension resource on the workspace, not the legacy SecurityInsights solution' {
          $onboarding.scope | Should -Be "[resourceId('Microsoft.OperationalInsights/workspaces', parameters('workspaceName'))]"
          @(Get-TemplateResource -Template $template -Type 'Microsoft.OperationsManagement/solutions').Count | Should -Be 0
      }

      It 'pins the GA API version 2024-03-01' {
          $onboarding.apiVersion | Should -Be '2024-03-01'
      }

      It 'outputs the workspace name for runbook 06' {
          $template.outputs.PSObject.Properties.Name | Should -Contain 'name'
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
      It 'defines the zone names once: three application zones and four Azure Monitor (AMPLS) zones' {
          @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault,monitor,oms,ods,agentsvc'
          $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
          $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
      }

      It 'adds the AMPLS zone <Key> = <Zone> (Phase 6)' -ForEach @(
          @{ Key = 'monitor'; Zone = 'privatelink.monitor.azure.com' }
          @{ Key = 'oms'; Zone = 'privatelink.oms.opinsights.azure.com' }
          @{ Key = 'ods'; Zone = 'privatelink.ods.opinsights.azure.com' }
          @{ Key = 'agentsvc'; Zone = 'privatelink.agentsvc.azure-automation.net' }
      ) {
          $main.variables.privateDnsZoneNames.$Key | Should -BeExactly $Zone
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

      It 'outputs the Front Door profile name and the global resource group name, so the pipeline can poll the origin group (final review A)' {
          foreach ($output in 'frontDoorProfileName', 'globalResourceGroupName') {
              $main.outputs.PSObject.Properties.Name | Should -Contain $output
          }
          $main.outputs.frontDoorProfileName.value | Should -Be "[reference('frontDoor').outputs.profileName.value]"
          $main.outputs.globalResourceGroupName.value | Should -Be "[variables('globalResourceGroupName')]"
      }
  }

  Describe 'Azure Monitor Private Link Scope (Phase 6)' {
      BeforeAll {
          $scope = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateLinkScope'
          $endpoint = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateEndpoint'
      }

      It 'deploys one scope per environment into the global resource group' {
          $scope.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $scope.properties.parameters.scopeName.value | Should -Be "[format('ampls-defenstack-{0}', parameters('environmentName'))]"
      }

      It 'scopes the workspace and the primary App Insights component, plus the secondary component only when deployed' {
          $value = $scope.properties.parameters.scopedResourceIds.value
          $value | Should -Match "^\[concat\(createArray\(reference\('global'\)\.outputs\.logAnalyticsWorkspaceId\.value, reference\('primaryStamp'\)\.outputs\.appInsightsId\.value\)"
          $value | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(reference\('secondaryStamp'\)\.outputs\.appInsightsId\.value\), createArray\(\)\)"
      }

      It 'puts the single azuremonitor endpoint in the primary spoke private-endpoint subnet' {
          $endpoint.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $endpoint.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
          $endpoint.properties.parameters.privateEndpointSubnetId.value | Should -Be "[reference('primaryStamp').outputs.privateEndpointSubnetId.value]"
          $endpoint.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
      }

      It 'creates the endpoint after the scope holds its resources, so the DNS records cover them all' {
          $endpoint.properties.parameters.privateLinkScopeId.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.id.value]"
          @($endpoint.dependsOn) | Should -Contain 'monitorPrivateLinkScope'
      }

      It 'outputs the scope name for runbook 06' {
          $main.outputs.monitorPrivateLinkScopeName.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.name.value]"
      }
  }

  Describe 'Hub-to-hub peering and firewall routing (Phase 6)' {
      BeforeAll {
          $primaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryHubPeering'
          $secondaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryHubPeering'
      }

      It 'peers the hubs both ways only when the secondary region is deployed' {
          foreach ($peering in $primaryPeering, $secondaryPeering) {
              $peering.condition | Should -Be "[parameters('deploySecondaryRegion')]"
          }
          $primaryPeering.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $secondaryPeering.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
      }

      It 'points each hub at the other hub' {
          $primaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('primaryStamp').outputs.hubVnetName.value]"
          $primaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetId.value]"
          $primaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('secondaryRegionCode'))]"
          $secondaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetName.value]"
          $secondaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('primaryStamp').outputs.hubVnetId.value]"
          $secondaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('primaryRegionCode'))]"
      }

      It 'creates the two sides one after the other' {
          @($secondaryPeering.dependsOn) | Should -Contain 'primaryHubPeering'
      }

      It 'makes the primary (AMPLS endpoint) region the Host and the secondary the Client, only with DR' {
          $primary.properties.parameters.hubPeering | Should -Match "^\[if\(parameters\('deploySecondaryRegion'\), createObject\('value', createObject\("
          $primary.properties.parameters.hubPeering | Should -Match "'monitorRole', 'Host'"
          $primary.properties.parameters.hubPeering | Should -Match "createObject\('value', null\(\)\)\)\]$"
          $secondary.properties.parameters.hubPeering.value.monitorRole | Should -Be 'Client'
      }

      It 'routes each region''s firewall to the other firewall at the first usable address of its AzureFirewallSubnet' {
          $primary.properties.parameters.hubPeering | Should -Match "'remoteFirewallPrivateIp', cidrHost\(parameters\('secondaryAddressPlan'\)\.firewallSubnetPrefix, 3\)"
          $primary.properties.parameters.hubPeering | Should -Match "'remoteSpokeAddressPrefixes', parameters\('secondaryAddressPlan'\)\.spokeAddressSpace"
          $secondary.properties.parameters.hubPeering.value.remoteFirewallPrivateIp | Should -Be "[cidrHost(parameters('primaryAddressPlan').firewallSubnetPrefix, 3)]"
          $secondary.properties.parameters.hubPeering.value.remoteSpokeAddressPrefixes | Should -Be "[parameters('primaryAddressPlan').spokeAddressSpace]"
          $secondary.properties.parameters.hubPeering.value.monitorClientPrefixes | Should -Be "[variables('monitorClientPrefixes')]"
          $primary.properties.parameters.hubPeering | Should -Match "'monitorClientPrefixes', variables\('monitorClientPrefixes'\)"
      }

      It 'allows only the East US App Service and management subnets to the primary private-endpoint subnet' {
          $main.variables.monitorClientPrefixes |
              Should -Be "[if(parameters('deploySecondaryRegion'), createArray(parameters('secondaryAddressPlan').appServiceIntegrationSubnetPrefix, parameters('secondaryAddressPlan').managementSubnetPrefix), createArray())]"
          @($main.variables.monitorPrivateEndpointPrefixes) | Should -Be @("[parameters('primaryAddressPlan').privateEndpointSubnetPrefix]")
      }
  }

  Describe 'Subscription Activity Log (Phase 6)' {
      BeforeAll {
          $activityLog = Get-TemplateResourceBySymbol -Template $main -Symbol 'activityLog'
      }

      It 'deploys at subscription scope, not into a resource group' {
          $activityLog.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
          $activityLog.PSObject.Properties.Name | Should -Not -Contain 'condition'
      }

      It 'names the setting per environment, so dev and prod can share one subscription' {
          $activityLog.properties.parameters.settingName.value | Should -Be "[format('activity-log-defenstack-{0}', parameters('environmentName'))]"
          $activityLog.name | Should -Be "[format('activity-log-{0}', parameters('environmentName'))]"
      }

      It 'sends the Activity Log to the shared workspace' {
          $activityLog.properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[reference('global').outputs.logAnalyticsWorkspaceId.value]"
      }
  }
  ```

  Replace `tests/Scripts.Tests.ps1` (the fake `az` now returns the role list as JSON, through `New-RoleListJson`):

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
              if ($joined -like 'role definition update*') {
                  $file = ($args | Where-Object { $_ -like '@*' }) -replace '^@', ''
                  $global:RoleUpdatePayload = Get-Content $file -Raw
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

      # The subscription deployment role's actions from Phase 6: deployments, read-only, and the subscription
      # Activity Log diagnostic setting.
      $deploymentRoleActions = @(
          'Microsoft.Resources/deployments/read',
          'Microsoft.Resources/deployments/write',
          'Microsoft.Resources/deployments/validate/action',
          'Microsoft.Resources/deployments/whatIf/action',
          'Microsoft.Resources/deployments/operations/read',
          'Microsoft.Resources/deployments/operationstatuses/read',
          'Microsoft.Resources/subscriptions/read',
          'Microsoft.Resources/subscriptions/resourceGroups/read',
          'Microsoft.Resources/subscriptions/operationresults/read',
          'Microsoft.Insights/diagnosticSettings/read',
          'Microsoft.Insights/diagnosticSettings/write',
          'Microsoft.Insights/diagnosticSettings/delete'
      )

      # What 'az role definition list --output json' returns for an existing custom role with these actions.
      function New-RoleListJson([string[]]$Actions) {
          ConvertTo-Json -Depth 5 -InputObject @(
              [ordered]@{
                  name             = 'ffffffff-6666-6666-6666-666666666666'
                  roleName         = 'DefenStack Subscription Deployment Operator'
                  roleType         = 'CustomRole'
                  permissions      = @([ordered]@{ actions = $Actions; notActions = @() })
                  assignableScopes = @('/subscriptions/22222222-2222-2222-2222-222222222222')
              }
          )
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

      It 'targets NetworkWatcherRG by default and accepts only a valid resource group name (Phase 6)' {
          $parameter = (Get-Command $scriptPath).Parameters['NetworkWatcherResourceGroupName']
          $parameter | Should -Not -BeNullOrEmpty
          (Get-Content $scriptPath -Raw) | Should -Match '\[string\]\$NetworkWatcherResourceGroupName = ''NetworkWatcherRG'''
          Set-AzShadow (New-BaseResponses)
          try {
              { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -NetworkWatcherResourceGroupName 'bad/name' -WhatIf } |
                  Should -Throw
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
          $responses['*role definition list*'] = New-RoleListJson $deploymentRoleActions
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
              $responses['*role definition list*'] = New-RoleListJson $deploymentRoleActions
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

          It 'assigns Network Contributor on NetworkWatcherRG only, so the pipeline can manage VNet flow logs (Phase 6)' {
              $networkWatcherScope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/NetworkWatcherRG'
              $networkContributor = @($creates | Where-Object { $_ -like '*--role Network Contributor *' })
              $networkContributor.Count | Should -Be 1
              $networkContributor[0] | Should -BeLike "*--scope $networkWatcherScope *"
              @($creates | Where-Object { $_ -like "*--scope $networkWatcherScope *" }).Count | Should -Be 1
          }

          It 'constrains RBAC Administrator with the exact ABAC condition for the delegatable roles (Storage Blob Data Contributor, Virtual Machine Administrator Login, Storage Blob Data Reader, Monitoring Metrics Publisher)' {
              $expected = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 1c0163c0-47e6-4577-8991-ea5c82e286e4, 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1, 3913510d-42f4-4e42-8a64-420c390055eb}))"
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

          It 'grants exactly the 9 deployment-operation and read-only actions plus the 3 diagnostic-setting actions (Phase 6), no wildcard' {
              @($script:roleDefinitionPayload.Actions | Sort-Object) | Should -Be @($deploymentRoleActions | Sort-Object)
              @($script:roleDefinitionPayload.Actions).Count | Should -Be 12
              foreach ($action in $script:roleDefinitionPayload.Actions) {
                  $action | Should -Not -Match '\*' -Because 'every action is named explicitly'
              }
          }

          It 'does not update a role it has just created' {
              @($global:AzCalls | Where-Object { $_ -like 'role definition update*' }).Count | Should -Be 0
          }

          It 'is assignable only at the subscription scope' {
              @($script:roleDefinitionPayload.AssignableScopes) | Should -Be @('/subscriptions/22222222-2222-2222-2222-222222222222')
          }
      }

      Context 'when the subscription deployment role exists with the pre-Phase 6 actions (update path)' {
          BeforeAll {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
              $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
              $responses['*role definition list*'] = New-RoleListJson ($deploymentRoleActions | Where-Object { $_ -notlike 'Microsoft.Insights/*' })
              Set-AzShadow $responses
              $global:RoleUpdatePayload = $null
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $script:updateCalls = @($global:AzCalls | Where-Object { $_ -like 'role definition update*' })
              $script:createCalls = @($global:AzCalls | Where-Object { $_ -like 'role definition create*' })
              $script:roleUpdatePayload = $global:RoleUpdatePayload | ConvertFrom-Json
          }

          It 'updates the existing role once and never re-creates it' {
              $script:updateCalls.Count | Should -Be 1
              $script:createCalls.Count | Should -Be 0
          }

          It 'gives the existing role exactly the Phase 6 action set, including the diagnostic-setting actions' {
              @($script:roleUpdatePayload.Actions | Sort-Object) | Should -Be @($deploymentRoleActions | Sort-Object)
              $script:roleUpdatePayload.Actions | Should -Contain 'Microsoft.Insights/diagnosticSettings/write'
          }

          It 'updates the role by its ID, keeping its name and subscription-only assignable scope' {
              $script:roleUpdatePayload.Id | Should -Be 'ffffffff-6666-6666-6666-666666666666'
              $script:roleUpdatePayload.Name | Should -Be 'DefenStack Subscription Deployment Operator'
              @($script:roleUpdatePayload.AssignableScopes) | Should -Be @('/subscriptions/22222222-2222-2222-2222-222222222222')
          }
      }

      Context 'when the subscription deployment role is already up to date, or under -WhatIf' {
          BeforeAll {
              function New-ExistingRoleResponses([string[]]$Actions) {
                  $responses = New-BaseResponses
                  $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
                  $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
                  $responses['*federated-credential list*github-dev-plan*'] = 'repo:Godson90/bicep:environment:dev-plan'
                  $responses['*federated-credential list*'] = 'repo:Godson90/bicep:environment:dev'
                  $responses['*role definition list*'] = New-RoleListJson $Actions
                  $responses
              }
          }

          It 'does not update a role that already has the expected actions, whatever their order or case' {
              Set-AzShadow (New-ExistingRoleResponses @($deploymentRoleActions | Sort-Object -Descending | ForEach-Object { $_.ToLowerInvariant() }))
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              @($global:AzCalls | Where-Object { $_ -like 'role definition update*' -or $_ -like 'role definition create*' }).Count | Should -Be 0
          }

          It 'makes no role change under -WhatIf when the existing role is out of date' {
              Set-AzShadow (New-ExistingRoleResponses @($deploymentRoleActions | Select-Object -First 9))
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              @($global:AzCalls | Where-Object { $_ -like 'role definition list*--output json*' }).Count | Should -BeGreaterThan 0
              @($global:AzCalls | Where-Object { $_ -like 'role definition update*' -or $_ -like 'role definition create*' }).Count | Should -Be 0
          }

          It 'stops when the existing role cannot be read' {
              $responses = New-ExistingRoleResponses $deploymentRoleActions
              $responses['*role definition list*'] = 'not json'
              Set-AzShadow $responses
              try {
                  { & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false } |
                      Should -Throw -ExpectedMessage "*custom role 'DefenStack Subscription Deployment Operator'*"
              }
              finally {
                  Remove-AzShadow
              }
          }
      }

      Context 'federated credentials for the plan and apply environments (Phase 2)' {
          It 'creates github-<env> and github-<env>-plan with their exact environment subjects' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = New-RoleListJson $deploymentRoleActions
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 2
              ($credentials | Where-Object { $_.name -eq 'github-dev' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev'
              ($credentials | Where-Object { $_.name -eq 'github-dev-plan' }).subject | Should -BeExactly 'repo:Godson90/bicep:environment:dev-plan'
              foreach ($credential in $credentials) {
                  $credential.issuer | Should -BeExactly 'https://token.actions.githubusercontent.com'
                  @($credential.audiences) | Should -Be @('api://AzureADTokenExchange')
              }
          }

          It 'creates only github-staging for an environment not on the ungated-plan allowlist, with no plan credential (Final review D.7, fail closed)' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = New-RoleListJson $deploymentRoleActions
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'staging' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-staging'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:staging'
          }

          It 'creates only github-prod for the prod environment, with no plan credential' {
              $responses = New-BaseResponses
              $responses['*ad app list*'] = 'cccccccc-3333-3333-3333-333333333333'
              $responses['*ad sp list*'] = 'dddddddd-4444-4444-4444-444444444444'
              $responses['*role definition list*'] = New-RoleListJson $deploymentRoleActions
              Set-AzShadow $responses
              try {
                  & $scriptPath -ResourceGroupNames $resourceGroups -GitHubRepository 'Godson90/bicep' -EnvironmentName 'prod' -Confirm:$false | Out-Null
              }
              finally {
                  Remove-AzShadow
              }
              $credentials = @($global:FederatedCredentialPayloads | ForEach-Object { $_ | ConvertFrom-Json })
              $credentials.Count | Should -Be 1
              $credentials[0].name | Should -BeExactly 'github-prod'
              $credentials[0].subject | Should -BeExactly 'repo:Godson90/bicep:environment:prod'
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

  Describe 'Role GUIDs are all delegatable' {
      It 'includes every role-definition GUID used in modules/*.bicep in the default -DelegatableRoleDefinitionIds list' {
          $guidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
          $roleGuids = [System.Collections.Generic.HashSet[string]]::new()
          foreach ($file in Get-ChildItem (Get-RepoPath 'modules') -Filter '*.bicep') {
              $text = Get-Content $file.FullName -Raw
              foreach ($match in [regex]::Matches($text, "subscriptionResourceId\('Microsoft\.Authorization/roleDefinitions',\s*'($guidPattern)'\)")) {
                  [void]$roleGuids.Add($match.Groups[1].Value.ToLowerInvariant())
              }
              foreach ($match in [regex]::Matches($text, "(?:roleDefinitionId|roleId|\w*RoleId)\s*=\s*'($guidPattern)'")) {
                  [void]$roleGuids.Add($match.Groups[1].Value.ToLowerInvariant())
              }
          }

          # The test must not pass vacuously: it has to find at least one GUID to check.
          $roleGuids.Count | Should -BeGreaterThan 0

          # Strip comments first, so a parenthesis inside one (e.g. "(app identity, container scope)")
          # cannot be mistaken for the end of the @(...) array below.
          $scriptTextNoComments = (Get-Content $scriptPath -Raw) -replace '#[^\r\n]*', ''
          $defaultBlock = [regex]::Match($scriptTextNoComments, '\$DelegatableRoleDefinitionIds\s*=\s*@\((.*?)\)', 'Singleline').Groups[1].Value
          $defaultBlock | Should -Not -BeNullOrEmpty

          foreach ($roleGuid in $roleGuids) {
              $defaultBlock | Should -Match ([regex]::Escape($roleGuid))
          }
      }
  }

  AfterAll {
      Remove-Variable -Name AzCalls, FederatedCredentialPayloads, RoleDefinitionPayload, RoleUpdatePayload -Scope Global -ErrorAction SilentlyContinue
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected failures: `bicep build failed for modules/activityLog.bicep`, the `Microsoft Sentinel (Phase 6)` and `Subscription Activity Log (Phase 6)` tests, the 12-action role test, and the update-path contexts.

- [ ] **Step 3: Create the Activity Log module and onboard Sentinel**

  Create `modules/activityLog.bicep`:

  ```bicep
  targetScope = 'subscription'

  @description('Name of the subscription diagnostic setting. Include the environment, since dev and prod may share a subscription.')
  @minLength(1)
  @maxLength(260)
  param settingName string

  @description('Resource ID of the Log Analytics workspace that receives the Activity Log.')
  param logAnalyticsWorkspaceId string

  // The subscription Activity Log feeds Sentinel's Azure Activity data (Phase 6). 2021-05-01-preview is the only API
  // version that supports subscription-scope diagnostic settings (ADR-025). Diagnostic settings write over Azure's
  // internal path, so the workspace's private-only ingestion does not block them. The Activity Log has no category
  // groups, so every category is listed.
  resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    name: settingName
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logs: [
        { category: 'Administrative', enabled: true }
        { category: 'Security', enabled: true }
        { category: 'ServiceHealth', enabled: true }
        { category: 'Alert', enabled: true }
        { category: 'Recommendation', enabled: true }
        { category: 'Policy', enabled: true }
        { category: 'Autoscale', enabled: true }
        { category: 'ResourceHealth', enabled: true }
      ]
    }
  }

  output name string = activityLog.name
  ```

  Replace `modules/monitoring.bicep`:

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

  @description('Region that holds the workspace replica for regional failover. Empty disables replication (sends enabled: false).')
  param replicationLocation string = ''

  @description('Apply a CanNotDelete lock to the workspace.')
  param enableDeleteLock bool = false

  // Central workspace for platform, network, storage, and application diagnostics. Agents and queries reach it
  // only through the Azure Monitor Private Link Scope; diagnostic settings use Azure's internal path (F10, Phase 6).
  resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2026-03-01' = {
    name: workspaceName
    location: location
    properties: {
      retentionInDays: retentionInDays
      publicNetworkAccessForIngestion: 'Disabled'
      publicNetworkAccessForQuery: 'Disabled'
      sku: {
        name: 'PerGB2018'
      }
      replication: {
        enabled: !empty(replicationLocation)
        location: empty(replicationLocation) ? null : replicationLocation
      }
    }
  }

  // Microsoft Sentinel on the central workspace, in every environment (Phase 6). onboardingStates replaces the legacy
  // SecurityInsights solution. Connectors and analytics rules come from Content Hub (runbook 06, ADR-024).
  resource sentinelOnboarding 'Microsoft.SecurityInsights/onboardingStates@2024-03-01' = {
    scope: logAnalyticsWorkspace
    name: 'default'
    properties: {}
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

  @description('Application secrets written to every regional Key Vault, as { name: value }. The pipeline supplies them from the KEYVAULT_SECRETS_JSON environment secret; never put values in a committed parameter file (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

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
    // Azure Monitor Private Link Scope zones (Phase 6); the AMPLS endpoint also registers in the blob zone above.
    monitor: 'privatelink.monitor.azure.com'
    oms: 'privatelink.oms.opinsights.azure.com'
    ods: 'privatelink.ods.opinsights.azure.com'
    agentsvc: 'privatelink.agentsvc.azure-automation.net'
  }

  // Prod with DR (Phase 6): the East US App Service and management subnets may reach the one AMPLS endpoint, in the
  // primary private-endpoint subnet, through both firewalls and the hub-to-hub peering. Nothing else crosses yet (Phase 8).
  var monitorClientPrefixes = deploySecondaryRegion ? [
    secondaryAddressPlan!.appServiceIntegrationSubnetPrefix
    secondaryAddressPlan!.managementSubnetPrefix
  ] : []
  var monitorPrivateEndpointPrefixes = [
    primaryAddressPlan.privateEndpointSubnetPrefix
  ]

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

  // The subscription Activity Log goes to the shared workspace, where Sentinel reads it as Azure Activity (Phase 6).
  module activityLog 'modules/activityLog.bicep' = {
    name: 'activity-log-${environmentName}'
    params: {
      settingName: 'activity-log-defenstack-${environmentName}'
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
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
      keyVaultSecrets: keyVaultSecrets
      // A firewall always takes the first usable address (.4) of its AzureFirewallSubnet (see regionStamp.bicep).
      hubPeering: deploySecondaryRegion ? {
        remoteFirewallPrivateIp: cidrHost(secondaryAddressPlan!.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: secondaryAddressPlan!.spokeAddressSpace
        monitorRole: 'Host'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      } : null
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
      primaryStorageAccountId: isProd ? primaryStamp.outputs.storageAccountId : ''
      primaryStorageAccountName: isProd ? primaryStamp.outputs.storageAccountName : ''
      keyVaultSecrets: keyVaultSecrets
      hubPeering: {
        remoteFirewallPrivateIp: cidrHost(primaryAddressPlan.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: primaryAddressPlan.spokeAddressSpace
        monitorRole: 'Client'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      }
    }
  }

  // Hub-to-hub global peering, both ways, once both hubs exist (brought forward from Phase 8). The sides are created
  // one after the other, since each peering operation updates both VNets.
  module primaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${primaryRegionCode}-to-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      localVnetName: primaryStamp.outputs.hubVnetName
      remoteVnetId: secondaryStamp!.outputs.hubVnetId
      peeringName: 'hub-to-${secondaryRegionCode}-hub'
    }
  }

  module secondaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${secondaryRegionCode}-to-${primaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      localVnetName: secondaryStamp!.outputs.hubVnetName
      remoteVnetId: primaryStamp.outputs.hubVnetId
      peeringName: 'hub-to-${primaryRegionCode}-hub'
    }
    dependsOn: [
      primaryHubPeering
    ]
  }

  // The warm-standby App Service may read (never write) the primary application container (ADR-020).
  module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion && isProd) {
    name: 'storage-reader-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      storageAccountName: primaryStamp.outputs.storageAccountName
      storageContainerName: primaryStamp.outputs.storageContainerName
      readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
      readerAppServiceName: secondaryStamp!.outputs.appServiceName
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

  // Private-only monitoring (Phase 6): one scope holds the workspace and every regional App Insights component.
  module monitorPrivateLinkScope 'modules/monitorPrivateLinkScope.bicep' = {
    name: 'monitor-private-link-scope-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      scopeName: 'ampls-defenstack-${environmentName}'
      scopedResourceIds: concat([
        global.outputs.logAnalyticsWorkspaceId
        primaryStamp.outputs.appInsightsId
      ], deploySecondaryRegion ? [
        secondaryStamp!.outputs.appInsightsId
      ] : [])
    }
  }

  // The single azuremonitor endpoint, in the primary spoke, created once the scope holds every resource.
  module monitorPrivateEndpoint 'modules/monitorPrivateEndpoint.bicep' = {
    name: 'monitor-private-endpoint-${environmentName}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      location: primaryLocation
      privateLinkScopeId: monitorPrivateLinkScope.outputs.id
      privateLinkScopeName: monitorPrivateLinkScope.outputs.name
      privateEndpointSubnetId: primaryStamp.outputs.privateEndpointSubnetId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
    }
  }

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output frontDoorProfileName string = frontDoor.outputs.profileName
  output globalResourceGroupName string = globalResourceGroupName
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
  output monitorPrivateLinkScopeName string = monitorPrivateLinkScope.outputs.name
  ```

- [ ] **Step 4: Extend and update the subscription custom role**

  Replace `scripts/New-GitHubDeploymentIdentity.ps1`:

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
      [string[]]$DelegatableRoleDefinitionIds = @(
          'ba92f5b4-2d11-453d-a403-e96b0029c9fe', # Storage Blob Data Contributor (app identity, container scope)
          '1c0163c0-47e6-4577-8991-ea5c82e286e4', # Virtual Machine Administrator Login (admin group, jump host; Phase 3)
          '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1', # Storage Blob Data Reader (warm-standby app on the primary container; Phase 5)
          '3913510d-42f4-4e42-8a64-420c390055eb'  # Monitoring Metrics Publisher (App Service identity on its App Insights component; Phase 5)
      ),

      [Parameter()]
      [ValidatePattern('^[-\w._()]{1,90}$')]
      [string]$NetworkWatcherResourceGroupName = 'NetworkWatcherRG',

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
  # The deploy workflow's plan job runs in '<env>-plan' (no reviewers) only for the environments listed here;
  # every other environment's plan job runs in the gated '<env>' environment alongside apply, so it gets no
  # ungated '-plan' credential. Fail closed: an environment must be explicitly opted in to get an ungated plan
  # credential. Today only dev is opted in; prod (ADR-012) and any future environment (for example a 'staging')
  # get no '-plan' credential unless deliberately added here.
  $ungatedPlanEnvironments = @('dev')
  $credentialEnvironments = if ($ungatedPlanEnvironments -contains $EnvironmentName) { @($EnvironmentName, "$EnvironmentName-plan") } else { @($EnvironmentName) }

  Write-Host "Application: $DisplayName"
  Write-Host "Federated subjects: $(($credentialEnvironments | ForEach-Object { "repo:${GitHubRepository}:environment:$_" }) -join ', ')"
  Write-Host "Resource group scopes: $($resourceGroupScopes -join ', ')"
  Write-Host "Flow-log scope (Network Contributor): $subscriptionScope/resourceGroups/$NetworkWatcherResourceGroupName"

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

      $existingRoleJson = (az role definition list --name $Name --custom-role-only true --output json) -join "`n"
      if ($LASTEXITCODE -ne 0) { throw "Failed to query the custom role '$Name'." }
      $existingRole = $null
      if (-not [string]::IsNullOrWhiteSpace($existingRoleJson)) {
          try {
              $parsedRoles = $existingRoleJson | ConvertFrom-Json
          }
          catch {
              throw "Could not read the custom role '$Name' returned by az role definition list: $($_.Exception.Message)"
          }
          # Windows PowerShell returns a JSON array as one object; @(...)[0] works on both shells.
          if ($parsedRoles) { $existingRole = @($parsedRoles)[0] }
      }

      if ($existingRole) {
          # Idempotent update: a role created by an earlier phase gains new actions (Phase 6 adds the subscription
          # diagnostic-setting actions). Actions are case-insensitive, so compare them lower-cased and sorted.
          $currentActions = @($existingRole.permissions | ForEach-Object { $_.actions } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
          $desiredActions = @($Actions | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
          if (($currentActions -join "`n") -eq ($desiredActions -join "`n")) {
              Write-Host "Custom role '$Name' already has the expected actions."
              return
          }

          if ($PSCmdlet.ShouldProcess($Name, 'Update custom role actions')) {
              $roleFile = New-TemporaryFile
              try {
                  @{
                      Id               = $existingRole.name
                      Name             = $Name
                      IsCustom         = $true
                      Description      = $Description
                      Actions          = $Actions
                      NotActions       = @()
                      AssignableScopes = @($subscriptionScope)
                  } | ConvertTo-Json | Set-Content -Path $roleFile -Encoding ASCII

                  az role definition update --role-definition "@$roleFile" --output none
                  if ($LASTEXITCODE -ne 0) { throw "Failed to update the custom role '$Name'." }
              }
              finally {
                  Remove-Item $roleFile -Force
              }
          }
          return
      }

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
  #    while every resource lands in a pre-created resource group granted below. The one subscription resource is
  #    the Activity Log diagnostic setting (Phase 6). An existing role is updated in place when its actions differ.
  $deploymentRoleName = 'DefenStack Subscription Deployment Operator'
  Set-CustomRole -Name $deploymentRoleName -Description 'Run subscription-scope ARM deployments (validate, what-if, create), read resource groups, and manage the subscription Activity Log diagnostic setting. Grants no other resource permissions and cannot cancel or delete deployments.' -Actions @(
      'Microsoft.Resources/deployments/read',
      'Microsoft.Resources/deployments/write',
      'Microsoft.Resources/deployments/validate/action',
      'Microsoft.Resources/deployments/whatIf/action',
      'Microsoft.Resources/deployments/operations/read',
      'Microsoft.Resources/deployments/operationstatuses/read',
      'Microsoft.Resources/subscriptions/read',
      'Microsoft.Resources/subscriptions/resourceGroups/read',
      'Microsoft.Resources/subscriptions/operationresults/read',
      'Microsoft.Insights/diagnosticSettings/read',
      'Microsoft.Insights/diagnosticSettings/write',
      'Microsoft.Insights/diagnosticSettings/delete'
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

  # 6. VNet flow logs (Phase 6) are child resources of the region's Network Watcher, which Azure keeps in NetworkWatcherRG.
  #    Network Contributor there lets the pipeline manage them; it grants no role-assignment rights.
  Set-RoleAssignment -Role 'Network Contributor' -Scope "$subscriptionScope/resourceGroups/$NetworkWatcherResourceGroupName"

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

- [ ] **Step 5: Build, lint, test, PSRule**

  Run `bicep build main.bicep` and lint every file. The full suite should show `Tests Passed: 483, Failed: 0`. PSRule should show 0 failures out of 1104 rules processed. PSRule prints "no matching rules" for the subscription setting; that is expected.

- [ ] **Step 6: Commit**

  ```bash
  git add modules/activityLog.bicep modules/monitoring.bicep main.bicep main.json scripts/New-GitHubDeploymentIdentity.ps1 tests/ActivityLog.Tests.ps1 tests/Monitoring.Tests.ps1 tests/Main.Tests.ps1 tests/Scripts.Tests.ps1
  git commit -m "feat: subscription Activity Log to the workspace and Microsoft Sentinel onboarding" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 5: Action group and platform metric, Front Door and Service Health alerts

**Files:**
- Create: `modules/actionGroup.bicep`, `modules/metricAlerts.bicep`, `modules/serviceHealthAlert.bicep`, `tests/Alerts.Tests.ps1`
- Replace: `modules/types.bicep`, `modules/frontDoor.bicep`, `modules/regionStamp.bicep`, `main.bicep`, `.github/workflows/deploy.yml`, `.github/workflows/bicep-ci.yml`, `tests/FrontDoor.Tests.ps1`, `tests/RegionStamp.Tests.ps1`, `tests/Main.Tests.ps1`, `tests/Workflows.Tests.ps1`
- Modify: `main.json` (regenerate)

**Interfaces:**
- **Consumes:** stamp module outputs `azureFirewall.outputs.id`, `appService.outputs.appServiceAppId`, `keyVault.outputs.id` and `vpnGateway.outputs.id` (only when `deployAdminAccess`); `frontDoor` in `main.bicep`; the workflow steps Validate, What-if and Deploy, and the PR what-if in `bicep-ci.yml`.
- **Produces:**
  - Exported types `metricAlertDimension`, `metricAlertRule` (with `threshold: string`, converted with `json()`, and optional `dimensions` and `deploy`) and `alertThresholdSet` (`appServiceHttp5xx`, `keyVaultForbidden`, `vpnP2sConnections`, `frontDoorWafBlocks`).
  - `actionGroup.bicep(actionGroupName, shortName, alertEmail = '')`, outputs `id` and `name`: `ag-defenstack-<env>`, short name `ds-<env>-ops`, receiver `platform-operators`.
  - `metricAlerts.bicep(namePrefix, rules, actionGroupId)`; `serviceHealthAlert.bicep(alertName, regions, actionGroupId)`, output `name`.
  - `frontDoor.bicep` output `id`.
  - `main.bicep` params `alertEmail = ''` and `alertThresholds` (10 / 10 / 20 / 100); variable `regionDisplayNames`; modules `actionGroup`, `globalMetricAlerts` (`front-door-origin-health`, `front-door-waf-blocks`) and `serviceHealthAlert` (`alert-defenstack-<env>-service-health`).
  - Stamp params `actionGroupId` and `alertThresholds`; module `metric-alerts` with prefix `alert-defenstack-<env>-<regionCode>` and the seven rules `firewall-health`, `firewall-snat-ports`, `app-http-5xx`, `app-health-check`, `key-vault-availability`, `key-vault-forbidden` and `vpn-p2s-connections`.
  - Workflow step `Require ALERT_EMAIL for prod`, and `--parameters alertEmail="$ALERT_EMAIL"` on validate, what-if, create and the PR what-if.

- [ ] **Step 1: Write the failing tests**

  Create `tests/Alerts.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $actionGroupTemplate = Get-BicepTemplate -RelativePath 'modules/actionGroup.bicep'
      $actionGroup = Get-TemplateResource -Template $actionGroupTemplate -Type 'Microsoft.Insights/actionGroups' | Select-Object -First 1
      $metricAlertsTemplate = Get-BicepTemplate -RelativePath 'modules/metricAlerts.bicep'
      $metricAlert = Get-TemplateResource -Template $metricAlertsTemplate -Type 'Microsoft.Insights/metricAlerts' | Select-Object -First 1
      $serviceHealthTemplate = Get-BicepTemplate -RelativePath 'modules/serviceHealthAlert.bicep'
      $serviceHealth = Get-TemplateResource -Template $serviceHealthTemplate -Type 'Microsoft.Insights/activityLogAlerts' | Select-Object -First 1
  }

  Describe 'Action group (Phase 6)' {
      It 'is a global resource on the GA API version 2023-01-01' {
          $actionGroup.location | Should -Be 'Global'
          $actionGroup.apiVersion | Should -Be '2023-01-01'
          $actionGroup.properties.enabled | Should -BeTrue
      }

      It 'limits the short name to the 12 characters Azure allows' {
          $actionGroupTemplate.parameters.shortName.maxLength | Should -Be 12
          $actionGroup.properties.groupShortName | Should -Be "[parameters('shortName')]"
      }

      It 'emails ALERT_EMAIL with the common alert schema, and adds no receiver when it is empty' {
          $actionGroupTemplate.parameters.alertEmail.defaultValue | Should -BeExactly ''
          $actionGroup.properties.emailReceivers |
              Should -Be "[if(empty(parameters('alertEmail')), createArray(), createArray(createObject('name', 'platform-operators', 'emailAddress', parameters('alertEmail'), 'useCommonAlertSchema', true())))]"
      }

      It 'outputs its ID for the alert rules' {
          $actionGroupTemplate.outputs.id.value | Should -Match "Microsoft\.Insights/actionGroups"
      }
  }

  Describe 'Metric alerts module (Phase 6)' {
      It 'pins metricAlerts 2018-03-01, the last clearly GA version' {
          $metricAlert.apiVersion | Should -Be '2018-03-01'
          $metricAlert.location | Should -Be 'global'
      }

      It 'creates one alert per rule, skipping rules marked deploy = false' {
          $metricAlert.copy.count | Should -Be "[length(parameters('rules'))]"
          $metricAlert.condition | Should -Be "[coalesce(tryGet(parameters('rules')[copyIndex()], 'deploy'), true())]"
          $metricAlert.name | Should -Be "[format('{0}-{1}', parameters('namePrefix'), parameters('rules')[copyIndex()].name)]"
      }

      It 'watches one resource with a static threshold, every 5 minutes over 15 minutes, and resolves itself' {
          @($metricAlert.properties.scopes) | Should -Be @("[parameters('rules')[copyIndex()].resourceId]")
          $metricAlert.properties.evaluationFrequency | Should -Be 'PT5M'
          $metricAlert.properties.windowSize | Should -Be 'PT15M'
          $metricAlert.properties.autoMitigate | Should -BeTrue
          $metricAlert.properties.enabled | Should -BeTrue
          $metricAlert.properties.criteria.'odata.type' | Should -Be 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
          $metricAlert.properties.criteria.allOf[0].criterionType | Should -Be 'StaticThresholdCriterion'
      }

      It 'converts the text threshold to a number, so decimals such as 99.9 work' {
          $metricAlert.properties.criteria.allOf[0].threshold | Should -Be "[json(parameters('rules')[copyIndex()].threshold)]"
      }

      It 'applies the rule dimensions, or none' {
          $metricAlert.properties.criteria.allOf[0].dimensions | Should -Be "[coalesce(tryGet(parameters('rules')[copyIndex()], 'dimensions'), createArray())]"
      }

      It 'notifies the action group' {
          $metricAlert.properties.actions[0].actionGroupId | Should -Be "[parameters('actionGroupId')]"
      }
  }

  Describe 'Service Health alert (Phase 6)' {
      It 'is a global activity log alert on the GA API version 2020-10-01' {
          $serviceHealth.location | Should -Be 'Global'
          $serviceHealth.apiVersion | Should -Be '2020-10-01'
          $serviceHealth.properties.enabled | Should -BeTrue
      }

      It 'watches the whole subscription' {
          @($serviceHealth.properties.scopes) | Should -Be @('[subscription().id]')
      }

      It 'fires on Service Health events in the platform regions only' {
          $conditions = @($serviceHealth.properties.condition.allOf)
          ($conditions | Where-Object { $_.field -eq 'category' }).equals | Should -Be 'ServiceHealth'
          $regionCondition = ($conditions | Where-Object { $_.PSObject.Properties.Name -contains 'anyOf' }).anyOf[0]
          $regionCondition.field | Should -Be 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
          $regionCondition.containsAny | Should -Be "[parameters('regions')]"
      }

      It 'notifies the action group' {
          $serviceHealth.properties.actions.actionGroups[0].actionGroupId | Should -Be "[parameters('actionGroupId')]"
      }
  }
  ```

  Replace `tests/FrontDoor.Tests.ps1`:

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

  Describe 'Front Door alert target (Phase 6)' {
      It 'outputs the profile resource ID for the Front Door metric alerts' {
          $template.outputs.id.value | Should -Be "[resourceId('Microsoft.Cdn/profiles', parameters('profileName'))]"
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

      It 'uses RA-GZRS in the prod primary region, GRS in the warm standby and LRS in dev (Phase 5)' {
          (Get-StampModuleParameters 'storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), if(variables('isPrimary'), createObject('value', 'Standard_RAGZRS'), createObject('value', 'Standard_GRS')), createObject('value', 'Standard_LRS'))]"
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

      It 'outputs the private-endpoint subnet that hosts the AMPLS endpoint in the primary region (Phase 6)' {
          $stamp.outputs.privateEndpointSubnetId.value | Should -Be "[reference('spokeNetwork').outputs.privateEndpointSubnetId.value]"
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

  Describe 'Region stamp hub peering (Phase 6)' {
      It 'takes an optional hub peering plan, absent by default (dev, or prod without DR)' {
          $stamp.parameters.hubPeering.nullable | Should -BeExactly $true
          $stamp.parameters.hubPeering.'$ref' | Should -Be '#/definitions/hubPeeringPlan'
      }

      It 'routes the other region''s spoke from AzureFirewallSubnet to the other firewall' {
          $hub = Get-StampModuleParameters 'hub-network'
          $hub.remoteSpokeAddressPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteSpokeAddressPrefixes'\)"
          $hub.remoteFirewallPrivateIp.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'remoteFirewallPrivateIp'\)"
      }

      It 'passes the Azure Monitor role and prefixes to the firewall rules' {
          $firewall = Get-StampModuleParameters 'azure-firewall'
          $firewall.monitorPeeringRole.value | Should -Be "[variables('monitorPeeringRole')]"
          $firewall.monitorClientPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorClientPrefixes'\)"
          $firewall.monitorPrivateEndpointPrefixes.value | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorPrivateEndpointPrefixes'\)"
          $stamp.variables.monitorPeeringRole | Should -Match "tryGet\(parameters\('hubPeering'\), 'monitorRole'\), 'None'\)"
      }

      It 'lets the local firewall reach the private endpoints only in the region that hosts the AMPLS endpoint (it SNATs peer traffic)' {
          $stamp.variables.peerTrafficSourceCidrs |
              Should -Be "[if(equals(variables('monitorPeeringRole'), 'Host'), createArray(parameters('addressPlan').firewallSubnetPrefix), createArray())]"
          (Get-StampModuleParameters 'spoke-network').approvedPrivateEndpointSourceCidrs.value | Should -Match "variables\('peerTrafficSourceCidrs'\)"
      }
  }

  Describe 'Region stamp flow logs (Phase 6)' {
      BeforeAll {
          $flowLogs = Get-ModuleDeployment -Template $stamp -Name "[format('flow-logs-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
      }

      It 'names the flow-log account and identity per environment and region' {
          $stamp.variables.names.flowLogStorageAccount | Should -Be "[format('stfl{0}{1}', parameters('regionCode'), variables('nameSuffix'))]"
          $stamp.variables.names.flowLogIdentity | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)"
      }

      It 'keeps flow logs zone-redundant in prod and locally redundant in dev' {
          (Get-StampModuleParameters 'flow-log-storage').storageAccountSkuName |
              Should -Be "[if(variables('isProd'), createObject('value', 'Standard_ZRS'), createObject('value', 'Standard_LRS'))]"
      }

      It 'deploys the flow logs into NetworkWatcherRG, where the region''s Network Watcher lives' {
          $flowLogs.resourceGroup | Should -Be 'NetworkWatcherRG'
          $flowLogs.properties.parameters.location.value | Should -Be "[parameters('location')]"
      }

      It 'logs both the hub and the spoke VNet' {
          $value = @($flowLogs.properties.parameters.virtualNetworks.value)
          $value[0].name | Should -Be "[variables('names').hubVnet]"
          $value[0].id | Should -Be "[reference('hubNetwork').outputs.id.value]"
          $value[1].name | Should -Be "[variables('names').spokeVnet]"
          $value[1].id | Should -Be "[reference('spokeNetwork').outputs.id.value]"
      }

      It 'writes with the flow-log identity to the flow-log account and analyses into the central workspace' {
          $parameters = $flowLogs.properties.parameters
          $parameters.storageAccountId.value | Should -Be "[reference('flowLogStorage').outputs.id.value]"
          $parameters.identityId.value | Should -Be "[reference('flowLogStorage').outputs.identityId.value]"
          $parameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
      }
  }

  Describe 'Region stamp alerts (Phase 6)' {
      BeforeAll {
          $alertParameters = Get-StampModuleParameters 'metric-alerts'
          $rules = @($alertParameters.rules.value)
      }

      It 'names the alerts per environment and region and notifies the shared action group' {
          $alertParameters.namePrefix.value | Should -Be "[format('alert-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
          $alertParameters.actionGroupId.value | Should -Be "[parameters('actionGroupId')]"
          $stamp.parameters.PSObject.Properties.Name | Should -Contain 'alertThresholds'
      }

      It 'defines exactly the seven regional rules' {
          @($rules | ForEach-Object { $_.name }) -join ',' |
              Should -Be 'firewall-health,firewall-snat-ports,app-http-5xx,app-health-check,key-vault-availability,key-vault-forbidden,vpn-p2s-connections'
      }

      It 'alerts on <Metric> <Operator> <Threshold> (<Aggregation>) at Sev<Severity> as <Name>' -ForEach @(
          @{ Name = 'firewall-health'; Metric = 'FirewallHealth'; Namespace = 'Microsoft.Network/azureFirewalls'; Operator = 'LessThan'; Threshold = '90'; Aggregation = 'Average'; Severity = 1; Resource = "[reference('azureFirewall').outputs.id.value]" }
          @{ Name = 'firewall-snat-ports'; Metric = 'SNATPortUtilization'; Namespace = 'Microsoft.Network/azureFirewalls'; Operator = 'GreaterThan'; Threshold = '80'; Aggregation = 'Maximum'; Severity = 2; Resource = "[reference('azureFirewall').outputs.id.value]" }
          @{ Name = 'app-http-5xx'; Metric = 'Http5xx'; Namespace = 'Microsoft.Web/sites'; Operator = 'GreaterThan'; Threshold = "[string(parameters('alertThresholds').appServiceHttp5xx)]"; Aggregation = 'Total'; Severity = 2; Resource = "[reference('appService').outputs.appServiceAppId.value]" }
          @{ Name = 'app-health-check'; Metric = 'HealthCheckStatus'; Namespace = 'Microsoft.Web/sites'; Operator = 'LessThan'; Threshold = '100'; Aggregation = 'Average'; Severity = 1; Resource = "[reference('appService').outputs.appServiceAppId.value]" }
          @{ Name = 'key-vault-availability'; Metric = 'Availability'; Namespace = 'Microsoft.KeyVault/vaults'; Operator = 'LessThan'; Threshold = '99.9'; Aggregation = 'Average'; Severity = 2; Resource = "[reference('keyVault').outputs.id.value]" }
          @{ Name = 'key-vault-forbidden'; Metric = 'ServiceApiResult'; Namespace = 'Microsoft.KeyVault/vaults'; Operator = 'GreaterThan'; Threshold = "[string(parameters('alertThresholds').keyVaultForbidden)]"; Aggregation = 'Count'; Severity = 3; Resource = "[reference('keyVault').outputs.id.value]" }
          @{ Name = 'vpn-p2s-connections'; Metric = 'P2SConnectionCount'; Namespace = 'Microsoft.Network/virtualNetworkGateways'; Operator = 'GreaterThan'; Threshold = "[string(parameters('alertThresholds').vpnP2sConnections)]"; Aggregation = 'Maximum'; Severity = 3; Resource = "[if(parameters('deployAdminAccess'), reference('vpnGateway').outputs.id.value, '')]" }
      ) {
          $rule = $rules | Where-Object { $_.name -eq $Name }
          $rule | Should -Not -BeNullOrEmpty
          $rule.metricName | Should -BeExactly $Metric
          $rule.metricNamespace | Should -BeExactly $Namespace
          $rule.operator | Should -Be $Operator
          $rule.threshold | Should -Be $Threshold
          $rule.timeAggregation | Should -Be $Aggregation
          $rule.severity | Should -Be $Severity
          $rule.resourceId | Should -Be $Resource
          $rule.description | Should -Not -BeNullOrEmpty
      }

      It 'counts only Key Vault results with status code 403' {
          $rule = $rules | Where-Object { $_.name -eq 'key-vault-forbidden' }
          @($rule.dimensions).Count | Should -Be 1
          $rule.dimensions[0].name | Should -Be 'StatusCode'
          $rule.dimensions[0].operator | Should -Be 'Include'
          @($rule.dimensions[0].values) | Should -Be @('403')
      }

      It 'creates the VPN alert only where the gateway exists' {
          ($rules | Where-Object { $_.name -eq 'vpn-p2s-connections' }).deploy | Should -Be "[parameters('deployAdminAccess')]"
          foreach ($rule in $rules | Where-Object { $_.name -ne 'vpn-p2s-connections' }) {
              $rule.PSObject.Properties.Name | Should -Not -Contain 'deploy' -Because $rule.name
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
      It 'defines the zone names once: three application zones and four Azure Monitor (AMPLS) zones' {
          @($main.variables.privateDnsZoneNames.PSObject.Properties.Name) -join ',' | Should -Be 'blob,sites,vault,monitor,oms,ods,agentsvc'
          $main.variables.privateDnsZoneNames.sites | Should -Be 'privatelink.azurewebsites.net'
          $main.variables.privateDnsZoneNames.vault | Should -Be 'privatelink.vaultcore.azure.net'
      }

      It 'adds the AMPLS zone <Key> = <Zone> (Phase 6)' -ForEach @(
          @{ Key = 'monitor'; Zone = 'privatelink.monitor.azure.com' }
          @{ Key = 'oms'; Zone = 'privatelink.oms.opinsights.azure.com' }
          @{ Key = 'ods'; Zone = 'privatelink.ods.opinsights.azure.com' }
          @{ Key = 'agentsvc'; Zone = 'privatelink.agentsvc.azure-automation.net' }
      ) {
          $main.variables.privateDnsZoneNames.$Key | Should -BeExactly $Zone
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

      It 'outputs the Front Door profile name and the global resource group name, so the pipeline can poll the origin group (final review A)' {
          foreach ($output in 'frontDoorProfileName', 'globalResourceGroupName') {
              $main.outputs.PSObject.Properties.Name | Should -Contain $output
          }
          $main.outputs.frontDoorProfileName.value | Should -Be "[reference('frontDoor').outputs.profileName.value]"
          $main.outputs.globalResourceGroupName.value | Should -Be "[variables('globalResourceGroupName')]"
      }
  }

  Describe 'Azure Monitor Private Link Scope (Phase 6)' {
      BeforeAll {
          $scope = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateLinkScope'
          $endpoint = Get-TemplateResourceBySymbol -Template $main -Symbol 'monitorPrivateEndpoint'
      }

      It 'deploys one scope per environment into the global resource group' {
          $scope.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $scope.properties.parameters.scopeName.value | Should -Be "[format('ampls-defenstack-{0}', parameters('environmentName'))]"
      }

      It 'scopes the workspace and the primary App Insights component, plus the secondary component only when deployed' {
          $value = $scope.properties.parameters.scopedResourceIds.value
          $value | Should -Match "^\[concat\(createArray\(reference\('global'\)\.outputs\.logAnalyticsWorkspaceId\.value, reference\('primaryStamp'\)\.outputs\.appInsightsId\.value\)"
          $value | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(reference\('secondaryStamp'\)\.outputs\.appInsightsId\.value\), createArray\(\)\)"
      }

      It 'puts the single azuremonitor endpoint in the primary spoke private-endpoint subnet' {
          $endpoint.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $endpoint.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
          $endpoint.properties.parameters.privateEndpointSubnetId.value | Should -Be "[reference('primaryStamp').outputs.privateEndpointSubnetId.value]"
          $endpoint.properties.parameters.privateDnsZoneIds.value | Should -Be "[reference('global').outputs.privateDnsZoneIds.value]"
      }

      It 'creates the endpoint after the scope holds its resources, so the DNS records cover them all' {
          $endpoint.properties.parameters.privateLinkScopeId.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.id.value]"
          @($endpoint.dependsOn) | Should -Contain 'monitorPrivateLinkScope'
      }

      It 'outputs the scope name for runbook 06' {
          $main.outputs.monitorPrivateLinkScopeName.value | Should -Be "[reference('monitorPrivateLinkScope').outputs.name.value]"
      }
  }

  Describe 'Hub-to-hub peering and firewall routing (Phase 6)' {
      BeforeAll {
          $primaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryHubPeering'
          $secondaryPeering = Get-TemplateResourceBySymbol -Template $main -Symbol 'secondaryHubPeering'
      }

      It 'peers the hubs both ways only when the secondary region is deployed' {
          foreach ($peering in $primaryPeering, $secondaryPeering) {
              $peering.condition | Should -Be "[parameters('deploySecondaryRegion')]"
          }
          $primaryPeering.resourceGroup | Should -Be "[variables('primaryResourceGroupName')]"
          $secondaryPeering.resourceGroup | Should -Be "[variables('secondaryResourceGroupName')]"
      }

      It 'points each hub at the other hub' {
          $primaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('primaryStamp').outputs.hubVnetName.value]"
          $primaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetId.value]"
          $primaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('secondaryRegionCode'))]"
          $secondaryPeering.properties.parameters.localVnetName.value | Should -Be "[reference('secondaryStamp').outputs.hubVnetName.value]"
          $secondaryPeering.properties.parameters.remoteVnetId.value | Should -Be "[reference('primaryStamp').outputs.hubVnetId.value]"
          $secondaryPeering.properties.parameters.peeringName.value | Should -Be "[format('hub-to-{0}-hub', variables('primaryRegionCode'))]"
      }

      It 'creates the two sides one after the other' {
          @($secondaryPeering.dependsOn) | Should -Contain 'primaryHubPeering'
      }

      It 'makes the primary (AMPLS endpoint) region the Host and the secondary the Client, only with DR' {
          $primary.properties.parameters.hubPeering | Should -Match "^\[if\(parameters\('deploySecondaryRegion'\), createObject\('value', createObject\("
          $primary.properties.parameters.hubPeering | Should -Match "'monitorRole', 'Host'"
          $primary.properties.parameters.hubPeering | Should -Match "createObject\('value', null\(\)\)\)\]$"
          $secondary.properties.parameters.hubPeering.value.monitorRole | Should -Be 'Client'
      }

      It 'routes each region''s firewall to the other firewall at the first usable address of its AzureFirewallSubnet' {
          $primary.properties.parameters.hubPeering | Should -Match "'remoteFirewallPrivateIp', cidrHost\(parameters\('secondaryAddressPlan'\)\.firewallSubnetPrefix, 3\)"
          $primary.properties.parameters.hubPeering | Should -Match "'remoteSpokeAddressPrefixes', parameters\('secondaryAddressPlan'\)\.spokeAddressSpace"
          $secondary.properties.parameters.hubPeering.value.remoteFirewallPrivateIp | Should -Be "[cidrHost(parameters('primaryAddressPlan').firewallSubnetPrefix, 3)]"
          $secondary.properties.parameters.hubPeering.value.remoteSpokeAddressPrefixes | Should -Be "[parameters('primaryAddressPlan').spokeAddressSpace]"
          $secondary.properties.parameters.hubPeering.value.monitorClientPrefixes | Should -Be "[variables('monitorClientPrefixes')]"
          $primary.properties.parameters.hubPeering | Should -Match "'monitorClientPrefixes', variables\('monitorClientPrefixes'\)"
      }

      It 'allows only the East US App Service and management subnets to the primary private-endpoint subnet' {
          $main.variables.monitorClientPrefixes |
              Should -Be "[if(parameters('deploySecondaryRegion'), createArray(parameters('secondaryAddressPlan').appServiceIntegrationSubnetPrefix, parameters('secondaryAddressPlan').managementSubnetPrefix), createArray())]"
          @($main.variables.monitorPrivateEndpointPrefixes) | Should -Be @("[parameters('primaryAddressPlan').privateEndpointSubnetPrefix]")
      }
  }

  Describe 'Subscription Activity Log (Phase 6)' {
      BeforeAll {
          $activityLog = Get-TemplateResourceBySymbol -Template $main -Symbol 'activityLog'
      }

      It 'deploys at subscription scope, not into a resource group' {
          $activityLog.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
          $activityLog.PSObject.Properties.Name | Should -Not -Contain 'condition'
      }

      It 'names the setting per environment, so dev and prod can share one subscription' {
          $activityLog.properties.parameters.settingName.value | Should -Be "[format('activity-log-defenstack-{0}', parameters('environmentName'))]"
          $activityLog.name | Should -Be "[format('activity-log-{0}', parameters('environmentName'))]"
      }

      It 'sends the Activity Log to the shared workspace' {
          $activityLog.properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[reference('global').outputs.logAnalyticsWorkspaceId.value]"
      }
  }

  Describe 'Alerts (Phase 6)' {
      BeforeAll {
          $actionGroup = Get-TemplateResourceBySymbol -Template $main -Symbol 'actionGroup'
          $globalAlerts = Get-TemplateResourceBySymbol -Template $main -Symbol 'globalMetricAlerts'
          $serviceHealth = Get-TemplateResourceBySymbol -Template $main -Symbol 'serviceHealthAlert'
          $globalRules = @($globalAlerts.properties.parameters.rules.value)
      }

      It 'takes the alert email from the pipeline (ALERT_EMAIL), empty by default' {
          $main.parameters.alertEmail.type | Should -Be 'string'
          $main.parameters.alertEmail.defaultValue | Should -BeExactly ''
      }

      It 'defaults the count thresholds' {
          $defaults = $main.parameters.alertThresholds.defaultValue
          $defaults.appServiceHttp5xx | Should -Be 10
          $defaults.keyVaultForbidden | Should -Be 10
          $defaults.vpnP2sConnections | Should -Be 20
          $defaults.frontDoorWafBlocks | Should -Be 100
      }

      It 'creates one action group per environment in the global resource group' {
          $actionGroup.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $actionGroup.properties.parameters.actionGroupName.value | Should -Be "[format('ag-defenstack-{0}', parameters('environmentName'))]"
          $actionGroup.properties.parameters.shortName.value | Should -Be "[format('ds-{0}-ops', parameters('environmentName'))]"
          $actionGroup.properties.parameters.alertEmail.value | Should -Be "[parameters('alertEmail')]"
      }

      It 'gives both stamps the action group and the thresholds' {
          foreach ($stamp in $primary, $secondary) {
              $stamp.properties.parameters.actionGroupId.value | Should -Be "[reference('actionGroup').outputs.id.value]"
              $stamp.properties.parameters.alertThresholds.value | Should -Be "[parameters('alertThresholds')]"
          }
      }

      It 'puts the Front Door alerts in the global resource group' {
          $globalAlerts.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $globalAlerts.properties.parameters.namePrefix.value | Should -Be "[format('alert-defenstack-{0}', parameters('environmentName'))]"
          $globalAlerts.properties.parameters.actionGroupId.value | Should -Be "[reference('actionGroup').outputs.id.value]"
          @($globalRules | ForEach-Object { $_.name }) -join ',' | Should -Be 'front-door-origin-health,front-door-waf-blocks'
      }

      It 'alerts when Front Door origin health drops below 90 percent (Sev1)' {
          $rule = $globalRules | Where-Object { $_.name -eq 'front-door-origin-health' }
          $rule.metricName | Should -BeExactly 'OriginHealthPercentage'
          $rule.metricNamespace | Should -BeExactly 'Microsoft.Cdn/profiles'
          $rule.operator | Should -Be 'LessThan'
          $rule.threshold | Should -Be '90'
          $rule.timeAggregation | Should -Be 'Average'
          $rule.severity | Should -Be 1
          $rule.resourceId | Should -Be "[reference('frontDoor').outputs.id.value]"
      }

      It 'alerts when the WAF blocks more requests than the threshold (Sev2), counting only Action = Block' {
          $rule = $globalRules | Where-Object { $_.name -eq 'front-door-waf-blocks' }
          $rule.metricName | Should -BeExactly 'WebApplicationFirewallRequestCount'
          $rule.metricNamespace | Should -BeExactly 'Microsoft.Cdn/profiles'
          $rule.operator | Should -Be 'GreaterThan'
          $rule.threshold | Should -Be "[string(parameters('alertThresholds').frontDoorWafBlocks)]"
          $rule.timeAggregation | Should -Be 'Total'
          $rule.severity | Should -Be 2
          $rule.resourceId | Should -Be "[reference('frontDoor').outputs.id.value]"
          $rule.dimensions[0].name | Should -Be 'Action'
          $rule.dimensions[0].operator | Should -Be 'Include'
          @($rule.dimensions[0].values) | Should -Be @('Block')
      }

      It 'watches Service Health for the primary region, the secondary only with DR, and global events' {
          $serviceHealth.resourceGroup | Should -Be "[variables('globalResourceGroupName')]"
          $serviceHealth.properties.parameters.alertName.value | Should -Be "[format('alert-defenstack-{0}-service-health', parameters('environmentName'))]"
          $serviceHealth.properties.parameters.actionGroupId.value | Should -Be "[reference('actionGroup').outputs.id.value]"
          $regions = $serviceHealth.properties.parameters.regions.value
          $regions | Should -Match "^\[concat\(createArray\(variables\('regionDisplayNames'\)\[toLower\(parameters\('primaryLocation'\)\)\]\)"
          $regions | Should -Match "if\(parameters\('deploySecondaryRegion'\), createArray\(variables\('regionDisplayNames'\)\[toLower\(parameters\('secondaryLocation'\)\)\]\), createArray\(\)\)"
          $regions | Should -Match "createArray\('Global'\)\)\]$"
          $main.variables.regionDisplayNames.westus3 | Should -BeExactly 'West US 3'
          $main.variables.regionDisplayNames.eastus | Should -BeExactly 'East US'
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
          $approve = $deploy.IndexOf('./scripts/Approve-FrontDoorPrivateEndpoints.ps1')
          $approve | Should -BeGreaterThan $create
          $deploy | Should -Match ([regex]::Escape('--query properties.outputs --output json'))
          $deploy | Should -Match ([regex]::Escape('az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}"'))
      }

      It 'fails the job when the outputs cannot be read' {
          $deploy | Should -Match ([regex]::Escape("throw 'Could not read appServiceIds from the deployment outputs.'"))
          $deploy | Should -Match ([regex]::Escape("throw 'Could not read frontDoorProfileName from the deployment outputs.'"))
          $deploy | Should -Match ([regex]::Escape("throw 'Could not read globalResourceGroupName from the deployment outputs.'"))
      }

      It 'passes the Front Door profile and global resource group names to the approval script (final review A)' {
          $deploy | Should -Match ([regex]::Escape('-AppServiceId $ids -FrontDoorProfileName $profileName -FrontDoorResourceGroupName $resourceGroupName'))
      }

      It 'refreshes the Azure login right before the approval step, since the wait can outlast the first token' {
          $create = $deploy.IndexOf('az deployment sub create')
          $refresh = $deploy.IndexOf('Refresh Azure login before approval')
          $approve = $deploy.IndexOf('Approve Front Door private endpoint connections')
          $refresh | Should -BeGreaterThan $create
          $approve | Should -BeGreaterThan $refresh

          $applyStart = $deploy.IndexOf('  apply:')
          $applyJob = $deploy.Substring($applyStart)
          ([regex]::Matches($applyJob, 'uses: azure/login@v2')).Count | Should -Be 2
      }
  }

  Describe 'Alert email from the ALERT_EMAIL environment variable (Phase 6)' {
      BeforeAll {
          $applyStart = $deploy.IndexOf('  apply:')
          $applyJob = $deploy.Substring($applyStart)
          $planJob = $deploy.Substring(0, $applyStart)
          $alertEmailArgument = '--parameters alertEmail="$ALERT_EMAIL"'
          $alertEmailVariable = 'ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}'
      }

      It 'passes alertEmail from vars.ALERT_EMAIL to validate, what-if and create' {
          ([regex]::Matches($planJob, [regex]::Escape($alertEmailArgument))).Count | Should -Be 2
          ([regex]::Matches($applyJob, [regex]::Escape($alertEmailArgument))).Count | Should -Be 1
          ([regex]::Matches($deploy, [regex]::Escape($alertEmailVariable))).Count | Should -Be 4
      }

      It 'passes alertEmail to the pull request what-if, so it shows no spurious receiver change' {
          $ci | Should -Match ([regex]::Escape($alertEmailArgument))
          $ci | Should -Match ([regex]::Escape($alertEmailVariable))
      }

      It 'fails the prod apply before signing in to Azure when ALERT_EMAIL is empty' {
          $check = $applyJob.IndexOf('- name: Require ALERT_EMAIL for prod')
          $check | Should -BeGreaterThan -1
          $check | Should -BeLessThan $applyJob.IndexOf('uses: azure/login@v2')
          $check | Should -BeLessThan $applyJob.IndexOf('az deployment sub create')
          $step = $applyJob.Substring($check, $applyJob.IndexOf('- uses: actions/checkout@v4') - $check)
          $step | Should -Match "if: env\.TARGET_ENV == 'prod'"
          $step | Should -Match ([regex]::Escape('if [ -z "$ALERT_EMAIL" ]; then'))
          $step | Should -Match 'exit 1'
      }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected failures: `bicep build failed for modules/actionGroup.bicep`, `modules/metricAlerts.bicep` and `modules/serviceHealthAlert.bicep`, the Front Door `id` output, the `Alerts (Phase 6)` and `Region stamp alerts (Phase 6)` tests, and the three `ALERT_EMAIL` workflow tests.

- [ ] **Step 3: Create the alert modules and types**

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
  @description('Private DNS zone names (or resource IDs) keyed by private endpoint group: the application zones plus the Azure Monitor Private Link Scope zones (Phase 6).')
  type privateDnsZoneSet = {
    @description('Blob storage zone.')
    blob: string

    @description('App Service (sites) zone.')
    sites: string

    @description('Key Vault zone.')
    vault: string

    @description('Azure Monitor global endpoints zone (AMPLS).')
    monitor: string

    @description('Log Analytics workspace agent endpoints zone (AMPLS).')
    oms: string

    @description('Log Analytics workspace ingestion (ODS) endpoints zone (AMPLS).')
    ods: string

    @description('Log Analytics agent service endpoints zone (AMPLS).')
    agentsvc: string
  }

  @export()
  @description('A virtual network to link to a private DNS zone.')
  type virtualNetworkReference = {
    @description('VNet name; used to build a unique link name.')
    name: string

    @description('VNet resource ID.')
    id: string
  }

  @export()
  @description('Prod with DR only: how this region\'s firewall carries traffic to and from the other region over the hub-to-hub global peering (Phase 6).')
  type hubPeeringPlan = {
    @description('Private IP of the other region\'s firewall, the next hop for the other region\'s spoke.')
    remoteFirewallPrivateIp: string

    @description('Spoke address prefixes of the other region, routed from this AzureFirewallSubnet to the other firewall.')
    remoteSpokeAddressPrefixes: string[]

    @description('This region\'s part in Azure Monitor traffic: Host owns the AMPLS private endpoint, Client forwards its spoke to it.')
    monitorRole: 'Host' | 'Client'

    @description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
    monitorClientPrefixes: string[]

    @description('Private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint. Used by the Client rule.')
    monitorPrivateEndpointPrefixes: string[]
  }

  @export()
  @description('A dimension filter on a metric alert, for example StatusCode = 403.')
  type metricAlertDimension = {
    @description('Dimension name, for example StatusCode or Action.')
    name: string

    @description('Include matches only the values; Exclude matches everything else.')
    operator: 'Include' | 'Exclude'

    @description('Dimension values.')
    values: string[]
  }

  @export()
  @description('One static-threshold metric alert on a single resource (Phase 6).')
  type metricAlertRule = {
    @description('Short rule name, appended to the alert name prefix, for example firewall-health.')
    name: string

    @description('What the alert means. Shown in the alert email; runbook 06 has the triage steps.')
    description: string

    @description('Alert severity: 0 Critical, 1 Error, 2 Warning, 3 Informational, 4 Verbose.')
    severity: 0 | 1 | 2 | 3 | 4

    @description('Resource ID the metric is read from.')
    resourceId: string

    @description('Metric namespace, the resource type, for example Microsoft.Network/azureFirewalls.')
    metricNamespace: string

    @description('Exact metric name, for example FirewallHealth.')
    metricName: string

    @description('Comparison against the threshold.')
    operator: 'GreaterThan' | 'GreaterThanOrEqual' | 'LessThan' | 'LessThanOrEqual'

    @description('Threshold as text, for example \'90\' or \'99.9\'. Bicep has no decimal literals; the module converts it with json().')
    threshold: string

    @description('How the metric is aggregated over the window.')
    timeAggregation: 'Average' | 'Minimum' | 'Maximum' | 'Total' | 'Count'

    @description('Dimension filters. Omit for none.')
    dimensions: metricAlertDimension[]?

    @description('False skips the rule, for example the VPN alert in a region without a gateway. Defaults to true.')
    deploy: bool?
  }

  @export()
  @description('Thresholds for the count-based platform alerts (Phase 6). Health and percentage alerts use fixed thresholds.')
  type alertThresholdSet = {
    @description('App Service HTTP 5xx responses per region in a 15-minute window.')
    @minValue(1)
    appServiceHttp5xx: int

    @description('Key Vault requests refused with 403 per region in a 15-minute window.')
    @minValue(1)
    keyVaultForbidden: int

    @description('Point-to-site VPN connections on the gateway at any time in a 15-minute window.')
    @minValue(1)
    vpnP2sConnections: int

    @description('Front Door WAF blocked requests in a 15-minute window.')
    @minValue(1)
    frontDoorWafBlocks: int
  }
  ```

  Create `modules/actionGroup.bicep`:

  ```bicep
  @description('Action group name.')
  param actionGroupName string

  @description('Short name shown in alert emails and SMS. At most 12 characters.')
  @minLength(1)
  @maxLength(12)
  param shortName string

  @description('Email address that receives every platform alert, from the GitHub variable ALERT_EMAIL. Empty creates the group with no receiver (dev only; the prod apply refuses an empty value).')
  param alertEmail string = ''

  // One action group per environment for every platform alert (Phase 6). The common alert schema gives every
  // alert type the same email layout.
  resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
    name: actionGroupName
    location: 'Global'
    properties: {
      groupShortName: shortName
      enabled: true
      emailReceivers: empty(alertEmail) ? [] : [
        {
          name: 'platform-operators'
          emailAddress: alertEmail
          useCommonAlertSchema: true
        }
      ]
    }
  }

  output id string = actionGroup.id
  output name string = actionGroup.name
  ```

  Create `modules/metricAlerts.bicep`:

  ```bicep
  import { metricAlertRule } from 'types.bicep'

  @description('Prefix of every alert name, for example alert-defenstack-prod-wus3.')
  param namePrefix string

  @description('Static-threshold metric alerts to create, each on one resource.')
  param rules metricAlertRule[]

  @description('Resource ID of the action group notified when an alert fires or resolves.')
  param actionGroupId string

  // Static-threshold metric alerts (Phase 6). 2018-03-01 is the last clearly GA metricAlerts API version (research §6).
  // Every rule is evaluated every 5 minutes over a 15-minute window and resolves itself when the metric recovers.
  resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [for rule in rules: if (rule.?deploy ?? true) {
    name: '${namePrefix}-${rule.name}'
    location: 'global'
    properties: {
      description: rule.description
      severity: rule.severity
      enabled: true
      scopes: [
        rule.resourceId
      ]
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: rule.name
            metricNamespace: rule.metricNamespace
            metricName: rule.metricName
            operator: rule.operator
            // Bicep has no decimal literals, so thresholds arrive as text (for example '99.9').
            threshold: json(rule.threshold)
            timeAggregation: rule.timeAggregation
            dimensions: rule.?dimensions ?? []
          }
        ]
      }
      actions: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }]
  ```

  Create `modules/serviceHealthAlert.bicep`:

  ```bicep
  @description('Alert rule name.')
  param alertName string

  @description('Regions to watch, as Service Health names them (for example West US 3), plus Global for non-regional events.')
  param regions string[]

  @description('Resource ID of the action group notified when Service Health reports an event.')
  param actionGroupId string

  // Service Health incidents, planned maintenance and advisories for the platform regions (Phase 6). Activity log
  // alerts are global and watch the whole subscription; 2020-10-01 is the GA version (research §6).
  resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
    name: alertName
    location: 'Global'
    properties: {
      description: 'Azure Service Health event affecting a DefenStack region. Triage: runbook 06.'
      enabled: true
      scopes: [
        subscription().id
      ]
      condition: {
        allOf: [
          {
            field: 'category'
            equals: 'ServiceHealth'
          }
          {
            anyOf: [
              {
                field: 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
                containsAny: regions
              }
            ]
          }
        ]
      }
      actions: {
        actionGroups: [
          {
            actionGroupId: actionGroupId
          }
        ]
      }
    }
  }

  output name string = serviceHealthAlert.name
  ```

- [ ] **Step 4: Wire the alerts**

  Replace `modules/frontDoor.bicep`:

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

  // The match condition's RemoteAddr is derived from X-Forwarded-For, not the TCP peer (socket) address, but the
  // condition here matches all traffic regardless of that value (0.0.0.0/0 and ::/0 cover every IPv4 and IPv6
  // address), so it never filters anything out. Front Door's rate limit itself counts requests per socket IP, not
  // X-Forwarded-For, so the limit cannot be inflated or evaded by forging that header.
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
          // SocketAddr is the TCP peer address Front Door itself observed, not a client-supplied header, so it
          // cannot be spoofed via X-Forwarded-For.
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

  output id string = profile.id
  output profileName string = profile.name
  output endpointHostName string = endpoint.properties.hostName
  output frontDoorId string = profile.properties.frontDoorId
  output customDomainValidationToken string = hasCustomDomain ? customDomain!.properties.validationProperties.validationToken : ''
  output privateLinkRequestMessage string = privateLinkRequestMessage
  ```

  Replace `modules/regionStamp.bicep`:

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet, hubPeeringPlan, alertThresholdSet } from 'types.bicep'

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

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  @description('Application secrets written to this region\'s Key Vault, as { name: value } (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  @description('Prod with DR only: routing and Azure Monitor rules for the hub-to-hub peering with the other region. Absent in dev and in prod without DR.')
  param hubPeering hubPeeringPlan?

  @description('Resource ID of the environment\'s action group, which every regional alert notifies (Phase 6).')
  param actionGroupId string

  @description('Thresholds for the count-based regional alerts (Phase 6).')
  param alertThresholds alertThresholdSet

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
    appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
    flowLogStorageAccount: 'stfl${regionCode}${nameSuffix}'
    flowLogIdentity: 'id-flowlogs-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges.
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var monitorPeeringRole = hubPeering.?monitorRole ?? 'None'
  // The region hosting the AMPLS endpoint SNATs the other region's monitoring traffic at its firewall, so the
  // private-endpoint NSG must admit the firewall subnet there (Phase 6).
  var peerTrafficSourceCidrs = monitorPeeringRole == 'Host' ? [
    addressPlan.firewallSubnetPrefix
  ] : []
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
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
      secrets: keyVaultSecrets
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
      remoteSpokeAddressPrefixes: hubPeering.?remoteSpokeAddressPrefixes ?? []
      remoteFirewallPrivateIp: hubPeering.?remoteFirewallPrivateIp ?? ''
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
      monitorPeeringRole: monitorPeeringRole
      monitorClientPrefixes: hubPeering.?monitorClientPrefixes ?? []
      monitorPrivateEndpointPrefixes: hubPeering.?monitorPrivateEndpointPrefixes ?? []
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
      ], peerTrafficSourceCidrs, additionalPrivateEndpointSourceCidrs)
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  // One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
  module appInsights 'appInsights.bicep' = {
    name: 'app-insights'
    params: {
      location: location
      componentName: names.appInsights
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
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
      applicationInsightsConnectionString: appInsights.outputs.connectionString
    }
  }

  module appInsightsPublisher 'appInsightsPublisher.bicep' = {
    name: 'app-insights-publisher'
    params: {
      componentName: appInsights.outputs.name
      publisherPrincipalId: appService.outputs.appServicePrincipalId
      publisherAppServiceName: names.appService
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

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
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

  // VNet flow logs with Traffic Analytics (Phase 6): a regional keyless account and the identity that writes to it.
  module flowLogStorage 'flowLogStorage.bicep' = {
    name: 'flow-log-storage'
    params: {
      location: location
      storageAccountName: names.flowLogStorageAccount
      // Zone-redundant in prod; flow logs are regional telemetry, so no geo copy. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? 'Standard_ZRS' : 'Standard_LRS'
      identityName: names.flowLogIdentity
    }
  }

  // Network Watcher lives in NetworkWatcherRG (one per region per subscription), so the flow logs are deployed there.
  module flowLogs 'flowLogs.bicep' = {
    name: 'flow-logs-${environmentName}-${regionCode}'
    scope: resourceGroup('NetworkWatcherRG')
    params: {
      location: location
      virtualNetworks: [
        {
          name: names.hubVnet
          id: hubNetwork.outputs.id
        }
        {
          name: names.spokeVnet
          id: spokeNetwork.outputs.id
        }
      ]
      storageAccountId: flowLogStorage.outputs.id
      identityId: flowLogStorage.outputs.identityId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  // Regional platform alerts (Phase 6), all to the environment's action group. Triage steps: runbook 06.
  module metricAlerts 'metricAlerts.bicep' = {
    name: 'metric-alerts'
    params: {
      namePrefix: 'alert-defenstack-${environmentName}-${regionCode}'
      actionGroupId: actionGroupId
      rules: [
        {
          name: 'firewall-health'
          description: 'Azure Firewall health is below 90 percent.'
          severity: 1
          resourceId: azureFirewall.outputs.id
          metricNamespace: 'Microsoft.Network/azureFirewalls'
          metricName: 'FirewallHealth'
          operator: 'LessThan'
          threshold: '90'
          timeAggregation: 'Average'
        }
        {
          name: 'firewall-snat-ports'
          description: 'Azure Firewall SNAT port utilisation is above 80 percent.'
          severity: 2
          resourceId: azureFirewall.outputs.id
          metricNamespace: 'Microsoft.Network/azureFirewalls'
          metricName: 'SNATPortUtilization'
          operator: 'GreaterThan'
          threshold: '80'
          timeAggregation: 'Maximum'
        }
        {
          name: 'app-http-5xx'
          description: 'The App Service returned more HTTP 5xx responses than the threshold in 15 minutes.'
          severity: 2
          resourceId: appService.outputs.appServiceAppId
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'Http5xx'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.appServiceHttp5xx)
          timeAggregation: 'Total'
        }
        {
          name: 'app-health-check'
          description: 'Some App Service instances are failing the health check.'
          severity: 1
          resourceId: appService.outputs.appServiceAppId
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'HealthCheckStatus'
          operator: 'LessThan'
          threshold: '100'
          timeAggregation: 'Average'
        }
        {
          name: 'key-vault-availability'
          description: 'Key Vault availability is below 99.9 percent.'
          severity: 2
          resourceId: keyVault.outputs.id
          metricNamespace: 'Microsoft.KeyVault/vaults'
          metricName: 'Availability'
          operator: 'LessThan'
          threshold: '99.9'
          timeAggregation: 'Average'
        }
        {
          name: 'key-vault-forbidden'
          description: 'Key Vault refused more requests with 403 Forbidden than the threshold in 15 minutes.'
          severity: 3
          resourceId: keyVault.outputs.id
          metricNamespace: 'Microsoft.KeyVault/vaults'
          metricName: 'ServiceApiResult'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.keyVaultForbidden)
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'StatusCode'
              operator: 'Include'
              values: [
                '403'
              ]
            }
          ]
        }
        {
          name: 'vpn-p2s-connections'
          description: 'More point-to-site VPN connections than expected.'
          severity: 3
          resourceId: deployAdminAccess ? vpnGateway!.outputs.id : ''
          metricNamespace: 'Microsoft.Network/virtualNetworkGateways'
          metricName: 'P2SConnectionCount'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.vpnP2sConnections)
          timeAggregation: 'Maximum'
          // Only where this region has the gateway (deployAdminAccess).
          deploy: deployAdminAccess
        }
      ]
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
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  output appInsightsName string = appInsights.outputs.name
  output appInsightsId string = appInsights.outputs.id
  output privateEndpointSubnetId string = spokeNetwork.outputs.privateEndpointSubnetId
  ```

  Replace `main.bicep`:

  ```bicep
  targetScope = 'subscription'

  import { regionAddressPlan, privateDnsZoneSet, alertThresholdSet } from 'modules/types.bicep'

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

  @description('Application secrets written to every regional Key Vault, as { name: value }. The pipeline supplies them from the KEYVAULT_SECRETS_JSON environment secret; never put values in a committed parameter file (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  @description('Relative path probed by App Service health check in every region.')
  param healthCheckPath string = '/'

  @description('Email address that receives every platform alert. The pipeline passes the GitHub environment variable ALERT_EMAIL and refuses an empty value for prod; empty creates the action group with no receiver.')
  param alertEmail string = ''

  @description('Thresholds for the count-based alerts: App Service 5xx, Key Vault 403s, VPN connections and WAF blocks.')
  param alertThresholds alertThresholdSet = {
    appServiceHttp5xx: 10
    keyVaultForbidden: 10
    vpnP2sConnections: 20
    frontDoorWafBlocks: 100
  }

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
  // Region names as Azure Service Health reports them, for the Service Health alert.
  var regionDisplayNames = {
    westus3: 'West US 3'
    eastus: 'East US'
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
    // Azure Monitor Private Link Scope zones (Phase 6); the AMPLS endpoint also registers in the blob zone above.
    monitor: 'privatelink.monitor.azure.com'
    oms: 'privatelink.oms.opinsights.azure.com'
    ods: 'privatelink.ods.opinsights.azure.com'
    agentsvc: 'privatelink.agentsvc.azure-automation.net'
  }

  // Prod with DR (Phase 6): the East US App Service and management subnets may reach the one AMPLS endpoint, in the
  // primary private-endpoint subnet, through both firewalls and the hub-to-hub peering. Nothing else crosses yet (Phase 8).
  var monitorClientPrefixes = deploySecondaryRegion ? [
    secondaryAddressPlan!.appServiceIntegrationSubnetPrefix
    secondaryAddressPlan!.managementSubnetPrefix
  ] : []
  var monitorPrivateEndpointPrefixes = [
    primaryAddressPlan.privateEndpointSubnetPrefix
  ]

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

  // The subscription Activity Log goes to the shared workspace, where Sentinel reads it as Azure Activity (Phase 6).
  module activityLog 'modules/activityLog.bicep' = {
    name: 'activity-log-${environmentName}'
    params: {
      settingName: 'activity-log-defenstack-${environmentName}'
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
    }
  }

  // One action group per environment for every platform alert (Phase 6).
  module actionGroup 'modules/actionGroup.bicep' = {
    name: 'action-group-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      actionGroupName: 'ag-defenstack-${environmentName}'
      shortName: 'ds-${environmentName}-ops'
      alertEmail: alertEmail
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
      keyVaultSecrets: keyVaultSecrets
      actionGroupId: actionGroup.outputs.id
      alertThresholds: alertThresholds
      // A firewall always takes the first usable address (.4) of its AzureFirewallSubnet (see regionStamp.bicep).
      hubPeering: deploySecondaryRegion ? {
        remoteFirewallPrivateIp: cidrHost(secondaryAddressPlan!.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: secondaryAddressPlan!.spokeAddressSpace
        monitorRole: 'Host'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      } : null
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
      primaryStorageAccountId: isProd ? primaryStamp.outputs.storageAccountId : ''
      primaryStorageAccountName: isProd ? primaryStamp.outputs.storageAccountName : ''
      keyVaultSecrets: keyVaultSecrets
      actionGroupId: actionGroup.outputs.id
      alertThresholds: alertThresholds
      hubPeering: {
        remoteFirewallPrivateIp: cidrHost(primaryAddressPlan.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: primaryAddressPlan.spokeAddressSpace
        monitorRole: 'Client'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      }
    }
  }

  // Hub-to-hub global peering, both ways, once both hubs exist (brought forward from Phase 8). The sides are created
  // one after the other, since each peering operation updates both VNets.
  module primaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${primaryRegionCode}-to-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      localVnetName: primaryStamp.outputs.hubVnetName
      remoteVnetId: secondaryStamp!.outputs.hubVnetId
      peeringName: 'hub-to-${secondaryRegionCode}-hub'
    }
  }

  module secondaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${secondaryRegionCode}-to-${primaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      localVnetName: secondaryStamp!.outputs.hubVnetName
      remoteVnetId: primaryStamp.outputs.hubVnetId
      peeringName: 'hub-to-${primaryRegionCode}-hub'
    }
    dependsOn: [
      primaryHubPeering
    ]
  }

  // The warm-standby App Service may read (never write) the primary application container (ADR-020).
  module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion && isProd) {
    name: 'storage-reader-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      storageAccountName: primaryStamp.outputs.storageAccountName
      storageContainerName: primaryStamp.outputs.storageContainerName
      readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
      readerAppServiceName: secondaryStamp!.outputs.appServiceName
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

  // Global platform alerts (Phase 6): Front Door origin health and WAF blocks, and Service Health for the platform
  // regions. The backup job alert waits for Phase 8.
  module globalMetricAlerts 'modules/metricAlerts.bicep' = {
    name: 'global-metric-alerts-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      namePrefix: 'alert-defenstack-${environmentName}'
      actionGroupId: actionGroup.outputs.id
      rules: [
        {
          name: 'front-door-origin-health'
          description: 'Front Door sees less than 90 percent of origin health probes succeed.'
          severity: 1
          resourceId: frontDoor.outputs.id
          metricNamespace: 'Microsoft.Cdn/profiles'
          metricName: 'OriginHealthPercentage'
          operator: 'LessThan'
          threshold: '90'
          timeAggregation: 'Average'
        }
        {
          name: 'front-door-waf-blocks'
          description: 'The Front Door WAF blocked more requests than the threshold in 15 minutes.'
          severity: 2
          resourceId: frontDoor.outputs.id
          metricNamespace: 'Microsoft.Cdn/profiles'
          metricName: 'WebApplicationFirewallRequestCount'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.frontDoorWafBlocks)
          timeAggregation: 'Total'
          dimensions: [
            {
              name: 'Action'
              operator: 'Include'
              values: [
                'Block'
              ]
            }
          ]
        }
      ]
    }
  }

  module serviceHealthAlert 'modules/serviceHealthAlert.bicep' = {
    name: 'service-health-alert-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      alertName: 'alert-defenstack-${environmentName}-service-health'
      regions: concat([
        regionDisplayNames[toLower(primaryLocation)]
      ], deploySecondaryRegion ? [
        regionDisplayNames[toLower(secondaryLocation)]
      ] : [], [
        'Global'
      ])
      actionGroupId: actionGroup.outputs.id
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

  // Private-only monitoring (Phase 6): one scope holds the workspace and every regional App Insights component.
  module monitorPrivateLinkScope 'modules/monitorPrivateLinkScope.bicep' = {
    name: 'monitor-private-link-scope-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      scopeName: 'ampls-defenstack-${environmentName}'
      scopedResourceIds: concat([
        global.outputs.logAnalyticsWorkspaceId
        primaryStamp.outputs.appInsightsId
      ], deploySecondaryRegion ? [
        secondaryStamp!.outputs.appInsightsId
      ] : [])
    }
  }

  // The single azuremonitor endpoint, in the primary spoke, created once the scope holds every resource.
  module monitorPrivateEndpoint 'modules/monitorPrivateEndpoint.bicep' = {
    name: 'monitor-private-endpoint-${environmentName}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      location: primaryLocation
      privateLinkScopeId: monitorPrivateLinkScope.outputs.id
      privateLinkScopeName: monitorPrivateLinkScope.outputs.name
      privateEndpointSubnetId: primaryStamp.outputs.privateEndpointSubnetId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
    }
  }

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output frontDoorProfileName string = frontDoor.outputs.profileName
  output globalResourceGroupName string = globalResourceGroupName
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
  output monitorPrivateLinkScopeName string = monitorPrivateLinkScope.outputs.name
  ```

- [ ] **Step 5: Pass ALERT_EMAIL from the pipeline**

  Replace `.github/workflows/deploy.yml`:

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
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            az deployment sub validate \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --parameters alertEmail="$ALERT_EMAIL" \
              --output none

        - name: What-if
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            set -o pipefail
            az deployment sub what-if \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --parameters alertEmail="$ALERT_EMAIL" \
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
        # Prod alerts must reach someone: stop before any Azure call when the prod environment has no ALERT_EMAIL (runbook 06).
        - name: Require ALERT_EMAIL for prod
          if: env.TARGET_ENV == 'prod'
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            if [ -z "$ALERT_EMAIL" ]; then
              echo "::error::Set the ALERT_EMAIL variable on the prod GitHub environment before deploying prod (runbook 06)."
              exit 1
            fi

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

        # Application secrets come from the environment secret KEYVAULT_SECRETS_JSON and are written to every regional vault (ADR-019).
        - name: Prepare Key Vault secrets
          shell: pwsh
          env:
            KEYVAULT_SECRETS_JSON: ${{ secrets.KEYVAULT_SECRETS_JSON }}
          run: ./scripts/ConvertTo-KeyVaultSecretsParameter.ps1 -Json $env:KEYVAULT_SECRETS_JSON -OutFile "$env:RUNNER_TEMP/keyvault-secrets.json"

        - name: Deploy
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            az deployment sub create \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --parameters keyVaultSecrets=@"$RUNNER_TEMP/keyvault-secrets.json" \
              --parameters alertEmail="$ALERT_EMAIL" \
              --output table

        - name: Remove the secrets file
          if: always()
          run: rm -f "$RUNNER_TEMP/keyvault-secrets.json"

        # The approval wait can outlast the first login's token (up to 15 minutes per app), so refresh it immediately
        # before the step that needs it.
        - name: Refresh Azure login before approval
          uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        # Front Door reaches each App Service over Private Link; its connections stay Pending until approved (runbook 04).
        - name: Approve Front Door private endpoint connections
          shell: pwsh
          run: |
            $outputs = az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" --query properties.outputs --output json | ConvertFrom-Json
            $ids = $outputs.appServiceIds.value
            $profileName = $outputs.frontDoorProfileName.value
            $resourceGroupName = $outputs.globalResourceGroupName.value
            if ($LASTEXITCODE -ne 0 -or -not $ids) { throw 'Could not read appServiceIds from the deployment outputs.' }
            if (-not $profileName) { throw 'Could not read frontDoorProfileName from the deployment outputs.' }
            if (-not $resourceGroupName) { throw 'Could not read globalResourceGroupName from the deployment outputs.' }
            ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $ids -FrontDoorProfileName $profileName -FrontDoorResourceGroupName $resourceGroupName
  ````

  Replace `.github/workflows/bicep-ci.yml`:

  ````yaml
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
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            set -o pipefail
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"
            az deployment sub what-if \
              --location "$DEPLOYMENT_LOCATION" \
              --name "pr-${{ github.event.pull_request.number }}-${{ github.run_attempt }}" \
              --parameters params/dev.bicepparam \
              --parameters alertEmail="$ALERT_EMAIL" \
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
  ````

- [ ] **Step 6: Build, lint, test, YAML, PSRule**

  Run `bicep build main.bicep` and lint every file. The full suite should show `Tests Passed: 523, Failed: 0`. The YAML check should print `YAML-OK`. PSRule should show 0 failures out of 1200 rules processed.

- [ ] **Step 7: Commit**

  ```bash
  git add modules/actionGroup.bicep modules/metricAlerts.bicep modules/serviceHealthAlert.bicep modules/types.bicep modules/frontDoor.bicep modules/regionStamp.bicep main.bicep main.json .github/workflows/deploy.yml .github/workflows/bicep-ci.yml tests/Alerts.Tests.ps1 tests/FrontDoor.Tests.ps1 tests/RegionStamp.Tests.ps1 tests/Main.Tests.ps1 tests/Workflows.Tests.ps1
  git commit -m "feat: action group and platform metric, Front Door and Service Health alerts" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 6: Runbook 06, ADR-022 to ADR-025, and Phase 6 documentation updates

**Files:**
- Create: `docs/runbooks/06-monitoring-and-sentinel.md`, `docs/decisions/ADR-022-private-only-monitoring-and-hub-peering.md`, `docs/decisions/ADR-023-flow-log-identity-and-network-watcher.md`, `docs/decisions/ADR-024-sentinel-content-through-content-hub.md`, `docs/decisions/ADR-025-preview-api-subscription-diagnostic-setting.md`
- Replace: `tests/Docs.Tests.ps1`, `docs/decisions/ADR-021-application-insights-per-region.md`
- Modify: `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/00b-configure-pipeline-credentials.md`, `docs/runbooks/01-deploy-stack.md`, `docs/runbooks/05-app-and-data.md`, `README.md`

**Interfaces:**
- **Consumes:** the names, parameters, roles, rules, alerts and messages from Tasks 1–5. The runbook quotes them verbatim.
- **Produces:** the documents that the spec §6 definition of done requires a human to execute in dev, including alert triage and Sentinel connector enablement (§5 row 6).

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
          foreach ($topic in 'Custom domain and DNS cutover', 'WAF tuning and exclusions', 'Approving a private endpoint connection by hand', 'az network private-endpoint-connection approve', 'The request message is not proof') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the ingress runbook validates the spec checks: Front Door 200, WAF 403, direct App Service 403' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          $text | Should -Match ([regex]::Escape('?q=<script>alert(1)</script>'))
          $text | Should -Match ([regex]::Escape('https://<app>.azurewebsites.net/'))
      }

      It 'the ingress runbook documents that success is Front Door''s own origin status (final review A)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          $text | Should -Match ([regex]::Escape('sharedPrivateLinkResource.status'))
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

  Describe 'Phase 5 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/05-app-and-data.md', 'docs/decisions/ADR-019-deploy-time-key-vault-secrets.md', 'docs/decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md', 'docs/decisions/ADR-021-application-insights-per-region.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the app and data runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the app and data runbook covers secret sync and restore from soft delete and PITR (spec §5 Phase 5)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw
          foreach ($topic in 'Secret sync', 'KEYVAULT_SECRETS_JSON', 'az storage blob undelete', 'az storage container restore', 'az storage blob restore', 'az keyvault secret recover') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'runbook 00b documents the environment secret and the Phase 5 delegatable roles' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
          $text | Should -Match 'KEYVAULT_SECRETS_JSON'
          $text | Should -Match '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
          $text | Should -Match '3913510d-42f4-4e42-8a64-420c390055eb'
      }

      It 'the architecture overview and cost document cover Phase 5' {
          $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          foreach ($adr in 'ADR-019', 'ADR-020', 'ADR-021') { $overview | Should -Match $adr }
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 5 delta'
      }

      It 'runbook 04 documents the no-origin refusal' {
          Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw | Should -Match ([regex]::Escape("so it cannot be Front Door's request"))
      }
  }

  Describe 'Phase 6 documentation' {
      BeforeAll {
          $script:runbook06 = Get-Content (Get-RepoPath 'docs/runbooks/06-monitoring-and-sentinel.md') -Raw -ErrorAction SilentlyContinue
          $script:runbook00b = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
      }

      It '<_> exists' -ForEach 'docs/runbooks/06-monitoring-and-sentinel.md', 'docs/decisions/ADR-022-private-only-monitoring-and-hub-peering.md', 'docs/decisions/ADR-023-flow-log-identity-and-network-watcher.md', 'docs/decisions/ADR-024-sentinel-content-through-content-hub.md', 'docs/decisions/ADR-025-preview-api-subscription-diagnostic-setting.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the monitoring runbook follows the 9-section template' {
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $script:runbook06 | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the monitoring runbook covers alert triage, Sentinel connectors and querying over the VPN or jump host (spec §5 Phase 6)' {
          foreach ($topic in 'Alert triage', 'Sentinel connector enablement', 'Content Hub', 'Microsoft Entra ID', 'Tenant-based Microsoft Defender for Cloud', 'Querying the workspace over the VPN or jump host', 'Live-only risks') {
              $script:runbook06 | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the monitoring runbook has a triage entry for every alert rule' {
          foreach ($rule in 'firewall-health', 'firewall-snat-ports', 'app-http-5xx', 'app-health-check', 'key-vault-availability', 'key-vault-forbidden', 'vpn-p2s-connections', 'front-door-origin-health', 'front-door-waf-blocks', 'service-health') {
              $script:runbook06 | Should -Match ([regex]::Escape("``$rule``"))
          }
          $script:runbook06 | Should -Match 'backup job alert[^.]*Phase 8'
      }

      It 'the monitoring runbook sets ALERT_EMAIL on dev, dev-plan and prod' {
          foreach ($environment in 'dev', 'dev-plan', 'prod') {
              $script:runbook06 | Should -Match ([regex]::Escape("gh variable set ALERT_EMAIL --env $environment"))
          }
      }

      It 'the monitoring runbook and runbooks 00b and 01 require NetworkWatcherRG and NetworkWatcher_<region> before the identity script or deployment' {
          foreach ($text in $script:runbook06, $script:runbook00b, (Get-Content (Get-RepoPath 'docs/runbooks/01-deploy-stack.md') -Raw)) {
              $text | Should -Match ([regex]::Escape('az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true'))
              $text | Should -Match ([regex]::Escape('NetworkWatcher_<region>'))
          }
      }

      It 'the monitoring runbook covers the cross-region AMPLS path: East US network rule, West US 3 application rule with SNAT, and the private-endpoint NSG' {
          foreach ($topic in 'spoke-to-peer-azure-monitor', 'peer-spoke-to-azure-monitor', 'source address', 'AzureFirewallSubnet', '-firewall-rt') {
              $script:runbook06 | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the monitoring runbook lists each unverified item as a live-only risk with a fallback' {
          $risks = $script:runbook06.Substring($script:runbook06.IndexOf('Live-only risks'))
          foreach ($risk in 'trusted services', 'Traffic Analytics', 'FQDN', '2021-05-01-preview', '2018-03-01') {
              $risks | Should -Match ([regex]::Escape($risk))
          }
          ([regex]::Matches($risks, 'Fallback')).Count | Should -BeGreaterOrEqual 5
      }

      It 'runbook 00b documents the Phase 6 grants: Network Contributor on NetworkWatcherRG and the diagnostic-setting actions with the update path' {
          foreach ($topic in 'Network Contributor', '-NetworkWatcherResourceGroupName', 'Microsoft.Insights/diagnosticSettings/write', 'az role definition update', 'Update custom role actions') {
              $script:runbook00b | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'runbook 05 and ADR-021 no longer say Application Insights stays public until Phase 6' {
          Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw | Should -Not -Match 'until Phase 6'
          Get-Content (Get-RepoPath 'docs/decisions/ADR-021-application-insights-per-region.md') -Raw | Should -Match 'ADR-022'
      }

      It 'the architecture overview, README and cost document cover Phase 6' {
          $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          foreach ($adr in 'ADR-022', 'ADR-023', 'ADR-024', 'ADR-025') { $overview | Should -Match $adr }
          $overview | Should -Match '\*\*Phase 6\*\*'
          Get-Content (Get-RepoPath 'README.md') -Raw | Should -Match ([regex]::Escape('06-monitoring-and-sentinel.md'))
          $cost = Get-Content (Get-RepoPath 'docs/cost.md') -Raw
          $cost | Should -Match '## Phase 6 delta'
          foreach ($driver in 'Sentinel', 'Traffic Analytics', 'flow-log storage', 'private endpoint', 'DNS zones', 'peering', 'alert') {
              $cost | Should -Match ([regex]::Escape($driver))
          }
      }
  }
  ````

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected: the `Phase 6 documentation` tests fail.

- [ ] **Step 3: Create runbook 06**

  Create `docs/runbooks/06-monitoring-and-sentinel.md`:

  ````markdown
  # 06 - Monitoring, detection and response runbook (private Azure Monitor, flow logs, Sentinel, alerts)

  > Owning module(s): `modules/monitorPrivateLinkScope.bicep`, `modules/monitorPrivateEndpoint.bicep`, `modules/monitoring.bicep` (workspace and Sentinel onboarding), `modules/appInsights.bicep`, `modules/hubPeering.bicep`, `modules/hubNetwork.bicep` (firewall-subnet route table), `modules/firewallPolicyRules.bicep` (`cross-region-monitoring`), `modules/flowLogStorage.bicep`, `modules/flowLogs.bicep`, `modules/activityLog.bicep`, `modules/actionGroup.bicep`, `modules/metricAlerts.bicep`, `modules/serviceHealthAlert.bicep`, wired by `modules/regionStamp.bicep` and `main.bicep`. Pipeline: `.github/workflows/deploy.yml` (`ALERT_EMAIL`), `scripts/New-GitHubDeploymentIdentity.ps1`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Monitoring, detection and response", §5 Phase 6. Decisions: `ADR-022`, `ADR-023`, `ADR-024`, `ADR-025`.

  ## 1. Purpose and scope

  This runbook makes every telemetry path private, records network flows and subscription activity, turns on Microsoft Sentinel, and sends platform alerts to one email address.

  **Private-only Azure Monitor (`ADR-022`):**

  | Resource | Where | What it does |
  |---|---|---|
  | AMPLS `ampls-defenstack-<env>` | `rg-defenstack-<env>-global` | Ingestion and query access modes `PrivateOnly`. Scopes `log-defenstack-<env>` and every `appi-defenstack-<env>-<region>` |
  | Private endpoint `ampls-defenstack-<env>-pe` (group `azuremonitor`) | Primary spoke, `private-endpoints` subnet | The **only** AMPLS endpoint for the environment. Registers in the four Azure Monitor zones and the shared blob zone |
  | Zones `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net` | `rg-defenstack-<env>-global` | Linked to every hub and spoke, like the existing zones; locked in prod |
  | Workspace and App Insights components | unchanged places | `publicNetworkAccessForIngestion` and `publicNetworkAccessForQuery` are `Disabled`. Retention stays 90 days |

  **Cross-region AMPLS path (prod with DR only, `deploySecondaryRegion = true`):**

  The East US App Service and jump host reach the one endpoint in West US 3 through both firewalls:

  ```mermaid
  sequenceDiagram
      participant EUS as East US App Service or jump host
      participant FW2 as East US firewall (Client)
      participant FW1 as West US 3 firewall (Host)
      participant PE as AMPLS private endpoint (primary private-endpoints subnet)

      EUS->>FW2: HTTPS to the PE address (spoke route 0.0.0.0/0 to firewall)
      FW2->>FW2: Network rule spoke-to-peer-azure-monitor (source address kept)
      FW2->>FW1: AzureFirewallSubnet route table: primary spoke prefix to the West US 3 firewall, over the hub-to-hub peering
      FW1->>FW1: Application rule peer-spoke-to-azure-monitor (Azure Monitor FQDNs only; source address rewritten to the firewall)
      FW1->>PE: HTTPS from the West US 3 AzureFirewallSubnet (the PE NSG allows it)
      PE-->>FW1: Reply to the firewall
      FW1-->>FW2: Reply over the peering (East US spoke prefix to the East US firewall)
      FW2-->>EUS: Reply
  ```

  - **East US policy, network rule** `spoke-to-peer-azure-monitor` / `azure-monitor-private-endpoint`: TCP 443 from the East US `appservice-integration` and `management` subnets to the primary `private-endpoints` subnet prefix. A network rule keeps the source address.
  - **West US 3 policy, application rule** `peer-spoke-to-azure-monitor` / `azure-monitor-private-link`: HTTPS from the same East US subnets to `*.applicationinsights.azure.com`, `*.monitor.azure.com`, `*.ods.opinsights.azure.com`, `*.oms.opinsights.azure.com` and `*.agentsvc.azure-automation.net`. An application rule rewrites the source address to the firewall's own (SNAT), so the endpoint replies to the West US 3 firewall. The primary spoke has no route back to East US. Other private endpoints in that subnet stay unreachable from East US, because the Host rule allows only Azure Monitor names.
  - **Both rules** live in the rule collection group `cross-region-monitoring` (priority 250), which exists only with DR.
  - **West US 3 private-endpoint NSG** (`<spoke VNet>-private-endpoints-nsg`, rule `allow-approved-https`): its approved sources include the region's own `AzureFirewallSubnet` prefix, the SNAT source. Only the Host region gets this source.
  - **Routing:** each hub's `AzureFirewallSubnet` has the route table `<hub VNet>-firewall-rt`: `remote-spoke-<n>-through-peer-firewall` (the other region's spoke prefix to the other firewall's `.4` address) and `default-to-internet` (`0.0.0.0/0` to `Internet`, which Azure requires there).
  - **Peering:** `hub-to-eus-hub` and `hub-to-wus3-hub`, forwarded traffic allowed, no gateway transit. Nothing but Azure Monitor crosses until Phase 8.

  **VNet flow logs and Traffic Analytics (`ADR-023`), per region:**
  - A keyless flow-log account `stfl<region><suffix>` (no shared key, public network access `Disabled`, `AzureServices` bypass, default `Deny`; prod ZRS, dev LRS).
  - The identity `id-flowlogs-defenstack-<env>-<region>` holds Storage Blob Data Contributor on that account only.
  - Flow logs `<vnet>-flowlog` for the hub and spoke, under `NetworkWatcher_<region>` in `NetworkWatcherRG`: 90-day retention, Traffic Analytics to the workspace every 10 minutes.

  **Activity Log and Sentinel (`ADR-024`, `ADR-025`):**
  - The subscription diagnostic setting `activity-log-defenstack-<env>` sends all eight Activity Log categories to the workspace (Sentinel's Azure Activity data).
  - Microsoft Sentinel is onboarded on `log-defenstack-<env>` (`onboardingStates` `default`) in dev and prod.
  - Firewall, Key Vault and Front Door WAF logs already reach the workspace through their diagnostic settings. Connectors and analytics rules are installed by hand from Content Hub (§5.1).

  **Alerts.** Every alert goes to the action group `ag-defenstack-<env>` (global resource group), which emails the GitHub environment variable `ALERT_EMAIL`. Metric alerts run every 5 minutes over 15 minutes and resolve themselves.

  | Alert rule | Scope | Condition | Severity |
  |---|---|---|---|
  | `alert-defenstack-<env>-<region>-firewall-health` | Each region's firewall | `FirewallHealth` < 90 (average) | Sev1 |
  | `…-<region>-firewall-snat-ports` | Each region's firewall | `SNATPortUtilization` > 80 (maximum) | Sev2 |
  | `…-<region>-app-http-5xx` | Each region's App Service | `Http5xx` > `alertThresholds.appServiceHttp5xx` (total) | Sev2 |
  | `…-<region>-app-health-check` | Each region's App Service | `HealthCheckStatus` < 100 (average) | Sev1 |
  | `…-<region>-key-vault-availability` | Each region's Key Vault | `Availability` < 99.9 (average) | Sev2 |
  | `…-<region>-key-vault-forbidden` | Each region's Key Vault | `ServiceApiResult` with `StatusCode` 403 > `alertThresholds.keyVaultForbidden` (count) | Sev3 |
  | `…-<region>-vpn-p2s-connections` | VPN gateway, only where it exists | `P2SConnectionCount` > `alertThresholds.vpnP2sConnections` (maximum) | Sev3 |
  | `alert-defenstack-<env>-front-door-origin-health` | Front Door profile | `OriginHealthPercentage` < 90 (average) | Sev1 |
  | `alert-defenstack-<env>-front-door-waf-blocks` | Front Door profile | `WebApplicationFirewallRequestCount` with `Action` = Block > `alertThresholds.frontDoorWafBlocks` (total) | Sev2 |
  | `alert-defenstack-<env>-service-health` | Subscription | Service Health events for West US 3, East US (prod with DR) and Global | (activity log alert) |

  The backup job alert is deferred to Phase 8, together with the Recovery Services vaults.

  **Not in scope:**
  - Defender for Cloud plans and Azure Policy (Phase 7).
  - Backup, the backup job alert, DR traffic over the peering, and the failover runbook (Phase 8).
  - Sentinel analytics rules as code (`ADR-024`).

  ## 2. Prerequisites

  - **Network Watcher must exist before the identity script or the deployment runs.** The identity script grants Network Contributor on `NetworkWatcherRG`, and the flow logs are created under `NetworkWatcher_<region>` there. Azure normally creates both with the first VNet in a region, unless the subscription opted out. If either is missing, the script fails with a scope-not-found error and the deployment fails with `ResourceNotFound`. An operator with `Network Contributor` (or `Contributor`) at subscription scope checks and, if needed, creates them:

    ```powershell
    az network watcher list --query "[].{name:name, rg:resourceGroup, location:location}" -o table
    if ((az group exists --name NetworkWatcherRG) -eq 'false') { az group create --name NetworkWatcherRG --location westus3 -o none }
    az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true
    ```

    Expected: `NetworkWatcher_westus3` and `NetworkWatcher_eastus` in `NetworkWatcherRG`. The CLI needs `--resource-group` when it enables a region for the first time. Dev uses only `westus3`; enabling `eastus` too is harmless and free.
  - **Pipeline identity:** Phase 6 changes two grants. Re-run the identity script once per environment as an operator with `Owner` or `User Access Administrator` at subscription scope, because updating a custom role needs `Microsoft.Authorization/roleDefinitions/write` (§4 step 2, runbook 00b):
    - The subscription role `DefenStack Subscription Deployment Operator` gains `Microsoft.Insights/diagnosticSettings/read`, `/write` and `/delete` for the Activity Log setting. The script updates an existing role in place.
    - `Network Contributor` on `NetworkWatcherRG`.
  - **GitHub:** repository admin, to create the `ALERT_EMAIL` environment variable on `dev`, `dev-plan` and `prod` (§4 step 3).
  - **Providers:** register and check `Microsoft.SecurityInsights` (new), plus `Microsoft.Insights`, `Microsoft.OperationalInsights` and `Microsoft.Network`:

    ```powershell
    foreach ($ns in 'Microsoft.SecurityInsights','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Network') { az provider register --namespace $ns }
    foreach ($ns in 'Microsoft.SecurityInsights','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Network') { az provider show -n $ns --query registrationState -o tsv }
    ```

    Expect `Registered` four times.
  - **Operator for §5–§6:**
    - the VPN or the jump host from runbook 03. Queries, the Logs blade and the Sentinel pages work only from a connected network once query access is private;
    - `Log Analytics Reader` on the workspace for queries; `Microsoft Sentinel Contributor` on the workspace for Content Hub installs and analytics rules;
    - a tenant **Security Administrator** or **Global Administrator** for the Entra ID connector (§5.1).
  - **Tools:** Azure CLI 2.90+, Bicep CLI 0.47.16, PowerShell 7 or 5.1, `gh` (optional, for §4 step 3).

  ## 3. Parameters

  | Name | Default | Prod value | Rationale |
  |---|---|---|---|
  | `alertEmail` (`main.bicep`) | `''` | from `ALERT_EMAIL` | The pipeline passes the environment variable. Empty creates the action group with no receiver; the prod apply refuses an empty value |
  | `alertThresholds.appServiceHttp5xx` | `10` | `10` | HTTP 5xx responses per region per 15 minutes |
  | `alertThresholds.keyVaultForbidden` | `10` | `10` | Key Vault 403 results per region per 15 minutes |
  | `alertThresholds.vpnP2sConnections` | `20` | `20` | Point-to-site sessions on the gateway, peak in 15 minutes |
  | `alertThresholds.frontDoorWafBlocks` | `100` | `100` | WAF blocks per 15 minutes |
  | `retentionDays` (`flowLogs.bicep`) | `90` | `90` | Matches the workspace retention |
  | `trafficAnalyticsIntervalMinutes` (`flowLogs.bicep`) | `10` | `10` | Allowed values 10 or 60 |
  | `retentionInDays` (`monitoring.bicep`) | `90` | `90` | Unchanged; Sentinel's included retention |
  | `deploySecondaryRegion` (`main.bicep`) | `false` | `true` | Also turns on the hub-to-hub peering, the firewall-subnet route tables and `cross-region-monitoring` |
  | `-NetworkWatcherResourceGroupName` (identity script) | `NetworkWatcherRG` | `NetworkWatcherRG` | Where Network Contributor is granted. Change it only if the subscription keeps Network Watcher elsewhere, and then the flow-log module scope must change too |

  Thresholds are set in `main.bicep`'s `alertThresholds` default, or per environment in its `.bicepparam` file.

  ## 4. Step-by-step deployment

  1. **Check that Network Watcher exists** (§2, first bullet). Do not continue until `NetworkWatcher_westus3` (and, for prod, `NetworkWatcher_eastus`) is listed in `NetworkWatcherRG`.

  2. **Re-run the pipeline identity script** for each environment (runbook 00b §4 step 2), as an operator with `Owner` or `User Access Administrator`:

     ```powershell
     .\scripts\New-GitHubDeploymentIdentity.ps1 -ResourceGroupNames 'rg-defenstack-dev-global','rg-defenstack-dev-wus3' -GitHubRepository Godson90/bicep -EnvironmentName dev -WhatIf
     ```

     Expected `What if:` lines, among the existing ones: `Update custom role actions` on `DefenStack Subscription Deployment Operator` (only once per subscription; dev and prod share the role), and assigning `Network Contributor` at `/subscriptions/<sub>/resourceGroups/NetworkWatcherRG`. Run it again without `-WhatIf`. For prod, add `'rg-defenstack-prod-eus'` and `-GrantLockManagement`, as in runbook 00b §5.

     Check:

     ```powershell
     az role definition list --name "DefenStack Subscription Deployment Operator" --custom-role-only true --query "[0].permissions[0].actions" -o tsv
     ```

     Expected: 12 actions, including `Microsoft.Insights/diagnosticSettings/write`.

  3. **Set the `ALERT_EMAIL` GitHub environment variable, for dev and for prod.** Use a monitored mailbox or distribution list, never a personal address that can leave the team.
     - **Web UI:** `https://github.com/Godson90/bicep` → **Settings** → **Environments** → `dev` → **Environment variables** → **Add environment variable** → name `ALERT_EMAIL`, value the address. Repeat for `dev-plan` (the dev plan job and the PR what-if run there, so they need the same value or the what-if shows the email receiver being removed) and for `prod`.
     - **GitHub CLI:**

       ```powershell
       gh variable set ALERT_EMAIL --env dev --repo Godson90/bicep --body 'platform-alerts@example.org'
       gh variable set ALERT_EMAIL --env dev-plan --repo Godson90/bicep --body 'platform-alerts@example.org'
       gh variable set ALERT_EMAIL --env prod --repo Godson90/bicep --body 'platform-alerts@example.org'
       gh variable list --env prod --repo Godson90/bicep
       ```

     It is a **variable**, not a secret: the workflows read `vars.ALERT_EMAIL`. Dev may leave it empty (the action group then has no receiver). Prod may not: the `apply` job's first step, **Require ALERT_EMAIL for prod**, fails the run before it signs in to Azure.

  4. **Register the providers** (§2).

  5. **Validate and preview**, from the repository root (add `--parameters alertEmail=<address>` to see the receiver):

     ```powershell
     az deployment sub validate --location westus3 --parameters params/dev.bicepparam --parameters alertEmail='platform-alerts@example.org'
     az deployment sub what-if --location westus3 --parameters params/dev.bicepparam --parameters alertEmail='platform-alerts@example.org'
     ```

     Check the what-if:
     - `rg-defenstack-dev-global`: **create** the four Azure Monitor zones, their links and (prod) their locks; `ampls-defenstack-dev` and its scoped resources; `ag-defenstack-dev`; the two Front Door alerts and the Service Health alert; Sentinel `default` on the workspace. **Modify** the workspace (`publicNetworkAccessForIngestion` and `publicNetworkAccessForQuery` to `Disabled`).
     - `rg-defenstack-dev-wus3`: **create** `ampls-defenstack-dev-pe`, `stflwus3…`, `id-flowlogs-defenstack-dev-wus3` and its role assignment, and the seven regional alerts. **Modify** `appi-defenstack-dev-wus3` (both public access flags to `Disabled`).
     - `NetworkWatcherRG`: **create** `vnet-defenstack-dev-wus3-hub-flowlog` and `vnet-defenstack-dev-wus3-spoke-flowlog`.
     - Subscription: **create** the diagnostic setting `activity-log-defenstack-dev`.
     - Prod also: the hub peerings `hub-to-eus-hub` / `hub-to-wus3-hub`, the route tables `vnet-defenstack-prod-<region>-hub-firewall-rt`, the rule collection group `cross-region-monitoring` in both policies, and a change to the West US 3 `allow-approved-https` NSG rule (its sources gain `10.1.0.0/26`).
     - **Stop** on any delete or recreate of the workspace, a zone, a VNet, a firewall or an App Service.

  6. **Deploy through the pipeline:** GitHub → Actions → `deploy` → **Run workflow** → `dev` (prod: the two-approval flow, `ADR-012`).

  7. **Check the AMPLS endpoint's DNS records:**

     ```powershell
     az network private-endpoint dns-zone-group show -g rg-defenstack-dev-wus3 --endpoint-name ampls-defenstack-dev-pe -n default --query "privateDnsZoneConfigs[].{zone:name, records:recordSets[].fqdn}" -o json
     ```

     Expected: five zone configs (`monitor`, `oms`, `ods`, `agentsvc`, `blob`), with records for the workspace ID (`<workspace id>.ods.opinsights.azure.com`, `<workspace id>.oms.opinsights.azure.com`, `<workspace id>.agentsvc.azure-automation.net`) and the shared `api`, `global.in.ai`, `live` and regional `in.ai` names under `monitor.azure.com`.

  8. **Install the Sentinel content** (§5.1).

  ## 5. Manual and post-deployment steps

  ### 5.1 Sentinel connector enablement

  Do this once per environment, from the VPN or the jump host (§5.2), in **Microsoft Sentinel** → `log-defenstack-<env>` (or the Defender portal, if the workspace is onboarded there). Content Hub is the supported install path (`ADR-024`).

  1. **Content Hub** → search, select, **Install** for each solution:
     - **Azure Activity:** its data already arrives from `activity-log-defenstack-<env>` (table `AzureActivity`). Do **not** use the connector page's own "Launch Azure Policy" wizard; the Bicep setting already covers the subscription.
     - **Azure Firewall:** data in `AZFWNetworkRule`, `AZFWApplicationRule`, `AZFWDnsQuery`, `AZFWThreatIntel`, `AZFWIdpsSignature`.
     - **Azure Key Vault:** data in `AzureDiagnostics` (`ResourceProvider == "MICROSOFT.KEYVAULT"`).
     - **Azure Web Application Firewall (WAF):** Front Door WAF data in `AzureDiagnostics` (`Category == "FrontDoorWebApplicationFirewallLog"`).
     - **Microsoft Entra ID** and **Microsoft Defender for Cloud** (steps 3 and 4).
  2. **Analytics rule templates:** **Analytics** → **Rule templates**, filter **Data sources** by each solution above → open each template you want → **Create rule** → keep the defaults → **Review + create**. Start with the high-severity templates of the Firewall and Key Vault solutions. Record the enabled templates in the Phase 6 PR.
  3. **Microsoft Entra ID connector** (tenant administrator: Security Administrator or Global Administrator): **Data connectors** → **Microsoft Entra ID** → **Open connector page** → tick **Sign-In Logs**, **Audit Logs**, **Non-Interactive User Sign-In Log**, **Service Principal Sign-In Logs**, **Managed Identity Sign-In Logs** and **Provisioning Logs** → **Apply Changes**. This creates a tenant diagnostic setting in Entra ID; it is not managed by Bicep. Sign-in logs need an Entra ID P1 or P2 licence.
  4. **Tenant-based Microsoft Defender for Cloud connector:** **Data connectors** → **Tenant-based Microsoft Defender for Cloud** → **Open connector page** → **Connect**. It covers every subscription in the tenant, so no per-subscription connector is needed. The Defender plans themselves arrive in Phase 7; until then, only free-tier recommendations flow.
  5. **Check:** **Data connectors** shows **Connected** for Azure Activity, Azure Firewall, Azure Key Vault, Azure WAF, Microsoft Entra ID and Defender for Cloud after data arrives (up to an hour).

  ### 5.2 Querying the workspace over the VPN or jump host

  With query access `PrivateOnly`, the workspace answers only requests that arrive through the AMPLS endpoint:
  - **Point-to-site VPN** (runbook 03 §5.1 and §5.3): VPN clients use the hub DNS server (the firewall DNS proxy), so the Azure Monitor names resolve to the endpoint in the primary spoke. Open the portal in a browser on that machine.
  - **Jump host** (runbook 03, through Bastion): the management subnet already resolves and routes privately.
  - **Not supported:** the portal Logs blade or the Sentinel pages from any other network; queries sent through the Azure Resource Manager API (Microsoft states these cannot use private links); `az monitor log-analytics query` from a laptop that is not on the VPN.

  Check, from the VPN or the jump host:

  ```powershell
  $workspaceId = az monitor log-analytics workspace show -g rg-defenstack-dev-global -n log-defenstack-dev --query customerId -o tsv
  nslookup "$workspaceId.ods.opinsights.azure.com"
  nslookup api.loganalytics.io
  az monitor log-analytics query -w $workspaceId --analytics-query "AzureActivity | take 5" -o table
  ```

  Expected: both names resolve to addresses in the primary `private-endpoints` subnet (dev `10.20.1.0/24`, prod `10.0.1.0/24`), and the query returns rows. From an unconnected network, the same query fails with `InsufficientAccessError` or a message about public network access.

  ### 5.3 Alert triage

  Each alert email uses the common alert schema: it names the rule, the resource and the metric value. Start every triage from the VPN or the jump host, so the workspace queries work.

  | Alert rule | What it means | First checks | Usual fix |
  |---|---|---|---|
  | `firewall-health` (Sev1) | The firewall reports less than 90% health: degraded instances or SNAT exhaustion | `az network firewall show -g <rg> -n afw-defenstack-<env>-<region> --query provisioningState`; Azure Service Health; `AZFWNetworkRule` volume | Check `firewall-snat-ports`; open a Microsoft case if health stays low with no SNAT pressure. Everything in the region egresses through this firewall, so treat it as a regional outage risk |
  | `firewall-snat-ports` (Sev2) | More than 80% of SNAT ports in use | `AZFWNetworkRule` and `AZFWApplicationRule` by `SourceIp` and `DestinationIp` for the top talkers | Find the client opening many connections; reuse connections in the app; add firewall public IPs only through a reviewed change |
  | `app-http-5xx` (Sev2) | The App Service returned more 5xx responses than the threshold in 15 minutes | `AppRequests \| where ResultCode startswith "5" \| summarize count() by AppRoleName, Name, ResultCode`; `AppExceptions`; App Service **Diagnose and solve problems** | Roll back the last app deploy, or fix the dependency (Key Vault, Storage) the exceptions name |
  | `app-health-check` (Sev1) | Some instances fail `healthCheckPath` | App Service **Health check** blade; `AppServiceHTTPLogs` for the probe path; `front-door-origin-health` | Restart the unhealthy instance; if every instance fails, treat it as an app outage (Front Door fails over to East US in prod) |
  | `key-vault-availability` (Sev2) | Key Vault served less than 99.9% of requests successfully | Azure Service Health for Key Vault in the region; `AzureDiagnostics \| where ResourceProvider == "MICROSOFT.KEYVAULT" \| summarize count() by ResultSignature` | Usually a platform incident: follow Service Health. If it is throttling (`429`), reduce the app's call rate or cache secrets |
  | `key-vault-forbidden` (Sev3) | More 403 Forbidden results than the threshold: a missing role, a request from outside the private network, or someone probing | `AzureDiagnostics \| where ResourceProvider == "MICROSOFT.KEYVAULT" and httpStatusCode_d == 403 \| project TimeGenerated, CallerIPAddress, identity_claim_oid_g, OperationName` | A known identity missing a role: grant it through Bicep. An unknown caller: open a Sentinel incident and investigate |
  | `vpn-p2s-connections` (Sev3) | More admin VPN sessions than expected | `az network vnet-gateway vpn-client show-health -g <rg> -n vpng-defenstack-<env>-<region>`, or the gateway's **Point-to-site sessions** blade; Entra sign-in logs for the VPN app | Confirm the sessions belong to the admin group; remove unexpected users from the admin group in Entra ID (runbook 03 §5.5 and §8) |
  | `front-door-origin-health` (Sev1) | Fewer than 90% of Front Door health probes succeed | `AzureDiagnostics \| where Category == "FrontDoorHealthProbeLog"`; the origins' `app-health-check`; the Private Link connection status (runbook 04 §6) | Fix the failing origin; an unapproved Private Link connection also fails probes (runbook 04 §5.2) |
  | `front-door-waf-blocks` (Sev2) | The WAF blocked more requests than the threshold | `AzureDiagnostics \| where Category == "FrontDoorWebApplicationFirewallLog" and action_s == "Block" \| summarize count() by ruleName_s, clientIP_s` | An attack: no action beyond watching, and Sentinel incidents. A false positive after an app change: follow runbook 04 §5.3 "WAF tuning and exclusions" |
  | `service-health` | Azure reports an incident, maintenance or advisory in West US 3, East US (prod) or Global | The email links to the Service Health event | Follow Microsoft's guidance in the event; in a prolonged West US 3 outage, the failover decision belongs to the Phase 8 DR runbook |

  A Sev1 alert pages the on-call person by email only. Phase 8 may add SMS or a webhook to the action group.

  ## 6. Validation

  | Check | Command | Expected result |
  |---|---|---|
  | Workspace is private | `az monitor log-analytics workspace show -g rg-defenstack-<env>-global -n log-defenstack-<env> --query "{ingestion:publicNetworkAccessForIngestion, query:publicNetworkAccessForQuery, retention:retentionInDays}" -o json` | `Disabled`, `Disabled`, `90` |
  | App Insights is private | `az monitor app-insights component show -g rg-defenstack-<env>-<region> --app appi-defenstack-<env>-<region> --query "{ingestion:publicNetworkAccessForIngestion, query:publicNetworkAccessForQuery}" -o json` | `Disabled`, `Disabled` |
  | AMPLS modes and scope | `az monitor private-link-scope show -g rg-defenstack-<env>-global -n ampls-defenstack-<env> --query accessModeSettings -o json`; `az monitor private-link-scope scoped-resource list -g rg-defenstack-<env>-global --scope-name ampls-defenstack-<env> --query "[].name" -o tsv` | `PrivateOnly` twice; the workspace and every component (prod: both regions) |
  | Private resolution (§5.2) | `nslookup <workspace id>.ods.opinsights.azure.com` from the VPN or jump host | An address in the primary `private-endpoints` subnet |
  | Telemetry still arrives, both regions | `AppRequests \| where TimeGenerated > ago(1h) \| summarize count() by AppRoleName` (after traffic through Front Door) | One row per deployed region. East US rows prove the cross-region path |
  | Cross-region routes (prod) | `az network route-table route list -g rg-defenstack-prod-wus3 --route-table-name vnet-defenstack-prod-wus3-hub-firewall-rt -o table`, and the same for `rg-defenstack-prod-eus` / `vnet-defenstack-prod-eus-hub-firewall-rt` | West US 3: `10.10.0.0/16` → `VirtualAppliance` `10.11.0.4`; East US: `10.0.0.0/16` → `VirtualAppliance` `10.1.0.4`; both: `0.0.0.0/0` → `Internet` |
  | Host NSG (prod) | `az network nsg rule show -g rg-defenstack-prod-wus3 --nsg-name vnet-defenstack-prod-wus3-spoke-private-endpoints-nsg -n allow-approved-https --query sourceAddressPrefixes -o tsv` | Includes `10.1.0.0/26`, the West US 3 `AzureFirewallSubnet` |
  | Host rule hits (prod) | `AZFWApplicationRule \| where Rule == "azure-monitor-private-link" \| summarize count() by Fqdn, SourceIp` | East US source addresses, Azure Monitor FQDNs, action `Allow` |
  | Peering (prod) | `az network vnet peering list -g rg-defenstack-prod-wus3 --vnet-name vnet-defenstack-prod-wus3-hub --query "[?name=='hub-to-eus-hub'].{state:peeringState, fwd:allowForwardedTraffic, transit:allowGatewayTransit}" -o json` | `Connected`, `true`, `false` |
  | Flow logs | `az network watcher flow-log list --location westus3 --query "[].{name:name, enabled:enabled, ta:flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration.enabled}" -o table` | The hub and spoke flow logs of every environment in the subscription, enabled, Traffic Analytics `True` |
  | Flow-log blobs | `az storage container list --account-name <stfl…> --auth-mode login --query "[].name" -o tsv` (from the VPN; the account denies public access) | `insights-logs-flowlogflowevent` |
  | Traffic Analytics | `NTANetAnalytics \| where TimeGenerated > ago(1h) \| take 10` | Rows within about 30 minutes of the first deploy |
  | Activity Log | `az monitor diagnostic-settings subscription show --name activity-log-defenstack-<env> --query "logs[].{category:category, enabled:enabled}" -o table`; KQL `AzureActivity \| take 5` | Eight categories, all `True`; rows |
  | Sentinel | `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-defenstack-<env>-global/providers/Microsoft.OperationalInsights/workspaces/log-defenstack-<env>/providers/Microsoft.SecurityInsights/onboardingStates/default?api-version=2024-03-01" --query name -o tsv` | `default` |
  | Sentinel content (§5.1) | Sentinel → **Content hub** (filter **Installed**) and **Data connectors** | The four solutions installed; six connectors **Connected** |
  | Action group | `az monitor action-group show -g rg-defenstack-<env>-global -n ag-defenstack-<env> --query "emailReceivers[].emailAddress" -o tsv` | The `ALERT_EMAIL` value |
  | Alert rules | `az monitor metrics alert list -g rg-defenstack-<env>-<region> --query "[].{name:name, sev:severity, enabled:enabled}" -o table`; same for `rg-defenstack-<env>-global`; `az monitor activity-log alert list -g rg-defenstack-<env>-global -o table` | Seven regional rules where the gateway exists (six where it does not), two Front Door rules, one Service Health rule |
  | Test notification | `az monitor action-group test-notifications create --action-group ag-defenstack-<env> -g rg-defenstack-<env>-global --alert-type servicehealth --add-action email platform-operators <ALERT_EMAIL>` | The test email arrives |

  Paste every output into the Phase 6 PR (spec §6 definition of done).

  ## 7. Rollback

  Deployments are incremental: reverting the commit does not delete anything Phase 6 created, and the workspace keeps its private flags until a deployment sets them back.

  - **Make monitoring public again (emergency only, for example if telemetry stops and §9 has no fix):** set both flags to `Enabled` in `modules/monitoring.bicep` and `modules/appInsights.bicep`, deploy, and record why in `ADR-022`. As a temporary manual step: `az monitor log-analytics workspace update -g rg-defenstack-<env>-global -n log-defenstack-<env> --ingestion-access Enabled --query-access Enabled`. The AMPLS can stay; with public access re-enabled, its `PrivateOnly` modes affect only connected networks.
  - **AMPLS and its endpoint:** `az network private-endpoint delete -g rg-defenstack-<env>-wus3 -n ampls-defenstack-<env>-pe`, then `az monitor private-link-scope delete -g rg-defenstack-<env>-global -n ampls-defenstack-<env>`. Delete the endpoint first. In prod, the four new zones are locked; lift a zone lock before deleting a zone (runbook 01 §9 `ScopeLocked`).
  - **Hub peering (prod):** delete both peerings (`az network vnet peering delete -g rg-defenstack-prod-wus3 --vnet-name vnet-defenstack-prod-wus3-hub -n hub-to-eus-hub`, and the East US side), then remove each `-firewall-rt` route table from its `AzureFirewallSubnet` before deleting it. The hub VNets are locked in prod; peering changes do not need the lock lifted.
  - **Flow logs:** `az network watcher flow-log delete --location <region> --name <vnet>-flowlog`. The flow-log account keeps blobs until retention removes them.
  - **Activity Log setting:** `az monitor diagnostic-settings subscription delete --name activity-log-defenstack-<env>`.
  - **Sentinel:** offboarding deletes Sentinel's own content (incidents, rules) but not the workspace data. Do it only with security approval, from Sentinel → **Settings** → **Remove Microsoft Sentinel**.
  - **Alerts:** delete the rules and the action group with `az monitor metrics alert delete`, `az monitor activity-log alert delete` and `az monitor action-group delete`.
  - **Identity script changes:** the extra role actions and the Network Contributor assignment are harmless once the resources are gone. Remove them with `az role assignment delete --assignee <sp> --role 'Network Contributor' --scope /subscriptions/<sub>/resourceGroups/NetworkWatcherRG`, and with `az role definition update` without the three diagnostic-setting actions.

  ## 8. Operations

  - **Alert thresholds:** tune `alertThresholds` in `main.bicep` or in the environment's `.bicepparam` file after a week of real traffic; never edit a rule in the portal, because the next deploy overwrites it.
  - **Adding a region or a component to AMPLS:** turning on the secondary region in an existing environment adds its component to the scope after the endpoint exists. Re-run §4 step 7 afterwards and check that the regional `in.ai` record for the new region is present. If it is missing, delete and redeploy `ampls-defenstack-<env>-pe` in a change window.
  - **ALERT_EMAIL changes:** update the variable on `dev`, `dev-plan` and `prod` (§4 step 3) and run the deploy workflow; the action group follows.
  - **Sentinel content:** apply Content Hub updates monthly (**Content hub** → **Updates**). Review enabled analytics rules quarterly.
  - **Retention:** workspace and flow logs keep 90 days; do not raise it without a cost review.
  - **Backup job alert:** arrives with the Recovery Services vaults in Phase 8.
  - **Cost drivers** (`docs/cost.md` "Phase 6 delta"): Sentinel ingestion, Traffic Analytics processing, flow-log storage, the AMPLS endpoint, the four zones, global peering (prod), and alert rules.

  ## 9. Troubleshooting

  | Symptom / error text | Cause | Fix |
  |---|---|---|
  | Identity script fails with `ResourceGroupNotFound` or a scope error for `NetworkWatcherRG` | Network Watcher was never created in the subscription | §2 first bullet, then re-run the script |
  | Deploy fails on `flow-logs-<env>-<region>` with `ResourceNotFound` for `NetworkWatcher_<region>` | Network Watcher is missing in that region | `az network watcher configure --resource-group NetworkWatcherRG --locations <region> --enabled true`, then re-run |
  | Deploy fails on `activity-log-<env>` with `AuthorizationFailed ... Microsoft.Insights/diagnosticSettings/write` | The custom role predates Phase 6, or its update has not propagated | §4 step 2; wait up to 10 minutes and re-run |
  | Deploy fails on `flow-logs-<env>-<region>` with `AuthorizationFailed` | Network Contributor on `NetworkWatcherRG` is missing | §4 step 2 |
  | First deploy: flow logs fail with a storage access error | The flow-log identity's role assignment has not propagated | Re-run the deploy after a few minutes |
  | Prod `apply` fails at **Require ALERT_EMAIL for prod** | `ALERT_EMAIL` is not set on the `prod` environment | §4 step 3 |
  | The prod or dev what-if shows the email receiver being removed | `ALERT_EMAIL` is missing on the environment that ran the plan (`dev-plan` for dev) | Set it on that environment too (§4 step 3) |
  | Portal Logs or Sentinel shows "Access denied" or a public network access error | Your browser is not on a connected network | §5.2 |
  | `AppRequests` is empty for every region after the deploy | The App Service resolves the ingestion endpoint publicly, or the endpoint's records are missing | §4 step 7; `nslookup <region>-0.in.applicationinsights.azure.com` from the jump host must return a `private-endpoints` address |
  | `AppRequests` has West US 3 rows but no East US rows (prod) | The cross-region path is broken | Check the §6 rows "Cross-region routes", "Host NSG" and "Host rule hits"; `AZFWNetworkRule` on the East US firewall for `azure-monitor-private-endpoint` hits; see "Live-only risks" below |
  | `az monitor diagnostic-settings subscription create` reports the limit of five settings | Other settings exist on the subscription | Remove an unused one; dev and prod need two |
  | A metric alert fails to deploy with "metric not found" or "aggregation not supported" | A brand-new resource has not emitted the metric yet, or the aggregation is not offered for that metric | Re-run the deploy; for an aggregation error, see "Live-only risks" |

  ### Live-only risks

  These behaviours cannot be proved offline. Each one is first exercised by the first deployment that uses it. Record the outcome in the Phase 6 PR.

  | Risk | How it shows | Fallback |
  |---|---|---|
  | **Flow-log storage: the trusted services exception with public network access fully `Disabled`.** The account sets `publicNetworkAccess: 'Disabled'` with the `AzureServices` bypass; whether Network Watcher's trusted access is honoured when public access is fully disabled, rather than "enabled from selected networks", is not confirmed | 403s in the flow-log account's activity log; no `insights-logs-flowlogflowevent` container after 30 minutes | **Fallback:** set `publicNetworkAccess: 'Enabled'` in `modules/flowLogStorage.bicep`, keeping `defaultAction: 'Deny'` and the `AzureServices` bypass (still no public data-plane access), and record it in `ADR-023` |
  | **Traffic Analytics into a workspace with `PrivateOnly` ingestion.** Microsoft does not document whether the Traffic Analytics pipeline honours AMPLS-only ingestion | `NTANetAnalytics` stays empty after 30 minutes while the flow-log blobs grow | **Fallback:** keep the flow logs in storage, set Traffic Analytics off (`flowAnalyticsConfiguration` disabled in `modules/flowLogs.bicep`) and open a Microsoft case. Do not reopen public ingestion on the workspace without a new ADR (`ADR-023`) |
  | **The FQDN-filtered cross-region AMPLS path.** The West US 3 application rule must match multi-label hosts such as `global.in.ai.monitor.azure.com` and `eastus-8.in.applicationinsights.azure.com` with single wildcards, and the West US 3 firewall must resolve them to the private endpoint; the East US firewall must see the replies to its network-rule flow | East US `AppRequests` missing; `AZFWApplicationRule` on the West US 3 firewall shows `Deny` for an Azure Monitor FQDN, or no hits at all | **Fallback:** first add the exact denied FQDN to the Host rule's `targetFqdns`. If the path still fails, replace the Host application rule with a network rule (TCP 443, East US subnets → primary `private-endpoints` prefix), set the primary private-endpoint subnet's `privateEndpointNetworkPolicies` to `Enabled` and give it a route table that sends the East US spoke prefix to the West US 3 firewall, so replies return symmetrically. Record it in `ADR-022` |
  | **Preview API for the subscription diagnostic setting** (`Microsoft.Insights/diagnosticSettings@2021-05-01-preview`, the only version with subscription scope) | Deploy fails on `activity-log-<env>` with an API version error | **Fallback:** create the setting by hand, `az monitor diagnostic-settings subscription create --name activity-log-defenstack-<env> --location westus3 --workspace <workspace resource id> --logs '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'`, remove the module from `main.bicep`, and update `ADR-025` |
  | **Alert API versions that are not the newest.** `metricAlerts@2018-03-01`, `activityLogAlerts@2020-10-01` and `actionGroups@2023-01-01` are the last versions the research could confirm as GA. Newer versions without a preview label (for example `metricAlerts@2026-01-01`) were not adopted, because their GA status is not clearly documented | Deploy fails on an alert or the action group with `NoRegisteredProviderFound` or an API version error | **Fallback:** move the failing resource to the newest version that the template reference (`learn.microsoft.com/azure/templates/microsoft.insights/<type>`) labels GA, re-run `tests/Invoke-Tests.ps1`, and update the pinned-version tests |
  | **Alert details:** the `Maximum` aggregation for `P2SConnectionCount`, the `Count` aggregation for `ServiceApiResult`, and the Service Health region names `West US 3` / `East US` | Deploy error naming the aggregation; or no Service Health email for a known regional event | **Fallback:** use `Total` (and raise the P2S threshold accordingly); compare the region names with a Service Health event's `impactedRegions` and correct `regionDisplayNames` in `main.bicep` |
  ````

- [ ] **Step 4: Create the ADRs and update ADR-021**

  Create `docs/decisions/ADR-022-private-only-monitoring-and-hub-peering.md`:

  ```markdown
  # ADR-022: Azure Monitor is private-only through one AMPLS, and hub-to-hub peering moves to Phase 6

  ## Context
  The spec (§3, F10) asks for Log Analytics and Application Insights to ingest and answer queries only over Private Link. Until Phase 6, both accepted public ingestion and queries (`ADR-021`). Microsoft's guidance is one Azure Monitor Private Link Scope (AMPLS) per DNS: every private endpoint on an AMPLS rewrites the same shared `privatelink.*` records, so a second endpoint would override the first for every network that shares the zones. All our VNets, in both regions, share one set of private DNS zones.

  One endpoint in West US 3 means the East US App Service and jump host must reach it across regions. Hub-to-hub global peering was planned for Phase 8 (DR). Without it, the East US Application Insights component could not send telemetry once public ingestion is off.

  ## Decision
  - **One AMPLS per environment,** `ampls-defenstack-<env>`, in the global resource group, with ingestion and query access modes both `PrivateOnly` (`modules/monitorPrivateLinkScope.bicep`). It scopes the workspace and every regional Application Insights component.
  - **One `azuremonitor` private endpoint,** `ampls-defenstack-<env>-pe`, in the primary spoke's existing `private-endpoints` subnet (`modules/monitorPrivateEndpoint.bicep`). It registers in four new shared zones (`privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net`) and the existing blob zone. The new zones are linked like the others, and prod locks them like the others.
  - **The workspace and the components disable public ingestion and public query.**
  - **No lock on the AMPLS.** A `CanNotDelete` lock would also block deleting its scoped-resource children, so turning the secondary region off (which unlinks its component) would fail.
  - **Hub-to-hub global peering is brought forward from Phase 8,** prod with DR only (`deploySecondaryRegion`), both directions, with `allowForwardedTraffic: true` and no gateway transit (each hub has its own gateway) (`modules/hubPeering.bicep`).
  - **Each `AzureFirewallSubnet` gets a route table** `<hub VNet>-firewall-rt`: the other region's spoke prefixes go to the other firewall's private IP, and `0.0.0.0/0` goes to `Internet`, which Azure requires on that subnet. BGP propagation stays on, so the firewall keeps learning the point-to-site client pool.
  - **Only monitoring crosses regions.** The rule collection group `cross-region-monitoring` (priority 250) holds one collection per role:
    - **East US (Client):** a network rule `spoke-to-peer-azure-monitor`, TCP 443 from the East US `appservice-integration` and `management` subnets to the primary `private-endpoints` subnet. A network rule keeps the source address.
    - **West US 3 (Host):** an application rule `peer-spoke-to-azure-monitor`, HTTPS from the same East US subnets to the Azure Monitor FQDNs only. An application rule rewrites the source address to the firewall's own (SNAT), so the private endpoint replies to the West US 3 firewall. The primary spoke has no route back to East US, and Microsoft recommends SNAT for traffic to private endpoints.
    - **West US 3 private-endpoint NSG:** admits HTTPS from its own `AzureFirewallSubnet`, the SNAT source.

  ## Consequences
  - Nothing outside a connected network can send telemetry or run a query. Operators query over the VPN or from the jump host (runbook 06 §5.2). The portal Logs blade and the Sentinel pages fail from any other network.
  - Queries sent through the Azure Resource Manager API cannot use Private Link. Tools that query this way stop working.
  - Diagnostic settings, including the Activity Log, keep working: they use Azure's internal path, not the public endpoint.
  - Prod pays for global peering in both directions, per GB (`docs/cost.md` "Phase 6 delta"). Microsoft does not recommend dual-firewall transit across regions for performance. It is acceptable here because only telemetry crosses.
  - The East US firewall needs to see the reply to its network-rule flow, and the West US 3 application rule needs to match multi-label Azure Monitor hosts. Neither can be proved offline (runbook 06 §9 "Live-only risks", with the fallback).
  - Adding a component to the scope later relies on Azure adding its DNS records to the existing endpoint. Runbook 06 §8 has the check.

  ## Revisit when
  Phase 8 designs regional failover: the peering then carries DR traffic, and the AMPLS endpoint must still be reachable when West US 3 is down (a second endpoint in East US would need its own DNS).
  ```

  Create `docs/decisions/ADR-023-flow-log-identity-and-network-watcher.md`:

  ```markdown
  # ADR-023: VNet flow logs write with a managed identity to a regional keyless account, from NetworkWatcherRG

  ## Context
  The spec (§3) asks for VNet flow logs and Traffic Analytics. Flow logs are child resources of the region's Network Watcher, which Azure keeps as `NetworkWatcher_<region>` in `NetworkWatcherRG`, one per region per subscription, outside the environment's resource groups. Flow logs need a storage account in the same region as the VNet. Every storage account in this platform disables shared keys and public network access, and by default Network Watcher writes with the account key.

  ## Decision
  - **One flow-log storage account per region,** `stfl<region><suffix>`, in the region's resource group (`modules/flowLogStorage.bicep`):
    - shared key disabled, public network access disabled, `networkAcls` default `Deny` with the `AzureServices` bypass;
    - prod `Standard_ZRS`, dev `Standard_LRS` (`ADR-008`); no geo copy, because flow logs are regional telemetry and Traffic Analytics already lands in the replicated workspace;
    - 7-day blob and container soft delete; no lock and no diagnostic settings (the account is itself a log sink).
  - **A user-assigned identity per region,** `id-flowlogs-defenstack-<env>-<region>`, holds **Storage Blob Data Contributor** on that account only. The flow logs authenticate with it (API version `2024-07-01`; identity support starts at `2024-01-01`).
  - **Flow logs for the hub and spoke VNets,** `<vnet>-flowlog`, are deployed by a module scoped to `NetworkWatcherRG` (`modules/flowLogs.bicep`). It references the existing `NetworkWatcher_<region>`, keeps 90 days, and sends Traffic Analytics to the central workspace every 10 minutes.
  - **The pipeline identity gets Network Contributor on `NetworkWatcherRG`** and nothing else there (`scripts/New-GitHubDeploymentIdentity.ps1 -NetworkWatcherResourceGroupName`, default `NetworkWatcherRG`). It needs no role-assignment rights there.
  - **Network Watcher is not created by the template.** An operator makes sure `NetworkWatcherRG` and `NetworkWatcher_<region>` exist before the identity script and the deployment run (runbook 06 §2, runbook 00b, runbook 01).

  ## Consequences
  - No flow-log write uses a shared key, and the account accepts no public data-plane traffic.
  - `NetworkWatcherRG` holds resources of every environment that shares the subscription, so the flow-log names and deployment names include the environment and region.
  - Two behaviours are first exercised by a live deployment (runbook 06 §9 "Live-only risks"):
    - **The trusted-services exception with public network access fully `Disabled`.** Symptom: 403s in the account's activity log and no `insights-logs-flowlogflowevent` container. Fallback: set `publicNetworkAccess: 'Enabled'` and keep `defaultAction: 'Deny'` with the `AzureServices` bypass. There is still no public data-plane access, because the firewall default is Deny. Record the change here.
    - **Traffic Analytics writing into a workspace with `PrivateOnly` ingestion.** Symptom: `NTANetAnalytics` stays empty after 30 minutes. Fallback: keep the flow logs in storage, turn Traffic Analytics off, and raise it with Microsoft. Do not reopen public ingestion on the workspace without a new ADR.
  - A new identity's role assignment can take minutes to propagate. The first deploy may fail on storage access and succeed on a re-run.

  ## Revisit when
  Microsoft documents whether Traffic Analytics honours AMPLS `PrivateOnly` ingestion, or Phase 7 adds Defender for Storage to the flow-log accounts.
  ```

  Create `docs/decisions/ADR-024-sentinel-content-through-content-hub.md`:

  ```markdown
  # ADR-024: Microsoft Sentinel is onboarded in Bicep; its content comes from Content Hub

  ## Context
  The spec (§3) asks for Microsoft Sentinel on the central workspace, in dev and prod, with connectors for Azure Activity, Azure Firewall, Key Vault, the Front Door WAF, Microsoft Entra ID and Defender for Cloud. Three facts shape the design:
  - The legacy `SecurityInsights` solution resource is being retired. `Microsoft.SecurityInsights/onboardingStates` replaces it.
  - Azure Activity, Firewall, Key Vault and WAF data reaches Sentinel through diagnostic settings, not through a connector resource. Their Content Hub solutions add the parsers, workbooks and analytics rule templates.
  - Content Hub solutions are designed to be installed from the portal. The Entra ID connector needs a tenant administrator, and the tenant-based Defender for Cloud connector works at tenant level, so neither fits a pipeline identity that holds rights on resource groups only.

  ## Decision
  - **Bicep onboards Sentinel:** `Microsoft.SecurityInsights/onboardingStates` `default` (`2024-03-01`, GA), an extension resource on the workspace, in every environment (`modules/monitoring.bicep`).
  - **Bicep sends the data:**
    - the subscription Activity Log goes to the workspace through a diagnostic setting (`modules/activityLog.bicep`, `ADR-025`);
    - Firewall, Key Vault and Front Door WAF logs already flow through their existing diagnostic settings.
  - **Operators install the content by hand from Content Hub,** following runbook 06 §5.1, from a connected network:
    - the Azure Activity, Azure Firewall, Azure Key Vault and Azure Web Application Firewall solutions, then their analytics rule templates;
    - the Microsoft Entra ID connector (a tenant administrator: Security Administrator or Global Administrator);
    - the Tenant-based Microsoft Defender for Cloud connector.
  - No `dataConnectors`, `alertRules` or Content Hub package resources are deployed from this repository.

  ## Consequences
  - The pipeline needs no tenant-level or Sentinel content permissions.
  - Sentinel content is not versioned in Git, and a rebuilt workspace needs the §5.1 steps again. Runbook 06 §6 checks that the solutions and rules are present.
  - Content Hub updates arrive in the portal and are applied by an operator, not by a deployment.
  - Because the workspace query path is private (`ADR-022`), the Sentinel pages work only from the VPN or the jump host.

  ## Revisit when
  The team wants analytics rules as code (Sentinel Repositories or exported rule templates), or Microsoft publishes a supported Bicep path for Content Hub solutions.
  ```

  Create `docs/decisions/ADR-025-preview-api-subscription-diagnostic-setting.md`:

  ```markdown
  # ADR-025: The subscription Activity Log diagnostic setting uses the preview API 2021-05-01-preview

  ## Context
  The README's API version policy asks for the newest stable API version. The subscription Activity Log reaches Log Analytics, and so Sentinel's Azure Activity data, through a diagnostic setting at subscription scope. `Microsoft.Insights/diagnosticSettings` supports subscription scope only from `2021-05-01-preview`. The GA versions (`2016-09-01`, `2015-07-01`) predate subscription scope. The repository's resource-scope diagnostic settings already use the same preview version.

  ## Decision
  - **`modules/activityLog.bicep`** (`targetScope = 'subscription'`) pins `Microsoft.Insights/diagnosticSettings@2021-05-01-preview`. The exception covers this one resource.
  - The setting is named `activity-log-defenstack-<env>`, because dev and prod may share a subscription. It sends all eight Activity Log categories (Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth) to `log-defenstack-<env>`.
  - The pipeline's custom subscription role gains `Microsoft.Insights/diagnosticSettings/read`, `/write` and `/delete`, named explicitly with no wildcard. The identity script updates an existing role in place when its actions differ (runbook 00b).
  - No PSRule or linter suppression is needed: PSRule has no rule for this resource, and the linter's `use-recent-api-versions` rule is off.

  ## Consequences
  - A preview API version can change or be retired with notice. If ARM ever rejects it, create the setting with `az monitor diagnostic-settings subscription create` (runbook 06 §9) and remove the module until a GA version exists.
  - Each subscription allows at most five diagnostic settings. Dev and prod in one subscription use two.

  ## Revisit when
  A GA `Microsoft.Insights/diagnosticSettings` version supports subscription scope. Move to it then, together with the resource-scope settings.
  ```

  Replace `docs/decisions/ADR-021-application-insights-per-region.md` (the decision is now in the past tense and "Revisit when" is done):

  ```markdown
  # ADR-021: One workspace-based Application Insights component per region, Entra ID ingestion only

  ## Context
  The spec (§3) asks for workspace-based Application Insights, ingesting through AMPLS. AMPLS arrives in Phase 6. Telemetry could go to one global component or to one component per region.

  ## Decision
  - **One component per region**, `appi-defenstack-<env>-<region>` (`modules/appInsights.bicep`), in the region's resource group. Each is workspace-based on the shared `log-defenstack-<env>` workspace. The user chose this when Phase 5 was planned.
  - **Key-based ingestion is disabled** (`DisableLocalAuth: true`). Each App Service sends telemetry with its managed identity:
    - app settings `APPLICATIONINSIGHTS_CONNECTION_STRING` and `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`;
    - the **Monitoring Metrics Publisher** role on its own component only (`modules/appInsightsPublisher.bicep`), which the pipeline identity may now delegate.
  - **Public ingestion and query stayed enabled** until Phase 6 added the Azure Monitor Private Link Scope; both are now `Disabled` (`ADR-022`).

  ## Consequences
  - A regional outage takes only that region's component with it. All telemetry still lands in the one workspace, so a cross-region query is a single KQL query filtered by `AppRoleName`.
  - A leaked connection string cannot be used to inject telemetry, because ingestion requires an Entra token for an identity with the publisher role.
  - Until Phase 6, telemetry left the VNet over the public ingestion endpoint, authenticated with Entra ID. From Phase 6 it reaches the components only through the AMPLS private endpoint (`ADR-022`).
  - Telemetry costs are Log Analytics ingestion in the shared workspace; there is no separate App Insights bill.

  ## Revisit when
  Done in Phase 6: both public network access flags are `Disabled` and the components ingest through the Azure Monitor Private Link Scope (`ADR-022`). Revisit if a region gets its own App Insights ingestion path, for example in the Phase 8 failover design.
  ```

- [ ] **Step 5: Update the existing documents**

  Each edit below is an exact find/replace, and the find text occurs once in the file. Apply the edits for a file in the order given. If a find text is not found, stop and report. Change nothing outside the find text. These files contain non-ASCII characters (—, →, ↔, §), so read and write them as UTF-8.

  **`docs/architecture/overview.md`, edit 1 of 8.** Find:

  ```markdown
  # Architecture overview: Phase 1-5 (subscription-scope, multi-region, Premium firewall, admin access, public ingress, app and data resilience)

  > Owning files: `main.bicep`, `modules/global.bicep`, `modules/regionStamp.bicep`, `modules/privateDnsZoneLinks.bicep`, `modules/types.bicep`, `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`, `modules/hubNetwork.bicep`, `modules/bastion.bicep`, `modules/vpnGateway.bicep`, `modules/frontDoor.bicep`. Spec: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §1, §3, §5.

  ```

  Replace with:

  ```markdown
  # Architecture overview: Phase 1-6 (subscription-scope, multi-region, Premium firewall, admin access, public ingress, app and data resilience, private monitoring and detection)

  > Owning files: `main.bicep`, `modules/global.bicep`, `modules/regionStamp.bicep`, `modules/privateDnsZoneLinks.bicep`, `modules/types.bicep`, `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`, `modules/hubNetwork.bicep`, `modules/bastion.bicep`, `modules/vpnGateway.bicep`, `modules/frontDoor.bicep`, `modules/monitorPrivateLinkScope.bicep`, `modules/hubPeering.bicep`, `modules/flowLogs.bicep`, `modules/metricAlerts.bicep`. Spec: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §1, §3, §5.

  ```

  **`docs/architecture/overview.md`, edit 2 of 8.** Find:

  ```markdown

  - A **global layer** (`modules/global.bicep`), deployed once per environment into `rg-defenstack-<env>-global`: the shared Log Analytics workspace and the three `privatelink.*` private DNS zones every region stamp uses.
  - One or two **region stamps** (`modules/regionStamp.bicep`), each a hub/spoke pair with Azure Firewall, private App Service, Key Vault and Storage, deployed into `rg-defenstack-<env>-<regionCode>`:
  ```

  Replace with:

  ```markdown

  - A **global layer** (`modules/global.bicep`), deployed once per environment into `rg-defenstack-<env>-global`: the shared Log Analytics workspace and the shared `privatelink.*` private DNS zones every region stamp uses (three application zones; Phase 6 adds four Azure Monitor zones).
  - One or two **region stamps** (`modules/regionStamp.bicep`), each a hub/spoke pair with Azure Firewall, private App Service, Key Vault and Storage, deployed into `rg-defenstack-<env>-<regionCode>`:
  ```

  **`docs/architecture/overview.md`, edit 3 of 8.** Find:

  ```markdown

  What later phases add (not present after Phase 5):

  ```

  Replace with:

  ```markdown

  **Phase 6** added monitoring, detection and response:
  - Azure Monitor is private-only. One Azure Monitor Private Link Scope per environment, with ingestion and query `PrivateOnly`, scopes the workspace and every Application Insights component. Its single `azuremonitor` private endpoint sits in the primary spoke, and four Azure Monitor zones join the shared zone set (`ADR-022`).
  - Prod with DR peers the two hubs (brought forward from Phase 8). Each `AzureFirewallSubnet` routes the other region's spoke to the other firewall, and the `cross-region-monitoring` rules let only the East US App Service and management subnets reach the AMPLS endpoint (`ADR-022`).
  - VNet flow logs with Traffic Analytics, per region, write with a managed identity to a keyless regional account, under `NetworkWatcher_<region>` in `NetworkWatcherRG` (`ADR-023`).
  - The subscription Activity Log goes to the workspace (`ADR-025`), Microsoft Sentinel is onboarded, and its content comes from Content Hub (`ADR-024`).
  - One action group per environment emails `ALERT_EMAIL`; metric alerts cover the firewall, App Service, Key Vault, the VPN gateway and Front Door, plus Service Health.

  See [runbook 06](../runbooks/06-monitoring-and-sentinel.md).

  What later phases add (not present after Phase 6):

  ```

  **`docs/architecture/overview.md`, edit 4 of 8.** Find:

  ```markdown
  |---|---|
  | 6 | Azure Monitor Private Link Scope (AMPLS), alerts, Microsoft Sentinel |
  | 7 | Microsoft Defender for Cloud plans, Azure Policy assignments |
  | 8 | Recovery Services vaults, hub-to-hub peering, the regional-failover runbook |

  ```

  Replace with:

  ```markdown
  |---|---|
  | 7 | Microsoft Defender for Cloud plans, Azure Policy assignments |
  | 8 | Recovery Services vaults and the backup job alert, DR traffic over the hub-to-hub peering (Phase 6 carries only monitoring), the regional-failover runbook |

  ```

  **`docs/architecture/overview.md`, edit 5 of 8.** Find:

  ```markdown

  ### Admin access
  ```

  Replace with:

  ````markdown

  ### Monitoring (Phase 6)

  Telemetry and queries reach Azure Monitor only through the AMPLS endpoint (`ADR-022`); full procedures are in [runbook 06](../runbooks/06-monitoring-and-sentinel.md).

  ```mermaid
  flowchart LR
      subgraph WUS3["West US 3 (primary)"]
          APP1["App Service and jump host"]
          FW1["Firewall (Host: application rule, SNAT)"]
          PE["AMPLS private endpoint (private-endpoints subnet)"]
      end
      subgraph EUS["East US (prod with DR)"]
          APP2["App Service and jump host"]
          FW2["Firewall (Client: network rule)"]
      end
      subgraph GLOBAL["rg-defenstack-env-global"]
          AMPLS["AMPLS (PrivateOnly)"]
          WS["Log Analytics workspace + Sentinel"]
          AI["App Insights components (one per region)"]
      end
      APP1 -->|"HTTPS, private DNS"| PE
      APP2 --> FW2
      FW2 -->|"hub-to-hub peering"| FW1
      FW1 --> PE
      PE --> AMPLS
      AMPLS --> WS
      AMPLS --> AI
      DIAG["Diagnostic settings, Activity Log, flow logs (Traffic Analytics)"] -.->|"Azure internal path"| WS
  ```

  - VPN clients and the jump host resolve the Azure Monitor names through the firewall DNS proxy, so operators query and use Sentinel from there; nothing else can.
  - Diagnostic settings, the subscription Activity Log and Traffic Analytics write over Azure's own path, not through the endpoint.

  ### Admin access
  ````

  **`docs/architecture/overview.md`, edit 6 of 8.** Find:

  ```markdown
  |---|---|
  | `rg-defenstack-dev-global` | Log Analytics workspace `log-defenstack-dev` (`replication.enabled: false`); private DNS zones `privatelink.blob...`, `privatelink.azurewebsites.net`, `privatelink.vaultcore.azure.net`, each with 2 VNet links (dev-wus3 hub and spoke); Front Door Premium `afd-defenstack-dev` (endpoint `fde-defenstack-dev`, origin `app-wus3`, route `app`, security policy `waf`) and WAF policy `wafdefenstackdev` |
  | `rg-defenstack-dev-wus3` | Hub VNet with `AzureFirewallSubnet`, `AzureBastionSubnet` (Bastion NSG) and `GatewaySubnet` (route table spoke → firewall), DNS server = firewall IP; Bastion Standard `bas-defenstack-dev-wus3` and active-active VPN gateway `vpng-defenstack-dev-wus3` (`VpnGw1AZ`, `ADR-015`) with three public IPs and a gateway maintenance configuration; Firewall **Premium** `afw-defenstack-dev-wus3` (zones 1/2/3, IDPS `Alert`, `threatIntelMode: Alert`, `ADR-003`); firewall policy with four rule collection groups — `dns-egress`, `admin-access`, `platform-egress`, and `approved-https-egress` when `allowedOutboundFqdns` is non-empty (`ADR-010`) — and public IP; spoke VNet with `private-endpoints`, `appservice-integration`, `management` subnets, their NSGs, and two route tables (App Service and management egress through the firewall); App Service Plan `asp-defenstack-dev-wus3` (S1-equivalent, 1 instance, non-zonal); App Service with system-assigned identity and private endpoint; Key Vault (RBAC, purge protection on, 90-day soft delete) with private endpoint; Storage account (`Standard_LRS`) with private endpoint; Application Insights `appi-defenstack-dev-wus3` (workspace-based, Entra ID ingestion only); hub↔spoke peering with gateway transit; when `enableVirtualMachine = true`, the jump host (zone 1, Entra login extension, Update Manager schedule `<vm>-patch`) |

  ```

  Replace with:

  ```markdown
  |---|---|
  | `rg-defenstack-dev-global` | Log Analytics workspace `log-defenstack-dev` (`replication.enabled: false`); private DNS zones `privatelink.blob...`, `privatelink.azurewebsites.net`, `privatelink.vaultcore.azure.net` and the four Azure Monitor zones (`privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net`), each with 2 VNet links (dev-wus3 hub and spoke); Microsoft Sentinel on the workspace (public ingestion and query `Disabled`); AMPLS `ampls-defenstack-dev` (`PrivateOnly`); action group `ag-defenstack-dev`; Front Door alerts `alert-defenstack-dev-front-door-origin-health` and `-waf-blocks`; Service Health alert `alert-defenstack-dev-service-health`; Front Door Premium `afd-defenstack-dev` (endpoint `fde-defenstack-dev`, origin `app-wus3`, route `app`, security policy `waf`) and WAF policy `wafdefenstackdev` |
  | `rg-defenstack-dev-wus3` | Hub VNet with `AzureFirewallSubnet`, `AzureBastionSubnet` (Bastion NSG) and `GatewaySubnet` (route table spoke → firewall), DNS server = firewall IP; Bastion Standard `bas-defenstack-dev-wus3` and active-active VPN gateway `vpng-defenstack-dev-wus3` (`VpnGw1AZ`, `ADR-015`) with three public IPs and a gateway maintenance configuration; Firewall **Premium** `afw-defenstack-dev-wus3` (zones 1/2/3, IDPS `Alert`, `threatIntelMode: Alert`, `ADR-003`); firewall policy with four rule collection groups — `dns-egress`, `admin-access`, `platform-egress`, and `approved-https-egress` when `allowedOutboundFqdns` is non-empty (`ADR-010`) — and public IP; spoke VNet with `private-endpoints`, `appservice-integration`, `management` subnets, their NSGs, and two route tables (App Service and management egress through the firewall); App Service Plan `asp-defenstack-dev-wus3` (S1-equivalent, 1 instance, non-zonal); App Service with system-assigned identity and private endpoint; Key Vault (RBAC, purge protection on, 90-day soft delete) with private endpoint; Storage account (`Standard_LRS`) with private endpoint; Application Insights `appi-defenstack-dev-wus3` (workspace-based, Entra ID ingestion only, public access `Disabled`); AMPLS private endpoint `ampls-defenstack-dev-pe` in `private-endpoints`; flow-log account `stflwus3…` (LRS, keyless) and identity `id-flowlogs-defenstack-dev-wus3`; seven metric alerts `alert-defenstack-dev-wus3-*`; hub↔spoke peering with gateway transit; when `enableVirtualMachine = true`, the jump host (zone 1, Entra login extension, Update Manager schedule `<vm>-patch`) |

  ```

  **`docs/architecture/overview.md`, edit 7 of 8.** Find:

  ```markdown
  |---|---|
  | `rg-defenstack-prod-global` | Log Analytics workspace `log-defenstack-prod` (`replication.enabled: true, location: eastus`); the same three private DNS zones, each with 4 VNet links (wus3 hub, wus3 spoke, eus hub, eus spoke); Front Door Premium `afd-defenstack-prod` with origins `app-wus3` (priority 1) and `app-eus` (priority 2), and WAF policy `wafdefenstackprod`; `enableDeleteLock: true` on the zones, the workspace, the Front Door profile and the WAF policy |
  | `rg-defenstack-prod-wus3` (primary) | Same shape as dev's region resource group, but: VPN gateway `VpnGw2AZ`; Firewall Premium with IDPS `Deny`, `threatIntelMode: Deny`; App Service Plan `asp-defenstack-prod-wus3` zone-redundant, 3 instances (`isProd && isPrimary`); Storage account `Standard_RAGZRS` (`ADR-020`), with a Storage Blob Data Reader assignment on `def-blob` for the East US App Service; `enableDeleteLock: true` on the hub VNet, spoke VNet, Key Vault, firewall, firewall policy, and firewall public IP |
  | `rg-defenstack-prod-eus` (secondary, warm standby) | Same resource types as `rg-defenstack-prod-wus3`, deployed only when `deploySecondaryRegion = true`, except Bastion and the VPN gateway (their subnets exist; the resources arrive with `deploySecondaryAdminAccess = true` during failover): App Service Plan `asp-defenstack-prod-eus`, 1 instance, non-zonal (no scale-out until failover, `ADR-008`); Storage account `Standard_GRS`; private endpoint `<primary account>-secondary-pe` on the primary account's read-only secondary (`blob_secondary`); hub↔spoke peering local to this region; `enableDeleteLock: true` on the same set of resources as the primary (hub VNet, spoke VNet, Key Vault, firewall, firewall policy, firewall public IP) |

  ```

  Replace with:

  ```markdown
  |---|---|
  | `rg-defenstack-prod-global` | Log Analytics workspace `log-defenstack-prod` (`replication.enabled: true, location: eastus`); the same seven private DNS zones, each with 4 VNet links (wus3 hub, wus3 spoke, eus hub, eus spoke); Sentinel, AMPLS `ampls-defenstack-prod`, action group `ag-defenstack-prod` and the global alerts, as in dev; Front Door Premium `afd-defenstack-prod` with origins `app-wus3` (priority 1) and `app-eus` (priority 2), and WAF policy `wafdefenstackprod`; `enableDeleteLock: true` on the zones, the workspace, the Front Door profile and the WAF policy |
  | `rg-defenstack-prod-wus3` (primary) | Same shape as dev's region resource group, but: VPN gateway `VpnGw2AZ`; Firewall Premium with IDPS `Deny`, `threatIntelMode: Deny`; App Service Plan `asp-defenstack-prod-wus3` zone-redundant, 3 instances (`isProd && isPrimary`); Storage account `Standard_RAGZRS` (`ADR-020`), with a Storage Blob Data Reader assignment on `def-blob` for the East US App Service; the AMPLS endpoint `ampls-defenstack-prod-pe`; flow-log account `stflwus3…` (ZRS); hub peering `hub-to-eus-hub` and route table `vnet-defenstack-prod-wus3-hub-firewall-rt`; rule collection group `cross-region-monitoring` (Host); the private-endpoint NSG also admits its own `AzureFirewallSubnet`; `enableDeleteLock: true` on the hub VNet, spoke VNet, Key Vault, firewall, firewall policy, and firewall public IP |
  | `rg-defenstack-prod-eus` (secondary, warm standby) | Same resource types as `rg-defenstack-prod-wus3`, deployed only when `deploySecondaryRegion = true`, except Bastion and the VPN gateway (their subnets exist; the resources arrive with `deploySecondaryAdminAccess = true` during failover): App Service Plan `asp-defenstack-prod-eus`, 1 instance, non-zonal (no scale-out until failover, `ADR-008`); Storage account `Standard_GRS`; private endpoint `<primary account>-secondary-pe` on the primary account's read-only secondary (`blob_secondary`); hub↔spoke peering local to this region; hub peering `hub-to-wus3-hub`, route table `vnet-defenstack-prod-eus-hub-firewall-rt` and `cross-region-monitoring` (Client); flow-log account `stfleus…` (ZRS); seven metric alerts (six until the VPN gateway is deployed); `enableDeleteLock: true` on the same set of resources as the primary (hub VNet, spoke VNet, Key Vault, firewall, firewall policy, firewall public IP) |

  ### NetworkWatcherRG (shared by every environment in the subscription)

  | Resource group | Contents |
  |---|---|
  | `NetworkWatcherRG` | `NetworkWatcher_westus3` and `NetworkWatcher_eastus` (created by Azure or by an operator, never by this template); under them, the flow logs `<vnet>-flowlog` for every deployed hub and spoke. The pipeline identities hold `Network Contributor` here (`ADR-023`) |

  The subscription also holds the diagnostic setting `activity-log-defenstack-<env>` (`ADR-025`).

  ```

  **`docs/architecture/overview.md`, edit 8 of 8.** Find:

  ```markdown
  - [ADR-021: One workspace-based Application Insights component per region, Entra ID ingestion only](../decisions/ADR-021-application-insights-per-region.md)

  ```

  Replace with:

  ```markdown
  - [ADR-021: One workspace-based Application Insights component per region, Entra ID ingestion only](../decisions/ADR-021-application-insights-per-region.md)
  - [ADR-022: Azure Monitor is private-only through one AMPLS, and hub-to-hub peering moves to Phase 6](../decisions/ADR-022-private-only-monitoring-and-hub-peering.md)
  - [ADR-023: VNet flow logs write with a managed identity to a regional keyless account, from NetworkWatcherRG](../decisions/ADR-023-flow-log-identity-and-network-watcher.md)
  - [ADR-024: Microsoft Sentinel is onboarded in Bicep; its content comes from Content Hub](../decisions/ADR-024-sentinel-content-through-content-hub.md)
  - [ADR-025: The subscription Activity Log diagnostic setting uses the preview API 2021-05-01-preview](../decisions/ADR-025-preview-api-subscription-diagnostic-setting.md)

  ```

  **`docs/cost.md`, edit 1 of 2.** Find:

  ```markdown

  ## Dominant future cost drivers
  ```

  Replace with:

  ```markdown

  ## Phase 6 delta
  Phase 6 adds private-only Azure Monitor, flow logs with Traffic Analytics,
  Microsoft Sentinel, alerts and, in prod with DR, hub-to-hub global peering.
  As with every phase, **fill in the actual dollar estimate from the Pricing
  Calculator; do not invent prices.**

  | Environment | Cost driver | What changed / why it costs more |
  |---|---|---|
  | Both | Microsoft Sentinel ingestion | Sentinel bills per GB analysed on top of Log Analytics ingestion, for every table in `log-defenstack-<env>` (`ADR-024`). Retention stays 90 days, which Sentinel includes. Measure with `Usage \| where IsBillable \| summarize sum(Quantity) by DataType` |
  | Both | Activity Log ingestion | `AzureActivity` is free to ingest into Log Analytics; it adds Sentinel analysis only |
  | Both | Traffic Analytics | Per GB of flow-log data processed, per region, every 10 minutes (`ADR-023`); `NTANetAnalytics` ingestion is billed as Log Analytics data |
  | Both | VNet flow logs and flow-log storage | Flow logs are billed per GB collected; the flow-log storage account per region holds 90 days (prod `Standard_ZRS`, dev `Standard_LRS`), plus transactions |
  | Both | AMPLS private endpoint ×1 | The AMPLS itself is free; its one private endpoint is billed hourly and per GB processed, which is all workspace and App Insights ingestion and query traffic (`ADR-022`) |
  | Both | Private DNS zones ×4 and their VNet links | Four more zones (monitor, oms, ods, agentsvc), billed per zone per month, plus their VNet links (dev 2 per zone, prod 4) and queries |
  | Prod | Global VNet peering, hub to hub | Billed per GB in **both** directions between West US 3 and East US. Only East US telemetry crosses (`ADR-022`); measure with the peering's bytes metrics |
  | Prod | Firewall data processing | East US telemetry now crosses both firewalls, so it is processed twice |
  | Both | Alert rules | Each metric alert rule is billed per monitored time series per month (seven per region, two for Front Door); the Service Health activity log alert and the action group's email notifications are free up to the monthly allowance |
  | Both | Backup job alert | Not deployed until Phase 8 |

  **Estimate:** fill in from the Pricing Calculator (Microsoft Sentinel and
  Log Analytics: pay-as-you-go GB per day from a week of dev `Usage`; Network
  Watcher: flow logs collected and Traffic Analytics processed; Storage: ZRS and
  LRS block blob for 90 days of flow logs; Private Link: one endpoint; Azure
  DNS: four private zones; Virtual Network: global peering GB both ways;
  Azure Monitor: metric alert rules).

  ## Dominant future cost drivers
  ```

  **`docs/cost.md`, edit 2 of 2.** Find:

  ```markdown
  The VPN gateway and Azure Bastion arrived in Phase 3, and Azure Front Door
  Premium in Phase 4 (see their deltas):
  - Microsoft Sentinel ingestion
  ```

  Replace with:

  ```markdown
  The VPN gateway and Azure Bastion arrived in Phase 3, and Azure Front Door
  Premium in Phase 4, and Microsoft Sentinel in Phase 6 (see their deltas):
  - Microsoft Sentinel ingestion
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 1 of 15.** Find:

  ```markdown
  | Microsoft Entra ID | One app registration and service principal per environment name (`gh-Godson90-bicep-dev-deploy`, `gh-Godson90-bicep-prod-deploy`) — dev's app gets **two** federated credentials (`github-dev`, `github-dev-plan`); prod's app gets **one** (`github-prod`, since there is no `prod-plan` environment) |
  | Azure RBAC, at subscription scope | Custom role `DefenStack Subscription Deployment Operator` (deployment read/write/validate/whatIf, deployment-operation read, subscription and resource-group read, subscription operation-results read — no resource rights, and deliberately no deployment delete/cancel/exportTemplate), assigned to the identity |
  | Azure RBAC, on `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3` only | `Contributor`; `Role Based Access Control Administrator` with a condition that allows assigning only `Storage Blob Data Contributor` |
  ```

  Replace with:

  ```markdown
  | Microsoft Entra ID | One app registration and service principal per environment name (`gh-Godson90-bicep-dev-deploy`, `gh-Godson90-bicep-prod-deploy`) — dev's app gets **two** federated credentials (`github-dev`, `github-dev-plan`); prod's app gets **one** (`github-prod`, since there is no `prod-plan` environment) |
  | Azure RBAC, at subscription scope | Custom role `DefenStack Subscription Deployment Operator` (deployment read/write/validate/whatIf, deployment-operation read, subscription and resource-group read, subscription operation-results read, and from Phase 6 `Microsoft.Insights/diagnosticSettings/read`, `/write` and `/delete` for the subscription Activity Log setting — no other resource rights, and deliberately no deployment delete/cancel/exportTemplate), assigned to the identity |
  | Azure RBAC, on `NetworkWatcherRG` (Phase 6) | `Network Contributor`, so the pipeline can manage the VNet flow logs under `NetworkWatcher_<region>` (`ADR-023`). Nothing else at that scope |
  | Azure RBAC, on `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3` only | `Contributor`; `Role Based Access Control Administrator` with a condition that allows assigning only `Storage Blob Data Contributor` |
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 2 of 15.** Find:

  ```markdown
  | Resource groups `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3` exist | `az group show -n rg-defenstack-dev-global --query name -o tsv`; `az group show -n rg-defenstack-dev-wus3 --query name -o tsv` |
  | GitHub admin access to `Godson90/bicep` (needed for **Settings** → **Environments**) | Repository page shows the **Settings** tab |
  ```

  Replace with:

  ```markdown
  | Resource groups `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3` exist | `az group show -n rg-defenstack-dev-global --query name -o tsv`; `az group show -n rg-defenstack-dev-wus3 --query name -o tsv` |
  | **`NetworkWatcherRG` and `NetworkWatcher_<region>` exist (Phase 6)**, before the script runs: the script assigns Network Contributor on `NetworkWatcherRG` and fails if it does not exist. Azure normally creates them with the first VNet in a region; if not, an operator creates them: `az group create --name NetworkWatcherRG --location westus3` (only if missing), then `az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true` | `az network watcher list --query "[].{name:name, rg:resourceGroup}" -o table` lists `NetworkWatcher_westus3` (and `NetworkWatcher_eastus` for prod) in `NetworkWatcherRG` |
  | GitHub admin access to `Godson90/bicep` (needed for **Settings** → **Environments**) | Repository page shows the **Settings** tab |
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 3 of 15.** Find:

  ```markdown
  | `KEYVAULT_SECRETS_JSON` | `{}` until the app has secrets | GitHub **environment secret** on `dev` and `prod`, read only by the `apply` job (runbook 05 §5.1, `ADR-019`) | **Yes**: create it as a secret, never a variable |

  ```

  Replace with:

  ```markdown
  | `KEYVAULT_SECRETS_JSON` | `{}` until the app has secrets | GitHub **environment secret** on `dev` and `prod`, read only by the `apply` job (runbook 05 §5.1, `ADR-019`) | **Yes**: create it as a secret, never a variable |
  | `ALERT_EMAIL` (Phase 6) | The platform alert mailbox | GitHub **environment variable** on `dev`, `dev-plan` and `prod`; passed as `alertEmail` to validate, what-if and deploy. The prod `apply` fails early when it is empty (runbook 06 §4 step 3) | No |
  | `-NetworkWatcherResourceGroupName` (Phase 6) | `NetworkWatcherRG` (default) | Script parameter: where Network Contributor is assigned. Same name-pattern validation as `-ResourceGroupNames` | No |

  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 4 of 15.** Find:

  ```markdown
     - **two** federated credentials: subject `repo:Godson90/bicep:environment:dev` (`github-dev`) and subject `repo:Godson90/bicep:environment:dev-plan` (`github-dev-plan`) — the script creates one credential per entry in `$credentialEnvironments`, which is `@($EnvironmentName, "$EnvironmentName-plan")` only when `$EnvironmentName` is in the script's `$ungatedPlanEnvironments` allowlist (today, only `dev`); every other environment name — `prod`, or a future environment such as `staging` — gets just `@($EnvironmentName)`, fail closed, with no ungated `-plan` credential unless explicitly added to that allowlist
     - the custom role `DefenStack Subscription Deployment Operator`
     - assigning `DefenStack Subscription Deployment Operator` at subscription scope
  ```

  Replace with:

  ```markdown
     - **two** federated credentials: subject `repo:Godson90/bicep:environment:dev` (`github-dev`) and subject `repo:Godson90/bicep:environment:dev-plan` (`github-dev-plan`) — the script creates one credential per entry in `$credentialEnvironments`, which is `@($EnvironmentName, "$EnvironmentName-plan")` only when `$EnvironmentName` is in the script's `$ungatedPlanEnvironments` allowlist (today, only `dev`); every other environment name — `prod`, or a future environment such as `staging` — gets just `@($EnvironmentName)`, fail closed, with no ungated `-plan` credential unless explicitly added to that allowlist
     - the custom role `DefenStack Subscription Deployment Operator`: `Create custom role` the first time; `Update custom role actions` when the role exists from an earlier phase with different actions (see "Custom role update" below); nothing when it already has the 12 actions
     - assigning `DefenStack Subscription Deployment Operator` at subscription scope
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 5 of 15.** Find:

  ```markdown
     - `Contributor` and `Role Based Access Control Administrator` on `rg-defenstack-dev-wus3`

  ```

  Replace with:

  ```markdown
     - `Contributor` and `Role Based Access Control Administrator` on `rg-defenstack-dev-wus3`
     - `Network Contributor` on `/subscriptions/<sub>/resourceGroups/NetworkWatcherRG` (Phase 6); the banner line `Flow-log scope (Network Contributor): …` shows the scope

     **Custom role update (Phase 6).** Earlier versions of the script returned early when the role existed, so a role created before Phase 6 lacks the `Microsoft.Insights/diagnosticSettings/*` actions. The script now reads the existing role (`az role definition list --name <role> --custom-role-only true --output json`), compares its actions with the expected list (ignoring order and case), and only when they differ runs `az role definition update` with the role's ID, name, description, the full action list and the subscription as the only assignable scope. A role that already matches is left alone, and `-WhatIf` reports the update without making it. Updating a role definition needs `Owner` or `User Access Administrator` at subscription scope (§2), and takes a few minutes to propagate. Dev and prod share the role, so the first environment's run updates it for both.

  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 6 of 15.** Find:

  ```markdown
          "Name": "DefenStack Subscription Deployment Operator",
          "Description": "Run subscription-scope ARM deployments (validate, what-if, create) and read resource groups. Grants no resource permissions and cannot cancel or delete deployments.",
          "Actions": [
  ```

  Replace with:

  ```markdown
          "Name": "DefenStack Subscription Deployment Operator",
          "Description": "Run subscription-scope ARM deployments (validate, what-if, create), read resource groups, and manage the subscription Activity Log diagnostic setting. Grants no other resource permissions and cannot cancel or delete deployments.",
          "Actions": [
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 7 of 15.** Find:

  ```markdown
            "Microsoft.Resources/subscriptions/resourceGroups/read",
            "Microsoft.Resources/subscriptions/operationresults/read"
          ],
  ```

  Replace with:

  ```markdown
            "Microsoft.Resources/subscriptions/resourceGroups/read",
            "Microsoft.Resources/subscriptions/operationresults/read",
            "Microsoft.Insights/diagnosticSettings/read",
            "Microsoft.Insights/diagnosticSettings/write",
            "Microsoft.Insights/diagnosticSettings/delete"
          ],
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 8 of 15.** Find:

  ```markdown

        Alternative: use the **Permissions** tab and add these nine actions individually (search each by name): `Microsoft.Resources/deployments/read`, `Microsoft.Resources/deployments/write`, `Microsoft.Resources/deployments/validate/action`, `Microsoft.Resources/deployments/whatIf/action`, `Microsoft.Resources/deployments/operations/read`, `Microsoft.Resources/deployments/operationstatuses/read`, `Microsoft.Resources/subscriptions/read`, `Microsoft.Resources/subscriptions/resourceGroups/read`, `Microsoft.Resources/subscriptions/operationresults/read`. Do **not** add `deployments/delete`, `deployments/cancel/action` or `deployments/exportTemplate/action` — none is needed to validate, what-if or create a deployment, and because this role is assigned at subscription scope, granting them would let this identity cancel or delete another environment's in-flight deployments or export its templates. Leave **Assignable scopes** at the subscription (do not narrow it further; the script assigns it there too).
     3. Back on the subscription's **Access control (IAM)** → **Add** → **Add role assignment** → select **DefenStack Subscription Deployment Operator** → **Members**: `gh-Godson90-bicep-dev-deploy` → **Review + assign**.
  ```

  Replace with:

  ```markdown

        Alternative: use the **Permissions** tab and add these twelve actions individually (search each by name): `Microsoft.Resources/deployments/read`, `Microsoft.Resources/deployments/write`, `Microsoft.Resources/deployments/validate/action`, `Microsoft.Resources/deployments/whatIf/action`, `Microsoft.Resources/deployments/operations/read`, `Microsoft.Resources/deployments/operationstatuses/read`, `Microsoft.Resources/subscriptions/read`, `Microsoft.Resources/subscriptions/resourceGroups/read`, `Microsoft.Resources/subscriptions/operationresults/read`, `Microsoft.Insights/diagnosticSettings/read`, `Microsoft.Insights/diagnosticSettings/write`, `Microsoft.Insights/diagnosticSettings/delete`. If the role already exists from an earlier phase, open it → **Edit** → **JSON** and replace `Actions` with the list above. Do **not** add `deployments/delete`, `deployments/cancel/action` or `deployments/exportTemplate/action` — none is needed to validate, what-if or create a deployment, and because this role is assigned at subscription scope, granting them would let this identity cancel or delete another environment's in-flight deployments or export its templates. Leave **Assignable scopes** at the subscription (do not narrow it further; the script assigns it there too).
     3. Back on the subscription's **Access control (IAM)** → **Add** → **Add role assignment** → select **DefenStack Subscription Deployment Operator** → **Members**: `gh-Godson90-bicep-dev-deploy` → **Review + assign**.
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 9 of 15.** Find:

  ```markdown

  ### Step 3 - Verify the Azure side (both methods)
  ```

  Replace with:

  ```markdown

  6. **Network Contributor on `NetworkWatcherRG` (Phase 6).** `NetworkWatcherRG` → **Access control (IAM)** → **Add role assignment** → role **Network Contributor** → member `gh-Godson90-bicep-dev-deploy` → **Review + assign**. Do not add any other role there.

  ### Step 3 - Verify the Azure side (both methods)
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 10 of 15.** Find:

  ```markdown
    --query "[].{role:roleDefinitionName,scope:scope,hasCondition:condition!=null}" -o table
  az role definition list --name "DefenStack Subscription Deployment Operator" --custom-role-only true `
  ```

  Replace with:

  ```markdown
    --query "[].{role:roleDefinitionName,scope:scope,hasCondition:condition!=null}" -o table
  az role assignment list --assignee $spId --resource-group NetworkWatcherRG `
    --query "[].{role:roleDefinitionName,scope:scope}" -o table
  az role definition list --name "DefenStack Subscription Deployment Operator" --custom-role-only true `
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 11 of 15.** Find:

  ```markdown

  The last command is a drift check: it must return exactly the 9 actions in §1 above (no more, no fewer). A role created before `Microsoft.Resources/subscriptions/operationresults/read` was added will be missing that action (§9).

  ```

  Replace with:

  ```markdown

  The last command is a drift check: it must return exactly the 12 actions in the Method B JSON above (no more, no fewer). A role created before Phase 6 is missing the three `Microsoft.Insights/diagnosticSettings/*` actions until the script is re-run (Step 2, "Custom role update").

  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 12 of 15.** Find:

  ```markdown

  Nothing else is expected at any of these three scopes.

  ```

  Replace with:

  ```markdown

  - Exactly one role assignment at `/subscriptions/<sub>/resourceGroups/NetworkWatcherRG`: `Network Contributor` (Phase 6).

  Nothing else is expected at any of these four scopes.

  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 13 of 15.** Find:

  ```markdown
    3. Create the GitHub environment `prod` with **Required reviewers** (at least 1, and name at least one reviewer other than the person who is expected to dispatch the run) and **Deployment branches and tags: Selected branches → `main`**. On the same required-reviewers rule, also enable **Prevent self-review**. Without it, the person who dispatches a prod `deploy` run can approve their own `plan` and `apply` jobs, and the "two approvals" in `ADR-012` collapse into one person clicking approve twice — Prevent self-review is what makes the two approvals a real separation-of-duties control, not just two clicks. **Do not create a `prod-plan` environment** — `deploy.yml`'s `plan` job already runs in `prod` for a prod deploy, so `prod-plan` would either duplicate `prod` pointlessly or, if left without reviewers, create an ungated prod credential (§1a).
    4. Add the three `AZURE_*` variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) to the `prod` environment, exactly as in Step 4 above but for `prod`.
    5. **Prod deploys need two approvals.** When `deploy` runs with `environment=prod`: a reviewer approves the `plan` job, which runs validate + what-if against prod; the reviewer (or another reviewer) then reads that what-if — the `GITHUB_STEP_SUMMARY` job summary, or the `whatif-prod` artifact (kept 14 days) — before approving `apply`, which actually deploys. Neither approval can be skipped; both gate the same `prod` environment.
  ```

  Replace with:

  ```markdown
    3. Create the GitHub environment `prod` with **Required reviewers** (at least 1, and name at least one reviewer other than the person who is expected to dispatch the run) and **Deployment branches and tags: Selected branches → `main`**. On the same required-reviewers rule, also enable **Prevent self-review**. Without it, the person who dispatches a prod `deploy` run can approve their own `plan` and `apply` jobs, and the "two approvals" in `ADR-012` collapse into one person clicking approve twice — Prevent self-review is what makes the two approvals a real separation-of-duties control, not just two clicks. **Do not create a `prod-plan` environment** — `deploy.yml`'s `plan` job already runs in `prod` for a prod deploy, so `prod-plan` would either duplicate `prod` pointlessly or, if left without reviewers, create an ungated prod credential (§1a).
    4. Add the three `AZURE_*` variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) to the `prod` environment, exactly as in Step 4 above but for `prod`. From Phase 6, also add `ALERT_EMAIL` to `prod` (and to `dev` and `dev-plan`); the prod `apply` refuses to run without it (runbook 06 §4 step 3).
    5. **Prod deploys need two approvals.** When `deploy` runs with `environment=prod`: a reviewer approves the `plan` job, which runs validate + what-if against prod; the reviewer (or another reviewer) then reads that what-if — the `GITHUB_STEP_SUMMARY` job summary, or the `whatif-prod` artifact (kept 14 days) — before approving `apply`, which actually deploys. Neither approval can be skipped; both gate the same `prod` environment.
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 14 of 15.** Find:

  ```markdown
    Accepted limitation: the ABAC condition restricts *which role IDs* the pipeline identity can assign, not *which principal* it assigns them to or *at which resource* inside its resource groups. This is accepted because the identity is already `Contributor` on those resource groups (spec §3 "a condition that restricts which roles it can assign").
  - **Quarterly review:** re-run Step 3, including the role-definition drift check. The role list must be unchanged at all three scopes, the credential list must be empty, and the custom role's actions must still be exactly the 9 listed in §1.

  ```

  Replace with:

  ```markdown
    Accepted limitation: the ABAC condition restricts *which role IDs* the pipeline identity can assign, not *which principal* it assigns them to or *at which resource* inside its resource groups. This is accepted because the identity is already `Contributor` on those resource groups (spec §3 "a condition that restricts which roles it can assign").
  - **Adding actions to the custom subscription role** (Phase 6 added the three diagnostic-setting actions): change the list in step 4 of the script and in `tests/Scripts.Tests.ps1`, then re-run the script as `Owner` or `User Access Administrator`. It updates the existing role in place with `az role definition update` when the actions differ (Step 2, "Custom role update"); no delete is needed.
  - **Quarterly review:** re-run Step 3, including the role-definition drift check. The role list must be unchanged at all four scopes, the credential list must be empty, and the custom role's actions must still be exactly the 12 listed in Step 2 Method B.

  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 15 of 15.** Find:

  ```markdown
  | `AuthorizationFailed … Microsoft.Resources/deployments/write … /subscriptions/<id>` | The subscription-scope `DefenStack Subscription Deployment Operator` role assignment is missing | Step 3 subscription-scope role query; re-run the script, or add the assignment manually (Method B step 3) |
  | `AuthorizationFailed … Microsoft.Resources/subscriptions/operationresults/read` | The custom role predates this action (created before it was added to the 9-action set) | Update the role definition in place: `az role definition update --role-definition <updated-json-with-9-actions>`, or delete and let the script recreate it |
  | `AuthorizationFailed … Microsoft.Resources/deployments/whatIf/action` | `Contributor` missing on the target resource group, or not yet propagated | Step 3 resource-group role query; add `Contributor` |
  ```

  Replace with:

  ```markdown
  | `AuthorizationFailed … Microsoft.Resources/deployments/write … /subscriptions/<id>` | The subscription-scope `DefenStack Subscription Deployment Operator` role assignment is missing | Step 3 subscription-scope role query; re-run the script, or add the assignment manually (Method B step 3) |
  | `AuthorizationFailed … Microsoft.Resources/subscriptions/operationresults/read` or `… Microsoft.Insights/diagnosticSettings/write` | The custom role predates the action (created by an earlier version of the script) | Re-run the script as `Owner` or `User Access Administrator`: it runs `az role definition update` with the full 12-action list (Step 2, "Custom role update"). Wait up to 10 minutes for propagation |
  | Script: `Could not read the custom role '…'` or `Failed to query the custom role '…'` | `az role definition list` failed or returned something other than JSON (an old CLI, or a sign-in problem) | Run `az role definition list --name "DefenStack Subscription Deployment Operator" --custom-role-only true --output json` by hand and fix what it reports |
  | Script: `Failed to update the custom role '…'` | The operator lacks `Microsoft.Authorization/roleDefinitions/write` | Re-run as `Owner` or `User Access Administrator` at subscription scope (§2) |
  | Script fails assigning `Network Contributor` with `ResourceGroupNotFound` or a scope error for `NetworkWatcherRG` | Network Watcher was never created in the subscription | Create it (§2, the `NetworkWatcherRG` row), then re-run |
  | `AuthorizationFailed … Microsoft.Network/networkWatchers/flowLogs/write` | `Network Contributor` on `NetworkWatcherRG` is missing | Re-run the script (Phase 6), or Method B step 6 |
  | `AuthorizationFailed … Microsoft.Resources/deployments/whatIf/action` | `Contributor` missing on the target resource group, or not yet propagated | Step 3 resource-group role query; add `Contributor` |
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 1 of 5.** Find:

  ```markdown

  - The global layer (`modules/global.bicep`) in `rg-defenstack-<env>-global`: the Log Analytics workspace and the three shared private DNS zones.
  - The primary region stamp (`modules/regionStamp.bicep`), always, in `rg-defenstack-<env>-wus3`.
  ```

  Replace with:

  ```markdown

  - The global layer (`modules/global.bicep`) in `rg-defenstack-<env>-global`: the Log Analytics workspace and the shared private DNS zones (three application zones, plus the four Azure Monitor zones from Phase 6).
  - The primary region stamp (`modules/regionStamp.bicep`), always, in `rg-defenstack-<env>-wus3`.
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 2 of 5.** Find:

  ```markdown

    Expect `Registered` for all six.
  - **EncryptionAtHost**, only if a VM is enabled (`enableVirtualMachine = true`): register once per subscription, then wait for `Registered`.
  ```

  Replace with:

  ```markdown

    Expect `Registered` for all six. Phase 6 also needs `Microsoft.SecurityInsights` (Microsoft Sentinel); register it the same way ([runbook 06](06-monitoring-and-sentinel.md) §2).
  - **EncryptionAtHost**, only if a VM is enabled (`enableVirtualMachine = true`): register once per subscription, then wait for `Registered`.
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 3 of 5.** Find:

  ```markdown
  | `keyVaultSecrets` (`@secure()`) | `{}` | from `KEYVAULT_SECRETS_JSON` | from `KEYVAULT_SECRETS_JSON` | Never set in a parameter file; the pipeline supplies it ([runbook 05](05-app-and-data.md) §5.1) |
  | `healthCheckPath` | `/` | *(default)* | *(default)* | No application code yet (`ADR-006`) |
  ```

  Replace with:

  ```markdown
  | `keyVaultSecrets` (`@secure()`) | `{}` | from `KEYVAULT_SECRETS_JSON` | from `KEYVAULT_SECRETS_JSON` | Never set in a parameter file; the pipeline supplies it ([runbook 05](05-app-and-data.md) §5.1) |
  | `alertEmail` | `''` | from `ALERT_EMAIL` | from `ALERT_EMAIL` (required) | Receiver of every platform alert; the pipeline supplies it ([runbook 06](06-monitoring-and-sentinel.md) §4 step 3) |
  | `alertThresholds` | `{ appServiceHttp5xx: 10, keyVaultForbidden: 10, vpnP2sConnections: 20, frontDoorWafBlocks: 100 }` | *(default)* | *(default)* | Count thresholds for the Phase 6 alerts ([runbook 06](06-monitoring-and-sentinel.md) §3) |
  | `healthCheckPath` | `/` | *(default)* | *(default)* | No application code yet (`ADR-006`) |
  ```

  **`docs/runbooks/01-deploy-stack.md`, edit 4 of 5.** Find:

  ```markdown

  3. Run [runbook 00b](00b-configure-pipeline-credentials.md) for the environment's identity, passing every resource group just created as `-ResourceGroupNames` (dev: the two `dev` groups; prod: all three `prod` groups, plus `-GrantLockManagement`). This grants the identity the subscription-scope custom role (`DefenStack Subscription Deployment Operator`), per-resource-group `Contributor`, and per-resource-group ABAC-constrained `Role Based Access Control Administrator`.

  ```

  Replace with:

  ````markdown

     Then make sure Network Watcher exists in every region the environment uses (Phase 6). `NetworkWatcherRG` and `NetworkWatcher_<region>` must exist **before** the identity script (step 3) and the deployment run: the script grants Network Contributor on `NetworkWatcherRG`, and the flow logs are created under the regional watcher. Azure usually creates them with the first VNet in a region; if `az network watcher list -o table` does not show them, run:

     ```powershell
     if ((az group exists --name NetworkWatcherRG) -eq 'false') { az group create --name NetworkWatcherRG --location westus3 -o none }
     az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true
     ```

  3. Run [runbook 00b](00b-configure-pipeline-credentials.md) for the environment's identity, passing every resource group just created as `-ResourceGroupNames` (dev: the two `dev` groups; prod: all three `prod` groups, plus `-GrantLockManagement`). This grants the identity the subscription-scope custom role (`DefenStack Subscription Deployment Operator`), per-resource-group `Contributor`, per-resource-group ABAC-constrained `Role Based Access Control Administrator`, and `Network Contributor` on `NetworkWatcherRG` (Phase 6). Also set the `ALERT_EMAIL` environment variable ([runbook 06](06-monitoring-and-sentinel.md) §4 step 3); a prod deploy refuses to run without it.

  ````

  **`docs/runbooks/01-deploy-stack.md`, edit 5 of 5.** Find:

  ```markdown
  | `The template parameter 'secondaryAddressPlan' is null. Assign a value to this parameter …` (a type error on `addressPlan`) | `deploySecondaryRegion = true` without also setting `secondaryAddressPlan` | `params/prod.bicepparam` already supplies `secondaryAddressPlan`; if you copy `dev.bicepparam` and only flip `deploySecondaryRegion`, you must also add `secondaryAddressPlan` |
  | Deployment fails with a duplicate-deployment or resource-conflict error, both stamps writing what looks like the same names | `primaryLocation` equals `secondaryLocation` while `deploySecondaryRegion = true` | The two regions must differ; use the shipped defaults (`westus3` / `eastus`) or another distinct pair |
  ```

  Replace with:

  ```markdown
  | `The template parameter 'secondaryAddressPlan' is null. Assign a value to this parameter …` (a type error on `addressPlan`) | `deploySecondaryRegion = true` without also setting `secondaryAddressPlan` | `params/prod.bicepparam` already supplies `secondaryAddressPlan`; if you copy `dev.bicepparam` and only flip `deploySecondaryRegion`, you must also add `secondaryAddressPlan` |
  | `ResourceNotFound` for `NetworkWatcher_<region>`, or the identity script fails on `NetworkWatcherRG` | Network Watcher was never created in that region (Phase 6 flow logs) | §4 step 2: `az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true`, then re-run |
  | Deployment fails with a duplicate-deployment or resource-conflict error, both stamps writing what looks like the same names | `primaryLocation` equals `secondaryLocation` while `deploySecondaryRegion = true` | The two regions must differ; use the shipped defaults (`westus3` / `eastus`) or another distinct pair |
  ```

  **`docs/runbooks/05-app-and-data.md`, edit 1 of 3.** Find:

  ```markdown
  - Key-based ingestion is **disabled**. The App Service identity sends telemetry with Entra ID, using **Monitoring Metrics Publisher** on its own component.
  - Public ingestion stays on until Phase 6 adds the Azure Monitor Private Link Scope.

  ```

  Replace with:

  ```markdown
  - Key-based ingestion is **disabled**. The App Service identity sends telemetry with Entra ID, using **Monitoring Metrics Publisher** on its own component.
  - Ingestion and queries are private: from Phase 6 the components accept them only through the Azure Monitor Private Link Scope ([runbook 06](06-monitoring-and-sentinel.md), `ADR-022`).

  ```

  **`docs/runbooks/05-app-and-data.md`, edit 2 of 3.** Find:

  ```markdown
  **Not in scope:**
  - AMPLS and private ingestion (Phase 6).
  - Recovery Services vaults and the failover procedure (Phase 8).
  ```

  Replace with:

  ```markdown
  **Not in scope:**
  - AMPLS, alerts and Sentinel ([runbook 06](06-monitoring-and-sentinel.md)).
  - Recovery Services vaults and the failover procedure (Phase 8).
  ```

  **`docs/runbooks/05-app-and-data.md`, edit 3 of 3.** Find:

  ```markdown
  - **Secret rotation:** rotate at the source system, then §5.1 "Add or rotate". Record the rotation in the change log, never the value.
  - **Geo-replication health:** check `lastSyncTime` (§5.3) weekly. Phase 6 adds an alert on it.
  - **Telemetry:** start in the workspace (`AppRequests`, `AppExceptions`, `AppDependencies`), filtered by `AppRoleName` per region. The App Insights blade works too, because the components are workspace-based.
  - **Cost drivers** (`docs/cost.md` "Phase 5 delta"):
  ```

  Replace with:

  ```markdown
  - **Secret rotation:** rotate at the source system, then §5.1 "Add or rotate". Record the rotation in the change log, never the value.
  - **Geo-replication health:** check `lastSyncTime` (§5.3) weekly. The Phase 6 alerts do not cover it; Phase 8 (DR) revisits it with the backup alerts.
  - **Telemetry:** start in the workspace (`AppRequests`, `AppExceptions`, `AppDependencies`), filtered by `AppRoleName` per region. The App Insights blade works too, because the components are workspace-based. From Phase 6, both work only from the VPN or the jump host (runbook 06 §5.2).
  - **Cost drivers** (`docs/cost.md` "Phase 5 delta"):
  ```

  **`README.md`, edit 1 of 5.** Find:

  ```markdown

  This deployment is a **subscription-scope**, multi-region stack: `main.bicep` (`targetScope = 'subscription'`) fans out to pre-created resource groups, one per environment's global layer and one per deployed region. The environment's Log Analytics workspace and the three shared `privatelink.*` private DNS zones live once in the global resource group (`rg-defenstack-<env>-global`), not per region stamp. Each region stamp creates a private spoke VNet, a dedicated hub VNet, Azure Firewall Premium with IDPS (zone-redundant), private endpoints, private DNS links to the shared zones, subnet NSGs, and reciprocal hub/spoke peering. Storage and App Service public network access are disabled. Dev deploys one region (West US 3); prod deploys West US 3 as the active primary and East US as a warm standby (`docs/decisions/ADR-008-warm-standby-and-dev-single-region.md`). See `docs/architecture/overview.md` for the full topology, address plan, and naming convention.

  ```

  Replace with:

  ```markdown

  This deployment is a **subscription-scope**, multi-region stack: `main.bicep` (`targetScope = 'subscription'`) fans out to pre-created resource groups, one per environment's global layer and one per deployed region. The environment's Log Analytics workspace and the shared `privatelink.*` private DNS zones (three application zones and, from Phase 6, four Azure Monitor zones) live once in the global resource group (`rg-defenstack-<env>-global`), not per region stamp. Each region stamp creates a private spoke VNet, a dedicated hub VNet, Azure Firewall Premium with IDPS (zone-redundant), private endpoints, private DNS links to the shared zones, subnet NSGs, and reciprocal hub/spoke peering. Storage and App Service public network access are disabled. Dev deploys one region (West US 3); prod deploys West US 3 as the active primary and East US as a warm standby (`docs/decisions/ADR-008-warm-standby-and-dev-single-region.md`). See `docs/architecture/overview.md` for the full topology, address plan, and naming convention.

  ```

  **`README.md`, edit 2 of 5.** Find:

  ```markdown
  - Architecture: `docs/architecture/overview.md` - topology, traffic flows, address plan, naming convention, and resource inventory
  - Runbooks: `docs/runbooks/` - start with `00-pipeline-and-identity.md`, `00b-configure-pipeline-credentials.md` (pipeline Azure login via OIDC), `00a-apply-phase0-fixes.md`, `01-deploy-stack.md` (deploy dev or prod), `01a-migrate-from-defenstack.md` (retire the Phase 0 resource group), `02-firewall.md` (Premium firewall rule changes and allowlist requests), and `03-admin-access.md` (Bastion, point-to-site VPN client setup, jump host sign-in, break-glass), `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover), and `05-app-and-data.md` (storage resilience, Application Insights, deploy-time Key Vault secrets, restore procedures)
  - Runbook structure (mandatory for every change): `docs/runbooks/_template.md`
  ```

  Replace with:

  ```markdown
  - Architecture: `docs/architecture/overview.md` - topology, traffic flows, address plan, naming convention, and resource inventory
  - Runbooks: `docs/runbooks/` - start with `00-pipeline-and-identity.md`, `00b-configure-pipeline-credentials.md` (pipeline Azure login via OIDC), `00a-apply-phase0-fixes.md`, `01-deploy-stack.md` (deploy dev or prod), `01a-migrate-from-defenstack.md` (retire the Phase 0 resource group), `02-firewall.md` (Premium firewall rule changes and allowlist requests), and `03-admin-access.md` (Bastion, point-to-site VPN client setup, jump host sign-in, break-glass), `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover), `05-app-and-data.md` (storage resilience, Application Insights, deploy-time Key Vault secrets, restore procedures), and `06-monitoring-and-sentinel.md` (private Azure Monitor, flow logs, Sentinel connectors, alert triage, `ALERT_EMAIL`)
  - Runbook structure (mandatory for every change): `docs/runbooks/_template.md`
  ```

  **`README.md`, edit 3 of 5.** Find:

  ```markdown

  - `modules/global.bicep`: the environment's shared Log Analytics workspace and the three `privatelink.*` private DNS zones, deployed once per environment.
  - `modules/regionStamp.bicep`: one region's full hub/spoke stack (composes every module below), deployed once for the primary region and again for the secondary region when `deploySecondaryRegion = true`.
  - `modules/privateDnsZoneLinks.bicep`: links every deployed region's hub and spoke VNets to a shared private DNS zone.
  - `modules/types.bicep`: shared parameter contracts (`regionAddressPlan`, `privateDnsZoneSet`, `virtualNetworkReference`) used by `main.bicep`, `modules/global.bicep`, and `modules/regionStamp.bicep`.

  ```

  Replace with:

  ```markdown

  - `modules/global.bicep`: the environment's shared Log Analytics workspace (with Microsoft Sentinel) and the shared `privatelink.*` private DNS zones, deployed once per environment.
  - `modules/regionStamp.bicep`: one region's full hub/spoke stack (composes every module below), deployed once for the primary region and again for the secondary region when `deploySecondaryRegion = true`.
  - `modules/privateDnsZoneLinks.bicep`: links every deployed region's hub and spoke VNets to a shared private DNS zone.
  - `modules/types.bicep`: shared parameter contracts (`regionAddressPlan`, `privateDnsZoneSet`, `virtualNetworkReference`, `hubPeeringPlan`, `metricAlertRule`, `alertThresholdSet`) used by `main.bicep`, `modules/global.bicep`, and `modules/regionStamp.bicep`.
  - Phase 6 monitoring, deployed from `main.bicep`: `modules/monitorPrivateLinkScope.bicep` and `modules/monitorPrivateEndpoint.bicep` (private-only Azure Monitor), `modules/hubPeering.bicep` (prod hub-to-hub peering), `modules/activityLog.bicep` (subscription Activity Log), `modules/actionGroup.bicep`, `modules/metricAlerts.bicep` and `modules/serviceHealthAlert.bicep` (alerts). Each region stamp adds `modules/flowLogStorage.bicep` and `modules/flowLogs.bicep` (VNet flow logs, deployed into `NetworkWatcherRG`) and its own metric alerts. See `docs/runbooks/06-monitoring-and-sentinel.md`.

  ```

  **`README.md`, edit 4 of 5.** Find:

  ```markdown
    - `approved-https-egress` (priority 200, optional): the application allowlist from `allowedOutboundFqdns`; not deployed at all while that list is empty.
  - App Service integration traffic uses a `0.0.0.0/0` route through the firewall private IP and App Service route-all is enabled.
  ```

  Replace with:

  ```markdown
    - `approved-https-egress` (priority 200, optional): the application allowlist from `allowedOutboundFqdns`; not deployed at all while that list is empty.
    - `cross-region-monitoring` (priority 250, prod with DR only, Phase 6): lets the East US App Service and management subnets reach the AMPLS private endpoint in West US 3 over the hub-to-hub peering, a network rule in East US and an application rule (SNAT) in West US 3 (`docs/runbooks/06-monitoring-and-sentinel.md` §1).
  - App Service integration traffic uses a `0.0.0.0/0` route through the firewall private IP and App Service route-all is enabled.
  ```

  **`README.md`, edit 5 of 5.** Find:

  ```markdown

  Azure Firewall Premium has ongoing hourly and data-processing charges, higher than Standard's (`docs/cost.md` "Phase 2 delta"). Regional VNet peering and Log Analytics ingestion also incur charges. Phase 3 adds a point-to-site VPN gateway, Azure Bastion and their three public IPs in each region with admin access (`docs/cost.md` "Phase 3 delta"). This design intentionally avoids global peering, NAT gateways, site-to-site VPN or ExpressRoute, other public IPs, and Azure Firewall Manager unless separately approved.

  ```

  Replace with:

  ```markdown

  Azure Firewall Premium has ongoing hourly and data-processing charges, higher than Standard's (`docs/cost.md` "Phase 2 delta"). Regional VNet peering and Log Analytics ingestion also incur charges. Phase 3 adds a point-to-site VPN gateway, Azure Bastion and their three public IPs in each region with admin access (`docs/cost.md` "Phase 3 delta"). Phase 6 adds Microsoft Sentinel, Traffic Analytics, flow-log storage, the AMPLS private endpoint and zones, and, in prod with DR, hub-to-hub global peering that carries only monitoring traffic (`docs/cost.md` "Phase 6 delta", `docs/decisions/ADR-022-private-only-monitoring-and-hub-peering.md`). Apart from that peering, this design intentionally avoids global peering, NAT gateways, site-to-site VPN or ExpressRoute, other public IPs, and Azure Firewall Manager unless separately approved.

  ```

- [ ] **Step 6: Run the full suite on both shells**

  The full suite should show `Tests Passed: 538, Failed: 0` on Windows PowerShell 5.1 and on pwsh 7. PSRule is unchanged at 1200 rules processed, 0 failures. Encoding check: `grep -rln $'\xEF\xBF\xBD' docs README.md --exclude-dir=superpowers` prints nothing.

- [ ] **Step 7: Commit**

  ```bash
  git add docs/runbooks/06-monitoring-and-sentinel.md docs/decisions/ADR-022-private-only-monitoring-and-hub-peering.md docs/decisions/ADR-023-flow-log-identity-and-network-watcher.md docs/decisions/ADR-024-sentinel-content-through-content-hub.md docs/decisions/ADR-025-preview-api-subscription-diagnostic-setting.md docs/decisions/ADR-021-application-insights-per-region.md docs/architecture/overview.md docs/cost.md docs/runbooks/00b-configure-pipeline-credentials.md docs/runbooks/01-deploy-stack.md docs/runbooks/05-app-and-data.md README.md tests/Docs.Tests.ps1
  git commit -m "docs: Phase 6 runbook 06, ADR-022 to ADR-025 and monitoring updates" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## After the last task (human, not the implementer)

A person follows only runbook 06:

1. In dev: §4 steps 1–8 (Network Watcher check, identity script re-run as `Owner` or `User Access Administrator`, `ALERT_EMAIL` on `dev` and `dev-plan`, providers, validate and what-if, deploy, the AMPLS endpoint's DNS records, Sentinel content), then §5.1 Sentinel connector enablement and every §6 row from the VPN or jump host. Paste the outputs into the PR.
2. Watch the §9 live-only risks on the first dev run: Traffic Analytics into the PrivateOnly workspace (Review Focus 1) and the preview Activity Log API (Review Focus 4). Record any fallback taken in the matching ADR.
3. Before prod: set `ALERT_EMAIL` on `prod`, run `az deployment sub validate` with `params/prod.bicepparam`, and after the deployment run the §6 prod rows for the hub peering and the East US telemetry path (Review Focus 2).

