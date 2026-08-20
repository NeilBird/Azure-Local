function Update-AzLocalApplyUpdatesScheduleConfig {
    <#
    .SYNOPSIS
        Schema-version-aware updater for an existing apply-updates-schedule.yml.
        Backs the old file up as <name>.v<oldVersion>.old.yml and writes the
        migrated content. Customer schedule rows + operator comments are
        preserved verbatim by every recipe.

    .DESCRIPTION
        Partner to New-AzLocalApplyUpdatesScheduleConfig (which writes a
        FRESH file). This cmdlet is the dedicated maintenance entry point
        for an EXISTING schedule file:

          * -SchemaMigrate (default): walks the per-hop recipes registered
            by the module's migration framework
            (Private/Convert-AzLocalScheduleSchemaVersion.ps1) from the
            file's current schemaVersion up to the module's current
            $script:ScheduleSchemaCurrentVersion. The original file is
            renamed to <name>.v<oldVersion>.old.yml in the same directory
            (keeping the .yml extension so editors / git diff continue to
            treat it as YAML), then the new content is written. If the
            file is ALREADY on the current schema version, the cmdlet
            logs that fact and exits without writing anything.

          * (Future) -MergeNewRings: re-discover the fleet via Resource
            Graph, append a new schedule row for every UpdateRing tag
            value present in the fleet that is not yet referenced by ANY
            existing schedule row. Reserved for v0.7.70 - not implemented
            in v0.7.69; the parameter is rejected with a clear message.

        Both modes are intentionally non-destructive:
          - The customer's cycleWeeks, cycleAnchor*, and ALL schedule rows
            are preserved by every migration recipe (recipes operate on
            raw text and only touch the top-level schemaVersion field
            plus any newly-introduced top-level fields).
          - The original file is never silently overwritten - either
            renamed to <name>.v<oldVersion>.old.yml (SchemaMigrate hop)
            or left untouched (no-op).
          - The backup file is left in your working tree. Source control
            (git diff <name>.v<oldVersion>.old.yml <name>) gives you a
            full review of what changed. Delete the backup once you have
            committed the migration.

        Supports -WhatIf / -Confirm.

    .PARAMETER Path
        Path to the existing schedule file. Must exist.

    .PARAMETER SchemaMigrate
        Run schema-version migration to the module's current schema
        version. This is the default action.

    .PARAMETER MergeNewRings
        Reserved for v0.7.70. Currently throws with a remediation message.

    .PARAMETER PassThru
        Emit a [PSCustomObject] describing what happened (Action,
        FromVersion, ToVersion, BackupPath, Hops[]). Default: no
        pipeline output, only Write-Log messages.

    .OUTPUTS
        Nothing by default. With -PassThru:
        [PSCustomObject]@{
            Action       = 'Migrated' | 'Unchanged-SchemaCurrent'
            Path         = <full path>
            FromVersion  = <int>
            ToVersion    = <int>
            BackupPath   = <string or $null>
            Hops         = <object[]>
        }

    .EXAMPLE
        Update-AzLocalApplyUpdatesScheduleConfig -Path .\apply-updates-schedule.yml

        After 'Update-Module AzLocal.UpdateManagement', run this once to
        bring the schedule file up to the module's current schema. If no
        migration is needed it is a no-op.

    .EXAMPLE
        Update-AzLocalApplyUpdatesScheduleConfig -Path .\apply-updates-schedule.yml -PassThru |
            Format-List

        Same migration, but emit the structured result so it can be piped
        into change-control logs.

    .EXAMPLE
        Update-AzLocalApplyUpdatesScheduleConfig -Path .\apply-updates-schedule.yml -WhatIf

        Preview the migration without renaming the original or writing
        the new file.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'SchemaMigrate')]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(ParameterSetName = 'SchemaMigrate')]
        [switch]$SchemaMigrate,

        [Parameter(ParameterSetName = 'MergeNewRings')]
        [switch]$MergeNewRings,

        [Parameter()]
        [switch]$PassThru
    )

    # ---- 0. Reject the v0.7.70-reserved switch ----------------------
    if ($MergeNewRings) {
        throw "Update-AzLocalApplyUpdatesScheduleConfig: -MergeNewRings is reserved for v0.7.70 (fleet-drift detection). Use -SchemaMigrate (default) for schema version migration today, or call New-AzLocalApplyUpdatesScheduleConfig to regenerate the file from scratch."
    }

    # ---- 1. Path validation ----------------------------------------
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Update-AzLocalApplyUpdatesScheduleConfig: file not found: '$Path'. To create a starter file, use 'New-AzLocalApplyUpdatesScheduleConfig -OutputPath <path>'."
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    $text = Get-Content -LiteralPath $full -Raw -ErrorAction Stop

    # ---- 2. Run the migrator ---------------------------------------
    Write-Log -Message "Reading $full and computing migration to schema version $script:ScheduleSchemaCurrentVersion..." -Level Info
    $result = Convert-AzLocalScheduleSchemaVersion -Text $text -TargetSchemaVersion $script:ScheduleSchemaCurrentVersion -SourcePath $full

    # ---- 3. No-op path: schema already current ----------------------
    if (-not $result.Migrated) {
        Write-Log -Message "Schedule file is already on schemaVersion=$($result.ToVersion). No changes required." -Level Info
        if ($PassThru) {
            return [pscustomobject]@{
                Action      = 'Unchanged-SchemaCurrent'
                Path        = $full
                FromVersion = $result.FromVersion
                ToVersion   = $result.ToVersion
                BackupPath  = $null
                Hops        = @()
            }
        }
        return
    }

    # ---- 4. Migration path: backup + write -------------------------
    # Backup naming: <basename>.v<oldVersion>.old.yml
    # - keeps the .yml extension so editors and 'git diff' still treat it as YAML
    # - .v<N>.old makes the relationship to the migrated file obvious
    # - placed in the same directory so a single 'git diff' shows both files
    $dir       = [System.IO.Path]::GetDirectoryName($full)
    $base      = [System.IO.Path]::GetFileNameWithoutExtension($full)
    $backupName = "$base.v$($result.FromVersion).old.yml"
    $backupPath = if ($dir) { Join-Path $dir $backupName } else { $backupName }

    if ((Test-Path -LiteralPath $backupPath) -and -not $WhatIfPreference) {
        # An earlier migration left a backup with this exact version label.
        # Refuse rather than overwrite the prior backup - this is most
        # commonly a sign that a previous migration didn't get committed.
        throw "Update-AzLocalApplyUpdatesScheduleConfig: backup target '$backupPath' already exists. A previous migration from version $($result.FromVersion) was not cleaned up. Review/commit/delete it, then re-run."
    }

    $changeSummary = ($result.Hops | ForEach-Object { "v$($_.FromVersion)->v$($_.ToVersion): $(($_.Changes -join '; '))" }) -join ' | '

    $shouldMsg = "Migrate schemaVersion $($result.FromVersion) -> $($result.ToVersion). Backup '$([IO.Path]::GetFileName($full))' as '$backupName'. Changes: $changeSummary"
    if (-not $PSCmdlet.ShouldProcess($full, $shouldMsg)) {
        Write-Log -Message "WhatIf/Confirm declined: schedule file NOT modified. Computed migration was: $shouldMsg" -Level Info
        if ($PassThru) {
            return [pscustomobject]@{
                Action      = 'WhatIf'
                Path        = $full
                FromVersion = $result.FromVersion
                ToVersion   = $result.ToVersion
                BackupPath  = $backupPath
                Hops        = $result.Hops
            }
        }
        return
    }

    # Atomic-ish: rename original first so we never have two valid copies
    # at the canonical path. If the rename succeeds but the write fails,
    # the operator still has a working schedule file at <backupName>.
    Rename-Item -LiteralPath $full -NewName $backupName -ErrorAction Stop
    Write-Log -Message "Renamed original to: $backupPath" -Level Info

    try {
        [System.IO.File]::WriteAllText($full, $result.NewText, [System.Text.UTF8Encoding]::new($false))
        $null = Get-AzLocalApplyUpdatesScheduleConfig -Path $full
    }
    catch {
        # Roll the rename back so the operator is not left without a
        # schedule file in the canonical location.
        Write-Log -Message "Write or validation of migrated content FAILED: $($_.Exception.Message). Rolling back the rename so the original is restored." -Level Error
        try {
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                Remove-Item -LiteralPath $full -Force -ErrorAction Stop
            }
            Rename-Item -LiteralPath $backupPath -NewName ([System.IO.Path]::GetFileName($full)) -ErrorAction Stop
        }
        catch { Write-Log -Message "ROLLBACK ALSO FAILED. Manual recovery needed: rename '$backupPath' back to '$full' by hand." -Level Error }
        throw
    }

    Write-Log -Message "Migrated $full to schemaVersion=$($result.ToVersion):" -Level Success
    foreach ($hop in $result.Hops) {
        Write-Log -Message "  v$($hop.FromVersion) -> v$($hop.ToVersion):" -Level Info
        foreach ($c in $hop.Changes) { Write-Log -Message "    + $c" -Level Info }
    }
    Write-Log -Message "Review the migration with: git diff -- ""$([IO.Path]::GetFileName($full))""" -Level Info
    Write-Log -Message "Once you have committed the new file, the backup '$backupName' can be removed." -Level Info

    if ($PassThru) {
        return [pscustomobject]@{
            Action      = 'Migrated'
            Path        = $full
            FromVersion = $result.FromVersion
            ToVersion   = $result.ToVersion
            BackupPath  = $backupPath
            Hops        = $result.Hops
        }
    }
}
