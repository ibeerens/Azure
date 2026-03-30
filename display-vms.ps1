# Requires Azure PowerShell Az Module
# Connect to Azure (will prompt for login)
Connect-AzAccount

# Get all VMs in all subscriptions
$subscriptions = Get-AzSubscription
$vmList = @()
foreach ($sub in $subscriptions) {
    Set-AzContext -SubscriptionId $sub.Id
    $vms = Get-AzVM -Status
    foreach ($vm in $vms) {
        # Get private IPs
        $privateIps = @()
        foreach ($nicId in $vm.NetworkProfile.NetworkInterfaces.Id) {
            $nicName = ($nicId -split '/')[8]
            $nicRg = ($nicId -split '/')[4]
            try {
                $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $nicRg -ErrorAction Stop
                $privateIps += $nic.IpConfigurations.PrivateIpAddress
            } catch {
                Write-Warning "Failed to get NIC $nicName in $nicRg : $_"
            }
        }

        # Get disk info
        $osDiskName = $vm.StorageProfile.OsDisk.Name
        $osDiskSize = $vm.StorageProfile.OsDisk.DiskSizeGB
        $osDiskType = if ($vm.StorageProfile.OsDisk.ManagedDisk) { $vm.StorageProfile.OsDisk.ManagedDisk.StorageAccountType } else { 'Unmanaged' }
        $dataDisks = $vm.StorageProfile.DataDisks
        $dataDiskCount = $dataDisks.Count
        $dataDiskNames = ($dataDisks | Select-Object -ExpandProperty Name) -join ', '
        $dataDiskSizes = ($dataDisks | Select-Object -ExpandProperty DiskSizeGB) -join ', '
        $dataDiskTypes = ($dataDisks | Select-Object @{Name='Type'; Expression={if ($_.ManagedDisk) { $_.ManagedDisk.StorageAccountType } else { 'Unmanaged' }}} | Select-Object -ExpandProperty Type) -join ', '

        # Create object
        $vmObj = [PSCustomObject]@{
            VMName = $vm.Name
            SubscriptionName = $sub.Name
            PowerState = $vm.PowerState
            Location = $vm.Location
            VMSize = $vm.HardwareProfile.VmSize
            PrivateIPs = ($privateIps -join ', ')
            OSDisk = $osDiskName
            OSDiskSize = $osDiskSize
            OSDiskType = $osDiskType
            DataDisksCount = $dataDiskCount
            DataDiskNames = $dataDiskNames
            DataDiskSizes = $dataDiskSizes
            DataDiskTypes = $dataDiskTypes
            Date = Get-Date -Format 'yyyy-MM-dd'
        }
        $vmList += $vmObj
    }
}

# Display on console
$vmList | Format-Table -AutoSize

# Export to CSV
$csvPath = "all-vms-$(Get-Date -Format 'yyyyMMdd').csv"
$vmList | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "Exported to $csvPath"

# Export to Markdown
$mdPath = "all-vms-$(Get-Date -Format 'yyyyMMdd').md"
if ($vmList.Count -gt 0) {
    $headers = $vmList[0].PSObject.Properties.Name
    $mdContent = "| " + ($headers -join " | ") + " |`n"
    $mdContent += "| " + (("--- |") * $headers.Count) + "`n"
    foreach ($vm in $vmList) {
        $row = "| " + (($headers | ForEach-Object { $vm.$_ }) -join " | ") + " |`n"
        $mdContent += $row
    }
} else {
    $mdContent = "# No VMs found`n"
}
$mdContent | Out-File -FilePath $mdPath -Encoding UTF8
Write-Host "Exported to $mdPath"