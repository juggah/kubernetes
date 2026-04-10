# Script to export Azure IP Inventory to Confluence.

#Setup azure environment
$applicationId = $Env:CLIENTID
$tenantId = "TenantID"

Write-Host "Environment ClientId $Env:CLIENTID"
Write-Host "KV NAME $Env:KV"

# Login to Azure using the federated token.
$tokenFilePath = "/var/run/secrets/azure/tokens/azure-identity-token" 
$federatedToken = Get-Content $tokenFilePath
Connect-AzAccount -FederatedToken $federatedToken -ApplicationId $applicationId -TenantId $tenantId

# Parameters:
#   - SubscriptionId: Array of Azure Subscription IDs to fetch IP inventory from
$SubscriptionId = @("subid1","subid2")
$SubscriptionName = @("subName1","subName2")

$confluenceApiToken = Get-AzKeyVaultSecret -VaultName $Env:KV -Name "ct-confluence-sa-api-token" -AsPlainText

# Function to execute KQL Query against Azure Resource Graph and perform pagination
function Get-AzIpInventory {
    param(
        [string[]]$SubscriptionId,
        [string]$kqlQuery
    )
    $batchSize = 100
    $skipResult = 0
    $kqlResult = @()
    while ($true) {
         if ($skipResult -gt 0) {
         $graphResult = Search-AzGraph -Subscription $SubscriptionId -Query $kqlQuery -First $batchSize -SkipToken $graphResult.SkipToken 
         }
         else {
            $graphResult = Search-AzGraph -Subscription $SubscriptionId -Query $kqlQuery -First $batchSize 
         }
      $kqlResult += $graphResult.data
      if ($graphResult.data.Count -lt $batchSize) {
        break;
        }
        $skipResult += $batchSize
        }
      return $kqlResult
    }

