function New-AzLocalSideloadState {
    <#
    .SYNOPSIS
        Builds a fresh sideload state object for a cluster.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation. Produces the
        canonical state record persisted (one JSON per cluster) under the SHARED
        UNC state root so that ANY runner/agent can read it without cross-agent
        remoting. The detached copy Scheduled Task and each re-entrant pipeline run
        read/update this record to advance the per-cluster state machine.

    .OUTPUTS
        [PSCustomObject] the state record.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][string]$ClusterName,
        [Parameter(Mandatory = $true)][string]$Version,
        [string]$TaskName = '',
        [string]$MediaPath = '',
        [string]$TargetPath = '',
        [string]$LogPath = '',
        [string]$OperationId = ([guid]::NewGuid().ToString('N')),
        [ValidateSet('Queued', 'Copying', 'Copied', 'Verified', 'Discovering', 'NeedsSbe', 'ImportFailed', 'Imported', 'Failed', 'Stale')]
        [string]$State = 'Queued'
    )

    $nowUtc = [DateTime]::UtcNow.ToString('o')
    return [PSCustomObject]@{
        ClusterName       = $ClusterName
        Version           = $Version
        OperationId       = $OperationId
        State             = $State
        OwningMachine     = $env:COMPUTERNAME
        TaskName          = $TaskName
        MediaPath         = $MediaPath
        TargetPath        = $TargetPath
        LogPath           = $LogPath
        StartUtc          = $nowUtc
        LastHeartbeatUtc  = $nowUtc
        TotalBytes        = [long]0
        CopiedBytes       = [long]0
        Mbps              = [double]0
        EtaUtc            = ''
        ExitCode          = $null
        WorkerProcessId   = $null
        RobocopyProcessId = $null
        LastProgressUtc   = $nowUtc
        Retries           = [int]0
        ImportRetries     = [int]0
        Message           = ''
    }
}

function Get-AzLocalSideloadStatePath {
    <#
    .SYNOPSIS
        Returns the shared-state JSON path for a cluster, creating the state
        directory if needed.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ClusterName
    )

    $stateDir = Join-Path -Path $StateRoot -ChildPath 'state'
    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }
    # Sanitize cluster name for use as a file name.
    $safe = ($ClusterName -replace '[^A-Za-z0-9._-]', '_')
    return (Join-Path -Path $stateDir -ChildPath ("{0}.json" -f $safe))
}

function Get-AzLocalSideloadState {
    <#
    .SYNOPSIS
        Reads the shared sideload state record for a cluster; returns $null when
        no state exists yet.
    .OUTPUTS
        [PSCustomObject] or $null
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$ClusterName
    )

    $path = Get-AzLocalSideloadStatePath -StateRoot $StateRoot -ClusterName $ClusterName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        throw "Failed to read sideload state for cluster '$ClusterName' from '$path': $($_.Exception.Message)"
    }
}

function Set-AzLocalSideloadState {
    <#
    .SYNOPSIS
        Persists a sideload state record to the shared UNC state directory using an
        atomic temp-write + move so concurrent readers never see a partial file.
    .OUTPUTS
        [void]
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][ValidateNotNull()][PSCustomObject]$State
    )

    if ([string]::IsNullOrWhiteSpace([string]$State.ClusterName)) {
        throw "Set-AzLocalSideloadState: State object has no ClusterName."
    }

    $path = Get-AzLocalSideloadStatePath -StateRoot $StateRoot -ClusterName $State.ClusterName
    if (-not $PSCmdlet.ShouldProcess($path, 'Write sideload state')) { return }

    $json = $State | ConvertTo-Json -Depth 6
    $temp = "{0}.{1}.partial" -f $path, ([guid]::NewGuid().ToString('N'))
    try {
        Write-Utf8NoBomFile -Path $temp -Content $json
        Move-Item -LiteralPath $temp -Destination $path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-AzLocalSideloadHeartbeatStale {
    <#
    .SYNOPSIS
        Returns $true when a Copying state's heartbeat is older than the stale
        threshold (the owning runner/agent likely died), so the next pipeline run
        can re-drive the copy on a live host.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()][PSCustomObject]$State,
        [Parameter(Mandatory = $true)][int]$StaleMinutes
    )

    if ($State.State -ne 'Copying') { return $false }
    [DateTime]$last = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$State.LastHeartbeatUtc, [ref]$last)) {
        return $true
    }
    $ageMinutes = ([DateTime]::UtcNow - $last.ToUniversalTime()).TotalMinutes
    return ($ageMinutes -gt $StaleMinutes)
}

function Test-AzLocalSideloadProgressStale {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][ValidateNotNull()][PSCustomObject]$State,
        [Parameter(Mandatory = $true)][int]$StaleMinutes
    )

    if ($State.State -ne 'Copying') { return $false }
    [DateTime]$lastProgress = [DateTime]::MinValue
    if ($State.PSObject.Properties['LastProgressUtc']) {
        $progressValue = [string]$State.LastProgressUtc
    }
    elseif ($State.PSObject.Properties['StartUtc']) {
        $progressValue = [string]$State.StartUtc
    }
    elseif ($State.PSObject.Properties['LastHeartbeatUtc']) {
        $progressValue = [string]$State.LastHeartbeatUtc
    }
    else {
        return $false
    }
    if (-not [DateTime]::TryParse($progressValue, [ref]$lastProgress)) { return $true }
    return (([DateTime]::UtcNow - $lastProgress.ToUniversalTime()).TotalMinutes -gt $StaleMinutes)
}
