# Variables
$rg_vpn = "VPN-RG"
$rg_dc = "vm-dc-rg"
$peernamevpn = "peer-vpn-to-dc"
$peernamedc = "peer-dc-to-vpn"
$vnetvpnname = "VPN-VNET"
$vnetdcname = "vm-dc-rg-vnet"

$vnetvpn = Get-AzVirtualNetwork -Name $vnetvpnname -ResourceGroupName $rg_vpn
$vnetdc = Get-AzVirtualNetwork -Name $vnetdcname -ResourceGroupName $rg_dc

# Use this virtual network's gateway or Route Server

Add-AzVirtualNetworkPeering `
  -Name $peernamevpn `
  -VirtualNetwork $vnetvpn `
  -RemoteVirtualNetworkId $vnetdc.Id -AllowGatewayTransit:$true
  
Add-AzVirtualNetworkPeering `
  -Name $vnetdcname `
  -VirtualNetwork $vnetdc `
  -RemoteVirtualNetworkId $vnetvpn.Id -UseRemoteGateways:$true 
