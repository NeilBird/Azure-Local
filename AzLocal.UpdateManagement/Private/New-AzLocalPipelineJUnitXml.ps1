function New-AzLocalPipelineJUnitXml {
    <#
    .SYNOPSIS
        Builds a JUnit XML document from a structured suite/testcase
        description and (optionally) writes it to disk.

    .DESCRIPTION
        Generic JUnit XML emitter for the v0.8.5 thin-YAML refactor. Every
        Public Step.* cmdlet (Export-AzLocalAuthValidationReport,
        Invoke-AzLocalClusterInventory, Export-AzLocalUpdateRunMonitorReport,
        etc.) emits a JUnit XML report alongside its step-summary markdown so
        downstream CI consumers (dorny/test-reporter on GitHub, PublishTestResults
        on Azure DevOps) can render the report in the platform's native Tests UI.

        Pre-v0.8.5 the JUnit XML was hand-built inline in every Step.*.yml,
        which meant the same StringBuilder + XML-escape + <testsuites> /
        <testsuite> / <testcase> scaffolding was copy-pasted into 20 yml files.
        This helper centralises the scaffolding so the per-Step cmdlets only
        describe the suites + testcases as PowerShell data structures - no
        XML formatting in the per-Step bodies, and a single place to add
        new JUnit features (e.g. <properties>) across all Steps.

        The pre-existing Private/Export-ResultsToJUnitXml is per-cluster
        update-shape (one testcase per cluster, Status -> failure / error /
        skipped) used by Step.6's inline apply-updates path and is not
        replaced - it remains in place for that cluster-result-row use case.

    .PARAMETER TestSuitesName
        Top-level <testsuites name="..."> attribute. Typically the Step
        display name, e.g. "Step.0 - Authentication Validation and
        Subscription Scope Report".

    .PARAMETER Suites
        An array of suite hashtables. Each hashtable describes one
        <testsuite>. Recognised keys (all values are XML-escaped on emit):
          Name        [string]   (required) testsuite name attribute
          ClassName   [string]   (optional) default classname for testcases
                                 that omit their own ClassName
          TestCases   [object[]] (required) array of testcase hashtables

        Each testcase hashtable recognises:
          Name        [string]   (required) testcase name attribute
          ClassName   [string]   (optional) testcase classname attribute;
                                 falls back to the suite ClassName, then to
                                 the suite Name
          Time        [double]   (optional) testcase time attribute (seconds);
                                 default 0
          SystemOut   [string]   (optional) wraps in <system-out><![CDATA[...]]></system-out>
          SystemErr   [string]   (optional) wraps in <system-err><![CDATA[...]]></system-err>
          Failure     [hashtable] (optional) emits <failure message="..." type="...">body</failure>;
                                 keys: Message, Type, Body
          Error       [hashtable] (optional) emits <error message="..." type="...">body</error>;
                                 keys: Message, Type, Body
          Skipped     [string]   (optional) emits <skipped message="..."/>
                                 (passing an empty string still emits the
                                 element with no message attribute)

        The suite-level <testsuite tests="..." failures="..." errors="..."
        skipped="..."> attributes are computed from the testcase array so
        callers don't have to keep two counters in sync.

    .PARAMETER OutputPath
        Optional absolute path to write the rendered XML to. The file is
        written UTF-8 without BOM (matches dorny/test-reporter and ADO
        PublishTestResults expectations). When omitted, the cmdlet only
        returns the XML string and writes nothing.

    .PARAMETER Timestamp
        Optional [datetime] used for every <testsuite timestamp="..."> attribute.
        Defaults to (Get-Date) at invocation time. Parameterised so unit tests
        can assert against a fixed value.

    .OUTPUTS
        [string] The fully-rendered JUnit XML document. When -OutputPath is
        supplied, the same string is also written to disk.

    .EXAMPLE
        $xml = New-AzLocalPipelineJUnitXml -TestSuitesName 'Step.0 - Auth' -Suites @(
            @{
                Name = 'Authentication'
                ClassName = 'Authentication'
                TestCases = @(
                    @{ Name = 'OIDC token exchange succeeded'; SystemOut = "Tenant: $tid" }
                    @{ Name = "Default subscription = $subName" }
                )
            }
            @{
                Name = "Subscription Scope (count=$subCount)"
                ClassName = 'SubscriptionScope'
                TestCases = $subTestCases
            }
        ) -OutputPath "$reportDir/auth-report.xml"
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TestSuitesName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [object[]]$Suites,

        [Parameter(Mandatory = $false)]
        [string]$OutputPath,

        [Parameter(Mandatory = $false)]
        [datetime]$Timestamp = (Get-Date)
    )

    $xmlEscape = {
        param([string]$Text)
        if ($null -eq $Text) { return '' }
        $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;' -replace "'", '&apos;'
    }

    $now = $Timestamp.ToString('yyyy-MM-ddTHH:mm:ss')
    $totalTimeAcrossSuites = 0.0

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')

    $suiteBlocks = [System.Text.StringBuilder]::new()

    foreach ($suite in $Suites) {
        if (-not $suite -or -not $suite.ContainsKey('Name')) {
            throw "New-AzLocalPipelineJUnitXml: each Suites element must be a hashtable with a 'Name' key. Received: $($suite | Out-String)"
        }
        $suiteName = & $xmlEscape ([string]$suite.Name)
        $suiteClass = if ($suite.ContainsKey('ClassName') -and $suite.ClassName) { [string]$suite.ClassName } else { [string]$suite.Name }
        $tcs = @()
        if ($suite.ContainsKey('TestCases') -and $null -ne $suite.TestCases) { $tcs = @($suite.TestCases) }

        $tcCount = $tcs.Count
        $tcFailures = 0
        $tcErrors = 0
        $tcSkipped = 0
        $suiteTime = 0.0

        $caseBlocks = [System.Text.StringBuilder]::new()
        foreach ($tc in $tcs) {
            if (-not $tc -or -not $tc.ContainsKey('Name')) {
                throw "New-AzLocalPipelineJUnitXml: each TestCases element must be a hashtable with a 'Name' key. Received: $($tc | Out-String)"
            }
            $tcName = & $xmlEscape ([string]$tc.Name)
            $tcClass = if ($tc.ContainsKey('ClassName') -and $tc.ClassName) { [string]$tc.ClassName } else { $suiteClass }
            $tcClassEsc = & $xmlEscape $tcClass
            $tcTime = 0.0
            if ($tc.ContainsKey('Time') -and $null -ne $tc.Time) {
                try { $tcTime = [double]$tc.Time } catch { $tcTime = 0.0 }
            }
            $suiteTime += $tcTime

            $hasChild = ($tc.ContainsKey('Failure') -and $tc.Failure) -or `
                        ($tc.ContainsKey('Error') -and $tc.Error) -or `
                        ($tc.ContainsKey('Skipped')) -or `
                        ($tc.ContainsKey('SystemOut') -and $tc.SystemOut) -or `
                        ($tc.ContainsKey('SystemErr') -and $tc.SystemErr)

            if (-not $hasChild) {
                [void]$caseBlocks.AppendLine("    <testcase classname=`"$tcClassEsc`" name=`"$tcName`" time=`"$tcTime`" />")
                continue
            }

            [void]$caseBlocks.AppendLine("    <testcase classname=`"$tcClassEsc`" name=`"$tcName`" time=`"$tcTime`">")

            if ($tc.ContainsKey('Failure') -and $tc.Failure) {
                $tcFailures++
                $fMsg = & $xmlEscape ([string]$tc.Failure.Message)
                $fType = if ($tc.Failure.ContainsKey('Type') -and $tc.Failure.Type) { & $xmlEscape ([string]$tc.Failure.Type) } else { 'AssertionError' }
                $fBody = if ($tc.Failure.ContainsKey('Body') -and $tc.Failure.Body) { [string]$tc.Failure.Body } else { '' }
                if ($fBody) {
                    [void]$caseBlocks.AppendLine("      <failure message=`"$fMsg`" type=`"$fType`"><![CDATA[$fBody]]></failure>")
                }
                else {
                    [void]$caseBlocks.AppendLine("      <failure message=`"$fMsg`" type=`"$fType`" />")
                }
            }
            if ($tc.ContainsKey('Error') -and $tc.Error) {
                $tcErrors++
                $eMsg = & $xmlEscape ([string]$tc.Error.Message)
                $eType = if ($tc.Error.ContainsKey('Type') -and $tc.Error.Type) { & $xmlEscape ([string]$tc.Error.Type) } else { 'Error' }
                $eBody = if ($tc.Error.ContainsKey('Body') -and $tc.Error.Body) { [string]$tc.Error.Body } else { '' }
                if ($eBody) {
                    [void]$caseBlocks.AppendLine("      <error message=`"$eMsg`" type=`"$eType`"><![CDATA[$eBody]]></error>")
                }
                else {
                    [void]$caseBlocks.AppendLine("      <error message=`"$eMsg`" type=`"$eType`" />")
                }
            }
            if ($tc.ContainsKey('Skipped')) {
                $tcSkipped++
                $skMsg = & $xmlEscape ([string]$tc.Skipped)
                if ($skMsg) {
                    [void]$caseBlocks.AppendLine("      <skipped message=`"$skMsg`" />")
                }
                else {
                    [void]$caseBlocks.AppendLine('      <skipped />')
                }
            }
            if ($tc.ContainsKey('SystemOut') -and $tc.SystemOut) {
                [void]$caseBlocks.AppendLine("      <system-out><![CDATA[$([string]$tc.SystemOut)]]></system-out>")
            }
            if ($tc.ContainsKey('SystemErr') -and $tc.SystemErr) {
                [void]$caseBlocks.AppendLine("      <system-err><![CDATA[$([string]$tc.SystemErr)]]></system-err>")
            }
            [void]$caseBlocks.AppendLine('    </testcase>')
        }

        $totalTimeAcrossSuites += $suiteTime
        [void]$suiteBlocks.AppendLine("  <testsuite name=`"$suiteName`" tests=`"$tcCount`" failures=`"$tcFailures`" errors=`"$tcErrors`" skipped=`"$tcSkipped`" timestamp=`"$now`" time=`"$suiteTime`">")
        [void]$suiteBlocks.Append($caseBlocks.ToString())
        [void]$suiteBlocks.AppendLine('  </testsuite>')
    }

    $suitesNameEsc = & $xmlEscape $TestSuitesName
    [void]$sb.AppendLine("<testsuites name=`"$suitesNameEsc`" time=`"$totalTimeAcrossSuites`">")
    [void]$sb.Append($suiteBlocks.ToString())
    [void]$sb.AppendLine('</testsuites>')

    $xmlString = $sb.ToString()

    if ($OutputPath) {
        $dir = Split-Path -Path $OutputPath -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($OutputPath, $xmlString, [System.Text.UTF8Encoding]::new($false))
    }

    return $xmlString
}
