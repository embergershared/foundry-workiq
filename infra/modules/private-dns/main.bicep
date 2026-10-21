targetScope = 'resourceGroup'

@description('Prefix used for the virtual network link names.')
param name string
@description('Private DNS zones are global resources.')
param location string = 'global'
param tags object = {}
@description('Virtual network that the private DNS zones are linked to.')
param virtualNetworkId string

// The zone list is generated from module metadata by scripts/build-catalog.ps1.
// Adding a private-endpoint-capable module to the catalog is therefore the only
// edit required to get its private DNS zone deployed and linked.
var zoneCatalog = loadJsonContent('../../core/private-dns-zones.json')
var zoneKeys = map(zoneCatalog, entry => entry.key)
var deployedZones = [
  for (entry, index) in zoneCatalog: {
    key: entry.key
    zone: entry.zone
    id: zone[index].id
  }
]

resource zone 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for entry in zoneCatalog: {
    name: entry.zone
    location: location
    tags: tags
  }
]

resource link 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (entry, index) in zoneCatalog: {
    parent: zone[index]
    name: '${name}-${entry.linkSuffix}-link'
    location: location
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: virtualNetworkId
      }
    }
  }
]

@description('Every deployed zone, keyed by the catalog key that modules resolve against.')
output zones array = deployedZones

@description('Zone resource IDs keyed by catalog key. A module added later resolves its zone here without this module needing a new output.')
output zoneIds object = toObject(deployedZones, entry => entry.key, entry => entry.id)

// Retained so existing callers keep working. New modules should read zoneIds.
// Empty when the catalog has no such zone, so an adopted project whose catalog
// omits Key Vault or Storage still compiles and deploys.
output keyVaultZoneId string = contains(zoneKeys, 'keyVault') ? zone[indexOf(zoneKeys, 'keyVault')].id : ''
output blobZoneId string = contains(zoneKeys, 'blob') ? zone[indexOf(zoneKeys, 'blob')].id : ''
output fileZoneId string = contains(zoneKeys, 'file') ? zone[indexOf(zoneKeys, 'file')].id : ''
