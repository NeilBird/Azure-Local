#Requires -Version 5.1
<#
.SYNOPSIS
    Detached copy worker for AzLocal.UpdateManagement on-prem sideloading (v0.8.7).

.DESCRIPTION
    This script is the ACTION of the Windows Scheduled Task registered by
    Register-AzLocalSideloadCopyTask. It is intentionally SELF-CONTAINED (it does
    NOT import the AzLocal.UpdateManagement module) because it runs in a separate
    process, as the runner/agent service account, and must survive the CI/CD job
    ending and even a host reboot.

    It robocopies the verified solution media (a CombinedSolutionBundle .zip for a
    Microsoft Solution update, or a staged OEM SBE source folder) from the shared
    cache to the target cluster's infrastructure 'import' share, writing a
    structured heartbeat JSON to the SHARED state directory every few seconds so
    that ANY pipeline run on ANY runner/agent can monitor progress without
    cross-agent remoting.

    Robocopy exit codes 0-7 are treated as success; >= 8 is failure.

.PARAMETER ClusterName
    The Azure Local cluster name (used to name the shared-state JSON file).

.PARAMETER Version
    The solution-update version being copied (recorded in state).

.PARAMETER SourcePath
    The verified media path: a .zip file (Solution) or a folder (SBE).

.PARAMETER TargetPath
    The destination UNC folder on the cluster's import share.

.PARAMETER StateRoot
    The SHARED UNC state root. state\<cluster>.json and logs\ live beneath it.

.PARAMETER RobocopySwitches
    Extra robocopy switches (e.g. '/R:5 /W:30 /IPG:50'); space-separated.

.PARAMETER HeartbeatSeconds
    Interval between heartbeat JSON updates. Default 30.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ClusterName,
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$TargetPath,
    [Parameter(Mandatory = $true)][string]$StateRoot,
    [string]$RobocopySwitches = '/R:5 /W:30',
    [int]$HeartbeatSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StateFilePath {
    param([string]$Root, [string]$Cluster)
    $stateDir = Join-Path -Path $Root -ChildPath 'state'
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    $safe = ($Cluster -replace '[^A-Za-z0-9._-]', '_')
    return (Join-Path -Path $stateDir -ChildPath ("{0}.json" -f $safe))
}

function Write-StateAtomic {
    param([string]$Path, [PSCustomObject]$State)
    $json = $State | ConvertTo-Json -Depth 6
    $temp = "{0}.{1}.partial" -f $Path, ([guid]::NewGuid().ToString('N'))
    try {
        [System.IO.File]::WriteAllText($temp, $json, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Get-FolderSize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [long]0 }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return [long]((Get-Item -LiteralPath $Path).Length)
    }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) { return [long]0 }
    return [long]$sum
}

$statePath = Get-StateFilePath -Root $StateRoot -Cluster $ClusterName
$logDir = Join-Path -Path $StateRoot -ChildPath 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$safeName = ($ClusterName -replace '[^A-Za-z0-9._-]', '_')
$logPath = Join-Path -Path $logDir -ChildPath ("{0}.{1}.robocopy.log" -f $safeName, ([DateTime]::UtcNow.ToString('yyyyMMddHHmmss')))

# Carry forward existing fields (retries, taskname) when present.
$existing = $null
if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    try { $existing = (Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json) } catch { $existing = $null }
}

$startUtc = [DateTime]::UtcNow
$totalBytes = Get-FolderSize -Path $SourcePath

$state = [PSCustomObject]@{
    ClusterName      = $ClusterName
    Version          = $Version
    State            = 'Copying'
    OwningMachine    = $env:COMPUTERNAME
    TaskName         = if ($existing) { [string]$existing.TaskName } else { '' }
    MediaPath        = $SourcePath
    TargetPath       = $TargetPath
    LogPath          = $logPath
    StartUtc         = $startUtc.ToString('o')
    LastHeartbeatUtc = $startUtc.ToString('o')
    TotalBytes       = $totalBytes
    CopiedBytes      = [long]0
    Mbps             = [double]0
    EtaUtc           = ''
    ExitCode         = $null
    Retries          = if ($existing) { [int]$existing.Retries } else { [int]0 }
    Message          = 'Copy started.'
}
Write-StateAtomic -Path $statePath -State $state

# Ensure destination exists.
if (-not (Test-Path -LiteralPath $TargetPath)) { New-Item -ItemType Directory -Path $TargetPath -Force | Out-Null }

# Build the robocopy argument list. For a single-file source, robocopy copies
# from the parent directory with the file name as a selector; for a folder it
# mirrors the tree.
if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
    $srcDir = Split-Path -Path $SourcePath -Parent
    $srcFile = Split-Path -Path $SourcePath -Leaf
    $roboArgs = @($srcDir, $TargetPath, $srcFile)
}
else {
    $roboArgs = @($SourcePath, $TargetPath, '/E')
}
$roboArgs += ($RobocopySwitches -split '\s+' | Where-Object { $_ })
$roboArgs += @('/NP', '/NJH', '/NJS', ("/LOG:{0}" -f $logPath))

$proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $roboArgs -PassThru
while (-not $proc.HasExited) {
    Start-Sleep -Seconds $HeartbeatSeconds
    $copied = Get-FolderSize -Path $TargetPath
    $elapsed = ([DateTime]::UtcNow - $startUtc).TotalSeconds
    $mbps = if ($elapsed -gt 0) { [math]::Round((($copied * 8) / 1MB) / $elapsed, 2) } else { 0 }
    $eta = ''
    if ($copied -gt 0 -and $totalBytes -gt $copied -and $elapsed -gt 0) {
        $bytesPerSec = $copied / $elapsed
        if ($bytesPerSec -gt 0) {
            $remainingSec = ($totalBytes - $copied) / $bytesPerSec
            $eta = [DateTime]::UtcNow.AddSeconds($remainingSec).ToString('o')
        }
    }
    $state.CopiedBytes = [long]$copied
    $state.Mbps = [double]$mbps
    $state.EtaUtc = $eta
    $state.LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o')
    $state.Message = 'Copy in progress.'
    Write-StateAtomic -Path $statePath -State $state
}

$exit = $proc.ExitCode
$state.ExitCode = $exit
$state.CopiedBytes = Get-FolderSize -Path $TargetPath
$state.LastHeartbeatUtc = [DateTime]::UtcNow.ToString('o')
if ($exit -lt 8) {
    $state.State = 'Copied'
    $state.Message = ("Copy completed (robocopy exit {0})." -f $exit)
}
else {
    $state.State = 'Failed'
    $state.Message = ("Copy FAILED (robocopy exit {0}); see log {1}." -f $exit, $logPath)
}
Write-StateAtomic -Path $statePath -State $state

# Surface a non-zero process exit only on real failure (>= 8).
if ($exit -ge 8) { exit 1 } else { exit 0 }
