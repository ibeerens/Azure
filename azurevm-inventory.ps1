<#
.SYNOPSIS
    azurevm-inventory.ps1
.VERSION
    1.0
.DESCRIPTION
    List all the VMs in a Azure subscription
.NOTES
    Author(s): Ivo Beerens 
    Blog: www.ivobeerens.nl
    Requirements:  
        AZ PowerShell module
.EXAMPLE
    PS> ./azurevm-inventory.ps1
.NOTES
    Change the outputpath variable if needed
    After running this script a seperate window will appear to select the subscription
    The output will be displayed in the console, to a gridview and saved to a csv file
#>

# Variables
$VerbosePreference = 'Continue'
$datetime = $((Get-Date).ToString('yyyy-MM-dd_hh-mm-ss'))
$outputpath = "$env:USERPROFILE\Documents\Reports\Azure\VMs"
$vms = Get-AzVM

If ( -Not (Test-Path -Path $outputPath)) {
    New-Item -ItemType directory -Path $outputPath
}
 
Set-Location $outputPath
$outputfile = "Inventory-AzureVMs-$dateTime"


# AZ PowerShell module check
Clear
$latest_azmod = Find-Module -Name Az -Repository PSGallery
$installed_azmod = Get-InstalledModule -Name Az -ErrorAction SilentlyContinue
$update = ($latest_azmod.Version -gt $installed_azmod.Version)

if (Get-Module -ListAvailable -Name az) {
    Write-Host "The AZ Module exists"
} 
else {
    Write-Host "The Module does not exist"
    Install-Module -Name Az -Force -AllowClobber -Verbose
}

if ($update -eq "True") {
    Write-Verbose "The AZ module will be upgraded"
    Update-Module Az -Force
}
else {
    Write-Verbose "No upgrade of the AZ module needed"
}

# Azure Login
Write-Verbose "Connecting to Azure Account" 
try {
    Connect-AzAccount 
    # -Tenant $tenantid -ErrorAction Stop | Out-Null
    # Connect-AzAccount -Subscription '' -Tenant ''
    Write-Verbose "Connected to Azure" 
}
catch {
    Write-Verbose "Failed to connect to Azure. Exit script" 
    Write-Verbose 
    StopIteration
    Exit 1
}

# Select Subscription
Get-AzSubscription | Out-GridView -PassThru | Select-AzSubscription

# VM Inventory
$object = @()
foreach ($vm in $vms) {
    $name = $vm.Name
    $location = $vm.Location
    # VM Statuses
    $vm_status = Get-AzVm -ResourceGroupName $vm.ResourceGroupName -name $vm.Name -Status
    $powerstate = $vm_status.Statuses[1].DisplayStatus
    $hypergeneration = $vm_status.HyperVGeneration
    $licensetype = $vm.LicenseType
    $resourcegroupname = $vm.ResourceGroupName
    $vmsize = $vm.HardwareProfile.VmSize
    # Get the type, number of Cores, Memory and OSDisksize
    $vmsizing = Get-AzVMSize -VMName $vm.Name -ResourceGroupName $vm.ResourceGroupName | where {$_.Name -eq $vmsize}
    $cores = $vmsizing.NumberOfCores
    $memory = $vmsizing.MemoryInMB
    # Disks
    $osdisk = $vm.StorageProfile.OsDisk
    $osdisk_caching = $vm.StorageProfile.OsDisk.Caching
    $datadiskcount = $vm.StorageProfile.DataDisks.count
    $disknames = $vm.StorageProfile.DataDisks.Name
    $disknames1 = $vm.StorageProfile.DataDisks
    
    if ($disknames -ne 0) {
            #Write-Host "$diskNames1"
            #$datadisk_temp = $disknames1.Name + $disknames1.DiskSizeGB #+ "GB --- " + " ; `r`n "
            #$datadisks = $datadisk_temp
            $datadisks = $disknames -join ","
        } 
    else {
            $datadisks = "No data disks attached."
            # $datadisks
        }
    
    # Boot Diagnostics
    $bootDiagnosticStatus = $vm.DiagnosticsProfile.BootDiagnostics.Enabled
    $bootDiagnosticsStorageAccount = $vm.DiagnosticsProfile.BootDiagnostics.StorageUri

    $os = $vm.StorageProfile.OsDisk.OsType
    $offer = $vm.StorageProfile.ImageReference.Offer
    $sku = $vm.StorageProfile.ImageReference.Sku
    $publisher = $vm.StorageProfile.ImageReference.Publisher
    $os_name = $vm_status.OsName
    $os_version = $vm_status.OsVersion
    # Network
    $nicname = $vm.NetworkProfile.NetworkInterfaces.Id.Split("/")[-1]
    $vmnic = Get-AzNetworkInterface -Name $nicname
    $private_ip = $vmnic.IpConfigurations.PrivateIpAddress
    $vnet = $vmnic.IpConfigurations[0].Subnet.Id.Split("/")[8]
    # Public IP
    $vmnicName = $vm.NetworkProfile.NetworkInterfaces.Id.Split("/")[8]
    $publicipAddress = Get-AzPublicIpAddress | Where-Object {$_.IpConfiguration.Id -like "*$vmNicName*"}
    $tags = ($vm.Tags | ConvertTo-json) ;
    $vmcreated = $vm.TimeCreated

    $vmObject = [PSCustomObject]@{
        "Name" = $name
        "PowerState"= $powerstate
        "Location" = $location
        "Resource Group" = $resourcegroupname
        "VMSize" = $vmsize
        "CPU_Cores" = $cores
        "MemoryMB" = $memory
        "OS" = $os
        "Offer" = $offer 
        "SKU" = $sku
        "Publisher" = $publisher
        "VM Gen" = $hypergeneration
        "Zone" = $vm.Zones
        "VM Agent Version" = $vm_status.VMAgent.VmAgentVersion
        "OS_Name" = $os_name
        "OS_Version" = $os_version
        "NIC_Name" = $nicname
        "vNet" = $vnet
        "Private_IP" = $private_ip
        "Public_IP" = $publicipAddress.IpAddress
        "OS_Disk_Name" = $osdisk.Name
        "OS_Disk_Size_GB" = $osdisk.DiskSizeGB
        "OS_Storage_Account_Type" = $osdisk.ManagedDisk.StorageAccountType
        "OS_Disk_Caching" = $osdisk_caching
        "Datadisks_Count" = $datadiskcount 
        "Datadisks" =  $datadisks
        "Admin UserName" = $vm.OSProfile.AdminUsername
        "Bootdiagnostics_Enabled" = $bootDiagnosticStatus
        "Bootdiag_StorageAccount" = $bootDiagnosticsStorageAccount
        "Tags" = $tags
        "VM Created" = $vmcreated
    }
    $object += $vmObject 
}

$object
$object | Out-GridView
$object | Export-Csv "$Outputfile.csv" -NoTypeInformation -UseCulture