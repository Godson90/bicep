BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $scriptPath = Get-RepoPath 'scripts/New-GitHubDeploymentIdentity.ps1'
}

Describe 'New-GitHubDeploymentIdentity.ps1' {
    It 'exists and parses without errors' {
        $scriptPath | Should -Exist
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It 'supports -WhatIf' {
        (Get-Command $scriptPath).Parameters.Keys | Should -Contain 'WhatIf'
    }

    It 'makes no Azure or Entra changes under -WhatIf' {
        $global:AzCalls = [System.Collections.Generic.List[string]]::new()
        function global:az {
            $joined = $args -join ' '
            $global:AzCalls.Add($joined)
            $global:LASTEXITCODE = 0
            if ($joined -like 'account show*') { if ($joined -like '*tenantId*') { return '11111111-1111-1111-1111-111111111111' } return '22222222-2222-2222-2222-222222222222' }
            return ''
        }
        try {
            & $scriptPath -ResourceGroupName 'defenStack' -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
        }
        finally {
            Remove-Item -Path Function:\az
        }
        $mutations = $global:AzCalls | Where-Object { $_ -match '\b(create|delete|update)\b' }
        Remove-Variable -Name AzCalls -Scope Global
        $mutations | Should -BeNullOrEmpty
    }
}
