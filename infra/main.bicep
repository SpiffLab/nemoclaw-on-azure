// NemoClaw on Azure — resource-group scoped deployment.
// Provisions networking and a single Ubuntu VM that installs NemoClaw via cloud-init.
targetScope = 'resourceGroup'

@description('Short prefix used for all resource names (3-16 chars, lowercase/alnum).')
@minLength(3)
@maxLength(16)
param namePrefix string = 'nemoclaw'

@description('Azure region.')
param location string = resourceGroup().location

@description('VM size. Default is CPU-only for routed NVIDIA inference. Use an NC-series SKU for local GPU inference.')
param vmSize string = 'Standard_D4s_v5'

@description('Admin username on the VM.')
param adminUsername string = 'azureuser'

@description('SSH public key (full contents, e.g. ssh-ed25519 AAAA... user@host).')
@secure()
param sshPublicKey string

@description('CIDR allowed to reach port 22. Narrow this to your IP for production.')
param allowedSshCidr string = '0.0.0.0/0'

@description('NVIDIA API key for routed inference. Leave empty to configure later.')
@secure()
param nvidiaApiKey string = ''

@description('Name of the NemoClaw assistant to onboard.')
param assistantName string = 'my-assistant'

@description('OS disk size in GB (NemoClaw recommends 40+; default 64 leaves room for images).')
@minValue(30)
@maxValue(1024)
param osDiskSizeGB int = 64

var tags = {
  project: 'nemoclaw-on-azure'
  workload: 'nemoclaw'
  managedBy: 'bicep'
}

module network 'modules/network.bicep' = {
  name: 'network'
  params: {
    namePrefix: namePrefix
    location: location
    allowedSshCidr: allowedSshCidr
    tags: tags
  }
}

module vm 'modules/vm.bicep' = {
  name: 'vm'
  params: {
    namePrefix: namePrefix
    location: location
    vmSize: vmSize
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    subnetId: network.outputs.subnetId
    publicIpId: network.outputs.publicIpId
    nvidiaApiKey: nvidiaApiKey
    assistantName: assistantName
    osDiskSizeGB: osDiskSizeGB
    tags: tags
  }
}

output publicIpAddress string = network.outputs.publicIpAddress
output sshCommand string = 'ssh ${adminUsername}@${network.outputs.publicIpAddress}'
output vmName string = vm.outputs.vmName
