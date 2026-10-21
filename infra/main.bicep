targetScope = 'subscription'

import {
  abbreviations
  tenantCodeFor
  locationCodeFor
  azName
  globalName
  shortName
} from './core/naming.bicep'
import { commonTags } from './core/tags.bicep'

@description('Short azd environment name used in resource names and tags.')
@minLength(2)
@maxLength(32)
param environmentName string

@description('Azure region for the resource group and regional resources.')
param location string = 'eastus2'

@description('Stable s<N> code derived from the Azure subscription display name (or ID); see scripts/naming.ps1.')
@minLength(2)
@maxLength(5)
param subscriptionCode string

@description('Deployment profile. core deploys the resource group, tags and monitoring only. private adds the virtual network, private DNS and private Key Vault and storage. full adds Bastion, jumpbox VMs, NAT Gateway and Entra login. minimal is a deprecated alias for private.')
@allowed([
  'core'
  'private'
  'full'
  'minimal'
])
param deploymentProfile string = 'core'

@description('Repository identifier applied to common tags. Seeded from the git remote by the azd preprovision hook.')
@minLength(1)
@maxLength(256)
param repository string

@description('Optional owner tag. Avoid personal data; prefer a team or service identifier.')
@maxLength(256)
param owner string = ''

@description('Optional cost-center tag.')
@maxLength(256)
param costCenter string = ''

@description('Creation timestamp seeded once by the azd preprovision hook.')
@minLength(25)
@maxLength(25)
param createdOn string

@description('Last-update timestamp refreshed by the azd preprovision hook.')
@minLength(25)
@maxLength(25)
param lastUpdatedOn string

// `minimal` is accepted so environments provisioned before the three-rung
// ladder keep working. Every downstream decision uses resolvedProfile.
var resolvedProfile = deploymentProfile == 'minimal' ? 'private' : deploymentProfile
var isPrivateOrHigher = resolvedProfile != 'core'
var isFull = resolvedProfile == 'full'

@description('Deploy the virtual network, subnets, NSGs and private DNS. Defaults on for private and full.')
param enableNetwork bool?

@description('Deploy the Key Vault catalog module. Defaults on for private and full.')
param enableKeyVault bool?

@description('Deploy the storage account catalog module. Defaults on for private and full.')
param enableStorage bool?

@description('Deploy Standard Azure Bastion. Defaults on for the full profile.')
param enableBastion bool?

@description('Deploy the Windows 11 Pro jumpbox. Defaults on for the full profile.')
param enableWindowsVm bool?

@description('Deploy the Ubuntu jumpbox. Defaults on for the full profile.')
param enableLinuxVm bool?

@description('Enable outbound internet from the jumpbox subnet through a NAT Gateway. Defaults on for full and must be disabled with Entra login for air-gapped deployments.')
param enableNatGateway bool?

@description('Install Microsoft Entra login extensions on jumpbox VMs. Defaults on for full and must match the NAT Gateway setting.')
param enableEntraLogin bool?

@description('Optional MDM application ID passed to AADLoginForWindows. Leave empty for Entra login without automatic MDM enrollment.')
@maxLength(36)
param windowsMdmId string = ''

@description('Create VM auto-shutdown schedules. Defaults on for the full profile.')
param enableShutdownSchedules bool?

@description('Create configured operator RBAC assignments. Disable when the deployer lacks roleAssignments/write.')
param enableRoleAssignments bool = true

@description('Base64-encoded JSON object overriding profile feature flags. Supported keys: network, keyVault, storage, bastion, windowsVm, linuxVm, natGateway, entraLogin, shutdownSchedules, roleAssignments. natGateway and entraLogin must match.')
param featureOverridesBase64 string = 'e30='

@description('Comma-separated Entra user or group object IDs that receive VM login and private data-plane roles.')
param operatorPrincipalIdsCsv string = ''

@description('VNet address space. Default subnet parameters are derived from this /22.')
param vnetAddressPrefix string = '10.42.0.0/22'

@description('Azure Bastion subnet. Azure requires /26 or larger.')
param bastionSubnetPrefix string = cidrSubnet(vnetAddressPrefix, 26, 0)

@description('Private jumpbox subnet.')
param jumpboxSubnetPrefix string = cidrSubnet(vnetAddressPrefix, 26, 1)

@description('Private endpoint subnet.')
param privateEndpointSubnetPrefix string = cidrSubnet(vnetAddressPrefix, 27, 4)

