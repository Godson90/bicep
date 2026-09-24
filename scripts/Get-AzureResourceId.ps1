[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceName,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceType,

    [Parameter()]
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
}

$commonArguments = @(
    '--resource-group', $ResourceGroupName
)

if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $commonArguments += @('--subscription', $SubscriptionId)
}

if (-not [string]::IsNullOrWhiteSpace($ResourceType)) {
    $arguments = @('resource', 'show') + $commonArguments + @(
        '--name', $ResourceName,
        '--resource-type', $ResourceType,
        '--query', 'id',
        '--output', 'tsv'
    )

    $resourceId = & az @arguments
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI failed to find the resource.'
    }

    if ([string]::IsNullOrWhiteSpace($resourceId)) {
        throw "No resource named '$ResourceName' of type '$ResourceType' was found in resource group '$ResourceGroupName'."
    }

    $resourceId.Trim()
    return
}

$arguments = @('resource', 'list') + $commonArguments + @('--output', 'json')
$resourceJson = & az @arguments
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI failed to list resources.'
}

$matches = @($resourceJson | ConvertFrom-Json | Where-Object { $_.name -eq $ResourceName })
if ($matches.Count -eq 0) {
    throw "No resource named '$ResourceName' was found in resource group '$ResourceGroupName'."
}

if ($matches.Count -gt 1) {
    Write-Warning "Multiple resources named '$ResourceName' were found. Add -ResourceType to select one."
}

$matches | ForEach-Object { $_.id }