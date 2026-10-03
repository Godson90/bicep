# 05 - App and data runbook (storage resilience, Application Insights, deploy-time secrets)

> Owning module(s): `modules/storage.bicep`, `modules/storageSecondaryEndpoint.bicep`, `modules/storageReaderAssignment.bicep`, `modules/appInsights.bicep`, `modules/appInsightsPublisher.bicep`, `modules/appService.bicep`, `modules/keyVault.bicep`, wired by `modules/regionStamp.bicep` and `main.bicep`. Pipeline: `.github/workflows/deploy.yml` with `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`. Spec section: `docs/superpowers/specs/2026-09-25-secure-connectivity-design.md` §3 "Identity and secrets" and "Data and application resilience", §5 Phase 5.

## 1. Purpose and scope

This runbook makes each region's application data and secrets survive the failures the design plans for, and makes the app observable.

**Storage (`modules/storage.bicep`, per stamp):**

| Stamp | SKU | Why |
|---|---|---|
| Prod primary (West US 3) | `Standard_RAGZRS` | Zone-redundant in West US 3, geo-copied to East US, with a read-only secondary endpoint (`ADR-020`) |
| Prod warm standby (East US) | `Standard_GRS` | The standby's own state; geo-copied to its pair |
| Dev | `Standard_LRS` | Single-region dev (`ADR-008`); PSRule's replication rule is suppressed for LRS accounts only |

Data protection is unchanged from Phase 0 (F7) on every account:
- versioning;
- 14-day blob and container soft delete;
- change feed;
- point-in-time restore for 13 days;
- no shared keys, no public network access.

**Warm-standby read path (prod only):**
- The East US stamp has a private endpoint `<primary account>-secondary-pe` on the primary account's **read-only secondary** (`blob_secondary`). It is registered in the shared `privatelink.blob` zone as `<primary account>-secondary`.
- The East US App Service identity holds **Storage Blob Data Reader** on the primary account's `def-blob` container: read only, never write (`modules/storageReaderAssignment.bicep`, deployed into the primary resource group).

**Application Insights (`modules/appInsights.bicep`):**
- One workspace-based component per region, `appi-defenstack-<env>-<region>`, storing telemetry in `log-defenstack-<env>` (`ADR-021`).
- Key-based ingestion is **disabled**. The App Service identity sends telemetry with Entra ID, using **Monitoring Metrics Publisher** on its own component.
- Public ingestion stays on until Phase 6 adds the Azure Monitor Private Link Scope.

**App Service (`modules/appService.bicep`):**
- App settings `APPLICATIONINSIGHTS_CONNECTION_STRING` and `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`.
- `ipSecurityRestrictionsDefaultAction` and `scmIpSecurityRestrictionsDefaultAction` set to `Deny`, so the site and Kudu stay closed even if someone re-enables public network access.

**Deploy-time secrets (`ADR-019`):**
- Application secrets live in one GitHub **environment secret**, `KEYVAULT_SECRETS_JSON`: a JSON object of `{ "secret-name": "value" }`.
- The `apply` job validates it with `scripts/ConvertTo-KeyVaultSecretsParameter.ps1` and passes it as the `@secure()` parameter `keyVaultSecrets`.
- Azure Resource Manager writes the **same** values to **every** regional Key Vault, which is how the regional vaults stay in sync. The runner never needs a network path to the private vaults.
- An empty or unset secret writes nothing.

**Not in scope:**
- AMPLS and private ingestion (Phase 6).
- Recovery Services vaults and the failover procedure (Phase 8).
- App code and its own use of the secrets.

## 2. Prerequisites

- **Pipeline identity:** Phase 5 adds two delegatable roles, **Storage Blob Data Reader** (`2a2b9908-6ea1-4ae2-8e65-a410df84e7d1`) and **Monitoring Metrics Publisher** (`3913510d-42f4-4e42-8a64-420c390055eb`). `scripts/New-GitHubDeploymentIdentity.ps1` now includes both by default. Re-apply the constrained assignment as described in §4 step 1. The identity's existing `Contributor` on each resource group covers writing Key Vault secrets through Azure Resource Manager (`Microsoft.KeyVault/vaults/secrets/write`).
- **GitHub:** permission to create environment secrets on `dev` and `prod` (repository admin).
- **Operator for §5–§6:** `Reader` on the resource groups. The Key Vault and Storage data-plane checks need:
  - the VPN or Bastion path from runbook 03, because both services are private;
  - `Key Vault Secrets User` (read) on the vault, PIM-eligible to the admin group (runbook 03 §2);
  - `Storage Blob Data Reader` (or `Contributor` for restores) on the container.
