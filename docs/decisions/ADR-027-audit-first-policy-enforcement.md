# ADR-027: Azure Policy goes live audit-first through enforcementMode, with exemptions instead of notScopes

## Context
The spec (§3) asks for the Microsoft cloud security benchmark in audit, deny rules for public network access on Storage, Key Vault and Web, a public IP allowlist, allowed locations (West US 3, East US, global) and diagnostic settings. Switching deny rules on against an existing estate can break a deployment that already works, and some resources legitimately differ from a rule: the flow-log accounts (`ADR-023`), and the legacy `defenStack` group until runbook 01a removes it.

## Decision
- **Every deny-type assignment takes `enforcementMode` from one parameter, `denyEnforcement` (`DoNotEnforce` | `Default`, default `DoNotEnforce`).** Under `DoNotEnforce`, Azure reports compliance and blocks nothing. After about a week and a clean review (`az policy state summarize`, runbook 07 §5.2), the operator commits `Default`.
- The built-ins whose effect is a parameter still get `effect: 'Deny'` (Storage, Key Vault, App Service apps and slots, Function apps and slots). The audit phase lives in the enforcement mode, not in the effect, so the switch changes one value.
- **Locations:** "Allowed locations" lists `westus3`, `eastus` and `global`. The built-in is believed to skip `global` already; listing it is harmless either way, and the point is **unverified** (runbook 07 §9). "Allowed locations for resource groups" lists the two regions. Neither gets an `effect` parameter: the first has none, and the second defaults to Deny (also **unverified**).
- **Public IPs:** no built-in denies by name, so the custom definition `defenstack-deny-public-ip-except-allowlist` denies any public IP whose name is not in `allowedNames`. Its effect is fixed at `deny`, because the audit phase is the enforcement mode. `governance.bicep` computes the allowlist from the naming convention for every environment and region, including the warm standby's admin-access IPs, and a test fails if any module other than the firewall, Bastion and VPN gateway creates a public IP.
- **Diagnostic settings are audited, not deployed:** "Audit diagnostic setting for selected resource types" (`AuditIfNotExists`, enforced), with no managed identity and no remediation. This replaces the spec's DeployIfNotExists item: every module already creates its settings, and a remediation identity would need write rights across the subscription. The list holds the types whose modules send both logs and metrics. The flow-log accounts' blob services have no setting and report non-compliant; that is expected.
- **The benchmark is assigned as `defenstack-mcsb`,** enforced (its members audit). Defender for Cloud also assigns it, as "ASC Default". Both are kept: `defenstack-mcsb` is under code review and cannot be changed in the portal unnoticed. The cost is duplicate compliance rows, and Defender's **Exempt** button acts only on ASC Default.
- **Exemptions, never `notScopes`:** the flow-log accounts get a `Mitigated` exemption from the Storage assignment (no expiry, citing `ADR-023`); the legacy group gets a dated `Waiver` from every deny assignment, which expires on its own. An exemption carries a category, a reason and an expiry, and can be added without editing the assignment.

## Consequences
- **The ordering trap.** An exemption needs its target to exist, and under `Default` a new flow-log account is denied before its exemption can exist. Adding an environment or region is therefore: set `DoNotEnforce`, deploy the workload, add it to governance, redeploy governance, set `Default` (runbook 07 §5.3).
- Azure-created groups outside the two regions (for example `NetworkWatcherRG`, `DefaultResourceGroup-*`) appear in the audit week and must be exempted or removed before the switch.
- Every deny assignment carries a non-compliance message pointing to runbook 07, and `metadata.assignedBy` names `governance.bicep`.
- The legacy waiver's date, `2027-03-31`, is a placeholder to confirm.

## Revisit when
The legacy group is gone, policy exemptions reach GA, or the platform adds a remediation identity for DeployIfNotExists.
