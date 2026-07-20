Set-StrictMode -Version Latest

function Get-VMCollectionStateToken {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][string]$OwnerNode
    )

    $vmState = Get-VM -Name $VMName -ErrorAction Stop
    $diskPaths = @(Get-VMHardDiskDrive -VM $vmState -ErrorAction Stop | ForEach-Object { [string]$_.Path } | Where-Object { $_ } | Sort-Object -Unique)
    $checkpointCount = @(Get-VMSnapshot -VM $vmState -ErrorAction Stop).Count
    $configPath = Join-Path $vmState.ConfigurationLocation ("Virtual Machines\{0}.vmcx" -f $vmState.VMId)
    $configItem = Get-Item -LiteralPath $configPath -ErrorAction SilentlyContinue
    [pscustomobject]@{
        OwnerNode = $OwnerNode
        State = [string]$vmState.State
        CheckpointCount = [int]$checkpointCount
        DiskPaths = @($diskPaths)
        ConfigLastWriteUtc = if ($configItem) { $configItem.LastWriteTimeUtc.ToString('o') } else { '' }
    }
}

Export-ModuleMember -Function Get-VMCollectionStateToken
