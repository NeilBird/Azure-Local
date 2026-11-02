function Export-AzLocalFleetState {
    <#
    .SYNOPSIS
        Exports the current fleet operation state to a JSON file for resume capability.
    
    .DESCRIPTION
        Saves the state of a fleet-wide update operation to a JSON file. This enables:
        - Resume capability after failures or interruptions
        - Progress tracking across multiple sessions
        - Audit trail of fleet operations
        
        The state file includes: RunId, timestamps, total/completed/failed/pending clusters,
        and detailed status for each cluster.
    
    .PARAMETER State
        The fleet operation state object to export. If not provided, uses the current
        in-memory state from $script:FleetOperationState.
    
    .PARAMETER Path
        The file path to save the state. Supports .json extension.
        Default: Creates timestamped file in the default log folder.
    
    .EXAMPLE
        Export-AzLocalFleetState -Path "C:\Logs\fleet-state.json"
        Exports the current fleet state to the specified file.
    
    .EXAMPLE
        $state = Invoke-AzLocalFleetOperation -ScopeByUpdateRingTag -UpdateRingValue "Wave1" -PassThru
        Export-AzLocalFleetState -State $state -Path "C:\Logs\wave1-state.json"
        Exports a specific state object.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [PSCustomObject]$State,
        
        [Parameter(Mandatory = $false)]
        [string]$Path
    )
    
    # Use provided state or script-level state
    $stateToExport = if ($State) { $State } else { $script:FleetOperationState }
    
    if (-not $stateToExport) {
        Write-Warning "No fleet operation state available to export."
        return $null
    }
    
    # Generate default path if not provided
    if (-not $Path) {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $logDir = $script:DefaultLogFolder
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $Path = Join-Path -Path $logDir -ChildPath "FleetState_$timestamp.json"
    }
    
    # Ensure directory exists
    $parentDir = Split-Path -Path $Path -Parent
    if ($parentDir -and -not (Test-Path $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }
    
    # Update state metadata
    $stateToExport.LastSaved = [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $stateToExport.StateFilePath = $Path
    
    # Export to JSON
    $targetPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $temporaryPath = Join-Path (Split-Path $targetPath -Parent) (([guid]::NewGuid().ToString('N')) + '.partial')
    try {
        Write-Utf8NoBomFile -Path $temporaryPath -Content ($stateToExport | ConvertTo-Json -Depth 10)
        if ([IO.File]::Exists($targetPath)) {
            [IO.File]::Replace($temporaryPath, $targetPath, [System.Management.Automation.Language.NullString]::Value)
        }
        else {
            [IO.File]::Move($temporaryPath, $targetPath)
        }
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) { [IO.File]::Delete($temporaryPath) }
    }
    Write-Log -Message "Fleet state exported to: $Path" -Level Success
    return $Path
}
