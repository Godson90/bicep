# ADR-018: Front Door deploys from main.bicep after the stamps; the pipeline approves its Private Link connections

## Context
The spec (§4) has `modules/global.bicep` create Front Door. In practice, each Front Door origin needs its App Service's resource ID and hostname, and those come from the region stamps. The stamps in turn need the global layer's workspace and DNS zone IDs. Creating Front Door inside `global.bicep` would therefore form a dependency cycle (global → stamps → global).

Each Private Link origin also creates a private endpoint connection on its App Service that stays **Pending** until the app's owner approves it. The spec (§3) requires this manual step to be in the runbook and scripted with `az network private-endpoint-connection approve`. When Phase 4 was planned, the user chose to have the deploy pipeline run that script.

## Decision
- `main.bicep` calls `modules/frontDoor.bicep` as a separate module, `frontDoor`, scoped to `rg-defenstack-<env>-global` and deployed after both stamps. Front Door therefore lives in the global resource group as the spec intends, but is not created by `global.bicep`.
- Origins are built in `main.bicep`: the primary stamp's app first (priority 1), then the secondary stamp's app (priority 2) when `deploySecondaryRegion` is true.
- Every origin sets the Private Link request message `defenstack-frontdoor`. `scripts/Approve-FrontDoorPrivateEndpoints.ps1` approves **only** pending connections carrying that exact message. It writes an approval description that starts with the same text, so approved connections stay recognizable. It waits up to 15 minutes for Front Door to create each connection, and fails the job if none is approved.
- `deploy.yml` runs the script in the `apply` job right after `az deployment sub create`, reading the `appServiceIds` deployment output.
- The custom domain is an optional parameter (`customDomainHostName`), empty in both committed parameter files until the domain exists. The domain is hosted at an external DNS provider, so the TXT validation and CNAME cutover are manual steps (runbook 04 §5.1).

## Consequences
- A new region or a recreated profile becomes reachable without an operator. A Pending connection never sits unnoticed, because the job fails when no approval happens.
- The pipeline identity approves connections using its existing `Contributor` on the region resource groups. No new role is needed.
- A pending connection with any other message is never approved automatically. The script warns, and runbook 04 §5.2 treats it as a security incident.
- The request message is a shared contract between `modules/frontDoor.bicep` (the `privateLinkRequestMessage` variable, also an output) and the script's `-RequestMessage` default. Changing one requires changing the other.

## Revisit when
Azure supports auto-approval of Front Door Private Link connections for a trusted profile, or the custom domain moves to an Azure DNS zone (Bicep could then write the TXT and CNAME records).
