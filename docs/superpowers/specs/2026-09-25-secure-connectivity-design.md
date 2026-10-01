# Plan: Secure Connectivity, Security & Availability Roadmap for the DefenStack Bicep Project

## Context

The repo (`C:\Workspace\Bicep`) deploys a single-region (West US 3), resource-group-scoped hub/spoke stack: Azure Firewall Standard, a spoke VNet with private endpoints for Storage, App Service and Key Vault (all with public access disabled), subnet NSGs, a UDR to the firewall, Log Analytics, and an optional VM. The baseline is good, but it has gaps that stop it from being operable, reachable and resilient:

- **No one can reach it.** There is no admin path (no Bastion or VPN), so the README's Key Vault secret step and VM administration can't be done. There's also no user ingress, even though the app should serve **public internet users**.
- **No availability design.** Nothing is zone-redundant, and there's no second region. The target is **multi-region active/passive DR (West US 3 → East US)**.
- **No security operations layer.** There are no Defender for Cloud plans, Azure Policy assignments, flow logs, alerts or SIEM. The target includes **Defender plans, Firewall Premium and Microsoft Sentinel**.
- **Config defects** (listed in §2).

User decisions: public ingress through a WAF; admin access through **Bastion plus a Point-to-Site VPN**; DR region **East US**; docs as **Markdown in `docs/`**; deployment through **GitHub Actions**.

**Mandatory documentation rule:** every implementation step in this plan must ship with detailed documentation, including step-by-step procedures wherever a human or pipeline action is required. §6 defines the standard. A phase is not "done" until its runbook is merged and has been executed once against a dev environment.

---

## 1. Target architecture (recommended)

```
                        Internet users
                              │
              Azure Front Door Premium + WAF (global, rg-global)
               │  Private Link (priority 1)        │ Private Link (priority 2)
     ┌─────────▼──────── West US 3 (primary) ─┐  ┌──▼─────────── East US (DR, warm) ─┐
     │ Hub 10.1.0.0/16                        │  │ Hub 10.11.0.0/16                   │
     │  AzureFirewallSubnet  (FW Premium, AZ) │◄─┼─► AzureFirewallSubnet (FW Premium) │  global hub-hub peering
     │  AzureBastionSubnet   (Bastion Std, AZ)│  │  AzureBastionSubnet (deploy on DR) │
     │  GatewaySubnet        (P2S VPN AZ,Entra)│  │  GatewaySubnet      (deploy on DR) │
     │ Spoke 10.0.0.0/16                      │  │ Spoke 10.10.0.0/16                 │
     │  private-endpoints / appsvc-int / mgmt │  │  same subnet contract              │
     │  App Service P-v3 zone-redundant       │  │  App Service P-v3 (min instances)  │
     │  Key Vault, Storage RA-GZRS (primary)  │  │  Key Vault (regional)              │
     │  Recovery Services vault (GRS, CRR)    │  │  Recovery Services vault           │
     └────────────────────────────────────────┘  └────────────────────────────────────┘
  rg-global: Front Door + WAF policy, Private DNS zones (linked to both hubs + spokes),
             Log Analytics + Sentinel, AMPLS, parent Firewall Policy, action groups
  Subscription: Defender for Cloud plans, Policy assignments, Activity Log export
```

**Availability balance.** The primary region is fully zone-redundant. The DR region runs **warm**: Firewall, App Service at minimum scale, Key Vault and the private endpoints stay deployed, while Bastion and the VPN gateway sit behind a `deployAdminAccess` flag and are switched on during failover. That cuts steady-state cost by about 2 gateways and 1 Bastion.

**Address plan.** WUS3 hub `10.1.0.0/16`, spoke `10.0.0.0/16`. EUS hub `10.11.0.0/16`, spoke `10.10.0.0/16`. P2S client pool `172.16.200.0/24`.

Hub subnets:
- `AzureFirewallSubnet` /26
- `AzureBastionSubnet` /26
- `GatewaySubnet` /27

Spoke subnets:
- `private-endpoints` /24
- `appservice-integration` /24
- `management` /24 (renamed from `virtual-machines`)

