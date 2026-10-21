// Microsoft Foundry account
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// AIServices account with key authentication disabled (callers use Entra ID),
// a Foundry project for agents, and model deployments. Operations on one
// account conflict when they overlap, so the project is created first and the
// deployments one at a time.
//
// The account name is also its custom subdomain, which must be globally unique:
// build it with globalName(abbreviations.aiFoundry, ..., '-', 64).

@description('Account name and custom subdomain.')
@minLength(2)
@maxLength(64)
param name string

@description('Azure region; choose one where the requested models and quota are available.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}

@description('Foundry project name. Build it with azName(abbreviations.aiFoundryProject, ...).')
@minLength(2)
@maxLength(64)
param projectName string

@description('Project display name.')
param projectDisplayName string = projectName

@description('Model deployments: [{ name, model, version, sku?, capacity }]. sku defaults to GlobalStandard.')
param deployments array = []

@description('Public network access. Private endpoints are not configured by this module.')
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Enabled'

resource account 'Microsoft.CognitiveServices/accounts@2025-06-01' = {
  name: name
  location: location
  tags: tags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: name
    allowProjectManagement: true
    publicNetworkAccess: publicNetworkAccess
    disableLocalAuth: true
  }
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: account
  name: projectName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: projectDisplayName
  }
}

@batchSize(1)
resource modelDeployments 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = [
  for deployment in deployments: {
    parent: account
    name: deployment.name
    sku: {
      name: deployment.?sku ?? 'GlobalStandard'
      capacity: deployment.capacity
    }
    properties: {
      model: {
        format: 'OpenAI'
        name: deployment.model
        version: deployment.version
      }
      versionUpgradeOption: 'NoAutoUpgrade'
    }
    dependsOn: [
      project
    ]
  }
]

@description('Resource ID.')
output id string = account.id

@description('Resource name.')
output name string = account.name

@description('Azure OpenAI-compatible endpoint, for example https://<name>.openai.azure.com.')
output openAiEndpoint string = 'https://${account.name}.openai.azure.com'

@description('Foundry project resource ID.')
output projectId string = project.id

@description('Foundry project name.')
output projectName string = project.name

@description('Foundry project endpoint for agents and the Responses API.')
output projectEndpoint string = 'https://${account.name}.services.ai.azure.com/api/projects/${project.name}'
