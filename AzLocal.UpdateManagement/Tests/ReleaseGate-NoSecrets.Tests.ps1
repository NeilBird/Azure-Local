#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Release gate: no secrets or objectively-identifiable PII in shippable content.

    WHY: prevent credentials / real Azure identifiers from being published to
    PSGallery or the public repo. This is a DETERMINISTIC gate - it scans for
    objective, machine-checkable patterns only (GUIDs against an allow-list,
    email addresses on non-example domains, and hard secret material such as
    private keys / storage keys / tokens).

    SCOPE: it does NOT attempt to detect arbitrary customer / organisation
    NAMES (e.g. a retailer name in a comment). Reliably catching those would
    require either a committed denylist of customer names (itself a leak /
    anti-pattern) or a noisy heuristic; both were deliberately rejected. Names
    remain a human PR-review responsibility.

    HOW TO ALLOW A NEW GUID: if a NEW, legitimately-public GUID is added (e.g.
    another Azure built-in role definition id, or a documented example), add it
    to $script:AllowedGuids below WITH a comment explaining what it is. Any GUID
    not on the allow-list (and not an obvious placeholder) fails the gate.
#>

Describe 'Release gate: no secrets or PII in shippable content' -Tag 'ReleaseGate' {

    BeforeAll {
        $script:ModuleRoot = Split-Path -Path $PSScriptRoot -Parent

        # Shippable text files. The Tests/ tree is excluded on purpose: it holds
        # synthetic fixtures (fake GUIDs, mock emails, and this gate's own
        # allow-list) that would otherwise self-trip the scan.
        $textExtensions = '*.ps1', '*.psd1', '*.psm1', '*.md', '*.yml', '*.yaml', '*.json', '*.csv', '*.txt'
        $script:ShipFiles = Get-ChildItem -Path $script:ModuleRoot -Recurse -File -Include $textExtensions |
            Where-Object { $_.FullName -notmatch '\\Tests\\' -and $_.FullName -notmatch '\\TestResults\\' }

        # ---- GUID allow-list ------------------------------------------------
        # The module's own identity GUID is read from the manifest so it never
        # has to be hard-coded here.
        $manifest = Import-PowerShellDataFile -Path (Join-Path $script:ModuleRoot 'AzLocal.UpdateManagement.psd1')
        $script:AllowedGuids = @(
            [string]$manifest.GUID                             # this module's identity GUID
            'bda0d508-adf1-4af0-9c28-88919fc3ae06'            # PUBLIC Azure built-in role: Azure Stack HCI Administrator
            '865ae368-6a45-4bd1-8fbf-0d5151f56fc1'            # PUBLIC Azure built-in role: Azure Stack HCI Device Management Role
            '23b779ba-0d52-4a80-8571-45ca74664ec3'            # documented example update-run resource name (example-update-request.json)
            'fbaf508b-cb61-4383-9cda-a42bfa0c7bc9'            # maintainer's own non-sensitive test-lab subscription id (approved by owner)
            '00000000-0000-0000-0000-000000000001'            # doc placeholder
        ) | ForEach-Object { $_.ToLowerInvariant() }

        # Explicit placeholder GUIDs used throughout the docs/examples.
        $script:PlaceholderGuids = @(
            '12345678-1234-1234-1234-123456789012'
            'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
        )

        function Test-IsAllowedGuid {
            param([string]$Guid)
            $g = $Guid.ToLowerInvariant()
            if ($script:AllowedGuids -contains $g) { return $true }
            if ($script:PlaceholderGuids -contains $g) { return $true }
            # All-same-hex-character placeholders (00000000-..., 11111111-..., etc.)
            $hex = ($g -replace '-', '')
            if ((($hex.ToCharArray() | Select-Object -Unique).Count) -le 1) { return $true }
            return $false
        }

        # Email domains that are canonical placeholders / non-routable examples.
        $script:AllowedEmailDomains = @(
            'example.com', 'example.org', 'example.net'
            'contoso.com', 'corp.contoso.com'
            'fabrikam.com'
            'company.com'
            'fqdn.com'
            'localhost'
            'noreply.github.com', 'users.noreply.github.com'
        )

        $script:GuidRegex   = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
        $script:EmailRegex  = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

        # Hard secret material - these must NEVER appear in the repo.
        $script:SecretPatterns = [ordered]@{
            'PEM private key'          = '-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP )?PRIVATE KEY-----'
            'Azure Storage AccountKey' = 'AccountKey\s*=\s*[A-Za-z0-9+/]{60,}={0,2}'
            'Shared Access Signature'  = '[?&]sig=[A-Za-z0-9%]{24,}'
            'JWT bearer token'         = 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
            'GitHub token'             = '\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b|\bgithub_pat_[A-Za-z0-9_]{22,}\b'
            'Slack token'              = '\bxox[baprs]-[A-Za-z0-9-]{10,}\b'
            'AWS access key id'        = '\bAKIA[0-9A-Z]{16}\b'
        }

        # Helper: scan every shippable file for a regex, returning file/line/value.
        function Get-Matches {
            param([string]$Pattern)
            foreach ($f in $script:ShipFiles) {
                Select-String -Path $f.FullName -Pattern $Pattern -AllMatches |
                    ForEach-Object {
                        $lineNo = $_.LineNumber
                        $rel = $_.Path.Replace($script:ModuleRoot, '').TrimStart('\', '/')
                        foreach ($m in $_.Matches) {
                            [pscustomobject]@{ File = $rel; Line = $lineNo; Value = $m.Value }
                        }
                    }
            }
        }
    }

    It 'contains no Azure GUIDs outside the documented allow-list' {
        $offenders = @(Get-Matches -Pattern $script:GuidRegex |
            Where-Object { -not (Test-IsAllowedGuid $_.Value) })
        $report = ($offenders | ForEach-Object { "  $($_.File):$($_.Line)  $($_.Value)" }) -join "`n"
        $offenders.Count | Should -Be 0 -Because "every GUID must be an allow-listed public/example/module GUID; add a documented allow-list entry if intentional. Offenders:`n$report"
    }

    It 'contains no email addresses on non-example domains' {
        $offenders = @(Get-Matches -Pattern $script:EmailRegex | Where-Object {
                $domain = ($_.Value -split '@', 2)[1].ToLowerInvariant()
                -not ($script:AllowedEmailDomains -contains $domain)
            })
        $report = ($offenders | ForEach-Object { "  $($_.File):$($_.Line)  $($_.Value)" }) -join "`n"
        $offenders.Count | Should -Be 0 -Because "real email addresses must not be shipped; use an example domain (contoso.com etc.). Offenders:`n$report"
    }

    It 'contains no hard secret material (keys, tokens, storage keys)' {
        $allOffenders = New-Object System.Collections.Generic.List[string]
        foreach ($name in $script:SecretPatterns.Keys) {
            foreach ($hit in @(Get-Matches -Pattern $script:SecretPatterns[$name])) {
                $allOffenders.Add("  [$name] $($hit.File):$($hit.Line)")
            }
        }
        $report = ($allOffenders -join "`n")
        $allOffenders.Count | Should -Be 0 -Because "secret material must never be committed. Offenders:`n$report"
    }

    It 'does not track generated test-result artifacts that may contain live environment data' {
        $repoRoot = Split-Path -Path $script:ModuleRoot -Parent
        $trackedResults = @(& git -C $repoRoot ls-files -- 'AzLocal.UpdateManagement/Tests/TestResults/**')
        $LASTEXITCODE | Should -Be 0
        $trackedResults | Should -BeNullOrEmpty -Because 'live logs and reports can contain resource names and identifiers and must remain ignored'
    }
}
