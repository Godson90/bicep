BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $vault = Get-BicepTemplate -RelativePath 'modules/keyVault.bicep'
    $vaultSecrets = Get-TemplateResource -Template $vault -Type 'Microsoft.KeyVault/vaults/secrets' | Select-Object -First 1
    $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
    $main = Get-BicepTemplate -RelativePath 'main.bicep'
    $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
    $converter = Get-RepoPath 'scripts/ConvertTo-KeyVaultSecretsParameter.ps1'
    $outFile = Join-Path ([IO.Path]::GetTempPath()) "kvs-test-$([guid]::NewGuid()).json"
}

AfterAll {
    Remove-Item -Path $outFile -ErrorAction SilentlyContinue
}

Describe 'Deploy-time Key Vault secrets (Phase 5, ADR-019)' {
    It 'takes secrets as a secure object, empty by default' {
        $vault.parameters.secrets.type | Should -Be 'secureObject'
        $vault.parameters.secrets.PSObject.Properties.Name | Should -Contain 'defaultValue'
        @($vault.parameters.secrets.defaultValue.PSObject.Properties).Count | Should -Be 0
    }

    It 'writes one vault secret per entry through Azure Resource Manager' {
        $vaultSecrets.copy.count | Should -Be "[length(items(parameters('secrets')))]"
        $vaultSecrets.name | Should -Match "items\(parameters\('secrets'\)\)\[copyIndex\(\)\]\.key"
        $vaultSecrets.properties.value | Should -Match "items\(parameters\('secrets'\)\)\[copyIndex\(\)\]\.value"
    }

    It 'passes the same secrets to the Key Vault of every stamp' {
        $stamp.parameters.keyVaultSecrets.type | Should -Be 'secureObject'
        (Get-ModuleDeployment -Template $stamp -Name 'key-vault').properties.parameters.secrets.value | Should -Be "[parameters('keyVaultSecrets')]"
        $main.parameters.keyVaultSecrets.type | Should -Be 'secureObject'
        foreach ($symbol in 'primaryStamp', 'secondaryStamp') {
            (Get-TemplateResourceBySymbol -Template $main -Symbol $symbol).properties.parameters.keyVaultSecrets.value | Should -Be "[parameters('keyVaultSecrets')]"
        }
    }

    It 'never sets keyVaultSecrets in a committed parameter file' {
        foreach ($file in 'params/dev.bicepparam', 'params/prod.bicepparam') {
            Get-Content (Get-RepoPath $file) -Raw | Should -Not -Match 'keyVaultSecrets'
        }
    }
}

Describe 'Pipeline secret handling (Phase 5)' {
    It 'reads KEYVAULT_SECRETS_JSON from the environment secrets, converts it, and passes it to the deployment' {
        $deploy | Should -Match ([regex]::Escape('KEYVAULT_SECRETS_JSON: ${{ secrets.KEYVAULT_SECRETS_JSON }}'))
        $prepare = $deploy.IndexOf('./scripts/ConvertTo-KeyVaultSecretsParameter.ps1')
        $create = $deploy.IndexOf('az deployment sub create')
        $prepare | Should -BeGreaterThan -1
        $create | Should -BeGreaterThan $prepare
        $deploy | Should -Match ([regex]::Escape('--parameters keyVaultSecrets=@"$RUNNER_TEMP/keyvault-secrets.json"'))
    }

    It 'always deletes the secrets file after the deployment' {
        $deploy | Should -Match "- name: Remove the secrets file\s+if: always\(\)\s+run: rm -f `"\`$RUNNER_TEMP/keyvault-secrets.json`""
    }
}

Describe 'ConvertTo-KeyVaultSecretsParameter.ps1 (Phase 5)' {
    It 'writes {} for empty or missing input' {
        & $converter -Json '' -OutFile $outFile | Out-Null
        Get-Content $outFile -Raw | Should -Be '{}'
        & $converter -OutFile $outFile | Out-Null
        Get-Content $outFile -Raw | Should -Be '{}'
    }

    It 'writes the validated object and reports names, never values' {
        $output = & $converter -Json '{"api-key":"s3cret-value","db-password":"another"}' -OutFile $outFile
        $written = Get-Content $outFile -Raw | ConvertFrom-Json
        $written.'api-key' | Should -Be 's3cret-value'
        $written.'db-password' | Should -Be 'another'
        ($output -join ' ') | Should -Match 'api-key, db-password'
        ($output -join ' ') | Should -Not -Match 's3cret-value'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'invalid JSON'; Json = '{not json'; Message = '*not valid JSON*' }
        @{ Case = 'a JSON array'; Json = '["a"]'; Message = '*must be a JSON object*' }
        @{ Case = 'a name with an underscore'; Json = '{"api_key":"x"}'; Message = "*Secret name 'api_key' is invalid*" }
        @{ Case = 'an empty value'; Json = '{"api-key":""}'; Message = "*Secret 'api-key' must have a non-empty string value*" }
        @{ Case = 'a non-string value'; Json = '{"api-key":42}'; Message = "*Secret 'api-key' must have a non-empty string value*" }
    ) {
        { & $converter -Json $Json -OutFile $outFile } | Should -Throw $Message
    }

    It 'never echoes a value in an error message' {
        $message = ''
        try { & $converter -Json '{"bad_name":"do-not-leak"}' -OutFile $outFile } catch { $message = $_.Exception.Message }
        $message | Should -Not -Match 'do-not-leak'
    }
}
