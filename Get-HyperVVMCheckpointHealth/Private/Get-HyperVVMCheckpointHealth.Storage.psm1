Set-StrictMode -Version Latest

function Get-VHDChainReport {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [scriptblock]$GetVhdCommand = { param($ResolvedPath) Get-VHD -Path $ResolvedPath -ErrorAction Stop },
        [scriptblock]$GetItemCommand = { param($ResolvedPath) Get-Item -LiteralPath $ResolvedPath -ErrorAction Stop },
        [ValidateRange(1, 1024)]
        [int]$MaximumDepth = 256
    )

    $chain = [System.Collections.Generic.List[object]]::new()
    $visited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $currentPath = $Path
    $complete = $false
    $failurePath = $null
    $errorText = $null
    $terminalType = $null
    $depthLimitReached = $false

    while ($currentPath) {
        if ($chain.Count -ge $MaximumDepth) {
            $failurePath = $currentPath
            $errorText = "VHD chain exceeded the maximum depth of $MaximumDepth layers."
            $depthLimitReached = $true
            break
        }
        if (-not $visited.Add([string]$currentPath)) {
            $failurePath = $currentPath
            $errorText = "VHD parent cycle detected at '$currentPath'."
            break
        }

        $vhd = $null
        try {
            $vhd = & $GetVhdCommand $currentPath
            if (-not $vhd) { throw "Get-VHD returned no data for '$currentPath'." }
        } catch {
            $failurePath = $currentPath
            $errorText = $_.Exception.Message
            break
        }

        $file = $null
        try { $file = & $GetItemCommand $currentPath } catch { }
        [void]$chain.Add([pscustomobject]@{
            Path      = [string]$vhd.Path
            Type      = [string]$vhd.VhdType
            SizeGB    = if ($file) { [math]::Round($file.Length / 1GB, 2) } else { [math]::Round(($vhd.FileSize) / 1GB, 2) }
            Created   = if ($file) { $file.CreationTimeUtc } else { $null }
            LastWrite = if ($file) { $file.LastWriteTimeUtc } else { $null }
        })

        $parentPath = [string]$vhd.ParentPath
        if (-not $parentPath) {
            $terminalType = [string]$vhd.VhdType
            if ([string]$vhd.VhdType -eq 'Differencing') {
                $failurePath = [string]$vhd.Path
                $errorText = "Differencing layer '$($vhd.Path)' has no parent path; a terminal base disk was not reached."
            } else {
                $complete = $true
            }
            break
        }
        $currentPath = $parentPath
    }

    [pscustomobject]@{
        Chain       = $chain.ToArray()
        Complete    = $complete
        FailurePath = $failurePath
        Error       = $errorText
        TerminalType = $terminalType
        DepthLimitReached = $depthLimitReached
    }
}

function Get-CheckpointStalenessAssessment {
    [OutputType([pscustomobject])]
    param(
        [object[]]$DiskReports,
        [object[]]$Snapshots,
        [ValidateRange(0, 8760)]
        [int]$StaleHours,
        [datetime]$NowUtc = [datetime]::UtcNow
    )

    $attachedLayers = @($DiskReports | ForEach-Object { @($_.Chain) } | Where-Object { $_.Type -eq 'Differencing' })
    $snapshotRows = @($Snapshots)
    $staleAttachedLayers = @($attachedLayers | Where-Object {
        $_.LastWrite -and ($NowUtc - ([datetime]$_.LastWrite).ToUniversalTime()).TotalHours -ge $StaleHours
    })
    $staleSnapshots = @($snapshotRows | Where-Object {
        $_.CreationTimeUtc -and ($NowUtc - ([datetime]$_.CreationTimeUtc).ToUniversalTime()).TotalHours -ge $StaleHours
    })
    $snapshotLayerMismatch = (($snapshotRows.Count -gt 0) -xor ($attachedLayers.Count -gt 0))

    [pscustomobject]@{
        AttachedLayerCount      = $attachedLayers.Count
        SnapshotCount           = $snapshotRows.Count
        StaleAttachedLayerCount = $staleAttachedLayers.Count
        StaleSnapshotCount      = $staleSnapshots.Count
        SnapshotLayerMismatch   = [bool]$snapshotLayerMismatch
        StaleAttachedLayers     = $staleAttachedLayers
        StaleSnapshots          = $staleSnapshots
    }
}

