targetScope = 'resourceGroup'

// The single private-endpoint + private-DNS pattern used by every catalog
// module. Modules never declare Microsoft.Network/privateEndpoints directly, so
// the approval state, DNS zone group shape and NIC naming stay consistent
// across the whole catalog.
//
// Resource names are supplied by the caller rather than generated here, so a
// module can be moved onto this pattern without renaming anything.

@description('Private endpoint resource name.')
@minLength(2)
@maxLength(80)
param name string

@description('Custom name for the private endpoint network interface.')
@minLength(2)
@maxLength(80)
param networkInterfaceName string

@description('Region for the private endpoint. Must match the subnet region.')
param location string = resourceGroup().location

@description('Tags applied to the private endpoint.')
param tags object = {}

@description('Resource ID of the subnet that hosts the private endpoint.')
param subnetId string

@description('Resource ID of the service the private endpoint targets.')
param privateLinkServiceId string

@description('Private link sub-resource names, such as [\'vault\'] or [\'blob\'].')
param groupIds array

@description('Resource ID of the private DNS zone that resolves this endpoint.')
param privateDnsZoneId string

@description('Name of the private link service connection and its DNS zone config. Kept stable because it is part of the endpoint properties.')
@minLength(1)
@maxLength(80)
param connectionName string

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    customNetworkInterfaceName: networkInterfaceName
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: connectionName
        properties: {
          privateLinkServiceId: privateLinkServiceId
          groupIds: groupIds
          privateLinkServiceConnectionState: {
            status: 'Approved'
            description: 'Approved by infrastructure deployment.'
            actionsRequired: 'None'
          }
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-07-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: connectionName
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output id string = privateEndpoint.id
output name string = privateEndpoint.name
