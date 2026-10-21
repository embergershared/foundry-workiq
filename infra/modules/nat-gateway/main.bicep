targetScope = 'resourceGroup'

param name string
@minLength(2)
@maxLength(80)
param publicIpName string
param location string = resourceGroup().location
param tags object = {}
param enabled bool = false

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (enabled) {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 10
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-07-01' = if (enabled) {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: publicIp.id
      }
    ]
  }
}

@description('Resource ID of the NAT Gateway, or an empty string when disabled.')
output id string = enabled ? natGateway!.id : ''
@description('Name of the NAT Gateway, or an empty string when disabled.')
output name string = enabled ? natGateway!.name : ''
@description('Deprecated alias of `id`, retained for existing callers.')
output natGatewayId string = enabled ? natGateway!.id : ''
