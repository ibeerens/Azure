# Create a Azure Site to Site VPN gateway
# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-create-site-to-site-rm-powershell#modify
#
# Install the Az PowerShell module
# https://docs.microsoft.com/en-us/powershell/azure/install-az-ps?view=azps-6.6.0
# Install-Module -Name Az -AllowClobber -Scope CurrentUser

# Variables
$rg_vpn = "VPN-RG"
$vnetname = "VPN-VNET"
$location = "WestEurope"
$addressspacehub = "10.2.0.0/16"
$subnetname = "Frontend"
$subnet = "10.2.0.0/24"
$gatewaysubnet = "10.2.255.0/27"
$public_ip_onprem = "31.151.12.226"
$allowd_onprem_networks1 = "192.168.249.0/24"
$allowd_onprem_networks2 = "192.168.13.0/24"
$gatewayname = "VPN-GW"
$vpntype = "RouteBased"
# https://docs.microsoft.com/en-us/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings#gwsku
$sku = "VpnGw1"
$gatewayType = "Vpn"
$connectionname = "VPNVNetToOnPrem"
$vpnpip_azure = "VPN-AZURE-PIP"
$vpnconnection = "VPN-IPSEC-S2S"
$sharedkey = "!ThisisASecret!"

# Connect to Azure
Connect-AzAccount

# Create Azure Resource Group
Write-Host "Create a Resource Group called $rg_vpn" -ForegroundColor Green
New-AzResourceGroup -Name $rg_vpn -Location $Location

# Create networks
$subnet1 = New-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -AddressPrefix $gatewaysubnet
$subnet2 = New-AzVirtualNetworkSubnetConfig -Name $subnetname -AddressPrefix $subnet

# Create VNet
$vnet = New-AzVirtualNetwork -Name $vnetname -ResourceGroupName $rg_vpn `
-Location $location -AddressPrefix $addressspacehub -Subnet $subnet1,$subnet2
$vnet | Set-AzVirtualNetwork

# Create a local network gateway
New-AzLocalNetworkGateway -Name $connectionname -ResourceGroupName $rg_vpn `
-Location $location -GatewayIpAddress $public_ip_onprem -AddressPrefix $allowd_onprem_networks1,$allowd_onprem_networks2

# Request a public IP Address
$gwpip= New-AzPublicIpAddress -Name $vpnpip_azure -ResourceGroupName $rg_vpn -Location $location -AllocationMethod Dynamic

# Create Gatway IP addressing
$vnet = Get-AzVirtualNetwork -Name $vnetname -ResourceGroupName $rg_vpn
$subnet = Get-AzVirtualNetworkSubnetConfig -Name 'GatewaySubnet' -VirtualNetwork $vnet
$gwipconfig = New-AzVirtualNetworkGatewayIpConfig -Name gwipconfig1 -SubnetId $subnet.Id -PublicIpAddressId $gwpip.Id

# Create a Site to Site VPN gateway
Write-Host "Creating the VPN gateway. This can take up to 45 minutes!" -ForegroundColor Green
New-AzVirtualNetworkGateway -Name $gatewayname -ResourceGroupName $rg_vpn `
-Location $location -IpConfigurations $gwipconfig -GatewayType $gatewayType `
-VpnType $vpntype -GatewaySku $sku

# Configure the VPN Connection configuration
$gateway1 = Get-AzVirtualNetworkGateway -Name $gatewayname -ResourceGroupName $rg_vpn
$local = Get-AzLocalNetworkGateway -Name $connectionname -ResourceGroupName $rg_vpn

New-AzVirtualNetworkGatewayConnection -Name $vpnconnection -ResourceGroupName $rg_vpn `
-Location $location -VirtualNetworkGateway1 $gateway1 -LocalNetworkGateway2 $local `
-ConnectionType IPsec -RoutingWeight 10 -SharedKey $sharedkey

# Verify the VPN connection
Get-AzVirtualNetworkGatewayConnection -Name $vpnconnection -ResourceGroupName $rg_vpn

# View VPN config
Get-AzVirtualNetworkGateway -Name $gatewayname -ResourceGroup $rg_vpn

# Get Public IP adress
$pubip = Get-AzPublicIpAddress -Name $vpnpip_azure -ResourceGroupName $rg_vpn
$pubip.IpAddress
