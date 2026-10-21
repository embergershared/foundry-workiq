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
//
// Foundry User is granted on both the account and the project: agents that
// call tools on behalf of a user fail with "Principal does not have access to
// API/Operation" when either scope is missing.

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

@description('Principals that build with and run agents in the project: [{ principalId, principalType }]. Granted Foundry User on the account and the project.')
param userPrincipals principal[] = []

@description('Principals that manage the project, including its connections: [{ principalId, principalType }]. Granted Foundry Project Manager on the project.')
param projectManagerPrincipals principal[] = []

@description('Create the role assignments above. Disable when the deployer lacks roleAssignments/write.')
param enableRoleAssignments bool = true

@description('An Entra principal and its type, so role assignments do not wait on directory replication.')
type principal = {
  @minLength(36)
  @maxLength(36)
  principalId: string
  principalType: 'User' | 'Group' | 'ServicePrincipal'
}

// Role definition IDs, not names: the Foundry roles were renamed from Azure AI
// User and Azure AI Project Manager, and the IDs did not change.
var foundryUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '53ca6127-db72-4b80-b1b0-d745d6d5456d'
)
var foundryProjectManagerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'eadc314b-1a2d-4efa-be10-5d325db5065e'
)

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

resource accountUserAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for user in userPrincipals: if (enableRoleAssignments) {
    name: guid(account.id, user.principalId, foundryUserRoleId)
    scope: account
    properties: {
      principalId: user.principalId
      principalType: user.principalType
      roleDefinitionId: foundryUserRoleId
    }
  }
]

resource projectUserAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for user in userPrincipals: if (enableRoleAssignments) {
    name: guid(project.id, user.principalId, foundryUserRoleId)
    scope: project
    properties: {
      principalId: user.principalId
      principalType: user.principalType
      roleDefinitionId: foundryUserRoleId
    }
  }
]

resource projectManagerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for manager in projectManagerPrincipals: if (enableRoleAssignments) {
    name: guid(project.id, manager.principalId, foundryProjectManagerRoleId)
    scope: project
    properties: {
      principalId: manager.principalId
      principalType: manager.principalType
      roleDefinitionId: foundryProjectManagerRoleId
    }
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
