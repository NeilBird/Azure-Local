function Get-AzLocalSideloadAuthMap {
    <#
    .SYNOPSIS
        Parses the sideload auth-map CSV that maps the numeric UpdateAuthAccountId
        cluster tag to the Key Vault secrets + remoting settings used to stage a
        sideloaded solution update on an on-premises Azure Local cluster.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation feature.

        Reads a CSV with these columns:
          - UpdateAuthAccountId  (REQUIRED) numeric account id, 1-3 digits
                                 (e.g. 001). Matches the per-cluster
                                 'UpdateAuthAccountId' tag written by Step.2.
          - KeyVaultName         (REQUIRED) Key Vault holding the AD credential.
          - UsernameSecretName   (REQUIRED) KV secret holding the username
                                 (UPN 'user@contoso.com' recommended;
                                 'DOMAIN\user' also accepted).
          - PasswordSecretName   (REQUIRED) KV secret holding the password.
          - RemotingTargetFqdn   (optional) explicit FQDN to remote to; when
                                 set it overrides the cluster-name + suffix
                                 resolution.
          - FqdnSuffix           (optional) per-row DNS suffix appended to the
                                 cluster name (e.g. '.corp.contoso.com').
          - AuthMechanism        (optional) WinRM auth mechanism
                                 (Kerberos|Negotiate|Default). Defaults to
                                 Default at the remoting layer.
          - ImportSharePath      (optional) override for the cluster
                                 infrastructure 'import' UNC share.

        Validation:
          - UpdateAuthAccountId must match ^\d{1,3}$ (numeric only). The raw
            (trimmed) string is used verbatim as the lookup key so it must
            match the tag value exactly.
          - KeyVaultName, UsernameSecretName, PasswordSecretName must be
            non-empty.
          - A DUPLICATE UpdateAuthAccountId is a HARD ERROR (the mapping would
            be ambiguous). This is a pre-requisite gate for the sideload
            pipeline.

        Returns a hashtable keyed by the trimmed UpdateAuthAccountId string,
        whose values are [PSCustomObject] rows. An empty CSV returns an empty
        hashtable.

    .PARAMETER Path
        Path to the auth-map CSV file.

    .OUTPUTS
        [hashtable] keyed by UpdateAuthAccountId -> [PSCustomObject].
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Sideload auth-map CSV not found at '$Path'. Configure paths.authMap in sideload-settings.yml (or pass -Path) to a CSV with columns UpdateAuthAccountId,KeyVaultName,UsernameSecretName,PasswordSecretName."
    }

    try {
        # Tolerate inline documentation: drop blank lines and '#'-prefixed
        # comment lines (Import-Csv has no native comment support) before
        # parsing. The real header is the first non-comment line.
        $rawLines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
        $dataLines = @($rawLines | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and ($_.TrimStart())[0] -ne '#'
        })
        $rows = if ($dataLines.Count -gt 0) { @($dataLines | ConvertFrom-Csv) } else { @() }
    }
    catch {
        throw "Failed to read sideload auth-map CSV '$Path': $($_.Exception.Message)"
    }

    $authMap = @{}
    if ($rows.Count -eq 0) {
        return $authMap
    }

    # Column presence is validated from the first row's properties so a
    # misspelled header surfaces clearly instead of as silent $null fields.
    $firstRow = $rows[0]
    $required = @('UpdateAuthAccountId', 'KeyVaultName', 'UsernameSecretName', 'PasswordSecretName')
    $columns = @($firstRow.PSObject.Properties.Name)
    $missing = @($required | Where-Object { $columns -notcontains $_ })
    if ($missing.Count -gt 0) {
        throw "Sideload auth-map CSV '$Path' is missing required column(s): $($missing -join ', '). Required columns: $($required -join ', ')."
    }

    $rowIndex = 0
    foreach ($row in $rows) {
        $rowIndex++
        $accountId = ([string]$row.UpdateAuthAccountId).Trim()
        if ([string]::IsNullOrWhiteSpace($accountId)) {
            throw "Sideload auth-map CSV '$Path' row $rowIndex has an empty UpdateAuthAccountId."
        }
        if ($accountId -notmatch '^\d{1,3}$') {
            throw "Sideload auth-map CSV '$Path' row $rowIndex has an invalid UpdateAuthAccountId '$accountId'. Must be numeric (1-3 digits, e.g. 001)."
        }
        if ($authMap.ContainsKey($accountId)) {
            throw "Sideload auth-map CSV '$Path' contains a DUPLICATE UpdateAuthAccountId '$accountId' (row $rowIndex). Each account id must be unique."
        }

        $keyVaultName = ([string]$row.KeyVaultName).Trim()
        $usernameSecret = ([string]$row.UsernameSecretName).Trim()
        $passwordSecret = ([string]$row.PasswordSecretName).Trim()
        if ([string]::IsNullOrWhiteSpace($keyVaultName)) {
            throw "Sideload auth-map CSV '$Path' row $rowIndex (UpdateAuthAccountId '$accountId') has an empty KeyVaultName."
        }
        if ([string]::IsNullOrWhiteSpace($usernameSecret)) {
            throw "Sideload auth-map CSV '$Path' row $rowIndex (UpdateAuthAccountId '$accountId') has an empty UsernameSecretName."
        }
        if ([string]::IsNullOrWhiteSpace($passwordSecret)) {
            throw "Sideload auth-map CSV '$Path' row $rowIndex (UpdateAuthAccountId '$accountId') has an empty PasswordSecretName."
        }

        # Optional columns are tolerated as absent properties.
        $remotingTargetFqdn = if ($columns -contains 'RemotingTargetFqdn') { ([string]$row.RemotingTargetFqdn).Trim() } else { '' }
        $fqdnSuffix = if ($columns -contains 'FqdnSuffix') { ([string]$row.FqdnSuffix).Trim() } else { '' }
        $authMechanism = if ($columns -contains 'AuthMechanism') { ([string]$row.AuthMechanism).Trim() } else { '' }
        $importSharePath = if ($columns -contains 'ImportSharePath') { ([string]$row.ImportSharePath).Trim() } else { '' }

        $authMap[$accountId] = [PSCustomObject]@{
            UpdateAuthAccountId = $accountId
            KeyVaultName        = $keyVaultName
            UsernameSecretName  = $usernameSecret
            PasswordSecretName  = $passwordSecret
            RemotingTargetFqdn  = $remotingTargetFqdn
            FqdnSuffix          = $fqdnSuffix
            AuthMechanism       = $authMechanism
            ImportSharePath     = $importSharePath
        }
    }

    return $authMap
}
