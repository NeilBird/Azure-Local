#Requires -Module Pester
<#
.SYNOPSIS
    v0.9.1 feature tests: the optional subscription-exclusion list. Covers the
    CSV parser (Resolve-AzLocalExcludedSubscriptionId), the KQL clause builder
    (New-AzLocalSubscriptionExclusionKqlClause), the lazy env-var resolver
    (Get-AzLocalExcludedSubscriptionId), the central injection inside
    Invoke-AzResourceGraphQuery, the public Get/Set cmdlets, and the
    pipeline-example wiring (env var + starter CSV drop).

.NOTES
    The default code path (no AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH set, no
    explicit Set-AzLocalExcludedSubscription call) is a no-op, so these tests
    deliberately reset module-scope state in each block to avoid bleed.
#>

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\AzLocal.UpdateManagement.psd1'
    Import-Module $modulePath -Force -ErrorAction Stop

    $script:PipelineRoot = Join-Path -Path $PSScriptRoot -ChildPath '..\Automation-Pipeline-Examples'

    # Helper to reset all exclusion module-scope state between tests.
    $script:ResetExclusions = {
        InModuleScope AzLocal.UpdateManagement {
            $script:ExcludedSubscriptionIds = @()
            $script:ExcludedSubscriptionSource = $null
            $script:ExcludedSubscriptionsResolved = $false
            $script:ExcludedSubscriptionsExplicit = $false
        }
    }
}

AfterAll {
    & $script:ResetExclusions
    Remove-Module AzLocal.UpdateManagement -Force -ErrorAction SilentlyContinue
}

Describe 'v0.9.1 Private parser: Resolve-AzLocalExcludedSubscriptionId' {

    BeforeAll {
        $script:G1 = '11111111-1111-1111-1111-111111111111'
        $script:G2 = '22222222-2222-2222-2222-222222222222'
    }

    It 'Parses valid subscription IDs, lowercases, and de-duplicates' {
        $csv = Join-Path $TestDrive 'valid.csv'
        @(
            'Subscription IDs,Subscription Name,Comment / Notes'
            ('{0},Contoso-Lab,first' -f $script:G1.ToUpper())
            ('{0},Contoso-Two,second' -f $script:G2)
            ('{0},Contoso-Dup,dup of first' -f $script:G1)
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.SubscriptionIds.Count | Should -Be 2
            $r.SubscriptionIds[0]    | Should -Be '11111111-1111-1111-1111-111111111111'
            $r.SubscriptionIds[1]    | Should -Be '22222222-2222-2222-2222-222222222222'
            $r.Skipped.Count         | Should -Be 0
        }
    }

    It 'Skips non-GUID values and records them' {
        $csv = Join-Path $TestDrive 'mixed.csv'
        @(
            'Subscription IDs,Subscription Name,Comment / Notes'
            ('{0},Good,ok' -f $script:G1)
            'not-a-guid,Bad,nope'
            ',Empty,blank is ignored'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.SubscriptionIds.Count | Should -Be 1
            $r.Skipped.Count         | Should -Be 1
            $r.Skipped[0].Value      | Should -Be 'not-a-guid'
            $r.Skipped[0].Reason     | Should -Be 'NotAGuid'
        }
    }

    It 'Header-only file returns an empty list and does NOT throw' {
        $csv = Join-Path $TestDrive 'header-only.csv'
        @('Subscription IDs,Subscription Name,Comment / Notes') | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            { Resolve-AzLocalExcludedSubscriptionId -Path $Path } | Should -Not -Throw
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.SubscriptionIds.Count | Should -Be 0
        }
    }

    It 'Ignores leading comment (#) and blank lines above the header' {
        $csv = Join-Path $TestDrive 'commented.csv'
        @(
            '# guidance line 1'
            '# guidance line 2'
            ''
            'Subscription IDs,Subscription Name,Comment / Notes'
            ('{0},Contoso,ok' -f $script:G1)
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.SubscriptionIds.Count | Should -Be 1
            $r.Column                | Should -Be 'Subscription IDs'
        }
    }

    It 'Tolerates a SubscriptionId header variant' {
        $csv = Join-Path $TestDrive 'variant.csv'
        @(
            'SubscriptionId,Name,Notes'
            ('{0},Contoso,ok' -f $script:G1)
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.SubscriptionIds.Count | Should -Be 1
        }
    }

    It 'Throws when no subscription-id column is present' {
        $csv = Join-Path $TestDrive 'no-col.csv'
        @(
            'Name,Notes'
            'Contoso,ok'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            { Resolve-AzLocalExcludedSubscriptionId -Path $Path } | Should -Throw -ExpectedMessage '*Subscription IDs*'
        }
    }

    It 'Throws when the file does not exist' {
        InModuleScope AzLocal.UpdateManagement {
            { Resolve-AzLocalExcludedSubscriptionId -Path 'X:\nope\missing.csv' } | Should -Throw -ExpectedMessage '*not found*'
        }
    }
}

