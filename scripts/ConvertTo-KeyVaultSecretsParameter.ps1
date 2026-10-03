<#
.SYNOPSIS
Validates the KEYVAULT_SECRETS_JSON environment secret and writes it as the keyVaultSecrets deployment parameter.

.DESCRIPTION
The deploy pipeline keeps application secrets in the GitHub environment secret KEYVAULT_SECRETS_JSON, a JSON
object of { "secret-name": "value" }. This script checks the object and writes it to -OutFile, which
deploy.yml passes as `--parameters keyVaultSecrets=@<file>`. Every regional Key Vault then receives the same
values through Azure Resource Manager (ADR-019).

Rules: empty or missing input means no secrets ({}). Names must be 1-127 letters, digits or hyphens (the Key Vault
rule). Values must be non-empty strings. The script never prints a value; error messages name only the secret.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [AllowEmptyString()]
    [AllowNull()]
    [string]$Json,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$secrets = [ordered]@{}
if (-not [string]::IsNullOrWhiteSpace($Json)) {
    try {
        $parsed = $Json | ConvertFrom-Json
    }
    catch {
        throw 'KEYVAULT_SECRETS_JSON is not valid JSON. Expected an object such as {"api-key": "value"}.'
    }
    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'KEYVAULT_SECRETS_JSON must be a JSON object of { "secret-name": "value" }.'
    }
    foreach ($property in $parsed.PSObject.Properties) {
        if ($property.Name -cnotmatch '^[0-9A-Za-z-]{1,127}$') {
            throw "Secret name '$($property.Name)' is invalid: use 1-127 letters, digits or hyphens."
        }
        if ($property.Value -isnot [string] -or [string]::IsNullOrEmpty($property.Value)) {
            throw "Secret '$($property.Name)' must have a non-empty string value."
        }
        $secrets[$property.Name] = $property.Value
    }
}

$directory = Split-Path -Parent $OutFile
if ($directory -and -not (Test-Path $directory)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
[IO.File]::WriteAllText($OutFile, (ConvertTo-Json -InputObject $secrets -Compress), (New-Object Text.UTF8Encoding($false)))
Write-Output "Prepared $($secrets.Count) Key Vault secret(s): $((@($secrets.Keys) | Sort-Object) -join ', ')"
