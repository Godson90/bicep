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

## Dominant future cost drivers
From `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §6, the
resources expected to dominate spend in later phases (not present in Phase 0):
- Two Azure Firewall Premium instances (hub-to-hub, later phase)
- VPN gateway
- Azure Bastion
- Azure Front Door Premium
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
