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
          - If Path is a directory, recursively find files matching any of
            'Step.6_apply-updates*.yml', 'Step.6_apply-updates*.yaml',
            'apply-updates*.yml', or 'apply-updates*.yaml'.
            (The 'Step.5_' prefix is the v0.7.68+ shipped name; the un-prefixed
             form is the legacy name still supported for backwards compatibility.)

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
        # NOTE: Get-ChildItem -LiteralPath -Recurse -Include silently ignores the
        # -Include filter and returns every recursed file (confirmed in PS 5.1).
        # That caused v0.7.68 to pick up every Step.N_*.yml sibling (Step.1, Step.3,
        # Step.4, Step.7, Step.8, Step.9 all carry their own schedule crons) and treat
        # their crons as apply-updates crons - garbage in the audit, and on PS 7 the
        # binder surfaced it as 'Cannot bind argument to parameter Expression because
        # it is an empty string' once any unparseable capture was reached.
        # Use -Filter (which is honoured under -Recurse) one pattern at a time,
        # then dedupe by FullName.
        $patterns = @(
            'Step.6_apply-updates*.yml',
            'Step.6_apply-updates*.yaml',
            'apply-updates*.yml',
            'apply-updates*.yaml'
        )
        $hits = @()
        foreach ($pattern in $patterns) {
            $hits += @(Get-ChildItem -Path $item.FullName -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue)
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
