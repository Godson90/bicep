BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $componentTemplate = Get-BicepTemplate -RelativePath 'modules/appInsights.bicep'
    $component = Get-TemplateResource -Template $componentTemplate -Type 'Microsoft.Insights/components' | Select-Object -First 1
    $publisherTemplate = Get-BicepTemplate -RelativePath 'modules/appInsightsPublisher.bicep'
    $publisher = Get-TemplateResource -Template $publisherTemplate -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
    $appServiceTemplate = Get-BicepTemplate -RelativePath 'modules/appService.bicep'
    $site = Get-TemplateResource -Template $appServiceTemplate -Type 'Microsoft.Web/sites' | Select-Object -First 1
    $stamp = Get-BicepTemplate -RelativePath 'modules/regionStamp.bicep'
}

Describe 'Application Insights component (Phase 5)' {
    It 'is workspace-based, storing telemetry in the central workspace' {
        $component.kind | Should -Be 'web'
        $component.properties.WorkspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
        $component.properties.IngestionMode | Should -Be 'LogAnalytics'
    }

    It 'accepts only Entra ID-authenticated telemetry (no instrumentation-key ingestion)' {
        $component.properties.DisableLocalAuth | Should -BeExactly $true
    }

    It 'keeps public ingestion and query until Phase 6 adds AMPLS' {
        $component.properties.publicNetworkAccessForIngestion | Should -Be 'Enabled'
        $component.properties.publicNetworkAccessForQuery | Should -Be 'Enabled'
    }

    It 'outputs the connection string the App Service needs' {
        $componentTemplate.outputs.connectionString.value | Should -Match 'ConnectionString'
    }
}

Describe 'Telemetry publisher role (Phase 5)' {
    It 'grants Monitoring Metrics Publisher on the component only' {
        $publisherTemplate.variables.monitoringMetricsPublisherRoleId | Should -Be '3913510d-42f4-4e42-8a64-420c390055eb'
        $publisher.scope | Should -Be "[resourceId('Microsoft.Insights/components', parameters('componentName'))]"
        $publisher.properties.principalType | Should -Be 'ServicePrincipal'
        $publisher.properties.principalId | Should -Be "[parameters('publisherPrincipalId')]"
    }
}

Describe 'App Service telemetry and hardening (Phase 5)' {
    It 'sends telemetry with the connection string and Entra ID authentication only when a component is given' {
        $appServiceTemplate.parameters.applicationInsightsConnectionString.defaultValue | Should -Be ''
        $appServiceTemplate.variables.telemetrySettings | Should -Match "^\[if\(empty\(parameters\('applicationInsightsConnectionString'\)\), createArray\(\)"
        $appServiceTemplate.variables.telemetrySettings | Should -Match "'APPLICATIONINSIGHTS_CONNECTION_STRING'"
        $appServiceTemplate.variables.telemetrySettings | Should -Match "'APPLICATIONINSIGHTS_AUTHENTICATION_STRING', 'value', 'Authorization=AAD'"
        $site.properties.siteConfig.appSettings | Should -Be "[variables('telemetrySettings')]"
    }

    It 'denies all public access to the site and Kudu by default even if public access is re-enabled' {
        $site.properties.siteConfig.ipSecurityRestrictionsDefaultAction | Should -Be 'Deny'
        $site.properties.siteConfig.scmIpSecurityRestrictionsDefaultAction | Should -Be 'Deny'
        $site.properties.publicNetworkAccess | Should -Be 'Disabled'
    }
}

Describe 'Region stamp telemetry wiring (Phase 5)' {
    It 'creates one component per region, named with environment and region' {
        $stamp.variables.names.appInsights | Should -Be "[format('appi-defenstack-{0}-{1}', parameters('environmentName'), parameters('regionCode'))]"
        (Get-ModuleDeployment -Template $stamp -Name 'app-insights').properties.parameters.logAnalyticsWorkspaceId.value | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
    }

    It 'passes the regional connection string to the App Service' {
        (Get-ModuleDeployment -Template $stamp -Name 'app-service').properties.parameters.applicationInsightsConnectionString.value |
            Should -Be "[reference('appInsights').outputs.connectionString.value]"
    }

    It 'grants the App Service identity the publisher role on its own component' {
        $parameters = (Get-ModuleDeployment -Template $stamp -Name 'app-insights-publisher').properties.parameters
        $parameters.publisherPrincipalId.value | Should -Be "[reference('appService').outputs.appServicePrincipalId.value]"
        $parameters.componentName.value | Should -Be "[reference('appInsights').outputs.name.value]"
    }
}
