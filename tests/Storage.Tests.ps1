BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'Bicep.TestHelpers.psm1') -Force
    $template = Get-BicepTemplate -RelativePath 'modules/storage.bicep'
    $blobService = Get-TemplateResource -Template $template -Type 'Microsoft.Storage/storageAccounts/blobServices' | Select-Object -First 1
    $diagnostics = Get-TemplateResource -Template $template -Type 'Microsoft.Insights/diagnosticSettings'
}

Describe 'Blob data protection (F7)' {
    It 'enables versioning, change feed, blob and container soft delete, and point-in-time restore' {
        $blobService.properties.isVersioningEnabled | Should -BeTrue
        $blobService.properties.changeFeed.enabled | Should -BeTrue
        $blobService.properties.deleteRetentionPolicy.enabled | Should -BeTrue
        $blobService.properties.containerDeleteRetentionPolicy.enabled | Should -BeTrue
        $blobService.properties.restorePolicy.enabled | Should -BeTrue
    }

    It 'keeps the restore window shorter than soft delete retention' {
        $blobService.properties.restorePolicy.days | Should -Be "[sub(parameters('blobSoftDeleteRetentionDays'), 1)]"
        $template.parameters.blobSoftDeleteRetentionDays.defaultValue | Should -Be 14
    }
}

Describe 'Blob audit logs (F6)' {
    It 'has an account-level and a blob-service-level diagnostic setting' {
        $diagnostics.Count | Should -Be 2
    }

    It 'collects all blob read/write/delete logs' {
        $blobDiagnostics = $diagnostics | Where-Object { $_.scope -match 'blobServices' }
        $blobDiagnostics.properties.logs[0].categoryGroup | Should -Be 'allLogs'
    }
}
