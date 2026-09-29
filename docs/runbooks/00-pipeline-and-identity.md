# 00 - Pipeline and deployment identity

> Owning files: `.github/workflows/bicep-ci.yml`, `.github/workflows/deploy.yml`, `scripts/New-GitHubDeploymentIdentity.ps1`, `ps-rule.yaml`, `params/*.bicepparam`, `tests/`.

## 1. Purpose and scope
- `bicep-ci` runs on every PR and push to `main`: lint, build, Pester template assertions, the `main.json` drift check and PSRule for Azure. On same-repo PRs it also posts a what-if against dev as a PR comment (the `what-if` job runs in the `dev-plan` GitHub environment).
- `deploy` deploys `main` to dev (on push to `main`) or to dev/prod (on `workflow_dispatch`). It is split into a `plan` job (validate + what-if) and an `apply` job (the actual deployment), so a deployment is always preceded by a what-if in the same run. Where each job's `environment:` points differs by target:
  - **Dev:** `plan` runs in `dev-plan` (no reviewers, no branch restriction — same identity as `dev`), `apply` runs in `dev` (no reviewers). No approval is required for either.
  - **Prod:** `plan` **and** `apply` both run in the reviewer-gated `prod` GitHub environment. There is no `prod-plan` environment — see [ADR-012](../decisions/ADR-012-prod-two-approval-deploys.md) for why a separate ungated prod-plan credential would be unsafe. A prod deploy therefore needs **two** approvals: one to let `plan` run and produce the what-if, and a second to let `apply` run after a reviewer has read it (the job summary, or the `whatif-prod` artifact, kept 14 days).
- Azure access uses an Entra application with a **federated credential** bound to the GitHub environment. Dev's identity holds two credentials (`github-dev`, `github-dev-plan`) for its two environments; prod's identity holds one (`github-prod`). No client secret exists anywhere.

## 2. Prerequisites
- GitHub CLI signed in with admin rights on `Godson90/bicep`: `gh auth status`.
- Entra role able to create app registrations: `Application Developer`, or `Cloud Application Administrator`.
- Azure role at subscription scope: any run that creates a custom role needs `Owner` or `User Access Administrator` at subscription scope — `Role Based Access Control Administrator` cannot create a role definition (`Microsoft.Authorization/roleDefinitions/write`). Two runs create a role: the **first** run against a subscription (`DefenStack Subscription Deployment Operator`) and the **first prod run with `-GrantLockManagement`** (`DefenStack Resource Lock Operator`). Other runs need `Role Based Access Control Administrator` + `Contributor`.
- Azure CLI 2.90 or later and PowerShell 5.1 or 7.

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `-GitHubRepository` | none | `Godson90/bicep` | Federated credential subject |
| `-EnvironmentName` | none | `dev` and `prod` | One identity per environment limits blast radius |
| `-ResourceGroupNames` | none | `rg-defenstack-prod-global`, `rg-defenstack-prod-wus3`, `rg-defenstack-prod-eus` | Resource groups the identity may deploy resources into; the identity separately gets the custom `DefenStack Subscription Deployment Operator` role at subscription scope so it can run subscription-scope deployments (see ADR-009) |
| `-DelegatableRoleDefinitionIds` | Storage Blob Data Contributor | extended per phase | Roles the pipeline may assign; `Owner`, `User Access Administrator`, `Role Based Access Control Administrator` and `Contributor` are always refused, and all other roles are blocked by the ABAC condition |
| `-GrantLockManagement` | off | on for prod | Needed only where `CanNotDelete` locks are deployed |

## 4. Step-by-step setup
> For the full operator procedure, including the Azure portal and GitHub web UI paths (no `gh` CLI needed), verification and troubleshooting of the pipeline login, follow [00b - Configure secure pipeline credentials](00b-configure-pipeline-credentials.md). The steps below are the CLI summary.

