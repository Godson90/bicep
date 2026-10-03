<#
.SYNOPSIS
Approves the pending private endpoint connections that Azure Front Door creates on each App Service origin, and
waits until Front Door's own origin status confirms the Private Link is Approved.

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
  Every request message comparison is case-sensitive (ordinal), so a message that differs only in case is
  treated as unrelated, never approved.

An approved connection is not, by itself, proof that Front Door is using it: approving is this script's own
action, and a stale or unrelated connection could coincidentally be approved by someone else. The script
therefore waits for Front Door's own view, the origin group's `sharedPrivateLinkResource.status`, read with
`az afd origin list`, to report Approved for the origin whose private link targets this app. Only then is the
app done. If this run approved a connection but the origin never reaches Approved by the deadline, the script
throws a distinct message, because the connection it approved may not be the one Front Door is actually using.
If no origin in the given profile/origin group references the app at all, it throws a different message once
the deadline passes.

Runs in deploy.yml after the deployment, and by hand from runbook 04.

A matching Pending request for an App Service that no origin in the origin group references is refused (the
script approves nothing and throws): Front Door creates its origin before it sends the request, so such a request
cannot be Front Door's.

.EXAMPLE
./scripts/Approve-FrontDoorPrivateEndpoints.ps1 -AppServiceId /subscriptions/<sub>/resourceGroups/rg-defenstack-dev-wus3/providers/Microsoft.Web/sites/<app> -FrontDoorProfileName afd-defenstack-dev -FrontDoorResourceGroupName rg-defenstack-dev-global
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^/subscriptions/[0-9a-fA-F-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Web/sites/[^/]+$')]
    [string[]]$AppServiceId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9-]{1,90}$')]
    [string]$FrontDoorProfileName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[-\w._()]{1,90}$')]
    [string]$FrontDoorResourceGroupName,

    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9-]{1,90}$')]
    [string]$OriginGroupName = 'app',

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

function Get-FrontDoorOrigins {
    $json = az afd origin list --profile-name $FrontDoorProfileName --resource-group $FrontDoorResourceGroupName --origin-group-name $OriginGroupName --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to list Front Door origins for $FrontDoorProfileName/$FrontDoorResourceGroupName/$OriginGroupName."
    }
    # Same Windows PowerShell 5.1 array-unrolling guard as Get-PrivateEndpointConnections.
    $parsed = ($json -join "`n") | ConvertFrom-Json
    @($parsed | ForEach-Object { $_ })
}

# `az afd origin list`/`show` print a FLATTENED shape: sharedPrivateLinkResource sits at the top level of each
# origin object, not nested under properties (runbook 04 uses this shape directly: --query
# sharedPrivateLinkResource.status). Fall back to properties.sharedPrivateLinkResource only when the top-level
# property is absent, in case an older/alternate shape is ever returned.
function Get-SharedPrivateLinkResource($origin) {
    if ($origin.sharedPrivateLinkResource) {
        return $origin.sharedPrivateLinkResource
    }
    if ($origin.properties -and $origin.properties.sharedPrivateLinkResource) {
        return $origin.properties.sharedPrivateLinkResource
    }
    return $null
}

function Find-MatchingOrigin([object[]]$Origins, [string]$ResourceId) {
    $Origins | Where-Object {
        $splr = Get-SharedPrivateLinkResource $_
        $splr -and $splr.privateLink -and [string]$splr.privateLink.id -ieq $ResourceId
    } | Select-Object -First 1
}

