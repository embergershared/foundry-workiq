targetScope = 'resourceGroup'

@minLength(3)
@maxLength(24)
param name string
param location string = resourceGroup().location
param tags object = {}
@minLength(2)
@maxLength(80)
param blobPrivateEndpointName string
@minLength(2)
@maxLength(80)
param blobPrivateEndpointNetworkInterfaceName string
@minLength(2)
@maxLength(80)
param filePrivateEndpointName string
@minLength(2)
@maxLength(80)
param filePrivateEndpointNetworkInterfaceName string
@description('Subnet that hosts the private endpoints. Leave empty to deploy public-with-firewall.')
param privateEndpointSubnetId string = ''
@description('Private DNS zone resolving the blob endpoint. Leave empty to deploy public-with-firewall.')
param blobPrivateDnsZoneId string = ''
@description('Private DNS zone resolving the file endpoint. Leave empty to deploy public-with-firewall.')
param filePrivateDnsZoneId string = ''
param logAnalyticsWorkspaceId string
param enableRoleAssignments bool = true
param operatorPrincipalIds array = []
@description('Private blob containers to create.')
param blobContainerNames array = []
@description('Delete block blobs in blobContainerNames this many days after their last modification. 0 disables the lifecycle rule.')
@minValue(0)
param deleteBlobsAfterDays int = 0

// One module body serves every profile. With the private-networking inputs
// supplied the account is private-only; without them it stays reachable on the
// public endpoint but the firewall still denies everything by default.
var useBlobPrivateEndpoint = !empty(privateEndpointSubnetId) && !empty(blobPrivateDnsZoneId)
var useFilePrivateEndpoint = !empty(privateEndpointSubnetId) && !empty(filePrivateDnsZoneId)
var usePrivateEndpoints = useBlobPrivateEndpoint || useFilePrivateEndpoint

var blobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)
var fileDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0c867c2a-1d8c-454a-a3db-ab2ea1bdc8bb'
)

resource storageAccount 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: name
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    isHnsEnabled: false
    isLocalUserEnabled: false
    isSftpEnabled: false
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: usePrivateEndpoints ? 'Disabled' : 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'None'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
        file: {
          enabled: true
          keyType: 'Account'
        }
      }
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource blobContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = [
  for containerName in blobContainerNames: {
    parent: blobService
    name: containerName
    properties: {
      publicAccess: 'None'
    }
  }
]

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2025-01-01' = if (deleteBlobsAfterDays > 0 && !empty(blobContainerNames)) {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-blobs'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [for containerName in blobContainerNames: '${containerName}/']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: deleteBlobsAfterDays
                }
              }
            }
          }
        }
      ]
    }
  }
  dependsOn: [
    blobContainers
  ]
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

module blobPrivateEndpoint '../../core/private-endpoint.bicep' = if (useBlobPrivateEndpoint) {
  name: '${name}-blob-private-endpoint'
  params: {
    name: blobPrivateEndpointName
    networkInterfaceName: blobPrivateEndpointNetworkInterfaceName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: storageAccount.id
    groupIds: [
      'blob'
    ]
    privateDnsZoneId: blobPrivateDnsZoneId
    connectionName: 'blob'
  }
}

module filePrivateEndpoint '../../core/private-endpoint.bicep' = if (useFilePrivateEndpoint) {
  name: '${name}-file-private-endpoint'
  params: {
    name: filePrivateEndpointName
    networkInterfaceName: filePrivateEndpointNetworkInterfaceName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: storageAccount.id
    groupIds: [
      'file'
    ]
    privateDnsZoneId: filePrivateDnsZoneId
    connectionName: 'file'
  }
}

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource fileDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: fileService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'Transaction'
        enabled: true
      }
    ]
  }
}

resource blobRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in operatorPrincipalIds: if (enableRoleAssignments) {
    name: guid(storageAccount.id, principalId, blobDataContributorRoleId)
    scope: storageAccount
    properties: {
      principalId: principalId
      roleDefinitionId: blobDataContributorRoleId
    }
  }
]

resource fileRoleAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in operatorPrincipalIds: if (enableRoleAssignments) {
    name: guid(storageAccount.id, principalId, fileDataContributorRoleId)
    scope: storageAccount
    properties: {
      principalId: principalId
      roleDefinitionId: fileDataContributorRoleId
    }
  }
]

@description('Resource ID of the storage account.')
output id string = storageAccount.id
@description('Name of the storage account.')
output name string = storageAccount.name
@description('Deprecated alias of `name`, retained for existing callers.')
output storageAccountName string = storageAccount.name
@description('Deprecated alias of `id`, retained for existing callers.')
output storageAccountId string = storageAccount.id
