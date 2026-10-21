// Container registry
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// The admin user is disabled (anonymous pull is off by default): workloads pull with a managed
// identity granted AcrPull, and operators push with Entra ID (for example
// `azd deploy` remote builds). Public network access stays enabled because ACR
// Tasks remote builds and Basic SKU registries do not support private-only access.

@description('Resource name. Build it with globalName(abbreviations.containerRegistry, ..., \'\', 50) from infra/core/naming.bicep.')
@minLength(5)
@maxLength(50)
param name string

@description('Azure region.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}

@description('Registry SKU. Premium is required for private endpoints.')
@allowed([
  'Basic'
  'Standard'
  'Premium'
])
param sku string = 'Basic'

@description('Principal IDs (workload identities) granted AcrPull.')
param pullPrincipalIds array = []

var acrPullRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: false
    publicNetworkAccess: 'Enabled'
  }
}

resource pullRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in pullPrincipalIds: {
    name: guid(registry.id, principalId, acrPullRoleId)
    scope: registry
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: acrPullRoleId
    }
  }
]

@description('Resource ID.')
output id string = registry.id

@description('Resource name.')
output name string = registry.name

@description('Registry login server, for example cruse2s3dev123.azurecr.io.')
output loginServer string = registry.properties.loginServer