- **Providers:** `Microsoft.Insights` (already registered for diagnostics) and `Microsoft.Storage`.
- **Tools:** Azure CLI 2.90+ (the deploy combines a `.bicepparam` file with an extra `--parameters` value, which needs a current CLI), Bicep CLI 0.47.16, PowerShell 7 or 5.1.

## 3. Parameters

| Name | Default | Prod value | Rationale |
|---|---|---|---|
| `keyVaultSecrets` (`main.bicep`, `@secure()`) | `{}` | from `KEYVAULT_SECRETS_JSON` | Application secrets for every regional vault. **Never** set it in a committed `.bicepparam` file (`tests/KeyVaultSecrets.Tests.ps1` enforces this) |
| Storage SKU (`regionStamp.bicep`) | dev `Standard_LRS` | primary `Standard_RAGZRS`, standby `Standard_GRS` | §1 table (`ADR-020`) |
| `blobSoftDeleteRetentionDays` (`storage.bicep`) | `14` | `14` | Soft delete for blobs and containers, plus change feed retention; point-in-time restore covers `retention - 1` days |
| `applicationInsightsConnectionString` (`appService.bicep`) | set by the stamp | set by the stamp | The region's own component |
| `primaryStorageAccountId` / `primaryStorageAccountName` (`regionStamp.bicep`) | `''` | set for the East US stamp only | Creates the warm-standby read endpoint |

## 4. Step-by-step deployment

1. **Re-apply the pipeline identity's constrained role assignment,** so that it may assign the two new roles. Follow `docs/runbooks/00b-configure-pipeline-credentials.md` §8 "Assigning an extra role from Bicep", steps 2–3:
   1. Delete the existing RBAC Administrator assignment on each resource group.
   2. Re-run the script with its default role list.

   Check:

   ```powershell
   az role assignment list --assignee <pipeline-app-id> --resource-group rg-defenstack-dev-wus3 --role 'Role Based Access Control Administrator' --query '[0].condition' -o tsv
   ```

   Expected: the condition contains `2a2b9908-6ea1-4ae2-8e65-a410df84e7d1` and `3913510d-42f4-4e42-8a64-420c390055eb`.

2. **Create the environment secret** on each environment, even if empty for now: GitHub → **Settings** → **Environments** → `dev` → **Add environment secret** → name `KEYVAULT_SECRETS_JSON`, value `{}`. When the app needs secrets, set it to, for example, `{"api-key":"<value>","db-password":"<value>"}`. Do the same on `prod`. With the GitHub CLI:

   ```powershell
   gh secret set KEYVAULT_SECRETS_JSON --env dev --body '{}'
   ```

   Rules, enforced by the converter: names are 1–127 letters, digits or hyphens; values are non-empty strings.

3. **Validate and preview**, from the repository root:

   ```powershell
   az deployment sub validate --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
   az deployment sub what-if --location westus3 --template-file main.bicep --parameters params/dev.bicepparam
   ```

   Check the what-if:
   - In `rg-defenstack-dev-wus3`: **create** `appi-defenstack-dev-wus3` and a role assignment on it; **modify** the App Service (two app settings and two default-deny restrictions).
   - In prod, also: the primary storage account `sku.name` `Standard_GRS` → `Standard_RAGZRS`, and in `rg-defenstack-prod-eus` a new private endpoint `<primary account>-secondary-pe`, plus a role assignment in `rg-defenstack-prod-wus3`.
   - The plan job and what-if run without `KEYVAULT_SECRETS_JSON`, so they never show secret writes. That is expected.
   - **Stop** if the what-if shows any storage account or vault being recreated.

   Prod only: run the same `validate` with `params/prod.bicepparam` before the prod deployment. It is the first deployment of the RA-GZRS account with point-in-time restore (§9).
