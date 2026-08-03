function Invoke-AzResourceGraphQuery {
    <#
    .SYNOPSIS
        Runs an Azure Resource Graph query via 'az graph query' and transparently
        follows skip_token pagination until all rows are returned.
    .DESCRIPTION
        The Azure CLI returns at most --first rows per call (max 1000). When a
        fleet has more than 1000 clusters the caller was previously receiving
        only a truncated first page. This helper loops on the response's
        skip_token field, aggregating .data across pages and returning the
        merged row array.

        Safety cap: MaxPages (default 100 -> 100,000 rows). Prevents a bug in
        the caller's query from producing an infinite pagination loop. When
        the cap is hit, a Write-Warning is emitted, the module-scope flag
        $script:LastResourceGraphQueryTruncated is set to $true, and the
        partial result is returned. Callers that need to behave differently
        on truncation can read the flag after the call.

        v0.7.68: the Query string is normalised (CR/LF and runs of whitespace
        collapsed to single spaces) BEFORE being passed to 'az graph query -q'.
        On Windows, az is implemented as az.cmd (a batch file), and the CMD
        argument parser truncates command-line arguments at the first CR/LF -
        so a multi-line PowerShell here-string KQL would silently be reduced
        to just its first line on the runner. The pre-v0.7.68 behaviour caused
        Test-AzLocalApplyUpdatesScheduleCoverage to silently return all
        resources (default schema, no UpdateRing/UpdateStartWindow columns) instead
        of the projected cluster rows it asked for; the audit then reported
        zero tagged clusters even when clusters were tagged correctly. The
        normalisation here protects every caller, current and future. KQL is
        whitespace-agnostic, so collapsing newlines/tabs is semantically a
        no-op.
    .PARAMETER Query
        KQL query string. Normalised to single-line before being passed to
        'az graph query -q'. See .DESCRIPTION for the Windows az.cmd reason.
    .PARAMETER SubscriptionId
        Optional. If supplied, scopes the query to those subscriptions via
        --subscriptions. Explicit subscriptions take precedence over management
        groups configured in fleet-settings.yml. Omit to use configured
        management groups, or the existing implicit accessible-subscription
        scope when no management groups are configured.
    .PARAMETER First
        Initial page size. Defaults to 1000 (the ARG maximum). If ARG rejects
        a page with ResponsePayloadTooLarge, the helper halves the page size
        and retries the same page until it succeeds or reaches one row.
    .PARAMETER MaxPages
        Safety cap. Defaults to 100 (= 100,000 rows). Bumped from 50 in
        v0.7.68 so that fleets up to ~100K clusters paginate without operator
        intervention.
    .PARAMETER MaxRetries
        v0.7.68: per-page retry budget for transient ARG throttling (HTTP 429
        / RateLimitingException). Each page can be retried up to this many
        times with exponential backoff + jitter before the call gives up and
        throws. Defaults to 5 (initial attempt + 5 retries = 6 total tries
        per page).

        v0.8.95: the SAME budget now also covers transient network failures
        (connection reset / "Connection broken" / ConnectionResetError 10054 /
        5xx gateway / timeout). These are retried with the same backoff but,
        unlike throttling, do NOT arm the cross-call cooldown.
    .PARAMETER RetryBaseSeconds
        v0.7.68: base delay for the exponential backoff on throttle retries.
        Defaults to 1 second; attempt N sleeps `RetryBaseSeconds * 2^(N-1)`
        seconds (1, 2, 4, 8, 16, ...) with +/-20% random jitter. The minimum
        effective sleep is 0.5s.
    .PARAMETER DisableCrossCallCooldown
        v0.7.84: opt out of the cross-call ARG cooldown wait at the start of
        this call. The cooldown is a small voluntary pause that this helper
        applies on entry if a PREVIOUS call to this helper observed ARG
        throttling. It is the cross-call companion to the per-page retry
        loop: the retry loop protects against bursts WITHIN one call; the
        cooldown protects against bursts ACROSS sequential calls (typical
        of fan-out fleet queries that issue many ARG requests back-to-back).
        Use this switch only in unit tests or when the caller has its own
        rate-limiting upstream.
    .NOTES
        v0.7.68 throttle handling exposes two module-scope diagnostic flags
        reset at the start of every call and readable by callers/tests:
          $script:LastResourceGraphThrottled  - $true if any retry happened
          $script:LastResourceGraphRetryCount - total retries across all pages
        Recognised throttle markers in the CLI error text (case-insensitive):
          'rate limit', 'ratelimit', 'throttl', '429', 'too many requests'.
        Once a throttle event is observed during a call, an inter-page pause
        of 1 second is inserted between subsequent pages to avoid immediately
        re-triggering the limiter.

        v0.8.95 transient-network handling exposes two more module-scope flags
        reset at the start of every call:
          $script:LastResourceGraphTransientNetwork   - $true if a connection
                                                        reset / "Connection
                                                        broken" / 5xx / timeout
                                                        was retried
          $script:LastResourceGraphTransientRetryCount - count of such retries
        Recognised transient-network markers (case-insensitive) include:
          'connection reset/aborted/broken/refused', 'forcibly closed',
          '10054', 'ConnectionResetError', 'RemoteDisconnected', 'remote end
          closed', 'max retries exceeded', 'ECONNRESET', 'service unavailable',
          '502/503/504', 'gateway time(out)', 'timed out', 'temporarily
          unavailable'. These share the -MaxRetries budget and the exponential
          backoff with throttling but do NOT arm the cross-call cooldown.

                v0.9.22 payload-size handling exposes three module-scope diagnostics,
                reset at the start of every call:
                    $script:LastResourceGraphPayloadReduced    - $true if ARG rejected a
                                                                                                             page as too large
                    $script:LastResourceGraphPayloadRetryCount - page-size reductions
                    $script:LastResourceGraphEffectivePageSize - final --first value
                ResponsePayloadTooLarge is deterministic request shaping, not a
                transient service failure. The helper retries immediately with half
                the row count and does not consume -MaxRetries or sleep.
        v0.7.84 cross-call coordination adds two more module-scope items:
          $script:ArgCrossCallCooldownUntil               - [DateTime]; until this
                                                            instant the NEXT call
                                                            voluntarily sleeps on
                                                            entry. Set on throttle.
          $script:ArgConsecutiveThrottledCalls            - int counter for
                                                            adaptive cooldown
                                                            duration (capped 5).
          $script:LastResourceGraphCrossCallCooldownSeconds - per-call diagnostic;
                                                            how long THIS call
                                                            slept on entry due
                                                            to the cooldown.
        The cross-call counter decays by 1 on every clean (un-throttled)
        call so the cooldown does not accumulate forever.
    .OUTPUTS
        [object[]] of rows merged across all pages. Empty array if no rows.
        Throws if the CLI returns a non-zero exit code or the response cannot
        be parsed as JSON.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Query,

        [Parameter(Mandatory = $false)]
        [string[]]$SubscriptionId,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 1000)]
        [int]$First = 1000,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 500)]
        [int]$MaxPages = 100,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0, 20)]
        [int]$MaxRetries = 5,

        [Parameter(Mandatory = $false)]
        [ValidateRange(0.1, 60)]
        [double]$RetryBaseSeconds = 1,

        [Parameter(Mandatory = $false)]
        [switch]$DisableCrossCallCooldown
    )

    # v0.7.68: collapse CR/LF and runs of whitespace into single spaces so the
    # query survives az.cmd's CMD argument parser on Windows. See .DESCRIPTION.
    # KQL is whitespace-agnostic in its grammar, so this is semantically inert
    # for every well-formed query. Leading/trailing whitespace is also trimmed
    # to keep the eventual command-line clean.
    #
    # v0.7.70 caller-contract note: callers MUST NOT embed KQL line-comments
    # (`// ...`) inside the here-string that they pass to this helper. KQL
    # line-comments terminate at a newline; once this function collapses the
    # newlines to spaces (above), a `//` runs all the way to end-of-input and
    # silently eats the rest of the query. The ARG parser then fails with
    # "expected | got <EOF>" at the truncation point. We deliberately do NOT
    # strip `//` here because a naive strip would also break URL literals
    # such as `'https://portal.azure.com/...'`. If you need to annotate your
    # KQL, do it in PowerShell `#` comments OUTSIDE the here-string.
    $Query = ($Query -replace '\s+', ' ').Trim()

    # Explicit subscription scope always wins. Otherwise, consult the optional
    # fleet settings file. A missing or fully commented file deliberately leaves
    # the az CLI call unscoped, preserving the pre-v0.9.22 behavior for smaller
    # environments. Management-group scope avoids the CLI/PowerShell implicit
    # first-1,000-subscriptions limit for large estates.
    $subscriptionIds = @($SubscriptionId | ForEach-Object {
        $_ -split ','
    } | ForEach-Object {
        $_.Trim()
    } | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | Select-Object -Unique)
    $managementGroupIds = @()
    if ($subscriptionIds.Count -eq 0) {
        $fleetSettings = Get-AzLocalFleetSettings
        $managementGroupIds = @($fleetSettings.ManagementGroups)
    }
    $script:LastResourceGraphScopeMode = if ($subscriptionIds.Count -gt 0) {
        'ExplicitSubscriptions'
    }
    elseif ($managementGroupIds.Count -gt 0) {
        'ManagementGroups'
    }
    else {
        'ImplicitSubscriptions'
    }
    $script:LastResourceGraphScopeCount = if ($subscriptionIds.Count -gt 0) {
        $subscriptionIds.Count
    }
    else {
        $managementGroupIds.Count
    }

    # v0.9.1: central subscription-exclusion injection. Every ARG query in this
    # module begins with a bare table token ('resources' / 'extensibilityresources')
    # followed by ' | ...'. After the whitespace-collapse above, the query is a
    # single line, so we can inject the exclusion filter immediately AFTER the
    # first table token - before any '| project' that might drop the 'id' column
    # the filter relies on. The exclusion set is resolved at most once per
    # process (see Get-AzLocalExcludedSubscriptionId) and is empty by default, so
    # this is a no-op unless the operator has opted in via
    # AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH or Set-AzLocalExcludedSubscription.
    $excludedSubs = Get-AzLocalExcludedSubscriptionId
    if ($excludedSubs -and @($excludedSubs).Count -gt 0) {
        $exclusionClause = New-AzLocalSubscriptionExclusionKqlClause -SubscriptionId $excludedSubs
        if ($exclusionClause) {
            $firstSpace = $Query.IndexOf(' ')
            if ($firstSpace -lt 0) {
                $Query = '{0} {1}' -f $Query, $exclusionClause
            }
            else {
                $Query = $Query.Substring(0, $firstSpace) + ' ' + $exclusionClause + ' ' + $Query.Substring($firstSpace + 1)
            }
        }
    }

    $queryTable = if ($Query -match '^([A-Za-z][A-Za-z0-9]*)') { $Matches[1] } else { 'Unknown' }
    $queryHashProvider = [System.Security.Cryptography.SHA256]::Create()
    try {
        $queryHashBytes = $queryHashProvider.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Query))
        $queryFingerprint = ([System.BitConverter]::ToString($queryHashBytes) -replace '-', '').Substring(0, 12).ToLowerInvariant()
    }
    finally {
        $queryHashProvider.Dispose()
    }
    Write-Verbose ("ARG query start: table={0}; fingerprint={1}; chars={2}; scope={3}; scopeCount={4}; requestedPageSize={5}; maxPages={6}." -f
        $queryTable, $queryFingerprint, $Query.Length, $script:LastResourceGraphScopeMode,
        $script:LastResourceGraphScopeCount, $First, $MaxPages)

    # Reset the truncation flag at the start of every call so a caller checking
    # $script:LastResourceGraphQueryTruncated sees only THIS call's outcome.
    $script:LastResourceGraphQueryTruncated = $false

    # v0.7.68: throttle diagnostics, reset per call. Tests and pipeline
    # callers can read these flags to detect/report transient ARG throttling.
    $script:LastResourceGraphThrottled = $false
    $script:LastResourceGraphRetryCount = 0

    # v0.8.95: transient network / connection-reset diagnostics, reset per
    # call. Kept separate from the throttle flags so callers can distinguish
    # a connection reset (ConnectionResetError 10054 / "Connection broken")
    # from a rate-limit 429. Set by the per-page retry loop below.
    $script:LastResourceGraphTransientNetwork = $false
    $script:LastResourceGraphTransientRetryCount = 0

    # v0.9.22: response-payload diagnostics. ARG enforces a response byte cap
    # independently of its 1,000-row cap, so a page can be rejected before it
    # returns a skip token. The retry loop below reduces --first for that same
    # logical page and retains the successful size for all subsequent pages.
    $script:LastResourceGraphPayloadReduced = $false
    $script:LastResourceGraphPayloadRetryCount = 0
    $script:LastResourceGraphEffectivePageSize = $First

    # v0.7.84: cross-call ARG cooldown coordination. The per-page retry loop
    # handles bursts WITHIN one call; this block adds coordination ACROSS
    # sequential calls. State is module-scope and initialised lazily on
    # first use. If a previous call set a cooldown window that is still
    # active, sleep out the remainder before issuing the first page request
    # of THIS call. The $DisableCrossCallCooldown switch is provided for
    # unit tests and for callers that have their own rate-limiting upstream.
    if (-not (Test-Path Variable:script:ArgCrossCallCooldownUntil)) {
        $script:ArgCrossCallCooldownUntil = [DateTime]::MinValue
        $script:ArgConsecutiveThrottledCalls = 0
    }
    $script:LastResourceGraphCrossCallCooldownSeconds = 0
    if (-not $DisableCrossCallCooldown.IsPresent) {
        $now = Get-Date
        if ($script:ArgCrossCallCooldownUntil -gt $now) {
            $waitSecs = ($script:ArgCrossCallCooldownUntil - $now).TotalSeconds
            if ($waitSecs -gt 0) {
                Write-Verbose ("Invoke-AzResourceGraphQuery: applying cross-call ARG cooldown ({0:N2}s) due to recent throttling." -f $waitSecs)
                Start-Sleep -Milliseconds ([int]($waitSecs * 1000))
                $script:LastResourceGraphCrossCallCooldownSeconds = $waitSecs
            }
        }
    }

    # Inter-page pause (milliseconds). Starts at 0; ratchets to 1000ms after
    # the first throttle event in this call so subsequent pages don't
    # immediately re-trigger the limiter.
    $interPagePauseMs = 0

    $allRows = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    $pages = 0
    $effectiveFirst = $First
    $authenticationRepairAttempted = $false

    # Force Azure CLI (Python) to write UTF-8 to stdout/stderr regardless of the
    # host console code page. Without this, any non-cp1252 character in an ARG
    # response (resource IDs from non-en-US tenants, localised update names,
    # cluster property strings, etc.) causes the CLI to emit a stderr warning
    # like "WARNING: Unable to encode the output with cp1252 encoding..." which,
    # when captured via 2>&1, gets prepended to the JSON and breaks
    # ConvertFrom-Json. See the matching hardening in Invoke-AzRestJson.ps1
    # (the v0.7.2 cp1252 fix). NOTE: az.cmd launches python with -I (isolated),
    # which causes python to ignore PYTHONIOENCODING / PYTHONUTF8; the env-var
    # assignment is therefore best-effort. The hard fix is the stderr/stdout
    # split below: stderr lines surface as ErrorRecord objects under 2>&1 and
    # we only feed the stdout strings to ConvertFrom-Json.
    $prevPyEncoding = $env:PYTHONIOENCODING
    try {
        $env:PYTHONIOENCODING = 'utf-8'

        while ($true) {
            $pages++
            if ($pages -gt $MaxPages) {
                $script:LastResourceGraphQueryTruncated = $true
                Write-Warning "Invoke-AzResourceGraphQuery: reached MaxPages=$MaxPages safety cap; returning partial result ($($allRows.Count) rows). Check the query for unbounded output or raise -MaxPages. Callers can detect this via `$script:LastResourceGraphQueryTruncated."
                break
            }

            $azArgs = @('graph', 'query', '-q', $Query, '--first', $effectiveFirst, '--only-show-errors')
            if ($subscriptionIds.Count -gt 0) {
                $azArgs += @('--subscriptions')
                $azArgs += $subscriptionIds
            }
            elseif ($managementGroupIds.Count -gt 0) {
                $azArgs += @('--management-groups')
                $azArgs += $managementGroupIds
            }
            if ($skipToken) { $azArgs += @('--skip-token', $skipToken) }

            # v0.7.68: per-page retry loop for transient ARG throttling. ARG
            # returns HTTP 429 / RateLimitingException when the caller exceeds
            # the per-subscription quota; the CLI surfaces those in the error
            # stream. Non-throttle failures (auth, bad KQL, permissions) fall
            # straight through to the throw path - we do NOT retry those.
            $retryAttempt = 0
            $raw = $null
            $exit = $null
            $stderrLines = @()
            $stdoutLines = @()
            while ($true) {
                $raw = & az @azArgs 2>&1
                $exit = $LASTEXITCODE

                # Split merged stdout+stderr by stream type. Stderr lines
                # (Python warnings, deprecation notices, throttle errors)
                # surface as ErrorRecord objects when using 2>&1; stdout
                # lines surface as strings. We only pass the string stream to
                # ConvertFrom-Json so a stray stderr warning can never corrupt
                # JSON.
                $stderrLines = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
                $stdoutLines = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

                if ($exit -eq 0) {
                    break
                }

                $errText = ((($stderrLines + $stdoutLines) | Out-String).Trim())
                $isPayloadTooLarge = $errText -match '(?i)(ResponsePayloadTooLarge|response payload size.*exceed(?:ed|s).*limit|payload.*too large)'
                $isThrottle = $errText -match '(?i)(rate.?limit|throttl|\b429\b|too many requests)'
                $isAuthenticationExpired = $errText -match '(?i)(\b401\b|ExpiredAuthenticationToken|InvalidAuthenticationToken|AuthenticationFailed|AADSTS700024|assertion is not within its valid time range)'

                if ($isAuthenticationExpired -and -not $authenticationRepairAttempted) {
                    $authenticationRepairAttempted = $true
                    if (Repair-AzLocalAzureCliAuthentication) {
                        Write-Warning "Invoke-AzResourceGraphQuery: Azure CLI authentication expired on page $pages; renewed through GitHub OIDC and retrying once."
                        continue
                    }
                }

                # v0.8.95: transient network / connection-reset classifier.
                # ARG calls over the public endpoint occasionally have the TCP
                # connection torn down mid-request by the remote host. The CLI
                # surfaces this as a Python 'ConnectionResetError(10054, ...)'
                # wrapped in azure.core HttpResponseError 'Connection broken'.
                # Worse, the resource-graph extension's own error handler then
                # crashes with "'NoneType' object has no attribute 'error'"
                # (it assumes ex.model is non-null) - so the observable exit-1
                # text is a Python traceback, NOT a clean HTTP status. These
                # are transient and safe to retry. We deliberately keep this
                # SEPARATE from $isThrottle: a connection reset is not a
                # rate-limit signal, so it must NOT arm the cross-call throttle
                # cooldown (that would needlessly slow every subsequent call).
                # Non-transient failures (auth, bad KQL, permissions) do not
                # match either pattern and still fall through to the throw.
                $isTransientNetwork = $errText -match '(?i)(connection (?:reset|aborted|broken|refused)|forcibly closed|\b10054\b|connectionreseterror|remotedisconnected|remote end closed|max retries exceeded|\bECONNRESET\b|\bservice unavailable\b|\b50[234]\b|gateway time|\btimed? ?out\b|temporar(?:ily|y) unavailable|operation timed out)'

                if ($isPayloadTooLarge) {
                    $script:LastResourceGraphPayloadReduced = $true
                    if ($effectiveFirst -le 1) {
                        throw "Azure Resource Graph query failed: one result row exceeds the ARG response payload limit. Project fewer or smaller fields in the query. Details: $(ConvertTo-ScrubbedCliOutput -Text $errText)"
                    }

                    $previousFirst = $effectiveFirst
                    $effectiveFirst = [Math]::Max(1, [int][Math]::Floor($effectiveFirst / 2))
                    $script:LastResourceGraphPayloadRetryCount++
                    $script:LastResourceGraphEffectivePageSize = $effectiveFirst
                    $firstArgIndex = [Array]::IndexOf($azArgs, '--first')
                    $azArgs[$firstArgIndex + 1] = $effectiveFirst
                    Write-Warning ("Invoke-AzResourceGraphQuery: ARG response payload exceeded the service limit on page {0}; reducing --first from {1} to {2} and retrying the same page." -f $pages, $previousFirst, $effectiveFirst)
                    continue
                }

                if (($isThrottle -or $isTransientNetwork) -and $retryAttempt -lt $MaxRetries) {
                    $retryAttempt++

                    if ($isThrottle) {
                        $script:LastResourceGraphThrottled = $true
                        $script:LastResourceGraphRetryCount++

                        # v0.7.84: update cross-call cooldown so the NEXT call to
                        # this helper (whatever the caller) waits this out before
                        # its first page. Adaptive: more consecutive throttled
                        # calls -> longer cooldown, capped at 10s and counter
                        # capped at 5 so cooldown never exceeds the cap.
                        $script:ArgConsecutiveThrottledCalls = [Math]::Min(5, $script:ArgConsecutiveThrottledCalls + 1)
                        $cooldownSecs = [Math]::Min(10.0, $RetryBaseSeconds * [Math]::Pow(2, $script:ArgConsecutiveThrottledCalls - 1))
                        $script:ArgCrossCallCooldownUntil = (Get-Date).AddSeconds($cooldownSecs)
                    }
                    else {
                        # v0.8.95: transient network retry - tracked via its own
                        # diagnostics so callers/tests can distinguish a reset
                        # from a throttle. Does NOT arm the cross-call cooldown.
                        $script:LastResourceGraphTransientNetwork = $true
                        $script:LastResourceGraphTransientRetryCount++
                    }

                    $baseDelay = $RetryBaseSeconds * [Math]::Pow(2, $retryAttempt - 1)
                    # +/-20% jitter, floor 0.5s
                    $jitterFactor = 1 + (Get-Random -Minimum -0.2 -Maximum 0.2)
                    $delay = [Math]::Max(0.5, $baseDelay * $jitterFactor)
                    $reason = if ($isThrottle) { 'throttled' } else { 'transient network error' }
                    Write-Warning ("Invoke-AzResourceGraphQuery: ARG {0} on page {1} (attempt {2}/{3}); sleeping {4:N2}s before retry." -f $reason, $pages, $retryAttempt, $MaxRetries, $delay)
                    Start-Sleep -Seconds $delay
                    # Ratchet the inter-page pause so the NEXT page also waits
                    if ($interPagePauseMs -lt 1000) { $interPagePauseMs = 1000 }
                    continue
                }

                # Either not retryable, or out of retries: fail hard.
                $scrubbedError = ConvertTo-ScrubbedCliOutput -Text $errText
                Write-Verbose ("ARG query failed: table={0}; fingerprint={1}; page={2}; exit={3}; error={4}" -f $queryTable, $queryFingerprint, $pages, $exit, $scrubbedError)
                throw "Azure Resource Graph query failed (exit $exit): $scrubbedError"
            }

            $rawText = ($stdoutLines | Out-String).Trim()
            if ([string]::IsNullOrWhiteSpace($rawText)) {
                break
            }
            try {
                $parsed = $rawText | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                $parseError = "Azure Resource Graph query failed to parse JSON: $($_.Exception.Message); raw: $(ConvertTo-ScrubbedCliOutput -Text $rawText.Substring(0, [Math]::Min(500, $rawText.Length)))"
                Write-Verbose ("ARG query failed: table={0}; fingerprint={1}; page={2}; error={3}" -f $queryTable, $queryFingerprint, $pages, $parseError)
                throw $parseError
            }

            # 'az graph query' returns either a top-level array (older CLI) or an
            # object with .data / .skip_token (newer CLI). Normalise.
            $rows = $null
            $nextToken = $null
            if ($parsed -is [System.Array]) {
                $rows = $parsed
            }
            elseif ($parsed.PSObject.Properties.Name -contains 'data') {
                $rows = $parsed.data
                if ($parsed.PSObject.Properties.Name -contains 'skip_token') { $nextToken = $parsed.skip_token }
                elseif ($parsed.PSObject.Properties.Name -contains 'skipToken') { $nextToken = $parsed.skipToken }
            }
            else {
                # Unknown shape - treat as single-row result
                $rows = @($parsed)
            }

            if ($rows) {
                foreach ($row in $rows) {
                    if ($null -eq $row) { continue }
                    [void]$allRows.Add($row)
                }
            }

            if (-not $nextToken) { break }
            $skipToken = $nextToken
            Write-Verbose "Invoke-AzResourceGraphQuery: fetched page $pages ($($allRows.Count) rows so far); following skip_token for next page."

            # v0.7.68: pause between pages if we have observed throttling in
            # this call, to avoid immediately re-triggering the limiter on
            # the next page request.
            if ($interPagePauseMs -gt 0) {
                Start-Sleep -Milliseconds $interPagePauseMs
            }
        }
    }
    finally {
        $env:PYTHONIOENCODING = $prevPyEncoding
    }

    # v0.7.84: decay the cross-call consecutive-throttle counter on a clean
    # call (no throttle observed during THIS call) so the cooldown window
    # does not accumulate forever in long-running scripts. One clean call
    # decreases the counter by 1; persistent throttling keeps it pinned
    # near the cap of 5 (-> 10s cooldown).
    if (-not $script:LastResourceGraphThrottled -and $script:ArgConsecutiveThrottledCalls -gt 0) {
        $script:ArgConsecutiveThrottledCalls = [Math]::Max(0, $script:ArgConsecutiveThrottledCalls - 1)
    }

    $resultLabel = if ($allRows.Count -eq 0) { 'empty result' } else { 'completed' }
    Write-Verbose ("ARG query {0}: table={1}; fingerprint={2}; rows={3}; pages={4}; effectivePageSize={5}; truncated={6}; throttleRetries={7}; networkRetries={8}; payloadReductions={9}." -f
        $resultLabel, $queryTable, $queryFingerprint, $allRows.Count, $pages,
        $script:LastResourceGraphEffectivePageSize, $script:LastResourceGraphQueryTruncated,
        $script:LastResourceGraphRetryCount, $script:LastResourceGraphTransientRetryCount,
        $script:LastResourceGraphPayloadRetryCount)

    # IMPORTANT: the leading comma is required to preserve array shape so that
    # callers using `$x = Invoke-AzResourceGraphQuery ...` receive an [object[]]
    # for 0, 1, or N rows (not $null, scalar, or unwrapped enumerable).
    # WARNING: callers MUST NOT wrap this call with @( ... ). The `,`-return
    # plus `@()` combination produces a double-wrapped Object[1] containing the
    # inner array, which silently collapses N rows to 1 row of property-arrays.
    # Use `$x = Invoke-AzResourceGraphQuery ...` directly; the result is always
    # an array.
    return , $allRows.ToArray()
}
