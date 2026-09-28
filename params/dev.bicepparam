using '../main.bicep'

// Non-secret dev parameters for the existing defenStack resource group.
// Secret values go in a git-ignored *.local.bicepparam overlay, never here.
param environmentType = 'dev'
param allowedOutboundFqdns = []
