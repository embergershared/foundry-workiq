<#
.SYNOPSIS
    Runs the template's rules-checking suite.

.DESCRIPTION
    Discovers every tests/*.tests.ps1 file, runs it, and fails the process if any
    case fails. The suite has no external module dependency so it can run
    unchanged on a developer machine and in CI.

.PARAMETER Name
    Optional wildcard filter applied to the test file base name, for example
    'naming' to run only naming.tests.ps1.

.EXAMPLE
    ./tests/run-tests.ps1
.EXAMPLE
    ./tests/run-tests.ps1 -Name catalog
#>
[CmdletBinding()]
param(
    [string] $Name = '*'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'assert.ps1')

$filter = if ($Name.Contains('*')) { "$Name.tests.ps1" } else { "*$Name*.tests.ps1" }
$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter $filter -File -Recurse | Sort-Object FullName)

if ($testFiles.Count -eq 0) {
    throw "No test files matched '$filter' under $PSScriptRoot."
}

$failed = 0
$passed = 0

foreach ($file in $testFiles) {
    Reset-TestResults
    Write-Output ""
    Write-Output "== $($file.BaseName)"

    try {
        . $file.FullName
    }
    catch {
        Write-Output "   [FAIL] <file did not load> $($_.Exception.Message)"
        $failed++
        continue
    }

    foreach ($result in Get-TestResults) {
        if ($result.Passed) {
            $passed++
            Write-Output "   [ OK ] $($result.Name)"
        }
        else {
            $failed++
            Write-Output "   [FAIL] $($result.Name)"
            Write-Output "          $($result.Message)"
        }
    }
}

Write-Output ""
Write-Output "$passed passed, $failed failed."

if ($failed -gt 0) {
    throw "$failed test case(s) failed."
}

# Expected native-command failures in regression tests must not leak into CI's exit code.
$global:LASTEXITCODE = 0
