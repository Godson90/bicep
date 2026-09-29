# 02 - Firewall (Premium, IDPS, and rule changes)

> Owning module(s): `modules/azureFirewall.bicep`, `modules/firewallPolicyRules.bicep`, called from `modules/regionStamp.bicep`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3, §5. Related: [ADR-010](../decisions/ADR-010-shared-firewall-rules-module.md), [ADR-011](../decisions/ADR-011-tls-inspection-deferred.md), [ADR-012](../decisions/ADR-012-prod-two-approval-deploys.md), [runbook 01](01-deploy-stack.md), [runbook 00b](00b-configure-pipeline-credentials.md).

## 1. Purpose and scope

Each region stamp deploys its own Azure Firewall **Premium** instance
(`modules/azureFirewall.bicep`) and firewall policy, with rules from the
shared `modules/firewallPolicyRules.bicep` module (ADR-010). The firewall
enforces:

- **Three rule collection groups**, dependency-chained so Azure never tries to
  update two of a policy's rule collection groups at once:
  - `dns-egress` (priority 100): DNS to Azure's resolver (`168.63.129.16:53`)
    for the spoke, and HTTPS to the `AzureMonitor`/`AzureResourceManager`
    service tags for the Azure Monitor Agent.
  - `platform-egress` (priority 150): OS update endpoints
    (`WindowsUpdate` FQDN tag, and the Ubuntu archive FQDNs) — **management
    subnet only**, never the App Service subnet.
  - `approved-https-egress` (priority 200, optional): the application
    allowlist from `allowedOutboundFqdns`. Not deployed at all when that list
    is empty, which is the shipped default — application HTTPS egress is
    denied until an operator adds FQDNs (§5).
- **IDPS** (Premium-only): `idpsMode` — `Alert` in dev, `Deny` in prod.
- **Threat intelligence**: `threatIntelMode` — `Alert` in dev (`ADR-003`),
  `Deny` in prod.