@description('Windows VM size.')
param windowsVmSize string = 'Standard_D4s_v5'

@description('Ubuntu VM size.')
param linuxVmSize string = 'Standard_D2s_v5'

@description('Windows 11 Pro Marketplace image.')
param windowsImage object = {
  publisher: 'MicrosoftWindowsDesktop'
  offer: 'windows-11'
  sku: 'win11-24h2-pro'
  version: 'latest'
}

@description('Ubuntu Server 24.04 LTS Marketplace image.')
param linuxImage object = {
  publisher: 'Canonical'
  offer: 'ubuntu-24_04-lts'
  sku: 'server'
  version: 'latest'
}

@description('Local Windows break-glass account name.')
param windowsAdminUsername string = 'azurelocaladmin'

@description('Local Ubuntu break-glass account name.')
param linuxAdminUsername string = 'azurelocaladmin'

@description('Log Analytics retention in days.')
@minValue(30)
@maxValue(730)
param logRetentionInDays int = 30

@description('Log Analytics daily ingestion cap in GB.')
@minValue(1)
param logDailyCapGb int = 1

@description('Local auto-shutdown time in HHmm format.')
@minLength(4)
@maxLength(4)
param shutdownTime string = '1900'

@description('Windows time zone ID used by Azure DevTest Lab auto-shutdown schedules.')
param shutdownTimeZone string = 'Eastern Standard Time'

// Resolved from infra/core/tenant-codes.json; an unlisted tenant fails here and in preflight.
var tenantCode = tenantCodeFor(tenant().tenantId)
var locationCode = locationCodeFor(location)
var shortUniqueSuffix = take(uniqueString(subscription().id, environmentName, location), 3)

var resourceGroupName = azName(
  abbreviations.resourceGroup,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  ''
)
var vnetName = azName(abbreviations.virtualNetwork, tenantCode, locationCode, subscriptionCode, environmentName, '')
var bastionNsgName = azName(
  abbreviations.networkSecurityGroup,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'bastion'
)
var jumpboxNsgName = azName(
  abbreviations.networkSecurityGroup,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'jumpboxes'
)
var privateEndpointNsgName = azName(
  abbreviations.networkSecurityGroup,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'private-endpoints'
)
var jumpboxSubnetName = azName(
  abbreviations.subnet,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'jumpboxes'
)
var privateEndpointSubnetName = azName(
  abbreviations.subnet,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'private-endpoints'
)
var keyVaultName = globalName(
  abbreviations.keyVault,
  locationCode,
  subscriptionCode,
  environmentName,
  shortUniqueSuffix,
  '-',
  24
)
var keyVaultPrivateEndpointName = azName(
  abbreviations.privateEndpoint,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'kv'
)
var keyVaultPrivateEndpointNicName = azName(
  abbreviations.privateEndpointNetworkInterface,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'kv'
)
var storageAccountName = globalName(
  abbreviations.storageAccount,
  locationCode,
  subscriptionCode,
  environmentName,
  shortUniqueSuffix,
  '',
  24
)
var blobPrivateEndpointName = azName(
  abbreviations.privateEndpoint,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'blob'
)
var blobPrivateEndpointNicName = azName(
  abbreviations.privateEndpointNetworkInterface,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'blob'
)
var filePrivateEndpointName = azName(
  abbreviations.privateEndpoint,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'file'
)
var filePrivateEndpointNicName = azName(
  abbreviations.privateEndpointNetworkInterface,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'file'
)
var logAnalyticsName = azName(
  abbreviations.logAnalytics,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  ''
)
var appInsightsName = azName(
  abbreviations.applicationInsights,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  ''
)
var natGatewayName = azName(abbreviations.natGateway, tenantCode, locationCode, subscriptionCode, environmentName, '')
var natGatewayPublicIpName = azName(
  abbreviations.publicIp,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'nat'
)
var bastionName = azName(abbreviations.bastion, tenantCode, locationCode, subscriptionCode, environmentName, '')
var bastionPublicIpName = azName(
  abbreviations.publicIp,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'bastion'
)
var windowsVmName = azName(
  abbreviations.windowsVirtualMachine,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  ''
)
var windowsComputerName = shortName('w', environmentName, shortUniqueSuffix, 15)
var windowsNicName = azName(
  abbreviations.networkInterface,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'win'
)
var linuxVmName = azName(
  abbreviations.linuxVirtualMachine,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  ''
)
var linuxNicName = azName(
  abbreviations.networkInterface,
  tenantCode,
  locationCode,
  subscriptionCode,
  environmentName,
  'lin'
)

