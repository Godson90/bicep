# 01a - Migrate from the legacy `defenStack` resource group

> Owning module(s): none directly — this runbook moves the deployment target from the Phase 0 resource group `defenStack` to the Phase 1 environment's resource groups. Related: [runbook 01](01-deploy-stack.md), [runbook 00b](00b-configure-pipeline-credentials.md), README "Safe teardown".

## 1. Purpose and scope

Moves the `dev` GitHub Actions pipeline and Azure workload off the Phase 0, resource-group-scoped `defenStack` deployment and onto the Phase 1 subscription-scope stack (`rg-defenstack-dev-global`, `rg-defenstack-dev-wus3`). It covers: deploying the new stack alongside the old one, inventorying whatever is in `defenStack` before it is retired, moving the pipeline identity's role assignments, and tearing `defenStack` down. It does not cover prod: prod is a new environment with no predecessor, so it only ever needs runbook 01.

## 2. Prerequisites

- Runbook 01 already run once for `dev` (§4 steps 1–6), so the new stack exists and validates.
- The roles and provider registrations listed in runbook 01 §2.
- Azure role sufficient to read and delete resources in `defenStack` (the same `Owner`, or `Contributor` plus `Role Based Access Control Administrator`, used by `00a-apply-phase0-fixes.md`).
- GitHub admin access to `Godson90/bicep` (to edit the `dev` environment's variables).
- `defenStack` has no private admin path yet (Phase 3 adds Bastion/VPN), so every inventory step below uses only the Azure management plane — no data-plane access to storage blobs, Key Vault secret values, or a shell on the App Service.

## 3. Parameters

| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `-ResourceGroupNames` (runbook 00b script) | *(none, required)* | not applicable — dev only | Step 4.1 passes the **new** `dev` resource groups so the existing app registration gets rights there |
| `-EnvironmentName` (runbook 00b script) | *(none, required)* | not applicable — dev only | Stays `dev`; the same app registration and federated credential are reused, only the resource-group scope of its role assignments changes |

This runbook is dev-only and introduces no new template parameters; it reuses `params/dev.bicepparam` unchanged (runbook 01).

## 4. Step-by-step

1. **Deploy the new dev stack alongside `defenStack`** (runbook 01, §4, for `env = dev`). The two coexist without conflict: `defenStack` uses `10.0.0.0/16`/`10.1.0.0/16`, while the Phase 1 dev stack uses `10.20.0.0/16`/`10.21.0.0/16`, and every resource name differs (different resource groups entirely).

2. **Inventory data in `defenStack`**, from the management plane only:

   - Storage `UsedCapacity`:

     ```powershell
     az monitor metrics list --resource <storage-id> --metric UsedCapacity --interval PT1H --query "value[0].timeseries[0].data[-1].average"
     ```

   - Key Vault secret count (names only, not values): not obtainable through the management plane while the vault is private — there is no admin network path into `defenStack` yet. Record the only secret known to exist from Phase 0: `phase0-reference-test` (test data, per the README's Key Vault walkthrough).
   - App Service: whether real application code was deployed. Do **not** use `az webapp deployment list-publishing-profiles` (that would print a live, unrotated credential to the console/logs for a resource about to be torn down). Instead:

     ```powershell
     az webapp show -g defenStack -n <app-service-name> --query state -o tsv
     ```

     combined with team knowledge of whether anyone has ever deployed code to it.

3. **Decide whether there is anything to migrate:**
   - If storage `UsedCapacity` is under 1 MiB **and** no application code was ever deployed: there is nothing to migrate. Continue to step 4.
   - Otherwise: **stop here.** Do not tear down `defenStack` yet. Migrate the data after Phase 3 provides a private admin path (Bastion/VPN jump host), using:
     - Storage: `azcopy copy` between the two private storage accounts, run from the jump host.
     - Key Vault: `az keyvault secret show` against the old vault and `az keyvault secret set` against the new one, both run from the jump host.

4. **Move the pipeline:**
   1. Run [runbook 00b](00b-configure-pipeline-credentials.md) again, with `-ResourceGroupNames 'rg-defenstack-dev-global','rg-defenstack-dev-wus3'`. The script is idempotent by display name, so it reuses the existing `gh-Godson90-bicep-dev-deploy` app registration and its `github-dev` federated credential, and only adds the `Contributor` / `Role Based Access Control Administrator` assignments on the two new resource groups.
   2. Delete the `AZURE_RESOURCE_GROUP` variable from the GitHub `dev` environment (Settings → Environments → `dev`) — the workflows no longer read it; `main.bicep` now deploys at subscription scope.
   3. Remove the identity's old `defenStack` role assignments so it can no longer touch the retired resource group:

      ```powershell
      $spId = az ad sp list --filter "appId eq '<client-id>'" --query "[0].id" -o tsv
      az role assignment list --assignee $spId --resource-group defenStack --query "[].id" -o tsv | ForEach-Object { az role assignment delete --ids $_ }
      ```

5. **Validate the new stack** with runbook 01 §6.

6. **Tear down `defenStack`,** using the README's existing "Safe teardown" section, in order (steps 1–9 there). Then delete the resource-group budget:

   ```powershell
   az consumption budget delete -g defenStack -n defenstack-monthly
   ```

7. **Record the migration** in this runbook's execution record below: date, operator, storage `UsedCapacity` at inventory time, the decision made in step 3, and the `defenStack` teardown completion time.

## 5. Manual and post-deployment steps

- Confirm with the team, out of band, whether `defenStack`'s App Service ever received a real deployment — `az webapp show --query state` only reports `Running`/`Stopped`, not deployment history, so this is a judgment call combined with step 2's App Service check.
- Update any bookmarks, dashboards, or alerting rules that still point at `defenStack` by name.

## 6. Validation

Use runbook 01 §6 in full against `rg-defenstack-dev-wus3` / `rg-defenstack-dev-global` before tearing down `defenStack` in step 6.

| Check | Command | Expected result |
|---|---|---|
| Old identity has no remaining access to `defenStack` | `az role assignment list --assignee <sp-id> --resource-group defenStack -o table` | Empty, after step 4.3 |
| `defenStack` fully removed | `az group exists --name defenStack` | `false`, after step 6 |
| `AZURE_RESOURCE_GROUP` no longer set | GitHub `dev` environment variables | Variable absent, after step 4.2 |

## 7. Rollback

- **Before step 6 (teardown):** fully reversible. Re-add the identity's `defenStack` role assignments by re-running the Phase 0 version of the identity script, which still uses `-ResourceGroupName` (singular) against `defenStack`:

  ```powershell
  git show phase0-foundation-fixes:scripts/New-GitHubDeploymentIdentity.ps1 > $env:TEMP/old.ps1
  & $env:TEMP/old.ps1 -ResourceGroupName defenStack -GitHubRepository Godson90/bicep -EnvironmentName dev
  ```

  Re-add the `AZURE_RESOURCE_GROUP` GitHub variable if any workflow still expects it, and revert the pipeline's target back to `defenStack` if needed.

- **After step 6 (teardown):** there is **no rollback**. `defenStack`'s resources — Firewall, App Service, Storage, Key Vault, VNets — are deleted per the README's "Safe teardown" section, and Key Vault soft delete/purge protection only preserves the *name* and lets you *recover the vault itself*, not the workload as a whole. If step 3 correctly determined there was nothing to migrate, this is expected and acceptable. If step 6 is run in error before step 3's decision is confirmed, the only recovery path is `az keyvault recover` for the vault (if purge-protected) and re-deploying every other resource from scratch with no data.

## 8. Operations

- This runbook is a one-time migration per environment; it has no recurring day-2 operations of its own. Once `defenStack` is torn down, all day-2 operations for `dev` follow runbook 01 §8.
- If a future environment needs the same pattern (an old resource-group-scoped stack retired in favor of a subscription-scope one), copy this runbook's structure rather than reusing it directly — it is written specifically for `defenStack` → `rg-defenstack-dev-*`.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| `AuthorizationFailed` when running runbook 00b against the new resource groups | The identity's replicated custom role assignment has not propagated yet | Wait a few minutes and re-run; see runbook 00b §9 |
| Step 2's storage metric returns `null` | No metrics recorded yet at the queried interval, or the storage account name/ID is wrong | Widen `--interval`, or confirm the resource ID with `scripts/Get-AzureResourceId.ps1` |
| Team cannot confirm whether App Service code was deployed | No record kept from Phase 0 | Treat as "yes, something was deployed" (the conservative assumption) and follow step 3's "stop" branch |
| `defenStack` teardown step (README §9) fails because of Key Vault purge protection | Expected — purge protection is intentional | Do not force-purge; verify retention requirement, then move on once the vault is soft-deleted (name reservation only, no live resource) |
| `az consumption budget delete` returns `NotFound` | The budget was never created, or already removed | Confirm with `az consumption budget show -g defenStack -n defenstack-monthly`; skip if absent |

## Execution record

| Date | Operator | Storage `UsedCapacity` at inventory | Decision (§3) | `defenStack` teardown completed |
|---|---|---|---|---|
| *(fill in when run)* | | | | |
