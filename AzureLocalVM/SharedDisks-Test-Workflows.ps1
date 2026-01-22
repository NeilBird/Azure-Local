
# Download the module files directly from GitHub:
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/AzureLocalVM/AzureLocalVM.psm1' -OutFile .\AzureLocalVM.psm1
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/NeilBird/Azure-Local/refs/heads/main/AzureLocalVM/AzureLocalVM.psd1' -OutFile .\AzureLocalVM.psd1

# Import the module:
Import-Module .\AzureLocalVM.psd1 -Force

# /////// EDIT parameters
[guid]$SubscriptionId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
$resourceGroup = 'Resource-Group'
$clusterName = 'Cluster-01'
$keyvaultname = 'keyvault-name'
$secretname = 'vm-admin-password'
$VmAdminUsername = 'vmadmin'
# /////// END EDIT parameters

# Login to Azure, use device authentication for MFA support, in case no browser is available
Login-AzAccount -UseDeviceAuthentication

# Create a "VM-admin-password" secret in the Key Vault beforehand, containing the VM admin password
$password = Read-Host -Prompt "Enter password for VM admin user '$VmAdminUsername'" -AsSecureString

# Store the SecureString directly in Key Vault, avoiding plain text conversion.
# Check if secret already exists in the Key Vault.
$existingSecret = Get-AzKeyVaultSecret -VaultName $keyvaultname -Name $secretname -ErrorAction SilentlyContinue
if ($existingSecret) {
    Write-Host "Secret '$secretname' already exists in Key Vault '$keyvaultname'."
} else {
    Write-Host "Creating new secret '$secretname' in Key Vault '$keyvaultname'."
    Set-AzKeyVaultSecret -VaultName $keyvaultname -Name $secretname -SecretValue $password -ErrorAction Stop
}
# Remove secure string password from memory
Remove-Variable password


# Call function to get Custom Location Id for the target cluster
$customLocationId = Get-CustomLocationIdForCluster -ClusterName $clusterName -SubscriptionId $SubscriptionId.Guid -ResourceGroup $resourceGroup

# Required to allow later Key Vault secret retrieval.
Remove-Module Az.Accounts

# If you get an error about Az.Accounts version, close and re-open PowerShell window, then re-import module
Import-Module Az.Accounts -Force

# Create a logical network for the VMs
New-AzureLocalLogicalNetwork -NetworkName "lnet-dhcp-500" -SubscriptionId $SubscriptionId.Guid -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -VirtualSwitchName 'ConvergedSwitch(compute_management)' -IpAllocationMethod 'Dynamic' -vlanId "500"

# Create two Azure Local VMs in the cluster
New-AzureLocalVM -VMName "TestVM-01" -SubscriptionId $SubscriptionId.Guid -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -NicName "TestVM01-nic" -VMSize "Standard_D2s_v3" -VMImage "2022-datacenter-azure-edition-01" -AdminUsername $VmAdminUsername -KeyVaultSecretId "https://$keyvaultname.vault.azure.net/secrets/$secretname"
New-AzureLocalVM -VMName "TestVM-02" -SubscriptionId $SubscriptionId.Guid -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -NicName "TestVM02-nic" -VMSize "Standard_D2s_v3" -VMImage "2022-datacenter-azure-edition-01" -AdminUsername $VmAdminUsername -KeyVaultSecretId "https://$keyvaultname.vault.azure.net/secrets/$secretname"

# Create a new 20GB dynamic VHD Set for shared disk use
$vhdSetPath = New-HyperVVHDSet -TargetCluster $clusterName -ClusterSharedVolume "C:\ClusterStorage\UserStorage_1\VHDs" -VHDName "SQLSharedDisk01.vhds" -VHDSizeGB 20 -VHDType Dynamic

# Attach the VHD Set as a shared disk to both VMs
Add-VHDSetToAzureLocalVM -TargetCluster $clusterName -VMNames @("TestVM-01", "TestVM-02") -VHDSetPath $vhdSetPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation -1

