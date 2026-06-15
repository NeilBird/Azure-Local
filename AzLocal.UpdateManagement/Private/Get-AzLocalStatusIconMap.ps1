function Get-AzLocalStatusIconMap {
    ########################################
    <#
    .SYNOPSIS
        Returns the host-aware status-icon map used by every pipeline
        step-summary renderer.
    .DESCRIPTION
        v0.8.81 single source of truth for the "status name -> icon" map shared
        by every Public cmdlet that emits a markdown step summary (Step.05-10).

        Prior to this helper each cmdlet hard-coded its own icon glyphs, with
        Step.07 also implementing a host-aware switch between Unicode glyphs
        (for GitHub Actions and local runs) and GitHub-style markdown
        shortcodes (`:white_check_mark:` etc., for Azure DevOps where the
        Wiki/Markdown rendering surface understands shortcodes more reliably
        than Unicode at small font sizes).

        The map is keyed by status NAME (not emoji) so callers stay readable.
        Add new entries here rather than inline in renderers.

    .PARAMETER PipelineHost
        Optional host override. Accepted values: 'GitHub', 'AzureDevOps', 'Local'.
        When omitted, the helper auto-detects via Get-AzLocalPipelineHost.

    .OUTPUTS
        [hashtable] keyed by status-name (string) -> formatted display cell (string).
        Example: $map['UpToDate'] -> ':white_check_mark: Up to Date' on ADO
                                  -> '<U+2705> Up to Date'           on GitHub/Local

    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.81
        Created : 2026-06-15
    #>
    ########################################
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateSet('GitHub', 'AzureDevOps', 'Local', 'Auto')]
        [string]$PipelineHost = 'Auto'
    )

    Set-StrictMode -Version Latest

    $resolvedHost = if ($PipelineHost -eq 'Auto') { Get-AzLocalPipelineHost } else { $PipelineHost }
    $useShortcodes = ($resolvedHost -eq 'AzureDevOps')

    # Glyph constants -- declared once so the hashtable below stays readable.
    $check     = [string][char]0x2705                       # ✅
    $cross     = [string][char]0x274C                       # ❌
    $noEntry   = [string][char]0x26D4                       # ⛔
    $hourglass = [string][char]0x23F3                       # ⏳
    $warn      = [string][char]0x26A0 + [string][char]0xFE0F # ⚠️
    $question  = [string][char]0x2753                       # ❓

    if ($useShortcodes) {
        return @{
            # Readiness cascade
            'Ready'              = ':white_check_mark: Ready'
            'ReadyForUpdate'     = ':white_check_mark: Ready for Update'
            'UpToDate'           = ':white_check_mark: Up to Date'
            'InProgress'         = ':hourglass_flowing_sand: In Progress'
            'SbeBlocked'         = ':no_entry: SBE Prerequisite'
            'HealthFailure'      = ':x: Health Failure'
            'UpdateFailed'       = ':x: Update Failed'
            'ActionRequired'     = ':x: Action Required'
            'NeedsInvestigation' = ':warning: Needs Investigation'
            # Health overview
            'Healthy'            = ':white_check_mark: Healthy'
            'Critical'           = ':x: Critical'
            'Warning'            = ':warning: Warning'
            'Unknown'            = ':question: Unknown'
            'HealthCheckFailed'  = ':x: Health check failed'
            # Severity tags (for failure-row labels)
            'SeverityCritical'   = ':x: Critical'
            'SeverityWarning'    = ':warning: Warning'
            # Apply-updates outcomes
            'Success'            = ':white_check_mark:'
            'Fail'               = ':x:'
            'Block'              = ':no_entry:'
            'Skip'               = ':next_track_button:'
            'Warn'               = ':warning:'
            # Run.State buckets (Step.08 monitor) - bare glyph for the State
            # column. Kept visually distinct from progress-status icons above
            # so the State column doesn't blur into the Current Step icon.
            'StateInProgress'    = ':large_blue_circle:'
            'StateSucceeded'     = ':white_check_mark:'
            'StateFailed'        = ':x:'
            'StateNotStarted'    = ':white_circle:'
            'StateUnknown'       = ':grey_question:'
            # Progress-status buckets (Step.08 Current Step Status column) -
            # bare glyph form of the same icons used in the readiness cascade.
            'StatusInProgress'   = ':hourglass_flowing_sand:'
            'StatusCancelled'    = ':fast_forward:'
            # Fleet status (Step.09 Primary/Critical Health tables) - bare
            # glyphs for the per-row Status column. Mostly aliases of the
            # outcome icons; named so each renderer can stay readable.
            'Info'               = ':information_source:'
            'GreenCircle'        = ':green_circle:'
            'YellowCircle'       = ':yellow_circle:'
            'CycleArrows'        = ':arrows_counterclockwise:'
            'GreyQuestion'       = ':grey_question:'
            # Fleet version-distribution Support cell (Step.09).
            'SupportSupported'   = ':white_check_mark: Supported'
            'SupportUnsupported' = ':warning: Unsupported'
            'SupportUnknown'     = ':grey_question: Unknown'
        }
    }

    return @{
        # Readiness cascade
        'Ready'              = ('{0} Ready' -f $check)
        'ReadyForUpdate'     = ('{0} Ready for Update' -f $check)
        'UpToDate'           = ('{0} Up to Date' -f $check)
        'InProgress'         = ('{0} In Progress' -f $hourglass)
        'SbeBlocked'         = ('{0} SBE Prerequisite' -f $noEntry)
        'HealthFailure'      = ('{0} Health Failure' -f $cross)
        'UpdateFailed'       = ('{0} Update Failed' -f $cross)
        'ActionRequired'     = ('{0} Action Required' -f $cross)
        'NeedsInvestigation' = ('{0} Needs Investigation' -f $warn)
        # Health overview
        'Healthy'            = ('{0} Healthy' -f $check)
        'Critical'           = ('{0} Critical' -f $cross)
        'Warning'            = ('{0} Warning' -f $warn)
        'Unknown'            = ('{0} Unknown' -f $question)
        'HealthCheckFailed'  = ('{0} Health check failed' -f $cross)
        # Severity tags
        'SeverityCritical'   = ('{0} Critical' -f $cross)
        'SeverityWarning'    = ('{0} Warning' -f $warn)
        # Apply-updates outcomes (bare glyphs for inline use)
        'Success'            = $check
        'Fail'               = $cross
        'Block'              = $noEntry
        'Skip'               = ([string][char]0x23ED + [string][char]0xFE0F)
        'Warn'               = $warn
        # Run.State buckets (Step.08 monitor) - bare glyph for the State column.
        'StateInProgress'    = ([char]::ConvertFromUtf32(0x1F535))   # blue circle (supplementary plane)
        'StateSucceeded'     = $check
        'StateFailed'        = $cross
        'StateNotStarted'    = ([string][char]0x26AA)    # white circle
        'StateUnknown'       = ([string][char]0x2754)    # white question mark
        # Progress-status buckets (Step.08 Current Step Status column) -
        # bare glyph form of the same icons used in the readiness cascade.
        'StatusInProgress'   = $hourglass
        'StatusCancelled'    = ([string][char]0x23E9)    # fast-forward
        # Fleet status (Step.09 Primary/Critical Health tables) - bare glyphs.
        'Info'               = ([string][char]0x2139 + [string][char]0xFE0F)   # information source
        'GreenCircle'        = ([char]::ConvertFromUtf32(0x1F7E2))             # green circle (supplementary plane)
        'YellowCircle'       = ([char]::ConvertFromUtf32(0x1F7E1))             # yellow circle (supplementary plane)
        'CycleArrows'        = ([char]::ConvertFromUtf32(0x1F504))             # arrows counterclockwise (supplementary plane)
        'GreyQuestion'       = $question
        # Fleet version-distribution Support cell (Step.09).
        'SupportSupported'   = ('{0} Supported' -f $check)
        'SupportUnsupported' = ('{0} Unsupported' -f $warn)
        'SupportUnknown'     = ('{0} Unknown' -f $question)
    }
}
