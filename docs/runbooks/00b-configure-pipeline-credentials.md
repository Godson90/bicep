# 00b - Configure secure pipeline credentials for Azure (OIDC)

> Owning files: `.github/workflows/bicep-ci.yml` (PR what-if), `.github/workflows/deploy.yml` (deploy), `scripts/New-GitHubDeploymentIdentity.ps1`. Related: [00 - Pipeline and deployment identity](00-pipeline-and-identity.md), [ADR-007](../decisions/ADR-007-dev-environment-pipeline-exposure.md).

## 1. Purpose and scope

This runbook configures the credentials GitHub Actions uses to run `az` commands (what-if, validate, deploy) against Azure. Use it when the `what-if` or `deploy` job fails at the **Azure login** step.

**How authentication works. There is no password, client secret or certificate anywhere.**

1. The workflow job runs in the GitHub environment `dev` and has `permissions: id-token: write`.
2. GitHub issues the job a short-lived OIDC token. Its subject is `repo:Godson90/bicep:environment:dev`.
3. `azure/login@v2` presents that token to Microsoft Entra ID.
4. Entra ID accepts the token only because the deployment app registration has a **federated credential** with exactly that issuer, subject and audience.
5. Entra ID returns an Azure access token that lasts about one hour. `az` then runs as the app's service principal: the custom `DefenStack Subscription Deployment Operator` role at subscription scope lets it run the deployment itself, and `Contributor` plus `Role Based Access Control Administrator` on each of the environment's own resource groups let it create resources there (`docs/decisions/ADR-009-subscription-scope-pipeline-identity.md`).

The only values stored in GitHub are three **identifiers**, kept as environment variables: client ID, tenant ID and subscription ID. None of them grants access on its own.

**This runbook creates or changes:**

| Where | What |
|---|---|
| Microsoft Entra ID | One app registration and service principal (`gh-Godson90-bicep-dev-deploy`) with one federated credential (`github-dev`) |
| Azure RBAC, at subscription scope | Custom role `DefenStack Subscription Deployment Operator` (deployment read/write/validate/whatIf, deployment-operation read, subscription and resource-group read — no resource rights, and deliberately no deployment delete/cancel/exportTemplate), assigned to the identity |
| Azure RBAC, on `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3` only | `Contributor`; `Role Based Access Control Administrator` with a condition that allows assigning only `Storage Blob Data Contributor` |
| GitHub `Godson90/bicep` | Environment `dev` with three variables |

> **Do not** create a client secret, run `az ad sp create-for-rbac --sdk-auth`, or store an `AZURE_CREDENTIALS` JSON secret. All three put a long-lived credential into GitHub, and this design exists to avoid that.

## 2. Prerequisites

| Requirement | How to check |
|---|---|
| Entra role that can create app registrations (`Application Developer`, or `Cloud Application Administrator`, or tenant setting "Users can register applications" = Yes) | Entra admin center → **Roles & admins** → **My roles** |
| Azure role for the **first** run against a subscription (it creates the custom `DefenStack Subscription Deployment Operator` role definition, which needs `Microsoft.Authorization/roleDefinitions/write`): `Owner`, or `User Access Administrator`, at subscription scope. `Role Based Access Control Administrator` is **not** sufficient for this step — it cannot create a role definition. | `az role assignment list --assignee <your-upn> --scope /subscriptions/<subscription-id> -o table` |
| Azure role for **later** runs, once the custom role definition already exists (a second environment, or re-running the script): `Role Based Access Control Administrator` at subscription scope and on the target resource groups (plus `Contributor` to see resources) | Same command; check the role name column |
| Resource groups `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3` exist | `az group show -n rg-defenstack-dev-global --query name -o tsv`; `az group show -n rg-defenstack-dev-wus3 --query name -o tsv` |
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
| `AZURE_SUBSCRIPTION_ID` | Subscription containing `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3` | GitHub environment variable | No (identifier) |
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

Check that `subscription` is the one that contains `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3`. Write down `subscription` and `tenant`; you need them in Step 4.

### Step 2 (Method A) - Create the identity with the script