# Verify the shared disk is attached to both VMs
Get-VM "TestVM-01" -CimSession (get-cluster).Name | Get-VMHardDiskDrive
Get-VM "TestVM-02" -CimSession (get-cluster).Name | Get-VMHardDiskDrive

# Add a new 100GB dynamic data disk using Azure control plane
Add-AzureLocalVMDataDisk -VMName "TestVM-01" -SubscriptionId $SubscriptionId.Guid -ResourceGroup $resourceGroup -DiskName "TestVM-01-datadisk01" -DiskSizeGB 100 -Dynamic -CustomLocationId $customLocationId

# Verify the new data disk is attached
Get-VM "TestVM-01" -CimSession (get-cluster).Name | Get-VMHardDiskDrive

# Delete the new Arc Data Disk
Remove-AzureLocalVMDataDisk -VMName "TestVM-01" -SubscriptionId $SubscriptionId.Guid -ResourceGroup $resourceGroup -DiskName "TestVM-01-datadisk01" -DeleteDisk

# Verify the shared data disk, added by Hyper-V has NOT been removed
Get-VM "TestVM-01" -CimSession (get-cluster).Name | Get-VMHardDiskDrive

# Stop one of Azure Local VMs
Stop-AzStackHCIVMVirtualMachine -Name "TestVM-02" -ResourceGroupName $resourceGroup -SubscriptionId $SubscriptionId.Guid 

# Verify the VM has been stopped
Get-VM "TestVM-02" -CimSession (get-cluster).Name

# Start the Azure Local VM again
Start-AzStackHCIVMVirtualMachine -Name "TestVM-02" -ResourceGroupName $resourceGroup -SubscriptionId $SubscriptionId.Guid

# Verify the VM has been started
Get-VM "TestVM-02" -CimSession (get-cluster).Name

# Delete one of the Azure Local VMs that has the shared disk attached
Remove-AzStackHCIVMVirtualMachine -VirtualMachineName "TestVM-01" -ResourceGroupName $resourceGroup -SubscriptionId $SubscriptionId.Guid -Verbose

# Verify the VM has been removed
Get-VM "TestVM-01" -CimSession (get-cluster).Name

# Verify the shared disk is still attached to the remaining VM
Get-VM "TestVM-02" -CimSession (get-cluster).Name | Get-VMHardDiskDrive

# Delete one of the Azure Local VMs
Remove-AzStackHCIVMVirtualMachine -VirtualMachineName "TestVM-01" -ResourceGroupName $resourceGroup -SubscriptionId $SubscriptionId.Guid -Verbose

# Create another Azure Local VM:
New-AzureLocalVM -VMName "TestVM-03" -SubscriptionId $SubscriptionId.Guid -ResourceGroup $resourceGroup -CustomLocationId $customLocationId -NicName "TestVM03-nic" -VMSize "Standard_D2s_v3" -VMImage "2022-datacenter-azure-edition-01" -AdminUsername "vmadmin" -KeyVaultSecretId "https://alcss15cl-hcikv.vault.azure.net/secrets/vmpassword"

# Get the VHD Set path again:
$vhdSetPath = New-HyperVVHDSet -TargetCluster $clusterName -ClusterSharedVolume "C:\ClusterStorage\UserStorage_1\VHDs" -VHDName "SQLSharedDisk01.vhds" -VHDSizeGB 20 -VHDType Dynamic

# Attach to the new VM03
Add-VHDSetToAzureLocalVM -TargetCluster $clusterName -VMNames @("TestVM-02", "TestVM-03") -VHDSetPath $vhdSetPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation -1

# Verify the shared disk is attached to both VMs
Get-VM "TestVM-02" -CimSession (get-cluster).Name | Get-VMHardDiskDrive
Get-VM "TestVM-03" -CimSession (get-cluster).Name | Get-VMHardDiskDrive

