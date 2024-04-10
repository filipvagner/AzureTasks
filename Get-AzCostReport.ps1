$subscriptionList = @(
    "00000000-0000-0000-0000-000000000000",
    "00000000-0000-0000-0000-000000000001"
)
$companyName = "my_company"
$downloadData = $false
$processData = $true
$createHtmlReport = $true
$costDataPath = "$env:USERPROFILE\Downloads\report_"
$htmlReportPath = "$env:USERPROFILE\Downloads\cost_report.html"
$subObjList = New-Object -TypeName "System.Collections.ArrayList"
$monthFday = (Get-Date -Month ((Get-Date).Month - 1) -Day 1).ToString("yyyy-MM-dd")
$monthLday = (Get-Date -Day 1).AddDays(-1).ToString("yyyy-MM-dd")

if ($downloadData) {
    $azToken = (Get-AzAccessToken).Token

    Write-Host "INFORMATION - DOWNLOADING DATA"
    foreach ($subItem in $subscriptionList) {
        Write-Host "INFORMATION - PROCESSSING $subItem"
        $costDataPathFile = $costDataPath + $subItem + ".csv"

        $costRequest = @{
            Method      = "POST"
            Uri         = "https://management.azure.com/subscriptions/$subItem/providers/Microsoft.CostManagement/generateCostDetailsReport?api-version=2023-08-01"
            Headers     = @{"authorization" = "Bearer $azToken"}
            ContentType = "application/json"
            Body        = @{
                "metric" = "ActualCost"
                "timePeriod" = @{
                    "start" = $monthFday
                    "end" = $monthLday
                }
            } | ConvertTo-Json -Depth 2
        }
        $costRequestResult = (Invoke-WebRequest @costRequest).RawContent -split "`r`n"

        [string]$reportEndpoint = ""
        foreach ($lineItem in $costRequestResult) {
            if ($lineItem.StartsWith("Location")) {
                $reportEndpoint = $lineItem.Replace("Location: ", "").Trim()
            }
        }

        [int]$retryTime = ""
        foreach ($lineItem in $costRequestResult) {
            if ($lineItem.StartsWith("Retry-After:")) {
                $retryTime = $lineItem.Replace("Retry-After: ", "").Trim()
            }
        }

        $getCost = @{
            Method      = "GET"
            Uri         = $reportEndpoint
            Headers     = @{"authorization" = "Bearer $azToken"}
            ContentType = "application/json"
            Body        = ""
        }
        $reportLink = ((Invoke-WebRequest @getCost).Content | ConvertFrom-Json).manifest.blobs.blobLink

        $repeatCounter = 0
        if ([string]::IsNullOrEmpty($reportLink)) {
            while (($repeatCounter -lt 6) -and [string]::IsNullOrEmpty($reportLink)) {
                Write-Host "INFORMATION - Report is not ready for download"
                $reportLink = ((Invoke-WebRequest @getCost).Content | ConvertFrom-Json).manifest.blobs.blobLink
                Start-Sleep -Seconds $retryTime
                $repeatCounter++
            }
        }

        if ([string]::IsNullOrEmpty($reportLink)) {
            Write-Host "ERROR - Cannot get data for subscription $subItem"
            Clear-Variable -Name subObj
            continue
        }
        
        Invoke-WebRequest -Uri $reportLink -OutFile $costDataPathFile
    }
}