function Resolve-AvhdxOwnership {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Inventory,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Ownership,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CurrentVMName,

        [Parameter(Mandatory)]
        [bool]$CoverageComplete
    )

    $ownersByPath = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.HashSet[string]]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ownerRow in @($Ownership)) {
        $path = [string]$ownerRow.Path
        $vmName = [string]$ownerRow.VMName
        if ([string]::IsNullOrWhiteSpace($path) -or [string]::IsNullOrWhiteSpace($vmName)) { continue }
        if (-not $ownersByPath.ContainsKey($path)) {
            $ownersByPath[$path] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$ownersByPath[$path].Add($vmName)
    }

    foreach ($inventoryRow in @($Inventory)) {
        $path = [string]$inventoryRow.FullName
        $owners = @(if ($path -and $ownersByPath.ContainsKey($path)) { @($ownersByPath[$path] | Sort-Object) } else { @() })
        $classification = if (@($owners | Where-Object { $_ -eq $CurrentVMName }).Count -gt 0) {
            'AttachedToThisVM'
        } elseif ($owners.Count -gt 0) {
            'AttachedToOtherVM'
        } elseif ($CoverageComplete) {
            'UnattachedCandidate'
        } else {
            'OwnershipAmbiguous'
        }

        [pscustomobject]@{
            FullName       = $path
            InventoryItem  = $inventoryRow
            Owners         = $owners
            Classification = $classification
        }
    }
}

