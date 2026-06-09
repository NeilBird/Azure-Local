#Requires -Module Pester
<#
.SYNOPSIS
    Repo-hygiene guard: fail the build if any file under Tests\ contains
    accidentally-added PII (real GUIDs in identity contexts, real public
    IPv4 addresses, real-looking email addresses, or AAD UPNs).

.DESCRIPTION
    The Tests\ folder ships in the public GitHub repo. This guard scans
    every file under Tests\ for patterns that would leak customer or
    corporate identifiers, and asserts every hit is on the known-safe
    allow-list. Add new fixture values to the allow-list ONLY after
    confirming they are synthetic.

    What the guard checks (per file, all hits aggregated):
      - Email addresses (anything matching local@domain.tld where the
        local part is at least 3 chars).
      - Public IPv4 addresses (anything NOT in RFC1918, loopback,
        link-local, RFC5737 doc ranges, multicast, or the well-known
        public-DNS allow-list). Tokens that look like four-part
        version strings (e.g. SbeVersion 4.5.6.7-RegressionMarker)
        are excluded by the trailing word-boundary.
      - GUIDs appearing in identity contexts (tenantId, clientId,
        objectId, principalId, applicationId), excluding the zero-GUID
        and the explicit allow-list below.
      - AAD UPNs / domain names (anything ending in .onmicrosoft.com).

    What the guard DOES NOT check:
      - Subscription IDs in resource paths (these are not credentials
        and the project owner has confirmed they are acceptable in
        public fixtures).
      - Run IDs / action-plan IDs in error-message strings (same
        rationale; already on the allow-list below).

    To extend the allow-list, add the literal token to the matching
    $allowed* collection in BeforeAll. To extend the BLOCK list, add
    a new aggregator loop + Should assertion in the matching It below.

.NOTES
    Author: Neil Bird, Microsoft.
    Added:  v0.7.99
#>

