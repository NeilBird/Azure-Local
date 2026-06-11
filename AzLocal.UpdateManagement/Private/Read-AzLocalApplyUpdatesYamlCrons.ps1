function Read-AzLocalApplyUpdatesYamlCrons {
    <#
    .SYNOPSIS
        Extracts cron schedule entries from apply-updates pipeline YAML files
        (GitHub Actions and Azure DevOps).
    .DESCRIPTION
        Pure regex pre-scan; deliberately does NOT take a dependency on
        powershell-yaml. Used by Test-AzLocalApplyUpdatesScheduleCoverage.

        Discovery rules:
          - If Path is a file, scan that file.
          - If Path is a directory, recursively scan every *.yml / *.yaml and
            keep only the apply-updates pipeline, identified by its stable
            '# AZLOCAL-PIPELINE-ID: apply-updates' header comment (v0.8.7+).
            Files that lack the ID comment (pre-v0.8.7 copies) fall back to a
            filename match: 'apply-updates*.yml/.yaml', optionally carrying a
            legacy 'Step.N_' prefix - but the de-numbered sibling
            'apply-updates-schedule-audit.yml' (the Step.3 audit pipeline,
            which has its own poll crons) is explicitly EXCLUDED so its crons
            are never mistaken for apply-updates windows.

        Platform is inferred from the parent directory name when the YAML is
        under .../github-actions/ or .../azure-devops/. Falls back to the
        Platform parameter when path-based inference is inconclusive.

        Parsing rules:
          - GitHub Actions:   lines matching   '- cron: "<expr>"'  or  "- cron: '<expr>'"
                              under a `schedule:` map.
          - Azure DevOps:     `cron:` keys inside a `schedules:` list. Same regex
                              works because cron lines look identical.
        Cron expressions wrapped in single or double quotes are both accepted.
    .PARAMETER Path
        File or directory to scan.
    .PARAMETER Platform
        Default platform tag when path inference is inconclusive. One of
        'GitHubActions', 'AzureDevOps', or 'Unknown'.
    .OUTPUTS
        PSCustomObject[] - one per discovered cron, with:
            File           - full path
            RelativePath   - path relative to Path (or basename if Path is a file)
            Platform       - 'GitHubActions' | 'AzureDevOps' | 'Unknown'
            CronExpression - the cron string (quotes stripped)
            LineNumber     - 1-based line in the source file
    .EXAMPLE
        Read-AzLocalApplyUpdatesYamlCrons -Path .\Automation-Pipeline-Examples
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [ValidateSet('GitHubActions', 'AzureDevOps', 'Unknown')]
        [string]$Platform = 'Unknown'
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    $item = Get-Item -LiteralPath $Path
    $files = if ($item.PSIsContainer) {
        # v0.8.7: identify the apply-updates pipeline by its stable
        # AZLOCAL-PIPELINE-ID header comment rather than a filename glob. The
        # previous 'apply-updates*.yml' wildcard now collides with the
        # de-numbered Step.3 audit pipeline ('apply-updates-schedule-audit.yml')
        # and would wrongly ingest its poll crons. Recurse all YAML, then keep
        # only ID == 'apply-updates'; for pre-ID copies fall back to a filename
        # match that explicitly excludes the schedule-audit sibling.
        $allYaml = @(Get-ChildItem -Path $item.FullName -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -in @('.yml', '.yaml') })
        $hits = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        foreach ($yf in $allYaml) {
            $ymlText = $null
            try { $ymlText = [System.IO.File]::ReadAllText($yf.FullName, [System.Text.UTF8Encoding]::new($false)) } catch { $ymlText = $null }
            $ymlId = if ($ymlText) { Get-AzLocalPipelineId -Text $ymlText } else { $null }
            if ($ymlId) {
                if ($ymlId -eq 'apply-updates') { $hits.Add($yf) | Out-Null }
                # ID present but not apply-updates -> deliberately skipped.
            }
            elseif ($yf.Name -match '(?i)^(Step\.\d+_)?apply-updates.*\.(yml|yaml)$' -and
                    $yf.Name -notmatch '(?i)apply-updates-schedule-audit') {
                # Pre-v0.8.7 copy with no ID comment: name-based fallback,
                # excluding the schedule-audit pipeline.
                $hits.Add($yf) | Out-Null
            }
        }
        @($hits | Sort-Object FullName -Unique)
    }
    else {
        @($item)
    }

    $output = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($f in $files) {
        $inferred = $Platform
        if ($f.FullName -match '[\\/]github-actions[\\/]') { $inferred = 'GitHubActions' }
        elseif ($f.FullName -match '[\\/]azure-devops[\\/]') { $inferred = 'AzureDevOps' }

        $relative = if ($item.PSIsContainer) {
            $f.FullName.Substring($item.FullName.Length).TrimStart('\','/')
        } else { $f.Name }

        $lineNum = 0
        $lines = Get-Content -LiteralPath $f.FullName -ErrorAction Stop
        foreach ($line in $lines) {
            $lineNum++
            # Match cron lines in both quote styles. Allow leading dash + space for
            # list-style entries (- cron: '...') and bare key style (cron: '...').
            if ($line -match "^\s*-?\s*cron\s*:\s*['""]([^'""]+)['""]") {
                $expr = $matches[1].Trim()
                # The character class [^'""]+ also matches whitespace runs, so
                # `cron: '   '` would survive with an empty capture after Trim().
                # Skip those instead of feeding an empty string to a downstream
                # [Parameter(Mandatory)][string] binder.
                if ([string]::IsNullOrWhiteSpace($expr)) { continue }
                $output.Add([PSCustomObject]@{
                    File           = $f.FullName
                    RelativePath   = $relative
                    Platform       = $inferred
                    CronExpression = $expr
                    LineNumber     = $lineNum
                })
            }
        }
    }

    # WARNING: Callers MUST use direct assignment ($x = func ...) and NEVER
    # wrap with @(func ...). The unary-comma return below preserves Object[N]
    # shape for any N including 0 and 1, but @() at the call site collapses
    # to Object[1] containing the inner array, silently producing one-row
    # output instead of N rows. See `docs/MODULE-REVIEW-AND-RECOMMENDATIONS.md`
    # Finding 1 for the v0.7.75 incident.
    return , $output.ToArray()
}
