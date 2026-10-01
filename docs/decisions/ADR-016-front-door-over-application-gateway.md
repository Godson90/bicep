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
