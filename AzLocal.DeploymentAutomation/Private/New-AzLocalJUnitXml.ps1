Function New-AzLocalJUnitXml {
    <#
    .SYNOPSIS

    Generates a JUnit XML report from an array of test result objects.

    .DESCRIPTION

    Builds a JUnit-compatible XML document from deployment test results. Each cluster
    is represented as a test case with pass, fail, or skip status. The output is compatible
    with dorny/test-reporter (GitHub Actions) and PublishTestResults@2 (Azure DevOps).

    .PARAMETER TestResults
    Array of PSCustomObjects with properties: TestName, ClassName, Status (Passed/Failed/Skipped),
    Message, Duration (seconds).

    .PARAMETER SuiteName
    Name of the test suite in the JUnit XML. Default: 'AzLocalDeploymentAutomation'.

    .PARAMETER OutputPath
    Optional. File path to write the XML. If omitted, returns the XML string.

    #>

    [OutputType([string])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0)]
        [PSCustomObject[]]$TestResults,

        [Parameter(Mandatory = $false)]
        [string]$SuiteName = 'AzLocalDeploymentAutomation',

        [Parameter(Mandatory = $false)]
        [string]$OutputPath = ""
    )

    $timestamp = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"
    $totalTests = $TestResults.Count
    $failures = @($TestResults | Where-Object { $_.Status -eq 'Failed' }).Count
    $skipped = @($TestResults | Where-Object { $_.Status -eq 'Skipped' }).Count
    [double]$totalTime = 0
    foreach ($result in $TestResults) {
        if ($result.PSObject.Properties['Duration'] -and $null -ne $result.Duration) {
            $totalTime += [double]$result.Duration
        }
    }
    $invariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

    # Build XML using XmlDocument for proper escaping and well-formed output
    $xml = [System.Xml.XmlDocument]::new()
    $xml.AppendChild($xml.CreateXmlDeclaration("1.0", "UTF-8", $null)) | Out-Null

    $testSuites = $xml.CreateElement("testsuites")
    $xml.AppendChild($testSuites) | Out-Null

    $testSuite = $xml.CreateElement("testsuite")
    $testSuite.SetAttribute("name", $SuiteName)
    $testSuite.SetAttribute("tests", $totalTests.ToString())
    $testSuite.SetAttribute("failures", $failures.ToString())
    $testSuite.SetAttribute("errors", "0")
    $testSuite.SetAttribute("skipped", $skipped.ToString())
    $testSuite.SetAttribute("time", ([System.Convert]::ToString($totalTime, $invariantCulture)))
    $testSuite.SetAttribute("timestamp", $timestamp)
    $testSuites.AppendChild($testSuite) | Out-Null

    foreach ($result in $TestResults) {
        $duration = if ($result.PSObject.Properties['Duration'] -and $result.Duration) { $result.Duration } else { 0 }
        $message = if ($result.PSObject.Properties['Message'] -and $result.Message) { [string]$result.Message } else { "" }

        $testCase = $xml.CreateElement("testcase")
        $testCase.SetAttribute("name", $result.TestName)
        $testCase.SetAttribute("classname", $result.ClassName)
        $testCase.SetAttribute("time", ([System.Convert]::ToString($duration, $invariantCulture)))

        if ($result.Status -eq 'Failed') {
            $failure = $xml.CreateElement("failure")
            $failure.SetAttribute("message", "$($result.TestName) failed")
            $failure.SetAttribute("type", "DeploymentFailure")
            $failure.AppendChild($xml.CreateTextNode($message)) | Out-Null
            $testCase.AppendChild($failure) | Out-Null
        } elseif ($result.Status -eq 'Skipped') {
            $skippedEl = $xml.CreateElement("skipped")
            $skippedEl.SetAttribute("message", $message)
            $testCase.AppendChild($skippedEl) | Out-Null
        } else {
            if ($message) {
                $systemOut = $xml.CreateElement("system-out")
                $systemOut.AppendChild($xml.CreateTextNode($message)) | Out-Null
                $testCase.AppendChild($systemOut) | Out-Null
            }
        }

        $testSuite.AppendChild($testCase) | Out-Null
    }

    # Pretty-print the XML
    $stringWriter = [System.IO.StringWriter]::new()
    $xmlWriter = [System.Xml.XmlTextWriter]::new($stringWriter)
    try {
        $xmlWriter.Formatting = [System.Xml.Formatting]::Indented
        $xmlWriter.Indentation = 2
        $xml.WriteTo($xmlWriter)
        $xmlWriter.Flush()
        $xmlContent = $stringWriter.ToString()
    } finally {
        $xmlWriter.Close()
        $stringWriter.Close()
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        $outputDir = Split-Path $OutputPath -Parent
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -Path $outputDir -ItemType Directory -Force -WhatIf:$false | Out-Null
        }
        $xmlContent | Out-File -FilePath $OutputPath -Encoding utf8 -Force -WhatIf:$false
        Write-AzLocalLog "JUnit XML report written to '$OutputPath'." -Level Success
        return
    }

    return $xmlContent
}
