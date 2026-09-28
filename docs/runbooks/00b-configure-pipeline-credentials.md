# 00b - Configure secure pipeline credentials for Azure (OIDC)

> Owning files: `.github/workflows/bicep-ci.yml` (PR what-if), `.github/workflows/deploy.yml` (deploy), `scripts/New-GitHubDeploymentIdentity.ps1`. Related: [00 - Pipeline and deployment identity](00-pipeline-and-identity.md), [ADR-007](../decisions/ADR-007-dev-environment-pipeline-exposure.md).

## 1. Purpose and scope

This runbook configures the credentials GitHub Actions uses to run `az` commands (what-if, validate, deploy) against Azure. Use it when the `what-if` or `deploy` job fails at the **Azure login** step.

**How authentication works. There is no password, client secret or certificate anywhere.**

1. The workflow job runs in the GitHub environment `dev` and has `permissions: id-token: write`.
2. GitHub issues the job a short-lived OIDC token. Its subject is `repo:Godson90/bicep:environment:dev`.
3. `azure/login@v2` presents that token to Microsoft Entra ID.
4. Entra ID accepts the token only because the deployment app registration has a **federated credential** with exactly that issuer, subject and audience.
5. Entra ID returns an Azure access token that lasts about one hour. `az` then runs as the app's service principal, limited to the roles assigned on the `defenStack` resource group.

The only values stored in GitHub are four **identifiers**, kept as environment variables: client ID, tenant ID, subscription ID and resource group name. None of them grants access on its own.

**This runbook creates or changes:**

| Where | What |
|---|---|
| Microsoft Entra ID | One app registration and service principal (`gh-Godson90-bicep-dev-deploy`) with one federated credential (`github-dev`) |
| Azure RBAC, on `defenStack` only | `Contributor`; `Role Based Access Control Administrator` with a condition that allows assigning only `Storage Blob Data Contributor` |
| GitHub `Godson90/bicep` | Environment `dev` with four variables |

> **Do not** create a client secret, run `az ad sp create-for-rbac --sdk-auth`, or store an `AZURE_CREDENTIALS` JSON secret. All three put a long-lived credential into GitHub, and this design exists to avoid that.

## 2. Prerequisites

| Requirement | How to check |
|---|---|
| Entra role that can create app registrations (`Application Developer`, or `Cloud Application Administrator`, or tenant setting "Users can register applications" = Yes) | Entra admin center → **Roles & admins** → **My roles** |
| Azure role that can create role assignments on `defenStack`: `Owner`, or `User Access Administrator`, or `Role Based Access Control Administrator` (plus `Contributor` to see resources) | `az role assignment list --assignee <your-upn> --resource-group defenStack -o table` |
| Resource group `defenStack` exists | `az group show -n defenStack --query name -o tsv` |
| GitHub admin access to `Godson90/bicep` (needed for **Settings** → **Environments**) | Repository page shows the **Settings** tab |
| Azure CLI 2.90+ signed in to the right tenant and subscription | `az version`; `az account show --query "{sub:id,tenant:tenantId}" -o table` |
| PowerShell 5.1 or 7 (Method A only) | `$PSVersionTable.PSVersion` |

**Git or Azure CLI TLS errors on a corporate network.** Errors such as `SSL certificate problem: unable to get local issuer certificate` mean a TLS-inspecting proxy's root certificate is in the Windows store but not in the tool's own bundle.

- For Git, use the Windows store: `git -c http.sslBackend=schannel <command>`. To make it permanent: `git config --global http.sslBackend schannel`.
- Never turn certificate verification off.

## 3. Parameters

| Name | Value for dev | Where it is used | Secret? |
|---|---|---|---|
| GitHub repository | `Godson90/bicep` | Federated credential subject | No |
| GitHub environment | `dev` | Job `environment:` in both workflows; federated credential subject | No |
| Federated subject | `repo:Godson90/bicep:environment:dev` | Entra federated credential | No |
| Issuer | `https://token.actions.githubusercontent.com` | Entra federated credential | No |
| Audience | `api://AzureADTokenExchange` | Entra federated credential | No |
| `AZURE_CLIENT_ID` | App registration **Application (client) ID** | GitHub environment variable | No (identifier) |
| `AZURE_TENANT_ID` | Directory (tenant) ID | GitHub environment variable | No (identifier) |
| `AZURE_SUBSCRIPTION_ID` | Subscription containing `defenStack` | GitHub environment variable | No (identifier) |
| `AZURE_RESOURCE_GROUP` | `defenStack` | GitHub environment variable | No |
| Delegatable role | `Storage Blob Data Contributor` (`ba92f5b4-2d11-453d-a403-e96b0029c9fe`) | RBAC Administrator condition | No |

