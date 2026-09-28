# ADR-005: Spoke VNet uses a single DNS server, the firewall's DNS proxy IP (PSRule Azure.VNET.SingleDNS accepted)

## Context
PSRule for Azure's `Azure.VNET.SingleDNS` rule (AZR-000264) recommends at least two
custom DNS servers on a VNet for redundancy when Azure-provided DNS is not used.

The spoke VNet (`modules/spokeNetwork.bicep` → `modules/vnet.bicep`) sets
`dnsServer: [firewallPrivateIp]`, one address, because Azure Firewall's built-in DNS
proxy (`dnsSettings.enableProxy: true` in `modules/azureFirewall.bicep`) is the
intended hub/spoke DNS resolution path: it lets the firewall log and filter DNS
queries and is a standard reference pattern for this topology.

Azure Firewall exposes exactly one private IP per deployment regardless of SKU or
availability-zone configuration (a zone-redundant Standard/Premium firewall still
presents a single IP configuration). Adding a second, independent DNS server would
mean standing up a second firewall or a separate DNS resolution path, which is a
different architecture, not a configuration tweak, and is out of scope for every
phase in `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §5 as
currently planned.

## Decision
Accept the risk: keep the single firewall private IP as the VNet's DNS server. Exclude
`Azure.VNET.SingleDNS` in `ps-rule.yaml` with a reference to this ADR.

## Consequences
- If the firewall is briefly unavailable (for example during a maintenance update),
  DNS resolution for the spoke VNet is also unavailable, coupling DNS availability to
  firewall availability. This mirrors the existing coupling of spoke egress to the
  firewall's forced-tunnel default route, so it is not a new failure mode.
- If a future phase introduces Azure DNS Private Resolver or a second firewall
  instance for DNS redundancy, revisit this ADR and remove the exclusion.
