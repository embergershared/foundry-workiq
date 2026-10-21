# bastion

Azure Bastion, Standard SKU, with native client tunneling enabled.

| | |
|---|---|
| Kind | `resource` |
| Profiles | `full` |
| Abbreviation | `bast` |
| Providers | `Microsoft.Network` |
| Private endpoint | none |
| Feature flag | `bastion` |

## Purpose

Provides RDP and SSH access to the jumpboxes without assigning them public IP
addresses, and without opening inbound ports on the jumpbox network security
group.

Standard SKU is required for native client tunneling (`az network bastion ssh`
and `az network bastion rdp`). This is the single largest recurring cost in the
`full` profile.

Bastion depends on the `AzureBastionSubnet` produced by the `network` module.
Any override that enables a jumpbox must therefore also enable `bastion`;
`scripts/preflight.ps1` enforces that rule.

## Parameters

| Name | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | |
| `publicIpName` | string | yes | Standard SKU, static allocation |
| `location` | string | no | Defaults to the resource group location |
| `tags` | object | no | |
| `bastionSubnetId` | string | yes | Must be the `AzureBastionSubnet` |
| `logAnalyticsWorkspaceId` | string | yes | Diagnostics target |

## Outputs

| Name | Notes |
|---|---|
| `id` | Contract output |
| `name` | Contract output |
| `bastionName` | Deprecated alias |
