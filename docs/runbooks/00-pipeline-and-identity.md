# 00 - Pipeline and deployment identity

> Owning files: `.github/workflows/bicep-ci.yml`, `.github/workflows/deploy.yml`, `scripts/New-GitHubDeploymentIdentity.ps1`, `ps-rule.yaml`, `params/*.bicepparam`, `tests/`.

## 1. Purpose and scope
- `bicep-ci` runs on every PR and push to `main`: lint, build, Pester template assertions, the `main.json` drift check and PSRule for Azure. On same-repo PRs it also posts a what-if against dev as a PR comment.
- `deploy` deploys `main` to dev through a gated GitHub environment.
- Azure access uses an Entra application with a **federated credential** bound to the GitHub environment. No client secret exists anywhere.

## 2. Prerequisites
- GitHub CLI signed in with admin rights on `Godson90/bicep`: `gh auth status`.
- Entra role able to create app registrations: `Application Developer`, or `Cloud Application Administrator`.
- Azure role able to create role assignments on the target resource group: `Owner`, or `Role Based Access Control Administrator` + `Contributor`.
- Azure CLI 2.90 or later and PowerShell 5.1 or 7.

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `-GitHubRepository` | none | `Godson90/bicep` | Federated credential subject |
| `-EnvironmentName` | none | `dev` now; `prod` in Phase 1 | One identity per environment limits blast radius |
| `-ResourceGroupName` | none | `defenStack` (dev) | Role assignment scope |
| `-DelegatableRoleDefinitionIds` | Storage Blob Data Contributor | extended per phase | Roles the pipeline may assign; all others are blocked by the ABAC condition |
| `-GrantLockManagement` | off | on for prod | Needed only where `CanNotDelete` locks are deployed |

## 4. Step-by-step setup
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
     -ResourceGroupName defenStack `
     -GitHubRepository Godson90/bicep `
     -EnvironmentName dev `
     -WhatIf
   ```

   Expected: `What if:` lines for the app registration, service principal, federated credential, `Contributor`, and `Role Based Access Control Administrator`. No changes are made.

3. **Create the identity:** run the same command without `-WhatIf`. Expected: the output object with the four `AZURE_*` values, plus four `gh variable set …` commands.

