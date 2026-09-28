# ADR-003: Dev firewall threat intelligence stays in Alert mode (PSRule Azure.Firewall.PolicyMode accepted)

## Context
PSRule for Azure's `Azure.Firewall.PolicyMode` rule (AZR-000399) recommends
`threatIntelMode: 'Deny'` so the firewall blocks, rather than only logs, traffic to or
from IP addresses, domains and URLs on Microsoft's threat intelligence feed.

`main.bicep` already sets this per environment (F9, commit `5dea25d`):

```bicep
threatIntelMode: environmentType == 'prod' ? 'Deny' : 'Alert'
```

`params/dev.bicepparam` deploys with `environmentType = 'dev'`, so PSRule evaluates
the dev parameter file with `threatIntelMode: 'Alert'` and fails the rule. Production
already uses `Deny`. No later phase changes the dev value: Phase 2's "threat intel
Deny" deliverable (`docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`
§5) is about the greenfield subscription-scope build reaching parity with this
Phase-0 in-place default for prod, not about changing the dev default.

## Decision
Keep `Alert` mode for non-prod environments so a threat-intel false positive during
development and testing logs instead of silently dropping traffic, which would be
harder to diagnose than an over-permissive dev network. Exclude
`Azure.Firewall.PolicyMode` in `ps-rule.yaml` with a reference to this ADR, scoped to
the dev parameter file PSRule evaluates in CI.

## Consequences
- Malicious IP/domain/URL traffic through the dev firewall is logged (`AZFWApplicationRule`/
  `AZFWNetworkRule` with `Action: Alert`) but not blocked. Dev is not internet-facing
  and carries no production data, which limits the blast radius.
- Production deployments must continue to pass `environmentType = 'prod'`, which
  already yields `Deny`; this ADR does not change prod behavior.
- If a prod-like parameter file (for example a `staging.bicepparam`) is added before
  Phase 2, evaluate whether it should also pass `environmentType = 'prod'` for firewall
  purposes rather than relying on this exclusion.
