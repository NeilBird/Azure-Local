function Export-ResultsToJUnitXml {
    <#
    .SYNOPSIS
        Exports update results to JUnit XML format for CI/CD pipeline integration.
    .DESCRIPTION
        Converts update operation results to JUnit XML format, which is the de facto
        standard for test results in CI/CD tools. Each cluster update is represented
        as a test case, with success/failure/skipped mapped to JUnit test outcomes.
        
        Supported CI/CD tools:
        - Azure DevOps (Publish Test Results task)
        - GitHub Actions (dorny/test-reporter or similar)
        - Jenkins (JUnit plugin)
        - GitLab CI (native support)
        - TeamCity (built-in)
    .PARAMETER Results
        Array of result objects from update operations.
    .PARAMETER OutputPath
        Path to write the JUnit XML file.
    .PARAMETER TestSuiteName
        Name of the test suite (default: "AzureLocalClusterUpdates").
    .PARAMETER OperationType
        Type of operation being reported (e.g., "Update", "Watch", "TagUpdate").
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Results,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [string]$TestSuiteName = "AzureLocalClusterUpdates",

        [Parameter(Mandatory = $false)]
        [string]$OperationType = "Update"
    )

    # Calculate summary statistics
    $totalTests = $Results.Count
    # v0.7.62: summary <testsuite tests/failures/errors/skipped/> attributes must
    # match the per-testcase elements emitted by the switch below; previously the
    # summary said "0 failures" while individual rows had <failure>, and "0 errors"
    # while UpdateNotFound rows had <error>. Tools like dorny/test-reporter use the
    # summary attributes for the headline numbers, so the discrepancy produced
    # misleading "all green" CI summaries.
    # v0.8.78: ScheduleBlocked / SideloadedBlocked / ExcludedByTag are DESIGNED
    # no-ops (operator-configured gates honoured by Start-AzLocalClusterUpdate),
    # not failures. Previously they emitted <failure> rows, which made dorny/test-
    # reporter flip Step.7 runs RED with '##[error]Failed test were found' even
    # though the cluster simply respected its UpdateStartWindow / UpdateSideloaded /
    # UpdateExcluded tag. They now render as <skipped> alongside NoUpdatesAvailable
    # so legitimate gate-respect outcomes do not look like apply failures.
    # HealthCheckBlocked remains in the failure bucket - a Critical health check
    # blocking an update IS an operational issue the team should action.
    $failures = @($Results | Where-Object { $_.Status -in @("Failed", "Error", "HealthCheckBlocked") }).Count
    $skipped  = @($Results | Where-Object { $_.Status -in @("Skipped", "NotReady", "NotConnected", "NoUpdatesAvailable", "NoReadyUpdates", "ScheduleBlocked", "SideloadedBlocked", "ExcludedByTag") }).Count
    $errors   = @($Results | Where-Object { $_.Status -in @("NotFound", "UpdateNotFound") }).Count
    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    
    # Calculate total time if Duration is available
    $totalTime = 0
    foreach ($result in $Results) {
        if ($result.Duration -and $result.Duration -is [TimeSpan]) {
            $totalTime += $result.Duration.TotalSeconds
        }
        elseif ($result.Duration -and $result.Duration -match '^\d+') {
            # Try to parse duration string
            $totalTime += [double]($result.Duration -replace '[^\d.]', '')
        }
    }

    # Helper function to XML-escape strings
    function ConvertTo-XmlSafeString {
        param([string]$Text)
        if (-not $Text) { return "" }
        return $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&apos;'
    }

    # Build XML content
    $xmlBuilder = [System.Text.StringBuilder]::new()
    [void]$xmlBuilder.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
    [void]$xmlBuilder.AppendLine("<testsuites>")
    [void]$xmlBuilder.AppendLine("  <testsuite name=`"$(ConvertTo-XmlSafeString $TestSuiteName)`" tests=`"$totalTests`" failures=`"$failures`" errors=`"$errors`" skipped=`"$skipped`" time=`"$totalTime`" timestamp=`"$timestamp`">")

    foreach ($result in $Results) {
        $clusterName = ConvertTo-XmlSafeString ($result.ClusterName)
        $testName = "$OperationType-$clusterName"
        
        # Calculate test time
        $testTime = 0
        if ($result.Duration -and $result.Duration -is [TimeSpan]) {
            $testTime = $result.Duration.TotalSeconds
        }
        elseif ($result.Duration -and $result.Duration -match '^\d+') {
            $testTime = [double]($result.Duration -replace '[^\d.]', '')
        }

        # Human-friendly duration string (portal-style), for inclusion
        # in failure/system-out bodies. The JUnit `time` attribute stays
        # in seconds (CI tooling expects numeric seconds).
        $durationHuman = ""
        if ($result.Duration -is [TimeSpan]) {
            $durationHuman = Format-AzLocalDurationHuman -Value $result.Duration
        }
        elseif ($result.Duration -is [string] -and -not [string]::IsNullOrWhiteSpace($result.Duration)) {
            # If the producer already formatted it (e.g. Format-AzLocalUpdateRun
            # returns "1 hour 24 minutes 31 seconds" or "running"), reuse it;
            # otherwise attempt to normalise hh:mm:ss / seconds.
            if ($result.Duration -match '\b(hour|minute|second|day)s?\b') {
                $durationHuman = $result.Duration
            }
            else {
                $durationHuman = Format-AzLocalDurationHuman -Value $result.Duration
            }
        }

        [void]$xmlBuilder.AppendLine("    <testcase name=`"$(ConvertTo-XmlSafeString $testName)`" classname=`"$TestSuiteName.$OperationType`" time=`"$testTime`">")

        switch ($result.Status) {
            # v0.8.78: ScheduleBlocked / SideloadedBlocked / ExcludedByTag moved to
            # the <skipped> branch below (designed gate-respect, not failure).
            # HealthCheckBlocked remains here because a Critical health failure
            # blocking an update IS something operators need to action.
            { $_ -in @("Failed", "Error", "HealthCheckBlocked") } {
                $message = ConvertTo-XmlSafeString ($result.Message)
                $errorType = if ($result.Status -eq "Error") { "Error" } elseif ($result.Status -eq "HealthCheckBlocked") { "HealthCheckBlocked" } else { "AssertionError" }
                [void]$xmlBuilder.AppendLine("      <failure message=`"$message`" type=`"$errorType`">")
                [void]$xmlBuilder.AppendLine("Cluster: $clusterName")
                [void]$xmlBuilder.AppendLine("Status: $($result.Status)")
                [void]$xmlBuilder.AppendLine("Message: $message")
                if ($result.PSObject.Properties['UpdateName'] -and $result.UpdateName) {
                    [void]$xmlBuilder.AppendLine("Update: $(ConvertTo-XmlSafeString $result.UpdateName)")
                }
                if ($result.PSObject.Properties['CurrentState'] -and $result.CurrentState) {
                    [void]$xmlBuilder.AppendLine("Current State: $(ConvertTo-XmlSafeString $result.CurrentState)")
                }
                if ($result.PSObject.Properties['Progress'] -and $result.Progress) {
                    [void]$xmlBuilder.AppendLine("Progress: $($result.Progress)")
                }
                if ($result.PSObject.Properties['StartTime'] -and $result.StartTime) {
                    [void]$xmlBuilder.AppendLine("Start Time: $(ConvertTo-XmlSafeString $result.StartTime)")
                }
                if ($result.PSObject.Properties['EndTime'] -and $result.EndTime) {
                    [void]$xmlBuilder.AppendLine("End Time: $(ConvertTo-XmlSafeString $result.EndTime)")
                }
                if ($durationHuman) {
                    [void]$xmlBuilder.AppendLine("Duration: $durationHuman")
                }
                [void]$xmlBuilder.AppendLine("      </failure>")
            }
            "NotFound" {
                $message = ConvertTo-XmlSafeString ($result.Message)
                [void]$xmlBuilder.AppendLine("      <error message=`"$message`" type=`"ResourceNotFound`">")
                [void]$xmlBuilder.AppendLine("Cluster: $clusterName")
                [void]$xmlBuilder.AppendLine("Message: $message")
                [void]$xmlBuilder.AppendLine("      </error>")
            }
            "UpdateNotFound" {
                # v0.7.62: requested update version not present on the cluster -
                # treat as an error so the CI summary surfaces it, not a silent pass.
                $message = ConvertTo-XmlSafeString ($result.Message)
                [void]$xmlBuilder.AppendLine("      <error message=`"$message`" type=`"UpdateNotFound`">")
                [void]$xmlBuilder.AppendLine("Cluster: $clusterName")
                [void]$xmlBuilder.AppendLine("Message: $message")
                [void]$xmlBuilder.AppendLine("      </error>")
            }
            { $_ -in @("Skipped", "NotReady", "NotConnected", "NoUpdatesAvailable", "NoReadyUpdates", "ScheduleBlocked", "SideloadedBlocked", "ExcludedByTag") } {
                # v0.7.62: previously only literal "Skipped" rendered as <skipped>; the
                # other "did not apply, but not a failure" Status values fell through to
                # <system-out>, producing misleading "all green" CI summaries.
                # v0.8.78: ScheduleBlocked / SideloadedBlocked / ExcludedByTag added here -
                # they are DESIGNED operator-configured gate-respect outcomes, not failures.
                $message = ConvertTo-XmlSafeString ($result.Message)
                [void]$xmlBuilder.AppendLine("      <skipped message=`"$message`" />")
            }
            default {
                # Success case - add system-out with details
                [void]$xmlBuilder.AppendLine("      <system-out>")
                [void]$xmlBuilder.AppendLine("Cluster: $clusterName")
                [void]$xmlBuilder.AppendLine("Status: $($result.Status)")
                if ($result.Message) {
                    [void]$xmlBuilder.AppendLine("Message: $(ConvertTo-XmlSafeString $result.Message)")
                }
                if ($result.PSObject.Properties['UpdateName'] -and $result.UpdateName) {
                    [void]$xmlBuilder.AppendLine("Update: $(ConvertTo-XmlSafeString $result.UpdateName)")
                }
                if ($result.PSObject.Properties['CurrentState'] -and $result.CurrentState) {
                    [void]$xmlBuilder.AppendLine("Final State: $(ConvertTo-XmlSafeString $result.CurrentState)")
                }
                if ($result.PSObject.Properties['Progress'] -and $result.Progress) {
                    [void]$xmlBuilder.AppendLine("Progress: $($result.Progress)")
                }
                if ($result.PSObject.Properties['StartTime'] -and $result.StartTime) {
                    [void]$xmlBuilder.AppendLine("Start Time: $(ConvertTo-XmlSafeString $result.StartTime)")
                }
                if ($result.PSObject.Properties['EndTime'] -and $result.EndTime) {
                    [void]$xmlBuilder.AppendLine("End Time: $(ConvertTo-XmlSafeString $result.EndTime)")
                }
                if ($durationHuman) {
                    [void]$xmlBuilder.AppendLine("Duration: $durationHuman")
                }
                [void]$xmlBuilder.AppendLine("      </system-out>")
            }
        }

        [void]$xmlBuilder.AppendLine("    </testcase>")
    }

    [void]$xmlBuilder.AppendLine("  </testsuite>")
    [void]$xmlBuilder.AppendLine("</testsuites>")

    # Write to file
    Write-Utf8NoBomFile -Path $OutputPath -Content $xmlBuilder.ToString()
}
