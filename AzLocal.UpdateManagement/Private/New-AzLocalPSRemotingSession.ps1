function New-AzLocalPSRemotingSession {
    <#
    .SYNOPSIS
        Opens a PowerShell remoting (WinRM) PSSession to an Azure Local cluster
        node using the AD credential resolved from Key Vault.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation.

        Transport defaults to WinRM over HTTPS (port 5986) with Kerberos/Negotiate
        authentication - the recommended posture for cross-forest service accounts.
        HTTP (5985) is supported as a documented fallback by passing -UseSsl:$false.
        CredSSP is intentionally NOT used: there is no second-hop (robocopy runs as
        the runner/agent over UNC, and Add-SolutionUpdate executes locally on the
        target node), so basic Kerberos/Negotiate is sufficient.

        The caller is responsible for Remove-PSSession in a finally block.

    .PARAMETER ComputerName
        The remoting target (cluster name, override FQDN, or name+suffix).

    .PARAMETER Credential
        The [pscredential] built by Resolve-AzLocalSideloadCredential.

    .PARAMETER UseSsl
        Use WinRM HTTPS (5986). Default $true. Set $false for the HTTP (5985)
        fallback.

    .PARAMETER Port
        Explicit WinRM port. When 0 (default), 5986 is used for SSL and 5985 for
        non-SSL.

    .PARAMETER Authentication
        WinRM authentication mechanism. Default 'Negotiate'. From the auth-map
        AuthMechanism column when supplied.

    .PARAMETER SkipCertificateCheck
        When using SSL, skip CA/CN/revocation checks on the node's WinRM HTTPS
        listener certificate (lab/self-signed only - not recommended for prod).

    .OUTPUTS
        [System.Management.Automation.Runspaces.PSSession]
    #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [System.Management.Automation.PSCredential]$Credential,

        [bool]$UseSsl = $true,

        [int]$Port = 0,

        [ValidateSet('Default', 'Negotiate', 'Kerberos', 'Basic', 'CredSSP')]
        [string]$Authentication = 'Negotiate',

        [switch]$SkipCertificateCheck
    )

    $effectivePort = if ($Port -gt 0) { $Port } elseif ($UseSsl) { 5986 } else { 5985 }

    $newSessionParams = @{
        ComputerName   = $ComputerName
        Credential     = $Credential
        Port           = $effectivePort
        Authentication = $Authentication
        ErrorAction    = 'Stop'
    }
    if ($UseSsl) { $newSessionParams['UseSSL'] = $true }

    if ($SkipCertificateCheck) {
        $newSessionParams['SessionOption'] = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
    }

    try {
        return New-PSSession @newSessionParams
    }
    catch {
        throw "Failed to open WinRM session to '$ComputerName' (port $effectivePort, SSL=$UseSsl, auth=$Authentication): $($_.Exception.Message)"
    }
}