The workflows read these values with `vars.*`, so they **must be created as variables, not secrets**. A secret with the same name is ignored.

## 4. Step-by-step setup

Pick **one** method for the Azure side:
- **Method A** (script, recommended) produces exactly the condition the script checks on later runs.
- **Method B** (Azure portal) is for operators who cannot run PowerShell.

Do not mix them. The script refuses to reuse an RBAC Administrator assignment whose condition differs from its own, and the portal generates a different condition.

### Step 1 - Sign in and select the subscription

```powershell
az login
az account set --subscription <subscription-id>
az account show --query "{name:name,subscription:id,tenant:tenantId}" -o table
```

Check that `subscription` is the one that contains `defenStack`. Write down `subscription` and `tenant`; you need them in Step 4.

### Step 2 (Method A) - Create the identity with the script

1. Preview. This changes nothing:

   ```powershell
   cd <repo-root>
   .\scripts\New-GitHubDeploymentIdentity.ps1 `
     -ResourceGroupName defenStack `
     -GitHubRepository Godson90/bicep `
     -EnvironmentName dev `
     -WhatIf
   ```

   Expected: `What if:` lines for, in order:
   - the app registration
   - the service principal
   - the federated credential (subject `repo:Godson90/bicep:environment:dev`)
   - `Contributor`
   - `Role Based Access Control Administrator`

   Any error at this point, such as `Multiple Entra applications are named …`, must be resolved before continuing. See §9.

2. Create. Run the same command without `-WhatIf`.

   Expected: the script prints four `gh variable set …` lines, then an object with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` and `AZURE_RESOURCE_GROUP`. Copy the four values.

3. Continue at Step 3.

### Step 2 (Method B) - Create the identity in the Azure portal

1. **App registration.**
   1. Entra admin center → **App registrations** → **New registration**.
   2. Name `gh-Godson90-bicep-dev-deploy`; Supported account types **Single tenant**; no redirect URI.
   3. Select **Register**.
   4. Copy the **Application (client) ID** and **Directory (tenant) ID**.

2. **Federated credential.**
   1. In the app: **Certificates & secrets** → **Federated credentials** → **Add credential**.
   2. Scenario: **GitHub Actions deploying Azure resources**.
   3. Organization `Godson90`; Repository `bicep`; Entity type **Environment**; GitHub environment name `dev`.
   4. Name `github-dev`.
   5. Leave Issuer and Audience at their defaults (`https://token.actions.githubusercontent.com`, `api://AzureADTokenExchange`).
   6. Select **Add**.

   Check that the displayed subject is exactly `repo:Godson90/bicep:environment:dev`. Case matters, and so does the environment name.

   Do **not** open the **Client secrets** tab.

3. **Contributor.**
   1. Azure portal → resource group `defenStack` → **Access control (IAM)** → **Add** → **Add role assignment**.
   2. Role **Contributor**.
   3. **Members** → **User, group, or service principal** → select `gh-Godson90-bicep-dev-deploy`.
   4. **Review + assign**.

4. **Role Based Access Control Administrator, constrained.**
   1. Same resource group → **Add role assignment**.
   2. Role **Role Based Access Control Administrator**.
   3. Members: the same app.
   4. **Conditions** tab → **Allow user to only assign selected roles to selected principals (fewer privileges)** → **Configure**:
      - Roles: **Storage Blob Data Contributor** only.
      - Principal types: **Service principals**.
      - Save.
   5. **Review + assign**.

   Never choose "Allow user to assign all roles".

### Step 3 - Verify the Azure side (both methods)