1. Preview. This changes nothing:

   ```powershell
   cd <repo-root>
   .\scripts\New-GitHubDeploymentIdentity.ps1 `
     -ResourceGroupNames 'rg-defenstack-dev-global','rg-defenstack-dev-wus3' `
     -GitHubRepository Godson90/bicep `
     -EnvironmentName dev `
     -WhatIf
   ```

   Expected: `What if:` lines for, in order:
   - the app registration
   - the service principal
   - the federated credential (subject `repo:Godson90/bicep:environment:dev`)
   - the custom role `DefenStack Subscription Deployment Operator`
   - assigning `DefenStack Subscription Deployment Operator` at subscription scope
   - `Contributor` and `Role Based Access Control Administrator` on `rg-defenstack-dev-global`
   - `Contributor` and `Role Based Access Control Administrator` on `rg-defenstack-dev-wus3`

   Any error at this point, such as `Multiple Entra applications are named …`, must be resolved before continuing. See §9.

2. Create. Run the same command without `-WhatIf`.

   Expected: the script prints three `gh variable set …` lines, then an object with `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`. Copy the three values. The first run against a fresh subscription can take a few minutes longer than later runs: creating the custom role and then assigning it needs the role to replicate first, so the script retries that assignment (up to 6 times, `-RoleReplicationWaitSeconds` apart, 20s by default).

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

