function Invoke-AzLocalRemoteSolutionImport {
    <#
    .SYNOPSIS
        Imports (stages + discovers) a sideloaded solution update on an Azure Local
        cluster node over WinRM so it becomes available to the apply pipeline.

    .DESCRIPTION
        Private helper for the v0.8.7 on-prem sideloading automation. Runs the
        documented offline import sequence on the target node:

          1. Expand the CombinedSolutionBundle .zip (already robocopied into the
             import share) into the import\Solution folder.
          2. Run Add-SolutionUpdate against the import folder to register it.
          3. Poll Get-SolutionUpdate until the matching version is discovered, or
             until it reports AdditionalContentRequired (an OEM SBE package must be
             staged alongside it), or the discovery timeout elapses.

        This does NOT apply/install the update - that remains the job of the apply
        pipeline (Step.7) once UpdateSideloaded is flipped True. The function only
        confirms the media is discoverable so the gate can be opened.

        For SBE packages the operator-staged SBE content is already robocopied into
        the import share; the same Add-SolutionUpdate / Get-SolutionUpdate discovery
        applies. When a Solution reports AdditionalContentRequired and no SBE has
        been provided, the result is 'NeedsSbe' so the orchestrator can surface it.

        The remote work is isolated in a single Invoke-Command so it can be mocked
        in unit tests.

    .PARAMETER Session
        Open PSSession to the cluster node.

    .PARAMETER ImportRoot
        The import folder path AS SEEN ON THE NODE (e.g.
        C:\ClusterStorage\Infrastructure_1\Shares\SU1_Infrastructure_1\import).

    .PARAMETER MediaFileName
        For a Solution package: the .zip file name within ImportRoot to expand.
        For an SBE package: the staged SBE subfolder name within ImportRoot.

    .PARAMETER PackageType
        'Solution' or 'SBE'.

    .PARAMETER Version
        The version expected to appear in Get-SolutionUpdate.

    .PARAMETER DiscoveryTimeoutMinutes
        Max minutes to poll for discovery. Default 30.

    .PARAMETER PollSeconds
        Seconds between discovery polls. Default 30.

    .OUTPUTS
        [PSCustomObject] with:
          ImportState     'Imported' | 'NeedsSbe' | 'Discovering' | 'Failed'
          DiscoveredName  the discovered update name (when found)
          Version         echoed version
          Message         human-readable detail
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([PSCustomObject])]
    param(
        # Untyped (ValidateNotNull) so the function is unit-testable by passing a
        # session double and mocking Invoke-Command; callers pass a real PSSession.
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        $Session,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ImportRoot,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MediaFileName,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Solution', 'SBE')]
        [string]$PackageType,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Version,

        [int]$DiscoveryTimeoutMinutes = 30,
        [int]$PollSeconds = 30
    )

    if (-not $PSCmdlet.ShouldProcess($Session.ComputerName, "Import solution update '$Version'")) {
        return [PSCustomObject]@{
            ImportState    = 'Discovering'
            DiscoveredName = ''
            Version        = $Version
            Message        = 'WhatIf - import not performed.'
        }
    }

    $remote = Invoke-Command -Session $Session -ScriptBlock {
        param($ImportRoot, $MediaFileName, $PackageType, $Version, $DiscoveryTimeoutMinutes, $PollSeconds)

        $result = @{
            ImportState    = 'Failed'
            DiscoveredName = ''
            Version        = $Version
            Message        = ''
        }

        try {
            if ($PackageType -eq 'Solution') {
                $zip = Join-Path -Path $ImportRoot -ChildPath $MediaFileName
                if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) {
                    $result.Message = "Solution bundle '$zip' not found on node."
                    return $result
                }
                $solutionFolder = Join-Path -Path $ImportRoot -ChildPath 'Solution'
                if (-not (Test-Path -LiteralPath $solutionFolder)) {
                    New-Item -ItemType Directory -Path $solutionFolder -Force | Out-Null
                }
                Expand-Archive -LiteralPath $zip -DestinationPath $solutionFolder -Force
            }
            else {
                $solutionFolder = Join-Path -Path $ImportRoot -ChildPath $MediaFileName
                if (-not (Test-Path -LiteralPath $solutionFolder)) {
                    $result.Message = "SBE source folder '$solutionFolder' not found on node."
                    return $result
                }
            }

            if (-not (Get-Command Add-SolutionUpdate -ErrorAction SilentlyContinue)) {
                $result.Message = 'Add-SolutionUpdate is not available on the node (Azure Local update cmdlets missing).'
                return $result
            }

            Add-SolutionUpdate -SolutionUpdateContentFolderPath $solutionFolder -ErrorAction Stop

            $deadline = (Get-Date).AddMinutes($DiscoveryTimeoutMinutes)
            do {
                Start-Sleep -Seconds $PollSeconds
                $updates = @(Get-SolutionUpdate -ErrorAction SilentlyContinue)
                $match = $updates | Where-Object {
                    ($_.Version -eq $Version) -or ($_.DisplayName -like "*$Version*") -or ($_.Name -like "*$Version*")
                } | Select-Object -First 1

                if ($null -ne $match) {
                    $state = [string]$match.State
                    if ($state -match 'AdditionalContentRequired') {
                        $result.ImportState = 'NeedsSbe'
                        $result.DiscoveredName = [string]$match.Name
                        $result.Message = "Discovered '$($match.Name)' but it reports AdditionalContentRequired (OEM SBE needed)."
                        return $result
                    }
                    $result.ImportState = 'Imported'
                    $result.DiscoveredName = [string]$match.Name
                    $result.Message = "Discovered '$($match.Name)' (State=$state)."
                    return $result
                }
            } while ((Get-Date) -lt $deadline)

            $result.ImportState = 'Discovering'
            $result.Message = "Discovery still in progress after $DiscoveryTimeoutMinutes minute(s); will re-check on next run."
            return $result
        }
        catch {
            $result.ImportState = 'Failed'
            $result.Message = "Import failed on node: $($_.Exception.Message)"
            return $result
        }
    } -ArgumentList $ImportRoot, $MediaFileName, $PackageType, $Version, $DiscoveryTimeoutMinutes, $PollSeconds

    return [PSCustomObject]@{
        ImportState    = [string]$remote.ImportState
        DiscoveredName = [string]$remote.DiscoveredName
        Version        = [string]$remote.Version
        Message        = [string]$remote.Message
    }
}
