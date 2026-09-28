BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/monitoring.bicep'
}

Describe 'Log Analytics retention (F10)' {
    It 'retains 90 days by default (Sentinel free retention window)' {
        $template.parameters.retentionInDays.defaultValue | Should -Be 90
    }

    It 'bounds retention to supported values' {
        $template.parameters.retentionInDays.minValue | Should -Be 30
        $template.parameters.retentionInDays.maxValue | Should -Be 730
    }
}
