# Copilot Instructions for Azure-Local

## Project Overview

This repository contains PowerShell automation tools for deploying and managing Azure Local (Azure Stack HCI) clusters. The primary modules are **AzLocal.DeploymentAutomation** and **AzLocal.UpdateManagement**, which provide ARM template-based deployment automation and fleet update management capabilities, respectively. Additional tools include VM management and Active Directory permissions analysis.

## Repository Structure

- `AzLocal.DeploymentAutomation/` — Primary module for ARM template-based cluster deployments
  - `Public/` — Exported functions (4)
  - `Private/` — Internal helper functions
  - `Tests/` — Pester test suite
  - `template-parameter-files/` — ARM template parameter templates
  - `templates/` — ARM templates
  - `.config/` — Naming standards configuration
- `AzLocal.UpdateManagement/` — Fleet update management module
- `AzureLocalVM/` — Hyper-V VM creation/management module
- `ad-effective-permissions/` — Active Directory permissions analysis
- `Test-ClusterPendingRestart/` — Cluster restart pre-flight checks

## PowerShell Coding Conventions

### Function Design
- **Naming**: Strict `Verb-AzLocal<Noun>` pattern for all functions
- **CmdletBinding**: Required on all exported functions
- **OutputType**: `[OutputType()]` declarations required on all functions
- **SupportsShouldProcess**: Required on functions that modify state (`-WhatIf`, `-Confirm`)
- **Parameter Validation**: Use `ValidateSet`, `ValidateRange`, `ValidatePattern` attributes
- **Strict Mode**: `Set-StrictMode -Version Latest` is enforced at module scope

### Error Handling
- Use `throw` for errors — never `Return "Error"` or similar string-based patterns
- Clear credential/secret variables in `finally` blocks
- Use `Join-Path` for all path construction (not string concatenation)

### Logging
- Use `Write-AzLocalLog` for all console output (provides timestamps, severity, color)
- Severity levels: Info, Warning, Error, Success, Debug, Verbose

### Comment Style
```powershell
########################################
<#
.SYNOPSIS
    Brief description
.DESCRIPTION
    Detailed description
.NOTES
    Author, Version, Created, Updated
#>
########################################
```

## File Encoding

- All `.ps1` files must use **ASCII-compatible encoding** (no em-dashes, smart quotes, or non-ASCII characters)
- Use standard hyphens (`-`), straight quotes (`'` `"`), and angle brackets (`<` `>`) only
- This prevents encoding corruption when files are consumed across different systems

## Testing

- Framework: **Pester**
- Tests located in each module's `Tests/` folder
- Test invocation: `.\Tests\Invoke-Tests.ps1` from the module directory

### AzLocal.UpdateManagement release pull requests

- Never create an `AzLocal.UpdateManagement` release PR directly with `gh pr create` or another GitHub client.
- Commit and push the complete release candidate first, then use `AzLocal.UpdateManagement\Tools\New-AzLocalReleasePullRequest.ps1`.
- The wrapper must complete the hermetic suite and all live-Azure shards with zero live failures, skips, or inconclusive tests before PR creation.
- Do not bypass, mock, suppress, or reorder the pre-PR gate. See `AzLocal.UpdateManagement\docs\RELEASE-PROCESS.md`.

### CRITICAL: Running Pester tests from Copilot/AI terminals
- Pester output (ANSI colors, verbose test results) overwhelms VS Code's terminal renderer
- This has caused repeated VS Code "window not responding" crashes
- **NEVER** run Pester tests with output going to the terminal — always redirect all output to a file
- Safe pattern (background terminal with output redirected to file):
  ```powershell
  Push-Location "c:\Users\nebird\Repos\Azure-Local\AzLocal.DeploymentAutomation"
  .\Tests\Invoke-Tests.ps1 *> "$env:TEMP\pester-results.txt"
  ```
- Then read the results from the file:
  ```powershell
  Select-String -Path "$env:TEMP\pester-results.txt" -Pattern 'Tests Passed|Failed:' | Select-Object -Last 5
  ```
- **Important**: Run in a clean terminal where the module has not already been imported, or remove it first:
  ```powershell
  Get-Module AzLocal.DeploymentAutomation -All | Remove-Module -Force -ErrorAction SilentlyContinue
  ```
- This applies to `Invoke-Pester`, `Invoke-Tests.ps1`, and any script that runs Pester underneath

## Dependencies

- PowerShell 5.1+
- `Az.Accounts` (v2.0.0+)
- `Az.Resources` (v6.0.0+)
- `Az.KeyVault` (v4.0.0+ — optional, checked at runtime)
