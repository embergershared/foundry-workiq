# FROZEN REFERENCE IMPLEMENTATION -- DO NOT EDIT.
#
# Verbatim transcription of the resource-name algorithm that shipped in
# infra/main.bicep at commit b20a251 ("Tested and full deploy"), covering the
# `var abbreviations` ... `var linuxNicName` block.
#
# This file exists solely so the refactored naming layer can be proven to
# produce byte-identical resource names. Changing it would defeat that proof.
# If a naming rule must genuinely change, add a NEW fixture and record the
# resource-replacement consequences in the deployment plan instead.
#
# Bicep-to-PowerShell translation notes:
#   take(s, n)     -> s.Substring(0, [Math]::Min(s.Length, n))   (n is clamped)
#   toLower(s)     -> s.ToLowerInvariant()
#   replace(s,a,b) -> s.Replace(a, b)
#   max(a, b)      -> [Math]::Max(a, b)
#   length(s)      -> s.Length
#
# `shortUniqueSuffix` in Bicep is
#   take(uniqueString(subscription().id, environmentName, location), 3)
# which cannot be evaluated offline, so callers pass a pinned hash instead.
# The algorithm only ever consumes it as an opaque 3-character string.

function Get-LegacyNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [hashtable] $Abbreviations,

        [Parameter(Mandatory)]
        [string] $LocationCode,

        [Parameter(Mandatory)]
        [string] $SubscriptionCode,

        [Parameter(Mandatory)]
        [string] $EnvironmentName,

        [Parameter(Mandatory)]
        [string] $ShortUniqueSuffix
    )

    $hash = $ShortUniqueSuffix

    # var normalizedEnvironmentName = toLower(replace(environmentName, '-', ''))
    $normalizedEnvironmentName = $EnvironmentName.Replace('-', '').ToLowerInvariant()

    # var baseName = '${locationCode}-${subscriptionCode}-${environmentName}'
    $baseName = "$LocationCode-$SubscriptionCode-$EnvironmentName"

    # var keyVaultEnvironmentLength = max(1, 24 - length('${abbreviations.keyVault}-${locationCode}-${subscriptionCode}--${shortUniqueSuffix}'))
    $keyVaultEnvironmentLength = [Math]::Max(
        1,
        24 - "$($Abbreviations.keyVault)-$LocationCode-$SubscriptionCode--$hash".Length
    )

    # var storageEnvironmentLength = max(1, 24 - length('${abbreviations.storageAccount}${locationCode}${subscriptionCode}${shortUniqueSuffix}'))
    $storageEnvironmentLength = [Math]::Max(
        1,
        24 - "$($Abbreviations.storageAccount)$LocationCode$SubscriptionCode$hash".Length
    )

    $keyVaultEnvironmentSegment = $normalizedEnvironmentName.Substring(
        0,
        [Math]::Min($normalizedEnvironmentName.Length, $keyVaultEnvironmentLength)
    )
    $storageEnvironmentSegment = $normalizedEnvironmentName.Substring(
        0,
        [Math]::Min($normalizedEnvironmentName.Length, $storageEnvironmentLength)
    )
    $windowsComputerSegment = $normalizedEnvironmentName.Substring(
        0,
        [Math]::Min($normalizedEnvironmentName.Length, 9)
    )

    return [ordered] @{
        resourceGroup              = "$($Abbreviations.resourceGroup)-$baseName"
        virtualNetwork             = "$($Abbreviations.virtualNetwork)-$baseName"
        bastionNsg                 = "$($Abbreviations.networkSecurityGroup)-$baseName-bastion"
        jumpboxNsg                 = "$($Abbreviations.networkSecurityGroup)-$baseName-jumpboxes"
        privateEndpointNsg         = "$($Abbreviations.networkSecurityGroup)-$baseName-private-endpoints"
        jumpboxSubnet              = "$($Abbreviations.subnet)-$baseName-jumpboxes"
        privateEndpointSubnet      = "$($Abbreviations.subnet)-$baseName-private-endpoints"
        keyVault                   = "$($Abbreviations.keyVault)-$LocationCode-$SubscriptionCode-$keyVaultEnvironmentSegment-$hash"
        keyVaultPrivateEndpoint    = "$($Abbreviations.privateEndpoint)-$baseName-kv"
        keyVaultPrivateEndpointNic = "$($Abbreviations.privateEndpointNetworkInterface)-$baseName-kv"
        storageAccount             = "$($Abbreviations.storageAccount)$LocationCode$SubscriptionCode$storageEnvironmentSegment$hash"
        blobPrivateEndpoint        = "$($Abbreviations.privateEndpoint)-$baseName-blob"
        blobPrivateEndpointNic     = "$($Abbreviations.privateEndpointNetworkInterface)-$baseName-blob"
        filePrivateEndpoint        = "$($Abbreviations.privateEndpoint)-$baseName-file"
        filePrivateEndpointNic     = "$($Abbreviations.privateEndpointNetworkInterface)-$baseName-file"
        logAnalytics               = "$($Abbreviations.logAnalytics)-$baseName"
        applicationInsights        = "$($Abbreviations.applicationInsights)-$baseName"
        natGateway                 = "$($Abbreviations.natGateway)-$baseName"
        natPublicIp                = "$($Abbreviations.publicIp)-$baseName-nat"
        bastion                    = "$($Abbreviations.bastion)-$baseName"
        bastionPublicIp            = "$($Abbreviations.publicIp)-$baseName-bastion"
        windowsVm                  = "$($Abbreviations.windowsVirtualMachine)-$baseName"
        windowsComputerName        = "w-$windowsComputerSegment-$hash"
        windowsNic                 = "$($Abbreviations.networkInterface)-$baseName-win"
        linuxVm                    = "$($Abbreviations.linuxVirtualMachine)-$baseName"
        linuxNic                   = "$($Abbreviations.networkInterface)-$baseName-lin"
    }
}

# The fixed input matrix the golden file is generated from. Both the generator
# and the equivalence test iterate this, so they cannot drift apart.
function Get-LegacyNameMatrix {
    [CmdletBinding()]
    param()

    return @(
        foreach ($environmentName in @('poc', 'my-azd-env-test', 'aca-private-acr', ('a' * 32))) {
            foreach ($subscriptionCode in @('s1', 's1234')) {
                foreach ($locationCode in @('use2', 'usw3', 'cac')) {
                    [pscustomobject] @{
                        EnvironmentName   = $environmentName
                        SubscriptionCode  = $subscriptionCode
                        LocationCode      = $locationCode
                        ShortUniqueSuffix = 'abc'
                    }
                }
            }
        }
    )
}