```powershell
$clientId = '<AZURE_CLIENT_ID>'
az ad app federated-credential list --id $clientId --query "[].{name:name,subject:subject,issuer:issuer}" -o table
az ad app credential list --id $clientId
$spId = az ad sp list --filter "appId eq '$clientId'" --query "[0].id" -o tsv
az role assignment list --assignee $spId --resource-group defenStack `
  --query "[].{role:roleDefinitionName,scope:scope,hasCondition:condition!=null}" -o table
```

Expected:
- One federated credential, `github-dev`, with subject `repo:Godson90/bicep:environment:dev` and issuer `https://token.actions.githubusercontent.com`.
- `az ad app credential list` prints `[]`: no secrets or certificates.
- Exactly two role assignments at `/subscriptions/<sub>/resourceGroups/defenStack`:
  - `Contributor` (`hasCondition` False)
  - `Role Based Access Control Administrator` (`hasCondition` **True**)

**Stop** if the RBAC Administrator row shows `hasCondition` False. Delete it (`az role assignment delete --ids <id>`) and redo Step 2.

### Step 4 - Create the GitHub environment and variables

**Web UI (no GitHub CLI needed):**

1. `https://github.com/Godson90/bicep` → **Settings** → **Environments**.
2. If `dev` already exists, open it. The failed PR run may have created it automatically. Otherwise select **New environment**, enter `dev`, and **Configure environment**.
3. **Deployment branches and tags**: leave it at **No restriction**.
   - The PR `what-if` job runs from feature branches in this environment, so a branch rule would block it.
   - The `deploy` job is limited to `main` by its own `if: github.ref == 'refs/heads/main'` condition.
   - ADR-007 records this trade-off.
4. Leave **Required reviewers** off for dev. Prod gets reviewers in Phase 1.
5. **Environment variables** → **Add environment variable**, four times:

   | Name | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | Application (client) ID |
   | `AZURE_TENANT_ID` | Tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | Subscription ID |
   | `AZURE_RESOURCE_GROUP` | `defenStack` |

   Use **Environment variables**, not **Environment secrets**, and not repository-level variables. The jobs read them from the `dev` environment.

**GitHub CLI alternative** (if `gh` is installed and signed in):

```powershell
gh api --method PUT repos/Godson90/bicep/environments/dev
gh variable set AZURE_CLIENT_ID --env dev --repo Godson90/bicep --body '<client-id>'
gh variable set AZURE_TENANT_ID --env dev --repo Godson90/bicep --body '<tenant-id>'
gh variable set AZURE_SUBSCRIPTION_ID --env dev --repo Godson90/bicep --body '<subscription-id>'
gh variable set AZURE_RESOURCE_GROUP --env dev --repo Godson90/bicep --body 'defenStack'
gh variable list --env dev --repo Godson90/bicep
```

### Step 5 - Re-run the pipeline

1. Open the pull request → **Checks** → `bicep-ci` → **Re-run jobs** → **Re-run failed jobs**. Alternatively, push any commit to the branch.
2. Open the `what-if` job log. Expected:
   - **azure/login** step: `Login successful.` (Federated token details are logged; no secret is used.)
   - **What-if against dev** step: a what-if listing. Changes should match the "Expected what-if" lists in `00a-apply-phase0-fixes.md` §5.
   - The PR gets a **What-if: dev (`defenStack`)** comment.

## 5. Manual and post-deployment steps

- The role assignments can take up to 10 minutes to propagate. If the first re-run fails with `AuthorizationFailed`, wait and re-run.
- Once `validate` and `what-if` are green, continue with `00a-apply-phase0-fixes.md` §4 (the dev dry run) before merging. Merging to `main` triggers `deploy.yml`, which uses the same credentials.
- **Prod (Phase 1).** Repeat this runbook with:
  - `-EnvironmentName prod -GrantLockManagement` against the prod resource group;
  - a **separate** app registration (the script derives the name `gh-Godson90-bicep-prod-deploy`);
  - a GitHub environment `prod` with **Required reviewers** and **Deployment branches: Selected branches → `main`**.

  Never reuse the dev identity for prod.

## 6. Validation

