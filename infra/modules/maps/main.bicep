// Maps
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// Gen2 account. Callers authenticate with Microsoft Entra ID and send the
// account's clientId as the x-ms-client-id header. Azure Maps supports a limited
// set of regions, so pass a supported location (for example eastus, westeurope)
// rather than the workload region when they differ.

@description('Resource name. Build it with azName(abbreviations.mapsAccount, ...) using the Maps location code.')
@minLength(1)
@maxLength(98)
param name string

@description('Azure region supported by Azure Maps.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}

@description('Disable shared-key (subscription-key) authentication. Leave false only when a tool still needs the account key.')
param disableLocalAuth bool = false

@description('Principal IDs granted Azure Maps Data Reader.')
param readerPrincipalIds array = []

@description('Principal type of readerPrincipalIds.')
@allowed([
  'ServicePrincipal'
  'User'
  'Group'
])
param readerPrincipalType string = 'ServicePrincipal'

var mapsDataReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '423170ca-a8f6-4b0f-8487-9e4eb8f49bfa'
)

resource maps 'Microsoft.Maps/accounts@2023-06-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'G2'
  }
  kind: 'Gen2'
  properties: {
    disableLocalAuth: disableLocalAuth
  }
}

resource readerRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in readerPrincipalIds: {
    name: guid(maps.id, principalId, mapsDataReaderRoleId)
    scope: maps
    properties: {
      principalId: principalId
      principalType: readerPrincipalType
      roleDefinitionId: mapsDataReaderRoleId
    }
  }
]

@description('Resource ID.')
output id string = maps.id

@description('Resource name.')
output name string = maps.name

@description('Account client ID, sent as the x-ms-client-id header with Entra ID tokens.')
output clientId string = maps.properties.uniqueId
