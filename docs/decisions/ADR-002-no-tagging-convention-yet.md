# ADR-002: No resource tagging convention yet (PSRule Azure.Resource.UseTags accepted)

## Context
PSRule for Azure's `Azure.Resource.UseTags` rule (AZR-000166) recommends tagging every
resource with a standard convention (for example, owner, cost center, environment) so
that cost and ownership can be attributed and Azure Policy can enforce the standard.
Every resource in this stack currently deploys without tags, so the rule fails for the
whole template.

Defining a tagging convention is an organizational decision (which keys are mandatory,
what values they take, who owns enforcement) rather than an infrastructure defect. It
does not appear as a deliverable in any of the phases in
`docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §5, so there is no
later phase this finding can be attributed to.

## Decision
Accept the risk for Phase 0. `Azure.Resource.UseTags` is excluded in `ps-rule.yaml`
with a reference to this ADR. No tags are added to any module in this task.

## Consequences
- Cost and ownership cannot yet be attributed per resource via tags; cost review relies
  on `docs/cost.md` and resource-group-level review instead.
- When a tagging convention is agreed (recommended before Phase 1's `regionStamp.bicep`
  rewrite touches every module), add a `tags` parameter to `main.bicep` and thread it
  through each module, then remove this exclusion from `ps-rule.yaml`.
- No Azure Policy that enforces mandatory tags should be assigned against this resource
  group until the convention exists and resources are tagged, or compliant resources
  will be flagged non-compliant.
