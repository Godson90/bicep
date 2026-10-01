<#
.SYNOPSIS
Approves the pending private endpoint connections that Azure Front Door creates on each App Service origin.

.DESCRIPTION
Front Door reaches every App Service over Private Link. Each origin creates a private endpoint connection on the
app that stays Pending until someone approves it, and until then Front Door returns errors for that origin.
This script approves only connections whose request message is the one modules/frontDoor.bicep sets
(defenstack-frontdoor by default). Any other pending connection is reported and left alone.

Because the request message is free text, a third party could set the same message on an unrelated private
endpoint request. To guard against that, for each app:
  - A pending connection whose request message does not match is always left alone (warned about, never
    approved).
  - If a Front Door connection is already Approved (its description starts with the request message) and
    another pending connection also carries the exact request message, nothing is approved. The script throws,
    naming the pending connection(s), so an operator can verify them before approving by hand (runbook 04
    section 5.2).
  - If more than one pending connection carries the exact request message and none is approved yet, nothing is
    approved either, and the script throws the same way.
  - Otherwise, when exactly one pending connection carries the exact request message and none is approved yet,
    that connection is approved and its private endpoint id is reported.

For each app it waits until a Front Door connection is Approved, approving pending ones as they appear,
because Front Door creates the connection a few minutes after the origin is deployed.
Runs in deploy.yml after the deployment, and by hand from runbook 04.

.EXAMPLE
./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId /subscriptions/<sub>/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/<app>
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$')]
    [string[]]$AppServiceId,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9-]{1,64}$')]
    [string]$RequestMessage = 'defenstack-frontdoor',

    [Parameter()]
    [ValidateRange(0, 3600)]
    [int]$TimeoutSeconds = 900,

    [Parameter()]
    [ValidateRange(1, 300)]
    [int]$PollIntervalSeconds = 30
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
}

# The approval description keeps the request message as a prefix, so an approved Front Door connection stays recognizable.
$approvalDescription = "$RequestMessage approved by Approve-FrontDoorPrivateEndpoints.ps1"

function Get-PrivateEndpointConnections([string]$ResourceId) {
    $json = az network private-endpoint-connection list --id $ResourceId --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list private endpoint connections for $ResourceId."
    }
    # On Windows PowerShell 5.1, ConvertFrom-Json does not reliably unroll a JSON array when the result is
    # wrapped directly in @(...): several connections can collapse into a single merged object instead of
    # staying separate. Force the unroll with ForEach-Object so each connection stays its own object (and an
    # empty or missing array becomes zero items).
    $parsed = ($json -join "`n") | ConvertFrom-Json
    @($parsed | ForEach-Object { $_ })
}

foreach ($id in $AppServiceId) {
    $appName = ($id -split '/')[-1]
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $connections = Get-PrivateEndpointConnections $id
        $states = $connections | ForEach-Object {
            [pscustomobject]@{
                Id                = $_.id
                Name              = $_.name
                Status            = $_.properties.privateLinkServiceConnectionState.status
                Description       = [string]$_.properties.privateLinkServiceConnectionState.description
                PrivateEndpointId = $_.properties.privateEndpoint.id
            }
        }

        $approvedFrontDoor = @($states | Where-Object { $_.Status -eq 'Approved' -and $_.Description.StartsWith($RequestMessage) })
        $pendingMatching = @($states | Where-Object { $_.Status -eq 'Pending' -and $_.Description -eq $RequestMessage })
        $pendingOther = @($states | Where-Object { $_.Status -eq 'Pending' -and $_.Description -ne $RequestMessage })

        foreach ($other in $pendingOther) {
            Write-Warning "$appName`: leaving pending connection '$($other.Name)' (request message '$($other.Description)'): not a Front Door request from this deployment."
        }

        if ($approvedFrontDoor.Count -gt 0 -and $pendingMatching.Count -gt 0) {
            $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
            throw "$appName`: a Front Door connection is already approved, but a pending connection with the same request message ('$RequestMessage') also exists ($names). This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
        }

        if ($pendingMatching.Count -gt 1) {
            $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
            throw "$appName`: multiple pending connections share the request message '$RequestMessage' ($names). This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
        }

        if ($approvedFrontDoor.Count -eq 0 -and $pendingMatching.Count -eq 1) {
            $pending = $pendingMatching[0]
            if ($PSCmdlet.ShouldProcess($pending.Name, "Approve Front Door private endpoint connection on $appName")) {
                az network private-endpoint-connection approve --id $pending.Id --description $approvalDescription --output none
                if ($LASTEXITCODE -ne 0) {
                    throw "Approving private endpoint connection '$($pending.Name)' on $appName failed."
                }
                Write-Output "$appName`: approved Front Door connection '$($pending.Name)' (private endpoint $($pending.PrivateEndpointId))."
            }
        }

        if ($WhatIfPreference) {
            break
        }

        $approved = @(Get-PrivateEndpointConnections $id | Where-Object {
                $_.properties.privateLinkServiceConnectionState.status -eq 'Approved' -and
                ([string]$_.properties.privateLinkServiceConnectionState.description).StartsWith($RequestMessage)
            })
        if ($approved.Count -gt 0) {
            Write-Output "$appName`: $($approved.Count) Front Door connection(s) approved."
            break
        }

        if ((Get-Date) -ge $deadline) {
            throw "$appName`: no Front Door private endpoint connection was approved within $TimeoutSeconds seconds. Check the origin in the Front Door profile, then re-run this script (runbook 04 section 9)."
        }
        Write-Output "$appName`: waiting for Front Door to create its private endpoint connection..."
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
