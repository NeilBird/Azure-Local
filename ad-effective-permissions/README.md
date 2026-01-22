# Active Directory Effective Permissions Module

This folder contains a PowerShell module for analyzing effective permissions on Active Directory objects, with advanced support for user-specific, computer-specific, and group-specific permission analysis.

## Overview

The `Get-ADEffectiveAccess` module provides comprehensive functionality to:

- Retrieve all permissions for any Active Directory object
- Calculate effective permissions for a specific user, computer, or group including permissions inherited through group memberships
- Analyze permission inheritance through nested group structures
- Check for specific required permissions (BitLocker recovery, computer object management, cluster CNO permissions)
- Handle computer object names with automatic $ suffix resolution

## Installation

### Option 1: Import from Local Path

```powershell
# Navigate to the module directory
cd "C:\path\to\Azure-Local\ad-effective-permissions"

# Import the module
Import-Module .\Get-ADEffectiveAccess.psd1
```

### Option 2: Copy to PowerShell Module Path

```powershell
# Find your PowerShell module path
$env:PSModulePath -split ';'

# Copy the module files to one of the module paths
# Example: Copy to user modules directory
$userModulePath = "$env:USERPROFILE\Documents\PowerShell\Modules\Get-ADEffectiveAccess"
New-Item -Path $userModulePath -ItemType Directory -Force
Copy-Item ".\Get-ADEffectiveAccess.psm1" -Destination $userModulePath
Copy-Item ".\Get-ADEffectiveAccess.psd1" -Destination $userModulePath

# Import the module
Import-Module Get-ADEffectiveAccess
```

## Prerequisites

### Required PowerShell Module

This script requires the **Active Directory PowerShell module** to be installed and imported.

To install the module:

#### On Windows Server

```powershell
# Install RSAT-AD-PowerShell feature
Install-WindowsFeature RSAT-AD-PowerShell
```

#### On Windows 10/11

```powershell
# Install RSAT tools
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

#### Alternative: Install from PowerShell Gallery

```powershell
# Install the ActiveDirectory module from PowerShell Gallery
Install-Module -Name ActiveDirectory -Force -AllowClobber
```

### Required Permissions

- **Read permissions** on Active Directory objects you want to analyze
- **Access to security descriptors** (typically requires Domain Admin or delegated permissions)
- **Network connectivity** to domain controllers

## Module Files

### Get-ADEffectiveAccess.psm1

Main module file containing the `Get-ADEffectiveAccess` function and supporting helper functions.

### Get-ADEffectiveAccess.psd1

Module manifest file defining module metadata, dependencies, and exported functions.

## Functions

### Get-ADEffectiveAccess

Primary function that operates in four modes:

1. **All Permissions Mode (Default)**: Returns all ACEs for an AD object
2. **User SID Mode**: Calculates effective permissions for a specific user SID
3. **Computer SID Mode**: Calculates effective permissions for a specific computer SID
4. **Object Name Mode**: Calculates effective permissions for any AD object by name (auto-detects object type)

#### Parameters

- `ADObject` (Mandatory): Distinguished Name of the AD object to analyze (alias: DistinguishedName)
- `UserSID` (Optional): Security Identifier of user for effective permissions calculation
- `ComputerSID` (Optional): Security Identifier of computer for effective permissions calculation
- `ObjectName` (Optional): SAMAccountName or DN of any AD object (user, computer, or group). Can also be used with aliases: UserName, ComputerName, GroupName. Accepts both SAM account names and full Distinguished Names
- `Server` (Optional): Specific domain controller to query

##### Performance Optimization Parameters

- `MaxGroupDepth` (Optional): Maximum recursion depth for nested group resolution (1-100, default: 50)
- `GroupBatchSize` (Optional): Number of groups to process in a batch for AD queries (10-1000, default: 100)
- `TimeoutSeconds` (Optional): Maximum execution time in seconds to prevent runaway operations (30-3600, default: 300)

#### Key Features

- **Comprehensive Group Resolution**: Uses `tokenGroups` for complete group membership including domain local groups from trusted domains
- **Nested Group Support**: Recursively resolves all group memberships including nested groups
- **Computer Name Flexibility**: Handles computer names with or without the trailing $ character automatically
- **Automatic Object Type Detection**: Identifies whether an object is a user, computer, or group automatically
- **Permission Precedence**: Properly handles Deny vs Allow permission precedence
- **Source Attribution**: Shows whether permissions come from direct assignment or group membership
- **GUID Resolution**: Automatically resolves schema and extended rights GUIDs to human-readable names
- **Multi-SID Support**: Supports direct SID input for users and computers when you already have the SID
- **Performance Optimizations**: Optimized for large AD environments with extensive group hierarchies
  - Configurable recursion depth limits to prevent stack overflow
  - Batch processing for efficient AD queries
  - Timeout protection for long-running operations
  - Memory-efficient collections (.NET HashSet, Dictionary, List)
  - O(1) SID lookups instead of array contains operations
  - Progress reporting for large operations

### Helper Functions

#### Resolve-ADObjectNameToSID

Converts any AD object name (user, computer, or group) to a Security Identifier (SID) with automatic object type detection. Handles computer names with or without the $ suffix.

#### Resolve-UserNameToSID

Converts a user SAMAccountName to a Security Identifier (SID).

#### Resolve-ComputerNameToSID

Converts a computer SAMAccountName to a Security Identifier (SID).

#### Get-ADObjectGroupMemberships

Recursively retrieves all group memberships for a user or computer, including nested groups.

#### Get-UserEffectivePermissions

Core function that calculates effective permissions by analyzing user and group ACEs.

#### Test-LCMUserRequiredPermissions

Checks for specific required permissions including:

- CreateChild/DeleteChild on computer objects
- ReadProperty on all objects
- GenericAll on BitLocker recovery information objects

#### Test-ClusterCNORequiredPermissions

Checks for specific required permissions for Cluster Computer Name Object (CNO) including:

- CreateChild on computer objects with "This object and all descendant objects" inheritance
- ReadProperty on all objects with "This object and all descendant objects" inheritance

## Usage Examples

### Basic Permission Analysis

```powershell
# Import the module
Import-Module .\Get-ADEffectiveAccess.psd1

