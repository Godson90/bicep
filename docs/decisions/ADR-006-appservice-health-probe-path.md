# ADR-006: App Service health probe path stays at the default until application code lands (PSRule Azure.AppService.WebProbePath accepted)

## Context
PSRule for Azure's `Azure.AppService.WebProbePath` rule (AZR-000080) recommends a
dedicated health-probe endpoint rather than the site root, so that a functional check
(not just "the web server process is up") determines whether an instance is healthy.

`modules/appService.bicep` exposes `healthCheckPath` as a parameter (default `'/'`),
and F8 (commit `09970de`) already wires it into `siteConfig.healthCheckPath` with
`alwaysOn: true`. `params/dev.bicepparam` and this repository as a whole deploy
infrastructure only; no application code exists yet, so there is no `/healthz` (or
equivalent) endpoint to point at. Setting a non-root path today would make health
checks fail outright once App Service starts probing, which is worse than the current
gap.

This is not resolved by any infrastructure phase in
`docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §5: Phase 5's "App
Service hardening and ZR" is about plan/SKU/zone-redundancy configuration, not
application-level endpoints, which are out of this repository's scope entirely.

## Decision
Accept the risk for Phase 0: leave `healthCheckPath` defaulting to `'/'` in
`params/dev.bicepparam`. Exclude `Azure.AppService.WebProbePath` in `ps-rule.yaml`
with a reference to this ADR.

## Consequences
- Until application code implements a dedicated health endpoint, `healthCheckPath`
  only proves the site root responds, not that the application is functionally
  healthy.
- Whoever deploys real application code must implement a lightweight, unauthenticated
  health endpoint (for example `/healthz`) and set `healthCheckPath` to it in the
  relevant `*.bicepparam` file. Once every committed parameter file does so, remove
  this exclusion from `ps-rule.yaml`.
