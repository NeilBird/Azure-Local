Set-StrictMode -Version Latest

function ConvertTo-ReplicaDurationText {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateRange(0, [double]::MaxValue)][double]$Minutes
    )

    $minuteText = '{0:N1} min' -f $Minutes
    if ($Minutes -lt 1440) { return $minuteText }

    $days = $Minutes / 1440
    $dayUnit = if ([math]::Round($days, 1) -eq 1.0) { 'day' } else { 'days' }
    '{0} ({1:N1} {2})' -f $minuteText, $days, $dayUnit
}

function Get-HyperVEventFloodObservations {
    [OutputType([object[]])]
    param(
        [AllowEmptyCollection()][object[]]$NodeEventContext = @(),
        [int]$EventId = 15268,
        [ValidateRange(1, 1000000)][int]$MinimumCount = 100,
        [ValidateRange(1, 10080)][int]$MinimumSpanMinutes = 30,
        [ValidateRange(1, 1000000)][int]$BurstCount = 10,
        [ValidateRange(1, 1440)][int]$BurstWindowMinutes = 10
    )

    $observations = [System.Collections.Generic.List[object]]::new()
    foreach ($nodeContext in @($NodeEventContext)) {
        if (-not $nodeContext) { continue }
        $node = [string]$nodeContext.Node
        $parsedRows = @($nodeContext.Events | Where-Object { [int]$_.Id -eq $EventId } | ForEach-Object {
            $rawTime = if ($_.PSObject.Properties['Time (UTC)']) { [string]$_.'Time (UTC)' } elseif ($_.PSObject.Properties['Time']) { [string]$_.Time } else { '' }
            $parsedTime = [datetime]::MinValue
            if ([datetime]::TryParse($rawTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedTime)) {
                [pscustomobject]@{ Time = $parsedTime.ToUniversalTime(); Message = if ($_.PSObject.Properties['FullMessage']) { [string]$_.FullMessage } else { [string]$_.Message } }
            }
        } | Sort-Object Time)
        if ($parsedRows.Count -eq 0) { continue }

        $first = [datetime]$parsedRows[0].Time
        $last = [datetime]$parsedRows[-1].Time
        $durationMinutes = [math]::Max(0, ($last - $first).TotalMinutes)
        $burstDetected = $false
        $windowStart = 0
        for ($windowEnd = 0; $windowEnd -lt $parsedRows.Count; $windowEnd++) {
            while ($windowStart -lt $windowEnd -and ([datetime]$parsedRows[$windowEnd].Time - [datetime]$parsedRows[$windowStart].Time).TotalMinutes -gt $BurstWindowMinutes) {
                $windowStart++
            }
            if (($windowEnd - $windowStart + 1) -ge $BurstCount) { $burstDetected = $true; break }
        }
        $sustained = ($parsedRows.Count -ge $MinimumCount -and $durationMinutes -ge $MinimumSpanMinutes)
        if (-not ($sustained -or $burstDetected)) { continue }

        $durationHours = [math]::Max($durationMinutes / 60, 1 / 60)
        [void]$observations.Add([pscustomobject][ordered]@{
            Node = $node
            EventId = $EventId
            Count = $parsedRows.Count
            FirstUtc = $first.ToString('yyyy-MM-dd HH:mm:ssZ')
            LastUtc = $last.ToString('yyyy-MM-dd HH:mm:ssZ')
            DurationMinutes = [math]::Round($durationMinutes, 1)
            AverageRatePerHour = [math]::Round($parsedRows.Count / $durationHours, 1)
            DistinctMessageCount = @($parsedRows | ForEach-Object { $_.Message } | Sort-Object -Unique).Count
            Trigger = if ($sustained) { 'SustainedVolume' } else { 'BurstRate' }
            AffectedNodeCount = 0
        })
    }
    $affectedNodeCount = @($observations | ForEach-Object { $_.Node } | Sort-Object -Unique).Count
    foreach ($observation in $observations) { $observation.AffectedNodeCount = $affectedNodeCount }
    $observations.ToArray()
}

function ConvertTo-VMCheckpointAuditHtml {
    [OutputType([string])]
    param(
        [object[]]$Results,
        [int]$StaleHours,
        [int]$EventLookbackHours,
        [string]$ClusterName,
        [string]$GeneratedUtc,
        [object[]]$DiscoveredVMs,
        [object]$DiscoverySummary,
        [object]$StorageHealth,
        [object[]]$HousekeepingFindings,
        [object[]]$NodeEventContext = @(),
        [bool]$IncludeDiscoveredVMs,
        [bool]$DebugLogAvailable = $false,
        [string]$ScriptVersion,
        [string]$ReportGenerationTime,
        [int]$ClusterNodeCount,
        [int]$ClusterCsvCount
    )

    if ($GeneratedUtc -and $GeneratedUtc -notmatch 'Z$') { $GeneratedUtc = $GeneratedUtc.TrimEnd() + 'Z' }

    function ConvertTo-HtmlText { param([object]$Value) if ($null -eq $Value) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$Value) } }
    function ConvertTo-ByteText {
        param([long]$Bytes)
        if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
        if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
        return ("$Bytes bytes")
    }
    function ConvertTo-HousekeepingSizeText {
        [OutputType([string])]
        param([long]$Bytes)

        if ($Bytes -le 0) { return '0 KB' }
        if ($Bytes -lt 1KB) { return '< 1 KB' }
        return ConvertTo-ByteText $Bytes
    }
    function Get-OptionalPropertyValue {
        param([object]$InputObject, [string]$Name, [object]$DefaultValue = $null)
        if ($InputObject -and $InputObject.PSObject.Properties[$Name]) { return $InputObject.$Name }
        $DefaultValue
    }
    function Get-ReplicaMeasurementEvidence {
        param([object]$Assessment, [string[]]$Breaches)
        if (-not $Assessment) { return '' }
        $parts = @()
        foreach ($breach in @($Breaches)) {
            switch ($breach) {
                'LastReplicationAge' {
                    $ageText = ConvertTo-ReplicaDurationText -Minutes ([double]$Assessment.LastReplicationAgeMinutes)
                    $limitText = ConvertTo-ReplicaDurationText -Minutes ([double]$Assessment.EffectiveMaxAgeMinutes)
                    $parts += ('last replication age {0}; effective limit {1}' -f $ageText, $limitText)
                }
                'PendingBytes' { $parts += ('pending data {0} (effective limit {1})' -f (ConvertTo-ByteText ([long]$Assessment.PendingBytes)), (ConvertTo-ByteText ([long]$Assessment.EffectiveMaxPendingBytes))) }
                'Latency' { $parts += ('average latency {0:N1} sec (effective limit {1:N1} sec)' -f [double]$Assessment.LatencySeconds, [double]$Assessment.EffectiveMaxLatencySeconds) }
                'MissedCount' {
                    $rateText = if ($null -ne $Assessment.MissedRatePercent) { '; {0:N2}% of measured attempts' -f [double]$Assessment.MissedRatePercent } else { '; rate unavailable' }
                    $parts += ('missed replications {0}{1}' -f [long]$Assessment.MissedCount, $rateText)
                }
            }
        }
        $parts -join '; '
    }
    function Get-VerdictRank { param([string]$Rec) switch ($Rec) { 'HOLD STATE' { 0 } 'INVESTIGATE' { 1 } 'OK' { 2 } 'NOT FOUND' { 3 } default { 4 } } }
    function Get-VerdictPill {
        param([string]$Rec)
        switch ($Rec) {
            'HOLD STATE'  { '<span class="pill hold">HOLD STATE</span>' }
            'INVESTIGATE' { '<span class="pill investigate">INVESTIGATE</span>' }
            'OK'          { '<span class="pill ok">OK</span>' }
            'NOT FOUND'   { '<span class="pill err">NOT FOUND</span>' }
            default       { '<span class="pill err">ERROR</span>' }
        }
    }
    # Stable in-page anchor id for a VM (used to link the VM summary table to each VM's detail card).
    # Non-word characters are replaced so the id is always a valid HTML fragment identifier, and the
    # SAME function is used on both ends so the href and the id always match.
    function ConvertTo-Anchor { param([string]$Name) 'vm-' + ([regex]::Replace([string]$Name, '[^A-Za-z0-9_-]', '_')) }

    $rows       = @($Results)
    $countAll   = $rows.Count
    # Distinct cluster nodes that actually owned an audited VM (blank/unknown owners excluded).
    $nodeCount  = @($rows | ForEach-Object { [string]$_.OwningNode } | Where-Object { $_ } | Sort-Object -Unique).Count
    $countHold  = @($rows | Where-Object { $_.Recommendation -eq 'HOLD STATE' }).Count
    $countInv   = @($rows | Where-Object { $_.Recommendation -eq 'INVESTIGATE' }).Count
    $countOk    = @($rows | Where-Object { $_.Recommendation -eq 'OK' }).Count
    $countNotFound = @($rows | Where-Object { $_.Recommendation -eq 'NOT FOUND' }).Count
    $countError = @($rows | Where-Object { $_.Recommendation -eq 'ERROR' }).Count
    $notFoundNames = @($rows | Where-Object { $_.Recommendation -eq 'NOT FOUND' } | ForEach-Object { [string]$_.VMName } | Where-Object { $_ } | Sort-Object -Unique)
    $countIncomplete = $countNotFound + $countError
    $countAssessed = $countAll - $countIncomplete
    $assessedVerb = if ($countAssessed -eq 1) { 'was' } else { 'were' }
    $incompleteVerb = if ($countIncomplete -eq 1) { 'was' } else { 'were' }
    $staleSnapshotTotal = (@($rows | ForEach-Object { [int]$_.StaleCheckpointCount }) | Measure-Object -Sum).Sum
    if (-not $staleSnapshotTotal) { $staleSnapshotTotal = 0 }
    $staleAttachedTotal = (@($rows | ForEach-Object {
        if ($_.ReportData -and $_.ReportData.PSObject.Properties['StaleAttachedLayerCount']) { [int]$_.ReportData.StaleAttachedLayerCount } else { 0 }
    }) | Measure-Object -Sum).Sum
    if (-not $staleAttachedTotal) { $staleAttachedTotal = 0 }
    # Fleet-wide count of orphaned .avhdx files (present in a VM's disk folder(s) but not attached to
    # any chain). Summed from each VM's ReportData.OrphanCount for the summary card and the gated
    # 'orphaned files' recommended-next-step below.
    $orphanTotal = (@($rows | ForEach-Object { if ($_.ReportData) { [int]$_.ReportData.OrphanCount } else { 0 } }) | Measure-Object -Sum).Sum
    if (-not $orphanTotal) { $orphanTotal = 0 }
    # v0.2.17: fleet roll-up of VMs that show EVIDENCE OF A PAST fork-commit rollback - either the
    # historic cross-node scan recovered a fork-commit / merge event around the orphan timestamps
    # (HistoricForkConfirmed) OR several orphans share a common last-write date (HasRollbackFingerprint).
    # A past rollback is NOT a HOLD STATE (it has already materialised - it is a data-RECOVERY case, not a
    # 'do not migrate a dormant risk' case), so it does NOT increment $countHold. It MUST, however, drive
    # the Exec Summary headline - otherwise a run with a CONFIRMED past rollback still reads 'no fork-commit
    # signature ... no Microsoft case warranted', directly contradicting that VM's own CONFIRMED card.
    $pastRollbackConfirmedCount = @($rows | Where-Object { $_.ReportData -and $_.ReportData.HistoricForkConfirmed }).Count
    $pastRollbackAnyCount       = @($rows | Where-Object { $_.ReportData -and ($_.ReportData.HistoricForkConfirmed -or $_.ReportData.HasRollbackFingerprint) }).Count
    # True when at least one audited node still has the Hyper-V-VMMS Analytic channel NOT enabled
    # (per-VM ReportData.AnalyticNodesNeedEnable). Used to show the 'Enable the Analytic channel'
    # recommended step ONLY when it is actually actionable - if it is already enabled everywhere
    # (or the check was skipped), the bullet is omitted.
    $analyticNeedsEnable = (@($rows | ForEach-Object { if ($_.ReportData) { @($_.ReportData.AnalyticNodesNeedEnable) } } | Where-Object { $_ }).Count -gt 0)

    $sb = [System.Text.StringBuilder]::new()
    $head = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hyper-V VM Checkpoint Health Audit</title>
