# ADR-015: VPN gateway: VpnGw1AZ in dev, VpnGw2AZ in prod, always active-active

## Context
The spec (§3) selects `VpnGw2AZ` for point-to-site access. The spec's definition of done (§6) requires every runbook to be executed end-to-end in dev, so dev needs a working VPN gateway too, not only Bastion. Dev carries a handful of admin sessions. The spec sizes `VpnGw2AZ` for prod, and in dev it would add cost without adding anything the runbook tests.

PSRule for Azure flags a non-active-active gateway (`Azure.VNG.VPNActiveActive`), and a gateway without a customer-controlled maintenance window (`Azure.VNG.MaintenanceConfig`). Point-to-site works on active-active gateways. The only extra resource is a second Standard public IP, since the gateway's hourly rate does not change.

## Decision
- The stamp uses `VpnGw2AZ` in prod and `VpnGw1AZ` in dev (`isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'` in `modules/regionStamp.bicep`). `modules/vpnGateway.bicep` accepts only the zone-redundant `VpnGw1AZ`–`VpnGw3AZ` SKUs.
- Every gateway is **active-active**, with one zonal Standard public IP per instance (zones 1/2/3).
- Every gateway has a customer-controlled maintenance window: Sundays 06:00 UTC, 5 hours (the minimum Azure accepts). The jump host's Update Manager window (Sundays 02:00 UTC, 3 hours) ends before it starts.
- The user chose this option when Phase 3 was planned (dev: Bastion plus a smaller VPN gateway).

## Consequences
- Dev tests the same gateway type, generation, authentication and topology as prod. Only the throughput and connection limits differ.
- Planned maintenance or an instance failure drops only the sessions on one instance, and the clients reconnect.
- Each region with admin access has three Standard public IPs: Bastion, plus two for the gateway (`docs/cost.md` "Phase 3 delta").
- Resizing within the AZ family (runbook 03 §8) happens in place, so dev can be raised to `VpnGw2AZ` without redeploying the gateway.

## Revisit when
Dev needs to load-test VPN throughput, or prod session counts approach the `VpnGw2AZ` point-to-site connection limit (review the monthly P2S connection counts in runbook 03 §8).