4. **Deploy through the pipeline:** GitHub → Actions → `deploy` → **Run workflow** → `dev` (prod: the two-approval flow, `ADR-012`). Check that the step **Prepare Key Vault secrets** logs `Prepared <n> Key Vault secret(s): <names>` (names only, never values), and that **Deploy** succeeds.
5. **Record the component names:** `az monitor app-insights component show -g rg-defenstack-dev-wus3 --app appi-defenstack-dev-wus3 --query "{name:name, workspace:workspaceResourceId, localAuth:disableLocalAuth}" -o json`. Expected: the workspace ID ends in `log-defenstack-dev`, and `"localAuth": true`, which means local auth is disabled.

## 5. Manual and post-deployment steps

### 5.1 Secret sync: add, rotate or remove a secret

- **Add or rotate:**
  1. Update `KEYVAULT_SECRETS_JSON` on the environment with the **complete** object (GitHub stores it as one value). For example:

     ```powershell
     gh secret set KEYVAULT_SECRETS_JSON --env prod --body (Get-Content .\secrets.prod.json -Raw)
     ```

     Keep that file outside the repository, and delete it afterwards.
  2. Run the deploy workflow. Every regional vault gets a new **version** of each changed secret; consumers that read `latest` pick it up.
- **Check that both regions match** (over the VPN):

  ```powershell
  foreach ($kv in '<kv-wus3>', '<kv-eus>') { az keyvault secret show --vault-name $kv --name api-key --query "{vault:'$kv', updated:attributes.updated}" -o tsv }
  ```

  Expected: both vaults show the same deployment's timestamp, within a few minutes of each other.
- **Remove:** taking a name out of the JSON does **not** delete it from the vaults, because deployments are incremental. Delete it from each vault over the VPN: `az keyvault secret delete --vault-name <kv> --name <secret>`. Purge protection keeps it recoverable for 90 days.
- **Never** put secret values in a `.bicepparam` file, a pipeline variable, a PR, or a command line that is logged.

### 5.2 Restore deleted or overwritten data

The examples use the dev primary account `<st>` and container `def-blob`, run over the VPN with `--auth-mode login`. Shared keys are disabled, so every command authenticates with Entra ID.

| What happened | Recover with | Command |
|---|---|---|
| A blob was deleted (within 14 days) | Soft delete | `az storage blob undelete --account-name <st> --container-name def-blob --name <blob> --auth-mode login` |
| A blob was overwritten | Versioning: copy a previous version over the current one | `az storage blob list --account-name <st> --container-name def-blob --prefix <blob> --include v --auth-mode login --query "[].{version:versionId, modified:properties.lastModified}" -o table`, then `az storage blob copy start --account-name <st> --destination-container def-blob --destination-blob <blob> --source-uri "https://<st>.blob.core.windows.net/def-blob/<blob>?versionid=<versionId>" --auth-mode login` |
| A container was deleted (within 14 days) | Container soft delete | `az storage container list --account-name <st> --include-deleted --auth-mode login --query "[?deleted].{name:name, version:version}" -o table`, then `az storage container restore --account-name <st> --name def-blob --deleted-version <version> --auth-mode login` |
| Many blobs were corrupted at a known time (within 13 days) | Point-in-time restore | `az storage blob restore --account-name <st> --resource-group rg-defenstack-dev-wus3 --time-to-restore 2026-10-02T09:00:00Z`. With no `--blob-range` it restores every container in the account; `def-blob` is the only one. It runs as a long operation: writes fail until it finishes, so stop the app writing first |
| A Key Vault secret was deleted (within 90 days) | Soft delete | `az keyvault secret recover --vault-name <kv> --name <secret>`, or redeploy, which re-creates it from `KEYVAULT_SECRETS_JSON` |
| A whole Key Vault was deleted | Vault soft delete; purge protection blocks purging | `az keyvault recover --name <kv>`, then redeploy |

### 5.3 Reading the primary's data from East US (prod, during an incident)

- The primary account's secondary endpoint `https://<primary account>-secondary.blob.core.windows.net` resolves, from the East US spoke, to the East US private endpoint IP. It is **read-only**.
- Check how current the copy is:

  ```powershell
  az storage account show -n <primary account> -g rg-defenstack-prod-wus3 --expand geoReplicationStats --query "geoReplicationStats.{status:status, lastSync:lastSyncTime}" -o table
  ```

  Expected: `status` is `Live`, and `lastSync` is within about 15 minutes.
