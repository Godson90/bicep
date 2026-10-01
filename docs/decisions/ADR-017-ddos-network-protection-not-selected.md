# ADR-017: Azure DDoS Network Protection not selected

## Context
Azure DDoS Network Protection is a per-VNet-plan add-on with a significant fixed monthly fee. It covers public IPs in protected VNets with adaptive tuning, attack telemetry, and cost protection. Every Azure public IP already gets **DDoS infrastructure protection** at no cost.

After Phase 4, this project's public IPs are:
- **Application traffic:** none in any region. Users reach the app only through Azure Front Door (`ADR-016`), whose edge absorbs volumetric L3/L4 attacks as part of the platform. The WAF handles L7: Default Rule Set, Bot Manager, and the per-IP rate limit.
- **The firewall public IP** in each region is egress-only. There is no DNAT rule, so nothing listens on it inbound.
- **The Bastion and VPN gateway public IPs** (Phase 3) are admin entry points. Both services are Microsoft-managed and authenticate with Entra ID. Losing them to an attack costs admin access, not application availability, and Bastion and the VPN back each other up (runbook 03 §5.6).

The spec (§3) states: "DDoS: not selected. Front Door absorbs L3/4 attacks at the edge. The firewall PIP is egress-only (no DNAT), so this risk is accepted and recorded in an ADR."

## Decision
Do not deploy a DDoS protection plan. Rely on Front Door edge protection for application traffic, and on the free infrastructure protection for the remaining public IPs.

## Consequences
- No DDoS Network Protection fee.
- A volumetric attack aimed at a regional public IP, rather than at Front Door, is mitigated only by the platform-level infrastructure protection. There is no adaptive tuning, no attack-analytics telemetry, and no cost-protection credit.
- An attack on the Bastion or VPN gateway IPs can deny admin access in that region. The break-glass paths (runbook 03 §5.6) use the control plane: `az vm run-command` and serial console.

## Revisit when
- A public IP starts serving application traffic directly, for example a DNAT rule, a public load balancer, or Application Gateway.
- A regulator or customer contract requires DDoS Network Protection.
- An incident shows the infrastructure-level protection was insufficient.
