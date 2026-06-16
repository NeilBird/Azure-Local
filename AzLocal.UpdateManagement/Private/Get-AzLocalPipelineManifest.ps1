function Get-AzLocalPipelineManifest {
    <#
    .SYNOPSIS
        Returns the canonical pipeline manifest mapping each logical pipeline
        ID to its current bundled filename, display step number and the
        historical filenames it may have shipped under.

    .DESCRIPTION
        Private data helper introduced in v0.8.7. It is the single source of
        truth that decouples a pipeline's STABLE IDENTITY (the logical ID,
        e.g. 'apply-updates') from its volatile PRESENTATION (the display step
        number 'Step.7 - ...' and, historically, the filename prefix
        'Step.7_apply-updates.yml').

        Why this exists
        ---------------
        Up to and including v0.8.6 the bundled CI/CD YAMLs encoded their
        ordering in BOTH the filename ('Step.7_apply-updates.yml') and the
        display name ('Step.7 - Apply Updates ...'). Update-AzLocalPipelineExample
        matched a customer's destination file to a bundled source file by
        EXACT FILENAME. That made any renumbering a breaking change: when
        v0.8.7 moved apply-updates from Step.6 to Step.7, a customer's
        'Step.6_apply-updates.yml' (carrying their CRON triggers inside the
        BEGIN/END-AZLOCAL-CUSTOMIZE:schedule-triggers markers) became an
        orphan, and the new 'Step.7_apply-updates.yml' was treated as a
        brand-new file - silently stranding the customer's schedule.

        v0.8.7 fixes this two ways:
          1. The bundled filenames lose their 'Step.N_' prefix entirely and
             become stable forever (e.g. 'apply-updates.yml'). The step
             number now lives ONLY in the display name and artifact names,
             which flow through the marker-aware merge automatically.
          2. Every bundled YAML carries a '# AZLOCAL-PIPELINE-ID: <id>'
             comment, and this manifest records each ID's canonical filename
             plus the legacy filenames it used to ship under (Aliases).
             Update-AzLocalPipelineExample uses the ID/alias mapping to find
             a customer's file even when it is still named with an old
             'Step.N_' prefix, then renames it on disk while carrying the
             customer's marker bodies (CRONs) into the new file.

        Both platforms (GitHub Actions and Azure DevOps) share the same
        de-numbered base name + '.yml' for a given logical ID, so a single
        FileName/Aliases set covers both - the only difference is the
        platform subfolder the file lives in.

    .OUTPUTS
        PSCustomObject[] - one row per logical pipeline, in display order:
            Id           - stable logical identifier (de-numbered base name)
            FileName     - canonical bundled filename ('<Id>.yml')
            DisplayStep  - current Step.N number shown in the display name /
                           artifact names (presentation only)
            IntroducedIn - module version the pipeline first shipped in
            Aliases      - [string[]] historical filenames this pipeline has
                           shipped under (most-recent first). Empty for
                           pipelines that are net-new in this release.

    .NOTES
        Author   : Neil Bird, Microsoft
        Module   : AzLocal.UpdateManagement
        Added in : v0.8.7

        MAINTENANCE: when a pipeline is renamed, renumbered or added, update
        ONLY this manifest and the '# AZLOCAL-PIPELINE-ID' comment in the YAML.
        - Renumber (display only): bump DisplayStep, leave FileName/Id alone.
          Nothing else needs to change - Update merges the new display name in.
        - Rename a file: change FileName, PREPEND the old filename to Aliases.
        - Add a pipeline: add a new row with the next DisplayStep, a fresh Id,
          IntroducedIn = the new module version and Aliases = @().
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param()

    # Display order follows the Step.N numbering shown in the rendered
    # GitHub Actions / Azure DevOps pipeline list. Aliases list the historical
    # 'Step.N_<base>.yml' filenames most-recent first. The four pipelines that
    # were renumbered in v0.8.7 Group R (apply 6->7, monitor 7->8,
    # fleet-update 8->9, fleet-health 9->10) carry BOTH the post-renumber and
    # the pre-renumber legacy filename so Update can recover a customer's CRONs
    # regardless of which copy they started from. sideload-updates is net-new
    # in v0.8.7 and therefore has no aliases.
    #
    # v0.8.85: the two standalone onboarding workflows authentication-test.yml
    # (DisplayStep 0) and inventory-clusters.yml (DisplayStep 1) were merged
    # into a single setup-validate-and-inventory.yml (Config: 01). Its Aliases
    # list BOTH superseded filenames (and their Step.N_ ancestors) so
    # Update-AzLocalPipelineExample can rename-match a customer who still has
    # either old file and carry their schedule CRONs into the merged workflow.
    # inventory-clusters.yml is listed first because it is the alias that
    # historically carried the schedule trigger; the rename path adopts the
    # first existing alias. The companion authentication-test.yml is then
    # cleaned up by -PruneDeprecated.
    @(
        [PSCustomObject]@{ Id = 'setup-validate-and-inventory'; FileName = 'setup-validate-and-inventory.yml'; DisplayStep = 0;  IntroducedIn = '0.8.85'; Aliases = @('inventory-clusters.yml', 'authentication-test.yml', 'Step.1_inventory-clusters.yml', 'Step.0_authentication-test.yml') }
        [PSCustomObject]@{ Id = 'manage-updatering-tags';       FileName = 'manage-updatering-tags.yml';       DisplayStep = 2;  IntroducedIn = '0.7.0'; Aliases = @('Step.2_manage-updatering-tags.yml') }
        [PSCustomObject]@{ Id = 'apply-updates-schedule-audit'; FileName = 'apply-updates-schedule-audit.yml'; DisplayStep = 3;  IntroducedIn = '0.7.0'; Aliases = @('Step.3_apply-updates-schedule-audit.yml') }
        [PSCustomObject]@{ Id = 'fleet-connectivity-status';    FileName = 'fleet-connectivity-status.yml';    DisplayStep = 4;  IntroducedIn = '0.7.0'; Aliases = @('Step.4_fleet-connectivity-status.yml') }
        [PSCustomObject]@{ Id = 'assess-update-readiness';      FileName = 'assess-update-readiness.yml';      DisplayStep = 5;  IntroducedIn = '0.7.0'; Aliases = @('Step.5_assess-update-readiness.yml') }
        [PSCustomObject]@{ Id = 'sideload-updates';             FileName = 'sideload-updates.yml';             DisplayStep = 6;  IntroducedIn = '0.8.7'; Aliases = @() }
        [PSCustomObject]@{ Id = 'apply-updates';                FileName = 'apply-updates.yml';                DisplayStep = 7;  IntroducedIn = '0.7.0'; Aliases = @('Step.7_apply-updates.yml', 'Step.6_apply-updates.yml') }
        [PSCustomObject]@{ Id = 'monitor-updates';              FileName = 'monitor-updates.yml';              DisplayStep = 8;  IntroducedIn = '0.7.0'; Aliases = @('Step.8_monitor-updates.yml', 'Step.7_monitor-updates.yml') }
        [PSCustomObject]@{ Id = 'fleet-update-status';          FileName = 'fleet-update-status.yml';          DisplayStep = 9;  IntroducedIn = '0.7.0'; Aliases = @('Step.9_fleet-update-status.yml', 'Step.8_fleet-update-status.yml') }
        [PSCustomObject]@{ Id = 'fleet-health-status';          FileName = 'fleet-health-status.yml';          DisplayStep = 10; IntroducedIn = '0.7.0'; Aliases = @('Step.10_fleet-health-status.yml', 'Step.9_fleet-health-status.yml') }
    )
}
