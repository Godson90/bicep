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

**Jump host agent:** when `enableVirtualMachine` is true, the jump host's Azure Monitor Agent uses a regional data collection endpoint, `<vm>-dce` (public network access `Disabled`, association `configurationAccessEndpoint`), scoped into the AMPLS.

**Cross-region AMPLS path (prod with DR only, `deploySecondaryRegion = true`):**

The East US App Service and management subnets reach the one endpoint in West US 3 through both firewalls (the jump host is primary-only):

```mermaid
sequenceDiagram
    participant EUS as East US App Service or management subnet
    participant FW2 as East US firewall (Client)
    participant FW1 as West US 3 firewall (Host)
    participant PE as AMPLS private endpoint (primary private-endpoints subnet)

    EUS->>FW2: HTTPS to the PE address (spoke route 0.0.0.0/0 to firewall)
    FW2->>FW2: Network rule spoke-to-peer-azure-monitor (source address kept)
    FW2->>FW1: AzureFirewallSubnet route table: primary spoke prefix to the West US 3 firewall, over the hub-to-hub peering
    FW1->>FW1: Application rule peer-spoke-to-azure-monitor (Azure Monitor FQDNs only; source address rewritten to the firewall)
    FW1->>PE: HTTPS from the West US 3 AzureFirewallSubnet (the PE NSG allows it to the AMPLS ASG only)
    PE-->>FW1: Reply to the firewall
    FW1-->>FW2: Reply over the peering (East US spoke prefix to the East US firewall)
    FW2-->>EUS: Reply
```

- **East US policy, network rule** `spoke-to-peer-azure-monitor` / `azure-monitor-private-endpoint`: TCP 443 from the East US `appservice-integration` and `management` subnets to the primary `private-endpoints` subnet prefix. A network rule keeps the source address.
- **West US 3 policy, application rule** `peer-spoke-to-azure-monitor` / `azure-monitor-private-link`: HTTPS from the same East US subnets to `*.applicationinsights.azure.com`, `*.monitor.azure.com`, `*.ods.opinsights.azure.com`, `*.oms.opinsights.azure.com` and `*.agentsvc.azure-automation.net`. An application rule rewrites the source address to the firewall's own (SNAT), so the endpoint replies to the West US 3 firewall. The primary spoke has no route back to East US. The rule filters on the requested name (SNI), which without TLS inspection does not prove the destination address, so it is not what isolates the subnet's other private endpoints. The West US 3 private-endpoint NSG enforces that isolation (below).
- **Both rules** live in the rule collection group `cross-region-monitoring` (priority 250), which exists only with DR.
- **West US 3 private-endpoint NSG, the enforcement point** (`<spoke VNet>-private-endpoints-nsg`, rule `allow-peer-monitoring-https`, priority 110): TCP 443 from the region's own `AzureFirewallSubnet` prefix, the SNAT source, to the application security group `<spoke VNet>-ampls-asg` only. The AMPLS endpoint is the group's only member, so East US traffic reaches no other private endpoint, whatever name it asks for. The firewall subnet is never an `allow-approved-https` source. Only the Host region gets the rule; every spoke has the (free) group.
- **Routing:** each hub's `AzureFirewallSubnet` has the route table `<hub VNet>-firewall-rt`: `remote-spoke-<n>-through-peer-firewall` (the other region's spoke prefix to the other firewall's `.4` address) and `default-to-internet` (`0.0.0.0/0` to `Internet`, which Azure requires there).
- **Peering:** `hub-to-eus-hub` and `hub-to-wus3-hub`, forwarded traffic allowed, no gateway transit. Nothing but Azure Monitor crosses until Phase 8.