3. **Custom subscription-scope role, `DefenStack Subscription Deployment Operator`.**
   1. Azure portal → **Subscriptions** → the target subscription → **Access control (IAM)** → **Roles** → **Add** → **Add custom role**.
   2. Recommended: skip the **Basics**/**Permissions** wizard and use the **JSON** tab instead — **Edit** → replace the contents with:

      ```json
      {
        "Name": "DefenStack Subscription Deployment Operator",
        "Description": "Run subscription-scope ARM deployments (validate, what-if, create) and read resource groups. Grants no resource permissions and cannot cancel or delete deployments.",
        "Actions": [
          "Microsoft.Resources/deployments/read",
          "Microsoft.Resources/deployments/write",
          "Microsoft.Resources/deployments/validate/action",
          "Microsoft.Resources/deployments/whatIf/action",
          "Microsoft.Resources/deployments/operations/read",
          "Microsoft.Resources/deployments/operationstatuses/read",
          "Microsoft.Resources/subscriptions/read",
          "Microsoft.Resources/subscriptions/resourceGroups/read"
        ],
        "NotActions": [],
        "AssignableScopes": ["/subscriptions/<subscription-id>"]
      }
      ```

      Replace `<subscription-id>` with the actual subscription ID, then **Review + create** → **Create**. This is exactly what the script writes, and it avoids typing each action by hand through the **Permissions** tab's search box.

      Alternative: use the **Permissions** tab and add these eight actions individually (search each by name): `Microsoft.Resources/deployments/read`, `Microsoft.Resources/deployments/write`, `Microsoft.Resources/deployments/validate/action`, `Microsoft.Resources/deployments/whatIf/action`, `Microsoft.Resources/deployments/operations/read`, `Microsoft.Resources/deployments/operationstatuses/read`, `Microsoft.Resources/subscriptions/read`, `Microsoft.Resources/subscriptions/resourceGroups/read`. Do **not** add `deployments/delete`, `deployments/cancel/action` or `deployments/exportTemplate/action` — none is needed to validate, what-if or create a deployment, and because this role is assigned at subscription scope, granting them would let this identity cancel or delete another environment's in-flight deployments or export its templates. Leave **Assignable scopes** at the subscription (do not narrow it further; the script assigns it there too).
   3. Back on the subscription's **Access control (IAM)** → **Add** → **Add role assignment** → select **DefenStack Subscription Deployment Operator** → **Members**: `gh-Godson90-bicep-dev-deploy` → **Review + assign**.

   This grants deployment operations and read-only visibility at subscription scope only — no rights over any resource, and no ability to cancel or delete a deployment record.

4. **Contributor, on each dev resource group.** Repeat for `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3`:
   1. Azure portal → the resource group → **Access control (IAM)** → **Add** → **Add role assignment**.
   2. Role **Contributor**.
   3. **Members** → **User, group, or service principal** → select `gh-Godson90-bicep-dev-deploy`.
   4. **Review + assign**.

5. **Role Based Access Control Administrator, constrained, on each dev resource group.** Repeat for `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3`:
   1. Same resource group → **Add role assignment**.
   2. Role **Role Based Access Control Administrator**.
   3. Members: the same app.
   4. **Conditions** tab → **Allow user to only assign selected roles to selected principals (fewer privileges)** → **Configure**:
      - Roles: **Storage Blob Data Contributor** only.
      - Principal types: **Service principals**.
      - Save.
   5. **Review + assign**.

   Never choose "Allow user to assign all roles". Never assign `Contributor` or `Role Based Access Control Administrator` at subscription scope — only the custom deployment role belongs there.

### Step 3 - Verify the Azure side (both methods)

```powershell
$clientId = '<AZURE_CLIENT_ID>'
$subscriptionId = '<AZURE_SUBSCRIPTION_ID>'
az ad app federated-credential list --id $clientId --query "[].{name:name,subject:subject,issuer:issuer}" -o table
az ad app credential list --id $clientId
$spId = az ad sp list --filter "appId eq '$clientId'" --query "[0].id" -o tsv
az role assignment list --assignee $spId --scope "/subscriptions/$subscriptionId" `
  --query "[].{role:roleDefinitionName,scope:scope,hasCondition:condition!=null}" -o table
az role assignment list --assignee $spId --resource-group rg-defenstack-dev-global `
  --query "[].{role:roleDefinitionName,scope:scope,hasCondition:condition!=null}" -o table
az role assignment list --assignee $spId --resource-group rg-defenstack-dev-wus3 `
  --query "[].{role:roleDefinitionName,scope:scope,hasCondition:condition!=null}" -o table
```

Expected:
- One federated credential, `github-dev`, with subject `repo:Godson90/bicep:environment:dev` and issuer `https://token.actions.githubusercontent.com`.
- `az ad app credential list` prints `[]`: no secrets or certificates.
- Exactly one role assignment at `/subscriptions/<sub>`: the custom `DefenStack Subscription Deployment Operator` role.
- Exactly two role assignments at `/subscriptions/<sub>/resourceGroups/rg-defenstack-dev-global`, and the same two at `/subscriptions/<sub>/resourceGroups/rg-defenstack-dev-wus3`:
  - `Contributor` (`hasCondition` False)
  - `Role Based Access Control Administrator` (`hasCondition` **True**)

Nothing else is expected at any of these three scopes.

**Stop** if the RBAC Administrator row shows `hasCondition` False. Delete it (`az role assignment delete --ids <id>`) and redo Step 2.

### Step 4 - Create the GitHub environment and variables

**Web UI (no GitHub CLI needed):**

1. `https://github.com/Godson90/bicep` → **Settings** → **Environments**.
2. If `dev` already exists, open it. The failed PR run may have created it automatically. Otherwise select **New environment**, enter `dev`, and **Configure environment**.
3. **Deployment branches and tags**: leave it at **No restriction**.
   - The PR `what-if` job runs from feature branches in this environment, so a branch rule would block it.
   - The `deploy` job is limited to `main` by its own `if: github.ref == 'refs/heads/main'` condition.
   - ADR-007 records this trade-off.
4. Leave **Required reviewers** off for dev. Prod gets reviewers below (§5).
5. **Environment variables** → **Add environment variable**, three times:

   | Name | Value |
   |---|---|
   | `AZURE_CLIENT_ID` | Application (client) ID |
   | `AZURE_TENANT_ID` | Tenant ID |
   | `AZURE_SUBSCRIPTION_ID` | Subscription ID |

   Use **Environment variables**, not **Environment secrets**, and not repository-level variables. The jobs read them from the `dev` environment.

   If the `dev` environment still has an `AZURE_RESOURCE_GROUP` variable from before Phase 1, delete it: the workflows no longer read it, and `main.bicep` now deploys at subscription scope to the resource groups it references directly.

**GitHub CLI alternative** (if `gh` is installed and signed in):

```powershell
gh api --method PUT repos/Godson90/bicep/environments/dev
gh variable set AZURE_CLIENT_ID --env dev --repo Godson90/bicep --body '<client-id>'
gh variable set AZURE_TENANT_ID --env dev --repo Godson90/bicep --body '<tenant-id>'
gh variable set AZURE_SUBSCRIPTION_ID --env dev --repo Godson90/bicep --body '<subscription-id>'
gh variable list --env dev --repo Godson90/bicep
gh variable delete AZURE_RESOURCE_GROUP --env dev --repo Godson90/bicep
```

### Step 5 - Re-run the pipeline

1. Open the pull request → **Checks** → `bicep-ci` → **Re-run jobs** → **Re-run failed jobs**. Alternatively, push any commit to the branch.
2. Open the `what-if` job log. Expected:
   - **azure/login** step: `Login successful.` (Federated token details are logged; no secret is used.)
   - **What-if against dev** step: a what-if listing. Changes should match the "Expected what-if" lists in `00a-apply-phase0-fixes.md` §5.
   - The PR gets a **What-if: dev (subscription scope, rg-defenstack-dev-*)** comment.

## 5. Manual and post-deployment steps

- The role assignments can take up to 10 minutes to propagate. If the first re-run fails with `AuthorizationFailed`, wait and re-run.
- Once `validate` and `what-if` are green, continue with `00a-apply-phase0-fixes.md` §4 (the dev dry run) before merging. Merging to `main` triggers `deploy.yml`, which uses the same credentials.
- **Prod.** Repeat this runbook for the `prod` environment:
  1. Create the prod resource groups first (`docs/runbooks/01-*.md` §4 step 2): `rg-defenstack-prod-global`, `rg-defenstack-prod-wus3` and `rg-defenstack-prod-eus`.
  2. Run the script with `-EnvironmentName prod -ResourceGroupNames 'rg-defenstack-prod-global','rg-defenstack-prod-wus3','rg-defenstack-prod-eus' -GrantLockManagement`. This creates a **separate** app registration (the script derives the name `gh-Godson90-bicep-prod-deploy`), its own federated credential (subject `repo:Godson90/bicep:environment:prod`), and grants it `Contributor` plus the constrained `Role Based Access Control Administrator` on each of the three prod resource groups, plus the `DefenStack Resource Lock Operator` role (from `-GrantLockManagement`) needed to manage the `CanNotDelete` locks prod deploys. It reuses the same subscription-scope `DefenStack Subscription Deployment Operator` custom role definition created for dev (one role definition, one assignment per identity).
  3. Create the GitHub environment `prod` with **Required reviewers** (at least 1) and **Deployment branches and tags: Selected branches → `main`**.
  4. Add the three `AZURE_*` variables (`AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`) to the `prod` environment, exactly as in Step 4 above but for `prod`.

  Never reuse the dev identity for prod.

## 6. Validation

| Check | Command / location | Expected result |
|---|---|---|
| Federated credential subject | `az ad app federated-credential list --id <client-id> --query "[].subject" -o tsv` | `repo:Godson90/bicep:environment:dev` |
| No long-lived secret | `az ad app credential list --id <client-id>` | `[]` |
| Least-privilege roles | Step 3 role query | `DefenStack Subscription Deployment Operator` at `/subscriptions/<sub>` only; `Contributor` (no condition) and `Role Based Access Control Administrator` (condition) on each of `rg-defenstack-dev-global` and `rg-defenstack-dev-wus3`; nothing else at subscription scope |
| GitHub variables | Settings → Environments → dev | Three `AZURE_*` variables; no environment secrets |
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

- Delete the three variables, or the whole `dev` environment, under GitHub **Settings** → **Environments**. Deleting the app registration also removes the subscription-scope `DefenStack Subscription Deployment Operator` role *assignment* to it, but leaves the role *definition* itself in place — it is shared with (or ready to be reused by) the prod identity; delete the role definition separately (`az role definition delete --name "DefenStack Subscription Deployment Operator"`) only once no identity uses it.

## 8. Operations

- **Rotation:** nothing to rotate. There are no stored secrets, and each run gets a fresh token that lasts about an hour.
- **Renaming the repo, organisation or environment** changes the token subject. Update the federated credential subject in the same change, otherwise login fails with `AADSTS70021`.
- **Assigning an extra role from Bicep** (for example Key Vault Secrets User in a later phase):
  1. Add the role's GUID to `-DelegatableRoleDefinitionIds`.
  2. Delete the existing RBAC Administrator assignment on **each** resource group the environment uses.
  3. Re-run the script. It refuses a mismatched condition on purpose.
- **Quarterly review:** re-run Step 3. The role list must be unchanged at all three scopes and the credential list must be empty.

## 9. Troubleshooting

| Symptom / error text | Cause | Fix |
|---|---|---|
| `Login failed … Not all values are present. Ensure 'client-id' and 'tenant-id' are supplied.` | Variables missing, created as secrets, or created at repo level instead of on the `dev` environment | Step 4: create them as **environment variables** on `dev` |
| `AADSTS70021: No matching federated identity record found for presented assertion` | Subject mismatch. Wrong environment name, owner/repo typo or case, or the job isn't running in environment `dev` | Compare the credential subject with `repo:Godson90/bicep:environment:dev`; confirm the job has `environment: dev` |
| `AADSTS700016: Application with identifier … was not found in the directory` | `AZURE_CLIENT_ID` or `AZURE_TENANT_ID` is wrong, or from another tenant | Re-copy both from the app registration **Overview** |
| `AADSTS700213` / audience error | Federated credential audience changed from the default | Set the audience to `api://AzureADTokenExchange` |
| `Unable to get ACTIONS_ID_TOKEN_REQUEST_URL env variable` | Job lacks `permissions: id-token: write`, or it's a fork PR | Workflows already grant it; fork PRs are skipped by design |
| `No subscriptions found for …` | No role assignment yet, or not yet propagated | Step 3; wait 10 minutes and re-run |
| `AuthorizationFailed … Microsoft.Resources/deployments/write … /subscriptions/<id>` | The subscription-scope `DefenStack Subscription Deployment Operator` role assignment is missing | Step 3 subscription-scope role query; re-run the script, or add the assignment manually (Method B step 3) |
| `AuthorizationFailed … Microsoft.Resources/deployments/whatIf/action` | `Contributor` missing on the target resource group, or not yet propagated | Step 3 resource-group role query; add `Contributor` |
| `AuthorizationFailed … Microsoft.Authorization/roleAssignments/write` with a condition in the message | Template assigns a role the condition doesn't allow | Expected for disallowed roles; to allow one deliberately, see §8 |
| `ResourceGroupNotFound` | The resource group was not pre-created, `AZURE_SUBSCRIPTION_ID` is wrong, or the RG is in another subscription | Create the resource group first (runbook 01); check `AZURE_SUBSCRIPTION_ID` |
| Script: `Role definition 'DefenStack Subscription Deployment Operator' not found` on first run | The custom role was just created and has not finished replicating through Entra ID yet | Expected transiently; the script retries the assignment 6 times, `-RoleReplicationWaitSeconds` (default 20s) apart, before failing |
| Script: `Role definition <guid> is privileged and cannot be delegated to the pipeline.` | `-DelegatableRoleDefinitionIds` included `Owner`, `User Access Administrator`, `Role Based Access Control Administrator` or `Contributor` | By design: these roles are never delegable, since the pipeline identity itself only has an ABAC-constrained `Role Based Access Control Administrator`, and delegating one of these would let it re-grant itself broader rights |
| Script: `Multiple Entra applications are named …` | Duplicate display names in the tenant | Delete the stale app, or pass a unique `-DisplayName` |
| Script: `An unconditioned 'Role Based Access Control Administrator' assignment already exists …` | A manual or portal assignment without the script's condition exists | Delete the named assignment and re-run the script |
| `what-if` job skipped | PR comes from a fork | Expected: forks never receive Azure tokens |
| Local `SSL certificate problem: unable to get local issuer certificate` | Corporate TLS inspection | `git -c http.sslBackend=schannel …` (see §2) |
