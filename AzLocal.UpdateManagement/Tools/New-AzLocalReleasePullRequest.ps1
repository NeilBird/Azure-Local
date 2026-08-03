#Requires -Version 5.1
<#
.SYNOPSIS
    Certifies and creates an AzLocal.UpdateManagement release pull request.
.DESCRIPTION
    This is the supported release-PR entry point. It always runs the complete
    hermetic and live-Azure pre-PR gate against the clean committed candidate
    before invoking GitHub CLI to create the pull request.
.PARAMETER Title
    Pull request title.
.PARAMETER BodyFile
    Markdown file containing the pull request body.
.PARAMETER Base
    Target branch. Defaults to main.
.PARAMETER ThrottleLimit
    Maximum concurrent live-Azure test jobs. Defaults to 3.
.OUTPUTS
    GitHub CLI pull request URL.
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$BodyFile,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Base = 'main',

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 8)]
    [int]$ThrottleLimit = 3
)

$ErrorActionPreference = 'Stop'
$moduleRoot = Split-Path -Path $PSScriptRoot -Parent
$repoRoot = (Resolve-Path (Join-Path $moduleRoot '..')).Path
$gatePath = Join-Path $moduleRoot 'Tests\Invoke-ReleasePrePullRequestGate.ps1'
if (-not (Test-Path -LiteralPath $gatePath -PathType Leaf)) {
    throw "Pre-PR release gate not found: $gatePath"
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required to create the release pull request.'
}

$receipt = & $gatePath -ThrottleLimit $ThrottleLimit
if ($null -eq $receipt -or $receipt.LiveFailed -ne 0 -or $receipt.LiveSkipped -ne 0) {
    throw 'Pre-PR release certification did not return a clean live-test receipt.'
}

Push-Location $repoRoot
try {
    $head = (& git branch --show-current).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $head) { throw 'Unable to resolve the release branch.' }

    $existing = & gh pr list --head $head --state open --json number,url --jq '.[0].url'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to check for an existing release pull request.' }
    if ($existing) { throw "An open pull request already exists for '$head': $existing" }

    $url = & gh pr create --base $Base --head $head --title $Title --body-file $BodyFile
    if ($LASTEXITCODE -ne 0 -or -not $url) { throw 'GitHub CLI did not create the release pull request.' }
    return [string]$url
}
finally {
    Pop-Location
}