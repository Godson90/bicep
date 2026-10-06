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

Describe 'Jump host just-in-time access (Phase 7, ADR-028)' {
    BeforeAll {
        $nsg = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkSecurityGroups' | Select-Object -First 1
        $nic = Get-TemplateResource -Template $template -Type 'Microsoft.Network/networkInterfaces' | Select-Object -First 1
        $jit = @(Get-TemplateResource -Template $template -Type 'Microsoft.Security/locations/jitNetworkAccessPolicies')
        $inboundRules = @($nsg.properties.securityRules | Where-Object { $_ -isnot [string] -and $_.properties.direction -eq 'Inbound' })
        $denyRule = $template.variables.denyManagementInboundRule
    }

    It 'has no static allow rule on the NIC: SSH and RDP open only through a JIT grant' {
        ($nsg.properties.securityRules | ConvertTo-Json -Depth 10) | Should -Not -Match "'Allow'|""Allow"""
        ($nsg.properties.securityRules | ConvertTo-Json -Depth 10) | Should -Not -Match 'allow-management-ssh-rdp'
        $template.variables.PSObject.Properties.Name | Should -Not -Contain 'managementInboundRules'
    }

    It 'denies inbound SSH and RDP from any source at priority 4000, leaving 100-3999 free for JIT allow rules' {
        @($nsg.properties.securityRules)[0] | Should -Be "[variables('denyManagementInboundRule')]"
        $denyRule.name | Should -Be 'deny-ssh-rdp-inbound'
        $denyRule.properties.priority | Should -Be 4000
        $denyRule.properties.access | Should -Be 'Deny'
        $denyRule.properties.direction | Should -Be 'Inbound'
        $denyRule.properties.sourceAddressPrefix | Should -Be '*'
        $denyRule.properties.protocol | Should -Be '*'
        @($denyRule.properties.destinationPortRanges) -join ',' | Should -Be '22,3389'
    }

    It 'denies exactly the ports the JIT policy opens' {
        @($denyRule.properties.destinationPortRanges) -join ',' | Should -Be (@($template.variables.jitPorts | ForEach-Object { [string]$_ }) -join ',')
    }

    It 'keeps the catch-all inbound deny below the SSH/RDP deny' {
        $inboundRules.Count | Should -Be 1
        $inboundRules[0].name | Should -Be 'deny-unsolicited-inbound'
        $inboundRules[0].properties.priority | Should -Be 4096
    }

    It 'attaches the NSG to the NIC, the NSG closest to the VM, which JIT programs' {
        $nic.properties.networkSecurityGroup.id | Should -Be "[resourceId('Microsoft.Network/networkSecurityGroups', variables('networkSecurityGroupName'))]"
    }

    It 'creates one JIT policy, named default in the VM region, with the GA API and kind Basic' {
        $jit.Count | Should -Be 1
        $jit[0].apiVersion | Should -Be '2020-01-01'
        $jit[0].name | Should -Be "[format('{0}/default', parameters('location'))]"
        $jit[0].kind | Should -Be 'Basic'
    }

    It 'skips the JIT policy when no admin source is given, so the ports stay closed' {
        $jit[0].condition | Should -Be "[not(empty(parameters('managementSourceCidrs')))]"
    }

    It 'covers this VM on TCP 22 and 3389, from the admin sources only, for at most three hours' {
        $vmEntry = @($jit[0].properties.virtualMachines)
        $vmEntry.Count | Should -Be 1
        $vmEntry[0].id | Should -Be "[resourceId('Microsoft.Compute/virtualMachines', parameters('vmName'))]"
        @($template.variables.jitPorts) -join ',' | Should -Be '22,3389'
        $ports = $vmEntry[0].copy[0]
        $ports.name | Should -Be 'ports'
        $ports.count | Should -Be "[length(variables('jitPorts'))]"
        $ports.input.number | Should -Be "[variables('jitPorts')[copyIndex('ports')]]"
        $ports.input.protocol | Should -Be 'TCP'
        $ports.input.allowedSourceAddressPrefixes | Should -Be "[parameters('managementSourceCidrs')]"
        $ports.input.maxRequestAccessDuration | Should -Be 'PT3H'
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

Describe 'VM data collection endpoint in the AMPLS (final review I-2)' {
    BeforeAll {
        $endpoints = @(Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionEndpoints')
        $associations = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/dataCollectionRuleAssociations'
        $ruleAssociation = $associations | Where-Object { $_.name -eq "[format('{0}-dcra', parameters('vmName'))]" }
        $configurationAssociation = $associations | Where-Object { $_.name -eq 'configurationAccessEndpoint' }
    }

    It 'creates one regional data collection endpoint, named after the VM, with public network access disabled' {
        $endpoints.Count | Should -Be 1
        $endpoints[0].apiVersion | Should -Be '2023-03-11'
        $endpoints[0].name | Should -Be "[format('{0}-dce', parameters('vmName'))]"
        $endpoints[0].location | Should -Be "[parameters('location')]"
        $endpoints[0].properties.networkAcls.publicNetworkAccess | Should -Be 'Disabled'
    }

    It 'associates the endpoint with the VM as its configurationAccessEndpoint' {
        @($configurationAssociation).Count | Should -Be 1
        $configurationAssociation.apiVersion | Should -Be '2023-03-11'
        $configurationAssociation.scope | Should -Be "[resourceId('Microsoft.Compute/virtualMachines', parameters('vmName'))]"
        $configurationAssociation.properties.dataCollectionEndpointId | Should -Be "[resourceId('Microsoft.Insights/dataCollectionEndpoints', format('{0}-dce', parameters('vmName')))]"
        $configurationAssociation.properties.PSObject.Properties.Name | Should -Not -Contain 'dataCollectionRuleId'
    }

    It 'keeps the existing DCR association unchanged' {
        $associations.Count | Should -Be 2
        @($ruleAssociation).Count | Should -Be 1
        $ruleAssociation.properties.dataCollectionRuleId | Should -Be "[resourceId('Microsoft.Insights/dataCollectionRules', variables('dataCollectionRuleName'))]"
        $ruleAssociation.properties.PSObject.Properties.Name | Should -Not -Contain 'dataCollectionEndpointId'
    }

    It 'outputs the data collection endpoint ID' {
        $template.outputs.dataCollectionEndpointId.value | Should -Be "[resourceId('Microsoft.Insights/dataCollectionEndpoints', format('{0}-dce', parameters('vmName')))]"
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

Describe 'VM backup hand-off (Phase 8)' {
    It 'outputs the VM resource ID, which the Recovery Services vault protects' {
        $template.outputs.id.value | Should -Be "[resourceId('Microsoft.Compute/virtualMachines', parameters('vmName'))]"
    }
}