---

## 2. Review findings: defects to fix first (Phase 0)

| # | File:line | Finding | Fix |
|---|---|---|---|
| F1 | `modules/spokeNetwork.bicep:154-160` | The VM subnet reuses the **App Service NSG and route table**. | Give the management subnet its own NSG: allow 22/3389 only from `AzureBastionSubnet` and the P2S pool. Give it its own route table. |
| F2 | `modules/spokeNetwork.bicep:114` | `disableBgpRoutePropagation: false`. Once a VPN gateway exists, the propagated routes will **bypass the firewall**. | Set it to `true` on every spoke route table. Add a GatewaySubnet route table that sends spoke prefixes → firewall. |
| F3 | `modules/virtualMachine.bicep:172-190` | The VM diagnostic setting uses `categoryGroup: allLogs`. Compute VMs expose no log categories, so this likely fails when `enableVirtualMachine=true`. | Replace it with Azure Monitor Agent plus a Data Collection Rule. Keep metrics only. **Verify with `az deployment group validate`.** |
| F4 | `modules/keyVault.bicep:27-41` | `enabledForTemplateDeployment` is not set, so the README's `az.getSecret()` flow will not resolve. | Add the parameter, default `true`, for the composed stack. **Verify against current ARM docs.** |
| F5 | `main.bicep:152-154`, `:80-82` | The spoke CIDR `10.0.0.0/16` and the PE-source CIDR `10.0.2.0/24` are hard-coded, duplicating the spoke module defaults. | Derive both from the spoke module parameters and outputs (single source of truth). |
| F6 | `modules/storage.bicep:43-55` | Only account-level metrics are collected. There are no blob `StorageRead/Write/Delete` logs. | Add a diagnostic setting on `blobServices/default` with `allLogs`. |
| F7 | `modules/storage.bicep` | No data protection. | Enable blob versioning, 14-day blob and container soft delete, change feed, and point-in-time restore. |
| F8 | `modules/appService.bicep` | Basic-auth publishing isn't disabled, and there's no health check, `alwaysOn`, zone redundancy, `scmMinTlsVersion` or remote-debug lockdown. The plan name isn't unique per region. | Add `basicPublishingCredentialsPolicies` (ftp/scm = false), `healthCheckPath`, `alwaysOn`, `zoneRedundant` plus capacity ≥3 in prod, and a region-suffixed plan name. |
| F9 | `modules/azureFirewall.bicep` | No availability zones on the firewall or its PIP, `threatIntelMode: 'Alert'`, and the diagnostics use the legacy AzureDiagnostics table. | Set zones `[1,2,3]`, `Deny` in prod, and `logAnalyticsDestinationType: 'Dedicated'`. |
| F10 | `modules/monitoring.bicep` | Public ingestion and query are enabled, and retention is 30 days. | Disable public access via AMPLS in Phase 6. Retain 90 days (Sentinel includes 90 days free). |
| F11 | `modules/networkIntegration.bicep:79` | `Storage Blob Data Contributor` is assigned at account scope. | Scope it to the `def-blob` container. |
| F12 | `modules/privateConnectivity.bicep:247` | The Key Vault private endpoint ID isn't output. | Add the output. It's needed for alerts and the docs. |
| F13 | Repo | There's no `bicepconfig.json`, `.gitignore` for `*.bicepparam` secrets, or CI. | Add them in Phase 0. |

---

## 3. Recommended resources by domain

**Connectivity and network security**
- **Azure Firewall Premium** (per region, zones 1-3):
  - A parent **Firewall Policy** in `rg-global` with a child policy per region. The parent holds the shared rules (DNS, Azure platform FQDN tags, Windows Update and Ubuntu repos for the management VMs); each child holds regional allowlists.
  - IDPS in `Alert and Deny`, threat intel set to `Deny`.
  - TLS inspection is **optional and gated**: it needs an intermediate CA in Key Vault plus a firewall user-assigned identity. First verify that Firewall Premium can read a private-endpoint-only vault, and document the result as an ADR.
