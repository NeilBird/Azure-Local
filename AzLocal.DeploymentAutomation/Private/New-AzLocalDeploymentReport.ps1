Function New-AzLocalDeploymentReport {
    <#
    .SYNOPSIS

    Generates HTML and Markdown deployment status reports.

    .DESCRIPTION

    Takes the output from Get-AzLocalDeploymentStatus and generates a self-contained
    HTML report with summary cards, a color-coded status table, and deployment details.
    Optionally generates a Markdown report suitable for GitHub Step Summary or Azure
    DevOps pipeline annotations.

    The HTML report uses the same visual style as the Pester test reports from
    Invoke-Tests.ps1 (Azure blue gradient header, summary cards, Segoe UI font).

    .PARAMETER StatusResults
    Array of PSCustomObjects from Get-AzLocalDeploymentStatus with properties:
    UniqueID, ClusterName, ResourceGroupName, DeploymentName, DeploymentStatus,
    ProvisioningState, Message, Duration.

    .PARAMETER HtmlOutputPath
    Optional. File path to write the HTML report. If omitted, no HTML is generated.

    .PARAMETER MarkdownOutputPath
    Optional. File path to write the Markdown report. If omitted, no Markdown is generated.

    .PARAMETER ReportTitle
    Optional. Title for the report header. Default: 'Azure Local Deployment Status Report'.

    .NOTES
    Author  : Neil Bird, MSFT
    Version : 0.9.81
    Created : 2025-06-20
    #>

    [OutputType([hashtable])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyCollection()]
        [PSCustomObject[]]$StatusResults,

        [Parameter(Mandatory = $false)]
        [string]$HtmlOutputPath = "",

        [Parameter(Mandatory = $false)]
        [string]$MarkdownOutputPath = "",

        [Parameter(Mandatory = $false)]
        [string]$ReportTitle = "Azure Local Deployment Status Report"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $total = $StatusResults.Count

    # Categorise results
    $succeeded  = @($StatusResults | Where-Object { $_.DeploymentStatus -in @('DeploySucceeded','ValidateSucceeded','ClusterExists') }).Count
    $failed     = @($StatusResults | Where-Object {
        $_.DeploymentStatus -like '*Failed*' -or
        $_.DeploymentStatus -like '*Error' -or
        $_.DeploymentStatus -like '*Canceled*'
    }).Count
    $inProgress = @($StatusResults | Where-Object { $_.DeploymentStatus -like '*InProgress*' }).Count
    $notStarted = @($StatusResults | Where-Object { $_.DeploymentStatus -eq 'NotStarted' }).Count

    # Generate HTML report
    $htmlContent = ""
    if (-not [string]::IsNullOrWhiteSpace($HtmlOutputPath)) {
        $htmlContent = ConvertTo-AzLocalDeploymentHtml -StatusResults $StatusResults `
            -ReportTitle $ReportTitle -Timestamp $timestamp `
            -Total $total -Succeeded $succeeded -Failed $failed `
            -InProgress $inProgress -NotStarted $notStarted

        $outputDir = Split-Path $HtmlOutputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force -WhatIf:$false | Out-Null
        }
        $htmlContent | Out-File -FilePath $HtmlOutputPath -Encoding utf8 -Force -WhatIf:$false
        Write-AzLocalLog "HTML deployment report written to '$HtmlOutputPath'." -Level Success
    }

    # Generate Markdown report
    $markdownContent = ""
    if (-not [string]::IsNullOrWhiteSpace($MarkdownOutputPath)) {
        $markdownContent = ConvertTo-AzLocalDeploymentMarkdown -StatusResults $StatusResults `
            -ReportTitle $ReportTitle -Timestamp $timestamp `
            -Total $total -Succeeded $succeeded -Failed $failed `
            -InProgress $inProgress -NotStarted $notStarted

        $outputDir = Split-Path $MarkdownOutputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force -WhatIf:$false | Out-Null
        }
        $markdownContent | Out-File -FilePath $MarkdownOutputPath -Encoding utf8 -Force -WhatIf:$false
        Write-AzLocalLog "Markdown deployment report written to '$MarkdownOutputPath'." -Level Success
    }

    return @{
        Html     = $htmlContent
        Markdown = $markdownContent
    }
}