# Get all permissions for a user object
Get-ADEffectiveAccess -ADObject "CN=TestUser,CN=Users,DC=contoso,DC=com"

# Get all permissions for an OU
Get-ADEffectiveAccess -ADObject "OU=TestOU,DC=contoso,DC=com"
```

### Object-Specific Effective Permissions

```powershell
# Calculate effective permissions by user SID
Get-ADEffectiveAccess -ADObject "CN=TestOU,OU=TestOUs,DC=contoso,DC=com" -UserSID "S-1-5-21-1234567890-1234567890-1234567890-1001"

# Calculate effective permissions by computer SID
Get-ADEffectiveAccess -ADObject "CN=TestOU,OU=TestOUs,DC=contoso,DC=com" -ComputerSID "S-1-5-21-1234567890-1234567890-1234567890-1002"

# Calculate effective permissions by object name (auto-detects type)
Get-ADEffectiveAccess -ADObject "CN=TestOU,OU=TestOUs,DC=contoso,DC=com" -ObjectName "jdoe"          # User
Get-ADEffectiveAccess -ADObject "CN=TestOU,OU=TestOUs,DC=contoso,DC=com" -ObjectName "SERVER01"      # Computer (with or without $)
Get-ADEffectiveAccess -ADObject "CN=TestOU,OU=TestOUs,DC=contoso,DC=com" -ObjectName "SERVER01$"     # Computer
Get-ADEffectiveAccess -ADObject "CN=TestOU,OU=TestOUs,DC=contoso,DC=com" -ObjectName "Domain Admins" # Group

# Use specific domain controller
Get-ADEffectiveAccess -ADObject "CN=TestComputer,CN=Computers,DC=contoso,DC=com" -ObjectName "jsmith" -Server "dc01.contoso.com"
```

### Validate Azure Local permissions for OU

Example commands to download the module, import it and confirm that an Azure Local OU has required permissions delegated for the LifeCycle Manager (LCM) user (deployment user) account:

```PowerShell
# Download the module files
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/ad-effective-permissions/Get-ADEffectiveAccess.psm1' -OutFile .\Get-ADEffectiveAccess.psm1
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/ad-effective-permissions/Get-ADEffectiveAccess.psd1' -OutFile .\Get-ADEffectiveAccess.psd1

# Import the module
Import-Module .\Get-ADEffectiveAccess.psd1 -Force

$OU = "CN=AzureLocalOU,DC=contoso,DC=com"
$LCMUser = "LCM-UserName"

$LCMUserPermissions = Get-ADEffectiveAccess -ADObject $OU -UserName $LCMUser -Verbose

Test-LCMUserRequiredPermissions $LCMUserPermissions


CreateDeleteComputerObjects ReadPropertyAllObjects ms-FVE-RecoveryInformation AllRequiredPermissionsPresent
--------------------------- ---------------------- -------------------------- -----------------------------
                       True                   True                       True                          True

# Check Cluster CNO permissions
# Post-cluster deployment only, such as for troubleshooting cluster validation report failures for AD Organizational Unit permissions.
$OU = "CN=AzureLocalOU,DC=contoso,DC=com"
$ClusterCNO = "cluster01-cl"
$ClusterPermissions = Get-ADEffectiveAccess -ADObject $OU -ComputerName $ClusterCNO -Verbose

