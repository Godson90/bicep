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