foreach ($id in $AppServiceId) {
    $appName = ($id -split '/')[-1]
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $approvedConnectionForApp = $null
    $matchingOrigin = $null
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

        # Every comparison against $RequestMessage is case-sensitive (ordinal): a message that differs only in
        # case belongs to someone else, never to Front Door.
        $approvedFrontDoor = @($states | Where-Object { $_.Status -ceq 'Approved' -and $_.Description.StartsWith($RequestMessage, [StringComparison]::Ordinal) })
        $pendingMatching = @($states | Where-Object { $_.Status -ceq 'Pending' -and $_.Description -ceq $RequestMessage })
        $pendingOther = @($states | Where-Object { $_.Status -ceq 'Pending' -and $_.Description -cne $RequestMessage })

        foreach ($other in $pendingOther) {
            Write-Warning "$appName`: leaving pending connection '$($other.Name)' (request message '$($other.Description)'): not a Front Door request from this deployment."
        }

        # Read Front Door's own origin status before deciding whether to approve anything. The "already approved"
        # refusal below only catches a connection whose description starts with the request message; a connection
        # approved another way (for example, by hand in the portal, without the prefix) would not match it. Once
        # Front Door's own origin reports its private link Approved, any pending connection with the same request
        # message cannot be Front Door's either way, so check this first (runbook 04 section 5.2).
        $origins = Get-FrontDoorOrigins
        $matchingOrigin = Find-MatchingOrigin $origins $id
        $matchingOriginStatus = if ($matchingOrigin) { (Get-SharedPrivateLinkResource $matchingOrigin).status } else { $null }

        if ($matchingOriginStatus -eq 'Approved' -and $pendingMatching.Count -gt 0) {
            $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
            throw "$appName`: Front Door's origin '$($matchingOrigin.name)' already reports its private link Approved, so the pending connection with the same request message ('$RequestMessage') cannot be Front Door's ($names). This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
        }

        # Front Door creates its origin first and only then sends the private endpoint request, so a matching
        # request for an App Service that no origin references cannot be Front Door's.
        if (-not $matchingOrigin -and $pendingMatching.Count -gt 0) {
            $names = ($pendingMatching | ForEach-Object { $_.Name }) -join ', '
            throw "$appName`: a pending connection carries the request message '$RequestMessage' ($names), but no Front Door origin in $FrontDoorProfileName/$OriginGroupName references this App Service, so it cannot be Front Door's request. This could be a spoofed request: verify the private endpoint and reject any unexpected connection, then re-run this script (runbook 04 section 5.2)."
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
                $approvedConnectionForApp = $pending
            }
        }

        if ($WhatIfPreference) {
            break
        }

        # Approving a connection is this script's own action, not proof Front Door is using it. Trust only
        # Front Door's own origin status for success. Re-read it: approving above may have just flipped it.
        $origins = Get-FrontDoorOrigins
        $matchingOrigin = Find-MatchingOrigin $origins $id
        $matchingOriginStatus = if ($matchingOrigin) { (Get-SharedPrivateLinkResource $matchingOrigin).status } else { $null }

        if ($matchingOriginStatus -eq 'Approved') {
            Write-Output "$appName`: Front Door origin '$($matchingOrigin.name)' reports its private link Approved."
            break
        }

        if ((Get-Date) -ge $deadline) {
            if (-not $matchingOrigin) {
                throw "$appName`: no Front Door origin in $FrontDoorProfileName/$OriginGroupName references this App Service. Check the origin exists, or redeploy (runbook 04 section 9)."
            }
            if ($approvedConnectionForApp) {
                throw "$appName`: the approved connection '$($approvedConnectionForApp.Name)' (private endpoint $($approvedConnectionForApp.PrivateEndpointId)) did not bring Front Door's origin '$($matchingOrigin.name)' to Approved within $TimeoutSeconds seconds; it may not be Front Door's request. Reject it and follow runbook 04 section 5.2."
            }
            if ($approvedFrontDoor.Count -gt 0) {
                throw "$appName`: a Front Door connection is approved but origin '$($matchingOrigin.name)' still reports '$matchingOriginStatus' after $TimeoutSeconds seconds; check the origin in the Front Door profile (runbook 04 section 9)."
            }
            throw "$appName`: no Front Door private endpoint connection was approved within $TimeoutSeconds seconds. Check the origin in the Front Door profile, then re-run this script (runbook 04 section 9)."
        }
        Write-Output "$appName`: waiting for Front Door to create its private endpoint connection..."
        Start-Sleep -Seconds $PollIntervalSeconds
    }
}