- Writes in East US go to the East US account. Account failover, which makes East US writable for the primary account, belongs to the DR runbook (Phase 8).

## 6. Validation

| Check | Command | Expected result |
|---|---|---|
| Storage SKU per stamp | `az storage account list -g rg-defenstack-<env>-<region> --query "[].{name:name, sku:sku.name}" -o table` | dev `Standard_LRS`; prod wus3 `Standard_RAGZRS`; prod eus `Standard_GRS` |
| Data protection | `az storage account blob-service-properties show -n <st> -g <rg> --query "{versioning:isVersioningEnabled, softDelete:deleteRetentionPolicy.days, containerSoftDelete:containerDeleteRetentionPolicy.days, pitr:restorePolicy.days, changeFeed:changeFeed.enabled}" -o json` | `true`, `14`, `14`, `13`, `true` |
| Geo-replication (prod) | §5.3 command | `Live`, recent `lastSync` |
| Warm-standby read endpoint (prod) | `az network private-endpoint show -g rg-defenstack-prod-eus -n <primary account>-secondary-pe --query "{group:privateLinkServiceConnections[0].groupIds[0], state:privateLinkServiceConnections[0].privateLinkServiceConnectionState.status}" -o json` | `blob_secondary`, `Approved` |
| Secondary name resolves privately (prod, from the East US jump host or VPN) | `nslookup <primary account>-secondary.blob.core.windows.net` | An address in `10.10.1.0/24` |
| Warm-standby reader role (prod) | `az role assignment list --scope <primary account id>/blobServices/default/containers/def-blob --query "[?roleDefinitionName=='Storage Blob Data Reader'].principalId" -o tsv` | The East US App Service principal ID |
| App Insights is workspace-based with key auth off | §4 step 5 command | Workspace `log-defenstack-<env>`, `"localAuth": true` |
| App Service telemetry settings | `az webapp config appsettings list -n <app> -g <rg> --query "[?starts_with(name,'APPLICATIONINSIGHTS')].{name:name, value:value}" -o table` | Connection string present; `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` = `Authorization=AAD` |
| Publisher role | `az role assignment list --scope $(az monitor app-insights component show -g <rg> --app appi-defenstack-<env>-<region> --query id -o tsv) --query "[].roleDefinitionName" -o tsv` | `Monitoring Metrics Publisher` |
| Default-deny restrictions | `az webapp config access-restriction show -n <app> -g <rg> --query "{site:ipSecurityRestrictionsDefaultAction, scm:scmIpSecurityRestrictionsDefaultAction}" -o json` | `Deny`, `Deny` |
| Telemetry arrives (after any request through Front Door, runbook 04 §6) | KQL in `log-defenstack-<env>`: `AppRequests \| where TimeGenerated > ago(1h) \| summarize count() by AppRoleName` | One row per region with traffic |
| Secrets written (when `KEYVAULT_SECRETS_JSON` is non-empty) | §5.1 check | The same names in every regional vault |

Paste every output into the Phase 5 PR (spec §6 definition of done).

## 7. Rollback

- **Storage SKU:** an RA-GZRS → GRS change, done by reverting the commit and redeploying, is supported, but Azure converts redundancy asynchronously and it can take hours. Never go to LRS in prod.
- **Warm-standby read endpoint and reader role:** reverting does not delete them, because deployments are incremental. Remove them by hand:
  - `az network private-endpoint delete -g rg-defenstack-prod-eus -n <primary account>-secondary-pe`
  - `az role assignment delete --assignee <eus app principal> --scope <container id> --role 'Storage Blob Data Reader'`
- **App Insights:** reverting leaves the component and role in place, and the app settings point to it. Harmless. Delete the component with `az monitor app-insights component delete --app <name> -g <rg>`, after a redeploy without the settings.
- **Secrets:** see §5.1 "Remove". Purge protection means a deleted secret's name stays reserved until it is purged after 90 days.
- **Prod locks:** Key Vault and the spoke VNet are locked (`CanNotDelete`). Removing a private endpoint in the locked spoke may need the lock lifted first (`az lock list -g rg-defenstack-prod-eus --query "[].id" -o tsv`, then `az lock delete --ids <id>`); the next deployment recreates it.

## 8. Operations

