# Cost estimation

## Purpose
Tracks how this project estimates and monitors Azure spend per phase, and lists the
cost drivers each phase introduces so a reviewer can see what changed and why, without
this document itself asserting prices that go stale.

## How estimates are produced
- Every phase's estimate comes from the
  [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/), built
  from that phase's actual resource SKUs, region, and the parameters in
  `params/<environment>.bicepparam`.
- This document does **not** invent or hardcode prices. Prices vary by region,
  currency, negotiated discount (EA/CSP), and change over time; a number written here
  would mislead as soon as any of those change. Instead, each phase gets a Pricing
  Calculator link/export, refreshed when the phase's resource set changes, and a
  measurement method (below) to validate the estimate against actual usage.
- Actual spend is reviewed in Azure Cost Analysis at the resource-group scope, since
  Phase 0 does not yet apply a tagging convention (`docs/decisions/ADR-002-no-tagging-convention-yet.md`)
  that would allow per-resource or per-owner attribution.

## Phase 0 delta
Phase 0 does not add new resource types; it changes configuration on existing
resources. The table below lists what changed, why it can move cost, and how to
measure the actual impact after a week of dev traffic.

| Cost driver | What changed (F-ref) | How to measure |
|---|---|---|
| Log Analytics retention 30 → 90 days | F10: workspace `retentionInDays` | KQL: `Usage \| where TimeGenerated > ago(7d) \| summarize GB = sum(Quantity) / 1000 by DataType` — daily ingestion by table; days 31–90 are billed as data retention per GB-month until Sentinel is enabled (Phase 6, then the first 90 days are included) |
| Blob versioning, soft delete, change feed | F6/F7: `blobServices/default` data protection properties | Storage account capacity metrics (`UsedCapacity`, blob index) in Azure Monitor; versioned/soft-deleted blobs are billed as stored capacity in addition to the live data |
| Blob diagnostic logs ingestion | F6/F7: new `blob-diagnostics` setting (`StorageRead`/`StorageWrite`/`StorageDelete`) | Same `Usage` KQL query above, filtered to `DataType == "StorageBlobLogs"` |
| Firewall dedicated-table logs | F9: `logAnalyticsDestinationType: 'Dedicated'` on `firewall-diagnostics` | Same ingestion volume as before (moves from `AzureDiagnostics` to `AZFW*` tables); confirm with the `Usage` query filtered to `AZFWNetworkRule`/`AZFWApplicationRule`/`AZFWDnsQuery`/`AZFWThreatIntel` — no expected net change versus the prior `AzureDiagnostics` volume |
| AMA / DCR ingestion | F3: Azure Monitor Agent + data collection rule | Only applies if `enableVirtualMachine=true`; measure with the `Usage` query filtered to `DataType in ("Syslog", "Event", "Perf")` (or the relevant table for the enabled VM OS) |

**Estimate:** fill in from the Pricing Calculator after the first week of dev data
collection above gives real ingestion/capacity numbers to plug into the calculator,
rather than guessing.

## Phase 1 delta
Phase 1 moves from one resource group in one region to a subscription-scope,
multi-region layout (`docs/architecture/overview.md`). It changes both resource
**counts** (a second region for prod) and **SKUs** (zone redundancy, GRS, a bigger
App Service plan). As with every phase, **fill in the actual dollar estimate from the
Pricing Calculator; do not invent prices.**

