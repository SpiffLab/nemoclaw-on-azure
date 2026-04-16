@description('Short prefix used for resource names.')
param namePrefix string

@description('Azure region.')
param location string

@description('VM size.')
param vmSize string

@description('Admin username.')
param adminUsername string

@description('SSH public key (contents).')
@secure()
param sshPublicKey string

@description('Subnet resource ID.')
param subnetId string

@description('Public IP resource ID.')
param publicIpId string

@description('NVIDIA API key for routed inference. Empty = configure later.')
@secure()
param nvidiaApiKey string

@description('NemoClaw assistant name to onboard.')
param assistantName string

@description('OS disk size in GB.')
param osDiskSizeGB int

@description('Tags.')
param tags object

var vmName = '${namePrefix}-vm'
var nicName = '${namePrefix}-nic'

// cloud-init template (loadTextContent substitutes literal file contents).
var cloudInitTemplate = loadTextContent('../../scripts/cloud-init.yaml')
var cloudInitRendered = replace(
  replace(
    replace(cloudInitTemplate, '__ADMIN_USERNAME__', adminUsername),
    '__NVIDIA_API_KEY__', nvidiaApiKey
  ),
  '__ASSISTANT_NAME__', assistantName
)

resource nic 'Microsoft.Network/networkInterfaces@2024-01-01' = {
  name: nicName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: subnetId }
          publicIPAddress: { id: publicIpId }
          privateIPAllocationMethod: 'Dynamic'
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: osDiskSizeGB
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(cloudInitRendered)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

output vmName string = vm.name
output vmId string = vm.id
