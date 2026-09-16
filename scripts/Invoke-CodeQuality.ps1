#Requires -Version 7.0
# Copyright (c) 2026 POMINI Long Rolling Mills. Licensed under the MIT License.

[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$FixFormat,
    [switch]$SkipTests
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$settingsPath = Join-Path $ProjectRoot 'PSScriptAnalyzerSettings.psd1'
if (-not (Test-Path -LiteralPath $settingsPath)) {
    throw "PSScriptAnalyzer settings not found: $settingsPath"
}

$formatScript = Join-Path $ProjectRoot 'scripts' 'Format-Code.ps1'
if (-not (Test-Path -LiteralPath $formatScript)) {
    throw "Formatter script not found: $formatScript"
}

$formatParameters = @{ ProjectRoot = $ProjectRoot }
if (-not $FixFormat.IsPresent) {
    $formatParameters.Check = $true
}

& $formatScript @formatParameters
if (-not $?) {
    exit 1
}

$targets = @(
    'dev-bootstrap.ps1'
    'DevBootstrap.psm1'
    'DevBootstrap.psd1'
    'scripts'
    'src'
    'tests'
)

$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in $targets) {
    $resolvedTarget = Join-Path $ProjectRoot $target
    if (-not (Test-Path -LiteralPath $resolvedTarget)) {
        continue
    }

    $results.AddRange(@(Invoke-ScriptAnalyzer -Path $resolvedTarget -Recurse -Settings $settingsPath))
}

if ($results.Count -gt 0) {
    $results |
        Sort-Object Severity, ScriptName, Line |
        Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap
}
else {
    Write-Host 'PSScriptAnalyzer: no issues found.' -ForegroundColor Green
}

$errors = @($results | Where-Object Severity -eq 'Error')
$warnings = @($results | Where-Object Severity -eq 'Warning')

Write-Host "PSScriptAnalyzer summary: errors=$($errors.Count), warnings=$($warnings.Count)" -ForegroundColor Cyan

if ($errors.Count -gt 0) {
    exit 1
}

if ($SkipTests.IsPresent) {
    exit 0
}

$pesterModule = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -eq 6 } |
    Sort-Object -Property Version -Descending |
    Select-Object -First 1

if ($null -eq $pesterModule) {
    throw 'Pester 6 is required to run the test suite. Install a Pester 6.x version and retry.'
}

Import-Module -Name $pesterModule.Path -Force -ErrorAction Stop

$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $ProjectRoot 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
$configuration.TestResult.Enabled = $true
$configuration.TestResult.OutputPath = Join-Path $ProjectRoot 'testResults.xml'
$configuration.TestResult.OutputFormat = 'NUnitXml'

$pesterResult = Invoke-Pester -Configuration $configuration
if ($pesterResult.FailedCount -gt 0) {
    exit 1
}

Write-Host (
    "Pester summary: passed=$($pesterResult.PassedCount), failed=$($pesterResult.FailedCount), skipped=$($pesterResult.SkippedCount)"
) -ForegroundColor Green

