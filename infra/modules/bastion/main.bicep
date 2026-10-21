targetScope = 'resourceGroup'

param name string
@minLength(2)
@maxLength(80)
param publicIpName string
param location string = resourceGroup().location
param tags object = {}
param bastionSubnetId string
param logAnalyticsWorkspaceId string

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
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
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    scaleUnits: 2
    disableCopyPaste: false
    enableFileCopy: false
    enableIpConnect: true
    enableKerberos: true
    enableShareableLink: false
    enableTunneling: true
    ipConfigurations: [
      {
        name: 'bastion-ip-configuration'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: bastion
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'BastionAuditLogs'
        enabled: true
      }
    ]
    metrics: []
  }
}

@description('Resource ID of the Bastion host.')
output id string = bastion.id
@description('Name of the Bastion host.')
output name string = bastion.name
@description('Deprecated alias of `name`, retained for existing callers.')
output bastionName string = bastion.name