- **The DNS proxy** (`dnsSettings.enableProxy: true`): the stamp's **spoke**
  VNet uses the firewall's private IP as its DNS server
  (`modules/spokeNetwork.bicep`'s `vnet.bicep` call sets `dhcpOptions`), so
  all spoke DNS resolution — including the private DNS zones linked in the
  global layer — is proxied through the firewall. The **hub** VNet
  (`modules/hubNetwork.bicep`) sets no `dhcpOptions` and so has no VNet-level
  DNS server override; it relies on Azure-provided DNS directly (`ADR-005`).

TLS inspection is explicitly out of scope for Phase 2 (`ADR-011`): IDPS and
threat intelligence see only unencrypted traffic and TLS metadata, not
decrypted HTTPS payloads.

Owning files: `modules/azureFirewall.bicep` (firewall, policy, public IP,
diagnostics, locks), `modules/firewallPolicyRules.bicep` (the three rule
collection groups), `modules/regionStamp.bicep` (wires `firewallTier`,
`idpsMode`, `threatIntelMode`, `enableDeleteLock` per environment), and
`params/<env>.bicepparam` (`allowedOutboundFqdns`).

## 2. Prerequisites

- **Roles:** to read the firewall and its policy, `Reader` at the resource
  group scope (or broader). To run a deploy that changes firewall rules, the
  same pipeline identity and process as any other change — see
  [runbook 00b](00b-configure-pipeline-credentials.md) and
  [runbook 01](01-deploy-stack.md) §2/§3. Firewall and firewall-policy
  resources are ordinary resources under the pipeline identity's
  per-resource-group `Contributor` grant. **Prod deploys also need the
  `DefenStack Resource Lock Operator` custom role**, granted by running
  `scripts/New-GitHubDeploymentIdentity.ps1` with `-GrantLockManagement`
  (`docs/runbooks/00b-configure-pipeline-credentials.md` §5 "Prod") — built-in
  `Contributor` excludes `Microsoft.Authorization/*` writes, so it cannot
  create or update the `CanNotDelete` locks a prod deploy applies to the
  firewall, its policy, and its public IP (§6/§7 below) without this
  additional role.
- **The Log Analytics workspace** `log-defenstack-<env>`, in
  `rg-defenstack-<env>-global`, must already exist (`modules/global.bicep`,
  runbook 01). Firewall diagnostics (`firewall-diagnostics`,
  `logAnalyticsDestinationType: 'Dedicated'`) write to `AZFW*` tables in that
  workspace.
- Azure CLI 2.90+ signed in, for the validation and troubleshooting commands
  in §6 and §9.

## 3. Parameters

| Parameter | Dev | Prod |
|---|---|---|
| `firewallTier` | `Premium` | `Premium` |
| `idpsMode` | `Alert` | `Deny` |
| `threatIntelMode` | `Alert` (`ADR-003`) | `Deny` |
| `allowedOutboundFqdns` | from `params/dev.bicepparam` (`[]` shipped) | from `params/prod.bicepparam` (`[]` shipped) |
| `managementAddressPrefixes` | `[addressPlan.managementSubnetPrefix]`, from `primaryAddressPlan`/`secondaryAddressPlan` | same, from the prod address plan |
| `enableDeleteLock` | `false` | `true` |

These are `modules/regionStamp.bicep` values derived from `environmentName`
(`isProd`), not separate `main.bicep` parameters — `firewallTier` is fixed to
`Premium` for every stamp, `idpsMode`/`threatIntelMode`/`enableDeleteLock`
follow `isProd`, and `allowedOutboundFqdns`/`managementAddressPrefixes` come
from the committed `.bicepparam` address plan. Only `allowedOutboundFqdns` is
meant to change routinely (§4/§5); the others change only through a reviewed
code change.

## 4. Step-by-step

### Rule change procedure

1. **Edit the rule source.**
   - A **baseline** rule (applies to every stamp — for example, a new
     platform FQDN tag, or widening `dns-egress`): edit
     `modules/firewallPolicyRules.bicep` directly.
   - An **application allowlist** entry (one environment only): edit
     `allowedOutboundFqdns` in `params/<env>.bicepparam`.
   - An **IDPS signature override** (Alert-only or Off for one specific
     signature): edit `idpsSignatureOverrides` in `modules/azureFirewall.bicep`'s
     module call in `modules/regionStamp.bicep` (or the parameter's default in
     `modules/azureFirewall.bicep` for every stamp). This is **not** in
     `modules/firewallPolicyRules.bicep` — that module holds only the three
     rule collection groups (`dns-egress`, `platform-egress`,
     `approved-https-egress`); IDPS overrides live on the policy resource
     itself, under `intrusionDetection.configuration.signatureOverrides`. See
     §8.
2. **Add or adjust a test** in `tests/FirewallPolicyRules.Tests.ps1` covering
   the new or changed rule.
3. **Run the suite and PSRule** locally:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File tests/Invoke-Tests.ps1
   ```

   Then the PSRule baseline command from
   [runbook 00](00-pipeline-and-identity.md) §8.
4. **Open a PR** and read the PR what-if. `bicep-ci.yml`'s `what-if` job runs
   in the `dev-plan` GitHub environment and posts a **What-if: dev** comment —
   review it for the exact rule collection group change before merging.
5. **Merge.** `deploy.yml` runs `plan` then `apply` for dev automatically
   (push to `main`).
6. **For prod,** run the `deploy` workflow with `environment=prod`
   (`workflow_dispatch`). Reviewers approve the `plan` job, read its what-if
   (the job summary, or the `whatif-prod` artifact — kept 14 days), then
   approve the `apply` job. Both jobs run in the gated `prod` environment
   (`ADR-012`); a prod rule change needs two separate approvals.

## 5. Manual and post-deployment steps

### Allowlist request

Application egress is denied by default (`allowedOutboundFqdns = []`).
Adding an FQDN to the allowlist is a change request, not a self-service
toggle:

- **The requester supplies:** the FQDN (as specific as possible — avoid
  wildcards broader than needed), the port/protocol (this project's
  `approved-https-egress` group is HTTPS/443 only), the source (application
  traffic from the spoke, or management-subnet traffic — the latter belongs
  in `platform-egress`, not this allowlist), the business justification, an
  owner, and an expiry date.
- **The reviewer checks:** that the requested FQDN is the least specific
  wildcard that still satisfies the need (prefer `api.example.com` over
  `*.example.com`), and that it does not overlap with an FQDN already present
  in `allowedOutboundFqdns` or in `platform-egress`.
- **Record the request** (FQDN, justification, owner, expiry) in the pull
  request description that adds it to `params/<env>.bicepparam`, so the
  history of why each entry exists lives with the code change.
- **Remove expired entries quarterly.** Treat an expired, unrenewed entry the
  same as any other rule change: remove it from `allowedOutboundFqdns`,
  redeploy, and confirm with §6/§8 below that the removal actually took
  effect (§8 — Azure does not delete a whole rule collection group just
  because the FQDN list becomes empty in one deploy; see the note there).

## 6. Validation

| Check | Command | Expected result |
|---|---|---|
| Firewall tier and zones | `az network firewall show -g rg-defenstack-<env>-wus3 -n afw-defenstack-<env>-wus3 --query "{tier:sku.tier,zones:zones}"` | `Premium`, zones `1 2 3` |
| Policy tier, IDPS, threat intel | `az network firewall policy show -g rg-defenstack-<env>-wus3 -n afwp-defenstack-<env>-wus3 --query "{tier:sku.tier,idps:intrusionDetection.mode,ti:threatIntelMode}"` | `Premium`; `idps` = `Alert` (dev) or `Deny` (prod); `ti` = `Alert` (dev) or `Deny` (prod) |
| Rule collection groups | `az network firewall policy rule-collection-group list -g rg-defenstack-<env>-wus3 --policy-name afwp-defenstack-<env>-wus3 --query "[].{name:name,priority:priority}" -o table` | `dns-egress` 100, `platform-egress` 150, and `approved-https-egress` 200 only when the allowlist is non-empty |
| Prod locks | `az lock list -g rg-defenstack-prod-wus3 -o table` | `CanNotDelete` locks on the hub VNet, spoke VNet, Key Vault, firewall, firewall policy, and firewall public IP (see also runbook 01 §6/§7) |
| IDPS signature hits (KQL) | `AZFWIdpsSignature \| take 20` | Recent signature matches, if any, with `Action` (`Alert` or `Deny`) |
| Threat intelligence hits (KQL) | `AZFWThreatIntel \| take 20` | Recent threat-intel matches, if any |
| Denied application traffic (KQL) | `AZFWApplicationRule \| where Action == "Deny" \| take 20` | Denied outbound calls — expected for any FQDN not yet allowlisted |

## 7. Rollback

- **Rule content:** revert the commit that changed
  `modules/firewallPolicyRules.bicep` or `allowedOutboundFqdns`, and redeploy
  through the normal pipeline (§4).
- **Tier:** a Premium → Standard change is **not supported in place** — Azure
  Firewall does not allow an existing firewall's SKU tier to be downgraded.
  Reverting to Standard would need a new firewall resource. Phase 2 is
  greenfield (no Standard firewall has ever taken production traffic under
  this design), so do not attempt an in-place tier downgrade; treat any
  future Standard requirement as a new design decision, not a rollback.
- **In prod,** every locked resource (§6) needs its lock lifted before any
  delete: `az lock delete --ids <lock-id>`. Re-create the lock afterward by
  redeploying (`enableDeleteLock: true` for prod recreates it automatically).

## 8. Operations

- **IDPS tuning:** review `AZFWIdpsSignature` in dev weekly while dev runs in
  `Alert` mode. If a signature false-positives against legitimate traffic,
  find its ID in `AZFWIdpsSignature`'s `SignatureId` column and add an entry
  to `idpsSignatureOverrides` (each entry `{ id: '<signatureId>', mode:
  'Alert' | 'Off' }`) — **not** in `modules/firewallPolicyRules.bicep`, which
  holds only rule collection groups. The override lives on the firewall
  policy resource in `modules/azureFirewall.bicep`
  (`intrusionDetection.configuration.signatureOverrides`), in a follow-up PR
  through the normal rule change procedure (§4): edit the source, add or
  adjust a test in `tests/AzureFirewall.Tests.ps1`, run the suite, open a PR,
  read the dev what-if, merge, then for prod run `deploy` with
  `environment=prod` and approve `plan` then `apply` (§4 steps 4–6). There is
  no portal-side configuration drift, since every override lives in source
  control. Never disable IDPS entirely to tune out one false positive — set
  only that signature's mode, never `idpsMode: 'Off'`.
- **Moving dev IDPS to Deny:** change the `idpsMode: isProd ? 'Deny' :
  'Alert'` expression in `modules/regionStamp.bicep`'s `azureFirewall` module
  call to stop conditioning on `isProd`, through the normal rule change
  procedure (§4). Do this only after the dev IDPS signature review (above)
  has run long enough to be confident false positives are tuned out.
- **OS update egress** is management-subnet only
  (`platform-egress`'s `sourceAddresses: managementAddressPrefixes`). The App
  Service integration subnet never gets Windows Update or Ubuntu archive
  access — if App Service needs an update-related FQDN, it must go through
  `approved-https-egress` (the allowlist request process, §5), not
  `platform-egress`.
- **Cost:** Azure Firewall Premium's hourly rate is higher than Standard's,
  plus data processing charges scale with throughput; see
  [`docs/cost.md`](../cost.md) "Phase 2 delta" for the driver breakdown (fill
  actual numbers from the Pricing Calculator; do not invent prices here).
- **Removing an allowlist entirely.** Setting `allowedOutboundFqdns = []` and
  redeploying does **not** delete the existing `approved-https-egress` rule
  collection group — Azure Resource Manager's incremental deployment mode
  (the mode this project uses) only adds or updates resources it sees in the
  template; it does not delete a resource collection group that the
  bicepparam-driven `if (!empty(allowedOutboundFqdns))` condition now omits.
  A stamp that once had entries and now has none is left with a
  `approved-https-egress` group containing stale rules. To actually remove
  it:

  ```powershell
  az network firewall policy rule-collection-group delete -g <resource-group> --policy-name <policy-name> -n approved-https-egress
  ```

  In prod, the firewall policy carries a `CanNotDelete` lock — lift it first:

  ```powershell
  az lock delete --ids <policy-lock-id>
  ```

  Then redeploy (§4) to restore the lock.
- **A prod deploy waiting for approval holds the `deploy-prod` concurrency
  group** (`deploy.yml`'s `concurrency: group: deploy-${{ inputs.environment
  || 'dev' }}`, `cancel-in-progress: false`). A run that is waiting on `plan`
  or `apply` approval counts as holding the group, so it is not cancelled out
  from under a reviewer. If a *second* prod run is then dispatched while the
  first is still waiting, the newer run is queued behind it — and if a
  *third* is dispatched before the second gets its turn, the newer queued run
  **replaces** the older queued one (GitHub only keeps the most recently
  queued run per concurrency group). So approving a prod run after other prod
  runs were dispatched behind it may end up approving a different
  deployment than the one originally reviewed. When multiple prod changes are
  in flight, confirm which run is actually pending approval
  (`gh run list --workflow deploy.yml`) before approving `plan` or `apply`.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| `AnotherOperationInProgress` / `FirewallPolicyUpdateNotAllowedWhenUpdatingOrDeleting` | Two rule collection groups on the same policy tried to update concurrently | The groups are already dependency-chained in `modules/firewallPolicyRules.bicep`; re-run the deployment — it is transient, not a real conflict |
| VM (or other management-subnet resource) updates fail to reach an OS update endpoint | `AZFWApplicationRule` is denying the request from the management subnet | Query `AZFWApplicationRule` for `Action == "Deny"` from the management subnet's source IP; confirm the target FQDN is actually covered by `platform-egress` (`WindowsUpdate` tag or the Ubuntu archive FQDNs) — if not, it needs a baseline rule change (§4), not an allowlist entry |
| An application call is denied that should be allowed | The destination FQDN is not in `allowedOutboundFqdns` | Follow the allowlist request process (§5) |
| IDPS blocks legitimate prod traffic | A signature is matching traffic that is actually benign, and prod's `idpsMode: Deny` blocks on match | Find the signature ID in `AZFWIdpsSignature`'s `SignatureId` column and temporarily add `{ id: '<signatureId>', mode: 'Alert' }` to `idpsSignatureOverrides` in `modules/azureFirewall.bicep` (not `modules/firewallPolicyRules.bicep`) through the normal rule change procedure (§4/§8) — never disable IDPS entirely to work around one false positive |
| `ScopeLocked` on a delete in prod | A `CanNotDelete` lock (§6) is still attached | See §7/§8's lock-removal step, then redeploy to restore the lock |
| `AADSTS70021` in the dev **plan** job | The `dev-plan` federated credential or environment is missing — the identity script only created it if `-EnvironmentName dev` was used (it does not create a `-plan` credential for `-EnvironmentName prod`) | Re-run `scripts/New-GitHubDeploymentIdentity.ps1` for dev (`-EnvironmentName dev`); see [runbook 00b](00b-configure-pipeline-credentials.md) §9 |

**Known gaps (management egress).** These are not bugs — they are FQDNs the
baseline `platform-egress` rules do not cover yet:

| Symptom | Cause | Fix |
|---|---|---|
| A Windows management VM cannot activate (KMS activation fails) | `platform-egress`'s `windows-update` rule only covers the `WindowsUpdate` FQDN tag; it does not allow `azkms.core.windows.net:1688`, the KMS activation endpoint | Add a network rule (TCP 1688 to `azkms.core.windows.net`) to `modules/firewallPolicyRules.bicep`'s `platform-egress` group, scoped to `managementAddressPrefixes`, through the normal rule change procedure (§4) |
| An Ubuntu management VM cannot reach `changelogs.ubuntu.com`, `esm.ubuntu.com`, or `api.snapcraft.io` | `platform-egress`'s `ubuntu-archives` rule only allows the core archive FQDNs (`archive.ubuntu.com`, `security.ubuntu.com`, `azure.archive.ubuntu.com`, `*.azure.archive.ubuntu.com`) — not the changelog viewer, Ubuntu Pro/ESM, or Snap store endpoints | Add the needed FQDNs to `platform-egress`'s `ubuntu-archives` rule in `modules/firewallPolicyRules.bicep` through the normal rule change procedure (§4) when a management VM actually needs them |
