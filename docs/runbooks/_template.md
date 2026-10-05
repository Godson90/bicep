# NN - <Component> runbook

> Owning module(s): `modules/<file>.bicep`. Spec section: <link>.

## 1. Purpose and scope
What this runbook deploys or changes, and which resources it creates, modifies, or deletes.

## 2. Prerequisites
- Azure roles (scope and role name) for the operator or pipeline identity.
- Provider or feature registrations (with the `az` command to register and verify).
- Tools and minimum versions (Azure CLI, Bicep CLI, PowerShell, gh).
- Network path required (for example: "must run from P2S VPN or Bastion jump host").

## 3. Parameters
| Name | Default | Prod value | Rationale |
|---|---|---|---|

## 4. Step-by-step deployment
Numbered steps. Every command is copy-pasteable PowerShell. Each step says what to check in its output before continuing.

## 5. Manual and post-deployment steps
Anything the template cannot do (approvals, role cleanup, client configuration).

## 6. Validation
| Check | Command | Expected result |
|---|---|---|

## 7. Rollback
Exact steps to return to the previous state, including what cannot be rolled back.

## 8. Operations
Day-2 tasks: rotation, scaling, rule changes, cost drivers.

## 9. Troubleshooting
| Symptom / error text | Cause | Fix |
|---|---|---|