function Get-VMOrphanCandidatesFromClusterInventory {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Ownership,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$CurrentVMName,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$VhdFolders,
        [Parameter(Mandatory)][bool]$CoverageComplete,
        [AllowEmptyCollection()][string[]]$VhdSetManagedFolders = @()
    )

    if (-not $CoverageComplete -or $VhdFolders.Count -eq 0) { return }

    $folderSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($folder in @($VhdFolders)) {
        if ($folder) { [void]$folderSet.Add(([string]$folder).TrimEnd('\', '/')) }
    }
    $inScope = @($Inventory | Where-Object {
        $path = [string]$_.FullName
        if ([System.IO.Path]::GetExtension($path) -ne '.avhdx') { return $false }
        $parent = [System.IO.Path]::GetDirectoryName($path)
        if (@($VhdSetManagedFolders | Where-Object {
            $parent -and $parent.Equals(([string]$_).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0) { return $false }
        foreach ($folder in $folderSet) {
            if ($parent.Equals($folder, [System.StringComparison]::OrdinalIgnoreCase) -or
                $parent.StartsWith($folder + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
                $parent.StartsWith($folder + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
        return $false
    })
    if ($inScope.Count -eq 0) { return }

    Resolve-AvhdxOwnership -Inventory $inScope -Ownership $Ownership -CurrentVMName $CurrentVMName `
        -CoverageComplete $CoverageComplete | Where-Object { $_.Classification -eq 'UnattachedCandidate' } |
        ForEach-Object { $_.InventoryItem }
}

function Get-VirtualDiskHousekeepingClassification {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Owners,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$VMAssociatedFolders,

        [Parameter(Mandatory)]
        [bool]$CoverageComplete,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ImageLibraryPathPatterns,

        [AllowEmptyCollection()]
        [string[]]$VhdSetManagedFolders = @()
    )

    $normalizedPath = $Path.TrimEnd('\', '/')
    $associatedRows = @($VMAssociatedFolders | Where-Object {
        $folderPath = ([string]$_.Path).TrimEnd('\', '/')
        $folderPath -and ($normalizedPath.StartsWith($folderPath + '\', [System.StringComparison]::OrdinalIgnoreCase) -or
            $normalizedPath.StartsWith($folderPath + '/', [System.StringComparison]::OrdinalIgnoreCase))
    })
    $ownerSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($owner in @($Owners)) { if ($owner) { [void]$ownerSet.Add($owner) } }
    $folderOwnerMismatch = @($associatedRows | Where-Object { $_.VMName -and -not $ownerSet.Contains([string]$_.VMName) }).Count -gt 0
    # Azure Local ImageStore paths and versioned ARB appliance images are always excluded from
    # housekeeping, even when policy replaces the configurable pattern list with an empty array.
    $automaticImageStorePattern = '(?i)[\\/]imagestore(?:[\\/]|$)'
    $automaticArbImagePattern = '(?i)(?:^|[\\/])linux-cblmariner-[0-9]+(?:\.[0-9]+){3}\.vhdx$'
    $effectiveImagePatterns = @($automaticImageStorePattern, $automaticArbImagePattern) + @($ImageLibraryPathPatterns)
    $matchedImagePattern = @($effectiveImagePatterns | Where-Object { $normalizedPath -match $_ } | Select-Object -First 1)
    $matchedImageText = if ($matchedImagePattern.Count -gt 0) {
        ([regex]::Match($normalizedPath, [string]$matchedImagePattern[0]).Value).Trim('\', '/')
    } else { '' }
    $extension = [System.IO.Path]::GetExtension($normalizedPath).ToLowerInvariant()
    $parentPath = [System.IO.Path]::GetDirectoryName($normalizedPath)
    # VHD Sets expose an attached .vhds metadata path while Hyper-V manages companion files.
    # https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/create-vhdset-file
    $vhdSetManagedFolder = @($VhdSetManagedFolders | Where-Object {
        $parentPath -and $parentPath.Equals(([string]$_).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)

    $classification = if (-not $CoverageComplete) {
        'OwnershipAmbiguous'
    } elseif ($matchedImagePattern.Count -gt 0) {
        'ExcludedImageLibraryAsset'
    } elseif ($extension -eq '.avhdx' -and $ownerSet.Count -eq 0 -and $vhdSetManagedFolder.Count -gt 0) {
        'VhdSetManagedAsset'
    } elseif ($folderOwnerMismatch -or (($ownerSet.Count -eq 0) -and ($associatedRows.Count -gt 0))) {
        'PlacementInconsistency'
    } elseif ($ownerSet.Count -gt 0) {
        'AttachedVirtualDisk'
    } elseif ($extension -eq '.avhdx') {
        'UnattachedDifferencingCandidate'
    } elseif ($extension -eq '.vhds') {
        'UnattachedVhdSetCandidate'
    } else {
        'UnattachedBaseDiskCandidate'
    }

    [pscustomobject]@{
        Path                   = $Path
        Classification         = $classification
        Owners                 = @($ownerSet | Sort-Object)
        AssociatedVMs          = @($associatedRows | ForEach-Object { [string]$_.VMName } | Where-Object { $_ } | Sort-Object -Unique)
        MatchedImageSegment    = $matchedImageText
        MatchedImagePattern    = if ($matchedImagePattern.Count -gt 0) { [string]$matchedImagePattern[0] } else { '' }
        VhdSetManagedFolder    = if ($vhdSetManagedFolder.Count -gt 0) { [string]$vhdSetManagedFolder[0] } else { '' }
        HealthVerdictImpact    = $false
        CoverageComplete       = $CoverageComplete
    }
}

function Get-ClusterStorageHealthSnapshot {
    [OutputType([object])]
    param([string]$TargetNode)

    $scan = {
        $o = [ordered]@{
            ComputerName   = $env:COMPUTERNAME
            StorageModule  = [bool](Get-Command Get-StorageJob -ErrorAction SilentlyContinue)
            StorageJobs    = @()
            VDiskUnhealthy = @()
            PDiskUnhealthy = @()
            Subsystem      = @()
            HealthFaults   = @()
            HealthFaultCollectionStatus = 'Not attempted'
            CsvRedirected  = @()
            Notes          = @()
        }
        try { $o.StorageJobs = @(Get-StorageJob -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.Name; State = [string]$_.JobState; Pct = [string]$_.PercentComplete } }) } catch { $o.Notes += "StorageJob: $($_.Exception.Message)" }
        try { $o.VDiskUnhealthy = @(Get-VirtualDisk -ErrorAction Stop | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' -or "$($_.OperationalStatus)" -notmatch '^(OK|Completed)$' } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus; Operational = [string]($_.OperationalStatus -join ',') } }) } catch { $o.Notes += "VirtualDisk: $($_.Exception.Message)" }
        try { $o.PDiskUnhealthy = @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.HealthStatus)" -ne 'Healthy' } | ForEach-Object { [pscustomobject]@{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus; Operational = [string]($_.OperationalStatus -join ','); Usage = [string]$_.Usage } }) } catch { $o.Notes += "PhysicalDisk: $($_.Exception.Message)" }
        try { $o.Subsystem = @(Get-StorageSubSystem -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = [string]$_.FriendlyName; Health = [string]$_.HealthStatus } }) } catch { $o.Notes += "Subsystem: $($_.Exception.Message)" }
        if (Get-Command Get-HealthFault -ErrorAction SilentlyContinue) {
            try {
                $o.HealthFaults = @(Get-HealthFault -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{
                        Severity                  = if ($_.PSObject.Properties['PerceivedSeverity']) { [string]$_.PerceivedSeverity } elseif ($_.PSObject.Properties['Severity']) { [string]$_.Severity } else { '' }
                        Reason                    = if ($_.PSObject.Properties['Reason']) { [string]$_.Reason } else { '' }
                        FaultingObjectDescription = if ($_.PSObject.Properties['FaultingObjectDescription']) { [string]$_.FaultingObjectDescription } else { '' }
                        FaultingObjectLocation    = if ($_.PSObject.Properties['FaultingObjectLocation']) { [string]$_.FaultingObjectLocation } else { '' }
                    }
                })
                $o.HealthFaultCollectionStatus = 'Success'
            } catch {
                $o.HealthFaultCollectionStatus = 'Failed'
                $o.Notes += "HealthFault: $($_.Exception.Message)"
            }
        } else {
            $o.HealthFaultCollectionStatus = 'Cmdlet unavailable'
        }
        try {
            # IMPORTANT: on Azure Local / S2D with ReFS, CSVs run in FileSystemRedirected mode BY DESIGN
            # (FileSystemRedirectedIOReason = FileSystemReFs) - that is NORMAL and must NOT be flagged as
            # degraded. Only surface genuinely abnormal states: block redirection for a real reason,
            # file-system redirection for a NON-ReFS reason, or a paused / offline volume.
            $benignFsReasons = @('NotFileSystemRedirected', 'FileSystemReFs', '')
            $csvAbnormal = @(Get-ClusterSharedVolumeState -ErrorAction Stop |
                Where-Object {
                    $br = "$($_.BlockRedirectedIOReason)"
                    $fr = "$($_.FileSystemRedirectedIOReason)"
                    $si = "$($_.StateInfo)"
                    ($br -and $br -ne 'NotBlockRedirected') -or
                    ($fr -and ($benignFsReasons -notcontains $fr)) -or
                    ($si -match 'Paused|Offline')
                })
            # Collapse to ONE row per volume. Get-ClusterSharedVolumeState returns a row per volume PER
            # NODE, so a large cluster (e.g. 8 nodes x 40 volumes = 320 rows) would flood the table and a
            # single affected volume would repeat across every node. Group by volume and aggregate the
            # affected node(s) + distinct non-benign reasons so the table stays compact at any scale.
            $o.CsvRedirected = @($csvAbnormal | Group-Object VolumeFriendlyName | ForEach-Object {
                $g = $_.Group
                [pscustomobject]@{
                    Volume      = [string]$_.Name
                    Nodes       = (@($g | ForEach-Object { [string]$_.Node } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
                    State       = (@($g | ForEach-Object { [string]$_.StateInfo } | Where-Object { $_ } | Sort-Object -Unique) -join ', ')
                    BlockReason = (@($g | ForEach-Object { [string]$_.BlockRedirectedIOReason } | Where-Object { $_ -and $_ -ne 'NotBlockRedirected' } | Sort-Object -Unique) -join ', ')
                    FsReason    = (@($g | ForEach-Object { [string]$_.FileSystemRedirectedIOReason } | Where-Object { $_ -and ($benignFsReasons -notcontains $_) } | Sort-Object -Unique) -join ', ')
                }
            })
        } catch { $o.Notes += "CsvState: $($_.Exception.Message)" }
        [pscustomobject]$o
    }

    try {
        $local = $env:COMPUTERNAME
        if ($TargetNode -and ($TargetNode.Split('.')[0] -ne $local)) {
            $raw = Invoke-Command -ComputerName $TargetNode -ScriptBlock $scan -ErrorAction Stop
        } else {
            $raw = & $scan
        }
    } catch {
        return [pscustomobject]@{ Available = $false; Source = $TargetNode; Summary = 'Unavailable'; Note = $_.Exception.Message; StorageJobs = @(); VDiskUnhealthy = @(); PDiskUnhealthy = @(); Subsystem = @(); HealthFaults = @(); HealthFaultCollectionStatus = 'Not attempted'; CsvRedirected = @() }
    }

    $degraded = (@($raw.VDiskUnhealthy).Count -gt 0) -or (@($raw.PDiskUnhealthy).Count -gt 0) -or
        (@($raw.CsvRedirected).Count -gt 0) -or (@($raw.Subsystem | Where-Object { "$($_.Health)" -eq 'Unhealthy' }).Count -gt 0)
    $summary = if (-not $raw.StorageModule) { 'Unavailable' } elseif ($degraded) { 'Degraded' } elseif (@($raw.StorageJobs).Count -gt 0) { 'Active storage jobs' } else { 'Healthy' }
    [pscustomobject]@{
        Available      = [bool]$raw.StorageModule
        Source         = [string]$raw.ComputerName
        Summary        = $summary
        StorageJobs    = @($raw.StorageJobs)
        VDiskUnhealthy = @($raw.VDiskUnhealthy)
        PDiskUnhealthy = @($raw.PDiskUnhealthy)
        Subsystem      = @($raw.Subsystem)
        HealthFaults   = @($raw.HealthFaults)
        HealthFaultCollectionStatus = [string]$raw.HealthFaultCollectionStatus
        CsvRedirected  = @($raw.CsvRedirected)
        Note           = ((@($raw.Notes)) -join '; ')
    }
}

Export-ModuleMember -Function Get-VHDChainReport, Get-CheckpointStalenessAssessment, Resolve-AvhdxOwnership, Get-VMOrphanCandidatesFromClusterInventory, Get-VirtualDiskHousekeepingClassification, Get-ClusterStorageHealthSnapshot
