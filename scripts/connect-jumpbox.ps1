<#
.SYNOPSIS
    Opens an RDP session to the Windows jumpbox through Bastion in a window of
    a chosen size.

.DESCRIPTION
    Does what `az network bastion rdp` does on Windows, with one difference:
    that command opens the RDP file Bastion returns as is, which starts full
    screen, and it has no option to change the display. This script downloads
    the same short-lived RDP file, sets a windowed desktop of the requested
    size and opens it with mstsc.

    The Bastion, resource group and VM names come from the azd environment, so
    run it from the repository after a `full` provision.

.PARAMETER Environment
    The azd environment. Defaults to the selected one.

.PARAMETER Width
    Desktop width in physical pixels, before the local display scaling.

.PARAMETER Height
    Desktop height in physical pixels. Keep it below the screen height so the
    title bar and taskbar still fit.

.PARAMETER Scale
    Display scaling inside the session, in percent, like the Scale setting in
    Windows display settings.

.PARAMETER AuthType
    AAD signs in with Microsoft Entra ID. Password prompts for a local account
    such as .\azurelocaladmin, whose password is the windows-admin-password
    secret in the Key Vault.

.EXAMPLE
    ./scripts/connect-jumpbox.ps1
.EXAMPLE
    ./scripts/connect-jumpbox.ps1 -Environment sandbox -Width 1600 -Height 900 -AuthType Password
#>
[CmdletBinding()]
param(
    [string] $Environment,
    [ValidateRange(640, 7680)]
    [int] $Width = 3072,
    [ValidateRange(480, 4320)]
    [int] $Height = 1600,
    [ValidateSet(100, 125, 150, 175, 200, 250, 300)]
    [int] $Scale = 150,
    [ValidateSet('AAD', 'Password')]
    [string] $AuthType = 'AAD'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'This script launches mstsc and only runs on Windows.'
}

function Get-AzdValue {
    param([Parameter(Mandatory)] [string] $Name)

    $arguments = @('env', 'get-value', $Name)
    if ($Environment) { $arguments += @('-e', $Environment) }
    $value = & azd @arguments 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($value)) {
        throw "azd environment value '$Name' is not set. Provision the full profile first."
    }
    return $value.Trim()
}

$subscriptionId = Get-AzdValue 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-AzdValue 'AZURE_RESOURCE_GROUP'
$bastionName = Get-AzdValue 'AZURE_BASTION_NAME'
$vmName = Get-AzdValue 'AZURE_WINDOWS_VM_NAME'

$bastion = az network bastion show --subscription $subscriptionId -g $resourceGroup -n $bastionName `
    --query '{dnsName:dnsName, tunneling:enableTunneling}' -o json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Unable to read Bastion '$bastionName'." }
if (-not $bastion.tunneling) {
    throw "Bastion '$bastionName' does not have native client support enabled."
}

$token = az account get-access-token --subscription $subscriptionId --query accessToken -o tsv
if ($LASTEXITCODE -ne 0) { throw 'Unable to get an Azure access token. Run az login.' }

$vmId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"
$enableEntra = ($AuthType -eq 'AAD').ToString()
$uri = "https://$($bastion.dnsName)/api/rdpfile?resourceId=$vmId&format=rdp&rdpport=3389&enablerdsaad=$enableEntra"
$response = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -UseBasicParsing

# A later duplicate key is ignored by mstsc, so replace the display settings
# Bastion sends instead of appending to them. Bastion asks for multimon,
# which spans every monitor and forces full screen whatever the screen mode.
# Without a window position mstsc opens at the top left of the screen. Centre
# it on the primary monitor's work area instead. winposstr is in physical
# pixels and covers the frame too, so the process must be DPI aware to read
# real coordinates, and the title bar and borders are added to the desktop.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace Win32 -Name Dpi -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern uint GetDpiForSystem();
'@
[void][Win32.Dpi]::SetProcessDPIAware()
$dpiScale = [Win32.Dpi]::GetDpiForSystem() / 96
$workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$windowWidth = $Width + [int](16 * $dpiScale)
$windowHeight = $Height + [int](39 * $dpiScale)
$left = $workArea.Left + [Math]::Max(0, [int](($workArea.Width - $windowWidth) / 2))
$top = $workArea.Top + [Math]::Max(0, [int](($workArea.Height - $windowHeight) / 2))

$display = [ordered] @{
    'winposstr:s'          = "0,1,$left,$top,$($left + $windowWidth),$($top + $windowHeight)"
    'use multimon:i'       = '0'
    'screen mode id:i'     = '1'
    'desktopwidth:i'       = "$Width"
    'desktopheight:i'      = "$Height"
    # Smart sizing scales the session to the window. mstsc prefers dynamic
    # resolution when both are on, so that one is off.
    'dynamic resolution:i' = '0'
    'smart sizing:i'       = '1'
    'desktopscalefactor:i' = "$Scale"
    'devicescalefactor:i'  = '100'
}
$lines = @($response.Content -split "`r?`n" | Where-Object {
        $line = $_
        $line -and -not @($display.Keys | Where-Object { $line.StartsWith("${_}:") }).Count
    })
$lines += $display.GetEnumerator() | ForEach-Object { "$($_.Key):$($_.Value)" }

# mstsc hands the session to another process and exits at once, so the file
# cannot be deleted when it returns. Its gateway token is short-lived; files
# from earlier runs are removed instead.
$tempPath = [IO.Path]::GetTempPath()
Get-ChildItem -LiteralPath $tempPath -Filter 'jumpbox_*.rdp' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddHours(-1) } |
    Remove-Item -Force -ErrorAction SilentlyContinue

$rdpFile = Join-Path $tempPath "jumpbox_$([guid]::NewGuid().ToString('N')).rdp"
Set-Content -LiteralPath $rdpFile -Value $lines -Encoding utf8
Write-Output "Connecting to '$vmName' through '$bastionName' at ${Width}x${Height}, $Scale% scale ($AuthType)."
Start-Process -FilePath mstsc -ArgumentList "`"$rdpFile`""
