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

    It 'refuses to proceed when multiple applications share the display name' {
        function global:az {
            $joined = $args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -like 'account show*') {
                if ($joined -like '*tenantId*') { return '33333333-3333-3333-3333-333333333333' }
                return '44444444-4444-4444-4444-444444444444'
            }
            if ($joined -like '*ad app list*') {
                return @('aaaaaaaa-1111-1111-1111-111111111111', 'bbbbbbbb-2222-2222-2222-222222222222')
            }
            return ''
        }
        try {
            $caught = $null
            try {
                & $scriptPath -ResourceGroupName 'defenStack' -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
            }
            catch {
                $caught = $_
            }
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -Match 'Multiple Entra applications'
        }
        finally {
            Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        }
    }

    It 'refuses an existing unconditioned RBAC Administrator assignment' {
        function global:az {
            $joined = $args -join ' '
            $global:LASTEXITCODE = 0
            if ($joined -like 'account show*') {
                if ($joined -like '*tenantId*') { return '55555555-5555-5555-5555-555555555555' }
                return '66666666-6666-6666-6666-666666666666'
            }
            if ($joined -like '*ad app list*') {
                return 'cccccccc-3333-3333-3333-333333333333'
            }
            if ($joined -like '*ad sp list*') {
                return 'dddddddd-4444-4444-4444-444444444444'
            }
            if ($joined -like '*federated-credential list*') {
                return 'github-dev'
            }
            if ($joined -like '*role assignment list*condition*') {
                return ''
            }
            if ($joined -like '*role assignment list*') {
                return 'eeeeeeee-5555-5555-5555-555555555555'
            }
            return ''
        }
        try {
            $caught = $null
            try {
                & $scriptPath -ResourceGroupName 'defenStack' -GitHubRepository 'Godson90/bicep' -EnvironmentName 'dev' -WhatIf | Out-Null
            }
            catch {
                $caught = $_
            }
            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -Match 'unconditioned'
        }
        finally {
            Remove-Item -Path Function:\az -ErrorAction SilentlyContinue
        }
    }
}
