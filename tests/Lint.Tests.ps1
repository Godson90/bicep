BeforeDiscovery {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $bicepFiles = Get-ChildItem -Path $repoRoot -Recurse -Filter '*.bicep' |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object { @{ Name = $_.FullName.Substring($repoRoot.Length + 1); FullName = $_.FullName } }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
}

Describe 'Repository linter configuration' {
    It 'has bicepconfig.json at the repository root' {
        Get-RepoPath 'bicepconfig.json' | Should -Exist
    }

    It 'raises security rules to error level' {
        $config = Get-Content (Get-RepoPath 'bicepconfig.json') -Raw | ConvertFrom-Json
        foreach ($rule in 'secure-parameter-default', 'outputs-should-not-contain-secrets', 'use-secure-value-for-secure-inputs', 'no-hardcoded-env-urls', 'secure-secrets-in-params') {
            $config.analyzers.core.rules.$rule.level | Should -Be 'error' -Because "$rule protects secrets and portability"
        }
    }

    It 'ignores local secret parameter overlays' {
        Get-Content (Get-RepoPath '.gitignore') | Should -Contain '*.local.bicepparam'
    }
}

Describe 'Bicep lint' {
    It '<Name> lints without errors' -ForEach $bicepFiles {
        $output = & bicep lint $FullName 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join [Environment]::NewLine)
    }
}

Describe 'Generated ARM template' {
    It 'main.json matches a fresh build of main.bicep' {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $expected = ((& bicep build (Get-RepoPath 'main.bicep') --stdout) -join "`n").Trim()
        $actual = ((Get-Content (Get-RepoPath 'main.json') -Raw -Encoding UTF8) -replace "`r`n", "`n").Trim()
        $actual | Should -BeExactly $expected -Because 'run "bicep build main.bicep" and commit main.json'
    }
}
