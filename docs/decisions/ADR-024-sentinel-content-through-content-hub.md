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