<style>
  :root{
    --bg:#0f172a; --panel:#1e293b; --panel2:#243349; --ink:#e2e8f0; --muted:#94a3b8;
    --line:#334155; --accent:#38bdf8;
    --amber:#f59e0b; --amber-bg:#3a2c07; --red:#ef4444; --red-bg:#3a0d0d;
    --green:#22c55e; --green-bg:#0f2e1a; --high:#fb7185; --high-bg:#3a1420;
  }
  *{box-sizing:border-box}
  body{margin:0;font-family:Segoe UI,-apple-system,Roboto,Helvetica,Arial,sans-serif;
    background:var(--bg);color:var(--ink);line-height:1.55;font-size:15px}
    .wrap{width:100%;max-width:1440px;margin:0 auto;padding:32px 24px 80px}
  header.top{border-bottom:2px solid var(--line);padding-bottom:18px;margin-bottom:28px}
  header.top h1{margin:0 0 6px;font-size:26px;color:#fff}
  .meta{color:var(--muted);font-size:13px}
  .meta b{color:var(--ink)}
  h2{margin:38px 0 14px;font-size:20px;color:#fff;border-left:4px solid var(--accent);padding-left:10px}
  h3{margin:22px 0 8px;font-size:16px;color:#fff}
  p{margin:8px 0}
  a{color:var(--accent)}
  code{background:#0b1220;color:#7dd3fc;padding:1px 6px;border-radius:4px;font-size:13px;
    font-family:Consolas,Monaco,monospace;overflow-wrap:anywhere;word-break:break-word}
  pre{white-space:pre-wrap;word-break:break-word;background:#0b1220;color:#cbd5e1;padding:12px;
    border-radius:8px;font-size:12.5px;line-height:1.4;font-family:Consolas,Monaco,monospace;overflow:auto;max-height:560px}
    .cards{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:14px;margin:8px 0 6px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;
        padding:14px 18px;min-width:0}
    .card.lead{grid-column:1/-1}
  .card .n{font-size:30px;font-weight:700;color:#fff;line-height:1.1}
  .card .l{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.04em;margin-top:4px}
  .card.amber .n{color:var(--amber)} .card.high .n{color:var(--high)} .card.green .n{color:var(--green)}
    .callout{border-radius:10px;padding:14px 18px;margin:16px 0;border:1px solid var(--line);overflow-wrap:anywhere}
    .callout li{min-width:0;overflow-wrap:anywhere}
  .callout.info{background:#0b2436;border-color:#1d4e6b}
  .callout.warn{background:var(--amber-bg);border-color:#7a5b12}
  .callout.high{background:var(--high-bg);border-color:#7a2438}
  .callout.ok{background:var(--green-bg);border-color:#1c6b3a}
  .disclaimer{background:var(--amber-bg);border:1px solid #7a5b12;border-radius:8px;
    padding:10px 16px;margin:0 0 22px;color:#fcd34d;font-size:12.5px;line-height:1.5}
  .disclaimer b{color:#fde68a}
  /* All tables fill the SAME width as the body text and cards (the .wrap container) and never grow
     wider than it. Header cells wrap (white-space:normal) instead of nowrap - a 13-column table with
     nowrap headers forces a minimum width past the container and pokes out past every other section,
     giving a ragged right edge. Wrapping headers + overflow-wrap on cells lets any table collapse to
     the shared 100% width, so tables, text and the whole page line up on one uniform right edge.
     NOTE: use overflow-wrap:break-word (NOT word-break:break-word) on cells - word-break splits words
     mid-character ('Runn ing', 'Siz e'); overflow-wrap only breaks a word when it truly cannot fit, so
     normal words (Running, Size, Created, Parent) stay intact and headers wrap only at spaces. Long
     file paths still break because the 'code' rule carries its own overflow-wrap:anywhere. */
    table{width:100%;max-width:100%;table-layout:auto;border-collapse:collapse;margin:12px 0;font-size:13.5px;
        background:var(--panel);border:1px solid var(--line);border-radius:10px;overflow:hidden}
    .vm-summary-scroll{width:100%;max-width:100%;overflow-x:auto}
    .vm-summary-scroll table{margin:12px 0}
  th,td{padding:9px 11px;text-align:left;border-bottom:1px solid var(--line);vertical-align:top;overflow-wrap:break-word}
  th{background:var(--panel2);color:#cbd5e1;font-weight:600;white-space:normal}
  tbody tr:hover{background:#22304a}
  td.num{text-align:right;font-variant-numeric:tabular-nums}
  /* VM name / node cells must NOT wrap (a wrapped long VM name was unreadable). The global
     'code' rule breaks long words, so override it inside these cells. */
  td.nm{white-space:nowrap}
  td.nm code{white-space:nowrap;word-break:normal;overflow-wrap:normal}
  /* VM-name cell: reserve at least ~16 characters (min-width:16ch) so short / normal names NEVER
     wrap - without it, overflow-wrap:anywhere lets the browser shrink the column to one character and
     wrap even short names. A very long name (e.g. a Kubernetes control-plane VM) still wraps within
     the 300px ceiling so it never forces the whole table wider than the page. */
  td.vmn{min-width:16ch;max-width:300px}
  td.vmn code{white-space:normal;word-break:break-word;overflow-wrap:anywhere}
  /* Housekeeping rows contain both long VM/path identifiers and prose. A fixed, explicit column
      allocation prevents the path from consuming the table and crushing Scope/Review into letters. */
  table.housekeeping{table-layout:fixed}
    table.housekeeping col.hk-category{width:15%}
        table.housekeeping col.hk-scope{width:13%}
        table.housekeeping col.hk-filecol{width:24%}
        table.housekeeping col.hk-size{width:10%}
        table.housekeeping col.hk-observation{width:22%}
        table.housekeeping col.hk-review{width:16%}
  table.housekeeping td{overflow-wrap:anywhere}
  table.housekeeping td code{white-space:normal;word-break:break-word;overflow-wrap:anywhere}
    table.housekeeping .hk-file{margin-bottom:10px;font-weight:700}
    table.housekeeping .hk-observation{margin:0}
    .hk-tools{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:14px;margin:14px 0}
    .hk-tools-header{display:flex;align-items:flex-start;justify-content:space-between;gap:16px}
    .hk-tools-header .muted{margin-top:4px}
    .hk-categories,.hk-actions,.hk-live{display:flex;flex-wrap:wrap;gap:8px 16px;margin:10px 0}
    .hk-categories label{display:flex;align-items:center;gap:7px;color:#cbd5e1;font-size:13px}
    .hk-categories input{accent-color:var(--accent)}
    .hk-actions button,.hk-export,.hk-sort{background:var(--panel2);color:var(--ink);border:1px solid var(--line);border-radius:5px;padding:6px 10px;cursor:pointer}
    .hk-export{flex:0 0 auto;white-space:nowrap}
    .hk-image-option{margin-top:12px;padding-top:10px;border-top:1px solid var(--line)}
    .hk-image-option label{display:flex;align-items:flex-start;gap:7px;color:#fcd34d;font-size:13px;font-weight:600;cursor:pointer}
    .hk-image-option input{margin-top:2px;accent-color:var(--accent)}
    .hk-image-policy{background:#172033;border:1px solid #7a5b12;border-radius:8px;padding:14px;margin:14px 0}
    .hk-image-policy[hidden]{display:none}
    .hk-image-policy textarea{width:100%;min-height:140px;box-sizing:border-box;margin:10px 0;background:#0f172a;color:var(--ink);border:1px solid var(--line);border-radius:5px;padding:10px;font-family:Consolas,monospace;resize:vertical}
    .hk-image-policy-list{margin:10px 0;padding:0;list-style:none}
    .hk-image-policy-list li{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;padding:7px 0;border-bottom:1px solid var(--line)}
    .hk-image-policy-list code{overflow-wrap:anywhere}
    .hk-sort{width:100%;min-height:34px;display:flex;align-items:center;justify-content:space-between;gap:8px;text-align:left;font-weight:600}
    .hk-sort-arrows{flex:0 0 12px;display:grid;grid-template-rows:10px 10px;align-items:center;justify-items:center;color:var(--muted);font-size:10px;line-height:10px}
    .hk-sort[data-direction='ascending'] .hk-sort-up,.hk-sort[data-direction='descending'] .hk-sort-down{color:var(--accent)}
    .hk-filters{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px}
    .hk-filters label{display:flex;flex-direction:column;gap:4px;color:#cbd5e1;font-size:13px}
    .hk-filters input,.hk-filters select{width:100%;box-sizing:border-box;background:#0f172a;color:var(--ink);border:1px solid var(--line);border-radius:5px;padding:7px}
    .hk-live strong{color:#fff}
    .hk-charts{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:14px;margin:14px 0}
    .hk-chart{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:12px;min-height:150px}
    .hk-chart h3{font-size:14px;margin:0 0 8px}.hk-chart svg{width:100%;height:auto;display:block}
    .hk-empty{display:none;padding:18px;text-align:center;background:var(--panel);border:1px solid var(--line);color:var(--muted)}
  .src{display:inline-block;margin-left:6px;padding:1px 7px;border-radius:999px;font-size:10.5px;
    font-weight:600;text-transform:uppercase;letter-spacing:.03em;vertical-align:middle}
  .src.input{background:#12303f;color:#7dd3fc;border:1px solid #1d4e6b}
  .src.discovered{background:#3a2c07;color:#fcd34d;border:1px solid #7a5b12}
    .vmn>a{display:block}
    .vmn>.src{display:block;width:max-content;margin:4px 0 0}
  .pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11.5px;font-weight:700;white-space:nowrap}
  .pill.investigate{background:var(--amber-bg);color:#fcd34d;border:1px solid #7a5b12}
  .pill.high{background:var(--high-bg);color:#fda4af;border:1px solid #7a2438}
  .pill.ok{background:var(--green-bg);color:#86efac;border:1px solid #1c6b3a}
  .pill.hold{background:var(--red-bg);color:#fca5a5;border:1px solid #7a1f1f}
  .pill.err{background:#2a2f3a;color:#cbd5e1;border:1px solid #475569}
    .vm{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:0;margin:16px 0;overflow:hidden}
  .vm.hold{border-color:#7a1f1f;box-shadow:0 0 0 1px #7a1f1f inset}
        .vm>summary{display:flex;align-items:center;gap:10px;list-style:none;padding:14px 20px;background:var(--panel2);user-select:none}
        .vm>summary::-webkit-details-marker{display:none}
        .vm>summary::before{content:'\25B6';color:var(--accent);font-size:12px;line-height:1}
        .vm[open]>summary::before{content:'\25BC'}
        .vm>summary:hover{background:#2b3d59}
        .vm>summary h3{display:flex;align-items:center;flex-wrap:wrap;gap:10px;margin:0}
        .vm>.vm-body{padding:6px 20px 18px}
    .vm-label{color:var(--muted);font-weight:600}
  .kv{display:grid;grid-template-columns:230px 1fr;gap:2px 14px;margin:10px 0}
  .kv div.k{color:var(--muted)}
  ul{margin:8px 0;padding-left:22px} li{margin:3px 0}
  details{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:6px 14px;margin:10px 0}
  summary{cursor:pointer;font-weight:600;color:#cbd5e1}
    details.report-section{background:transparent;border:0;border-radius:0;padding:0;margin:24px 0}
    details.report-section>summary{display:flex;align-items:center;gap:10px;list-style:none;padding:10px 12px;
        background:var(--panel2);border:1px solid var(--line);border-radius:8px;user-select:none}
    details.report-section>summary::-webkit-details-marker{display:none}
    details.report-section>summary::before{content:'\25B6';color:var(--accent);font-size:14px;line-height:1}
    details.report-section[open]>summary::before{content:'\25BC'}
    details.report-section>summary:hover{background:#2b3d59}
    details.report-section>summary h2{margin:0;color:#fff;font-size:22px}
    details.report-section>.report-section-body{padding-top:4px}
  /* Appendix collapsibles: a clear 'Show / Hide' pill button on each heading bar so it is
     obvious the section expands (the bare default disclosure arrow is easy to miss). */
  details.appx{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:0;margin:14px 0;overflow:hidden}
  details.appx>summary{list-style:none;cursor:pointer;padding:14px 18px;font-weight:600;font-size:15.5px;color:#fff;
    background:var(--panel2);display:flex;align-items:center;gap:12px;user-select:none}
  details.appx>summary::-webkit-details-marker{display:none}
  details.appx>summary::before{content:'\25B6 Show';flex:0 0 auto;font-size:11.5px;font-weight:700;letter-spacing:.03em;
    color:#0b1220;background:var(--accent);padding:4px 12px;border-radius:999px;min-width:78px;text-align:center}
  details.appx[open]>summary::before{content:'\25BC Hide';background:var(--amber)}
  details.appx>summary:hover{background:#2b3d59}
  details.appx>summary:hover::before{filter:brightness(1.08)}
  details.appx>.appx-body{padding:4px 18px 18px}
  .muted{color:var(--muted)}
    .scope-label{color:#d97706;font-weight:700}
  /* Semantic inline emphasis (used sparingly): amber for a warning value (stale YES, a non-zero
     orphan / stale count, an oldest-checkpoint age at/over the stale threshold); muted grey for a
     zero count so it recedes; soft-red bold for the single most important imperative inside a HOLD
     callout. Colours are drawn from the existing palette so they stay accessible on the dark theme. */
  .warnval{color:var(--amber);font-weight:600}
  .zero{color:var(--muted)}
  .hot{color:#fca5a5;font-weight:700}
  /* Age cells in the per-VM Checkpoints table AND the Orphaned .avhdx files table both render two
     stacked values ('202.2 h' over '8.4 d'); ckptage keeps each value on ONE line (never split
     mid-value onto '202.2' + 'h'). ckptname caps the checkpoint Name column a little (max-width) so a
     long checkpoint name wraps slightly earlier, freeing the small amount of width the Age column needs. */
  td.ckptage{white-space:nowrap}
  td.ckptname{max-width:300px;overflow-wrap:anywhere}
    .chain-scroll{width:100%;max-width:100%;overflow-x:auto}
    table.chain-evidence{min-width:1040px;margin-bottom:8px}
    table.chain-evidence .chain-group th{background:#17243a;color:var(--text);padding:8px 11px}
    table.chain-evidence .chain-file{width:30%;overflow-wrap:anywhere}
    table.chain-evidence .chain-time{white-space:nowrap}
    .chain-paths{margin:8px 0 12px}
    .chain-paths table{min-width:900px}
        @media(max-width:1440px){table:not(.housekeeping){display:block;overflow-x:auto}}
    @media(max-width:980px){.cards{grid-template-columns:repeat(4,minmax(0,1fr))}}
        @media(max-width:760px){
            table.housekeeping,table.housekeeping tbody,table.housekeeping tr,table.housekeeping td{display:block;width:100%}
            table.housekeeping{border:0;background:transparent}
            table.housekeeping thead{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
            table.housekeeping tr{margin:0 0 14px;border:1px solid var(--line);border-radius:8px;background:var(--panel);overflow:hidden}
            table.housekeeping td{display:grid;grid-template-columns:110px minmax(0,1fr);gap:12px;padding:9px 11px}
            table.housekeeping td::before{content:attr(data-label);color:var(--muted);font-weight:600}
            table.housekeeping td .hk-observation{grid-column:2;min-width:0}
        }
    @media(max-width:640px){
        .cards{grid-template-columns:repeat(2,minmax(0,1fr))}
        .kv{grid-template-columns:minmax(0,1fr);gap:0}
        .kv div{min-width:0}
        .kv div.k{margin-top:8px}
        .hk-tools-header{flex-direction:column}
        .hk-export{width:100%}
    }
    @media(max-width:390px){
        .cards{grid-template-columns:1fr}
        .hk-charts{grid-template-columns:minmax(0,1fr)}
    }
  footer{margin-top:44px;border-top:1px solid var(--line);padding-top:16px;color:var(--muted);font-size:12.5px}
</style>
</head>
<body>
<div class="wrap">
<div class="disclaimer"><b>&#9888; Disclaimer:</b> This tool is EXAMPLE code only - <b>it is NOT a Microsoft-supported product or service offering</b>; provided AS IS with NO warranty of any kind (see the MIT License and <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">README.md</a>). It collects READ-ONLY diagnostic data to render this report - it does NOT determine root cause definitively and does NOT remediate anything. Each VM's status is a data-driven analysis of cluster / VM state, diagnostic events and file-system objects. If you require assistance to interpret any findings, or need guidance prior to any remediation, open a Microsoft Support (CSS) support request (SR) case and act on their advice.</div>
'@
    [void]$sb.Append($head)

    # Header + summary cards.
    $vmWord   = if ($countAll -eq 1) { 'VM' } else { 'VMs' }
    $nodeWord = if ($nodeCount -eq 1) { 'cluster node' } else { 'cluster nodes' }
    $inputCount = @($rows | Where-Object { -not $_.PSObject.Properties['Source'] -or $_.Source -ne 'Discovered' }).Count
    $autoAuditedCount = @($rows | Where-Object { $_.PSObject.Properties['Source'] -and $_.Source -eq 'Discovered' }).Count
    $unauditedDiscoveryCount = if ($null -ne $DiscoveredVMs) { $DiscoveredVMs.Count } else { 0 }
    $unauditedDiscoveryNote = if ($unauditedDiscoveryCount -gt 0) {
        $discoveredVmWord = if ($unauditedDiscoveryCount -eq 1) { 'VM was' } else { 'VMs were' }
        "<br><strong>Audit coverage:</strong> <strong>$unauditedDiscoveryCount additional discovered $discoveredVmWord not audited in this run</strong> and $(if ($unauditedDiscoveryCount -eq 1) { 'is' } else { 'are' }) not represented by the findings or summary totals below."
    } else { '' }
    $discoveryMeta = if ($DiscoverySummary) {
        $capText = if ($null -eq $DiscoverySummary.Cap) { 'None' } else { [string]$DiscoverySummary.Cap }
        "<br>Discovery: <b>$($DiscoverySummary.EligibleCount)</b> eligible &nbsp;&bull;&nbsp; <b>$($DiscoverySummary.AuditedCount)</b> auto-audited &nbsp;&bull;&nbsp; <b>$($DiscoverySummary.DeferredCount)</b> deferred &nbsp;&bull;&nbsp; cap: <b>$(ConvertTo-HtmlText $capText)</b>."
    } else { '' }
    [void]$sb.Append(@"
<header class="top">
  <h1>Hyper-V VM Checkpoint Health Audit</h1>
  <div class="meta">
        Cluster <b>$(ConvertTo-HtmlText $ClusterName)</b> &nbsp;&bull;&nbsp; $countAll processed $vmWord &nbsp;&bull;&nbsp; $countAssessed fully assessed
    &nbsp;&bull;&nbsp; Fleet report finalized (UTC) <b>$(ConvertTo-HtmlText $GeneratedUtc)</b>
    &nbsp;&bull;&nbsp; Module version <b>$(ConvertTo-HtmlText $ScriptVersion)</b>$(if ($ReportGenerationTime) { "&nbsp;&bull;&nbsp; Processed <b>$countAll</b> $vmWord, across <b>$nodeCount</b> owning $nodeWord, in <b>$(ConvertTo-HtmlText $ReportGenerationTime)</b>" })<br>$(if ($ClusterNodeCount -gt 0) { "
    Cluster size: <b>$ClusterNodeCount</b> $(if ($ClusterNodeCount -eq 1) { 'node' } else { 'nodes' }) &nbsp;&bull;&nbsp; <b>$ClusterCsvCount</b> Cluster Shared Volume$(if ($ClusterCsvCount -eq 1) { '' } else { 's' })<br>" })
    Parameters: Stale CheckPoint threshold: $StaleHours h; Diagnostic events lookback: $EventLookbackHours h; Include discovered VMs: $(if ($IncludeDiscoveredVMs) { 'Yes' } else { 'No' }).<br>
    Read-only diagnostic - <b>no changes were made to any VM</b>.$discoveryMeta
  </div>
</header>

<div class="callout info">
    <strong class="scope-label">Report scope:</strong> <strong>$inputCount input + $autoAuditedCount automatically discovered = $countAll processed</strong>; <strong>$countAssessed $assessedVerb fully assessed</strong>; <strong>$countIncomplete $incompleteVerb incomplete</strong>. Eligible discoveries: <strong>$(if ($DiscoverySummary) { [int]$DiscoverySummary.EligibleCount } else { 0 })</strong>; deferred: <strong>$(if ($DiscoverySummary) { [int]$DiscoverySummary.DeferredCount } else { 0 })</strong>. Input VMs that were also discovered were deduplicated and retained as input results. Fleet report finalized (UTC): <strong>$(ConvertTo-HtmlText $GeneratedUtc)</strong>. Its findings should be considered alongside a wider assessment of the cluster, storage, backup solution, workloads, and relevant operational history. It is not a complete cluster health assessment and does not represent the health of VMs that were not fully assessed.$unauditedDiscoveryNote
</div>

<div class="callout info">
    <strong>Event CSV interpretation:</strong> <code>Concern</code> is retained as a compatibility field; the adjacent Boolean <code>CollectedAsConcern</code> states the same broad collection/catalog decision unambiguously. <code>VerdictDriver</code>, <code>EventClassification</code>, <code>RecoveryDisposition</code>, and <code>DispositionReason</code> are authoritative for how each row affected the result. A low-signal row can therefore show <code>Concern=YES</code> and <code>CollectedAsConcern=True</code> while correctly showing <code>VerdictDriver=False</code> and <code>RecoveryDisposition=ContextOnly</code>.
</div>

<div class="cards">
    <div class="card lead"><div class="n">$countAll</div><div class="l">$vmWord processed ($countAssessed fully assessed)</div></div>
  <div class="card high"><div class="n">$countHold</div><div class="l">Hold state</div></div>
  <div class="card amber"><div class="n">$countInv</div><div class="l">Investigate</div></div>
  <div class="card green"><div class="n">$countOk</div><div class="l">OK</div></div>
    <div class="card amber"><div class="n">$countIncomplete</div><div class="l">Incomplete</div></div>
    <div class="card amber"><div class="n">$staleAttachedTotal</div><div class="l">Stale attached AVHDX layers</div></div>
    <div class="card amber"><div class="n">$staleSnapshotTotal</div><div class="l">Stale snapshots</div></div>
  <div class="card amber"><div class="n">$orphanTotal</div><div class="l">Orphaned .avhdx</div></div>
</div>
"@)

    if ($countIncomplete -gt 0) {
        [void]$sb.Append(@"
<div class="callout warn">
    <strong>Assessment incomplete:</strong> $countIncomplete VM(s) were not fully assessed ($countNotFound not found; $countError collection error). For <strong>NOT FOUND</strong>, verify the VM name and cluster. For <strong>ERROR</strong>, review permissions, connectivity, and the debug log, then rerun the audit. Do not treat these VMs as healthy based on this report.$(if ($notFoundNames.Count -gt 0) { " Input VM name(s) not found on this cluster: <strong>$(ConvertTo-HtmlText ($notFoundNames -join ', '))</strong>." } else { '' })
</div>
"@)
                if ($DebugLogAvailable) {
                        [void]$sb.Append(@"
<div class="callout warn">
    <strong>Unrecovered collection errors were logged:</strong> review the run folder's <code>_debug_log_*.txt</code> for exact failure context. It can contain sensitive operational data. For usage guidance, see <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">the README</a>; to report a reproducible failure, use <a href="https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback" target="_blank" rel="noopener noreferrer">feedback / GitHub issues</a>.
</div>
"@)
                }
    }

    $eventFloodObservations = @(Get-HyperVEventFloodObservations -NodeEventContext $NodeEventContext)
    $eventFloodHtml = ''
    if ($eventFloodObservations.Count -gt 0) {
        $affectedNodeCount = [int]$eventFloodObservations[0].AffectedNodeCount
        $eventFloodBuilder = [System.Text.StringBuilder]::new()
        [void]$eventFloodBuilder.Append("<div class='callout warn' id='cluster-low-signal-events'><strong>Cluster-level low-signal event observation:</strong> Event <code>15268</code> remains low-signal for individual VM checkpoint verdicts, but repeated <code>Failed to get the disk information</code> errors were observed at cluster scale on <strong>$affectedNodeCount node(s)</strong>. Review storage, VMMS, and backup activity for the affected nodes. This observation is event-driven only; it does not attribute the errors to every VM and does not establish checkpoint-chain corruption.<ul>")
        foreach ($observation in $eventFloodObservations) {
            $nodeCsvName = '_NodeEvents_{0}_*.csv' -f (([string]$observation.Node) -replace '[^\w.\-]', '_')
            [void]$eventFloodBuilder.Append(("<li><code>{0}</code>: {1:N0} event(s), {2} to {3}, {4:N1} minutes, approximately {5:N1}/hour, {6} distinct message signature(s). Evidence: <code>{7}</code>.</li>" -f
                (ConvertTo-HtmlText $observation.Node), [int]$observation.Count,
                (ConvertTo-HtmlText $observation.FirstUtc), (ConvertTo-HtmlText $observation.LastUtc),
                [double]$observation.DurationMinutes, [double]$observation.AverageRatePerHour,
                [int]$observation.DistinctMessageCount, (ConvertTo-HtmlText $nodeCsvName)))
        }
        [void]$eventFloodBuilder.Append('</ul></div>')
        $eventFloodHtml = $eventFloodBuilder.ToString()
    }

    # Shared fleet evidence used by mixed HOLD / historic-recovery / INVESTIGATE headlines.
    $replicaProductConcernCount = @($rows | Where-Object {
        $_.ReportData -and $_.ReportData.PSObject.Properties['ReplAssessment'] -and $_.ReportData.ReplAssessment -and
        $_.ReportData.ReplAssessment.ProductSeverity -in @('Critical', 'Warning', 'Unknown')
    }).Count
    $replicaMeasurementConcernCount = @($rows | Where-Object {
        $_.ReportData -and $_.ReportData.PSObject.Properties['ReplAssessment'] -and $_.ReportData.ReplAssessment -and
        $_.ReportData.ReplAssessment.MeasurementStatus -eq 'Concern'
    }).Count
    $replicaAdvisoryCount = @($rows | Where-Object { $_.ReportData -and $_.ReportData.PSObject.Properties['ReplAdvisory'] -and $_.ReportData.ReplAdvisory }).Count
    $hrlConcernCount = @($rows | Where-Object {
        $_.ReportData -and $_.ReportData.PSObject.Properties['HrlAssessment'] -and $_.ReportData.HrlAssessment -and $_.ReportData.HrlAssessment.IsConcern
    }).Count
    $investigateEvidence = @()
    if ($staleAttachedTotal -gt 0) { $investigateEvidence += "$staleAttachedTotal stale attached AVHDX layer(s)" }
    if ($staleSnapshotTotal -gt 0) { $investigateEvidence += "$staleSnapshotTotal stale named snapshot(s)" }
    if ($orphanTotal -gt 0) { $investigateEvidence += "$orphanTotal orphaned .avhdx file(s)" }
    if ($replicaProductConcernCount -gt 0) { $investigateEvidence += "$replicaProductConcernCount VM(s) with Replica product-health/state concerns" }
    if ($replicaMeasurementConcernCount -gt 0) { $investigateEvidence += "$replicaMeasurementConcernCount VM(s) with material Replica measurement concerns" }
    if ($hrlConcernCount -gt 0) { $investigateEvidence += "$hrlConcernCount VM(s) with cadence-breaching HRL evidence" }
    if ($replicaAdvisoryCount -gt 0) { $investigateEvidence += "$replicaAdvisoryCount VM(s) with Replica measurement advisories" }
    $investigateEvidenceText = if ($investigateEvidence.Count -gt 0) { $investigateEvidence -join ', ' } else { 'see the per-VM findings below' }

    $housekeepingRows = @($HousekeepingFindings | Where-Object { $null -ne $_ })
    $housekeepingFindingsCount = $housekeepingRows.Count
    $housekeepingRoots = @($housekeepingRows | ForEach-Object { if ($_.PSObject.Properties['CsvRoot']) { [string]$_.CsvRoot } } | Where-Object { $_ } | Sort-Object -Unique)
    $seenHousekeepingPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    [long]$housekeepingTotalBytes = 0
    foreach ($finding in $housekeepingRows) {
        if ($finding.PSObject.Properties['FullName'] -and $finding.FullName -and $seenHousekeepingPaths.Add([string]$finding.FullName)) {
            $housekeepingTotalBytes += [long]$finding.Length
        }
    }
    $housekeepingTotalText = ConvertTo-HousekeepingSizeText $housekeepingTotalBytes
    $housekeepingExecSummaryLi = "<li><strong><a href='#housekeeping'>Cluster storage (VHD and checkpoint) housekeeping audit results:</a></strong> identified <strong>$housekeepingFindingsCount</strong> item(s), with a total unique-file storage size of <strong>$(ConvertTo-HtmlText $housekeepingTotalText)</strong>, across <strong>$($housekeepingRoots.Count)</strong> Cluster Shared Volume(s). <strong>Action:</strong> review this section to determine whether the files are required VM images, inconsistent VM VHD paths, and/or unrequired orphaned objects.</li>"

    $storageDegraded = ($StorageHealth -and (@('Degraded', 'Active storage jobs') -contains "$($StorageHealth.Summary)"))
    $storageFaults = @()
    $unhealthySubsystems = @()
    if ($StorageHealth) {
        $storageFaults = @(Get-OptionalPropertyValue -InputObject $StorageHealth -Name 'HealthFaults' -DefaultValue @())
        $unhealthySubsystems = @($StorageHealth.Subsystem | Where-Object { "$($_.Health)" -eq 'Unhealthy' })
    }
    $storageFaultCollectionStatus = if ($StorageHealth) { [string](Get-OptionalPropertyValue -InputObject $StorageHealth -Name 'HealthFaultCollectionStatus' -DefaultValue 'Not collected') } else { 'Not collected' }
    $storageFaultCollection = if ($StorageHealth) { Get-OptionalPropertyValue -InputObject $StorageHealth -Name 'HealthFaultCollection' -DefaultValue $null } else { $null }
    $storageReasonText = if ($storageFaults.Count -gt 0) {
        $faultReasons = @($storageFaults | ForEach-Object {
            $reason = [string](Get-OptionalPropertyValue -InputObject $_ -Name 'Reason' -DefaultValue '')
            if ($reason) { ConvertTo-HtmlText $reason } else { 'unspecified storage Health Service fault' }
        } | Sort-Object -Unique)
        "$($storageFaults.Count) active storage Health Service fault(s): $($faultReasons -join '; ')"
    } elseif ($unhealthySubsystems.Count -gt 0) {
        "$($unhealthySubsystems.Count) storage subsystem(s) report Unhealthy, but no active Health Service fault detail was returned (collection status: $(ConvertTo-HtmlText $storageFaultCollectionStatus))"
    } elseif ($StorageHealth -and @($StorageHealth.StorageJobs).Count -gt 0) {
        "$(@($StorageHealth.StorageJobs).Count) active storage job(s)"
    } else {
        'the lightweight storage snapshot reported a non-healthy state'
    }
    $storageExecSummaryLi = if ($storageDegraded) {
        "<li><strong><a href='#cluster-storage-health'>Cluster storage requires investigation:</a></strong> $storageReasonText. See Cluster storage health and the existing CSS Storage Diagnostic guidance below.</li>"
    } else { '' }
    $eventFloodExecSummaryLi = if ($eventFloodObservations.Count -gt 0) {
        "<li><strong><a href='#cluster-low-signal-events'>Cluster-level low-signal event observation:</a></strong> repeated event <code>15268</code> activity was observed on <strong>$([int]$eventFloodObservations[0].AffectedNodeCount) node(s)</strong>. This is event-driven cluster context only; it does not change individual VM verdicts. See the bottom of Cluster storage health.</li>"
    } else { '' }

    # Adaptive headline.
    if ($countHold -gt 0) {
        [void]$sb.Append(@"
<div class="callout high">
  <strong>Exec Summary - action required:</strong> $countHold VM(s) are in <strong>HOLD STATE</strong> - a 'checkpoint fork-commit / merge-failure' signature AND unmerged differencing disk(s) are present together.
  <ul>
    <li><span class="hot">Do NOT live/quick/storage-migrate or restart</span> those VMs until the differencing chain has been validated (and merged if required).</li>
    <li>Engage Microsoft Support (CSS) and/or your backup vendor for those VMs.</li>
    <li>See the per-VM detail below for which VMs are affected and why.</li>
    <li><strong>$countInv additional VM(s) are flagged INVESTIGATE:</strong> these require separate operations / backup-team triage and are not included in the HOLD count.</li>
    <li><strong>Fleet-wide checkpoint / replication evidence:</strong> $investigateEvidenceText. See Recommended next steps and the per-VM detail below.</li>
    $housekeepingExecSummaryLi
    $storageExecSummaryLi
    $eventFloodExecSummaryLi
  </ul>
</div>
"@)
    } elseif ($pastRollbackAnyCount -gt 0) {
        # v0.2.17: a historic rollback is materialised, not a dormant HOLD risk - so the headline is distinct
        # from HOLD STATE. It is still a data-RECOVERY escalation, so it must NOT read 'no case warranted'.
        $confPhrase = if ($pastRollbackConfirmedCount -gt 0) {
            "$pastRollbackConfirmedCount CONFIRMED via fork-commit / merge events recovered by the historic cross-node scan"
        } else {
            'identified by an orphaned .avhdx rollback fingerprint (several files frozen at a common date)'
        }
                $additionalInvestigateCount = [math]::Max(0, $countInv - $pastRollbackAnyCount)
        [void]$sb.Append(@"
<div class="callout high">
    <strong>Exec Summary - data recovery:</strong> $pastRollbackAnyCount VM(s) show evidence of a <strong>historic 'checkpoint fork-commit / merge-failure' rollback</strong> ($confPhrase).
  <ul>
    <li>The rollback has already occurred. The priority is DATA RECOVERY, not only preventing a future migration or restart.</li>
    <li>Do NOT delete the orphaned <code>.avhdx</code> files - they may hold un-recovered data.</li>
    <li>Validate each affected VM's current differencing chain before any live/quick/storage migration or restart.</li>
    <li>Engage Microsoft Support (CSS) and/or your backup vendor for those VMs. See each VM's detail and the "Historic event correlation" below.</li>
        <li><strong>$countInv VM(s) are flagged INVESTIGATE in total:</strong> $pastRollbackAnyCount historic rollback recovery case(s) above and $additionalInvestigateCount additional VM(s) requiring operations / backup-team triage.</li>
        <li><strong>Fleet-wide INVESTIGATE evidence:</strong> $investigateEvidenceText. See Recommended next steps and the per-VM detail below.</li>
    $housekeepingExecSummaryLi
$storageExecSummaryLi
$eventFloodExecSummaryLi
  </ul>
</div>
"@)
    } else {
        $execTriageLi = if ($countInv -gt 0) {
            "$countInv VM(s) are flagged INVESTIGATE for the operations / backup team to triage first (see Recommended next steps below) - findings: $investigateEvidenceText."
        } elseif ($investigateEvidence.Count -gt 0) {
            "$investigateEvidenceText were found - for the operations / backup team to triage first (see Recommended next steps below)."
        } else {
            'No stale attached AVHDX layers, stale named snapshots, or orphaned .avhdx files were found.'
        }
                if ($countInv -gt 0) {
                        [void]$sb.Append(@"
<div class="callout ok">
  <strong>Exec Summary:</strong> <strong>Cluster / backup administrators should INVESTIGATE the items listed below. No Microsoft Support (CSS) case is warranted, unless additional guidance is required.</strong>
  <ul>
    <li>No VM shows the '<em>checkpoint fork-commit / merge-failure</em>' signature (event <code>3216</code> or an HRESULT such as <code>0x80048102</code>).</li>
    <li>No VM is in a HOLD STATE, and no historic rollback evidence was found.</li>
    <li>$execTriageLi</li>
    $housekeepingExecSummaryLi
    $storageExecSummaryLi
    $eventFloodExecSummaryLi
  </ul>
</div>
"@)
                } elseif ($countIncomplete -gt 0) {
                        [void]$sb.Append(@"
<div class="callout warn">
    <strong>Exec Summary - assessment incomplete:</strong> no fully assessed VM is in HOLD STATE or INVESTIGATE, but $countIncomplete VM(s) could not be fully assessed ($countNotFound not found; $countError error).
    <ul>
        <li>Do not treat the incomplete VM(s) as healthy based on this report.</li>
        <li>Resolve the NOT FOUND / ERROR items in Recommended next steps, then re-run the audit.</li>
        <li>$execTriageLi</li>
    $housekeepingExecSummaryLi
    $storageExecSummaryLi
    $eventFloodExecSummaryLi
    </ul>
</div>
"@)
                } else {
                        $housekeepingSummary = if ($null -ne $HousekeepingFindings -and $HousekeepingFindings.Count -gt 0) {
                                'Review the separate cluster / storage housekeeping observations below; they do not change the VM health verdict and do not authorize file modification.'
                        } else {
                                'No cluster / storage housekeeping observations were produced by the checks performed in this run.'
                        }
                        [void]$sb.Append(@"
<div class="callout ok">
    <strong>Exec Summary - no VM health action required:</strong> no VM is in HOLD STATE or INVESTIGATE, and no historic rollback evidence was found.
    <ul>
        <li>No VM shows the '<em>checkpoint fork-commit / merge-failure</em>' signature (event <code>3216</code> or an HRESULT such as <code>0x80048102</code>).</li>
        <li>$execTriageLi</li>
    $housekeepingExecSummaryLi
    $storageExecSummaryLi
    $eventFloodExecSummaryLi
    </ul>
</div>
"@)
                }
    }

    # Recommended next steps (placed up-front, right after the summary callouts). Every bullet is
    # CONTEXT-GATED so the list shows only advice that is actually actionable for this run:
    #   - the two stale-checkpoint bullets appear only when >=1 stale checkpoint was found;
    #   - the INVESTIGATE bullet only when >=1 VM is INVESTIGATE ($countInv) AND there are NO stale
    #     checkpoints ($staleTotal -eq 0) - i.e. the INVESTIGATE driver is an unhealthy VSS writer or
    #     VM-attributed concern events rather than a stale checkpoint. When a stale checkpoint IS the
    #     driver, the two stale-checkpoint bullets above already cover it, so this bullet is suppressed
    #     to avoid duplicate 'backup team first' advice;
    #   - the Analytic-channel bullet only when a node still needs it enabled ($analyticNeedsEnable);
    #   - the storage bullet only when the storage snapshot is Degraded / has active jobs;
    #   - the HOLD STATE bullet only when >=1 VM is in HOLD STATE.
    # When none of those apply a single 'no action required' line is shown instead. The
    # 'Open a Microsoft Support case' escalation line is a fleet roll-up shown ONLY when >=1 VM is in
    # HOLD STATE (a fork-commit signature is present somewhere) - on INVESTIGATE-only / clean runs it
    # is omitted, because with no fork-commit signature the next step is backup-team triage, not a case.
    # NOTE: $countInv is included in $anyContextualStep so an INVESTIGATE-only run (e.g. VSS-writer /
    # concern-event driven with zero stale checkpoints) never falls through to 'No action required'.
    # v0.2.14 fleet roll-ups for the new gated bullets.
    $rollbackVMs          = @($rows | Where-Object { $_.ReportData -and $_.ReportData.HasRollbackFingerprint })
    $historicConfirmedVMs = @($rows | Where-Object { $_.ReportData -and $_.ReportData.HistoricForkConfirmed })
    $replicaProductConcernVMs = @($rows | Where-Object {
        $_.ReportData -and $_.ReportData.PSObject.Properties['ReplAssessment'] -and $_.ReportData.ReplAssessment -and
        $_.ReportData.ReplAssessment.ProductSeverity -in @('Critical', 'Warning', 'Unknown')
    })
    $replicaMeasurementConcernVMs = @($rows | Where-Object {
        $_.ReportData -and $_.ReportData.PSObject.Properties['ReplAssessment'] -and $_.ReportData.ReplAssessment -and
        $_.ReportData.ReplAssessment.MeasurementStatus -eq 'Concern'
    })
    $replicaAdvisoryVMs = @($rows | Where-Object { $_.ReportData -and $_.ReportData.PSObject.Properties['ReplAdvisory'] -and $_.ReportData.ReplAdvisory })
    $hrlConcernVMs = @($rows | Where-Object {
        $_.ReportData -and $_.ReportData.PSObject.Properties['HrlAssessment'] -and $_.ReportData.HrlAssessment -and
        $_.ReportData.HrlAssessment.IsConcern
    })
    # v0.2.17: proactive pre-migration roll-ups from the active-checkpoint historic look-back.
    $activeCkptForkVMs    = @($rows | Where-Object { $_.ReportData -and $_.ReportData.ActiveCkptForkConfirmed })
    $cannotConfirmVMs     = @($rows | Where-Object { $_.ReportData -and $_.ReportData.CannotConfirmMigrationSafe })
    # v0.2.17: VMs flagged INVESTIGATE whose ONLY driver is HIGH-signal VM-attributed event(s) - no stale
    # checkpoint, no orphan, no rollback fingerprint, no unhealthy replica, no unhealthy VSS writer. In the
    # field these are the VMs that previously fell through with NO actionable step: the generic INVESTIGATE
    # bullet was gated `-and $staleTotal -eq 0`, so any run that ALSO had a stale checkpoint suppressed it
    # entirely and these VMs got only the per-card 'triage first' note. They now get their own always-on
    # bullet (below) with concrete steps, regardless of whether stale checkpoints exist elsewhere.
    $eventsOnlyInvVMs = @($rows | Where-Object {
            $_.Recommendation -eq 'INVESTIGATE' -and $_.ReportData -and
            ([int]$_.ReportData.VmEscalatingConcernCount -gt 0) -and
            ([int]$_.ReportData.StaleCheckpointCount -eq 0) -and
            (-not $_.ReportData.PSObject.Properties['StaleAttachedLayerCount'] -or ([int]$_.ReportData.StaleAttachedLayerCount -eq 0)) -and
            ([int]$_.ReportData.OrphanCount -eq 0) -and
            (-not $_.ReportData.HasRollbackFingerprint) -and
            (-not $_.ReportData.ReplUnhealthy) -and
            ($_.ReportData.VssState -ne 'Unhealthy')
        })
    # v0.2.17: VM counts (not just item counts) for the stale-checkpoint and orphan next-step headlines,
    # so each step reads "<N item(s)> across <M VM(s)>" for at-a-glance scanning.
    $staleSnapshotVMsCount = @($rows | Where-Object { $_.ReportData -and ([int]$_.ReportData.StaleCheckpointCount -gt 0) }).Count
    $staleAttachedVMsCount = @($rows | Where-Object {
        $_.ReportData -and $_.ReportData.PSObject.Properties['StaleAttachedLayerCount'] -and ([int]$_.ReportData.StaleAttachedLayerCount -gt 0)
    }).Count
    $orphanVMsCount = @($rows | Where-Object { $_.ReportData -and ([int]$_.ReportData.OrphanCount -gt 0) }).Count
    $anyContextualStep = ($staleAttachedTotal -gt 0) -or ($staleSnapshotTotal -gt 0) -or ($countInv -gt 0) -or $analyticNeedsEnable -or $storageDegraded -or ($countHold -gt 0) -or ($orphanTotal -gt 0) -or ($rollbackVMs.Count -gt 0) -or ($replicaProductConcernVMs.Count -gt 0) -or ($replicaMeasurementConcernVMs.Count -gt 0) -or ($replicaAdvisoryVMs.Count -gt 0) -or ($hrlConcernVMs.Count -gt 0) -or ($activeCkptForkVMs.Count -gt 0) -or ($cannotConfirmVMs.Count -gt 0)
    [void]$sb.Append(@'
<details class="report-section" id="recommended-next-steps" open>
<summary><h2>Recommended next steps</h2></summary>
<div class="report-section-body">
<ol>
'@)
    if (-not $anyContextualStep) {
        $cleanNextStep = if ($null -ne $HousekeepingFindings -and $HousekeepingFindings.Count -gt 0) {
            '<li><strong>No VM-health action required from this audit:</strong> no stale attached AVHDX layers or named snapshots, no HOLD STATE or INVESTIGATE VMs, and no storage-layer disruption. Review the separate cluster / storage housekeeping observations before making any storage-layout changes.</li>'
        } else {
            '<li><strong>No action required from this audit:</strong> no stale attached AVHDX layers or named snapshots, no HOLD STATE or INVESTIGATE VMs, no storage-layer disruption, and no cluster / storage housekeeping observations were produced. Keep this report for your records.</li>'
        }
        [void]$sb.Append("    $cleanNextStep`r`n")
    }
    if ($historicConfirmedVMs.Count -gt 0) {
        $confirmedNames = (@($historicConfirmedVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>PRIORITY - CONFIRMED historic rollback ({0} VM(s)):</strong> recovered historic fork-commit / merge-failure events confirm this scenario for {1}. Orphaned <code>.avhdx</code> files may contain data that is no longer accessible to the VM. Do NOT remove them. Engage Microsoft Support (CSS) or your backup vendor for recovery guidance.</li>
'@ -f $historicConfirmedVMs.Count, $confirmedNames))
    }
    $possibleRollbackVMs = @($rollbackVMs | Where-Object { -not $_.ReportData.HistoricForkConfirmed })
    if ($possibleRollbackVMs.Count -gt 0) {
        $possibleNames = (@($possibleRollbackVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>PRIORITY - possible historic rollback ({0} VM(s)):</strong> {1} have a group of orphaned <code>.avhdx</code> files with matching dates. This may indicate that the disks already rolled back to their base disks and left the checkpoint layers unattached. Those files may contain data that is no longer accessible to the VM. Do NOT remove them. Engage Microsoft Support (CSS) or your backup vendor for recovery guidance. The original events may be older than the {2}h lookback. <strong>Rerun with a larger window</strong> (for example, <code>-EventLookbackHours 720</code>) and review each VM's "Historic event correlation" detail.</li>
'@ -f $possibleRollbackVMs.Count, $possibleNames, $EventLookbackHours))
    }
    if ($replicaProductConcernVMs.Count -gt 0) {
        $rcNames = (@($replicaProductConcernVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
  <li><strong>Hyper-V Replica product health/state needs attention ({0} VM(s)):</strong> {1} report Warning, Critical, an abnormal state, or unavailable required relationship evidence. Review <code>Get-VMReplication</code> health details and the relationship state; this is separate from checkpoint-chain evidence. The audit is read-only and does not start, repair, resume, or resynchronize replication.</li>
'@ -f $replicaProductConcernVMs.Count, $rcNames))
    }
    if ($replicaMeasurementConcernVMs.Count -gt 0) {
        $rmNames = (@($replicaMeasurementConcernVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>Hyper-V Replica measurements need attention ({0} VM(s)):</strong> the measured replication age, backlog, latency, or missed cycles for {1} significantly exceed the limits calculated for each VM's replication frequency. Review the observed values, calculated limits, monitoring window, and recent network or storage demand in each VM card. Rerun after the next monitoring interval. Contact the Replica owner if the condition continues or product health becomes Warning or Critical.</li>
'@ -f $replicaMeasurementConcernVMs.Count, $rmNames))
    }
    if ($replicaAdvisoryVMs.Count -gt 0) {
        $raNames = (@($replicaAdvisoryVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>Hyper-V Replica measurement advisory ({0} VM(s), no verdict escalation by itself):</strong> {1} report product health <code>Normal</code>, but one measurement is outside its expected range. Review the per-VM values and rerun after the next monitoring interval. Investigate if the condition continues, another Replica signal confirms a concern, or product health or state becomes worse.</li>
'@ -f $replicaAdvisoryVMs.Count, $raNames))
    }
    if ($hrlConcernVMs.Count -gt 0) {
        $hrlNames = (@($hrlConcernVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>Hyper-V Replica log cadence needs attention ({0} VM(s)):</strong> the <code>.hrl</code> files for {1} exceed the age limit calculated from each VM's replication frequency. Separate Replica health or measurement evidence also confirms a concern. Review the HRL ages and Replica evidence, confirm replication progress and storage availability on both partners, and rerun after the next monitoring interval. Do not delete or modify <code>.hrl</code> files based on this report.</li>
'@ -f $hrlConcernVMs.Count, $hrlNames))
    }
    if ($activeCkptForkVMs.Count -gt 0) {
        $acfNames = (@($activeCkptForkVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>HOLD STATE - fork-commit recorded at an active checkpoint's creation ({0} VM(s)):</strong> {1} have an ACTIVE (still-attached) checkpoint created before the {2}h event window. The historic cross-node scan detected a 'fork-commit / merge-failure' event around that creation time. The chain may be inconsistent while the VM continues to run. Do NOT perform a live migration, quick migration, storage migration, or restart until the differencing chain is validated and, if required, merged. Engage Microsoft Support (CSS) or your backup vendor. This warning identifies a dormant risk; the report has not detected that data loss has occurred.</li>
'@ -f $activeCkptForkVMs.Count, $acfNames, $EventLookbackHours))
    }
    if ($cannotConfirmVMs.Count -gt 0) {
        $ccNames = (@($cannotConfirmVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>PRE-MIGRATION - safety could not be verified ({0} VM(s)):</strong> {1} have an ACTIVE checkpoint created before the normal event lookback, and required Worker/VMMS logs are incomplete for that time. The missing logs may contain evidence that this audit could not detect. Validate the differencing chain before any live migration, quick migration, storage migration, or restart. See each VM's detail for the incomplete node and channel scopes.</li>
'@ -f $cannotConfirmVMs.Count, $ccNames))
    }
    if ($notFoundNames.Count -gt 0) {
        $notFoundDisplay = ConvertTo-HtmlText ($notFoundNames -join ', ')
        $notFoundArguments = ConvertTo-HtmlText ((@($notFoundNames | ForEach-Object { "'{0}'" -f $_ }) -join ','))
        [void]$sb.Append((@'
  <li><strong>INVESTIGATE - input VM name(s) not found on this cluster ({0}):</strong> {1}. Check that each VM name is correct (including possible typing or naming differences), confirm that the VM belongs to this cluster, then re-run the audit with the confirmed names: <code>Get-HyperVVMCheckpointHealth -VMName {2} -OutputPath &lt;folder&gt;</code>.</li>
'@ -f $notFoundNames.Count, $notFoundDisplay, $notFoundArguments))
    }
        if ($staleAttachedTotal -gt 0) {
                [void]$sb.Append((@'
    <li><strong>INVESTIGATE - {0} stale attached AVHDX layer(s) across {1} VM(s):</strong> these are readable layers in the active disk chains, regardless of whether <code>Get-VMSnapshot</code> exposes a matching named snapshot. Validate the chain and backup job before migration/restart or any merge/removal action.</li>
'@ -f $staleAttachedTotal, $staleAttachedVMsCount))
        }
        if ($staleSnapshotTotal -gt 0) {
        [void]$sb.Append((@'
    <li><strong>INVESTIGATE - {0} stale named snapshot(s) across {1} VM(s):</strong> ask the backup team to review each stale snapshot before taking action. Check the backup product's recent job history and confirm whether the snapshot is expected or was left by a failed or incomplete backup. The VM owner and backup administrator are responsible for approving any remediation.</li>
'@ -f $staleSnapshotTotal, $staleSnapshotVMsCount))
    }
    if ($eventsOnlyInvVMs.Count -gt 0) {
        $eoNames = (@($eventsOnlyInvVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>INVESTIGATE - VM-attributed checkpoint or merge operations reported failures ({0} VM(s)):</strong> {1} have no current checkpoint, orphan, or Replica product-health issue, but their own high-signal Hyper-V events fired inside the {2}h window. A checkpoint-request failure (<code>18012</code>) does not necessarily create a merge and is not resolved merely by a later <code>19080</code>; merge completion is used as recovery evidence only for a merge-eligible failure such as <code>19100</code>. Steps: (a) open each VM's events <code>.csv</code> and note the exact IDs, timestamps, recurrence, and any disk/operation identifiers; (b) compare those times with that VM's backup/checkpoint job history; (c) engage the backup/checkpoint owner if failures recur across cycles. Event <code>18012</code> alone does not require Microsoft Support involvement. Consider Microsoft Support only when separate evidence identifies a fork-commit signature, an unresolved merge failure, checkpoint or virtual disk files that remain after the operation, or continuing failures after the responsible owner has ruled out their component. This is checkpoint reliability evidence, not proof of chain corruption.</li>
'@ -f $eventsOnlyInvVMs.Count, $eoNames, $EventLookbackHours))
    }
    if ($orphanTotal -gt 0) {
        [void]$sb.Append((@'
    <li><strong>INVESTIGATE - {0} orphaned .avhdx file(s) across {1} VM(s):</strong> do NOT delete these files based only on this report. A failed merge, failed backup checkpoint, interrupted instant recovery or live mount, or an initial Hyper-V Replica checkpoint can leave them behind. <ol><li><strong>Match each file to a job:</strong> use the file's <em>Created</em> and <em>LastWrite</em> times to find the related backup, restore, live-mount, instant-recovery, or replica-seed job for that VM.</li><li><strong>For a live-mount or instant-recovery file:</strong> stop the recovery session through the backup product. Do not delete the file manually.</li><li><strong>For an initial Replica recovery point:</strong> review <code>Get-VMReplication</code> health and follow the approved Replica recovery procedure.</li><li><strong>Before any file change:</strong> confirm the file's ownership and purpose, verify that a current backup exists, and use a procedure approved by the backup vendor or Microsoft Support.</li></ol> Do not move, rename, merge, or delete the file until its ownership and purpose are confirmed. Open a Microsoft Support case if a file cannot be matched to a job or if the required action is uncertain. See each VM's "Orphaned .avhdx files" detail below for names, sizes, timestamps, and file-specific guidance.</li>
'@ -f $orphanTotal, $orphanVMsCount))
    }
    if ($analyticNeedsEnable) {
        [void]$sb.Append(@'
  <li><strong>Enable the Analytic channel</strong> (operator's choice; elevated, per node) to capture the internal per-disk revert trace for the next occurrence: <code>wevtutil sl Microsoft-Windows-Hyper-V-VMMS-Analytic /e:true /q:true</code></li>
'@)
    }
    if ($storageDegraded) {
                [void]$sb.Append((@'
    <li><strong>Investigate the degraded cluster-storage snapshot:</strong> {0}. This is observed state, not a root-cause determination. See the existing Deeper analysis guidance in the storage section.</li>
'@ -f $storageReasonText))
    }
    if ($countHold -gt 0) {
        [void]$sb.Append(@'
  <li><strong>HOLD STATE VMs:</strong> engage Microsoft Support (CSS) and/or your backup vendor before any migration / restart.</li>
'@)
    }
    # Case-escalation line: shown ONLY when at least one VM is in HOLD STATE (a fork-commit signature
    # is present somewhere in the fleet). This is a roll-up - if ANY audited VM has the signature a
    # Microsoft case is warranted (the per-VM detail below shows which). On INVESTIGATE-only / clean
    # runs it is deliberately omitted: with NO fork-commit signature the operator's next step is
    # backup-team / vendor triage of the aged checkpoint(s), NOT opening a Microsoft case.
    if ($countHold -gt 0) {
        [void]$sb.Append(@'
  <li><strong>Open a Microsoft Support case:</strong> a checkpoint fork-commit signature (event <code>3216</code> or an HRESULT such as <code>0x80048102</code>) is present on one or more VMs above - that is the condition that warrants a case (the per-VM detail shows which).</li>
'@)
    }
    [void]$sb.Append(@'
</ol>
</div>
</details>
'@)

    # Node-wide events caveat. Place it immediately before the summary table where both event counts
    # are first interpreted: per-VM attributed events drive the verdict; node-wide events are context.
    [void]$sb.Append(@'
<details class="report-section" id="vm-summary" open>
<summary><h2>VM summary table</h2></summary>
<div class="report-section-body">
<div class="callout info">
  <strong>Reading the event counts:</strong> each VM shows <strong>two</strong> figures - a <strong>per-VM</strong>
  count of concern events whose message names <em>that</em> VM (these drive its verdict), and a <strong>node-wide</strong>
  count for context (checkpoint / merge activity across <strong>all</strong> VMs on the owning node, often referencing
  <em>other</em> VMs). Only the node-wide figure is node health context, not proof the audited VM is failing; each VM's
  own attributed events are listed in its section below.
</div>
'@)

    # VM summary table.
    [void]$sb.Append(@'
<p class="muted"><strong>VM Source:</strong> <span class="src input">Input</span> means you requested the VM; <span class="src discovered">Discovered</span> means <code>-IncludeDiscoveredVMs</code> added it automatically. <strong>Checkpoints:</strong> checkpoint objects returned by <code>Get-VMSnapshot</code>. <strong>AVHDX files:</strong> active differencing <code>.avhdx</code> layers; this can equal Checkpoints &times; Disks. <strong>Orphans:</strong> <code>.avhdx</code> files on disk that are not attached to a detected disk chain. <strong>Stale checkpoint evidence:</strong> attached AVHDX layers or named snapshots at or beyond the configured age threshold. <strong>Concerning Events (VM):</strong> events attributed to this VM; <code>hi</code> events can affect the verdict, while <code>low</code> events provide context and do not affect the verdict by themselves. Rows are ordered by severity within each verdict.</p>
<div class="vm-summary-scroll">
<table>
<thead><tr>
  <th>VM</th><th>State</th><th>Node</th><th>Cfg</th><th>Disks</th><th>Checkpoints</th><th>AVHDX files</th>
    <th>Orphans</th><th>Stale<br>evidence</th><th>Oldest ckpt age</th><th>Concerning<br>Events (VM)</th><th>Hyper-V Replica</th><th>Verdict</th>
</tr></thead>
<tbody>
'@)
    $sortedRows = $rows | Sort-Object `
        @{ Expression = { Get-VerdictRank $_.Recommendation } }, `
        @{ Expression = { if ($_.ReportData) { [int]$_.ReportData.SeverityScore } else { 0 } }; Descending = $true }, `
        VMName
    foreach ($r in $sortedRows) {
        $node = (("$($r.OwningNode)" -split '\.')[0])
        $rd   = $r.ReportData
        $pill = Get-VerdictPill $r.Recommendation
        # Source badge (Input vs Discovered) rendered next to the VM name.
        $srcBadge = ''
        if ($r.PSObject.Properties['Source'] -and $r.Source) {
            $srcCls = if ("$($r.Source)" -eq 'Discovered') { 'discovered' } else { 'input' }
            $srcBadge = "<span class=`"src $srcCls`">$(ConvertTo-HtmlText $r.Source)</span>"
        }
        if ($rd) {
            $ckptCount = @($rd.Checkpoints).Count
            $ages = @($rd.Checkpoints | ForEach-Object { [double]$_.AgeHrs })
            if ($ages.Count -gt 0) {
                $mx = ($ages | Measure-Object -Maximum).Maximum
                $oldest = '~{0}h (~{1}d)' -f [math]::Round($mx, 1), [math]::Round($mx / 24, 1)
                if ($mx -ge $StaleHours) { $oldest = "<span class='warnval'>$oldest</span>" }
            } else { $oldest = '-' }
            if ($rd.Replication.Enabled) {
                $replText = ConvertTo-HtmlText ("{0} ({1})" -f $rd.Replication.State, $rd.Replication.Health)
                $repl = if (("$($rd.Replication.State)" -eq 'Replicating') -and ("$($rd.Replication.Health)" -eq 'Normal')) {
                    $replText
                } else {
                    "<span class='warnval'>$replText</span>"
                }
                if ($rd.PSObject.Properties['ReplAssessment'] -and $rd.ReplAssessment) {
                    $summaryBreaches = if ($rd.ReplAssessment.MeasurementStatus -eq 'Concern') { @($rd.ReplAssessment.ConcernBreaches) } elseif ($rd.ReplAssessment.MeasurementStatus -eq 'Advisory') { @($rd.ReplAssessment.AdvisoryBreaches) } else { @() }
                    $summaryEvidence = Get-ReplicaMeasurementEvidence -Assessment $rd.ReplAssessment -Breaches $summaryBreaches
                    if ($summaryEvidence) {
                        $repl += "<br><span class='warnval'>$(ConvertTo-HtmlText $rd.ReplAssessment.MeasurementStatus) - $(ConvertTo-HtmlText $summaryEvidence)</span>"
                    }
                }
                if ($rd.PSObject.Properties['HrlAssessment'] -and $rd.HrlAssessment -and $rd.HrlAssessment.IsConcern -and ([int]$rd.HrlAssessment.ExceedsCadenceCount -gt 0)) {
                    $hrlFileWord = if ([int]$rd.HrlAssessment.ExceedsCadenceCount -eq 1) { 'file' } else { 'files' }
                    $repl += "<br><span class='warnval'>$($rd.HrlAssessment.ExceedsCadenceCount) queued HRL $hrlFileWord beyond cadence</span>"
                }
            } else {
                $repl = 'Not enabled'
            }
            $stateTxt = ConvertTo-HtmlText $rd.State
            # Concern (VM) cell: attributed concern-event count for THIS VM, annotating whether any are
            # high-signal (drive the verdict) vs low-signal only (transient / housekeeping - no action).
            $concernCell = if ([int]$rd.VmEventConcernCount -gt 0) {
                if ([int]$rd.VmHighConcernCount -gt 0) { "{0} <span class='warnval'>({1} hi)</span>" -f $rd.VmEventConcernCount, $rd.VmHighConcernCount } else { "{0} (low)" -f $rd.VmEventConcernCount }
            } else { '0' }
            # Orphan / stale count cells: amber when non-zero (a value to act on), muted grey when 0
            # so a clean row recedes and a real count pops.
            $orphanCell = if ([int]$rd.OrphanCount -gt 0) { "<span class='warnval'>$($rd.OrphanCount)</span>" } else { "<span class='zero'>0</span>" }
            $staleAttached = if ($rd.PSObject.Properties['StaleAttachedLayerCount']) { [int]$rd.StaleAttachedLayerCount } else { 0 }
            $staleSnapshots = [int]$rd.StaleCheckpointCount
            $layerLabel = if ($staleAttached -eq 1) { 'layer' } else { 'layers' }
            $snapshotLabel = if ($staleSnapshots -eq 1) { 'snapshot' } else { 'snapshots' }
            $stalePair = "$staleAttached $layerLabel / $staleSnapshots $snapshotLabel"
            $staleCell = if (($staleAttached + $staleSnapshots) -gt 0) { "<span class='warnval'>$stalePair</span>" } else { "<span class='zero'>$stalePair</span>" }
            [void]$sb.Append(@"
<tr>
  <td class="vmn"><a href="#$(ConvertTo-Anchor $r.VMName)"><code>$(ConvertTo-HtmlText $r.VMName)</code></a>$srcBadge</td><td>$stateTxt</td><td class="nm">$(ConvertTo-HtmlText $node)</td><td>$(ConvertTo-HtmlText $rd.Version)</td>
  <td class="num">$($rd.AttachedDiskCount)</td><td class="num">$ckptCount</td><td class="num">$($rd.CheckpointLayers)</td>
  <td class="num">$orphanCell</td><td class="num">$staleCell</td><td>$oldest</td>
  <td class="num">$concernCell</td><td>$repl</td><td>$pill</td>
</tr>
"@)
        } else {
            [void]$sb.Append(@"
<tr>
  <td class="vmn"><a href="#$(ConvertTo-Anchor $r.VMName)"><code>$(ConvertTo-HtmlText $r.VMName)</code></a>$srcBadge</td><td>-</td><td class="nm">$(ConvertTo-HtmlText $node)</td><td>-</td>
  <td class="num">-</td><td class="num">-</td><td class="num">-</td>
  <td class="num">-</td><td class="num">-</td><td>-</td>
  <td class="num">-</td><td>-</td><td>$pill</td>
</tr>
"@)
        }
    }
    [void]$sb.Append("</tbody></table></div></div></details>`r`n")

    # Discovered high-risk VMs (referenced in event data but not in the audit list).
    if ($null -ne $DiscoveredVMs -and $DiscoveredVMs.Count -gt 0) {
        $capReached = $IncludeDiscoveredVMs -and $DiscoverySummary -and ([int]$DiscoverySummary.DeferredCount -gt 0)
        $discoveryHeading = if ($capReached) { 'Discovered VMs not audited - discovery cap reached' } else { 'Discovered high-risk VMs (recommended to audit)' }
        $discoveryCallout = if ($capReached) {
            "These VMs were validated as high-risk discoveries but were deferred because the explicit <code>-MaxDiscoveredVMs $($DiscoverySummary.Cap)</code> limit was reached. Audit them with the command below."
        } else {
            "These VMs were <strong>not in the audit list</strong> but were referenced in this cluster's <strong>high-risk</strong> checkpoint / merge event signals (background disk merge interrupted / failed, sharing violation <code>0x80070020</code>, or 'cannot load VM configuration'). Given the data-loss risk of the fork-commit failure mode, auditing them is recommended."
        }
        [void]$sb.Append("<details class='report-section' id='discovered-vms' open><summary><h2>$discoveryHeading</h2></summary><div class='report-section-body'>`r`n")
        [void]$sb.Append("<div class='callout warn'>$discoveryCallout</div>`r`n")
        [void]$sb.Append("<table><thead><tr><th>VM</th><th>Why flagged</th></tr></thead><tbody>")
        foreach ($dv in $DiscoveredVMs) {
            $reasonText = if ($dv.PSObject.Properties['Reasons'] -and @($dv.Reasons).Count -gt 0) { @($dv.Reasons) -join '; ' } else { [string]$dv.Reason }
            [void]$sb.Append("<tr><td><code>$(ConvertTo-HtmlText $dv.Name)</code></td><td>$(ConvertTo-HtmlText $reasonText)</td></tr>")
        }
        [void]$sb.Append("</tbody></table>`r`n")
        $dvNames = (@($DiscoveredVMs | ForEach-Object { "'{0}'" -f $_.Name }) -join ',')
        [void]$sb.Append("<p>Audit them with:</p><pre>Get-HyperVVMCheckpointHealth -VMName $(ConvertTo-HtmlText $dvNames) -OutputPath &lt;folder&gt;</pre>`r`n")
        if (-not $IncludeDiscoveredVMs) {
            [void]$sb.Append("<p class='muted'>Or re-run the original command adding <code>-IncludeDiscoveredVMs</code> to audit every eligible discovery automatically (non-recursive). Supply <code>-MaxDiscoveredVMs</code> only when an explicit cap is required.</p>`r`n")
        }
        [void]$sb.Append("</div></details>`r`n")
    }

    # Per-VM detail. Keep findings and incomplete assessments open; collapse OK cards by default.
    [void]$sb.Append("<details class='report-section' open><summary><h2>Per-VM detailed information</h2></summary><div class='report-section-body'>`r`n")
    foreach ($r in $sortedRows) {
        $rd   = $r.ReportData
        $pill = Get-VerdictPill $r.Recommendation
        $cls  = if ($r.Recommendation -eq 'HOLD STATE') { ' hold' } else { '' }
        $openAttr = if ($r.Recommendation -eq 'OK') { '' } else { ' open' }
        $srcBadge = ''
        if ($r.PSObject.Properties['Source'] -and $r.Source) {
            $srcCls = if ("$($r.Source)" -eq 'Discovered') { 'discovered' } else { 'input' }
            $srcBadge = "<span class=`"src $srcCls`">$(ConvertTo-HtmlText $r.Source)</span>"
        }
        [void]$sb.Append("<details class=`"vm$cls`" id=`"$(ConvertTo-Anchor $r.VMName)`"$openAttr>`r`n  <summary><h3><span class=`"vm-label`">VM Name:</span> <code>$(ConvertTo-HtmlText $r.VMName)</code> $pill$srcBadge</h3></summary>`r`n  <div class=`"vm-body`">`r`n")
        if (-not $rd) {
            [void]$sb.Append("  <div class='kv'><div class='k'>VM name</div><div><code>$(ConvertTo-HtmlText $r.VMName)</code></div></div>`r`n")
            [void]$sb.Append("  <div class='callout warn'>$(ConvertTo-HtmlText $r.Detail)</div>`r`n  </div>`r`n</details>")
            continue
        }
        $ckptCount = @($rd.Checkpoints).Count
        $verOld = if ($rd.VmVerOlder) { "Yes - v$(ConvertTo-HtmlText $rd.Version) vs cluster max v$(ConvertTo-HtmlText $rd.HostMaxVersion) (migration/start context only; not a checkpoint cause)." } else { 'No - at the latest supported version.' }
        $analytic = if ($rd.PSObject.Properties['AnalyticCheckSkipped'] -and $rd.AnalyticCheckSkipped) {
            'Not checked (-SkipAnalyticCheck)'
        } elseif (@($rd.AnalyticNodesNeedEnable) -contains $r.OwningNode) {
            'Not enabled on this node'
        } else {
            'Enabled'
        }
        $vss = switch ($rd.VssState) { 'Healthy' { "All $($rd.VssTotal) writer(s) Stable (no last error)" } 'Unhealthy' { "$($rd.VssUnhealthyCount) of $($rd.VssTotal) writer(s) NOT healthy" } default { 'Unavailable (needs elevated context on owner)' } }
        $srcText   = if ($r.PSObject.Properties['Source'] -and $r.Source) { [string]$r.Source } else { 'Input' }
        $nodeWideNote = if ($rd.PSObject.Properties['NodeDominantNote'] -and $rd.NodeDominantNote) { " ($($rd.NodeDominantNote))" } else { '' }
        $policySourceText = if ($rd.PSObject.Properties['PolicySource'] -and $rd.PolicySource) { [string]$rd.PolicySource } else { 'BuiltInDefaults' }
        $csvPolicyText = if ($rd.PSObject.Properties['CsvFreeSpaceAssessment'] -and $rd.CsvFreeSpaceAssessment) {
            $csvPolicy = $rd.CsvFreeSpaceAssessment
            if (-not $csvPolicy.Enabled) { 'Disabled' }
            elseif ($csvPolicy.IsConcern) { "BREACH - $(@($csvPolicy.Breaches).Count) volume(s); minimum $($csvPolicy.MinimumFreePercent)% and $($csvPolicy.MinimumFreeGB) GB" }
            else { "Pass - minimum $($csvPolicy.MinimumFreePercent)% and $($csvPolicy.MinimumFreeGB) GB" }
        } else { 'Disabled' }
        $hrlPolicyText = if ($rd.PSObject.Properties['HrlAssessment'] -and $rd.HrlAssessment) {
            $hrlPolicy = $rd.HrlAssessment
            if (-not $hrlPolicy.Enabled) { 'Disabled' }
            elseif (-not $hrlPolicy.ReplicationEnabled) { 'Not applicable - Replica disabled' }
            else { "Threshold $([math]::Round([double]$hrlPolicy.ThresholdMinutes, 1)) min; $($hrlPolicy.ExceedsCadenceCount) exceeded; corroborated=$($hrlPolicy.CorroboratedByReplication)" }
        } else { 'Unavailable' }
        $replicaAssessment = $null
        $replicaMeasurementText = if ($rd.PSObject.Properties['ReplAssessment'] -and $rd.ReplAssessment) {
            $replicaAssessment = $rd.ReplAssessment
            $breachesToShow = if ($replicaAssessment.MeasurementStatus -eq 'Concern') { @($replicaAssessment.ConcernBreaches) } else { @($replicaAssessment.AdvisoryBreaches) }
            $measurementEvidence = Get-ReplicaMeasurementEvidence -Assessment $replicaAssessment -Breaches $breachesToShow
            if ($measurementEvidence) { "$($replicaAssessment.MeasurementStatus) - $measurementEvidence" } else { [string]$replicaAssessment.MeasurementStatus }
        } else { 'Unavailable' }
        $replicaMeasurementHtml = if ($replicaAssessment -and $replicaAssessment.MeasurementStatus -in @('Concern', 'Advisory')) {
            "<span class='warnval'>$(ConvertTo-HtmlText $replicaMeasurementText)</span>"
        } else {
            ConvertTo-HtmlText $replicaMeasurementText
        }
        $replicaProductText = if ($rd.Replication.Enabled) { "{0} ({1})" -f $rd.Replication.State, $rd.Replication.Health } else { 'Not enabled' }
        $replicaProductHtml = if ($replicaAssessment -and $replicaAssessment.ProductSeverity -in @('Critical', 'Warning', 'Unknown')) {
            "<span class='warnval'>$(ConvertTo-HtmlText $replicaProductText)</span>"
        } else {
            ConvertTo-HtmlText $replicaProductText
        }
        $chainCompleteText = if ($rd.PSObject.Properties['ChainComplete'] -and $rd.ChainComplete) { 'Complete' } elseif ($rd.PSObject.Properties['IncompleteChainCount']) { "INCOMPLETE ($($rd.IncompleteChainCount) disk(s) unreadable)" } else { 'Unavailable' }
        $chainCompleteHtml = if ($chainCompleteText -eq 'Complete') { $chainCompleteText } else { "<span class='warnval'>$(ConvertTo-HtmlText $chainCompleteText)</span>" }
        $staleAttachedCount = if ($rd.PSObject.Properties['StaleAttachedLayerCount']) { [int]$rd.StaleAttachedLayerCount } else { 0 }
        $staleAttachedHtml = if ($staleAttachedCount -gt 0) { "<span class='warnval'>$staleAttachedCount</span>" } else { '0' }
        $staleSnapshotCount = [int]$rd.StaleCheckpointCount
        $staleSnapshotHtml = if ($staleSnapshotCount -gt 0) { "<span class='warnval'>$staleSnapshotCount</span>" } else { '0' }
        $snapshotLayerMismatch = ($rd.PSObject.Properties['SnapshotLayerMismatch'] -and $rd.SnapshotLayerMismatch)
        $snapshotLayerHtml = if ($snapshotLayerMismatch) { "<span class='warnval'>MISMATCH - only one representation is present</span>" } else { 'Consistent presence' }
        $orphanCount = [int]$rd.OrphanCount
        $orphanCountHtml = if ($orphanCount -gt 0) { "<span class='warnval'>$orphanCount</span>" } else { '0' }
        $vssHtml = if ($rd.VssState -eq 'Healthy') { ConvertTo-HtmlText $vss } else { "<span class='warnval'>$(ConvertTo-HtmlText $vss)</span>" }
        $csvPolicyHtml = if ($rd.PSObject.Properties['CsvFreeSpaceAssessment'] -and $rd.CsvFreeSpaceAssessment -and $rd.CsvFreeSpaceAssessment.IsConcern) { "<span class='warnval'>$(ConvertTo-HtmlText $csvPolicyText)</span>" } else { ConvertTo-HtmlText $csvPolicyText }
        $hrlPolicyConcern = ($rd.PSObject.Properties['HrlAssessment'] -and $rd.HrlAssessment -and $rd.HrlAssessment.Enabled -and ([int]$rd.HrlAssessment.ExceedsCadenceCount -gt 0) -and $rd.HrlAssessment.CorroboratedByReplication)
        $hrlPolicyHtml = if ($hrlPolicyConcern) { "<span class='warnval'>$(ConvertTo-HtmlText $hrlPolicyText)</span>" } else { ConvertTo-HtmlText $hrlPolicyText }
        $vmEventHtml = if ([int]$rd.VmHighConcernCount -gt 0) {
            "<span class='warnval'>$($rd.VmEventConcernCount) ($($rd.VmHighConcernCount) high-signal)</span>"
        } elseif ([int]$rd.VmEventConcernCount -gt 0) {
            "$($rd.VmEventConcernCount) (low-signal only)"
        } else {
            '0 (none attributed)'
        }
        $stateConsistencyText = if ($rd.PSObject.Properties['StateConsistencyImpact'] -and $rd.StateConsistencyImpact -eq 'Advisory') {
            'Advisory - VM configuration (.vmcx) timestamp changed during collection; core state and disk paths remained stable'
        } elseif ($rd.PSObject.Properties['StateConsistencyStatus'] -and $rd.StateConsistencyStatus -eq 'Unavailable') {
            'Unavailable - final collection-state recheck evidence was not available'
        } elseif ($rd.PSObject.Properties['StateConsistencyImpact'] -and $rd.StateConsistencyImpact -eq 'Inconclusive') {
            $changedFields = if ($rd.PSObject.Properties['StateConsistencyReasons'] -and @($rd.StateConsistencyReasons).Count -gt 0) { @($rd.StateConsistencyReasons) -join ', ' } else { 'state token evidence unavailable' }
            "Inconclusive - material collection-state change: $changedFields; rerun after VM activity settles"
        } else {
            'Stable - no owner, state, checkpoint, disk-path, or configuration timestamp changes detected'
        }
        $stateConsistencyHtml = if ($rd.PSObject.Properties['StateConsistencyImpact'] -and $rd.StateConsistencyImpact -eq 'Inconclusive') { "<span class='warnval'>$(ConvertTo-HtmlText $stateConsistencyText)</span>" } else { ConvertTo-HtmlText $stateConsistencyText }
        [void]$sb.Append(@"
  <div class="kv">
        <div class="k">VM name</div><div><code>$(ConvertTo-HtmlText $r.VMName)</code></div>
    <div class="k">Source</div><div>$(ConvertTo-HtmlText $srcText) $(if ($srcText -eq 'Discovered') { '(auto-added via -IncludeDiscoveredVMs)' } else { '(you requested this VM)' })</div>
    <div class="k">VM state</div><div>$(ConvertTo-HtmlText $rd.State) / $(ConvertTo-HtmlText $rd.Status)</div>
    <div class="k">Owning node</div><div><code>$(ConvertTo-HtmlText $r.OwningNode)</code></div>
    <div class="k">Config version</div><div>$(ConvertTo-HtmlText $rd.Version) (cluster max $(ConvertTo-HtmlText $rd.HostMaxVersion))</div>
    <div class="k">Uptime</div><div>$(ConvertTo-HtmlText $rd.Uptime)</div>
    <div class="k">Attached disks</div><div>$($rd.AttachedDiskCount)</div>
    <div class="k">Checkpoints (Get-VMSnapshot)</div><div>$ckptCount</div>
    <div class="k">Differencing (.avhdx) files</div><div>$(if ([int]$rd.CheckpointLayers -gt 0) { "$($rd.CheckpointLayers) (= checkpoints &times; disks)" } else { '0 (no checkpoints)' })</div>
    <div class="k">VHD chain completeness</div><div>$chainCompleteHtml</div>
    <div class="k">Stale attached AVHDX layers (&ge;$($rd.StaleHours)h)</div><div>$staleAttachedHtml</div>
    <div class="k">Stale named snapshots (&ge;$($rd.StaleHours)h)</div><div>$staleSnapshotHtml</div>
    <div class="k">Snapshot/layer representation</div><div>$snapshotLayerHtml</div>
    <div class="k">Checkpoint type</div><div>$(ConvertTo-HtmlText $rd.CheckpointType)</div>
    <div class="k">Orphaned .avhdx</div><div>$orphanCountHtml</div>
    <div class="k">Hyper-V Replica</div><div>$replicaProductHtml</div>
    <div class="k">Replica measurement assessment</div><div>$replicaMeasurementHtml</div>
    <div class="k">VSS writers</div><div>$vssHtml</div>
    <div class="k">Analytic channel</div><div>$(ConvertTo-HtmlText $analytic)</div>
    <div class="k">Policy source</div><div><code>$(ConvertTo-HtmlText $policySourceText)</code></div>
    <div class="k">CSV free-space policy</div><div>$csvPolicyHtml</div>
    <div class="k">HRL cadence assessment</div><div>$hrlPolicyHtml</div>
    <div class="k">Config behind latest</div><div>$verOld</div>
    <div class="k">Concerning events - this VM ($($rd.EventLookbackHours)h)</div><div>$vmEventHtml</div>
    <div class="k">Concerning events - node-wide ($($rd.EventLookbackHours)h)</div><div>$($rd.EventConcernCount)$nodeWideNote (references other VMs / none - context only)</div>
        <div class="k">Collection state consistency</div><div>$stateConsistencyHtml</div>
  </div>
"@)
        # Assessment callout. v0.2.14: name the actual INVESTIGATE driver (so the operator sees WHY and
        # HOW urgent), surface the 'possible past rollback' fingerprint + historic-correlation result,
        # and add a low-key note on OK VMs whose only signal was low-signal chatter.
        if ($r.Recommendation -eq 'HOLD STATE') {
            [void]$sb.Append("  <div class='callout high'><strong>HOLD STATE (data-loss risk).</strong> A 'checkpoint fork-commit / merge-failure' signature AND unmerged differencing disk(s) are present together. <span class='hot'>Do NOT migrate or restart this VM</span> until the chain is validated (and merged if required); reopening an inconsistent chain can roll disks back to base. Engage Microsoft Support (CSS) and/or your backup vendor.</div>`r`n")
        } elseif ($r.Recommendation -eq 'INVESTIGATE') {
            # Build the driver phrase from the strongest signal down.
            $drv = @()
            if ($rd.HasRollbackFingerprint) { $drv += "possible historic rollback - $($rd.OrphanCount) orphaned .avhdx frozen at a common date ($(ConvertTo-HtmlText $rd.RollbackDate))" }
            elseif ($rd.HasStuckMergeOrphan) { $drv += "orphaned .avhdx with a matching stuck/failed-merge event" }
            if ($rd.PSObject.Properties['StaleAttachedLayerCount'] -and ([int]$rd.StaleAttachedLayerCount -gt 0)) { $drv += "$($rd.StaleAttachedLayerCount) stale attached AVHDX layer(s)" }
            if ($rd.StaleCheckpointCount -gt 0) { $drv += "$($rd.StaleCheckpointCount) stale named snapshot(s)" }
            if ($rd.PSObject.Properties['SnapshotLayerMismatch'] -and $rd.SnapshotLayerMismatch) { $drv += 'snapshot/layer representation mismatch' }
            if ($rd.PSObject.Properties['ChainComplete'] -and -not $rd.ChainComplete) { $drv += "$($rd.IncompleteChainCount) incomplete/unreadable VHD chain(s)" }
            if ($rd.PSObject.Properties['StateConsistencyImpact'] -and $rd.StateConsistencyImpact -eq 'Inconclusive') { $drv += "INCONCLUSIVE collection state ($($rd.StateConsistencyStatus))" }
            if ($rd.PSObject.Properties['ReplAssessment'] -and $rd.ReplAssessment) {
                if ($rd.ReplAssessment.ProductSeverity -in @('Critical', 'Warning', 'Unknown')) {
                    $drv += "Replica product health/state $($rd.ReplAssessment.ProductSeverity) ($(ConvertTo-HtmlText $rd.ReplAssessment.State) / $(ConvertTo-HtmlText $rd.ReplAssessment.Health))"
                }
                if ($rd.ReplAssessment.MeasurementStatus -eq 'Concern') {
                    $drv += "Replica measurement concern: $(ConvertTo-HtmlText (Get-ReplicaMeasurementEvidence -Assessment $rd.ReplAssessment -Breaches @($rd.ReplAssessment.ConcernBreaches)))"
                }
            } elseif ($rd.ReplCritical) { $drv += "Replica product health Critical ($(ConvertTo-HtmlText $rd.ReplHealth))" }
            if (($rd.OrphanCount -gt 0) -and -not $rd.HasRollbackFingerprint -and -not $rd.HasStuckMergeOrphan) {
                $drv += $(if ($rd.OrphanOnlyLiveMount) { "$($rd.OrphanCount) orphaned .avhdx (likely backup live-mount artifact)" } else { "$($rd.OrphanCount) orphaned .avhdx (leftover file)" })
            }
            # v0.2.17: only the ESCALATING events (critical + UNRESOLVED operation failures) name a driver;
            # a self-resolved operation failure does not appear here (the VM is OK-with-note, not INVESTIGATE).
            if ([int]$rd.VmEscalatingConcernCount -gt 0) {
                if ([int]$rd.VmCriticalCount -gt 0) { $drv += "$($rd.VmCriticalCount) critical fork-commit event(s) for this VM" }
                $unresolvedHighOp = [int]$rd.VmEscalatingConcernCount - [int]$rd.VmCriticalCount
                if ($unresolvedHighOp -gt 0) { $drv += "$unresolvedHighOp VM-attributed checkpoint/merge operation failure event(s) requiring recurrence and job-history review" }
            }
            if ($rd.VssState -eq 'Unhealthy') { $drv += "$($rd.VssUnhealthyCount) unhealthy VSS writer(s)" }
            if ($rd.PSObject.Properties['CsvFreeSpaceAssessment'] -and $rd.CsvFreeSpaceAssessment -and $rd.CsvFreeSpaceAssessment.IsConcern) {
                $drv += "$(@($rd.CsvFreeSpaceAssessment.Breaches).Count) CSV free-space policy breach(es)"
            }
            if ($rd.PSObject.Properties['HrlAssessment'] -and $rd.HrlAssessment -and $rd.HrlAssessment.IsConcern) {
                $drv += "$($rd.HrlAssessment.ExceedsCadenceCount) HRL file(s) beyond cadence with Replica corroboration"
            }
            $investigationDrivers = if ($rd.PSObject.Properties['InvestigationDrivers']) { $rd.InvestigationDrivers } else { $null }
            if ($investigationDrivers -and $investigationDrivers.PSObject.Properties['Labels'] -and @($investigationDrivers.Labels).Count -gt 0) {
                $drv = @($investigationDrivers.Labels | ForEach-Object { ConvertTo-HtmlText $_ })
            }
            $drvText = if ($drv.Count -gt 0) { (($drv) -join '; ') } else { 'concern signals present' }
            if ($rd.HistoricForkConfirmed) {
                [void]$sb.Append("  <div class='callout high'><strong>INVESTIGATE - CONFIRMED historic rollback.</strong> <strong>Reason for this verdict:</strong> recovered historic fork-commit / merge-failure events confirm this scenario; $drvText. The orphaned <code>.avhdx</code> files may contain data that is no longer accessible to the VM. Do NOT remove them. Engage Microsoft Support (CSS) or your backup vendor for recovery guidance.</div>`r`n")
            } elseif ($rd.HasRollbackFingerprint) {
                [void]$sb.Append("  <div class='callout high'><strong>INVESTIGATE - possible historic rollback.</strong> <strong>Reason for this verdict:</strong> $drvText. The orphaned <code>.avhdx</code> files may remain from a fork-commit rollback on <strong>$(ConvertTo-HtmlText $rd.RollbackDate)</strong>. They may contain data that is no longer accessible to the VM. Do NOT remove them. Engage Microsoft Support (CSS) or your backup vendor for recovery guidance. The original fork-commit events may be older than the $($rd.EventLookbackHours)h lookback; see the historic correlation below.</div>`r`n")
            } else {
                $hasCheckpointStorageDriver = if ($investigationDrivers -and $investigationDrivers.PSObject.Properties['HasCheckpointArtifact']) {
                    [bool]$investigationDrivers.HasCheckpointArtifact
                } else {
                    ($rd.PSObject.Properties['StaleAttachedLayerCount'] -and ([int]$rd.StaleAttachedLayerCount -gt 0)) -or
                    ([int]$rd.StaleCheckpointCount -gt 0) -or
                    ($rd.PSObject.Properties['SnapshotLayerMismatch'] -and $rd.SnapshotLayerMismatch) -or
                    ($rd.PSObject.Properties['ChainComplete'] -and -not $rd.ChainComplete) -or
                    ([int]$rd.OrphanCount -gt 0)
                }
                $hasEventDriver = if ($investigationDrivers -and $investigationDrivers.PSObject.Properties['HasEvents']) { [bool]$investigationDrivers.HasEvents } else { [int]$rd.VmEscalatingConcernCount -gt 0 }
                $hasStateDriver = if ($investigationDrivers -and $investigationDrivers.PSObject.Properties['HasStateInconclusive']) { [bool]$investigationDrivers.HasStateInconclusive } elseif ($rd.PSObject.Properties['StateConsistencyImpact']) { $rd.StateConsistencyImpact -eq 'Inconclusive' } else { $rd.PSObject.Properties['StateConsistencyStatus'] -and $rd.StateConsistencyStatus -ne 'Stable' }
                $hasReplicaDriver = if ($investigationDrivers -and $investigationDrivers.PSObject.Properties['HasReplica']) { [bool]$investigationDrivers.HasReplica } else { $rd.PSObject.Properties['ReplAssessment'] -and $rd.ReplAssessment -and $rd.ReplAssessment.IsConcern }
                $investigateGuidance = if ($hasCheckpointStorageDriver) {
                    $artifactEvidence = [System.Collections.Generic.List[string]]::new()
                    if ($rd.PSObject.Properties['ChainComplete'] -and -not $rd.ChainComplete) { [void]$artifactEvidence.Add('VHD chain') }
                    if ($rd.PSObject.Properties['StaleAttachedLayerCount'] -and ([int]$rd.StaleAttachedLayerCount -gt 0)) { [void]$artifactEvidence.Add('attached AVHDX layer') }
                    if ([int]$rd.StaleCheckpointCount -gt 0) { [void]$artifactEvidence.Add('stale snapshot') }
                    if ($rd.PSObject.Properties['SnapshotLayerMismatch'] -and $rd.SnapshotLayerMismatch) { [void]$artifactEvidence.Add('snapshot/layer mismatch') }
                    if ([int]$rd.OrphanCount -gt 0) { [void]$artifactEvidence.Add('orphaned .avhdx') }
                    $artifactEvidenceText = if ($artifactEvidence.Count -gt 0) { $artifactEvidence.ToArray() -join ' and ' } else { 'checkpoint/storage evidence' }
                    "No confirming checkpoint fork-commit signature was observed, so on-disk chain corruption is not established. Before modifying any checkpoint-related AVHDX/VHD artifact or differencing chain, validate the $artifactEvidenceText with the backup/storage owner, confirm ownership and purpose, verify current backup protection, and follow an approved procedure."
                } elseif ($hasEventDriver -and -not ($hasReplicaDriver -or $hasStateDriver)) {
                    'Review the VM-attributed failure events and corresponding backup/checkpoint jobs for recurrence. No stale checkpoint, orphan, or attached AVHDX residue was found, so this is checkpoint reliability evidence rather than proof of chain corruption; there is no disk merge or removal action from this result.'
                } elseif ($hasReplicaDriver -and -not ($hasEventDriver -or $hasStateDriver)) {
                    'Review the Hyper-V Replica details below, confirm connectivity and capacity on both replication partners, address the breached effective limits, then verify that replication returns to Normal and the backlog drains.'
                } elseif ($hasStateDriver -and -not ($hasEventDriver -or $hasReplicaDriver)) {
                    'The collected evidence may span different VM states. Rerun the audit after migration, checkpoint, merge, replication, or power-state activity has settled; do not infer a checkpoint-chain problem from this inconclusive result.'
                } elseif ($investigationDrivers -and $investigationDrivers.PSObject.Properties['AssessmentText']) {
                    "$(ConvertTo-HtmlText $investigationDrivers.AssessmentText) Follow the driver-specific evidence and actions below, then rerun the audit."
                } else {
                    'Review the detailed evidence below, correlate it with the responsible workload or platform owner, and re-run the audit after remediation.'
                }
                [void]$sb.Append("  <div class='callout warn'><strong>INVESTIGATE.</strong> <strong>Reason for this verdict:</strong> $drvText. $investigateGuidance</div>`r`n")
                # v0.2.17: when this VM's driver includes HIGH-signal VM-attributed event(s), give a concrete
                # step list naming the actual IDs - otherwise the operator sees 'INVESTIGATE' with no action.
                # These IDs are the VM's OWN checkpoint / merge operations failing (not node-wide chatter),
                # which usually points at a repeatedly failing backup / checkpoint job.
                if ([int]$rd.VmEscalatingConcernCount -gt 0) {
                    $eoIds = if ($rd.PSObject.Properties['VmHighConcernIds'] -and $rd.VmHighConcernIds) { ConvertTo-HtmlText $rd.VmHighConcernIds } else { 'see the events table below' }
                    $has18012Finding = ($rd.PSObject.Properties['VmHighConcernIds'] -and ([string]$rd.VmHighConcernIds -match '(^|,\s*)18012\b'))
                    if ($has18012Finding) {
                        [void]$sb.Append("  <div class='callout info'><strong>What to INVESTIGATE for this VM - recurring backup/checkpoint reliability:</strong> This <code>18012</code> finding does not, by itself, require Microsoft Support involvement. The high-signal event(s) attributed to this VM are <strong>$eoIds</strong>. Event <code>18012</code> means that a checkpoint request failed before a usable checkpoint was created. It does not, by itself, prove a failed merge, AVHDX-chain corruption, or data-loss risk. <p><strong>Observed pattern:</strong> Review the expanded event evidence below for the first/last timestamps and recurrence. Repeated failures at a similar time on different days commonly indicate a scheduled backup or checkpoint operation repeatedly encountering the same condition.</p><ol><li>Open this VM's events <code>.csv</code> (<code>$(ConvertTo-HtmlText $rd.EventsCsvName)</code>) and note the UTC timestamps, VM ID, event IDs, recurrence, and complete messages.</li><li>Match each timestamp to the backup/checkpoint product's job and activity history. Identify the requesting job or policy, whether it retried, and whether the overall backup succeeded, failed, or used a fallback method.</li><li>Review the backup product's detailed error for each failed attempt. Check Hyper-V, VSS, guest integration, concurrent operations, timeouts, and storage evidence only when the job details indicate those components.</li><li>If the failure occurs across multiple backup cycles, engage the backup/checkpoint owner to correct the recurring job or policy condition, then re-run this audit after a successful cycle.</li><li>Event <code>18012</code> alone does not identify a virtual-disk file that requires operator action. Do not move, rename, delete, or manually alter virtual-disk files based on this event alone. If Hyper-V or the backup product is already performing a checkpoint cleanup or merge, allow that managed operation to complete and review its job status; do not interfere with its files while it is running.</li><li>For repeated failures, if applicable, check with your backup solution vendor for assistance and guidance. Then open a support request (SR) case with Microsoft Support when recurring checkpoint failures remain after the backup/checkpoint owner has ruled out their component.</li></ol></div>`r`n")
                    } else {
                        [void]$sb.Append("  <div class='callout info'><strong>What to INVESTIGATE for this VM - checkpoint/merge reliability:</strong> the high-signal event(s) attributed to this VM are <strong>$eoIds</strong>. <ol><li>Open this VM's events <code>.csv</code> (<code>$(ConvertTo-HtmlText $rd.EventsCsvName)</code>) and review the full messages, timestamps, recurrence, and any disk/operation identifiers.</li><li>Compare those times with this VM's backup/checkpoint job history and identify the operational owner.</li><li>If the failures recur across cycles, engage the backup/checkpoint owner and re-run after the next backup cycle.</li><li>Consider Microsoft Support only when the available evidence separately identifies a fork-commit signature, an unresolved merge failure, checkpoint or virtual disk files that remain after the operation, or continuing failures after the responsible owner has ruled out their component.</li></ol></div>`r`n")
                    }
                }
            }
        } elseif ($r.Recommendation -eq 'OK') {
            if ($rd.PSObject.Properties['HighOpSelfResolved'] -and $rd.HighOpSelfResolved) {
                $recoveryStatus = if ($rd.PSObject.Properties['OperationRecoveryStatus']) { [string]$rd.OperationRecoveryStatus } else { 'ApparentlyRecovered' }
                if ($recoveryStatus -eq 'ConfirmedRecovered') {
                    [void]$sb.Append("  <div class='callout ok'><strong>OK - correlated recovery observed.</strong> $($rd.VmHighOpCount) checkpoint or merge failure event(s) are attributed to this VM. A later merge-success event occurred within the configured correlation window and contains the same disk or operation identifier. No orphaned <code>.avhdx</code>, stale attached layer, or stale snapshot remains. Review the events CSV and backup history if the pattern occurs again.</div>`r`n")
                } else {
                    [void]$sb.Append("  <div class='callout info'><strong>OK - apparently recovered operation.</strong> $($rd.VmHighOpCount) checkpoint or merge failure event(s) are followed by a successful merge within the configured correlation window, and no persistent file or checkpoint remains. The events do <strong>not</strong> contain the same disk or operation identifier, so the report cannot prove that the success event resolved the earlier failure. Review the events CSV and backup history if this pattern occurs again.</div>`r`n")
                }
            } elseif ($rd.LowSignalOnly) {
                $replicaSummary = if ($rd.PSObject.Properties['ReplAssessment'] -and $rd.ReplAssessment -and $rd.ReplAssessment.MeasurementStatus -eq 'Advisory') { 'no verdict-driving Replica concern; one measurement advisory is recorded' } else { 'Replica product state and measurements are healthy' }
                [void]$sb.Append("  <div class='callout ok'><strong>OK.</strong> No active checkpoint layers, no orphaned .avhdx, $replicaSummary, and VSS is stable. Note: $($rd.VmLowConcernCount) low-signal event(s) are attributed to this VM - e.g. transient 'background disk merge interrupted' (<code>19090</code>) that subsequently completed (no leftover <code>.avhdx</code> remains), or 'failed to get disk information' (<code>15268</code>) storage / housekeeping chatter. These are not, on their own, a concern and need no action.</div>`r`n")
            } else {
                if ($rd.PSObject.Properties['ReplAssessment'] -and $rd.ReplAssessment -and $rd.ReplAssessment.MeasurementStatus -eq 'Advisory') {
                    [void]$sb.Append("  <div class='callout ok'><strong>OK.</strong> No active checkpoint layers or verdict-driving concern was found; one Replica measurement advisory is recorded below the verdict threshold. No action required from this result.</div>`r`n")
                } else {
                    [void]$sb.Append("  <div class='callout ok'><strong>OK.</strong> No active checkpoint layers and no concern signals were found. No action required from this result.</div>`r`n")
                }
            }
        }
        # v0.2.17: PROACTIVE active-checkpoint findings (pre-migration). Rendered for ANY verdict when set,
        # right after the main assessment, because the whole point is to warn BEFORE a migration/restart.
        if ($rd.PSObject.Properties['ActiveCkptForkConfirmed'] -and $rd.ActiveCkptForkConfirmed) {
            [void]$sb.Append("  <div class='callout high'><strong>HOLD STATE - fork-commit recorded at this active checkpoint's creation.</strong> This VM has an ACTIVE (still-attached) checkpoint created <strong>$(ConvertTo-HtmlText $rd.ActiveCkptOldestCreateUtc)</strong>, before the $($rd.EventLookbackHours)h event lookback. The historic cross-node scan detected a 'fork-commit / merge-failure' event around that creation time. The differencing chain may be inconsistent while the VM continues to run. A live migration, quick migration, storage migration, or restart could expose the inconsistency and cause the VM disks to roll back to their base disks. <span class='hot'>Do NOT migrate or restart this VM</span> until the chain is validated and, if required, merged. Engage Microsoft Support (CSS) or your backup vendor. This warning identifies a dormant risk; the report has not detected that data loss has occurred.</div>`r`n")
        } elseif ($rd.PSObject.Properties['CannotConfirmMigrationSafe'] -and $rd.CannotConfirmMigrationSafe) {
            $activeCoverage = @(if ($rd.PSObject.Properties['ActiveCkptHistoric'] -and $rd.ActiveCkptHistoric) { @($rd.ActiveCkptHistoric.Coverage) } else { @() })
            $incompleteScopes = @($activeCoverage | Where-Object { -not $_.Sufficient } | ForEach-Object {
                $scope = "{0}/{1}={2}" -f $_.Node, $_.Channel, $_.Status
                if ($_.Status -eq 'Wrapped' -and $_.OldestAvailable) { $scope += " (oldest $(([datetime]$_.OldestAvailable).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ')))" }
                $scope
            }) -join '; '
            $coverageReason = if ($rd.PSObject.Properties['ActiveCkptLogsWrapped'] -and $rd.ActiveCkptLogsWrapped) {
                'At least one required log has wrapped past the searched checkpoint-creation window.'
            } else {
                'No required log was shown to have wrapped past the checkpoint-creation window, but at least one required scope is disabled, unavailable, or failed.'
            }
            [void]$sb.Append("  <div class='callout warn'><strong>SAFETY COULD NOT BE VERIFIED - required Worker/VMMS logs are incomplete.</strong> This VM has an ACTIVE (still-attached) checkpoint created <strong>$(ConvertTo-HtmlText $rd.ActiveCkptOldestCreateUtc)</strong>. Incomplete node/channel scopes: <strong>$(ConvertTo-HtmlText $incompleteScopes)</strong>. $(ConvertTo-HtmlText $coverageReason) The missing logs may contain evidence of a 'fork-commit / merge-failure' that this audit could not detect. Validate the differencing chain and consider a backup vendor or Microsoft Support (CSS) review BEFORE any live migration, quick migration, storage migration, or restart of this VM.</div>`r`n")
        }
        # HOLD STATE: the copy/paste support-case summary lifted verbatim from the per-VM report (collapsed).
        if ($r.Recommendation -eq 'HOLD STATE' -and $rd.PSObject.Properties['SupportCaseSummary'] -and $rd.SupportCaseSummary) {
            [void]$sb.Append("  <details open><summary>Support Case summary (copy/paste for Microsoft Support / your backup vendor)</summary><pre>$(ConvertTo-HtmlText $rd.SupportCaseSummary)</pre></details>`r`n")
        }
        if ($rd.Replication.Enabled) {
            $productSeverity = [string](Get-OptionalPropertyValue $replicaAssessment 'ProductSeverity' 'Unknown')
            $measurementStatus = [string](Get-OptionalPropertyValue $replicaAssessment 'MeasurementStatus' 'Unavailable')
            $replicaNeedsAttention = ([bool](Get-OptionalPropertyValue $replicaAssessment 'IsConcern' $true)) -or
                ([bool](Get-OptionalPropertyValue $replicaAssessment 'HasAdvisory' $false)) -or
                ($productSeverity -ne 'Healthy') -or ($measurementStatus -ne 'Healthy')
            $replicaOpenAttr = if ($replicaNeedsAttention) { ' open' } else { '' }
            $replicaState = [string](Get-OptionalPropertyValue $rd.Replication 'State' 'Unavailable')
            $replicaHealth = [string](Get-OptionalPropertyValue $rd.Replication 'Health' 'Unavailable')
            $replicaMode = [string](Get-OptionalPropertyValue $rd.Replication 'Mode' 'Unavailable')
            $primaryServer = [string](Get-OptionalPropertyValue $rd.Replication 'Primary' 'Unavailable')
            $replicaServer = [string](Get-OptionalPropertyValue $rd.Replication 'Replica' 'Unavailable')
            $measurementsAvailable = [bool](Get-OptionalPropertyValue $replicaAssessment 'MeasurementsAvailable' $false)
            $concernBreaches = @((Get-OptionalPropertyValue $replicaAssessment 'ConcernBreaches' @()))
            $advisoryBreaches = @((Get-OptionalPropertyValue $replicaAssessment 'AdvisoryBreaches' @()))
            $getMetricAssessment = {
                param([string]$Breach)
                if (-not $measurementsAvailable) { return 'Unavailable' }
                if ($concernBreaches -contains $Breach) { return 'Concern' }
                if ($advisoryBreaches -contains $Breach) { return 'Advisory' }
                'Within effective limit'
            }
            $frequencySeconds = [double](Get-OptionalPropertyValue $replicaAssessment 'FrequencySeconds' 0)
            $monitoringIntervalSeconds = [double](Get-OptionalPropertyValue $replicaAssessment 'MonitoringIntervalSeconds' 0)
            $lastReplicationTimeUtc = Get-OptionalPropertyValue $replicaAssessment 'LastReplicationTimeUtc' $null
            $lastReplicationAgeMinutes = Get-OptionalPropertyValue $replicaAssessment 'LastReplicationAgeMinutes' $null
            $lastReplicationText = if ($measurementsAvailable -and $lastReplicationTimeUtc -and ([datetime]$lastReplicationTimeUtc -ne [datetime]::MinValue)) {
                '{0} ({1} ago)' -f ([datetime]$lastReplicationTimeUtc).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ'), (ConvertTo-ReplicaDurationText -Minutes ([double]$lastReplicationAgeMinutes))
            } else { 'Unavailable' }
            $averageReplicationBytes = [long](Get-OptionalPropertyValue $replicaAssessment 'AverageReplicationBytes' 0)
            $pendingBytes = [long](Get-OptionalPropertyValue $replicaAssessment 'PendingBytes' 0)
            $latencySeconds = [double](Get-OptionalPropertyValue $replicaAssessment 'LatencySeconds' 0)
            $successfulCount = [long](Get-OptionalPropertyValue $replicaAssessment 'SuccessfulCount' -1)
            $missedCount = [long](Get-OptionalPropertyValue $replicaAssessment 'MissedCount' 0)
            $missedRatePercent = Get-OptionalPropertyValue $replicaAssessment 'MissedRatePercent' $null
            $effectiveMaxAgeMinutes = [double](Get-OptionalPropertyValue $replicaAssessment 'EffectiveMaxAgeMinutes' 0)
            $effectiveMaxPendingBytes = [long](Get-OptionalPropertyValue $replicaAssessment 'EffectiveMaxPendingBytes' 0)
            $effectiveMaxLatencySeconds = [double](Get-OptionalPropertyValue $replicaAssessment 'EffectiveMaxLatencySeconds' 0)
            $maxMissedRatePercent = [double](Get-OptionalPropertyValue $replicaAssessment 'MaxMissedRatePercent' 0)
            $cycleText = if ($measurementsAvailable) {
                'Successful {0}; missed {1}; missed rate {2}' -f $(if ($successfulCount -ge 0) { $successfulCount } else { 'Unavailable' }), $missedCount, $(if ($null -ne $missedRatePercent) { '{0:N2}%' -f [double]$missedRatePercent } else { 'Unavailable' })
            } else { 'Unavailable' }
            $replicaRows = @(
                [pscustomobject]@{ Signal = 'Product state and health'; Observed = "$replicaState / $replicaHealth"; Guardrail = 'Authoritative Get-VMReplication evidence'; Assessment = $productSeverity }
                [pscustomobject]@{ Signal = 'Relationship'; Observed = "Mode $replicaMode"; Guardrail = "Primary $primaryServer; replica $replicaServer"; Assessment = 'Context' }
                [pscustomobject]@{ Signal = 'Replication cadence'; Observed = $(if ($frequencySeconds -gt 0) { '{0:N1} sec' -f $frequencySeconds } else { 'Unavailable' }); Guardrail = 'Used to calculate relationship-aware limits'; Assessment = 'Context' }
                [pscustomobject]@{ Signal = 'Monitoring window'; Observed = $(if ($monitoringIntervalSeconds -gt 0) { [timespan]::FromSeconds($monitoringIntervalSeconds).ToString() } else { 'Unavailable' }); Guardrail = 'Get-VMReplicationServer monitoring interval'; Assessment = 'Context' }
                [pscustomobject]@{ Signal = 'Last replication'; Observed = $lastReplicationText; Guardrail = $(if ($effectiveMaxAgeMinutes -gt 0) { '{0} effective maximum age' -f (ConvertTo-ReplicaDurationText -Minutes $effectiveMaxAgeMinutes) } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'LastReplicationAge') }
                [pscustomobject]@{ Signal = 'Average replication size'; Observed = $(if ($measurementsAvailable) { ConvertTo-ByteText $averageReplicationBytes } else { 'Unavailable' }); Guardrail = 'Workload baseline for pending-data limit'; Assessment = 'Context' }
                [pscustomobject]@{ Signal = 'Pending replication data'; Observed = $(if ($measurementsAvailable) { ConvertTo-ByteText $pendingBytes } else { 'Unavailable' }); Guardrail = $(if ($effectiveMaxPendingBytes -gt 0) { "$(ConvertTo-ByteText $effectiveMaxPendingBytes) effective maximum" } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'PendingBytes') }
                [pscustomobject]@{ Signal = 'Average replication latency'; Observed = $(if ($measurementsAvailable) { '{0:N1} sec' -f $latencySeconds } else { 'Unavailable' }); Guardrail = $(if ($effectiveMaxLatencySeconds -gt 0) { '{0:N1} sec effective maximum' -f $effectiveMaxLatencySeconds } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'Latency') }
                [pscustomobject]@{ Signal = 'Measured replication cycles'; Observed = $cycleText; Guardrail = $(if ($maxMissedRatePercent -gt 0) { '{0:N2}% maximum missed rate' -f $maxMissedRatePercent } else { 'Count and rate guardrails' }); Assessment = (& $getMetricAssessment 'MissedCount') }
            )
            [void]$sb.Append("  <details$replicaOpenAttr><summary>Hyper-V Replica details - $(ConvertTo-HtmlText $replicaState) / $(ConvertTo-HtmlText $replicaHealth); measurements $(ConvertTo-HtmlText $measurementStatus)</summary><table><thead><tr><th>Signal</th><th>Observed</th><th>Effective guardrail / context</th><th>Assessment</th></tr></thead><tbody>")
            foreach ($replicaRow in $replicaRows) {
                $replicaRowNeedsAttention = ($replicaRow.Assessment -in @('Critical', 'Warning', 'Unknown', 'Unavailable', 'Concern', 'Advisory'))
                $observedHtml = if ($replicaRowNeedsAttention) { "<span class='warnval'>$(ConvertTo-HtmlText $replicaRow.Observed)</span>" } else { ConvertTo-HtmlText $replicaRow.Observed }
                $assessmentHtml = if ($replicaRowNeedsAttention) { "<span class='warnval'>$(ConvertTo-HtmlText $replicaRow.Assessment)</span>" } else { ConvertTo-HtmlText $replicaRow.Assessment }
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $replicaRow.Signal)</td><td>$observedHtml</td><td>$(ConvertTo-HtmlText $replicaRow.Guardrail)</td><td>$assessmentHtml</td></tr>")
            }
            $replicaReason = [string](Get-OptionalPropertyValue $replicaAssessment 'Reason' 'Detailed measurement assessment was unavailable.')
            [void]$sb.Append("</tbody></table><p class='muted'>$(ConvertTo-HtmlText $replicaReason) Product health/state remains authoritative; measurement advisories do not change the VM verdict by themselves.</p></details>`r`n")
        }
        # Checkpoints table.
        if ($ckptCount -gt 0) {
            [void]$sb.Append("  <details open><summary>Checkpoints ($ckptCount)</summary><table><thead><tr><th>Name</th><th>Type</th><th>Purpose</th><th>Created (UTC)</th><th>Age</th><th>Stale</th><th>Parent</th></tr></thead><tbody>")
            foreach ($c in @($rd.Checkpoints | Sort-Object AgeHrs -Descending)) {
                # Stale YES is amber (matches the summary table's stale-count colour); NO stays plain.
                $staleTxt = if ($c.Stale) { "<span class='warnval'>YES</span>" } else { 'NO' }
                $ageText = '{0} h<br>{1} d' -f $c.AgeHrs, [math]::Round([double]$c.AgeHrs / 24, 1)
                $ageCell = if ($c.Stale) { "<span class='warnval'>$ageText</span>" } else { $ageText }
                $parentDisplay = if ($c.PSObject.Properties['ParentDisplay']) { [string]$c.ParentDisplay } elseif ([string]::IsNullOrWhiteSpace([string]$c.Parent)) { 'n/a (root)' } else { [string]$c.Parent }
                [void]$sb.Append("<tr><td class='ckptname'>$(ConvertTo-HtmlText $c.Name)</td><td>$(ConvertTo-HtmlText $c.Type)</td><td>$(ConvertTo-HtmlText $c.Purpose)</td><td>$(ConvertTo-HtmlText $c.Created)</td><td class='num ckptage'>$ageCell</td><td>$staleTxt</td><td>$(ConvertTo-HtmlText $parentDisplay)</td></tr>")
            }
            [void]$sb.Append("</tbody></table></details>`r`n")
        }
        # Attached chain evidence supports stale-layer and representation-mismatch findings even when
        # Get-VMSnapshot exposes no corresponding named checkpoint.
        $attachedVhdLayers = if ($rd.PSObject.Properties['AttachedVhdLayers']) { @($rd.AttachedVhdLayers) } else { @() }
        if (@($attachedVhdLayers | Where-Object { $_.Type -eq 'Differencing' }).Count -gt 0) {
            [void]$sb.Append("  <details open><summary>Attached VHD chain evidence ($(@($attachedVhdLayers).Count) layer(s))</summary><div class='chain-scroll'><table class='chain-evidence'><thead><tr><th>Layer</th><th>Role</th><th>Layer file</th><th>Type</th><th>Size (GB)</th><th>Created (UTC)</th><th>Checkpoint age</th><th>Last activity</th><th>Checkpoint stale</th></tr></thead><tbody>")
            $previousChainName = $null
            foreach ($layer in $attachedVhdLayers) {
                $checkpointStale = [bool](Get-OptionalPropertyValue $layer 'CheckpointStale' (Get-OptionalPropertyValue $layer 'Stale' $false))
                $checkpointAgeHrs = Get-OptionalPropertyValue $layer 'CheckpointAgeHrs' (Get-OptionalPropertyValue $layer 'AgeHrs' $null)
                $lastActivityAgeHrs = Get-OptionalPropertyValue $layer 'LastActivityAgeHrs' $null
                $chainName = [string](Get-OptionalPropertyValue $layer 'Chain' (Get-OptionalPropertyValue $layer 'Disk' ''))
                $fileName = [string](Get-OptionalPropertyValue $layer 'FileName' (Split-Path ([string]$layer.Path) -Leaf))
                $role = [string](Get-OptionalPropertyValue $layer 'Role' $(if ($layer.Type -eq 'Differencing') { if ([int]$layer.Layer -eq 1) { 'Active (top)' } else { 'Checkpoint' } } elseif ($layer.Type -in @('Dynamic', 'Fixed')) { 'Base' } else { "Attached ($($layer.Type))" }))
                $checkpointStaleText = if ($layer.Type -in @('Dynamic', 'Fixed')) { 'n/a (base)' } elseif ($checkpointStale) { "<span class='warnval'>YES</span>" } elseif ($layer.Type -eq 'Differencing') { 'NO' } else { 'n/a' }
                $checkpointAgeText = if ($null -ne $checkpointAgeHrs) { '{0} h<br>{1} d' -f $checkpointAgeHrs, [math]::Round([double]$checkpointAgeHrs / 24, 1) } else { 'n/a' }
                $checkpointAge = if ($checkpointStale -and $null -ne $checkpointAgeHrs) { "<span class='warnval'>$checkpointAgeText</span>" } else { $checkpointAgeText }
                $lastActivityText = if ($null -ne $lastActivityAgeHrs) { '{0} h<br>{1} d<br><span class="muted">{2}</span>' -f $lastActivityAgeHrs, [math]::Round([double]$lastActivityAgeHrs / 24, 1), (ConvertTo-HtmlText $layer.LastWrite) } else { '-' }
                if ($chainName -ne $previousChainName) {
                    [void]$sb.Append("<tr class='chain-group'><th colspan='9'>Attached chain: <code>$(ConvertTo-HtmlText $chainName)</code></th></tr>")
                    $previousChainName = $chainName
                }
                [void]$sb.Append("<tr><td class='num'>$($layer.Layer)</td><td>$(ConvertTo-HtmlText $role)</td><td class='chain-file'>$(ConvertTo-HtmlText $fileName)</td><td>$(ConvertTo-HtmlText $layer.Type)</td><td class='num'>$($layer.SizeGB)</td><td class='chain-time'>$(ConvertTo-HtmlText $layer.Created)</td><td class='num ckptage'>$checkpointAge</td><td class='num ckptage'>$lastActivityText</td><td>$checkpointStaleText</td></tr>")
            }
            [void]$sb.Append("</tbody></table></div><details class='chain-paths'><summary>Full path and parent-path evidence</summary><div class='chain-scroll'><table><thead><tr><th>Layer file</th><th>Full path</th><th>Parent path</th></tr></thead><tbody>")
            foreach ($layer in $attachedVhdLayers) {
                $fileName = [string](Get-OptionalPropertyValue $layer 'FileName' (Split-Path ([string]$layer.Path) -Leaf))
                $parentPathDisplay = if ($layer.Type -in @('Dynamic', 'Fixed') -and [string]::IsNullOrWhiteSpace([string]$layer.ParentPath)) { 'n/a (base)' } else { [string]$layer.ParentPath }
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $fileName)</td><td><code>$(ConvertTo-HtmlText $layer.Path)</code></td><td><code>$(ConvertTo-HtmlText $parentPathDisplay)</code></td></tr>")
            }
            [void]$sb.Append("</tbody></table></div></details><p class='muted'><strong>Layer order:</strong> Active (top) is the child the VM currently writes to; each Checkpoint row is its next differencing-disk parent; Base is the terminal VHDX parent. Checkpoint age is measured from AVHDX creation. Last activity is measured independently from LastWrite and can remain near zero while an old active checkpoint is continuously written. Base VHDX files are not checkpoints and always show <code>n/a (base)</code>. A differencing <code>.avhdx</code> layer can remain attached even when <code>Get-VMSnapshot</code> exposes no named checkpoint. Validate the chain and the responsible backup/checkpoint job before migration, restart, merge, or removal.</p></details>`r`n")
        }
        # Orphaned .avhdx files table (present on disk in this VM's folder(s) but NOT attached to any
        # chain). v0.2.14: per-orphan class + age + a neutral 'Likely / action' read. NEVER states
        # 'safe to delete' - the action and decision always rest with the operator.
        if (@($rd.Orphans).Count -gt 0) {
            [void]$sb.Append("  <details open><summary>Orphaned .avhdx files ($($rd.OrphanCount)) - on disk but NOT attached to the VM</summary><table><thead><tr><th>File Name</th><th>Size (GB)</th><th>Created (UTC)</th><th>LastWrite (UTC)</th><th>Age</th><th>Likely / action</th><th>Full path</th></tr></thead><tbody>")
            foreach ($o in @($rd.Orphans)) {
                # Age shown in BOTH hours and days (stacked), matching the Checkpoints table above.
                $ageTxt = if ($null -ne $o.AgeHrs) { "<span class='warnval'>$('{0} h<br>{1} d' -f $o.AgeHrs, $o.AgeDays)</span>" } else { '-' }
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $o.Name)</td><td class='num'>$($o.SizeGB)</td><td>$(ConvertTo-HtmlText $o.Created)</td><td>$(ConvertTo-HtmlText $o.LastWrite)</td><td class='num ckptage'>$ageTxt</td><td>$(ConvertTo-HtmlText $o.Likely)</td><td><code>$(ConvertTo-HtmlText $o.FullName)</code></td></tr>")
            }
            [void]$sb.Append("</tbody></table><p class='muted'>Orphaned <code>.avhdx</code> files are on disk but are not attached to the VM. They may remain from a rollback, failed merge, backup, or live-mount operation and may contain required recovery data. <strong>Do not move, rename, merge, or delete these files based only on this report.</strong> Match each file to the VM's backup, restore, live-mount, instant-recovery, or replica-seed history at its Created and LastWrite times. Stop live-mount or instant-recovery sessions through the backup product. For Replica files, review <code>Get-VMReplication</code> health and follow the approved Replica recovery procedure. Before any file change, confirm ownership and purpose, verify that a current backup exists, and use a procedure approved by the backup vendor or Microsoft Support. The 'Likely / action' column provides file-specific guidance.</p></details>`r`n")
        }
        # Historic cross-node event correlation (v0.2.14) - only present when this VM had orphans.
        if ($rd.PSObject.Properties['Historic'] -and $rd.Historic) {
            $hc = $rd.Historic
            $openAttr = if ([int]$hc.MatchCount -gt 0) { ' open' } else { '' }
            [void]$sb.Append("  <details$openAttr><summary>Historic event correlation ($($hc.MatchCount) match(es) around orphan timestamps, across $(@($hc.NodesSearched).Count) node(s))</summary>")
            [void]$sb.Append("<p class='muted'>Searched &plusmn;$($hc.WindowMinutes) min around each orphan's create and last-write times (windows: $(ConvertTo-HtmlText ((@($hc.Windows)) -join ', '))) across all cluster nodes, for this VM's fork-commit / merge events that may predate the $($rd.EventLookbackHours)h lookback.</p>")
            if ([int]$hc.MatchCount -gt 0) {
                if ($rd.HistoricForkConfirmed) {
                    $historicCsvText = if ($rd.EventsCsvName) { " The structured rows used by this verdict are in this VM's events CSV, <code>$(ConvertTo-HtmlText $rd.EventsCsvName)</code>." } else { '' }
                    [void]$sb.Append("<div class='callout high'><strong>Confirmed historic 'fork-commit / merge failure'.</strong> Historic events for this VM were recovered around the orphan timestamps (outside the standard window). A historic event can remain valid when recorded on a former owner node: current VM ownership does not invalidate VM-ID-attributed evidence from another cluster node.$historicCsvText This is strong evidence the rollback DID occur - engage Microsoft Support (CSS) / your backup vendor to recover the orphaned data.</div>")
                }
                [void]$sb.Append("<table><thead><tr><th>Time (UTC)</th><th>Node</th><th>Log</th><th>Id</th><th>Message</th></tr></thead><tbody>")
                foreach ($m in @($hc.Matches)) {
                    [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $m.Time)</td><td>$(ConvertTo-HtmlText $m.Node)</td><td>$(ConvertTo-HtmlText $m.Log)</td><td><code>$($m.Id)</code></td><td>$(ConvertTo-HtmlText $m.Message)</td></tr>")
                }
                [void]$sb.Append("</tbody></table>")
            } else {
                if (-not $hc.CoverageComplete) {
                    $incompleteScopes = @($hc.Coverage | Where-Object { -not $_.Sufficient } | ForEach-Object { "{0}/{1}={2}" -f $_.Node, $_.Channel, $_.Status }) -join '; '
                    [void]$sb.Append("<div class='callout warn'>No historic events found, but event coverage is <strong>incomplete</strong> ($(ConvertTo-HtmlText $incompleteScopes)). The least-retained available history starts at <strong>$(ConvertTo-HtmlText $hc.OldestAvailableUtc)</strong>. A required node/channel was wrapped, disabled, unavailable, or failed, so <strong>absence here is NOT proof</strong> that no rollback occurred.</div>")
                } else {
                    [void]$sb.Append("<div class='callout ok'>No historic fork-commit / merge events for this VM in the searched windows, and the logs DO cover that period (oldest available $(ConvertTo-HtmlText $hc.OldestAvailableUtc)). The orphans are less likely to be a fork-commit rollback - more likely leftover backup / live-mount files. Confirm by matching each file to a backup / restore / live-mount job for this VM at its timestamps; if it is a live-mount, unmount it through the backup product rather than deleting it by hand (see the orphaned-files guidance above for the full steps).</div>")
                }
            }
            [void]$sb.Append("</details>`r`n")
        }
        # Concerning events breakdown - events ATTRIBUTABLE TO THIS VM only (not node-wide). The
        # node-wide total is shown for context, but the itemised list is this VM's own events so the
        # per-VM section never lists another VM's events.
        if ($rd.VmEventConcernCount -gt 0 -and @($rd.EventBreakdown).Count -gt 0) {
            $eventDetailsOpen = if ([int]$rd.VmEscalatingConcernCount -gt 0) { ' open' } else { '' }
            [void]$sb.Append("  <details$eventDetailsOpen><summary>Concerning events attributable to this VM ($($rd.VmEventConcernCount) in $($rd.EventLookbackHours)h)</summary><ul>")
            foreach ($e in @($rd.EventBreakdown)) {
                # Show a single timestamp when there is only one occurrence; a first/last range otherwise.
                $whenTxt = if ([int]$e.Count -le 1 -or "$($e.First)" -eq "$($e.Last)") { "at $(ConvertTo-HtmlText $e.First)" } else { "first $(ConvertTo-HtmlText $e.First), last $(ConvertTo-HtmlText $e.Last)" }
                [void]$sb.Append("<li><code>$($e.Id)</code> &times;$($e.Count) ($whenTxt) - $(ConvertTo-HtmlText $e.Sample)</li>")
            }
            [void]$sb.Append("</ul>")
            $nodeOnlyCount = [int]$rd.EventConcernCount - [int]$rd.VmEventConcernCount
            if ($nodeOnlyCount -gt 0) {
                [void]$sb.Append("<p class='muted'>A further $nodeOnlyCount concerning event(s) on this node reference OTHER VMs (or no VM) - node context only, not attributed to this VM and not listed here.</p>")
            }
            $csvPtr = @()
            if ($rd.EventsCsvName) { $csvPtr += "this VM's events in <code>$(ConvertTo-HtmlText $rd.EventsCsvName)</code>" }
            if ($rd.PSObject.Properties['NodeEventsCsvName'] -and $rd.NodeEventsCsvName) { $csvPtr += "node-wide detail in <code>$(ConvertTo-HtmlText $rd.NodeEventsCsvName)</code>" }
            if ($csvPtr.Count -gt 0) { [void]$sb.Append("<p class='muted'>Full, untruncated messages: $((($csvPtr) -join '; ')).</p>") }
            [void]$sb.Append("</details>`r`n")
        }
        [void]$sb.Append("  </div>`r`n</details>")
    }
    [void]$sb.Append("</div></details>`r`n")

    # Cluster storage-health snapshot (S2D / CSV) - a strong candidate contributing factor for the
    # checkpoint/merge symptoms (files transiently locked / unavailable during repair-resync or CSV
    # redirection). Read-only lightweight snapshot; points to the CSS deep-diagnostic for more.
    if ($StorageHealth) {
        $sh = $StorageHealth
        $badge = switch ("$($sh.Summary)") { 'Healthy' { 'ok' } 'Unavailable' { 'info' } default { 'warn' } }
        [void]$sb.Append("<details class='report-section' id='cluster-storage-health' open><summary><h2>Cluster storage health (Storage Spaces Direct / CSV)</h2></summary><div class='report-section-body'>`r`n")
        [void]$sb.Append("<div class='callout $badge'><strong>Storage status: $(ConvertTo-HtmlText $sh.Summary).</strong> Read-only snapshot (source node <code>$(ConvertTo-HtmlText $sh.Source)</code>).</div>`r`n")
        [void]$sb.Append("<p><strong>Why this check matters:</strong> storage repair/resync activity, abnormal CSV redirection or state, and unhealthy disks can make checkpoint or merge files temporarily locked or unavailable. A ReFS CSV reporting File System Redirected mode with reason <code>FileSystemReFs</code> is normal on Azure Local / S2D and is not flagged; non-ReFS file-system redirection, block redirection, and paused or offline volumes are treated as abnormal.</p>`r`n")
        if ($storageFaultCollectionStatus -eq 'Success' -and $storageFaults.Count -eq 0) {
            [void]$sb.Append("<div class='callout info'><strong>Health Service collection status: Success; zero active faults returned.</strong> The subsystem health snapshot was collected independently.</div>`r`n")
        } elseif ($storageFaultCollectionStatus -eq 'Failed') {
            $collectionOperation = if ($storageFaultCollection) { [string](Get-OptionalPropertyValue -InputObject $storageFaultCollection -Name 'Operation' -DefaultValue 'Get-HealthFault') } else { 'Get-HealthFault' }
            $collectionCategory = if ($storageFaultCollection) { [string](Get-OptionalPropertyValue -InputObject $storageFaultCollection -Name 'ErrorCategory' -DefaultValue 'Unspecified') } else { 'Unspecified' }
            $collectionException = if ($storageFaultCollection) { [string](Get-OptionalPropertyValue -InputObject $storageFaultCollection -Name 'ExceptionType' -DefaultValue 'Unspecified') } else { 'Unspecified' }
            $collectionMessage = if ($storageFaultCollection) { [string](Get-OptionalPropertyValue -InputObject $storageFaultCollection -Name 'Message' -DefaultValue 'No sanitized error message was captured.') } else { 'No sanitized error message was captured.' }
            $collectionScope = if ($storageFaultCollection) { [string](Get-OptionalPropertyValue -InputObject $storageFaultCollection -Name 'Scope' -DefaultValue $sh.Source) } else { [string]$sh.Source }
            [void]$sb.Append("<div class='callout warn'><strong>Health Service collection status: Failed.</strong> Operation <code>$(ConvertTo-HtmlText $collectionOperation)</code>; scope <code>$(ConvertTo-HtmlText $collectionScope)</code>; category <code>$(ConvertTo-HtmlText $collectionCategory)</code>; exception <code>$(ConvertTo-HtmlText $collectionException)</code>; message: $(ConvertTo-HtmlText $collectionMessage). The subsystem health snapshot was collected independently, so missing fault detail does not negate an observed unhealthy subsystem.$(if ($DebugLogAvailable) { ' Review the run debug log for full diagnostic context.' })</div>`r`n")
        }
        if ($storageDegraded) {
            [void]$sb.Append("<div class='callout warn'><strong>Why this snapshot is non-healthy:</strong> $storageReasonText. This is read-only observed evidence; it does not establish root cause.</div>`r`n")
        }
        if ($storageFaults.Count -gt 0) {
            [void]$sb.Append("<h3>Active storage Health Service faults (read-only evidence)</h3><table><thead><tr><th>Severity</th><th>Reason</th><th>Affected object</th><th>Location</th><th>Recommended action(s)</th></tr></thead><tbody>")
            foreach ($fault in $storageFaults) {
                $severity = Get-OptionalPropertyValue -InputObject $fault -Name 'Severity' -DefaultValue ''
                $reason = Get-OptionalPropertyValue -InputObject $fault -Name 'Reason' -DefaultValue ''
                $affectedObject = Get-OptionalPropertyValue -InputObject $fault -Name 'FaultingObjectDescription' -DefaultValue ''
                $location = Get-OptionalPropertyValue -InputObject $fault -Name 'FaultingObjectLocation' -DefaultValue ''
                $recommendedActions = @(Get-OptionalPropertyValue -InputObject $fault -Name 'RecommendedActions' -DefaultValue @())
                $recommendedActionsHtml = if ($recommendedActions.Count -gt 0) { (@($recommendedActions | ForEach-Object { ConvertTo-HtmlText $_ }) -join '<br>') } else { '' }
                [void]$sb.Append("<tr><td><span class='warnval'>$(ConvertTo-HtmlText $severity)</span></td><td>$(ConvertTo-HtmlText $reason)</td><td>$(ConvertTo-HtmlText $affectedObject)</td><td>$(ConvertTo-HtmlText $location)</td><td>$recommendedActionsHtml</td></tr>")
            }
            [void]$sb.Append("</tbody></table><p><strong>EVIDENCE - </strong>These records come from <code>Get-HealthFault</code> and are displayed as observed diagnostic evidence. Only faults classified under Microsoft's StorHealth entity types are included; unrelated cluster Health Service faults are excluded. Recommended actions are shown exactly as supplied by the matching storage fault.</p>")
        } elseif ($unhealthySubsystems.Count -gt 0) {
            [void]$sb.Append("<p class='muted'><strong>Health Service detail unavailable:</strong> the subsystem state is Unhealthy, but no active fault records are available (collection status: $(ConvertTo-HtmlText $storageFaultCollectionStatus)). This does not negate the unhealthy subsystem observation. Use the Deeper analysis guidance below for the full diagnostic.</p>")
        }
        [void]$sb.Append("<p><strong>Storage knowledge links:</strong></p><ul><li><a href='https://learn.microsoft.com/en-us/windows-server/failover-clustering/health-service-faults' target='_blank' rel='noopener noreferrer'>Health Service faults | Microsoft Learn</a></li><li><a href='https://learn.microsoft.com/en-us/windows-server/storage/storage-spaces/troubleshooting-storage-spaces' target='_blank' rel='noopener noreferrer'>Storage Spaces Direct troubleshooting | Microsoft Learn</a></li></ul>")
        if (@($sh.StorageJobs).Count -gt 0) {
            [void]$sb.Append("<h3>Active storage jobs</h3><table><thead><tr><th>Job</th><th>State</th><th>% complete</th></tr></thead><tbody>")
            foreach ($j in @($sh.StorageJobs)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $j.Name)</td><td>$(ConvertTo-HtmlText $j.State)</td><td class='num'>$(ConvertTo-HtmlText $j.Pct)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if (@($sh.CsvRedirected).Count -gt 0) {
            [void]$sb.Append("<h3>CSVs in an abnormal state (block-redirected, non-ReFS file-system redirected, or paused)</h3><table><thead><tr><th>Volume</th><th>Affected node(s)</th><th>State</th><th>Block reason</th><th>FS reason</th></tr></thead><tbody>")
            foreach ($v in @($sh.CsvRedirected)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $v.Volume)</td><td>$(ConvertTo-HtmlText $v.Nodes)</td><td>$(ConvertTo-HtmlText $v.State)</td><td>$(ConvertTo-HtmlText $v.BlockReason)</td><td>$(ConvertTo-HtmlText $v.FsReason)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
            $hasIncompatibleFileSystemFilter = @($sh.CsvRedirected | Where-Object { [string]$_.FsReason -match '(^|,\s*)IncompatibleFileSystemFilter(,|$)' }).Count -gt 0
            if ($hasIncompatibleFileSystemFilter) {
                $csvStateCommand = 'Get-ClusterSharedVolumeState | Sort-Object VolumeFriendlyName, Node | Format-Table Node, VolumeFriendlyName, StateInfo, BlockRedirectedIOReason, FileSystemRedirectedIOReason -AutoSize'
                $filterInventoryCommand = '$nodes = (Get-ClusterNode).Name' + [Environment]::NewLine + 'Invoke-Command -ComputerName $nodes -ScriptBlock { fltmc filters; fltmc instances }'
                $filterDriverCommand = @'
$filterName = '<filtername>'
Invoke-Command -ComputerName $nodes -ArgumentList $filterName -ScriptBlock {
    param($FilterName)

    $escapedFilterName = $FilterName.Replace("'", "''")
    Get-CimInstance Win32_SystemDriver -Filter ("Name='{0}'" -f $escapedFilterName) |
        Select-Object Name, State, StartMode, PathName

    $servicePath = "HKLM:\SYSTEM\CurrentControlSet\Services\$FilterName"
    if (Test-Path -LiteralPath $servicePath) {
        Get-ItemProperty -LiteralPath $servicePath |
            Select-Object DisplayName, ImagePath, Start, SupportedFeatures
    }
}
'@
                $clusterEventCommand = '$nodes = (Get-ClusterNode).Name' + [Environment]::NewLine + 'Invoke-Command -ComputerName $nodes -ScriptBlock {' + [Environment]::NewLine + "    Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName='Microsoft-Windows-FailoverClustering'; Id=5120,5142; StartTime=(Get-Date).AddDays(-7)} -ErrorAction SilentlyContinue |" + [Environment]::NewLine + '        Select-Object TimeCreated, Id, LevelDisplayName, Message' + [Environment]::NewLine + '}'
                [void]$sb.Append("<div class='callout warn'><strong>Incompatible file-system filter reported:</strong> <code>FileSystemReFs</code> remains expected for ReFS CSVs; the additional <code>IncompatibleFileSystemFilter</code> reason is why this observation requires review. It commonly indicates that a file-system minifilter, such as antivirus, EDR, backup, replication, encryption, or file-monitoring software, is not compatible with the CSV direct-I/O path. This point-in-time state does not identify the responsible product and does not, by itself, prove disk failure or data corruption.</div>")
                [void]$sb.Append("<p><strong>Read-only validation:</strong> confirm that the state persists, compare loaded minifilters and instances on every cluster node, and correlate recent Failover Clustering CSV events.</p>")
                [void]$sb.Append("<pre><code>$(ConvertTo-HtmlText $csvStateCommand)</code></pre>")
                [void]$sb.Append("<pre><code>$(ConvertTo-HtmlText $filterInventoryCommand)</code></pre>")
                [void]$sb.Append("<p><strong>Selected-filter details:</strong> replace <code>&lt;filtername&gt;</code> with a non-Microsoft filter name from <code>fltmc filters</code> to map it to its driver and service registration on every node. Treat <code>SupportedFeatures</code> as collected evidence; confirm its meaning and product support with the driver owner or vendor.</p>")
                [void]$sb.Append("<pre><code>$(ConvertTo-HtmlText $filterDriverCommand.Trim())</code></pre>")
                [void]$sb.Append("<pre><code>$(ConvertTo-HtmlText $clusterEventCommand)</code></pre>")
                [void]$sb.Append("<p><strong>Action boundary:</strong> map non-Microsoft filter names to the installed security, backup, or data-protection product and validate Azure Local / CSV support with its owner or vendor. Do not unload or remove a filter based only on this report; use an approved maintenance procedure. Microsoft guidance: <a href='https://learn.microsoft.com/windows-server/failover-clustering/failover-cluster-csvs' target='_blank' rel='noopener noreferrer'>Cluster Shared Volumes overview</a> and <a href='https://learn.microsoft.com/troubleshoot/windows-server/virtualization/storage-issues-in-hyper-v-and-windows-server-failover-clusters' target='_blank' rel='noopener noreferrer'>Hyper-V and failover-cluster storage troubleshooting</a>.</p>")
            }
        }
        if (@($sh.VDiskUnhealthy).Count -gt 0) {
            [void]$sb.Append("<h3>Unhealthy virtual disks</h3><table><thead><tr><th>Name</th><th>Health</th><th>Operational</th></tr></thead><tbody>")
            foreach ($d in @($sh.VDiskUnhealthy)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $d.Name)</td><td>$(ConvertTo-HtmlText $d.Health)</td><td>$(ConvertTo-HtmlText $d.Operational)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if (@($sh.PDiskUnhealthy).Count -gt 0) {
            [void]$sb.Append("<h3>Unhealthy physical disks</h3><table><thead><tr><th>Name</th><th>Health</th><th>Operational</th><th>Usage</th></tr></thead><tbody>")
            foreach ($d in @($sh.PDiskUnhealthy)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $d.Name)</td><td>$(ConvertTo-HtmlText $d.Health)</td><td>$(ConvertTo-HtmlText $d.Operational)</td><td>$(ConvertTo-HtmlText $d.Usage)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if ("$($sh.Summary)" -eq 'Healthy') {
            [void]$sb.Append("<p class='muted'>No active storage jobs, no redirected CSVs, and no unhealthy virtual / physical disks were detected at snapshot time.</p>")
        }
        if ("$($sh.Summary)" -eq 'Unavailable' -and $sh.Note) {
            [void]$sb.Append("<p class='muted'>Storage cmdlets were not available from the snapshot node: $(ConvertTo-HtmlText $sh.Note)</p>")
        }
        if ($eventFloodHtml) { [void]$sb.Append($eventFloodHtml) }
        [void]$sb.Append("<div class='callout info'><strong>Deeper analysis (recommended):</strong> this is a lightweight snapshot. Validate the current fault state and use your cluster maintenance procedures before performing any recommended action. For a full Storage Spaces Direct / SBL diagnostic - including storage event-channel analysis around the incident window - run Microsoft's CSS Storage Diagnostic, which performs far more checks. Open a Microsoft Support (CSS) support request if you need additional guidance before taking action.<br><code>Install-Module -Name Microsoft.AzLocal.CSSTools</code><br><code>Start-AzsSupportStorageDiagnostic</code><br><a href='https://github.com/Azure/AzureLocal-Supportability/blob/main/tools/CSSTools/1.2605.5.1611/functions/Start-AzsSupportStorageDiagnostic.md' target='_blank' rel='noopener noreferrer'>Start-AzsSupportStorageDiagnostic documentation</a></div>`r`n")
        [void]$sb.Append("</div></details>`r`n")
    } elseif ($eventFloodHtml) {
        [void]$sb.Append("<details class='report-section' id='cluster-storage-health' open><summary><h2>Cluster storage health (Storage Spaces Direct / CSV)</h2></summary><div class='report-section-body'>`r`n")
        [void]$sb.Append("<div class='callout info'><strong>Storage snapshot not collected.</strong> The event-driven observation below remains available, but no storage-health conclusion was produced.</div>`r`n")
        [void]$sb.Append($eventFloodHtml)
        [void]$sb.Append("</div></details>`r`n")
    }

    # Operational observations are intentionally separate from VM health verdicts. These findings
    # improve supportability and consistency but do not, by themselves, prove corruption or root cause.
    [void]$sb.Append(@'
<details class="report-section" id="housekeeping" open>
<summary><h2>Cluster / storage housekeeping to review:</h2></summary>
<div class="report-section-body">
<div class="callout info">
    <strong>WHY THIS MATTERS:</strong> Operational excellence and consistent storage practices improve reliability and reduce operational complexity.
  The observations in this section are not necessarily VM health failures. They identify file placement, ownership,
  naming, inventory, or storage-layout conditions that may make future troubleshooting, backup, migration, and recovery
        operations more difficult. One file can appear in more than one category, so row and category totals may overlap and are not unique-file counts.
                Review each observation before making changes. <strong>Do not move, rename, merge, or delete virtual disk files based solely on this report, all decisions and actions are your responsibility.</strong>
</div>
'@)
    if ($null -ne $HousekeepingFindings -and $HousekeepingFindings.Count -gt 0) {
        $housekeepingCategories = @($HousekeepingFindings | ForEach-Object { [string]$_.Category } | Where-Object { $_ } | Sort-Object -Unique)
        $housekeepingExtensions = @($HousekeepingFindings | ForEach-Object { if ($_.PSObject.Properties['Extension']) { [string]$_.Extension } } | Where-Object { $_ } | Sort-Object -Unique)
        [void]$sb.Append("<div class='hk-tools'><div class='hk-tools-header'><div><strong>Housekeeping filters</strong><div class='muted'>All categories are selected by default. Uncheck a category to remove its rows and update the visible totals and charts.</div></div><button class='hk-export' type='button' id='hk-export-csv' data-cluster='$(ConvertTo-HtmlText $ClusterName)' data-generated='$(ConvertTo-HtmlText $GeneratedUtc)'>Download all findings (CSV)</button></div><div class='hk-categories' role='group' aria-label='Housekeeping categories'>")
        foreach ($category in $housekeepingCategories) { $text = ConvertTo-HtmlText $category; [void]$sb.Append("<label><input class='hk-category-filter' type='checkbox' value='$text' checked> $text</label>") }
        [void]$sb.Append("</div><div class='hk-actions'><button type='button' id='hk-select-all'>Select all</button><button type='button' id='hk-clear-all'>Clear all</button></div><div class='hk-filters'><label>Search filename or path<input id='hk-search' type='search' placeholder='Search findings'></label><label>Storage root<select id='hk-root'><option value=''>All roots</option>")
        foreach ($root in $housekeepingRoots) { $text = ConvertTo-HtmlText $root; [void]$sb.Append("<option value='$text'>$text</option>") }
        [void]$sb.Append("</select></label><label>Extension<select id='hk-extension'><option value=''>All extensions</option>")
        foreach ($extension in $housekeepingExtensions) { $text = ConvertTo-HtmlText $extension; [void]$sb.Append("<option value='$text'>$text</option>") }
        [void]$sb.Append("</select></label><label>Minimum size (MB)<input id='hk-min-size' type='number' min='0' step='1' value='0'></label></div><div class='hk-live' aria-live='polite'><span>Visible findings: <strong id='hk-visible-count'>$(@($HousekeepingFindings).Count)</strong> of $(@($HousekeepingFindings).Count)</span><span>Visible unique-file storage: <strong id='hk-visible-bytes'>$(ConvertTo-HtmlText $housekeepingTotalText)</strong></span><span>Unfiltered unique-file storage: <strong>$(ConvertTo-HtmlText $housekeepingTotalText)</strong></span></div></div>")
        [void]$sb.Append("<div class='hk-charts'><div class='hk-chart'><h3>Visible storage by category</h3><svg id='hk-category-chart' role='img' aria-label='Visible housekeeping storage by category'></svg></div><div class='hk-chart'><h3>Cluster Shared Volume (CSV) paths</h3><svg id='hk-path-chart' role='img' aria-label='Visible housekeeping storage by Cluster Shared Volume'></svg></div></div><div class='hk-empty' id='hk-empty'>No housekeeping findings match the active filters.</div>")
        [void]$sb.Append('<table class="housekeeping" id="hk-table"><colgroup><col class="hk-category"><col class="hk-scope"><col class="hk-filecol"><col class="hk-size"><col class="hk-observation"><col class="hk-review"></colgroup><thead><tr><th aria-sort="none"><button class="hk-sort" type="button" data-sort="category" data-direction="none" aria-label="Sort by Category"><span>Category</span><span class="hk-sort-arrows" aria-hidden="true"><span class="hk-sort-up">&#9650;</span><span class="hk-sort-down">&#9660;</span></span></button></th><th aria-sort="none"><button class="hk-sort" type="button" data-sort="scope" data-direction="none" aria-label="Sort by Scope"><span>Scope</span><span class="hk-sort-arrows" aria-hidden="true"><span class="hk-sort-up">&#9650;</span><span class="hk-sort-down">&#9660;</span></span></button></th><th aria-sort="none"><button class="hk-sort" type="button" data-sort="path" data-direction="none" aria-label="Sort by File or path"><span>File / path</span><span class="hk-sort-arrows" aria-hidden="true"><span class="hk-sort-up">&#9650;</span><span class="hk-sort-down">&#9660;</span></span></button></th><th aria-sort="descending"><button class="hk-sort" type="button" data-sort="bytes" data-direction="descending" aria-label="Sort by Size, currently descending"><span>Size</span><span class="hk-sort-arrows" aria-hidden="true"><span class="hk-sort-up">&#9650;</span><span class="hk-sort-down">&#9660;</span></span></button></th><th>Observation</th><th>Review</th></tr></thead><tbody>')
        $housekeepingDisplayRows = @($housekeepingRows | Sort-Object -Property @{ Expression = { if ($_.PSObject.Properties['Length']) { [long]$_.Length } else { 0 } }; Descending = $true })
        foreach ($finding in $housekeepingDisplayRows) {
            $findingLength = if ($finding.PSObject.Properties['Length']) { [long]$finding.Length } else { 0 }
            $findingFullName = if ($finding.PSObject.Properties['FullName']) { [string]$finding.FullName } else { '' }
            $findingParent = if ($finding.PSObject.Properties['ParentPath']) { [string]$finding.ParentPath } else { '' }
            $findingRoot = if ($finding.PSObject.Properties['CsvRoot']) { [string]$finding.CsvRoot } else { '' }
            $findingExtension = if ($finding.PSObject.Properties['Extension']) { [string]$finding.Extension } else { '' }
            $findingFileName = if ($finding.PSObject.Properties['FileName']) { [string]$finding.FileName } else { '' }
            $findingObservation = if ($finding.PSObject.Properties['Observation']) { [string]$finding.Observation } else { '' }
            $findingReview = if ($finding.PSObject.Properties['Review']) { [string]$finding.Review } else { '' }
            $fileNameHtml = if ($finding.PSObject.Properties['FileName'] -and $finding.FileName) {
                "<div class='hk-file'><code>$(ConvertTo-HtmlText $finding.FileName)</code></div>"
            } else { '' }
            $pathHtml = if ($findingFullName) { "$fileNameHtml<code>$(ConvertTo-HtmlText $findingFullName)</code>" } else { $fileNameHtml }
            $sizeHtml = if ($findingFullName) { ConvertTo-HtmlText (ConvertTo-HousekeepingSizeText $findingLength) } else { '<span class="muted">n/a</span>' }
            $reviewHtml = ConvertTo-HtmlText $finding.Review
            if ([string]$finding.Category -eq 'Unattached base disk candidate') {
                $reviewHtml = $reviewHtml.Replace(
                    '(see housekeeping guidance)',
                    '(see <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#cluster-storage-housekeeping" target="_blank" rel="noopener noreferrer">housekeeping guidance</a>)'
                )
                if ($findingFullName -and $findingExtension -match '^\.vhdx?$') {
                    $reviewHtml += "<div class='hk-image-option'><label><input class='hk-image-filter' type='checkbox'> Filter out as VM image</label></div>"
                }
            }
            [void]$sb.Append(("<tr data-category='{0}' data-scope='{1}' data-path='{2}' data-parent='{3}' data-root='{4}' data-extension='{5}' data-bytes='{6}' data-file-name='{11}' data-observation='{12}' data-review='{13}'><td data-label='Category'>{0}</td><td data-label='Scope'><code>{1}</code></td><td data-label='File / path'>{7}</td><td data-label='Size' class='num'>{8}</td><td data-label='Observation'><p class='hk-observation'>{9}</p></td><td data-label='Review'>{10}</td></tr>" -f `
                (ConvertTo-HtmlText $finding.Category), (ConvertTo-HtmlText $finding.Scope), (ConvertTo-HtmlText $findingFullName), `
                (ConvertTo-HtmlText $findingParent), (ConvertTo-HtmlText $findingRoot), (ConvertTo-HtmlText $findingExtension), `
                $findingLength, $pathHtml, $sizeHtml, (ConvertTo-HtmlText $findingObservation), $reviewHtml, `
                (ConvertTo-HtmlText $findingFileName), (ConvertTo-HtmlText $findingObservation), (ConvertTo-HtmlText $findingReview)))
        }
        [void]$sb.Append("</tbody></table>`r`n")
        [void]$sb.Append("<div class='hk-image-policy' id='hk-image-policy' hidden><h3>Persistent VM image policy settings</h3><p class='muted'>The selected <span id='hk-image-count'>0</span> VM image file(s) are hidden only in this open report. Use the generated settings below to exclude them from future audits.</p><ol><li>For a new policy, select <strong>Download checkpoint-health-policy.yml</strong>.</li><li>For an existing policy, select <strong>Copy policy settings</strong>, then copy only the generated <code>- '(?i)^...$'</code> entries into its existing <code>storage.imageLibraryPathPatterns</code> list. Preserve existing entries; do not add duplicate <code>schemaVersion</code>, <code>storage</code>, or <code>imageLibraryPathPatterns</code> keys.</li><li>Supply the saved YAML file to the original audit command with <code>-PolicyPath '.\checkpoint-health-policy.yml'</code>, then review the newly generated report.</li></ol><p class='muted'>These settings affect housekeeping observations only. They do not change VM health verdicts or authorize modifying the selected files.</p><ul class='hk-image-policy-list' id='hk-image-policy-list'></ul><textarea id='hk-image-policy-yaml' readonly aria-label='Generated VM image policy settings'></textarea><div class='hk-actions'><button type='button' id='hk-download-policy'>Download checkpoint-health-policy.yml</button><button type='button' id='hk-copy-policy'>Copy policy settings</button><button type='button' id='hk-restore-images'>Restore all rows</button><span class='muted' id='hk-policy-status' aria-live='polite'></span></div></div>`r`n")
    } else {
        [void]$sb.Append('<p class="muted">No cluster or storage housekeeping observations were produced by the checks performed in this run. This is not a comprehensive storage-layout certification.</p>')
    }
    [void]$sb.Append("</div></details>`r`n")

    # Information (anonymised RCA background) + footer.
    [void]$sb.Append(@'
<details class="report-section" id="appendix" open>
<summary><h2>Appendix - Knowledge and Information</h2></summary>
<div class="report-section-body">
<p class="muted">Reference material to help interpret this report. Both sections below are <strong>collapsed by default</strong>
to keep the report concise - click the <strong style="color:#0b1220;background:#38bdf8;padding:1px 8px;border-radius:999px;font-size:11.5px">&#9654; Show</strong>
button on either heading to expand it.</p>
<p class="muted">Reference: Microsoft Learn - Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures: <a href="https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage" target="_blank" rel="noopener noreferrer">learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage</a></p>

<details class="appx">
<summary>Diagnostic event IDs - severity classification (how this tool grades each signal)</summary>
<div class="appx-body">
<div class="callout info">
  This is how <strong>this tool</strong> classifies each Hyper-V event ID / HRESULT when deciding a VM''s verdict. It
  scans two Windows event providers - <code>Microsoft-Windows-Hyper-V-Worker-Admin</code> and
  <code>Microsoft-Windows-Hyper-V-VMMS-Admin</code> - and also matches the HRESULT strings
  <code>0x80048102</code>, <code>0x800480BD</code>, <code>0x800480BC</code>, <code>0x80070020</code>,
  <code>0x800703EE</code>, <code>0x80070002</code> in the message text. (The <em>failure-mode forensic role</em> of
  each signal - leading / trigger / symptom - is described in the technical-details section below; that framing is
  complementary to the verdict grading here.)
</div>
<table>
<thead><tr><th>Classification</th><th>Channel</th><th>Event ID / HRESULT</th><th>Description</th><th>Effect on the verdict</th></tr></thead>
<tbody>
  <tr><td><span class="pill hold">HOLD STATE</span></td><td>Hyper-V-Worker</td><td>Event <code>3216</code> (<code>0x800703EE</code>)</td><td>Failed to switch to the new differencing disks during checkpoint</td><td rowspan="4">Fork-commit signature. Drives <strong>HOLD STATE</strong> when found together with one or more unmerged differencing (<code>.avhdx</code>) layer(s).</td></tr>
  <tr><td><span class="pill hold">HOLD STATE</span></td><td>Hyper-V-VMMS</td><td><code>0x80048102</code></td><td><code>VM_E_COMMIT_FORKS_ERROR</code> - the checkpoint fork-commit failed</td></tr>
  <tr><td><span class="pill hold">HOLD STATE</span></td><td>Hyper-V-VMMS (Replica)</td><td><code>0x800480BD</code></td><td><code>VM_E_FR_CHANGE_TRACKING_FAILED</code> - Replica change-tracking failure (leading indicator)</td></tr>
  <tr><td><span class="pill hold">HOLD STATE</span></td><td>Hyper-V-VMMS (Replica)</td><td><code>0x800480BC</code></td><td><code>VM_E_FR_RESYNC_REQUIRED</code> - Replica relationship broken (leading indicator)</td></tr>
    <tr><td><span class="pill investigate">INVESTIGATE</span></td><td>Hyper-V-VMMS</td><td>Event <code>18012</code></td><td>Checkpoint operation failed</td><td>High-signal checkpoint-request failure. A later background-merge completion (<code>19080</code>) may belong to another operation and does not prove this request recovered; review recurrence and the corresponding backup/checkpoint job.</td></tr>
    <tr><td><span class="pill investigate">INVESTIGATE</span></td><td>Hyper-V-VMMS</td><td>Event <code>19100</code></td><td>Background disk merge FAILED to complete (e.g. <code>0x80070020</code> sharing violation)</td><td>High-signal merge failure. A later <code>19080</code> within the configured correlation window can indicate apparent recovery. Recovery is confirmed only when both events contain the same disk or operation identifier and no persistent file or checkpoint remains.</td></tr>
    <tr><td><span class="pill investigate">INVESTIGATE</span></td><td>Hyper-V-VMMS</td><td>Event <code>16300</code></td><td>Cannot load a virtual machine configuration</td><td>High-signal configuration-load failure. A later merge completion does not resolve this separate failure class.</td></tr>
  <tr><td><strong class="muted">Low-signal</strong></td><td>Hyper-V-Worker</td><td>Event <code>3280</code></td><td>Related checkpoint / disk error</td><td rowspan="5">Context only. Surfaced (and still drives <em>discovery</em> of at-risk VMs) but, on its own, does NOT change an otherwise-clean VM''s verdict - a genuine leftover is caught separately by the orphaned-<code>.avhdx</code> scan.</td></tr>
  <tr><td><strong class="muted">Low-signal</strong></td><td>Hyper-V-VMMS</td><td>Event <code>12240</code></td><td>Attachment <code>.avhdx</code> not found (<code>0x80070002</code>)</td></tr>
  <tr><td><strong class="muted">Low-signal</strong></td><td>Hyper-V-VMMS</td><td>Event <code>15268</code></td><td>Failed to get disk information (storage / housekeeping chatter)</td></tr>
  <tr><td><strong class="muted">Low-signal</strong></td><td>Hyper-V-VMMS</td><td>Event <code>19090</code></td><td>Background disk merge INTERRUPTED - transient; Hyper-V normally completes the merge later</td></tr>
  <tr><td><strong class="muted">Low-signal</strong></td><td>Hyper-V-VMMS</td><td>Event <code>32510</code></td><td>Stale <code>.hrl</code> delete / merge housekeeping</td></tr>
  <tr><td><strong class="muted">Informational</strong></td><td>Hyper-V-VMMS</td><td>Event <code>18500</code></td><td>VM started successfully</td><td rowspan="4">Normal lifecycle. Listed for the timeline / context and NEVER flagged as a concern.</td></tr>
  <tr><td><strong class="muted">Informational</strong></td><td>Hyper-V-VMMS</td><td>Event <code>18510</code></td><td>Checkpoint completed</td></tr>
  <tr><td><strong class="muted">Informational</strong></td><td>Hyper-V-VMMS</td><td>Event <code>19070</code></td><td>Background disk merge started</td></tr>
  <tr><td><strong class="muted">Informational</strong></td><td>Hyper-V-VMMS</td><td>Event <code>19080</code></td><td>Background disk merge FINISHED successfully</td></tr>
</tbody>
</table>
</div>
</details>

<details class="appx">
<summary>Technical details of the 'checkpoint fork-commit / merge-failure' signature</summary>
<div class="appx-body">
<div class="callout info">
  <strong>Generic technical background</strong> - this section contains no customer, host or VM-specific data. It
  explains the failure mode this audit looks for and the exact Event IDs / error codes that indicate it is present.
</div>
<p><strong>What it is.</strong> When Hyper-V takes a checkpoint (including the checkpoint a backup product creates
automatically), the running disk is frozen and writes are redirected into a new differencing <code>.avhdx</code>.
When the checkpoint is later removed, Hyper-V must <em>commit</em> (merge) that fork back into its parent and rewrite
each disk''s on-disk configuration (<code>.vmcx</code>). If that <strong>fork-commit</strong> step fails, the per-disk
<code>.vmcx</code> can be reverted <em>inconsistently</em>: the VM keeps running normally on its in-memory chain, but
the on-disk chain metadata no longer matches. The inconsistency stays <strong>dormant</strong> until the VM is
live-migrated or restarted - at which point Hyper-V reopens the on-disk chain and can <strong>roll the disks back to
their base</strong>, orphaning everything written into the <code>.avhdx</code> layer(s) since the checkpoint.</p>
<p><strong>How it typically unfolds:</strong></p>
<ol>
  <li><strong>Leading indicators</strong> - Hyper-V Replica change-tracking / resync failures (<code>0x800480BD</code>, <code>0x800480BC</code>).</li>
  <li><strong>Trigger</strong> - the checkpoint fork-commit fails: VMMS event <code>18590</code> with <code>0x80048102</code> (<code>VM_E_COMMIT_FORKS_ERROR</code>), or Worker event <code>3216</code> (<code>0x800703EE</code>, failed to switch to the new differencing disks).</li>
  <li><strong>Per-disk revert</strong> leaves the <code>.vmcx</code> chain inconsistent (traced only on the Hyper-V-VMMS/Analytic channel, which is off by default).</li>
  <li><strong>Symptoms</strong> - backup retries then fail to open the disk (<code>0x80070020</code>, sharing violation); follow-on merges are interrupted / fail (<code>19090</code> / <code>19100</code>).</li>
    <li><strong>Dormant risk exposed by a state change</strong> - the VM may continue to run, but a live migration or restart can reopen the chain and cause the disks to roll back.</li>
</ol>
<p><strong>Event IDs and error codes treated as the signature:</strong></p>
<table>
<thead><tr><th>Signal</th><th>Channel</th><th>Meaning</th><th>Role</th></tr></thead>
<tbody>
  <tr><td>HRESULT <code>0x80048102</code> (typically with VMMS event <code>18590</code>)</td><td>Hyper-V-VMMS</td><td><code>VM_E_COMMIT_FORKS_ERROR</code> - the checkpoint fork-commit failed</td><td><strong>Confirming</strong> (drives HOLD STATE)</td></tr>
  <tr><td>Event <code>18590</code> <em>without</em> a fork-commit HRESULT</td><td>Hyper-V-Worker</td><td>Guest-OS bugcheck / fatal error (e.g. Stop <code>0x7E</code>) - the VM crashed; this is NOT a checkpoint fork-commit</td><td>Context only (does not drive HOLD STATE)</td></tr>
  <tr><td>Event <code>3216</code> + <code>0x800703EE</code></td><td>Hyper-V-Worker</td><td>Failed to switch to the new differencing disks during checkpoint</td><td><strong>Confirming</strong></td></tr>
  <tr><td><code>0x800480BD</code></td><td>Replica</td><td><code>VM_E_FR_CHANGE_TRACKING_FAILED</code></td><td>Leading indicator</td></tr>
  <tr><td><code>0x800480BC</code></td><td>Replica</td><td><code>VM_E_FR_RESYNC_REQUIRED</code></td><td>Leading indicator</td></tr>
  <tr><td>Event <code>18012</code></td><td>Hyper-V-VMMS</td><td>Checkpoint operation failed</td><td>Corroborating</td></tr>
  <tr><td>Event <code>19090</code> / <code>19100</code></td><td>Hyper-V-VMMS</td><td>Background disk merge interrupted / failed (<code>0x80070020</code>)</td><td>Corroborating</td></tr>
  <tr><td>Event <code>12240</code> / <code>15268</code></td><td>Hyper-V-VMMS</td><td>Attachment <code>.avhdx</code> not found / failed to get disk information (<code>0x80070002</code>)</td><td>Corroborating</td></tr>
  <tr><td>Event <code>16300</code></td><td>Hyper-V-VMMS</td><td>Cannot load a virtual machine configuration</td><td>Corroborating</td></tr>
</tbody>
</table>
<p><strong>How the verdict is decided.</strong> A VM is flagged <span class="pill hold">HOLD STATE</span> only when a
<strong>confirming</strong> signal above is found <em>together with</em> one or more unmerged differencing
(<code>.avhdx</code>) layers - that combination is the data-loss risk. Concern signals <em>without</em> a confirming
fork-commit signature are flagged <span class="pill investigate">INVESTIGATE</span> (usually a stalled / failed backup
checkpoint or an unhealthy VSS writer), which the operations / backup team should triage first.</p>
</div>
</details>

</div>
</details>

<footer>
    Generated by <code>Get-HyperVVMCheckpointHealth</code> (version __SCRIPTVERSION__). Read-only diagnostic report; no VM state was
  modified. Verdict legend: <span class="pill hold">HOLD STATE</span> fork-commit signature + unmerged
  disks (case-worthy) &nbsp; <span class="pill investigate">INVESTIGATE</span> concern signals, ops/backup
  team first &nbsp; <span class="pill ok">OK</span> no concerns &nbsp; <span class="pill err">ERROR / NOT FOUND</span>.
  <br><br><strong>DISCLAIMER:</strong> EXAMPLE code only - <strong>it is NOT a Microsoft-supported product or service offering</strong>; provided AS IS with NO warranty of any kind (see the MIT License and <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">README.md</a>). It collects READ-ONLY diagnostic data to render this report - it does NOT determine root cause definitively and does NOT remediate anything. Each VM's status is a data-driven analysis of cluster / VM state, diagnostic events and file-system objects. If you require assistance to interpret any findings, or need guidance prior to any remediation, open a Microsoft Support (CSS) support request (SR) case and act on their advice.
  <br><br><a href="https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback" target="_blank" rel="noopener noreferrer">Share feedback / report an issue</a>
</footer>
</div>
<script>
window.addEventListener('load', function () {
    var table = document.getElementById('hk-table');
    if (table) {
        var body = table.tBodies[0];
        var rows = Array.prototype.slice.call(body.rows);
        var categoryBoxes = Array.prototype.slice.call(document.querySelectorAll('.hk-category-filter'));
        var search = document.getElementById('hk-search');
        var root = document.getElementById('hk-root');
        var extension = document.getElementById('hk-extension');
        var minSize = document.getElementById('hk-min-size');
        var visibleCount = document.getElementById('hk-visible-count');
        var visibleBytes = document.getElementById('hk-visible-bytes');
        var empty = document.getElementById('hk-empty');
        var imageBoxes = Array.prototype.slice.call(document.querySelectorAll('.hk-image-filter'));
        var imagePolicy = document.getElementById('hk-image-policy');
        var imageCount = document.getElementById('hk-image-count');
        var imageList = document.getElementById('hk-image-policy-list');
        var imageYaml = document.getElementById('hk-image-policy-yaml');
        var policyStatus = document.getElementById('hk-policy-status');
        var sortAscending = { bytes: false };
        function formatBytes(bytes) {
            var readable = bytes > 0 ? '< 1 KB' : '0 KB';
            if (bytes >= 1099511627776) { readable = (bytes / 1099511627776).toFixed(2) + ' TB'; }
            else if (bytes >= 1073741824) { readable = (bytes / 1073741824).toFixed(2) + ' GB'; }
            else if (bytes >= 1048576) { readable = (bytes / 1048576).toFixed(2) + ' MB'; }
            else if (bytes >= 1024) { readable = (bytes / 1024).toFixed(2) + ' KB'; }
            return readable;
        }
        function drawChart(id, values) {
            var svg = document.getElementById(id);
            while (svg.firstChild) { svg.removeChild(svg.firstChild); }
            var entries = Object.keys(values).map(function (key) { return { key: key || 'Unspecified', value: values[key] }; });
            entries.sort(function (left, right) { return right.value - left.value; });
            entries = entries.slice(0, 8);
            var width = 620, rowHeight = 30, height = Math.max(60, entries.length * rowHeight + 10);
            svg.setAttribute('viewBox', '0 0 ' + width + ' ' + height);
            if (!entries.length) {
                var none = document.createElementNS('http://www.w3.org/2000/svg', 'text');
                none.setAttribute('x', '8'); none.setAttribute('y', '30'); none.setAttribute('fill', '#94a3b8');
                none.textContent = 'No visible file-size data'; svg.appendChild(none); return;
            }
            var max = entries[0].value || 1;
            entries.forEach(function (entry, index) {
                var y = index * rowHeight + 5;
                var label = document.createElementNS('http://www.w3.org/2000/svg', 'text');
                label.setAttribute('x', '0'); label.setAttribute('y', y + 14); label.setAttribute('fill', '#cbd5e1'); label.setAttribute('font-size', '11');
                label.textContent = entry.key.length > 30 ? entry.key.substring(0, 29) + '...' : entry.key; svg.appendChild(label);
                var bar = document.createElementNS('http://www.w3.org/2000/svg', 'rect');
                bar.setAttribute('x', '215'); bar.setAttribute('y', y); bar.setAttribute('width', Math.max(1, 250 * entry.value / max)); bar.setAttribute('height', '17'); bar.setAttribute('rx', '2'); bar.setAttribute('fill', '#38bdf8'); svg.appendChild(bar);
                var value = document.createElementNS('http://www.w3.org/2000/svg', 'text');
                value.setAttribute('x', '475'); value.setAttribute('y', y + 14); value.setAttribute('fill', '#e2e8f0'); value.setAttribute('font-size', '11'); value.textContent = formatBytes(entry.value); svg.appendChild(value);
            });
        }
        function escapeRegex(value) {
            return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        }
        function selectedImageBoxes() {
            return imageBoxes.filter(function (box) { return box.checked; });
        }
        function csvVolumeName(rootPath) {
            var match = /^c:\\clusterstorage\\([^\\]+)(?:\\|$)/i.exec(rootPath || '');
            return match ? match[1] : (rootPath || 'Unspecified');
        }
        function csvEscape(value) {
            var text = value === null || value === undefined ? '' : String(value);
            return /[",\r\n]/.test(text) ? '"' + text.replace(/"/g, '""') + '"' : text;
        }
        function housekeepingExportName(button) {
            var cluster = (button.getAttribute('data-cluster') || 'cluster').replace(/[<>:"/\\|?*\x00-\x1F]/g, '_').replace(/\s+/g, '_');
            var generated = button.getAttribute('data-generated') || '';
            var match = /(\d{4})-(\d{2})-(\d{2})[^\d]?(\d{2})[:.]?(\d{2})[:.]?(\d{2})/.exec(generated);
            var timestamp = match ? match[1] + '-' + match[2] + '-' + match[3] + '_' + match[4] + match[5] + match[6] + 'Z' : 'unknown-time';
            return 'CheckpointHousekeeping-' + cluster + '-' + timestamp + '.csv';
        }
        function exportHousekeepingCsv() {
            var button = document.getElementById('hk-export-csv');
            var headers = ['Category', 'Scope', 'FileName', 'FullName', 'ParentPath', 'CsvRoot', 'Extension', 'LengthBytes', 'Observation', 'Review'];
            var lines = [headers.map(csvEscape).join(',')];
            rows.forEach(function (row) {
                var values = ['category', 'scope', 'file-name', 'path', 'parent', 'root', 'extension', 'bytes', 'observation', 'review'].map(function (name) {
                    return row.getAttribute('data-' + name) || '';
                });
                lines.push(values.map(csvEscape).join(','));
            });
            var blob = new Blob(['\uFEFF' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
            var url = URL.createObjectURL(blob);
            var link = document.createElement('a');
            link.href = url; link.download = housekeepingExportName(button); document.body.appendChild(link); link.click(); link.remove();
            window.setTimeout(function () { URL.revokeObjectURL(url); }, 0);
        }
        function updateImagePolicy() {
            var selectedBoxes = selectedImageBoxes();
            imagePolicy.hidden = selectedBoxes.length === 0;
            imageCount.textContent = selectedBoxes.length;
            while (imageList.firstChild) { imageList.removeChild(imageList.firstChild); }
            var yamlLines = ['schemaVersion: 1', 'storage:', '    imageLibraryPathPatterns:'];
            selectedBoxes.forEach(function (box) {
                var path = box.closest('tr').getAttribute('data-path') || '';
                yamlLines.push("        - '(?i)^" + escapeRegex(path).replace(/'/g, "''") + "$'");
                var item = document.createElement('li');
                var code = document.createElement('code'); code.textContent = path; item.appendChild(code);
                var restore = document.createElement('button'); restore.type = 'button'; restore.textContent = 'Restore';
                restore.addEventListener('click', function () { box.checked = false; applyFilters(); });
                item.appendChild(restore); imageList.appendChild(item);
            });
            imageYaml.value = selectedBoxes.length ? yamlLines.join('\n') : '';
            policyStatus.textContent = '';
        }
        function downloadImagePolicy() {
            if (!imageYaml.value) { return; }
            var content = imageYaml.value.replace(/\r?\n/g, '\r\n') + '\r\n';
            var blob = new Blob([content], { type: 'application/yaml;charset=utf-8' });
            var url = URL.createObjectURL(blob);
            var link = document.createElement('a');
            link.href = url; link.download = 'checkpoint-health-policy.yml'; document.body.appendChild(link); link.click(); link.remove();
            window.setTimeout(function () { URL.revokeObjectURL(url); }, 0);
            policyStatus.textContent = 'Downloaded checkpoint-health-policy.yml.';
        }
        function applyFilters() {
            var selected = {};
            categoryBoxes.forEach(function (box) { if (box.checked) { selected[box.value] = true; } });
            var query = search.value.toLowerCase();
            var minimumBytes = (parseFloat(minSize.value) || 0) * 1048576;
            var count = 0, bytes = 0, seen = {}, byCategory = {}, byCsvVolume = {};
            rows.forEach(function (row) {
                var path = row.getAttribute('data-path') || '';
                var rowBytes = parseInt(row.getAttribute('data-bytes') || '0', 10);
                var searchable = (path + ' ' + (row.getAttribute('data-scope') || '')).toLowerCase();
                var imageBox = row.querySelector('.hk-image-filter');
                var matches = (!imageBox || !imageBox.checked) && !!selected[row.getAttribute('data-category')] && (!query || searchable.indexOf(query) >= 0) &&
                    (!root.value || row.getAttribute('data-root') === root.value) && (!extension.value || row.getAttribute('data-extension') === extension.value) && rowBytes >= minimumBytes;
                row.style.display = matches ? '' : 'none';
                if (matches) {
                    count++;
                    var identity = path.toLowerCase();
                    if (path && !seen[identity]) {
                        seen[identity] = true; bytes += rowBytes;
                        var category = row.getAttribute('data-category') || 'Unspecified';
                        var csvVolume = csvVolumeName(row.getAttribute('data-root'));
                        byCategory[category] = (byCategory[category] || 0) + rowBytes;
                        byCsvVolume[csvVolume] = (byCsvVolume[csvVolume] || 0) + rowBytes;
                    }
                }
            });
            visibleCount.textContent = count; visibleBytes.textContent = formatBytes(bytes);
            empty.style.display = count ? 'none' : 'block'; table.style.display = count ? '' : 'none';
            drawChart('hk-category-chart', byCategory); drawChart('hk-path-chart', byCsvVolume);
            updateImagePolicy();
        }
        categoryBoxes.forEach(function (box) { box.addEventListener('change', applyFilters); });
        imageBoxes.forEach(function (box) { box.addEventListener('change', applyFilters); });
        [search, root, extension, minSize].forEach(function (control) { control.addEventListener('input', applyFilters); control.addEventListener('change', applyFilters); });
        document.getElementById('hk-select-all').addEventListener('click', function () { categoryBoxes.forEach(function (box) { box.checked = true; }); applyFilters(); });
        document.getElementById('hk-clear-all').addEventListener('click', function () { categoryBoxes.forEach(function (box) { box.checked = false; }); applyFilters(); });
        document.getElementById('hk-export-csv').addEventListener('click', exportHousekeepingCsv);
        document.getElementById('hk-restore-images').addEventListener('click', function () { imageBoxes.forEach(function (box) { box.checked = false; }); applyFilters(); });
        document.getElementById('hk-download-policy').addEventListener('click', downloadImagePolicy);
        document.getElementById('hk-copy-policy').addEventListener('click', function () {
            imageYaml.select(); imageYaml.setSelectionRange(0, imageYaml.value.length);
            var copied = false;
            try { copied = document.execCommand('copy'); } catch (error) { copied = false; }
            if (!copied && navigator.clipboard && window.isSecureContext) {
                navigator.clipboard.writeText(imageYaml.value).then(function () { policyStatus.textContent = 'Copied.'; }, function () { policyStatus.textContent = 'Select the policy text and copy it manually.'; });
            } else { policyStatus.textContent = copied ? 'Copied.' : 'Select the policy text and copy it manually.'; }
        });
        Array.prototype.slice.call(document.querySelectorAll('.hk-sort')).forEach(function (button) {
            button.addEventListener('click', function () {
                var key = button.getAttribute('data-sort'); sortAscending[key] = !sortAscending[key];
                Array.prototype.slice.call(document.querySelectorAll('.hk-sort')).forEach(function (sortButton) {
                    sortButton.setAttribute('data-direction', 'none');
                    sortButton.parentNode.setAttribute('aria-sort', 'none');
                });
                var direction = sortAscending[key] ? 'ascending' : 'descending';
                button.setAttribute('data-direction', direction);
                button.setAttribute('aria-label', 'Sort by ' + button.querySelector('span').textContent + ', currently ' + direction);
                button.parentNode.setAttribute('aria-sort', direction);
                rows.sort(function (left, right) {
                    var leftValue = key === 'bytes' ? parseInt(left.getAttribute('data-bytes'), 10) : (left.getAttribute('data-' + key) || '').toLowerCase();
                    var rightValue = key === 'bytes' ? parseInt(right.getAttribute('data-bytes'), 10) : (right.getAttribute('data-' + key) || '').toLowerCase();
                    return (leftValue < rightValue ? -1 : leftValue > rightValue ? 1 : 0) * (sortAscending[key] ? 1 : -1);
                });
                rows.forEach(function (row) { body.appendChild(row); });
            });
        });
        applyFilters();
    }
    if (!window.location.hash) { return; }
    window.setTimeout(function () {
        var target = document.getElementById(window.location.hash.substring(1));
        if (target) { target.scrollIntoView({ block: 'start' }); window.scrollBy(0, -70); }
    }, 0);
});
</script>
</body>
</html>
'@)
    $html = $sb.ToString() -replace '__SCRIPTVERSION__', [System.Net.WebUtility]::HtmlEncode([string]$ScriptVersion)
    return [regex]::Replace($html, '(?m)^[ \t]+(?=\r?$)', '')
}

Export-ModuleMember -Function ConvertTo-VMCheckpointAuditHtml, ConvertTo-ReplicaDurationText, Get-HyperVEventFloodObservations
