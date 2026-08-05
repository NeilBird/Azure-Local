#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

[CmdletBinding()]
param(
    [string]$OutputPath,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Verbosity = 'Normal'
)

if (-not $OutputPath) {
    $OutputPath = Join-Path $PSScriptRoot 'results'
}

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

Import-Module Pester -MinimumVersion 5.0.0 -Force

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = $Verbosity
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = Join-Path $OutputPath 'pester-results.xml'

$result = Invoke-Pester -Configuration $config
$resultXmlPath = [string]$config.TestResult.OutputPath.Value
$nunitFailureCount = 0
if (Test-Path -LiteralPath $resultXmlPath) {
    [xml]$resultXml = Get-Content -LiteralPath $resultXmlPath -Raw
    $nunitFailureCount = [int]$resultXml.DocumentElement.failures + [int]$resultXml.DocumentElement.errors
}
if ([int]$result.FailedCount -gt 0 -or $nunitFailureCount -gt 0) { exit 1 }
exit 0
