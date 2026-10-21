targetScope = 'resourceGroup'

@minLength(1)
@maxLength(64)
param windowsVmName string
@minLength(1)
@maxLength(15)
param windowsComputerName string
@minLength(1)
@maxLength(80)
param windowsNicName string
@minLength(1)
@maxLength(64)
param linuxVmName string
@minLength(1)
@maxLength(80)
param linuxNicName string
param location string = resourceGroup().location
param tags object = {}
param jumpboxSubnetId string
param deployWindowsVm bool = false
param deployLinuxVm bool = false
param windowsVmSize string = 'Standard_D4s_v5'
param linuxVmSize string = 'Standard_D2s_v5'
@allowed([
  {
    publisher: 'MicrosoftWindowsDesktop'
    offer: 'windows-11'
    sku: 'win11-24h2-pro'
    version: 'latest'
  }
])
param windowsImage object
@allowed([
  {
    publisher: 'Canonical'
    offer: 'ubuntu-24_04-lts'
    sku: 'server'
    version: 'latest'
  }
])
param linuxImage object
param windowsAdminUsername string
@secure()
param windowsAdminPassword string
param linuxAdminUsername string
@secure()
param linuxAdminPassword string
param enableEntraLogin bool = true
@maxLength(36)
param windowsMdmId string = ''
param credentialRotationTag string
param enableShutdownSchedules bool = true
param shutdownTime string = '1900'
param shutdownTimeZone string = 'Eastern Standard Time'
param enableRoleAssignments bool = true
param operatorPrincipalIds array = []

var virtualMachineUserLoginRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'fb879df8-f326-4884-b1cf-06f3ad86be52'
)
resource windowsNic 'Microsoft.Network/networkInterfaces@2024-07-01' = if (deployWindowsVm) {
  name: windowsNicName
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: jumpboxSubnetId
          }
        }
      }
    ]
  }
}

resource linuxNic 'Microsoft.Network/networkInterfaces@2024-07-01' = if (deployLinuxVm) {
  name: linuxNicName
  location: location
  tags: tags
  properties: {
    enableAcceleratedNetworking: false
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: jumpboxSubnetId
          }
        }
      }
    ]
  }
}

resource windowsVm 'Microsoft.Compute/virtualMachines@2024-11-01' = if (deployWindowsVm) {
  name: windowsVmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: windowsVmSize
    }
    licenseType: 'Windows_Client'
    networkProfile: {
      networkInterfaces: [
        {
          id: windowsNic.id
          properties: {
            deleteOption: 'Delete'
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: windowsComputerName
      adminUsername: windowsAdminUsername
      adminPassword: windowsAdminPassword
      allowExtensionOperations: true
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          assessmentMode: 'ImageDefault'
          patchMode: 'AutomaticByOS'
        }
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: windowsImage
      osDisk: {
        name: '${windowsVmName}-osdisk'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        caching: 'ReadWrite'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource linuxVm 'Microsoft.Compute/virtualMachines@2024-11-01' = if (deployLinuxVm) {
  name: linuxVmName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: linuxVmSize
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: linuxNic.id
          properties: {
            deleteOption: 'Delete'
            primary: true
          }
        }
      ]
    }
    osProfile: {
      computerName: linuxVmName
      adminUsername: linuxAdminUsername
      adminPassword: linuxAdminPassword
      allowExtensionOperations: true
      linuxConfiguration: {
        provisionVMAgent: true
        disablePasswordAuthentication: false
        patchSettings: {
          assessmentMode: 'AutomaticByPlatform'
          patchMode: 'AutomaticByPlatform'
        }
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    storageProfile: {
      imageReference: linuxImage
      osDisk: {
        name: '${linuxVmName}-osdisk'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        caching: 'ReadWrite'
        diskSizeGB: 64
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource windowsEntraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (deployWindowsVm && enableEntraLogin) {
  parent: windowsVm
  name: 'AADLoginForWindows'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADLoginForWindows'
    typeHandlerVersion: '2.1'
    autoUpgradeMinorVersion: true
    settings: {
      mdmId: windowsMdmId
    }
  }
}

resource linuxEntraLogin 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (deployLinuxVm && enableEntraLogin) {
  parent: linuxVm
  name: 'AADSSHLoginForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.ActiveDirectory'
    type: 'AADSSHLoginForLinux'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings: {}
  }
}

resource windowsCredentialReset 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (deployWindowsVm) {
  parent: windowsVm
  name: 'VMAccessAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'VMAccessAgent'
    typeHandlerVersion: '2.4'
    autoUpgradeMinorVersion: true
    forceUpdateTag: credentialRotationTag
    settings: {}
    protectedSettings: {
      username: windowsAdminUsername
      password: windowsAdminPassword
    }
  }
}

resource linuxCredentialReset 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (deployLinuxVm) {
  parent: linuxVm
  name: 'VMAccessForLinux'
  location: location
  properties: {
    publisher: 'Microsoft.OSTCExtensions'
    type: 'VMAccessForLinux'
    typeHandlerVersion: '1.5'
    autoUpgradeMinorVersion: true
    forceUpdateTag: credentialRotationTag
    settings: {}
    protectedSettings: {
      username: linuxAdminUsername
      password: linuxAdminPassword
    }
  }
}

resource windowsLoginAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in operatorPrincipalIds: if (deployWindowsVm && enableEntraLogin && enableRoleAssignments) {
    name: guid(windowsVm.id, principalId, virtualMachineUserLoginRoleId)
    scope: windowsVm
    properties: {
      principalId: principalId
      roleDefinitionId: virtualMachineUserLoginRoleId
    }
  }
]

resource linuxLoginAssignments 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in operatorPrincipalIds: if (deployLinuxVm && enableEntraLogin && enableRoleAssignments) {
    name: guid(linuxVm.id, principalId, virtualMachineUserLoginRoleId)
    scope: linuxVm
    properties: {
      principalId: principalId
      roleDefinitionId: virtualMachineUserLoginRoleId
    }
  }
]

resource windowsShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployWindowsVm && enableShutdownSchedules) {
  name: 'shutdown-computevm-${windowsVm.name}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTime
    }
    timeZoneId: shutdownTimeZone
    notificationSettings: {
      status: 'Disabled'
    }
    targetResourceId: windowsVm.id
  }
}

resource linuxShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = if (deployLinuxVm && enableShutdownSchedules) {
  name: 'shutdown-computevm-${linuxVm.name}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTime
    }
    timeZoneId: shutdownTimeZone
    notificationSettings: {
      status: 'Disabled'
    }
    targetResourceId: linuxVm.id
  }
}

output windowsVmName string = deployWindowsVm ? windowsVm!.name : ''
output linuxVmName string = deployLinuxVm ? linuxVm!.name : ''
