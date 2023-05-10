# Azure

## Azure scripts
---
*Edgerouter.txt*
*adconnect-sync.ps1* - Performs a AD Connect delta sync
*azurevm-inventory.ps1* - This script will do a inventory of all VMs in a subscription. The following VM information is displayed: 
  - Name
  - PowerState
  - Region
  - Resource Group
  - VM Size
  - CPU Cores
  - Memory (MB)
  - Operating System
  - Offer
  - SKU
  - Publisher
  - VM Generation
  - Zone
  - VM Agent version
  - OS Name
  - OS Version
  - NIC Name
  - VNet
  - Private IP address
  - Public IP address
  - OS disk name
  - OS disk size (GB)
  - OS storage type
  - OS disk caching
  - Datadisks count
  - Datadisks names
  - Admin username
  - Boot diagnostics
  - Boot diagnostics storage account
  - Tags
  - The time the VM was created

The output will be displayed in the console, to a PS Gridview and saved to a CSV file

*pair-vnets.ps1* - Pair VNets
*vpm-2s2.ps1 - Create Site to Site VPN script
