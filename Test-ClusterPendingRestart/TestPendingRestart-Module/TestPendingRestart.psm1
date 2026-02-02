##########################################################################################################
<#
.SYNOPSIS
    Module:     TestPendingRestart
    Author:     Neil Bird, MSFT
    Version:    0.2.0
    Created:    January 30th 2026
    Updated:    January 30th 2026

.DESCRIPTION
    This module provides functions to test computers for pending restart indicators.
    It checks for common pending restart signals such as Windows Update, Component Based Servicing,
    pending file rename operations, computer rename, domain join/rename signals, SCCM/ConfigMgr
    client indicators, and Azure Local/HCI-specific indicators (CAU state).

.NOTES
    Requires PowerShell 5.1 or later.
    
    THIS CODE-SAMPLE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED 
    OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR 
    FITNESS FOR A PARTICULAR PURPOSE.

    This sample is not supported under any Microsoft standard support program or service. 
    The script is provided AS IS without warranty of any kind. Microsoft further disclaims all
    implied warranties including, without limitation, any implied warranties of merchantability
    or of fitness for a particular purpose. The entire risk arising out of the use or performance
    of the sample and documentation remains with you. In no event shall Microsoft, its authors,
    or anyone else involved in the creation, production, or delivery of the script be liable for 
    any damages whatsoever (including, without limitation, damages for loss of business profits, 
    business interruption, loss of business information, or other pecuniary loss) arising out of 
    the use of or inability to use the sample or documentation, even if Microsoft has been advised 
    of the possibility of such damages, rising out of the use of or inability to use the sample script, 
    even if Microsoft has been advised of the possibility of such damages. 
#>
##########################################################################################################

function Write-Log {
<#
.SYNOPSIS
    Writes a timestamped, color-coded log message to the console.

.DESCRIPTION
    Outputs a formatted log message with timestamp, level prefix, and appropriate color coding.
    Useful for providing consistent, readable output in scripts.

.PARAMETER Message
    The message text to display.

.PARAMETER Level
    The log level determining the color and prefix. Valid values:
    Info, Success, Warning, Error, Processing, Start, Complete

.EXAMPLE
    Write-Log "Starting process..." -Level Start

.EXAMPLE
    Write-Log "Operation completed successfully" -Level Success
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, Position=0)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ValidateSet('Info', 'Success', 'Warning', 'Error', 'Processing', 'Start', 'Complete')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    $levelConfig = @{
        'Info'       = @{ Color = 'White';   Prefix = '[INFO]    ' }
        'Success'    = @{ Color = 'Green';   Prefix = '[SUCCESS] ' }
        'Warning'    = @{ Color = 'Yellow';  Prefix = '[WARNING] ' }
        'Error'      = @{ Color = 'Red';     Prefix = '[ERROR]   ' }
        'Processing' = @{ Color = 'Cyan';    Prefix = '[PROCESS] ' }
        'Start'      = @{ Color = 'Magenta'; Prefix = '[START]   ' }
        'Complete'   = @{ Color = 'Green';   Prefix = '[COMPLETE]' }
    }

    $config = $levelConfig[$Level]
    $formattedMessage = "[$timestamp] $($config.Prefix) $Message"
    
    Write-Host $formattedMessage -ForegroundColor $config.Color
}

