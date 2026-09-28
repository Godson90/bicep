# ADR-009: Subscription-scope pipeline and hardened deployment identity

## Context
Phase 1 moves the layout to a subscription-scope, multi-region deployment
(`docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`,
`docs/decisions/ADR-008-warm-standby-and-dev-single-region.md`): each
environment now spans more than one resource group (`rg-defenstack-dev-global`,
`rg-defenstack-dev-wus3` for dev; `rg-defenstack-prod-global`,
`rg-defenstack-prod-wus3`, `rg-defenstack-prod-eus` for prod). A resource-group
scoped deployment (`az deployment group create`) can only target one resource
group, so the entry point must become a subscription-scope deployment
(`az deployment sub create`) that fans out to each resource group with
`resourceGroup(name)`. That, in turn, means the pipeline identity's Azure RBAC
can no longer be scoped entirely to one resource group: some permission has to
exist at the subscription itself just to run the deployment operation, while
the previous design already went to some effort (an ABAC-constrained
`Role Based Access Control Administrator`) to avoid granting the pipeline
identity broad rights. Widening that same `Contributor` + `Role Based Access
Control Administrator` pairing to subscription scope would hand the pipeline
identity control of every resource group in the subscription, including the
other environment's.

## Decision
- Operators pre-create the resource groups (`docs/runbooks/01-*.md`), and
  templates reference them with `resourceGroup(name)`; the pipeline identity
  never creates or deletes resource groups itself.
- Each environment keeps its own app registration and federated credential,
  scoped to that environment's GitHub environment (`dev`, `prod`) — unchanged
  from ADR-007's per-environment isolation, just carried forward to the new
  scope.
- At subscription scope, the pipeline identity holds only the new custom role
  **DefenStack Subscription Deployment Operator**, limited to exactly the
  nine actions `az deployment sub validate|what-if|create` needs: deployment
  read, deployment write, deployment validate, deployment whatIf, deployment
  operation read, deployment operation-status read, subscription /
  resource-group read, and subscription operation-results read (subscription-scope
  validate/what-if are asynchronous and poll
  `/subscriptions/{id}/operationresults/...`, which needs its own read action).
  It deliberately excludes `deployments/delete`,
  `deployments/cancel/action` and `deployments/exportTemplate/action` — none
  of those three is needed to validate, what-if or create a deployment (ARM
  prunes deployment history itself), and because this role's assignment is at
  subscription scope, granting them would let the dev identity cancel
  in-flight prod deployments, delete prod's deployment history, or export
  prod's templates. It grants no rights over any resource.
- Resource rights — `Contributor`, plus the existing ABAC-constrained
  `Role Based Access Control Administrator` — are granted **only on that
  environment's own resource groups**, exactly as before, just repeated once
  per resource group instead of once per environment.
- `scripts/New-GitHubDeploymentIdentity.ps1` takes `-ResourceGroupNames
  string[]` (replacing `-ResourceGroupName`) so operators pass every resource
  group for the environment in one run, and refuses to delegate `Owner`,
  `User Access Administrator`, `Role Based Access Control Administrator` or
  `Contributor` through `-DelegatableRoleDefinitionIds`, since delegating any
  of those would let the pipeline identity re-grant itself (or anything else)
  broader rights than the operator intended.

## Consequences
- Because the custom role's assignment is at subscription scope, its actions
  are inherited by every resource group underneath — including the other
  environment's. So the dev identity can **create and read** deployment
  records (the deployment's template metadata, non-secure parameters,
  outputs and errors) in any resource group of the subscription, including
  prod's. It cannot **cancel or delete** those deployment records, since
  `deployments/cancel/action` and `deployments/delete` are deliberately not
  in the role, and it cannot create, modify or delete any actual *resource*
  outside its own resource groups, since every nested resource write still
  needs `Contributor` (or narrower) rights on that specific resource group,
  which the identity does not have there. Consequently, prod's deployment
  parameters and outputs must never carry sensitive values — they already
  only carry names and resource IDs, and any secret-shaped value stays a
  `@secure()` parameter, which Azure Resource Manager omits from what a
  deployment record exposes.
- Every resource group a deployment touches must exist before the first
  deploy; `ResourceGroupNotFound` is the expected failure otherwise (see
  runbook 00b §9).
- `Contributor` at subscription scope is deliberately never used, because dev
  and prod share one subscription; scoping resource rights per resource group
  is what keeps the dev identity from reaching prod's resource groups (or vice
  versa) even though both identities can create deployment records anywhere.
- The custom role needs to replicate through Azure RBAC before the first role
  assignment against it succeeds; the script retries assignment of roles it
  just created (6 attempts, `-RoleReplicationWaitSeconds` apart) to absorb
  that delay.

## Revisit when
A future phase needs the pipeline identity to manage resource groups
themselves (create/delete), which would require a new, narrowly scoped
subscription-level grant beyond deployment operations; or if a phase splits
dev and prod into separate subscriptions, at which point the per-resource-group
scoping this ADR relies on could be relaxed back to a per-subscription grant
per environment.