- **Secret rotation:** rotate at the source system, then §5.1 "Add or rotate". Record the rotation in the change log, never the value.
- **Geo-replication health:** check `lastSyncTime` (§5.3) weekly. Phase 6 adds an alert on it.
- **Telemetry:** start in the workspace (`AppRequests`, `AppExceptions`, `AppDependencies`), filtered by `AppRoleName` per region. The App Insights blade works too, because the components are workspace-based.
- **Cost drivers** (`docs/cost.md` "Phase 5 delta"):
  - the RA-GZRS premium over GRS on the prod primary account, plus geo-replication data transfer;
  - one extra private endpoint (East US);
  - App Insights ingestion, billed as Log Analytics ingestion in the shared workspace.

### Operator notes

- `modules/appService.bicep` owns the App Service app settings (`siteConfig.appSettings`). Each deployment replaces the whole collection, so a setting added in the portal or with `az webapp config appsettings set` is lost on the next deploy. Put any lasting setting in Bicep.
- Key Vault secrets, behaviour to expect:
  - The deployment is incremental, so removing a name from `KEYVAULT_SECRETS_JSON` does not delete the secret. Delete it by hand, and purge it if you need to.
  - An empty or missing environment secret deploys `{}`, which writes nothing. The pipeline prints the count it prepared, so check that count.
  - Each deploy may create a new version of every secret, even when the value is unchanged.
  - Recreating a name that is soft-deleted fails with `Conflict` until it is recovered or purged.
  - No `contentType` or expiry is set.
- The plan job (what-if) runs without secrets by design, so secret writes do not appear in the plan that prod approvers review.
- Live check, one time: confirm the runner's Azure CLI accepts `--parameters params/<env>.bicepparam --parameters keyVaultSecrets=@<file>`. To do that, run `az deployment sub validate` with an empty `{}` file.
- On a self-hosted runner, restrict the temp secrets file to 0600, or use hosted runners only.
- Approval script, known limit: if Front Door's origin exists and is still Pending, and a spoofed matching request arrives before Front Door's own, the script can approve it. The check after approval then throws, because the origin does not reach Approved. Reject that connection and re-run, as runbook 04 section 5.2 describes.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| Step **Prepare Key Vault secrets** fails with `Secret name '<x>' is invalid` / `must have a non-empty string value` / `not valid JSON` | `KEYVAULT_SECRETS_JSON` breaks the rules in §4 step 2 | Fix the secret in the environment; the message names the secret, never the value |
| **Deploy** fails with `unrecognized arguments` or an error about combining a `.bicepparam` file with other parameters | Azure CLI too old to combine `--parameters <file>.bicepparam` with `--parameters name=value` | Use the CLI the workflow installs (GitHub's `ubuntu-latest` image); locally, upgrade the CLI (§2) |
| **Deploy** fails writing `Microsoft.KeyVault/vaults/secrets` with `Forbidden` | The deploying identity lacks `Microsoft.KeyVault/vaults/secrets/write` on the vault's resource group | Check the pipeline identity's `Contributor` on the region resource group (runbook 00b §6) |
| Prod **Deploy** rejects the storage update, for example a property combination not supported with `Standard_RAGZRS` (point-in-time restore or change feed) | A platform limit on RA-GZRS accounts that only the first prod deployment exercises | Record the exact error in the PR. Then either drop `restorePolicy` on the prod primary account (keep versioning and soft delete) or keep `Standard_GRS`, and update `ADR-020` |
| `AppRequests` stays empty, or the app logs `401` from the ingestion endpoint | The App Service identity lacks Monitoring Metrics Publisher, or `APPLICATIONINSIGHTS_AUTHENTICATION_STRING` is missing | Check the two §6 rows; redeploy |
| `AuthorizationFailed ... roleAssignments/write` for Storage Blob Data Reader or Monitoring Metrics Publisher | §4 step 1 was skipped | Re-apply the constrained assignment (§4 step 1) |
| `nslookup <account>-secondary...` returns a public IP in East US | The secondary endpoint's DNS record is missing, or the client does not use the firewall DNS proxy | Check the private endpoint's DNS zone group; check that the client is on the VPN or the spoke |
| `az storage blob restore` fails with `point in time restore is not enabled` | The account was created without `restorePolicy` (an older commit) | Redeploy; restore points start from when the policy was enabled |
