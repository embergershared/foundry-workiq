# container-apps-environment

VNet-integrated workload-profiles Container Apps environment with Log Analytics logging and a named infrastructure resource group.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `cae` |
| Providers | `Microsoft.App`, `Microsoft.OperationalInsights` |
| Private endpoints | – |
| Feature flag | `containerAppsEnvironment` |
| Name rule | `regional` |

## Purpose

A workload-profiles (v2) Container Apps environment on the Consumption profile, sending logs to Log Analytics. With `infrastructureSubnetId` it is VNet-integrated, so apps reach private endpoints; pair it with the `network` module's container apps subnet, which is delegated to `Microsoft.App/environments`. The legacy Consumption-only (v1) type is deliberately not offered.

`infrastructureResourceGroupName` names the platform-managed resource group. Use `managedResourceGroupName(resourceGroupName)` from `infra/core/naming.bicep`, which gives `<resource group name>-managed`, instead of the generated `ME_...` name. Azure cannot rename it later: changing it recreates the environment.

Some subscriptions must first register `Microsoft.Network/AllowBringYourOwnPublicIpAddress` (`az feature register`, then `az provider register -n Microsoft.Network`). An environment created before that registration has no static IP and must be deleted and recreated.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes |  |
| `location` | string | no |  |
| `tags` | object | no |  |
| `infrastructureSubnetId` | string | no | Delegated subnet; empty means no VNet integration |
| `internal` | bool | no | VNet-only ingress; default `false` |
| `infrastructureResourceGroupName` | string | no | Platform-managed resource group name |
| `logAnalyticsWorkspaceId` | string | yes | Log destination |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `defaultDomain` |  |
| `staticIp` |  |

## Wire-up

```bicep
module containerAppsEnvironment 'modules/container-apps-environment/main.bicep' = {
  scope: resourceGroup
  name: 'container-apps-environment'
  params: {
    name: azName(abbreviations.containerAppsEnvironment, tenantCode, locationCode, subscriptionCode, environmentName, '')
    location: location
    tags: tags
    infrastructureSubnetId: network.outputs.containerAppsSubnetId
    infrastructureResourceGroupName: managedResourceGroupName(resourceGroupName)
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}
```
