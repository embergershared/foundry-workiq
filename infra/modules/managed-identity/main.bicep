// Managed identity
//
// Contract (enforced by tests/catalog.tests.ps1):
//   params  : name, location, tags
//   outputs : id, name
//
// A user-assigned identity outlives the workload that uses it, so its role
// assignments survive app redeployments. Grant roles from the modules that own
// the target resources, passing principalId.

@description('Resource name. Build it with azName(abbreviations.managedIdentity, ...) from infra/core/naming.bicep, using the workload as the suffix.')
@minLength(3)
@maxLength(128)
param name string

@description('Azure region.')
param location string = resourceGroup().location

@description('Common tags from infra/core/tags.bicep.')
param tags object = {}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

@description('Resource ID.')
output id string = identity.id

@description('Resource name.')
output name string = identity.name

@description('Object (principal) ID, used for role assignments.')
output principalId string = identity.properties.principalId

@description('Client ID, passed to workloads as AZURE_CLIENT_ID.')
output clientId string = identity.properties.clientId