1. **Create the GitHub environment `dev`:**

   ```powershell
   gh api --method PUT repos/Godson90/bicep/environments/dev
   ```

   Expected: a JSON response containing `"name": "dev"`.

2. **Preview the identity changes:**

   ```powershell
   az login
   az account set --subscription <subscription-id>
   .\scripts\New-GitHubDeploymentIdentity.ps1 `
     -ResourceGroupNames 'rg-defenstack-dev-global','rg-defenstack-dev-wus3' `
     -GitHubRepository Godson90/bicep `
     -EnvironmentName dev `
     -WhatIf
   ```

   Expected: `What if:` lines for the app registration, service principal, federated credential, the custom `DefenStack Subscription Deployment Operator` role and its assignment at subscription scope, then `Contributor` and `Role Based Access Control Administrator` on each of the two resource groups. No changes are made.

3. **Create the identity:** run the same command without `-WhatIf`. Expected: the output object with the three `AZURE_*` values, plus three `gh variable set …` commands.

4. **Set the GitHub environment variables:** run the three printed `gh variable set` commands. They are identifiers, not secrets. Verify:

   ```powershell
   gh variable list --env dev --repo Godson90/bicep
   ```

   Expected: all three variables are listed. If the environment previously held an `AZURE_RESOURCE_GROUP` variable from before Phase 1, delete it — it is no longer read by either workflow.

5. **Re-run CI on the Phase 0 PR:**

   ```powershell
   gh run rerun --failed <run-id>
   ```

   Expected: the `what-if` job signs in and posts a "What-if: dev" comment on the PR.

6. **Protect `main`:** this requires a public repo or a paid plan for private repos. Create `protection.json`:

   ```json
   {
     "required_status_checks": { "strict": true, "contexts": ["validate"] },
     "enforce_admins": false,
     "required_pull_request_reviews": { "required_approving_review_count": 0 },
     "restrictions": null
   }
   ```

   Apply it and remove the file:

   ```powershell
   gh api --method PUT repos/Godson90/bicep/branches/main/protection --input protection.json
   Remove-Item protection.json
   ```

## 5. Manual and post-deployment steps
- After merging to `main`, the `deploy` workflow runs automatically for changes under `main.bicep`, `modules/` or `params/`. To deploy manually:

  ```powershell
  gh workflow run deploy -f environment=dev
  ```

- The first merged deployment is the Phase 0 rollout. Complete `docs/runbooks/00a-apply-phase0-fixes.md` §5 manual steps (the F11 role cleanup and F4 verification) after it finishes.

## 6. Validation
| Check | Command | Expected result |
|---|---|---|
| Federated credential | `az ad app federated-credential list --id <AZURE_CLIENT_ID> --query "[].subject" -o tsv` | `repo:Godson90/bicep:environment:dev` |
| Subscription-scope role | `az role assignment list --assignee <AZURE_CLIENT_ID> --scope /subscriptions/<sub> --query "[].roleDefinitionName" -o tsv` | `DefenStack Subscription Deployment Operator` only |
| Resource group role assignments | `az role assignment list --assignee <AZURE_CLIENT_ID> --scope /subscriptions/<sub>/resourceGroups/rg-defenstack-dev-global --query "[].{role:roleDefinitionName,condition:condition!=null}" -o table` (repeat for `rg-defenstack-dev-wus3`) | `Contributor` (condition False) and `Role Based Access Control Administrator` (condition True) on each resource group |
| No secrets | `az ad app credential list --id <AZURE_CLIENT_ID>` | `[]` |
| CI gate | `gh pr checks <pr-number>` | `validate` pass, `what-if` pass |

## 7. Rollback
- Disable the pipeline: `gh workflow disable deploy`.
- Remove access:

  ```powershell
  $sp = az ad sp list --filter "appId eq '<AZURE_CLIENT_ID>'" --query "[0].id" -o tsv
  az role assignment list --assignee $sp --all --query "[].id" -o tsv | ForEach-Object { az role assignment delete --ids $_ }
  az ad app delete --id <AZURE_CLIENT_ID>
  ```