########################################
# Private helper: Build HTML report
########################################
Function ConvertTo-AzLocalDeploymentHtml {
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [PSCustomObject[]]$StatusResults,
        [string]$ReportTitle,
        [string]$Timestamp,
        [int]$Total,
        [int]$Succeeded,
        [int]$Failed,
        [int]$InProgress,
        [int]$NotStarted
    )

    # Load System.Web for HtmlEncode with an actionable failure if unavailable.
    if (-not ([System.Management.Automation.PSTypeName]'System.Web.HttpUtility').Type) {
        try {
            Add-Type -AssemblyName System.Web -ErrorAction Stop
        } catch {
            throw "Unable to generate HTML deployment report because System.Web could not be loaded. $($_.Exception.Message)"
        }
    }

    # Calculate progress percentages
    $pctSucceeded  = if ($Total -gt 0) { [math]::Round(($Succeeded  / $Total) * 100, 1) } else { 0 }
    $pctFailed     = if ($Total -gt 0) { [math]::Round(($Failed     / $Total) * 100, 1) } else { 0 }
    $pctInProgress = if ($Total -gt 0) { [math]::Round(($InProgress / $Total) * 100, 1) } else { 0 }
    $pctNotStarted = if ($Total -gt 0) { [math]::Round(($NotStarted / $Total) * 100, 1) } else { 0 }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append(@"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>$([System.Web.HttpUtility]::HtmlEncode($ReportTitle))</title>
    <style>
        :root {
            --success-color: #28a745;
            --failure-color: #dc3545;
            --warning-color: #ffc107;
            --info-color: #17a2b8;
            --pending-color: #6c757d;
            --bg-color: #f8f9fa;
            --card-bg: #ffffff;
            --text-color: #212529;
            --border-color: #dee2e6;
        }
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-color);
            line-height: 1.6;
            padding: 20px;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        header {
            background: linear-gradient(135deg, #0078d4, #005a9e);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 20px;
            box-shadow: 0 4px 6px rgba(0,0,0,0.1);
        }
        header h1 { font-size: 2em; margin-bottom: 10px; }
        header p { opacity: 0.9; }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }
        .summary-card {
            background: var(--card-bg);
            padding: 20px;
            border-radius: 8px;
            text-align: center;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            border-left: 4px solid var(--border-color);
        }
        .summary-card.succeeded { border-left-color: var(--success-color); }
        .summary-card.failed    { border-left-color: var(--failure-color); }
        .summary-card.progress  { border-left-color: var(--warning-color); }
        .summary-card.notstarted { border-left-color: var(--pending-color); }
        .summary-card.total     { border-left-color: #0078d4; }
        .summary-card .number {
            font-size: 2.5em; font-weight: bold; display: block;
        }
        .summary-card.succeeded .number  { color: var(--success-color); }
        .summary-card.failed .number     { color: var(--failure-color); }
        .summary-card.progress .number   { color: var(--warning-color); }
        .summary-card.notstarted .number { color: var(--pending-color); }
        .summary-card.total .number      { color: #0078d4; }
        .summary-card .label {
            text-transform: uppercase; font-size: 0.85em;
            color: #6c757d; letter-spacing: 1px;
        }
        .progress-bar-container {
            background: var(--card-bg);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .progress-bar-container h3 { margin-bottom: 10px; }
        .progress {
            height: 30px; background: #e9ecef;
            border-radius: 15px; overflow: hidden; display: flex;
        }
        .progress-succeeded  { background: var(--success-color); }
        .progress-failed     { background: var(--failure-color); }
        .progress-inprogress { background: var(--warning-color); }
        .progress-notstarted { background: var(--pending-color); }
        .cluster-table {
            background: var(--card-bg);
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            overflow: hidden;
            margin-bottom: 20px;
        }
        .cluster-table h2 {
            background: #f1f3f5;
            padding: 15px 20px;
            border-bottom: 1px solid var(--border-color);
        }
        table {
            width: 100%; border-collapse: collapse;
        }
        th {
            background: #f8f9fa; padding: 12px 16px;
            text-align: left; font-weight: 600;
            border-bottom: 2px solid var(--border-color);
            white-space: nowrap;
        }
        td {
            padding: 12px 16px;
            border-bottom: 1px solid #f1f3f5;
        }
        tr:hover td { background: #f8f9fa; }
        .status-badge {
            display: inline-block; padding: 4px 12px;
            border-radius: 12px; font-size: 0.85em;
            font-weight: 600; white-space: nowrap;
        }
        .status-succeeded  { background: #d4edda; color: #155724; }
        .status-failed     { background: #f8d7da; color: #721c24; }
        .status-inprogress { background: #fff3cd; color: #856404; }
        .status-notstarted { background: #e2e3e5; color: #383d41; }
        .message-cell {
            max-width: 400px; overflow: hidden;
            text-overflow: ellipsis; white-space: nowrap;
        }
        .message-cell:hover { white-space: normal; }
        footer {
            text-align: center; padding: 20px;
            color: #6c757d; font-size: 0.9em;
        }
    </style>
</head>
<body>
<div class="container">
    <header>
        <h1>$([System.Web.HttpUtility]::HtmlEncode($ReportTitle))</h1>
        <p>Generated $Timestamp</p>
    </header>

    <div class="summary">
        <div class="summary-card total">
            <span class="number">$Total</span>
            <span class="label">Total Clusters</span>
        </div>
        <div class="summary-card succeeded">
            <span class="number">$Succeeded</span>
            <span class="label">Succeeded</span>
        </div>
        <div class="summary-card failed">
            <span class="number">$Failed</span>
            <span class="label">Failed</span>
        </div>
        <div class="summary-card progress">
            <span class="number">$InProgress</span>
            <span class="label">In Progress</span>
        </div>
        <div class="summary-card notstarted">
            <span class="number">$NotStarted</span>
            <span class="label">Not Started</span>
        </div>
    </div>

    <div class="progress-bar-container">
        <h3>Overall Progress</h3>
        <div class="progress">
            <div class="progress-succeeded" style="width: $pctSucceeded%;" title="Succeeded: $Succeeded ($pctSucceeded%)"></div>
            <div class="progress-failed" style="width: $pctFailed%;" title="Failed: $Failed ($pctFailed%)"></div>
            <div class="progress-inprogress" style="width: $pctInProgress%;" title="In Progress: $InProgress ($pctInProgress%)"></div>
            <div class="progress-notstarted" style="width: $pctNotStarted%;" title="Not Started: $NotStarted ($pctNotStarted%)"></div>
        </div>
    </div>

    <div class="cluster-table">
        <h2>Cluster Status Details</h2>
        <table>
            <thead>
                <tr>
                    <th>UniqueID</th>
                    <th>Cluster Name</th>
                    <th>Resource Group</th>
                    <th>Status</th>
                    <th>Provisioning</th>
                    <th>Message</th>
                </tr>
            </thead>
            <tbody>
"@)

    foreach ($result in $StatusResults) {
        $badgeClass = switch -Wildcard ($result.DeploymentStatus) {
            'DeploySucceeded'    { 'status-succeeded' }
            'ValidateSucceeded'  { 'status-succeeded' }
            'ClusterExists'      { 'status-succeeded' }
            '*Failed*'           { 'status-failed' }
            '*Error'             { 'status-failed' }
            '*Canceled*'         { 'status-failed' }
            '*InProgress*'       { 'status-inprogress' }
            'NotStarted'         { 'status-notstarted' }
            default              { 'status-notstarted' }
        }

        $encodedUID     = [System.Web.HttpUtility]::HtmlEncode($result.UniqueID)
        $encodedCluster = [System.Web.HttpUtility]::HtmlEncode($result.ClusterName)
        $encodedRG      = [System.Web.HttpUtility]::HtmlEncode($result.ResourceGroupName)
        $encodedStatus  = [System.Web.HttpUtility]::HtmlEncode($result.DeploymentStatus)
        $encodedProv    = [System.Web.HttpUtility]::HtmlEncode($result.ProvisioningState)
        $encodedMsg     = [System.Web.HttpUtility]::HtmlEncode($result.Message)

        [void]$sb.Append(@"

                <tr>
                    <td><strong>$encodedUID</strong></td>
                    <td>$encodedCluster</td>
                    <td>$encodedRG</td>
                    <td><span class="status-badge $badgeClass">$encodedStatus</span></td>
                    <td>$encodedProv</td>
                    <td class="message-cell" title="$encodedMsg">$encodedMsg</td>
                </tr>
"@)
    }

    if ($Total -eq 0) {
        [void]$sb.Append(@"

                <tr>
                    <td colspan="6" style="text-align: center; color: #6c757d; padding: 30px;">
                        No clusters with ReadyToDeploy = TRUE found in CSV.
                    </td>
                </tr>
"@)
    }

    [void]$sb.Append(@"

            </tbody>
        </table>
    </div>

    <footer>
        <p>Generated by AzLocal.DeploymentAutomation v0.9.81 | $Timestamp</p>
    </footer>
</div>
</body>
</html>
"@)

    return $sb.ToString()
}


########################################
# Private helper: Build Markdown report
########################################
Function ConvertTo-AzLocalDeploymentMarkdown {
    [OutputType([string])]
    [CmdletBinding()]
    param (
        [PSCustomObject[]]$StatusResults,
        [string]$ReportTitle,
        [string]$Timestamp,
        [int]$Total,
        [int]$Succeeded,
        [int]$Failed,
        [int]$InProgress,
        [int]$NotStarted
    )

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.AppendLine("## $ReportTitle")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("**Generated:** $Timestamp")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("### Summary")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("| Status | Count |")
    [void]$sb.AppendLine("|--------|-------|")
    [void]$sb.AppendLine("| Succeeded | $Succeeded |")
    [void]$sb.AppendLine("| Failed | $Failed |")
    [void]$sb.AppendLine("| In Progress | $InProgress |")
    [void]$sb.AppendLine("| Not Started | $NotStarted |")
    [void]$sb.AppendLine("| **Total** | **$Total** |")
    [void]$sb.AppendLine("")

    if ($Total -gt 0) {
        [void]$sb.AppendLine("### Cluster Details")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("| UniqueID | Cluster | Resource Group | Status | Provisioning |")
        [void]$sb.AppendLine("|----------|---------|----------------|--------|--------------|")

        foreach ($result in $StatusResults) {
            $statusIcon = switch -Wildcard ($result.DeploymentStatus) {
                'DeploySucceeded'   { '[PASS]' }
                'ValidateSucceeded' { '[PASS]' }
                'ClusterExists'     { '[PASS]' }
                '*Failed*'          { '[FAIL]' }
                '*Error'            { '[FAIL]' }
                '*Canceled*'        { '[FAIL]' }
                '*InProgress*'      { '[....]' }
                'NotStarted'        { '[----]' }
                default             { '[????]' }
            }
            [void]$sb.AppendLine("| $($result.UniqueID) | $($result.ClusterName) | $($result.ResourceGroupName) | $statusIcon $($result.DeploymentStatus) | $($result.ProvisioningState) |")
        }
        [void]$sb.AppendLine("")
    }

    # Add failed cluster details if any
    $failedResults = @($StatusResults | Where-Object {
        $_.DeploymentStatus -like '*Failed*' -or
        $_.DeploymentStatus -like '*Error' -or
        $_.DeploymentStatus -like '*Canceled*'
    })
    if ($failedResults.Count -gt 0) {
        [void]$sb.AppendLine("### Failed Deployments")
        [void]$sb.AppendLine("")
        foreach ($fail in $failedResults) {
            [void]$sb.AppendLine("- **$($fail.UniqueID)** ($($fail.ClusterName)): $($fail.Message)")
        }
        [void]$sb.AppendLine("")
    }

    return $sb.ToString()
}
