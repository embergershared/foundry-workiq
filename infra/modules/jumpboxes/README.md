# jumpboxes

Optional Windows 11 and Ubuntu developer desktops inside the virtual network.

| | |
|---|---|
| Kind | `composite` |
| Profiles | `full` |
| Abbreviation | `vm-win`, `vm-lin` |
| Providers | `Microsoft.Compute`, `Microsoft.Network`, `Microsoft.DevTestLab` |
| Private endpoint | none |
| Feature flag | `windowsVm`, `linuxVm` |

## Purpose

A desktop inside the perimeter, for the cases where a private endpoint is only
reachable from within the virtual network.

Neither virtual machine receives a public IP address. Access is via Azure
Bastion only.

## Dependency rules

These rules are enforced by `scripts/preflight.ps1` and by the module itself:

- a jumpbox requires `bastion`, otherwise it is unreachable
- `entraLogin` requires a virtual machine and requires `natGateway` for egress
- `shutdownSchedules` requires a virtual machine

## Credentials

Administrator passwords are generated with `newGuid()` in the `key-vault`
module and written to Key Vault. They are never emitted as template outputs and
never written to `.azure` state. `credentialRotationTag` forces regeneration
when it changes.

## Parameters

Selected parameters; see `main.bicep` for the full list.

| Name | Type | Required | Notes |
|---|---|---|---|
| `windowsVmName`, `windowsComputerName`, `windowsNicName` | string | yes | `windowsComputerName` obeys the 15 character NetBIOS limit |
| `linuxVmName`, `linuxNicName` | string | yes | |
| `jumpboxSubnetId` | string | yes | From the `network` module |
| `deployWindowsVm`, `deployLinuxVm` | bool | no | Default `false` |
| `windowsVmSize`, `linuxVmSize` | string | no | `Standard_D4s_v5` / `Standard_D2s_v5` |
| `windowsImage`, `linuxImage` | object | yes | Publisher/offer/sku/version |
| `enableEntraLogin` | bool | no | Requires egress |
| `enableShutdownSchedules` | bool | no | Default `true` |
| `shutdownTime`, `shutdownTimeZone` | string | no | `1900`, Eastern Standard Time |
| `operatorPrincipalIds` | array | no | Granted Virtual Machine User Login |

## Outputs

| Name | Notes |
|---|---|
| `windowsVmName` | Empty string when not deployed |
| `linuxVmName` | Empty string when not deployed |
