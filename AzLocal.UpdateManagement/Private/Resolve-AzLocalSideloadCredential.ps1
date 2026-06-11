function Resolve-AzLocalSideloadCredential {
    <#
    .SYNOPSIS
        Builds the Active Directory [pscredential] used to PowerShell-remote into
        an Azure Local cluster, from the two Key Vault secrets named in the
        sideload auth-map row for the cluster's UpdateAuthAccountId.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation. Given an
        auth-map row (from Get-AzLocalSideloadAuthMap), reads the username and
        password secrets from the row's Key Vault and returns a [pscredential].

        Key Vault authentication is assumed to be already established by the
        pipeline (azure/login OIDC, managed identity, or service principal) per
        the SIDELOAD_KV_AUTH variable - this helper only calls
        Get-AzKeyVaultSecret. The actual KV read is isolated in the thin wrapper
        Get-AzLocalKeyVaultSecretText so it can be mocked in unit tests.

        The username may be a UPN ('svc@contoso.com') or DOMAIN\user form; both
        are accepted by [pscredential]. The plaintext password is converted to a
        SecureString and the plaintext copy is cleared from memory before return.

    .PARAMETER AuthRow
        A single auth-map row [PSCustomObject] with KeyVaultName,
        UsernameSecretName, PasswordSecretName.

    .OUTPUTS
        [System.Management.Automation.PSCredential]
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [PSCustomObject]$AuthRow
    )

    foreach ($field in @('KeyVaultName', 'UsernameSecretName', 'PasswordSecretName')) {
        if ([string]::IsNullOrWhiteSpace([string]$AuthRow.$field)) {
            throw "Resolve-AzLocalSideloadCredential: auth-map row (UpdateAuthAccountId '$($AuthRow.UpdateAuthAccountId)') has an empty $field."
        }
    }

    $username = $null
    $password = $null
    try {
        $username = Get-AzLocalKeyVaultSecretText -VaultName $AuthRow.KeyVaultName -SecretName $AuthRow.UsernameSecretName
        $password = Get-AzLocalKeyVaultSecretText -VaultName $AuthRow.KeyVaultName -SecretName $AuthRow.PasswordSecretName

        if ([string]::IsNullOrWhiteSpace($username)) {
            throw "Username secret '$($AuthRow.UsernameSecretName)' in vault '$($AuthRow.KeyVaultName)' resolved to an empty value."
        }
        if ([string]::IsNullOrEmpty($password)) {
            throw "Password secret '$($AuthRow.PasswordSecretName)' in vault '$($AuthRow.KeyVaultName)' resolved to an empty value."
        }

        $securePassword = ConvertTo-SecureString -String $password -AsPlainText -Force
        return New-Object System.Management.Automation.PSCredential ($username.Trim(), $securePassword)
    }
    finally {
        # Clear the plaintext secret copies from memory as soon as possible.
        if ($null -ne $password) { $password = $null }
        Remove-Variable -Name password -ErrorAction SilentlyContinue
    }
}

function Get-AzLocalKeyVaultSecretText {
    <#
    .SYNOPSIS
        Thin wrapper around Get-AzKeyVaultSecret -AsPlainText so the parent
        function can be unit-tested by mocking just this call.
    .OUTPUTS
        [string] the plaintext secret value.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$VaultName,
        [Parameter(Mandatory = $true)][string]$SecretName
    )

    if (-not (Get-Command Get-AzKeyVaultSecret -ErrorAction SilentlyContinue)) {
        throw "Az.KeyVault module is not loaded. Install with: Install-Module Az.KeyVault -Scope CurrentUser"
    }

    try {
        $value = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SecretName -AsPlainText -ErrorAction Stop
    }
    catch {
        throw "Failed to read Key Vault secret '$SecretName' from vault '$VaultName': $($_.Exception.Message)"
    }

    return $value
}
