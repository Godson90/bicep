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

var linuxImagePublisher = 'Canonical'
var linuxImageOffer = '0001-com-ubuntu-server-jammy'
var linuxImageSku = '22_04-lts-gen2'
var windowsImagePublisher = 'MicrosoftWindowsServer'
var windowsImageOffer = 'WindowsServer'
var windowsImageSku = '2022-datacenter-g2'
var networkInterfaceName = '${vmName}-nic'
var networkSecurityGroupName = '${vmName}-nsg'

// NIC-level NSG keeps the VM boundary explicit without changing shared subnet policy.
resource networkSecurityGroup 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: networkSecurityGroupName
  location: location
  properties: {
    securityRules: [
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
    ]
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

resource virtualMachineDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: virtualMachine
  name: 'vm-diagnostics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = virtualMachine.id
output name string = virtualMachine.name
output networkInterfaceId string = networkInterface.id
