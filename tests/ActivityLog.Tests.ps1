BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/activityLog.bicep'
    $setting = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
}

Describe 'Subscription Activity Log diagnostic setting (Phase 6)' {
    It 'deploys at subscription scope' {
        $template.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
        $setting | Should -Not -BeNullOrEmpty
    }

    It 'pins 2021-05-01-preview, the only API version with subscription-scope settings (ADR-025)' {
        $setting.apiVersion | Should -Be '2021-05-01-preview'
    }

    It 'sends the Activity Log to the central workspace only' {
        $setting.name | Should -Be "[parameters('settingName')]"
        $setting.properties.workspaceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
        $setting.properties.PSObject.Properties.Name | Should -Not -Contain 'storageAccountId'
        $setting.properties.PSObject.Properties.Name | Should -Not -Contain 'eventHubAuthorizationRuleId'
    }

    It 'enables every Activity Log category' {
        $logs = @($setting.properties.logs)
        @($logs | ForEach-Object { $_.category } | Sort-Object) |
            Should -Be @('Administrative', 'Alert', 'Autoscale', 'Policy', 'Recommendation', 'ResourceHealth', 'Security', 'ServiceHealth')
        foreach ($log in $logs) {
            $log.enabled | Should -BeTrue -Because $log.category
        }
    }
}
