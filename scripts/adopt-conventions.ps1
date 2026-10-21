<#
.SYNOPSIS
    Pushes this template's conventions layer into an existing repository.

.DESCRIPTION
    Copies the always-present conventions - infra/core/**, the shared scripts,
    the naming instructions and the azure.yaml hook block - into a target
    repository and stamps it with .azd-starter.json so a repository that has
    fallen behind can be identified.

    The operation is re-runnable and deliberately conservative:

      * a project's own infra/main.bicep and infra/modules/** are never touched
      * azure.yaml is never overwritten; the hook block is printed when it is
        missing or has drifted
      * -WhatIf reports every change without writing anything

.PARAMETER Path
    Target repository root.

.PARAMETER Force
    Overwrite target files that have local modifications. Without it, a file
    that differs from both the template and the last applied stamp is reported
    and skipped.

.EXAMPLE
    ./scripts/adopt-conventions.ps1 -Path D:\src\foundry-notifications-tests -WhatIf

.EXAMPLE
    ./scripts/adopt-conventions.ps1 -Path D:\src\foundry-notifications-tests
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $Path,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'naming.ps1')

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    throw "Target path '$Path' was not found."
}
$target = (Resolve-Path -LiteralPath $Path).Path

if ($target -eq $repoRoot) {
    throw 'The target repository is this template. Nothing to adopt.'
}

if (-not (Test-Path -LiteralPath (Join-Path $target 'infra/modules/catalog.json'))) {
    throw 'Adoption requires a project-owned infra/modules/catalog.json matching the target composition. Prepare module metadata and build the catalog first; no files were changed. The hooks do not infer resources from arbitrary Bicep.'
}

$template = Get-TemplateVersion
$stampPath = Join-Path $target '.azd-starter.json'

# ---------------------------------------------------------------------------
# What travels. Everything here is conventions, never project content.
# ---------------------------------------------------------------------------

$payload = @(
    'infra/core/naming.bicep'
    'infra/core/tags.bicep'
    'infra/core/private-endpoint.bicep'
    'infra/core/name-rules.json'
    'infra/core/abbreviations.json'
    'infra/core/location-codes.json'
    'infra/core/tenant-codes.json'
    'scripts/naming.ps1'
    'scripts/preflight.ps1'
    'scripts/module-selection.ps1'
    'scripts/set-deployment-tags.ps1'
    'scripts/build-catalog.ps1'
    'scripts/build-docs.ps1'
    'scripts/new-module.ps1'
    'scripts/add-module.ps1'
    'scripts/promote-module.ps1'
    'scripts/adopt-conventions.ps1'
    '.github/instructions/naming.instructions.md'
)

# Never travels: a project owns these outright.
$protected = @(
    'infra/main.bicep'
    'infra/main.parameters.json'
    'infra/modules'
    'azure.yaml'
)

$previous = $null
if (Test-Path -LiteralPath $stampPath) {
    try {
        $previous = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "'.azd-starter.json' in '$target' is not valid JSON and will be rewritten."
    }
}

$previousHashes = @{}
if ($previous -and $previous.PSObject.Properties.Name -contains 'files') {
    foreach ($property in $previous.files.PSObject.Properties) {
        $previousHashes[$property.Name] = [string] $property.Value
    }
}

function Get-TextHash {
    param([Parameter(Mandatory)][string] $LiteralPath)

    $text = [System.IO.File]::ReadAllText($LiteralPath) -replace "`r`n", "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

$applied = [System.Collections.Generic.List[object]]::new()
$skipped = [System.Collections.Generic.List[object]]::new()
$fileHashes = [ordered] @{}

foreach ($relative in $payload) {
    $sourcePath = Join-Path $repoRoot $relative
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Template file '$relative' is missing. This template is inconsistent - fix it before adopting."
    }

    $sourceHash = Get-TextHash -LiteralPath $sourcePath
    $fileHashes[$relative] = $sourceHash

    $destinationPath = Join-Path $target $relative
    $action = 'Add'

    if (Test-Path -LiteralPath $destinationPath -PathType Leaf) {
        $destinationHash = Get-TextHash -LiteralPath $destinationPath
        if ($destinationHash -eq $sourceHash) {
            $skipped.Add([pscustomobject] @{ File = $relative; Reason = 'Unchanged' })
            continue
        }

        # A file that matches the last applied stamp is a clean template file
        # the project has not touched, so it is safe to roll forward.
        $stamped = $previousHashes.ContainsKey($relative) -and $previousHashes[$relative] -eq $destinationHash
        if (-not $stamped -and -not $Force) {
            $skipped.Add([pscustomobject] @{ File = $relative; Reason = 'LocallyModified' })
            Write-Warning "Skipping '$relative': it differs from the template and from the last applied stamp. Re-run with -Force to overwrite."
            continue
        }

        $action = if ($stamped) { 'Update' } else { 'Overwrite' }
    }

    if ($PSCmdlet.ShouldProcess($destinationPath, $action)) {
        $parent = Split-Path -Parent $destinationPath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    $applied.Add([pscustomobject] @{ File = $relative; Action = $action })
}

foreach ($relative in $protected) {
    $destinationPath = Join-Path $target $relative
    if (Test-Path -LiteralPath $destinationPath) {
        $skipped.Add([pscustomobject] @{ File = $relative; Reason = 'ProjectOwned' })
    }
}

# ---------------------------------------------------------------------------
# azure.yaml hook block: reported, never written.
# ---------------------------------------------------------------------------

$hookBlock = @'
hooks:
  preprovision:
    shell: pwsh
    continueOnError: false
    run: |
      $ErrorActionPreference = 'Stop'
      $deploymentProfile = azd env get-value DEPLOYMENT_PROFILE 2>$null
      if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($deploymentProfile)) {
        azd env set DEPLOYMENT_PROFILE core
        if ($LASTEXITCODE -ne 0) { throw "Unable to initialize DEPLOYMENT_PROFILE." }
      }
      ./scripts/set-deployment-tags.ps1
      ./scripts/preflight.ps1
'@

$azureYamlPath = Join-Path $target 'azure.yaml'
$hookState = 'Missing'
if (Test-Path -LiteralPath $azureYamlPath) {
    $azureYaml = Get-Content -LiteralPath $azureYamlPath -Raw
    $hookState = if (($azureYaml -replace "`r`n", "`n").Contains(($hookBlock -replace "`r`n", "`n"))) {
        'Present'
    }
    else {
        'Drifted'
    }
}

if ($hookState -ne 'Present') {
    Write-Warning "azure.yaml in '$target' is $($hookState.ToLowerInvariant()) the preprovision hooks. It is never written automatically - add this block by hand:"
    Write-Output ''
    Write-Output $hookBlock
    Write-Output ''
}

# ---------------------------------------------------------------------------
# Stamp.
# ---------------------------------------------------------------------------

$stamp = [ordered] @{
    '$schema'   = 'https://github.com/embergershared/azd-private-starter-template/blob/main/docs/modules.md'
    template    = $template.Name
    version     = $template.Version
    stamp       = $template.Stamp
    appliedOnUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    files       = $fileHashes
}

if ($PSCmdlet.ShouldProcess($stampPath, 'Write .azd-starter.json')) {
    $json = ($stamp | ConvertTo-Json -Depth 6) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($stampPath, $json.TrimEnd() + "`n", [System.Text.UTF8Encoding]::new($false))
}

$behind = $previous -and $previous.PSObject.Properties.Name -contains 'version' -and $previous.version -ne $template.Version

[pscustomobject] @{
    Target          = $target
    Template        = $template.Stamp
    PreviousVersion = if ($previous -and $previous.PSObject.Properties.Name -contains 'version') { $previous.version } else { $null }
    WasBehind       = [bool] $behind
    Applied         = $applied.ToArray()
    Skipped         = $skipped.ToArray()
    AzureYamlHooks  = $hookState
    StampPath       = $stampPath
}