Describe 'v0.9.1 Private helper: New-AzLocalSubscriptionExclusionKqlClause' {

    It 'Returns empty string for an empty / null input' {
        InModuleScope AzLocal.UpdateManagement {
            New-AzLocalSubscriptionExclusionKqlClause -SubscriptionId @()   | Should -Be ''
            New-AzLocalSubscriptionExclusionKqlClause                       | Should -Be ''
        }
    }

    It 'Builds a single id !startswith clause for one subscription' {
        InModuleScope AzLocal.UpdateManagement {
            $c = New-AzLocalSubscriptionExclusionKqlClause -SubscriptionId @('11111111-1111-1111-1111-111111111111')
            $c | Should -Be "| where id !startswith '/subscriptions/11111111-1111-1111-1111-111111111111/'"
        }
    }

    It 'Joins multiple subscriptions with and, and lowercases' {
        InModuleScope AzLocal.UpdateManagement {
            $c = New-AzLocalSubscriptionExclusionKqlClause -SubscriptionId @('AAAAAAAA-1111-1111-1111-111111111111', 'bbbbbbbb-2222-2222-2222-222222222222')
            $c | Should -Be "| where id !startswith '/subscriptions/aaaaaaaa-1111-1111-1111-111111111111/' and id !startswith '/subscriptions/bbbbbbbb-2222-2222-2222-222222222222/'"
        }
    }
}

