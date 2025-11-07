param(
    [string]$suffix
)
Clear-Host
Write-Host "Starting script at $(Get-Date)"

# If no suffix provided, generate a 7-character alphanumeric one
if (-not $suffix) {
    $suffix = -join ((48..57) + (97..122) | Get-Random -Count 7 | ForEach-Object {[char]$_})
}

$resourceGroupName = "msl-$suffix"
Write-Output "Using resource group name: $resourceGroupName"

# Handle multiple subscriptions
$subs = Get-AzSubscription | Select-Object
if ($subs.GetType().IsArray -and $subs.length -gt 1) {
    Write-Host "You have multiple Azure subscriptions - please select the one you want to use:"
    for ($i = 0; $i -lt $subs.length; $i++) {
        Write-Host "[$($i)]: $($subs[$i].Name) (ID = $($subs[$i].Id))"
    }
    $selectedIndex = -1
    while ($selectedIndex -lt 0 -or $selectedIndex -ge $subs.Length) {
        $enteredValue = Read-Host("Enter 0 to $($subs.Length - 1)")
        if ([int]::TryParse($enteredValue, [ref]$null)) {
            $selectedIndex = [int]$enteredValue
        }
    }
    $selectedSub = $subs[$selectedIndex].Id
    Select-AzSubscription -SubscriptionId $selectedSub
    az account set --subscription $selectedSub
}

# Register resource providers
Write-Host "Registering resource providers..."
$provider_list = "Microsoft.Storage", "Microsoft.Compute", "Microsoft.Databricks"
foreach ($provider in $provider_list) {
    $result = Register-AzResourceProvider -ProviderNamespace $provider
    Write-Host "$provider : $($result.RegistrationState)"
}

# Expanded supported regions for Databricks
$supported_regions = @(
    "canadacentral","canadaeast",
    "eastus","eastus2","westus","westus2","centralus","northcentralus","southcentralus",
    "westeurope","northeurope"
)

Write-Host "Preparing to deploy. This may take several minutes..."
Start-Sleep -Seconds (0,30,60,90,120 | Get-Random)

# Get valid locations
$locations = Get-AzLocation | Where-Object {
    $_.Providers -contains "Microsoft.Databricks" -and
    $_.Providers -contains "Microsoft.Compute" -and
    $_.Location -in $supported_regions
}

# Use a more widely available SKU
$targetSku = "Standard_DS3_v2"

$rand = Get-Random -Minimum 0 -Maximum $locations.Count
$Region = $locations[$rand].Location

$stop = 0
$tried_regions = New-Object Collections.Generic.List[string]

while ($stop -ne 1) {
    Write-Host "Trying $Region..."
    $skuOK = 1
    $skus = Get-AzComputeResourceSku -Location $Region | Where-Object {
        $_.ResourceType -eq "VirtualMachines" -and $_.Name -eq $targetSku
    }
    if ($skus.length -gt 0 -and $skus.Restrictions.Count -gt 0) {
        $skuOK = 0
        Write-Host "SKU restricted: $($skus.Restrictions[0].ReasonCode)"
    }

    $available_quota = 0
    if ($skuOK -eq 1) {
        $quota = @(Get-AzVMUsage -Location $Region).where{ $_.Name.LocalizedValue -match 'Standard DSv2 Family vCPUs' }
        if ($quota) {
            $available_quota = $quota.Limit - $quota.CurrentValue
            Write-Host "$($quota.CurrentValue) of $($quota.Limit) cores in use."
        }
    }

    if (($available_quota -lt 4) -or ($skuOK -eq 0)) {
        Write-Host "$Region has insufficient capacity."
        $tried_regions.Add($Region)
        $locations = $locations | Where-Object { $_.Location -notin $tried_regions }
        if ($locations.Count -gt 0) {
            $Region = $locations[(Get-Random -Minimum 0 -Maximum $locations.Count)].Location
        } else {
            Write-Host "Could not create a Databricks workspace."
            Write-Host "Try using the Azure portal to add one to the $resourceGroupName resource group."
            $stop = 1
        }
    } else {
        Write-Host "Creating $resourceGroupName resource group ..."
        New-AzResourceGroup -Name $resourceGroupName -Location $Region | Out-Null
        $dbworkspace = "databricks-$suffix"
        Write-Host "Creating $dbworkspace Azure Databricks workspace in $resourceGroupName resource group..."
        New-AzDatabricksWorkspace -Name $dbworkspace -ResourceGroupName $resourceGroupName -Location $Region -Sku premium | Out-Null
        $stop = 1
    }
}

Write-Host "Script completed at $(Get-Date)"