- **Azure Bastion Standard** (primary; DR behind a flag): zone-redundant, native-client and IP-based connect, Bastion NSG with the Microsoft-required rules.
- **VPN Gateway `VpnGw2AZ`, P2S**:
  - OpenVPN with **Microsoft Entra ID authentication**, restricted to an admin security group through app assignment.
  - Hub-to-spoke peering switched to `allowGatewayTransit`/`useRemoteGateways`.
  - The VPN client profile uses the firewall private IP as its DNS server, so private endpoint names resolve.
- **Global VNet peering hub↔hub** for DR admin access and replication traffic, routed through both firewalls.
- **Management jump host** (the existing VM module, refocused):
  - Entra ID login extension (`AADSSHLoginForLinux` / `AADLoginForWindows`) with the `Virtual Machine Administrator Login` role for the admin group.
  - Defender JIT access, Azure Update Manager maintenance configuration, availability zone pinning.
- **DDoS**: not selected. Front Door absorbs L3/4 attacks at the edge. The firewall PIP is egress-only (no DNAT), so this risk is accepted and recorded in an ADR.

**Ingress**
- **Azure Front Door Premium**:
  - An origin group with the WUS3 App Service (priority 1) and EUS (priority 2), each reached over **Private Link** (`sites` group ID). App Service `publicNetworkAccess` stays `Disabled`.
  - Health probes on `healthCheckPath`.
  - A custom domain with a managed certificate, HTTPS redirect, and TLS 1.2 minimum.
- **Front Door WAF policy**: Prevention mode, Microsoft Default Rule Set 2.1 plus Bot Manager, rate-limit rule, geo-filter if required.
- **Manual step (must be in the runbook):** approve the Front Door private endpoint connection on each App Service. Script it: `az network private-endpoint-connection approve`.

**Identity and secrets**
- A regional Key Vault per stamp, synced by the pipeline. Keep RBAC, purge protection and private endpoints; add a delete lock.
- GitHub Actions deploys through an **Entra app with a federated credential per GitHub environment** (dev and prod, no secrets):
  - `Contributor` at subscription scope.
  - `Role Based Access Control Administrator`, with a **condition** that restricts which roles it can assign.
- The admin group gets PIM-eligible roles. This is documented, since PIM is a tenant configuration and not Bicep.

**Data and application resilience**
- Storage: prod **RA-GZRS** (geo-copy to East US) plus the F7 data protection. The DR stamp consumes it through a private endpoint on the secondary endpoint (`blob-secondary` group ID).
- App Service: P-v3 zone-redundant in the primary (capacity ≥3), minimum instances in DR. Deployment is identical across regions through the pipeline; recovery means redeploy, not App Service backup, which would need a SAS and conflicts with `allowSharedKeyAccess: false`.
- **Recovery Services vault** per region: GRS, cross-region restore, soft delete, immutability. Covers management VMs.
- **Application Insights**, workspace-based, ingesting through AMPLS.

**Monitoring, detection and response**
- **Azure Monitor Private Link Scope (AMPLS)**, one for the whole network, private-only ingestion and query mode. Add private DNS zones: `privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net` (plus the existing blob zone).
- **VNet flow logs** (the NSG flow-log replacement) for both regions: to a dedicated flow-log storage account, plus **Traffic Analytics** to the workspace. Verify whether identity-based storage access is supported given shared key is disabled; otherwise document the exception.
- **Subscription Activity Log** diagnostic setting to the workspace.
- **Microsoft Sentinel** on the central workspace. Data connectors: Azure Activity, Defender for Cloud, Azure Firewall, Key Vault, Front Door WAF, and Entra ID (tenant admin; a manual runbook step). Enable the analytics rule templates.
- **Action group** plus alerts:
  - Firewall health below 90% and SNAT utilisation.
  - Front Door origin health, and WAF block spikes.
  - App Service 5xx and health check.
  - Key Vault availability and denied requests.
  - VPN gateway P2S connection count.
  - Backup job failure.
  - Service Health for both regions.

