param(
    [string]$SubscriptionId,
    [string]$Fslogix,
    [string]$FslogixResourceGroup,
    [string]$FileStorageAccount,
    [string]$FileStorageResourceGroup,
    [string]$OutputMarkdownPath = ".\Get-AvdHostPools.md"
)

if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az.Accounts module is required. Install it with 'Install-Module Az.Accounts -Scope CurrentUser'."
    return
}

try {
    if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
        Connect-AzAccount -ErrorAction Stop | Out-Null
    }
}
catch {
    Write-Error "Failed to authenticate to Azure: $($_.Exception.Message)"
    return
}

if (-not $SubscriptionId) {
    $SubscriptionId = (Get-AzContext).Subscription.Id
}

if (-not $SubscriptionId) {
    Write-Error "No subscription ID available. Set -SubscriptionId or configure the current context."
    return
}

$apiVersion = "2024-04-03"

try {
    # Use Az's built-in REST helper so token handling is automatic
    $restResponse = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/hostPools?api-version=$apiVersion"
}
catch {
    Write-Error "Failed to query AVD host pools via Invoke-AzRestMethod: $($_.Exception.Message)"
    return
}

if (-not $restResponse.Content) {
    Write-Output "No response content returned for subscription '$SubscriptionId'."
    return
}

$responseObject = $restResponse.Content | ConvertFrom-Json

if (-not $responseObject.value) {
    Write-Output "No AVD host pools found in subscription '$SubscriptionId'."
    return
}

# Fetch scaling plans to check if enabled per host pool
$scalingPlanInfo = @{}
try {
    $spResponse = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$SubscriptionId/providers/Microsoft.DesktopVirtualization/scalingPlans?api-version=$apiVersion"
    if ($spResponse.Content) {
        $spObject = $spResponse.Content | ConvertFrom-Json
        if ($spObject.value) {
            foreach ($sp in $spObject.value) {
                $refs = $sp.properties.hostPoolReferences
                if ($refs) {
                    foreach ($ref in $refs) {
                        $scalingPlanInfo[$ref.hostPoolArmPath] = @{
                            ScalingPlanEnabled = $ref.scalingPlanEnabled
                            ScalingPlanName    = $sp.name
                        }
                    }
                }
            }
        }
    }
}
catch {
    Write-Warning "Failed to query scaling plans: $($_.Exception.Message)"
}

$sessionHostRows = @()
$sessionHostCounts = @{}

foreach ($hp in $responseObject.value) {
    $rgName = ($hp.id -split '/')[4]
    $hpName = $hp.name

    $sessionHostsPath = "/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.DesktopVirtualization/hostPools/$hpName/sessionHosts?api-version=$apiVersion"

    try {
        $shResponse = Invoke-AzRestMethod -Method GET -Path $sessionHostsPath
    }
    catch {
        Write-Warning "Failed to query session hosts for host pool '$hpName' in resource group '$rgName': $($_.Exception.Message)"
        $sessionHostCounts[$hpName] = 0
        continue
    }

    if (-not $shResponse.Content) {
        Write-Host ""
        Write-Host "Host pool: $hpName (RG: $rgName) - no session hosts response content." -ForegroundColor Yellow
        $sessionHostCounts[$hpName] = 0
        continue
    }

    $shObject = $shResponse.Content | ConvertFrom-Json

    if (-not $shObject.value) {
        Write-Host ""
        Write-Host "Host pool: $hpName (RG: $rgName) - no session hosts found." -ForegroundColor Yellow
        $sessionHostCounts[$hpName] = 0
        continue
    }

    $sessionHostCounts[$hpName] = $shObject.value.Count

    $sessionHostsForPool = $shObject.value |
        Select-Object `
            @{Name = 'HostPool'; Expression = { $hpName }},
            @{Name = 'ResourceGroup'; Expression = { $rgName }},
            @{Name = 'SessionHost'; Expression = { $_.name }},
            @{Name = 'ResourceId'; Expression = { $_.properties.resourceId }},
            @{Name = 'AgentVersion'; Expression = { $_.properties.agentVersion }},
            @{Name = 'Status'; Expression = { $_.properties.status }},
            @{Name = 'Sessions'; Expression = { $_.properties.sessions }},
            @{Name = 'LastHeartbeat'; Expression = { $_.properties.lastHeartBeat }},
            @{Name = 'AllowNewSession'; Expression = { $_.properties.allowNewSession }}

    $sessionHostRows += $sessionHostsForPool
}

# Enrich session hosts with VM private IP address
$computeApiVersion = "2024-07-01"
$networkApiVersion = "2024-05-01"
foreach ($row in $sessionHostRows) {
    $ip = $null
    if ($row.ResourceId) {
        try {
            $vmPath = "$($row.ResourceId)?api-version=$computeApiVersion"
            $vmResp = Invoke-AzRestMethod -Method GET -Path $vmPath
            if ($vmResp.Content) {
                $vm = $vmResp.Content | ConvertFrom-Json
                $nicId = $vm.properties.networkProfile.networkInterfaces[0].id
                if ($nicId) {
                    $nicPath = "$nicId`?api-version=$networkApiVersion"
                    $nicResp = Invoke-AzRestMethod -Method GET -Path $nicPath
                    if ($nicResp.Content) {
                        $nic = $nicResp.Content | ConvertFrom-Json
                        $ip = $nic.properties.ipConfigurations[0].properties.privateIPAddress
                    }
                }
            }
        }
        catch {
            $ip = "N/A"
        }
    }
    if ($null -eq $ip) { $ip = "N/A" }
    $row | Add-Member -NotePropertyName 'PrivateIP' -NotePropertyValue $ip -Force
}

