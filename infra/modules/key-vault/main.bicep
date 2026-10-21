targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
param name string
param location string = resourceGroup().location
param tags object = {}
@minLength(2)
@maxLength(80)
param privateEndpointName string
@minLength(2)
@maxLength(80)
param privateEndpointNetworkInterfaceName string
@description('Subnet that hosts the private endpoint. Leave empty to deploy public-with-firewall.')
param privateEndpointSubnetId string = ''
@description('Private DNS zone that resolves the private endpoint. Leave empty to deploy public-with-firewall.')
param privateDnsZoneId string = ''
param logAnalyticsWorkspaceId string
param enableWindowsVm bool = false
param enableLinuxVm bool = false
param windowsAdminUsername string
@secure()
param windowsAdminPassword string = newGuid()
param linuxAdminUsername string
@secure()
param linuxAdminPassword string = newGuid()
param enableRoleAssignments bool = true
param operatorPrincipalIds array = []

var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

// One module body serves every profile. With both private-networking inputs
// supplied the vault is private-only; without them it stays reachable on the
// public endpoint but the firewall still denies everything by default.
var usePrivateEndpoint = !empty(privateEndpointSubnetId) && !empty(privateDnsZoneId)

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    accessPolicies: []
    enableRbacAuthorization: true
    enablePurgeProtection: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: true
    publicNetworkAccess: usePrivateEndpoint ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

resource windowsUsernameSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (enableWindowsVm) {
  parent: keyVault
  name: 'windows-admin-username'
  tags: tags
  properties: {
    value: windowsAdminUsername
  }
}

resource windowsPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (enableWindowsVm) {
  parent: keyVault
  name: 'windows-admin-password'
  tags: tags
  properties: {
    value: windowsAdminPassword
  }
}

resource linuxUsernameSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (enableLinuxVm) {
  parent: keyVault
  name: 'linux-admin-username'
  tags: tags
  properties: {
    value: linuxAdminUsername
  }
}

resource linuxPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2024-11-01' = if (enableLinuxVm) {
  parent: keyVault
  name: 'linux-admin-password'
  tags: tags
  properties: {
    value: linuxAdminPassword
  }
}

module privateEndpoint '../../core/private-endpoint.bicep' = if (usePrivateEndpoint) {
  name: '${name}-private-endpoint'
  params: {
    name: privateEndpointName
    networkInterfaceName: privateEndpointNetworkInterfaceName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: keyVault.id
    groupIds: [
      'vault'
    ]
    privateDnsZoneId: privateDnsZoneId
    connectionName: 'key-vault'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'AuditEvent'
        enabled: true
      }
      {
        category: 'AzurePolicyEvaluationDetails'
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

resource secretReaderAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in operatorPrincipalIds: if (enableRoleAssignments) {
    name: guid(keyVault.id, principalId, keyVaultSecretsUserRoleId)
    scope: keyVault
    properties: {
      principalId: principalId
      roleDefinitionId: keyVaultSecretsUserRoleId
    }
  }
]

@description('Resource ID of the Key Vault.')
output id string = keyVault.id
@description('Name of the Key Vault.')
output name string = keyVault.name
@description('Deprecated alias of `name`, retained for existing callers.')
output keyVaultName string = keyVault.name
@description('Deprecated alias of `id`, retained for existing callers.')
output keyVaultId string = keyVault.id
