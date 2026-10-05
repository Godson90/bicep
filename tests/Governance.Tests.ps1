BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $governance = Get-BicepTemplate -RelativePath 'governance.bicep'
    $plansTemplate = Get-BicepTemplate -RelativePath 'modules/governance/defenderPlans.bicep'
    $pricings = Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/pricings' | Select-Object -First 1
    $contactsTemplate = Get-BicepTemplate -RelativePath 'modules/governance/securityContacts.bicep'
    $contact = Get-TemplateResource -Template $contactsTemplate -Type 'Microsoft.Security/securityContacts' | Select-Object -First 1

    function Get-Plan([string]$Name) {
        @($plansTemplate.variables.plans | Where-Object { $_.name -eq $Name })[0]
    }
}

Describe 'Governance entry point (Phase 7)' {
    It 'is a subscription-scope template at the repository root' {
        Get-RepoPath 'governance.bicep' | Should -Exist
        $governance.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
    }

    It 'is never deployed by main.bicep or the pipeline (operator only, ADR-026)' {
        Get-Content (Get-RepoPath 'main.bicep') -Raw | Should -Not -Match 'governance'
        $deploy = Get-Content (Get-RepoPath '.github/workflows/deploy.yml') -Raw
        $deploy | Should -Not -Match 'governance\.bicep\b'
        $deploy | Should -Not -Match '--template-file'
    }

    It 'requires at least one security contact address' {
        $governance.parameters.securityContactEmails.type | Should -Be 'array'
        $governance.parameters.securityContactEmails.minLength | Should -Be 1
        $governance.parameters.securityContactEmails.PSObject.Properties.Name | Should -Not -Contain 'defaultValue'
    }

    It 'caps on-upload malware scanning at 5000 GB per storage account per month by default' {
        $governance.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
        $governance.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
    }

    It 'deploys the Defender plans with the malware scanning cap' {
        $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'defenderPlans'
        $module.properties.parameters.malwareScanCapGbPerMonth.value | Should -Be "[parameters('malwareScanCapGbPerMonth')]"
        $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
    }

    It 'deploys the security contact with the contact addresses' {
        $module = Get-TemplateResourceBySymbol -Template $governance -Symbol 'securityContacts'
        $module.properties.parameters.emails.value | Should -Be "[parameters('securityContactEmails')]"
        $module.PSObject.Properties.Name | Should -Not -Contain 'resourceGroup'
    }
}

Describe 'Defender for Cloud plans (Phase 7)' {
    It 'deploys at subscription scope with the GA pricings API' {
        $plansTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
        $pricings.apiVersion | Should -Be '2024-01-01'
    }

    It 'updates one plan at a time, since parallel pricing updates conflict' {
        $pricings.copy.mode | Should -Be 'serial'
        $pricings.copy.batchSize | Should -Be 1
        $pricings.copy.count | Should -Be "[length(variables('plans'))]"
    }

    It 'enables exactly the spec plans: Servers, App Service, Storage, Key Vault, Resource Manager and Defender CSPM' {
        @($plansTemplate.variables.plans | ForEach-Object { $_.name }) -join ',' |
            Should -Be 'VirtualMachines,AppServices,StorageAccounts,KeyVaults,Arm,CloudPosture'
    }

    It 'sets every plan to Standard' {
        foreach ($plan in $plansTemplate.variables.plans) {
            $plan.properties.pricingTier | Should -Be 'Standard' -Because $plan.name
        }
        $pricings.properties | Should -Be "[variables('plans')[copyIndex()].properties]"
        $pricings.name | Should -Be "[variables('plans')[copyIndex()].name]"
    }

    It 'runs Defender for Servers Plan 2 with agentless VM scanning and no MDE direct onboarding' {
        $plan = Get-Plan 'VirtualMachines'
        $plan.properties.subPlan | Should -Be 'P2'
        @($plan.properties.extensions | ForEach-Object { $_.name }) | Should -Be @('AgentlessVmScanning')
        $plan.properties.extensions[0].isEnabled | Should -BeExactly 'True'
    }

    It 'runs Defender for Storage V2 with capped on-upload malware scanning and sensitive data discovery' {
        $plan = Get-Plan 'StorageAccounts'
        $plan.properties.subPlan | Should -Be 'DefenderForStorageV2'
        @($plan.properties.extensions | ForEach-Object { $_.name }) -join ',' | Should -Be 'OnUploadMalwareScanning,SensitiveDataDiscovery'
        foreach ($extension in $plan.properties.extensions) {
            $extension.isEnabled | Should -BeExactly 'True' -Because $extension.name
        }
        $malware = @($plan.properties.extensions | Where-Object { $_.name -eq 'OnUploadMalwareScanning' })[0]
        $malware.additionalExtensionProperties.CapGBPerMonthPerStorageAccount | Should -Be "[string(parameters('malwareScanCapGbPerMonth'))]"
    }

    It 'leaves <_> on the Azure default sub-plan with no extensions' -ForEach 'AppServices', 'KeyVaults', 'Arm', 'CloudPosture' {
        $plan = Get-Plan $_
        $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'subPlan'
        $plan.properties.PSObject.Properties.Name | Should -Not -Contain 'extensions'
    }

    It 'does not manage the retired legacy agent auto-provisioning setting' {
        Get-TemplateResource -Template $plansTemplate -Type 'Microsoft.Security/autoProvisioningSettings' | Should -BeNullOrEmpty
    }

    It 'defaults the malware scanning cap to 5000 GB and allows -1 for no cap' {
        $plansTemplate.parameters.malwareScanCapGbPerMonth.defaultValue | Should -Be 5000
        $plansTemplate.parameters.malwareScanCapGbPerMonth.minValue | Should -Be -1
    }
}

Describe 'Defender for Cloud security contact (Phase 7)' {
    It 'is the subscription singleton named default' {
        $contactsTemplate.'$schema' | Should -Match 'subscriptionDeploymentTemplate\.json'
        $contact.name | Should -Be 'default'
    }

    It 'pins 2023-12-01-preview, the latest version; the type has no GA version (ADR-029)' {
        $contact.apiVersion | Should -Be '2023-12-01-preview'
    }

    It 'emails every address, semicolon-separated, and requires at least one' {
        $contact.properties.isEnabled | Should -BeExactly $true
        $contact.properties.emails | Should -Be "[join(parameters('emails'), ';')]"
        $contactsTemplate.parameters.emails.minLength | Should -Be 1
    }

    It 'also notifies subscription Owners' {
        $contact.properties.notificationsByRole.state | Should -Be 'On'
        @($contact.properties.notificationsByRole.roles) | Should -Be @('Owner')
    }

    It 'emails alerts of severity High only' {
        $sources = @($contact.properties.notificationsSources)
        $sources.Count | Should -Be 1
        $sources[0].sourceType | Should -Be 'Alert'
        $sources[0].minimalSeverity | Should -Be 'High'
    }
}
