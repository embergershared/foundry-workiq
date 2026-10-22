// Azure API Management for the Foundry AI Gateway
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// A v2-tier instance, which is what Foundry requires before it lists an
// instance under Manage > AI Gateway > Use existing. Linking the instance to
// the Foundry account is a portal step with no documented API, so this module
// stops at making the instance eligible and the roles ready:
//
//   - the instance's managed identity gets Cognitive Services User on the
//     Foundry account, so the gateway can call the model deployments;
//   - gatewayAdminPrincipals get API Management Service Contributor on the
//     instance and Foundry Account Owner on the Foundry account, the two roles
//     the portal link needs.
//
// The instance name is also its *.azure-api.net host name, which must be
// globally unique: build it with globalName(abbreviations.apiManagement, ...,
// '-', 50).

@description('Instance name and host name prefix.')
@minLength(1)
@maxLength(50)
param name string

@description('Azure region. Keep it with the Foundry account to avoid cross-region latency on every model call.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}

@description('v2 tier. Basic v2 is for development and test; use Standard v2 for production or a private endpoint.')
@allowed([
  'BasicV2'
  'StandardV2'
])
param sku string = 'BasicV2'

@description('Scale units.')
@minValue(1)
@maxValue(10)
param capacity int = 1

@description('Publisher email, shown in the developer portal and used for service notifications.')
@minLength(3)
param publisherEmail string

@description('Publisher organization name.')
@minLength(1)
param publisherName string

@description('Log Analytics workspace that receives the gateway logs, including the LLM logs. Empty skips diagnostics.')
param logAnalyticsWorkspaceId string = ''

@description('Foundry (AIServices) account in this resource group that the gateway fronts. Empty skips the Foundry role assignments.')
param foundryAccountName string = ''

@description('Principals that link the gateway in the Foundry portal and manage its token limits: [{ principalId, principalType }].')
param gatewayAdminPrincipals principal[] = []

@description('Create the role assignments above. Disable when the deployer lacks roleAssignments/write.')
param enableRoleAssignments bool = true

@description('An Entra principal and its type, so role assignments do not wait on directory replication.')
type principal = {
  @minLength(36)
  @maxLength(36)
  principalId: string
  principalType: 'User' | 'Group' | 'ServicePrincipal'
}

// Role definition IDs, not names: Foundry Account Owner was renamed from
// Azure AI Account Owner, and the ID did not change.
var cognitiveServicesUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a97b65f3-24c7-4388-baec-2e87135dc908'
)
var apiManagementServiceContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '312a565d-c81f-4fd8-895a-4e21e48d571c'
)
var foundryAccountOwnerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'e47c6f54-e4a2-4754-9501-8e0985b135e1'
)
var frontsFoundry = !empty(foundryAccountName)

resource apiManagement 'Microsoft.ApiManagement/service@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
    capacity: capacity
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: publisherEmail
    publisherName: publisherName
    publicNetworkAccess: 'Enabled'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'send-to-log-analytics'
  scope: apiManagement
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    // Resource-specific tables (ApiManagementGatewayLogs), which the Foundry
    // AI Gateway article queries to confirm traffic goes through the gateway.
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource foundryAccount 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = if (frontsFoundry) {
  name: frontsFoundry ? foundryAccountName : 'unused'
}

resource gatewayInferenceAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (frontsFoundry && enableRoleAssignments) {
  name: guid(foundryAccount.id, apiManagement.id, cognitiveServicesUserRoleId)
  scope: foundryAccount
  properties: {
    principalId: apiManagement.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: cognitiveServicesUserRoleId
  }
}

resource serviceContributorAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for admin in gatewayAdminPrincipals: if (enableRoleAssignments) {
    name: guid(apiManagement.id, admin.principalId, apiManagementServiceContributorRoleId)
    scope: apiManagement
    properties: {
      principalId: admin.principalId
      principalType: admin.principalType
      roleDefinitionId: apiManagementServiceContributorRoleId
    }
  }
]

resource foundryAccountOwnerAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for admin in gatewayAdminPrincipals: if (frontsFoundry && enableRoleAssignments) {
    name: guid(foundryAccount.id, admin.principalId, foundryAccountOwnerRoleId)
    scope: foundryAccount
    properties: {
      principalId: admin.principalId
      principalType: admin.principalType
      roleDefinitionId: foundryAccountOwnerRoleId
    }
  }
]

@description('Resource ID.')
output id string = apiManagement.id

@description('Resource name.')
output name string = apiManagement.name

@description('Gateway URL, for example https://<name>.azure-api.net.')
output gatewayUrl string = apiManagement.properties.gatewayUrl

@description('Object ID of the instance managed identity.')
output principalId string = apiManagement.identity.principalId
