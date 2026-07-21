Set-StrictMode -Version Latest

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
        [bool]$IncludeDiscoveredVMs,
        [string]$ScriptVersion,
        [string]$ReportGenerationTime,
        [int]$ClusterNodeCount,
        [int]$ClusterCsvCount
    )

    function ConvertTo-HtmlText { param([object]$Value) if ($null -eq $Value) { '' } else { [System.Net.WebUtility]::HtmlEncode([string]$Value) } }
    function ConvertTo-ByteText {
        param([long]$Bytes)
        if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
        if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
        if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
        if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
        return ("$Bytes bytes")
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
                'LastReplicationAge' { $parts += ('last replication age {0:N1} min (effective limit {1:N1} min)' -f [double]$Assessment.LastReplicationAgeMinutes, [double]$Assessment.EffectiveMaxAgeMinutes) }
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
    $countIncomplete = $countNotFound + $countError
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
  .wrap{max-width:1120px;margin:0 auto;padding:32px 24px 80px}
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
  .callout{border-radius:10px;padding:14px 18px;margin:16px 0;border:1px solid var(--line)}
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
    .hk-categories,.hk-actions,.hk-live{display:flex;flex-wrap:wrap;gap:8px 16px;margin:10px 0}
    .hk-categories label{display:flex;align-items:center;gap:7px;color:#cbd5e1;font-size:13px}
    .hk-categories input{accent-color:var(--accent)}
    .hk-actions button,.hk-sort{background:var(--panel2);color:var(--ink);border:1px solid var(--line);border-radius:5px;padding:6px 10px;cursor:pointer}
    .hk-sort{width:100%;text-align:left;font-weight:600}
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
  .pill{display:inline-block;padding:2px 9px;border-radius:999px;font-size:11.5px;font-weight:700;white-space:nowrap}
  .pill.investigate{background:var(--amber-bg);color:#fcd34d;border:1px solid #7a5b12}
  .pill.high{background:var(--high-bg);color:#fda4af;border:1px solid #7a2438}
  .pill.ok{background:var(--green-bg);color:#86efac;border:1px solid #1c6b3a}
  .pill.hold{background:var(--red-bg);color:#fca5a5;border:1px solid #7a1f1f}
  .pill.err{background:#2a2f3a;color:#cbd5e1;border:1px solid #475569}
  .vm{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:6px 20px 18px;margin:16px 0}
  .vm.hold{border-color:#7a1f1f;box-shadow:0 0 0 1px #7a1f1f inset}
    .vm h3{display:flex;align-items:center;flex-wrap:wrap;gap:10px}
    .vm-label{color:var(--muted);font-weight:600}
  .kv{display:grid;grid-template-columns:230px 1fr;gap:2px 14px;margin:10px 0}
  .kv div.k{color:var(--muted)}
  ul{margin:8px 0;padding-left:22px} li{margin:3px 0}
  details{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:6px 14px;margin:10px 0}
  summary{cursor:pointer;font-weight:600;color:#cbd5e1}
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
    @media(max-width:980px){.cards{grid-template-columns:repeat(4,minmax(0,1fr))}}
        @media(max-width:760px){
            table:not(.housekeeping){display:block;overflow-x:auto}
            table.housekeeping,table.housekeeping tbody,table.housekeeping tr,table.housekeeping td{display:block;width:100%}
            table.housekeeping{border:0;background:transparent}
            table.housekeeping thead{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
            table.housekeeping tr{margin:0 0 14px;border:1px solid var(--line);border-radius:8px;background:var(--panel);overflow:hidden}
            table.housekeeping td{display:grid;grid-template-columns:110px minmax(0,1fr);gap:12px;padding:9px 11px}
            table.housekeeping td::before{content:attr(data-label);color:var(--muted);font-weight:600}
            table.housekeeping td .hk-observation{grid-column:2;min-width:0}
        }
    @media(max-width:640px){.cards{grid-template-columns:repeat(2,minmax(0,1fr))}}
    @media(max-width:390px){.cards{grid-template-columns:1fr}}
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
    $discoveryMeta = if ($DiscoverySummary) {
        $capText = if ($null -eq $DiscoverySummary.Cap) { 'None' } else { [string]$DiscoverySummary.Cap }
        "<br>Discovery: <b>$($DiscoverySummary.EligibleCount)</b> eligible &nbsp;&bull;&nbsp; <b>$($DiscoverySummary.AuditedCount)</b> auto-audited &nbsp;&bull;&nbsp; <b>$($DiscoverySummary.DeferredCount)</b> deferred &nbsp;&bull;&nbsp; cap: <b>$(ConvertTo-HtmlText $capText)</b>."
    } else { '' }
    [void]$sb.Append(@"
<header class="top">
  <h1>Hyper-V VM Checkpoint Health Audit</h1>
  <div class="meta">
    Cluster <b>$(ConvertTo-HtmlText $ClusterName)</b> &nbsp;&bull;&nbsp; $countAll audited $vmWord
    &nbsp;&bull;&nbsp; Report generated <b>$(ConvertTo-HtmlText $GeneratedUtc) UTC</b>
    &nbsp;&bull;&nbsp; Module version <b>$(ConvertTo-HtmlText $ScriptVersion)</b>$(if ($ReportGenerationTime) { "&nbsp;&bull;&nbsp; Processed <b>$countAll</b> $vmWord, across <b>$nodeCount</b> owning $nodeWord, in <b>$(ConvertTo-HtmlText $ReportGenerationTime)</b>" })<br>$(if ($ClusterNodeCount -gt 0) { "
    Cluster size: <b>$ClusterNodeCount</b> $(if ($ClusterNodeCount -eq 1) { 'node' } else { 'nodes' }) &nbsp;&bull;&nbsp; <b>$ClusterCsvCount</b> Cluster Shared Volume$(if ($ClusterCsvCount -eq 1) { '' } else { 's' })<br>" })
    Parameters: Stale CheckPoint threshold: $StaleHours h; Diagnostic events lookback: $EventLookbackHours h; Include discovered VMs: $(if ($IncludeDiscoveredVMs) { 'Yes' } else { 'No' }).<br>
    Read-only diagnostic - <b>no changes were made to any VM</b>.$discoveryMeta
  </div>
</header>

<div class="cards">
    <div class="card lead"><div class="n">$countAll</div><div class="l">$vmWord audited</div></div>
  <div class="card high"><div class="n">$countHold</div><div class="l">Hold state</div></div>
  <div class="card amber"><div class="n">$countInv</div><div class="l">Investigate</div></div>
  <div class="card green"><div class="n">$countOk</div><div class="l">OK</div></div>
    <div class="card amber"><div class="n">$countIncomplete</div><div class="l">Incomplete</div></div>
    <div class="card amber"><div class="n">$staleAttachedTotal</div><div class="l">Stale AVHDX layers</div></div>
    <div class="card amber"><div class="n">$staleSnapshotTotal</div><div class="l">Stale snapshots</div></div>
  <div class="card amber"><div class="n">$orphanTotal</div><div class="l">Orphaned .avhdx</div></div>
</div>
"@)

    if ($countIncomplete -gt 0) {
        [void]$sb.Append(@"
<div class="callout warn">
  <strong>Incomplete assessment:</strong> $countIncomplete VM(s) returned <strong>NOT FOUND or ERROR</strong> ($countNotFound not found; $countError error). Those VMs were not fully assessed and must not be treated as healthy based on this report.
    When the run was saved with <code>-OutputPath</code>, review the run folder's <code>_debug_log_*.txt</code> for exact failure context. It can contain sensitive operational data. For usage guidance, see <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">the README</a>; to report a reproducible failure, use <a href="https://aka.ms/Get-HyperVVMCheckpointHealth-Feedback" target="_blank" rel="noopener noreferrer">feedback / GitHub issues</a>.
</div>
"@)
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
    <li>This has ALREADY materialised (it is not a dormant HOLD STATE), so the priority is DATA RECOVERY, not a migration hold.</li>
    <li>Do NOT delete the orphaned <code>.avhdx</code> files - they may hold un-recovered data.</li>
    <li>Validate each affected VM's current differencing chain before any live/quick/storage migration or restart.</li>
    <li>Engage Microsoft Support (CSS) and/or your backup vendor for those VMs. See each VM's detail and the "Historic event correlation" below.</li>
        <li><strong>$countInv VM(s) are flagged INVESTIGATE in total:</strong> $pastRollbackAnyCount historic rollback recovery case(s) above and $additionalInvestigateCount additional VM(s) requiring operations / backup-team triage.</li>
        <li><strong>Fleet-wide INVESTIGATE evidence:</strong> $investigateEvidenceText. See Recommended next steps and the per-VM detail below.</li>
  </ul>
</div>
"@)
    } else {
        # Summarise the triage findings (stale checkpoints AND orphaned .avhdx) + the INVESTIGATE count
        # so the Exec Summary reflects EVERY driver, not just stale checkpoints.
        $execBits = @()
        if ($staleAttachedTotal -gt 0) { $execBits += "$staleAttachedTotal stale attached AVHDX layer(s)" }
        if ($staleSnapshotTotal -gt 0) { $execBits += "$staleSnapshotTotal stale named snapshot(s)" }
        if ($orphanTotal -gt 0) { $execBits += "$orphanTotal orphaned .avhdx file(s)" }
        $execTriageLi = if ($countInv -gt 0) {
            $execFound = if ($execBits.Count -gt 0) { ' - findings: ' + ($execBits -join ', ') } else { '' }
            "$countInv VM(s) are flagged INVESTIGATE for the operations / backup team to triage first (see Recommended next steps below)$execFound."
        } elseif ($execBits.Count -gt 0) {
            ($execBits -join ', ') + ' were found - for the operations / backup team to triage first (see Recommended next steps below).'
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
        <li>$housekeepingSummary</li>
    </ul>
</div>
"@)
                }
    }

    # Node-wide events caveat. v0.2.15: the report now shows TWO event counts per VM (per-VM attributed,
    # which drives the verdict, and node-wide for context), so this explains both rather than a single
    # node-wide figure.
    [void]$sb.Append(@'
<div class="callout info">
  <strong>Reading the event counts:</strong> each VM shows <strong>two</strong> figures - a <strong>per-VM</strong>
  count of concern events whose message names <em>that</em> VM (these drive its verdict), and a <strong>node-wide</strong>
  count for context (checkpoint / merge activity across <strong>all</strong> VMs on the owning node, often referencing
  <em>other</em> VMs). Only the node-wide figure is node health context, not proof the audited VM is failing; each VM's
  own attributed events are listed in its section below.
</div>
'@)

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
    $storageDegraded   = ($StorageHealth -and (@('Degraded', 'Active storage jobs') -contains "$($StorageHealth.Summary)"))
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
    $anyContextualStep = ($staleAttachedTotal -gt 0) -or ($staleSnapshotTotal -gt 0) -or ($countInv -gt 0) -or $analyticNeedsEnable -or $storageDegraded -or ($countHold -gt 0) -or ($orphanTotal -gt 0) -or ($rollbackVMs.Count -gt 0) -or ($replicaProductConcernVMs.Count -gt 0) -or ($replicaMeasurementConcernVMs.Count -gt 0) -or ($replicaAdvisoryVMs.Count -gt 0) -or ($activeCkptForkVMs.Count -gt 0) -or ($cannotConfirmVMs.Count -gt 0)
    [void]$sb.Append(@'
<h2>Recommended next steps</h2>
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
    if ($rollbackVMs.Count -gt 0) {
        $rbNames = (@($rollbackVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>PRIORITY - possible historic rollback ({0} VM(s)):</strong> {1} show a cluster of orphaned <code>.avhdx</code> frozen at a common date - the signature of a materialised fork-commit rollback (disks rolled back to base, orphaning the checkpoint layers). Those files may hold un-recovered data. Do NOT remove them; engage Microsoft Support (CSS) / your backup vendor to recover. Because the original events may predate the {2}h lookback, <strong>re-run with a larger window</strong> (e.g. <code>-EventLookbackHours 720</code>) to try to capture them - and see each VM's "Historic event correlation" detail{3}.</li>
'@ -f $rollbackVMs.Count, $rbNames, $EventLookbackHours, $(if ($historicConfirmedVMs.Count -gt 0) { ' (some are already CONFIRMED from recovered historic events)' } else { '' })))
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
  <li><strong>Hyper-V Replica measurements need attention ({0} VM(s)):</strong> {1} materially exceed relationship-aware age, backlog, latency, or missed-replication limits. Review the observed and effective values in each VM card, the monitoring window, and recent network/storage demand. Re-run after the next monitoring interval; escalate to the Replica owner if the condition persists or product health becomes Warning/Critical.</li>
'@ -f $replicaMeasurementConcernVMs.Count, $rmNames))
    }
    if ($replicaAdvisoryVMs.Count -gt 0) {
        $raNames = (@($replicaAdvisoryVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
  <li><strong>Hyper-V Replica measurement advisory ({0} VM(s), no verdict escalation by itself):</strong> {1} have raw health <code>Normal</code> with isolated measurement drift. Review the per-VM values and re-run after the next monitoring interval; investigate only if the drift persists, becomes corroborated, or product health/state degrades.</li>
'@ -f $replicaAdvisoryVMs.Count, $raNames))
    }
    if ($activeCkptForkVMs.Count -gt 0) {
        $acfNames = (@($activeCkptForkVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>HOLD STATE - fork-commit recorded at an active checkpoint's creation ({0} VM(s)):</strong> {1} carry an ACTIVE (still-attached) checkpoint created OUTSIDE the {2}h window, and the historic cross-node scan recovered a 'fork-commit / merge-failure' event around that creation time. The chain may be inconsistent while the VM runs. Do NOT live/quick/storage-migrate or restart these VMs until the differencing chain has been validated (and merged if required); engage Microsoft Support (CSS) / your backup vendor. This is a proactive dormant-risk flag - it has not yet materialised into data loss.</li>
'@ -f $activeCkptForkVMs.Count, $acfNames, $EventLookbackHours))
    }
    if ($cannotConfirmVMs.Count -gt 0) {
        $ccNames = (@($cannotConfirmVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>PRE-MIGRATION - cannot confirm from event data ({0} VM(s)):</strong> {1} carry an ACTIVE checkpoint created outside the normal lookback, but required Worker/VMMS coverage around its creation is incomplete. A required scope may be wrapped, disabled, unavailable, or failed, so absence of evidence is not proof the chain is safe. As a precaution, validate the differencing chain before any live/quick/storage migration or restart; see each VM's detail for the exact incomplete node/channel scopes.</li>
'@ -f $cannotConfirmVMs.Count, $ccNames))
    }
        if ($staleAttachedTotal -gt 0) {
                [void]$sb.Append((@'
    <li><strong>INVESTIGATE - {0} stale attached AVHDX layer(s) across {1} VM(s):</strong> these are readable layers in the active disk chains, regardless of whether <code>Get-VMSnapshot</code> exposes a matching named snapshot. Validate the chain and backup job before migration/restart or any merge/removal action.</li>
'@ -f $staleAttachedTotal, $staleAttachedVMsCount))
        }
        if ($staleSnapshotTotal -gt 0) {
        [void]$sb.Append((@'
    <li><strong>INVESTIGATE - {0} stale named snapshot(s) across {1} VM(s):</strong> backup team first. For each, check your backup product's recent job history (did the last backup complete?) and confirm whether the snapshot is <em>expected</em> or was <em>left behind</em> by a failed / incomplete backup. The action and decision rest with you / your backup team.</li>
'@ -f $staleSnapshotTotal, $staleSnapshotVMsCount))
    }
    if ($eventsOnlyInvVMs.Count -gt 0) {
        $eoNames = (@($eventsOnlyInvVMs | ForEach-Object { ConvertTo-HtmlText $_.VMName }) -join ', ')
        [void]$sb.Append((@'
    <li><strong>INVESTIGATE - VM-attributed checkpoint or merge operations reported failures ({0} VM(s)):</strong> {1} have no current checkpoint, orphan, or Replica product-health issue, but their own high-signal Hyper-V events fired inside the {2}h window. A checkpoint-request failure (<code>18012</code>) does not necessarily create a merge and is not resolved merely by a later <code>19080</code>; merge completion is used as recovery evidence only for a merge-eligible failure such as <code>19100</code>. Steps: (a) open each VM's events <code>.csv</code> and note the exact IDs, timestamps, recurrence, and any disk/operation identifiers; (b) compare those times with that VM's backup/checkpoint job history; (c) engage the backup/checkpoint owner if failures recur across cycles; (d) escalate to Microsoft Support when a <code>3216</code>, fork-commit HRESULT, persistent merge failure, or durable disk artifact is present. In the absence of those signals, this is checkpoint reliability evidence, not proof of chain corruption.</li>
'@ -f $eventsOnlyInvVMs.Count, $eoNames, $EventLookbackHours))
    }
    if ($orphanTotal -gt 0) {
        [void]$sb.Append((@'
  <li><strong>INVESTIGATE - {0} orphaned .avhdx file(s) across {1} VM(s):</strong> do NOT delete blindly - a stuck / failed merge, a failed backup checkpoint, an interrupted instant-recovery / live-mount, or a leftover initial Hyper-V Replica checkpoint can leave these behind. Prescriptive checks (backup team / VM owner): <ol><li><strong>Match each file to a job:</strong> in your backup product's job / activity history, find the backup, restore, instant-recovery / live-mount or replica-seed job for THAT VM that was running at the file's <em>Created</em> / <em>LastWrite</em> time (shown in each VM's detail) - a job that failed or aborted then is the usual cause.</li><li><strong>If it is a live-mount / instant-recovery file</strong> (path contains a mount / recovery folder, or the product shows an active mount): tear the mount down THROUGH the backup product (unmount / stop the recovery session) - do NOT delete the file by hand, which leaves the product's catalog inconsistent.</li><li><strong>If it is a leftover initial-replica recovery point:</strong> check Hyper-V Replica health (<code>Get-VMReplication</code>) and let replication remove it (resume / resync) rather than deleting it manually.</li><li><strong>Before removing anything:</strong> confirm a current, verified backup of the VM exists, then MOVE (rename) the orphan to a quarantine folder instead of deleting, keep it for one retention cycle, confirm the VM stays healthy and its next backup succeeds, and only then delete.</li></ol> Open a Microsoft CSS case for guidance if a file cannot be matched to a job or you are unsure. The action and decision to clean up these file(s) rests with you / the administrator. See each VM's "Orphaned .avhdx files" detail below for names, sizes, timestamps and a per-file read.</li>
'@ -f $orphanTotal, $orphanVMsCount))
    }
    if ($analyticNeedsEnable) {
        [void]$sb.Append(@'
  <li><strong>Enable the Analytic channel</strong> (operator's choice; elevated, per node) to capture the internal per-disk revert trace for the next occurrence: <code>wevtutil sl Microsoft-Windows-Hyper-V-VMMS-Analytic /e:true /q:true</code></li>
'@)
    }
    if ($storageDegraded) {
        [void]$sb.Append(@'
  <li><strong>Rule out storage-layer disruption:</strong> the storage-health section shows active S2D repair / resync jobs, CSV redirection, or unhealthy disks - treat it as a probable contributing factor and run the CSS Storage Diagnostic (<code>Install-Module -Name Microsoft.AzLocal.CSSTools</code>; then <code>Start-AzsSupportStorageDiagnostic</code>).</li>
'@)
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
'@)

    # VM summary table.
    [void]$sb.Append(@'
<h2>VM summary table</h2>
<p class="muted"><strong>VM Source</strong> = <span class="src input">Input</span> (you requested it) or <span class="src discovered">Discovered</span> (auto-added via <code>-IncludeDiscoveredVMs</code>). <strong>Checkpoints</strong> = checkpoint objects (<code>Get-VMSnapshot</code>). <strong>AVHDX files</strong> = active differencing <code>.avhdx</code> layers = <strong>Checkpoints &times; Disks</strong>. <strong>Orphans</strong> = <code>.avhdx</code> on disk but NOT attached. <strong>Stale evidence</strong> = attached AVHDX layers / named snapshots at or beyond the stale threshold. <strong>Concerning Events (VM)</strong> = count of concern events attributed to THIS VM (<code>hi</code> = high-signal that drive the verdict; <code>low</code> = transient / housekeeping only). Rows are ordered by severity within each verdict.</p>
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
            } else {
                $repl = 'Not enabled'
            }
            $stateTxt = ConvertTo-HtmlText $rd.State
            # Concern (VM) cell: attributed concern-event count for THIS VM, annotating whether any are
            # high-signal (drive the verdict) vs low-signal only (transient / housekeeping - no action).
            $concernCell = if ([int]$rd.VmEventConcernCount -gt 0) {
                if ([int]$rd.VmHighConcernCount -gt 0) { "{0} ({1} hi)" -f $rd.VmEventConcernCount, $rd.VmHighConcernCount } else { "{0} (low)" -f $rd.VmEventConcernCount }
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
    [void]$sb.Append("</tbody></table>`r`n")

    # Discovered high-risk VMs (referenced in event data but not in the audit list).
    if ($null -ne $DiscoveredVMs -and $DiscoveredVMs.Count -gt 0) {
        $capReached = $IncludeDiscoveredVMs -and $DiscoverySummary -and ([int]$DiscoverySummary.DeferredCount -gt 0)
        $discoveryHeading = if ($capReached) { 'Discovered VMs not audited - discovery cap reached' } else { 'Discovered high-risk VMs (recommended to audit)' }
        $discoveryCallout = if ($capReached) {
            "These VMs were validated as high-risk discoveries but were deferred because the explicit <code>-MaxDiscoveredVMs $($DiscoverySummary.Cap)</code> limit was reached. Audit them with the command below."
        } else {
            "These VMs were <strong>not in the audit list</strong> but were referenced in this cluster's <strong>high-risk</strong> checkpoint / merge event signals (background disk merge interrupted / failed, sharing violation <code>0x80070020</code>, or 'cannot load VM configuration'). Given the data-loss risk of the fork-commit failure mode, auditing them is recommended."
        }
        [void]$sb.Append("<h2>$discoveryHeading</h2>`r`n")
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
    }

    # Per-VM detail.
    [void]$sb.Append("<h2>Per-VM detailed information</h2>`r`n")
    foreach ($r in $sortedRows) {
        $rd   = $r.ReportData
        $pill = Get-VerdictPill $r.Recommendation
        $cls  = if ($r.Recommendation -eq 'HOLD STATE') { ' hold' } else { '' }
        $srcBadge = ''
        if ($r.PSObject.Properties['Source'] -and $r.Source) {
            $srcCls = if ("$($r.Source)" -eq 'Discovered') { 'discovered' } else { 'input' }
            $srcBadge = "<span class=`"src $srcCls`">$(ConvertTo-HtmlText $r.Source)</span>"
        }
        [void]$sb.Append("<div class=`"vm$cls`" id=`"$(ConvertTo-Anchor $r.VMName)`">`r`n  <h3><span class=`"vm-label`">VM Name:</span> <code>$(ConvertTo-HtmlText $r.VMName)</code> $pill$srcBadge</h3>`r`n")
        if (-not $rd) {
            [void]$sb.Append("  <div class='callout warn'>$(ConvertTo-HtmlText $r.Detail)</div>`r`n</div>")
            continue
        }
        $ckptCount = @($rd.Checkpoints).Count
        $verOld = if ($rd.VmVerOlder) { "Yes - v$(ConvertTo-HtmlText $rd.Version) vs cluster max v$(ConvertTo-HtmlText $rd.HostMaxVersion) (migration/start context only; not a checkpoint cause)." } else { 'No - at the latest supported version.' }
        $analytic = if (@($rd.AnalyticNodesNeedEnable) -contains $r.OwningNode) { 'Not enabled on this node' } else { 'Enabled (or not checked)' }
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
        [void]$sb.Append(@"
  <div class="kv">
    <div class="k">Source</div><div>$(ConvertTo-HtmlText $srcText) $(if ($srcText -eq 'Discovered') { '(auto-added via -IncludeDiscoveredVMs)' } else { '(you requested this VM)' })</div>
    <div class="k">VM state</div><div>$(ConvertTo-HtmlText $rd.State) / $(ConvertTo-HtmlText $rd.Status)</div>
    <div class="k">Owning node</div><div><code>$(ConvertTo-HtmlText $r.OwningNode)</code></div>
    <div class="k">Config version</div><div>$(ConvertTo-HtmlText $rd.Version) (cluster max $(ConvertTo-HtmlText $rd.HostMaxVersion))</div>
    <div class="k">Uptime</div><div>$(ConvertTo-HtmlText $rd.Uptime)</div>
    <div class="k">Attached disks</div><div>$($rd.AttachedDiskCount)</div>
    <div class="k">Checkpoints (Get-VMSnapshot)</div><div>$ckptCount</div>
    <div class="k">Differencing (.avhdx) files</div><div>$(if ([int]$rd.CheckpointLayers -gt 0) { "$($rd.CheckpointLayers) (= checkpoints &times; disks)" } else { '0 (no checkpoints)' })</div>
    <div class="k">VHD chain completeness</div><div>$(if ($rd.PSObject.Properties['ChainComplete'] -and $rd.ChainComplete) { 'Complete' } elseif ($rd.PSObject.Properties['IncompleteChainCount']) { "INCOMPLETE ($($rd.IncompleteChainCount) disk(s) unreadable)" } else { 'Unavailable' })</div>
    <div class="k">Stale attached AVHDX layers (&ge;$($rd.StaleHours)h)</div><div>$(if ($rd.PSObject.Properties['StaleAttachedLayerCount']) { $rd.StaleAttachedLayerCount } else { 0 })</div>
    <div class="k">Stale named snapshots (&ge;$($rd.StaleHours)h)</div><div>$($rd.StaleCheckpointCount)</div>
    <div class="k">Snapshot/layer representation</div><div>$(if ($rd.PSObject.Properties['SnapshotLayerMismatch'] -and $rd.SnapshotLayerMismatch) { 'MISMATCH - only one representation is present' } else { 'Consistent presence' })</div>
    <div class="k">Checkpoint type</div><div>$(ConvertTo-HtmlText $rd.CheckpointType)</div>
    <div class="k">Orphaned .avhdx</div><div>$($rd.OrphanCount)</div>
    <div class="k">Hyper-V Replica</div><div>$(if ($rd.Replication.Enabled) { ConvertTo-HtmlText ("{0} ({1})" -f $rd.Replication.State, $rd.Replication.Health) } else { 'Not enabled' })</div>
    <div class="k">Replica measurement assessment</div><div>$(ConvertTo-HtmlText $replicaMeasurementText)</div>
    <div class="k">VSS writers</div><div>$(ConvertTo-HtmlText $vss)</div>
    <div class="k">Analytic channel</div><div>$(ConvertTo-HtmlText $analytic)</div>
    <div class="k">Policy source</div><div><code>$(ConvertTo-HtmlText $policySourceText)</code></div>
    <div class="k">CSV free-space policy</div><div>$(ConvertTo-HtmlText $csvPolicyText)</div>
    <div class="k">HRL cadence assessment</div><div>$(ConvertTo-HtmlText $hrlPolicyText)</div>
    <div class="k">Config behind latest</div><div>$verOld</div>
    <div class="k">Concerning events - this VM ($($rd.EventLookbackHours)h)</div><div>$($rd.VmEventConcernCount) ($(if ([int]$rd.VmHighConcernCount -gt 0) { "$($rd.VmHighConcernCount) high-signal" } else { 'low-signal only' }))</div>
    <div class="k">Concerning events - node-wide ($($rd.EventLookbackHours)h)</div><div>$($rd.EventConcernCount)$nodeWideNote (references other VMs / none - context only)</div>
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
            if ($rd.PSObject.Properties['StateConsistencyStatus'] -and $rd.StateConsistencyStatus -ne 'Stable') { $drv += "INCONCLUSIVE collection state ($($rd.StateConsistencyStatus))" }
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
            $drvText = if ($drv.Count -gt 0) { (($drv) -join '; ') } else { 'concern signals present' }
            if ($rd.HasRollbackFingerprint) {
                [void]$sb.Append("  <div class='callout high'><strong>INVESTIGATE - possible historic rollback.</strong> Driver: $drvText. The orphaned <code>.avhdx</code> appear to be the aftermath of a materialised fork-commit rollback on <strong>$(ConvertTo-HtmlText $rd.RollbackDate)</strong> - they may hold the data written between the checkpoint and the rollback. Do NOT remove them; engage Microsoft Support (CSS) / your backup vendor to recover. The original fork-commit events may predate the $($rd.EventLookbackHours)h lookback - see the historic correlation below.</div>`r`n")
            } else {
                [void]$sb.Append("  <div class='callout warn'><strong>INVESTIGATE.</strong> Driver: $drvText. The specific checkpoint fork-commit signature was NOT observed in the current window, so on-disk chain corruption is not confirmed - backup-team / operator triage first; no Microsoft case needed yet.</div>`r`n")
                # v0.2.17: when this VM's driver includes HIGH-signal VM-attributed event(s), give a concrete
                # step list naming the actual IDs - otherwise the operator sees 'INVESTIGATE' with no action.
                # These IDs are the VM's OWN checkpoint / merge operations failing (not node-wide chatter),
                # which usually points at a repeatedly failing backup / checkpoint job.
                if ([int]$rd.VmEscalatingConcernCount -gt 0) {
                    $eoIds = if ($rd.PSObject.Properties['VmHighConcernIds'] -and $rd.VmHighConcernIds) { ConvertTo-HtmlText $rd.VmHighConcernIds } else { 'see the events table below' }
                    [void]$sb.Append("  <div class='callout info'><strong>What to INVESTIGATE for this VM - checkpoint/merge reliability:</strong> the high-signal event(s) attributed to this VM are <strong>$eoIds</strong>. A checkpoint-request failure such as <code>18012</code> may occur before any merge exists, so a later <code>19080</code> is not required and is not treated as proof of recovery. <ol><li>Open this VM's events <code>.csv</code> (<code>$(ConvertTo-HtmlText $rd.EventsCsvName)</code>) and review the full messages, timestamps, recurrence, and any disk/operation identifiers.</li><li>Compare those times with this VM's backup/checkpoint job history and identify the operational owner.</li><li>If the failures recur across cycles, engage the backup/checkpoint owner. Escalate to Microsoft Support when a <code>3216</code>, fork-commit HRESULT, persistent merge failure, or durable disk artifact is present.</li><li>Re-run after the next backup cycle. With no stale checkpoint, orphan, fork signature, or matching disk residue, this finding is not proof of chain corruption.</li></ol></div>`r`n")
                }
            }
        } elseif ($r.Recommendation -eq 'OK') {
            if ($rd.PSObject.Properties['HighOpSelfResolved'] -and $rd.HighOpSelfResolved) {
                $recoveryStatus = if ($rd.PSObject.Properties['OperationRecoveryStatus']) { [string]$rd.OperationRecoveryStatus } else { 'ApparentlyRecovered' }
                if ($recoveryStatus -eq 'ConfirmedRecovered') {
                    [void]$sb.Append("  <div class='callout ok'><strong>OK - correlated recovery observed.</strong> $($rd.VmHighOpCount) checkpoint/merge operation-failure event(s) are attributed to this VM, and a bounded later merge completion shares exact operation evidence. No orphaned <code>.avhdx</code>, stale attached layer, or stale snapshot remains. Review the events CSV and backup history if the pattern recurs.</div>`r`n")
                } else {
                    [void]$sb.Append("  <div class='callout info'><strong>OK - apparently recovered operation.</strong> $($rd.VmHighOpCount) checkpoint/merge operation-failure event(s) are followed within the bounded operation window by a successful merge, and no durable artifact remains. The events do <strong>not</strong> share an exact operation identifier, so causal recovery is not proven. Review the events CSV and backup history if this pattern recurs.</div>`r`n")
                }
            } elseif ($rd.LowSignalOnly) {
                [void]$sb.Append("  <div class='callout ok'><strong>OK.</strong> No active checkpoint layers, no orphaned .avhdx, replica healthy and VSS stable. Note: $($rd.VmLowConcernCount) low-signal event(s) are attributed to this VM - e.g. transient 'background disk merge interrupted' (<code>19090</code>) that subsequently completed (no leftover <code>.avhdx</code> remains), or 'failed to get disk information' (<code>15268</code>) storage / housekeeping chatter. These are not, on their own, a concern and need no action.</div>`r`n")
            } else {
                [void]$sb.Append("  <div class='callout ok'><strong>OK.</strong> No active checkpoint layers and no concern signals were found. No action required from this result.</div>`r`n")
            }
        }
        # v0.2.17: PROACTIVE active-checkpoint findings (pre-migration). Rendered for ANY verdict when set,
        # right after the main assessment, because the whole point is to warn BEFORE a migration/restart.
        if ($rd.PSObject.Properties['ActiveCkptForkConfirmed'] -and $rd.ActiveCkptForkConfirmed) {
            [void]$sb.Append("  <div class='callout high'><strong>HOLD STATE - fork-commit recorded at this active checkpoint's creation.</strong> This VM has an ACTIVE (still-attached) checkpoint created <strong>$(ConvertTo-HtmlText $rd.ActiveCkptOldestCreateUtc) UTC</strong> - OLDER than the $($rd.EventLookbackHours)h event lookback - and the historic cross-node scan recovered a 'fork-commit / merge-failure' event around that creation time. The differencing chain may be INCONSISTENT while the VM keeps running; a live/quick/storage migration or restart could materialise it and roll disks back to base. <span class='hot'>Do NOT migrate or restart this VM</span> until the chain has been validated (and merged if required). Engage Microsoft Support (CSS) / your backup vendor. (This has NOT yet materialised into data loss - it is a dormant risk being flagged proactively.)</div>`r`n")
        } elseif ($rd.PSObject.Properties['CannotConfirmMigrationSafe'] -and $rd.CannotConfirmMigrationSafe) {
            $activeCoverage = @(if ($rd.PSObject.Properties['ActiveCkptHistoric'] -and $rd.ActiveCkptHistoric) { @($rd.ActiveCkptHistoric.Coverage) } else { @() })
            $incompleteScopes = @($activeCoverage | Where-Object { -not $_.Sufficient } | ForEach-Object {
                $scope = "{0}/{1}={2}" -f $_.Node, $_.Channel, $_.Status
                if ($_.Status -eq 'Wrapped' -and $_.OldestAvailable) { $scope += " (oldest $(([datetime]$_.OldestAvailable).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC)" }
                $scope
            }) -join '; '
            $coverageReason = if ($rd.PSObject.Properties['ActiveCkptLogsWrapped'] -and $rd.ActiveCkptLogsWrapped) {
                'At least one required log has wrapped past the searched checkpoint-creation window.'
            } else {
                'No required log was shown to have wrapped past the checkpoint-creation window, but at least one required scope is disabled, unavailable, or failed.'
            }
            [void]$sb.Append("  <div class='callout warn'><strong>CANNOT CONFIRM from event data - required Worker/VMMS coverage is incomplete.</strong> This VM has an ACTIVE (still-attached) checkpoint created <strong>$(ConvertTo-HtmlText $rd.ActiveCkptOldestCreateUtc) UTC</strong>. Incomplete node/channel scopes: <strong>$(ConvertTo-HtmlText $incompleteScopes)</strong>. $(ConvertTo-HtmlText $coverageReason) This automation therefore cannot fully check for a 'fork-commit / merge-failure' at that time: absence of evidence here is NOT proof the chain is safe. As a precaution, validate the differencing chain (and consider a backup vendor / Microsoft Support (CSS) review) BEFORE any live/quick/storage migration or restart of this VM.</div>`r`n")
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
                '{0} UTC ({1:N1} min ago)' -f ([datetime]$lastReplicationTimeUtc).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'), [double]$lastReplicationAgeMinutes
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
                [pscustomobject]@{ Signal = 'Last replication'; Observed = $lastReplicationText; Guardrail = $(if ($effectiveMaxAgeMinutes -gt 0) { '{0:N1} min effective maximum age' -f $effectiveMaxAgeMinutes } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'LastReplicationAge') }
                [pscustomobject]@{ Signal = 'Average replication size'; Observed = $(if ($measurementsAvailable) { ConvertTo-ByteText $averageReplicationBytes } else { 'Unavailable' }); Guardrail = 'Workload baseline for pending-data limit'; Assessment = 'Context' }
                [pscustomobject]@{ Signal = 'Pending replication data'; Observed = $(if ($measurementsAvailable) { ConvertTo-ByteText $pendingBytes } else { 'Unavailable' }); Guardrail = $(if ($effectiveMaxPendingBytes -gt 0) { "$(ConvertTo-ByteText $effectiveMaxPendingBytes) effective maximum" } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'PendingBytes') }
                [pscustomobject]@{ Signal = 'Average replication latency'; Observed = $(if ($measurementsAvailable) { '{0:N1} sec' -f $latencySeconds } else { 'Unavailable' }); Guardrail = $(if ($effectiveMaxLatencySeconds -gt 0) { '{0:N1} sec effective maximum' -f $effectiveMaxLatencySeconds } else { 'Unavailable' }); Assessment = (& $getMetricAssessment 'Latency') }
                [pscustomobject]@{ Signal = 'Measured replication cycles'; Observed = $cycleText; Guardrail = $(if ($maxMissedRatePercent -gt 0) { '{0:N2}% maximum missed rate' -f $maxMissedRatePercent } else { 'Count and rate guardrails' }); Assessment = (& $getMetricAssessment 'MissedCount') }
            )
            [void]$sb.Append("  <details$replicaOpenAttr><summary>Hyper-V Replica details - $(ConvertTo-HtmlText $replicaState) / $(ConvertTo-HtmlText $replicaHealth); measurements $(ConvertTo-HtmlText $measurementStatus)</summary><table><thead><tr><th>Signal</th><th>Observed</th><th>Effective guardrail / context</th><th>Assessment</th></tr></thead><tbody>")
            foreach ($replicaRow in $replicaRows) {
                $assessmentHtml = if ($replicaRow.Assessment -in @('Critical', 'Warning', 'Unknown', 'Unavailable', 'Concern', 'Advisory')) { "<span class='warnval'>$(ConvertTo-HtmlText $replicaRow.Assessment)</span>" } else { ConvertTo-HtmlText $replicaRow.Assessment }
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $replicaRow.Signal)</td><td>$(ConvertTo-HtmlText $replicaRow.Observed)</td><td>$(ConvertTo-HtmlText $replicaRow.Guardrail)</td><td>$assessmentHtml</td></tr>")
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
                $ageCell  = '{0} h<br>{1} d' -f $c.AgeHrs, [math]::Round([double]$c.AgeHrs / 24, 1)
                [void]$sb.Append("<tr><td class='ckptname'>$(ConvertTo-HtmlText $c.Name)</td><td>$(ConvertTo-HtmlText $c.Type)</td><td>$(ConvertTo-HtmlText $c.Purpose)</td><td>$(ConvertTo-HtmlText $c.Created)</td><td class='num ckptage'>$ageCell</td><td>$staleTxt</td><td>$(ConvertTo-HtmlText $c.Parent)</td></tr>")
            }
            [void]$sb.Append("</tbody></table></details>`r`n")
        }
        # Orphaned .avhdx files table (present on disk in this VM's folder(s) but NOT attached to any
        # chain). v0.2.14: per-orphan class + age + a neutral 'Likely / action' read. NEVER states
        # 'safe to delete' - the action and decision always rest with the operator.
        if (@($rd.Orphans).Count -gt 0) {
            [void]$sb.Append("  <details open><summary>Orphaned .avhdx files ($($rd.OrphanCount)) - on disk but NOT attached to the VM</summary><table><thead><tr><th>File Name</th><th>Size (GB)</th><th>Created (UTC)</th><th>LastWrite (UTC)</th><th>Age</th><th>Likely / action</th><th>Full path</th></tr></thead><tbody>")
            foreach ($o in @($rd.Orphans)) {
                # Age shown in BOTH hours and days (stacked), matching the Checkpoints table above.
                $ageTxt = if ($null -ne $o.AgeHrs) { '{0} h<br>{1} d' -f $o.AgeHrs, $o.AgeDays } else { '-' }
                [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $o.Name)</td><td class='num'>$($o.SizeGB)</td><td>$(ConvertTo-HtmlText $o.Created)</td><td>$(ConvertTo-HtmlText $o.LastWrite)</td><td class='num ckptage'>$ageTxt</td><td>$(ConvertTo-HtmlText $o.Likely)</td><td><code>$(ConvertTo-HtmlText $o.FullName)</code></td></tr>")
            }
            [void]$sb.Append("</tbody></table><p class='muted'>Orphaned <code>.avhdx</code> are differencing files on disk that are not attached to the VM. They can be the aftermath of a rolled-back / stuck merge (which may hold un-recovered data) or leftover backup / live-mount files. <strong>Do not delete based on this report.</strong> Action (backup team / VM owner): (1) match each file to a backup / restore / live-mount / replica-seed job for this VM at its Created / LastWrite time; (2) if it is a live-mount / instant-recovery file, unmount it THROUGH the backup product rather than deleting it by hand; (3) if it is a leftover initial-replica point, let Hyper-V Replica remove it (resume / resync); (4) before removing anything, confirm a current good backup exists, MOVE (rename) the file to a quarantine folder, keep it one retention cycle, verify the VM and its next backup are healthy, then delete. The 'Likely / action' column above gives the per-file read. The action and decision rest with you / the administrator.</p></details>`r`n")
        }
        # Historic cross-node event correlation (v0.2.14) - only present when this VM had orphans.
        if ($rd.PSObject.Properties['Historic'] -and $rd.Historic) {
            $hc = $rd.Historic
            $openAttr = if ([int]$hc.MatchCount -gt 0) { ' open' } else { '' }
            [void]$sb.Append("  <details$openAttr><summary>Historic event correlation ($($hc.MatchCount) match(es) around orphan timestamps, across $(@($hc.NodesSearched).Count) node(s))</summary>")
            [void]$sb.Append("<p class='muted'>Searched &plusmn;$($hc.WindowMinutes) min around each orphan's create and last-write times (windows: $(ConvertTo-HtmlText ((@($hc.Windows)) -join ', '))) across all cluster nodes, for this VM's fork-commit / merge events that may predate the $($rd.EventLookbackHours)h lookback.</p>")
            if ([int]$hc.MatchCount -gt 0) {
                if ($rd.HistoricForkConfirmed) {
                    [void]$sb.Append("<div class='callout high'><strong>Confirmed historic 'fork-commit / merge failure'.</strong> Historic events for this VM were recovered around the orphan timestamps (outside the standard window). This is strong evidence the rollback DID occur - engage Microsoft Support (CSS) / your backup vendor to recover the orphaned data.</div>")
                }
                [void]$sb.Append("<table><thead><tr><th>Time (UTC)</th><th>Node</th><th>Log</th><th>Id</th><th>Message</th></tr></thead><tbody>")
                foreach ($m in @($hc.Matches)) {
                    [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $m.Time)</td><td>$(ConvertTo-HtmlText $m.Node)</td><td>$(ConvertTo-HtmlText $m.Log)</td><td><code>$($m.Id)</code></td><td>$(ConvertTo-HtmlText $m.Message)</td></tr>")
                }
                [void]$sb.Append("</tbody></table>")
            } else {
                if (-not $hc.CoverageComplete) {
                    $incompleteScopes = @($hc.Coverage | Where-Object { -not $_.Sufficient } | ForEach-Object { "{0}/{1}={2}" -f $_.Node, $_.Channel, $_.Status }) -join '; '
                    [void]$sb.Append("<div class='callout warn'>No historic events found, but event coverage is <strong>incomplete</strong> ($(ConvertTo-HtmlText $incompleteScopes)). The least-retained available history starts at <strong>$(ConvertTo-HtmlText $hc.OldestAvailableUtc) UTC</strong>. A required node/channel was wrapped, disabled, unavailable, or failed, so <strong>absence here is NOT proof</strong> that no rollback occurred.</div>")
                } else {
                    [void]$sb.Append("<div class='callout ok'>No historic fork-commit / merge events for this VM in the searched windows, and the logs DO cover that period (oldest available $(ConvertTo-HtmlText $hc.OldestAvailableUtc) UTC). The orphans are less likely to be a fork-commit rollback - more likely leftover backup / live-mount files. Confirm by matching each file to a backup / restore / live-mount job for this VM at its timestamps; if it is a live-mount, unmount it through the backup product rather than deleting it by hand (see the orphaned-files guidance above for the full steps).</div>")
                }
            }
            [void]$sb.Append("</details>`r`n")
        }
        # Concerning events breakdown - events ATTRIBUTABLE TO THIS VM only (not node-wide). The
        # node-wide total is shown for context, but the itemised list is this VM's own events so the
        # per-VM section never lists another VM's events.
        if ($rd.VmEventConcernCount -gt 0 -and @($rd.EventBreakdown).Count -gt 0) {
            [void]$sb.Append("  <details><summary>Concerning events attributable to this VM ($($rd.VmEventConcernCount) in $($rd.EventLookbackHours)h)</summary><ul>")
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
        [void]$sb.Append("</div>")
    }

    # Cluster storage-health snapshot (S2D / CSV) - a strong candidate contributing factor for the
    # checkpoint/merge symptoms (files transiently locked / unavailable during repair-resync or CSV
    # redirection). Read-only lightweight snapshot; points to the CSS deep-diagnostic for more.
    if ($StorageHealth) {
        $sh = $StorageHealth
        $badge = switch ("$($sh.Summary)") { 'Healthy' { 'ok' } 'Unavailable' { 'info' } default { 'warn' } }
        [void]$sb.Append("<h2>Cluster storage health (Storage Spaces Direct / CSV)</h2>`r`n")
        [void]$sb.Append("<div class='callout $badge'><strong>Storage status: $(ConvertTo-HtmlText $sh.Summary).</strong> Read-only snapshot (source node <code>$(ConvertTo-HtmlText $sh.Source)</code>). Storage-layer disruption - S2D repair / resync jobs, CSV block-redirected or paused state, or unhealthy disks - can cause the very symptoms behind checkpoint / merge failures (files transiently locked or unavailable: <code>0x80070020</code>, <code>0x80070002</code>, 'cannot load VM configuration'). Note: on Azure Local / S2D an <strong>ReFS CSV normally reports File System Redirected mode with reason <code>FileSystemReFs</code></strong> (from <code>Get-ClusterSharedVolumeState</code>) - that is by design (S2D serves the I/O over the software storage bus, so there is no redirect penalty) and is NOT flagged here. Only a NON-ReFS file-system redirect, block redirection, or a paused / offline volume is treated as abnormal.</div>`r`n")
        if (@($sh.StorageJobs).Count -gt 0) {
            [void]$sb.Append("<h3>Active storage jobs</h3><table><thead><tr><th>Job</th><th>State</th><th>% complete</th></tr></thead><tbody>")
            foreach ($j in @($sh.StorageJobs)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $j.Name)</td><td>$(ConvertTo-HtmlText $j.State)</td><td class='num'>$(ConvertTo-HtmlText $j.Pct)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
        }
        if (@($sh.CsvRedirected).Count -gt 0) {
            [void]$sb.Append("<h3>CSVs in an abnormal state (block-redirected, non-ReFS file-system redirected, or paused)</h3><table><thead><tr><th>Volume</th><th>Affected node(s)</th><th>State</th><th>Block reason</th><th>FS reason</th></tr></thead><tbody>")
            foreach ($v in @($sh.CsvRedirected)) { [void]$sb.Append("<tr><td>$(ConvertTo-HtmlText $v.Volume)</td><td>$(ConvertTo-HtmlText $v.Nodes)</td><td>$(ConvertTo-HtmlText $v.State)</td><td>$(ConvertTo-HtmlText $v.BlockReason)</td><td>$(ConvertTo-HtmlText $v.FsReason)</td></tr>") }
            [void]$sb.Append("</tbody></table>")
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
        if (@($sh.Subsystem).Count -gt 0) {
            $subTxt = (@($sh.Subsystem | ForEach-Object { "{0}: {1}" -f $_.Name, $_.Health }) -join '; ')
            [void]$sb.Append("<p class='muted'>Storage subsystem health: $(ConvertTo-HtmlText $subTxt). (A <em>Warning</em> here is often a minor, non-storage fault such as 'update available' - use the CSS diagnostic below for the exact fault.)</p>")
        }
        if ("$($sh.Summary)" -eq 'Healthy') {
            [void]$sb.Append("<p class='muted'>No active storage jobs, no redirected CSVs, and no unhealthy virtual / physical disks were detected at snapshot time.</p>")
        }
        if ("$($sh.Summary)" -eq 'Unavailable' -and $sh.Note) {
            [void]$sb.Append("<p class='muted'>Storage cmdlets were not available from the snapshot node: $(ConvertTo-HtmlText $sh.Note)</p>")
        }
        [void]$sb.Append("<div class='callout info'><strong>Deeper analysis (recommended):</strong> this is a lightweight snapshot. For a full Storage Spaces Direct / SBL diagnostic - including storage event-channel analysis around the incident window - run Microsoft's CSS Storage Diagnostic, which performs far more checks:<br><code>Install-Module -Name Microsoft.AzLocal.CSSTools</code><br><code>Start-AzsSupportStorageDiagnostic</code><br><a href='https://github.com/Azure/AzureLocal-Supportability/blob/main/tools/CSSTools/1.2605.5.1611/functions/Start-AzsSupportStorageDiagnostic.md'>Start-AzsSupportStorageDiagnostic documentation</a></div>`r`n")
    }

    # Operational observations are intentionally separate from VM health verdicts. These findings
    # improve supportability and consistency but do not, by themselves, prove corruption or root cause.
    [void]$sb.Append(@'
<h2 id="housekeeping">Cluster / storage housekeeping to review:</h2>
<div class="callout info">
  <strong>Operational excellence and consistent storage practices improve reliability and reduce operational complexity.</strong>
  The observations in this section are not necessarily VM health failures. They identify file placement, ownership,
  naming, inventory, or storage-layout conditions that may make future troubleshooting, backup, migration, and recovery
    operations more difficult. Review each observation before making changes. <strong>Do not move, rename, merge, or delete virtual disk files based solely on this report.</strong>
</div>
'@)
    if ($null -ne $HousekeepingFindings -and $HousekeepingFindings.Count -gt 0) {
        $housekeepingCategories = @($HousekeepingFindings | ForEach-Object { [string]$_.Category } | Where-Object { $_ } | Sort-Object -Unique)
        $housekeepingRoots = @($HousekeepingFindings | ForEach-Object { if ($_.PSObject.Properties['CsvRoot']) { [string]$_.CsvRoot } } | Where-Object { $_ } | Sort-Object -Unique)
        $housekeepingExtensions = @($HousekeepingFindings | ForEach-Object { if ($_.PSObject.Properties['Extension']) { [string]$_.Extension } } | Where-Object { $_ } | Sort-Object -Unique)
        $seenHousekeepingPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        [long]$housekeepingTotalBytes = 0
        foreach ($finding in @($HousekeepingFindings)) {
            if ($finding.PSObject.Properties['FullName'] -and $finding.FullName -and $seenHousekeepingPaths.Add([string]$finding.FullName)) {
                $housekeepingTotalBytes += [long]$finding.Length
            }
        }
        $housekeepingTotalText = if ($housekeepingTotalBytes -ge 1024) {
            '{0} ({1} bytes)' -f (ConvertTo-ByteText $housekeepingTotalBytes), $housekeepingTotalBytes
        } else { ConvertTo-ByteText $housekeepingTotalBytes }
        [void]$sb.Append("<div class='hk-tools'><strong>Housekeeping filters</strong><div class='muted'>All categories are selected by default. Uncheck a category to remove its rows and update the visible totals and charts.</div><div class='hk-categories' role='group' aria-label='Housekeeping categories'>")
        foreach ($category in $housekeepingCategories) { $text = ConvertTo-HtmlText $category; [void]$sb.Append("<label><input class='hk-category-filter' type='checkbox' value='$text' checked> $text</label>") }
        [void]$sb.Append("</div><div class='hk-actions'><button type='button' id='hk-select-all'>Select all</button><button type='button' id='hk-clear-all'>Clear all</button></div><div class='hk-filters'><label>Search filename or path<input id='hk-search' type='search' placeholder='Search findings'></label><label>Storage root<select id='hk-root'><option value=''>All roots</option>")
        foreach ($root in $housekeepingRoots) { $text = ConvertTo-HtmlText $root; [void]$sb.Append("<option value='$text'>$text</option>") }
        [void]$sb.Append("</select></label><label>Extension<select id='hk-extension'><option value=''>All extensions</option>")
        foreach ($extension in $housekeepingExtensions) { $text = ConvertTo-HtmlText $extension; [void]$sb.Append("<option value='$text'>$text</option>") }
        [void]$sb.Append("</select></label><label>Minimum size (MB)<input id='hk-min-size' type='number' min='0' step='1' value='0'></label></div><div class='hk-live' aria-live='polite'><span>Visible findings: <strong id='hk-visible-count'>$(@($HousekeepingFindings).Count)</strong> of $(@($HousekeepingFindings).Count)</span><span>Visible unique-file storage: <strong id='hk-visible-bytes'>$(ConvertTo-HtmlText $housekeepingTotalText)</strong></span><span>Unfiltered unique-file storage: <strong>$(ConvertTo-HtmlText $housekeepingTotalText)</strong></span></div></div>")
        [void]$sb.Append("<div class='hk-charts'><div class='hk-chart'><h3>Visible storage by category</h3><svg id='hk-category-chart' role='img' aria-label='Visible housekeeping storage by category'></svg></div><div class='hk-chart'><h3>Top visible parent paths</h3><svg id='hk-path-chart' role='img' aria-label='Top visible housekeeping parent paths'></svg></div></div><div class='hk-empty' id='hk-empty'>No housekeeping findings match the active filters.</div>")
        [void]$sb.Append('<table class="housekeeping" id="hk-table"><colgroup><col class="hk-category"><col class="hk-scope"><col class="hk-filecol"><col class="hk-size"><col class="hk-observation"><col class="hk-review"></colgroup><thead><tr><th><button class="hk-sort" type="button" data-sort="category">Category</button></th><th><button class="hk-sort" type="button" data-sort="scope">Scope</button></th><th><button class="hk-sort" type="button" data-sort="path">File / path</button></th><th><button class="hk-sort" type="button" data-sort="bytes">Size</button></th><th>Observation</th><th>Review</th></tr></thead><tbody>')
        foreach ($finding in @($HousekeepingFindings)) {
            $findingLength = if ($finding.PSObject.Properties['Length']) { [long]$finding.Length } else { 0 }
            $findingFullName = if ($finding.PSObject.Properties['FullName']) { [string]$finding.FullName } else { '' }
            $findingParent = if ($finding.PSObject.Properties['ParentPath']) { [string]$finding.ParentPath } else { '' }
            $findingRoot = if ($finding.PSObject.Properties['CsvRoot']) { [string]$finding.CsvRoot } else { '' }
            $findingExtension = if ($finding.PSObject.Properties['Extension']) { [string]$finding.Extension } else { '' }
            $fileNameHtml = if ($finding.PSObject.Properties['FileName'] -and $finding.FileName) {
                "<div class='hk-file'><code>$(ConvertTo-HtmlText $finding.FileName)</code></div>"
            } else { '' }
            $pathHtml = if ($findingFullName) { "$fileNameHtml<code>$(ConvertTo-HtmlText $findingFullName)</code>" } else { $fileNameHtml }
            $sizeHtml = if ($findingFullName) { "$(ConvertTo-HtmlText (ConvertTo-ByteText $findingLength))<br><span class='muted'>$findingLength bytes</span>" } else { '<span class="muted">n/a</span>' }
            $reviewHtml = ConvertTo-HtmlText $finding.Review
            if ([string]$finding.Category -eq 'Unattached base disk candidate') {
                $reviewHtml = $reviewHtml.Replace(
                    '(see README.md)',
                    '(see <a href="https://aka.ms/Get-HyperVVMCheckpointHealth#readme" target="_blank" rel="noopener noreferrer">README.md</a>)'
                )
            }
            [void]$sb.Append(("<tr data-category='{0}' data-scope='{1}' data-path='{2}' data-parent='{3}' data-root='{4}' data-extension='{5}' data-bytes='{6}'><td data-label='Category'>{0}</td><td data-label='Scope'><code>{1}</code></td><td data-label='File / path'>{7}</td><td data-label='Size' class='num'>{8}</td><td data-label='Observation'><p class='hk-observation'>{9}</p></td><td data-label='Review'>{10}</td></tr>" -f `
                (ConvertTo-HtmlText $finding.Category), (ConvertTo-HtmlText $finding.Scope), (ConvertTo-HtmlText $findingFullName), `
                (ConvertTo-HtmlText $findingParent), (ConvertTo-HtmlText $findingRoot), (ConvertTo-HtmlText $findingExtension), `
                $findingLength, $pathHtml, $sizeHtml, (ConvertTo-HtmlText $finding.Observation), $reviewHtml))
        }
        [void]$sb.Append("</tbody></table>`r`n")
    } else {
        [void]$sb.Append('<p class="muted">No cluster or storage housekeeping observations were produced by the checks performed in this run. This is not a comprehensive storage-layout certification.</p>')
    }

    # Information (anonymised RCA background) + footer.
    [void]$sb.Append(@'
<h2>Appendix - Knowledge and Information</h2>
<p class="muted">Reference material to help interpret this report. Both sections below are <strong>collapsed by default</strong>
to keep the report concise - click the <strong style="color:#0b1220;background:#38bdf8;padding:1px 8px;border-radius:999px;font-size:11.5px">&#9654; Show</strong>
button on either heading to expand it.</p>
<p class="muted">Reference: Microsoft Learn - Troubleshoot Hyper-V Virtual Machine Backup, Checkpoint, and Storage Failures: <a href="https://learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage">learn.microsoft.com/en-us/troubleshoot/windows-server/virtualization/hyper-v-virtual-machine-backup-checkpoint-storage</a></p>

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
  <tr><td><span class="pill investigate">INVESTIGATE</span></td><td>Hyper-V-VMMS</td><td>Event <code>18012</code></td><td>Checkpoint operation failed</td><td rowspan="3">High-signal (operation-failure class) for this VM. Drives <strong>INVESTIGATE</strong> only when it did NOT self-resolve - i.e. it was <em>not</em> followed by a successful background merge (<code>19080</code>) and left an orphan / stale layer. A failure that WAS followed by a successful merge with no leftover layer is treated as benign self-healing backup activity (reported OK with a note), not INVESTIGATE.</td></tr>
  <tr><td><span class="pill investigate">INVESTIGATE</span></td><td>Hyper-V-VMMS</td><td>Event <code>19100</code></td><td>Background disk merge FAILED to complete (e.g. <code>0x80070020</code> sharing violation)</td></tr>
  <tr><td><span class="pill investigate">INVESTIGATE</span></td><td>Hyper-V-VMMS</td><td>Event <code>16300</code></td><td>Cannot load a virtual machine configuration</td></tr>
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
  <li><strong>Dormant, then materialised</strong> - the VM runs fine until a live migration or restart reopens the chain and rolls the disks back.</li>
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
        var sortAscending = {};
        function formatBytes(bytes) {
            var readable = bytes + ' bytes';
            if (bytes >= 1099511627776) { readable = (bytes / 1099511627776).toFixed(2) + ' TB'; }
            else if (bytes >= 1073741824) { readable = (bytes / 1073741824).toFixed(2) + ' GB'; }
            else if (bytes >= 1048576) { readable = (bytes / 1048576).toFixed(2) + ' MB'; }
            else if (bytes >= 1024) { readable = (bytes / 1024).toFixed(2) + ' KB'; }
            return readable + (bytes >= 1024 ? ' (' + bytes + ' bytes)' : '');
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
        function applyFilters() {
            var selected = {};
            categoryBoxes.forEach(function (box) { if (box.checked) { selected[box.value] = true; } });
            var query = search.value.toLowerCase();
            var minimumBytes = (parseFloat(minSize.value) || 0) * 1048576;
            var count = 0, bytes = 0, seen = {}, byCategory = {}, byParent = {};
            rows.forEach(function (row) {
                var path = row.getAttribute('data-path') || '';
                var rowBytes = parseInt(row.getAttribute('data-bytes') || '0', 10);
                var searchable = (path + ' ' + (row.getAttribute('data-scope') || '')).toLowerCase();
                var matches = !!selected[row.getAttribute('data-category')] && (!query || searchable.indexOf(query) >= 0) &&
                    (!root.value || row.getAttribute('data-root') === root.value) && (!extension.value || row.getAttribute('data-extension') === extension.value) && rowBytes >= minimumBytes;
                row.style.display = matches ? '' : 'none';
                if (matches) {
                    count++;
                    var identity = path.toLowerCase();
                    if (path && !seen[identity]) {
                        seen[identity] = true; bytes += rowBytes;
                        var category = row.getAttribute('data-category') || 'Unspecified';
                        var parent = row.getAttribute('data-parent') || 'Unspecified';
                        byCategory[category] = (byCategory[category] || 0) + rowBytes;
                        byParent[parent] = (byParent[parent] || 0) + rowBytes;
                    }
                }
            });
            visibleCount.textContent = count; visibleBytes.textContent = formatBytes(bytes);
            empty.style.display = count ? 'none' : 'block'; table.style.display = count ? '' : 'none';
            drawChart('hk-category-chart', byCategory); drawChart('hk-path-chart', byParent);
        }
        categoryBoxes.forEach(function (box) { box.addEventListener('change', applyFilters); });
        [search, root, extension, minSize].forEach(function (control) { control.addEventListener('input', applyFilters); control.addEventListener('change', applyFilters); });
        document.getElementById('hk-select-all').addEventListener('click', function () { categoryBoxes.forEach(function (box) { box.checked = true; }); applyFilters(); });
        document.getElementById('hk-clear-all').addEventListener('click', function () { categoryBoxes.forEach(function (box) { box.checked = false; }); applyFilters(); });
        Array.prototype.slice.call(document.querySelectorAll('.hk-sort')).forEach(function (button) {
            button.addEventListener('click', function () {
                var key = button.getAttribute('data-sort'); sortAscending[key] = !sortAscending[key];
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
    return ($sb.ToString() -replace '__SCRIPTVERSION__', [System.Net.WebUtility]::HtmlEncode([string]$ScriptVersion))
}

Export-ModuleMember -Function ConvertTo-VMCheckpointAuditHtml