**VNet flow logs and Traffic Analytics (`ADR-023`), per region:**
- A keyless flow-log account `stfl<region><suffix>` (no shared key; public network access `Enabled` with the firewall at default `Deny`, the `AzureServices` bypass and no IP or VNet rules, so only trusted Azure services reach it; prod ZRS, dev LRS).
- The identity `id-flowlogs-defenstack-<env>-<region>` holds Storage Blob Data Contributor on that account only.
- **Phase 7 exemption:** governance (runbook 07) exempts each `stfl…` account from the Storage public network access assignment (`defenstack-flow-log-storage-public-network`, `Mitigated`, citing `ADR-023`). The account must exist before governance deploys. Its blob service has no diagnostic setting, so it reports non-compliant in `defenstack-audit-diagnostic-settings`; that is expected.
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
- Defender for Cloud plans and Azure Policy: Phase 7, deployed by an operator from `governance.bicep` (runbook 07).
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
- **Providers:** register and check `Microsoft.SecurityInsights` and `Microsoft.OperationsManagement` (new), plus `Microsoft.Insights`, `Microsoft.OperationalInsights` and `Microsoft.Network`:

  ```powershell
  foreach ($ns in 'Microsoft.SecurityInsights','Microsoft.OperationsManagement','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Network') { az provider register --namespace $ns }
  foreach ($ns in 'Microsoft.SecurityInsights','Microsoft.OperationsManagement','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Network') { az provider show -n $ns --query registrationState -o tsv }
  ```

  Expect `Registered` five times.
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

   It is a **variable**, not a secret: the workflows read `vars.ALERT_EMAIL`. Dev may leave it empty (the action group then has no receiver). Prod may not: the first step of both the `plan` and the `apply` job, **Require ALERT_EMAIL for prod**, fails the run before it checks out the code or signs in to Azure.

4. **Register the providers** (§2).

5. **Validate and preview**, from the repository root (add `--parameters alertEmail=<address>` to see the receiver):

   ```powershell
   az deployment sub validate --location westus3 --parameters params/dev.bicepparam --parameters alertEmail='platform-alerts@example.org'
   az deployment sub what-if --location westus3 --parameters params/dev.bicepparam --parameters alertEmail='platform-alerts@example.org'
   ```

   Check the what-if:
   - `rg-defenstack-dev-global`: **create** the four Azure Monitor zones, their links and (prod) their locks; `ampls-defenstack-dev` and its scoped resources; `ag-defenstack-dev`; the two Front Door alerts and the Service Health alert; Sentinel `default` on the workspace. **Modify** the workspace (`publicNetworkAccessForIngestion` and `publicNetworkAccessForQuery` to `Disabled`).
   - `rg-defenstack-dev-wus3`: **create** `vnet-defenstack-dev-wus3-spoke-ampls-asg`, `ampls-defenstack-dev-pe` (in that application security group), `stflwus3…`, `id-flowlogs-defenstack-dev-wus3` and its role assignment, and the seven regional alerts; with `enableVirtualMachine`, also `<vm>-dce` and the VM's `configurationAccessEndpoint` association (and the DCE as a scoped resource in the global group). **Modify** `appi-defenstack-dev-wus3` (both public access flags to `Disabled`).
   - `NetworkWatcherRG`: **create** `vnet-defenstack-dev-wus3-hub-flowlog` and `vnet-defenstack-dev-wus3-spoke-flowlog`.
   - Subscription: **create** the diagnostic setting `activity-log-defenstack-dev`.
   - Prod also: the hub peerings `hub-to-eus-hub` / `hub-to-wus3-hub`, the route tables `vnet-defenstack-prod-<region>-hub-firewall-rt`, the rule collection group `cross-region-monitoring` in both policies, the East US group `vnet-defenstack-prod-eus-spoke-ampls-asg`, and a new West US 3 NSG rule `allow-peer-monitoring-https` (source `10.1.0.0/26`, destination the AMPLS application security group). `allow-approved-https` must **not** change.
   - **Stop** on any delete or recreate of the workspace, a zone, a VNet, a firewall or an App Service.

