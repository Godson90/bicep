@description('Azure region for the VM resources.')
param location string

@description('Virtual machine name. Use 1-15 characters because the name is also used for the computer hostname.')
@minLength(1)
@maxLength(15)
param vmName string

@description('Operating system image to deploy.')
@allowed([
  'Linux'
  'Windows'
])
param osType string = 'Linux'

@description('Subnet resource ID for the VM network interface.')
param subnetId string

@description('Local administrator username. Do not use reserved Windows administrator names.')
@minLength(1)
@maxLength(64)
param adminUsername string

@description('SSH public key for Linux deployments. Required when osType is Linux.')
param adminSshPublicKey string = ''

@description('Local administrator password for Windows deployments. Required when osType is Windows.')
@secure()
param adminPassword string = ''

@description('VM size selected for the workload.')
param vmSize string = 'Standard_B2s'

@description('Log Analytics workspace resource ID for VM diagnostics.')
param logAnalyticsWorkspaceId string

@description('CIDR ranges allowed to reach the VM over SSH (22) and RDP (3389). Must match the management subnet NSG; an empty list denies all administrative inbound traffic.')
param managementSourceCidrs array = []

var linuxImagePublisher = 'Canonical'
var linuxImageOffer = '0001-com-ubuntu-server-jammy'
var linuxImageSku = '22_04-lts-gen2'
var windowsImagePublisher = 'MicrosoftWindowsServer'
var windowsImageOffer = 'WindowsServer'
var windowsImageSku = '2022-datacenter-g2'
var networkInterfaceName = '${vmName}-nic'
var networkSecurityGroupName = '${vmName}-nsg'
var managementInboundRules = empty(managementSourceCidrs) ? [] : [
  {
    name: 'allow-management-ssh-rdp'
    properties: {
      priority: 100
      access: 'Allow'
      direction: 'Inbound'
      protocol: 'Tcp'
      sourceAddressPrefixes: managementSourceCidrs
      sourcePortRange: '*'
      destinationAddressPrefix: '*'
      destinationPortRanges: [
        '22'
        '3389'
      ]
    }
  }
]

var dataCollectionRuleName = '${vmName}-dcr'
var azureMonitorAgentName = osType == 'Linux' ? 'AzureMonitorLinuxAgent' : 'AzureMonitorWindowsAgent'
var performanceCounterSource = {
  performanceCounters: [
    {
      name: 'perf'
      streams: [
        'Microsoft-Perf'
      ]
      samplingFrequencyInSeconds: 60
      counterSpecifiers: osType == 'Linux' ? [
        '\\Processor(*)\\% Processor Time'
        '\\Memory(*)\\% Used Memory'
        '\\Logical Disk(*)\\% Used Space'
      ] : [
        '\\Processor Information(_Total)\\% Processor Time'
        '\\Memory\\% Committed Bytes In Use'
        '\\LogicalDisk(_Total)\\% Free Space'
      ]
    }
  ]
}
var osLogSource = osType == 'Linux' ? {
  syslog: [
    {
      name: 'syslog'
      streams: [
        'Microsoft-Syslog'
      ]
      facilityNames: [
        'auth'
        'authpriv'
        'daemon'
        'kern'
        'syslog'
      ]
      logLevels: [
        'Warning'
        'Error'
        'Critical'
        'Alert'
        'Emergency'
      ]
    }
  ]
} : {
  windowsEventLogs: [
    {
      name: 'windows-events'
      streams: [
        'Microsoft-Event'
      ]
      xPathQueries: [
        'System!*[System[(Level=1 or Level=2 or Level=3)]]'
        'Application!*[System[(Level=1 or Level=2 or Level=3)]]'
      ]
    }
  ]
}

// NIC-level NSG keeps the VM boundary explicit without changing shared subnet policy.
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: concat(managementInboundRules, [
      {
        name: 'deny-unsolicited-inbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ])
  }
}

// Dynamic private IP NIC with a managed identity and no public IP.
resource networkInterface 'Microsoft.Network/networkInterfaces@2024-07-01' = {
  name: networkInterfaceName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: subnetId
          }
        }
      }
    ]
    networkSecurityGroup: {
      id: networkSecurityGroup.id
    }
  }
}

// OS-specific VM with trusted launch, host encryption, and boot diagnostics.
resource virtualMachine 'Microsoft.Compute/virtualMachines@2026-04-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: osType == 'Linux' ? {
        publisher: linuxImagePublisher
        offer: linuxImageOffer
        sku: linuxImageSku
        version: 'latest'
      } : {
        publisher: windowsImagePublisher
        offer: windowsImageOffer
        sku: windowsImageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        deleteOption: 'Delete'
      }
    }
    osProfile: osType == 'Linux' ? {
      computerName: vmName
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: adminSshPublicKey
            }
          ]
        }
      }
    } : {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: networkInterface.id
          properties: {
            primary: true
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      encryptionAtHost: true
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

// Platform metrics only; Compute VMs expose no diagnostic log categories. Guest logs use the DCR below.
resource virtualMachineDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: virtualMachine
  name: 'vm-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// Azure Monitor Agent authenticates with the VM's system-assigned identity.
resource azureMonitorAgent 'Microsoft.Compute/virtualMachines/extensions@2026-04-01' = {
  parent: virtualMachine
  name: azureMonitorAgentName
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: azureMonitorAgentName
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// Guest OS logs and performance counters routed to the central workspace.
resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  kind: osType
  properties: {
    dataSources: union(performanceCounterSource, osLogSource)
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: osType == 'Linux' ? [
          'Microsoft-Syslog'
          'Microsoft-Perf'
        ] : [
          'Microsoft-Event'
          'Microsoft-Perf'
        ]
        destinations: [
          'workspace'
        ]
      }
    ]
  }
}

resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: '${vmName}-dcra'
  scope: virtualMachine
  properties: {
    dataCollectionRuleId: dataCollectionRule.id
  }
}

output id string = virtualMachine.id
output name string = virtualMachine.name
output networkInterfaceId string = networkInterface.id
output dataCollectionRuleId string = dataCollectionRule.id