4. **Set the GitHub environment variables:** run the four printed `gh variable set` commands. They are identifiers, not secrets. Verify:

   ```powershell
   gh variable list --env dev --repo Godson90/bicep
   ```

   Expected: all four variables are listed.

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
| Role assignments | `az role assignment list --assignee <AZURE_CLIENT_ID> --scope /subscriptions/<sub>/resourceGroups/defenStack --query "[].{role:roleDefinitionName,condition:condition!=null}" -o table` | `Contributor` (condition False) and `Role Based Access Control Administrator` (condition True) |
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
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Install-Module -Name PSRule.Rules.Azure -Scope CurrentUser -Force"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
```

Installed `PSRule.Rules.Azure 1.47.0` on `PSRule v2.9.0`, Bicep CLI `0.47.16` on
`PATH` (`PSRULE_AZURE_BICEP_PATH` set explicitly). The first run against
`params/dev.bicepparam` reported 38 failures across 15 distinct rules. Each was
classified below; `ps-rule.yaml`'s `rule.exclude` list carries the same classification
as an inline comment. After classification, `Assert-PSRule` reports:

```
Rules processed: 175, failed: 0, errored: 0
```

| Rule | Classification | Resolving phase / ADR |
|---|---|---|
| `Azure.Log.Replication` (AZR-000425) | (a) Later phase | Phase 1 — multi-region Log Analytics workspace replication |
| `Azure.Storage.UseReplication` (AZR-000195) | (a) Later phase | Phase 5 — storage account moves to GZRS |
| `Azure.Storage.Firewall` (AZR-000202) | (b) Fixed now | `modules/storage.bicep` — added explicit `networkAcls.defaultAction: 'Deny'`; test in `tests/Storage.Tests.ps1` |
| `Azure.PublicIP.AvailabilityZone` (AZR-000157) | (a) Later phase | Phase 1 — zones cannot be added to an existing non-zonal public IP in place |
| `Azure.Firewall.PolicyMode` (AZR-000399) | (c) Accepted risk | `docs/decisions/ADR-003-dev-threat-intel-alert-mode.md` |
| `Azure.Firewall.AvailabilityZone` (AZR-000429) | (a) Later phase | Phase 1 — zones cannot be added to an existing non-zonal firewall in place |
| `Azure.NSG.LateralTraversal` (AZR-000139) | (a) Later phase | Phase 3 — Bastion/VPN/jump-host admin access redesign adds lateral-movement outbound rules |
| `Azure.NSG.DenyAllInbound` (AZR-000138) | (c) Accepted risk | `docs/decisions/ADR-004-nsg-default-deny-inbound.md` |
| `Azure.VNET.SingleDNS` (AZR-000264) | (c) Accepted risk | `docs/decisions/ADR-005-single-firewall-dns-proxy.md` |
| `Azure.VNET.PrivateSubnet` (AZR-000447) | (b) Fixed now | `modules/vnet.bicep` + `modules/spokeNetwork.bicep` — added `defaultOutboundAccess: false` on the private-endpoints and virtual-machines subnets; test in `tests/SpokeNetwork.Tests.ps1` |
| `Azure.AppService.PlanInstanceCount` (AZR-000071) | (a) Later phase | Phase 1 — App Service Plan moves to a zone-redundant SKU with >=3 instances |
| `Azure.AppService.AvailabilityZone` (AZR-000442) | (a) Later phase | Phase 1 — App Service Plan zone redundancy is set at plan creation only |
| `Azure.AppService.WebProbePath` (AZR-000080) | (c) Accepted risk | `docs/decisions/ADR-006-appservice-health-probe-path.md` |
| `Azure.AppService.ARRAffinity` (AZR-000083) | (b) Fixed now | `modules/appService.bicep` — added `clientAffinityEnabled: false`; test in `tests/AppService.Tests.ps1` |
| `Azure.Resource.UseTags` (AZR-000166) | (c) Accepted risk | `docs/decisions/ADR-002-no-tagging-convention-yet.md` |

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
| `AADSTS70021: No matching federated identity record found` | Job not running in the `dev` environment, or repo name/case mismatch | Confirm `environment: dev` in the job and that the subject equals `repo:Godson90/bicep:environment:dev` |
| `AuthorizationFailed … roleAssignments/write` with condition | Template assigns a role not in `-DelegatableRoleDefinitionIds` | Re-run the script with the role's GUID added. If an unconditioned or differently-conditioned `Role Based Access Control Administrator` assignment already exists at the scope, the script now stops with an error naming the mismatch; run `az role assignment delete --ids <id>` to delete that assignment, then re-run the script so it can create the correctly constrained one |
| `AuthorizationFailed … locks/write` | Prod lock deployed without `-GrantLockManagement` | Re-run the script with `-GrantLockManagement` |
| What-if job skipped | PR is from a fork | Expected; forks never receive Azure tokens |
| Validate fails `params/prod.bicepparam not found` | Prod is not available until Phase 1 | Deploy dev only |

**Security note:** the `what-if` job (`bicep-ci.yml`, same-repo pull requests) and the `deploy` job (`deploy.yml`) both run in the single **dev** GitHub environment and both authenticate as the dev deployment identity. Any collaborator who can push a branch can therefore run **arbitrary workflow YAML** authenticated as that identity — not just a read-only `what-if` — by opening a same-repo pull request, or by pushing to `main` (the `deploy` job also runs on `workflow_dispatch`, but only when `github.ref == 'refs/heads/main'`). That identity is scoped to `Contributor` plus a condition-constrained `Role Based Access Control Administrator` on the dev resource group only (the ABAC condition limits assignable roles to `Storage Blob Data Contributor`), so the blast radius stops at `defenStack`, but within that boundary the workflow code has full control. This exposure is accepted for dev in `docs/decisions/ADR-007-dev-environment-pipeline-exposure.md`; dev must not hold real data while it stands. The prod identity (Phase 1) is bound to its own `prod` environment, which has required reviewers and a `main`-only branch policy, so a pushed branch alone cannot authenticate as prod.
