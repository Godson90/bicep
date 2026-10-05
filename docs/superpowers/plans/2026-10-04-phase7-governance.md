# Phase 7: Governance and Posture (Defender for Cloud, Azure Policy, Exemptions, Just-in-Time Access) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Put the subscription under code-reviewed governance without giving the pipeline any new rights:
- Microsoft Defender for Cloud plans (Servers P2, App Service, Storage with capped malware scanning, Key Vault, Resource Manager, Defender CSPM) and the security contact;
- Azure Policy at subscription scope: the Microsoft cloud security benchmark in audit, deny assignments that go live audit-first, a computed public IP allowlist, allowed locations and a diagnostic settings audit;
- exemptions for the flow-log accounts and a dated waiver for the legacy `defenStack` resource group;
- just-in-time (JIT) access to the jump host, with a least-privilege "DefenStack JIT Requester" role for each environment's admin group.

**Architecture:**
- **Operator-only entry point.** `governance.bicep` (subscription scope, repository root) with `params/governance.bicepparam`, one file per subscription. An operator deploys it with `az deployment sub create` (runbook 07). `main.bicep` and `deploy.yml` never reference it; `deploy.yml` ignores governance-only paths; the pipeline identity script is unchanged (ADR-026). CI still builds, lints and PSRules it through the test suite and `-InputPath params/`. `governance.json` is committed and drift-tested, like `main.json`.
- **Defender for Cloud.** `modules/governance/defenderPlans.bicep` sets six `Microsoft.Security/pricings` one at a time (`@batchSize(1)`). `modules/governance/securityContacts.bicep` sets the `default` contact from `SECURITY_CONTACT_EMAILS`.
- **Policy.** `modules/governance/policies.bicep` holds 11 assignments and the custom definition `defenstack-deny-public-ip-except-allowlist`. Every deny-type assignment takes `enforcementMode: denyEnforcement` (default `DoNotEnforce`) while its effect stays `Deny` (ADR-027). `governance.bicep` computes the stamps, the public IP allowlist and the flow-log account names with the workload's own formulas; tests pin the parity.
- **Exemptions.** `modules/governance/flowLogStorageExemption.bicep` (one per stamp, `Mitigated`) and `modules/governance/legacyWaiver.bicep` (one `Waiver` per deny assignment, dated).
- **JIT.** Governance side: `modules/governance/jitRequesterRole.bicep` (custom role at subscription scope) and `modules/governance/jitRequesterAssignment.bicep` (the admin group, at each primary regional resource group). Pipeline side: `modules/virtualMachine.bicep` replaces the NIC NSG's static SSH/RDP allow with a priority-4000 deny and adds `Microsoft.Security/locations/jitNetworkAccessPolicies` `default`; the management subnet NSG is unchanged (ADR-028).

**Tech Stack:** Bicep CLI 0.47.16, Azure CLI 2.90+, Windows PowerShell 5.1 / pwsh 7, Pester 5.x, PSRule 2.9.0 with PSRule.Rules.Azure 1.47.0, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md`. The relevant parts are §3 "Governance and posture", the JIT bullet of §3 "Admin access" (the jump host, deferred from Phase 3 by ADR-014), §5 Phase 7 (row 7), and §6 documentation standard.

This plan builds on Phase 6 (`docs/superpowers/plans/2026-10-03-phase6-monitoring.md`). The branch `phase7-governance` is stacked on `phase6-monitoring` (commit `a2b9188`).

**Verification status of this plan:** every Bicep module, parameter file, test, workflow and document below was prototyped and run before the plan was written. The reference commits are local branches, not for merge: `phase7-proto-t1` … `phase7-proto-t3` (the state after Tasks 1–3) and `phase7-prototype` (the state after Task 4).
- `bicep lint` and `bicep build` are clean for every file.
- `main.json` and `governance.json` are in sync.
- The full Pester suite passes: 555 → **592** (Task 1) → **637** (Task 2) → **657** (Task 3) → **676** (Task 4).
- `Assert-PSRule` reports 0 failures and 0 errors: 1209 → **1240** rules processed (Task 1) → **1324** (Task 2) → **1332** (Task 3 and Task 4). No new suppression was needed. From Task 1 on, PSRule needs `SECURITY_CONTACT_EMAILS` set (see Execution Notes).
- `deploy.yml` and `bicep-ci.yml` parse as YAML.
- The prototype ran on Windows PowerShell 5.1 only, because pwsh 7 was not installed. The new tests use no 7-only syntax, but run them on pwsh 7 too (see Global Constraints).

The embedded content is that verified content. Transcribe it exactly.

## Global Constraints

- **User decisions (binding, taken when this plan was written):**
  - **Governance is deployed by an operator, not the pipeline.**
    - A new subscription-scope entry point, `governance.bicep`, at the repository root next to `main.bicep`, with its own `params/governance.bicepparam`, one file per subscription.
    - It is **not** referenced by `main.bicep` or `deploy.yml`. **The pipeline identity gets no new rights**, and `scripts/New-GitHubDeploymentIdentity.ps1` is unchanged. Its existing resource group Contributor already covers the jump host's `jitNetworkAccessPolicies` write.
    - CI (`bicep-ci.yml` and the test suite) still builds, lints and PSRules it. `governance.json` is committed and drift-tested, like `main.json` (ADR-026).
  - **Deny policies go live audit-first.** Every deny-type assignment takes the one parameter `denyEnforcement`, allowed values `'DoNotEnforce' | 'Default'`, **default `'DoNotEnforce'`**, mapped to `enforcementMode`. Built-in policies whose effect is a parameter still get effect `Deny`; the enforcement mode carries the audit phase (ADR-027). `params/governance.bicepparam` commits `denyEnforcement = 'DoNotEnforce'`; the switch to `Default` is a reviewed commit after the audit week (runbook 07 §5.2).
  - **Diagnostic settings are checked by AuditIfNotExists only:** the built-in "Audit diagnostic setting for selected resource types" (`7f89b1eb-583c-429a-8828-af049802c1d9`), no managed identity, no remediation. This replaces the spec's "Deploy-if-not-exists".
  - **Defender for Storage on-upload malware scanning is on, with a cap:** param `malwareScanCapGbPerMonth` (default `5000`, `-1` = no cap) sets `CapGBPerMonthPerStorageAccount`.
- **Approved design (binding):**
  - Defender plans on `Microsoft.Security/pricings@2024-01-01`, `@batchSize(1)`, in this order: `VirtualMachines` (Standard, `subPlan: 'P2'`, extension `AgentlessVmScanning`), `AppServices`, `StorageAccounts` (`subPlan: 'DefenderForStorageV2'`, `OnUploadMalwareScanning` with the cap, `SensitiveDataDiscovery`), `KeyVaults`, `Arm`, `CloudPosture`, all Standard. No `MdeDesignatedSubscription`, no `autoProvisioningSettings` (the retired agent toggle), no sub-plan for the last four (ADR-026).
  - Security contact `default`: emails from `securityContactEmails` (`@minLength(1)`), joined with `;`; `notificationsByRole` `On` for `Owner`; `notificationsSources` `Alert` at minimal severity `High`.
  - Policy assignments (all `defenstack-*`, `metadata.assignedBy: 'DefenStack governance.bicep (runbook 07)'`): `defenstack-mcsb` (`Default`); six public network access denies (storage first, then Key Vault, app, app slot, function, function slot); `defenstack-allowed-locations` (`westus3`, `eastus`, `global`) and `defenstack-allowed-resource-group-locations` (`westus3`, `eastus`), with no `effect` parameter; `defenstack-deny-public-ip` on the custom definition (fixed `deny`, `mode: 'Indexed'`); `defenstack-audit-diagnostic-settings` (`Default`). The nine deny assignments follow `denyEnforcement`, and each has a `nonComplianceMessages` entry ending "Exemptions: runbook 07."
  - The public IP allowlist is computed by `func publicIpNames(environmentName, regionCode)`: `pip-afw-`, `pip-bas-`, `pip-vpng-…-1` and `pip-vpng-…-2` for every stamp, 12 names with the default layout.
  - Layout params `environments` (default `['dev','prod']`) and `environmentRegions` (type `environmentRegionLayout`, default dev `['westus3']`, prod `['westus3','eastus']`, primary first).
  - Flow-log exemption `defenstack-flow-log-storage-public-network` on each `stfl<regionCode><nameSuffix>` account, category `Mitigated`, citing ADR-023. The name formula is `uniqueString(subscription().id, environmentName, location)`, exactly as `regionStamp.bicep` computes it.
  - Legacy waiver: one `Waiver` per deny assignment on `legacyResourceGroupName` (default `'defenStack'`; empty skips it), `expiresOn: '<legacyWaiverExpiresOn>T23:59:59Z'`. The committed `legacyWaiverExpiresOn = '2027-03-31'` is a **placeholder**; the user confirms it in the PR.
  - JIT requester role "DefenStack JIT Requester" (`roleDefinitions@2022-04-01`, name `guid(subscription().id, 'DefenStack JIT Requester')`, assignable at the subscription) with seven read/initiate actions. It is assigned directly to `adminGroupObjectIds.<env>` (type `environmentAdminGroups`, default both `''`) at each environment's **primary** regional resource group, with `guid(resourceGroup().id, principalId, roleDefinitionId)` and `principalType: 'Group'`. Runbook 07 makes the group membership PIM-eligible, as Phase 3 does.
  - JIT policy (only where the jump host exists, `enableVirtualMachine && isPrimary`, and `managementSourceCidrs` is non-empty): `Microsoft.Security/locations/jitNetworkAccessPolicies@2020-01-01`, name `'${location}/default'`, kind `Basic`, TCP 22 and 3389 from `managementSourceCidrs` (Bastion subnet, VPN pool and any ADR-approved extra), `maxRequestAccessDuration: 'PT3H'`.
  - NIC NSG `<vm>-nsg`: `allow-management-ssh-rdp` is removed; `deny-ssh-rdp-inbound` (priority 4000, any source, ports 22 and 3389) is added first, leaving 100–3999 for JIT. The subnet NSG `<spoke>-management-nsg` keeps `allow-management-ssh-rdp` at 100. Each pipeline redeploy resets `<vm>-nsg` and ends active JIT grants (ADR-028).
- **Spec values (verbatim):**
  - "**Defender for Cloud**: Servers P2, App Service, Storage (with malware scanning), Key Vault, Resource Manager, and Defender CSPM. Set security contacts and auto-provisioning." Auto-provisioning is satisfied by agentless scanning and the default Defender for Endpoint integration (ADR-026).
  - "Microsoft Cloud Security Benchmark initiative, audit." "Deny public network access on Storage, Key Vault and Web." "Deny public IPs except the allowed firewall, Bastion and gateway PIP names." "Allowed locations: WUS3, EUS, global."
  - §3 admin access: "Defender JIT access" on the management jump host.
  - §5 row 7: "Defender plans, Policy assignments, security contacts", doc `07-governance.md` ("policy exemption procedure, Defender recommendation handling").
- **New API versions:**
  - `Microsoft.Security/pricings@2024-01-01` (GA)
  - `Microsoft.Authorization/policyAssignments@2025-11-01` and `Microsoft.Authorization/policyDefinitions@2025-11-01` (newest GA in the Bicep 0.47.16 types)
  - `Microsoft.Authorization/roleDefinitions@2022-04-01`
  - `Microsoft.Security/locations/jitNetworkAccessPolicies@2020-01-01` (GA)
  - Existing versions for role assignments (`2022-04-01`), storage (`2026-04-01`, `existing`) and NSGs (`2024-07-01`).
- **Preview API exceptions (ADR-029):** `Microsoft.Security/securityContacts@2023-12-01-preview` and `Microsoft.Authorization/policyExemptions@2026-01-01-preview`. Neither type has a GA version. Together with ADR-025's `Microsoft.Insights/diagnosticSettings@2021-05-01-preview`, these are the only preview versions allowed. Fallbacks, if ARM rejects one, are in runbook 07 §9.
- **`SECURITY_CONTACT_EMAILS`:** contact addresses are never committed. `params/governance.bicepparam` reads the semicolon-separated environment variable `SECURITY_CONTACT_EMAILS` (trimmed, empty entries dropped). Unset, the list is empty and ARM refuses the deployment (`@minLength(1)`). The operator sets it before `what-if` and `create`. `bicep-ci.yml`'s PSRule step and every local PSRule command set the placeholder `security-contact@example.com`; without it, `Azure.Defender.SecurityContact` fails.
- **Exemption ordering trap:** an exemption needs its target to exist. Every stamp listed in `environments`/`environmentRegions` must already be deployed, and `legacyResourceGroupName` must exist (set it to `''` after teardown). To add an environment or region: keep or set `denyEnforcement = 'DoNotEnforce'`, deploy the workload, add the environment or region, redeploy governance, then switch back to `Default`. Under `Default`, a new `stfl…` account (public network access Enabled) and its exemption deadlock. Likewise, governance runs **before** the workload deploy that creates the JIT policy, because JIT needs Defender for Servers (runbook 07 §4).
- **Unchanged:** `scripts/New-GitHubDeploymentIdentity.ps1` and its roles; `ps-rule.yaml` and `.ps-rule/`; the management subnet NSG rules; every Phase 1–6 resource name; regions and address plan; `params/dev.bicepparam` and `params/prod.bicepparam`.
- **PSRule:** no new suppression. The first policy run fails `Azure.Policy.AssignmentAssignedBy` until `metadata.assignedBy` is set, which the embedded code already does. The JIT policy is not in PSRule's expansion, because both parameter files keep `enableVirtualMachine = false`.
- **main.json and governance.json are generated:** after any `.bicep` change (including `modules/types.bicep` and `modules/governance/*`), run `bicep build main.bicep` **and** `bicep build governance.bicep`, and commit whichever changed. Check with `diff --strip-trailing-cr <(bicep build main.bicep --stdout) main.json` and the same for `governance`. `tests/Lint.Tests.ps1` checks both.
- **Docs are mandatory:** runbooks use the 9-section template.
- **Tests must run on both shells:** Windows PowerShell 5.1 and pwsh 7. The prototype ran on 5.1 only; run the full suite on pwsh 7 too before the final commit and report the count.
- **No live Azure/Entra/GitHub commands; no push.** Nothing in this plan calls Azure; runbook 07 is for a human after the PR.
- **Commit trailers:** every commit ends with `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`.
- **Build output:** never commit `modules/*.json` or `modules/governance/*.json` (Task 1 widens `.gitignore` to `modules/**/*.json`).
- **PowerShell editing gotchas:**
  - Never write Bicep through a double-quoted PowerShell string, because `${...}` is expanded and dropped.
  - In single-quoted strings, `''` is one `'`.
  - A helper `.ps1` containing non-ASCII characters (—, →, ↔, §) needs a UTF-8 BOM.
  - Read and write docs as UTF-8.
  - The working tree is CRLF (`core.autocrlf=true`): normalize line endings before matching a find text, or a multi-line find silently misses.
  - Windows PowerShell 5.1 returns a JSON array from `ConvertFrom-Json` as one object; use `@(...)[0]`.

## Review Focus

These are inputs and conditions the spec implies but no offline test can fully exercise, most likely first:

1. **Switching to `Default` blocks the platform, or a new stamp deadlocks**, because an Azure-created resource group sits outside the two regions or a new `stfl…` account is created before its exemption can exist. Pinned by the Task 2 tests "goes live audit-first: every deny assignment follows denyEnforcement, default DoNotEnforce (ADR-027)" and "starts audit-first for dev and prod (ADR-027)", and the Task 4 test "the governance runbook spells out the ordering trap for a new environment or region".
2. **The public IP allowlist or a flow-log exemption drifts from the workload's names**, so Deny blocks a firewall, Bastion or VPN IP, or an exemption targets an account that does not exist. Pinned by the Task 2 tests "allows the <Key> public IP name exactly as regionStamp.bicep builds it", "only the firewall, Bastion and VPN gateway modules create public IPs, so the allowlist is complete" and "computes the flow-log account name with the same formula as regionStamp.bicep".
3. **ARM rejects a preview API or a Defender plan payload** (the 2023-12-01-preview contact, the 2026-01-01-preview exemptions, the default Key Vault and Resource Manager sub-plans). Pinned by the Task 1 tests "pins 2023-12-01-preview, the latest version; the type has no GA version (ADR-029)" and "leaves <_> on the Azure default sub-plan with no extensions", the Task 2 test "pins 2026-01-01-preview, the latest version; exemptions have no GA version (ADR-029)", and the Task 4 test "the governance runbook lists each unverified item as a live-only risk with a fallback".
4. **A JIT grant does not open the jump host**, because Defender programs the subnet NSG instead of the NIC, its allow lands below the 4000 deny, or the requester role lacks an action. Pinned by the Task 3 tests "denies inbound SSH and RDP from any source at priority 4000, leaving 100-3999 free for JIT allow rules", "keeps the subnet allow for the admin sources only, so a JIT grant on the NIC NSG can pass it (ADR-028)", "covers this VM on TCP 22 and 3389, from the admin sources only, for at most three hours" and "grants only reading and initiating JIT requests plus the reads the request needs".
5. **Governance leaks into the pipeline, or deploys with no contact:** a governance-only commit triggers a workload redeploy that resets the NIC NSG and ends active JIT grants, or the operator forgets `SECURITY_CONTACT_EMAILS`. Pinned by the Task 1 tests "is never deployed by main.bicep or the pipeline (operator only, ADR-026)", "does not redeploy the workload when only governance files change (a redeploy resets the JIT NSG rules, ADR-028)" and "turns an unset SECURITY_CONTACT_EMAILS into an empty list, which the template refuses (minLength 1)", and the Task 4 test "the governance runbook sets SECURITY_CONTACT_EMAILS before what-if and create".

Known coverage gaps:
- PSRule does not evaluate the JIT policy or the NIC NSG change (`enableVirtualMachine = false` in both parameter files), and has no rules for the security contact's notification settings or the JIT role.
- Whether the built-in "Allowed locations" already skips `global`, the effect parameter of "Allowed locations for resource groups", the JIT role's action list and the operator role pair (Security Admin plus User Access Administrator) come from the research or the built-in definitions, not a live call.
- The diagnostic audit will report the flow-log accounts' blob services as non-compliant (they have no diagnostic setting); runbook 06 and runbook 07 record this as expected.
- Defender for Cloud's own "ASC Default" MCSB assignment duplicates `defenstack-mcsb`; accepted in ADR-027.

## Execution Notes

- **Full suite:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`, then `pwsh -NoProfile -File tests/Invoke-Tests.ps1`. Each prints `Tests Passed: N, Failed: 0`. It takes about 3.5 minutes.
- **Some files only:**

  ```powershell
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { `$f = @('tests/Governance.Tests.ps1'); & ./tests/Invoke-Tests.ps1 -Path `$f }"
  ```

- **PSRule** (the `SECURITY_CONTACT_EMAILS` placeholder is required from Task 1 on and harmless before it):

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; $env:SECURITY_CONTACT_EMAILS = 'security-contact@example.com'; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
  ```

  The summary line reports the rules processed; the expected count is given per task.
- **Build both entry points:** `bicep build main.bicep` and `bicep build governance.bicep`.
- **Lint:** `for f in main.bicep governance.bicep modules/*.bicep modules/governance/*.bicep; do bicep lint "$f" || echo "LINT FAIL $f"; done`
- **YAML check:** `powershell.exe -NoProfile -Command "Import-Module powershell-yaml; foreach (`$f in '.github/workflows/deploy.yml', '.github/workflows/bicep-ci.yml') { ConvertFrom-Yaml (Get-Content `$f -Raw) | Out-Null }; 'YAML-OK'"`

## File Map

| File | Responsibility | Task |
|---|---|---|
| `governance.bicep`, `params/governance.bicepparam` (new in Task 1, replace in Tasks 2 and 3), `governance.json` (generate in Tasks 1–3) | Operator entry point: plans and contact (1); policy, allowlist and exemptions (2); JIT role and assignments (3) | 1, 2, 3 |
| `modules/governance/defenderPlans.bicep`, `modules/governance/securityContacts.bicep` (new) | Six Defender plans; the `default` security contact | 1 |
| `.gitignore`, `.github/workflows/deploy.yml`, `.github/workflows/bicep-ci.yml` (replace); `docs/runbooks/00-pipeline-and-identity.md` (edit) | `modules/**/*.json`; governance-only paths skip the deploy; the PSRule placeholder | 1 |
| `modules/governance/policies.bicep`, `modules/governance/flowLogStorageExemption.bicep`, `modules/governance/legacyWaiver.bicep` (new) | 11 assignments and the custom definition; flow-log exemptions; legacy waiver | 2 |
| `modules/types.bicep` (replace in Tasks 2 and 3) | `environmentRegionLayout` (2); `environmentAdminGroups` (3) | 2, 3 |
| `modules/governance/jitRequesterRole.bicep`, `modules/governance/jitRequesterAssignment.bicep` (new); `modules/virtualMachine.bicep`, `modules/spokeNetwork.bicep`, `modules/regionStamp.bicep`, `main.bicep` (replace), `main.json` (regenerate) | JIT role and assignment; NIC deny and JIT policy; comments and the `managementSourceCidrs` description | 3 |
| `tests/Governance.Tests.ps1` (new in Task 1, replace in Tasks 2 and 3); `tests/Params.Tests.ps1` (1, 2, 3); `tests/Lint.Tests.ps1`, `tests/Workflows.Tests.ps1` (1); `tests/VirtualMachine.Tests.ps1`, `tests/SpokeNetwork.Tests.ps1` (3) | Tests | 1–3 |
| `docs/runbooks/07-governance.md`, `docs/decisions/ADR-026/027/028/029-*` (new); `tests/Docs.Tests.ps1` (replace); `docs/decisions/ADR-014-*` (append); `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/00b-*`, `03-*`, `06-*`, `README.md` (edit) | Phase 7 docs | 4 |

---

### Task 1: Governance entry point, Defender for Cloud plans and the security contact

**Files:**
- Create: `governance.bicep`, `params/governance.bicepparam`, `modules/governance/defenderPlans.bicep`, `modules/governance/securityContacts.bicep`, `tests/Governance.Tests.ps1`
- Replace: `.gitignore`, `.github/workflows/deploy.yml`, `.github/workflows/bicep-ci.yml`, `tests/Lint.Tests.ps1`, `tests/Params.Tests.ps1`, `tests/Workflows.Tests.ps1`
- Modify: `docs/runbooks/00-pipeline-and-identity.md` (one edit), `governance.json` (generate)

**Interfaces:**
- **Consumes (Phases 0–6):** the test helpers in `tests/Bicep.TestHelpers.psm1`; the `Generated ARM template` test in `tests/Lint.Tests.ps1`; the `params/*.bicepparam` build test in `tests/Params.Tests.ps1`; the `on.push.paths` filter of `deploy.yml` and the `PSRule for Azure` step of `bicep-ci.yml`; `ps-rule.yaml`'s `pathIgnore '!params/*.bicepparam'`, which already picks up the new parameter file.
- **Produces:**
  - `governance.bicep` (`targetScope = 'subscription'`) params `securityContactEmails string[]` (`@minLength(1)`) and `malwareScanCapGbPerMonth int = 5000` (`@minValue(-1)`); modules `governance-defender-plans` and `governance-security-contacts`; output `defenderPlanNames`. No environment suffix: governance is per subscription.
  - `defenderPlans.bicep(malwareScanCapGbPerMonth = 5000)`, output `planNames`; `securityContacts.bicep(emails)`, output `name`.
  - `params/governance.bicepparam` with `using '../governance.bicep'` and `securityContactEmails` read from `SECURITY_CONTACT_EMAILS`.
  - `deploy.yml` path filters `'!modules/governance/**'` and `'!params/governance.bicepparam'`; `bicep-ci.yml` PSRule `env: SECURITY_CONTACT_EMAILS: security-contact@example.com`.

- [ ] **Step 1: Confirm the branch**

  The worktree `.claude/worktrees/phase7-governance` is on branch `phase7-governance` at `a2b9188` plus this plan's commit. Check it with `git log --oneline -2`. The baseline is `Tests Passed: 555, Failed: 0` and 1209 PSRule rules processed.

- [ ] **Step 2: Write the failing tests**

  Create `tests/Governance.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
      $plansTemplate = Get-BicepTemplate -RelativePath 'modules/governance/defenderPlans.bicep'
      $pricings = Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/pricings' | Select-Object -First 1
      $contactsTemplate = Get-BicepTemplate -RelativePath 'modules/governance/securityContacts.bicep'
      $contact = Get-TemplateResource -Template $contactsTemplate -Type 'Microsoft.Security/securityContacts' | Select-Object -First 1

      function Get-Plan([string]$Name) {
          @($plansTemplate.variables.plans | Where-Object { $_.name -eq $Name })[0]
      }
  }

  Describe 'Governance entry point (Phase 7)' {
      It 'is a subscription-scope template at the repository root' {
          Get-RepoPath 'governance.bicep' | Should -Exist
          $governance.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
      }

      It 'is never deployed by main.bicep or the pipeline (operator only, ADR-026)' {
          Get-Content (Get-RepoPath 'main.bicep') -Raw | Should -Not -Match 'governance'
          $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
          $deploy | Should -Not -Match 'governance\.bicep\b'
          $deploy | Should -Not -Match '--template-file'
      }

      It 'requires at least one security contact address' {
          $governance.parameters.securityContactEmails.type | Should -Be 'array'
          $governance.parameters.securityContactEmails.minLength | Should -Be 1
          $governance.parameters.securityContactEmails.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
      }

      It 'caps on-upload malware scanning at 5000 GB per storage account per month by default' {
          $governance.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
          $governance.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
      }

      It 'deploys the Defender plans with the malware scanning cap' {
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'defenderPlans'
          $module.properties.parameters.malwareScanCapGbPerMonth.value | Should -Be "[parameters('malwareScanCapGbPerMonth')]"
          $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
      }

      It 'deploys the security contact with the contact addresses' {
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'securityContacts'
          $module.properties.parameters.emails.value | Should -Be "[parameters('securityContactEmails')]"
          $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
      }
  }

  Describe 'Defender for Cloud plans (Phase 7)' {
      It 'deploys at subscription scope with the GA pricings API' {
          $plansTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $pricings.apiVersion | Should -Be '2024-01-01'
      }

      It 'updates one plan at a time, since parallel pricing updates conflict' {
          $pricings.copy.mode | Should -Be 'serial'
          $pricings.copy.batchSize | Should -Be 1
          $pricings.copy.count | Should -Be "[length(variables('plans'))]"
      }

      It 'enables exactly the spec plans: Servers, App Service, Storage, Key Vault, Resource Manager and Defender CSPM' {
          @($plansTemplate.variables.plans | ForEach-Object { $_.name }) -join ',' |
              Should -Be 'VirtualMachines,AppServices,StorageAccounts,KeyVaults,Arm,CloudPosture'
      }

      It 'sets every plan to Standard' {
          foreach ($plan in $plansTemplate.variables.plans) {
              $plan.properties.pricingTier | Should -Be 'Standard' -Because $plan.name
          }
          $pricings.properties | Should -Be "[variables('plans')[copyIndex()].properties]"
          $pricings.name | Should -Be "[variables('plans')[copyIndex()].name]"
      }

      It 'runs Defender for Servers Plan 2 with agentless VM scanning and no MDE direct onboarding' {
          $plan = Get-Plan 'VirtualMachines'
          $plan.properties.subPlan | Should -Be 'P2'
          @($plan.properties.extensions | ForEach-Object { $_.name }) | Should -Be @('AgentlessVmScanning')
          $plan.properties.extensions[0].isEnabled | Should -BeExactly 'True'
      }

      It 'runs Defender for Storage V2 with capped on-upload malware scanning and sensitive data discovery' {
          $plan = Get-Plan 'StorageAccounts'
          $plan.properties.subPlan | Should -Be 'DefenderForStorageV2'
          @($plan.properties.extensions | ForEach-Object { $_.name }) -join ',' | Should -Be 'OnUploadMalwareScanning,SensitiveDataDiscovery'
          foreach ($extension in $plan.properties.extensions) {
              $extension.isEnabled | Should -BeExactly 'True' -Because $extension.name
          }
          $malware = @($plan.properties.extensions | Where-Object { $_.name -eq 'OnUploadMalwareScanning' })[0]
          $malware.additionalExtensionProperties.CapGBPerMonthPerStorageAccount | Should -Be "[string(parameters('malwareScanCapGbPerMonth'))]"
      }

      It 'leaves <_> on the Azure default sub-plan with no extensions' -ForEach 'AppServices', 'KeyVaults', 'Arm', 'CloudPosture' {
          $plan = Get-Plan $_
          $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'subPlan'
          $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'extensions'
      }

      It 'does not manage the retired legacy agent auto-provisioning setting' {
          Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/autoProvisioningSettings' | Should -BeNullOrEmpty
      }

      It 'defaults the malware scanning cap to 5000 GB and allows -1 for no cap' {
          $plansTemplate.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
          $plansTemplate.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
      }
  }

  Describe 'Defender for Cloud security contact (Phase 7)' {
      It 'is the subscription singleton named default' {
          $contactsTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $contact.name | Should -Be 'default'
      }

      It 'pins 2023-12-01-preview, the latest version; the type has no GA version (ADR-029)' {
          $contact.apiVersion | Should -Be '2023-12-01-preview'
      }

      It 'emails every address, semicolon-separated, and requires at least one' {
          $contact.properties.isEnabled | Should -BeExactly $true
          $contact.properties.emails | Should -Be "[join(parameters('emails'), ';')]"
          $contactsTemplate.parameters.emails.minLength | Should -Be 1
      }

      It 'also notifies subscription Owners' {
          $contact.properties.notificationsByRole.state | Should -Be 'On'
          @($contact.properties.notificationsByRole.roles) | Should -Be @('Owner')
      }

      It 'emails alerts of severity High only' {
          $sources = @($contact.properties.notificationsSources)
          $sources.Count | Should -Be 1
          $sources[0].sourceType | Should -Be 'Alert'
          $sources[0].minimalSeverity | Should -Be 'High'
      }
  }
  ```

  Replace `tests/Lint.Tests.ps1` (the drift test now covers both root entry points):

  ```powershell
  BeforeDiscovery {
      $repoRoot = Split-Path -Parent $PSScriptRoot
      # Match against each file's path relative to $repoRoot, not FullName: the repository can be
      # checked out under a directory that itself contains a path segment such as '.claude' (e.g. a
      # worktree under '<repo>\.claude\worktrees\<name>'), which would otherwise make every file look
      # excluded.
      $bicepFiles = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.bicep' |
          ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); FullName = $_.FullName } } |
          Where-Object { $_.Name -notmatch '(^|[\\/])\.(git|claude|superpowers)([\\/]|$)' }
  }

  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
  }

  Describe 'Repository linter configuration' {
      It 'has bicepconfig.json at the repository root' {
          Get-RepoPath 'bicepconfig.json' | Should -Exist
      }

      It 'raises security rules to error level' {
          $config = Get-Content (Get-RepoPath 'bicepconfig.json') -Raw | ConvertFrom-Json
          foreach ($rule in 'secure-parameter-default', 'outputs-should-not-contain-secrets', 'use-secure-value-for-secure-inputs', 'no-hardcoded-env-urls', 'secure-secrets-in-params') {
              $config.analyzers.core.rules.$rule.level | Should -Be 'error' -Because "$rule protects secrets and portability"
          }
      }

      It 'ignores local secret parameter overlays' {
          Get-Content (Get-RepoPath '.gitignore') | Should -Contain '*.local.bicepparam'
      }
  }

  Describe 'Bicep lint' {
      It '<Name> lints without errors' -ForEach $bicepFiles {
          $output = & bicep lint $FullName 2>&1
          $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
      }
  }

  Describe 'Generated ARM template' {
      # Both root entry points commit their build: main.json (pipeline) and governance.json (operator, Phase 7).
      It '<_>.json matches a fresh build of <_>.bicep' -ForEach 'main', 'governance' {
          [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
          $expected = ((& bicep build (Get-RepoPath "$_.bicep") --stdout) -join "`n").Trim()
          $actual = ((Get-Content (Get-RepoPath "$_.json") -Raw -Encoding UTF8) -replace "`r`n", "`n").Trim()
          $actual | Should -BeExactly $expected -Because "run ""bicep build $_.bicep"" and commit $_.json"
      }
  }
  ```

  Replace `tests/Params.Tests.ps1`:

  ```powershell
  BeforeDiscovery {
      $repoRoot = Split-Path -Parent $PSScriptRoot
      $paramFiles = Get-ChildItem -Path (Join-Path $repoRoot 'params') -Filter '*.bicepparam' -ErrorAction SilentlyContinue |
          ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
  }

  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force

      function Get-BuiltParameters([string]$RelativePath) {
          [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
          $built = (& bicep build-params (Get-RepoPath $RelativePath) --stdout) -join "`n" | ConvertFrom-Json
          ($built.parametersJson | ConvertFrom-Json).parameters
      }

      # True when every prefix in $Prefixes shares the first two octets of $Space (all ranges here are /16 spaces).
      function Test-InsideSixteen([string]$Space, [string[]]$Prefixes) {
          $root = ($Space -split '\.')[0..1] -join '.'
          -not ($Prefixes | Where-Object { -not $_.StartsWith("$root.") })
      }

      $dev = Get-BuiltParameters 'params/dev.bicepparam'
      $prod = Get-BuiltParameters 'params/prod.bicepparam'
  }

  Describe 'Committed parameter files' {
      It 'includes dev and prod parameter files' {
          Get-RepoPath 'params/dev.bicepparam' | Should -Exist
          Get-RepoPath 'params/prod.bicepparam' | Should -Exist
      }

      It 'binds dev and prod to main.bicep and the governance file to governance.bicep (Phase 7)' {
          Get-Content (Get-RepoPath 'params/dev.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
          Get-Content (Get-RepoPath 'params/prod.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
          Get-Content (Get-RepoPath 'params/governance.bicepparam') -TotalCount 1 | Should -Be "using '../governance.bicep'"
      }

      It '<Name> builds against its template' -ForEach $paramFiles {
          $output = & bicep build-params $FullName --stdout 2>&1
          $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
      }

      It '<Name> contains no az.getSecret references (secrets belong in *.local.bicepparam)' -ForEach $paramFiles {
          Get-Content $FullName -Raw | Should -Not -Match 'getSecret'
      }
  }

  Describe 'Environment topology' {
      It 'runs dev in the primary region only' {
          $dev.environmentName.value | Should -Be 'dev'
          $dev.deploySecondaryRegion.value | Should -BeExactly $false
      }

      It 'runs prod in both regions with a secondary address plan' {
          $prod.environmentName.value | Should -Be 'prod'
          $prod.deploySecondaryRegion.value | Should -BeExactly $true
          $prod.secondaryAddressPlan.value | Should -Not -BeNullOrEmpty
      }
  }

  Describe 'Address plan' {
      It 'uses the spec ranges for prod (WUS3 hub 10.1/16, spoke 10.0/16; EUS hub 10.11/16, spoke 10.10/16)' {
          $prod.primaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.1.0.0/16'
          $prod.primaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.0.0.0/16'
          $prod.secondaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.11.0.0/16'
          $prod.secondaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.10.0.0/16'
      }

      It 'gives dev its own ranges so dev and prod never overlap' {
          $prodRanges = @($prod.primaryAddressPlan.value.hubAddressSpace + $prod.primaryAddressPlan.value.spokeAddressSpace +
              $prod.secondaryAddressPlan.value.hubAddressSpace + $prod.secondaryAddressPlan.value.spokeAddressSpace)
          foreach ($range in @($dev.primaryAddressPlan.value.hubAddressSpace + $dev.primaryAddressPlan.value.spokeAddressSpace)) {
              $prodRanges | Should -Not -Contain $range
          }
      }

      It 'keeps every subnet inside its VNet in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          Test-InsideSixteen $plan.hubAddressSpace[0] @($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Should -BeTrue
          Test-InsideSixteen $plan.spokeAddressSpace[0] @($plan.privateEndpointSubnetPrefix, $plan.appServiceIntegrationSubnetPrefix, $plan.managementSubnetPrefix) | Should -BeTrue
      }
  }

  Describe 'Admin access address plan (Phase 3)' {
      BeforeAll {
          $plans = @($dev.primaryAddressPlan.value, $prod.primaryAddressPlan.value, $prod.secondaryAddressPlan.value)
      }

      It 'sizes the hub subnets for Azure (Bastion /26, GatewaySubnet /27) in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          $plan.bastionSubnetPrefix | Should -Match '/26$'
          $plan.gatewaySubnetPrefix | Should -Match '/27$'
          @(@($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'uses the spec pool 172.16.200.0/24 for the prod primary region' {
          $prod.primaryAddressPlan.value.vpnClientAddressPool | Should -Be '172.16.200.0/24'
      }

      It 'gives every region and environment its own VPN client pool' {
          @($plans | ForEach-Object { $_.vpnClientAddressPool } | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'keeps every VPN client pool outside every VNet (clients must never overlap Azure ranges)' {
          $vnetRoots = @($plans | ForEach-Object { @($_.hubAddressSpace) + @($_.spokeAddressSpace) } | ForEach-Object { ($_ -split '\.')[0..1] -join '.' })
          foreach ($plan in $plans) {
              $poolRoot = ($plan.vpnClientAddressPool -split '\.')[0..1] -join '.'
              $vnetRoots | Should -Not -Contain $poolRoot
          }
      }
  }

  Describe 'Front Door custom domain (Phase 4)' {
      It 'leaves the custom domain empty in <_> until the external DNS records exist (runbook 04)' -ForEach 'dev', 'prod' {
          $parameters = if ($_ -eq 'dev') { $dev } else { $prod }
          $parameters.customDomainHostName.value | Should -Be ''
      }
  }

  Describe 'Governance parameters (Phase 7)' {
      BeforeAll {
          $savedEmails = $env:SECURITY_CONTACT_EMAILS
          $governanceText = Get-Content (Get-RepoPath 'params/governance.bicepparam') -Raw
      }

      AfterAll {
          $env:SECURITY_CONTACT_EMAILS = $savedEmails
      }

      It 'commits no contact address; the operator sets SECURITY_CONTACT_EMAILS (runbook 07)' {
          $governanceText | Should -Not -Match '[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.'
          $governanceText | Should -Match ([regex]::Escape("readEnvironmentVariable('SECURITY_CONTACT_EMAILS', '')"))
      }

      It 'turns an unset SECURITY_CONTACT_EMAILS into an empty list, which the template refuses (minLength 1)' {
          $env:SECURITY_CONTACT_EMAILS = $null
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          @($parameters.securityContactEmails.value).Count | Should -Be 0
      }

      It 'splits SECURITY_CONTACT_EMAILS on semicolons, trimming spaces and dropping empty entries' {
          $env:SECURITY_CONTACT_EMAILS = ' secops@example.com ; ;cloud-admins@example.com;'
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          @($parameters.securityContactEmails.value) | Should -Be @('secops@example.com', 'cloud-admins@example.com')
      }

      It 'keeps the default 5000 GB malware scanning cap' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          $parameters.malwareScanCapGbPerMonth.value | Should -Be 5000
      }
  }
  ```

  Replace `tests/Workflows.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $ci = Get-Content (Get-RepoPath '.github/workflows/bicep-ci.yml') -Raw
      $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
  }

  Describe 'Workflows target the subscription scope' {
      It '<Name> uses az deployment sub, never az deployment group' -ForEach @(
          @{ Name = 'bicep-ci.yml'; Key = 'ci' },
          @{ Name = 'deploy.yml'; Key = 'deploy' }
      ) {
          $text = if ($Key -eq 'ci') { $ci } else { $deploy }
          $text | Should -Match 'az deployment sub '
          $text | Should -Not -Match 'az deployment group '
          $text | Should -Match 'DEPLOYMENT_LOCATION: westus3'
      }

      It '<Name> no longer reads the removed AZURE_RESOURCE_GROUP variable' -ForEach @(
          @{ Name = 'bicep-ci.yml'; Key = 'ci' },
          @{ Name = 'deploy.yml'; Key = 'deploy' }
      ) {
          $text = if ($Key -eq 'ci') { $ci } else { $deploy }
          $text | Should -Not -Match 'AZURE_RESOURCE_GROUP'
      }
  }

  Describe 'Deploy workflow gating' {
      It 'offers dev and prod and deploys only from main' {
          $deploy | Should -Match 'options: \[dev, prod\]'
          $deploy | Should -Match "if: github\.ref == 'refs/heads/main'"
          $deploy | Should -Match "environment: \$\{\{ inputs\.environment \|\| 'dev' \}\}"
      }

      It 'runs validate and what-if before create' {
          $validate = $deploy.IndexOf('az deployment sub validate')
          $whatIf = $deploy.IndexOf('az deployment sub what-if')
          $create = $deploy.IndexOf('az deployment sub create')
          $validate | Should -BeGreaterThan -1
          $whatIf | Should -BeGreaterThan $validate
          $create | Should -BeGreaterThan $whatIf
      }
  }

  Describe 'Deploy workflow plan/apply split (Phase 2)' {
      BeforeAll {
          $planStart = $deploy.IndexOf('  plan:')
          $applyStart = $deploy.IndexOf('  apply:')
          $planJob = $deploy.Substring($planStart, $applyStart - $planStart)
          $applyJob = $deploy.Substring($applyStart)
      }

      It 'has a plan job before an apply job' {
          $planStart | Should -BeGreaterThan -1
          $applyStart | Should -BeGreaterThan $planStart
      }

      It 'runs validate and what-if in the plan job, gated to prod for prod and dev-plan otherwise' {
          $planJob | Should -Match "environment: \$\{\{ inputs\.environment == 'prod' && 'prod' \|\| 'dev-plan' \}\}"
          $planJob | Should -Match 'az deployment sub validate'
          $planJob | Should -Match 'az deployment sub what-if'
          $planJob | Should -Not -Match 'az deployment sub create'
      }

      It 'creates only in the apply job, which waits for plan and runs in the reviewer-gated {env} environment' {
          $applyJob | Should -Match 'needs: plan'
          $applyJob | Should -Match "environment: \$\{\{ inputs\.environment \|\| 'dev' \}\}\s"
          $applyJob | Should -Match 'az deployment sub create'
          $applyJob | Should -Not -Match 'az deployment sub what-if'
      }

      It 'runs both jobs from main only' {
          ([regex]::Matches($deploy, "if: github\.ref == 'refs/heads/main'")).Count | Should -Be 2
      }

      It 'runs the PR what-if in dev-plan' {
          $ci | Should -Match 'environment: dev-plan'
      }

      It 'has no prod-plan environment anywhere' {
          $deploy | Should -Not -Match 'prod-plan'
      }

      It 'retains the what-if artifact for 14 days' {
          $planJob | Should -Match 'retention-days: 14'
      }

      It 'overwrites the what-if artifact so a re-run of a failed plan job does not fail on an existing artifact name (Final review D.4)' {
          $planJob | Should -Match 'overwrite: true'
      }
  }

  Describe 'Front Door private endpoint approval (Phase 4)' {
      It 'approves Front Door connections after the deployment, from the deployment outputs' {
          $create = $deploy.IndexOf('az deployment sub create')
          $approve = $deploy.IndexOf('./scripts/Approve-FrontDoorPrivateEndpoints.ps1')
          $approve | Should -BeGreaterThan $create
          $deploy | Should -Match ([regex]::Escape('--query properties.outputs --output json'))
          $deploy | Should -Match ([regex]::Escape('az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}"'))
      }

      It 'fails the job when the outputs cannot be read' {
          $deploy | Should -Match ([regex]::Escape("throw 'Could not read appServiceIds from the deployment outputs.'"))
          $deploy | Should -Match ([regex]::Escape("throw 'Could not read frontDoorProfileName from the deployment outputs.'"))
          $deploy | Should -Match ([regex]::Escape("throw 'Could not read globalResourceGroupName from the deployment outputs.'"))
      }

      It 'passes the Front Door profile and global resource group names to the approval script (final review A)' {
          $deploy | Should -Match ([regex]::Escape('-AppServiceId $ids -FrontDoorProfileName $profileName -FrontDoorResourceGroupName $resourceGroupName'))
      }

      It 'refreshes the Azure login right before the approval step, since the wait can outlast the first token' {
          $create = $deploy.IndexOf('az deployment sub create')
          $refresh = $deploy.IndexOf('Refresh Azure login before approval')
          $approve = $deploy.IndexOf('Approve Front Door private endpoint connections')
          $refresh | Should -BeGreaterThan $create
          $approve | Should -BeGreaterThan $refresh

          $applyStart = $deploy.IndexOf('  apply:')
          $applyJob = $deploy.Substring($applyStart)
          ([regex]::Matches($applyJob, 'uses: azure/login@v2')).Count | Should -Be 2
      }
  }

  Describe 'Alert email from the ALERT_EMAIL environment variable (Phase 6)' {
      BeforeAll {
          $applyStart = $deploy.IndexOf('  apply:')
          $applyJob = $deploy.Substring($applyStart)
          $planJob = $deploy.Substring(0, $applyStart)
          $alertEmailArgument = '--parameters alertEmail="$ALERT_EMAIL"'
          $alertEmailVariable = 'ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}'
      }

      It 'passes alertEmail from vars.ALERT_EMAIL to validate, what-if and create' {
          ([regex]::Matches($planJob, [regex]::Escape($alertEmailArgument))).Count | Should -Be 2
          ([regex]::Matches($applyJob, [regex]::Escape($alertEmailArgument))).Count | Should -Be 1
          ([regex]::Matches($deploy, [regex]::Escape($alertEmailVariable))).Count | Should -Be 5
      }

      It 'fails the prod plan first, before checkout and sign-in, when ALERT_EMAIL is empty (final review M-7)' {
          $planSteps = $planJob.Substring($planJob.IndexOf('  plan:'))
          $check = $planSteps.IndexOf('- name: Require ALERT_EMAIL for prod')
          $check | Should -BeGreaterThan -1
          $check | Should -BeLessThan $planSteps.IndexOf('- uses: actions/checkout@v4')
          $check | Should -BeLessThan $planSteps.IndexOf('uses: azure/login@v2')
          $planSteps.Substring($planSteps.IndexOf('steps:')).TrimStart() | Should -Match '^steps:\s+(#[^\n]*\n\s+)*- name: Require ALERT_EMAIL for prod'
          $step = $planSteps.Substring($check, $planSteps.IndexOf('- uses: actions/checkout@v4') - $check)
          $step | Should -Match "if: env\.TARGET_ENV == 'prod'"
          $step | Should -Match ([regex]::Escape($alertEmailVariable))
          $step | Should -Match ([regex]::Escape('if [ -z "$ALERT_EMAIL" ]; then'))
          $step | Should -Match 'exit 1'
          # The address reaches the script through env:, never interpolated into run:.
          $step.Substring($step.IndexOf('run:')) | Should -Not -Match '\$\{\{'
      }

      It 'passes alertEmail to the pull request what-if, so it shows no spurious receiver change' {
          $ci | Should -Match ([regex]::Escape($alertEmailArgument))
          $ci | Should -Match ([regex]::Escape($alertEmailVariable))
      }

      It 'fails the prod apply before signing in to Azure when ALERT_EMAIL is empty' {
          $check = $applyJob.IndexOf('- name: Require ALERT_EMAIL for prod')
          $check | Should -BeGreaterThan -1
          $check | Should -BeLessThan $applyJob.IndexOf('uses: azure/login@v2')
          $check | Should -BeLessThan $applyJob.IndexOf('az deployment sub create')
          $step = $applyJob.Substring($check, $applyJob.IndexOf('- uses: actions/checkout@v4') - $check)
          $step | Should -Match "if: env\.TARGET_ENV == 'prod'"
          $step | Should -Match ([regex]::Escape('if [ -z "$ALERT_EMAIL" ]; then'))
          $step | Should -Match 'exit 1'
      }
  }

  Describe 'Governance stays outside the pipeline (Phase 7)' {
      It 'does not redeploy the workload when only governance files change (a redeploy resets the JIT NSG rules, ADR-028)' {
          $deploy | Should -Match ([regex]::Escape("      - 'modules/**'"))
          $deploy | Should -Match ([regex]::Escape("      - '!modules/governance/**'"))
          $deploy | Should -Match ([regex]::Escape("      - '!params/governance.bicepparam'"))
          # GitHub applies path filters in order, so each exclusion must follow the pattern it narrows.
          $deploy.IndexOf("'!modules/governance/**'") | Should -BeGreaterThan $deploy.IndexOf("'modules/**'")
          $deploy.IndexOf("'!params/governance.bicepparam'") | Should -BeGreaterThan $deploy.IndexOf("'params/**'")
      }

      It 'deploys only the environment parameter files, never governance' {
          $deploy | Should -Match ([regex]::Escape('--parameters "params/${TARGET_ENV}.bicepparam"'))
          $deploy | Should -Match 'options: \[dev, prod\]'
      }

      It 'still runs PSRule over every parameter file, governance included, with a placeholder contact list' {
          $ci | Should -Match ([regex]::Escape('Assert-PSRule -InputPath params/'))
          $psRuleStep = $ci.Substring($ci.IndexOf('- name: PSRule for Azure'))
          $psRuleStep | Should -Match 'SECURITY_CONTACT_EMAILS: security-contact@example\.com'
      }
  }
  ```

- [ ] **Step 3: Run the tests to confirm they fail**

  Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1`

  Expected failures:
  - the `Governance entry point (Phase 7)`, `Defender for Cloud plans (Phase 7)` and `Defender for Cloud security contact (Phase 7)` tests (no `governance.bicep` or `modules/governance/*.bicep` yet)
  - `governance.json matches a fresh build of governance.bicep`
  - the `using` binding test and the `Governance parameters (Phase 7)` tests in `Params.Tests.ps1`
  - the `Governance stays outside the pipeline (Phase 7)` tests

- [ ] **Step 4: Create the Defender modules**

  Create `modules/governance/defenderPlans.bicep`:

  ```bicep
  // Microsoft Defender for Cloud plans for the whole subscription (Phase 7). Deployed by an operator through
  // governance.bicep, never by the pipeline (ADR-026).
  targetScope = 'subscription'

  @description('Monthly cap, in GB per storage account, on Defender for Storage on-upload malware scanning, which is billed per GB scanned. -1 removes the cap.')
  @minValue(-1)
  param malwareScanCapGbPerMonth int = 5000

  // One entry per plan, in deployment order. A plan with no subPlan or extensions takes Azure's current default.
  var plans = [
    {
      // Servers Plan 2 with agentless disk scanning (Plan 2 is also what JIT VM access needs). Azure VMs reach
      // Defender for Endpoint through the integration Defender turns on by default, so MdeDesignatedSubscription,
      // which designates a subscription for directly onboarded non-Azure machines, stays off (ADR-026).
      name: 'VirtualMachines'
      properties: {
        pricingTier: 'Standard'
        subPlan: 'P2'
        extensions: [
          {
            name: 'AgentlessVmScanning'
            isEnabled: 'True'
          }
        ]
      }
    }
    {
      name: 'AppServices'
      properties: {
        pricingTier: 'Standard'
      }
    }
    {
      // Defender for Storage (per account): every upload is scanned for malware up to the monthly cap, and
      // sensitive data discovery is a separate extension.
      name: 'StorageAccounts'
      properties: {
        pricingTier: 'Standard'
        subPlan: 'DefenderForStorageV2'
        extensions: [
          {
            name: 'OnUploadMalwareScanning'
            isEnabled: 'True'
            additionalExtensionProperties: {
              CapGBPerMonthPerStorageAccount: string(malwareScanCapGbPerMonth)
            }
          }
          {
            name: 'SensitiveDataDiscovery'
            isEnabled: 'True'
          }
        ]
      }
    }
    {
      name: 'KeyVaults'
      properties: {
        pricingTier: 'Standard'
      }
    }
    {
      // Defender for Resource Manager.
      name: 'Arm'
      properties: {
        pricingTier: 'Standard'
      }
    }
    {
      // Defender CSPM.
      name: 'CloudPosture'
      properties: {
        pricingTier: 'Standard'
      }
    }
  ]

  // The pricing API rejects concurrent updates in one subscription ("Another update operation is in progress"),
  // so the plans are set one at a time.
  @batchSize(1)
  resource pricings 'Microsoft.Security/pricings@2024-01-01' = [for plan in plans: {
    name: plan.name
    properties: plan.properties
  }]

  output planNames string[] = [for (plan, index) in plans: pricings[index].name]
  ```

  Create `modules/governance/securityContacts.bicep`:

  ```bicep
  // Who Defender for Cloud emails about alerts in this subscription (Phase 7).
  targetScope = 'subscription'

  @description('Addresses that receive Defender for Cloud alert emails. At least one.')
  @minLength(1)
  param emails string[]

  // A subscription has one contact, and it must be named default. Microsoft.Security/securityContacts has no GA API
  // version; 2023-12-01-preview is the latest (ADR-029).
  resource securityContact 'Microsoft.Security/securityContacts@2023-12-01-preview' = {
    name: 'default'
    properties: {
      isEnabled: true
      emails: join(emails, ';')
      // Subscription Owners are emailed too, so an alert still reaches someone if the list goes stale.
      notificationsByRole: {
        state: 'On'
        roles: [
          'Owner'
        ]
      }
      notificationsSources: [
        {
          sourceType: 'Alert'
          minimalSeverity: 'High'
        }
      ]
    }
  }

  output name string = securityContact.name
  ```

- [ ] **Step 5: Create the entry point and its parameter file**

  Create `governance.bicep`:

  ```bicep
  // Subscription governance and posture (Phase 7): Microsoft Defender for Cloud plans and the security contact.
  // An operator deploys it with az deployment sub create (runbook 07). main.bicep and the pipeline never do, so the
  // pipeline identity needs no rights over Defender for Cloud (ADR-026).
  targetScope = 'subscription'

  @description('Addresses that receive Defender for Cloud alert emails. The parameter file reads them from the SECURITY_CONTACT_EMAILS environment variable.')
  @minLength(1)
  param securityContactEmails string[]

  @description('Monthly cap, in GB per storage account, on Defender for Storage on-upload malware scanning. -1 removes the cap.')
  @minValue(-1)
  param malwareScanCapGbPerMonth int = 5000

  module defenderPlans 'modules/governance/defenderPlans.bicep' = {
    name: 'governance-defender-plans'
    params: {
      malwareScanCapGbPerMonth: malwareScanCapGbPerMonth
    }
  }

  module securityContacts 'modules/governance/securityContacts.bicep' = {
    name: 'governance-security-contacts'
    params: {
      emails: securityContactEmails
    }
  }

  output defenderPlanNames string[] = defenderPlans.outputs.planNames
  ```

  Create `params/governance.bicepparam`:

  ```bicep
  using '../governance.bicep'

  // Subscription governance (Phase 7): one file per subscription, deployed by an operator (runbook 07), never by
  // the pipeline. When dev and prod share a subscription, this one file covers both; another subscription gets its own copy.
  // Contact addresses are not committed: set SECURITY_CONTACT_EMAILS (semicolon-separated) before the deployment.
  // Unset, the list is empty and Azure refuses the deployment (at least one address is required).
  param securityContactEmails = filter(
    map(split(readEnvironmentVariable('SECURITY_CONTACT_EMAILS', ''), ';'), email => trim(email)),
    email => !empty(email)
  )
  param malwareScanCapGbPerMonth = 5000
  ```

  Replace `.gitignore` (the old `modules/*.json` does not match `modules/governance/*.json`):

  ```
  # Local parameter overlays that reference or contain secrets. Never commit these.
  *.local.bicepparam
  *.secrets.bicepparam

  # Test and tool output
  test-results.xml
  whatif.txt
  whatif.md
  reports/

  # Bicep build output for modules; only the root entry points (main.json, governance.json) are committed build artifacts.
  modules/**/*.json
  ```

- [ ] **Step 6: Keep governance out of the deploy and give PSRule a placeholder contact**

  Replace `.github/workflows/deploy.yml` (two negated path filters; still no `governance.bicep` reference):

  ````yaml
  name: deploy

  on:
    push:
      branches: [main]
      paths:
        - 'main.bicep'
        - 'modules/**'
        # Governance is deployed by an operator (runbook 07); a workload redeploy would only reset the JIT NSG rules.
        - '!modules/governance/**'
        - 'params/**'
        - '!params/governance.bicepparam'
    workflow_dispatch:
      inputs:
        environment:
          description: Target environment
          type: choice
          options: [dev, prod]
          default: dev

  permissions:
    contents: read
    id-token: write

  concurrency:
    group: deploy-${{ inputs.environment || 'dev' }}
    cancel-in-progress: false

  env:
    BICEP_VERSION: v0.47.16
    DEPLOYMENT_LOCATION: westus3
    TARGET_ENV: ${{ inputs.environment || 'dev' }}

  jobs:
    # Prod: runs in the reviewer-gated prod environment (approve plan, read the what-if, then approve apply) so every prod token needs approval.
    # Dev: runs in dev-plan (no reviewers).
    plan:
      if: github.ref == 'refs/heads/main'
      runs-on: ubuntu-latest
      environment: ${{ inputs.environment == 'prod' && 'prod' || 'dev-plan' }}
      steps:
        # Same check as apply: a prod plan without ALERT_EMAIL would show a what-if that apply then refuses (runbook 06).
        - name: Require ALERT_EMAIL for prod
          if: env.TARGET_ENV == 'prod'
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            if [ -z "$ALERT_EMAIL" ]; then
              echo "::error::Set the ALERT_EMAIL variable on the prod GitHub environment before deploying prod (runbook 06)."
              exit 1
            fi

        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"

        - name: Validate
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            az deployment sub validate \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --parameters alertEmail="$ALERT_EMAIL" \
              --output none

        - name: What-if
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            set -o pipefail
            az deployment sub what-if \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --parameters alertEmail="$ALERT_EMAIL" \
              --exclude-change-types Ignore NoChange 2>&1 \
              | sed -r 's/\x1B\[[0-9;]*[mK]//g' > whatif.txt
            {
              echo "### What-if: ${TARGET_ENV} (subscription scope, rg-defenstack-${TARGET_ENV}-*)"
              echo '```'
              head -c 60000 whatif.txt
              echo '```'
            } >> "$GITHUB_STEP_SUMMARY"

        - name: Keep the what-if for reviewers
          uses: actions/upload-artifact@v4
          with:
            name: whatif-${{ inputs.environment || 'dev' }}
            path: whatif.txt
            retention-days: 14
            if-no-files-found: error
            overwrite: true

    # Gated by the target environment's required reviewers (prod); reviewers read the plan job summary first.
    apply:
      needs: plan
      if: github.ref == 'refs/heads/main'
      runs-on: ubuntu-latest
      environment: ${{ inputs.environment || 'dev' }}
      steps:
        # Prod alerts must reach someone: stop before any Azure call when the prod environment has no ALERT_EMAIL (runbook 06).
        - name: Require ALERT_EMAIL for prod
          if: env.TARGET_ENV == 'prod'
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            if [ -z "$ALERT_EMAIL" ]; then
              echo "::error::Set the ALERT_EMAIL variable on the prod GitHub environment before deploying prod (runbook 06)."
              exit 1
            fi

        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"

        # Application secrets come from the environment secret KEYVAULT_SECRETS_JSON and are written to every regional vault (ADR-019).
        - name: Prepare Key Vault secrets
          shell: pwsh
          env:
            KEYVAULT_SECRETS_JSON: ${{ secrets.KEYVAULT_SECRETS_JSON }}
          run: ./scripts/ConvertTo-KeyVaultSecretsParameter.ps1 -Json $env:KEYVAULT_SECRETS_JSON -OutFile "$env:RUNNER_TEMP/keyvault-secrets.json"

        - name: Deploy
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            az deployment sub create \
              --location "$DEPLOYMENT_LOCATION" \
              --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" \
              --parameters "params/${TARGET_ENV}.bicepparam" \
              --parameters keyVaultSecrets=@"$RUNNER_TEMP/keyvault-secrets.json" \
              --parameters alertEmail="$ALERT_EMAIL" \
              --output table

        - name: Remove the secrets file
          if: always()
          run: rm -f "$RUNNER_TEMP/keyvault-secrets.json"

        # The approval wait can outlast the first login's token (up to 15 minutes per app), so refresh it immediately
        # before the step that needs it.
        - name: Refresh Azure login before approval
          uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        # Front Door reaches each App Service over Private Link; its connections stay Pending until approved (runbook 04).
        - name: Approve Front Door private endpoint connections
          shell: pwsh
          run: |
            $outputs = az deployment sub show --name "gh-${{ github.run_id }}-${{ github.run_attempt }}" --query properties.outputs --output json | ConvertFrom-Json
            $ids = $outputs.appServiceIds.value
            $profileName = $outputs.frontDoorProfileName.value
            $resourceGroupName = $outputs.globalResourceGroupName.value
            if ($LASTEXITCODE -ne 0 -or -not $ids) { throw 'Could not read appServiceIds from the deployment outputs.' }
            if (-not $profileName) { throw 'Could not read frontDoorProfileName from the deployment outputs.' }
            if (-not $resourceGroupName) { throw 'Could not read globalResourceGroupName from the deployment outputs.' }
            ./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId $ids -FrontDoorProfileName $profileName -FrontDoorResourceGroupName $resourceGroupName
  ````

  Replace `.github/workflows/bicep-ci.yml`:

  ````yaml
  name: bicep-ci

  on:
    pull_request:
      branches: [main]
    push:
      branches: [main]
    workflow_dispatch:

  permissions:
    contents: read

  env:
    BICEP_VERSION: v0.47.16
    DEPLOYMENT_LOCATION: westus3

  jobs:
    validate:
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v4

        - name: Install Bicep CLI
          run: |
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"
            echo "$HOME/.azure/bin" >> "$GITHUB_PATH"

        - name: Lint, build, template assertions, main.json drift
          shell: pwsh
          run: ./tests/Invoke-Tests.ps1 -CI

        - name: PSRule for Azure
          shell: pwsh
          env:
            # params/governance.bicepparam reads the Defender contact list when it is deployed (runbook 07). A
            # placeholder lets PSRule check the security contact as it will be deployed.
            SECURITY_CONTACT_EMAILS: security-contact@example.com
          run: |
            Install-Module -Name PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force
            New-Item -ItemType Directory -Path reports -Force | Out-Null
            Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error -OutputFormat Sarif -OutputPath reports/ps-rule.sarif

        - name: Upload results
          if: always()
          uses: actions/upload-artifact@v4
          with:
            name: validation-results
            path: |
              test-results.xml
              reports/

    what-if:
      if: github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name == github.repository
      needs: validate
      runs-on: ubuntu-latest
      environment: dev-plan
      permissions:
        contents: read
        id-token: write
        pull-requests: write
      steps:
        - uses: actions/checkout@v4

        - uses: azure/login@v2
          with:
            client-id: ${{ vars.AZURE_CLIENT_ID }}
            tenant-id: ${{ vars.AZURE_TENANT_ID }}
            subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

        - name: What-if against dev
          env:
            ALERT_EMAIL: ${{ vars.ALERT_EMAIL }}
          run: |
            set -o pipefail
            az config set bicep.use_binary_from_path=false
            az bicep install --version "$BICEP_VERSION"
            az deployment sub what-if \
              --location "$DEPLOYMENT_LOCATION" \
              --name "pr-${{ github.event.pull_request.number }}-${{ github.run_attempt }}" \
              --parameters params/dev.bicepparam \
              --parameters alertEmail="$ALERT_EMAIL" \
              --exclude-change-types Ignore NoChange 2>&1 \
              | sed -r 's/\x1B\[[0-9;]*[mK]//g' > whatif.txt
            {
              echo "### What-if: dev (subscription scope, rg-defenstack-dev-*)"
              echo '```'
              head -c 60000 whatif.txt
              echo '```'
            } > whatif.md
            cat whatif.md >> "$GITHUB_STEP_SUMMARY"

        - name: Comment what-if on PR
          env:
            GH_TOKEN: ${{ github.token }}
          run: |
            gh pr comment "${{ github.event.pull_request.number }}" --body-file whatif.md --edit-last \
              || gh pr comment "${{ github.event.pull_request.number }}" --body-file whatif.md
  ````

  Update the local PSRule command in runbook 00. The edit is an exact find/replace, and the find text occurs once in the file. If it is not found, stop and report. Change nothing outside the find text. Read and write the file as UTF-8.

  **`docs/runbooks/00-pipeline-and-identity.md`, edit 1 of 1.** Find:

  ````markdown
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Install-Module -Name PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
  ```

  Installed `PSRule.Rules.Azure 1.47.0` on `PSRule v2.9.0`, Bicep CLI on `PATH`
  ````

  Replace with:

  ````markdown
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Install-Module -Name PSRule.Rules.Azure -RequiredVersion 1.47.0 -Scope CurrentUser -Force"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "$env:PSRULE_AZURE_BICEP_PATH = (Get-Command bicep).Source; $env:SECURITY_CONTACT_EMAILS = 'security-contact@example.com'; Assert-PSRule -InputPath params/ -Module PSRule.Rules.Azure -Format File -Outcome Fail, Error"
  ```

  `params/` also holds `governance.bicepparam` (Phase 7), which reads the Defender for Cloud contact list from `SECURITY_CONTACT_EMAILS` when an operator deploys it (runbook 07). Without the placeholder above, `Azure.Defender.SecurityContact` fails on an empty list; `bicep-ci.yml` sets the same placeholder on its PSRule step.

  Installed `PSRule.Rules.Azure 1.47.0` on `PSRule v2.9.0`, Bicep CLI on `PATH`
  ````

- [ ] **Step 7: Build, lint, test, YAML, PSRule**

  ```bash
  bicep build main.bicep
  bicep build governance.bicep
  for f in main.bicep governance.bicep modules/*.bicep modules/governance/*.bicep; do bicep lint "$f" || echo "LINT FAIL $f"; done
  git status --short main.json
  ```

  Expected: no `LINT FAIL`; `main.json` unchanged; a new `governance.json`. Then run the full suite: `Tests Passed: 592, Failed: 0`. The YAML check prints `YAML-OK`. PSRule (with `SECURITY_CONTACT_EMAILS` set): 0 failures, 1240 rules processed. The increase comes from the governance file, including `Azure.Defender.Servers`, `.Storage`, `.Storage.MalwareScan`, `.KeyVault`, `.Cspm` and `.SecurityContact`. If `Azure.Defender.SecurityContact` fails, the placeholder is not set.

- [ ] **Step 8: Commit**

  ```bash
  git add governance.bicep governance.json params/governance.bicepparam modules/governance/defenderPlans.bicep modules/governance/securityContacts.bicep .gitignore .github/workflows/deploy.yml .github/workflows/bicep-ci.yml docs/runbooks/00-pipeline-and-identity.md tests/Governance.Tests.ps1 tests/Lint.Tests.ps1 tests/Params.Tests.ps1 tests/Workflows.Tests.ps1
  git commit -m "feat: governance entry point with Defender for Cloud plans and security contact" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 2: Audit-first Azure Policy, the public IP allowlist and exemptions

**Files:**
- Create: `modules/governance/policies.bicep`, `modules/governance/flowLogStorageExemption.bicep`, `modules/governance/legacyWaiver.bicep`
- Replace: `governance.bicep`, `params/governance.bicepparam`, `modules/types.bicep`, `tests/Governance.Tests.ps1`, `tests/Params.Tests.ps1`
- Modify: `governance.json` (regenerate)

**Interfaces:**
- **Consumes (Task 1 and Phases 1–6):** `main.bicep` variable `regionCodes` and its resource group names `rg-defenstack-<env>-<code>`; `regionStamp.bicep` `nameSuffix`, `names.firewallPublicIp`, `names.bastionPublicIp`, the VPN gateway public IP prefix and `names.flowLogStorageAccount`; `vpnGateway.bicep`'s `-1`/`-2` suffixes; the parameter files' `deploySecondaryRegion`.
- **Produces:**
  - Exported type `environmentRegionLayout { dev: ('westus3' | 'eastus')[], prod: ('westus3' | 'eastus')[] }`.
  - `governance.bicep` params `denyEnforcement = 'DoNotEnforce'`, `environments = ['dev','prod']`, `environmentRegions`, `legacyResourceGroupName = 'defenStack'` and `legacyWaiverExpiresOn` (required, `yyyy-MM-dd`); variables `regionCodes`, `platformLocations`, `stamps`, `allowedPublicIpNames` and `diagnosticResourceTypes`; function `publicIpNames(environmentName, regionCode)`; output `allowedPublicIpNames`.
  - `policies.bicep(denyEnforcement, allowedLocations, allowedResourceGroupLocations, allowedPublicIpNames, diagnosticResourceTypes)`, deployment `governance-policies`, outputs `storagePublicNetworkAssignmentId` (the first public network access assignment) and `denyAssignmentIds` (nine IDs).
  - `flowLogStorageExemption.bicep(environmentName, location, regionCode, policyAssignmentId)`, deployment `governance-flow-log-exemption-<env>-<code>` in `rg-defenstack-<env>-<code>`, output `storageAccountName`.
  - `legacyWaiver.bicep(policyAssignmentIds, expiresOn)`, deployment `governance-legacy-waiver`, exemptions `defenstack-legacy-waiver-<assignment name>`.

- [ ] **Step 1: Write the failing tests**

  Replace `tests/Governance.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
      $plansTemplate = Get-BicepTemplate -RelativePath 'modules/governance/defenderPlans.bicep'
      $pricings = Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/pricings' | Select-Object -First 1
      $contactsTemplate = Get-BicepTemplate -RelativePath 'modules/governance/securityContacts.bicep'
      $contact = Get-TemplateResource -Template $contactsTemplate -Type 'Microsoft.Security/securityContacts' | Select-Object -First 1

      function Get-Plan([string]$Name) {
          @($plansTemplate.variables.plans | Where-Object { $_.name -eq $Name })[0]
      }
  }

  Describe 'Governance entry point (Phase 7)' {
      It 'is a subscription-scope template at the repository root' {
          Get-RepoPath 'governance.bicep' | Should -Exist
          $governance.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
      }

      It 'is never deployed by main.bicep or the pipeline (operator only, ADR-026)' {
          Get-Content (Get-RepoPath 'main.bicep') -Raw | Should -Not -Match 'governance'
          $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
          $deploy | Should -Not -Match 'governance\.bicep\b'
          $deploy | Should -Not -Match '--template-file'
      }

      It 'requires at least one security contact address' {
          $governance.parameters.securityContactEmails.type | Should -Be 'array'
          $governance.parameters.securityContactEmails.minLength | Should -Be 1
          $governance.parameters.securityContactEmails.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
      }

      It 'caps on-upload malware scanning at 5000 GB per storage account per month by default' {
          $governance.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
          $governance.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
      }

      It 'deploys the Defender plans with the malware scanning cap' {
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'defenderPlans'
          $module.properties.parameters.malwareScanCapGbPerMonth.value | Should -Be "[parameters('malwareScanCapGbPerMonth')]"
          $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
      }

      It 'deploys the security contact with the contact addresses' {
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'securityContacts'
          $module.properties.parameters.emails.value | Should -Be "[parameters('securityContactEmails')]"
          $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
      }
  }

  Describe 'Defender for Cloud plans (Phase 7)' {
      It 'deploys at subscription scope with the GA pricings API' {
          $plansTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $pricings.apiVersion | Should -Be '2024-01-01'
      }

      It 'updates one plan at a time, since parallel pricing updates conflict' {
          $pricings.copy.mode | Should -Be 'serial'
          $pricings.copy.batchSize | Should -Be 1
          $pricings.copy.count | Should -Be "[length(variables('plans'))]"
      }

      It 'enables exactly the spec plans: Servers, App Service, Storage, Key Vault, Resource Manager and Defender CSPM' {
          @($plansTemplate.variables.plans | ForEach-Object { $_.name }) -join ',' |
              Should -Be 'VirtualMachines,AppServices,StorageAccounts,KeyVaults,Arm,CloudPosture'
      }

      It 'sets every plan to Standard' {
          foreach ($plan in $plansTemplate.variables.plans) {
              $plan.properties.pricingTier | Should -Be 'Standard' -Because $plan.name
          }
          $pricings.properties | Should -Be "[variables('plans')[copyIndex()].properties]"
          $pricings.name | Should -Be "[variables('plans')[copyIndex()].name]"
      }

      It 'runs Defender for Servers Plan 2 with agentless VM scanning and no MDE direct onboarding' {
          $plan = Get-Plan 'VirtualMachines'
          $plan.properties.subPlan | Should -Be 'P2'
          @($plan.properties.extensions | ForEach-Object { $_.name }) | Should -Be @('AgentlessVmScanning')
          $plan.properties.extensions[0].isEnabled | Should -BeExactly 'True'
      }

      It 'runs Defender for Storage V2 with capped on-upload malware scanning and sensitive data discovery' {
          $plan = Get-Plan 'StorageAccounts'
          $plan.properties.subPlan | Should -Be 'DefenderForStorageV2'
          @($plan.properties.extensions | ForEach-Object { $_.name }) -join ',' | Should -Be 'OnUploadMalwareScanning,SensitiveDataDiscovery'
          foreach ($extension in $plan.properties.extensions) {
              $extension.isEnabled | Should -BeExactly 'True' -Because $extension.name
          }
          $malware = @($plan.properties.extensions | Where-Object { $_.name -eq 'OnUploadMalwareScanning' })[0]
          $malware.additionalExtensionProperties.CapGBPerMonthPerStorageAccount | Should -Be "[string(parameters('malwareScanCapGbPerMonth'))]"
      }

      It 'leaves <_> on the Azure default sub-plan with no extensions' -ForEach 'AppServices', 'KeyVaults', 'Arm', 'CloudPosture' {
          $plan = Get-Plan $_
          $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'subPlan'
          $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'extensions'
      }

      It 'does not manage the retired legacy agent auto-provisioning setting' {
          Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/autoProvisioningSettings' | Should -BeNullOrEmpty
      }

      It 'defaults the malware scanning cap to 5000 GB and allows -1 for no cap' {
          $plansTemplate.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
          $plansTemplate.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
      }
  }

  Describe 'Defender for Cloud security contact (Phase 7)' {
      It 'is the subscription singleton named default' {
          $contactsTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $contact.name | Should -Be 'default'
      }

      It 'pins 2023-12-01-preview, the latest version; the type has no GA version (ADR-029)' {
          $contact.apiVersion | Should -Be '2023-12-01-preview'
      }

      It 'emails every address, semicolon-separated, and requires at least one' {
          $contact.properties.isEnabled | Should -BeExactly $true
          $contact.properties.emails | Should -Be "[join(parameters('emails'), ';')]"
          $contactsTemplate.parameters.emails.minLength | Should -Be 1
      }

      It 'also notifies subscription Owners' {
          $contact.properties.notificationsByRole.state | Should -Be 'On'
          @($contact.properties.notificationsByRole.roles) | Should -Be @('Owner')
      }

      It 'emails alerts of severity High only' {
          $sources = @($contact.properties.notificationsSources)
          $sources.Count | Should -Be 1
          $sources[0].sourceType | Should -Be 'Alert'
          $sources[0].minimalSeverity | Should -Be 'High'
      }
  }

  Describe 'Governance policy parameters (Phase 7)' {
      It 'goes live audit-first: every deny assignment follows denyEnforcement, default DoNotEnforce (ADR-027)' {
          $governance.parameters.denyEnforcement.defaultValue | Should -Be 'DoNotEnforce'
          @($governance.parameters.denyEnforcement.allowedValues) -join ',' | Should -Be 'DoNotEnforce,Default'
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $module.properties.parameters.denyEnforcement.value | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'covers dev and prod by default, dev in West US 3 only and prod in both regions' {
          @($governance.parameters.environments.defaultValue) -join ',' | Should -Be 'dev,prod'
          @($governance.parameters.environments.allowedValues | Sort-Object) -join ',' | Should -Be 'dev,prod'
          @($governance.parameters.environmentRegions.defaultValue.dev) -join ',' | Should -Be 'westus3'
          @($governance.parameters.environmentRegions.defaultValue.prod) -join ',' | Should -Be 'westus3,eastus'
      }

      It 'allows West US 3, East US and global for resources, and the two regions for resource groups' {
          @($governance.variables.platformLocations) -join ',' | Should -Be 'westus3,eastus'
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $module.properties.parameters.allowedLocations.value | Should -Be "[concat(variables('platformLocations'), createArray('global'))]"
          $module.properties.parameters.allowedResourceGroupLocations.value | Should -Be "[variables('platformLocations')]"
      }

      It 'waives the legacy defenStack resource group by default, until a dated expiry' {
          $governance.parameters.legacyResourceGroupName.defaultValue | Should -Be 'defenStack'
          $governance.parameters.legacyWaiverExpiresOn.minLength | Should -Be 10
          $governance.parameters.legacyWaiverExpiresOn.maxLength | Should -Be 10
      }
  }

  Describe 'Name parity with the workload templates (Phase 7)' {
      BeforeAll {
          $main = Get-BicepTemplate -RelativePath 'main.bicep'
          $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
          $vpnTemplate = Get-BicepTemplate -RelativePath 'modules/vpnGateway.bicep'
          $exemptionTemplate = Get-BicepTemplate -RelativePath 'modules/governance/flowLogStorageExemption.bicep'
          $publicIpFunction = $governance.functions[0].members.publicIpNames
      }

      It 'uses the same region codes as main.bicep' {
          ($governance.variables.regionCodes | ConvertTo-Json -Compress) | Should -Be ($main.variables.regionCodes | ConvertTo-Json -Compress)
      }

      It 'names regional resource groups exactly as main.bicep does' {
          $main.variables.primaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('primaryRegionCode'))]"
          $governance.variables.stamps | Should -Match ([regex]::Escape("'resourceGroupName', format('rg-defenstack-{0}-{1}', lambdaVariables('environmentName'), variables('regionCodes')[lambdaVariables('location')])"))
          $governance.variables.stamps | Should -Match ([regex]::Escape("'regionCode', variables('regionCodes')[lambdaVariables('location')]"))
      }

      It 'hands each stamp the full region name as location, as main.bicep does (the name hash uses it)' {
          $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
          $primary.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
          $primary.properties.parameters.regionCode.value | Should -Be "[variables('primaryRegionCode')]"
          $governance.variables.stamps | Should -Match ([regex]::Escape("'location', lambdaVariables('location')"))
      }

      It 'allows the <Key> public IP name exactly as regionStamp.bicep builds it' -ForEach @(
          @{ Key = 'firewallPublicIp' }
          @{ Key = 'bastionPublicIp' }
      ) {
          $expression = $stamp.variables.names.$Key
          $expression | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)\)\]$"
          @($publicIpFunction.output.value) | Should -Contain $expression
      }

      It 'allows both active-active VPN gateway public IPs (prefix -1 and -2, as vpnGateway.bicep appends)' {
          $prefix = $stamp.variables.names.vpnGatewayPublicIp
          $prefix | Should -Be "[format('pip-vpng-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
          @($vpnTemplate.variables.instances) -join ',' | Should -Be '1,2'
          $vpnIps = Get-TemplateResource -Template $vpnTemplate -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
          $vpnIps.name | Should -Be "[format('{0}-{1}', parameters('publicIpNamePrefix'), variables('instances')[copyIndex()])]"
          foreach ($instance in 1, 2) {
              @($publicIpFunction.output.value) | Should -Contain "[format('pip-vpng-defenstack-{0}-{1}-$instance', parameters('environmentName'), parameters('regionCode'))]"
          }
          @($publicIpFunction.output.value).Count | Should -Be 4
      }

      It 'only the firewall, Bastion and VPN gateway modules create public IPs, so the allowlist is complete' {
          $owners = Get-ChildItem (Get-RepoPath 'modules') -Filter '*.bicep' -Recurse |
              Where-Object { (Get-Content $_.FullName -Raw) -match "'Microsoft\.Network/publicIPAddresses@" } |
              ForEach-Object { $_.Name } | Sort-Object
          @($owners) -join ',' | Should -Be 'azureFirewall.bicep,bastion.bicep,vpnGateway.bicep'
      }

      It 'computes the flow-log account name with the same formula as regionStamp.bicep' {
          $exemptionTemplate.variables.nameSuffix | Should -BeExactly $stamp.variables.nameSuffix
          $exemptionTemplate.variables.flowLogStorageAccountName | Should -BeExactly $stamp.variables.names.flowLogStorageAccount
          $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
      }
  }

  Describe 'Policy assignments (Phase 7)' {
      BeforeAll {
          $policyTemplate = Get-BicepTemplate -RelativePath 'modules/governance/policies.bicep'
          $assignments = @(Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyAssignments')
          $definition = Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyDefinitions' | Select-Object -First 1
          $publicNetwork = Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol 'publicNetworkAccess'

          function Get-Assignment([string]$Symbol) {
              Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol $Symbol
          }
      }

      It 'deploys at subscription scope with the GA policy APIs' {
          $policyTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          foreach ($assignment in $assignments) {
              $assignment.apiVersion | Should -Be '2025-11-01' -Because $assignment.name
          }
          $definition.apiVersion | Should -Be '2025-11-01'
      }

      It 'assigns the Microsoft cloud security benchmark initiative, enforced (its policies only audit)' {
          $mcsb = Get-Assignment 'cloudSecurityBenchmark'
          $mcsb.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')]"
          $mcsb.properties.enforcementMode | Should -Be 'Default'
          $mcsb.properties.PSObject.Properties.Name | Should -Not -Contain 'parameters'
      }

      It 'denies public network access on <Name>' -ForEach @(
          @{ Name = 'storage accounts'; Id = 'b2982f36-99f2-4db5-8eff-283140c09693' }
          @{ Name = 'Key Vault'; Id = '405c5871-3e91-4644-8a63-58e19d68ff5b' }
          @{ Name = 'App Service apps'; Id = '1b5ef780-c53c-4a64-87f3-bb9c8c8094ba' }
          @{ Name = 'App Service app slots'; Id = '701a595d-38fb-4a66-ae6d-fb3735217622' }
          @{ Name = 'Function apps'; Id = '969ac98b-88a8-449f-883c-2e9adb123127' }
          @{ Name = 'Function app slots'; Id = '11c82d0c-db9f-4d7b-97c5-f3f9aa957da2' }
      ) {
          @($policyTemplate.variables.publicNetworkAccessPolicies | ForEach-Object { $_.definitionId }) | Should -Contain $Id
      }

      It 'gives every public network access assignment effect Deny under denyEnforcement' {
          @($policyTemplate.variables.publicNetworkAccessPolicies).Count | Should -Be 6
          $publicNetwork.copy.count | Should -Be "[length(variables('publicNetworkAccessPolicies'))]"
          $publicNetwork.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', variables('publicNetworkAccessPolicies')[copyIndex()].definitionId)]"
          $publicNetwork.properties.parameters.effect.value | Should -Be 'Deny'
          $publicNetwork.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'lists storage first, since the flow-log exemption takes the first assignment' {
          $policyTemplate.variables.publicNetworkAccessPolicies[0].definitionId | Should -Be 'b2982f36-99f2-4db5-8eff-283140c09693'
          $policyTemplate.outputs.storagePublicNetworkAssignmentId.value | Should -Match "variables\('publicNetworkAccessPolicies'\)\[0\]\.name"
      }

      It 'restricts resource locations under denyEnforcement' {
          $locations = Get-Assignment 'allowedLocationsAssignment'
          $locations.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')]"
          $locations.properties.parameters.listOfAllowedLocations.value | Should -Be "[parameters('allowedLocations')]"
          $locations.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'restricts resource group locations under denyEnforcement' {
          $groups = Get-Assignment 'allowedResourceGroupLocationsAssignment'
          $groups.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e765b5de-1225-4ba3-bd56-1ac6695af988')]"
          $groups.properties.parameters.listOfAllowedLocations.value | Should -Be "[parameters('allowedResourceGroupLocations')]"
          $groups.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'sets no effect on the location policies, whose effect is Deny already' {
          foreach ($symbol in 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment') {
              (Get-Assignment $symbol).properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'effect'
          }
      }

      It 'tells the blocked caller why, on every deny assignment' {
          foreach ($symbol in 'publicNetworkAccess', 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment', 'publicIpAssignment') {
              @((Get-Assignment $symbol).properties.nonComplianceMessages).Count | Should -Be 1 -Because $symbol
              (Get-Assignment $symbol).properties.nonComplianceMessages[0].message | Should -Match 'runbook 07' -Because $symbol
          }
      }

      It 'audits missing diagnostic settings with AuditIfNotExists only, enforced, with no identity' {
          $diagnostics = Get-Assignment 'diagnosticSettingsAudit'
          $diagnostics.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', '7f89b1eb-583c-429a-8828-af049802c1d9')]"
          $diagnostics.properties.parameters.listOfResourceTypes.value | Should -Be "[parameters('diagnosticResourceTypes')]"
          $diagnostics.properties.enforcementMode | Should -Be 'Default'
          foreach ($assignment in $assignments) {
              $assignment.PSObject.Properties.Name | Should -Not -Contain 'identity' -Because $assignment.name
          }
          Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.PolicyInsights/remediations' | Should -BeNullOrEmpty
      }

      It 'records governance.bicep as the owner of every assignment (PSRule Azure.Policy.AssignmentAssignedBy)' {
          $policyTemplate.variables.assignmentMetadata.assignedBy | Should -Match 'governance\.bicep'
          foreach ($assignment in $assignments) {
              $assignment.properties.metadata | Should -Be "[variables('assignmentMetadata')]" -Because $assignment.name
          }
      }

      It 'names every assignment defenstack-* within the 64-character limit' {
          $names = @($policyTemplate.variables.publicNetworkAccessPolicies | ForEach-Object { $_.name }) +
              @($assignments | Where-Object { $_.name -notmatch '^\[' } | ForEach-Object { $_.name })
          $names.Count | Should -Be 11
          foreach ($name in $names) {
              $name | Should -Match '^defenstack-[a-z0-9-]+$'
              $name.Length | Should -BeLessOrEqual 64
          }
          @($names | Select-Object -Unique).Count | Should -Be $names.Count
      }

      It 'outputs the nine deny assignment IDs for the legacy waiver' {
          $policyTemplate.outputs.denyAssignmentIds.value | Should -Match "map\(variables\('publicNetworkAccessPolicies'\)"
          foreach ($symbol in 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment', 'publicIpAssignment') {
              $name = (Get-Assignment $symbol).name
              $policyTemplate.outputs.denyAssignmentIds.value | Should -Match ([regex]::Escape("'$name')"))
          }
      }
  }

  Describe 'Custom public IP allowlist policy (Phase 7)' {
      BeforeAll {
          $policyTemplate = Get-BicepTemplate -RelativePath 'modules/governance/policies.bicep'
          $definition = Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyDefinitions' | Select-Object -First 1
          $assignment = Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol 'publicIpAssignment'
      }

      It 'is a custom definition named defenstack-deny-public-ip-except-allowlist' {
          $definition.name | Should -Be 'defenstack-deny-public-ip-except-allowlist'
          $definition.properties.policyType | Should -Be 'Custom'
          $definition.properties.mode | Should -Be 'Indexed'
          $definition.properties.parameters.allowedNames.type | Should -Be 'Array'
      }

      It 'denies any public IP whose name is not in allowedNames' {
          $conditions = @($definition.properties.policyRule.if.allOf)
          $conditions.Count | Should -Be 2
          $conditions[0].field | Should -Be 'type'
          $conditions[0].equals | Should -Be 'Microsoft.Network/publicIPAddresses'
          $conditions[1].field | Should -Be 'name'
          # Bicep escapes the leading [ so ARM hands the expression to Azure Policy unevaluated.
          $conditions[1].notIn | Should -Be "[[parameters('allowedNames')]"
          $definition.properties.policyRule.then.effect | Should -Be 'deny'
      }

      It 'is assigned with the computed allowlist under denyEnforcement' {
          $assignment.properties.policyDefinitionId | Should -Be "[subscriptionResourceId('Microsoft.Authorization/policyDefinitions', 'defenstack-deny-public-ip-except-allowlist')]"
          $assignment.properties.parameters.allowedNames.value | Should -Be "[parameters('allowedPublicIpNames')]"
          $assignment.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
          $governancePolicies = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $governancePolicies.properties.parameters.allowedPublicIpNames.value | Should -Be "[variables('allowedPublicIpNames')]"
          $governance.variables.allowedPublicIpNames | Should -Be "[flatten(map(variables('stamps'), lambda('stamp', __bicep.publicIpNames(lambdaVariables('stamp').environmentName, lambdaVariables('stamp').regionCode))))]"
      }
  }

  Describe 'Diagnostic settings audit scope (Phase 7)' {
      It 'audits exactly the resource types whose modules send logs and metrics to the workspace' {
          @($governance.variables.diagnosticResourceTypes | Sort-Object) -join ',' | Should -Be (@(
                  'Microsoft.Cdn/profiles'
                  'Microsoft.KeyVault/vaults'
                  'Microsoft.Network/azureFirewalls'
                  'Microsoft.Network/bastionHosts'
                  'Microsoft.Network/virtualNetworkGateways'
                  'Microsoft.Storage/storageAccounts/blobServices'
                  'Microsoft.Web/sites'
              ) -join ',')
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $module.properties.parameters.diagnosticResourceTypes.value | Should -Be "[variables('diagnosticResourceTypes')]"
      }
  }

  Describe 'Policy exemptions (Phase 7)' {
      BeforeAll {
          $exemptionTemplate = Get-BicepTemplate -RelativePath 'modules/governance/flowLogStorageExemption.bicep'
          $flowLogExemption = Get-TemplateResource -Template $exemptionTemplate -Type 'Microsoft.Authorization/policyExemptions' | Select-Object -First 1
          $waiverTemplate = Get-BicepTemplate -RelativePath 'modules/governance/legacyWaiver.bicep'
          $waiver = Get-TemplateResource -Template $waiverTemplate -Type 'Microsoft.Authorization/policyExemptions' | Select-Object -First 1
          $flowLogModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'flowLogExemptions'
          $waiverModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'legacyWaiver'
      }

      It 'pins 2026-01-01-preview, the latest version; exemptions have no GA version (ADR-029)' {
          $flowLogExemption.apiVersion | Should -Be '2026-01-01-preview'
          $waiver.apiVersion | Should -Be '2026-01-01-preview'
      }

      It 'exempts each flow-log account from the storage public network access assignment as Mitigated (ADR-023)' {
          $flowLogExemption.scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', variables('flowLogStorageAccountName'))]"
          $flowLogExemption.properties.exemptionCategory | Should -Be 'Mitigated'
          $flowLogExemption.properties.policyAssignmentId | Should -Be "[parameters('policyAssignmentId')]"
          $flowLogExemption.properties.description | Should -Match 'ADR-023'
          $flowLogExemption.properties.PSObject.Properties.Name | Should -Not -Contain 'expiresOn'
      }

      It 'creates one flow-log exemption per environment and region, in the regional resource group' {
          $flowLogModule.copy.count | Should -Be "[length(variables('stamps'))]"
          $flowLogModule.resourceGroup | Should -Be "[variables('stamps')[copyIndex()].resourceGroupName]"
          $flowLogModule.properties.parameters.environmentName.value | Should -Be "[variables('stamps')[copyIndex()].environmentName]"
          $flowLogModule.properties.parameters.location.value | Should -Be "[variables('stamps')[copyIndex()].location]"
          $flowLogModule.properties.parameters.regionCode.value | Should -Be "[variables('stamps')[copyIndex()].regionCode]"
          $flowLogModule.properties.parameters.policyAssignmentId.value | Should -Be "[reference('policies').outputs.storagePublicNetworkAssignmentId.value]"
      }

      It 'waives every deny assignment on the legacy resource group, only when one is named' {
          $waiverModule.condition | Should -Be "[not(empty(parameters('legacyResourceGroupName')))]"
          $waiverModule.resourceGroup | Should -Be "[parameters('legacyResourceGroupName')]"
          $waiverModule.properties.parameters.policyAssignmentIds.value | Should -Be "[reference('policies').outputs.denyAssignmentIds.value]"
          $waiverModule.properties.parameters.expiresOn.value | Should -Be "[parameters('legacyWaiverExpiresOn')]"
      }

      It 'makes each legacy waiver a dated Waiver that points to runbook 01a' {
          $waiver.copy.count | Should -Be "[length(parameters('policyAssignmentIds'))]"
          $waiver.properties.exemptionCategory | Should -Be 'Waiver'
          $waiver.properties.policyAssignmentId | Should -Be "[parameters('policyAssignmentIds')[copyIndex()]]"
          $waiver.properties.expiresOn | Should -Be "[format('{0}T23:59:59Z', parameters('expiresOn'))]"
          $waiver.properties.description | Should -Match 'runbook 01a'
          $waiver.name | Should -Be "[format('defenstack-legacy-waiver-{0}', last(split(parameters('policyAssignmentIds')[copyIndex()], '/')))]"
      }
  }
  ```

  Replace `tests/Params.Tests.ps1`:

  ```powershell
  BeforeDiscovery {
      $repoRoot = Split-Path -Parent $PSScriptRoot
      $paramFiles = Get-ChildItem -Path (Join-Path $repoRoot 'params') -Filter '*.bicepparam' -ErrorAction SilentlyContinue |
          ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
  }

  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force

      function Get-BuiltParameters([string]$RelativePath) {
          [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
          $built = (& bicep build-params (Get-RepoPath $RelativePath) --stdout) -join "`n" | ConvertFrom-Json
          ($built.parametersJson | ConvertFrom-Json).parameters
      }

      # True when every prefix in $Prefixes shares the first two octets of $Space (all ranges here are /16 spaces).
      function Test-InsideSixteen([string]$Space, [string[]]$Prefixes) {
          $root = ($Space -split '\.')[0..1] -join '.'
          -not ($Prefixes | Where-Object { -not $_.StartsWith("$root.") })
      }

      $dev = Get-BuiltParameters 'params/dev.bicepparam'
      $prod = Get-BuiltParameters 'params/prod.bicepparam'
  }

  Describe 'Committed parameter files' {
      It 'includes dev and prod parameter files' {
          Get-RepoPath 'params/dev.bicepparam' | Should -Exist
          Get-RepoPath 'params/prod.bicepparam' | Should -Exist
      }

      It 'binds dev and prod to main.bicep and the governance file to governance.bicep (Phase 7)' {
          Get-Content (Get-RepoPath 'params/dev.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
          Get-Content (Get-RepoPath 'params/prod.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
          Get-Content (Get-RepoPath 'params/governance.bicepparam') -TotalCount 1 | Should -Be "using '../governance.bicep'"
      }

      It '<Name> builds against its template' -ForEach $paramFiles {
          $output = & bicep build-params $FullName --stdout 2>&1
          $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
      }

      It '<Name> contains no az.getSecret references (secrets belong in *.local.bicepparam)' -ForEach $paramFiles {
          Get-Content $FullName -Raw | Should -Not -Match 'getSecret'
      }
  }

  Describe 'Environment topology' {
      It 'runs dev in the primary region only' {
          $dev.environmentName.value | Should -Be 'dev'
          $dev.deploySecondaryRegion.value | Should -BeExactly $false
      }

      It 'runs prod in both regions with a secondary address plan' {
          $prod.environmentName.value | Should -Be 'prod'
          $prod.deploySecondaryRegion.value | Should -BeExactly $true
          $prod.secondaryAddressPlan.value | Should -Not -BeNullOrEmpty
      }
  }

  Describe 'Address plan' {
      It 'uses the spec ranges for prod (WUS3 hub 10.1/16, spoke 10.0/16; EUS hub 10.11/16, spoke 10.10/16)' {
          $prod.primaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.1.0.0/16'
          $prod.primaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.0.0.0/16'
          $prod.secondaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.11.0.0/16'
          $prod.secondaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.10.0.0/16'
      }

      It 'gives dev its own ranges so dev and prod never overlap' {
          $prodRanges = @($prod.primaryAddressPlan.value.hubAddressSpace + $prod.primaryAddressPlan.value.spokeAddressSpace +
              $prod.secondaryAddressPlan.value.hubAddressSpace + $prod.secondaryAddressPlan.value.spokeAddressSpace)
          foreach ($range in @($dev.primaryAddressPlan.value.hubAddressSpace + $dev.primaryAddressPlan.value.spokeAddressSpace)) {
              $prodRanges | Should -Not -Contain $range
          }
      }

      It 'keeps every subnet inside its VNet in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          Test-InsideSixteen $plan.hubAddressSpace[0] @($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Should -BeTrue
          Test-InsideSixteen $plan.spokeAddressSpace[0] @($plan.privateEndpointSubnetPrefix, $plan.appServiceIntegrationSubnetPrefix, $plan.managementSubnetPrefix) | Should -BeTrue
      }
  }

  Describe 'Admin access address plan (Phase 3)' {
      BeforeAll {
          $plans = @($dev.primaryAddressPlan.value, $prod.primaryAddressPlan.value, $prod.secondaryAddressPlan.value)
      }

      It 'sizes the hub subnets for Azure (Bastion /26, GatewaySubnet /27) in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          $plan.bastionSubnetPrefix | Should -Match '/26$'
          $plan.gatewaySubnetPrefix | Should -Match '/27$'
          @(@($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'uses the spec pool 172.16.200.0/24 for the prod primary region' {
          $prod.primaryAddressPlan.value.vpnClientAddressPool | Should -Be '172.16.200.0/24'
      }

      It 'gives every region and environment its own VPN client pool' {
          @($plans | ForEach-Object { $_.vpnClientAddressPool } | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'keeps every VPN client pool outside every VNet (clients must never overlap Azure ranges)' {
          $vnetRoots = @($plans | ForEach-Object { @($_.hubAddressSpace) + @($_.spokeAddressSpace) } | ForEach-Object { ($_ -split '\.')[0..1] -join '.' })
          foreach ($plan in $plans) {
              $poolRoot = ($plan.vpnClientAddressPool -split '\.')[0..1] -join '.'
              $vnetRoots | Should -Not -Contain $poolRoot
          }
      }
  }

  Describe 'Front Door custom domain (Phase 4)' {
      It 'leaves the custom domain empty in <_> until the external DNS records exist (runbook 04)' -ForEach 'dev', 'prod' {
          $parameters = if ($_ -eq 'dev') { $dev } else { $prod }
          $parameters.customDomainHostName.value | Should -Be ''
      }
  }

  Describe 'Governance parameters (Phase 7)' {
      BeforeAll {
          $savedEmails = $env:SECURITY_CONTACT_EMAILS
          $governanceText = Get-Content (Get-RepoPath 'params/governance.bicepparam') -Raw
      }

      AfterAll {
          $env:SECURITY_CONTACT_EMAILS = $savedEmails
      }

      It 'commits no contact address; the operator sets SECURITY_CONTACT_EMAILS (runbook 07)' {
          $governanceText | Should -Not -Match '[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.'
          $governanceText | Should -Match ([regex]::Escape("readEnvironmentVariable('SECURITY_CONTACT_EMAILS', '')"))
      }

      It 'turns an unset SECURITY_CONTACT_EMAILS into an empty list, which the template refuses (minLength 1)' {
          $env:SECURITY_CONTACT_EMAILS = $null
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          @($parameters.securityContactEmails.value).Count | Should -Be 0
      }

      It 'splits SECURITY_CONTACT_EMAILS on semicolons, trimming spaces and dropping empty entries' {
          $env:SECURITY_CONTACT_EMAILS = ' secops@example.com ; ;cloud-admins@example.com;'
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          @($parameters.securityContactEmails.value) | Should -Be @('secops@example.com', 'cloud-admins@example.com')
      }

      It 'keeps the default 5000 GB malware scanning cap' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          $parameters.malwareScanCapGbPerMonth.value | Should -Be 5000
      }

      It 'starts audit-first for dev and prod (ADR-027)' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          $parameters.denyEnforcement.value | Should -Be 'DoNotEnforce'
          @($parameters.environments.value) -join ',' | Should -Be 'dev,prod'
      }

      It 'gives the legacy waiver a real yyyy-MM-dd expiry' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          $parameters.legacyResourceGroupName.value | Should -Be 'defenStack'
          $expires = $parameters.legacyWaiverExpiresOn.value
          $expires | Should -Match '^\d{4}-\d{2}-\d{2}$'
          { [datetime]::ParseExact($expires, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } | Should -Not -Throw
      }

      It 'mirrors the environment parameter files in the governance region layout' {
          $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
          $main = Get-BicepTemplate -RelativePath 'main.bicep'
          $layout = $governance.parameters.environmentRegions.defaultValue
          # Dev runs the primary only; prod adds the secondary. Neither file overrides the region defaults.
          $dev.deploySecondaryRegion.value | Should -BeExactly $false
          $prod.deploySecondaryRegion.value | Should -BeExactly $true
          foreach ($parameters in $dev, $prod) {
              $parameters.PSObject.Properties.Name | Should -Not -Contain 'primaryLocation'
              $parameters.PSObject.Properties.Name | Should -Not -Contain 'secondaryLocation'
          }
          @($layout.dev) -join ',' | Should -Be $main.parameters.primaryLocation.defaultValue
          @($layout.prod) -join ',' | Should -Be "$($main.parameters.primaryLocation.defaultValue),$($main.parameters.secondaryLocation.defaultValue)"
      }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected failures: the `Governance policy parameters (Phase 7)`, `Name parity with the workload templates (Phase 7)`, `Policy assignments (Phase 7)`, `Custom public IP allowlist policy (Phase 7)`, `Diagnostic settings audit scope (Phase 7)` and `Policy exemptions (Phase 7)` tests (the new modules do not exist), and the three new parameter tests.

- [ ] **Step 3: Create the policy and exemption modules**

  Create `modules/governance/policies.bicep` (the rule's `'[parameters(''allowedNames'')]'` compiles to `[[parameters('allowedNames')]`, which a test pins; do not "fix" it):

  ```bicep
  // Azure Policy for the whole subscription (Phase 7): the Microsoft cloud security benchmark in audit, deny
  // assignments that go live audit-first through denyEnforcement (ADR-027), the custom public IP allowlist and the
  // diagnostic settings audit. No assignment has a managed identity, and nothing is remediated.
  targetScope = 'subscription'

  @description('Enforcement of every deny assignment: DoNotEnforce reports compliance without blocking; Default blocks (ADR-027).')
  @allowed([
    'DoNotEnforce'
    'Default'
  ])
  param denyEnforcement string

  @description('Locations where resources may be created, including global.')
  @minLength(1)
  param allowedLocations string[]

  @description('Locations where resource groups may be created.')
  @minLength(1)
  param allowedResourceGroupLocations string[]

  @description('Every public IP name the platform may create: the firewall, Bastion and VPN gateway IPs of each stamp.')
  @minLength(1)
  param allowedPublicIpNames string[]

  @description('Resource types audited for a diagnostic setting.')
  @minLength(1)
  param diagnosticResourceTypes string[]

  // Built-in "should disable public network access" policies. Storage stays first: the flow-log exemption uses it.
  var publicNetworkAccessPolicies = [
    {
      name: 'defenstack-deny-storage-public-network'
      displayName: 'Storage accounts should disable public network access'
      definitionId: 'b2982f36-99f2-4db5-8eff-283140c09693'
    }
    {
      name: 'defenstack-deny-key-vault-public-network'
      displayName: 'Azure Key Vault should disable public network access'
      definitionId: '405c5871-3e91-4644-8a63-58e19d68ff5b'
    }
    {
      name: 'defenstack-deny-app-public-network'
      displayName: 'App Service apps should disable public network access'
      definitionId: '1b5ef780-c53c-4a64-87f3-bb9c8c8094ba'
    }
    {
      name: 'defenstack-deny-app-slot-public-network'
      displayName: 'App Service app slots should disable public network access'
      definitionId: '701a595d-38fb-4a66-ae6d-fb3735217622'
    }
    {
      name: 'defenstack-deny-function-public-network'
      displayName: 'Function apps should disable public network access'
      definitionId: '969ac98b-88a8-449f-883c-2e9adb123127'
    }
    {
      name: 'defenstack-deny-function-slot-public-network'
      displayName: 'Function app slots should disable public network access'
      definitionId: '11c82d0c-db9f-4d7b-97c5-f3f9aa957da2'
    }
  ]

  // Azure Policy shows who owns each assignment; changes go through this file, never the portal.
  var assignmentMetadata = {
    assignedBy: 'DefenStack governance.bicep (runbook 07)'
  }

  // The benchmark's policies only audit by default, so the initiative is enforced from the start.
  resource cloudSecurityBenchmark 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
    name: 'defenstack-mcsb'
    properties: {
      metadata: assignmentMetadata
      displayName: 'Microsoft cloud security benchmark'
      description: 'Security posture baseline, audit only (Phase 7, runbook 07).'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')
      enforcementMode: 'Default'
    }
  }

  // The effect is Deny from the start; denyEnforcement carries the audit phase (ADR-027).
  resource publicNetworkAccess 'Microsoft.Authorization/policyAssignments@2025-11-01' = [for policy in publicNetworkAccessPolicies: {
    name: policy.name
    properties: {
      metadata: assignmentMetadata
      displayName: policy.displayName
      description: 'Data services are reached through private endpoints only (Phase 7, ADR-027).'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', policy.definitionId)
      enforcementMode: denyEnforcement
      parameters: {
        effect: {
          value: 'Deny'
        }
      }
      nonComplianceMessages: [
        {
          message: 'Public network access must be disabled; use the private endpoint. Exemptions: runbook 07.'
        }
      ]
    }
  }]

  // Neither location policy has an effect parameter: both always deny.
  resource allowedLocationsAssignment 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
    name: 'defenstack-allowed-locations'
    properties: {
      metadata: assignmentMetadata
      displayName: 'Allowed locations'
      description: 'Resources only in the platform regions, or global (Phase 7, ADR-027).'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
      enforcementMode: denyEnforcement
      parameters: {
        listOfAllowedLocations: {
          value: allowedLocations
        }
      }
      nonComplianceMessages: [
        {
          message: 'Only the platform regions (and global) are allowed. Exemptions: runbook 07.'
        }
      ]
    }
  }

  resource allowedResourceGroupLocationsAssignment 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
    name: 'defenstack-allowed-resource-group-locations'
    properties: {
      metadata: assignmentMetadata
      displayName: 'Allowed locations for resource groups'
      description: 'Resource groups only in the platform regions (Phase 7, ADR-027).'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e765b5de-1225-4ba3-bd56-1ac6695af988')
      enforcementMode: denyEnforcement
      parameters: {
        listOfAllowedLocations: {
          value: allowedResourceGroupLocations
        }
      }
      nonComplianceMessages: [
        {
          message: 'Resource groups are allowed only in the platform regions. Exemptions: runbook 07.'
        }
      ]
    }
  }

  // No built-in policy allows public IPs by name. Azure Policy compares the names case-insensitively.
  resource publicIpDefinition 'Microsoft.Authorization/policyDefinitions@2025-11-01' = {
    name: 'defenstack-deny-public-ip-except-allowlist'
    properties: {
      policyType: 'Custom'
      mode: 'Indexed'
      displayName: 'Deny public IP addresses except the platform allowlist'
      description: 'Only the firewall, Bastion and VPN gateway public IPs named by the platform may exist (Phase 7, ADR-027).'
      metadata: {
        category: 'Network'
      }
      parameters: {
        allowedNames: {
          type: 'Array'
          metadata: {
            displayName: 'Allowed public IP names'
            description: 'Names of the public IPs the platform deploys.'
          }
        }
      }
      policyRule: {
        if: {
          allOf: [
            {
              field: 'type'
              equals: 'Microsoft.Network/publicIPAddresses'
            }
            {
              field: 'name'
              // Evaluated by Azure Policy, not by the deployment (Bicep escapes the leading bracket).
              notIn: '[parameters(\'allowedNames\')]'
            }
          ]
        }
        then: {
          effect: 'deny'
        }
      }
    }
  }

  resource publicIpAssignment 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
    name: 'defenstack-deny-public-ip'
    properties: {
      metadata: assignmentMetadata
      displayName: 'Deny public IP addresses except the platform allowlist'
      description: 'Public IPs only for the firewall, Bastion and VPN gateways (Phase 7, ADR-027).'
      policyDefinitionId: publicIpDefinition.id
      enforcementMode: denyEnforcement
      parameters: {
        allowedNames: {
          value: allowedPublicIpNames
        }
      }
      nonComplianceMessages: [
        {
          message: 'This public IP name is not on the platform allowlist (governance.bicep). Exemptions: runbook 07.'
        }
      ]
    }
  }

  // AuditIfNotExists only: no identity, no remediation.
  resource diagnosticSettingsAudit 'Microsoft.Authorization/policyAssignments@2025-11-01' = {
    name: 'defenstack-audit-diagnostic-settings'
    properties: {
      metadata: assignmentMetadata
      displayName: 'Audit diagnostic setting for selected resource types'
      description: 'Platform resource types that send logs and metrics to the workspace keep doing so (Phase 7).'
      policyDefinitionId: tenantResourceId('Microsoft.Authorization/policyDefinitions', '7f89b1eb-583c-429a-8828-af049802c1d9')
      enforcementMode: 'Default'
      parameters: {
        listOfResourceTypes: {
          value: diagnosticResourceTypes
        }
      }
    }
  }

  output storagePublicNetworkAssignmentId string = publicNetworkAccess[0].id

  // Built from the names so the list is known up front; consumers still wait for this module to finish.
  output denyAssignmentIds string[] = concat(
    map(publicNetworkAccessPolicies, policy => subscriptionResourceId('Microsoft.Authorization/policyAssignments', policy.name)),
    [
      allowedLocationsAssignment.id
      allowedResourceGroupLocationsAssignment.id
      publicIpAssignment.id
    ]
  )
  ```

  Create `modules/governance/flowLogStorageExemption.bicep`:

  ```bicep
  // Exempts one region's flow-log storage account from the storage public network access assignment (Phase 7).
  // The account keeps public network access Enabled behind a deny-all firewall, so Network Watcher can write to it
  // as a trusted Azure service (ADR-023). Deployed into the regional resource group; the account must already exist.

  @description('Environment of the stamp that owns the account.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Full region name of the stamp, for example westus3. It is part of the account name hash.')
  param location string

  @description('Short region code of the stamp, for example wus3.')
  @minLength(2)
  @maxLength(4)
  param regionCode string

  @description('Resource ID of the storage public network access assignment.')
  param policyAssignmentId string

  // The same formula as regionStamp.bicep (nameSuffix and names.flowLogStorageAccount); a test pins the parity.
  var nameSuffix = uniqueString(subscription().id, environmentName, location)
  var flowLogStorageAccountName = 'stfl${regionCode}${nameSuffix}'

  resource flowLogStorage 'Microsoft.Storage/storageAccounts@2026-04-01' existing = {
    name: flowLogStorageAccountName
  }

  // Microsoft.Authorization/policyExemptions has no GA API version; 2026-01-01-preview is the latest (ADR-029).
  resource exemption 'Microsoft.Authorization/policyExemptions@2026-01-01-preview' = {
    name: 'defenstack-flow-log-storage-public-network'
    scope: flowLogStorage
    properties: {
      policyAssignmentId: policyAssignmentId
      exemptionCategory: 'Mitigated'
      displayName: 'Flow-log storage: deny-all firewall instead of disabled public access'
      description: 'Network Watcher writes VNet flow logs as a trusted Azure service. Public network access stays Enabled so the deny-all firewall and its trusted-services bypass apply; shared key is disabled (ADR-023).'
    }
  }

  output storageAccountName string = flowLogStorage.name
  ```

  Create `modules/governance/legacyWaiver.bicep`:

  ```bicep
  // Waives the deny assignments on the legacy defenStack resource group until it is migrated and torn down
  // (Phase 7, runbook 01a). Deployed into that resource group.

  @description('Resource IDs of the deny assignments to waive.')
  @minLength(1)
  param policyAssignmentIds string[]

  @description('Date the waivers expire, as yyyy-MM-dd (end of that day, UTC).')
  @minLength(10)
  @maxLength(10)
  param expiresOn string

  // Microsoft.Authorization/policyExemptions has no GA API version; 2026-01-01-preview is the latest (ADR-029).
  resource waivers 'Microsoft.Authorization/policyExemptions@2026-01-01-preview' = [for assignmentId in policyAssignmentIds: {
    name: 'defenstack-legacy-waiver-${last(split(assignmentId, '/'))}'
    properties: {
      policyAssignmentId: assignmentId
      exemptionCategory: 'Waiver'
      expiresOn: '${expiresOn}T23:59:59Z'
      displayName: 'Legacy defenStack resource group, pending teardown'
      description: 'The pre-platform resource group is migrated and torn down by runbook 01a; until then the deny assignments do not apply to it.'
    }
  }]
  ```

- [ ] **Step 4: Add the layout type and wire the policies**

  Replace `modules/types.bicep`:

  ```bicep
  // Shared parameter contracts between the subscription entry point, the global layer, and region stamps.

  @export()
  @description('Address plan for one region: hub VNet with the firewall, Bastion and gateway subnets, spoke VNet with its three subnets, and the P2S VPN client pool.')
  type regionAddressPlan = {
    @description('Hub VNet address space.')
    hubAddressSpace: string[]

    @description('AzureFirewallSubnet prefix (at least /26) inside hubAddressSpace.')
    firewallSubnetPrefix: string

    @description('AzureBastionSubnet prefix (at least /26) inside hubAddressSpace.')
    bastionSubnetPrefix: string

    @description('GatewaySubnet prefix (at least /27) inside hubAddressSpace.')
    gatewaySubnetPrefix: string

    @description('Point-to-site VPN client address pool. Must not overlap any VNet in any region or environment.')
    vpnClientAddressPool: string

    @description('Spoke VNet address space. Also the firewall source range for spoke egress rules.')
    spokeAddressSpace: string[]

    @description('private-endpoints subnet prefix inside spokeAddressSpace.')
    privateEndpointSubnetPrefix: string

    @description('appservice-integration subnet prefix inside spokeAddressSpace.')
    appServiceIntegrationSubnetPrefix: string

    @description('management subnet prefix inside spokeAddressSpace.')
    managementSubnetPrefix: string
  }

  @export()
  @description('Private DNS zone names (or resource IDs) keyed by private endpoint group: the application zones plus the Azure Monitor Private Link Scope zones (Phase 6).')
  type privateDnsZoneSet = {
    @description('Blob storage zone.')
    blob: string

    @description('App Service (sites) zone.')
    sites: string

    @description('Key Vault zone.')
    vault: string

    @description('Azure Monitor global endpoints zone (AMPLS).')
    monitor: string

    @description('Log Analytics workspace agent endpoints zone (AMPLS).')
    oms: string

    @description('Log Analytics workspace ingestion (ODS) endpoints zone (AMPLS).')
    ods: string

    @description('Log Analytics agent service endpoints zone (AMPLS).')
    agentsvc: string
  }

  @export()
  @description('A virtual network to link to a private DNS zone.')
  type virtualNetworkReference = {
    @description('VNet name; used to build a unique link name.')
    name: string

    @description('VNet resource ID.')
    id: string
  }

  @export()
  @description('Prod with DR only: how this region\'s firewall carries traffic to and from the other region over the hub-to-hub global peering (Phase 6).')
  type hubPeeringPlan = {
    @description('Private IP of the other region\'s firewall, the next hop for the other region\'s spoke.')
    remoteFirewallPrivateIp: string

    @description('Spoke address prefixes of the other region, routed from this AzureFirewallSubnet to the other firewall.')
    remoteSpokeAddressPrefixes: string[]

    @description('This region\'s part in Azure Monitor traffic: Host owns the AMPLS private endpoint, Client forwards its spoke to it.')
    monitorRole: 'Host' | 'Client'

    @description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
    monitorClientPrefixes: string[]

    @description('Private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint. Used by the Client rule.')
    monitorPrivateEndpointPrefixes: string[]
  }

  @export()
  @description('A dimension filter on a metric alert, for example StatusCode = 403.')
  type metricAlertDimension = {
    @description('Dimension name, for example StatusCode or Action.')
    name: string

    @description('Include matches only the values; Exclude matches everything else.')
    operator: 'Include' | 'Exclude'

    @description('Dimension values.')
    values: string[]
  }

  @export()
  @description('One static-threshold metric alert on a single resource (Phase 6).')
  type metricAlertRule = {
    @description('Short rule name, appended to the alert name prefix, for example firewall-health.')
    name: string

    @description('What the alert means. Shown in the alert email; runbook 06 has the triage steps.')
    description: string

    @description('Alert severity: 0 Critical, 1 Error, 2 Warning, 3 Informational, 4 Verbose.')
    severity: 0 | 1 | 2 | 3 | 4

    @description('Resource ID the metric is read from.')
    resourceId: string

    @description('Metric namespace, the resource type, for example Microsoft.Network/azureFirewalls.')
    metricNamespace: string

    @description('Exact metric name, for example FirewallHealth.')
    metricName: string

    @description('Comparison against the threshold.')
    operator: 'GreaterThan' | 'GreaterThanOrEqual' | 'LessThan' | 'LessThanOrEqual'

    @description('Threshold as text, for example \'90\' or \'99.9\'. Bicep has no decimal literals; the module converts it with json().')
    threshold: string

    @description('How the metric is aggregated over the window.')
    timeAggregation: 'Average' | 'Minimum' | 'Maximum' | 'Total' | 'Count'

    @description('Dimension filters. Omit for none.')
    dimensions: metricAlertDimension[]?

    @description('False skips the rule, for example the VPN alert in a region without a gateway. Defaults to true.')
    deploy: bool?
  }

  @export()
  @description('Thresholds for the count-based platform alerts (Phase 6). Health and percentage alerts use fixed thresholds.')
  type alertThresholdSet = {
    @description('App Service HTTP 5xx responses per region in a 15-minute window.')
    @minValue(1)
    appServiceHttp5xx: int

    @description('Key Vault requests refused with 403 per region in a 15-minute window.')
    @minValue(1)
    keyVaultForbidden: int

    @description('Point-to-site VPN connections on the gateway at any time in a 15-minute window.')
    @minValue(1)
    vpnP2sConnections: int

    @description('Front Door WAF blocked requests in a 15-minute window.')
    @minValue(1)
    frontDoorWafBlocks: int
  }

  @export()
  @description('Regions each environment runs in, as main.bicep lays out its stamps: the primary first, then the warm standby (Phase 7 governance).')
  type environmentRegionLayout = {
    @description('Dev regions. Dev runs primary-only (ADR-008).')
    dev: ('westus3' | 'eastus')[]

    @description('Prod regions: the primary, then the warm standby.')
    prod: ('westus3' | 'eastus')[]
  }
  ```

  Replace `governance.bicep`:

  ```bicep
  // Subscription governance and posture (Phase 7): Microsoft Defender for Cloud plans, the security contact and Azure
  // Policy with its exemptions. An operator deploys it with az deployment sub create (runbook 07). main.bicep and the
  // pipeline never do, so the pipeline identity needs no rights over Defender for Cloud or Azure Policy (ADR-026).
  targetScope = 'subscription'

  import { environmentRegionLayout } from 'modules/types.bicep'

  @description('Addresses that receive Defender for Cloud alert emails. The parameter file reads them from the SECURITY_CONTACT_EMAILS environment variable.')
  @minLength(1)
  param securityContactEmails string[]

  @description('Monthly cap, in GB per storage account, on Defender for Storage on-upload malware scanning. -1 removes the cap.')
  @minValue(-1)
  param malwareScanCapGbPerMonth int = 5000

  @description('Enforcement of every deny assignment. DoNotEnforce (audit-first) reports compliance without blocking; switch to Default once compliance is clean (ADR-027, runbook 07).')
  @allowed([
    'DoNotEnforce'
    'Default'
  ])
  param denyEnforcement string = 'DoNotEnforce'

  @description('Environments deployed in this subscription. Their public IPs are allowed and their flow-log accounts exempted; every listed stamp must already exist (runbook 07).')
  @minLength(1)
  param environments ('dev' | 'prod')[] = [
    'dev'
    'prod'
  ]

  @description('Regions each environment runs in, mirroring the dev and prod parameter files: dev primary-only, prod with the East US warm standby.')
  param environmentRegions environmentRegionLayout = {
    dev: [
      'westus3'
    ]
    prod: [
      'westus3'
      'eastus'
    ]
  }

  @description('Legacy resource group that gets a dated waiver from the deny assignments until runbook 01a tears it down. Empty skips the waiver.')
  param legacyResourceGroupName string = 'defenStack'

  @description('Date the legacy waiver expires, as yyyy-MM-dd (end of that day, UTC).')
  @minLength(10)
  @maxLength(10)
  param legacyWaiverExpiresOn string

  // The same region codes as main.bicep; a test pins the parity.
  var regionCodes = {
    westus3: 'wus3'
    eastus: 'eus'
  }
  var platformLocations = [
    'westus3'
    'eastus'
  ]

  // Every region stamp in this subscription, named as main.bicep names them.
  var stamps = flatten(map(environments, environmentName => map(environmentRegions[environmentName], location => {
    environmentName: environmentName
    location: location
    regionCode: regionCodes[location]
    resourceGroupName: 'rg-defenstack-${environmentName}-${regionCodes[location]}'
  })))

  // Every public IP a region stamp may create, named as regionStamp.bicep names them; vpnGateway.bicep appends -1
  // and -2 for the active-active gateway. Includes the admin-access IPs a warm standby creates only during failover.
  func publicIpNames(environmentName string, regionCode string) string[] => [
    'pip-afw-defenstack-${environmentName}-${regionCode}'
    'pip-bas-defenstack-${environmentName}-${regionCode}'
    'pip-vpng-defenstack-${environmentName}-${regionCode}-1'
    'pip-vpng-defenstack-${environmentName}-${regionCode}-2'
  ]

  var allowedPublicIpNames = flatten(map(stamps, stamp => publicIpNames(stamp.environmentName, stamp.regionCode)))

  // The resource types whose modules send both logs and metrics to the workspace. Storage logs live on the blob
  // service; public IPs, VNets and the jump host send no logs, so they are not audited.
  var diagnosticResourceTypes = [
    'Microsoft.Network/azureFirewalls'
    'Microsoft.Network/bastionHosts'
    'Microsoft.Network/virtualNetworkGateways'
    'Microsoft.Cdn/profiles'
    'Microsoft.KeyVault/vaults'
    'Microsoft.Web/sites'
    'Microsoft.Storage/storageAccounts/blobServices'
  ]

  module defenderPlans 'modules/governance/defenderPlans.bicep' = {
    name: 'governance-defender-plans'
    params: {
      malwareScanCapGbPerMonth: malwareScanCapGbPerMonth
    }
  }

  module securityContacts 'modules/governance/securityContacts.bicep' = {
    name: 'governance-security-contacts'
    params: {
      emails: securityContactEmails
    }
  }

  module policies 'modules/governance/policies.bicep' = {
    name: 'governance-policies'
    params: {
      denyEnforcement: denyEnforcement
      allowedLocations: concat(platformLocations, [
        'global'
      ])
      allowedResourceGroupLocations: platformLocations
      allowedPublicIpNames: allowedPublicIpNames
      diagnosticResourceTypes: diagnosticResourceTypes
    }
  }

  // Each flow-log account keeps public network access behind a deny-all firewall (ADR-023), so it is exempted.
  module flowLogExemptions 'modules/governance/flowLogStorageExemption.bicep' = [for stamp in stamps: {
    name: 'governance-flow-log-exemption-${stamp.environmentName}-${stamp.regionCode}'
    scope: resourceGroup(stamp.resourceGroupName)
    params: {
      environmentName: stamp.environmentName
      location: stamp.location
      regionCode: stamp.regionCode
      policyAssignmentId: policies.outputs.storagePublicNetworkAssignmentId
    }
  }]

  module legacyWaiver 'modules/governance/legacyWaiver.bicep' = if (!empty(legacyResourceGroupName)) {
    name: 'governance-legacy-waiver'
    scope: resourceGroup(legacyResourceGroupName)
    params: {
      policyAssignmentIds: policies.outputs.denyAssignmentIds
      expiresOn: legacyWaiverExpiresOn
    }
  }

  output defenderPlanNames string[] = defenderPlans.outputs.planNames
  output allowedPublicIpNames string[] = allowedPublicIpNames
  ```

  Replace `params/governance.bicepparam`:

  ```bicep
  using '../governance.bicep'

  // Subscription governance (Phase 7): one file per subscription, deployed by an operator (runbook 07), never by
  // the pipeline. When dev and prod share a subscription, this one file covers both; another subscription gets its own copy.
  // Contact addresses are not committed: set SECURITY_CONTACT_EMAILS (semicolon-separated) before the deployment.
  // Unset, the list is empty and Azure refuses the deployment (at least one address is required).
  param securityContactEmails = filter(
    map(split(readEnvironmentVariable('SECURITY_CONTACT_EMAILS', ''), ';'), email => trim(email)),
    email => !empty(email)
  )
  param malwareScanCapGbPerMonth = 5000
  // Audit-first: switch to 'Default' only after the compliance review in runbook 07 is clean (ADR-027).
  param denyEnforcement = 'DoNotEnforce'
  param environments = [
    'dev'
    'prod'
  ]
  // The legacy waiver ends here; extend it only with a dated reason in runbook 01a.
  param legacyResourceGroupName = 'defenStack'
  param legacyWaiverExpiresOn = '2027-03-31'
  ```

- [ ] **Step 5: Build, lint, test, PSRule**

  Run `bicep build main.bicep` and `bicep build governance.bicep`, and lint every file (no `LINT FAIL`). `main.json` must not change: `main.bicep` does not import the new type. The full suite should show `Tests Passed: 637, Failed: 0`. PSRule should show 0 failures out of 1324 rules processed, including `Azure.Policy.AssignmentDescriptors`, `Azure.Policy.AssignmentAssignedBy`, `Azure.Policy.Descriptors`, `Azure.Policy.ExemptionDescriptors` and `Azure.Policy.WaiverExpiry`.

- [ ] **Step 6: Commit**

  ```bash
  git add modules/governance/policies.bicep modules/governance/flowLogStorageExemption.bicep modules/governance/legacyWaiver.bicep modules/types.bicep governance.bicep governance.json params/governance.bicepparam tests/Governance.Tests.ps1 tests/Params.Tests.ps1
  git commit -m "feat: audit-first Azure Policy with a public IP allowlist and exemptions" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 3: Just-in-time access for the jump host and the JIT requester role

**Files:**
- Create: `modules/governance/jitRequesterRole.bicep`, `modules/governance/jitRequesterAssignment.bicep`
- Replace: `governance.bicep`, `params/governance.bicepparam`, `modules/types.bicep`, `modules/virtualMachine.bicep`, `modules/spokeNetwork.bicep`, `modules/regionStamp.bicep`, `main.bicep`, `tests/Governance.Tests.ps1`, `tests/Params.Tests.ps1`, `tests/VirtualMachine.Tests.ps1`, `tests/SpokeNetwork.Tests.ps1`
- Modify: `main.json`, `governance.json` (regenerate)

**Interfaces:**
- **Consumes (Task 2 and Phase 3):** `governance.bicep` variable `stamps`; `regionStamp.bicep`'s `adminSourceCidrs` (Bastion subnet, VPN pool and `managementSourceCidrs`), passed to `spokeNetwork.bicep` and `virtualMachine.bicep` as `managementSourceCidrs`, and its VM condition `enableVirtualMachine && isPrimary`; `virtualMachine.bicep`'s `virtualMachine` and `<vm>-nsg`; `adminGroupObjectId` in `params/<env>.bicepparam` (runbook 03).
- **Produces:**
  - Exported type `environmentAdminGroups { dev: string, prod: string }`.
  - `governance.bicep` param `adminGroupObjectIds` (default both `''`); `stamps` entries gain `isPrimary`; variable `jumpHostStamps`; modules `governance-jit-requester-role` and `governance-jit-requester-<env>-<code>`; output `jitRequesterRoleDefinitionId`.
  - `jitRequesterRole.bicep` (subscription scope), output `roleDefinitionId`; `jitRequesterAssignment.bicep(principalId, roleDefinitionId)`, output `roleAssignmentId`.
  - `virtualMachine.bicep`: variables `denyManagementInboundRule` (`deny-ssh-rdp-inbound`, 4000) and `jitPorts`; resource `jitPolicy` (`'${location}/default'`). The variable `managementInboundRules` is gone from this module only; `spokeNetwork.bicep` keeps its own.

- [ ] **Step 1: Write the failing tests**

  Replace `tests/Governance.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
      $plansTemplate = Get-BicepTemplate -RelativePath 'modules/governance/defenderPlans.bicep'
      $pricings = Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/pricings' | Select-Object -First 1
      $contactsTemplate = Get-BicepTemplate -RelativePath 'modules/governance/securityContacts.bicep'
      $contact = Get-TemplateResource -Template $contactsTemplate -Type 'Microsoft.Security/securityContacts' | Select-Object -First 1

      function Get-Plan([string]$Name) {
          @($plansTemplate.variables.plans | Where-Object { $_.name -eq $Name })[0]
      }
  }

  Describe 'Governance entry point (Phase 7)' {
      It 'is a subscription-scope template at the repository root' {
          Get-RepoPath 'governance.bicep' | Should -Exist
          $governance.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
      }

      It 'is never deployed by main.bicep or the pipeline (operator only, ADR-026)' {
          Get-Content (Get-RepoPath 'main.bicep') -Raw | Should -Not -Match 'governance'
          $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
          $deploy | Should -Not -Match 'governance\.bicep\b'
          $deploy | Should -Not -Match '--template-file'
      }

      It 'requires at least one security contact address' {
          $governance.parameters.securityContactEmails.type | Should -Be 'array'
          $governance.parameters.securityContactEmails.minLength | Should -Be 1
          $governance.parameters.securityContactEmails.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
      }

      It 'caps on-upload malware scanning at 5000 GB per storage account per month by default' {
          $governance.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
          $governance.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
      }

      It 'deploys the Defender plans with the malware scanning cap' {
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'defenderPlans'
          $module.properties.parameters.malwareScanCapGbPerMonth.value | Should -Be "[parameters('malwareScanCapGbPerMonth')]"
          $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
      }

      It 'deploys the security contact with the contact addresses' {
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'securityContacts'
          $module.properties.parameters.emails.value | Should -Be "[parameters('securityContactEmails')]"
          $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
      }
  }

  Describe 'Defender for Cloud plans (Phase 7)' {
      It 'deploys at subscription scope with the GA pricings API' {
          $plansTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $pricings.apiVersion | Should -Be '2024-01-01'
      }

      It 'updates one plan at a time, since parallel pricing updates conflict' {
          $pricings.copy.mode | Should -Be 'serial'
          $pricings.copy.batchSize | Should -Be 1
          $pricings.copy.count | Should -Be "[length(variables('plans'))]"
      }

      It 'enables exactly the spec plans: Servers, App Service, Storage, Key Vault, Resource Manager and Defender CSPM' {
          @($plansTemplate.variables.plans | ForEach-Object { $_.name }) -join ',' |
              Should -Be 'VirtualMachines,AppServices,StorageAccounts,KeyVaults,Arm,CloudPosture'
      }

      It 'sets every plan to Standard' {
          foreach ($plan in $plansTemplate.variables.plans) {
              $plan.properties.pricingTier | Should -Be 'Standard' -Because $plan.name
          }
          $pricings.properties | Should -Be "[variables('plans')[copyIndex()].properties]"
          $pricings.name | Should -Be "[variables('plans')[copyIndex()].name]"
      }

      It 'runs Defender for Servers Plan 2 with agentless VM scanning and no MDE direct onboarding' {
          $plan = Get-Plan 'VirtualMachines'
          $plan.properties.subPlan | Should -Be 'P2'
          @($plan.properties.extensions | ForEach-Object { $_.name }) | Should -Be @('AgentlessVmScanning')
          $plan.properties.extensions[0].isEnabled | Should -BeExactly 'True'
      }

      It 'runs Defender for Storage V2 with capped on-upload malware scanning and sensitive data discovery' {
          $plan = Get-Plan 'StorageAccounts'
          $plan.properties.subPlan | Should -Be 'DefenderForStorageV2'
          @($plan.properties.extensions | ForEach-Object { $_.name }) -join ',' | Should -Be 'OnUploadMalwareScanning,SensitiveDataDiscovery'
          foreach ($extension in $plan.properties.extensions) {
              $extension.isEnabled | Should -BeExactly 'True' -Because $extension.name
          }
          $malware = @($plan.properties.extensions | Where-Object { $_.name -eq 'OnUploadMalwareScanning' })[0]
          $malware.additionalExtensionProperties.CapGBPerMonthPerStorageAccount | Should -Be "[string(parameters('malwareScanCapGbPerMonth'))]"
      }

      It 'leaves <_> on the Azure default sub-plan with no extensions' -ForEach 'AppServices', 'KeyVaults', 'Arm', 'CloudPosture' {
          $plan = Get-Plan $_
          $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'subPlan'
          $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'extensions'
      }

      It 'does not manage the retired legacy agent auto-provisioning setting' {
          Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/autoProvisioningSettings' | Should -BeNullOrEmpty
      }

      It 'defaults the malware scanning cap to 5000 GB and allows -1 for no cap' {
          $plansTemplate.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
          $plansTemplate.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
      }
  }

  Describe 'Defender for Cloud security contact (Phase 7)' {
      It 'is the subscription singleton named default' {
          $contactsTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $contact.name | Should -Be 'default'
      }

      It 'pins 2023-12-01-preview, the latest version; the type has no GA version (ADR-029)' {
          $contact.apiVersion | Should -Be '2023-12-01-preview'
      }

      It 'emails every address, semicolon-separated, and requires at least one' {
          $contact.properties.isEnabled | Should -BeExactly $true
          $contact.properties.emails | Should -Be "[join(parameters('emails'), ';')]"
          $contactsTemplate.parameters.emails.minLength | Should -Be 1
      }

      It 'also notifies subscription Owners' {
          $contact.properties.notificationsByRole.state | Should -Be 'On'
          @($contact.properties.notificationsByRole.roles) | Should -Be @('Owner')
      }

      It 'emails alerts of severity High only' {
          $sources = @($contact.properties.notificationsSources)
          $sources.Count | Should -Be 1
          $sources[0].sourceType | Should -Be 'Alert'
          $sources[0].minimalSeverity | Should -Be 'High'
      }
  }

  Describe 'Governance policy parameters (Phase 7)' {
      It 'goes live audit-first: every deny assignment follows denyEnforcement, default DoNotEnforce (ADR-027)' {
          $governance.parameters.denyEnforcement.defaultValue | Should -Be 'DoNotEnforce'
          @($governance.parameters.denyEnforcement.allowedValues) -join ',' | Should -Be 'DoNotEnforce,Default'
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $module.properties.parameters.denyEnforcement.value | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'covers dev and prod by default, dev in West US 3 only and prod in both regions' {
          @($governance.parameters.environments.defaultValue) -join ',' | Should -Be 'dev,prod'
          @($governance.parameters.environments.allowedValues | Sort-Object) -join ',' | Should -Be 'dev,prod'
          @($governance.parameters.environmentRegions.defaultValue.dev) -join ',' | Should -Be 'westus3'
          @($governance.parameters.environmentRegions.defaultValue.prod) -join ',' | Should -Be 'westus3,eastus'
      }

      It 'allows West US 3, East US and global for resources, and the two regions for resource groups' {
          @($governance.variables.platformLocations) -join ',' | Should -Be 'westus3,eastus'
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $module.properties.parameters.allowedLocations.value | Should -Be "[concat(variables('platformLocations'), createArray('global'))]"
          $module.properties.parameters.allowedResourceGroupLocations.value | Should -Be "[variables('platformLocations')]"
      }

      It 'waives the legacy defenStack resource group by default, until a dated expiry' {
          $governance.parameters.legacyResourceGroupName.defaultValue | Should -Be 'defenStack'
          $governance.parameters.legacyWaiverExpiresOn.minLength | Should -Be 10
          $governance.parameters.legacyWaiverExpiresOn.maxLength | Should -Be 10
      }
  }

  Describe 'Name parity with the workload templates (Phase 7)' {
      BeforeAll {
          $main = Get-BicepTemplate -RelativePath 'main.bicep'
          $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
          $vpnTemplate = Get-BicepTemplate -RelativePath 'modules/vpnGateway.bicep'
          $exemptionTemplate = Get-BicepTemplate -RelativePath 'modules/governance/flowLogStorageExemption.bicep'
          $publicIpFunction = $governance.functions[0].members.publicIpNames
      }

      It 'uses the same region codes as main.bicep' {
          ($governance.variables.regionCodes | ConvertTo-Json -Compress) | Should -Be ($main.variables.regionCodes | ConvertTo-Json -Compress)
      }

      It 'names regional resource groups exactly as main.bicep does' {
          $main.variables.primaryResourceGroupName | Should -Be "[format('rg-defenstack-{0}-{1}', parameters('environmentName'), variables('primaryRegionCode'))]"
          $governance.variables.stamps | Should -Match ([regex]::Escape("'resourceGroupName', format('rg-defenstack-{0}-{1}', lambdaVariables('environmentName'), variables('regionCodes')[lambdaVariables('location')])"))
          $governance.variables.stamps | Should -Match ([regex]::Escape("'regionCode', variables('regionCodes')[lambdaVariables('location')]"))
      }

      It 'hands each stamp the full region name as location, as main.bicep does (the name hash uses it)' {
          $primary = Get-TemplateResourceBySymbol -Template $main -Symbol 'primaryStamp'
          $primary.properties.parameters.location.value | Should -Be "[parameters('primaryLocation')]"
          $primary.properties.parameters.regionCode.value | Should -Be "[variables('primaryRegionCode')]"
          $governance.variables.stamps | Should -Match ([regex]::Escape("'location', lambdaVariables('location')"))
      }

      It 'allows the <Key> public IP name exactly as regionStamp.bicep builds it' -ForEach @(
          @{ Key = 'firewallPublicIp' }
          @{ Key = 'bastionPublicIp' }
      ) {
          $expression = $stamp.variables.names.$Key
          $expression | Should -Match "parameters\('environmentName'\), parameters\('regionCode'\)\)\]$"
          @($publicIpFunction.output.value) | Should -Contain $expression
      }

      It 'allows both active-active VPN gateway public IPs (prefix -1 and -2, as vpnGateway.bicep appends)' {
          $prefix = $stamp.variables.names.vpnGatewayPublicIp
          $prefix | Should -Be "[format('pip-vpng-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
          @($vpnTemplate.variables.instances) -join ',' | Should -Be '1,2'
          $vpnIps = Get-TemplateResource -Template $vpnTemplate -Type 'Microsoft.Network/publicIPAddresses' | Select-Object -First 1
          $vpnIps.name | Should -Be "[format('{0}-{1}', parameters('publicIpNamePrefix'), variables('instances')[copyIndex()])]"
          foreach ($instance in 1, 2) {
              @($publicIpFunction.output.value) | Should -Contain "[format('pip-vpng-defenstack-{0}-{1}-$instance', parameters('environmentName'), parameters('regionCode'))]"
          }
          @($publicIpFunction.output.value).Count | Should -Be 4
      }

      It 'only the firewall, Bastion and VPN gateway modules create public IPs, so the allowlist is complete' {
          $owners = Get-ChildItem (Get-RepoPath 'modules') -Filter '*.bicep' -Recurse |
              Where-Object { (Get-Content $_.FullName -Raw) -match "'Microsoft\.Network/publicIPAddresses@" } |
              ForEach-Object { $_.Name } | Sort-Object
          @($owners) -join ',' | Should -Be 'azureFirewall.bicep,bastion.bicep,vpnGateway.bicep'
      }

      It 'computes the flow-log account name with the same formula as regionStamp.bicep' {
          $exemptionTemplate.variables.nameSuffix | Should -BeExactly $stamp.variables.nameSuffix
          $exemptionTemplate.variables.flowLogStorageAccountName | Should -BeExactly $stamp.variables.names.flowLogStorageAccount
          $stamp.variables.nameSuffix | Should -Be "[uniqueString(subscription().id, parameters('environmentName'), parameters('location'))]"
      }
  }

  Describe 'Policy assignments (Phase 7)' {
      BeforeAll {
          $policyTemplate = Get-BicepTemplate -RelativePath 'modules/governance/policies.bicep'
          $assignments = @(Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyAssignments')
          $definition = Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyDefinitions' | Select-Object -First 1
          $publicNetwork = Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol 'publicNetworkAccess'

          function Get-Assignment([string]$Symbol) {
              Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol $Symbol
          }
      }

      It 'deploys at subscription scope with the GA policy APIs' {
          $policyTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          foreach ($assignment in $assignments) {
              $assignment.apiVersion | Should -Be '2025-11-01' -Because $assignment.name
          }
          $definition.apiVersion | Should -Be '2025-11-01'
      }

      It 'assigns the Microsoft cloud security benchmark initiative, enforced (its policies only audit)' {
          $mcsb = Get-Assignment 'cloudSecurityBenchmark'
          $mcsb.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policySetDefinitions', '1f3afdf9-d0c9-4c3d-847f-89da613e70a8')]"
          $mcsb.properties.enforcementMode | Should -Be 'Default'
          $mcsb.properties.PSObject.Properties.Name | Should -Not -Contain 'parameters'
      }

      It 'denies public network access on <Name>' -ForEach @(
          @{ Name = 'storage accounts'; Id = 'b2982f36-99f2-4db5-8eff-283140c09693' }
          @{ Name = 'Key Vault'; Id = '405c5871-3e91-4644-8a63-58e19d68ff5b' }
          @{ Name = 'App Service apps'; Id = '1b5ef780-c53c-4a64-87f3-bb9c8c8094ba' }
          @{ Name = 'App Service app slots'; Id = '701a595d-38fb-4a66-ae6d-fb3735217622' }
          @{ Name = 'Function apps'; Id = '969ac98b-88a8-449f-883c-2e9adb123127' }
          @{ Name = 'Function app slots'; Id = '11c82d0c-db9f-4d7b-97c5-f3f9aa957da2' }
      ) {
          @($policyTemplate.variables.publicNetworkAccessPolicies | ForEach-Object { $_.definitionId }) | Should -Contain $Id
      }

      It 'gives every public network access assignment effect Deny under denyEnforcement' {
          @($policyTemplate.variables.publicNetworkAccessPolicies).Count | Should -Be 6
          $publicNetwork.copy.count | Should -Be "[length(variables('publicNetworkAccessPolicies'))]"
          $publicNetwork.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', variables('publicNetworkAccessPolicies')[copyIndex()].definitionId)]"
          $publicNetwork.properties.parameters.effect.value | Should -Be 'Deny'
          $publicNetwork.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'lists storage first, since the flow-log exemption takes the first assignment' {
          $policyTemplate.variables.publicNetworkAccessPolicies[0].definitionId | Should -Be 'b2982f36-99f2-4db5-8eff-283140c09693'
          $policyTemplate.outputs.storagePublicNetworkAssignmentId.value | Should -Match "variables\('publicNetworkAccessPolicies'\)\[0\]\.name"
      }

      It 'restricts resource locations under denyEnforcement' {
          $locations = Get-Assignment 'allowedLocationsAssignment'
          $locations.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')]"
          $locations.properties.parameters.listOfAllowedLocations.value | Should -Be "[parameters('allowedLocations')]"
          $locations.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'restricts resource group locations under denyEnforcement' {
          $groups = Get-Assignment 'allowedResourceGroupLocationsAssignment'
          $groups.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e765b5de-1225-4ba3-bd56-1ac6695af988')]"
          $groups.properties.parameters.listOfAllowedLocations.value | Should -Be "[parameters('allowedResourceGroupLocations')]"
          $groups.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
      }

      It 'sets no effect on the location policies, whose effect is Deny already' {
          foreach ($symbol in 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment') {
              (Get-Assignment $symbol).properties.parameters.PSObject.Properties.Name | Should -Not -Contain 'effect'
          }
      }

      It 'tells the blocked caller why, on every deny assignment' {
          foreach ($symbol in 'publicNetworkAccess', 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment', 'publicIpAssignment') {
              @((Get-Assignment $symbol).properties.nonComplianceMessages).Count | Should -Be 1 -Because $symbol
              (Get-Assignment $symbol).properties.nonComplianceMessages[0].message | Should -Match 'runbook 07' -Because $symbol
          }
      }

      It 'audits missing diagnostic settings with AuditIfNotExists only, enforced, with no identity' {
          $diagnostics = Get-Assignment 'diagnosticSettingsAudit'
          $diagnostics.properties.policyDefinitionId | Should -Be "[tenantResourceId('Microsoft.Authorization/policyDefinitions', '7f89b1eb-583c-429a-8828-af049802c1d9')]"
          $diagnostics.properties.parameters.listOfResourceTypes.value | Should -Be "[parameters('diagnosticResourceTypes')]"
          $diagnostics.properties.enforcementMode | Should -Be 'Default'
          foreach ($assignment in $assignments) {
              $assignment.PSObject.Properties.Name | Should -Not -Contain 'identity' -Because $assignment.name
          }
          Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.PolicyInsights/remediations' | Should -BeNullOrEmpty
      }

      It 'records governance.bicep as the owner of every assignment (PSRule Azure.Policy.AssignmentAssignedBy)' {
          $policyTemplate.variables.assignmentMetadata.assignedBy | Should -Match 'governance\.bicep'
          foreach ($assignment in $assignments) {
              $assignment.properties.metadata | Should -Be "[variables('assignmentMetadata')]" -Because $assignment.name
          }
      }

      It 'names every assignment defenstack-* within the 64-character limit' {
          $names = @($policyTemplate.variables.publicNetworkAccessPolicies | ForEach-Object { $_.name }) +
              @($assignments | Where-Object { $_.name -notmatch '^\[' } | ForEach-Object { $_.name })
          $names.Count | Should -Be 11
          foreach ($name in $names) {
              $name | Should -Match '^defenstack-[a-z0-9-]+$'
              $name.Length | Should -BeLessOrEqual 64
          }
          @($names | Select-Object -Unique).Count | Should -Be $names.Count
      }

      It 'outputs the nine deny assignment IDs for the legacy waiver' {
          $policyTemplate.outputs.denyAssignmentIds.value | Should -Match "map\(variables\('publicNetworkAccessPolicies'\)"
          foreach ($symbol in 'allowedLocationsAssignment', 'allowedResourceGroupLocationsAssignment', 'publicIpAssignment') {
              $name = (Get-Assignment $symbol).name
              $policyTemplate.outputs.denyAssignmentIds.value | Should -Match ([regex]::Escape("'$name')"))
          }
      }
  }

  Describe 'Custom public IP allowlist policy (Phase 7)' {
      BeforeAll {
          $policyTemplate = Get-BicepTemplate -RelativePath 'modules/governance/policies.bicep'
          $definition = Get-TemplateResource -Template $policyTemplate -Type 'Microsoft.Authorization/policyDefinitions' | Select-Object -First 1
          $assignment = Get-TemplateResourceBySymbol -Template $policyTemplate -Symbol 'publicIpAssignment'
      }

      It 'is a custom definition named defenstack-deny-public-ip-except-allowlist' {
          $definition.name | Should -Be 'defenstack-deny-public-ip-except-allowlist'
          $definition.properties.policyType | Should -Be 'Custom'
          $definition.properties.mode | Should -Be 'Indexed'
          $definition.properties.parameters.allowedNames.type | Should -Be 'Array'
      }

      It 'denies any public IP whose name is not in allowedNames' {
          $conditions = @($definition.properties.policyRule.if.allOf)
          $conditions.Count | Should -Be 2
          $conditions[0].field | Should -Be 'type'
          $conditions[0].equals | Should -Be 'Microsoft.Network/publicIPAddresses'
          $conditions[1].field | Should -Be 'name'
          # Bicep escapes the leading [ so ARM hands the expression to Azure Policy unevaluated.
          $conditions[1].notIn | Should -Be "[[parameters('allowedNames')]"
          $definition.properties.policyRule.then.effect | Should -Be 'deny'
      }

      It 'is assigned with the computed allowlist under denyEnforcement' {
          $assignment.properties.policyDefinitionId | Should -Be "[subscriptionResourceId('Microsoft.Authorization/policyDefinitions', 'defenstack-deny-public-ip-except-allowlist')]"
          $assignment.properties.parameters.allowedNames.value | Should -Be "[parameters('allowedPublicIpNames')]"
          $assignment.properties.enforcementMode | Should -Be "[parameters('denyEnforcement')]"
          $governancePolicies = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $governancePolicies.properties.parameters.allowedPublicIpNames.value | Should -Be "[variables('allowedPublicIpNames')]"
          $governance.variables.allowedPublicIpNames | Should -Be "[flatten(map(variables('stamps'), lambda('stamp', __bicep.publicIpNames(lambdaVariables('stamp').environmentName, lambdaVariables('stamp').regionCode))))]"
      }
  }

  Describe 'Diagnostic settings audit scope (Phase 7)' {
      It 'audits exactly the resource types whose modules send logs and metrics to the workspace' {
          @($governance.variables.diagnosticResourceTypes | Sort-Object) -join ',' | Should -Be (@(
                  'Microsoft.Cdn/profiles'
                  'Microsoft.KeyVault/vaults'
                  'Microsoft.Network/azureFirewalls'
                  'Microsoft.Network/bastionHosts'
                  'Microsoft.Network/virtualNetworkGateways'
                  'Microsoft.Storage/storageAccounts/blobServices'
                  'Microsoft.Web/sites'
              ) -join ',')
          $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'policies'
          $module.properties.parameters.diagnosticResourceTypes.value | Should -Be "[variables('diagnosticResourceTypes')]"
      }
  }

  Describe 'Policy exemptions (Phase 7)' {
      BeforeAll {
          $exemptionTemplate = Get-BicepTemplate -RelativePath 'modules/governance/flowLogStorageExemption.bicep'
          $flowLogExemption = Get-TemplateResource -Template $exemptionTemplate -Type 'Microsoft.Authorization/policyExemptions' | Select-Object -First 1
          $waiverTemplate = Get-BicepTemplate -RelativePath 'modules/governance/legacyWaiver.bicep'
          $waiver = Get-TemplateResource -Template $waiverTemplate -Type 'Microsoft.Authorization/policyExemptions' | Select-Object -First 1
          $flowLogModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'flowLogExemptions'
          $waiverModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'legacyWaiver'
      }

      It 'pins 2026-01-01-preview, the latest version; exemptions have no GA version (ADR-029)' {
          $flowLogExemption.apiVersion | Should -Be '2026-01-01-preview'
          $waiver.apiVersion | Should -Be '2026-01-01-preview'
      }

      It 'exempts each flow-log account from the storage public network access assignment as Mitigated (ADR-023)' {
          $flowLogExemption.scope | Should -Be "[resourceId('Microsoft.Storage/storageAccounts', variables('flowLogStorageAccountName'))]"
          $flowLogExemption.properties.exemptionCategory | Should -Be 'Mitigated'
          $flowLogExemption.properties.policyAssignmentId | Should -Be "[parameters('policyAssignmentId')]"
          $flowLogExemption.properties.description | Should -Match 'ADR-023'
          $flowLogExemption.properties.PSObject.Properties.Name | Should -Not -Contain 'expiresOn'
      }

      It 'creates one flow-log exemption per environment and region, in the regional resource group' {
          $flowLogModule.copy.count | Should -Be "[length(variables('stamps'))]"
          $flowLogModule.resourceGroup | Should -Be "[variables('stamps')[copyIndex()].resourceGroupName]"
          $flowLogModule.properties.parameters.environmentName.value | Should -Be "[variables('stamps')[copyIndex()].environmentName]"
          $flowLogModule.properties.parameters.location.value | Should -Be "[variables('stamps')[copyIndex()].location]"
          $flowLogModule.properties.parameters.regionCode.value | Should -Be "[variables('stamps')[copyIndex()].regionCode]"
          $flowLogModule.properties.parameters.policyAssignmentId.value | Should -Be "[reference('policies').outputs.storagePublicNetworkAssignmentId.value]"
      }

      It 'waives every deny assignment on the legacy resource group, only when one is named' {
          $waiverModule.condition | Should -Be "[not(empty(parameters('legacyResourceGroupName')))]"
          $waiverModule.resourceGroup | Should -Be "[parameters('legacyResourceGroupName')]"
          $waiverModule.properties.parameters.policyAssignmentIds.value | Should -Be "[reference('policies').outputs.denyAssignmentIds.value]"
          $waiverModule.properties.parameters.expiresOn.value | Should -Be "[parameters('legacyWaiverExpiresOn')]"
      }

      It 'makes each legacy waiver a dated Waiver that points to runbook 01a' {
          $waiver.copy.count | Should -Be "[length(parameters('policyAssignmentIds'))]"
          $waiver.properties.exemptionCategory | Should -Be 'Waiver'
          $waiver.properties.policyAssignmentId | Should -Be "[parameters('policyAssignmentIds')[copyIndex()]]"
          $waiver.properties.expiresOn | Should -Be "[format('{0}T23:59:59Z', parameters('expiresOn'))]"
          $waiver.properties.description | Should -Match 'runbook 01a'
          $waiver.name | Should -Be "[format('defenstack-legacy-waiver-{0}', last(split(parameters('policyAssignmentIds')[copyIndex()], '/')))]"
      }
  }

  Describe 'JIT requester role (Phase 7, ADR-028)' {
      BeforeAll {
          $roleTemplate = Get-BicepTemplate -RelativePath 'modules/governance/jitRequesterRole.bicep'
          $role = Get-TemplateResource -Template $roleTemplate -Type 'Microsoft.Authorization/roleDefinitions' | Select-Object -First 1
          $assignmentTemplate = Get-BicepTemplate -RelativePath 'modules/governance/jitRequesterAssignment.bicep'
          $assignment = Get-TemplateResource -Template $assignmentTemplate -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
          $roleModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'jitRequesterRole'
          $assignmentModule = Get-TemplateResourceBySymbol -Template $governance -Symbol 'jitRequesterAssignments'
      }

      It 'defines the DefenStack JIT Requester custom role at subscription scope, with a deterministic name' {
          $roleTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
          $role.apiVersion | Should -Be '2022-04-01'
          $role.name | Should -Be "[guid(subscription().id, 'DefenStack JIT Requester')]"
          $role.properties.roleName | Should -BeExactly 'DefenStack JIT Requester'
          $role.properties.type | Should -Be 'CustomRole'
          @($role.properties.assignableScopes) | Should -Be @('[subscription().id]')
          $role.properties.description | Should -Match 'ADR-028'
      }

      It 'grants only reading and initiating JIT requests plus the reads the request needs' {
          $role.properties.permissions[0].actions | Should -Be "[variables('roleActions')]"
          @($roleTemplate.variables.roleActions) -join ',' | Should -Be (@(
                  'Microsoft.Security/locations/jitNetworkAccessPolicies/read'
                  'Microsoft.Security/locations/jitNetworkAccessPolicies/initiate/action'
                  'Microsoft.Security/locations/jitNetworkAccessPolicies/*/read'
                  'Microsoft.Compute/virtualMachines/read'
                  'Microsoft.Network/networkInterfaces/read'
                  'Microsoft.Network/networkInterfaces/*/read'
                  'Microsoft.Network/publicIPAddresses/read'
              ) -join ',')
          @($role.properties.permissions[0].dataActions).Count | Should -Be 0
      }

      It 'never grants a write, a delete or a wildcard action outside a read' {
          foreach ($action in $roleTemplate.variables.roleActions) {
              $action | Should -Match '(/read|/initiate/action)$' -Because $action
              $action | Should -Not -Match '/write$|/delete$'
              ($action -replace '/\*/read$', '/read') | Should -Not -Match '\*' -Because $action
          }
      }

      It 'outputs the role definition ID for the assignments' {
          $roleTemplate.outputs.roleDefinitionId.value | Should -Be "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', guid(subscription().id, 'DefenStack JIT Requester'))]"
          $governance.outputs.jitRequesterRoleDefinitionId.value | Should -Be "[reference('jitRequesterRole').outputs.roleDefinitionId.value]"
          $roleModule.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
      }

      It 'takes one admin group per environment, empty by default (same groups as runbook 03)' {
          $governance.parameters.adminGroupObjectIds.'$ref' | Should -Be '#/definitions/environmentAdminGroups'
          $governance.parameters.adminGroupObjectIds.defaultValue.dev | Should -BeExactly ''
          $governance.parameters.adminGroupObjectIds.defaultValue.prod | Should -BeExactly ''
      }

      It 'marks the first region of each environment as its primary stamp' {
          $governance.variables.stamps | Should -Match ([regex]::Escape("lambda('location', 'index', createObject("))
          $governance.variables.stamps | Should -Match ([regex]::Escape("'isPrimary', equals(lambdaVariables('index'), 0)"))
      }

      It 'assigns the role only at primary stamps, where the jump host runs, and only for environments with a group' {
          $governance.variables.jumpHostStamps | Should -Be "[filter(variables('stamps'), lambda('stamp', and(lambdaVariables('stamp').isPrimary, not(empty(parameters('adminGroupObjectIds')[lambdaVariables('stamp').environmentName])))))]"
          $stampTemplate = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
          (Get-TemplateResourceBySymbol -Template $stampTemplate -Symbol 'virtualMachine').condition |
              Should -Be "[and(parameters('enableVirtualMachine'), variables('isPrimary'))]"
      }

      It 'assigns the role to the environment admin group in each jump host resource group' {
          $assignmentModule.copy.count | Should -Be "[length(variables('jumpHostStamps'))]"
          $assignmentModule.resourceGroup | Should -Be "[variables('jumpHostStamps')[copyIndex()].resourceGroupName]"
          $assignmentModule.name | Should -Be "[format('governance-jit-requester-{0}-{1}', variables('jumpHostStamps')[copyIndex()].environmentName, variables('jumpHostStamps')[copyIndex()].regionCode)]"
          $assignmentModule.properties.parameters.principalId.value | Should -Be "[parameters('adminGroupObjectIds')[variables('jumpHostStamps')[copyIndex()].environmentName]]"
          $assignmentModule.properties.parameters.roleDefinitionId.value | Should -Be "[reference('jitRequesterRole').outputs.roleDefinitionId.value]"
      }

      It 'gives each assignment a deterministic GUID name and assigns it to a group' {
          $assignment.apiVersion | Should -Be '2022-04-01'
          $assignment.name | Should -Be "[guid(resourceGroup().id, parameters('principalId'), parameters('roleDefinitionId'))]"
          $assignment.properties.principalType | Should -Be 'Group'
          $assignment.properties.principalId | Should -Be "[parameters('principalId')]"
          $assignment.properties.roleDefinitionId | Should -Be "[parameters('roleDefinitionId')]"
          $assignmentTemplate.parameters.principalId.minLength | Should -Be 36
      }
  }
  ```

  Replace `tests/Params.Tests.ps1`:

  ```powershell
  BeforeDiscovery {
      $repoRoot = Split-Path -Parent $PSScriptRoot
      $paramFiles = Get-ChildItem -Path (Join-Path $repoRoot 'params') -Filter '*.bicepparam' -ErrorAction SilentlyContinue |
          ForEach-Object { @{ Name = $_.Name; FullName = $_.FullName } }
  }

  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force

      function Get-BuiltParameters([string]$RelativePath) {
          [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
          $built = (& bicep build-params (Get-RepoPath $RelativePath) --stdout) -join "`n" | ConvertFrom-Json
          ($built.parametersJson | ConvertFrom-Json).parameters
      }

      # True when every prefix in $Prefixes shares the first two octets of $Space (all ranges here are /16 spaces).
      function Test-InsideSixteen([string]$Space, [string[]]$Prefixes) {
          $root = ($Space -split '\.')[0..1] -join '.'
          -not ($Prefixes | Where-Object { -not $_.StartsWith("$root.") })
      }

      $dev = Get-BuiltParameters 'params/dev.bicepparam'
      $prod = Get-BuiltParameters 'params/prod.bicepparam'
  }

  Describe 'Committed parameter files' {
      It 'includes dev and prod parameter files' {
          Get-RepoPath 'params/dev.bicepparam' | Should -Exist
          Get-RepoPath 'params/prod.bicepparam' | Should -Exist
      }

      It 'binds dev and prod to main.bicep and the governance file to governance.bicep (Phase 7)' {
          Get-Content (Get-RepoPath 'params/dev.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
          Get-Content (Get-RepoPath 'params/prod.bicepparam') -TotalCount 1 | Should -Be "using '../main.bicep'"
          Get-Content (Get-RepoPath 'params/governance.bicepparam') -TotalCount 1 | Should -Be "using '../governance.bicep'"
      }

      It '<Name> builds against its template' -ForEach $paramFiles {
          $output = & bicep build-params $FullName --stdout 2>&1
          $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
      }

      It '<Name> contains no az.getSecret references (secrets belong in *.local.bicepparam)' -ForEach $paramFiles {
          Get-Content $FullName -Raw | Should -Not -Match 'getSecret'
      }
  }

  Describe 'Environment topology' {
      It 'runs dev in the primary region only' {
          $dev.environmentName.value | Should -Be 'dev'
          $dev.deploySecondaryRegion.value | Should -BeExactly $false
      }

      It 'runs prod in both regions with a secondary address plan' {
          $prod.environmentName.value | Should -Be 'prod'
          $prod.deploySecondaryRegion.value | Should -BeExactly $true
          $prod.secondaryAddressPlan.value | Should -Not -BeNullOrEmpty
      }
  }

  Describe 'Address plan' {
      It 'uses the spec ranges for prod (WUS3 hub 10.1/16, spoke 10.0/16; EUS hub 10.11/16, spoke 10.10/16)' {
          $prod.primaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.1.0.0/16'
          $prod.primaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.0.0.0/16'
          $prod.secondaryAddressPlan.value.hubAddressSpace[0] | Should -Be '10.11.0.0/16'
          $prod.secondaryAddressPlan.value.spokeAddressSpace[0] | Should -Be '10.10.0.0/16'
      }

      It 'gives dev its own ranges so dev and prod never overlap' {
          $prodRanges = @($prod.primaryAddressPlan.value.hubAddressSpace + $prod.primaryAddressPlan.value.spokeAddressSpace +
              $prod.secondaryAddressPlan.value.hubAddressSpace + $prod.secondaryAddressPlan.value.spokeAddressSpace)
          foreach ($range in @($dev.primaryAddressPlan.value.hubAddressSpace + $dev.primaryAddressPlan.value.spokeAddressSpace)) {
              $prodRanges | Should -Not -Contain $range
          }
      }

      It 'keeps every subnet inside its VNet in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          Test-InsideSixteen $plan.hubAddressSpace[0] @($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Should -BeTrue
          Test-InsideSixteen $plan.spokeAddressSpace[0] @($plan.privateEndpointSubnetPrefix, $plan.appServiceIntegrationSubnetPrefix, $plan.managementSubnetPrefix) | Should -BeTrue
      }
  }

  Describe 'Admin access address plan (Phase 3)' {
      BeforeAll {
          $plans = @($dev.primaryAddressPlan.value, $prod.primaryAddressPlan.value, $prod.secondaryAddressPlan.value)
      }

      It 'sizes the hub subnets for Azure (Bastion /26, GatewaySubnet /27) in <_> plans' -ForEach 'dev-primary', 'prod-primary', 'prod-secondary' {
          $plan = switch ($_) {
              'dev-primary' { $dev.primaryAddressPlan.value }
              'prod-primary' { $prod.primaryAddressPlan.value }
              'prod-secondary' { $prod.secondaryAddressPlan.value }
          }
          $plan.bastionSubnetPrefix | Should -Match '/26$'
          $plan.gatewaySubnetPrefix | Should -Match '/27$'
          @(@($plan.firewallSubnetPrefix, $plan.bastionSubnetPrefix, $plan.gatewaySubnetPrefix) | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'uses the spec pool 172.16.200.0/24 for the prod primary region' {
          $prod.primaryAddressPlan.value.vpnClientAddressPool | Should -Be '172.16.200.0/24'
      }

      It 'gives every region and environment its own VPN client pool' {
          @($plans | ForEach-Object { $_.vpnClientAddressPool } | Select-Object -Unique) | Should -HaveCount 3
      }

      It 'keeps every VPN client pool outside every VNet (clients must never overlap Azure ranges)' {
          $vnetRoots = @($plans | ForEach-Object { @($_.hubAddressSpace) + @($_.spokeAddressSpace) } | ForEach-Object { ($_ -split '\.')[0..1] -join '.' })
          foreach ($plan in $plans) {
              $poolRoot = ($plan.vpnClientAddressPool -split '\.')[0..1] -join '.'
              $vnetRoots | Should -Not -Contain $poolRoot
          }
      }
  }

  Describe 'Front Door custom domain (Phase 4)' {
      It 'leaves the custom domain empty in <_> until the external DNS records exist (runbook 04)' -ForEach 'dev', 'prod' {
          $parameters = if ($_ -eq 'dev') { $dev } else { $prod }
          $parameters.customDomainHostName.value | Should -Be ''
      }
  }

  Describe 'Governance parameters (Phase 7)' {
      BeforeAll {
          $savedEmails = $env:SECURITY_CONTACT_EMAILS
          $governanceText = Get-Content (Get-RepoPath 'params/governance.bicepparam') -Raw
      }

      AfterAll {
          $env:SECURITY_CONTACT_EMAILS = $savedEmails
      }

      It 'commits no contact address; the operator sets SECURITY_CONTACT_EMAILS (runbook 07)' {
          $governanceText | Should -Not -Match '[A-Za-z0-9._-]+@[A-Za-z0-9-]+\.'
          $governanceText | Should -Match ([regex]::Escape("readEnvironmentVariable('SECURITY_CONTACT_EMAILS', '')"))
      }

      It 'turns an unset SECURITY_CONTACT_EMAILS into an empty list, which the template refuses (minLength 1)' {
          $env:SECURITY_CONTACT_EMAILS = $null
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          @($parameters.securityContactEmails.value).Count | Should -Be 0
      }

      It 'splits SECURITY_CONTACT_EMAILS on semicolons, trimming spaces and dropping empty entries' {
          $env:SECURITY_CONTACT_EMAILS = ' secops@example.com ; ;cloud-admins@example.com;'
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          @($parameters.securityContactEmails.value) | Should -Be @('secops@example.com', 'cloud-admins@example.com')
      }

      It 'keeps the default 5000 GB malware scanning cap' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          $parameters.malwareScanCapGbPerMonth.value | Should -Be 5000
      }

      It 'starts audit-first for dev and prod (ADR-027)' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          $parameters.denyEnforcement.value | Should -Be 'DoNotEnforce'
          @($parameters.environments.value) -join ',' | Should -Be 'dev,prod'
      }

      It 'gives the legacy waiver a real yyyy-MM-dd expiry' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          $parameters.legacyResourceGroupName.value | Should -Be 'defenStack'
          $expires = $parameters.legacyWaiverExpiresOn.value
          $expires | Should -Match '^\d{4}-\d{2}-\d{2}$'
          { [datetime]::ParseExact($expires, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) } | Should -Not -Throw
      }

      It 'grants JIT requests to the same admin group each environment file signs in with (runbook 03)' {
          $parameters = Get-BuiltParameters 'params/governance.bicepparam'
          foreach ($pair in @(@{ Name = 'dev'; File = $dev }, @{ Name = 'prod'; File = $prod })) {
              $expected = if ($pair.File.PSObject.Properties.Name -contains 'adminGroupObjectId') { $pair.File.adminGroupObjectId.value } else { '' }
              $parameters.adminGroupObjectIds.value.($pair.Name) | Should -BeExactly $expected -Because $pair.Name
          }
      }

      It 'mirrors the environment parameter files in the governance region layout' {
          $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
          $main = Get-BicepTemplate -RelativePath 'main.bicep'
          $layout = $governance.parameters.environmentRegions.defaultValue
          # Dev runs the primary only; prod adds the secondary. Neither file overrides the region defaults.
          $dev.deploySecondaryRegion.value | Should -BeExactly $false
          $prod.deploySecondaryRegion.value | Should -BeExactly $true
          foreach ($parameters in $dev, $prod) {
              $parameters.PSObject.Properties.Name | Should -Not -Contain 'primaryLocation'
              $parameters.PSObject.Properties.Name | Should -Not -Contain 'secondaryLocation'
          }
          @($layout.dev) -join ',' | Should -Be $main.parameters.primaryLocation.defaultValue
          @($layout.prod) -join ',' | Should -Be "$($main.parameters.primaryLocation.defaultValue),$($main.parameters.secondaryLocation.defaultValue)"
      }
  }
  ```

  Replace `tests/VirtualMachine.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/virtualMachine.bicep'
  }

  Describe 'VM NIC NSG management access (F1)' {
      It 'exposes managementSourceCidrs defaulting to an empty list' {
          $template.parameters.PSObject.Properties.Name | Should -Contain 'managementSourceCidrs'
          @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
      }
  }

  Describe 'Jump host just-in-time access (Phase 7, ADR-028)' {
      BeforeAll {
          $nsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' | Select-Object -First 1
          $nic = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkInterfaces' | Select-Object -First 1
          $jit = @(Get-TemplateResource -Template $template -Type 'Microsoft.Security/locations/jitNetworkAccessPolicies')
          $inboundRules = @($nsg.properties.securityRules | Where-Object { $_ -isnot [string] -and $_.properties.direction -eq 'Inbound' })
          $denyRule = $template.variables.denyManagementInboundRule
      }

      It 'has no static allow rule on the NIC: SSH and RDP open only through a JIT grant' {
          ($nsg.properties.securityRules | ConvertTo-Json -Depth 10) | Should -Not -Match "'Allow'|""Allow"""
          ($nsg.properties.securityRules | ConvertTo-Json -Depth 10) | Should -Not -Match 'allow-management-ssh-rdp'
          $template.variables.PSObject.Properties.Name | Should -Not -Contain 'managementInboundRules'
      }

      It 'denies inbound SSH and RDP from any source at priority 4000, leaving 100-3999 free for JIT allow rules' {
          @($nsg.properties.securityRules)[0] | Should -Be "[variables('denyManagementInboundRule')]"
          $denyRule.name | Should -Be 'deny-ssh-rdp-inbound'
          $denyRule.properties.priority | Should -Be 4000
          $denyRule.properties.access | Should -Be 'Deny'
          $denyRule.properties.direction | Should -Be 'Inbound'
          $denyRule.properties.sourceAddressPrefix | Should -Be '*'
          @($denyRule.properties.destinationPortRanges) -join ',' | Should -Be '22,3389'
      }

      It 'keeps the catch-all inbound deny below the SSH/RDP deny' {
          $inboundRules.Count | Should -Be 1
          $inboundRules[0].name | Should -Be 'deny-unsolicited-inbound'
          $inboundRules[0].properties.priority | Should -Be 4096
      }

      It 'attaches the NSG to the NIC, the NSG closest to the VM, which JIT programs' {
          $nic.properties.networkSecurityGroup.id | Should -Be "[resourceId('Microsoft.Network/networkSecurityGroups', variables('networkSecurityGroupName'))]"
      }

      It 'creates one JIT policy, named default in the VM region, with the GA API and kind Basic' {
          $jit.Count | Should -Be 1
          $jit[0].apiVersion | Should -Be '2020-01-01'
          $jit[0].name | Should -Be "[format('{0}/default', parameters('location'))]"
          $jit[0].kind | Should -Be 'Basic'
      }

      It 'skips the JIT policy when no admin source is given, so the ports stay closed' {
          $jit[0].condition | Should -Be "[not(empty(parameters('managementSourceCidrs')))]"
      }

      It 'covers this VM on TCP 22 and 3389, from the admin sources only, for at most three hours' {
          $vmEntry = @($jit[0].properties.virtualMachines)
          $vmEntry.Count | Should -Be 1
          $vmEntry[0].id | Should -Be "[resourceId('Microsoft.Compute/virtualMachines', parameters('vmName'))]"
          @($template.variables.jitPorts) -join ',' | Should -Be '22,3389'
          $ports = $vmEntry[0].copy[0]
          $ports.name | Should -Be 'ports'
          $ports.count | Should -Be "[length(variables('jitPorts'))]"
          $ports.input.number | Should -Be "[variables('jitPorts')[copyIndex('ports')]]"
          $ports.input.protocol | Should -Be 'TCP'
          $ports.input.allowedSourceAddressPrefixes | Should -Be "[parameters('managementSourceCidrs')]"
          $ports.input.maxRequestAccessDuration | Should -Be 'PT3H'
      }
  }

  Describe 'VM monitoring (F3)' {
      BeforeAll {
          $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
          $dcr = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRules' | Select-Object -First 1
          $association = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRuleAssociations' | Select-Object -First 1
          $agent = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines/extensions' | Select-Object -First 1
      }

      It 'sends only metrics through the VM diagnostic setting (VMs expose no log categories)' {
          $diagnostics.properties.PSObject.Properties.Name | Should -Not -Contain 'logs'
          $diagnostics.properties.metrics[0].category | Should -Be 'AllMetrics'
      }

      It 'installs the Azure Monitor Agent' {
          $agent.properties.publisher | Should -Be 'Microsoft.Azure.Monitor'
          $agent.properties.enableAutomaticUpgrade | Should -BeTrue
      }

      It 'sends guest logs and performance counters to the workspace through a DCR' {
          $dcr.properties.destinations.logAnalytics[0].workspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
      }

      It 'associates the DCR with the VM' {
          $association.scope | Should -Match 'virtualMachines'
      }

      It 'outputs the DCR ID' {
          $template.outputs.PSObject.Properties.Name | Should -Contain 'dataCollectionRuleId'
      }

      It 'uses Azure Monitor counter paths with a leading backslash' {
          # dataSources compiles to the expression '[union(variables(...), variables(...))]' rather than
          # an inline object, so the literal counter text lives in the performanceCounterSource variable.
          $dcrText = $template.variables.performanceCounterSource | ConvertTo-Json -Depth 10
          $dcrText | Should -Match ([regex]::Escape('\\Processor(*)\\% Processor Time'))
      }
  }

  Describe 'VM data collection endpoint in the AMPLS (final review I-2)' {
      BeforeAll {
          $endpoints = @(Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionEndpoints')
          $associations = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRuleAssociations'
          $ruleAssociation = $associations | Where-Object { $_.name -eq "[format('{0}-dcra', parameters('vmName'))]" }
          $configurationAssociation = $associations | Where-Object { $_.name -eq 'configurationAccessEndpoint' }
      }

      It 'creates one regional data collection endpoint, named after the VM, with public network access disabled' {
          $endpoints.Count | Should -Be 1
          $endpoints[0].apiVersion | Should -Be '2023-03-11'
          $endpoints[0].name | Should -Be "[format('{0}-dce', parameters('vmName'))]"
          $endpoints[0].location | Should -Be "[parameters('location')]"
          $endpoints[0].properties.networkAcls.publicNetworkAccess | Should -Be 'Disabled'
      }

      It 'associates the endpoint with the VM as its configurationAccessEndpoint' {
          @($configurationAssociation).Count | Should -Be 1
          $configurationAssociation.apiVersion | Should -Be '2023-03-11'
          $configurationAssociation.scope | Should -Be "[resourceId('Microsoft.Compute/virtualMachines', parameters('vmName'))]"
          $configurationAssociation.properties.dataCollectionEndpointId | Should -Be "[resourceId('Microsoft.Insights/dataCollectionEndpoints', format('{0}-dce', parameters('vmName')))]"
          $configurationAssociation.properties.PSObject.Properties.Name | Should -Not -Contain 'dataCollectionRuleId'
      }

      It 'keeps the existing DCR association unchanged' {
          $associations.Count | Should -Be 2
          @($ruleAssociation).Count | Should -Be 1
          $ruleAssociation.properties.dataCollectionRuleId | Should -Be "[resourceId('Microsoft.Insights/dataCollectionRules', variables('dataCollectionRuleName'))]"
          $ruleAssociation.properties.PSObject.Properties.Name | Should -Not -Contain 'dataCollectionEndpointId'
      }

      It 'outputs the data collection endpoint ID' {
          $template.outputs.dataCollectionEndpointId.value | Should -Be "[resourceId('Microsoft.Insights/dataCollectionEndpoints', format('{0}-dce', parameters('vmName')))]"
      }
  }

  Describe 'VM monitoring on Windows (F3)' {
      It 'installs the Windows agent and collects System and Application events when osType is Windows' {
          $template.variables.azureMonitorAgentName | Should -Match "'AzureMonitorWindowsAgent'"
          $template.variables.osLogSource | Should -Match 'windowsEventLogs'
          $template.variables.osLogSource | Should -Match 'Microsoft-Event'
          $template.variables.osLogSource | Should -Match 'Application!'
      }
  }

  Describe 'Jump host access (Phase 3)' {
      BeforeAll {
          $vm = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines' | Select-Object -First 1
          $extensions = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines/extensions'
          $entraLogin = $extensions | Where-Object { $_.properties.publisher -eq 'Microsoft.Azure.ActiveDirectory' }
          $roleAssignment = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
          $nsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' | Select-Object -First 1
      }

      It 'pins the VM to one availability zone, zone 1 by default' {
          @($vm.zones) | Should -Be @("[parameters('availabilityZone')]")
          $template.parameters.availabilityZone.defaultValue | Should -Be '1'
      }

      It 'installs the Entra ID login extension that matches the OS' {
          $template.variables.entraLoginExtensionName | Should -Be "[if(equals(parameters('osType'), 'Linux'), 'AADSSHLoginForLinux', 'AADLoginForWindows')]"
          $entraLogin.properties.type | Should -Be "[variables('entraLoginExtensionName')]"
      }

      It 'installs the Entra extension after the Azure Monitor Agent (one extension operation at a time)' {
          ($entraLogin.dependsOn -join ' ') | Should -Match 'azureMonitorAgentName'
      }

      It 'grants the admin group Virtual Machine Administrator Login on this VM only, when a group is given' {
          $roleAssignment.condition | Should -Be "[not(empty(parameters('adminGroupObjectId')))]"
          $roleAssignment.scope | Should -Match 'virtualMachines'
          $roleAssignment.properties.principalType | Should -Be 'Group'
          $template.variables.virtualMachineAdministratorLoginRoleId | Should -Be '1c0163c0-47e6-4577-8991-ea5c82e286e4'
          $template.parameters.adminGroupObjectId.defaultValue | Should -Be ''
      }

      It 'hands patching to Update Manager on both operating systems' {
          $template.variables.patchSettings.patchMode | Should -Be 'AutomaticByPlatform'
          $template.variables.patchSettings.assessmentMode | Should -Be 'AutomaticByPlatform'
          $template.variables.patchSettings.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule | Should -BeExactly $true
          # osProfile compiles to one if() expression; both the Linux and Windows branches carry the settings.
          ([regex]::Matches($vm.properties.osProfile, [regex]::Escape("'patchSettings', variables('patchSettings')"))).Count | Should -Be 2
      }

      It 'installs critical and security updates in a weekly window and assigns it to the VM' {
          $schedule = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/maintenanceConfigurations' | Select-Object -First 1
          $assignment = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/configurationAssignments' | Select-Object -First 1
          $schedule.properties.maintenanceScope | Should -Be 'InGuestPatch'
          $schedule.properties.maintenanceWindow.recurEvery | Should -Be 'Week Sunday'
          @($schedule.properties.installPatches.linuxParameters.classificationsToInclude) -join ',' | Should -Be 'Critical,Security'
          @($schedule.properties.installPatches.windowsParameters.classificationsToInclude) -join ',' | Should -Be 'Critical,Security'
          $assignment.scope | Should -Match 'virtualMachines'
      }

      It 'denies outbound SSH and RDP from the NIC (PSRule Azure.NSG.LateralTraversal)' {
          ($nsg.properties.securityRules | ConvertTo-Json -Depth 10) | Should -Match 'deny-ssh-rdp-outbound'
      }
  }
  ```

  Replace `tests/SpokeNetwork.Tests.ps1`:

  ```powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
      $template = Get-BicepTemplate -RelativePath 'modules/spokeNetwork.bicep'
      $routeTables = Get-TemplateResource -Template $template -Type 'Microsoft.Network/routeTables'
      $vnetModule = Get-TemplateResource -Template $template -Type 'Microsoft.Resources/deployments' | Select-Object -First 1
      # Subnet order in spokeNetwork.bicep: 0 private-endpoints, 1 appservice-integration, 2 management.
      $subnets = @($vnetModule.properties.parameters.subnets.value)
  }

  Describe 'Spoke routing (F2)' {
      It 'has one route table for App Service and one for the management subnet' {
          $routeTables.Count | Should -Be 2
      }

      It 'disables BGP route propagation on every spoke route table so gateway routes cannot bypass the firewall' {
          foreach ($routeTable in $routeTables) {
              $routeTable.properties.disableBgpRoutePropagation | Should -BeTrue
          }
      }
  }

  Describe 'Management subnet isolation (F1)' {
      It 'uses its own NSG, not the App Service integration NSG' {
          $subnets[2].nsgId | Should -Not -Be $subnets[1].nsgId
      }

      It 'uses its own route table, not the App Service route table' {
          $subnets[2].udrId | Should -Not -Be $subnets[1].udrId
      }

      It 'defaults to no management source CIDRs (deny all admin inbound)' {
          @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
      }

      It 'keeps the subnet allow for the admin sources only, so a JIT grant on the NIC NSG can pass it (ADR-028)' {
          $template.variables.managementInboundRules | Should -Match ([regex]::Escape("if(empty(parameters('managementSourceCidrs')), createArray(), createArray(createObject('name', 'allow-management-ssh-rdp'"))
          $template.variables.managementInboundRules | Should -Match ([regex]::Escape("'priority', 100, 'access', 'Allow'"))
          $template.variables.managementInboundRules | Should -Match ([regex]::Escape("'sourceAddressPrefixes', parameters('managementSourceCidrs')"))
          $template.variables.managementInboundRules | Should -Match ([regex]::Escape("'destinationAddressPrefix', parameters('virtualMachineSubnetAddressPrefix')"))
      }
  }

  Describe 'Subnet default outbound access (PSRule Azure.VNET.PrivateSubnet)' {
      It 'disables default outbound internet access on the private endpoint and management subnets' {
          $subnets[0].defaultOutboundAccess | Should -Be $false
          $subnets[2].defaultOutboundAccess | Should -Be $false
      }

      It 'leaves the delegated App Service integration subnet unset (delegation manages its own egress)' {
          $subnets[1].PSObject.Properties.Name | Should -Not -Contain 'defaultOutboundAccess'
      }
  }

  Describe 'Management subnet naming (Phase 1)' {
      It 'names the third subnet management' {
          $template.parameters.virtualMachineSubnetName.defaultValue | Should -Be 'management'
      }
  }

  Describe 'Lateral traversal (PSRule Azure.NSG.LateralTraversal, Phase 3)' {
      It 'denies outbound SSH and RDP from every spoke subnet' {
          $template.variables.denyLateralTraversalRule.properties.access | Should -Be 'Deny'
          $template.variables.denyLateralTraversalRule.properties.direction | Should -Be 'Outbound'
          @($template.variables.denyLateralTraversalRule.properties.destinationPortRanges) -join ',' | Should -Be '22,3389'
          $nsgs = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups'
          $nsgs.Count | Should -Be 3
          foreach ($nsg in $nsgs) {
              # Plain NSGs list the variable as an array element; the management NSG compiles to one concat() expression.
              (@($nsg.properties.securityRules) -join ' ').Contains("variables('denyLateralTraversalRule')") | Should -BeTrue
          }
      }
  }

  Describe 'Azure Monitor endpoint isolation (Phase 6 final review I-1)' {
      BeforeAll {
          $asgs = @(Get-TemplateResource -Template $template -Type 'Microsoft.Network/applicationSecurityGroups')
          $privateEndpointNsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' |
              Where-Object { $_.name -eq "[variables('privateEndpointNsgName')]" }
      }

      It 'always creates one application security group for the AMPLS endpoint, named after the spoke VNet' {
          $asgs.Count | Should -Be 1
          $asgs[0].apiVersion | Should -Be '2024-07-01'
          $template.variables.amplsAsgName | Should -Be "[format('{0}-ampls-asg', parameters('vnetName'))]"
          $asgs[0].name | Should -Be "[variables('amplsAsgName')]"
          $asgs[0].location | Should -Be "[parameters('location')]"
          $asgs[0].PSObject.Properties.Name | Should -Not -Contain 'condition'
      }

      It 'outputs the application security group ID as amplsAsgId' {
          $template.outputs.amplsAsgId.value | Should -Be "[resourceId('Microsoft.Network/applicationSecurityGroups', variables('amplsAsgName'))]"
      }

      It 'takes the peer monitoring sources as a parameter, empty by default (no rule)' {
          @($template.parameters.monitorPeerSourceCidrs.defaultValue).Count | Should -Be 0
          $template.variables.peerMonitoringInboundRules | Should -Be "[if(empty(parameters('monitorPeerSourceCidrs')), createArray(), createArray(variables('peerMonitoringRule')))]"
      }

      It 'lets the peer sources reach only the AMPLS application security group, on TCP 443' {
          $rule = $template.variables.peerMonitoringRule
          $rule.name | Should -Be 'allow-peer-monitoring-https'
          $rule.properties.priority | Should -Be 110
          $rule.properties.direction | Should -Be 'Inbound'
          $rule.properties.access | Should -Be 'Allow'
          $rule.properties.protocol | Should -Be 'Tcp'
          $rule.properties.sourceAddressPrefixes | Should -Be "[parameters('monitorPeerSourceCidrs')]"
          $rule.properties.destinationPortRange | Should -Be '443'
          @($rule.properties.destinationApplicationSecurityGroups).Count | Should -Be 1
          $rule.properties.destinationApplicationSecurityGroups[0].id | Should -Be "[resourceId('Microsoft.Network/applicationSecurityGroups', variables('amplsAsgName'))]"
          $rule.properties.PSObject.Properties.Name | Should -Not -Contain 'destinationAddressPrefix'
      }

      It 'adds the peer rule to the private-endpoint NSG and keeps the approved-https rule on its own sources' {
          $rules = [string]$privateEndpointNsg.properties.securityRules
          $rules | Should -Match "variables\('peerMonitoringInboundRules'\)"
          $rules | Should -Match "'allow-approved-https'"
          $rules | Should -Match "'sourceAddressPrefixes', parameters\('approvedPrivateEndpointSourceCidrs'\)"
      }

      It 'enables NSG private endpoint network policies on the private-endpoint subnet, which application security groups on private endpoints need' {
          $subnets[0].privateEndpointNetworkPolicies | Should -Be 'NetworkSecurityGroupEnabled'
      }
  }
  ```

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected failures: the `JIT requester role (Phase 7, ADR-028)` tests (the role modules and `adminGroupObjectIds` do not exist), the admin group parity test in `Params.Tests.ps1`, and the `Jump host just-in-time access (Phase 7, ADR-028)` tests (the NIC still allows SSH/RDP at 100 and has no JIT policy). The subnet NSG test passes already: it pins what must not change.

- [ ] **Step 3: Create the JIT requester role and its assignment**

  Create `modules/governance/jitRequesterRole.bicep`:

  ```bicep
  // The DefenStack JIT Requester custom role (Phase 7, ADR-028): just enough to see the jump host's just-in-time policy
  // and request access through it. It grants no sign-in; Virtual Machine Administrator Login still does that (runbook 03).
  targetScope = 'subscription'

  // Least-privilege actions for requesting JIT access, as Microsoft documents them; runbook 07 lists them as a live check.
  var roleActions = [
    'Microsoft.Security/locations/jitNetworkAccessPolicies/read'
    'Microsoft.Security/locations/jitNetworkAccessPolicies/initiate/action'
    'Microsoft.Security/locations/jitNetworkAccessPolicies/*/read'
    'Microsoft.Compute/virtualMachines/read'
    'Microsoft.Network/networkInterfaces/read'
    'Microsoft.Network/networkInterfaces/*/read'
    'Microsoft.Network/publicIPAddresses/read'
  ]

  // The name is a GUID derived from the subscription, so every redeploy updates the same definition.
  resource jitRequester 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
    name: guid(subscription().id, 'DefenStack JIT Requester')
    properties: {
      roleName: 'DefenStack JIT Requester'
      description: 'Request just-in-time SSH/RDP access to DefenStack jump hosts (ADR-028, runbook 07). Assigned to each environment admin group at its primary regional resource group.'
      type: 'CustomRole'
      permissions: [
        {
          actions: roleActions
          notActions: []
          dataActions: []
          notDataActions: []
        }
      ]
      assignableScopes: [
        subscription().id
      ]
    }
  }

  output roleDefinitionId string = jitRequester.id
  ```

  Create `modules/governance/jitRequesterAssignment.bicep`:

  ```bicep
  // Assigns the DefenStack JIT Requester role to one environment's admin group at a regional resource group that
  // hosts a jump host (Phase 7, ADR-028). The resource group must already exist. PIM makes the group membership
  // just-in-time, as for Virtual Machine Administrator Login (runbook 03).

  @description('Object ID of the environment\'s Entra ID admin group.')
  @minLength(36)
  @maxLength(36)
  param principalId string

  @description('Resource ID of the DefenStack JIT Requester role definition.')
  param roleDefinitionId string

  // Deterministic name: the same resource group, group and role always give the same assignment.
  resource jitRequester 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
    name: guid(resourceGroup().id, principalId, roleDefinitionId)
    properties: {
      principalId: principalId
      principalType: 'Group'
      roleDefinitionId: roleDefinitionId
      description: 'Request just-in-time access to the jump host (ADR-028, runbook 07).'
    }
  }

  output roleAssignmentId string = jitRequester.id
  ```

  Replace `modules/types.bicep`:

  ```bicep
  // Shared parameter contracts between the subscription entry point, the global layer, and region stamps.

  @export()
  @description('Address plan for one region: hub VNet with the firewall, Bastion and gateway subnets, spoke VNet with its three subnets, and the P2S VPN client pool.')
  type regionAddressPlan = {
    @description('Hub VNet address space.')
    hubAddressSpace: string[]

    @description('AzureFirewallSubnet prefix (at least /26) inside hubAddressSpace.')
    firewallSubnetPrefix: string

    @description('AzureBastionSubnet prefix (at least /26) inside hubAddressSpace.')
    bastionSubnetPrefix: string

    @description('GatewaySubnet prefix (at least /27) inside hubAddressSpace.')
    gatewaySubnetPrefix: string

    @description('Point-to-site VPN client address pool. Must not overlap any VNet in any region or environment.')
    vpnClientAddressPool: string

    @description('Spoke VNet address space. Also the firewall source range for spoke egress rules.')
    spokeAddressSpace: string[]

    @description('private-endpoints subnet prefix inside spokeAddressSpace.')
    privateEndpointSubnetPrefix: string

    @description('appservice-integration subnet prefix inside spokeAddressSpace.')
    appServiceIntegrationSubnetPrefix: string

    @description('management subnet prefix inside spokeAddressSpace.')
    managementSubnetPrefix: string
  }

  @export()
  @description('Private DNS zone names (or resource IDs) keyed by private endpoint group: the application zones plus the Azure Monitor Private Link Scope zones (Phase 6).')
  type privateDnsZoneSet = {
    @description('Blob storage zone.')
    blob: string

    @description('App Service (sites) zone.')
    sites: string

    @description('Key Vault zone.')
    vault: string

    @description('Azure Monitor global endpoints zone (AMPLS).')
    monitor: string

    @description('Log Analytics workspace agent endpoints zone (AMPLS).')
    oms: string

    @description('Log Analytics workspace ingestion (ODS) endpoints zone (AMPLS).')
    ods: string

    @description('Log Analytics agent service endpoints zone (AMPLS).')
    agentsvc: string
  }

  @export()
  @description('A virtual network to link to a private DNS zone.')
  type virtualNetworkReference = {
    @description('VNet name; used to build a unique link name.')
    name: string

    @description('VNet resource ID.')
    id: string
  }

  @export()
  @description('Prod with DR only: how this region\'s firewall carries traffic to and from the other region over the hub-to-hub global peering (Phase 6).')
  type hubPeeringPlan = {
    @description('Private IP of the other region\'s firewall, the next hop for the other region\'s spoke.')
    remoteFirewallPrivateIp: string

    @description('Spoke address prefixes of the other region, routed from this AzureFirewallSubnet to the other firewall.')
    remoteSpokeAddressPrefixes: string[]

    @description('This region\'s part in Azure Monitor traffic: Host owns the AMPLS private endpoint, Client forwards its spoke to it.')
    monitorRole: 'Host' | 'Client'

    @description('Spoke subnets of the Client region allowed to reach the AMPLS private endpoint on TCP 443.')
    monitorClientPrefixes: string[]

    @description('Private-endpoint subnet prefixes in the Host region that hold the AMPLS endpoint. Used by the Client rule.')
    monitorPrivateEndpointPrefixes: string[]
  }

  @export()
  @description('A dimension filter on a metric alert, for example StatusCode = 403.')
  type metricAlertDimension = {
    @description('Dimension name, for example StatusCode or Action.')
    name: string

    @description('Include matches only the values; Exclude matches everything else.')
    operator: 'Include' | 'Exclude'

    @description('Dimension values.')
    values: string[]
  }

  @export()
  @description('One static-threshold metric alert on a single resource (Phase 6).')
  type metricAlertRule = {
    @description('Short rule name, appended to the alert name prefix, for example firewall-health.')
    name: string

    @description('What the alert means. Shown in the alert email; runbook 06 has the triage steps.')
    description: string

    @description('Alert severity: 0 Critical, 1 Error, 2 Warning, 3 Informational, 4 Verbose.')
    severity: 0 | 1 | 2 | 3 | 4

    @description('Resource ID the metric is read from.')
    resourceId: string

    @description('Metric namespace, the resource type, for example Microsoft.Network/azureFirewalls.')
    metricNamespace: string

    @description('Exact metric name, for example FirewallHealth.')
    metricName: string

    @description('Comparison against the threshold.')
    operator: 'GreaterThan' | 'GreaterThanOrEqual' | 'LessThan' | 'LessThanOrEqual'

    @description('Threshold as text, for example \'90\' or \'99.9\'. Bicep has no decimal literals; the module converts it with json().')
    threshold: string

    @description('How the metric is aggregated over the window.')
    timeAggregation: 'Average' | 'Minimum' | 'Maximum' | 'Total' | 'Count'

    @description('Dimension filters. Omit for none.')
    dimensions: metricAlertDimension[]?

    @description('False skips the rule, for example the VPN alert in a region without a gateway. Defaults to true.')
    deploy: bool?
  }

  @export()
  @description('Thresholds for the count-based platform alerts (Phase 6). Health and percentage alerts use fixed thresholds.')
  type alertThresholdSet = {
    @description('App Service HTTP 5xx responses per region in a 15-minute window.')
    @minValue(1)
    appServiceHttp5xx: int

    @description('Key Vault requests refused with 403 per region in a 15-minute window.')
    @minValue(1)
    keyVaultForbidden: int

    @description('Point-to-site VPN connections on the gateway at any time in a 15-minute window.')
    @minValue(1)
    vpnP2sConnections: int

    @description('Front Door WAF blocked requests in a 15-minute window.')
    @minValue(1)
    frontDoorWafBlocks: int
  }

  @export()
  @description('Regions each environment runs in, as main.bicep lays out its stamps: the primary first, then the warm standby (Phase 7 governance).')
  type environmentRegionLayout = {
    @description('Dev regions. Dev runs primary-only (ADR-008).')
    dev: ('westus3' | 'eastus')[]

    @description('Prod regions: the primary, then the warm standby.')
    prod: ('westus3' | 'eastus')[]
  }
  @export()
  @description('Object ID of each environment\'s Entra ID admin group, the group runbook 03 creates (Phase 7 governance). Empty skips that environment.')
  type environmentAdminGroups = {
    @description('Dev admin group object ID, the adminGroupObjectId of params/dev.bicepparam.')
    dev: string

    @description('Prod admin group object ID, the adminGroupObjectId of params/prod.bicepparam.')
    prod: string
  }
  ```

  Replace `governance.bicep`:

  ```bicep
  // Subscription governance and posture (Phase 7): Microsoft Defender for Cloud plans, the security contact and Azure
  // Policy with its exemptions. An operator deploys it with az deployment sub create (runbook 07). main.bicep and the
  // pipeline never do, so the pipeline identity needs no rights over Defender for Cloud or Azure Policy (ADR-026).
  targetScope = 'subscription'

  import { environmentAdminGroups, environmentRegionLayout } from 'modules/types.bicep'

  @description('Addresses that receive Defender for Cloud alert emails. The parameter file reads them from the SECURITY_CONTACT_EMAILS environment variable.')
  @minLength(1)
  param securityContactEmails string[]

  @description('Monthly cap, in GB per storage account, on Defender for Storage on-upload malware scanning. -1 removes the cap.')
  @minValue(-1)
  param malwareScanCapGbPerMonth int = 5000

  @description('Enforcement of every deny assignment. DoNotEnforce (audit-first) reports compliance without blocking; switch to Default once compliance is clean (ADR-027, runbook 07).')
  @allowed([
    'DoNotEnforce'
    'Default'
  ])
  param denyEnforcement string = 'DoNotEnforce'

  @description('Environments deployed in this subscription. Their public IPs are allowed and their flow-log accounts exempted; every listed stamp must already exist (runbook 07).')
  @minLength(1)
  param environments ('dev' | 'prod')[] = [
    'dev'
    'prod'
  ]

  @description('Regions each environment runs in, mirroring the dev and prod parameter files: dev primary-only, prod with the East US warm standby.')
  param environmentRegions environmentRegionLayout = {
    dev: [
      'westus3'
    ]
    prod: [
      'westus3'
      'eastus'
    ]
  }

  @description('The Entra ID admin group of each environment (runbook 03), granted the DefenStack JIT Requester role at its primary regional resource group, where the jump host runs. Empty skips that environment.')
  param adminGroupObjectIds environmentAdminGroups = {
    dev: ''
    prod: ''
  }

  @description('Legacy resource group that gets a dated waiver from the deny assignments until runbook 01a tears it down. Empty skips the waiver.')
  param legacyResourceGroupName string = 'defenStack'

  @description('Date the legacy waiver expires, as yyyy-MM-dd (end of that day, UTC).')
  @minLength(10)
  @maxLength(10)
  param legacyWaiverExpiresOn string

  // The same region codes as main.bicep; a test pins the parity.
  var regionCodes = {
    westus3: 'wus3'
    eastus: 'eus'
  }
  var platformLocations = [
    'westus3'
    'eastus'
  ]

  // Every region stamp in this subscription, named as main.bicep names them. The first region is the primary.
  var stamps = flatten(map(environments, environmentName => map(environmentRegions[environmentName], (location, index) => {
    environmentName: environmentName
    location: location
    isPrimary: index == 0
    regionCode: regionCodes[location]
    resourceGroupName: 'rg-defenstack-${environmentName}-${regionCodes[location]}'
  })))

  // Every public IP a region stamp may create, named as regionStamp.bicep names them; vpnGateway.bicep appends -1
  // and -2 for the active-active gateway. Includes the admin-access IPs a warm standby creates only during failover.
  func publicIpNames(environmentName string, regionCode string) string[] => [
    'pip-afw-defenstack-${environmentName}-${regionCode}'
    'pip-bas-defenstack-${environmentName}-${regionCode}'
    'pip-vpng-defenstack-${environmentName}-${regionCode}-1'
    'pip-vpng-defenstack-${environmentName}-${regionCode}-2'
  ]

  // The jump host runs in the primary stamp only (regionStamp.bicep), so the JIT Requester role is assigned there.
  var jumpHostStamps = filter(stamps, stamp => stamp.isPrimary && !empty(adminGroupObjectIds[stamp.environmentName]))

  var allowedPublicIpNames = flatten(map(stamps, stamp => publicIpNames(stamp.environmentName, stamp.regionCode)))

  // The resource types whose modules send both logs and metrics to the workspace. Storage logs live on the blob
  // service; public IPs, VNets and the jump host send no logs, so they are not audited.
  var diagnosticResourceTypes = [
    'Microsoft.Network/azureFirewalls'
    'Microsoft.Network/bastionHosts'
    'Microsoft.Network/virtualNetworkGateways'
    'Microsoft.Cdn/profiles'
    'Microsoft.KeyVault/vaults'
    'Microsoft.Web/sites'
    'Microsoft.Storage/storageAccounts/blobServices'
  ]

  module defenderPlans 'modules/governance/defenderPlans.bicep' = {
    name: 'governance-defender-plans'
    params: {
      malwareScanCapGbPerMonth: malwareScanCapGbPerMonth
    }
  }

  module securityContacts 'modules/governance/securityContacts.bicep' = {
    name: 'governance-security-contacts'
    params: {
      emails: securityContactEmails
    }
  }

  module policies 'modules/governance/policies.bicep' = {
    name: 'governance-policies'
    params: {
      denyEnforcement: denyEnforcement
      allowedLocations: concat(platformLocations, [
        'global'
      ])
      allowedResourceGroupLocations: platformLocations
      allowedPublicIpNames: allowedPublicIpNames
      diagnosticResourceTypes: diagnosticResourceTypes
    }
  }

  // Each flow-log account keeps public network access behind a deny-all firewall (ADR-023), so it is exempted.
  module flowLogExemptions 'modules/governance/flowLogStorageExemption.bicep' = [for stamp in stamps: {
    name: 'governance-flow-log-exemption-${stamp.environmentName}-${stamp.regionCode}'
    scope: resourceGroup(stamp.resourceGroupName)
    params: {
      environmentName: stamp.environmentName
      location: stamp.location
      regionCode: stamp.regionCode
      policyAssignmentId: policies.outputs.storagePublicNetworkAssignmentId
    }
  }]

  module legacyWaiver 'modules/governance/legacyWaiver.bicep' = if (!empty(legacyResourceGroupName)) {
    name: 'governance-legacy-waiver'
    scope: resourceGroup(legacyResourceGroupName)
    params: {
      policyAssignmentIds: policies.outputs.denyAssignmentIds
      expiresOn: legacyWaiverExpiresOn
    }
  }

  module jitRequesterRole 'modules/governance/jitRequesterRole.bicep' = {
    name: 'governance-jit-requester-role'
  }

  // Requesting JIT access is separate from signing in: the admin group also holds Virtual Machine Administrator Login.
  module jitRequesterAssignments 'modules/governance/jitRequesterAssignment.bicep' = [for stamp in jumpHostStamps: {
    name: 'governance-jit-requester-${stamp.environmentName}-${stamp.regionCode}'
    scope: resourceGroup(stamp.resourceGroupName)
    params: {
      principalId: adminGroupObjectIds[stamp.environmentName]
      roleDefinitionId: jitRequesterRole.outputs.roleDefinitionId
    }
  }]

  output defenderPlanNames string[] = defenderPlans.outputs.planNames
  output allowedPublicIpNames string[] = allowedPublicIpNames
  output jitRequesterRoleDefinitionId string = jitRequesterRole.outputs.roleDefinitionId
  ```

  Replace `params/governance.bicepparam`:

  ```bicep
  using '../governance.bicep'

  // Subscription governance (Phase 7): one file per subscription, deployed by an operator (runbook 07), never by
  // the pipeline. When dev and prod share a subscription, this one file covers both; another subscription gets its own copy.
  // Contact addresses are not committed: set SECURITY_CONTACT_EMAILS (semicolon-separated) before the deployment.
  // Unset, the list is empty and Azure refuses the deployment (at least one address is required).
  param securityContactEmails = filter(
    map(split(readEnvironmentVariable('SECURITY_CONTACT_EMAILS', ''), ';'), email => trim(email)),
    email => !empty(email)
  )
  param malwareScanCapGbPerMonth = 5000
  // Audit-first: switch to 'Default' only after the compliance review in runbook 07 is clean (ADR-027).
  param denyEnforcement = 'DoNotEnforce'
  param environments = [
    'dev'
    'prod'
  ]
  // The admin groups get the DefenStack JIT Requester role at their primary regional resource group. Keep each value
  // equal to adminGroupObjectId in params/<env>.bicepparam (runbook 03, section 4); empty skips that environment.
  param adminGroupObjectIds = {
    dev: ''
    prod: ''
  }
  // The legacy waiver ends here; extend it only with a dated reason in runbook 01a.
  param legacyResourceGroupName = 'defenStack'
  param legacyWaiverExpiresOn = '2027-03-31'
  ```

- [ ] **Step 4: Close the NIC and add the JIT policy**

  Replace `modules/virtualMachine.bicep`:

  ```bicep
  @description('Azure region for the VM resources.')
  param location string

  @description('Virtual machine name. Use 1-15 characters because the name is also used for the computer hostname.')
  @minLength(1)
  @maxLength(15)
  param vmName string

  @description('Operating system image to deploy.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param osType string = 'Linux'

  @description('Subnet resource ID for the VM network interface.')
  param subnetId string

  @description('Local administrator username. Do not use reserved Windows administrator names.')
  @minLength(1)
  @maxLength(64)
  param adminUsername string

  @description('SSH public key for Linux deployments. Required when osType is Linux.')
  param adminSshPublicKey string = ''

  @description('Local administrator password for Windows deployments. Required when osType is Windows.')
  @secure()
  param adminPassword string = ''

  @description('VM size selected for the workload.')
  param vmSize string = 'Standard_B2s'

  @description('Log Analytics workspace resource ID for VM diagnostics.')
  param logAnalyticsWorkspaceId string

  @description('CIDR ranges a just-in-time (JIT) request may open SSH (22) and RDP (3389) from: the same admin sources the management subnet NSG allows. The NIC NSG denies both ports until JIT grants access (ADR-028). An empty list creates no JIT policy, so the ports stay closed.')
  param managementSourceCidrs array = []

  @description('Availability zone the VM is pinned to. Fixed at creation.')
  @allowed([
    '1'
    '2'
    '3'
  ])
  param availabilityZone string = '1'

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('First Update Manager patch window, in UTC (yyyy-MM-dd HH:mm). The window then repeats every Sunday at the same time.')
  param patchWindowStartDateTime string = '2026-10-04 02:00'

  var linuxImagePublisher = 'Canonical'
  var linuxImageOffer = '0001-com-ubuntu-server-jammy'
  var linuxImageSku = '22_04-lts-gen2'
  var windowsImagePublisher = 'MicrosoftWindowsServer'
  var windowsImageOffer = 'WindowsServer'
  var windowsImageSku = '2022-datacenter-g2'
  var networkInterfaceName = '${vmName}-nic'
  var networkSecurityGroupName = '${vmName}-nsg'
  // SSH and RDP stay closed at the NIC unless a JIT request is granted. Defender for Cloud adds its time-bound allow
  // rules to this NSG above this deny, so priorities 100-3999 stay free for them (ADR-028).
  var denyManagementInboundRule = {
    name: 'deny-ssh-rdp-inbound'
    properties: {
      priority: 4000
      access: 'Deny'
      direction: 'Inbound'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  var jitPorts = [
    22
    3389
  ]

  var entraLoginExtensionName = osType == 'Linux' ? 'AADSSHLoginForLinux' : 'AADLoginForWindows'
  var virtualMachineAdministratorLoginRoleId = '1c0163c0-47e6-4577-8991-ea5c82e286e4'
  // Update Manager owns patching: platform-orchestrated installs inside the maintenance window, daily assessment.
  var patchSettings = {
    patchMode: 'AutomaticByPlatform'
    assessmentMode: 'AutomaticByPlatform'
    automaticByPlatformSettings: {
      bypassPlatformSafetyChecksOnUserSchedule: true
    }
  }
  var dataCollectionRuleName = '${vmName}-dcr'
  var azureMonitorAgentName = osType == 'Linux' ? 'AzureMonitorLinuxAgent' : 'AzureMonitorWindowsAgent'
  var performanceCounterSource = {
    performanceCounters: [
      {
        name: 'perf'
        streams: [
          'Microsoft-Perf'
        ]
        samplingFrequencyInSeconds: 60
        counterSpecifiers: osType == 'Linux' ? [
          '\\Processor(*)\\% Processor Time'
          '\\Memory(*)\\% Used Memory'
          '\\Logical Disk(*)\\% Used Space'
        ] : [
          '\\Processor Information(_Total)\\% Processor Time'
          '\\Memory\\% Committed Bytes In Use'
          '\\LogicalDisk(_Total)\\% Free Space'
        ]
      }
    ]
  }
  var osLogSource = osType == 'Linux' ? {
    syslog: [
      {
        name: 'syslog'
        streams: [
          'Microsoft-Syslog'
        ]
        facilityNames: [
          'auth'
          'authpriv'
          'daemon'
          'kern'
          'syslog'
        ]
        logLevels: [
          'Warning'
          'Error'
          'Critical'
          'Alert'
          'Emergency'
        ]
      }
    ]
  } : {
    windowsEventLogs: [
      {
        name: 'windows-events'
        streams: [
          'Microsoft-Event'
        ]
        xPathQueries: [
          'System!*[System[(Level=1 or Level=2 or Level=3)]]'
          'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
        ]
      }
    ]
  }

  // NIC-level NSG: the subnet NSG admits only Bastion and VPN clients; this NSG keeps SSH and RDP closed until a JIT
  // grant opens them.
  resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: networkSecurityGroupName
    location: location
    properties: {
      securityRules: [
        denyManagementInboundRule
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        {
          name: 'deny-ssh-rdp-outbound'
          properties: {
            priority: 4000
            access: 'Deny'
            direction: 'Outbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRanges: [
              '22'
              '3389'
            ]
          }
        }
      ]
    }
  }

  // Dynamic private IP NIC with a managed identity and no public IP.
  resource networkInterface 'Microsoft.Network/networkInterfaces@2024-07-01' = {
    name: networkInterfaceName
    location: location
    properties: {
      ipConfigurations: [
        {
          name: 'ipconfig'
          properties: {
            privateIPAllocationMethod: 'Dynamic'
            subnet: {
              id: subnetId
            }
          }
        }
      ]
      networkSecurityGroup: {
        id: networkSecurityGroup.id
      }
    }
  }

  // OS-specific VM with trusted launch, host encryption, and boot diagnostics.
  resource virtualMachine 'Microsoft.Compute/virtualMachines@2026-04-01' = {
    name: vmName
    location: location
    zones: [
      availabilityZone
    ]
    identity: {
      type: 'SystemAssigned'
    }
    properties: {
      hardwareProfile: {
        vmSize: vmSize
      }
      storageProfile: {
        imageReference: osType == 'Linux' ? {
          publisher: linuxImagePublisher
          offer: linuxImageOffer
          sku: linuxImageSku
          version: 'latest'
        } : {
          publisher: windowsImagePublisher
          offer: windowsImageOffer
          sku: windowsImageSku
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          deleteOption: 'Delete'
        }
      }
      osProfile: osType == 'Linux' ? {
        computerName: vmName
        adminUsername: adminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: adminSshPublicKey
              }
            ]
          }
          patchSettings: patchSettings
        }
      } : {
        computerName: vmName
        adminUsername: adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          enableAutomaticUpdates: true
          provisionVMAgent: true
          patchSettings: patchSettings
        }
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: networkInterface.id
            properties: {
              primary: true
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true
        }
      }
      securityProfile: {
        securityType: 'TrustedLaunch'
        encryptionAtHost: true
        uefiSettings: {
          secureBootEnabled: true
          vTpmEnabled: true
        }
      }
    }
  }

  // Platform metrics only; Compute VMs expose no diagnostic log categories. Guest logs use the DCR below.
  resource virtualMachineDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
    scope: virtualMachine
    name: 'vm-diagnostics'
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      metrics: [
        {
          category: 'AllMetrics'
          enabled: true
        }
      ]
    }
  }

  // Azure Monitor Agent authenticates with the VM's system-assigned identity.
  resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = {
    parent: virtualMachine
    name: azureMonitorAgentName
    location: location
    properties: {
      publisher: 'Microsoft.Azure.Monitor'
      type: azureMonitorAgentName
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
      enableAutomaticUpgrade: true
    }
  }

  // Guest OS logs and performance counters routed to the central workspace.
  resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
    name: dataCollectionRuleName
    location: location
    kind: osType
    properties: {
      dataSources: union(performanceCounterSource, osLogSource)
      destinations: {
        logAnalytics: [
          {
            name: 'workspace'
            workspaceResourceId: logAnalyticsWorkspaceId
          }
        ]
      }
      dataFlows: [
        {
          streams: osType == 'Linux' ? [
            'Microsoft-Syslog'
            'Microsoft-Perf'
          ] : [
            'Microsoft-Event'
            'Microsoft-Perf'
          ]
          destinations: [
            'workspace'
          ]
        }
      ]
    }
  }

  resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
    name: '${vmName}-dcra'
    scope: virtualMachine
    properties: {
      dataCollectionRuleId: dataCollectionRule.id
    }
  }

  // Regional configuration endpoint for the agent, scoped into the AMPLS by main.bicep so the agent fetches its
  // configuration over the private endpoint rather than through the firewall (Phase 6, ADR-022).
  resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
    name: '${vmName}-dce'
    location: location
    properties: {
      networkAcls: {
        publicNetworkAccess: 'Disabled'
      }
    }
  }

  // Azure Monitor requires this exact association name for the endpoint the agent reads its configuration from.
  resource dataCollectionEndpointAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
    name: 'configurationAccessEndpoint'
    scope: virtualMachine
    properties: {
      dataCollectionEndpointId: dataCollectionEndpoint.id
    }
  }

  // Entra ID sign-in (az ssh vm / Bastion native client with --auth-type AAD); local admin stays for break-glass.
  resource entraLogin 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = {
    parent: virtualMachine
    name: entraLoginExtensionName
    location: location
    properties: {
      publisher: 'Microsoft.Azure.ActiveDirectory'
      type: entraLoginExtensionName
      typeHandlerVersion: '1.0'
      autoUpgradeMinorVersion: true
    }
    // One extension operation at a time per VM.
    dependsOn: [
      azureMonitorAgent
    ]
  }

  // The admin group signs in as administrator; PIM makes the membership just-in-time (runbook 03).
  resource administratorLogin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminGroupObjectId)) {
    name: guid(virtualMachine.id, adminGroupObjectId, virtualMachineAdministratorLoginRoleId)
    scope: virtualMachine
    properties: {
      principalId: adminGroupObjectId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', virtualMachineAdministratorLoginRoleId)
    }
  }

  // Just-in-time access (Phase 7, ADR-028): a granted request opens SSH and RDP on the NIC NSG for up to three hours,
  // from the admin sources only. Needs Defender for Servers, which governance.bicep enables (runbook 07). The portal and
  // az security jit-policy use the policy named default in the VM's resource group and region.
  resource jitPolicy 'Microsoft.Security/locations/jitNetworkAccessPolicies@2020-01-01' = if (!empty(managementSourceCidrs)) {
    name: '${location}/default'
    kind: 'Basic'
    properties: {
      virtualMachines: [
        {
          id: virtualMachine.id
          ports: [for port in jitPorts: {
            number: port
            protocol: 'TCP'
            allowedSourceAddressPrefixes: managementSourceCidrs
            maxRequestAccessDuration: 'PT3H'
          }]
        }
      ]
    }
  }

  // Weekly Update Manager window for critical and security updates.
  resource patchSchedule 'Microsoft.Maintenance/maintenanceConfigurations@2023-04-01' = {
    name: '${vmName}-patch'
    location: location
    properties: {
      maintenanceScope: 'InGuestPatch'
      extensionProperties: {
        InGuestPatchMode: 'User'
      }
      maintenanceWindow: {
        startDateTime: patchWindowStartDateTime
        duration: '03:00'
        timeZone: 'UTC'
        recurEvery: 'Week Sunday'
      }
      installPatches: {
        rebootSetting: 'IfRequired'
        linuxParameters: {
          classificationsToInclude: [
            'Critical'
            'Security'
          ]
        }
        windowsParameters: {
          classificationsToInclude: [
            'Critical'
            'Security'
          ]
        }
      }
    }
  }

  resource patchScheduleAssignment 'Microsoft.Maintenance/configurationAssignments@2023-04-01' = {
    name: '${vmName}-patch'
    scope: virtualMachine
    location: location
    properties: {
      maintenanceConfigurationId: patchSchedule.id
      resourceId: virtualMachine.id
    }
  }

  output id string = virtualMachine.id
  output name string = virtualMachine.name
  output networkInterfaceId string = networkInterface.id
  output dataCollectionRuleId string = dataCollectionRule.id
  output dataCollectionEndpointId string = dataCollectionEndpoint.id
  ```

  Replace `modules/spokeNetwork.bicep` (a comment only; the subnet rules are unchanged):

  ```bicep
  @description('Azure region for the spoke network resources.')
  param location string

  @description('Spoke virtual network name.')
  @minLength(2)
  @maxLength(64)
  param vnetName string

  @description('Non-overlapping spoke address space.')
  param vnetAddressSpace array = [
    '10.0.0.0/16'
  ]

  @description('Firewall private IP used for App Service egress and VNet DNS proxy traffic.')
  param firewallPrivateIp string

  @description('Log Analytics workspace resource ID for VNet diagnostics.')
  param logAnalyticsWorkspaceId string

  @description('CIDR ranges allowed to reach private endpoints over HTTPS. The caller derives these from subnet prefixes so they cannot drift.')
  param approvedPrivateEndpointSourceCidrs array

  @description('Private endpoint subnet name.')
  param privateEndpointSubnetName string = 'private-endpoints'

  @description('App Service integration subnet name.')
  param appServiceIntegrationSubnetName string = 'appservice-integration'

  @description('Private endpoint subnet address prefix.')
  param privateEndpointSubnetAddressPrefix string = '10.0.1.0/24'

  @description('App Service integration subnet address prefix.')
  param appServiceIntegrationSubnetAddressPrefix string = '10.0.2.0/24'

  @description('Virtual machine subnet name.')
  param virtualMachineSubnetName string = 'management'

  @description('Virtual machine subnet address prefix.')
  param virtualMachineSubnetAddressPrefix string = '10.0.3.0/24'

  @description('Apply a CanNotDelete lock to the spoke VNet.')
  param enableDeleteLock bool = false

  @description('CIDR ranges allowed to reach management VMs over SSH (22) and RDP (3389), such as AzureBastionSubnet or the P2S VPN client pool. An empty list denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('CIDR ranges allowed to reach only the AMPLS private endpoint (its application security group) over HTTPS: the local AzureFirewallSubnet in the region that hosts the endpoint, which SNATs the other region\'s Azure Monitor traffic (Phase 6). An empty list adds no rule.')
  param monitorPeerSourceCidrs array = []

  var appServiceRouteTableName = '${vnetName}-appservice-egress-rt'
  var virtualMachineRouteTableName = '${vnetName}-${virtualMachineSubnetName}-egress-rt'
  var privateEndpointNsgName = '${vnetName}-${privateEndpointSubnetName}-nsg'
  var appServiceIntegrationNsgName = '${vnetName}-${appServiceIntegrationSubnetName}-nsg'
  var virtualMachineNsgName = '${vnetName}-${virtualMachineSubnetName}-nsg'
  var amplsAsgName = '${vnetName}-ampls-asg'

  // Administrative inbound is only rendered when approved management sources are supplied. This subnet allow is the
  // outer bound on who may ever connect; the jump host's NIC NSG denies SSH and RDP until a JIT grant (ADR-028).
  var managementInboundRules = empty(managementSourceCidrs) ? [] : [
    {
      name: 'allow-management-ssh-rdp'
      properties: {
        priority: 100
        access: 'Allow'
        direction: 'Inbound'
        protocol: 'Tcp'
        sourceAddressPrefixes: managementSourceCidrs
        sourcePortRange: '*'
        destinationAddressPrefix: virtualMachineSubnetAddressPrefix
        destinationPortRanges: [
          '22'
          '3389'
        ]
      }
    }
  ]
  // No spoke subnet opens SSH/RDP sessions to other hosts (PSRule Azure.NSG.LateralTraversal).
  var denyLateralTraversalRule = {
    name: 'deny-ssh-rdp-outbound'
    properties: {
      priority: 4000
      access: 'Deny'
      direction: 'Outbound'
      protocol: '*'
      sourceAddressPrefix: '*'
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
  // The peer region's monitoring traffic arrives from the local firewall's SNAT address; it may reach the AMPLS
  // endpoint alone, never the subnet's other private endpoints (ADR-022).
  var peerMonitoringRule = {
    name: 'allow-peer-monitoring-https'
    properties: {
      priority: 110
      access: 'Allow'
      direction: 'Inbound'
      protocol: 'Tcp'
      sourceAddressPrefixes: monitorPeerSourceCidrs
      sourcePortRange: '*'
      destinationApplicationSecurityGroups: [
        {
          id: amplsAsg.id
        }
      ]
      destinationPortRange: '443'
    }
  }
  var peerMonitoringInboundRules = empty(monitorPeerSourceCidrs) ? [] : [
    peerMonitoringRule
  ]

  // Membership marks the AMPLS private endpoint as the only target of the peer monitoring rule. Free of charge.
  resource amplsAsg 'Microsoft.Network/applicationSecurityGroups@2024-07-01' = {
    name: amplsAsgName
    location: location
  }

  // NSG for the private endpoint subnet; source CIDRs are explicit deployment inputs.
  resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: privateEndpointNsgName
    location: location
    properties: {
      securityRules: concat([
        {
          name: 'allow-approved-https'
          properties: {
            priority: 100
            access: 'Allow'
            direction: 'Inbound'
            protocol: 'Tcp'
            sourceAddressPrefixes: approvedPrivateEndpointSourceCidrs
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '443'
          }
        }
      ], peerMonitoringInboundRules, [
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        denyLateralTraversalRule
      ])
    }
  }

  // NSG for the delegated App Service integration subnet.
  resource appServiceIntegrationNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: appServiceIntegrationNsgName
    location: location
    properties: {
      securityRules: [
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        denyLateralTraversalRule
      ]
    }
  }

  // Route only App Service integration egress through Azure Firewall.
  resource appServiceRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
    name: appServiceRouteTableName
    location: location
    properties: {
      disableBgpRoutePropagation: true
      routes: [
        {
          name: 'default-through-firewall'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopIpAddress: firewallPrivateIp
          }
        }
      ]
    }
  }

  // Dedicated NSG for the management subnet; denies everything except approved admin sources.
  resource virtualMachineNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
    name: virtualMachineNsgName
    location: location
    properties: {
      securityRules: concat(managementInboundRules, [
        {
          name: 'deny-unsolicited-inbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourceAddressPrefix: '*'
            sourcePortRange: '*'
            destinationAddressPrefix: '*'
            destinationPortRange: '*'
          }
        }
        denyLateralTraversalRule
      ])
    }
  }

  // Route management subnet egress through Azure Firewall; gateway routes are not propagated.
  resource virtualMachineRouteTable 'Microsoft.Network/routeTables@2024-07-01' = {
    name: virtualMachineRouteTableName
    location: location
    properties: {
      disableBgpRoutePropagation: true
      routes: [
        {
          name: 'default-through-firewall'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopIpAddress: firewallPrivateIp
          }
        }
      ]
    }
  }

  module vnet 'vnet.bicep' = {
    params: {
      vnetName: vnetName
      location: location
      vnetAddressSpace: vnetAddressSpace
      dnsServer: [
        firewallPrivateIp
      ]
      subnets: [
        {
          name: privateEndpointSubnetName
          addressPrefix: privateEndpointSubnetAddressPrefix
          nsgId: privateEndpointNsg.id
          privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
        {
          name: appServiceIntegrationSubnetName
          addressPrefix: appServiceIntegrationSubnetAddressPrefix
          delegation: 'Microsoft.Web/serverFarms'
          nsgId: appServiceIntegrationNsg.id
          udrId: appServiceRouteTable.id
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
        }
        {
          name: virtualMachineSubnetName
          addressPrefix: virtualMachineSubnetAddressPrefix
          nsgId: virtualMachineNsg.id
          udrId: virtualMachineRouteTable.id
          privateEndpointNetworkPolicies: 'Disabled'
          privateLinkServiceNetworkPolicies: 'Enabled'
          defaultOutboundAccess: false
        }
      ]
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      virtualMachineSubnetName: virtualMachineSubnetName
      enableDeleteLock: enableDeleteLock
      enableDiagnostics: true
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  output id string = vnet.outputs.id
  output name string = vnet.outputs.name
  output privateEndpointSubnetId string = vnet.outputs.privateEndpointSubnetId
  output appServiceIntegrationSubnetId string = vnet.outputs.appServiceIntegrationSubnetId
  output virtualMachineSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', vnet.outputs.name, virtualMachineSubnetName)
  output amplsAsgId string = amplsAsg.id
  ```

  Replace `modules/regionStamp.bicep` (a comment only):

  ```bicep
  import { regionAddressPlan, privateDnsZoneSet, hubPeeringPlan, alertThresholdSet } from 'types.bicep'

  @description('Deployment environment.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Role of this region in the active/passive design. Only the primary gets zone-redundant App Service capacity and the optional management VM.')
  @allowed([
    'primary'
    'secondary'
  ])
  param regionRole string

  @description('Azure region for this stamp.')
  param location string

  @description('Short lowercase region code used in resource names, for example wus3 or eus.')
  @minLength(2)
  @maxLength(4)
  param regionCode string

  @description('Hub and spoke address plan for this region.')
  param addressPlan regionAddressPlan

  @description('Central Log Analytics workspace resource ID from the global layer.')
  param logAnalyticsWorkspaceId string

  @description('Shared private DNS zone resource IDs from the global layer.')
  param privateDnsZoneIds privateDnsZoneSet

  @description('Approved outbound HTTPS destinations. An empty list keeps application traffic denied by the firewall.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges, beyond the App Service integration and management subnets, allowed to reach private endpoints over HTTPS.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('CIDR ranges allowed to administer management VMs over SSH/RDP. Empty denies all administrative inbound traffic.')
  param managementSourceCidrs array = []

  @description('Relative path probed by App Service health check.')
  param healthCheckPath string = '/'

  @description('Deploy the optional management VM (primary region only).')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in this region. The warm standby leaves it off until failover.')
  param deployAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Warm standby only: resource ID of the primary region RA-GZRS storage account, read through its secondary endpoint. Empty for the primary stamp.')
  param primaryStorageAccountId string = ''

  @description('Warm standby only: name of the primary region storage account.')
  param primaryStorageAccountName string = ''

  @description('Application secrets written to this region\'s Key Vault, as { name: value } (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  @description('Prod with DR only: routing and Azure Monitor rules for the hub-to-hub peering with the other region. Absent in dev and in prod without DR.')
  param hubPeering hubPeeringPlan?

  @description('Resource ID of the environment\'s action group, which every regional alert notifies (Phase 6).')
  param actionGroupId string

  @description('Thresholds for the count-based regional alerts (Phase 6).')
  param alertThresholds alertThresholdSet

  var isProd = environmentName == 'prod'
  var isPrimary = regionRole == 'primary'
  var nameSuffix = uniqueString(subscription().id, environmentName, location)
  var availabilityZones = [
    '1'
    '2'
    '3'
  ]
  var names = {
    hubVnet: 'vnet-defenstack-${environmentName}-${regionCode}-hub'
    spokeVnet: 'vnet-defenstack-${environmentName}-${regionCode}-spoke'
    firewall: 'afw-defenstack-${environmentName}-${regionCode}'
    firewallPolicy: 'afwp-defenstack-${environmentName}-${regionCode}'
    firewallPublicIp: 'pip-afw-defenstack-${environmentName}-${regionCode}'
    storageAccount: 'st${regionCode}${nameSuffix}'
    keyVault: 'kv-${regionCode}-${nameSuffix}'
    appServicePlan: 'asp-defenstack-${environmentName}-${regionCode}'
    appService: 'app-defenstack-${environmentName}-${regionCode}-${take(nameSuffix, 6)}'
    virtualMachine: 'vm${regionCode}${take(nameSuffix, 7)}'
    bastion: 'bas-defenstack-${environmentName}-${regionCode}'
    bastionPublicIp: 'pip-bas-defenstack-${environmentName}-${regionCode}'
    vpnGateway: 'vpng-defenstack-${environmentName}-${regionCode}'
    vpnGatewayPublicIp: 'pip-vpng-defenstack-${environmentName}-${regionCode}'
    appInsights: 'appi-defenstack-${environmentName}-${regionCode}'
    flowLogStorageAccount: 'stfl${regionCode}${nameSuffix}'
    flowLogIdentity: 'id-flowlogs-defenstack-${environmentName}-${regionCode}'
  }
  // Azure Firewall always takes the first usable address (.4) of AzureFirewallSubnet. The hub needs it before
  // the firewall exists (GatewaySubnet route table); runbook 03 checks it matches the firewall's actual IP.
  var firewallPrivateIp = cidrHost(addressPlan.firewallSubnetPrefix, 3)
  // Admin sessions arrive from Bastion or from VPN clients; managementSourceCidrs adds any extra approved ranges. The
  // management subnet NSG allows these sources, and the jump host's JIT policy opens its NIC NSG to them on request (ADR-028).
  var adminSourceCidrs = concat([
    addressPlan.bastionSubnetPrefix
    addressPlan.vpnClientAddressPool
  ], managementSourceCidrs)
  var monitorPeeringRole = hubPeering.?monitorRole ?? 'None'
  // The region hosting the AMPLS endpoint SNATs the other region's monitoring traffic at its firewall, so the
  // private-endpoint NSG must admit the firewall subnet there, to the AMPLS endpoint's application security group only (Phase 6).
  var peerTrafficSourceCidrs = monitorPeeringRole == 'Host' ? [
    addressPlan.firewallSubnetPrefix
  ] : []
  var privateEndpointSubnetName = 'private-endpoints'
  var appServiceIntegrationSubnetName = 'appservice-integration'

  module storage 'storage.bicep' = {
    name: 'storage'
    params: {
      location: location
      storageAccountName: names.storageAccount
      // Prod primary: zone- and geo-redundant with read access to the East US copy (ADR-020). Warm standby: GRS. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? (isPrimary ? 'Standard_RAGZRS' : 'Standard_GRS') : 'Standard_LRS'
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module keyVault 'keyVault.bicep' = {
    name: 'key-vault'
    params: {
      location: location
      keyVaultName: names.keyVault
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      enablePurgeProtection: true
      enabledForTemplateDeployment: true
      enableDeleteLock: isProd
      secrets: keyVaultSecrets
    }
  }

  module hubNetwork 'hubNetwork.bicep' = {
    name: 'hub-network'
    params: {
      location: location
      vnetName: names.hubVnet
      addressSpace: addressPlan.hubAddressSpace
      firewallSubnetAddressPrefix: addressPlan.firewallSubnetPrefix
      bastionSubnetAddressPrefix: addressPlan.bastionSubnetPrefix
      gatewaySubnetAddressPrefix: addressPlan.gatewaySubnetPrefix
      firewallPrivateIp: firewallPrivateIp
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      bastionTargetAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      enableDeleteLock: isProd
      remoteSpokeAddressPrefixes: hubPeering.?remoteSpokeAddressPrefixes ?? []
      remoteFirewallPrivateIp: hubPeering.?remoteFirewallPrivateIp ?? ''
    }
  }

  module azureFirewall 'azureFirewall.bicep' = {
    name: 'azure-firewall'
    params: {
      location: location
      firewallName: names.firewall
      firewallPolicyName: names.firewallPolicy
      publicIpName: names.firewallPublicIp
      firewallSubnetId: hubNetwork.outputs.firewallSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      spokeAddressPrefixes: addressPlan.spokeAddressSpace
      managementAddressPrefixes: [
        addressPlan.managementSubnetPrefix
      ]
      vpnClientAddressPrefixes: [
        addressPlan.vpnClientAddressPool
      ]
      allowedOutboundFqdns: allowedOutboundFqdns
      threatIntelMode: isProd ? 'Deny' : 'Alert'
      availabilityZones: availabilityZones
      firewallTier: 'Premium'
      idpsMode: isProd ? 'Deny' : 'Alert'
      enableDeleteLock: isProd
      monitorPeeringRole: monitorPeeringRole
      monitorClientPrefixes: hubPeering.?monitorClientPrefixes ?? []
      monitorPrivateEndpointPrefixes: hubPeering.?monitorPrivateEndpointPrefixes ?? []
    }
  }

  module spokeNetwork 'spokeNetwork.bicep' = {
    name: 'spoke-network'
    params: {
      location: location
      vnetName: names.spokeVnet
      firewallPrivateIp: azureFirewall.outputs.privateIp
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      vnetAddressSpace: addressPlan.spokeAddressSpace
      privateEndpointSubnetAddressPrefix: addressPlan.privateEndpointSubnetPrefix
      appServiceIntegrationSubnetAddressPrefix: addressPlan.appServiceIntegrationSubnetPrefix
      virtualMachineSubnetAddressPrefix: addressPlan.managementSubnetPrefix
      approvedPrivateEndpointSourceCidrs: concat([
        addressPlan.appServiceIntegrationSubnetPrefix
        addressPlan.managementSubnetPrefix
        addressPlan.vpnClientAddressPool
      ], additionalPrivateEndpointSourceCidrs)
      monitorPeerSourceCidrs: peerTrafficSourceCidrs
      privateEndpointSubnetName: privateEndpointSubnetName
      appServiceIntegrationSubnetName: appServiceIntegrationSubnetName
      enableDeleteLock: isProd
      managementSourceCidrs: adminSourceCidrs
    }
  }

  // One workspace-based component per region, so a regional outage never takes the other region's telemetry with it (ADR-021).
  module appInsights 'appInsights.bicep' = {
    name: 'app-insights'
    params: {
      location: location
      componentName: names.appInsights
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  module appService 'appService.bicep' = {
    name: 'app-service'
    params: {
      location: location
      appServiceAppName: names.appService
      appServicePlanName: names.appServicePlan
      environmentType: environmentName
      vnetIntegrationSubnetId: spokeNetwork.outputs.appServiceIntegrationSubnetId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      healthCheckPath: healthCheckPath
      zoneRedundant: isProd && isPrimary
      instanceCount: isProd && isPrimary ? 3 : 1
      applicationInsightsConnectionString: appInsights.outputs.connectionString
    }
  }

  module appInsightsPublisher 'appInsightsPublisher.bicep' = {
    name: 'app-insights-publisher'
    params: {
      componentName: appInsights.outputs.name
      publisherPrincipalId: appService.outputs.appServicePrincipalId
      publisherAppServiceName: names.appService
    }
  }

  module virtualMachine 'virtualMachine.bicep' = if (enableVirtualMachine && isPrimary) {
    name: 'virtual-machine'
    params: {
      location: location
      vmName: names.virtualMachine
      osType: virtualMachineOsType
      subnetId: spokeNetwork.outputs.virtualMachineSubnetId
      adminUsername: virtualMachineAdminUsername
      adminSshPublicKey: virtualMachineAdminSshPublicKey
      adminPassword: virtualMachineAdminPassword
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
      managementSourceCidrs: adminSourceCidrs
      adminGroupObjectId: adminGroupObjectId
    }
  }

  module bastion 'bastion.bicep' = if (deployAdminAccess) {
    name: 'bastion'
    params: {
      location: location
      bastionName: names.bastion
      publicIpName: names.bastionPublicIp
      subnetId: hubNetwork.outputs.bastionSubnetId
      availabilityZones: availabilityZones
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    // The hub resolves DNS through the firewall, so admin access waits for it.
    dependsOn: [
      azureFirewall
    ]
  }

  module vpnGateway 'vpnGateway.bicep' = if (deployAdminAccess) {
    name: 'vpn-gateway'
    params: {
      location: location
      gatewayName: names.vpnGateway
      publicIpNamePrefix: names.vpnGatewayPublicIp
      gatewaySubnetId: hubNetwork.outputs.gatewaySubnetId
      skuName: isProd ? 'VpnGw2AZ' : 'VpnGw1AZ'
      availabilityZones: availabilityZones
      vpnClientAddressPool: addressPlan.vpnClientAddressPool
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
    dependsOn: [
      azureFirewall
    ]
  }

  module networkIntegration 'networkIntegration.bicep' = {
    name: 'network-integration'
    params: {
      hubVnetName: names.hubVnet
      hubVnetId: hubNetwork.outputs.id
      spokeVnetName: names.spokeVnet
      spokeVnetId: spokeNetwork.outputs.id
      storageAccountName: names.storageAccount
      storageAccountId: storage.outputs.id
      storageContainerName: storage.outputs.blobContainerName
      appServicePrincipalId: appService.outputs.appServicePrincipalId
      appServiceName: names.appService
      useHubGateway: deployAdminAccess
    }
    // Gateway transit on the peering needs a provisioned gateway.
    dependsOn: [
      vpnGateway
    ]
  }

  // The warm standby reads the primary's data through the RA-GZRS secondary endpoint (blob_secondary).
  module storageSecondaryEndpoint 'storageSecondaryEndpoint.bicep' = if (!empty(primaryStorageAccountId)) {
    name: 'storage-secondary-endpoint'
    params: {
      location: location
      primaryStorageAccountId: primaryStorageAccountId
      primaryStorageAccountName: primaryStorageAccountName
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      blobPrivateDnsZoneId: privateDnsZoneIds.blob
    }
  }

  module privateConnectivity 'privateConnectivity.bicep' = {
    name: 'private-connectivity'
    params: {
      location: location
      storageAccountId: storage.outputs.id
      storageAccountName: names.storageAccount
      appServiceId: appService.outputs.appServiceAppId
      appServiceName: names.appService
      privateEndpointSubnetId: spokeNetwork.outputs.privateEndpointSubnetId
      keyVaultId: keyVault.outputs.id
      keyVaultName: names.keyVault
      privateDnsZoneIds: privateDnsZoneIds
    }
  }

  // VNet flow logs with Traffic Analytics (Phase 6): a regional keyless account and the identity that writes to it.
  module flowLogStorage 'flowLogStorage.bicep' = {
    name: 'flow-log-storage'
    params: {
      location: location
      storageAccountName: names.flowLogStorageAccount
      // Zone-redundant in prod; flow logs are regional telemetry, so no geo copy. Dev: LRS (ADR-008).
      storageAccountSkuName: isProd ? 'Standard_ZRS' : 'Standard_LRS'
      identityName: names.flowLogIdentity
    }
  }

  // Network Watcher lives in NetworkWatcherRG (one per region per subscription), so the flow logs are deployed there.
  module flowLogs 'flowLogs.bicep' = {
    name: 'flow-logs-${environmentName}-${regionCode}'
    scope: resourceGroup('NetworkWatcherRG')
    params: {
      location: location
      virtualNetworks: [
        {
          name: names.hubVnet
          id: hubNetwork.outputs.id
        }
        {
          name: names.spokeVnet
          id: spokeNetwork.outputs.id
        }
      ]
      storageAccountId: flowLogStorage.outputs.id
      identityId: flowLogStorage.outputs.identityId
      logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    }
  }

  // Regional platform alerts (Phase 6), all to the environment's action group. Triage steps: runbook 06.
  module metricAlerts 'metricAlerts.bicep' = {
    name: 'metric-alerts'
    params: {
      namePrefix: 'alert-defenstack-${environmentName}-${regionCode}'
      actionGroupId: actionGroupId
      rules: [
        {
          name: 'firewall-health'
          description: 'Azure Firewall health is below 90 percent.'
          severity: 1
          resourceId: azureFirewall.outputs.id
          metricNamespace: 'Microsoft.Network/azureFirewalls'
          metricName: 'FirewallHealth'
          operator: 'LessThan'
          threshold: '90'
          timeAggregation: 'Average'
        }
        {
          name: 'firewall-snat-ports'
          description: 'Azure Firewall SNAT port utilisation is above 80 percent.'
          severity: 2
          resourceId: azureFirewall.outputs.id
          metricNamespace: 'Microsoft.Network/azureFirewalls'
          metricName: 'SNATPortUtilization'
          operator: 'GreaterThan'
          threshold: '80'
          timeAggregation: 'Maximum'
        }
        {
          name: 'app-http-5xx'
          description: 'The App Service returned more HTTP 5xx responses than the threshold in 15 minutes.'
          severity: 2
          resourceId: appService.outputs.appServiceAppId
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'Http5xx'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.appServiceHttp5xx)
          timeAggregation: 'Total'
        }
        {
          name: 'app-health-check'
          description: 'Some App Service instances are failing the health check.'
          severity: 1
          resourceId: appService.outputs.appServiceAppId
          metricNamespace: 'Microsoft.Web/sites'
          metricName: 'HealthCheckStatus'
          operator: 'LessThan'
          threshold: '100'
          timeAggregation: 'Average'
        }
        {
          name: 'key-vault-availability'
          description: 'Key Vault availability is below 99.9 percent.'
          severity: 2
          resourceId: keyVault.outputs.id
          metricNamespace: 'Microsoft.KeyVault/vaults'
          metricName: 'Availability'
          operator: 'LessThan'
          threshold: '99.9'
          timeAggregation: 'Average'
        }
        {
          name: 'key-vault-forbidden'
          description: 'Key Vault refused more requests with 403 Forbidden than the threshold in 15 minutes.'
          severity: 3
          resourceId: keyVault.outputs.id
          metricNamespace: 'Microsoft.KeyVault/vaults'
          metricName: 'ServiceApiResult'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.keyVaultForbidden)
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'StatusCode'
              operator: 'Include'
              values: [
                '403'
              ]
            }
          ]
        }
        {
          name: 'vpn-p2s-connections'
          description: 'More point-to-site VPN connections than expected.'
          severity: 3
          resourceId: deployAdminAccess ? vpnGateway!.outputs.id : ''
          metricNamespace: 'Microsoft.Network/virtualNetworkGateways'
          metricName: 'P2SConnectionCount'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.vpnP2sConnections)
          timeAggregation: 'Maximum'
          // Only where this region has the gateway (deployAdminAccess).
          deploy: deployAdminAccess
        }
      ]
    }
  }

  output hubVnetName string = names.hubVnet
  output hubVnetId string = hubNetwork.outputs.id
  output spokeVnetName string = names.spokeVnet
  output spokeVnetId string = spokeNetwork.outputs.id
  output firewallPrivateIp string = azureFirewall.outputs.privateIp
  output expectedFirewallPrivateIp string = firewallPrivateIp
  output bastionName string = deployAdminAccess ? names.bastion : ''
  output vpnGatewayName string = deployAdminAccess ? names.vpnGateway : ''
  output appServiceName string = names.appService
  output appServiceId string = appService.outputs.appServiceAppId
  output appServiceHostName string = appService.outputs.appServiceAppHostName
  output keyVaultName string = names.keyVault
  output storageAccountName string = names.storageAccount
  output storageAccountId string = storage.outputs.id
  output storageContainerName string = storage.outputs.blobContainerName
  output appServicePrincipalId string = appService.outputs.appServicePrincipalId
  output appInsightsName string = appInsights.outputs.name
  output appInsightsId string = appInsights.outputs.id
  output privateEndpointSubnetId string = spokeNetwork.outputs.privateEndpointSubnetId
  output monitorAsgId string = spokeNetwork.outputs.amplsAsgId
  output dataCollectionEndpointId string = enableVirtualMachine && isPrimary ? virtualMachine!.outputs.dataCollectionEndpointId : ''
  ```

  Replace `main.bicep` (the `managementSourceCidrs` description only):

  ```bicep
  targetScope = 'subscription'

  import { regionAddressPlan, privateDnsZoneSet, alertThresholdSet } from 'modules/types.bicep'

  @description('Deployment environment. Selects resource group names, redundancy, and deletion protection.')
  @allowed([
    'dev'
    'prod'
  ])
  param environmentName string

  @description('Primary (active) Azure region. Each allowed region has a short code in regionCodes.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param primaryLocation string = 'westus3'

  @description('Secondary (warm standby) Azure region, the platform pair of the primary.')
  @allowed([
    'westus3'
    'eastus'
  ])
  param secondaryLocation string = 'eastus'

  @description('Deploy the secondary region stamp. Prod enables it; dev runs primary-only to halve cost.')
  param deploySecondaryRegion bool = false

  @description('Address plan for the primary region.')
  param primaryAddressPlan regionAddressPlan

  @description('Address plan for the secondary region. Required when deploySecondaryRegion is true.')
  param secondaryAddressPlan regionAddressPlan?

  @description('Approved outbound HTTPS destinations for both regions. Empty keeps application traffic denied.')
  param allowedOutboundFqdns array = []

  @description('Extra CIDR ranges allowed to reach private endpoints over HTTPS in every region.')
  param additionalPrivateEndpointSourceCidrs array = []

  @description('Extra CIDR ranges allowed to administer management VMs over SSH/RDP, beyond the AzureBastionSubnet and VPN client pool of each region. Every session still needs a just-in-time request (ADR-028).')
  param managementSourceCidrs array = []

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the primary region.')
  param deployPrimaryAdminAccess bool = true

  @description('Deploy Azure Bastion and the point-to-site VPN gateway in the secondary region. Off in steady state; turned on during failover.')
  param deploySecondaryAdminAccess bool = false

  @description('Object ID of the Entra ID admin security group granted Virtual Machine Administrator Login on the management VM. Empty skips the assignment.')
  param adminGroupObjectId string = ''

  @description('Custom domain served by Front Door, for example app.example.com, hosted at an external DNS provider. Empty serves only the azurefd.net hostname.')
  param customDomainHostName string = ''

  @description('Application secrets written to every regional Key Vault, as { name: value }. The pipeline supplies them from the KEYVAULT_SECRETS_JSON environment secret; never put values in a committed parameter file (ADR-019).')
  @secure()
  param keyVaultSecrets object = {}

  @description('Relative path probed by App Service health check in every region.')
  param healthCheckPath string = '/'

  @description('Email address that receives every platform alert. The pipeline passes the GitHub environment variable ALERT_EMAIL and refuses an empty value for prod; empty creates the action group with no receiver.')
  param alertEmail string = ''

  @description('Thresholds for the count-based alerts: App Service 5xx, Key Vault 403s, VPN connections and WAF blocks.')
  param alertThresholds alertThresholdSet = {
    appServiceHttp5xx: 10
    keyVaultForbidden: 10
    vpnP2sConnections: 20
    frontDoorWafBlocks: 100
  }

  @description('Deploy the optional management VM in the primary region.')
  param enableVirtualMachine bool = false

  @description('Management VM operating system.')
  @allowed([
    'Linux'
    'Windows'
  ])
  param virtualMachineOsType string = 'Linux'

  @description('Management VM local administrator username.')
  @minLength(1)
  @maxLength(64)
  param virtualMachineAdminUsername string = 'azureadmin'

  @description('SSH public key for Linux management VMs.')
  param virtualMachineAdminSshPublicKey string = ''

  @description('Local administrator password for Windows management VMs.')
  @secure()
  param virtualMachineAdminPassword string = ''

  var isProd = environmentName == 'prod'
  var regionCodes = {
    westus3: 'wus3'
    eastus: 'eus'
  }
  // Region names as Azure Service Health reports them, for the Service Health alert.
  var regionDisplayNames = {
    westus3: 'West US 3'
    eastus: 'East US'
  }
  var primaryRegionCode = regionCodes[toLower(primaryLocation)]
  var secondaryRegionCode = regionCodes[toLower(secondaryLocation)]
  var globalResourceGroupName = 'rg-defenstack-${environmentName}-global'
  var primaryResourceGroupName = 'rg-defenstack-${environmentName}-${primaryRegionCode}'
  var secondaryResourceGroupName = 'rg-defenstack-${environmentName}-${secondaryRegionCode}'
  var privateDnsZoneNames privateDnsZoneSet = {
    blob: 'privatelink.blob.${environment().suffixes.storage}'
    sites: 'privatelink.azurewebsites.net'
    vault: 'privatelink.vaultcore.azure.net'
    // Azure Monitor Private Link Scope zones (Phase 6); the AMPLS endpoint also registers in the blob zone above.
    monitor: 'privatelink.monitor.azure.com'
    oms: 'privatelink.oms.opinsights.azure.com'
    ods: 'privatelink.ods.opinsights.azure.com'
    agentsvc: 'privatelink.agentsvc.azure-automation.net'
  }

  // Prod with DR (Phase 6): the East US App Service and management subnets may reach the one AMPLS endpoint, in the
  // primary private-endpoint subnet, through both firewalls and the hub-to-hub peering. Nothing else crosses yet (Phase 8).
  var monitorClientPrefixes = deploySecondaryRegion ? [
    secondaryAddressPlan!.appServiceIntegrationSubnetPrefix
    secondaryAddressPlan!.managementSubnetPrefix
  ] : []
  var monitorPrivateEndpointPrefixes = [
    primaryAddressPlan.privateEndpointSubnetPrefix
  ]

  // Shared layer: Log Analytics and private DNS zones. Resource groups are pre-created (runbook 01).
  module global 'modules/global.bicep' = {
    name: 'global-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      location: primaryLocation
      workspaceName: 'log-defenstack-${environmentName}'
      privateDnsZoneNames: privateDnsZoneNames
      workspaceReplicationLocation: isProd && deploySecondaryRegion ? secondaryLocation : ''
      enableDeleteLock: isProd
    }
  }

  // The subscription Activity Log goes to the shared workspace, where Sentinel reads it as Azure Activity (Phase 6).
  module activityLog 'modules/activityLog.bicep' = {
    name: 'activity-log-${environmentName}'
    params: {
      settingName: 'activity-log-defenstack-${environmentName}'
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
    }
  }

  // One action group per environment for every platform alert (Phase 6).
  module actionGroup 'modules/actionGroup.bicep' = {
    name: 'action-group-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      actionGroupName: 'ag-defenstack-${environmentName}'
      shortName: 'ds-${environmentName}-ops'
      alertEmail: alertEmail
    }
  }

  module primaryStamp 'modules/regionStamp.bicep' = {
    name: 'region-${primaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'primary'
      location: primaryLocation
      regionCode: primaryRegionCode
      addressPlan: primaryAddressPlan
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      enableVirtualMachine: enableVirtualMachine
      virtualMachineOsType: virtualMachineOsType
      virtualMachineAdminUsername: virtualMachineAdminUsername
      virtualMachineAdminSshPublicKey: virtualMachineAdminSshPublicKey
      virtualMachineAdminPassword: virtualMachineAdminPassword
      deployAdminAccess: deployPrimaryAdminAccess
      adminGroupObjectId: adminGroupObjectId
      keyVaultSecrets: keyVaultSecrets
      actionGroupId: actionGroup.outputs.id
      alertThresholds: alertThresholds
      // A firewall always takes the first usable address (.4) of its AzureFirewallSubnet (see regionStamp.bicep).
      hubPeering: deploySecondaryRegion ? {
        remoteFirewallPrivateIp: cidrHost(secondaryAddressPlan!.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: secondaryAddressPlan!.spokeAddressSpace
        monitorRole: 'Host'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      } : null
    }
  }

  module secondaryStamp 'modules/regionStamp.bicep' = if (deploySecondaryRegion) {
    name: 'region-${secondaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      environmentName: environmentName
      regionRole: 'secondary'
      location: secondaryLocation
      regionCode: secondaryRegionCode
      addressPlan: secondaryAddressPlan!
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      allowedOutboundFqdns: allowedOutboundFqdns
      additionalPrivateEndpointSourceCidrs: additionalPrivateEndpointSourceCidrs
      managementSourceCidrs: managementSourceCidrs
      healthCheckPath: healthCheckPath
      deployAdminAccess: deploySecondaryAdminAccess
      primaryStorageAccountId: isProd ? primaryStamp.outputs.storageAccountId : ''
      primaryStorageAccountName: isProd ? primaryStamp.outputs.storageAccountName : ''
      keyVaultSecrets: keyVaultSecrets
      actionGroupId: actionGroup.outputs.id
      alertThresholds: alertThresholds
      hubPeering: {
        remoteFirewallPrivateIp: cidrHost(primaryAddressPlan.firewallSubnetPrefix, 3)
        remoteSpokeAddressPrefixes: primaryAddressPlan.spokeAddressSpace
        monitorRole: 'Client'
        monitorClientPrefixes: monitorClientPrefixes
        monitorPrivateEndpointPrefixes: monitorPrivateEndpointPrefixes
      }
    }
  }

  // Hub-to-hub global peering, both ways, once both hubs exist (brought forward from Phase 8). The sides are created
  // one after the other, since each peering operation updates both VNets.
  module primaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${primaryRegionCode}-to-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      localVnetName: primaryStamp.outputs.hubVnetName
      remoteVnetId: secondaryStamp!.outputs.hubVnetId
      peeringName: 'hub-to-${secondaryRegionCode}-hub'
    }
  }

  module secondaryHubPeering 'modules/hubPeering.bicep' = if (deploySecondaryRegion) {
    name: 'hub-peering-${secondaryRegionCode}-to-${primaryRegionCode}'
    scope: resourceGroup(secondaryResourceGroupName)
    params: {
      localVnetName: secondaryStamp!.outputs.hubVnetName
      remoteVnetId: primaryStamp.outputs.hubVnetId
      peeringName: 'hub-to-${primaryRegionCode}-hub'
    }
    dependsOn: [
      primaryHubPeering
    ]
  }

  // The warm-standby App Service may read (never write) the primary application container (ADR-020).
  module secondaryStorageReader 'modules/storageReaderAssignment.bicep' = if (deploySecondaryRegion && isProd) {
    name: 'storage-reader-${secondaryRegionCode}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      storageAccountName: primaryStamp.outputs.storageAccountName
      storageContainerName: primaryStamp.outputs.storageContainerName
      readerPrincipalId: secondaryStamp!.outputs.appServicePrincipalId
      readerAppServiceName: secondaryStamp!.outputs.appServiceName
    }
  }

  var primaryVirtualNetworks = [
    {
      name: primaryStamp.outputs.hubVnetName
      id: primaryStamp.outputs.hubVnetId
    }
    {
      name: primaryStamp.outputs.spokeVnetName
      id: primaryStamp.outputs.spokeVnetId
    }
  ]
  var secondaryVirtualNetworks = deploySecondaryRegion
    ? [
        {
          name: secondaryStamp!.outputs.hubVnetName
          id: secondaryStamp!.outputs.hubVnetId
        }
        {
          name: secondaryStamp!.outputs.spokeVnetName
          id: secondaryStamp!.outputs.spokeVnetId
        }
      ]
    : []

  // Origins in failover order: the primary region first (priority 1), then the warm standby (priority 2).
  var primaryOrigin = {
    name: 'app-${primaryRegionCode}'
    appServiceId: primaryStamp.outputs.appServiceId
    hostName: primaryStamp.outputs.appServiceHostName
    location: primaryLocation
  }
  var secondaryOrigins = deploySecondaryRegion
    ? [
        {
          name: 'app-${secondaryRegionCode}'
          appServiceId: secondaryStamp!.outputs.appServiceId
          hostName: secondaryStamp!.outputs.appServiceHostName
          location: secondaryLocation
        }
      ]
    : []

  // Public ingress: one Front Door per environment in the global resource group, after both stamps exist.
  module frontDoor 'modules/frontDoor.bicep' = {
    name: 'front-door-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      profileName: 'afd-defenstack-${environmentName}'
      endpointName: 'fde-defenstack-${environmentName}'
      wafPolicyName: 'wafdefenstack${environmentName}'
      origins: concat([
        primaryOrigin
      ], secondaryOrigins)
      healthProbePath: healthCheckPath
      customDomainHostName: customDomainHostName
      logAnalyticsWorkspaceId: global.outputs.logAnalyticsWorkspaceId
      enableDeleteLock: isProd
    }
  }

  // Global platform alerts (Phase 6): Front Door origin health and WAF blocks, and Service Health for the platform
  // regions. The backup job alert waits for Phase 8.
  module globalMetricAlerts 'modules/metricAlerts.bicep' = {
    name: 'global-metric-alerts-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      namePrefix: 'alert-defenstack-${environmentName}'
      actionGroupId: actionGroup.outputs.id
      rules: [
        {
          name: 'front-door-origin-health'
          description: 'Front Door sees less than 90 percent of origin health probes succeed.'
          severity: 1
          resourceId: frontDoor.outputs.id
          metricNamespace: 'Microsoft.Cdn/profiles'
          metricName: 'OriginHealthPercentage'
          operator: 'LessThan'
          threshold: '90'
          timeAggregation: 'Average'
        }
        {
          name: 'front-door-waf-blocks'
          description: 'The Front Door WAF blocked more requests than the threshold in 15 minutes.'
          severity: 2
          resourceId: frontDoor.outputs.id
          metricNamespace: 'Microsoft.Cdn/profiles'
          metricName: 'WebApplicationFirewallRequestCount'
          operator: 'GreaterThan'
          threshold: string(alertThresholds.frontDoorWafBlocks)
          timeAggregation: 'Total'
          dimensions: [
            {
              name: 'Action'
              operator: 'Include'
              values: [
                'Block'
              ]
            }
          ]
        }
      ]
    }
  }

  module serviceHealthAlert 'modules/serviceHealthAlert.bicep' = {
    name: 'service-health-alert-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      alertName: 'alert-defenstack-${environmentName}-service-health'
      regions: concat([
        regionDisplayNames[toLower(primaryLocation)]
      ], deploySecondaryRegion ? [
        regionDisplayNames[toLower(secondaryLocation)]
      ] : [], [
        'Global'
      ])
      actionGroupId: actionGroup.outputs.id
    }
  }

  // Link every region's hub (firewall DNS proxy) and spoke to each shared zone.
  module privateDnsLinks 'modules/privateDnsZoneLinks.bicep' = [for zone in items(privateDnsZoneNames): {
    name: 'dns-links-${zone.key}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      zoneName: zone.value
      virtualNetworks: concat(primaryVirtualNetworks, secondaryVirtualNetworks)
    }
  }]

  // Private-only monitoring (Phase 6): one scope holds the workspace, every regional App Insights component and,
  // when the jump host is deployed, its data collection endpoint.
  module monitorPrivateLinkScope 'modules/monitorPrivateLinkScope.bicep' = {
    name: 'monitor-private-link-scope-${environmentName}'
    scope: resourceGroup(globalResourceGroupName)
    params: {
      scopeName: 'ampls-defenstack-${environmentName}'
      scopedResourceIds: concat([
        global.outputs.logAnalyticsWorkspaceId
        primaryStamp.outputs.appInsightsId
      ], deploySecondaryRegion ? [
        secondaryStamp!.outputs.appInsightsId
      ] : [], enableVirtualMachine ? [
        // The jump host agent's regional configuration endpoint (primary only).
        primaryStamp.outputs.dataCollectionEndpointId
      ] : [])
    }
  }

  // The single azuremonitor endpoint, in the primary spoke, created once the scope holds every resource.
  module monitorPrivateEndpoint 'modules/monitorPrivateEndpoint.bicep' = {
    name: 'monitor-private-endpoint-${environmentName}'
    scope: resourceGroup(primaryResourceGroupName)
    params: {
      location: primaryLocation
      privateLinkScopeId: monitorPrivateLinkScope.outputs.id
      privateLinkScopeName: monitorPrivateLinkScope.outputs.name
      privateEndpointSubnetId: primaryStamp.outputs.privateEndpointSubnetId
      privateDnsZoneIds: global.outputs.privateDnsZoneIds
      applicationSecurityGroupId: primaryStamp.outputs.monitorAsgId
    }
  }

  output primaryAppServiceHostName string = primaryStamp.outputs.appServiceHostName
  output secondaryAppServiceHostName string = deploySecondaryRegion ? secondaryStamp!.outputs.appServiceHostName : ''
  output primaryResourceGroupName string = primaryResourceGroupName
  output primaryBastionName string = primaryStamp.outputs.bastionName
  output primaryVpnGatewayName string = primaryStamp.outputs.vpnGatewayName
  output primaryFirewallPrivateIp string = primaryStamp.outputs.firewallPrivateIp
  output frontDoorEndpointHostName string = frontDoor.outputs.endpointHostName
  output frontDoorCustomDomainValidationToken string = frontDoor.outputs.customDomainValidationToken
  output frontDoorPrivateLinkRequestMessage string = frontDoor.outputs.privateLinkRequestMessage
  output frontDoorProfileName string = frontDoor.outputs.profileName
  output globalResourceGroupName string = globalResourceGroupName
  output appServiceIds array = concat([
    primaryStamp.outputs.appServiceId
  ], deploySecondaryRegion ? [
    secondaryStamp!.outputs.appServiceId
  ] : [])
  output monitorPrivateLinkScopeName string = monitorPrivateLinkScope.outputs.name
  ```

- [ ] **Step 5: Build, lint, test, PSRule**

  Run `bicep build main.bicep` and `bicep build governance.bicep` (both change), and lint every file. The full suite should show `Tests Passed: 657, Failed: 0`. PSRule should show 0 failures out of 1332 rules processed; the 8 new rules cover the role definition and assignments. The JIT policy does not appear, because both parameter files keep `enableVirtualMachine = false`.

- [ ] **Step 6: Commit**

  ```bash
  git add modules/governance/jitRequesterRole.bicep modules/governance/jitRequesterAssignment.bicep modules/types.bicep modules/virtualMachine.bicep modules/spokeNetwork.bicep modules/regionStamp.bicep main.bicep main.json governance.bicep governance.json params/governance.bicepparam tests/Governance.Tests.ps1 tests/Params.Tests.ps1 tests/VirtualMachine.Tests.ps1 tests/SpokeNetwork.Tests.ps1
  git commit -m "feat: just-in-time access for the jump host with a JIT requester role" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

### Task 4: Runbook 07, ADR-026 to ADR-029, and Phase 7 documentation updates

**Files:**
- Create: `docs/runbooks/07-governance.md`, `docs/decisions/ADR-026-operator-deployed-governance-entry-point.md`, `docs/decisions/ADR-027-audit-first-policy-enforcement.md`, `docs/decisions/ADR-028-jit-access-and-nsg-ownership.md`, `docs/decisions/ADR-029-preview-apis-for-governance.md`
- Replace: `tests/Docs.Tests.ps1`
- Modify: `docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md` (append), `docs/architecture/overview.md`, `docs/cost.md`, `docs/runbooks/00b-configure-pipeline-credentials.md`, `docs/runbooks/03-admin-access.md`, `docs/runbooks/06-monitoring-and-sentinel.md`, `README.md`

**Interfaces:**
- **Consumes:** the names, parameters, assignments, exemptions, roles and rules from Tasks 1–3. The runbook quotes them verbatim.
- **Produces:** the documents that the spec §6 definition of done requires a human to execute in dev, including the policy exemption procedure and Defender recommendation handling (§5 row 7).

- [ ] **Step 1: Write the failing docs tests**

  Replace `tests/Docs.Tests.ps1`:

  ````powershell
  BeforeAll {
      Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
  }

  Describe 'Phase 1 documentation' {
      It '<_> exists' -ForEach 'docs/architecture/overview.md', 'docs/runbooks/01-deploy-stack.md', 'docs/runbooks/01a-migrate-from-defenstack.md', 'docs/decisions/ADR-008-warm-standby-and-dev-single-region.md', 'docs/decisions/ADR-009-subscription-scope-pipeline-identity.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It '<_> follows the 9-section runbook template' -ForEach 'docs/runbooks/01-deploy-stack.md', 'docs/runbooks/01a-migrate-from-defenstack.md' {
          $text = Get-Content (Get-RepoPath $_) -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the architecture overview contains mermaid diagrams' {
          Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw | Should -Match '```mermaid'
      }
  }

  Describe 'README reflects the subscription-scope layout' {
      BeforeAll {
          $script:readmeText = Get-Content (Get-RepoPath 'README.md') -Raw
          $script:teardownHeading = '### Safe teardown'
          $script:beforeTeardown = $script:readmeText.Substring(0, $script:readmeText.IndexOf($script:teardownHeading))
      }

      It 'does not contain a param environmentType assignment before the legacy Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'param environmentType'
      }

      It 'does not contain an environmentType= CLI argument before the legacy Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'environmentType='
      }

      It 'does not mention spokeVnetAddressSpace' {
          $script:readmeText | Should -Not -Match 'spokeVnetAddressSpace'
      }

      It 'does not mention a virtual-machines subnet' {
          $script:readmeText | Should -Not -Match 'virtual-machines'
      }

      It 'only uses az deployment group inside or after the Safe teardown section' {
          $script:beforeTeardown | Should -Not -Match 'az deployment group'
      }
  }

  Describe 'Phase 2 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/02-firewall.md', 'docs/decisions/ADR-010-shared-firewall-rules-module.md', 'docs/decisions/ADR-011-tls-inspection-deferred.md', 'docs/decisions/ADR-012-prod-two-approval-deploys.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the firewall runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/02-firewall.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the firewall runbook documents the rule change and allowlist request procedures' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/02-firewall.md') -Raw
          $text | Should -Match 'Rule change procedure'
          $text | Should -Match 'Allowlist request'
      }

      It 'runbook 00b documents the dev-plan environment and the prod two-approval design' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
          $text | Should -Match 'dev-plan'
          $text | Should -Match 'two approvals'
          $text | Should -Match 'no `?prod-plan`? environment'
      }
  }

  Describe 'Phase 3 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/03-admin-access.md', 'docs/decisions/ADR-013-admin-access-network-paths.md', 'docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md', 'docs/decisions/ADR-015-vpn-gateway-sku-and-active-active.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the admin access runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the admin access runbook covers VPN client setup per OS, Bastion connect, and break-glass (spec §5 Phase 3)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
          foreach ($topic in 'Windows 10/11', 'macOS', 'Linux (Ubuntu', 'Connect through Bastion', 'Break-glass') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the admin access runbook restricts the VPN app to the admin group' {
          Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw | Should -Match 'appRoleAssignmentRequired=true'
      }

      It 'the architecture overview draws the admin flow and lists the Phase 3 ADRs' {
          $text = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          $text | Should -Match 'VPN gateway \(GatewaySubnet'
          foreach ($adr in 'ADR-013', 'ADR-014', 'ADR-015') { $text | Should -Match $adr }
      }

      It 'the cost document has a Phase 3 delta' {
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 3 delta'
      }
  }

  Describe 'Phase 4 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/04-ingress.md', 'docs/decisions/ADR-016-front-door-over-application-gateway.md', 'docs/decisions/ADR-017-ddos-network-protection-not-selected.md', 'docs/decisions/ADR-018-front-door-placement-and-private-link-approval.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the ingress runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the ingress runbook covers DNS cutover, WAF tuning and exclusions, and PE approval (spec §5 Phase 4)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          foreach ($topic in 'Custom domain and DNS cutover', 'WAF tuning and exclusions', 'Approving a private endpoint connection by hand', 'az network private-endpoint-connection approve', 'The request message is not proof') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the ingress runbook validates the spec checks: Front Door 200, WAF 403, direct App Service 403' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          $text | Should -Match ([regex]::Escape('?q=<script>alert(1)</script>'))
          $text | Should -Match ([regex]::Escape('https://<app>.azurewebsites.net/'))
      }

      It 'the ingress runbook documents that success is Front Door''s own origin status (final review A)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw
          $text | Should -Match ([regex]::Escape('sharedPrivateLinkResource.status'))
      }

      It 'the architecture overview draws the ingress flow and lists the Phase 4 ADRs' {
          $text = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          $text | Should -Match 'Azure Front Door Premium \(global'
          foreach ($adr in 'ADR-016', 'ADR-017', 'ADR-018') { $text | Should -Match $adr }
      }

      It 'the cost document has a Phase 4 delta' {
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 4 delta'
      }
  }

  Describe 'Phase 5 documentation' {
      It '<_> exists' -ForEach 'docs/runbooks/05-app-and-data.md', 'docs/decisions/ADR-019-deploy-time-key-vault-secrets.md', 'docs/decisions/ADR-020-storage-ra-gzrs-and-warm-standby-read.md', 'docs/decisions/ADR-021-application-insights-per-region.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the app and data runbook follows the 9-section template' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $text | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the app and data runbook covers secret sync and restore from soft delete and PITR (spec §5 Phase 5)' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw
          foreach ($topic in 'Secret sync', 'KEYVAULT_SECRETS_JSON', 'az storage blob undelete', 'az storage container restore', 'az storage blob restore', 'az keyvault secret recover') {
              $text | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'runbook 00b documents the environment secret and the Phase 5 delegatable roles' {
          $text = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
          $text | Should -Match 'KEYVAULT_SECRETS_JSON'
          $text | Should -Match '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
          $text | Should -Match '3913510d-42f4-4e42-8a64-420c390055eb'
      }

      It 'the architecture overview and cost document cover Phase 5' {
          $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          foreach ($adr in 'ADR-019', 'ADR-020', 'ADR-021') { $overview | Should -Match $adr }
          Get-Content (Get-RepoPath 'docs/cost.md') -Raw | Should -Match '## Phase 5 delta'
      }

      It 'runbook 04 documents the no-origin refusal' {
          Get-Content (Get-RepoPath 'docs/runbooks/04-ingress.md') -Raw | Should -Match ([regex]::Escape("so it cannot be Front Door's request"))
      }
  }

  Describe 'Phase 6 documentation' {
      BeforeAll {
          $script:runbook06 = Get-Content (Get-RepoPath 'docs/runbooks/06-monitoring-and-sentinel.md') -Raw -ErrorAction SilentlyContinue
          $script:runbook00b = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
      }

      It '<_> exists' -ForEach 'docs/runbooks/06-monitoring-and-sentinel.md', 'docs/decisions/ADR-022-private-only-monitoring-and-hub-peering.md', 'docs/decisions/ADR-023-flow-log-identity-and-network-watcher.md', 'docs/decisions/ADR-024-sentinel-content-through-content-hub.md', 'docs/decisions/ADR-025-preview-api-subscription-diagnostic-setting.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the monitoring runbook follows the 9-section template' {
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $script:runbook06 | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the monitoring runbook covers alert triage, Sentinel connectors and querying over the VPN or jump host (spec §5 Phase 6)' {
          foreach ($topic in 'Alert triage', 'Sentinel connector enablement', 'Content Hub', 'Microsoft Entra ID', 'Tenant-based Microsoft Defender for Cloud', 'Querying the workspace over the VPN or jump host', 'Live-only risks') {
              $script:runbook06 | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the monitoring runbook has a triage entry for every alert rule' {
          foreach ($rule in 'firewall-health', 'firewall-snat-ports', 'app-http-5xx', 'app-health-check', 'key-vault-availability', 'key-vault-forbidden', 'vpn-p2s-connections', 'front-door-origin-health', 'front-door-waf-blocks', 'service-health') {
              $script:runbook06 | Should -Match ([regex]::Escape("``$rule``"))
          }
          $script:runbook06 | Should -Match 'backup job alert[^.]*Phase 8'
      }

      It 'the monitoring runbook sets ALERT_EMAIL on dev, dev-plan and prod' {
          foreach ($environment in 'dev', 'dev-plan', 'prod') {
              $script:runbook06 | Should -Match ([regex]::Escape("gh variable set ALERT_EMAIL --env $environment"))
          }
      }

      It 'the monitoring runbook and runbooks 00b and 01 require NetworkWatcherRG and NetworkWatcher_<region> before the identity script or deployment' {
          foreach ($text in $script:runbook06, $script:runbook00b, (Get-Content (Get-RepoPath 'docs/runbooks/01-deploy-stack.md') -Raw)) {
              $text | Should -Match ([regex]::Escape('az network watcher configure --resource-group NetworkWatcherRG --locations westus3 eastus --enabled true'))
              $text | Should -Match ([regex]::Escape('NetworkWatcher_<region>'))
          }
      }

      It 'the monitoring runbook covers the cross-region AMPLS path: East US network rule, West US 3 application rule with SNAT, and the private-endpoint NSG' {
          foreach ($topic in 'spoke-to-peer-azure-monitor', 'peer-spoke-to-azure-monitor', 'source address', 'AzureFirewallSubnet', '-firewall-rt') {
              $script:runbook06 | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the monitoring runbook lists each unverified item as a live-only risk with a fallback' {
          $risks = $script:runbook06.Substring($script:runbook06.IndexOf('Live-only risks'))
          foreach ($risk in 'trusted services', 'Traffic Analytics', 'FQDN', '2021-05-01-preview', '2018-03-01') {
              $risks | Should -Match ([regex]::Escape($risk))
          }
          ([regex]::Matches($risks, 'Fallback')).Count | Should -BeGreaterOrEqual 5
      }

      It 'runbook 00b documents the Phase 6 grants: Network Contributor on NetworkWatcherRG and the diagnostic-setting actions with the update path' {
          foreach ($topic in 'Network Contributor', '-NetworkWatcherResourceGroupName', 'Microsoft.Insights/diagnosticSettings/write', 'az role definition update', 'Update custom role actions') {
              $script:runbook00b | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'runbook 05 and ADR-021 no longer say Application Insights stays public until Phase 6' {
          Get-Content (Get-RepoPath 'docs/runbooks/05-app-and-data.md') -Raw | Should -Not -Match 'until Phase 6'
          Get-Content (Get-RepoPath 'docs/decisions/ADR-021-application-insights-per-region.md') -Raw | Should -Match 'ADR-022'
      }

      It 'the architecture overview, README and cost document cover Phase 6' {
          $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          foreach ($adr in 'ADR-022', 'ADR-023', 'ADR-024', 'ADR-025') { $overview | Should -Match $adr }
          $overview | Should -Match '\*\*Phase 6\*\*'
          Get-Content (Get-RepoPath 'README.md') -Raw | Should -Match ([regex]::Escape('06-monitoring-and-sentinel.md'))
          $cost = Get-Content (Get-RepoPath 'docs/cost.md') -Raw
          $cost | Should -Match '## Phase 6 delta'
          foreach ($driver in 'Sentinel', 'Traffic Analytics', 'flow-log storage', 'private endpoint', 'DNS zones', 'peering', 'alert') {
              $cost | Should -Match ([regex]::Escape($driver))
          }
      }
  }

  Describe 'Phase 7 documentation' {
      BeforeAll {
          $script:runbook07 = Get-Content (Get-RepoPath 'docs/runbooks/07-governance.md') -Raw -ErrorAction SilentlyContinue
          $script:runbook03 = Get-Content (Get-RepoPath 'docs/runbooks/03-admin-access.md') -Raw
          $script:runbook06Text = Get-Content (Get-RepoPath 'docs/runbooks/06-monitoring-and-sentinel.md') -Raw
          $script:runbook00bText = Get-Content (Get-RepoPath 'docs/runbooks/00b-configure-pipeline-credentials.md') -Raw
      }

      It '<_> exists' -ForEach 'docs/runbooks/07-governance.md', 'docs/decisions/ADR-026-operator-deployed-governance-entry-point.md', 'docs/decisions/ADR-027-audit-first-policy-enforcement.md', 'docs/decisions/ADR-028-jit-access-and-nsg-ownership.md', 'docs/decisions/ADR-029-preview-apis-for-governance.md' {
          Get-RepoPath $_ | Should -Exist
      }

      It 'the governance runbook follows the 9-section template' {
          foreach ($section in '## 1. Purpose and scope', '## 2. Prerequisites', '## 3. Parameters', '## 4. Step-by-step', '## 5. Manual and post-deployment steps', '## 6. Validation', '## 7. Rollback', '## 8. Operations', '## 9. Troubleshooting') {
              $script:runbook07 | Should -Match ([regex]::Escape($section))
          }
      }

      It 'the governance runbook covers the exemption procedure and Defender recommendation handling (spec section 5 Phase 7)' {
          foreach ($topic in 'Exemption procedure', 'Defender recommendation handling', 'Requesting JIT access', 'Live-only risks', 'az policy exemption create') {
              $script:runbook07 | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the governance runbook deploys with PIM-activated operator roles, never the pipeline' {
          foreach ($topic in 'Privileged Identity Management', 'Security Admin', 'User Access Administrator', 'Owner', 'az deployment sub what-if', 'az deployment sub create', '--template-file governance.bicep --parameters params/governance.bicepparam') {
              $script:runbook07 | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the governance runbook sets SECURITY_CONTACT_EMAILS before what-if and create' {
          $setAt = $script:runbook07.IndexOf('$env:SECURITY_CONTACT_EMAILS')
          $setAt | Should -BeGreaterThan 0
          $setAt | Should -BeLessThan $script:runbook07.IndexOf('az deployment sub what-if')
      }

      It 'the governance runbook deploys governance before the workload (JIT needs Defender for Servers)' {
          $script:runbook07 | Should -Match 'governance first, then the workload deploy'
          $script:runbook07.IndexOf('az deployment sub create') | Should -BeLessThan $script:runbook07.IndexOf('**Deploy the workload**')
      }

      It 'the governance runbook documents the audit-to-deny switch with the compliance review' {
          foreach ($topic in 'DoNotEnforce', "denyEnforcement = 'Default'", 'az policy state summarize', 'az policy state list', 'about a week') {
              $script:runbook07 | Should -Match ([regex]::Escape($topic))
          }
      }

      It 'the governance runbook spells out the ordering trap for a new environment or region' {
          $trap = $script:runbook07.Substring($script:runbook07.IndexOf('**The ordering trap.**'))
          foreach ($step in "Set ``denyEnforcement = 'DoNotEnforce'``", 'Deploy the workload', 'Add the environment', 'Redeploy governance', "Set ``denyEnforcement = 'Default'``") {
              $trap | Should -Match ([regex]::Escape($step))
          }
      }

      It 'the governance runbook marks the legacy waiver expiry as a placeholder and clears the group after teardown' {
          $script:runbook07 | Should -Match ([regex]::Escape('`2027-03-31` is a **placeholder to confirm**'))
          $script:runbook07 | Should -Match ([regex]::Escape("legacyResourceGroupName = ''"))
      }

      It 'the governance runbook lists each unverified item as a live-only risk with a fallback' {
          $risks = $script:runbook07.Substring($script:runbook07.IndexOf('### Live-only risks'))
          foreach ($risk in 'policyExemptions@2026-01-01-preview', 'securityContacts@2023-12-01-preview', 'skips `global`', 'resource-group locations policy', 'NSG redeploy', 'action list', 'CapGBPerMonthPerStorageAccount') {
              $risks | Should -Match ([regex]::Escape($risk))
          }
          ([regex]::Matches($risks, 'Fallback')).Count | Should -BeGreaterOrEqual 6
      }

      It 'runbook 03 requires a JIT request before admin access' {
          $script:runbook03 | Should -Match 'Admin access now needs a JIT request first'
          $script:runbook03 | Should -Match 'ADR-028'
          $script:runbook03 | Should -Not -Match 'It is deferred to Phase 7'
      }

      It 'runbook 06 records the stfl flow-log exemption as in place' {
          $script:runbook06Text | Should -Match ([regex]::Escape('defenstack-flow-log-storage-public-network'))
          $script:runbook06Text | Should -Not -Match 'will need an exemption'
      }

      It 'runbook 00b states that the pipeline does not deploy governance and deploy.yml skips governance-only paths' {
          $script:runbook00bText | Should -Match 'The pipeline does not deploy governance'
          $script:runbook00bText | Should -Match ([regex]::Escape('modules/governance/**'))
          $script:runbook00bText | Should -Match ([regex]::Escape('params/governance.bicepparam'))
      }

      It 'ADR-014 points to its successor ADR-028' {
          Get-Content (Get-RepoPath 'docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md') -Raw | Should -Match 'Superseded by `ADR-028`'
      }

      It 'the architecture overview, README and cost document cover Phase 7' {
          $overview = Get-Content (Get-RepoPath 'docs/architecture/overview.md') -Raw
          foreach ($adr in 'ADR-026', 'ADR-027', 'ADR-028', 'ADR-029') { $overview | Should -Match $adr }
          $overview | Should -Match '\*\*Phase 7\*\*'
          Get-Content (Get-RepoPath 'README.md') -Raw | Should -Match ([regex]::Escape('07-governance.md'))
          $cost = Get-Content (Get-RepoPath 'docs/cost.md') -Raw
          $cost | Should -Match '## Phase 7 delta'
          foreach ($driver in 'Defender for Servers Plan 2', 'Defender for Storage', 'malware scanning', 'Defender CSPM', 'confirm on the pricing page') {
              $cost | Should -Match ([regex]::Escape($driver))
          }
      }
  }
  ````

- [ ] **Step 2: Run the tests to confirm they fail**

  Expected: the `Phase 7 documentation` tests fail.

- [ ] **Step 3: Create runbook 07**

  Create `docs/runbooks/07-governance.md`:

  ````markdown
  # 07 - Governance and posture runbook (Defender for Cloud, Azure Policy, exemptions, just-in-time access)

  > Owning module(s): `governance.bicep` (subscription scope, operator-deployed) with `params/governance.bicepparam`, and `modules/governance/defenderPlans.bicep`, `securityContacts.bicep`, `policies.bicep`, `flowLogStorageExemption.bicep`, `legacyWaiver.bicep`, `jitRequesterRole.bicep`, `jitRequesterAssignment.bicep`. Pipeline side (deployed by `deploy.yml`): `modules/virtualMachine.bicep` (JIT policy and NIC NSG) and `modules/spokeNetwork.bicep` (`management` NSG). Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Governance and posture" and "Management jump host" (JIT), §5 Phase 7. Decisions: `ADR-026`, `ADR-027`, `ADR-028`, `ADR-029`.

  ## 1. Purpose and scope

  This runbook turns on Microsoft Defender for Cloud and Azure Policy for the subscription, and puts the jump host behind just-in-time (JIT) access. **An operator deploys `governance.bicep` by hand. `main.bicep` and the pipeline never do**, so the pipeline identity gets no rights over Defender for Cloud, Azure Policy or role definitions (`ADR-026`). One `governance.bicepparam` covers one subscription: when dev and prod share a subscription, it covers both.

  **Defender for Cloud (`ADR-026`), at subscription scope:**

  | Plan (`Microsoft.Security/pricings`) | Tier and settings |
  |---|---|
  | `VirtualMachines` (Defender for Servers) | Standard, sub-plan `P2`, extension `AgentlessVmScanning`. JIT needs this plan. No `MdeDesignatedSubscription` (that is for directly onboarded non-Azure machines) |
  | `AppServices` | Standard |
  | `StorageAccounts` | Standard, sub-plan `DefenderForStorageV2`, `OnUploadMalwareScanning` with a cap of `malwareScanCapGbPerMonth` GB per account per month, and `SensitiveDataDiscovery` |
  | `KeyVaults`, `Arm`, `CloudPosture` (Defender CSPM) | Standard, Azure's default sub-plan and extensions |

  The plans are updated one at a time (`@batchSize(1)`), because parallel pricing updates conflict. The security contact `default` emails the `SECURITY_CONTACT_EMAILS` addresses and the subscription Owners for alerts of severity High. The retired agent auto-provisioning setting is not managed: agentless scanning and the default Defender for Endpoint integration replace it.

  **Azure Policy (`ADR-027`), at subscription scope. Every assignment name starts with `defenstack-`:**

  | Assignment | Policy | Effect | Enforcement |
  |---|---|---|---|
  | `defenstack-mcsb` | Microsoft cloud security benchmark initiative | Its members' defaults (mostly audit) | `Default` |
  | `defenstack-deny-storage-public-network`, `-key-vault-`, `-app-`, `-app-slot-`, `-function-`, `-function-slot-public-network` | "… should disable public network access" (6 built-ins) | `Deny` | `denyEnforcement` |
  | `defenstack-allowed-locations` | Allowed locations: `westus3`, `eastus`, `global` | Deny (fixed) | `denyEnforcement` |
  | `defenstack-allowed-resource-group-locations` | Allowed locations for resource groups: `westus3`, `eastus` | Deny (its default) | `denyEnforcement` |
  | `defenstack-deny-public-ip` | Custom `defenstack-deny-public-ip-except-allowlist`: public IPs whose name is not in the allowlist | `deny` | `denyEnforcement` |
  | `defenstack-audit-diagnostic-settings` | Audit diagnostic setting for selected resource types (firewalls, Bastion, VPN gateways, Front Door, Key Vault, App Service, blob services) | `AuditIfNotExists` | `Default` |

  **Audit-first.** `denyEnforcement` defaults to `DoNotEnforce`: Azure evaluates and reports every deny assignment, but blocks nothing. After a clean compliance review it becomes `Default` (§5.2).

  The public IP allowlist is computed from the naming convention: `pip-afw-…`, `pip-bas-…`, `pip-vpng-…-1` and `-2` for every environment and region in `environments` / `environmentRegions`, 12 names by default. It includes the warm standby's admin-access IPs, so a failover is never blocked.

  **Exemptions (`ADR-027`, `ADR-029`):**

  | Exemption | Scope | Assignment | Category |
  |---|---|---|---|
  | `defenstack-flow-log-storage-public-network` | Each flow-log account `stfl<region><suffix>` | Storage public network access | `Mitigated`, no expiry: a deny-all firewall with the trusted-services bypass replaces disabled public access (`ADR-023`) |
  | `defenstack-legacy-waiver-<assignment>` (9) | The legacy resource group `legacyResourceGroupName` (`defenStack`) | Every deny assignment | `Waiver`, expiring at the end of `legacyWaiverExpiresOn` (UTC), until runbook 01a tears the group down |

  **JIT access (`ADR-028`):**

  | Piece | Where | Deployed by |
  |---|---|---|
  | Custom role **DefenStack JIT Requester** (read and initiate JIT, read the VM and its NIC) | Subscription, assignable there only | `governance.bicep` |
  | Its assignment to the environment's admin group (`adminGroupObjectIds.<env>`) | The environment's **primary** resource group (`rg-defenstack-<env>-wus3`), where the jump host runs | `governance.bicep` |
  | JIT policy `default` (`Microsoft.Security/locations/jitNetworkAccessPolicies`, kind Basic) for the jump host: TCP 22 and 3389, sources the Bastion subnet and the region VPN client pool, at most 3 hours (`PT3H`) | The jump host's resource group and region | The pipeline (`deploy.yml`), with the jump host |
  | NIC NSG `<vm>-nsg`: `deny-ssh-rdp-inbound` (priority 4000, any source) replaces the static allow | The jump host's NIC | The pipeline |
  | `management` NSG: `allow-management-ssh-rdp` (priority 100) from the Bastion subnet and the VPN pool, **unchanged** | The `management` subnet | The pipeline |

  SSH and RDP to the jump host are **closed unless JIT-granted, and reachable when granted**. The subnet NSG keeps the outer bound (only Bastion and VPN clients can ever connect). The NIC NSG denies both ports. A granted request makes Defender for Cloud add a time-bound allow above that deny, on the NSG closest to the VM, so the session passes both NSGs.

  **Not in scope:**
  - `DeployIfNotExists` diagnostic settings and any policy remediation (the spec's DINE item is replaced by an audit, `ADR-027`).
  - Defender for Cloud settings outside the plans and the contact (for example the `WDATP` integration toggle).
  - Resource locks: they came with Phases 1–6 in the workload templates.

  ## 2. Prerequisites

  - **Operator roles, activated through PIM** at subscription scope, for §4 only. `governance.bicep` writes Defender pricings and the security contact, policy definitions, assignments and exemptions, a custom role definition and role assignments. The minimal pair is:
    - **Security Admin**: `Microsoft.Security/*` (pricings, security contact), `Microsoft.Authorization/policyAssignments/*`, `policyDefinitions/*`, `policyExemptions/*` and `Microsoft.Resources/deployments/*`;
    - **User Access Administrator**: `Microsoft.Authorization/roleDefinitions/write` for **DefenStack JIT Requester**, `Microsoft.Authorization/roleAssignments/write` for its assignments, and `*/read` (the flow-log exemptions read their storage accounts).

    If ARM refuses a policy write under that pair, add **Resource Policy Contributor**. **Owner** alone covers everything, and is the fallback when the tenant does not offer the narrower roles as PIM-eligible. Activate: Entra admin center → **Identity Governance** → **Privileged Identity Management** → **My roles** → **Azure resources** → the subscription → **Activate** each role, with a justification naming this runbook. Deactivate them after §4.
  - **Pipeline identity:** unchanged. It already holds `Contributor` on each regional resource group, which includes `Microsoft.Security/locations/jitNetworkAccessPolicies/write`, so `deploy.yml` creates the JIT policy with no new grant (`ADR-028`). Do not re-run the identity script for Phase 7.
  - **Everything governance targets must exist** (§5.3, "the ordering trap"): each regional resource group in `environments` / `environmentRegions` (default `rg-defenstack-dev-wus3`, `rg-defenstack-prod-wus3`, `rg-defenstack-prod-eus`) and its Phase 6 flow-log account `stfl…`; and the legacy resource group `defenStack`, or `legacyResourceGroupName = ''`.
  - **Providers:**

    ```powershell
    foreach ($ns in 'Microsoft.Security','Microsoft.PolicyInsights','Microsoft.Authorization') { az provider register --namespace $ns }
    foreach ($ns in 'Microsoft.Security','Microsoft.PolicyInsights','Microsoft.Authorization') { az provider show -n $ns --query registrationState -o tsv }
    ```

    Expect `Registered` three times.
  - **Admin groups:** the Entra groups from runbook 03 §4 step 1 (`sg-defenstack-<env>-admins`), with PIM-eligible membership (runbook 03 §5.5).
  - **Tools:** Azure CLI 2.90+, Bicep CLI 0.47.16, PowerShell 7 or 5.1. No network path is needed for §4; §5.4 (connecting after a JIT grant) needs the VPN or Bastion from runbook 03.

  ## 3. Parameters

  `governance.bicep`, set in `params/governance.bicepparam`:

  | Name | Default | Prod value | Rationale |
  |---|---|---|---|
  | `securityContactEmails` | none (at least one) | from `SECURITY_CONTACT_EMAILS` | The parameter file reads the environment variable (semicolon-separated); addresses are never committed. Unset gives an empty list, which ARM refuses |
  | `malwareScanCapGbPerMonth` | `5000` | `5000` | GB scanned per storage account per month; `-1` removes the cap. Billed per GB scanned (`docs/cost.md` "Phase 7 delta") |
  | `denyEnforcement` | `DoNotEnforce` | `DoNotEnforce`, then `Default` after §5.2 | Audit-first for every deny assignment (`ADR-027`) |
  | `environments` | `['dev','prod']` | `['dev','prod']` | Environments in this subscription. Their public IPs are allowed, flow-log accounts exempted and admin groups granted JIT requests |
  | `environmentRegions` | `{ dev: ['westus3'], prod: ['westus3','eastus'] }` | same | Regions per environment, primary first. Mirrors the parameter files: dev `deploySecondaryRegion = false`, prod `true` (a test pins it). Every listed stamp must already exist |
  | `adminGroupObjectIds` | `{ dev: '', prod: '' }` | the two admin group object IDs | Must equal `adminGroupObjectId` in `params/dev.bicepparam` and `params/prod.bicepparam` (a test pins it). Empty skips that environment's JIT Requester assignment |
  | `legacyResourceGroupName` | `defenStack` | `defenStack`, then `''` | The legacy group waived from the deny assignments. Set `''` once runbook 01a has deleted it |
  | `legacyWaiverExpiresOn` | none (required) | `2027-03-31` | `yyyy-MM-dd`, end of that day UTC. **`2027-03-31` is a placeholder: confirm it** with the runbook 01a teardown date |

  Pipeline side (`modules/virtualMachine.bicep`, fixed in code): JIT ports `22`, `3389` (TCP), `maxRequestAccessDuration` `PT3H`, sources = `managementSourceCidrs` as `regionStamp.bicep` derives it (Bastion subnet, VPN pool and any extra approved range). NIC deny priority `4000`.

  ## 4. Step-by-step deployment

  Run from the repository root. **Order matters: governance first, then the workload deploy.** The JIT policy needs Defender for Servers, which only `governance.bicep` turns on.

  1. **Activate the operator roles through PIM** (§2, first bullet), then sign in and select the subscription:

     ```powershell
     az login
     az account set --subscription <subscription id>
     az role assignment list --assignee (az ad signed-in-user show --query id -o tsv) --scope /subscriptions/<subscription id> --include-groups --query "[].roleDefinitionName" -o tsv
     ```

     Check: `Security Admin` and `User Access Administrator` (or `Owner`) are listed.

  2. **Register the providers** (§2).

  3. **Check the targets exist** (§5.3):

     ```powershell
     foreach ($rg in 'rg-defenstack-dev-wus3','rg-defenstack-prod-wus3','rg-defenstack-prod-eus','defenStack') { "$rg $(az group exists --name $rg)" }
     az storage account list --query "[?starts_with(name,'stfl')].{name:name, rg:resourceGroup}" -o table
     ```

     Expected: `true` for every group listed in your parameters, and one `stfl…` account per regional group. A missing regional group or account: deploy that workload first, or narrow `environments` / `environmentRegions`. A missing `defenStack`: set `legacyResourceGroupName = ''`.

  4. **Fill in the admin groups** in `params/governance.bicepparam`, from the environment parameter files (runbook 03 §4 step 1), and commit the change through a pull request:

     ```bicep
     param adminGroupObjectIds = {
       dev: '<dev admin group object ID>'
       prod: '<prod admin group object ID>'
     }
     ```

  5. **Set `SECURITY_CONTACT_EMAILS`** in the same PowerShell session, before `what-if` or `create`. Use monitored team mailboxes:

     ```powershell
     $env:SECURITY_CONTACT_EMAILS = 'secops@example.org;cloud-admins@example.org'
     bicep build-params params/governance.bicepparam --stdout | ConvertFrom-Json | ForEach-Object { ($_.parametersJson | ConvertFrom-Json).parameters.securityContactEmails.value }
     ```

     Check: each address is printed on its own line. Empty output means the variable is not set in this session.

  6. **Validate and preview:**

     ```powershell
     az deployment sub validate --location westus3 --name defenstack-governance --template-file governance.bicep --parameters params/governance.bicepparam
     az deployment sub what-if --location westus3 --name defenstack-governance --template-file governance.bicep --parameters params/governance.bicepparam
     ```

     The `using` line already binds the template, so `--template-file` is optional with Azure CLI 2.53+. Check the what-if:
     - Subscription: **create** or **modify** 6 `Microsoft.Security/pricings` (the free tier already exists, so these usually show as modify), `securityContacts/default`, the definition `defenstack-deny-public-ip-except-allowlist`, the 11 `defenstack-*` assignments and the role definition `DefenStack JIT Requester`. Every deny assignment shows `enforcementMode: DoNotEnforce`.
     - `rg-defenstack-<env>-<region>`: **create** `defenstack-flow-log-storage-public-network` on each `stfl…` account; in the primary groups, one role assignment per admin group that is set.
     - `defenStack`: **create** 9 `defenstack-legacy-waiver-*` exemptions.
     - **Stop** on any delete, and on any assignment whose `enforcementMode` is `Default` when you did not intend the §5.2 switch.

  7. **Deploy:**

     ```powershell
     az deployment sub create --location westus3 --name defenstack-governance --template-file governance.bicep --parameters params/governance.bicepparam
     ```

     Expected: `provisioningState` `Succeeded`, and outputs `defenderPlanNames` (6 names), `allowedPublicIpNames` (12 by default) and `jitRequesterRoleDefinitionId`. The plans update one after another, so allow about 10 minutes.

  8. **Deploy the workload** through the pipeline: GitHub → Actions → `deploy` → **Run workflow** → `dev`, then prod (two approvals, `ADR-012`). The jump host's environment (`enableVirtualMachine = true`) gets the JIT policy and the NIC deny. Check the what-if: **modify** `<vm>-nsg` (rule `allow-management-ssh-rdp` removed, `deny-ssh-rdp-inbound` added) and **create** `Microsoft.Security/locations/westus3/jitNetworkAccessPolicies/default`. `<spoke VNet>-management-nsg` must **not** change. From now on, an admin needs a JIT request before every session (§5.4, runbook 03).

  9. **Make the admin groups' memberships PIM-eligible**, if they are not already (runbook 03 §5.5). One activation gives both `Virtual Machine Administrator Login` and **DefenStack JIT Requester**.

  10. **Start the audit week** (§5.2).

  ## 5. Manual and post-deployment steps

  ### 5.1 Defender recommendation handling

  Review once a week, and after every phase deploy: **Defender for Cloud** → **Recommendations**, filtered to this subscription.

  ```powershell
  az security assessment list --query "[?status.code=='Unhealthy'].{recommendation:displayName, resource:resourceDetails.Id, severity:metadata.severity}" -o table
  az security alert list --query "[?status=='Active'].{alert:alertDisplayName, severity:severity, resource:compromisedEntity}" -o table
  ```

  Triage each unhealthy recommendation:
  1. **Fix it in Bicep** when the platform should change: open a PR against the owning module, deploy through the pipeline. Never fix it in the portal, because the next deploy reverts it.
  2. **Accept it with a reason** when the design already mitigates it (for example "Storage accounts should restrict network access" on the `stfl…` accounts, `ADR-023`): add an exemption in Bicep (§5.3) with category `Mitigated` and a description citing the ADR.
  3. **Expected findings, no action:** the jump host's "Management ports should be closed" stays healthy because nothing allows 22/3389 at the NIC; "Management ports should be protected with just-in-time network access control" is healthy once §4 step 8 has run.

  Defender's **Exempt** button writes an exemption on its own assignment of the benchmark, **ASC Default**, not on `defenstack-mcsb`. The benchmark is assigned twice on purpose (`ADR-027`): codify any lasting exemption in Bicep against `defenstack-mcsb` as well, or accept its audit row.

  Security alerts of severity High email `SECURITY_CONTACT_EMAILS` and the subscription Owners. Investigate them in Microsoft Sentinel (the tenant-based Defender for Cloud connector, runbook 06 §5.1).

  ### 5.2 Audit week and the audit-to-deny switch

  1. **Run under `DoNotEnforce` for about a week** after §4 step 7, including at least one workload deploy of each environment, so every resource has been evaluated.
  2. **Review compliance.** Trigger a fresh evaluation, then summarise and list the non-compliant resources:

     ```powershell
     az policy state trigger-scan --no-wait
     az policy state summarize --query "policyAssignments[?contains(policyAssignmentId, 'defenstack-')].{assignment:policyAssignmentId, nonCompliant:results.nonCompliantResources}" -o table
     az policy state list --filter "complianceState eq 'NonCompliant'" --query "[?starts_with(policyAssignmentName, 'defenstack-deny') || starts_with(policyAssignmentName, 'defenstack-allowed')].{assignment:policyAssignmentName, resource:resourceId}" -o table
     ```

     The scan takes up to 30 minutes; `summarize` then reflects it. The first command lists the 11 `defenstack-` assignments with their non-compliant resource counts.
  3. **Every row of the second list blocks the switch** until it is fixed in Bicep, deleted, or exempted (§5.3). Known rows that are **not** blockers:
     - `defenstack-audit-diagnostic-settings` on the `stfl…` accounts' blob services: Phase 6 gives the flow-log accounts no diagnostic setting, so they report non-compliant. Expected; that assignment never blocks.
     - `defenstack-mcsb`: benchmark findings are handled in §5.1, not here.
     - Anything in `defenStack`: it reports **Exempt** while the waiver lasts.
     - Azure-created groups such as `NetworkWatcherRG` or `DefaultResourceGroup-*` outside West US 3 / East US: they **are** blockers for the resource-group locations assignment. Move nothing; exempt the group (§5.3) or delete it if empty.
  4. **Switch.** Change `param denyEnforcement = 'Default'` in `params/governance.bicepparam` and update the Params test "starts audit-first for dev and prod" to expect `Default`, in one PR. Then repeat §4 steps 1, 5, 6 and 7. The what-if shows only `enforcementMode` changing to `Default` on the 9 deny assignments.
  5. **Check:** `az policy assignment list --query "[?starts_with(name,'defenstack-')].{name:name, mode:enforcementMode}" -o table` shows `Default` on all 11.

  A command-line override (`--parameters denyEnforcement=Default`) works for a one-off test, but commit the change: the next deploy from the file would quietly return to `DoNotEnforce`.

  ### 5.3 Exemption procedure and the ordering trap

  **When to exempt:** only a resource whose design meets the policy's intent another way (`Mitigated`), or one that is being retired (`Waiver`, always with `expiresOn`). Every exemption needs a reviewer and an ADR or runbook reference in its description.

  **How:**
  1. Add the exemption in Bicep, following `modules/governance/flowLogStorageExemption.bicep`: an RG-scope module that declares the target `existing` and creates `Microsoft.Authorization/policyExemptions@2026-01-01-preview` scoped to it, with `policyAssignmentId`, `exemptionCategory`, `displayName`, `description` and (for a waiver) `expiresOn`. Call it from `governance.bicep` and add tests.
  2. Deploy governance (§4 steps 1, 5–7).
  3. **Emergency only** (a blocked production change): create it by hand, then codify it within a week:

     ```powershell
     az policy exemption create --name defenstack-temp-<reason> --policy-assignment /subscriptions/<sub>/providers/Microsoft.Authorization/policyAssignments/<assignment> --exemption-category Waiver --expires-on 2026-11-01T00:00:00Z --scope <resource or resource group ID> --description 'Temporary: <ticket>. Codify in governance.bicep (runbook 07 §5.3).'
     ```

  4. Check: `az policy exemption list --query "[].{name:name, category:exemptionCategory, expires:expiresOn}" -o table` (add `--scope <resource group ID>` for resource-group and resource exemptions).

  **The ordering trap.** An exemption, and the JIT Requester role assignment, needs its target to exist when governance deploys. Under `Default` enforcement, a new flow-log account (public network access `Enabled`) is denied before its exemption can exist. So **adding an environment or a region** always follows this sequence:

  1. Set `denyEnforcement = 'DoNotEnforce'` and redeploy governance (§4 steps 5–7).
  2. Deploy the workload for the new environment or region (runbook 01; runbook 06 for its flow logs).
  3. Add the environment to `environments`, or the region to `environmentRegions`, in `params/governance.bicepparam` (and the admin group, for a new environment).
  4. Redeploy governance: it creates the new flow-log exemption, allows the new public IP names and assigns the JIT role.
  5. Set `denyEnforcement = 'Default'` and redeploy governance.

  Turning on the prod warm standby's admin access during failover needs no step: its public IPs are already allowed.

  **The legacy waiver.** It exempts `defenStack` from the 9 deny assignments until `legacyWaiverExpiresOn`. The committed date `2027-03-31` is a **placeholder to confirm** with the platform owner. When runbook 01a has deleted `defenStack`, set `legacyResourceGroupName = ''` and redeploy (the exemptions went with the group). If the teardown slips past the date, extend `legacyWaiverExpiresOn` with a dated reason in runbook 01a, and redeploy before the old date passes.

  ### 5.4 Requesting JIT access to the jump host

  Every SSH or RDP session to the jump host now starts with a JIT request. The jump host runs in the primary region only.

  1. **Activate the admin group membership** in PIM (runbook 03 §5.5). It carries both `Virtual Machine Administrator Login` and **DefenStack JIT Requester**.
  2. **Request access.**
     - **Portal:** **Microsoft Defender for Cloud** → **Workload protections** → **Just-in-time VM access** → **Configured** → tick the jump host → **Request access**. For each port you need (22 Linux, 3389 Windows): **On**, **Allowed source IP**: **IP range** = the Bastion subnet (dev `10.21.0.64/26`, prod `10.1.0.64/26`) to connect through Bastion, or the VPN pool (dev `172.16.210.0/24`, prod `172.16.200.0/24`) to connect over the VPN; **Time range** at most 3 hours; a justification → **Open ports**. The VM's own **Connect** blade no longer offers the request in many regions; use Defender for Cloud, or the VM's **Configuration** → **Just-in-time VM access**.
     - **Azure CLI.** `az security jit-policy` lists and shows policies; request access through the REST API:

       ```powershell
       az security jit-policy list --query "[].{name:name, rg:resourceGroup, location:location}" -o table
       $vmId = az vm list --resource-group rg-defenstack-dev-wus3 --query '[0].id' -o tsv
       $body = @{
         virtualMachines = @(@{ id = $vmId; ports = @(@{ number = 22; duration = 'PT3H'; allowedSourceAddressPrefixes = @('10.21.0.64/26', '172.16.210.0/24') }) })
         justification   = 'Runbook 07 §5.4: <ticket>'
       } | ConvertTo-Json -Depth 6 -Compress
       Set-Content -Path jit-request.json -Value $body -Encoding ascii
       az rest --method post --url "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Security/locations/westus3/jitNetworkAccessPolicies/default/initiate?api-version=2020-01-01" --body '@jit-request.json'
       ```

     Expected: the response lists the port with `status: Initiated` and an `endTimeUtc` about 3 hours ahead.
  3. **Connect** through Bastion or the VPN (runbook 03 §5.2 and §5.3).
  4. The grant ends on its own at `endTimeUtc`. **Any pipeline deploy of that environment also ends it**, because the deploy rewrites the NIC NSG (`ADR-028`). Request again after a deploy.

  ## 6. Validation

  | Check | Command | Expected result |
  |---|---|---|
  | Defender plans | `az security pricing list --query "value[].{plan:name, tier:pricingTier, subPlan:subPlan}" -o table` | `Standard` for `VirtualMachines` (`P2`), `AppServices`, `StorageAccounts` (`DefenderForStorageV2`), `KeyVaults`, `Arm`, `CloudPosture` |
  | Servers extensions | `az security pricing show -n VirtualMachines --query "extensions[].{name:name, on:isEnabled}" -o table` | `AgentlessVmScanning` `True` |
  | Storage malware cap | `az security pricing show -n StorageAccounts --query "extensions[?name=='OnUploadMalwareScanning'].additionalExtensionProperties" -o json` | `CapGBPerMonthPerStorageAccount` = `5000` |
  | Security contact | `az rest --method get --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Security/securityContacts/default?api-version=2023-12-01-preview" --query "properties.{emails:emails, roles:notificationsByRole.roles, sources:notificationsSources}" -o json` | The `SECURITY_CONTACT_EMAILS` addresses, `Owner`, `Alert` at `High` |
  | Assignments | `az policy assignment list --query "[?starts_with(name,'defenstack-')].{name:name, mode:enforcementMode}" -o table` | 11 rows; `DoNotEnforce` on the 9 deny assignments during the audit week, `Default` after §5.2; `defenstack-mcsb` and `defenstack-audit-diagnostic-settings` always `Default` |
  | Public IP allowlist | `az policy assignment show -n defenstack-deny-public-ip --query "parameters.allowedNames.value" -o tsv` | The 12 names (`pip-afw-`, `pip-bas-`, `pip-vpng-…-1`, `-2` for dev-wus3, prod-wus3, prod-eus) |
  | Flow-log exemption | `az policy exemption list --scope <stfl… account ID> --query "[].{name:name, category:exemptionCategory}" -o table` | `defenstack-flow-log-storage-public-network`, `Mitigated` |
  | Legacy waiver | `az policy exemption list --resource-group defenStack --query "[].{name:name, expires:expiresOn}" -o table` | 9 rows, expiry `2027-03-31T23:59:59Z` |
  | Deny works (after §5.2 only) | `az network public-ip create -g rg-defenstack-dev-wus3 -n pip-test-deny --sku Standard` | `RequestDisallowedByPolicy` naming `defenstack-deny-public-ip`, with "Exemptions: runbook 07." If the IP is created instead, delete it (`az network public-ip delete -g rg-defenstack-dev-wus3 -n pip-test-deny`) and check that `denyEnforcement` is `Default` |
  | JIT role | `az role definition list --name "DefenStack JIT Requester" --custom-role-only true --query "[0].permissions[0].actions" -o tsv` | The 7 actions of `modules/governance/jitRequesterRole.bicep` |
  | JIT role assignment | `az role assignment list --scope /subscriptions/<sub>/resourceGroups/rg-defenstack-<env>-wus3 --role "DefenStack JIT Requester" --query "[].principalId" -o tsv` | The environment's admin group |
  | JIT policy | `az security jit-policy show -l westus3 -g rg-defenstack-<env>-wus3 -n default --query "virtualMachines[0].ports[].{port:number, sources:allowedSourceAddressPrefixes, max:maxRequestAccessDuration}" -o json` | `22` and `3389`, the Bastion subnet and VPN pool, `PT3H` |
  | Closed without a grant | `az network nsg rule list -g rg-defenstack-<env>-wus3 --nsg-name <vm>-nsg --query "[?direction=='Inbound'].{name:name, priority:priority, access:access}" -o table`; then over the VPN `Test-NetConnection <vm private IP> -Port 22` | `deny-ssh-rdp-inbound` 4000 `Deny`, `deny-unsolicited-inbound` 4096 (plus any JIT-created `SecurityCenter-JITRule…` deny rules); `TcpTestSucceeded : False` |
  | Reachable with a grant | §5.4, then the same two commands | A `SecurityCenter-JITRule…` `Allow` rule above priority 4000 on `<vm>-nsg`; `TcpTestSucceeded : True`; `az ssh vm --ip <vm private IP>` gives a prompt |
  | Subnet NSG unchanged | `az network nsg rule show -g rg-defenstack-<env>-wus3 --nsg-name vnet-defenstack-<env>-wus3-spoke-management-nsg -n allow-management-ssh-rdp --query "{priority:priority, sources:sourceAddressPrefixes}" -o json` | `100`, the Bastion subnet and VPN pool. Also note whether JIT added rules here (§9, live-only risks) |

  Paste every output into the Phase 7 PR (spec §6 definition of done).

  ## 7. Rollback

  - **Stop blocking at once:** set `denyEnforcement = 'DoNotEnforce'` and redeploy governance (§4 steps 5–7). This is the first move for any deny that blocks a legitimate change; it keeps compliance reporting.
  - **Remove one assignment:** `az policy assignment delete --name <defenstack-…>`, then remove it from `modules/governance/policies.bicep` so the next deploy does not bring it back. Delete its exemptions first (`az policy exemption delete --name <name> --scope <scope>`).
  - **Defender plans:** `az security pricing create -n <plan> --tier Free`. Turning `VirtualMachines` to Free ends JIT: Defender removes the JIT policy's effect, and the jump host is then unreachable (the NIC deny stays). Revert the NIC change first (next bullet) if admins still need access.
  - **JIT on the jump host:** revert the Phase 7 change to `modules/virtualMachine.bicep` and deploy through the pipeline. The static NIC allow returns, and incremental mode leaves the JIT policy resource behind: `az security jit-policy delete -l westus3 -g rg-defenstack-<env>-wus3 -n default`.
  - **JIT role:** delete its assignments (`az role assignment delete --role "DefenStack JIT Requester" --scope <rg ID>`), then the definition (`az role definition delete --name "DefenStack JIT Requester"`).
  - **Security contact:** `az rest --method delete --url "https://management.azure.com/subscriptions/<sub>/providers/Microsoft.Security/securityContacts/default?api-version=2023-12-01-preview"`.
  - Deployments are incremental: removing a resource from the template never deletes it in Azure. Every removal above is a manual command.

  ## 8. Operations

  - **Weekly:** §5.1 recommendations and alerts; `az policy state summarize` for new non-compliance; exemptions close to expiry (`az policy exemption list --query "[?expiresOn!=null].{name:name, expires:expiresOn}"`).
  - **New public IP:** a module that creates a public IP fails the test suite until its name is added to the `publicIpNames` function in `governance.bicep`; deploy governance before the workload that creates it.
  - **New environment or region:** §5.3, the ordering trap.
  - **Admin changes:** PIM eligibility only (runbook 03 §8). The JIT Requester role follows the group.
  - **Malware scanning cap:** raise `malwareScanCapGbPerMonth` only after Defender reports an account hitting the cap; each GB scanned is billed.
  - **Contact changes:** set `SECURITY_CONTACT_EMAILS` and redeploy governance.
  - **JIT grants and deploys:** schedule workload deploys outside admin sessions; a deploy ends every active grant (§5.4 step 4).
  - **Cost drivers** (`docs/cost.md` "Phase 7 delta"): Defender for Servers P2 per server, Defender for Storage per account plus malware scanning per GB, App Service, Key Vault, Resource Manager and CSPM per billable resource. Azure Policy and JIT add no charge.

  ## 9. Troubleshooting

  | Symptom / error text | Cause | Fix |
  |---|---|---|
  | `securityContactEmails` "minimum length" / array length error at validate | `SECURITY_CONTACT_EMAILS` is not set in this session | §4 step 5 |
  | `AuthorizationFailed` on `Microsoft.Security/pricings/write` or `policyAssignments/write` | Security Admin is not active | Activate it in PIM (§2) and retry after a few minutes |
  | `AuthorizationFailed` on `roleDefinitions/write` or `roleAssignments/write` | User Access Administrator is not active | Activate it in PIM, or use Owner |
  | `Another update operation is in progress` on a pricing | A concurrent change to the plans (portal or another deploy) | Wait 5 minutes and re-run; the template already updates one plan at a time |
  | `ResourceGroupNotFound` or `ParentResourceNotFound` on `governance-flow-log-exemption-…`, `governance-jit-requester-…` or `governance-legacy-waiver` | A listed stamp or its flow-log account, or the legacy group, does not exist | §5.3 ordering; narrow `environments` / `environmentRegions`, or set `legacyResourceGroupName = ''` |
  | `RoleDefinitionWithSameNameExists` | Another subscription in the tenant already has a custom role named `DefenStack JIT Requester` (role names are tenant-wide) | See "Live-only risks" |
  | `RequestDisallowedByPolicy` in a workload deploy | `denyEnforcement` is `Default` and the resource breaks a deny assignment | Fix the resource; or, if it is legitimate, §5.3. To unblock a release now: §7 first bullet |
  | Workload deploy fails on `jitNetworkAccessPolicies` | Defender for Servers is not on, or the plan change has not propagated | Deploy governance first (§4 order); re-run the workload deploy after 15 minutes |
  | SSH/RDP to the jump host times out | No active JIT grant, the grant expired, or a deploy ended it | §5.4 |
  | JIT request fails with `AuthorizationFailed` on `initiate/action` | The PIM membership is not active, or the role assignment is missing in that resource group | Activate PIM, sign in again; check the §6 "JIT role assignment" row |
  | JIT request succeeds but the port stays closed | JIT programmed only the subnet NSG, or the request's source is outside the VPN pool / Bastion subnet | §6 "Reachable with a grant"; see "Live-only risks" |

  ### Live-only risks

  These cannot be proved offline. Each is first exercised by the first deployment that uses it; record the outcome in the Phase 7 PR.

  | Risk | How it shows | Fallback |
  |---|---|---|
  | **Preview APIs: policy exemptions and the security contact.** `policyExemptions@2026-01-01-preview` and `securityContacts@2023-12-01-preview` have no GA version (`ADR-029`); the contact's `isEnabled` / `notificationsSources` shape comes from the Bicep types, not a live call | Deploy fails on an exemption or `governance-security-contacts` with an API version or schema error, or §6 "Security contact" shows no `notificationsSources` | **Fallback:** for exemptions, move to the newest preview the template reference lists (`2024-12-01-preview`, then `2022-07-01-preview`) and update the pinned-version tests; or create them by hand (§5.3 step 3) and remove the module. For the contact: set it in the portal (**Defender for Cloud** → **Environment settings** → the subscription → **Email notifications**: the addresses, role **Owner**, severity **High**), and remove the module until the API settles |
  | **Whether "Allowed locations" skips `global`.** The built-in is believed to exempt `global` itself; `global` is listed anyway (harmless) | Front Door, DNS zones or the action group show non-compliant in `defenstack-allowed-locations` during the audit week | **Fallback:** none needed if they do not; if they do, the list already contains `global`, so check the resource's `location` value and add exactly that value |
  | **Effect of the resource-group locations policy.** No `effect` is passed, on the understanding that its default is `Deny` | The audit week shows the assignment with `effect` `Audit`, or a non-West US 3 / East US group is created after §5.2 without a deny | **Fallback:** read `az policy definition show -n e765b5de-1225-4ba3-bd56-1ac6695af988 --query parameters`; if it has an `effect` parameter, pass `effect: 'Deny'` in `modules/governance/policies.bicep` with a test |
  | **JIT rule behaviour after an NSG redeploy, and which NSG JIT edits.** The NIC NSG's rule list is rewritten by every pipeline deploy, which removes JIT's rules; whether Defender also programs the subnet NSG is not documented for a VM with both | §5.4 grant lost after a deploy (expected, `ADR-028`); a grant that never opens the port; `SecurityCenter-JITRule…` rules on `<spoke VNet>-management-nsg` | Re-request after each deploy. If a grant never opens the port: check both NSGs' effective rules (`az network nic list-effective-nsg -g <rg> -n <vm>-nic`). If JIT writes only to the subnet NSG, move `deny-ssh-rdp-inbound` from the NIC NSG to the subnet NSG (priority 4000) and keep the NIC allow-free, then record it in `ADR-028` |
  | **The JIT requester role's action list.** The 7 actions follow Microsoft's least-privilege guidance as researched, not a live test | A requester with an active PIM membership gets `AuthorizationFailed` naming another action, or the portal shows no **Request access** button | **Fallback:** add exactly the action the error names to `roleActions` in `modules/governance/jitRequesterRole.bicep` (and its test), redeploy governance. As a stopgap, assign the built-in **Security Admin** at the jump host's resource group through PIM |
  | **The malware scanning cap property.** `CapGBPerMonthPerStorageAccount` is passed as a string under `additionalExtensionProperties` | §6 "Storage malware cap" shows `10000` or nothing | **Fallback:** set the cap in the portal (Defender for Cloud → Environment settings → Storage → Settings) and open an issue to correct the property name in `modules/governance/defenderPlans.bicep` |
  | **Default sub-plans and extensions.** `KeyVaults`, `Arm` and `CloudPosture` send no sub-plan or extensions, so Azure picks its current default; a subscription already on a legacy sub-plan may keep it | §6 "Defender plans" shows a legacy sub-plan (`PerTransaction`, `PerSubscription`) | **Fallback:** set the current sub-plan explicitly in `defenderPlans.bicep` (`PerKeyVault`, `PerApiCall`) with a test, after confirming the names with `az security pricing show` |
  | **JIT policy creation by the pipeline identity.** RG `Contributor` includes the JIT write, but Defender may also read the subscription's pricing on that call | Workload deploy fails on `jitNetworkAccessPolicies` with `LinkedAuthorizationFailed` or `AuthorizationFailed` naming `Microsoft.Security/pricings/read` | **Fallback:** add only that read action to the subscription custom role in `scripts/New-GitHubDeploymentIdentity.ps1` (and its tests), re-run the identity script (runbook 00b), and record the change in `ADR-028` |
  | **Tenant-wide role name.** `DefenStack JIT Requester` must be unique in the tenant | `RoleDefinitionWithSameNameExists` on a second subscription's governance deploy | **Fallback:** add the subscription's display name to `roleName` in `jitRequesterRole.bicep` for that subscription's copy, and update the test |
  | **Exemption expiry in the past.** ARM may refuse to create or update an exemption whose `expiresOn` has passed | Governance redeploy fails on `governance-legacy-waiver` after `legacyWaiverExpiresOn` | **Fallback:** extend the date (§5.3) or set `legacyResourceGroupName = ''` |
  | **Benchmark members that need an identity.** `defenstack-mcsb` has no managed identity; no member is expected to need one | Assignment creation fails with a message about a missing identity for `DeployIfNotExists`/`Modify` | **Fallback:** add a system-assigned identity and a location to that one assignment in `policies.bicep`, with no remediation tasks, and record it in `ADR-027` |
  ````

- [ ] **Step 4: Create the ADRs and close ADR-014**

  Create `docs/decisions/ADR-026-operator-deployed-governance-entry-point.md`:

  ```markdown
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
  ```

  Create `docs/decisions/ADR-027-audit-first-policy-enforcement.md`:

  ```markdown
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
  ```

  Create `docs/decisions/ADR-028-jit-access-and-nsg-ownership.md`:

  ```markdown
  # ADR-028: Just-in-time access to the jump host: the NIC NSG denies, JIT opens, the subnet NSG bounds

  ## Context
  `ADR-014` deferred Defender just-in-time (JIT) VM access to Phase 7, which turns on Defender for Servers Plan 2. JIT works by adding time-bound allow rules to the NSGs in front of a VM. The jump host has two NSGs: the `management` subnet NSG and its own NIC NSG. Until Phase 7, both allowed SSH (22) and RDP (3389) at priority 100 from the Bastion subnet and the VPN client pool, so the ports were open to those sources all the time. Bicep owns every NSG rule list: each pipeline deploy rewrites it, which removes any rule JIT added. Microsoft does not document which NSG JIT edits when a VM has both.

  ## Decision
  - **NIC NSG (`<vm>-nsg`, closest to the VM): no allow for 22/3389.** An explicit `deny-ssh-rdp-inbound` (priority 4000, any source, ports 22 and 3389) replaces the static allow. Priorities 100–3999 stay free, so JIT's allow rules land above the deny. `deny-unsolicited-inbound` (4096) is unchanged.
  - **Subnet NSG (`<spoke>-management-nsg`): unchanged.** `allow-management-ssh-rdp` (priority 100) still admits only the Bastion subnet and the VPN pool, plus any ADR-approved extra. It is the outer bound on who can ever connect, and it lets a JIT grant on the NIC through.
  - Result: **closed unless JIT-granted, and reachable when granted.** Without a grant, the NIC deny drops the session. With one, the session passes the subnet allow and JIT's NIC allow. If Defender also programs the subnet NSG, its own deny sits below the existing allow, so nothing changes. The explicit deny keeps the ports closed even after a deploy has removed JIT's own deny rules.
  - **The JIT policy** (`Microsoft.Security/locations/jitNetworkAccessPolicies@2020-01-01`, name `default`, kind Basic) is deployed by the pipeline with the jump host (`modules/virtualMachine.bicep`, primary region only): TCP 22 and 3389, allowed sources the same list as the subnet NSG (the Bastion subnet and VPN pool), at most 3 hours. The pipeline identity's resource-group `Contributor` covers it, and the identity script is unchanged.
  - **Who may request:** a custom role, **DefenStack JIT Requester** (read and initiate JIT policies, read the VM and its NIC). `governance.bicep` defines it at subscription scope and assigns it to each environment's admin group at that environment's primary resource group, where the jump host runs. Assignment names are deterministic GUIDs. The group's membership is PIM-eligible, so one activation gives both the request right and `Virtual Machine Administrator Login` (runbook 03 §5.5).
  - Rejected: leaving the NIC NSG without inline rules for JIT to own, as `ADR-014` suggested. Whether a PUT that omits `securityRules` keeps the existing rules is not documented, and the closed state would then depend on JIT's own deny rules surviving.

  ## Consequences
  - **Every pipeline deploy of an environment rewrites the NIC NSG and ends any active JIT grant in it.** Admins request again after a deploy, and deploys are scheduled outside admin sessions. `deploy.yml` ignores governance-only commits, so those never cause it (`ADR-026`).
  - Order matters: governance (Defender for Servers) deploys before the workload that creates the JIT policy (runbook 07 §4).
  - Every admin session needs a JIT request first (runbook 03; runbook 07 §5.4). The VM **Connect** blade no longer offers the request in many regions, so requests go through Defender for Cloud or the REST API.
  - Live-only (runbook 07 §9): which NSG JIT programs, the role's exact action list, whether the pipeline's JIT write also needs a subscription-level read, and the tenant-wide uniqueness of the role name. If JIT programs only the subnet NSG, the fallback is to move the deny there.

  ## Revisit when
  Microsoft documents JIT behaviour with both NIC and subnet NSGs, or the jump host is deployed in a secondary region too (assign the role there as well).
  ```

  Create `docs/decisions/ADR-029-preview-apis-for-governance.md`:

  ```markdown
  # ADR-029: Governance uses preview APIs for policy exemptions and the security contact

  ## Context
  The README's API version policy asks for the newest stable API version, and `ADR-025` records the one earlier exception (the subscription Activity Log setting). Two Phase 7 resource types have no GA API version at all: `Microsoft.Authorization/policyExemptions` (previews only, up to `2026-01-01-preview`) and `Microsoft.Security/securityContacts` (previews only, up to `2023-12-01-preview`). The spec requires both: exemptions for the flow-log accounts and the legacy group, and a security contact.

  ## Decision
  - `modules/governance/flowLogStorageExemption.bicep` and `modules/governance/legacyWaiver.bicep` pin `Microsoft.Authorization/policyExemptions@2026-01-01-preview`, the newest version in the Bicep types.
  - `modules/governance/securityContacts.bicep` pins `Microsoft.Security/securityContacts@2023-12-01-preview`, the newest version. In it, `notificationsSources` replaces `alertNotifications`, and `emails` is one semicolon-separated string.
  - Everything else in governance uses GA versions: `pricings@2024-01-01`, `policyAssignments@2025-11-01`, `policyDefinitions@2025-11-01`, `roleDefinitions@2022-04-01` and `roleAssignments@2022-04-01`, plus `jitNetworkAccessPolicies@2020-01-01` on the pipeline side.
  - Tests pin each version, so a change is deliberate. No PSRule or linter suppression is needed.

  ## Consequences
  - A preview version can change shape or be retired with notice. The fallbacks are in runbook 07 §9: move exemptions to another listed preview, or create them with `az policy exemption create`; set the contact in the portal and remove the module.
  - The repository now has three preview pins (`ADR-025` and these two), each recorded with a fallback.

  ## Revisit when
  Either type gets a GA API version. Move to it then and update the pinned-version tests.
  ```

  Append to `docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md`, after one blank line:

  ```markdown
  ## Outcome
  Superseded by `ADR-028` (Phase 7): the NIC NSG denies SSH/RDP with an explicit rule, the JIT policy opens it on request, and the subnet NSG keeps its allow for the Bastion subnet and VPN pool. The "NIC NSG without inline rules" option above was rejected there.
  ```

- [ ] **Step 5: Update the existing documents**

  Each edit below is an exact find/replace, and the find text occurs once in the file. Apply the edits for a file in the order given. If a find text is not found, stop and report. Change nothing outside the find text. These files contain non-ASCII characters (—, →, ↔, §), so read and write them as UTF-8. `docs/cost.md` names billing units only: it quotes no prices.

  **`docs/architecture/overview.md`, edit 1 of 6.** Find:

  ```markdown
  # Architecture overview: Phase 1-6 (subscription-scope, multi-region, Premium firewall, admin access, public ingress, app and data resilience, private monitoring and detection)

  > Owning files: `main.bicep`, `modules/global.bicep`, `modules/regionStamp.bicep`, `modules/privateDnsZoneLinks.bicep`, `modules/types.bicep`, `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`, `modules/hubNetwork.bicep`, `modules/bastion.bicep`, `modules/vpnGateway.bicep`, `modules/frontDoor.bicep`, `modules/monitorPrivateLinkScope.bicep`, `modules/hubPeering.bicep`, `modules/flowLogs.bicep`, `modules/metricAlerts.bicep`. Spec: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §1, §3, §5.

  ```

  Replace with:

  ```markdown
  # Architecture overview: Phase 1-7 (subscription-scope, multi-region, Premium firewall, admin access, public ingress, app and data resilience, private monitoring and detection, governance)

  > Owning files: `main.bicep`, `modules/global.bicep`, `modules/regionStamp.bicep`, `modules/privateDnsZoneLinks.bicep`, `modules/types.bicep`, `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`, `modules/hubNetwork.bicep`, `modules/bastion.bicep`, `modules/vpnGateway.bicep`, `modules/frontDoor.bicep`, `modules/monitorPrivateLinkScope.bicep`, `modules/hubPeering.bicep`, `modules/flowLogs.bicep`, `modules/metricAlerts.bicep`, `governance.bicep` (operator-deployed, Phase 7). Spec: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §1, §3, §5.

  ```

  **`docs/architecture/overview.md`, edit 2 of 6.** Find:

  ```markdown

  What later phases add (not present after Phase 6):

  ```

  Replace with:

  ```markdown

  **Phase 7** added governance and posture, from a second entry point, `governance.bicep`, that an operator deploys per subscription; the pipeline never does (`ADR-026`):
  - Microsoft Defender for Cloud: Servers Plan 2 with agentless scanning, App Service, Storage (on-upload malware scanning with a monthly cap, sensitive data discovery), Key Vault, Resource Manager and Defender CSPM, plus a security contact (`ADR-026`).
  - Azure Policy at subscription scope: the Microsoft cloud security benchmark, deny public network access on Storage, Key Vault and App Service / Functions, allowed locations, a public IP name allowlist, and an audit of diagnostic settings. Deny assignments go live audit-first (`DoNotEnforce`, then `Default`), with exemptions for the flow-log accounts and a dated waiver for the legacy group (`ADR-027`, `ADR-029`).
  - Just-in-time access to the jump host: its NIC NSG denies SSH/RDP until Defender for Cloud grants a request, and the admin groups hold the **DefenStack JIT Requester** role (`ADR-028`).

  See [runbook 07](../runbooks/07-governance.md).

  What later phases add (not present after Phase 7):

  ```

  **`docs/architecture/overview.md`, edit 3 of 6.** Find:

  ```markdown
  |---|---|
  | 7 | Microsoft Defender for Cloud plans, Azure Policy assignments |
  | 8 | Recovery Services vaults and the backup job alert, DR traffic over the hub-to-hub peering (Phase 6 carries only monitoring), the regional-failover runbook |
  ```

  Replace with:

  ```markdown
  |---|---|
  | 8 | Recovery Services vaults and the backup job alert, DR traffic over the hub-to-hub peering (Phase 6 carries only monitoring), the regional-failover runbook |
  ```

  **`docs/architecture/overview.md`, edit 4 of 6.** Find:

  ```markdown

  - The `management` NSG and the jump host NIC NSG allow SSH/RDP only from `AzureBastionSubnet` and the region's VPN client pool (plus any `managementSourceCidrs`).
  - The `management` route table sends replies back through the firewall (`0.0.0.0/0`, BGP propagation off), so the VPN-to-jump-host flow is symmetric.
  - VPN clients use the hub DNS server, the firewall DNS proxy, so `privatelink.*` names resolve to private endpoint IPs.
  - Admin rights on the jump host come from the `Virtual Machine Administrator Login` role held by a PIM-eligible Entra group (`adminGroupObjectId`). Defender JIT is deferred to Phase 7 (`ADR-014`).

  ```

  Replace with:

  ```markdown

  - The `management` NSG allows SSH/RDP only from `AzureBastionSubnet` and the region's VPN client pool (plus any `managementSourceCidrs`). The jump host NIC NSG denies both ports (`deny-ssh-rdp-inbound`, priority 4000) until a just-in-time request opens them for up to 3 hours from those sources (Phase 7, `ADR-028`).
  - The `management` route table sends replies back through the firewall (`0.0.0.0/0`, BGP propagation off), so the VPN-to-jump-host flow is symmetric.
  - VPN clients use the hub DNS server, the firewall DNS proxy, so `privatelink.*` names resolve to private endpoint IPs.
  - Admin rights on the jump host come from the `Virtual Machine Administrator Login` role held by a PIM-eligible Entra group (`adminGroupObjectId`). The same group holds **DefenStack JIT Requester**, so one PIM activation lets an admin request just-in-time access (`ADR-028`, superseding `ADR-014`).

  ```

  **`docs/architecture/overview.md`, edit 5 of 6.** Find:

  ```markdown

  The subscription also holds the diagnostic setting `activity-log-defenstack-<env>` (`ADR-025`).

  ```

  Replace with:

  ```markdown

  The subscription also holds the diagnostic setting `activity-log-defenstack-<env>` (`ADR-025`) and, from Phase 7, the governance resources shared by every environment in it: the six Defender plans, the security contact `default`, the 11 `defenstack-*` policy assignments and the definition `defenstack-deny-public-ip-except-allowlist`, and the custom role **DefenStack JIT Requester**. Each regional resource group holds its flow-log account's policy exemption; each primary one, the JIT Requester assignment and, with the jump host, the JIT policy `default`. The legacy `defenStack` group holds nine dated waivers (`ADR-027`).

  ```

  **`docs/architecture/overview.md`, edit 6 of 6.** Find:

  ```markdown
  - [ADR-025: The subscription Activity Log diagnostic setting uses the preview API 2021-05-01-preview](../decisions/ADR-025-preview-api-subscription-diagnostic-setting.md)

  ```

  Replace with:

  ```markdown
  - [ADR-025: The subscription Activity Log diagnostic setting uses the preview API 2021-05-01-preview](../decisions/ADR-025-preview-api-subscription-diagnostic-setting.md)
  - [ADR-026: Governance is a separate, operator-deployed entry point](../decisions/ADR-026-operator-deployed-governance-entry-point.md)
  - [ADR-027: Azure Policy goes live audit-first through enforcementMode, with exemptions instead of notScopes](../decisions/ADR-027-audit-first-policy-enforcement.md)
  - [ADR-028: Just-in-time access to the jump host: the NIC NSG denies, JIT opens, the subnet NSG bounds](../decisions/ADR-028-jit-access-and-nsg-ownership.md)
  - [ADR-029: Governance uses preview APIs for policy exemptions and the security contact](../decisions/ADR-029-preview-apis-for-governance.md)

  ```

  **`docs/cost.md`, edit 1 of 2.** Find:

  ```markdown

  ## Dominant future cost drivers
  ```

  Replace with:

  ```markdown

  ## Phase 7 delta
  Phase 7 turns on Microsoft Defender for Cloud plans and Azure Policy for the
  whole subscription, from `governance.bicep` (runbook 07). The plans bill per
  subscription, so when dev and prod share one, every row below covers both
  environments together. As with every phase, **fill in the actual dollar
  estimate from the Pricing Calculator; do not invent prices.** Each row names
  the billing unit; read the current rate on the Defender for Cloud pricing page
  (https://azure.microsoft.com/pricing/details/defender-for-cloud/), marked
  **confirm on the pricing page** below.

  | Environment | Cost driver | What changed / why it costs more |
  |---|---|---|
  | Subscription | Defender for Servers Plan 2 | Per server per month, metered per second while the server runs: the jump host when `enableVirtualMachine = true` (**confirm on the pricing page**). Includes 500 MB per server per day of free Log Analytics ingestion for some security tables, which offsets part of Sentinel's ingestion of `SecurityEvent` and similar tables |
  | Subscription | Defender for Storage (`DefenderForStorageV2`) | Per storage account per month (**confirm on the pricing page**) for every account in the subscription: each region's app account and flow-log account, plus the legacy group's |
  | Subscription | On-upload malware scanning | Per GB scanned (**confirm on the pricing page**), capped at `malwareScanCapGbPerMonth` (5000 GB) per account per month. Flow-log blobs are scanned on upload too: measure the flow-log volume before raising the cap |
  | Subscription | Defender for App Service | Per App Service instance (plan instance) per month: prod West US 3 runs 3 instances, the warm standby and dev 1 each (**confirm on the pricing page**) |
  | Subscription | Defender for Key Vault | Per vault or per transaction, depending on the sub-plan Azure applies (runbook 07 §9) (**confirm on the pricing page**) |
  | Subscription | Defender for Resource Manager | Per subscription or per API call, depending on the sub-plan (**confirm on the pricing page**) |
  | Subscription | Defender CSPM | Per billable resource per month: servers, storage accounts and databases, not network or most PaaS resources (**confirm on the pricing page**) |
  | Subscription | Azure Policy, exemptions, the custom role, JIT | No charge. JIT is included in Defender for Servers |
  | Both | Sentinel ingestion of Defender alerts | `SecurityAlert` rows from the tenant-based Defender for Cloud connector (runbook 06 §5.1); small |

  **Estimate:** fill in from the Pricing Calculator (Microsoft Defender for
  Cloud: Servers Plan 2 × jump hosts, Storage × accounts plus malware scanning
  GB, App Service × instances, Key Vault, Resource Manager, CSPM × billable
  resources). Measure after a month with Cost Analysis filtered to the service
  name "Microsoft Defender for Cloud" at subscription scope; Defender charges do
  not appear under the environment resource groups.

  ## Dominant future cost drivers
  ```

  **`docs/cost.md`, edit 2 of 2.** Find:

  ```markdown
  The VPN gateway and Azure Bastion arrived in Phase 3, and Azure Front Door
  Premium in Phase 4, and Microsoft Sentinel in Phase 6 (see their deltas):
  - Microsoft Sentinel ingestion
  ```

  Replace with:

  ```markdown
  The VPN gateway and Azure Bastion arrived in Phase 3, and Azure Front Door
  Premium in Phase 4, Microsoft Sentinel in Phase 6, and the Microsoft Defender plans in Phase 7 (see their deltas):
  - Microsoft Sentinel ingestion
  ```

  **`docs/runbooks/00b-configure-pipeline-credentials.md`, edit 1 of 1.** Find:

  ```markdown

  ### 1a. Plan/apply split: why dev gets a `-plan` environment and prod does not
  ```

  Replace with:

  ```markdown

  **The pipeline does not deploy governance (Phase 7, `ADR-026`).** `governance.bicep` (Defender for Cloud plans, the security contact, Azure Policy and its exemptions, the DefenStack JIT Requester role) is deployed by an operator with PIM-activated roles (runbook 07). The pipeline identity gets no rights over Defender for Cloud, Azure Policy or role definitions, and Phase 7 needs no change to the identity script. `deploy.yml`'s `push` path filter excludes the governance-only paths `modules/governance/**` and `params/governance.bicepparam`, so merging a governance-only change does not start a workload deploy (which would also end active JIT grants on the jump host, `ADR-028`). A commit that touches `governance.bicep` together with workload files still deploys the workload, never governance. The only Phase 7 resource the pipeline creates is the jump host's JIT policy, which its resource-group `Contributor` already covers.

  ### 1a. Plan/apply split: why dev gets a `-plan` environment and prod does not
  ```

  **`docs/runbooks/03-admin-access.md`, edit 1 of 7.** Find:

  ```markdown
  - An outbound SSH/RDP deny (`deny-ssh-rdp-outbound`, priority 4000) on every spoke NSG and the jump host NIC NSG. No spoke host can open SSH/RDP to another host (PSRule `Azure.NSG.LateralTraversal`).
  - Admin sources are derived: the `management` NSG and NIC NSG allow SSH/RDP from `AzureBastionSubnet` and the region VPN client pool, plus any extra `managementSourceCidrs`. The `private-endpoints` NSG allows the VPN client pool on 443.

  ```

  Replace with:

  ```markdown
  - An outbound SSH/RDP deny (`deny-ssh-rdp-outbound`, priority 4000) on every spoke NSG and the jump host NIC NSG. No spoke host can open SSH/RDP to another host (PSRule `Azure.NSG.LateralTraversal`).
  - Admin sources are derived: the `management` NSG allows SSH/RDP from `AzureBastionSubnet` and the region VPN client pool, plus any extra `managementSourceCidrs`. The `private-endpoints` NSG allows the VPN client pool on 443.
  - **From Phase 7, the jump host's NIC NSG denies SSH/RDP (`deny-ssh-rdp-inbound`, priority 4000) until a Defender just-in-time (JIT) request is granted** (`ADR-028`). The JIT policy allows requests from the same sources, for at most 3 hours. **Every admin session now starts with a JIT request** (runbook 07 §5.4), and every pipeline deploy ends active grants.

  ```

  **`docs/runbooks/03-admin-access.md`, edit 2 of 7.** Find:

  ```markdown

  - **Defender just-in-time VM access.** It is deferred to Phase 7, which enables the Defender for Servers Plan 2 it requires (`ADR-014`).
  - **PIM for the admin group.** It is tenant configuration, not Bicep, and is documented in §5.5.
  ```

  Replace with:

  ```markdown

  - **Defender just-in-time VM access policy and its requester role.** Phase 7 adds them (runbook 07, `ADR-028`, which supersedes `ADR-014`); this runbook only adds the request step before connecting (§5.2, §5.3).
  - **PIM for the admin group.** It is tenant configuration, not Bicep, and is documented in §5.5.
  ```

  **`docs/runbooks/03-admin-access.md`, edit 3 of 7.** Find:

  ```markdown

  - **Portal:** open the VM → **Connect** → **Bastion**. Choose **Microsoft Entra ID** authentication (Linux; Windows needs the native client below).
  ```

  Replace with:

  ```markdown

  **Admin access now needs a JIT request first (Phase 7).** Activate your admin group membership in PIM (§5.5), then request access to the jump host in **Defender for Cloud** → **Just-in-time VM access**, with the Bastion subnet as the source (dev `10.21.0.64/26`, prod `10.1.0.64/26`), for at most 3 hours (runbook 07 §5.4). Without a grant, the connection times out at the NIC NSG. A pipeline deploy ends the grant; request again.

  - **Portal:** open the VM → **Connect** → **Bastion**. Choose **Microsoft Entra ID** authentication (Linux; Windows needs the native client below).
  ```

  **`docs/runbooks/03-admin-access.md`, edit 4 of 7.** Find:

  ```markdown

  1. Connect the Azure VPN Client (§5.1).
  2. Linux jump host (Entra ID; `az ssh` fetches a short-lived certificate):
  ```

  Replace with:

  ```markdown

  1. Connect the Azure VPN Client (§5.1), then request JIT access to the jump host with the VPN client pool as the source (dev `172.16.210.0/24`, prod `172.16.200.0/24`), as in §5.2 and runbook 07 §5.4. Private endpoints (step 4) need no JIT request.
  2. Linux jump host (Entra ID; `az ssh` fetches a short-lived certificate):
  ```

  **`docs/runbooks/03-admin-access.md`, edit 5 of 7.** Find:

  ```markdown
  4. To also grant `Reader` on the region resource group (for Bastion), add an **eligible** Azure role assignment on `rg-defenstack-<env>-<region>` for the group. Resource-group RBAC outside the template is intentionally not managed by Bicep.
  5. Admins activate before connecting: **My roles** → **Groups** → **Activate**. Tokens pick up the new membership at the next sign-in, so reconnect the VPN after activating.

  ```

  Replace with:

  ```markdown
  4. To also grant `Reader` on the region resource group (for Bastion), add an **eligible** Azure role assignment on `rg-defenstack-<env>-<region>` for the group. Resource-group RBAC outside the template is intentionally not managed by Bicep.
  5. From Phase 7 the group also holds **DefenStack JIT Requester** at the primary resource group (runbook 07), so the same activation lets the admin request JIT access.
  6. Admins activate before connecting: **My roles** → **Groups** → **Activate**. Tokens pick up the new membership at the next sign-in, so reconnect the VPN after activating.

  ```

  **`docs/runbooks/03-admin-access.md`, edit 6 of 7.** Find:

  ```markdown

  Run everything from the repository root in PowerShell. VPN rows need the Azure VPN Client connected.

  ```

  Replace with:

  ```markdown

  Run everything from the repository root in PowerShell. VPN rows need the Azure VPN Client connected. From Phase 7, rows that open SSH or RDP to the jump host also need an active JIT grant for that source (§5.2); runbook 07 §6 validates the JIT policy itself.

  ```

  **`docs/runbooks/03-admin-access.md`, edit 7 of 7.** Find:

  ```markdown
  | `az ssh vm` / Bastion Entra login: `Permission denied` or `not authorized` | The user lacks `Virtual Machine Administrator Login` (PIM not activated, or `adminGroupObjectId` empty), or the extension failed | Activate PIM; check the §6 role and extension rows. Extension failed on Linux: `packages.microsoft.com` is blocked, so check `AZFWApplicationRule` for denies from the `management` subnet |
  | SSH over the VPN times out, but works over Bastion | The firewall is denying (`AZFWNetworkRule` shows `Deny`), or the client is outside the pool | Check the client IP is in `172.16.210.0/24`; check the `admin-access` group exists on the policy (`az network firewall policy rule-collection-group list --policy-name afwp-defenstack-dev-wus3 -g $rg -o table`) |
  ```

  Replace with:

  ```markdown
  | `az ssh vm` / Bastion Entra login: `Permission denied` or `not authorized` | The user lacks `Virtual Machine Administrator Login` (PIM not activated, or `adminGroupObjectId` empty), or the extension failed | Activate PIM; check the §6 role and extension rows. Extension failed on Linux: `packages.microsoft.com` is blocked, so check `AZFWApplicationRule` for denies from the `management` subnet |
  | SSH/RDP to the jump host times out over both Bastion and the VPN (Phase 7 on) | No active JIT grant: never requested, expired, or ended by a pipeline deploy | Request access (§5.2, runbook 07 §5.4). A grant for the wrong source (Bastion subnet versus VPN pool) only opens that path |
  | SSH over the VPN times out, but works over Bastion | The firewall is denying (`AZFWNetworkRule` shows `Deny`), or the client is outside the pool | Check the client IP is in `172.16.210.0/24`; check the `admin-access` group exists on the policy (`az network firewall policy rule-collection-group list --policy-name afwp-defenstack-dev-wus3 -g $rg -o table`) |
  ```

  **`docs/runbooks/06-monitoring-and-sentinel.md`, edit 1 of 4.** Find:

  ```markdown
  - The identity `id-flowlogs-defenstack-<env>-<region>` holds Storage Blob Data Contributor on that account only.
  - Flow logs `<vnet>-flowlog` for the hub and spoke, under `NetworkWatcher_<region>` in `NetworkWatcherRG`: 90-day retention, Traffic Analytics to the workspace every 10 minutes.
  ```

  Replace with:

  ```markdown
  - The identity `id-flowlogs-defenstack-<env>-<region>` holds Storage Blob Data Contributor on that account only.
  - **Phase 7 exemption:** governance (runbook 07) exempts each `stfl…` account from the Storage public network access assignment (`defenstack-flow-log-storage-public-network`, `Mitigated`, citing `ADR-023`). The account must exist before governance deploys. Its blob service has no diagnostic setting, so it reports non-compliant in `defenstack-audit-diagnostic-settings`; that is expected.
  - Flow logs `<vnet>-flowlog` for the hub and spoke, under `NetworkWatcher_<region>` in `NetworkWatcherRG`: 90-day retention, Traffic Analytics to the workspace every 10 minutes.
  ```

  **`docs/runbooks/06-monitoring-and-sentinel.md`, edit 2 of 4.** Find:

  ```markdown
  **Not in scope:**
  - Defender for Cloud plans and Azure Policy (Phase 7).
  - Backup, the backup job alert, DR traffic over the peering, and the failover runbook (Phase 8).
  ```

  Replace with:

  ```markdown
  **Not in scope:**
  - Defender for Cloud plans and Azure Policy: Phase 7, deployed by an operator from `governance.bicep` (runbook 07).
  - Backup, the backup job alert, DR traffic over the peering, and the failover runbook (Phase 8).
  ```

  **`docs/runbooks/06-monitoring-and-sentinel.md`, edit 3 of 4.** Find:

  ```markdown
  3. **Microsoft Entra ID connector** (tenant administrator: Security Administrator or Global Administrator): **Data connectors** → **Microsoft Entra ID** → **Open connector page** → tick **Sign-In Logs**, **Audit Logs**, **Non-Interactive User Sign-In Log**, **Service Principal Sign-In Logs**, **Managed Identity Sign-In Logs** and **Provisioning Logs** → **Apply Changes**. This creates a tenant diagnostic setting in Entra ID; it is not managed by Bicep. Sign-in logs need an Entra ID P1 or P2 licence.
  4. **Tenant-based Microsoft Defender for Cloud connector:** **Data connectors** → **Tenant-based Microsoft Defender for Cloud** → **Open connector page** → **Connect**. It covers every subscription in the tenant, so no per-subscription connector is needed. The Defender plans themselves arrive in Phase 7; until then, only free-tier recommendations flow.
  5. **Check:** **Data connectors** shows **Connected** for Azure Activity, Azure Firewall, Azure Key Vault, Azure WAF, Microsoft Entra ID and Defender for Cloud after data arrives (up to an hour).
  ```

  Replace with:

  ```markdown
  3. **Microsoft Entra ID connector** (tenant administrator: Security Administrator or Global Administrator): **Data connectors** → **Microsoft Entra ID** → **Open connector page** → tick **Sign-In Logs**, **Audit Logs**, **Non-Interactive User Sign-In Log**, **Service Principal Sign-In Logs**, **Managed Identity Sign-In Logs** and **Provisioning Logs** → **Apply Changes**. This creates a tenant diagnostic setting in Entra ID; it is not managed by Bicep. Sign-in logs need an Entra ID P1 or P2 licence.
  4. **Tenant-based Microsoft Defender for Cloud connector:** **Data connectors** → **Tenant-based Microsoft Defender for Cloud** → **Open connector page** → **Connect**. It covers every subscription in the tenant, so no per-subscription connector is needed. The Defender plans arrive with Phase 7 governance (runbook 07); before it is deployed, only free-tier recommendations flow.
  5. **Check:** **Data connectors** shows **Connected** for Azure Activity, Azure Firewall, Azure Key Vault, Azure WAF, Microsoft Entra ID and Defender for Cloud after data arrives (up to an hour).
  ```

  **`docs/runbooks/06-monitoring-and-sentinel.md`, edit 4 of 4.** Find:

  ```markdown
  |---|---|---|
  | **Flow-log storage: confirm writes succeed through the trusted services exception.** The account already uses the fallback design: `publicNetworkAccess: 'Enabled'`, firewall default `Deny`, the `AzureServices` bypass and no IP or VNet rules (fully `Disabled` would likely ignore the exception, `ADR-023`). Confirm that Network Watcher's writes with the user-assigned identity succeed. Phase 7's "deny public network access on Storage" policy will need an exemption for the `stfl*` accounts | 403s in the flow-log account's activity log; no `insights-logs-flowlogflowevent` container after 30 minutes (§6 "Flow-log blobs") | **Fallback:** check the identity's Storage Blob Data Contributor assignment and the `AzureServices` bypass, re-run the deploy, then open a Microsoft case. Do not add IP or VNet rules or re-enable shared key; record the outcome in `ADR-023` |
  | **Traffic Analytics into a workspace with `PrivateOnly` ingestion.** Microsoft does not document whether the Traffic Analytics pipeline honours AMPLS-only ingestion | `NTANetAnalytics` stays empty after 30 minutes while the flow-log blobs grow | **Fallback:** keep the flow logs in storage, set Traffic Analytics off (`flowAnalyticsConfiguration` disabled in `modules/flowLogs.bicep`) and open a Microsoft case. Do not reopen public ingestion on the workspace without a new ADR (`ADR-023`) |
  ```

  Replace with:

  ```markdown
  |---|---|---|
  | **Flow-log storage: confirm writes succeed through the trusted services exception.** The account already uses the fallback design: `publicNetworkAccess: 'Enabled'`, firewall default `Deny`, the `AzureServices` bypass and no IP or VNet rules (fully `Disabled` would likely ignore the exception, `ADR-023`). Confirm that Network Watcher's writes with the user-assigned identity succeed. Phase 7 governance exempts the `stfl*` accounts from its "deny public network access on Storage" assignment: `defenstack-flow-log-storage-public-network` on each account, category `Mitigated` (runbook 07 §5.3) | 403s in the flow-log account's activity log; no `insights-logs-flowlogflowevent` container after 30 minutes (§6 "Flow-log blobs") | **Fallback:** check the identity's Storage Blob Data Contributor assignment and the `AzureServices` bypass, re-run the deploy, then open a Microsoft case. Do not add IP or VNet rules or re-enable shared key; record the outcome in `ADR-023` |
  | **Traffic Analytics into a workspace with `PrivateOnly` ingestion.** Microsoft does not document whether the Traffic Analytics pipeline honours AMPLS-only ingestion | `NTANetAnalytics` stays empty after 30 minutes while the flow-log blobs grow | **Fallback:** keep the flow logs in storage, set Traffic Analytics off (`flowAnalyticsConfiguration` disabled in `modules/flowLogs.bicep`) and open a Microsoft case. Do not reopen public ingestion on the workspace without a new ADR (`ADR-023`) |
  ```

  **`README.md`, edit 1 of 4.** Find:

  ```markdown
  - Architecture: `docs/architecture/overview.md` - topology, traffic flows, address plan, naming convention, and resource inventory
  - Runbooks: `docs/runbooks/` - start with `00-pipeline-and-identity.md`, `00b-configure-pipeline-credentials.md` (pipeline Azure login via OIDC), `00a-apply-phase0-fixes.md`, `01-deploy-stack.md` (deploy dev or prod), `01a-migrate-from-defenstack.md` (retire the Phase 0 resource group), `02-firewall.md` (Premium firewall rule changes and allowlist requests), and `03-admin-access.md` (Bastion, point-to-site VPN client setup, jump host sign-in, break-glass), `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover), `05-app-and-data.md` (storage resilience, Application Insights, deploy-time Key Vault secrets, restore procedures), and `06-monitoring-and-sentinel.md` (private Azure Monitor, flow logs, Sentinel connectors, alert triage, `ALERT_EMAIL`)
  - Runbook structure (mandatory for every change): `docs/runbooks/_template.md`
  ```

  Replace with:

  ```markdown
  - Architecture: `docs/architecture/overview.md` - topology, traffic flows, address plan, naming convention, and resource inventory
  - Runbooks: `docs/runbooks/` - start with `00-pipeline-and-identity.md`, `00b-configure-pipeline-credentials.md` (pipeline Azure login via OIDC), `00a-apply-phase0-fixes.md`, `01-deploy-stack.md` (deploy dev or prod), `01a-migrate-from-defenstack.md` (retire the Phase 0 resource group), `02-firewall.md` (Premium firewall rule changes and allowlist requests), and `03-admin-access.md` (Bastion, point-to-site VPN client setup, jump host sign-in, break-glass), `04-ingress.md` (Front Door, WAF tuning, Private Link approval, custom domain cutover), `05-app-and-data.md` (storage resilience, Application Insights, deploy-time Key Vault secrets, restore procedures), `06-monitoring-and-sentinel.md` (private Azure Monitor, flow logs, Sentinel connectors, alert triage, `ALERT_EMAIL`), and `07-governance.md` (operator-deployed Defender for Cloud and Azure Policy, the audit-to-deny switch, exemptions, just-in-time access to the jump host)
  - Runbook structure (mandatory for every change): `docs/runbooks/_template.md`
  ```

  **`README.md`, edit 2 of 4.** Find:

  ```markdown
  - Phase 6 monitoring, deployed from `main.bicep`: `modules/monitorPrivateLinkScope.bicep` and `modules/monitorPrivateEndpoint.bicep` (private-only Azure Monitor), `modules/hubPeering.bicep` (prod hub-to-hub peering), `modules/activityLog.bicep` (subscription Activity Log), `modules/actionGroup.bicep`, `modules/metricAlerts.bicep` and `modules/serviceHealthAlert.bicep` (alerts). Each region stamp adds `modules/flowLogStorage.bicep` and `modules/flowLogs.bicep` (VNet flow logs, deployed into `NetworkWatcherRG`) and its own metric alerts. See `docs/runbooks/06-monitoring-and-sentinel.md`.

  ```

  Replace with:

  ```markdown
  - Phase 6 monitoring, deployed from `main.bicep`: `modules/monitorPrivateLinkScope.bicep` and `modules/monitorPrivateEndpoint.bicep` (private-only Azure Monitor), `modules/hubPeering.bicep` (prod hub-to-hub peering), `modules/activityLog.bicep` (subscription Activity Log), `modules/actionGroup.bicep`, `modules/metricAlerts.bicep` and `modules/serviceHealthAlert.bicep` (alerts). Each region stamp adds `modules/flowLogStorage.bicep` and `modules/flowLogs.bicep` (VNet flow logs, deployed into `NetworkWatcherRG`) and its own metric alerts. See `docs/runbooks/06-monitoring-and-sentinel.md`.
  - Phase 7 governance, **deployed by an operator, never by the pipeline**: `governance.bicep` (a second subscription-scope entry point, with `params/governance.bicepparam` and a committed `governance.json`) and `modules/governance/` (`defenderPlans.bicep`, `securityContacts.bicep`, `policies.bicep`, `flowLogStorageExemption.bicep`, `legacyWaiver.bicep`, `jitRequesterRole.bicep`, `jitRequesterAssignment.bicep`). The jump host's just-in-time policy is deployed by the pipeline from `modules/virtualMachine.bicep`. See `docs/runbooks/07-governance.md`.

  ```

  **`README.md`, edit 3 of 4.** Find:

  ```markdown

  Resource API versions use the newest stable version that is both available from the target Azure provider and typed by the installed Bicep CLI. The Azure provider can expose newer versions before the local Bicep type catalog supports them; using those versions would remove compile-time property validation. Review provider metadata and the Bicep CLI catalog together before upgrading, then run lint, build, Azure deployment validation, and what-if.

  ```

  Replace with:

  ```markdown

  Resource API versions use the newest stable version that is both available from the target Azure provider and typed by the installed Bicep CLI. The Azure provider can expose newer versions before the local Bicep type catalog supports them; using those versions would remove compile-time property validation. Review provider metadata and the Bicep CLI catalog together before upgrading, then run lint, build, Azure deployment validation, and what-if. The only preview versions are for resource types or scopes with no GA version, each recorded with a fallback: the subscription Activity Log setting (`ADR-025`), and policy exemptions and the Defender for Cloud security contact (`ADR-029`).

  ```

  **`README.md`, edit 4 of 4.** Find:

  ```markdown

  The VM module is disabled by default through `enableVirtualMachine=false`. When enabled, it creates a private-only VM in the dedicated `management` subnet with no public IP, a NIC-level deny-by-default NSG, a system-assigned managed identity, Premium managed OS disk, trusted launch, secure boot, vTPM, boot diagnostics, platform metrics, and the Azure Monitor Agent with a data collection rule that sends syslog (Linux) or System/Application events (Windows) plus CPU, memory, and disk counters to the Log Analytics workspace. The firewall's `AzureMonitor` service-tag rule allows the agent's egress.

  ```

  Replace with:

  ```markdown

  The VM module is disabled by default through `enableVirtualMachine=false`. When enabled, it creates a private-only VM in the dedicated `management` subnet with no public IP, a NIC-level deny-by-default NSG that keeps SSH/RDP closed until a Defender just-in-time request opens it (Phase 7, runbook 07 §5.4), a system-assigned managed identity, Premium managed OS disk, trusted launch, secure boot, vTPM, boot diagnostics, platform metrics, and the Azure Monitor Agent with a data collection rule that sends syslog (Linux) or System/Application events (Windows) plus CPU, memory, and disk counters to the Log Analytics workspace. The firewall's `AzureMonitor` service-tag rule allows the agent's egress.

  ```

- [ ] **Step 6: Run the full suite on both shells**

  The full suite should show `Tests Passed: 676, Failed: 0` on Windows PowerShell 5.1 and on pwsh 7. PSRule is unchanged at 1332 rules processed, 0 failures. Encoding check: `grep -rln $'\xEF\xBF\xBD' docs README.md --exclude-dir=superpowers` prints nothing.

- [ ] **Step 7: Commit**

  ```bash
  git add docs/runbooks/07-governance.md docs/decisions/ADR-026-operator-deployed-governance-entry-point.md docs/decisions/ADR-027-audit-first-policy-enforcement.md docs/decisions/ADR-028-jit-access-and-nsg-ownership.md docs/decisions/ADR-029-preview-apis-for-governance.md docs/decisions/ADR-014-jit-access-deferred-to-phase-7.md docs/architecture/overview.md docs/cost.md docs/runbooks/00b-configure-pipeline-credentials.md docs/runbooks/03-admin-access.md docs/runbooks/06-monitoring-and-sentinel.md README.md tests/Docs.Tests.ps1
  git commit -m "docs: Phase 7 runbook 07, ADR-026 to ADR-029 and governance updates" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
  ```

---

## After the last task (human, not the implementer)

A person follows only runbook 07:

1. In dev: §4 steps 1–10 (PIM activation of the operator roles, providers, target check, `adminGroupObjectIds` from the environment files, `SECURITY_CONTACT_EMAILS`, validate and what-if, `az deployment sub create` for governance, **then** the workload deploy through the pipeline, PIM-eligible group membership, the audit week). Then §5.4 (a JIT request) and every §6 row. Paste the outputs into the PR.
2. Confirm or replace the placeholder `legacyWaiverExpiresOn = '2027-03-31'`, and watch the §9 live-only risks on the first run: the preview APIs and default sub-plans (Review Focus 3) and which NSG JIT programs (Review Focus 4). Record any fallback taken in the matching ADR.
3. After the audit week (§5.2): review compliance with `az policy state summarize`, then switch `denyEnforcement` to `'Default'` in a reviewed commit that also updates the Params test "starts audit-first for dev and prod (ADR-027)". Before adding an environment or region later, follow the ordering trap in §5.3 (Review Focus 1).