# Per host pool: available session hosts, shutdown/unavailable, users connected (sum of sessions)
$hostPoolSummaryRows = foreach ($hp in $responseObject.value) {
    $hpName = $hp.name
    $rgName = ($hp.id -split '/')[4]
    $rows = @($sessionHostRows | Where-Object { $_.HostPool -eq $hpName })
    $available = 0
    $shutdownOrUnavailable = 0
    $usersConnected = 0
    foreach ($row in $rows) {
        $st = [string]$row.Status
        if ($st -eq 'Available') {
            $available++
        }
        elseif ($st -in @('Shutdown', 'Unavailable')) {
            $shutdownOrUnavailable++
        }
        $sess = $row.Sessions
        if ($null -ne $sess) {
            $usersConnected += [long]$sess
        }
    }
    [PSCustomObject]@{
        HostPool                           = $hpName
        ResourceGroup                      = $rgName
        SessionHostsAvailable              = $available
        SessionHostsShutdownOrUnavailable  = $shutdownOrUnavailable
        UsersConnected                     = $usersConnected
    }
}

# Build host pools with session host count
$hostPools = $responseObject.value |
    Select-Object `
        name,
        @{Name = 'ResourceGroup'; Expression = { ($_.id -split '/')[4] }},
        location,
        @{Name = 'FriendlyName'; Expression = { $_.properties.friendlyName }},
        @{Name = 'HostPoolType'; Expression = { $_.properties.hostPoolType }},
        @{Name = 'LoadBalancerType'; Expression = { $_.properties.loadBalancerType }},
        @{Name = 'MaxSessionLimit'; Expression = { $_.properties.maxSessionLimit }},
        @{Name = 'PreferredAppGroupType'; Expression = { $_.properties.preferredAppGroupType }},
        @{Name = 'StartVMOnConnect'; Expression = { $_.properties.startVMOnConnect }},
        @{Name = 'ValidationEnvironment'; Expression = { $_.properties.validationEnvironment }},
        @{Name = 'SessionHostCount'; Expression = { $sessionHostCounts[$_.name] }}

Write-Host ""
Write-Host "=== Host pool summary ===" -ForegroundColor Cyan
$hostPoolSummaryRows | Sort-Object HostPool | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Host pools ===" -ForegroundColor Cyan

$hostPools | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Scaling plan per host pool ===" -ForegroundColor Cyan

$scalingPlanRows = foreach ($hp in $responseObject.value) {
    $info = $scalingPlanInfo[$hp.id]
    $enabled = if ($info) { $info.ScalingPlanEnabled } else { $false }
    $planName = if ($info) { $info.ScalingPlanName } else { "Not assigned" }
    [PSCustomObject]@{
        HostPool        = $hp.name
        ResourceGroup   = ($hp.id -split '/')[4]
        ScalingPlanEnabled = $enabled
        ScalingPlanName   = $planName
    }
}

$scalingPlanRows | Format-Table -AutoSize

Write-Host ""
Write-Host "=== Session hosts per host pool ===" -ForegroundColor Cyan

foreach ($group in ($sessionHostRows | Group-Object HostPool)) {
    $first = $group.Group[0]
    Write-Host ""
    Write-Host "Host pool: $($first.HostPool) (RG: $($first.ResourceGroup))" -ForegroundColor Green
    $group.Group | Sort-Object SessionHost | Format-Table -Property SessionHost, PrivateIP, AgentVersion, Status, LastHeartbeat, AllowNewSession -AutoSize
}

# File storage account (ARM REST): share, provisioned/used storage (GiB), IOPS, throughput
function ConvertFrom-AzRestJson {
    param($Response)
    if (-not $Response) { return $null }
    $c = $Response.Content
    if ($null -eq $c) { return $null }
    if ($c -is [string]) {
        $t = $c.TrimStart()
        if ($t.StartsWith('{') -or $t.StartsWith('[')) {
            return $c | ConvertFrom-Json
        }
        if ($t.StartsWith('<')) {
            return $null
        }
        return $null
    }
    return $c
}

function Get-SharePropertiesFromObject {
    param($Props)
    if (-not $Props) { return @{ ProvisionedGiB = $null; Iops = $null; Throughput = $null; UsedGiB = $null } }
    $gib = $null
    if ($null -ne $Props.shareQuotaGiB) { $gib = $Props.shareQuotaGiB }
    elseif ($null -ne $Props.ShareQuotaGiB) { $gib = $Props.ShareQuotaGiB }
    elseif ($null -ne $Props.shareQuota) { $gib = $Props.shareQuota }
    elseif ($null -ne $Props.ShareQuota) { $gib = $Props.ShareQuota }
    $iops = $null
    $tp = $null
    if ($null -ne $Props.provisionedIops) { $iops = $Props.provisionedIops }
    elseif ($null -ne $Props.ProvisionedIops) { $iops = $Props.ProvisionedIops }
    if ($null -ne $Props.provisionedBandwidthMibps) { $tp = $Props.provisionedBandwidthMibps }
    elseif ($null -ne $Props.ProvisionedBandwidthMibps) { $tp = $Props.ProvisionedBandwidthMibps }
    $burst = $Props.fileSharePaidBursting
    if (-not $burst) { $burst = $Props.FileSharePaidBursting }
    if ($burst) {
        if ($null -eq $iops -and $null -ne $burst.paidBurstingMaxIops) { $iops = $burst.paidBurstingMaxIops }
        elseif ($null -eq $iops -and $null -ne $burst.PaidBurstingMaxIops) { $iops = $burst.PaidBurstingMaxIops }
        if ($null -eq $tp -and $null -ne $burst.paidBurstingMaxBandwidthMibps) { $tp = $burst.paidBurstingMaxBandwidthMibps }
        elseif ($null -eq $tp -and $null -ne $burst.PaidBurstingMaxBandwidthMibps) { $tp = $burst.PaidBurstingMaxBandwidthMibps }
    }
    $usedBytes = $null
    if ($null -ne $Props.shareUsageBytes) { $usedBytes = $Props.shareUsageBytes }
    elseif ($null -ne $Props.ShareUsageBytes) { $usedBytes = $Props.ShareUsageBytes }
    $usedGiB = $null
    if ($null -ne $usedBytes) {
        $usedGiB = [math]::Round([double]$usedBytes / 1GB, 2)
    }
    return @{ ProvisionedGiB = $gib; Iops = $iops; Throughput = $tp; UsedGiB = $usedGiB }
}

$fileStorageRows = @()
if ($FileStorageAccount -and $FileStorageResourceGroup) {
    $storageArmApiVersion = "2025-06-01"
    $listSharesPath = "/subscriptions/$SubscriptionId/resourceGroups/$FileStorageResourceGroup/providers/Microsoft.Storage/storageAccounts/$FileStorageAccount/fileServices/default/shares?api-version=$storageArmApiVersion"

    try {
        $listResp = Invoke-AzRestMethod -Method GET -Path $listSharesPath
        $listObj = ConvertFrom-AzRestJson -Response $listResp
        if ($listObj -and $listObj.value) {
            $shareItems = @($listObj.value)
            while ($listObj.nextLink) {
                $nextPath = $listObj.nextLink -replace '^https://management\.azure\.com', ''
                $listResp = Invoke-AzRestMethod -Method GET -Path $nextPath
                $listObj = ConvertFrom-AzRestJson -Response $listResp
                if ($listObj -and $listObj.value) { $shareItems += $listObj.value }
                else { break }
            }

            foreach ($shareItem in $shareItems) {
                $shareName = $shareItem.name
                if (-not $shareName) { continue }

                $provisionedGiB = $null
                $iops = $null
                $throughput = $null
                $usedGiB = $null

                if ($shareItem.properties) {
                    $fromList = Get-SharePropertiesFromObject -Props $shareItem.properties
                    $provisionedGiB = $fromList.ProvisionedGiB
                    $iops = $fromList.Iops
                    $throughput = $fromList.Throughput
                    $usedGiB = $fromList.UsedGiB
                }

                $detailBase = "/subscriptions/$SubscriptionId/resourceGroups/$FileStorageResourceGroup/providers/Microsoft.Storage/storageAccounts/$FileStorageAccount/fileServices/default/shares/$shareName"
                foreach ($detailSuffix in @("?api-version=$storageArmApiVersion", "?api-version=$storageArmApiVersion&`$expand=stats")) {
                    try {
                        $detailResp = Invoke-AzRestMethod -Method GET -Path ($detailBase + $detailSuffix)
                        $detail = ConvertFrom-AzRestJson -Response $detailResp
                        if ($detail -and $detail.properties) {
                            $fromDetail = Get-SharePropertiesFromObject -Props $detail.properties
                            if ($null -ne $fromDetail.ProvisionedGiB) { $provisionedGiB = $fromDetail.ProvisionedGiB }
                            if ($null -ne $fromDetail.Iops) { $iops = $fromDetail.Iops }
                            if ($null -ne $fromDetail.Throughput) { $throughput = $fromDetail.Throughput }
                            if ($null -ne $fromDetail.UsedGiB) { $usedGiB = $fromDetail.UsedGiB }
                        }
                    }
                    catch {
                        continue
                    }
                }

                $iopsDisplay = if ($null -ne $iops) { $iops } else { "N/A (not provisioned)" }
                $tpDisplay = if ($null -ne $throughput) { $throughput } else { "N/A (not provisioned)" }
                $usedDisplay = if ($null -ne $usedGiB) { $usedGiB } else { "N/A" }

                $fileStorageRows += [PSCustomObject]@{
                    StorageAccount          = $FileStorageAccount
                    ResourceGroup           = $FileStorageResourceGroup
                    Share                   = $shareName
                    ProvisionedStorageGiB     = if ($null -ne $provisionedGiB) { $provisionedGiB } else { "N/A" }
                    UsedStorageGiB            = $usedDisplay
                    ProvisionedIops           = $iopsDisplay
                    ThroughputMiBps           = $tpDisplay
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to list file shares via ARM for storage account '$FileStorageAccount': $($_.Exception.Message)"
    }

    Write-Host ""
    Write-Host "=== File storage account (ARM API) ===" -ForegroundColor Cyan
    if ($fileStorageRows.Count -gt 0) {
        $fileStorageRows | Sort-Object Share | Format-Table -AutoSize
    }
    else {
        Write-Host "No file share details returned for storage account '$FileStorageAccount'." -ForegroundColor Yellow
    }
}

