// Azure Managed Redis with RediSearch, for the API Management semantic cache
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// An Azure Managed Redis cluster (Microsoft.Cache/redisEnterprise) with one
// database that API Management can use as its external cache, which the
// llm-semantic-cache-lookup and llm-semantic-cache-store policies require.
//
// RediSearch is enabled on the database because semantic caching stores and
// searches prompt embeddings with it. Redis allows modules, the clustering
// policy and the eviction policy only when a database is created, and
// RediSearch requires the Enterprise clustering policy and the NoEviction
// eviction policy, so all three are fixed here rather than parameters.
//
// API Management connects with an access-key connection string and does not
// support Microsoft Entra authentication to Azure Managed Redis, so access
// keys stay enabled on the database. The key never leaves Azure Resource
// Manager: the api-management module reads it with listKeys() into a secret
// named value.
//
// The cluster name is also its <name>.<region>.redis.azure.net host name,
// which must be globally unique: build it with
// globalName(abbreviations.managedRedis, ..., '-', 60).

@description('Cluster name and host name prefix.')
@minLength(1)
@maxLength(60)
param name string

@description('Azure region. Keep it with the API Management instance that uses the cache.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}

@description('Memory Optimized, Balanced or Compute Optimized SKU. Flash Optimized does not support RediSearch.')
@allowed([
  'Balanced_B0'
  'Balanced_B1'
  'Balanced_B3'
  'Balanced_B5'
  'Balanced_B10'
  'MemoryOptimized_M10'
  'MemoryOptimized_M20'
  'ComputeOptimized_X3'
  'ComputeOptimized_X5'
  'ComputeOptimized_X10'
])
param sku string = 'Balanced_B0'

@description('Replicate the cluster across nodes. Required for the SLA; turn it off only for development and test. It cannot be turned off again once enabled.')
@allowed([
  'Enabled'
  'Disabled'
])
param highAvailability string = 'Enabled'

@description('Log Analytics workspace that receives the cluster metrics and the database connection events. Empty skips diagnostics.')
param logAnalyticsWorkspaceId string = ''

resource cluster 'Microsoft.Cache/redisEnterprise@2025-04-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    highAvailability: highAvailability
    minimumTlsVersion: '1.2'
  }
}

resource database 'Microsoft.Cache/redisEnterprise/databases@2025-04-01' = {
  parent: cluster
  // API Management and the portal expect the single database to be 'default'.
  name: 'default'
  properties: {
    clientProtocol: 'Encrypted'
    port: 10000
    clusteringPolicy: 'EnterpriseCluster'
    evictionPolicy: 'NoEviction'
    accessKeysAuthentication: 'Enabled'
    modules: [
      {
        name: 'RediSearch'
      }
    ]
  }
}

resource clusterDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'send-to-log-analytics'
  scope: cluster
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource databaseDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  name: 'send-to-log-analytics'
  scope: database
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

@description('Resource ID.')
output id string = cluster.id

@description('Resource name.')
output name string = cluster.name

@description('Host name, for example <name>.<region>.redis.azure.net.')
output hostName string = cluster.properties.hostName

@description('TLS port of the database.')
output port int = database.properties.port
