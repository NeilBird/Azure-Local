<#
.SYNOPSIS
    Compresses bounded snapshots of the selected clusters' current copy logs.
.DESCRIPTION
    Reads shared state and logs without modifying them. The ZIP manifest records
    snapshot offsets, truncation, and unavailable files. No credentials or runner
    service logs are collected. Output is reporting, including during dry runs.
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$StateRoot,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$ClusterName,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$DestinationPath,
    [ValidateRange(1, 10485760)][int]$MaxLogBytes = 5242880,
    [ValidateRange(1, 104857600)][int]$MaxTotalLogBytes = 52428800,
    [ValidateRange(1, 1000)][int]$MaxClusters = 100
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression
$destination = [IO.Path]::GetFullPath($DestinationPath)
$null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
$temporaryPath = $destination + '.' + [guid]::NewGuid().ToString('N') + '.partial'
$logsRoot = [IO.Path]::GetFullPath((Join-Path $StateRoot 'logs')).TrimEnd('\', '/')
$records = [Collections.Generic.List[object]]::new()
$selectedClusters = @($ClusterName | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
$archiveStream = $null
$archive = $null
$totalBytes = 0L
try {
    $archiveStream = [IO.File]::Open($temporaryPath, [IO.FileMode]::CreateNew)
    $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($cluster in @($selectedClusters | Select-Object -First $MaxClusters)) {
        $record = [ordered]@{
            ClusterName = $cluster; SnapshotUtc = [DateTime]::UtcNow.ToString('o')
            Status = 'Unavailable'; State = $null; OperationId = $null; OwningMachine = $null
            ExitCode = $null; LastHeartbeatUtc = $null; Entry = $null
            SourceLength = 0L; Offset = 0L; CapturedBytes = 0L; Truncated = $false; ErrorType = $null
        }
        $sourceStream = $null
        $entryStream = $null
        try {
            $safeName = $cluster -replace '[^A-Za-z0-9._-]', '_'
            $statePath = Join-Path (Join-Path $StateRoot 'state') ($safeName + '.json')
            $stateFile = Get-Item -LiteralPath $statePath -ErrorAction Stop
            if ($stateFile.Length -gt 1MB -or ($stateFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Invalid state file.'
            }
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
            foreach ($property in @('State', 'OperationId', 'OwningMachine', 'ExitCode', 'LastHeartbeatUtc')) {
                if ($state.PSObject.Properties[$property]) { $record[$property] = $state.$property }
            }
            if (-not $state.PSObject.Properties['LogPath'] -or -not $state.LogPath) {
                $record.Status = 'NoLog'
                continue
            }
            $logPath = [IO.Path]::GetFullPath([string]$state.LogPath)
            if (-not [IO.Path]::GetDirectoryName($logPath).Equals($logsRoot, [StringComparison]::OrdinalIgnoreCase) -or
                -not $logPath.EndsWith('.robocopy.log', [StringComparison]::OrdinalIgnoreCase)) {
                $record.Status = 'RejectedPath'
                continue
            }
            $logFile = Get-Item -LiteralPath $logPath -ErrorAction Stop
            $logDirectory = Get-Item -LiteralPath $logsRoot -ErrorAction Stop
            if (($logFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
                ($logDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                $record.Status = 'RejectedPath'
                continue
            }
            if ($totalBytes -ge $MaxTotalLogBytes) {
                $record.Status = 'BudgetExceeded'
                continue
            }
            $sourceStream = [IO.File]::Open($logPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            $record.SourceLength = $sourceStream.Length
            $remaining = [Math]::Min($record.SourceLength, [Math]::Min($MaxLogBytes, $MaxTotalLogBytes - $totalBytes))
            $record.Offset = $record.SourceLength - $remaining
            $null = $sourceStream.Seek($record.Offset, [IO.SeekOrigin]::Begin)
            $record.Entry = 'logs/{0:D4}.robocopy.log' -f $records.Count
            $entryStream = $archive.CreateEntry($record.Entry, [IO.Compression.CompressionLevel]::Optimal).Open()
            $buffer = New-Object byte[] 65536
            while ($remaining -gt 0) {
                $readCount = $sourceStream.Read($buffer, 0, [int][Math]::Min($buffer.Length, $remaining))
                if ($readCount -eq 0) { break }
                $entryStream.Write($buffer, 0, $readCount)
                $remaining -= $readCount
                $record.CapturedBytes += $readCount
                $totalBytes += $readCount
            }
            $record.Truncated = $record.CapturedBytes -lt $record.SourceLength
            $record.Status = 'Captured'
        }
        catch { $record.ErrorType = $_.Exception.GetType().Name }
        finally {
            if ($entryStream) { $entryStream.Dispose() }
            if ($sourceStream) { $sourceStream.Dispose() }
            $records.Add([pscustomobject]$record)
        }
    }
    $manifest = [ordered]@{
        SnapshotUtc = [DateTime]::UtcNow.ToString('o'); MaxLogBytes = $MaxLogBytes
        MaxTotalLogBytes = $MaxTotalLogBytes; CapturedLogBytes = $totalBytes
        OmittedClusterCount = [Math]::Max(0, $selectedClusters.Count - $MaxClusters)
        Records = $records.ToArray()
    }
    $manifestStream = $archive.CreateEntry('manifest.json').Open()
    try {
        $content = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 6))
        $manifestStream.Write($content, 0, $content.Length)
    }
    finally { $manifestStream.Dispose() }
    $archive.Dispose()
    $archive = $null
    $archiveStream.Dispose()
    $archiveStream = $null
    Move-Item -LiteralPath $temporaryPath -Destination $destination -Force -WhatIf:$false
    return $destination
}
finally {
    if ($archive) { $archive.Dispose() }
    if ($archiveStream) { $archiveStream.Dispose() }
    if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
}