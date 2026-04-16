@description('Short prefix used for all resource names.')
param namePrefix string

@description('Azure region.')
param location string

@description('CIDR allowed to reach port 22.')
param allowedSshCidr string

@description('Tags applied to all resources.')
param tags object

var suffix = uniqueString(resourceGroup().id, namePrefix)
var vnetName = '${namePrefix}-vnet'
var subnetName = 'default'
var nsgName = '${namePrefix}-nsg'
var pipName = '${namePrefix}-pip-${suffix}'

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-01-01' = {
  name: nsgName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSshInbound'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: allowedSshCidr
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// VNet without subnets first, then the subnet as a child resource, to avoid a
// race where the subnet deployment can reference the NSG before ARM has fully
// propagated it (observed as "NSG not found" on first apply in some regions).
resource vnet 'Microsoft.Network/virtualNetworks@2024-01-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [ '10.42.0.0/16' ]
    }
  }
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-01-01' = {
  parent: vnet
  name: subnetName
  properties: {
    addressPrefix: '10.42.1.0/24'
    networkSecurityGroup: {
      id: nsg.id
    }
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: pipName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 4
    dnsSettings: {
      domainNameLabel: '${namePrefix}-${suffix}'
    }
  }
}

output subnetId string = subnet.id
output publicIpId string = publicIp.id
output publicIpAddress string = publicIp.properties.ipAddress
output fqdn string = publicIp.properties.dnsSettings.fqdn
