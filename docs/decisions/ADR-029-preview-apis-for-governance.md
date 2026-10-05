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
