// Work IQ tenant bootstrap: Entra resources for the Foundry Work IQ connection
//
// Deployed once per tenant by scripts/bootstrap-tenant.ps1, never by azd. The
// Microsoft Graph extension does not support what-if, so keeping these
// resources out of infra/main.bicep keeps `azd provision --preview` working,
// and the tenant-wide consent grant below needs an administrator that the
// day-to-day deployer is not.
//
// Requires the Work IQ service principal to exist in the tenant already; the
// bootstrap script provisions it before this deployment runs.

targetScope = 'subscription'

extension microsoftGraphV1

@description('Client-provided key for the app registration. Keep it stable: changing it creates a second app.')
@minLength(1)
@maxLength(64)
param appUniqueName string = 'foundry-workiq'

@description('Display name of the app registration.')
@minLength(1)
@maxLength(120)
param appDisplayName string = 'Foundry Work IQ connection'

@description('Web redirect URIs. Each Foundry Work IQ connection returns one after it is created; pass every known value so a redeploy keeps them.')
param redirectUris string[] = []

@description('Client-provided key for the security group whose members can use the Work IQ agent.')
@minLength(1)
@maxLength(64)
param usersGroupUniqueName string = 'foundry-workiq-users'

@description('Display name of the Work IQ users security group.')
@minLength(1)
@maxLength(120)
param usersGroupDisplayName string = 'Foundry Work IQ users'

@description('Entra object IDs that own the app registration and the group. Owners can add secrets and redirect URIs without a directory role.')
@minLength(1)
param ownerObjectIds string[]

@description('Entra user object IDs added to the Work IQ users group.')
param userObjectIds string[] = []

@description('Application ID of the Microsoft-owned Work IQ API.')
param workIqAppId string = 'fdcc1f02-fc51-4226-8753-f668596af7f7'

@description('Delegated permission the connection requests on behalf of the signed-in user.')
param workIqScope string = 'WorkIQAgent.Ask'

resource workIq 'Microsoft.Graph/servicePrincipals@v1.0' existing = {
  appId: workIqAppId
}

// The scope ID is read from the Work IQ service principal rather than
// hard-coded, so a renamed or reissued scope fails the deployment here instead
// of producing an app that requests a permission that no longer exists.
var workIqScopeId = filter(workIq.oauth2PermissionScopes, scope => scope.value == workIqScope)[0].id

resource app 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: appUniqueName
  displayName: appDisplayName
  signInAudience: 'AzureADMyOrg'
  requiredResourceAccess: [
    {
      resourceAppId: workIqAppId
      resourceAccess: [
        {
          id: workIqScopeId
          type: 'Scope'
        }
      ]
    }
  ]
  web: {
    redirectUris: redirectUris
  }
  owners: {
    relationships: ownerObjectIds
  }
}

resource appServicePrincipal 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: app.appId
  owners: {
    relationships: ownerObjectIds
  }
}

// Tenant-wide admin consent for the delegated Work IQ scope. This is the
// equivalent of "Grant admin consent" in the portal.
resource adminConsent 'Microsoft.Graph/oauth2PermissionGrants@v1.0' = {
  clientId: appServicePrincipal.id
  consentType: 'AllPrincipals'
  resourceId: workIq.id
  scope: workIqScope
}

resource usersGroup 'Microsoft.Graph/groups@v1.0' = {
  uniqueName: usersGroupUniqueName
  displayName: usersGroupDisplayName
  mailEnabled: false
  mailNickname: usersGroupUniqueName
  securityEnabled: true
  owners: {
    relationships: ownerObjectIds
  }
  members: {
    relationships: userObjectIds
  }
}

@description('Application (client) ID of the Work IQ app registration.')
output appId string = app.appId

@description('Object ID of the Work IQ app registration.')
output appObjectId string = app.id

@description('Object ID of the app registration service principal.')
output appServicePrincipalId string = appServicePrincipal.id

@description('Object ID of the Work IQ users security group.')
output usersGroupId string = usersGroup.id
