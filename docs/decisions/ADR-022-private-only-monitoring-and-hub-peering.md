# ADR-022: Azure Monitor is private-only through one AMPLS, and hub-to-hub peering moves to Phase 6

## Context
The spec (§3, F10) asks for Log Analytics and Application Insights to ingest and answer queries only over Private Link. Until Phase 6, both accepted public ingestion and queries (`ADR-021`). Microsoft's guidance is one Azure Monitor Private Link Scope (AMPLS) per DNS: every private endpoint on an AMPLS rewrites the same shared `privatelink.*` records, so a second endpoint would override the first for every network that shares the zones. All our VNets, in both regions, share one set of private DNS zones.

One endpoint in West US 3 means the East US App Service and management subnets must reach it across regions (the jump host is primary-only). Hub-to-hub global peering was planned for Phase 8 (DR). Without it, the East US Application Insights component could not send telemetry once public ingestion is off.

## Decision
- **One AMPLS per environment,** `ampls-defenstack-<env>`, in the global resource group, with ingestion and query access modes both `PrivateOnly` (`modules/monitorPrivateLinkScope.bicep`). It scopes the workspace and every regional Application Insights component.
- **The jump host's agent uses a regional data collection endpoint scoped into the AMPLS:** when `enableVirtualMachine` is true, `<vm>-dce` (public network access `Disabled`) is the VM's `configurationAccessEndpoint`, and `main.bicep` adds it to the scope (`modules/virtualMachine.bicep`).
- **One `azuremonitor` private endpoint,** `ampls-defenstack-<env>-pe`, in the primary spoke's existing `private-endpoints` subnet (`modules/monitorPrivateEndpoint.bicep`). It registers in four new shared zones (`privatelink.monitor.azure.com`, `privatelink.oms.opinsights.azure.com`, `privatelink.ods.opinsights.azure.com`, `privatelink.agentsvc.azure-automation.net`) and the existing blob zone. The new zones are linked like the others, and prod locks them like the others.
- **The workspace and the components disable public ingestion and public query.**
- **No lock on the AMPLS.** A `CanNotDelete` lock would also block deleting its scoped-resource children, so removing the secondary component's link after DR is turned off would fail. Turning DR off does not unlink the component by itself: deployments are incremental, so the scoped resource stays until an operator deletes it (runbook 06 §8).
- **Hub-to-hub global peering is brought forward from Phase 8,** prod with DR only (`deploySecondaryRegion`), both directions, with `allowForwardedTraffic: true` and no gateway transit (each hub has its own gateway) (`modules/hubPeering.bicep`).
- **Each `AzureFirewallSubnet` gets a route table** `<hub VNet>-firewall-rt`: the other region's spoke prefixes go to the other firewall's private IP, and `0.0.0.0/0` goes to `Internet`, which Azure requires on that subnet. BGP propagation stays on, so the firewall keeps learning the point-to-site client pool.
- **Only monitoring crosses regions.** The rule collection group `cross-region-monitoring` (priority 250) holds one collection per role:
  - **East US (Client):** a network rule `spoke-to-peer-azure-monitor`, TCP 443 from the East US `appservice-integration` and `management` subnets to the primary `private-endpoints` subnet. A network rule keeps the source address.
  - **West US 3 (Host):** an application rule `peer-spoke-to-azure-monitor`, HTTPS from the same East US subnets to the Azure Monitor FQDNs only. An application rule rewrites the source address to the firewall's own (SNAT), so the private endpoint replies to the West US 3 firewall. The primary spoke has no route back to East US, and Microsoft recommends SNAT for traffic to private endpoints.
  - **West US 3 private-endpoint NSG, the enforcement point:** the rule `allow-peer-monitoring-https` (priority 110) admits TCP 443 from its own `AzureFirewallSubnet`, the SNAT source, to the application security group `<spoke VNet>-ampls-asg` only. The AMPLS endpoint is that group's only member, so the firewall's SNAT address reaches no other private endpoint in the subnet. The firewall subnet is never an `allow-approved-https` source. The Host application rule filters on SNI, which without TLS inspection does not prove the destination address, so isolation rests on this NSG rule, not on the FQDN list. Every spoke has the (free) group; only the Host region gets the rule.
  - **Note:** the East US Client network rule still targets the whole primary `private-endpoints` subnet prefix. That is acceptable, because the West US 3 NSG rule above is what limits the cross-region traffic to the AMPLS endpoint.

## Consequences
- Nothing outside a connected network can send telemetry or run a query. Operators query over the VPN or from the jump host (runbook 06 §5.2). The portal Logs blade and the Sentinel pages fail from any other network.
- Queries sent through the Azure Resource Manager API cannot use Private Link. Tools that query this way stop working.
- Diagnostic settings, including the Activity Log, keep working: they use Azure's internal path, not the public endpoint.
- Prod pays for global peering in both directions, per GB (`docs/cost.md` "Phase 6 delta"). Microsoft does not recommend dual-firewall transit across regions for performance. It is acceptable here because only telemetry crosses.
- The East US firewall needs to see the reply to its network-rule flow, and the West US 3 application rule needs to match multi-label Azure Monitor hosts. Neither can be proved offline (runbook 06 §9 "Live-only risks", with the fallback).
- Adding a component to the scope later relies on Azure adding its DNS records to the existing endpoint. Runbook 06 §8 has the check.

## Revisit when
Phase 8 designs regional failover: the peering then carries DR traffic, and the AMPLS endpoint must still be reachable when West US 3 is down (a second endpoint in East US would need its own DNS).