**Governance and posture**
- **Defender for Cloud**: Servers P2, App Service, Storage (with malware scanning), Key Vault, Resource Manager, and Defender CSPM. Set security contacts and auto-provisioning.
- **Azure Policy** (subscription):
  - Microsoft Cloud Security Benchmark initiative, audit.
  - Deny public network access on Storage, Key Vault and Web.
  - Deny public IPs except the allowed firewall, Bastion and gateway PIP names.
  - Deploy-if-not-exists diagnostic settings to the workspace.
  - Allowed locations: WUS3, EUS, global.
- **Resource locks** (`CanNotDelete`) in prod on hubs, firewalls, Key Vaults, DNS zones, the workspace and Front Door.

---

## 4. Code structure changes

- Change `main.bicep` to **`targetScope = 'subscription'`**. It creates `rg-defenstack-global`, `rg-defenstack-wus3` and `rg-defenstack-eus`, and calls:
  - `modules/global.bicep` (new): Front Door, WAF, DNS zones and links, workspace, Sentinel, AMPLS, parent firewall policy, action group.
  - `modules/regionStamp.bicep` (new), **twice**: it composes the existing modules per region (`hubNetwork`, `azureFirewall`, `spokeNetwork`/`vnet`, `appService`, `keyVault`, `storage`, `privateConnectivity`, `networkIntegration`, `virtualMachine`). Its params are `regionRole` ('primary' | 'secondary'), `addressPlan` and `deployAdminAccess`.
  - `modules/governance.bicep` (new, subscription scope): Defender pricings, security contacts, Policy assignments, Activity Log.
- New regional modules:
  - `bastion.bicep`
  - `vpnGateway.bicep`
  - `recoveryVault.bicep`
  - `flowLogs.bicep`
  - `alerts.bicep`
  - `frontDoor.bicep`, called from global
  - `appInsights.bicep`
- Existing modules to modify:
  - `privateConnectivity.bicep`: stop creating the DNS zones; accept zone IDs from global.
  - `hubNetwork.bicep`: add the Bastion subnet and GatewaySubnet (conditional), plus the GatewaySubnet route table.
  - `azureFirewall.bicep`: Premium, zones, child policy.
  - The other F-items from §2.
- Parameter files: `params/dev.bicepparam` and `params/prod.bicepparam`, non-secret and committed. Secret overlays are local and git-ignored.
- Existing scripts are kept. `Set-AzureResourceGroupBudget.ps1` gets one run per new RG, documented.
- **Migration note:** changing the scope and RG layout means redeploying from new; it is not an in-place upgrade of `defenStack`. The runbook must include a migration procedure: stand up the new stack, cut DNS/users over, then use the README's existing **Safe teardown** section for the old RG.

---

## 5. Phased implementation order

Each phase is one PR with the Bicep, docs, lint and what-if, and a dev deployment.

| Phase | Scope | Key deliverable docs |
|---|---|---|
| 0 | F1–F13 fixes, `bicepconfig.json`, `.gitignore`, **GitHub Actions**: lint, `bicep build`, PSRule for Azure, what-if as PR comment, environment approvals; OIDC federated identity | `docs/runbooks/00-pipeline-and-identity.md` |
| 1 | Subscription scope, `global.bicep`, `regionStamp.bicep` ×2, address plan, param files | `docs/architecture/overview.md`, `docs/runbooks/01-deploy-stack.md`, `docs/runbooks/01a-migrate-from-defenstack.md` |
| 2 | Firewall Premium, zones, parent/child policy, IDPS, threat intel Deny, locks | `02-firewall.md` (rule change procedure, allowlist request process) |
| 3 | Bastion, P2S VPN with Entra, gateway transit, route fixes, jump host with Entra login and JIT | `03-admin-access.md` (VPN client setup per OS, Bastion connect, break-glass) |
| 4 | Front Door Premium, WAF, Private Link origins, PE approval, custom domain | `04-ingress.md` (DNS cutover, WAF tuning/exclusions, PE approval) |
| 5 | Storage GZRS and data protection, App Service hardening and ZR, regional Key Vaults, App Insights | `05-app-and-data.md` (secret sync, restore from soft delete/PITR) |
| 6 | AMPLS, flow logs and Traffic Analytics, Activity Log, alerts, retention, Sentinel and connectors | `06-monitoring-and-sentinel.md` (alert triage, Sentinel connector enablement) |
| 7 | Defender plans, Policy assignments, security contacts | `07-governance.md` (policy exemption procedure, Defender recommendation handling) |
| 8 | Recovery Services vaults, hub↔hub peering, DR enablement flag | `08-dr-failover.md` (**failover and failback step by step, RTO/RPO, drill log**) |

