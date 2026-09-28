Set-StrictMode -Version Latest

$script:RepoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    Join-Path $script:RepoRoot $RelativePath
}

function Get-BicepTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $json = & bicep build (Get-RepoPath $RelativePath) --stdout
    if ($LASTEXITCODE -ne 0) {
        throw "bicep build failed for $RelativePath"
    }

    ($json -join "`n") | ConvertFrom-Json
}

function Get-TemplateResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Template,

        [Parameter(Mandatory)]
        [string]$Type
    )

    # languageVersion 2.0 templates store resources as an object keyed by symbolic name.
    $resources = if ($Template.resources -is [array]) {
        $Template.resources
    }
    else {
        $Template.resources.PSObject.Properties | ForEach-Object { $_.Value }
    }

    @($resources | Where-Object {
            $isExisting = ($_.PSObject.Properties.Name -contains 'existing') -and $_.existing
            ($_.type -eq $Type) -and -not $isExisting
        })
}

function Get-ModuleDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Template,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $deployment = Get-TemplateResource -Template $Template -Type 'Microsoft.Resources/deployments' |
        Where-Object { $_.name -eq $Name }
    if (-not $deployment) {
        throw "Module deployment '$Name' was not found."
    }

    $deployment
}

function Get-TemplateResourceBySymbol {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Template,

        [Parameter(Mandatory)]
        [string]$Symbol
    )

    # Module names in the subscription entry point are expressions, so look them up by symbolic name.
    if ($Template.resources -is [array]) {
        throw 'Template has no symbolic resource names; languageVersion 2.0 is required.'
    }

    $property = $Template.resources.PSObject.Properties[$Symbol]
    if (-not $property) {
        throw "Resource with symbolic name '$Symbol' was not found."
    }

    $property.Value
}

Export-ModuleMember -Function Get-RepoPath, Get-BicepTemplate, Get-TemplateResource, Get-ModuleDeployment, Get-TemplateResourceBySymbol