| Check | Command / location | Expected result |
|---|---|---|
| Federated credential subject | `az ad app federated-credential list --id <client-id> --query "[].subject" -o tsv` | `repo:Godson90/bicep:environment:dev` |
| No long-lived secret | `az ad app credential list --id <client-id>` | `[]` |
| Least-privilege roles | Step 3 role query | `Contributor` (no condition) and `Role Based Access Control Administrator` (condition) at the `defenStack` scope only; nothing at subscription scope |
| GitHub variables | Settings → Environments → dev | Four `AZURE_*` variables; no environment secrets |
| Pipeline login | PR → `what-if` job → azure/login step | `Login successful.` |
| Sign-in audit | Entra admin center → **Monitoring** → **Sign-in logs** → **Service principal sign-ins** | Successful sign-ins for `gh-Godson90-bicep-dev-deploy`, credential type **Federated identity credential** |

## 7. Rollback

- **Stop the pipeline from reaching Azure immediately:** delete the federated credential. Tokens already issued expire within about an hour.

  ```powershell
  az ad app federated-credential delete --id <client-id> --federated-credential-id github-dev
  ```

- **Remove all access:**

  ```powershell
  $spId = az ad sp list --filter "appId eq '<client-id>'" --query "[0].id" -o tsv
  az role assignment list --assignee $spId --all --query "[].id" -o tsv | ForEach-Object { az role assignment delete --ids $_ }
  az ad app delete --id <client-id>
  ```

- Delete the four variables, or the whole `dev` environment, under GitHub **Settings** → **Environments**.

## 8. Operations

- **Rotation:** nothing to rotate. There are no stored secrets, and each run gets a fresh token that lasts about an hour.
- **Renaming the repo, organisation or environment** changes the token subject. Update the federated credential subject in the same change, otherwise login fails with `AADSTS70021`.
- **Assigning an extra role from Bicep** (for example Key Vault Secrets User in a later phase):
  1. Add the role's GUID to `-DelegatableRoleDefinitionIds`.
  2. Delete the existing RBAC Administrator assignment.
  3. Re-run the script. It refuses a mismatched condition on purpose.
- **Quarterly review:** re-run Step 3. The role list must be unchanged and the credential list must be empty.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| `Login failed … Not all values are present. Ensure 'client-id' and 'tenant-id' are supplied.` | Variables missing, created as secrets, or created at repo level instead of on the `dev` environment | Step 4: create them as **environment variables** on `dev` |
| `AADSTS70021: No matching federated identity record found for presented assertion` | Subject mismatch. Wrong environment name, owner/repo typo or case, or the job isn't running in environment `dev` | Compare the credential subject with `repo:Godson90/bicep:environment:dev`; confirm the job has `environment: dev` |
| `AADSTS700016: Application with identifier … was not found in the directory` | `AZURE_CLIENT_ID` or `AZURE_TENANT_ID` is wrong, or from another tenant | Re-copy both from the app registration **Overview** |
| `AADSTS700213` / audience error | Federated credential audience changed from the default | Set the audience to `api://AzureADTokenExchange` |
| `Unable to get ACTIONS_ID_TOKEN_REQUEST_URL env variable` | Job lacks `permissions: id-token: write`, or it's a fork PR | Workflows already grant it; fork PRs are skipped by design |
| `No subscriptions found for …` | No role assignment yet, or not yet propagated | Step 3; wait 10 minutes and re-run |
| `AuthorizationFailed … Microsoft.Resources/deployments/whatIf/action` | `Contributor` missing on `defenStack`, or not yet propagated | Step 3 role query; add `Contributor` |
| `AuthorizationFailed … Microsoft.Authorization/roleAssignments/write` with a condition in the message | Template assigns a role the condition doesn't allow | Expected for disallowed roles; to allow one deliberately, see §8 |
| `ResourceGroupNotFound` | `AZURE_RESOURCE_GROUP` wrong, or the RG is in another subscription | Fix the variable; check `AZURE_SUBSCRIPTION_ID` |
| Script: `Multiple Entra applications are named …` | Duplicate display names in the tenant | Delete the stale app, or pass a unique `-DisplayName` |
| Script: `An unconditioned 'Role Based Access Control Administrator' assignment already exists …` | A manual or portal assignment without the script's condition exists | Delete the named assignment and re-run the script |
| `what-if` job skipped | PR comes from a fork | Expected: forks never receive Azure tokens |
| Local `SSL certificate problem: unable to get local issuer certificate` | Corporate TLS inspection | `git -c http.sslBackend=schannel …` (see §2) |
