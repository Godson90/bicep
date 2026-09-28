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
(completed in Task 12)

## 8. Operations

### PSRule baseline
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