# Prepare markdown: host pools section
$mdLines = @()
$mdLines += "# AVD Host Pools"
$mdLines += ""
$mdLines += "## Host pool summary"
$mdLines += ""
$mdLines += "| HostPool | ResourceGroup | SessionHostsAvailable | SessionHostsShutdownOrUnavailable | UsersConnected |"
$mdLines += "| --- | --- | --- | --- | --- |"
foreach ($sum in ($hostPoolSummaryRows | Sort-Object HostPool)) {
    $mdLines += "| $($sum.HostPool) | $($sum.ResourceGroup) | $($sum.SessionHostsAvailable) | $($sum.SessionHostsShutdownOrUnavailable) | $($sum.UsersConnected) |"
}
$mdLines += ""
$mdLines += "## Host pools"
$mdLines += ""
$mdLines += "| Name | ResourceGroup | Location | FriendlyName | HostPoolType | LoadBalancerType | MaxSessionLimit | PreferredAppGroupType | StartVMOnConnect | ValidationEnvironment | SessionHostCount |"
$mdLines += "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
foreach ($hp in $hostPools) {
    $mdLines += "| $($hp.name) | $($hp.ResourceGroup) | $($hp.location) | $($hp.FriendlyName) | $($hp.HostPoolType) | $($hp.LoadBalancerType) | $($hp.MaxSessionLimit) | $($hp.PreferredAppGroupType) | $($hp.StartVMOnConnect) | $($hp.ValidationEnvironment) | $($hp.SessionHostCount) |"
}

