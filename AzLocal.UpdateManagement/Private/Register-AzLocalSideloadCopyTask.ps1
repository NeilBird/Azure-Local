function Register-AzLocalSideloadCopyTask {
    <#
    .SYNOPSIS
        Registers and starts a Windows Scheduled Task that runs the detached
        sideload copy worker (Tools/Invoke-AzLocalSideloadCopyTask.ps1).

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation.

        The Scheduled Task is the mechanism that lets a multi-hour robocopy
        OUTLIVE the short-lived CI/CD job (and even a host reboot). The task runs
        as the runner/agent service account (or a supplied principal) which must
        have UNC read rights to the shared cache and write rights to the target
        cluster import share.

        Network (UNC) access requires a logon type that carries network
        credentials: a group Managed Service Account (gMSA) or a stored password.
        The default S4U logon does NOT carry network credentials; supply
        -PrincipalUserId with -LogonType Password (and -Password) or a gMSA via
        -LogonType ServiceAccount for production UNC copies.

    .PARAMETER TaskName
        Name to register the task under.

    .PARAMETER ClusterName
        Cluster name (passed to the worker).

    .PARAMETER Version
        Solution-update version (passed to the worker).

    .PARAMETER OperationId
        Unique operation identifier used to reject writes from superseded workers.

    .PARAMETER SourcePath
        Verified media path (.zip or staged SBE folder).

    .PARAMETER TargetPath
        Destination UNC import-share folder.

    .PARAMETER StateRoot
        Shared UNC state root.

    .PARAMETER RobocopySwitches
        Extra robocopy switches passed through to the worker.

    .PARAMETER HeartbeatSeconds
        Heartbeat interval passed to the worker.

    .PARAMETER PrincipalUserId
        Optional account to run the task as (e.g. 'CONTOSO\svc-azl' or a gMSA
        'CONTOSO\gmsa-azl$'). Defaults to the current user.

    .PARAMETER LogonType
        Scheduled-task logon type. ServiceAccount (including gMSA) and Password
        carry network credentials required by UNC copies.

    .PARAMETER Password
        Secure password when -LogonType is Password.

    .OUTPUTS
        [string] the registered task name.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$ClusterName,
        [Parameter(Mandatory = $true)][string]$Version,
        [Parameter(Mandatory = $true)][string]$OperationId,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [string]$RobocopySwitches = '/R:5 /W:30',
        [int]$HeartbeatSeconds = 30,
        [string]$PrincipalUserId,
        [ValidateSet('S4U', 'Password', 'ServiceAccount', 'Interactive')]
        [string]$LogonType = 'ServiceAccount',
        [System.Security.SecureString]$Password
    )

    $networkPaths = @(@($SourcePath, $TargetPath, $StateRoot) | Where-Object { $_ -match '^\\\\' })
    if ($networkPaths.Count -gt 0 -and $LogonType -in @('S4U', 'Interactive')) {
        throw "LogonType '$LogonType' cannot be used for sideload UNC paths because it does not provide reusable network credentials. Configure ServiceAccount (for example a gMSA) or Password."
    }
    if ([string]::IsNullOrWhiteSpace($PrincipalUserId)) {
        throw "Register-AzLocalSideloadCopyTask: -PrincipalUserId is required for LogonType '$LogonType'."
    }
    if ($LogonType -eq 'Password' -and -not $Password) {
        throw "LogonType 'Password' requires -Password."
    }

    $robocopyTokens = @($RobocopySwitches -split '\s+' | Where-Object { $_ })
    foreach ($token in $robocopyTokens) {
        if ($token -notmatch '^/(R|W|IPG):\d+$' -and $token -notin @('/Z', '/J')) {
            throw "Unsupported robocopy switch '$token'. Sideload profiles permit /R:n, /W:n, /IPG:n, /Z, and /J only."
        }
    }
    if ($robocopyTokens -contains '/Z' -and $robocopyTokens -contains '/J') {
        throw "Robocopy switches /Z and /J cannot be combined."
    }

    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw "ScheduledTasks module is not available on this host. On-prem sideloading requires a Windows runner/agent with the ScheduledTasks module."
    }

    # $PSScriptRoot here is the module's Private folder; the worker ships under Tools\.
    $moduleRoot = Split-Path -Path $PSScriptRoot -Parent
    $worker = Join-Path -Path $moduleRoot -ChildPath 'Tools\Invoke-AzLocalSideloadCopyTask.ps1'
    if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) {
        throw "Sideload copy worker script not found at '$worker'."
    }

    $argLine = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $worker),
        '-ClusterName', ('"{0}"' -f $ClusterName),
        '-Version', ('"{0}"' -f $Version),
        '-OperationId', ('"{0}"' -f $OperationId),
        '-SourcePath', ('"{0}"' -f $SourcePath),
        '-TargetPath', ('"{0}"' -f $TargetPath),
        '-StateRoot', ('"{0}"' -f $StateRoot),
        '-RobocopySwitches', ('"{0}"' -f $RobocopySwitches),
        '-HeartbeatSeconds', $HeartbeatSeconds
    ) -join ' '

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)

    switch ($LogonType) {
        'Password' {
            $plain = [System.Net.NetworkCredential]::new('', $Password).Password
            $principal = $null  # password principal passed to Register-ScheduledTask directly
        }
        'ServiceAccount' {
            $principal = New-ScheduledTaskPrincipal -UserId $PrincipalUserId -LogonType ServiceAccount -RunLevel Highest
        }
        'Interactive' {
            $principal = New-ScheduledTaskPrincipal -UserId $PrincipalUserId -LogonType Interactive -RunLevel Highest
        }
        default {
            $principal = New-ScheduledTaskPrincipal -UserId $PrincipalUserId -LogonType S4U -RunLevel Highest
        }
    }

    if (-not $PSCmdlet.ShouldProcess($TaskName, 'Register and start sideload copy Scheduled Task')) {
        return $TaskName
    }

    # Stop and replace any pre-existing task of the same name.
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

    try {
        if ($LogonType -eq 'Password') {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings -User $PrincipalUserId -Password $plain -RunLevel Highest -Force | Out-Null
        }
        else {
            Register-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings -Principal $principal -Force | Out-Null
        }
        Start-ScheduledTask -TaskName $TaskName
    }
    finally {
        if ($LogonType -eq 'Password') { $plain = $null; Remove-Variable -Name plain -ErrorAction SilentlyContinue }
    }

    return $TaskName
}

function Remove-AzLocalSideloadCopyTask {
    <#
    .SYNOPSIS
        Unregisters a completed/failed sideload copy Scheduled Task.
    .OUTPUTS
        [void]
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)][string]$TaskName
    )

    if (-not (Get-Command Unregister-ScheduledTask -ErrorAction SilentlyContinue)) { return }
    if (-not $PSCmdlet.ShouldProcess($TaskName, 'Unregister sideload copy Scheduled Task')) { return }
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
}