if ($processData) {
    Write-Host "INFORMATION - PROCESSING DATA"
    [decimal]$totalCostBC = 0
    [decimal]$totalCostPC = 0
    foreach ($subItem in $subscriptionList) {
        Write-Host "INFORMATION - PROCESSSING $subItem"
        $costDataPathFile = $costDataPath + $subItem + ".csv"
        
        if (!(Test-Path -Path $costDataPathFile)) {
            Write-Host "ERROR - Data file $costDataPathFile for subscription $subItem not found"
            continue
        }

        $subObj = [PSCustomObject]@{
            SubscriptionName = ""
            SubscriptionId = ""
            CostInBillingCurrency = 0
            CostInPricingCurrency = 0
            Services = New-Object -TypeName "System.Collections.ArrayList"
            Locations = New-Object -TypeName "System.Collections.ArrayList"
            ResourceGroups = New-Object -TypeName "System.Collections.ArrayList"
            Family = New-Object -TypeName "System.Collections.ArrayList"
        }

        $costData = Import-Csv -Path $costDataPathFile
        [string]$subscriptionName =  ($costData | Select-Object -First 1).subscriptionName
        [string]$subscriptionId =  ($costData | Select-Object -First 1).SubscriptionId
        [decimal]$subscriptionTotalCostBC = ($costData | Measure-Object -Property "costInBillingCurrency" -Sum).Sum # BC stands for Billing Currency, the currency you choose to pay in
        [decimal]$subscriptionTotalCostPC = ($costData | Measure-Object -Property "costInPricingCurrency" -Sum).Sum # PC stands for Pricing Currency, the currency in which service is offered in
        $totalCostBC = $totalCostBC + $subscriptionTotalCostBC
        $totalCostPC = $totalCostPC + $subscriptionTotalCostPC

        Write-Host "Subscription Name: $subscriptionName"
        Write-Host "Subscription ID: $subscriptionId"
        Write-Host "Billing Currency: $($subscriptionTotalCostBC.ToString("0.00"))"
        Write-Host "Pricing Currency: $($subscriptionTotalCostPC.ToString("0.00"))"

        $subObj.SubscriptionName = if ([string]::IsNullOrEmpty($subscriptionName)) {
            "N/A"
        }
        else {
            $subscriptionName
        }
        $subObj.SubscriptionId = if ([string]::IsNullOrEmpty($subscriptionId)) {
            $subItem
        }
        else {
            $subscriptionId
        }
        $subObj.CostInBillingCurrency = $subscriptionTotalCostBC.ToString("0.00")
        $subObj.CostInPricingCurrency = $subscriptionTotalCostPC.ToString("0.00")

        $groupedMc = $costData | Group-Object -Property "meterCategory"
        foreach ($groupItem in $groupedMc) {
            $subObj.Services.Add(
                [PSCustomObject]@{
                    Service = $groupItem.Name
                    Cost  = ($groupItem.Group | Measure-Object -Property "costInBillingCurrency" -Sum).Sum.ToString("0.00").Replace(',','.')
                }    
            ) | Out-Null
        }

        $groupRg = $costData | Group-Object -Property "resourceGroupName"
        foreach ($groupItem in $groupRg) {
            if ([string]::IsNullOrEmpty($groupItem.Name)) {
                $subObj.ResourceGroups.Add(
                    [PSCustomObject]@{
                        ResourceGroup = "N/A"
                        Cost  = ($groupItem.Group | Measure-Object -Property "costInBillingCurrency" -Sum).Sum.ToString("0.00").Replace(',','.')
                    }    
                ) | Out-Null
            }
            else {
                $subObj.ResourceGroups.Add( 
                    [PSCustomObject]@{
                        ResourceGroup = $groupItem.Name
                        Cost  = ($groupItem.Group | Measure-Object -Property "costInBillingCurrency" -Sum).Sum.ToString("0.00").Replace(',','.')
                    }
                ) | Out-Null
            }
        }

        $groupLocation = $costData | Group-Object -Property "location"
        foreach ($groupItem in $groupLocation) {
            $subObj.Locations.Add(
                [PSCustomObject]@{
                    Location = $groupItem.Name
                    Cost  = ($groupItem.Group | Measure-Object -Property "costInBillingCurrency" -Sum).Sum.ToString("0.00").Replace(',','.')
                }    
            ) | Out-Null
        }
        
        $subObjList.Add($subObj) | Out-Null
    }
}