# Append scaling plan section to markdown
$mdLines += ""
$mdLines += "## Scaling plan"
$mdLines += ""
$mdLines += "| HostPool | ResourceGroup | ScalingPlanEnabled | ScalingPlanName |"
$mdLines += "| --- | --- | --- | --- |"
foreach ($row in $scalingPlanRows) {
    $mdLines += "| $($row.HostPool) | $($row.ResourceGroup) | $($row.ScalingPlanEnabled) | $($row.ScalingPlanName) |"
}

# Append session hosts section to markdown
$mdLines += ""
$mdLines += "## Session hosts"
$mdLines += ""
$mdLines += "=== Session hosts per host pool ==="
$mdLines += ""

foreach ($group in ($sessionHostRows | Group-Object HostPool)) {
    $first = $group.Group[0]
    $mdLines += "### Host pool: $($first.HostPool) (RG: $($first.ResourceGroup))"
    $mdLines += ""
    $mdLines += "| SessionHost | PrivateIP | AgentVersion | Status | LastHeartbeat | AllowNewSession |"
    $mdLines += "| --- | --- | --- | --- | --- | --- |"
    foreach ($row in ($group.Group | Sort-Object SessionHost)) {
        $mdLines += "| $($row.SessionHost) | $($row.PrivateIP) | $($row.AgentVersion) | $($row.Status) | $($row.LastHeartbeat) | $($row.AllowNewSession) |"
    }
    $mdLines += ""
}

