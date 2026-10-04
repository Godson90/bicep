# ADR-025: The subscription Activity Log diagnostic setting uses the preview API 2021-05-01-preview

## Context
The README's API version policy asks for the newest stable API version. The subscription Activity Log reaches Log Analytics, and so Sentinel's Azure Activity data, through a diagnostic setting at subscription scope. `Microsoft.Insights/diagnosticSettings` supports subscription scope only from `2021-05-01-preview`. The GA versions (`2016-09-01`, `2015-07-01`) predate subscription scope. The repository's resource-scope diagnostic settings already use the same preview version.

## Decision
- **`modules/activityLog.bicep`** (`targetScope = 'subscription'`) pins `Microsoft.Insights/diagnosticSettings@2021-05-01-preview`. The exception covers this one resource.
- The setting is named `activity-log-defenstack-<env>`, because dev and prod may share a subscription. It sends all eight Activity Log categories (Administrative, Security, ServiceHealth, Alert, Recommendation, Policy, Autoscale, ResourceHealth) to `log-defenstack-<env>`.
- The pipeline's custom subscription role gains `Microsoft.Insights/diagnosticSettings/read`, `/write` and `/delete`, named explicitly with no wildcard. The identity script updates an existing role in place when its actions differ (runbook 00b).
- No PSRule or linter suppression is needed: PSRule has no rule for this resource, and the linter's `use-recent-api-versions` rule is off.

## Consequences
- A preview API version can change or be retired with notice. If ARM ever rejects it, create the setting with `az monitor diagnostic-settings subscription create` (runbook 06 §9) and remove the module until a GA version exists.
- Each subscription allows at most five diagnostic settings. Dev and prod in one subscription use two.

## Revisit when
A GA `Microsoft.Insights/diagnosticSettings` version supports subscription scope. Move to it then, together with the resource-scope settings.
