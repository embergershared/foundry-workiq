// Container Apps environment
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// Workload-profiles (v2) environment on the Consumption profile. With a subnet
// it is VNet-integrated, which lets apps reach private endpoints; the subnet
// must be delegated to Microsoft.App/environments (see the network module's
// container apps subnet). The Consumption-only (v1) type is deliberately not
// offered: it requires an undelegated /23 and is a legacy option.
//
// Some subscriptions must register Microsoft.Network/AllowBringYourOwnPublicIpAddress
// before a VNet-integrated environment can be created. An environment created
// before that registration has no static IP and must be deleted and recreated.

@description('Resource name. Build it with azName(abbreviations.containerAppsEnvironment, ...) from infra/core/naming.bicep.')
@minLength(2)
@maxLength(60)
param name string

@description('Azure region.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}

@description('Delegated infrastructure subnet. Empty deploys an environment without VNet integration.')
param infrastructureSubnetId string = ''

@description('Expose the environment only inside the VNet. Ignored without a subnet.')
param internal bool = false

@description('Platform-managed resource group holding the environment infrastructure; use managedResourceGroupName(resourceGroupName). Empty lets Azure generate one. Changing it recreates the environment.')
@maxLength(90)
param infrastructureResourceGroupName string = ''

@description('Log Analytics workspace resource ID that receives container logs.')
param logAnalyticsWorkspaceId string

var useVnet = !empty(infrastructureSubnetId)

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
  scope: resourceGroup(split(logAnalyticsWorkspaceId, '/')[2], split(logAnalyticsWorkspaceId, '/')[4])
}

resource environment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    infrastructureResourceGroup: empty(infrastructureResourceGroupName) ? null : infrastructureResourceGroupName
    vnetConfiguration: useVnet
      ? {
          infrastructureSubnetId: infrastructureSubnetId
          internal: internal
        }
      : null
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

@description('Resource ID.')
output id string = environment.id

@description('Resource name.')
output name string = environment.name

@description('Default domain of apps in the environment.')
output defaultDomain string = environment.properties.defaultDomain

@description('Static IP of the environment ingress.')
output staticIp string = environment.properties.staticIp
