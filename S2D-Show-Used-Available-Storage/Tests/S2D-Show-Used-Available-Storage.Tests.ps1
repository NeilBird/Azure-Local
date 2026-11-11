BeforeAll {
    $scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'S2D-Show-Used-Available-Storage.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $elevationGuard = $ast.EndBlock.Statements |
        Where-Object { $_ -is [System.Management.Automation.Language.IfStatementAst] } |
        Select-Object -First 1
    $script:reportScript = [scriptblock]::Create($ast.Extent.Text.Remove(
        $elevationGuard.Extent.StartOffset,
        $elevationGuard.Extent.EndOffset - $elevationGuard.Extent.StartOffset
    ))

    function Get-Cluster {
        [CmdletBinding()]
        param()
        if ($script:clusterLookupFails) { throw 'Cluster lookup failed' }
        [pscustomobject]@{ Name = 'Cluster-A' }
    }
    function Get-ClusterNode { [CmdletBinding()]param(); 1..4 }
    function Get-StoragePool {
        [CmdletBinding()]
        param()
        [pscustomobject]@{ FriendlyName = 'Primordial'; IsPrimordial = $true; Size = 999TB; AllocatedSize = 998TB }
        $script:poolFixture
    }
    function Get-PhysicalDisk { [pscustomobject]@{ Usage = 'Auto-Select'; Size = 1.6TB } }
    function Get-VirtualDisk { [CmdletBinding()]param(); $script:volumeFixtures }
}

Describe 'S2D storage report output modes' {
    BeforeEach {
        $script:clusterLookupFails = $false
        $script:poolFixture = [pscustomobject]@{
            FriendlyName = 'SU1_Pool'; IsPrimordial = $false
            Size = 60TB; AllocatedSize = 13.8TB; ThinProvisioningAlertThresholds = @(70)
        }
        $script:volumeFixtures = @([pscustomobject]@{
            FriendlyName = 'UserStorage_1'; NumberOfDataCopies = 3
            ResiliencySettingName = 'Mirror'; ProvisioningType = 'Thin'
            Size = 15.5TB; FootprintOnPool = 6TB
        })
    }

    It 'returns exactly one report without explanatory or formatting output' {
        $information = @()
        $reports = @(& $script:reportScript -PassThru -InformationVariable information)
        $reports.Count | Should -Be 1
        $information.Count | Should -Be 0
        $reports[0].ClusterName | Should -Be 'Cluster-A'
        $reports[0].CollectedAtUtc.Kind | Should -Be ([DateTimeKind]::Utc)
        ($reports[0].Volumes -is [array]) | Should -BeTrue
        $reports[0].Volumes.Count | Should -Be 1
        $reports[0].Pool.PoolName | Should -Be 'SU1_Pool'
        $reports[0].Pool.PoolUsedPercent | Should -Be 23
        $reports[0].Pool.EstimatedAdditionalLogicalDataTiB | Should -Be 13.27
        $reports[0].Pool.RepairReserveDriveEquivalents | Should -BeOfType ([int])
        ($reports[0].Pool.ThinProvisioningAlertThresholdsPercent -is [uint16[]]) | Should -BeTrue
    }

    It 'preserves multiple numeric thresholds and nested values through JSON' {
        $script:poolFixture.ThinProvisioningAlertThresholds = @(70, 80)
        $report = & $script:reportScript -PassThru
        $parsed = $report | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $parsed.Pool.ThinProvisioningAlertThresholdsPercent.Count | Should -Be 2
        $parsed.Pool.ThinProvisioningAlertThresholdsPercent[1] | Should -Be 80
        $parsed.Volumes[0].FootprintOnPoolTiB | Should -Be 6
    }

    It 'returns an empty threshold array when configuration is absent' {
        $script:poolFixture.PSObject.Properties.Remove('ThinProvisioningAlertThresholds')
        $report = & $script:reportScript -PassThru
        $report.Pool.ThinProvisioningAlertThresholdsPercent.Count | Should -Be 0
    }

    It 'preserves an empty volume array and the no-volume warning' {
        $script:volumeFixtures = @()
        $report = & $script:reportScript -PassThru -WarningVariable warnings -WarningAction SilentlyContinue
        $report.Volumes.Count | Should -Be 0
        ($warnings -join ' ') | Should -Match 'No virtual disks'
    }

    It 'retains warnings for zero size and repair shortfalls without negative logical estimates' {
        $script:poolFixture.Size = 0
        $script:poolFixture.AllocatedSize = 0
        $report = & $script:reportScript -PassThru -WarningVariable warnings -WarningAction SilentlyContinue
        $report.Pool.PoolUsedPercent | Should -BeNullOrEmpty
        $report.Pool.PoolFreeRawPercent | Should -BeNullOrEmpty
        $report.Pool.PhysicalHeadroomAfterRecommendedReserveTiB | Should -BeLessThan 0
        $report.Pool.EstimatedAdditionalLogicalDataTiB | Should -Be 0
        ($warnings -join ' ') | Should -Match 'Pool size is zero'
        ($warnings -join ' ') | Should -Match 'below the recommended repair reserve'
    }

    It 'does not substitute a node name when cluster discovery fails' {
        $script:clusterLookupFails = $true
        $report = & $script:reportScript -PassThru -WarningVariable warnings -WarningAction SilentlyContinue
        $report.ClusterName | Should -BeNullOrEmpty
        ($warnings -join ' ') | Should -Match 'cluster name is unavailable'
    }

    It 'retains the formatted default view and explanatory console text' {
        $information = @()
        $display = & $script:reportScript -InformationVariable information 6>$null | Out-String -Width 200
        $display | Should -Match 'UserStorage_1'
        $display | Should -Match 'not dedicated drives'
        ($information -join ' ') | Should -Match 'Per-volume footprint'
        ($information -join ' ') | Should -Match 'Related capacity health failures'
        $script:poolFixture.PSObject.Properties.Remove('ThinProvisioningAlertThresholds')
        $display = & $script:reportScript 6>$null | Out-String -Width 200
        $display | Should -Match 'Not reported'
    }
}