Test-ClusterCNORequiredPermissions $ClusterPermissions


CreateComputerObjects ReadAllProperties AllRequiredPermissionsPresent
--------------------- ----------------- -----------------------------
                 True              True                          True
```

### Performance Optimization for Large Environments

```powershell
# For very large AD environments with deep group nesting
Get-ADEffectiveAccess -ADObject "CN=TestOU,DC=contoso,DC=com" -ObjectName "serviceaccount" -MaxGroupDepth 25 -GroupBatchSize 200 -TimeoutSeconds 600 -Verbose

# For environments with known shallow group structures (faster processing)
Get-ADEffectiveAccess -ADObject "CN=TestOU,DC=contoso,DC=com" -ObjectName "user123" -MaxGroupDepth 10 -GroupBatchSize 50 -TimeoutSeconds 120

# Conservative settings for very complex environments to prevent timeouts
Get-ADEffectiveAccess -ADObject "CN=TestOU,DC=contoso,DC=com" -ObjectName "admin" -MaxGroupDepth 15 -GroupBatchSize 25 -TimeoutSeconds 900
```

### Advanced Analysis

```powershell
# Get effective permissions with verbose output for troubleshooting
Get-ADEffectiveAccess -ADObject "CN=TestOU,OU=TestOUs,DC=contoso,DC=com" -ObjectName "serviceaccount" -Verbose

# Check permissions for multiple objects
$objects = @(
    "CN=Computer1,CN=Computers,DC=contoso,DC=com",
    "CN=Computer2,CN=Computers,DC=contoso,DC=com"
)
$objects | ForEach-Object { Get-ADEffectiveAccess -ADObject $_ -ObjectName "admin" }

# Compare different ways to specify the same computer
Get-ADEffectiveAccess -ADObject "CN=TestOU,DC=contoso,DC=com" -ObjectName "SERVER01"      # Auto-detects computer
Get-ADEffectiveAccess -ADObject "CN=TestOU,DC=contoso,DC=com" -ObjectName "SERVER01$"     # Explicit computer name
Get-ADEffectiveAccess -ADObject "CN=TestOU,DC=contoso,DC=com" -ComputerSID "S-1-5-21-..." # Direct SID
```

## Output Properties

### Standard Mode Output

- `DistinguishedName`: Full DN of the AD object
- `Name`: Name of the AD object
- `ObjectClass`: Class of the AD object
- `ObjectGUID`: Unique identifier
- `IdentitySID`: SID of the identity with permissions
- `IdentityReference`: Name of the identity
- `AccessControlType`: Allow or Deny
- `ActiveDirectoryRights`: Specific permissions
- `ObjectType`: Human-readable object type
- `InheritanceType`: How permissions are inherited

### Effective Permissions Mode Output

- `UserSID`: SID of the user/computer/group being analyzed
- `EffectiveRights`: Calculated effective permissions
- `PermissionSources`: Shows whether permissions come from direct assignment or group membership
- `RequiredPermissionCheck`: Results of BitLocker/computer object permission analysis

## Notes

- When using UserSID, ComputerSID, or ObjectName parameters, the function analyzes both direct permissions and all permissions inherited through group memberships
- Permission precedence follows Active Directory rules where Deny takes precedence over Allow
- Computer names can be specified with or without the trailing $ character - the module handles both automatically
- The ObjectName parameter automatically detects object types (user, computer, group) for flexible usage
- The script uses `tokenGroups` for comprehensive group membership resolution including domain local groups from trusted domains
- GUID maps are automatically built for schema and extended rights resolution
- Verbose mode provides detailed troubleshooting information about group resolution and permission calculation

## Troubleshooting

### Common Issues

1. **"Access Denied" errors**: Ensure you have sufficient permissions to read security descriptors
2. **Module not found**: Install the Active Directory PowerShell module
3. **User not found**: Verify the username/SID exists and is accessible
4. **Slow performance**: Consider using the `-Server` parameter to specify a closer domain controller

### Performance Tips

- Use the `-Server` parameter to specify a nearby domain controller
- When analyzing multiple objects for the same user, the GUID map is cached for better performance
- For large AD environments with deep group nesting:
  - Reduce `MaxGroupDepth` to limit recursion (default: 50, recommended for complex environments: 15-25)
  - Increase `GroupBatchSize` for fewer AD queries (default: 100, recommended for large environments: 200-500)
  - Increase `TimeoutSeconds` for complex operations (default: 300, recommended for large environments: 600-900)
- Verbose mode helps identify bottlenecks in group resolution
- Monitor memory usage in very large environments - the module uses efficient .NET collections but large result sets still consume memory
- Consider running during off-peak hours for large-scale permission analysis

## License

This script is licensed under the MIT License. See the script header for full license text.