---

## 6. Documentation standard (mandatory for every phase)

- `docs/architecture/overview.md`: Mermaid diagrams (topology, ingress flow, egress flow, admin flow, DNS resolution), address plan, resource inventory per RG.
- `docs/decisions/ADR-NNN-*.md`: one per non-obvious choice. Examples: Front Door over App Gateway, warm-standby DR, DDoS not selected, TLS inspection outcome, flow-log storage auth exception.
- `docs/runbooks/NN-<component>.md`, with these fixed sections:
  1. **Purpose and scope**: resources created, owning module file.
  2. **Prerequisites**: roles, feature/provider registrations (e.g. `EncryptionAtHost`, `Microsoft.Cdn`, `Microsoft.SecurityInsights`), tools and versions, network path.
  3. **Parameters**: table of name, default, prod value and rationale.
  4. **Step-by-step deployment**: numbered PowerShell/az commands, including `validate` and `what-if` with what to check in the output.
  5. **Manual or post-deployment steps**: e.g. PE approval, VPN profile distribution, Entra consent, Sentinel Entra connector.
  6. **Validation**: commands with the **expected output**, e.g. `nslookup <kv>.vault.azure.net` → `10.0.1.x`; `curl` via Front Door → 200 while the direct app hostname → 403; effective routes show `0.0.0.0/0 → firewall`.
  7. **Rollback**.
  8. **Operations**: rotation, scaling, rule changes, cost drivers.
  9. **Troubleshooting**: known errors.
- `docs/cost.md`: Pricing Calculator estimate per phase. The dominant cost drivers are 2× Firewall Premium, the VPN gateway, Bastion, Front Door Premium, Sentinel ingestion and Defender plans. Budget thresholds are updated through the existing script.
- The README keeps a short overview and links to `docs/`. The long procedures (teardown, Key Vault secrets) move into runbooks.
- **Definition of done** for each PR: runbook merged; its procedure executed end-to-end in dev by someone following only the doc; the validation section's outputs pasted into the PR.

---

## 7. Verification (end-to-end)

1. **Static checks:** `bicep lint` / `bicep build` on all files (as the README does today), plus PSRule for Azure in CI with zero errors.
2. **Pre-deployment checks:** `az deployment sub validate` and `az deployment sub what-if` with `params/dev.bicepparam`.
3. **Connectivity tests** in dev:
   - P2S connect → resolve and reach Key Vault/Storage private endpoints.
   - Bastion → jump host.
   - A Front Door URL returns 200 and a WAF test payload (e.g. `?q=<script>`) returns 403.
   - The direct `*.azurewebsites.net` is refused.
   - Firewall logs show denied non-allowlisted egress.
4. **Security posture:** Defender secure score and recommendations reviewed; Policy compliance shows no non-compliant deny-scope resources; Sentinel receives firewall, WAF and Key Vault logs (KQL checks in the runbook).
5. **Availability:**
   - Zone redundancy confirmed via `az` queries (firewall zones, App Service plan `zoneRedundant`).
   - **DR drill:** disable the primary origin in Front Door; traffic serves from East US. Record the observed RTO in `08-dr-failover.md`.
   - Storage geo-replication status and last sync time checked.

---

## 8. Next steps after approval (superpowers workflow)

1. Save this design as the spec at `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` and commit it.
2. Invoke **superpowers:writing-plans** to produce a detailed task-level implementation plan for Phase 0 and Phase 1 first. Later phases each get their own plan when reached.
3. Execute phase by phase under the definition of done above.