| Environment | Cost driver | What changed / why it costs more |
|---|---|---|
| Dev | Azure Firewall Standard ×1 | Unchanged instance count, but now zonal (`availabilityZones: ['1','2','3']`) — zone redundancy itself doesn't add an hourly charge, but cross-zone traffic between the firewall and zonal dependents adds inter-zone data processing charges that a non-zonal deployment didn't incur |
| Dev | App Service Plan ×1 (S1-equivalent, 1 instance, non-zonal) | Same shape as Phase 0; no change from Phase 1 |
| Prod | Azure Firewall Standard ×2 | One per region (`rg-defenstack-prod-wus3`, `rg-defenstack-prod-eus`) instead of one total — the warm-standby region's firewall is deployed, not scaled up, so it's billed continuously even while idle (`ADR-008`) |
| Prod | App Service Plan: P2V3 ×3 (WUS3, zone-redundant) + P2V3 ×1 (EUS) | Primary region moves to a 3-instance, zone-redundant Premium v3 plan; the secondary region adds a fourth, single-instance Premium v3 plan that did not exist in Phase 0 |
| Prod | Storage account GRS ×2 | One GRS account per region (was one LRS account total in Phase 0) — GRS itself also costs more per GB than LRS, independent of the region count |
| Prod | Key Vault ×2 | One per region (was one total) |
| Prod | Private endpoints ×6 | Three per region (blob, sites, vault) × two regions (was three total) |
| Prod | Log Analytics workspace replication | The single workspace now replicates to East US (`replication.enabled: true`); replication is charged per GB replicated, in addition to the existing ingestion/retention charges |
| Prod | Cross-region replication traffic | Storage GRS replication and workspace replication both move data WUS3 → EUS, which is billed as network egress between regions |
| Both, after migration | `defenStack`'s firewall and App Service plan retired | Runbook 01a tears down the Phase 0 resource group once dev's inventory (§3) shows nothing to migrate; this removes one firewall and one plan from the bill entirely |

**Estimate:** fill in from the Pricing Calculator, built from the actual SKUs above per
region, once dev's Phase 1 stack has run for a representative period. Prod's estimate
should be built before the first prod deploy (runbook 01 §4), since the warm-standby
region is billed from the moment it's deployed, not from the moment of an actual
failover.

## Phase 2 delta
Phase 2 upgrades every stamp's Azure Firewall from Standard to **Premium**
(`modules/azureFirewall.bicep`, `firewallTier: 'Premium'` for every
environment) and adds IDPS. It does not change resource counts — the same
one firewall per deployed stamp as Phase 1 — only the SKU tier and the
policy features enabled on it. As with every phase, **fill in the actual
dollar estimate from the Pricing Calculator; do not invent prices.**

| Environment | Cost driver | What changed / why it costs more |
|---|---|---|
| Dev | Azure Firewall **Premium** ×1 (was Standard ×1) | Premium's hourly rate is higher than Standard's, plus Premium's data processing rate per GB is higher than Standard's — IDPS deep packet inspection adds processing overhead even though TLS inspection itself is deferred (`ADR-011`) |
| Prod | Azure Firewall **Premium** ×2 (was Standard ×2) | Same per-instance Premium delta as dev, doubled — one per region (`rg-defenstack-prod-wus3`, `rg-defenstack-prod-eus`), including the idle warm-standby region's firewall (`ADR-008`) |
| Both | No change in instance count, zone count, or rule-processing volume from Phase 1 | The delta is purely the Standard → Premium SKU rate and Premium's data-processing rate, not a change in what traffic flows through the firewall |

**Estimate:** fill in from the Pricing Calculator, using the Premium SKU's
hourly and data-processing rates for the deployed region(s), once dev has run
on Premium for a representative period to measure actual data-processing
volume (`AZFWApplicationRule`/`AZFWNetworkRule`/`AZFWIdpsSignature` ingestion
via the same `Usage` KQL pattern as the Phase 0 table above).

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
- Microsoft Sentinel ingestion
- Microsoft Defender plans

## Budget thresholds
Resource-group budgets and their alert thresholds are created and updated through
`scripts/Set-AzureResourceGroupBudget.ps1` (`-ResourceGroupName`, `-BudgetName`,
`-MonthlyAmount`, `-ContactEmail`, plus optional threshold/date parameters). Run it
whenever a phase's estimate materially changes the expected monthly spend; see the
script's parameter help for details, and
`scripts/Grant-AzureResourceGroupBudgetAccess.ps1` for granting the identity that runs
it the required Cost Management access.
