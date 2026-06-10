function Invoke-AzLocalItsmTicketingFromArtifact {
    <#
    .SYNOPSIS
        Reads an ITSM config + the apply-updates JUnit artifact, invokes
        New-AzLocalIncident, and writes itsm-results.csv / itsm-results.xml.
        Replaces ~45 lines of inline `run:` boilerplate in both Step.6 pipelines.
    .DESCRIPTION
        v0.8.5 Step.6 thin-YAML helper. Behaviour matches the prior inline
        block byte-for-byte:
          - Short-circuits with a host-appropriate warning when the config
            file is missing.
          - Short-circuits with a host-appropriate warning when the JUnit
            input is missing.
          - Otherwise calls New-AzLocalIncident with the same parameter
            shape, AUTO-POPULATING -RunMetadata from the detected pipeline
            host:
              - GitHub      : Platform='github', RunId=GITHUB_RUN_ID,
                              RunUrl=GITHUB_SERVER_URL/GITHUB_REPOSITORY/
                              actions/runs/GITHUB_RUN_ID, Branch=GITHUB_REF.
              - AzureDevOps : Platform='azure-devops', RunId=BUILD_BUILDID,
                              RunUrl=SYSTEM_COLLECTIONURI + SYSTEM_TEAMPROJECT
                              + /_build/results?buildId=BUILD_BUILDID,
                              Branch=BUILD_SOURCEBRANCH.
              - Local       : Platform='local', RunId=hostname:pid,
                              RunUrl=empty, Branch=current branch (best effort).
          - Renders the same Format-Table summary the prior block did
            (ClusterName, Action, TicketId, Severity).
    .PARAMETER ConfigPath
        Path to the ITSM YAML config (consumed by Get-AzLocalItsmConfig).
    .PARAMETER InputArtifactPath
        Path to the JUnit XML produced by apply-updates (default per host).
    .PARAMETER ExportDirectory
        Directory where itsm-results.csv/.xml are written. Defaults to the
        InputArtifactPath's parent directory.
    .PARAMETER ExportCsvFileName
        Default 'itsm-results.csv'.
    .PARAMETER ExportJUnitFileName
        Default 'itsm-results.xml'.
    .PARAMETER DryRun
        Switch. Forwarded to New-AzLocalIncident -DryRun.
    .PARAMETER ForceCreate
        Switch. Forwarded to New-AzLocalIncident -ForceCreate.
    .PARAMETER PassThru
        Returns PSCustomObject with: Results, ExportCsvPath, ExportJUnitPath,
        ShortCircuited (one of 'ConfigMissing' / 'InputMissing' / $null).
    .NOTES
        Author  : AzLocal.UpdateManagement
        Version : 0.8.5 (Step.6 thin-YAML port)
    #>
    [CmdletBinding()]
    [OutputType([void])]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$InputArtifactPath = '',

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$ExportDirectory = '',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportCsvFileName = 'itsm-results.csv',

        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$ExportJUnitFileName = 'itsm-results.xml',

        [switch]$DryRun,

        [switch]$ForceCreate,

        [switch]$PassThru
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    $pipelineHost = Get-AzLocalPipelineHost

    # Defaults that match the prior inline block per host.
    if (-not $InputArtifactPath) {
        if ($pipelineHost -eq 'AzureDevOps' -and $env:BUILD_ARTIFACTSTAGINGDIRECTORY) {
            $InputArtifactPath = Join-Path -Path $env:BUILD_ARTIFACTSTAGINGDIRECTORY -ChildPath 'update-results.xml'
        }
        else {
            $InputArtifactPath = './artifacts/update-results.xml'
        }
    }

    if (-not $ExportDirectory) {
        $ExportDirectory = Split-Path -Path $InputArtifactPath -Parent
        if (-not $ExportDirectory) { $ExportDirectory = '.' }
    }
    if (-not (Test-Path -LiteralPath $ExportDirectory)) {
        New-Item -ItemType Directory -Path $ExportDirectory -Force | Out-Null
    }
    $exportCsvPath   = Join-Path -Path $ExportDirectory -ChildPath $ExportCsvFileName
    $exportJUnitPath = Join-Path -Path $ExportDirectory -ChildPath $ExportJUnitFileName

    # Config short-circuit.
    if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath)) {
        switch ($pipelineHost) {
            'GitHub'      { Write-Host "::warning::ITSM config not found at '$ConfigPath' - skipping ticket creation." }
            'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]ITSM config not found at '$ConfigPath' - skipping ticket creation." }
            default       { Write-Warning "ITSM config not found at '$ConfigPath' - skipping ticket creation." }
        }
        if ($PassThru) {
            return [pscustomobject]@{
                Results          = @()
                ExportCsvPath    = $exportCsvPath
                ExportJUnitPath  = $exportJUnitPath
                ShortCircuited   = 'ConfigMissing'
            }
        }
        return
    }

    $cfg = Get-AzLocalItsmConfig -Path $ConfigPath

    # JUnit short-circuit.
    if (-not (Test-Path -LiteralPath $InputArtifactPath)) {
        switch ($pipelineHost) {
            'GitHub'      { Write-Host "::warning::No update-results.xml found at '$InputArtifactPath' - skipping ticket creation." }
            'AzureDevOps' { Write-Host "##vso[task.logissue type=warning]No update-results.xml found at '$InputArtifactPath' - skipping ticket creation." }
            default       { Write-Warning "No update-results.xml found at '$InputArtifactPath' - skipping ticket creation." }
        }
        if ($PassThru) {
            return [pscustomobject]@{
                Results          = @()
                ExportCsvPath    = $exportCsvPath
                ExportJUnitPath  = $exportJUnitPath
                ShortCircuited   = 'InputMissing'
            }
        }
        return
    }

    # Build host-aware RunMetadata.
    $runMeta = switch ($pipelineHost) {
        'GitHub' {
            @{
                Platform = 'github'
                RunId    = $env:GITHUB_RUN_ID
                RunUrl   = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
                Branch   = $env:GITHUB_REF
            }
        }
        'AzureDevOps' {
            @{
                Platform = 'azure-devops'
                RunId    = $env:BUILD_BUILDID
                RunUrl   = "$($env:SYSTEM_COLLECTIONURI)$($env:SYSTEM_TEAMPROJECT)/_build/results?buildId=$($env:BUILD_BUILDID)"
                Branch   = $env:BUILD_SOURCEBRANCH
            }
        }
        default {
            $branch = ''
            try { $branch = (git rev-parse --abbrev-ref HEAD 2>$null) } catch { $branch = '' }
            @{
                Platform = 'local'
                RunId    = ("{0}:{1}" -f $env:COMPUTERNAME, $PID)
                RunUrl   = ''
                Branch   = $branch
            }
        }
    }

    $params = @{
        InputArtifactPath = $InputArtifactPath
        Config            = $cfg
        RunMetadata       = $runMeta
        DryRun            = [bool]$DryRun
        ForceCreate       = [bool]$ForceCreate
        ExportPath        = $exportCsvPath
        ExportJUnitPath   = $exportJUnitPath
    }

    $results = @(New-AzLocalIncident @params)
    $results | Format-Table ClusterName, Action, TicketId, Severity -AutoSize

    if ($PassThru) {
        return [pscustomobject]@{
            Results          = $results
            ExportCsvPath    = $exportCsvPath
            ExportJUnitPath  = $exportJUnitPath
            ShortCircuited   = $null
        }
    }
}
