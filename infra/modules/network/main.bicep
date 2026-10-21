targetScope = 'resourceGroup'

@minLength(2)
@maxLength(64)
param name string
@minLength(2)
@maxLength(80)
param bastionNetworkSecurityGroupName string
@minLength(2)
@maxLength(80)
param jumpboxNetworkSecurityGroupName string
@minLength(2)
@maxLength(80)
param privateEndpointNetworkSecurityGroupName string
@minLength(2)
@maxLength(80)
param jumpboxSubnetName string
@minLength(2)
@maxLength(80)
param privateEndpointSubnetName string
param location string = resourceGroup().location
param tags object = {}
param vnetAddressPrefix string
param bastionSubnetPrefix string
param jumpboxSubnetPrefix string
param privateEndpointSubnetPrefix string
param enableNatGateway bool = false
param natGatewayId string = ''
@description('Deploy AzureBastionSubnet and the jumpbox subnet with their NSGs. Disable for workloads without Bastion or jumpboxes.')
param deployJumpboxSubnets bool = true
@description('Delegated Container Apps infrastructure subnet prefix (/27 or larger). Empty skips the subnet and its NSG.')
param containerAppsSubnetPrefix string = ''
@maxLength(80)
param containerAppsSubnetName string = ''
@maxLength(80)
param containerAppsNetworkSecurityGroupName string = ''

var deployContainerAppsSubnet = !empty(containerAppsSubnetPrefix)

var bastionSubnetName = 'AzureBastionSubnet'

resource bastionNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = if (deployJumpboxSubnets) {
  name: bastionNetworkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowGatewayManagerInbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAzureLoadBalancerInbound'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: 'AzureLoadBalancer'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowBastionHostCommunication'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowSshRdpOutbound'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: [
            '22'
            '3389'
          ]
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowAzureCloudOutbound'
        properties: {
          priority: 110
          access: 'Allow'
          direction: 'Outbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'AzureCloud'
        }
      }
      {
        name: 'AllowBastionCommunication'
        properties: {
          priority: 120
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRanges: [
            '8080'
            '5701'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: 'VirtualNetwork'
        }
      }
      {
        name: 'AllowHttpOutbound'
        properties: {
          priority: 130
          access: 'Allow'
          direction: 'Outbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: 'Internet'
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Outbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

var jumpboxOutboundRules = concat(
  [
    {
      name: 'AllowVirtualNetworkOutbound'
      properties: {
        priority: 100
        access: 'Allow'
        direction: 'Outbound'
        protocol: '*'
        sourcePortRange: '*'
        destinationPortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: 'VirtualNetwork'
      }
    }
    {
      name: 'AllowAzurePlatformOutbound'
      properties: {
        priority: 110
        access: 'Allow'
        direction: 'Outbound'
        protocol: 'Tcp'
        sourcePortRange: '*'
        destinationPortRange: '443'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: 'AzureCloud'
      }
    }
    {
      name: 'AllowEntraOutbound'
      properties: {
        priority: 120
        access: 'Allow'
        direction: 'Outbound'
        protocol: 'Tcp'
        sourcePortRange: '*'
        destinationPortRange: '443'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: 'AzureActiveDirectory'
      }
    }
  ],
  enableNatGateway
    ? [
        {
          name: 'AllowInternetOutboundWithNat'
          properties: {
            priority: 130
            access: 'Allow'
            direction: 'Outbound'
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: 'Internet'
          }
        }
      ]
    : [],
  [
    {
      name: 'DenyAllOutbound'
      properties: {
        priority: 4096
        access: 'Deny'
        direction: 'Outbound'
        protocol: '*'
        sourcePortRange: '*'
        destinationPortRange: '*'
        sourceAddressPrefix: '*'
        destinationAddressPrefix: '*'
      }
    }
  ]
)

resource jumpboxNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = if (deployJumpboxSubnets) {
  name: jumpboxNetworkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: concat(
      [
        {
          name: 'AllowRdpFromBastion'
          properties: {
            priority: 100
            access: 'Allow'
            direction: 'Inbound'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '3389'
            sourceAddressPrefix: bastionSubnetPrefix
            destinationAddressPrefix: '*'
          }
        }
        {
          name: 'AllowSshFromBastion'
          properties: {
            priority: 110
            access: 'Allow'
            direction: 'Inbound'
            protocol: 'Tcp'
            sourcePortRange: '*'
            destinationPortRange: '22'
            sourceAddressPrefix: bastionSubnetPrefix
            destinationAddressPrefix: '*'
          }
        }
        {
          name: 'DenyAllInbound'
          properties: {
            priority: 4096
            access: 'Deny'
            direction: 'Inbound'
            protocol: '*'
            sourcePortRange: '*'
            destinationPortRange: '*'
            sourceAddressPrefix: '*'
            destinationAddressPrefix: '*'
          }
        }
      ],
      jumpboxOutboundRules
    )
  }
}

resource privateEndpointNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: privateEndpointNetworkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowPrivateServicesFromVnet'
        properties: {
          priority: 100
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRanges: [
            '443'
            '445'
          ]
          sourceAddressPrefix: 'VirtualNetwork'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          access: 'Deny'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// Container Apps workload-profiles environments manage their own ingress through
// the environment's public IP and need outbound access to Azure services and
// image registries, so this NSG keeps Azure's default rules. Owning the NSG
// (rather than leaving the subnet bare) also keeps policy-generated NSGs, with
// names outside the convention, from being attached.
resource containerAppsNsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = if (deployContainerAppsSubnet) {
  name: containerAppsNetworkSecurityGroupName
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

var jumpboxSubnets = deployJumpboxSubnets
  ? [
      {
        name: bastionSubnetName
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: {
            id: bastionNsg.id
          }
        }
      }
      {
        name: jumpboxSubnetName
        properties: {
          addressPrefix: jumpboxSubnetPrefix
          defaultOutboundAccess: false
          networkSecurityGroup: {
            id: jumpboxNsg.id
          }
          natGateway: enableNatGateway
            ? {
                id: natGatewayId
              }
            : null
        }
      }
    ]
  : []

var containerAppsSubnets = deployContainerAppsSubnet
  ? [
      {
        name: containerAppsSubnetName
        properties: {
          addressPrefix: containerAppsSubnetPrefix
          delegations: [
            {
              name: 'containerapps'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
          networkSecurityGroup: {
            id: containerAppsNsg.id
          }
        }
      }
    ]
  : []

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: concat(
      jumpboxSubnets,
      [
        {
          name: privateEndpointSubnetName
          properties: {
            addressPrefix: privateEndpointSubnetPrefix
            defaultOutboundAccess: false
            privateEndpointNetworkPolicies: 'NetworkSecurityGroupEnabled'
            networkSecurityGroup: {
              id: privateEndpointNsg.id
            }
          }
        }
      ],
      containerAppsSubnets
    )
  }
}

output virtualNetworkId string = virtualNetwork.id
output virtualNetworkName string = virtualNetwork.name
output bastionSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetwork.name,
  bastionSubnetName
)
output jumpboxSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetwork.name,
  jumpboxSubnetName
)
output privateEndpointSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  virtualNetwork.name,
  privateEndpointSubnetName
)
output containerAppsSubnetId string = deployContainerAppsSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetwork.name, containerAppsSubnetName)
  : ''
