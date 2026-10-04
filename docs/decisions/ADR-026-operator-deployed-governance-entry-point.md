# ADR-026: Governance is a separate, operator-deployed entry point

## Context
The spec (§3 "Governance and posture", §4) puts Defender for Cloud plans, the security contact and Azure Policy in a `governance` module. Every other module is deployed by `deploy.yml` with the per-environment pipeline identity, which holds `Contributor` on its own resource groups and a narrow custom role at subscription scope (`ADR-009`). Defender pricings, policy definitions, assignments and exemptions, and custom role definitions are subscription-wide and security-relevant. Granting them to the pipeline identity would let any merged workflow change weaken the subscription's guardrails. Dev and prod may share one subscription, while the pipeline deploys per environment.

## Decision
- **`governance.bicep`** is a second root entry point (`targetScope = 'subscription'`) next to `main.bicep`, with its own `params/governance.bicepparam`, one file per subscription. An operator deploys it with `az deployment sub create` after activating **Security Admin** and **User Access Administrator** (or **Owner**) through PIM (runbook 07 §2, §4).
- `main.bicep` never references it, and `deploy.yml` never deploys it. `deploy.yml`'s path filter excludes `modules/governance/**` and `params/governance.bicepparam`, so a governance-only commit does not trigger a workload deploy, which would reset the jump host NSG and end active JIT grants (`ADR-028`). The pipeline identity script is unchanged.
- CI still covers it: the lint and build tests recurse into `modules/governance/`, the parameter tests build `governance.bicepparam`, and PSRule (`-InputPath params/`) expands it. `governance.json` is committed and drift-tested, like `main.json`.
- Security contact addresses are not committed: the parameter file reads `SECURITY_CONTACT_EMAILS`. CI's PSRule step sets an `example.com` placeholder.
- **Defender plans:** Servers `P2` with `AgentlessVmScanning`; App Service; Storage `DefenderForStorageV2` with on-upload malware scanning (capped by `malwareScanCapGbPerMonth`, default 5000 GB per account per month) and sensitive data discovery; Key Vault; Resource Manager; Defender CSPM. One plan is written at a time (`@batchSize(1)`), because parallel pricing writes conflict.
- **Not set:** `MdeDesignatedSubscription`, which designates a subscription for directly onboarded non-Azure machines (this platform has only Azure VMs, which get Defender for Endpoint through the default integration); and `autoProvisioningSettings`, the retired Log Analytics agent toggle that agentless scanning replaces. `KeyVaults`, `Arm`, `AppServices` and `CloudPosture` send no sub-plan or extensions, so Azure applies its current defaults.

## Consequences
- Governance changes need an operator with elevated, time-bound roles, and they are not gated by the GitHub environment approvals. Review happens in the pull request, and the operator runs `what-if` first (runbook 07 §4).
- Nothing redeploys governance automatically. The operator redeploys it after every change to the governance files, and whenever an environment or region is added (runbook 07 §5.3).
- The workload depends on governance for JIT (Defender for Servers), so governance deploys first.
- Live-only items (default sub-plans, CloudPosture's default extensions, the malware cap property) are listed in runbook 07 §9.

## Revisit when
The pipeline gains a separate, approval-gated governance identity, or the platform moves to a management-group hierarchy where policy belongs above the subscription.
