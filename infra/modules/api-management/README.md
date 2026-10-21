# api-management

Azure API Management v2 instance (Basic v2 by default) to use as the Foundry AI Gateway, with a managed identity, gateway logs in Log Analytics and the Foundry roles for the gateway.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `full`, `private` |
| Abbreviation | `apim` |
| Providers | `Microsoft.ApiManagement` |
| Private endpoint | none |
| Feature flag | `apiManagement` |
| Name rule | `global` |

## Purpose

A [Foundry AI Gateway](https://learn.microsoft.com/azure/foundry/configuration/enable-ai-api-management-gateway-portal)
is an API Management instance linked to a Foundry account. It sets per-project
token-per-minute limits and token quotas, and governs agents and MCP tools.
Foundry lists an instance under **Use existing APIM** only when it is a v2
tier in the same tenant and subscription, and when you hold API Management
Service Contributor on it.

This module makes the instance eligible and grants the roles. Linking it is a
Foundry portal step with no documented API:

1. In the [Foundry portal](https://ai.azure.com), select **Manage** >
   **AI Gateway** > **Add AI Gateway**, pick the Foundry account, select
   **Use existing**, and pick this instance.
2. Projects created after the link use the gateway. For a project that
   already existed, select the gateway, then **Add project to gateway**.
3. Set token limits under **Token management**.

Basic v2 has no private endpoint. If the Foundry account loses public network
access, use Standard v2 with a private endpoint, which this module doesn't
configure yet.

## Roles

| Principal | Role | Scope |
|---|---|---|
| Instance managed identity | Cognitive Services User | Foundry account |
| `gatewayAdminPrincipals` | API Management Service Contributor | This instance |
| `gatewayAdminPrincipals` | Foundry Account Owner | Foundry account |

The Foundry assignments need `foundryAccountName`; without it the instance
deploys with only its own role.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Also the `*.azure-api.net` host name, so it must be globally unique |
| `location` | string | no | Defaults to the resource group location; keep it with the Foundry account |
| `tags` | object | no | |
| `sku` | string | no | `BasicV2` (default) or `StandardV2` |
| `capacity` | int | no | Scale units, default `1` |
| `publisherEmail` | string | yes | |
| `publisherName` | string | yes | |
| `logAnalyticsWorkspaceId` | string | no | Sends all gateway logs, including LLM logs, to resource-specific tables |
| `foundryAccountName` | string | no | Foundry account in the same resource group |
| `gatewayAdminPrincipals` | principal[] | no | `[{ principalId, principalType }]` |
| `enableRoleAssignments` | bool | no | Default `true` |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `gatewayUrl` | `https://<name>.azure-api.net` |
| `principalId` | Object ID of the instance managed identity |

## Wire-up

`infra/main.bicep` deploys it behind the `apiManagement` feature flag, in the
Foundry account's region:

```bicep
module apiManagement './modules/api-management/main.bicep' = if (deployApiManagement) {
  name: 'api-management'
  scope: resourceGroup
  params: {
    name: apiManagementName
    location: apiManagementLocation
    tags: tags
    sku: apiManagementSku
    publisherEmail: apiManagementPublisherEmail
    publisherName: apiManagementPublisherName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    foundryAccountName: deployAiFoundry ? aiFoundry!.outputs.name : ''
    gatewayAdminPrincipals: deployerPrincipals
    enableRoleAssignments: assignRoles
  }
}
```
