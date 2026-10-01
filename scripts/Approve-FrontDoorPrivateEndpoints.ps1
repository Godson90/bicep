<#
.SYNOPSIS
Approves the pending private endpoint connections that Azure Front Door creates on each App Service origin.

.DESCRIPTION
Front Door reaches every App Service over Private Link. Each origin creates a private endpoint connection on the
app that stays Pending until someone approves it, and until then Front Door returns errors for that origin.
This script approves only connections whose request message is the one modules/frontDoor.bicep sets
(defenstack-frontdoor by default). Any other pending connection is reported and left alone.

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
    @(($json -join "`n") | ConvertFrom-Json)
}

foreach ($id in $AppServiceId) {
    $appName = ($id -split '/')[-1]
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $connections = Get-PrivateEndpointConnections $id
        $states = $connections | ForEach-Object {
            [pscustomobject]@{
                Id          = $_.id
                Name        = $_.name
                Status      = $_.properties.privateLinkServiceConnectionState.status
                Description = [string]$_.properties.privateLinkServiceConnectionState.description
            }
        }

        foreach ($pending in @($states | Where-Object { $_.Status -eq 'Pending' })) {
            if ($pending.Description -ne $RequestMessage) {
                Write-Warning "$appName`: leaving pending connection '$($pending.Name)' (request message '$($pending.Description)'): not a Front Door request from this deployment."
                continue
            }
            if ($PSCmdlet.ShouldProcess($pending.Name, "Approve Front Door private endpoint connection on $appName")) {
                az network private-endpoint-connection approve --id $pending.Id --description $approvalDescription --output none
                if ($LASTEXITCODE -ne 0) {
                    throw "Approving private endpoint connection '$($pending.Name)' on $appName failed."
                }
                Write-Output "$appName`: approved Front Door connection '$($pending.Name)'."
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
            throw "$appName`: no Front Door private endpoint connection was approved within $TimeoutSeconds seconds. Check the origin in the Front Door profile, then re-run this script (runbook 04 §9)."
        }
        Write-Output "$appName`: waiting for Front Door to create its private endpoint connection..."
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