var tags = commonTags(
  repository,
  tenantCode,
  environmentName,
  resolvedProfile,
  createdOn,
  lastUpdatedOn,
  owner,
  costCenter
)

// Profile defaults resolve here rather than in parameter defaults, which may
// only reference other parameters. An explicitly supplied value always wins,
// so the ladder sets the baseline and the caller keeps the final say.
var featureSettings = union(
  {
    network: enableNetwork ?? isPrivateOrHigher
    keyVault: enableKeyVault ?? isPrivateOrHigher
    storage: enableStorage ?? isPrivateOrHigher
    bastion: enableBastion ?? isFull
    windowsVm: enableWindowsVm ?? isFull
    linuxVm: enableLinuxVm ?? isFull
    natGateway: enableNatGateway ?? isFull
    entraLogin: enableEntraLogin ?? isFull
    shutdownSchedules: enableShutdownSchedules ?? isFull
    roleAssignments: enableRoleAssignments
  },
  json(base64ToString(featureOverridesBase64))
)
var deployBastion = bool(featureSettings.bastion)
var deployWindowsVm = bool(featureSettings.windowsVm)
var deployLinuxVm = bool(featureSettings.linuxVm)
var deployNatGateway = bool(featureSettings.natGateway)
var deployEntraLogin = bool(featureSettings.entraLogin)
var deployShutdownSchedules = bool(featureSettings.shutdownSchedules)
var assignRoles = bool(featureSettings.roleAssignments)
var deployAnyVm = deployWindowsVm || deployLinuxVm

// scripts/preflight.ps1 rejects inconsistent combinations with an actionable
// message. These derivations keep a direct `az deployment sub create` that
// bypasses the azd hooks from producing dangling references.
var deployNetwork = bool(featureSettings.network) || deployBastion || deployAnyVm
var deployKeyVault = bool(featureSettings.keyVault) || deployAnyVm
var deployStorage = bool(featureSettings.storage)

var operatorPrincipalIds = empty(operatorPrincipalIdsCsv)
  ? []
  : map(split(operatorPrincipalIdsCsv, ','), principalId => trim(principalId))

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

// #region modules
module monitoring './modules/monitoring/main.bicep' = {
  name: 'monitoring'
  scope: resourceGroup
  params: {
    name: logAnalyticsName
    location: location
    tags: tags
    applicationInsightsName: appInsightsName
    retentionInDays: logRetentionInDays
    dailyCapGb: logDailyCapGb
  }
}

module natGateway './modules/nat-gateway/main.bicep' = if (deployNetwork) {
  name: 'nat-gateway'
  scope: resourceGroup
  params: {
    name: natGatewayName
    publicIpName: natGatewayPublicIpName
    location: location
    tags: tags
    enabled: deployNatGateway
  }
}

module network './modules/network/main.bicep' = if (deployNetwork) {
  name: 'network'
  scope: resourceGroup
  params: {
    name: vnetName
    bastionNetworkSecurityGroupName: bastionNsgName
    jumpboxNetworkSecurityGroupName: jumpboxNsgName
    privateEndpointNetworkSecurityGroupName: privateEndpointNsgName
    jumpboxSubnetName: jumpboxSubnetName
    privateEndpointSubnetName: privateEndpointSubnetName
    location: location
    tags: tags
    vnetAddressPrefix: vnetAddressPrefix
    bastionSubnetPrefix: bastionSubnetPrefix
    jumpboxSubnetPrefix: jumpboxSubnetPrefix
    privateEndpointSubnetPrefix: privateEndpointSubnetPrefix
    enableNatGateway: deployNatGateway
    natGatewayId: deployNetwork ? natGateway!.outputs.natGatewayId : ''
  }
}

module privateDns './modules/private-dns/main.bicep' = if (deployNetwork) {
  name: 'private-dns'
  scope: resourceGroup
  params: {
    name: 'private-dns'
    location: 'global'
    tags: tags
    virtualNetworkId: deployNetwork ? network!.outputs.virtualNetworkId : ''
  }
}

