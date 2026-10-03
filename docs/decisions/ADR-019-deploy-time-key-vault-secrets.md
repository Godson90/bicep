# ADR-019: Regional Key Vaults are kept in sync by deploy-time secrets written through Azure Resource Manager

## Context
The spec (§3) asks for "a regional Key Vault per stamp, synced by the pipeline". Every vault has `publicNetworkAccess: 'Disabled'` and is reachable only through its private endpoint. GitHub-hosted runners run on the public internet, so a pipeline step that calls the Key Vault data plane (`az keyvault secret set`) cannot reach any vault. The alternatives each had a cost:
- a self-hosted runner inside the VNet, which is new infrastructure to patch and secure;
- copying from the primary vault to the standby vault, which needs a data-plane path to both;
- temporarily allowing public access, which defeats the design.

No application secrets exist yet; there is no app code.

## Decision
- Secrets live in one GitHub **environment secret** per environment, `KEYVAULT_SECRETS_JSON`, a JSON object of `{ "secret-name": "value" }`.
- `deploy.yml`'s `apply` job validates it with `scripts/ConvertTo-KeyVaultSecretsParameter.ps1`. The rules: names are 1–127 letters, digits or hyphens; values are non-empty strings; nothing is ever printed except names. The job then passes the result to `az deployment sub create` as the `@secure()` object parameter `keyVaultSecrets`. The temporary file is removed with `if: always()`.
- `main.bicep` passes the same object to every stamp, and `modules/keyVault.bicep` creates one `Microsoft.KeyVault/vaults/secrets` resource per entry. Azure Resource Manager writes them through the control plane, so the runner never needs a network path to a vault. Every regional vault therefore receives the same values in the same deployment. That deployment is the sync.
- An empty or unset secret writes nothing. The plan job (validate and what-if) runs without the secret and never shows secret writes.
- Committed `.bicepparam` files must never set `keyVaultSecrets` (`tests/KeyVaultSecrets.Tests.ps1`).
- The user chose this option when Phase 5 was planned.

## Consequences
- The pipeline needs no data-plane role on the vaults. Its existing `Contributor` on each region resource group covers `Microsoft.KeyVault/vaults/secrets/write`.
- Anyone who can edit the environment secret, or run the deploy job, controls the secret values. The prod environment's required reviewers and two-approval flow (`ADR-012`) gate prod.
- Removing a name from the JSON does not delete the secret: deployments are incremental. Deletion is a manual, per-vault step (runbook 05 §5.1).
- Every deployment writes a new version of each secret, even when the value is unchanged. Consumers must read `latest`, not a pinned version.
- Writing secrets through Azure Resource Manager to a private, RBAC-mode vault is verified by the first dev deployment with a non-empty secret (runbook 05 §6 and §9).

## Revisit when
The app needs secrets that rotate outside deployments (for example, generated credentials), or a self-hosted runner in the VNet exists for other reasons.