6. **Deploy through the pipeline:** GitHub → Actions → `deploy` → **Run workflow** → `dev` (prod: the two-approval flow, `ADR-012`).

   **Prod with DR:** the private-only monitoring change (the workspace and components set to `Disabled`, the AMPLS and its endpoint) and the cross-region path (peering, the firewall-subnet route tables, `cross-region-monitoring`, the Host NSG rule) must deploy in the **same run**. Never deploy a commit that has the first without the second: East US telemetry would stop until the path exists.

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
4. **Tenant-based Microsoft Defender for Cloud connector:** **Data connectors** → **Tenant-based Microsoft Defender for Cloud** → **Open connector page** → **Connect**. It covers every subscription in the tenant, so no per-subscription connector is needed. The Defender plans arrive with Phase 7 governance (runbook 07); before it is deployed, only free-tier recommendations flow.
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
| AMPLS modes and scope | `az monitor private-link-scope show -g rg-defenstack-<env>-global -n ampls-defenstack-<env> --query accessModeSettings -o json`; `az monitor private-link-scope scoped-resource list -g rg-defenstack-<env>-global --scope-name ampls-defenstack-<env> --query "[].name" -o tsv` | `PrivateOnly` twice; the workspace and every component (prod: both regions), plus `<vm>-dce` when `enableVirtualMachine` is true |
| Private resolution (§5.2) | `nslookup <workspace id>.ods.opinsights.azure.com` from the VPN or jump host | An address in the primary `private-endpoints` subnet |
| Telemetry still arrives, both regions | `AppRequests \| where TimeGenerated > ago(1h) \| summarize count() by AppRoleName` (after traffic through Front Door) | One row per deployed region. East US rows prove the cross-region path |
| Cross-region routes (prod) | `az network route-table route list -g rg-defenstack-prod-wus3 --route-table-name vnet-defenstack-prod-wus3-hub-firewall-rt -o table`, and the same for `rg-defenstack-prod-eus` / `vnet-defenstack-prod-eus-hub-firewall-rt` | West US 3: `10.10.0.0/16` → `VirtualAppliance` `10.11.0.4`; East US: `10.0.0.0/16` → `VirtualAppliance` `10.1.0.4`; both: `0.0.0.0/0` → `Internet` |
| Host NSG (prod) | `az network nsg rule show -g rg-defenstack-prod-wus3 --nsg-name vnet-defenstack-prod-wus3-spoke-private-endpoints-nsg -n allow-peer-monitoring-https --query "{src:sourceAddressPrefixes, dst:destinationApplicationSecurityGroups[].id, port:destinationPortRange}" -o json`; the same with `-n allow-approved-https --query sourceAddressPrefixes -o tsv`; `az network private-endpoint show -g rg-defenstack-prod-wus3 -n ampls-defenstack-prod-pe --query "applicationSecurityGroups[].id" -o tsv` | `allow-peer-monitoring-https`: source `10.1.0.0/26` (the West US 3 `AzureFirewallSubnet`), destination `…/vnet-defenstack-prod-wus3-spoke-ampls-asg`, port `443`. `allow-approved-https` does **not** list `10.1.0.0/26`. The endpoint is in that group |
| Cross-region isolation (prod, negative test) | From an East US host on the cross-region path (the East US App Service's SSH console, or a test VM in the East US `management` subnet): `curl --max-time 15 --resolve api.monitor.azure.com:443:<primary Key Vault private endpoint IP> https://api.monitor.azure.com`. Control: the same with the AMPLS endpoint's `api` record IP | The Key Vault attempt **fails** (timeout: the West US 3 NSG drops the firewall's SNAT address to anything but the AMPLS group). The control connects (any HTTP status). A Key Vault response means isolation is broken: stop and check the Host NSG row |
| Host rule hits (prod) | `AZFWApplicationRule \| where Rule == "azure-monitor-private-link" \| summarize count() by Fqdn, SourceIp` | East US source addresses, Azure Monitor FQDNs, action `Allow` |
| Peering (prod) | `az network vnet peering list -g rg-defenstack-prod-wus3 --vnet-name vnet-defenstack-prod-wus3-hub --query "[?name=='hub-to-eus-hub'].{state:peeringState, fwd:allowForwardedTraffic, transit:allowGatewayTransit}" -o json` | `Connected`, `true`, `false` |
| Flow logs | `az network watcher flow-log list --location westus3 --query "[].{name:name, enabled:enabled, ta:flowAnalyticsConfiguration.networkWatcherFlowAnalyticsConfiguration.enabled}" -o table` | The hub and spoke flow logs of every environment in the subscription, enabled, Traffic Analytics `True` |
| Flow-log blobs (confirms the writes succeed) | `az storage container-rm list --storage-account <stfl…> -g rg-defenstack-<env>-<region> --query "[].name" -o tsv` (management plane: the account's firewall denies data-plane calls from every network, the VPN included) | `insights-logs-flowlogflowevent` |
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
- **Adding a region or a component to AMPLS:** turning on the secondary region in an existing environment adds its component to the scope after the endpoint exists. Re-run §4 step 7 afterwards and check that the regional `in.ai` record for the new region is present. If it is missing, delete and redeploy `ampls-defenstack-<env>-pe` in a change window. The same applies to turning `enableVirtualMachine` on after the endpoint exists: the jump host's `<vm>-dce` joins the scope later, so re-run the deploy so the endpoint's zone group refreshes, then check §4 step 7 for the DCE's `handler.control.monitor.azure.com` record; if it is missing, delete and redeploy the endpoint as above.
- **Turning DR off:** deployments are incremental, so the East US component's scoped resource stays in the AMPLS after `deploySecondaryRegion` goes back to `false`. Remove it: `az monitor private-link-scope scoped-resource delete -g rg-defenstack-prod-global --scope-name ampls-defenstack-prod -n appi-defenstack-prod-eus`.
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
| Prod `plan` or `apply` fails at **Require ALERT_EMAIL for prod** | `ALERT_EMAIL` is not set on the `prod` environment | §4 step 3 |
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
| **Flow-log storage: confirm writes succeed through the trusted services exception.** The account already uses the fallback design: `publicNetworkAccess: 'Enabled'`, firewall default `Deny`, the `AzureServices` bypass and no IP or VNet rules (fully `Disabled` would likely ignore the exception, `ADR-023`). Confirm that Network Watcher's writes with the user-assigned identity succeed. Phase 7 governance exempts the `stfl*` accounts from its "deny public network access on Storage" assignment: `defenstack-flow-log-storage-public-network` on each account, category `Mitigated` (runbook 07 §5.3) | 403s in the flow-log account's activity log; no `insights-logs-flowlogflowevent` container after 30 minutes (§6 "Flow-log blobs") | **Fallback:** check the identity's Storage Blob Data Contributor assignment and the `AzureServices` bypass, re-run the deploy, then open a Microsoft case. Do not add IP or VNet rules or re-enable shared key; record the outcome in `ADR-023` |
| **Traffic Analytics into a workspace with `PrivateOnly` ingestion.** Microsoft does not document whether the Traffic Analytics pipeline honours AMPLS-only ingestion | `NTANetAnalytics` stays empty after 30 minutes while the flow-log blobs grow | **Fallback:** keep the flow logs in storage, set Traffic Analytics off (`flowAnalyticsConfiguration` disabled in `modules/flowLogs.bicep`) and open a Microsoft case. Do not reopen public ingestion on the workspace without a new ADR (`ADR-023`) |
| **The FQDN-filtered cross-region AMPLS path.** The West US 3 application rule must match multi-label hosts such as `global.in.ai.monitor.azure.com` and `eastus-8.in.applicationinsights.azure.com` with single wildcards, and the West US 3 firewall must resolve them to the private endpoint; the East US firewall must see the replies to its network-rule flow | East US `AppRequests` missing; `AZFWApplicationRule` on the West US 3 firewall shows `Deny` for an Azure Monitor FQDN, or no hits at all | **Fallback:** first add the exact denied FQDN to the Host rule's `targetFqdns`. If the path still fails, replace the Host application rule with a network rule (TCP 443, East US subnets → primary `private-endpoints` prefix), set the primary private-endpoint subnet's `privateEndpointNetworkPolicies` to `Enabled` and give it a route table that sends the East US spoke prefix to the West US 3 firewall, so replies return symmetrically. Without SNAT the endpoint sees the East US addresses, so pass the East US subnets, not the firewall subnet, as the Host NSG rule's `monitorPeerSourceCidrs` (the destination stays the AMPLS application security group). Record it in `ADR-022` |
| **Preview API for the subscription diagnostic setting** (`Microsoft.Insights/diagnosticSettings@2021-05-01-preview`, the only version with subscription scope) | Deploy fails on `activity-log-<env>` with an API version error | **Fallback:** create the setting by hand, `az monitor diagnostic-settings subscription create --name activity-log-defenstack-<env> --location westus3 --workspace <workspace resource id> --logs '[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"ServiceHealth","enabled":true},{"category":"Alert","enabled":true},{"category":"Recommendation","enabled":true},{"category":"Policy","enabled":true},{"category":"Autoscale","enabled":true},{"category":"ResourceHealth","enabled":true}]'`, remove the module from `main.bicep`, and update `ADR-025` |
| **Alert API versions that are not the newest.** `metricAlerts@2018-03-01`, `activityLogAlerts@2020-10-01` and `actionGroups@2023-01-01` are the last versions the research could confirm as GA. Newer versions without a preview label (for example `metricAlerts@2026-01-01`) were not adopted, because their GA status is not clearly documented | Deploy fails on an alert or the action group with `NoRegisteredProviderFound` or an API version error | **Fallback:** move the failing resource to the newest version that the template reference (`learn.microsoft.com/azure/templates/microsoft.insights/<type>`) labels GA, re-run `tests/Invoke-Tests.ps1`, and update the pinned-version tests |
| **Alert details:** the `Maximum` aggregation for `P2SConnectionCount`, the `Count` aggregation for `ServiceApiResult`, and the Service Health region names `West US 3` / `East US` | Deploy error naming the aggregation; or no Service Health email for a known regional event | **Fallback:** use `Total` (and raise the P2S threshold accordingly); compare the region names with a Service Health event's `impactedRegions` and correct `regionDisplayNames` in `main.bicep` |
| **Custom role update payload.** `-WhatIf` only prints `Update custom role actions`; the JSON the script sends to `az role definition update` (`Id`, `Name`, `IsCustom`, `Actions`, `NotActions`, `AssignableScopes`) is first exercised live | §4 step 2 fails with "Failed to update the custom role", or the check after it shows fewer than 12 actions | Dry-run it in dev first: run §4 step 2 for dev without `-WhatIf` and run its check before touching prod (the role is shared, so prod then reports it already has the expected actions). **Fallback:** `az role definition list --name "DefenStack Subscription Deployment Operator" --custom-role-only true --query "[0]" -o json > role.json`, add the three `Microsoft.Insights/diagnosticSettings/*` actions (named, not as a wildcard) to `permissions[0].actions`, then `az role definition update --role-definition "@role.json"` |
| **Action group short name with hyphens** (`ds-dev-ops`, `ds-prod-ops`; 12 characters at most) | Deploy fails on `action-group-<env>` with a validation error on `groupShortName` | Check on the first dev deploy that `az monitor action-group show -g rg-defenstack-dev-global -n ag-defenstack-dev --query groupShortName -o tsv` prints `ds-dev-ops`. **Fallback:** drop the hyphens (`dsprodops`) in `main.bicep` and update the action-group tests |
| **Sentinel through the Defender portal with workspace query public access `Disabled`.** Whether the Defender portal's Sentinel pages (incidents, hunting, onboarding the workspace) work against a `PrivateOnly` query workspace is not documented | Onboarding the workspace to the Defender portal fails, or its Sentinel pages show query or access errors even from the VPN or jump host | **Fallback:** use Microsoft Sentinel in the Azure portal from the VPN or jump host (§5.2) while that experience is available, and raise it with Microsoft. Do not re-enable public query access without a new ADR (`ADR-022`) |
| **Sentinel onboarding and `Microsoft.OperationsManagement`.** Whether `onboardingStates` needs the `Microsoft.OperationsManagement` provider (the legacy SecurityInsights solution's provider) registered is not confirmed | Deploy fails on the workspace's `onboardingStates/default` with a provider-registration error | §2 registers the provider as a precaution. **Fallback:** if it was skipped, `az provider register --namespace Microsoft.OperationsManagement --wait` and re-run the deploy |
| **Service Health alert: the subscription-scope linked-access check.** The activity log alert lives in the global resource group but its `scopes` is the subscription; ARM checks that the pipeline identity can read that scope, and the identity's subscription rights are limited to the custom role | Deploy fails on the Service Health alert with `LinkedAuthorizationFailed` | **Fallback:** add only the read action the error names to the custom role in `scripts/New-GitHubDeploymentIdentity.ps1` (and its tests), re-run §4 step 2, and redeploy. As a stopgap, create the alert by hand with `az monitor activity-log alert create` and remove the module from `main.bicep` until the role is fixed |