function Fix-and-SortIPAddresses {
    param(
        [Parameter(Mandatory)]
        [array]$Items
    )
    # IP Adresses that contains the subnetId, are dynamic Ip Addresses (e.g. bastion,function), so replace with 'Dynamic'
    $fixed = foreach ($item in $Items) {

        # If IP is equal to subnetId → Dynamic
        if ($item.ip -and $item.subnetId -and $item.ip -eq $item.subnetId) {
            $item.ip = "Dynamic"
        }
        # If IP is a Subnet-ID → Dynamic
        elseif ($item.ip -and $item.ip -like "*/virtualNetworks/*/subnets/*") {
            $item.ip = "Dynamic"
        }

        $item
    }
    #Sort IP addresses by VNET, Subnet, IP (numerically)
        $sorted = $fixed | Sort-Object `
        @{ Expression = { $_.vnetName } }, `
        @{ Expression = { $_.subnetName } }, `
        @{ Expression = {
            $ip = $_.ip

            # Empty IP → to the end
            if ([string]::IsNullOrWhiteSpace($ip)) {
                return [uint64]::MaxValue
            }

            # "Dynamic" → to the end
            if ($ip -eq "Dynamic") {
                return [uint64]::MaxValue
            }

            # Non-IPv4 string → to the end
            if ($ip -notmatch '^\d+\.\d+\.\d+\.\d+$') {
                return [uint64]::MaxValue
            }

            # Try to convert IP to number
            $parsed = [System.Net.IPAddress]::None
            if (-not [System.Net.IPAddress]::TryParse($ip, [ref]$parsed)) {
                return [uint64]::MaxValue
            }

            $bytes = $parsed.GetAddressBytes()
            if ($bytes.Length -ne 4) {
                return [uint64]::MaxValue
            }

            [Array]::Reverse($bytes)
            return [BitConverter]::ToUInt32($bytes, 0)
        }}

    return $sorted
}

# query to get Virtual Machine Scale Sets private IPs 
$kqlQueryVMSS =  "computeresources
    | where type == 'microsoft.compute/virtualmachinescalesets/virtualmachines/networkinterfaces'
    | mv-expand ipconf = properties.ipConfigurations limit 2000 // array in einzele zeilen
    | extend
        ip = tostring(ipconf.properties.privateIPAddress),
        subnetId=tostring(subnetId = ipconf.properties.subnet.id),
        vmId = substring(id, 0, indexof(id, '/networkInterfaces/'))
    | join kind=leftouter (
        computeresources
        | where type =~ 'microsoft.compute/virtualmachinescalesets/virtualmachines'
        | project
            vmId = id,
            vmHostname = tostring(properties.osProfile.computerName)
    ) on vmId
    | where isnotempty(subnetId)
    | extend
        subscriptionId = tostring(split(id, '/')[2]),
        resourceGroup  = tostring(split(id, '/')[4]),
        vnetName   = tostring(split(subnetId, '/')[8]),
        subnetName = tostring(split(subnetId, '/')[10]),
        hostname   = vmHostname
    | project name, subscriptionId, resourceGroup, subnetId, ip, hostname, subnetName, vnetName, type"

# query to get VM, Private Endpoint and Firewall private IPs 
    $kqlQueryVM = "resources
    | where type startswith'microsoft.network'
    | mv-expand ipconf = properties.ipConfigurations
    | extend ip = coalesce(
        tostring(ipconf.properties.privateIPAddress),   // NIC, FW, Private Outbound ...
        tostring(ipconf.privateIpAddress)               // Private DNS Resolver Inbound
    ),
            subnetId = coalesce(
        tostring(ipconf.properties.subnet.id),          // NIC, FW, Private Outbound, ...
        tostring(ipconf.subnet.id)                      //Private DNS Resolver Inbound
    ),
             vmId     = iff(isnotempty(properties.virtualMachine.id),tolower(tostring(properties.virtualMachine.id)), 'n/a')
    | join kind=leftouter (
    resources
    | where type =~ 'microsoft.compute/virtualmachines'
    | project
        vmId      = tolower(id),
        hostname  = coalesce(
            tostring(properties.extended.instanceView.computerName),
            tostring(properties.osProfile.computerName), //Normal VM
            tostring(properties.osProfile.linuxConfiguration.hostName), //Weird Linux VM
            tostring(properties.osProfile.windowsConfiguration.computerName), //Weird Windows VM
            name
        )
) on vmId
    | where isnotempty(subnetId)
    | extend
        subscriptionId = tostring(split(id, '/')[2]),
        resourceGroup  = tostring(split(id, '/')[4]),
        vnetName   = tostring(split(subnetId, '/')[8]),
        subnetName = tostring(split(subnetId, '/')[10])
    | project name, subscriptionId, resourceGroup, subnetId, ip, hostname, subnetName, vnetName, type"

#query to get Application Gateway and Loadbalancers private IPs
$kqlQueryappGW = "resources    
    | where type =~ 'microsoft.network/applicationgateways' or type =~ 'microsoft.network/loadbalancers'
    // alle Frontend-IP-Konfigurationen entpacken
    | mv-expand fip = properties.frontendIPConfigurations limit 2000
    | extend
        ip       = tostring(fip.properties.privateIPAddress),
        subnetId = tostring(fip.properties.subnet.id),
        hostname = ''
    // nur Frontends mit privater IP (egal ob Static oder Dynamic)
    | where isnotempty(ip)
    // Schema angleichen
    | extend
        subscriptionId = tostring(split(id, '/')[2]),
        resourceGroup  = tostring(split(id, '/')[4]),
        vnetName   = tostring(split(subnetId, '/')[8]),
        subnetName = tostring(split(subnetId, '/')[10])
    | project name, subscriptionId, resourceGroup, subnetId, ip, hostname, subnetName, vnetName, type"

#query to get all other resources private IPs
$kqlQueryAOR = "resources 
    | extend subnetId = coalesce(
         tostring(properties.virtualNetworkSubnetId), //Azure App Service
         tostring(properties.subnet.id) //DNS Resolver outbound
        )
    | extend ip = coalesce(
        tostring(properties.virtualNetworkSubnetId), //Azure App Service
        tostring(properties.subnet.id) //DNS Resolver outbound
        )
    | extend hostname = ''
    | where isnotempty(subnetId) and type !~ 'microsoft.network/privateendpoints'
    // Schema angleichen
    | extend
        subscriptionId = tostring(split(id, '/')[2]),
        resourceGroup  = tostring(split(id, '/')[4]),
        vnetName   = tostring(split(subnetId, '/')[8]),
        subnetName = tostring(split(subnetId, '/')[10])
    | project name, subscriptionId, resourceGroup, subnetId, ip, hostname, subnetName, vnetName, type"

#query to get all public IPs and their associated resources
$kqlQueryPIP = "resources
    | where type contains 'publicIPAddresses' and isnotempty(properties.ipAddress)
    | extend  assocType = iff(isnotempty(properties.natGateway.id), tostring(split(properties.natGateway.id,'/')[7]),  tostring(split(properties.ipConfiguration.id, '/')[7]))
    | extend rgOfAssocResource = iff(isnotempty(properties.natGateway.id), tostring(split(properties.natGateway.id,'/')[4]), tostring(split(properties.ipConfiguration.id, '/')[4]))
    | extend pip = properties.ipAddress
    | project subscriptionId, resourceGroup, location, name, pip, assocType, rgOfAssocResource"

#query to get all Azure Functions and App Service IPs
$kqlQueryFunc = "resources
    | where type =~ 'Microsoft.Web/Sites' 
    | project subscriptionId, resourceGroup, name,  fqdn=properties.defaultHostName, ip=properties.inboundIpAddress 
    | sort by subscriptionId"


# Get all Private IPs
$VMSS = Get-AzIpInventory -SubscriptionId $SubscriptionId -kqlQuery $kqlQueryVMSS
$VM= Get-AzIpInventory -SubscriptionId $SubscriptionId -kqlQuery $kqlQueryVM
$APPGws = Get-AzIpInventory -SubscriptionId $SubscriptionId -kqlQuery $kqlQueryappGW
$AORs = Get-AzIpInventory -SubscriptionId $SubscriptionId -kqlQuery $kqlQueryAOR

$all = @(
       $VMSS  
       $VM  
       $APPGws
       $AORs
)

# Get all Public IPs
$PIPs = Get-AzIpInventory -SubscriptionId $SubscriptionId -kqlQuery $kqlQueryPIP
# Get all Function/App Service IPs
$FPIPs = Get-AzIpInventory -SubscriptionId $SubscriptionId -kqlQuery $kqlQueryFunc

# Function to post data to Confluence Cloud as a table
function Publish-ToConfluence {
    param(
        [Parameter(Mandatory)]
        [array]$Data,
        
        [Parameter(Mandatory)]
        [array]$PublicIPs,
        
        [Parameter(Mandatory)]
        [array]$FunctionIPs,
        
        [Parameter(Mandatory)]
        [array]$SubscriptionIds,
        
        [Parameter(Mandatory)]
        [array]$SubscriptionNames,
        
        [Parameter(Mandatory)]
        [string]$ConfluenceUrl,  #  "https://Company.atlassian.net"
        
        [Parameter(Mandatory)]
        [string]$PageId,  # Page ID of the confluence page to update
        
        [Parameter(Mandatory)]
        [string]$PageTitle,  # Title of the Confluence page
        
        [Parameter(Mandatory)]
        [string]$ApiToken  # Confluence Service Account Bearer Token
    )
    
    # Create lookup hashtable for subscription ID to Name
    $subLookup = @{}
    for ($i = 0; $i -lt $SubscriptionIds.Count; $i++) {
        $subLookup[$SubscriptionIds[$i]] = $SubscriptionNames[$i]
    }
    
    # Build Confluence table
    # Alternate colors every 2nd row
    $rowIndex = 0
    
    # Build table rows
    $tableRows = ""
    
    # Header row
    $tableRows += "<tr>"
    $tableRows += "<th><p style='text-align: left;'><strong>Subscription ID</strong></p></th>"
    $tableRows += "<th><p style='text-align: left;'><strong>Resource Group</strong></p></th>"
    $tableRows += "<th><p style='text-align: left;'><strong>VNET Name</strong></p></th>"
    $tableRows += "<th><p style='text-align: left;'><strong>Subnet Name</strong></p></th>"
    $tableRows += "<th><p style='text-align: left;'><strong>Resource Name</strong></p></th>"
    $tableRows += "<th><p style='text-align: left;'><strong>Hostname</strong></p></th>"
    $tableRows += "<th><p style='text-align: left;'><strong>IP Address</strong></p></th>"
    $tableRows += "<th><p style='text-align: left;'><strong>Resource Type</strong></p></th>"
    $tableRows += "</tr>"
    
    # Data rows with alternating background colors
    foreach ($item in $Data) {
        # Alternate color every 2nd row - use Confluence color names
        $bgColor = if ($rowIndex % 2 -eq 0) { "grey" } else { "" }
        
        # Resolve subscription name
        $subName = if ($subLookup.ContainsKey($item.subscriptionId)) { $subLookup[$item.subscriptionId] } else { "Unknown" }
        $subDisplay = "<strong>$subName</strong><br/><span style='font-size: 0.85em; color: #6B7280;'>$($item.subscriptionId)</span>"
        
        $tableRows += "<tr>"
        if ($bgColor) {
            $tableRows += "<td data-highlight-colour='$bgColor'>$subDisplay</td>"
            $tableRows += "<td data-highlight-colour='$bgColor'><code>$($item.resourceGroup)</code></td>"
            $tableRows += "<td data-highlight-colour='$bgColor'><code>$($item.vnetName)</code></td>"
            $tableRows += "<td data-highlight-colour='$bgColor'><code>$($item.subnetName)</code></td>"
            $tableRows += "<td data-highlight-colour='$bgColor'><code>$($item.name)</code></td>"
            $tableRows += "<td data-highlight-colour='$bgColor'><code>$($item.hostname)</code></td>"
            $tableRows += "<td data-highlight-colour='$bgColor'><code>$($item.ip)</code></td>"
            $tableRows += "<td data-highlight-colour='$bgColor'><code>$($item.type)</code></td>"
        } else {
            $tableRows += "<td>$subDisplay</td>"
            $tableRows += "<td><code>$($item.resourceGroup)</code></td>"
            $tableRows += "<td><code>$($item.vnetName)</code></td>"
            $tableRows += "<td><code>$($item.subnetName)</code></td>"
            $tableRows += "<td><code>$($item.name)</code></td>"
            $tableRows += "<td><code>$($item.hostname)</code></td>"
            $tableRows += "<td><code>$($item.ip)</code></td>"
            $tableRows += "<td><code>$($item.type)</code></td>"
        }
        $tableRows += "</tr>"
        
        $rowIndex++
    }
    
    # Confluence table 
    $tableHtml = "<table data-layout='default' ac:local-id='ip-inventory-table'><colgroup><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /></colgroup>"
    $tableHtml += "<tbody>$tableRows</tbody></table>"

    # Build Public IPs table
    $publicIPRows = ""
    
    # Public IPs Header row
    $publicIPRows += "<tr>"
    $publicIPRows += "<th><p style='text-align: left;'><strong>Subscription ID</strong></p></th>"
    $publicIPRows += "<th><p style='text-align: left;'><strong>Location</strong></p></th>"
    $publicIPRows += "<th><p style='text-align: left;'><strong>Resource Group</strong></p></th>"
    $publicIPRows += "<th><p style='text-align: left;'><strong>Resource Name</strong></p></th>"
    $publicIPRows += "<th><p style='text-align: left;'><strong>Public IP</strong></p></th>"
    $publicIPRows += "<th><p style='text-align: left;'><strong>Associated Type</strong></p></th>"
    $publicIPRows += "<th><p style='text-align: left;'><strong>Associated RG</strong></p></th>"
    $publicIPRows += "</tr>"
    
    # Public IPs Data rows
    $pipRowIndex = 0
    foreach ($pip in $PublicIPs) {
        # Alternate color every 2nd row - use Confluence color names
        $bgColor = if ($pipRowIndex % 2 -eq 0) { "grey" } else { "" }
        
        # Resolve subscription name
        $subName = if ($subLookup.ContainsKey($pip.subscriptionId)) { $subLookup[$pip.subscriptionId] } else { "Unknown" }
        $subDisplay = "<strong>$subName</strong><br/><span style='font-size: 0.85em; color: #6B7280;'>$($pip.subscriptionId)</span>"
        
        $publicIPRows += "<tr>"
        if ($bgColor) {
            $publicIPRows += "<td data-highlight-colour='$bgColor'>$subDisplay</td>"
            $publicIPRows += "<td data-highlight-colour='$bgColor'><code>$($pip.location)</td>"
            $publicIPRows += "<td data-highlight-colour='$bgColor'><code>$($pip.resourceGroup)</code></td>"
            $publicIPRows += "<td data-highlight-colour='$bgColor'><code>$($pip.name)</code></td>"
            $publicIPRows += "<td data-highlight-colour='$bgColor'><code>$($pip.pip)</code></td>"
            $publicIPRows += "<td data-highlight-colour='$bgColor'><code>$($pip.assocType)</code></td>"
            $publicIPRows += "<td data-highlight-colour='$bgColor'><code>$($pip.rgOfAssocResource)</code></td>"
        } else {
            $publicIPRows += "<td>$subDisplay</td>"
            $publicIPRows += "<td><code>$($pip.location)</code></td>"
            $publicIPRows += "<td><code>$($pip.resourceGroup)</code></td>"
            $publicIPRows += "<td><code>$($pip.name)</code></td>"
            $publicIPRows += "<td><code>$($pip.pip)</code></td>"
            $publicIPRows += "<td><code>$($pip.assocType)</code></td>"
            $publicIPRows += "<td><code>$($pip.rgOfAssocResource)</code></td>"
        }
        $publicIPRows += "</tr>"
        
        $pipRowIndex++
    }
    
    $publicIPTableHtml = "<table data-layout='default' ac:local-id='public-ip-table'><colgroup><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /><col style='width: 14.28%;' /></colgroup>"
    $publicIPTableHtml += "<tbody>$publicIPRows</tbody></table>"
    
    # Build Functions/App Service IPs table
    $functionIPRows = ""
    
    # Functions IPs Header row
    $functionIPRows += "<tr>"
    $functionIPRows += "<th><p style='text-align: left;'><strong>Subscription ID</strong></p></th>"
    $functionIPRows += "<th><p style='text-align: left;'><strong>Resource Group</strong></p></th>"
    $functionIPRows += "<th><p style='text-align: left;'><strong>Resource Name</strong></p></th>"
    $functionIPRows += "<th><p style='text-align: left;'><strong>FQDN</strong></p></th>"
    $functionIPRows += "<th><p style='text-align: left;'><strong>Inbound IP</strong></p></th>"
    $functionIPRows += "</tr>"
    
    # Functions IPs Data rows
    $funcRowIndex = 0
    foreach ($func in $FunctionIPs) {
        # Alternate color every 2nd row - use Confluence color names
        $bgColor = if ($funcRowIndex % 2 -eq 0) { "grey" } else { "" }
        
        # Resolve subscription name
        $subName = if ($subLookup.ContainsKey($func.subscriptionId)) { $subLookup[$func.subscriptionId] } else { "Unknown" }
        $subDisplay = "<strong>$subName</strong><br/><span style='font-size: 0.85em; color: #6B7280;'>$($func.subscriptionId)</span>"
        
        $functionIPRows += "<tr>"
        if ($bgColor) {
            $functionIPRows += "<td data-highlight-colour='$bgColor'>$subDisplay</td>"
            $functionIPRows += "<td data-highlight-colour='$bgColor'><code>$($func.resourceGroup)</code></td>"
            $functionIPRows += "<td data-highlight-colour='$bgColor'><code>$($func.name)</code></td>"
            $functionIPRows += "<td data-highlight-colour='$bgColor'><code>$($func.fqdn)</code></td>"
            $functionIPRows += "<td data-highlight-colour='$bgColor'><code>$($func.ip)</code></td>"
        } else {
            $functionIPRows += "<td>$subDisplay</td>"
            $functionIPRows += "<td><code>$($func.resourceGroup)</code></td>"
            $functionIPRows += "<td><code>$($func.name)</code></td>"
            $functionIPRows += "<td><code>$($func.fqdn)</code></td>"
            $functionIPRows += "<td><code>$($func.ip)</code></td>"
        }
        $functionIPRows += "</tr>"
        
        $funcRowIndex++
    }
    
    $functionIPTableHtml = "<table data-layout='default' ac:local-id='function-ip-table'><colgroup><col style='width: 20%;' /><col style='width: 20%;' /><col style='width: 20%;' /><col style='width: 20%;' /><col style='width: 20%;' /></colgroup>"
    $functionIPTableHtml += "<tbody>$functionIPRows</tbody></table>"
    
    # Add timestamp and summary
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $summary = "<p><strong>Azure IP Inventory Report</strong></p>"
    $summary += "<p>Generated: $timestamp</p>"
    $summary += "<p>Total Private IPs: $($Data.Count)</p>"
    $summary += "<p>Total Public IPs: $($PublicIPs.Count)</p>"
    $summary += "<p>Total Functions/App Services: $($FunctionIPs.Count)</p>"
    $summary += "<hr/>"
    
    # Add Table of Contents
    $toc = "<p><ac:structured-macro ac:name='toc' ac:schema-version='1' /></p>"
    
    # Add section headings
    $privateIPHeading = "<h1>Private IP Addresses</h1>"
    $publicIPHeading = "<h1>Public IP Addresses</h1><p>If column 'Associated Type' is  empty then the public IP is not associated to a resource</p>"
    $functionsHeading = "<h1>Azure Functions / App Service IP Addresses</h1>"
    
    $fullContent = $summary + $toc + $privateIPHeading + $tableHtml + $publicIPHeading + $publicIPTableHtml + $functionsHeading + $functionIPTableHtml
    
    # Resolve Confluence Cloud ID and build v2 API endpoint
    $baseUrl  = $ConfluenceUrl.TrimEnd('/')
    $cloudId  = (Invoke-RestMethod -Uri "$baseUrl/_edge/tenant_info").cloudId
    $endpoint = "https://api.atlassian.com/ex/confluence/$cloudId/wiki/api/v2/pages/$PageId"
    $headers  = @{ Authorization = "Bearer $($ApiToken.Trim())"; "Content-Type" = "application/json" }

    $makebody = { param($v) @{ id=$PageId; status="current"; version=@{number=$v}; title=$PageTitle; body=@{representation="storage"; value=$fullContent} } | ConvertTo-Json -Depth 10 }

    # Token has write-only scope: probe with version=1 to get current version from the 409 conflict
    try { Invoke-RestMethod -Uri $endpoint -Headers $headers -Method Put -Body (& $makebody 1) -ErrorAction Stop }
    catch {
        if ($_.ErrorDetails.Message -match 'Current Version: \[(\d+)\]') {
            $version = [int]$Matches[1] + 1
        } else { throw $_ }
    }

    $result = Invoke-RestMethod -Uri $endpoint -Headers $headers -Method Put -Body (& $makebody $version)
    Write-Host "Page updated to v${version}: $baseUrl/wiki/pages/$PageId" -ForegroundColor Green
    Write-Host "Total items published: $($Data.Count)" -ForegroundColor Cyan
    return $result
}

# Fix and Sort IP Addresses
$sorted = Fix-and-SortIPAddresses -Items $all 

# Output the result as a table
$sorted | Select-Object subscriptionId, resourceGroup, vnetName, subnetName, name, ip, type | Format-Table -AutoSize

# Confluence parameters
$confluenceParams = @{
    Data = $sorted
    PublicIPs = $PIPs
    FunctionIPs = $FPIPs
    SubscriptionIds = $SubscriptionId
    SubscriptionNames = $SubscriptionName
    ConfluenceUrl = "https://Company.atlassian.net"
    PageId = "519602277"  # Your Confluence Page ID
    PageTitle = "Azure IP Inventory"
    ApiToken = $confluenceApiToken  # Confluence Service Account Bearer Token
}
Publish-ToConfluence @confluenceParams
