[CmdletBinding()]
param(
    [Parameter()]
    [string[]]$Path,

    [Parameter()]
    [switch]$CI
)

$ErrorActionPreference = 'Stop'

if (-not $PSBoundParameters.ContainsKey('Path')) { $Path = @($PSScriptRoot) }

if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    throw 'Bicep CLI is required on PATH. Install it with "az bicep install" and add its folder to PATH.'
}

$minimumPester = [version]'5.5.0'
$maximumPester = [version]'5.999.999'
if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge $minimumPester -and $_.Version.Major -eq 5 })) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Install-Module -Name Pester -MinimumVersion $minimumPester -MaximumVersion $maximumPester -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module -Name Pester -MinimumVersion $minimumPester -MaximumVersion $maximumPester

$configuration = New-PesterConfiguration
$configuration.Run.Path = $Path
$configuration.Run.Exit = $true
$configuration.Output.Verbosity = 'Detailed'

if ($CI) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputFormat = 'JUnitXml'
    $configuration.TestResult.OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'test-results.xml'
}

# Native tools write warnings to stderr; Stop would turn those into terminating errors under Windows PowerShell.
$ErrorActionPreference = 'Continue'
Invoke-Pester -Configuration $configuration
