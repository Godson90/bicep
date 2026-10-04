BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $actionGroupTemplate = Get-BicepTemplate -RelativePath 'modules/actionGroup.bicep'
    $actionGroup = Get-TemplateResource -Template $actionGroupTemplate -Type 'Microsoft.Insights/actionGroups' | Select-Object -First 1
    $metricAlertsTemplate = Get-BicepTemplate -RelativePath 'modules/metricAlerts.bicep'
    $metricAlert = Get-TemplateResource -Template $metricAlertsTemplate -Type 'Microsoft.Insights/metricAlerts' | Select-Object -First 1
    $serviceHealthTemplate = Get-BicepTemplate -RelativePath 'modules/serviceHealthAlert.bicep'
    $serviceHealth = Get-TemplateResource -Template $serviceHealthTemplate -Type 'Microsoft.Insights/activityLogAlerts' | Select-Object -First 1
}

Describe 'Action group (Phase 6)' {
    It 'is a global resource on the GA API version 2023-01-01' {
        $actionGroup.location | Should -Be 'Global'
        $actionGroup.apiVersion | Should -Be '2023-01-01'
        $actionGroup.properties.enabled | Should -BeTrue
    }

    It 'limits the short name to the 12 characters Azure allows' {
        $actionGroupTemplate.parameters.shortName.maxLength | Should -Be 12
        $actionGroup.properties.groupShortName | Should -Be "[parameters('shortName')]"
    }

    It 'emails ALERT_EMAIL with the common alert schema, and adds no receiver when it is empty' {
        $actionGroupTemplate.parameters.alertEmail.defaultValue | Should -BeExactly ''
        $actionGroup.properties.emailReceivers |
            Should -Be "[if(empty(parameters('alertEmail')), createArray(), createArray(createObject('name', 'platform-operators', 'emailAddress', parameters('alertEmail'), 'useCommonAlertSchema', true())))]"
    }

    It 'outputs its ID for the alert rules' {
        $actionGroupTemplate.outputs.id.value | Should -Match "Microsoft\.Insights/actionGroups"
    }
}

Describe 'Metric alerts module (Phase 6)' {
    It 'pins metricAlerts 2018-03-01, the last clearly GA version' {
        $metricAlert.apiVersion | Should -Be '2018-03-01'
        $metricAlert.location | Should -Be 'global'
    }

    It 'creates one alert per rule, skipping rules marked deploy = false' {
        $metricAlert.copy.count | Should -Be "[length(parameters('rules'))]"
        $metricAlert.condition | Should -Be "[coalesce(tryGet(parameters('rules')[copyIndex()], 'deploy'), true())]"
        $metricAlert.name | Should -Be "[format('{0}-{1}', parameters('namePrefix'), parameters('rules')[copyIndex()].name)]"
    }

    It 'watches one resource with a static threshold, every 5 minutes over 15 minutes, and resolves itself' {
        @($metricAlert.properties.scopes) | Should -Be @("[parameters('rules')[copyIndex()].resourceId]")
        $metricAlert.properties.evaluationFrequency | Should -Be 'PT5M'
        $metricAlert.properties.windowSize | Should -Be 'PT15M'
        $metricAlert.properties.autoMitigate | Should -BeTrue
        $metricAlert.properties.enabled | Should -BeTrue
        $metricAlert.properties.criteria.'odata.type' | Should -Be 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        $metricAlert.properties.criteria.allOf[0].criterionType | Should -Be 'StaticThresholdCriterion'
    }

    It 'converts the text threshold to a number, so decimals such as 99.9 work' {
        $metricAlert.properties.criteria.allOf[0].threshold | Should -Be "[json(parameters('rules')[copyIndex()].threshold)]"
    }

    It 'applies the rule dimensions, or none' {
        $metricAlert.properties.criteria.allOf[0].dimensions | Should -Be "[coalesce(tryGet(parameters('rules')[copyIndex()], 'dimensions'), createArray())]"
    }

    It 'notifies the action group' {
        $metricAlert.properties.actions[0].actionGroupId | Should -Be "[parameters('actionGroupId')]"
    }
}

Describe 'Service Health alert (Phase 6)' {
    It 'is a global activity log alert on the GA API version 2020-10-01' {
        $serviceHealth.location | Should -Be 'Global'
        $serviceHealth.apiVersion | Should -Be '2020-10-01'
        $serviceHealth.properties.enabled | Should -BeTrue
    }

    It 'watches the whole subscription' {
        @($serviceHealth.properties.scopes) | Should -Be @('[subscription().id]')
    }

    It 'fires on Service Health events in the platform regions only' {
        $conditions = @($serviceHealth.properties.condition.allOf)
        ($conditions | Where-Object { $_.field -eq 'category' }).equals | Should -Be 'ServiceHealth'
        $regionCondition = ($conditions | Where-Object { $_.PSObject.Properties.Name -contains 'anyOf' }).anyOf[0]
        $regionCondition.field | Should -Be 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
        $regionCondition.containsAny | Should -Be "[parameters('regions')]"
    }

    It 'notifies the action group' {
        $serviceHealth.properties.actions.actionGroups[0].actionGroupId | Should -Be "[parameters('actionGroupId')]"
    }
}