Describe 'PII Guard: Tests folder' {

    BeforeAll {
        $script:TestsRoot     = $PSScriptRoot
        $script:GuardFileName = 'Pii-Guard.Tests.ps1'

        $script:AllowedGuids = @(
            '00000000-0000-0000-0000-000000000000',
            'fbaf508b-cb61-4383-9cda-a42bfa0c7bc9',
            'add1f87d-4174-4997-ae39-d9d41088be27',
            '1084e062-5d0b-48c0-b4d6-c1693b575bc1'
        )

        $script:AllowedEmailDomains = @(
            'example.com', 'example.org', 'example.net',
            'contoso.com', 'fabrikam.com',
            'noreply.github.com', 'users.noreply.github.com'
        )

        $script:AllowedPublicIPs = @(
            '8.8.8.8', '8.8.4.4',
            '1.1.1.1', '1.0.0.1',
            '9.9.9.9', '149.112.112.112',
            '208.67.222.222', '208.67.220.220'
        )

        $script:TargetFiles = Get-ChildItem -Path $script:TestsRoot -File -Recurse |
            Where-Object { $_.Name -ne $script:GuardFileName -and $_.Extension -in @('.ps1','.psm1','.psd1','.json','.md','.xml','.yml','.yaml','.csv') }
    }

    It 'enumerates at least one target file' {
        ($script:TargetFiles | Measure-Object).Count | Should -BeGreaterThan 0
    }

    It 'allow-listed GUID list contains zero-GUID sentinel' {
        $script:AllowedGuids | Should -Contain '00000000-0000-0000-0000-000000000000'
    }

    It 'finds no real-looking email addresses' {
        $emailRx = '(?<![A-Za-z0-9._%+-])[A-Za-z0-9._%+-]{3,}@[A-Za-z0-9.-]+\.[A-Za-z]{2,24}\b'
        $unsafe = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $script:TargetFiles) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, $emailRx)) {
                $addr = $m.Value
                $dom = ($addr -split '@')[1].ToLowerInvariant()
                $ok = $false
                foreach ($d in $script:AllowedEmailDomains) {
                    if ($dom -eq $d -or $dom.EndsWith(".$d")) { $ok = $true; break }
                }
                if (-not $ok) { $unsafe.Add("$($f.Name): $addr") }
            }
        }
        $unsafe | Should -BeNullOrEmpty -Because "found email-shaped tokens not on the allow-list: $($unsafe -join '; ')"
    }

    It 'finds no real-looking AAD tenant UPN domains (.onmicrosoft.com)' {
        $unsafe = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $script:TargetFiles) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, '\b[A-Za-z0-9-]+\.onmicrosoft\.com\b')) {
                $upnDomain = $m.Value
                if ($upnDomain -notmatch '^(contoso|fabrikam|example)\.onmicrosoft\.com$') {
                    $unsafe.Add("$($f.Name): $upnDomain")
                }
            }
        }
        $unsafe | Should -BeNullOrEmpty -Because "found tenant UPN domains not on the allow-list: $($unsafe -join '; ')"
    }

    It 'finds no GUIDs in identity contexts (tenantId/clientId/objectId/principalId/applicationId)' {
        $idCtxRx = '(?i)\b(?:tenant|client|object|principal|application)[-_ ]?id\b\s*[:=]\s*["'']?(?<g>[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
        $unsafe = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $script:TargetFiles) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            foreach ($m in [regex]::Matches($text, $idCtxRx)) {
                $g = $m.Groups['g'].Value.ToLowerInvariant()
                if ($script:AllowedGuids -notcontains $g) {
                    $unsafe.Add("$($f.Name): $g")
                }
            }
        }
        $unsafe | Should -BeNullOrEmpty -Because "found GUIDs in identity contexts not on the allow-list: $($unsafe -join '; ')"
    }

    It 'finds no real-looking public IPv4 addresses' {
        # Dotted-quad with word-boundaries. The trailing lookahead excludes
        # tokens immediately followed by another digit, dot, hyphen, or
        # letter, which removes version-string false-positives like
        # '4.5.6.7-RegressionMarker' or SemVer 'X.Y.Z.W-suffix'.
        $ipRx = '(?<![\w.])(?:25[0-5]|2[0-4]\d|1\d\d|\d{1,2})(?:\.(?:25[0-5]|2[0-4]\d|1\d\d|\d{1,2})){3}(?![\d.\-A-Za-z])'

        $unsafe = New-Object 'System.Collections.Generic.List[string]'
        foreach ($f in $script:TargetFiles) {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            $seen = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($m in [regex]::Matches($text, $ipRx)) {
                $ip = $m.Value
                if (-not $seen.Add($ip)) { continue }
                if ($script:AllowedPublicIPs -contains $ip) { continue }

                $octets = $ip -split '\.' | ForEach-Object { [int]$_ }
                $o1 = $octets[0]; $o2 = $octets[1]; $o3 = $octets[2]

                if ($o1 -eq 0)                                   { continue }  # 0.0.0.0/8
                if ($o1 -eq 10)                                  { continue }  # RFC1918
                if ($o1 -eq 172 -and $o2 -ge 16 -and $o2 -le 31) { continue }  # RFC1918
                if ($o1 -eq 192 -and $o2 -eq 168)                { continue }  # RFC1918
                if ($o1 -eq 127)                                 { continue }  # loopback
                if ($o1 -eq 169 -and $o2 -eq 254)                { continue }  # link-local
                if ($o1 -eq 100 -and $o2 -ge 64 -and $o2 -le 127){ continue }  # CGNAT
                if ($o1 -ge 224)                                 { continue }  # multicast / reserved
                if ($o1 -eq 255)                                 { continue }  # broadcast / mask
                if ($o1 -eq 192 -and $o2 -eq 0   -and $o3 -eq 2)  { continue } # RFC5737 TEST-NET-1
                if ($o1 -eq 198 -and $o2 -eq 51  -and $o3 -eq 100){ continue } # RFC5737 TEST-NET-2
                if ($o1 -eq 203 -and $o2 -eq 0   -and $o3 -eq 113){ continue } # RFC5737 TEST-NET-3
                if ($o1 -eq 198 -and ($o2 -eq 18 -or $o2 -eq 19)) { continue } # RFC2544 benchmarking

                # Subnet-mask shapes (every octet is 0 or 255).
                $maskShape = $true
                foreach ($o in $octets) { if ($o -ne 0 -and $o -ne 255) { $maskShape = $false; break } }
                if ($maskShape) { continue }

                $unsafe.Add("$($f.Name): $ip")
            }
        }
        $unsafe | Should -BeNullOrEmpty -Because "found public IPv4 addresses not on the allow-list: $($unsafe -join '; ')"
    }
}
