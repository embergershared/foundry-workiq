# Dependency-free assertion helpers shared by every tests/*.tests.ps1 file.
#
# The repository targets machines that only have Pester 3.4 available, which
# cannot run Pester 5 syntax, so the suite ships its own minimal runner rather
# than adding an install step to the validation path.

Set-StrictMode -Version Latest

$script:TestResults = [System.Collections.Generic.List[object]]::new()

function Reset-TestResults {
    [CmdletBinding()]
    param()

    $script:TestResults = [System.Collections.Generic.List[object]]::new()
}

function Get-TestResults {
    [CmdletBinding()]
    [OutputType([object[]])]
    param()

    return $script:TestResults.ToArray()
}

function Test-Case {
    <#
    .SYNOPSIS
        Runs one named assertion block and records its outcome.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [scriptblock] $Body
    )

    try {
        & $Body
        $script:TestResults.Add([pscustomobject] @{
                Name    = $Name
                Passed  = $true
                Message = ''
            })
    }
    catch {
        $script:TestResults.Add([pscustomobject] @{
                Name    = $Name
                Passed  = $false
                Message = $_.Exception.Message
            })
    }
}

function Assert-Equal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Actual,
        [Parameter(Mandatory)] [AllowNull()] [AllowEmptyString()] $Expected,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', received '$Actual'."
    }
}

function Assert-True {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )

    if (-not $Condition) { throw $Message }
}

function Assert-Match {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Actual,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Actual -cnotmatch $Pattern) {
        throw "$Message '$Actual' does not match '$Pattern'."
    }
}

function Assert-NotMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Actual,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Actual -cmatch $Pattern) {
        throw "$Message '$Actual' matches '$Pattern' but should not."
    }
}

function Assert-Throws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [Parameter(Mandatory)] [string] $Message
    )

    try {
        & $Action
    }
    catch {
        return
    }

    throw "$Message Expected an exception."
}
