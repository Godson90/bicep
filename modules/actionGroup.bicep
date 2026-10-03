@description('Action group name.')
param actionGroupName string

@description('Short name shown in alert emails and SMS. At most 12 characters.')
@minLength(1)
@maxLength(12)
param shortName string

@description('Email address that receives every platform alert, from the GitHub variable ALERT_EMAIL. Empty creates the group with no receiver (dev only; the prod apply refuses an empty value).')
param alertEmail string = ''

// One action group per environment for every platform alert (Phase 6). The common alert schema gives every
// alert type the same email layout.
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'Global'
  properties: {
    groupShortName: shortName
    enabled: true
    emailReceivers: empty(alertEmail) ? [] : [
      {
        name: 'platform-operators'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

output id string = actionGroup.id
output name string = actionGroup.name