if ($fileStorageRows.Count -gt 0) {
    $mdLines += ""
    $mdLines += "## File storage account (ARM API)"
    $mdLines += ""
    $mdLines += "| StorageAccount | ResourceGroup | Share | ProvisionedStorageGiB | UsedStorageGiB | ProvisionedIops | ThroughputMiBps |"
    $mdLines += "| --- | --- | --- | --- | --- | --- | --- |"
    foreach ($fs in ($fileStorageRows | Sort-Object Share)) {
        $mdLines += "| $($fs.StorageAccount) | $($fs.ResourceGroup) | $($fs.Share) | $($fs.ProvisionedStorageGiB) | $($fs.UsedStorageGiB) | $($fs.ProvisionedIops) | $($fs.ThroughputMiBps) |"
    }
}

try {
    $mdLines | Out-File -FilePath $OutputMarkdownPath -Encoding UTF8
    Write-Host ""
    Write-Host "Host pool and session host summary written to markdown file: $OutputMarkdownPath" -ForegroundColor Green
}
catch {
    Write-Warning "Failed to write markdown output to '$OutputMarkdownPath': $($_.Exception.Message)"
}

if ($Fslogix) {
    Write-Host ""
    Write-Host "=== FSLogix storage account: $Fslogix ===" -ForegroundColor Cyan

    # Determine resource group for FSLogix storage account
    if ($FslogixResourceGroup) {
        $fslogixRg = $FslogixResourceGroup
    }
    else {
        $firstHp = $responseObject.value | Select-Object -First 1
        if (-not $firstHp) {
            Write-Host "No host pools available to infer resource group for FSLogix storage account, and -FslogixResourceGroup was not provided." -ForegroundColor Yellow
            return
        }

        $fslogixRg = ($firstHp.id -split '/')[4]
    }

    if (-not (Get-Module -ListAvailable -Name Az.Storage)) {
        Write-Error "Az.Storage module is required for FSLogix share details. Install it with 'Install-Module Az.Storage -Scope CurrentUser'."
        return
    }

    try {
        $storageAccount = Get-AzStorageAccount -ResourceGroupName $fslogixRg -Name $Fslogix -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to get storage account '$Fslogix' in resource group '$fslogixRg': $($_.Exception.Message)"
        return
    }

    $ctx = $storageAccount.Context

    try {
        $shares = Get-AzStorageShare -Context $ctx -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to list file shares for storage account '$Fslogix': $($_.Exception.Message)"
        return
    }

    if (-not $shares) {
        Write-Host "No file shares found on storage account '$Fslogix'." -ForegroundColor Yellow
        return
    }

    $shares |
        Select-Object `
            @{Name = 'StorageAccount'; Expression = { $Fslogix }},
            @{Name = 'ResourceGroup'; Expression = { $fslogixRg }},
            @{Name = 'Share'; Expression = { $_.Name }},
            @{Name = 'FullShareName'; Expression = { "\\$($Fslogix).file.core.windows.net\$($_.Name)" }} |
        Format-Table -AutoSize
}