if ($createHtmlReport) {
    $billingCurrency = $($costData[0].billingCurrency)
    $pricingCurrency = $($costData[0].pricingCurrency)
    $reportBodyString = [System.Text.StringBuilder]::new()
    #region CSS Style
    $reportBodyString.Append("<!DOCTYPE html>
    <html>
    <head>
    <style>
    .table {
        border-collapse: collapse;
        /*width: 100%;*/
    }

    .table td, .table th {
        border: 1px solid #ddd;
        padding: 8px;
    }

    .table tr:hover {
        background-color: #ddd;
    }

    .table th {
        padding-top: 12px;
        padding-bottom: 12px;
        text-align: center;
        background-color: #2A0071;
        color: white;
    }

    .tdbold {
        font-weight: bold
    }

    .tdpadding {
        padding: 8px 23px!important;
    }

    .collapsible {
        background-color: #eee;
        color: #444;
        cursor: pointer;
        padding: 18px;
        width: 100%;
        border: none;
        text-align: left;
        outline: none;
        font-size: 15px;
    }

    /* Style the button when clicked or hovered */
    .active, .collapsible:hover {
        background-color: #ccc;
    }

    /* Hide the collapsible content by default */
    .content {
        padding: 0 18px;
        display: none;
        overflow: hidden;
        background-color: #ffffff;
    }
    </style>
    </head>
    ") | Out-Null
    #endregion CSS Style

    #region Overview report
    $reportBodyString.Append("<h1>$companyName - Cost report</h1>") | Out-Null
    $reportBodyString.Append("<p>Below is a summary of cost for subscriptions for period from <b>$monthFday</b> to <b>$monthLday</b>") | Out-Null
    $reportBodyString.Append("<br>Billing currency is <b>$billingCurrency</b>, the currency you choose to pay in.") | Out-Null
    $reportBodyString.Append("<br>Pricing currency is <b>$pricingCurrency</b>, the currency in which service is offered in.") | Out-Null
    $reportBodyString.Append('<table class="table">') | Out-Null
    $reportBodyString.Append("<tr>") | Out-Null
    $reportBodyString.Append("<th>Subscription Name</th>") | Out-Null
    $reportBodyString.Append("<th>Subscription ID</th>") | Out-Null
    $reportBodyString.Append("<th>Billing Currency ($billingCurrency)</th>") | Out-Null
    $reportBodyString.Append("<th>Pricing Currency ($pricingCurrency)</th>") | Out-Null
    $reportBodyString.Append("</tr>") | Out-Null
    foreach ($subItem in $subObjList) {
        $reportBodyString.Append("<tr>") | Out-Null
        $reportBodyString.Append("<td>") | Out-Null
        $reportBodyString.Append($subItem.SubscriptionName) | Out-Null
        $reportBodyString.Append("</td>") | Out-Null
        $reportBodyString.Append("<td>") | Out-Null
        $reportBodyString.Append($subItem.SubscriptionId) | Out-Null
        $reportBodyString.Append("</td>") | Out-Null
        $reportBodyString.Append("<td>") | Out-Null
        $reportBodyString.Append($subItem.CostInBillingCurrency) | Out-Null
        $reportBodyString.Append("</td>") | Out-Null
        $reportBodyString.Append("<td>") | Out-Null
        $reportBodyString.Append($subItem.CostInPricingCurrency) | Out-Null
        $reportBodyString.Append("</td>") | Out-Null
        $reportBodyString.Append("</tr>") | Out-Null
    }
    $reportBodyString.Append('<tr style="background-color: #f2f2f2;">') | Out-Null
    $reportBodyString.Append('<td colspan="2"><b>Total cost</b></td>') | Out-Null
    $reportBodyString.Append("<td><b>$($totalCostBC.ToString("0.00"))</b></td>") | Out-Null
    $reportBodyString.Append("<td><b>$($totalCostPC.ToString("0.00"))</b></td>") | Out-Null
    $reportBodyString.Append("</tr>") | Out-Null
    $reportBodyString.Append("</table>") | Out-Null
    #endregion Overview report

    #region Detailed report
    $reportBodyString.Append("<br>") | Out-Null
    $reportBodyString.Append("<h2>Detailed subscriptions report</h2>") | Out-Null
    $reportBodyString.Append("<p>Below you can find deatiled information for each subscription about cost per service, resource group and location</p>") | Out-Null
    $reportBodyString.Append("<br>") | Out-Null

    foreach ($subItem in $subObjList) {
        $reportBodyString.Append('<button type="button" class="collapsible">') | Out-Null
        $reportBodyString.Append("$($subItem.SubscriptionName)") | Out-Null
        $reportBodyString.Append("</button>") | Out-Null
        $reportBodyString.Append('<div class="content">') | Out-Null
        $reportBodyString.Append("<p>") | Out-Null
        $reportBodyString.Append("Subscription name: $($subItem.SubscriptionName)") | Out-Null
        $reportBodyString.Append("<br>Subscription ID: $($subItem.SubscriptionId)") | Out-Null
        $reportBodyString.Append("<br>Cost: $($subItem.CostInBillingCurrency) $billingCurrency") | Out-Null
        $reportBodyString.Append("</p>") | Out-Null

        #region Services report
        $reportBodyString.Append("<b>Service cost</b>") | Out-Null
        $reportBodyString.Append('<table class="table">') | Out-Null
        foreach ($sItem in $subItem.Services) {
            $reportBodyString.Append("<tr>") | Out-Null
            $reportBodyString.Append("<td>") | Out-Null
            $reportBodyString.Append($sItem.Service) | Out-Null
            $reportBodyString.Append("</td>") | Out-Null
            $reportBodyString.Append("<td>") | Out-Null
            $reportBodyString.Append($sItem.Cost) | Out-Null
            $reportBodyString.Append("</td>") | Out-Null
            $reportBodyString.Append("</tr>") | Out-Null
        }
        $reportBodyString.Append('<tr style="background-color: #f2f2f2;">') | Out-Null
        $reportBodyString.Append("<td><b>Total cost ($billingCurrency)</b></td>") | Out-Null
        $reportBodyString.Append("<td><b>") | Out-Null
        $reportBodyString.Append([decimal]($subItem.Services | Measure-Object -Property "Cost" -Sum).Sum) | Out-Null
        $reportBodyString.Append("</b></td>") | Out-Null
        $reportBodyString.Append("</tr>") | Out-Null
        $reportBodyString.Append("</table>") | Out-Null
        #endregion Services report

        #region ResourceGroups report
        $reportBodyString.Append("<br><b>Resource group cost</b>") | Out-Null
        $reportBodyString.Append('<table class="table">') | Out-Null
        foreach ($rgItem in $subItem.ResourceGroups) {
            $reportBodyString.Append("<tr>") | Out-Null
            $reportBodyString.Append("<td>") | Out-Null
            $reportBodyString.Append($rgItem.ResourceGroup) | Out-Null
            $reportBodyString.Append("</td>") | Out-Null
            $reportBodyString.Append("<td>") | Out-Null
            $reportBodyString.Append($rgItem.Cost) | Out-Null
            $reportBodyString.Append("</td>") | Out-Null
            $reportBodyString.Append("</tr>") | Out-Null
        }
        $reportBodyString.Append('<tr style="background-color: #f2f2f2;">') | Out-Null
        $reportBodyString.Append("<td><b>Total cost ($billingCurrency)</b></td>") | Out-Null
        $reportBodyString.Append("<td><b>") | Out-Null
        $reportBodyString.Append([decimal]($subItem.ResourceGroups | Measure-Object -Property "Cost" -Sum).Sum) | Out-Null
        $reportBodyString.Append("</b></td>") | Out-Null
        $reportBodyString.Append("</tr>") | Out-Null
        $reportBodyString.Append("</table>") | Out-Null
        #endregion ResourceGroups report

        #region Locations report
        $reportBodyString.Append("<br><b>Location cost</b>") | Out-Null
        $reportBodyString.Append('<table class="table">') | Out-Null
        foreach ($lItem in $subItem.Locations) {
            $reportBodyString.Append("<tr>") | Out-Null
            $reportBodyString.Append("<td>") | Out-Null
            $reportBodyString.Append($lItem.Location) | Out-Null
            $reportBodyString.Append("</td>") | Out-Null
            $reportBodyString.Append("<td>") | Out-Null
            $reportBodyString.Append($lItem.Cost) | Out-Null
            $reportBodyString.Append("</td>") | Out-Null
            $reportBodyString.Append("</tr>") | Out-Null
        }
        $reportBodyString.Append('<tr style="background-color: #f2f2f2;">') | Out-Null
        $reportBodyString.Append("<td><b>Total cost ($billingCurrency)</b></td>") | Out-Null
        $reportBodyString.Append("<td><b>") | Out-Null
        $reportBodyString.Append([decimal]($subItem.Locations | Measure-Object -Property "Cost" -Sum).Sum) | Out-Null
        $reportBodyString.Append("</b></td>") | Out-Null
        $reportBodyString.Append("</tr>") | Out-Null
        $reportBodyString.Append("</table>") | Out-Null
        #endregion Locations report
        $reportBodyString.Append("<p>") | Out-Null
        $reportBodyString.Append("</p>") | Out-Null
        $reportBodyString.Append("</div>") | Out-Null
    }
    #endregion Detailed report

    #region HTML script
    $reportBodyString.Append('
    <script>
        var coll = document.getElementsByClassName("collapsible");
        for (var i = 0; i < coll.length; i++) {
            coll[i].addEventListener("click", function() {
                this.classList.toggle("active");
                var content = this.nextElementSibling;
                if (content.style.display === "block") {
                    content.style.display = "none";
                } else {
                    content.style.display = "block";
                }
            });
        }
    </script>
    ') | Out-Null
    #endregion HTML script
    $reportBodyString.ToString() | Out-File -FilePath $htmlReportPath
}
