[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BudgetName,

    [Parameter(Mandatory)]
    [ValidateRange(0.01, 1000000000)]
    [decimal]$MonthlyAmount,

    [Parameter(Mandatory)]
    [ValidatePattern('^[^@\s]+@[^@\s]+\.[^@\s]+$')]
    [string[]]$ContactEmail,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [datetime]$StartDate = (Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0),

    [Parameter()]
    [datetime]$EndDate = ((Get-Date -Day 1 -Hour 0 -Minute 0 -Second 0).AddYears(1).AddDays(-1)),

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$ActualThresholdPercent = 80,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$ForecastedThresholdPercent = 100
)

$ErrorActionPreference = 'Stop'

if ($EndDate -le $StartDate) {
    throw 'EndDate must be later than StartDate.'
}

if ($ForecastedThresholdPercent -lt $ActualThresholdPercent) {
    throw 'ForecastedThresholdPercent must be greater than or equal to ActualThresholdPercent.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI (az) is required. Install it and run az login before executing this script.'
}

if ([string]::IsNullOrWhiteSpace($SubscriptionId)) {
    $SubscriptionId = az account show --query id --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        throw 'No active Azure subscription was found. Run az login or provide -SubscriptionId.'
    }
}

$start = $StartDate.ToUniversalTime().ToString('yyyy-MM-ddT00:00:00Z')
$end = $EndDate.ToUniversalTime().ToString('yyyy-MM-ddT23:59:59Z')
$resourceGroupScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
$budgetResourceId = "$resourceGroupScope/providers/Microsoft.Consumption/budgets/$BudgetName"
$budgetUri = "https://management.azure.com$budgetResourceId`?api-version=2023-11-01"

$budgetBody = @{
    properties = @{
        category = 'Cost'
        amount = $MonthlyAmount
        timeGrain = 'Monthly'
        timePeriod = @{
            startDate = $start
            endDate = $end
        }
        notifications = @{
            ActualThreshold = @{
                enabled = $true
                operator = 'GreaterThan'
                threshold = $ActualThresholdPercent
                contactEmails = $ContactEmail
                thresholdType = 'Actual'
            }
            ForecastedThreshold = @{
                enabled = $true
                operator = 'GreaterThan'
                threshold = $ForecastedThresholdPercent
                contactEmails = $ContactEmail
                thresholdType = 'Forecasted'
            }
        }
    }
} | ConvertTo-Json -Depth 10

Write-Host "Resource group: $ResourceGroupName"
Write-Host "Budget: $BudgetName"
Write-Host "Monthly amount: $MonthlyAmount"
Write-Host "Period: $start through $end"
Write-Host "Contacts: $($ContactEmail -join ', ')"

if ($PSCmdlet.ShouldProcess($budgetResourceId, 'Create or update Azure resource-group budget')) {
    az rest `
        --method put `
        --url $budgetUri `
        --headers 'Content-Type=application/json' `
        --body $budgetBody `
        --output json

    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI failed to create or update the budget.'
    }
}
