BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/virtualMachine.bicep'
}

Describe 'VM NIC NSG management access (F1)' {
    It 'exposes managementSourceCidrs defaulting to an empty list' {
        $template.parameters.PSObject.Properties.Name | Should -Contain 'managementSourceCidrs'
        @($template.parameters.managementSourceCidrs.defaultValue).Count | Should -Be 0
    }
}

Describe 'VM monitoring (F3)' {
    BeforeAll {
        $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings' | Select-Object -First 1
        $dcr = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRules' | Select-Object -First 1
        $association = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRuleAssociations' | Select-Object -First 1
        $agent = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines/extensions' | Select-Object -First 1
    }

    It 'sends only metrics through the VM diagnostic setting (VMs expose no log categories)' {
        $diagnostics.properties.PSObject.Properties.Name | Should -Not -Contain 'logs'
        $diagnostics.properties.metrics[0].category | Should -Be 'AllMetrics'
    }

    It 'installs the Azure Monitor Agent' {
        $agent.properties.publisher | Should -Be 'Microsoft.Azure.Monitor'
        $agent.properties.enableAutomaticUpgrade | Should -BeTrue
    }

    It 'sends guest logs and performance counters to the workspace through a DCR' {
        $dcr.properties.destinations.logAnalytics[0].workspaceResourceId | Should -Be "[parameters('logAnalyticsWorkspaceId')]"
    }

    It 'associates the DCR with the VM' {
        $association.scope | Should -Match 'virtualMachines'
    }

    It 'outputs the DCR ID' {
        $template.outputs.PSObject.Properties.Name | Should -Contain 'dataCollectionRuleId'
    }

    It 'uses Azure Monitor counter paths with a leading backslash' {
        # dataSources compiles to the expression '[union(variables(...), variables(...))]' rather than
        # an inline object, so the literal counter text lives in the performanceCounterSource variable.
        $dcrText = $template.variables.performanceCounterSource | ConvertTo-Json -Depth 10
        $dcrText | Should -Match ([regex]::Escape('\\Processor(*)\\% Processor Time'))
    }
}

Describe 'VM monitoring on Windows (F3)' {
    It 'installs the Windows agent and collects System and Application events when osType is Windows' {
        $template.variables.azureMonitorAgentName | Should -Match "'AzureMonitorWindowsAgent'"
        $template.variables.osLogSource | Should -Match 'windowsEventLogs'
        $template.variables.osLogSource | Should -Match 'Microsoft-Event'
        $template.variables.osLogSource | Should -Match 'Application!'
    }
}

Describe 'Jump host access (Phase 3)' {
    BeforeAll {
        $vm = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines' | Select-Object -First 1
        $extensions = Get-TemplateResource -Template $template -Type 'Microsoft.Compute/virtualMachines/extensions'
        $entraLogin = $extensions | Where-Object { $_.properties.publisher -eq 'Microsoft.Azure.ActiveDirectory' }
        $roleAssignment = Get-TemplateResource -Template $template -Type 'Microsoft.Authorization/roleAssignments' | Select-Object -First 1
        $nsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' | Select-Object -First 1
    }

    It 'pins the VM to one availability zone, zone 1 by default' {
        @($vm.zones) | Should -Be @("[parameters('availabilityZone')]")
        $template.parameters.availabilityZone.defaultValue | Should -Be '1'
    }

    It 'installs the Entra ID login extension that matches the OS' {
        $template.variables.entraLoginExtensionName | Should -Be "[if(equals(parameters('osType'), 'Linux'), 'AADSSHLoginForLinux', 'AADLoginForWindows')]"
        $entraLogin.properties.type | Should -Be "[variables('entraLoginExtensionName')]"
    }

    It 'installs the Entra extension after the Azure Monitor Agent (one extension operation at a time)' {
        ($entraLogin.dependsOn -join ' ') | Should -Match 'azureMonitorAgentName'
    }

    It 'grants the admin group Virtual Machine Administrator Login on this VM only, when a group is given' {
        $roleAssignment.condition | Should -Be "[not(empty(parameters('adminGroupObjectId')))]"
        $roleAssignment.scope | Should -Match 'virtualMachines'
        $roleAssignment.properties.principalType | Should -Be 'Group'
        $template.variables.virtualMachineAdministratorLoginRoleId | Should -Be '1c0163c0-47e6-4577-8991-ea5c82e286e4'
        $template.parameters.adminGroupObjectId.defaultValue | Should -Be ''
    }

    It 'hands patching to Update Manager on both operating systems' {
        $template.variables.patchSettings.patchMode | Should -Be 'AutomaticByPlatform'
        $template.variables.patchSettings.assessmentMode | Should -Be 'AutomaticByPlatform'
        $template.variables.patchSettings.automaticByPlatformSettings.bypassPlatformSafetyChecksOnUserSchedule | Should -BeExactly $true
        # osProfile compiles to one if() expression; both the Linux and Windows branches carry the settings.
        ([regex]::Matches($vm.properties.osProfile, [regex]::Escape("'patchSettings', variables('patchSettings')"))).Count | Should -Be 2
    }

    It 'installs critical and security updates in a weekly window and assigns it to the VM' {
        $schedule = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/maintenanceConfigurations' | Select-Object -First 1
        $assignment = Get-TemplateResource -Template $template -Type 'Microsoft.Maintenance/configurationAssignments' | Select-Object -First 1
        $schedule.properties.maintenanceScope | Should -Be 'InGuestPatch'
        $schedule.properties.maintenanceWindow.recurEvery | Should -Be 'Week Sunday'
        @($schedule.properties.installPatches.linuxParameters.classificationsToInclude) -join ',' | Should -Be 'Critical,Security'
        @($schedule.properties.installPatches.windowsParameters.classificationsToInclude) -join ',' | Should -Be 'Critical,Security'
        $assignment.scope | Should -Match 'virtualMachines'
    }

    It 'denies outbound SSH and RDP from the NIC (PSRule Azure.NSG.LateralTraversal)' {
        ($nsg.properties.securityRules | ConvertTo-Json -Depth 10) | Should -Match 'deny-ssh-rdp-outbound'
    }
}