module keyVault './modules/key-vault/main.bicep' = if (deployKeyVault) {
  name: 'key-vault'
  scope: resourceGroup
  params: {
    name: keyVaultName
    privateEndpointName: keyVaultPrivateEndpointName
    privateEndpointNetworkInterfaceName: keyVaultPrivateEndpointNicName
    location: location
    tags: tags
    privateEndpointSubnetId: deployNetwork ? network!.outputs.privateEndpointSubnetId : ''
    privateDnsZoneId: deployNetwork ? privateDns!.outputs.keyVaultZoneId : ''
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    enableWindowsVm: deployWindowsVm
    enableLinuxVm: deployLinuxVm
    windowsAdminUsername: windowsAdminUsername
    linuxAdminUsername: linuxAdminUsername
    enableRoleAssignments: assignRoles
    operatorPrincipalIds: operatorPrincipalIds
  }
}

module storage './modules/storage/main.bicep' = if (deployStorage) {
  name: 'storage'
  scope: resourceGroup
  params: {
    name: storageAccountName
    blobPrivateEndpointName: blobPrivateEndpointName
    blobPrivateEndpointNetworkInterfaceName: blobPrivateEndpointNicName
    filePrivateEndpointName: filePrivateEndpointName
    filePrivateEndpointNetworkInterfaceName: filePrivateEndpointNicName
    location: location
    tags: tags
    privateEndpointSubnetId: deployNetwork ? network!.outputs.privateEndpointSubnetId : ''
    blobPrivateDnsZoneId: deployNetwork ? privateDns!.outputs.blobZoneId : ''
    filePrivateDnsZoneId: deployNetwork ? privateDns!.outputs.fileZoneId : ''
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    enableRoleAssignments: assignRoles
    operatorPrincipalIds: operatorPrincipalIds
  }
}

module bastion './modules/bastion/main.bicep' = if (deployBastion) {
  name: 'bastion'
  scope: resourceGroup
  params: {
    name: bastionName
    publicIpName: bastionPublicIpName
    location: location
    tags: tags
    bastionSubnetId: deployNetwork ? network!.outputs.bastionSubnetId : ''
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module jumpboxes './modules/jumpboxes/main.bicep' = if (deployAnyVm) {
  name: 'jumpboxes'
  scope: resourceGroup
  params: {
    windowsVmName: windowsVmName
    windowsComputerName: windowsComputerName
    windowsNicName: windowsNicName
    linuxVmName: linuxVmName
    linuxNicName: linuxNicName
    location: location
    tags: tags
    jumpboxSubnetId: deployNetwork ? network!.outputs.jumpboxSubnetId : ''
    deployWindowsVm: deployWindowsVm
    deployLinuxVm: deployLinuxVm
    windowsVmSize: windowsVmSize
    linuxVmSize: linuxVmSize
    windowsImage: windowsImage
    linuxImage: linuxImage
    windowsAdminUsername: windowsAdminUsername
    windowsAdminPassword: deployWindowsVm ? deployedKeyVault.getSecret('windows-admin-password') : ''
    linuxAdminUsername: linuxAdminUsername
    linuxAdminPassword: deployLinuxVm ? deployedKeyVault.getSecret('linux-admin-password') : ''
    enableEntraLogin: deployEntraLogin
    windowsMdmId: windowsMdmId
    credentialRotationTag: lastUpdatedOn
    enableShutdownSchedules: deployShutdownSchedules
    shutdownTime: shutdownTime
    shutdownTimeZone: shutdownTimeZone
    enableRoleAssignments: assignRoles
    operatorPrincipalIds: operatorPrincipalIds
  }
  dependsOn: [
    keyVault
  ]
}
// #endregion modules

resource deployedKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
  scope: resourceGroup
}

output AZURE_RESOURCE_GROUP string = resourceGroup.name
output AZURE_DEPLOYMENT_PROFILE string = resolvedProfile
output AZURE_VIRTUAL_NETWORK_NAME string = deployNetwork ? network!.outputs.virtualNetworkName : ''
output AZURE_KEY_VAULT_NAME string = deployKeyVault ? keyVault!.outputs.name : ''
output AZURE_STORAGE_ACCOUNT_NAME string = deployStorage ? storage!.outputs.name : ''
output AZURE_LOG_ANALYTICS_WORKSPACE_ID string = monitoring.outputs.logAnalyticsWorkspaceId
output AZURE_APPLICATION_INSIGHTS_NAME string = monitoring.outputs.applicationInsightsName
output AZURE_BASTION_NAME string = deployBastion ? bastion!.outputs.name : ''
output AZURE_WINDOWS_VM_NAME string = deployWindowsVm ? jumpboxes!.outputs.windowsVmName : ''
output AZURE_LINUX_VM_NAME string = deployLinuxVm ? jumpboxes!.outputs.linuxVmName : ''