## 8. Operations

### PSRule baseline
`bicep-ci.yml` pins `PSRule.Rules.Azure` to `1.47.0` (`Install-Module -Name PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force`) so CI results are reproducible and do not silently change when a new module version ships. Bumping the pinned version is a deliberate PR: re-run the baseline capture below against the new version, resolve any newly failing rules the same way as the table below, and update the pinned version and this baseline together.

Baseline captured locally by running, from the repository root:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Install-Module -Name PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
```

Installed `PSRule.Rules.Azure 1.47.0` on `PSRule v2.9.0`, Bicep CLI on `PATH`
(`PSRULE_AZURE_BICEP_PATH` set explicitly). Phase 1 moved the layout to
subscription scope with a West US 3 primary and an East US warm standby
(`docs/decisions/ADR-008-warm-standby-and-dev-single-region.md`), which resolved
five of the rules that were previously excluded for every environment
(`Azure.Log.Replication`, `Azure.PublicIP.AvailabilityZone`,
`Azure.Firewall.AvailabilityZone`, `Azure.AppService.PlanInstanceCount`,
`Azure.AppService.AvailabilityZone`) for the prod primary region, while leaving
by-design gaps in dev and the East US standby. Those remaining gaps are now
suppressed **per target** in `.ps-rule/Suppression.Rule.yaml` instead of excluded
globally, so the prod primary stays fully enforced. After classification,
`Assert-PSRule` reports:

```
Rules processed: 604, failed: 0, errored: 0
```

**Exclusions** (`ps-rule.yaml`'s `rule.exclude`) apply to every environment and
every target:

| Rule | Classification | Resolving phase / ADR |
|---|---|---|
| `Azure.Storage.UseReplication` (AZR-000195) | (a) Later phase | Phase 5 — storage moves to RA-GZRS |
| `Azure.NSG.LateralTraversal` (AZR-000139) | (a) Later phase | Phase 3 — Bastion/VPN/jump-host admin access redesign adds lateral-movement outbound rules |
| `Azure.Resource.UseTags` (AZR-000166) | (c) Accepted risk | `docs/decisions/ADR-002-no-tagging-convention-yet.md` |
| `Azure.NSG.DenyAllInbound` (AZR-000138) | (c) Accepted risk | `docs/decisions/ADR-004-nsg-default-deny-inbound.md` |
| `Azure.VNET.SingleDNS` (AZR-000264) | (c) Accepted risk | `docs/decisions/ADR-005-single-firewall-dns-proxy.md` |
| `Azure.AppService.WebProbePath` (AZR-000080) | (c) Accepted risk | `docs/decisions/ADR-006-appservice-health-probe-path.md` |

**Suppression groups** (`.ps-rule/Suppression.Rule.yaml`) apply only to the named
targets they list; every other target (in particular the prod primary region) is
still checked against these rules:

| Suppression group | Rule(s) | Named target(s) | Classification | Resolving ADR |
|---|---|---|---|---|
| `DefenStack.SingleInstanceAppServicePlans` | `Azure.AppService.AvailabilityZone` (AZR-000442), `Azure.AppService.PlanInstanceCount` (AZR-000071) | `asp-defenstack-dev-wus3`, `asp-defenstack-prod-eus` | (c) Accepted risk | `docs/decisions/ADR-008-warm-standby-and-dev-single-region.md` |
| `DefenStack.DevWorkspaceReplication` | `Azure.Log.Replication` (AZR-000425) | `log-defenstack-dev` | (c) Accepted risk | `docs/decisions/ADR-008-warm-standby-and-dev-single-region.md` |
| `DefenStack.DevFirewallAlertMode` | `Azure.Firewall.PolicyMode` (AZR-000399) | `afwp-defenstack-dev-wus3` | (c) Accepted risk | `docs/decisions/ADR-003-dev-threat-intel-alert-mode.md` |

Rules already fixed in code rather than excluded or suppressed —
`Azure.Storage.Firewall`, `Azure.VNET.PrivateSubnet`, `Azure.AppService.ARRAffinity`
— are covered by `tests/Storage.Tests.ps1`, `tests/SpokeNetwork.Tests.ps1` and
`tests/AppService.Tests.ps1` respectively and no longer appear in either table.

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | Job not running in the `dev` environment, or repo name/case mismatch | Confirm `environment: dev` in the job and that the subject equals `repo:Godson90/bicep:environment:dev` |
| `AADSTS70021` specifically in the dev **plan** job (`bicep-ci.yml`'s `what-if`, or `deploy.yml`'s `plan` for dev) | The `dev-plan` credential or environment is missing | Re-run the script for dev (creates both `github-dev` and `github-dev-plan`); see runbook 00b §9 |
| `AuthorizationFailed … Microsoft.Resources/deployments/write … /subscriptions/<id>` | The subscription-scope `DefenStack Subscription Deployment Operator` role is missing or not yet propagated (ADR-009) | Confirm the role assignment at `/subscriptions/<sub>` (runbook 00b §3); wait for replication and re-run |
| `AuthorizationFailed … roleAssignments/write` with condition | Template assigns a role not in `-DelegatableRoleDefinitionIds` | Re-run the script with the role's GUID added. If an unconditioned or differently-conditioned `Role Based Access Control Administrator` assignment already exists at the scope, the script now stops with an error naming the mismatch; run `az role assignment delete --ids <id>` to delete that assignment, then re-run the script so it can create the correctly constrained one |
| `AuthorizationFailed … locks/write` | Prod lock deployed without `-GrantLockManagement` | Re-run the script with `-GrantLockManagement` |
| `ResourceGroupNotFound` | A resource group named in `-ResourceGroupNames`, or referenced by `resourceGroup(name)` in the templates, was not pre-created | Create the resource group first (runbook 01), then re-run |
| What-if job skipped | PR is from a fork | Expected; forks never receive Azure tokens |

**Security note:** the `what-if` job (`bicep-ci.yml`, same-repo pull requests) runs in the **dev-plan** GitHub environment; `deploy.yml`'s `plan` job also runs in `dev-plan` for dev, and its `apply` job runs in `dev`. `dev` and `dev-plan` hold the **same** dev deployment identity (two federated credentials, one app registration), so this remains a single blast radius, not two separate ones. Any collaborator who can push a branch can therefore run **arbitrary workflow YAML** authenticated as that identity — not just a read-only `what-if` — by opening a same-repo pull request, or by pushing to `main` (the `deploy` workflow also runs on `workflow_dispatch`, but only when `github.ref == 'refs/heads/main'`). That identity holds the custom `DefenStack Subscription Deployment Operator` role at subscription scope (deployment operations and read only, no resource rights — ADR-009), plus `Contributor` and a condition-constrained `Role Based Access Control Administrator` on the dev resource groups only (the ABAC condition limits assignable roles to `Storage Blob Data Contributor`). So a same-repo PR or a push to `main` can run arbitrary workflow code authenticated as the dev identity, but that code's blast radius on actual resources stops at `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3`; within that boundary the workflow code has full control. This exposure is accepted for dev in `docs/decisions/ADR-007-dev-environment-pipeline-exposure.md` (see its Phase 2 amendment); dev must not hold real data while it stands. The prod identity is bound only to the `prod` environment (both its `plan` and `apply` jobs — there is no `prod-plan`), which has required reviewers and a `main`-only branch policy, so a pushed branch alone cannot authenticate as prod, and every prod deployment needs two separate approvals (`docs/decisions/ADR-012-prod-two-approval-deploys.md`).