function Test-PendingRestart {
<#
.SYNOPSIS
    Tests a computer for pending restart indicators.

.DESCRIPTION
    Checks a local or remote computer for common pending restart signals including:
    - Component Based Servicing (CBS) reboot pending
    - Windows Update reboot required
    - Pending file rename operations
    - Computer rename pending
    - Domain join/rename signals (Netlogon)
    - SCCM/ConfigMgr client reboot pending
    - Azure Local/HCI Cluster-Aware Updating (CAU) state

.PARAMETER ComputerName
    The name of the computer to check. Can be localhost, the local computer name,
    or a remote computer name.

.PARAMETER Credential
    Optional PSCredential for remote computer authentication.

.PARAMETER TimeoutSeconds
    Timeout in seconds for remote connection attempts. Default is 30 seconds.

.PARAMETER Detailed
    Switch to return additional diagnostic information including registry values and timestamps.

.OUTPUTS
    PSCustomObject with properties:
    - ComputerName: The name of the checked computer
    - PendingRestart: Boolean indicating if a restart is pending ($null if check failed)
    - Reasons: Semicolon-separated list of pending restart reasons
    - Errors: Semicolon-separated list of any errors encountered
    - Success: Boolean indicating if all checks completed without errors
    - Details: (Only with -Detailed) Hashtable with additional diagnostic information

.EXAMPLE
    Test-PendingRestart -ComputerName "localhost"
    Tests the local computer for pending restart indicators.

.EXAMPLE
    Test-PendingRestart -ComputerName "Server01" -Credential (Get-Credential)
    Tests a remote computer with explicit credentials.

.EXAMPLE
    Test-PendingRestart -ComputerName "Server01" -Detailed
    Tests a remote computer and returns detailed diagnostic information.

.EXAMPLE
    "Server01", "Server02" | ForEach-Object { Test-PendingRestart -ComputerName $_ }
    Tests multiple remote computers for pending restart indicators.
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true, ValueFromPipeline=$true, ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias('CN', 'Name')]
        [string]$ComputerName,

        [Parameter(Mandatory=$false)]
        [PSCredential]$Credential,

        [Parameter(Mandatory=$false)]
        [ValidateRange(5, 300)]
        [int]$TimeoutSeconds = 30,

        [Parameter(Mandatory=$false)]
        [switch]$Detailed
    )

    begin {
        # Pre-create the script block once for efficiency
        $checkScript = {
            param([bool]$IncludeDetails)
            
            $reasons = [System.Collections.Generic.List[string]]::new()
            $errors = [System.Collections.Generic.List[string]]::new()
            $details = @{}

            # 1) CBS servicing stack / Component Based Servicing
            try {
                $cbsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
                if (Test-Path $cbsPath) {
                    $reasons.Add('CBS:RebootPending')
                    if ($IncludeDetails) {
                        $details['CBS_RebootPending'] = @{
                            Path = $cbsPath
                            Exists = $true
                            CheckedAt = (Get-Date).ToString('o')
                        }
                    }
                }
            } catch {
                $errors.Add("CBS check failed: $($_.Exception.Message)")
            }

            # 2) Windows Update
            try {
                $wuPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
                if (Test-Path $wuPath) {
                    $reasons.Add('WU:RebootRequired')
                    if ($IncludeDetails) {
                        $details['WU_RebootRequired'] = @{
                            Path = $wuPath
                            Exists = $true
                            CheckedAt = (Get-Date).ToString('o')
                        }
                    }
                }
            } catch {
                $errors.Add("Windows Update check failed: $($_.Exception.Message)")
            }

            # 3) Pending file rename operations (common driver/update indicator)
            try {
                $pfr = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
                if ($null -ne $pfr.PendingFileRenameOperations) {
                    $reasons.Add('SessionMgr:PendingFileRenameOperations')
                    if ($IncludeDetails) {
                        $details['PendingFileRenameOperations'] = @{
                            Count = ($pfr.PendingFileRenameOperations | Where-Object { $_ }).Count
                            CheckedAt = (Get-Date).ToString('o')
                        }
                    }
                }
            } catch {
                $errors.Add("Pending file rename check failed: $($_.Exception.Message)")
            }

            # 4) Computer rename pending
            try {
                $active = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
                $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
                if ($active -and $pending -and $active -ne $pending) {
                    $reasons.Add("ComputerName:RenamePending ($active -> $pending)")
                    if ($IncludeDetails) {
                        $details['ComputerRename'] = @{
                            ActiveName = $active
                            PendingName = $pending
                            CheckedAt = (Get-Date).ToString('o')
                        }
                    }
                }
            } catch {
                $errors.Add("Computer rename check failed: $($_.Exception.Message)")
            }

            # 5) Domain join / rename signals
            try {
                if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\JoinDomain') { 
                    $reasons.Add('Netlogon:JoinDomain')
                    if ($IncludeDetails) { $details['Netlogon_JoinDomain'] = $true }
                }
                if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\AvoidSpnSet') { 
                    $reasons.Add('Netlogon:AvoidSpnSet')
                    if ($IncludeDetails) { $details['Netlogon_AvoidSpnSet'] = $true }
                }
            } catch {
                $errors.Add("Netlogon check failed: $($_.Exception.Message)")
            }

            # 6) SCCM/ConfigMgr client (if present)
            try {
                if (Test-Path 'HKLM:\SOFTWARE\Microsoft\CCM\ClientSDK') {
                    $util = Invoke-CimMethod -Namespace root\ccm\ClientSDK -ClassName CCM_ClientUtilities -MethodName DetermineIfRebootPending -ErrorAction Stop
                    if ($util.RebootPending -or $util.IsHardRebootPending) {
                        $reasons.Add("ConfigMgr:RebootPending (Soft=$($util.RebootPending) Hard=$($util.IsHardRebootPending))")
                        if ($IncludeDetails) {
                            $details['ConfigMgr'] = @{
                                RebootPending = $util.RebootPending
                                IsHardRebootPending = $util.IsHardRebootPending
                                CheckedAt = (Get-Date).ToString('o')
                            }
                        }
                    }
                }
            } catch {
                $errors.Add("ConfigMgr check failed: $($_.Exception.Message)")
            }

            # 7) Azure Local/HCI - Cluster-Aware Updating (CAU) state
            try {
                $cauPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\RebootRequired'
                if (Test-Path $cauPath) {
                    $reasons.Add('Orchestrator:RebootRequired')
                    if ($IncludeDetails) {
                        $details['Orchestrator_RebootRequired'] = @{
                            Path = $cauPath
                            Exists = $true
                            CheckedAt = (Get-Date).ToString('o')
                        }
                    }
                }
                
                # Check for Azure Stack HCI update state
                $hciUpdatePath = 'HKLM:\SOFTWARE\Microsoft\AzureStack\HCI\Update'
                if (Test-Path $hciUpdatePath) {
                    $hciState = Get-ItemProperty -Path $hciUpdatePath -ErrorAction SilentlyContinue
                    if ($hciState.RebootRequired -eq 1) {
                        $reasons.Add('AzureStackHCI:RebootRequired')
                        if ($IncludeDetails) {
                            $details['AzureStackHCI_Update'] = @{
                                Path = $hciUpdatePath
                                RebootRequired = $true
                                CheckedAt = (Get-Date).ToString('o')
                            }
                        }
                    }
                }
            } catch {
                $errors.Add("Azure Local/HCI check failed: $($_.Exception.Message)")
            }

            # Result object
            $result = [pscustomobject]@{
                ComputerName    = $env:COMPUTERNAME
                PendingRestart  = ($reasons.Count -gt 0)
                Reasons         = if ($reasons.Count) { $reasons -join '; ' } else { '' }
                Errors          = if ($errors.Count) { $errors -join '; ' } else { '' }
                Success         = ($errors.Count -eq 0)
            }
            
            if ($IncludeDetails) {
                $result | Add-Member -NotePropertyName 'Details' -NotePropertyValue $details -Force
            }
            
            $result
        }
    }

    process {
        $includeDetails = $Detailed.IsPresent

        try {
            if ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq 'localhost' -or $ComputerName -eq '.') {
                & $checkScript -IncludeDetails $includeDetails
            } else {
                # Test connectivity before attempting remote command
                $pingJob = Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue
                if (-not $pingJob) {
                    Write-Log "Unable to reach computer '$ComputerName' - host is not responding to ping." -Level Warning
                    return [pscustomobject]@{
                        ComputerName    = $ComputerName
                        PendingRestart  = $null
                        Reasons         = ''
                        Errors          = 'Host unreachable - ping failed'
                        Success         = $false
                    }
                }

                # Build session options with timeout
                $sessionOption = New-PSSessionOption -OpenTimeout ($TimeoutSeconds * 1000) -OperationTimeout ($TimeoutSeconds * 1000)
                
                # Build invoke parameters
                $invokeParams = @{
                    ComputerName   = $ComputerName
                    ScriptBlock    = $checkScript
                    ArgumentList   = @($includeDetails)
                    SessionOption  = $sessionOption
                    ErrorAction    = 'Stop'
                }
                
                if ($Credential) {
                    $invokeParams['Credential'] = $Credential
                }

                Invoke-Command @invokeParams
            }
        } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
            Write-Log "Remote connection to '$ComputerName' failed: $($_.Exception.Message)" -Level Error
            return [pscustomobject]@{
                ComputerName    = $ComputerName
                PendingRestart  = $null
                Reasons         = ''
                Errors          = "Remote connection failed: $($_.Exception.Message)"
                Success         = $false
            }
        } catch [System.UnauthorizedAccessException] {
            Write-Log "Access denied to '$ComputerName': $($_.Exception.Message)" -Level Error
            return [pscustomobject]@{
                ComputerName    = $ComputerName
                PendingRestart  = $null
                Reasons         = ''
                Errors          = "Access denied: $($_.Exception.Message)"
                Success         = $false
            }
        } catch {
            Write-Log "Unexpected error checking '$ComputerName': $($_.Exception.Message)" -Level Error
            return [pscustomobject]@{
                ComputerName    = $ComputerName
                PendingRestart  = $null
                Reasons         = ''
                Errors          = "Unexpected error: $($_.Exception.Message)"
                Success         = $false
            }
        }
    }

    end {
        # Cleanup if needed
    }
}

# Export module members
Export-ModuleMember -Function Write-Log, Test-PendingRestart
