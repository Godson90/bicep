# ADR-007: Dev environment pipeline exposure accepted for Phase 0

## Context
`.github/workflows/bicep-ci.yml`'s `what-if` job and `.github/workflows/deploy.yml`'s
`deploy` job both run against the single GitHub environment `dev`. That environment
holds the federated-credential identity described in
`docs/runbooks/00-pipeline-and-identity.md`: `Contributor` plus a condition-scoped
`Role Based Access Control Administrator` on the `defenStack` resource group (dev),
constrained by `scripts/New-GitHubDeploymentIdentity.ps1`'s ABAC condition to assigning
only `Storage Blob Data Contributor`.

Because both jobs share the same environment and any collaborator who can push a
branch can trigger `what-if` (on a same-repo pull request) or, before this fix,
`workflow_dispatch` on `deploy` from any ref, that collaborator can run **arbitrary
workflow YAML** with the dev identity's credentials — not merely read-only `what-if`
output. `Contributor` on the resource group lets that workflow code create, modify, or
delete any resource in `defenStack`, and the constrained
`Role Based Access Control Administrator` lets it grant `Storage Blob Data Contributor`
to a principal of its choosing. This is a materially broader exposure than "can preview
a deployment," and the previous wording in `docs/runbooks/00-pipeline-and-identity.md`
described it as the latter.

## Decision
Accept this exposure for Phase 0, scoped to `dev` only, with one mitigation:
- `deploy.yml`'s `deploy` job gets `if: github.ref == 'refs/heads/main'`, so
  `workflow_dispatch` from a non-`main` ref cannot run the deploy job even though the
  workflow itself can still be dispatched from other refs. Push-triggered deploys were
  already restricted to `main`.
- The `what-if` job already only runs for same-repository pull requests
  (`github.event.pull_request.head.repo.full_name == github.repository`); it is not
  further restricted here.
- No separate GitHub environment is created for `what-if` versus `deploy` in Phase 0.
  Splitting them would not remove the core risk (arbitrary workflow code with the dev
  identity from a pushed branch) since `what-if` itself runs attacker-controlled
  workflow YAML from that branch.
- Prod (Phase 1) will not share this pattern: it gets its own identity, bound to its
  own `prod` GitHub environment with required reviewers and a `main`-only branch
  policy, so a pushed branch alone cannot trigger any workflow run authenticated as
  prod.

## Consequences
- Any collaborator with push access to this repository can run arbitrary workflow code
  authenticated as the dev deployment identity by opening a same-repo pull request
  (for `what-if`) or by pushing to `main` (for `deploy`, now also reachable through
  `workflow_dispatch` only when the ref is `main`).
  `Contributor` plus the constrained `Role Based Access Control Administrator` bounds
  the blast radius to the `defenStack` resource group and to
  `Storage Blob Data Contributor` grants, but within that boundary the collaborator has
  full control.
- `docs/runbooks/00-pipeline-and-identity.md` §9's security note is corrected to state
  this accurately (arbitrary workflow code, not just `what-if`) and links back to this
  ADR.
- Dev must never hold real customer data or production-equivalent secrets while this
  decision stands.

## Revisit when
- Dev starts holding real data, or
- before Phase 1 ships (Phase 1 introduces the separate prod identity/environment
  described above; at that point, re-evaluate whether dev also needs required
  reviewers or a narrower trigger).

## Phase 2 amendment

Phase 2 splits `deploy.yml` into a `plan` job and an `apply` job (what-if
before deploy). For dev, both the PR what-if job (`bicep-ci.yml`) and
`deploy.yml`'s `plan` job now run in the `dev-plan` GitHub environment (no
branch restriction, matching `dev`'s prior configuration), and `deploy.yml`'s
`apply` job runs in `dev`. Both `dev-plan` and `dev` hold the **same** dev
deployment identity (`scripts/New-GitHubDeploymentIdentity.ps1` creates two
federated credentials, `github-dev` and `github-dev-plan`, on one app
registration) — so the exposure this ADR describes is unchanged: a same-repo
pull request or a push to `main` still runs arbitrary workflow YAML
authenticated as the single dev identity, whichever of the two environments
that particular job happens to run in, with the same `Contributor` plus
ABAC-constrained `Role Based Access Control Administrator` blast radius on
the dev resource groups. Nothing about the plan/apply split narrows or widens
that boundary for dev.

Prod is covered separately: prod's `plan` and `apply` jobs both run in the
gated `prod` environment, and there is deliberately no `prod-plan`
environment. See
[ADR-012](ADR-012-prod-two-approval-deploys.md) for why, and
[runbook 00b](../runbooks/00b-configure-pipeline-credentials.md) §1a for the
operational summary.
