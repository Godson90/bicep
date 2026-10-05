// Who Defender for Cloud emails about alerts in this subscription (Phase 7).
targetScope = 'subscription'

@description('Addresses that receive Defender for Cloud alert emails. At least one.')
@minLength(1)
param emails string[]

// A subscription has one contact, and it must be named default. Microsoft.Security/securityContacts has no GA API
// version; 2023-12-01-preview is the latest (ADR-029).
resource securityContact 'Microsoft.Security/securityContacts@2023-12-01-preview' = {
  name: 'default'
  properties: {
    isEnabled: true
    emails: join(emails, ';')
    // Subscription Owners are emailed too, so an alert still reaches someone if the list goes stale.
    notificationsByRole: {
      state: 'On'
      roles: [
        'Owner'
      ]
    }
    notificationsSources: [
      {
        sourceType: 'Alert'
        minimalSeverity: 'High'
      }
    ]
  }
}

output name string = securityContact.name
