# key-vault

RBAC-authorized Key Vault with soft delete and purge protection.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `core`, `private`, `full` |
| Abbreviation | `kv` |
| Providers | `Microsoft.KeyVault` |
| Private endpoint | `vault` -> `privatelink.vaultcore.azure.net` |
| Feature flag | `keyVault` |
| Name rule | `global` (24 character budget, hyphenated) |

## Purpose

Holds the generated jumpbox credentials in the `full` profile, and is available
as an opt-in secret store in `core` and `private`.

The module body is identical in all three profiles. Supplying
`privateEndpointSubnetId` and `privateDnsZoneId` switches it from
public-with-firewall to private-only; leaving both empty leaves it reachable
from trusted Azure services with a deny-by-default firewall.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | |
| `location` | string | no | Defaults to the resource group location |
| `tags` | object | no | |
| `privateEndpointName` | string | yes | Ignored when no subnet is supplied |
| `privateEndpointNetworkInterfaceName` | string | yes | Ignored when no subnet is supplied |
| `privateEndpointSubnetId` | string | no | Empty means public with firewall |
| `privateDnsZoneId` | string | no | Empty means public with firewall |
| `logAnalyticsWorkspaceId` | string | yes | Diagnostics target |
| `enableWindowsVm` / `enableLinuxVm` | bool | no | Controls which credential secrets are written |
| `windowsAdminUsername` / `linuxAdminUsername` | string | yes | |
| `windowsAdminPassword` / `linuxAdminPassword` | securestring | no | Defaults to `newGuid()` |
| `enableRoleAssignments` | bool | no | Default `true` |
| `operatorPrincipalIds` | array | no | Granted Key Vault Secrets User |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `keyVaultId` / `keyVaultName` | Deprecated aliases, kept for compatibility |

## Wire-up

```bicep
module keyVault 'modules/key-vault/main.bicep' = if (deployKeyVault) {
  scope: resourceGroup
  name: 'key-vault'
  params: {
    name: keyVaultName
    privateEndpointName: keyVaultPrivateEndpointName
    privateEndpointNetworkInterfaceName: keyVaultPrivateEndpointNicName
    privateEndpointSubnetId: deployNetwork ? network!.outputs.privateEndpointSubnetId : ''
    privateDnsZoneId: deployNetwork ? privateDns!.outputs.keyVaultZoneId : ''
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
    windowsAdminUsername: windowsAdminUsername
    linuxAdminUsername: linuxAdminUsername
    location: location
    tags: tags
  }
}
```
