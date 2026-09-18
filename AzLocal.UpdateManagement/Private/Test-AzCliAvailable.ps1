function Test-AzCliAvailable {
    <#
    .SYNOPSIS
        Tests if a supported Azure CLI (az) version is installed and available.
    .DESCRIPTION
        Checks if the 'az' command is available on the system PATH and parses the installed version
        from 'az --version'. Azure CLI 2.78.0 or later is required. Versions earlier than 2.90.0
        are supported with a warning. If az is not found, prompts interactive users to download and
        install the Azure CLI MSI. In non-interactive environments, throws with installation instructions.
    .OUTPUTS
        Returns $true if a supported az CLI version is available. Throws if unavailable or unsupported.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    [version]$minimumSupportedVersion = '2.78.0'
    [version]$recommendedVersion = '2.90.0'
    $installedNow = $false

    if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
        # az not found - determine if we're running interactively
        $isInteractive = [Environment]::UserInteractive -and -not $env:TF_BUILD -and -not $env:GITHUB_ACTIONS -and -not $env:SYSTEM_TEAMFOUNDATIONCOLLECTIONURI

        if (-not $isInteractive) {
            throw "Azure CLI (az) is not installed. Install it from https://aka.ms/installazurecliwindows or run: winget install Microsoft.AzureCLI"
        }

        Write-Log -Message "" -Level Info
        Write-Log -Message "Azure CLI (az) is not installed on this system." -Level Error
        Write-Log -Message "The Azure CLI is required for this module to communicate with Azure." -Level Warning
        Write-Log -Message "Download URL: https://aka.ms/installazurecliwindows" -Level Header
        Write-Log -Message "" -Level Info

        $response = Read-Host "Would you like to download and install the Azure CLI now? (y/n)"
        if ($response -notin @('y', 'Y', 'yes', 'Yes')) {
            throw "Azure CLI (az) is required but not installed. Install it from https://aka.ms/installazurecliwindows or run: winget install Microsoft.AzureCLI"
        }

        # Download and install
        $msiPath = Join-Path $env:TEMP 'AzureCLI.msi'
        try {
            Write-Log -Message "Downloading Azure CLI installer..." -Level Warning
            Invoke-WebRequest -Uri 'https://aka.ms/installazurecliwindows' -OutFile $msiPath -UseBasicParsing

            Write-Log -Message "Installing Azure CLI (this may take a few minutes)..." -Level Warning
            $installProcess = Start-Process msiexec.exe -ArgumentList "/I `"$msiPath`" /quiet" -PassThru
            if (-not $installProcess.WaitForExit(1800000)) {
                # 30 minute safety timeout - prevents indefinite hangs in automation
                try { $installProcess.Kill() } catch { $null = $_ <# process may have just exited between WaitForExit and Kill; nothing to do #> }
                throw "Azure CLI installation timed out after 30 minutes."
            }
            if ($installProcess.ExitCode -ne 0) {
                throw "MSI installer exited with code $($installProcess.ExitCode)"
            }

            # Refresh PATH so the current session can find az
            $machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
            $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
            $env:PATH = "$machinePath;$userPath"

            if (-not (Get-Command 'az' -ErrorAction SilentlyContinue)) {
                throw "Azure CLI was installed but 'az' command is not found in PATH. Please restart your PowerShell session."
            }

            $installedNow = $true
        }
        catch {
            $errorMsg = $_.Exception.Message
            if ($errorMsg -notmatch 'not found in PATH|not installed') {
                Write-Log -Message "Failed to install Azure CLI: $errorMsg" -Level Error
            }
            throw "Azure CLI installation failed. Please install manually from https://aka.ms/installazurecliwindows - Error: $errorMsg"
        }
        finally {
            # Clean up MSI file
            if (Test-Path $msiPath) {
                Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $azVersionOutput = @(& az --version 2>&1)
    $azVersionText = $azVersionOutput -join "`n"
    $versionMatch = [regex]::Match($azVersionText, '(?im)^\s*azure-cli\s+([0-9]+(?:\.[0-9]+){2,3})(?:\s|$)')
    if (-not $versionMatch.Success) {
        throw "Unable to determine the installed Azure CLI version from 'az --version'. Install Azure CLI $minimumSupportedVersion or later from https://aka.ms/installazurecliwindows"
    }

    [version]$azVersion = $versionMatch.Groups[1].Value
    if ($azVersion -lt $minimumSupportedVersion) {
        throw "Azure CLI $azVersion is not supported. Version $minimumSupportedVersion or later is required. Upgrade from https://aka.ms/installazurecliwindows or run: az upgrade"
    }

    if ($installedNow) {
        Write-Log -Message "Azure CLI v$azVersion installed successfully." -Level Success
        Write-Log -Message "Run 'az login' to authenticate before using this module." -Level Warning
    }

    if ($azVersion -lt $recommendedVersion) {
        Write-Log -Message "Azure CLI $azVersion is supported, but version $recommendedVersion or later is recommended. Upgrade from https://aka.ms/installazurecliwindows or run: az upgrade" -Level Warning
    }

    return $true
}
