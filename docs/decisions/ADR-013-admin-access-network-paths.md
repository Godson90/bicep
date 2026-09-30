# ADR-013: Admin access network paths: SSH/RDP through the firewall, private endpoints direct

## Context
Phase 3 adds two admin entry points per region: Azure Bastion in `AzureBastionSubnet`, and a point-to-site VPN gateway in `GatewaySubnet`. Admins need to reach two kinds of targets in the spoke: the jump host in `management` (SSH 22 / RDP 3389), and the private endpoints in `private-endpoints` (HTTPS 443 to Key Vault, Storage and App Service). F2 already disabled BGP route propagation on the spoke route tables. The spec (§2 F2) adds a `GatewaySubnet` route table that sends spoke prefixes to the firewall.

Three platform behaviours shape what is possible:

1. **Private endpoint /32 routes.** Every private endpoint injects a /32 system route into its VNet and every peered VNet, including `GatewaySubnet`. A /32 is more specific than the `GatewaySubnet` UDR for the whole spoke prefix, so VPN traffic to a private endpoint skips the firewall. The /32 can be overridden only by enabling route-table network policies on `private-endpoints`. That would also override it for App Service integration and the jump host, whose `0.0.0.0/0 → firewall` routes would then pull all their private endpoint traffic through the firewall. The firewall has no rules for that traffic, and Microsoft recommends SNAT (application rules) for it to keep flows symmetric. That is a redesign of the Phase 0–2 data path, not an admin-access change.
2. **Bastion must open SSH/RDP.** Its NSG needs outbound 22/3389. PSRule `Azure.NSG.LateralTraversal` flags any NSG that allows this.
3. **The firewall IP is needed before the firewall exists.** The hub VNet (and so `GatewaySubnet` and its route table) is created before the firewall, which is attached to `AzureFirewallSubnet`. Reading the firewall's IP from its output would create a dependency cycle.

## Decision
- **VPN → jump host (22/3389) goes through the firewall.** The `GatewaySubnet` route table sends each spoke prefix to the firewall. The `management` route table (`0.0.0.0/0 → firewall`, BGP propagation off) sends the replies back through it, so the flow is symmetric. The shared rule group `admin-access` (priority 120) allows only the region VPN client pool to the `management` subnet on TCP 22/3389, and the firewall logs every session.
- **VPN → private endpoints (443) goes direct**, over the /32 routes. The `private-endpoints` NSG admits the VPN client pool on 443 only. Every service behind a private endpoint still requires Entra ID authentication and RBAC, since Storage shared keys are disabled and Key Vault uses RBAC. No firewall rule is added for this path; it would never match.
- **Bastion → jump host goes direct** over the hub↔spoke peering. `AzureBastionSubnet` does not support UDRs. The replies follow the more specific hub peering route, so the flow is symmetric without the firewall. The Bastion NSG allows SSH/RDP egress **only to the `management` subnet**, and denies all other SSH/RDP egress. `Azure.NSG.LateralTraversal` is suppressed for the Bastion NSGs by name (`.ps-rule/Suppression.Rule.yaml`, `DefenStack.BastionSessionEgress`). Every other NSG now carries `deny-ssh-rdp-outbound`, and the global `ps-rule.yaml` exclusion is removed.
- **The firewall IP is computed as `cidrHost(firewallSubnetPrefix, 3)`**, the `.4` address, which Azure Firewall always takes in an empty `AzureFirewallSubnet`. The hub uses it for the `GatewaySubnet` route and the hub DNS server (`ADR-005`). Runbook 03 §4 step 7 and §6 check it against the deployed firewall.
- **Admin sources are derived, not configured.** The `management` NSG and the jump host NIC NSG allow `AzureBastionSubnet` and the region VPN client pool; `managementSourceCidrs` only adds extra sources.
- **The Bastion and gateway subnets always exist**, even with `deployAdminAccess = false`, so that turning admin access on or off never adds or removes hub subnets. The spec (§4) describes them as conditional; they cost nothing, and a conditional subnet would fail to delete while in use.

## Consequences
- Admin SSH/RDP from the VPN is visible in `AZFWNetworkRule`, and subject to IDPS and threat intelligence. Admin HTTPS to private endpoints is visible only in each service's own logs (Key Vault `AuditEvent`, Storage `StorageRead`/`StorageWrite`, App Service HTTP logs), not in the firewall logs.
- A compromised admin workstation on the VPN can reach private endpoints on 443 without passing the firewall. It still needs a valid Entra token with data-plane RBAC on each service.
- Bastion sessions to the jump host are audited in `MicrosoftAzureBastionAuditLogs`, not in the firewall.
- If a firewall is ever created at a different address (for example in a non-empty subnet), VPN-to-spoke traffic and VPN DNS break until the computed IP is corrected (runbook 03 §9).

## Revisit when
- A phase moves private endpoint traffic through the firewall for every source (route-table network policies plus SNAT application rules). VPN traffic to private endpoints would then join it.
- Azure Firewall exposes its private IP in a way that can be referenced before the firewall is created, or supports a static private IP.
