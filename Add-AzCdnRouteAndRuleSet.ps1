# Link to work with commands https://docs.microsoft.com/en-us/powershell/module/az.cdn
$fdDomainDataPath = "<path>\fd-domains.csv"
$fdDomainData = Import-Csv -Path $fdDomainDataPath
$fdDomainList = New-Object -TypeName "System.Collections.ArrayList"
$fdDomainData | ForEach-Object {
    $fdObj = [PSCustomObject]@{
        Dalias = ($_.dalias).Split('.')[0].Replace('-','')
        Cookie = $_.cookie
        Domain = $_.dalias
    }
    $fdDomainList.Add($fdObj) | Out-Null
}
$cdnProfile = "<cdn profile name>"
$cdnRg = "<resource group name>"
$cdnSubscription = "<subscription id>"
$azToken = (Get-AzAccessToken).Token
$fdRequestHeader = @{
    "authorization" = "Bearer $azToken"
}
$fdApiRequest = @{
    Method      = "PUT"
    Uri         = ""
    Headers     = $fdRequestHeader
    ContentType = "application/json"
    Body        = ""
}

foreach ($fdItem in $fdDomainList) {
    # Create rule set
    $ruleSetName = "Editor" + $fdItem.Dalias
    New-AzFrontDoorCdnRuleSet -ProfileName $cdnProfile -ResourceGroupName $cdnRg -RuleSetName $ruleSetName

    # Create rule in rule set
    $ruleName = $fdItem.Dalias
    $ruletUri = "https://management.azure.com/subscriptions/" + $cdnSubscription + "/resourceGroups/" + $cdnRg + "/providers/Microsoft.Cdn/profiles/" + $cdnProfile + "/ruleSets/" + $ruleSetName + "/rules/" + $ruleName + "?api-version=2021-06-01"
    $fdApiRequest.Uri =  $ruletUri
    $ruleBody = @{
        "properties" = @{
            "order" = 0
            "conditions" = @(
                @{
                    "name" = "Cookies"
                    "parameters" = @{
                        "typeName" = "DeliveryRuleCookiesConditionParameters"
                        "operator" = "Any"
                        "selector" = $fdItem.Cookie
                        "negateCondition" = $false
                        "matchValues" = @()
                        "transforms" = @()
                    }
                }
            )
            "actions" = @(
                @{
                    "name" = "RouteConfigurationOverride"
                    "parameters" = @{
                        "typeName" = "DeliveryRuleRouteConfigurationOverrideActionParameters"
                        "cacheConfiguration" = $null
                        "originGroupOverride" = $null
                    }
                }
            )
        }
    }
    $ruleJsonBody = $ruleBody | ConvertTo-Json -Depth 5
    $fdApiRequest.Body = $ruleJsonBody
    $fdRequestContent = Invoke-WebRequest @fdApiRequest

    if ($fdRequestContent.StatusCode -ne 201 ) {
        Write-Host "WARNING - Failed to add rules to rule set $ruleSetName"
        exit
    }
    else {
        Write-Host "INFORMATION - Rule added to rule set $ruleSetName"
    }
    
    $fdApiRequest.Uri = ""
    $fdApiRequest.Body = ""
    $fdRequestContent = $null

    # Create route
    $endpointName = "<endpoint name>"
    $routeName = "<route name>" + $fdItem.Dalias
    $routeUri = "https://management.azure.com/subscriptions/" + $cdnSubscription + "/resourceGroups/" + $cdnRg + "/providers/Microsoft.Cdn/profiles/" + $cdnProfile + "/afdEndpoints/" + $endpointName + "/routes/" + $routeName + "?api-version=2021-06-01"
    $fdApiRequest.Uri = $routeUri
    $customDomain = $fdItem.Domain.Replace('.', '-')
    $routeBody = @{
        "properties" = @{
            "customDomains" = @(
                @{
                    "id" = "/subscriptions/<subscription id>/resourcegroups/<reource group name>/providers/Microsoft.Cdn/profiles/<profile name>/customdomains/" + $customDomain
                }
            )
            "originGroup" = @{
                "id" = "/subscriptions/<subscription id>/resourcegroups/<reource group name>/providers/Microsoft.Cdn/profiles/<profile name>/originGroups/<group name>"
            }
            "originPath" = $null
            "ruleSets" = @(
                @{
                    "id" = "/subscriptions/<subscription id>/resourcegroups/<reource group name>/providers/Microsoft.Cdn/profiles/<profile name>/rulesets/" + $ruleSetName
                }
                @{
                    "id" = "/subscriptions/<subscription id>/resourcegroups/<reource group name>/providers/Microsoft.Cdn/profiles/<profile name>/rulesets/ExcludeFromCDN"
                }
            )
            "supportedProtocols" = @(
                "Https"
                "Http"
            )
            "patternsToMatch" = @(
                "/*"
            )
            "cacheConfiguration" = @{
                "compressionSettings" = @{
                    "contentTypesToCompress" = @(
                        "application/eot"
                        "application/font"
                        "application/font-sfnt"
                        "application/javascript"
                        "application/json"
                        "application/opentype"
                        "application/otf"
                        "application/pkcs7-mime"
                        "application/truetype"
                        "application/ttf"
                        "application/vnd.ms-fontobject"
                        "application/xhtml+xml"
                        "application/xml"
                        "application/xml+rss"
                        "application/x-font-opentype"
                        "application/x-font-truetype"
                        "application/x-font-ttf"
                        "application/x-httpd-cgi"
                        "application/x-javascript"
                        "application/x-mpegurl"
                        "application/x-opentype"
                        "application/x-otf"
                        "application/x-perl"
                        "application/x-ttf"
                        "font/eot"
                        "font/ttf"
                        "font/otf"
                        "font/opentype"
                        "image/svg+xml"
                        "text/css"
                        "text/csv"
                        "text/html"
                        "text/javascript"
                        "text/js"
                        "text/plain"
                        "text/richtext"
                        "text/tab-separated-values"
                        "text/xml"
                        "text/x-script"
                        "text/x-component"
                        "text/x-java-source"
                    )
                    "isCompressionEnabled" = $true
                }
                "queryStringCachingBehavior" = "IgnoreQueryString"
                "queryParameters" = $null
            }
            "forwardingProtocol" = "HttpOnly"
            "linkToDefaultDomain" = "Disabled"
            "httpsRedirect" = "Enabled"
            "enabledState" = "Enabled"
        }
    }
    $routeJsonBody = $routeBody | ConvertTo-Json -Depth 5
    $fdApiRequest.Body = $routeJsonBody
    $fdRequestContent = Invoke-WebRequest @fdApiRequest

    if ($fdRequestContent.StatusCode -ne 201 ) {
        Write-Host "WARNING - Failed to create route $routeName"
        exit
    }
    else {
        Write-Host "INFORMATION - Route $routeName created"
    }

    $fdApiRequest.Uri = ""
    $fdApiRequest.Body = ""
    $fdRequestContent = $null
}