Describe 'v0.9.1 env-var resolver: Get-AzLocalExcludedSubscriptionId' {

    AfterEach {
        $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH = $null
        & $script:ResetExclusions
    }

    It 'Returns empty when the env var is not set' {
        & $script:ResetExclusions
        InModuleScope AzLocal.UpdateManagement {
            (Get-AzLocalExcludedSubscriptionId).Count | Should -Be 0
        }
    }

    It 'Auto-loads from AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH when set' {
        $csv = Join-Path $TestDrive 'env-load.csv'
        @(
            'Subscription IDs,Subscription Name,Comment / Notes'
            '33333333-3333-3333-3333-333333333333,Contoso,ok'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII
        $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH = $csv
        & $script:ResetExclusions

        InModuleScope AzLocal.UpdateManagement {
            $ids = @(Get-AzLocalExcludedSubscriptionId)
            $ids.Count | Should -Be 1
            $ids[0]    | Should -Be '33333333-3333-3333-3333-333333333333'
        }
    }

    It 'Warns (does not throw) when the env var points at a header-only file' {
        $csv = Join-Path $TestDrive 'env-empty.csv'
        @('Subscription IDs,Subscription Name,Comment / Notes') | Set-Content -LiteralPath $csv -Encoding ASCII
        $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH = $csv
        & $script:ResetExclusions

        InModuleScope AzLocal.UpdateManagement {
            $warnings = @()
            $ids = Get-AzLocalExcludedSubscriptionId -WarningVariable warnings -WarningAction SilentlyContinue
            $ids.Count       | Should -Be 0
            $warnings.Count  | Should -BeGreaterThan 0
        }
    }

    It 'Warns when the env var points at a missing file' {
        $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH = 'X:\nope\missing.csv'
        & $script:ResetExclusions

        InModuleScope AzLocal.UpdateManagement {
            $warnings = @()
            $ids = Get-AzLocalExcludedSubscriptionId -WarningVariable warnings -WarningAction SilentlyContinue
            $ids.Count      | Should -Be 0
            $warnings.Count | Should -BeGreaterThan 0
        }
    }
}

Describe 'v0.9.1 central injection: Invoke-AzResourceGraphQuery' {

    AfterEach {
        $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH = $null
        & $script:ResetExclusions
    }

    It 'Does NOT alter the query when no exclusions are set' {
        & $script:ResetExclusions
        # Shadow az with a stub that captures the query passed via -q.
        $global:CapturedQuery = $null
        function global:az {
            $global:LASTEXITCODE = 0
            $qIdx = [array]::IndexOf($args, '-q')
            if ($qIdx -ge 0) { $global:CapturedQuery = $args[$qIdx + 1] }
            return '[]'
        }
        try {
            InModuleScope AzLocal.UpdateManagement {
                $null = Invoke-AzResourceGraphQuery -Query 'resources | where type =~ ''microsoft.azurestackhci/clusters'' | project id' -DisableCrossCallCooldown
            }
            $global:CapturedQuery | Should -Not -Match 'id !startswith'
            $global:CapturedQuery | Should -Match '^resources \| where type'
        }
        finally {
            Remove-Item function:\az -ErrorAction SilentlyContinue
            Remove-Variable -Name CapturedQuery -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'Injects the exclusion clause after the leading table token' {
        InModuleScope AzLocal.UpdateManagement {
            $script:ExcludedSubscriptionIds = @('44444444-4444-4444-4444-444444444444')
            $script:ExcludedSubscriptionsExplicit = $true
            $script:ExcludedSubscriptionsResolved = $true
        }
        $global:CapturedQuery = $null
        function global:az {
            $global:LASTEXITCODE = 0
            $qIdx = [array]::IndexOf($args, '-q')
            if ($qIdx -ge 0) { $global:CapturedQuery = $args[$qIdx + 1] }
            return '[]'
        }
        try {
            InModuleScope AzLocal.UpdateManagement {
                $null = Invoke-AzResourceGraphQuery -Query 'resources | where type =~ ''microsoft.azurestackhci/clusters'' | project id' -DisableCrossCallCooldown
            }
            $global:CapturedQuery | Should -Match "^resources \| where id !startswith '/subscriptions/44444444-4444-4444-4444-444444444444/' \| where type"
        }
        finally {
            Remove-Item function:\az -ErrorAction SilentlyContinue
            Remove-Variable -Name CapturedQuery -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'Injects for extensibilityresources queries too' {
        InModuleScope AzLocal.UpdateManagement {
            $script:ExcludedSubscriptionIds = @('55555555-5555-5555-5555-555555555555')
            $script:ExcludedSubscriptionsExplicit = $true
            $script:ExcludedSubscriptionsResolved = $true
        }
        $global:CapturedQuery = $null
        function global:az {
            $global:LASTEXITCODE = 0
            $qIdx = [array]::IndexOf($args, '-q')
            if ($qIdx -ge 0) { $global:CapturedQuery = $args[$qIdx + 1] }
            return '[]'
        }
        try {
            InModuleScope AzLocal.UpdateManagement {
                $q = "extensibilityresources`n| where type =~ 'microsoft.azurestackhci/clusters/updatesummaries'`n| project id"
                $null = Invoke-AzResourceGraphQuery -Query $q -DisableCrossCallCooldown
            }
            $global:CapturedQuery | Should -Match "^extensibilityresources \| where id !startswith '/subscriptions/55555555-5555-5555-5555-555555555555/' \| where type"
        }
        finally {
            Remove-Item function:\az -ErrorAction SilentlyContinue
            Remove-Variable -Name CapturedQuery -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe 'v0.9.1 public cmdlets: Get/Set-AzLocalExcludedSubscription' {

    AfterEach {
        $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH = $null
        & $script:ResetExclusions
    }

    It 'Set -SubscriptionId sets the explicit list and Get returns it' {
        & $script:ResetExclusions
        Set-AzLocalExcludedSubscription -SubscriptionId '66666666-6666-6666-6666-666666666666' -Confirm:$false
        $state = Get-AzLocalExcludedSubscription
        $state.Count           | Should -Be 1
        $state.SubscriptionIds | Should -Contain '66666666-6666-6666-6666-666666666666'
        $state.IsExplicit      | Should -BeTrue
        $state.Source          | Should -Be 'Explicit:Parameter'
    }

    It 'Set -Path loads from a CSV' {
        $csv = Join-Path $TestDrive 'set-path.csv'
        @(
            'Subscription IDs,Subscription Name,Comment / Notes'
            '77777777-7777-7777-7777-777777777777,Contoso,ok'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII
        & $script:ResetExclusions

        Set-AzLocalExcludedSubscription -Path $csv -Confirm:$false
        (Get-AzLocalExcludedSubscription).SubscriptionIds | Should -Contain '77777777-7777-7777-7777-777777777777'
    }

    It 'Set -Clear empties the list and overrides env-var auto-load' {
        $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH = (Join-Path $TestDrive 'should-be-ignored.csv')
        @(
            'Subscription IDs,Subscription Name,Comment / Notes'
            '88888888-8888-8888-8888-888888888888,Contoso,ok'
        ) | Set-Content -LiteralPath $env:AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH -Encoding ASCII
        & $script:ResetExclusions

        Set-AzLocalExcludedSubscription -Clear -Confirm:$false
        $state = Get-AzLocalExcludedSubscription
        $state.Count      | Should -Be 0
        $state.IsExplicit | Should -BeTrue
    }

    It 'Set -SubscriptionId warns on a non-GUID value' {
        & $script:ResetExclusions
        $warnings = @()
        Set-AzLocalExcludedSubscription -SubscriptionId @('not-a-guid') -Confirm:$false -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -BeGreaterThan 0
        (Get-AzLocalExcludedSubscription).Count | Should -Be 0
    }
}

Describe 'v0.9.1 module surface: exclusion cmdlets exported' {

    It 'Exports Get-AzLocalExcludedSubscription and Set-AzLocalExcludedSubscription' {
        $exported = (Get-Module AzLocal.UpdateManagement).ExportedFunctions.Keys
        $exported | Should -Contain 'Get-AzLocalExcludedSubscription'
        $exported | Should -Contain 'Set-AzLocalExcludedSubscription'
    }
}

Describe 'v0.9.1 pipeline wiring: AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH' {

    It 'Every GitHub Actions workflow declares the AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH env var' {
        $ghaDir = Join-Path $script:PipelineRoot 'github-actions'
        $files = Get-ChildItem -Path $ghaDir -Filter '*.yml' -File
        $files.Count | Should -Be 10
        foreach ($f in $files) {
            (Get-Content -LiteralPath $f.FullName -Raw) |
                Should -Match 'AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH:\s*\$\{\{ vars\.AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH \}\}' -Because "GHA workflow '$($f.Name)' should map the Actions variable into the env var"
        }
    }

    It 'Every Azure DevOps pipeline sources shared settings from the AzureLocal-Pipeline-Settings variable group' {
        $adoDir = Join-Path $script:PipelineRoot 'azure-devops'
        $files = Get-ChildItem -Path $adoDir -Filter '*.yml' -File
        $files.Count | Should -Be 10
        foreach ($f in $files) {
            $content = Get-Content -LiteralPath $f.FullName -Raw
            # The exclusion path (and the other shared settings) are centralized in
            # the variable group - the ADO equivalent of GitHub repo Variables.
            $content |
                Should -Match '(?m)^\s*-\s*group:\s*AzureLocal-Pipeline-Settings\s*$' -Because "ADO pipeline '$($f.Name)' must reference the shared variable group"
            # And must NOT redefine AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH inline - an
            # inline pipeline-root variable OVERRIDES the group (ADO precedence), which
            # would defeat the set-once design. Comment lines (#) are allowed.
            $content |
                Should -Not -Match '(?m)^\s*AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH\s*:' -Because "ADO pipeline '$($f.Name)' must not define the exclusion var in map form inline"
            $content |
                Should -Not -Match '(?m)^\s*-\s*name:\s*AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH\s*$' -Because "ADO pipeline '$($f.Name)' must not define the exclusion var in list form inline"
        }
    }

    It 'Ships a worked-example excluded-subscription-ids.example.csv' {
        $example = Join-Path $script:PipelineRoot 'excluded-subscription-ids.example.csv'
        Test-Path -LiteralPath $example | Should -BeTrue
        (Get-Content -LiteralPath $example -Raw) | Should -Match 'Subscription IDs,Subscription Name,Comment / Notes'
    }
}

Describe 'v0.9.1 starter drop: Copy-AzLocalPipelineExample writes header-only Excluded-Subscription-Ids.csv' {

    It 'Drops a header-only Excluded-Subscription-Ids.csv into config\ (GitHub)' {
        $dest = Join-Path $TestDrive 'repo-gh\.github\workflows'
        $null = New-Item -ItemType Directory -Path $dest -Force
        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Confirm:$false | Out-Null

        $csv = Join-Path $TestDrive 'repo-gh\config\Excluded-Subscription-Ids.csv'
        Test-Path -LiteralPath $csv | Should -BeTrue
        $content = Get-Content -LiteralPath $csv
        ($content | Where-Object { $_ -match '^Subscription IDs,' }).Count | Should -Be 1
        # Header-only: no data rows (every non-comment line after the header).
        $dataRows = @($content | Where-Object { $_ -and ($_.TrimStart() -notmatch '^#') -and ($_ -notmatch '^Subscription IDs,') })
        $dataRows.Count | Should -Be 0
    }

    It 'Does NOT overwrite an existing Excluded-Subscription-Ids.csv' {
        $dest = Join-Path $TestDrive 'repo-gh2\.github\workflows'
        $null = New-Item -ItemType Directory -Path $dest -Force
        $configDir = Join-Path $TestDrive 'repo-gh2\config'
        $null = New-Item -ItemType Directory -Path $configDir -Force
        $csv = Join-Path $configDir 'Excluded-Subscription-Ids.csv'
        @(
            'Subscription IDs,Subscription Name,Comment / Notes'
            '99999999-9999-9999-9999-999999999999,Mine,keep me'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Confirm:$false | Out-Null

        (Get-Content -LiteralPath $csv -Raw) | Should -Match '99999999-9999-9999-9999-999999999999'
    }

    It 'Drops a comment-free CSV (no embedded # lines) that round-trips and parses cleanly (v0.9.10)' {
        $dest = Join-Path $TestDrive 'repo-gh-clean\.github\workflows'
        $null = New-Item -ItemType Directory -Path $dest -Force
        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Confirm:$false | Out-Null

        $csv = Join-Path $TestDrive 'repo-gh-clean\config\Excluded-Subscription-Ids.csv'
        Test-Path -LiteralPath $csv | Should -BeTrue
        $content = @(Get-Content -LiteralPath $csv)
        # The CSV must carry NO '#' guidance lines - that guidance moved to the
        # sidecar README so the CSV round-trips safely through Excel.
        ($content | Where-Object { $_ -match '^\s*#' }).Count | Should -Be 0
        # And the clean header-only CSV parses without throwing (header-only =
        # zero data rows = excludes nothing).
        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            { Resolve-AzLocalExcludedSubscriptionId -Path $Path } | Should -Not -Throw
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.RowCount | Should -Be 0
            $r.Column   | Should -Match 'Subscription'
        }
    }

    It 'Drops a sidecar Excluded-Subscription-Ids_README.txt with activation guidance (v0.9.10)' {
        $dest = Join-Path $TestDrive 'repo-gh-readme\.github\workflows'
        $null = New-Item -ItemType Directory -Path $dest -Force
        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Confirm:$false | Out-Null

        $readme = Join-Path $TestDrive 'repo-gh-readme\config\Excluded-Subscription-Ids_README.txt'
        Test-Path -LiteralPath $readme | Should -BeTrue
        $raw = Get-Content -LiteralPath $readme -Raw
        $raw | Should -Match 'AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH'
        $raw | Should -Match 'Subscription IDs,Subscription Name,Comment / Notes'
    }

    It 'Does NOT overwrite an existing Excluded-Subscription-Ids_README.txt (v0.9.10)' {
        $dest = Join-Path $TestDrive 'repo-gh-readme2\.github\workflows'
        $null = New-Item -ItemType Directory -Path $dest -Force
        $configDir = Join-Path $TestDrive 'repo-gh-readme2\config'
        $null = New-Item -ItemType Directory -Path $configDir -Force
        $readme = Join-Path $configDir 'Excluded-Subscription-Ids_README.txt'
        'MY OWN NOTES - KEEP' | Set-Content -LiteralPath $readme -Encoding ASCII

        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Confirm:$false | Out-Null

        (Get-Content -LiteralPath $readme -Raw) | Should -Match 'MY OWN NOTES - KEEP'
    }
}

Describe 'v0.9.10 migration: legacy commented Excluded-Subscription-Ids.csv is normalized in place' {

    BeforeAll {
        # The legacy v0.9.1 starter: '#' guidance comment lines above the header.
        $script:LegacyCommented = @(
            '# Excluded-Subscription-Ids.csv - optional subscription exclusion list (v0.9.1).'
            '# Add one Azure subscription ID (GUID) per row under "Subscription IDs".'
            '#'
            '# This file does NOTHING until AZLOCAL_EXCLUDED_SUBSCRIPTIONS_PATH is set.'
            'Subscription IDs,Subscription Name,Comment / Notes'
        )
    }

    It 'Repair-AzLocalExcludedSubscriptionCsv returns $false (no-op) for an already-clean CSV' {
        $csv = Join-Path $TestDrive 'clean\Excluded-Subscription-Ids.csv'
        $null = New-Item -ItemType Directory -Path (Split-Path $csv) -Force
        @('Subscription IDs,Subscription Name,Comment / Notes') | Set-Content -LiteralPath $csv -Encoding ASCII
        $before = Get-Content -LiteralPath $csv -Raw

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            Repair-AzLocalExcludedSubscriptionCsv -Path $Path | Should -BeFalse
        }
        # Unchanged.
        (Get-Content -LiteralPath $csv -Raw) | Should -Be $before
    }

    It 'Repair-AzLocalExcludedSubscriptionCsv strips comments and preserves GUID rows' {
        $csv = Join-Path $TestDrive 'legacy-guids\Excluded-Subscription-Ids.csv'
        $null = New-Item -ItemType Directory -Path (Split-Path $csv) -Force
        @(
            $script:LegacyCommented
            '00000000-0000-0000-0000-000000000000,Contoso-Lab,never update'
            '11111111-1111-1111-1111-111111111111,Contoso-Decom,pending cleanup'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            Repair-AzLocalExcludedSubscriptionCsv -Path $Path | Should -BeTrue
            # No '#' comment lines survive.
            $content = @(Get-Content -LiteralPath $Path)
            ($content | Where-Object { $_ -match '^\s*#' }).Count | Should -Be 0
            # Both GUID rows preserved and the file parses cleanly.
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.RowCount | Should -Be 2
            { Resolve-AzLocalExcludedSubscriptionId -Path $Path } | Should -Not -Throw
        }
        (Get-Content -LiteralPath $csv -Raw) | Should -Match '00000000-0000-0000-0000-000000000000'
        (Get-Content -LiteralPath $csv -Raw) | Should -Match '11111111-1111-1111-1111-111111111111'
    }

    It 'Recovers GUID rows even from an Excel-mangled legacy file (quoted comments + trailing commas)' {
        # Simulate what Excel writes after open+save: comment lines wrapped in
        # quotes and padded with trailing commas, and a quoted GUID field.
        $csv = Join-Path $TestDrive 'mangled\Excluded-Subscription-Ids.csv'
        $null = New-Item -ItemType Directory -Path (Split-Path $csv) -Force
        @(
            '"# Excluded-Subscription-Ids.csv - optional subscription exclusion list (v0.9.1).",,'
            '"# Add one Azure subscription ID (GUID) per row.",,'
            'Subscription IDs,Subscription Name,Comment / Notes'
            '"22222222-2222-2222-2222-222222222222",Contoso-Edge,keep excluded'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        InModuleScope AzLocal.UpdateManagement -Parameters @{ Path = $csv } {
            param($Path)
            Repair-AzLocalExcludedSubscriptionCsv -Path $Path | Should -BeTrue
            { Resolve-AzLocalExcludedSubscriptionId -Path $Path } | Should -Not -Throw
            $r = Resolve-AzLocalExcludedSubscriptionId -Path $Path
            $r.RowCount | Should -Be 1
        }
        (Get-Content -LiteralPath $csv -Raw) | Should -Match '22222222-2222-2222-2222-222222222222'
    }

    It 'Copy-AzLocalPipelineExample normalizes an existing legacy commented CSV (GitHub)' {
        $dest = Join-Path $TestDrive 'repo-migrate\.github\workflows'
        $null = New-Item -ItemType Directory -Path $dest -Force
        $configDir = Join-Path $TestDrive 'repo-migrate\config'
        $null = New-Item -ItemType Directory -Path $configDir -Force
        $csv = Join-Path $configDir 'Excluded-Subscription-Ids.csv'
        @(
            $script:LegacyCommented
            '33333333-3333-3333-3333-333333333333,Contoso-Old,exclude'
        ) | Set-Content -LiteralPath $csv -Encoding ASCII

        Copy-AzLocalPipelineExample -Destination $dest -Platform GitHub -Confirm:$false | Out-Null

        $content = @(Get-Content -LiteralPath $csv)
        ($content | Where-Object { $_ -match '^\s*#' }).Count | Should -Be 0
        (Get-Content -LiteralPath $csv -Raw) | Should -Match '33333333-3333-3333-3333-333333333333'
    }
}

