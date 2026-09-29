# ADR-012: Prod plan and apply both run in the gated `prod` environment

## Context
Task 2 split `deploy.yml` into a `plan` job (validate + what-if) and an `apply`
job (`az deployment sub create`), so reviewers can read a what-if before a
prod deployment actually runs. The natural mirror of dev's split — `plan` in
an ungated `<env>-plan` environment, `apply` in the reviewer-gated `<env>`
environment — does not carry over safely to prod.

A `prod-plan` environment would need the prod deployment identity's
credentials (`AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`) to
run `az deployment sub validate`/`what-if` against prod. If that environment
had no required reviewers — mirroring `dev-plan`'s "no restriction" design —
then any change landed on `main` would authenticate as the prod identity and
run against prod the moment the workflow reached the `plan` job, with no
approval gate at all. Worse, a GitHub Actions job that references an
environment name which does not yet exist in the repository **auto-creates
that environment, unprotected** (no required reviewers, no branch
restriction) — so simply naming `prod-plan` in the workflow YAML without
separately, deliberately configuring reviewers on it would silently produce
an ungated prod credential the first time the job ran.

## Decision
Prod's `plan` and `apply` jobs both run in the **same** gated `prod` GitHub
environment (`deploy.yml`: `environment: ${{ inputs.environment == 'prod' &&
'prod' || 'dev-plan' }}` for `plan`, `environment: ${{ inputs.environment ||
'dev' }}` for `apply`). There is no `prod-plan` environment. Dev is
unaffected: `plan` runs in `dev-plan` (no reviewers, no branch restriction, so
the PR what-if in `bicep-ci.yml` can also use it), and `apply` runs in `dev`.

## Consequences
- Every prod deployment needs **two separate approvals**: a reviewer approves
  the `plan` job before it runs `validate`/what-if against prod, and then
  (after reading the what-if in the step summary or the `whatif-prod`
  artifact, kept 14 days) a reviewer approves the `apply` job before it
  actually creates or updates prod resources. Both approvals gate the same
  prod credential; there is no way to reach prod with only one approval.
- Reviewers see the what-if for the exact deployment `apply` is about to run,
  since both jobs authenticate as the same prod identity in the same run.
- Dev's workflow shape, and the identity script's behavior for dev
  (`github-dev` + `github-dev-plan`), are unchanged by this decision.
- The prod deployment identity script (`scripts/New-GitHubDeploymentIdentity.ps1`)
  creates only one federated credential for prod, `github-prod`; it does not
  create a `github-prod-plan` credential, because no `prod-plan` environment
  exists for it to bind to.

## Revisit when
A read-only plan identity — one that can run `validate`/`what-if` but has no
write access to prod resources — is designed and verified end-to-end. At that
point, `plan` could run ungated (in a `prod-plan` environment, or even without
an environment) under that identity, since an attacker who reached it could
read prod's what-if output but could not change prod. Until such an identity
exists, `plan` and `apply` must share the same gate.
