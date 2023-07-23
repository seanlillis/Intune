<#
.SYNOPSIS
Set the Primary User of an Intune device based on Azure AD SignIns log
 
.DESCRIPTION
This script gets a list of: 
    1. Intune devices and current Primary Users from Log Analytics
    2. Azure AD Sign in Logs from Log Analytics
It compares the two data sources to identify the most frequently logged in user over a specified time period with configurable parameters and exclusion options.
If the most frequently signed in user is not the current Primary User, then the script sets the Primary User of the device in Intune via Graph API accordingly.
The changes made are written back to a custom Log Analytics table so there is an audit trail of any changes made.
The script requires Log Analytics to be configured for Intune and Azure AD.
    
This script is licensed under the MIT License - Copyright (c) 2023 Sean Lillis

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
      
.EXAMPLE
   .\Update-IntuneDevicePrimaryUser.ps1
 
.NOTES
    Version: 1.0 
    Author: Sean Lillis 
    Contact: @seanels
    
.INPUTS

None
You cannot pipe objects to this script.

.OUTPUTS

This script generates Out-GridView output if run manually and writes output to Log Analytics if enabled.

.LINK

https//endpointcode.com
#>

#region ---------------------------------------------------[Module Requirements]-----------------------------------------------
#
#Requires -Modules Az.Accounts
#Requires -Modules Az.OperationalInsights
#Requires -Modules Microsoft.Graph.Authentication
#Requires -Modules Microsoft.Graph.DeviceManagement
#
#endregion

#region ---------------------------------------------------[Configurable Variabless]------------------------------------

# Parameters
$testRun = $true # If set to true, the script will perform a dry run and will not make any changes to the Primary User attribute.
$intuneDeviceDays = 7 # Specify the number of days of Intune Log Analytics to review
$signInDays = 7 # Specify the number of days of Azure AD Sign In Logs to review
$minDeviceAgeDays = 2 # Specify the minimum number of days a device should be in Intune before it is included in scope
$minUserSignIns = 3 # Specify the minimum number of times a user should have signed in to the device within the specified timeframe in order to be considered as the primary user

# Exclusions
$excludeDevicesWithNoPrimaryUser = $false # Specify whether to exclude devices that have no primary user currently assigned, e.g. shared devices
$deviceNameExclusions = "","" # Specify a comma separated list of device names that you wish to exclude (if any). The KQL query will perform a "contains" match, e.g. "Kiosk"
$deviceModelExclusions = "","" # Specify a comma separated list of device models that you wish to exclude (if any). The KQL query will perform a "contains" match, e.g. "Surface Hub"
$userNameExistingExclusions = "","" # Specify a comma separated list of existing Primary users whose devices you wish to exclude (if any). The KQL query will perform a "contains match", e.g. "Robot"
$userNameTargetExclusions = "","" # Specify a comma separated list of target user names that you do not wish to assign as primary user on any device (if any). The KQL query will perform a "contains match", e.g. "DEMUser01", "DEMUser02"

# Log Analytics Workspace details for Intune
$subscriptionIDIntune = '' # Subscription ID for Intune Log Analytics
$workspaceResourceGroupNameIntune = '' # Resource Group Name for Intune Log Analytics
$workspaceNameIntune = '' # Workspace Name for Intune Log Analytics

# Log Analytics Workspace details for Azure AD
$subscriptionIDAzureAD = '' # Subscription ID for Azure AD Log Analytics
$workspaceResourceGroupNameAzureAD = '' # Resource Group Name for Azure AD Log Analytics
$workspaceNameAzureAD = '' # Workspace Name for Azure AD Log Analytics

# Log Analytics Workspace used to capture output
$outputToLogAnalytics = $true
$logAnalyticsLogName = "" # Name of the custom Log Analytics log table that will be used to store a log of changes performed by the script
$tenantID = ''
$customerID = '' # Replace with your Log Analytics Workspace ID
$sharedKey = ''  # Replace with your Primary Key for the Log Analytics Workspace

    If ("AzureAutomation/" -eq $env:AZUREPS_HOST_ENVIRONMENT) {
        $AzureAutomation = $true
        $customerId = Get-AutomationVariable 'customerID' 
        $sharedKey = Get-AutomationVariable 'sharedKey'
        $tenantID = Get-AutomationVariable 'tenantid'
    }
    Else {
        $AzureAutomation = $false
    }

#endregion

#region ---------------------------------------------------[Static Variables]------------------------------------------------------
$RequiredScopes = ("DeviceManagementManagedDevices.ReadWrite.All")
    
$date = (Get-Date)
# You can use an optional field to specify the timestamp from the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time
# DO NOT DELETE THIS VARIABLE. Recommened keep this blank. 
$timeStampField = ""
$primaryUserUpdates = $null
$PrimaryUserUpdatesCount = 0

#endregion

#region ---------------------------------------------------[Functions]------------------------------------
# Variables

Function Invoke-LogAnalyticsQuery {

<#
.SYNOPSIS
Function to run a Log Analytics Query and retrieve the output
.DESCRIPTION
Function to run a Log Analytics Query and retrieve the output
.EXAMPLE
Invoke-LogAnalyticsQuery
.NOTES
NAME: Invoke-LogAnalyticsQuery
#>

[cmdletbinding()]

Param
(
[parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$tenantID,
[parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$subscriptionID,
[parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$workspaceResourceGroupName,
[parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$workspaceName,
[parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
[string]$query 
)

    Try { 
        $null = Set-AzContext -Tenant $tenantID -SubscriptionID $subscriptionID
        $workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $workspaceResourceGroupName -Name $workspaceName
    }
    Catch {
        Write-Error "Get-AzOperationalInsightsWorkspace failed with error: $_"
    }
    Try {
        $queryResults = (Invoke-AzOperationalInsightsQuery -Workspace $workspace -Query $query).Results
        Return $queryResults
    }
    Catch {
        Write-Error "Invoke-AzOperationalInsightsQuery failed with error: $_"
    }
}

Function Set-IntuneDevicePrimaryUser {

<#
.SYNOPSIS
This updates the Intune device primary user
.DESCRIPTION
This updates the Intune device primary user
.EXAMPLE
Set-IntuneDevicePrimaryUser
.NOTES
NAME: Set-IntuneDevicePrimaryUser
#>

[cmdletbinding()]

param
(
[parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
$IntuneDeviceId,
[parameter(Mandatory=$true)]
[ValidateNotNullOrEmpty()]
$UserId
)

    $graphApiVersion = "beta"
    $Resource = "deviceManagement/managedDevices('$IntuneDeviceId')/users/`$ref"

    Try {
        
        $uri = "https://graph.microsoft.com/$graphApiVersion/$($Resource)"

        $userUri = "https://graph.microsoft.com/$graphApiVersion/users/" + "$userID"

        $id = "@odata.id"
        $JSON = @{ $id="$userUri" } | ConvertTo-Json -Compress
        $result = Invoke-MgGraphRequest -Uri $uri -Method POST -body $JSON -ContentType "application/json"
        Return "Success"
    } 
    Catch { 
        Write-Error "Request to $Uri failed with error: $_"
        Return "Error"
    }

}

# Function to send data to log analytics
Function Send-LogAnalyticsData() {
    <#
   .SYNOPSIS
       Send log data to Azure Monitor by using the HTTP Data Collector API
   
   .DESCRIPTION
       Send log data to Azure Monitor by using the HTTP Data Collector API
   
   .NOTES
       Author:      Jan Ketil Skanke
       Contact:     @JankeSkanke
       Created:     2022-01-14
       Updated:     2022-01-14
   
       Version history:
       1.0.0 - (2022-01-14) Function created
   #>
   param(
       [string]$sharedKey,
       [array]$body, 
       [string]$logType,
       [string]$customerId
   )
   #Defining method and datatypes
   $method = "POST"
   $contentType = "application/json"
   $resource = "/api/logs"
   $date = [DateTime]::UtcNow.ToString("r")
   $contentLength = $body.Length
   #Construct authorization signature
   $xHeaders = "x-ms-date:" + $date
   $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
   $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
   $keyBytes = [Convert]::FromBase64String($sharedKey)
   $sha256 = New-Object System.Security.Cryptography.HMACSHA256
   $sha256.Key = $keyBytes
   $calculatedHash = $sha256.ComputeHash($bytesToHash)
   $encodedHash = [Convert]::ToBase64String($calculatedHash)
   $signature = 'SharedKey {0}:{1}' -f $customerId, $encodedHash
   
   #Construct uri 
   $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
   
   #validate that payload data does not exceed limits
   if ($body.Length -gt (31.9 *1024*1024))
   {
       throw("Upload payload is too big and exceed the 32Mb limit for a single upload. Please reduce the payload size. Current payload size is: " + ($body.Length/1024/1024).ToString("#.#") + "Mb")
   }
   $payloadsize = ("Upload payload size is " + ($body.Length/1024).ToString("#.#") + "Kb ")
   
   #Create authorization Header
   $headers = @{
       "Authorization"        = $signature;
       "Log-Type"             = $logType;
       "x-ms-date"            = $date;
       "time-generated-field" = $TimeStampField;
   }
   #Sending data to log analytics 
   Write-Host "Sending data to log analytics."
   $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
   $statusmessage = "$($response.StatusCode) : $($payloadsize)"
   
    #Report back status
    $date = Get-Date -Format "dd-MM HH:mm"
    $OutputMessage = "Date:$date "

    if ($statusmessage -match "200 :") {
        $OutputMessage = $OutPutMessage + "$logType:OK " + $statusmessage
    }
    else {
        $OutputMessage = $OutPutMessage + "$logType:Fail "
    }

    Write-Output $OutputMessage
}#end function


#endregion

#region ---------------------------------------------------[Main Script]------------------------------------

Try {
    "Authenticating to Azure"
    # Azure Automation
    If ($AzureAutomation) 
    {
        Write-Output "Setting Azure Context"
        # Ensures you do not inherit an AzContext in your runbook
        Disable-AzContextAutosave -Scope Process
        # Connect to Azure with system-assigned managed identity
        $AzureContext = (Connect-AzAccount -Identity).context
        # set and store context
        $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
        # Pass context object - even though the context had just been set
        # This is the step that guarantees the context will not be switched.

        Write-Output "Authenticating to Graph"
        # Get Microsoft Graph AccessToken
        Try {
            $resourceURL = "https://graph.microsoft.com/" 
            $response = [System.Text.Encoding]::Default.GetString((Invoke-WebRequest -UseBasicParsing -Uri "$($env:IDENTITY_ENDPOINT)?resource=$resourceURL" -Method 'GET' -Headers @{'X-IDENTITY-HEADER' = "$env:IDENTITY_HEADER"; 'Metadata' = 'True'}).RawContentStream.ToArray()) | ConvertFrom-Json 
            $accessToken = $response.access_token
            Write-verbose "Success getting an Access Token to Graph"
        }
        Catch {
            Write-Error "Failed getting an Access Token to Graph, with error: $_"
        }
        # Connect to the Microsoft Graph using the AccessToken
        Try {
            Select-MgProfile beta
            Connect-MgGraph -AccessToken $accessToken
            Write-Verbose "Success to connect to Graph"
        }
        Catch {
            Write-Error "Failed to connect to Graph, with error: $_"
        }       

    }
    Else {
        $null = Connect-AzAccount
        $null = Connect-MgGraph -Scope $RequiredScopes
    }
}
Catch {
    Write-Error -Message $_.Exception
    Throw $_.Exception
}
 
$ErrorActionPreference = 'stop'

# Build the KQL query
$deviceNameExclusionKustoString = ""
Foreach ($deviceNameExclusion in $deviceNameExclusions) {
    If (!([string]::IsNullOrWhiteSpace($deviceNameExclusion))) {
        If ([string]::IsNullOrWhiteSpace($deviceNameExclusionKustoString)) {
            $deviceNameExclusionKustoString += "| where DeviceName !contains '$($deviceNameExclusion.Trim())'"
        }
        Else {
            $deviceNameExclusionKustoString += " and DeviceName !contains '$($deviceNameExclusion.Trim())'"
        }
    }
}

$deviceModelExclusionKustoString = ""
Foreach ($deviceModelExclusion in $deviceModelExclusions) {
    If (!([string]::IsNullOrWhiteSpace($deviceModelExclusion))) {
        If ([string]::IsNullOrWhiteSpace($deviceModelExclusionKustoString)) {
            $deviceModelExclusionKustoString += "| where Model !contains '$($deviceModelExclusion.Trim())'"
        }
        Else {
            $deviceModelExclusionKustoString += " and Model !contains '$($deviceModelExclusion.Trim())'"
        }
    }
}

$userNameExistingExclusionKustoString = ""
Foreach ($userNameExistingExclusion in $userNameExistingExclusions) {
    If (!([string]::IsNullOrWhiteSpace($userNameExistingExclusion))) {
        If ([string]::IsNullOrWhiteSpace($userNameExistingExclusionKustoString)) {
            $userNameExistingExclusionKustoString += "| where UPN !contains '$($userNameExistingExclusion.Trim())'"
            }
        Else {
            $userNameExistingExclusionKustoString += " and UPN !contains '$($userNameExistingExclusion.Trim())'"
        }
    }
}

$userNameTargetExclusionKustoString = ""
Foreach ($userNameTargetExclusion in $userNameTargetExclusions) {
    If (!([string]::IsNullOrWhiteSpace($userNameTargetExclusion))) {
        If ([string]::IsNullOrWhiteSpace($userNameTargetExclusionKustoString)) {
            $userNameTargetExclusionKustoString += "| where UserPrincipalName !contains '$($userNameTargetExclusion.Trim())'"
        }
        Else {
            $userNameTargetExclusionKustoString += " and UserPrincipalName !contains '$($userNameTargetExclusion.Trim())'"
        }
    }
}

If ($excludeDevicesWithNoPrimaryUser) {
    $excludeDevicesWithNoPrimaryUserKustoString = "| where isnotempty(UPN)"
}

$kqlQuery = "workspace('/subscriptions/$subscriptionIDIntune/resourcegroups/$workspaceResourceGroupNameIntune/providers/microsoft.operationalinsights/workspaces/$workspaceNameIntune').IntuneDevices
| where TimeGenerated >= ago($($intuneDeviceDays)d) and OS contains 'Windows' and Ownership == 'Corporate' and ManagedBy == 'Intune'
| where todatetime(CreatedDate) <= ago($($minDeviceAgeDays)d)
$deviceNameExclusionKustoString
$deviceModelExclusionKustoString
$userNameExistingExclusionKustoString
$excludeDevicesWithNoPrimaryUserKustoString
| summarize arg_max(TimeGenerated, *) by DeviceId
| extend ExistingPrimaryUser = UPN, ExistingPrimaryUserID = PrimaryUser, AzureADDeviceID = ReferenceId, IntuneDeviceID = DeviceId
| project DeviceName, IntuneDeviceID, AzureADDeviceID, ExistingPrimaryUser, ExistingPrimaryUserID
| join kind=inner (workspace('/subscriptions/$subscriptionIDAzureAD/resourcegroups/$workspaceResourceGroupNameAzureAD/providers/microsoft.operationalinsights/workspaces/$workspaceNameAzureAD').SigninLogs 
| where TimeGenerated >= ago($($signInDays)d)
| where AppDisplayName == 'Windows Sign In' and UserType == 'Member' 
$userNameTargetExclusionKustoString
| extend DeviceName = tostring(DeviceDetail.displayName),DeviceId = tostring(DeviceDetail.deviceId)
| summarize UserSignInCount = count(UserId) by DeviceId,DeviceName,UserPrincipalName,UserId // Count how many times each user has logged in to a device
| where UserSignInCount >= $($minUserSignIns)
| summarize arg_max(UserSignInCount,*) by DeviceId,DeviceName // Get the top user with most sign ins on the device
| extend AzureADDeviceID = DeviceId, NewPrimaryUser = UserPrincipalName, NewPrimaryUserID = UserId
| project DeviceName,AzureADDeviceID,NewPrimaryUser,NewPrimaryUserID,UserSignInCount)
on `$left.AzureADDeviceID==`$right.AzureADDeviceID // Join the tables on the Azure AD Device ID
| where isnotempty(NewPrimaryUser)
| where ExistingPrimaryUserID !~ NewPrimaryUserID 
| project DeviceName, IntuneDeviceID, AzureADDeviceID, ExistingPrimaryUser, ExistingPrimaryUserID, NewPrimaryUser, NewPrimaryUserID, UserSignInCount // Return the IntuneDeviceID required to update the Primary user in Graph" -creplace '(?m)^\s*\r?\n','' # Trim any blank lines where the exclusion variables are empty


Write-Output "Running Log Analytics Query to retrieve Intune devices and existing primary users and compare with Azure AD Sign In Logs to identify the user most frequently signed in to each device with KQL Query: [$kqlQuery]"
[Array]$PrimaryUserUpdates = Invoke-LogAnalyticsQuery -tenantId $tenantID -subscriptionID $subscriptionIDIntune -workspaceResourceGroupName $workspaceResourceGroupNameIntune -workspaceName $workspaceNameIntune -query $kqlQuery

If ($primaryUserUpdates) {
    [Int]$primaryUserUpdatesCount = @($PrimaryUserUpdates).Count
}
Else {
    [Int]$primaryUserUpdatesCount = 0
}

$ErrorActionPreference = 'continue'

Write-Output "Total Primary User updates required: [$($PrimaryUserUpdatesCount)]"

# Process the primary user changes
If ($primaryUserUpdatesCount -gt 0) {
    If ($testRun) {
        Write-Output "This is a test run. No changes will be performed via Graph API." 
    }
    Else {
        Write-Output "Processing Primary User changes using Graph." 
        $i = 0
        Foreach ($update in $PrimaryUserUpdates) {
            $i++   
            If ($AzureAutomation) {
                Write-Output "Processing Intune device [$($update.DeviceName)] [$($i)/$($primarUserUpdatesCount)]. Overall status6: [$(($i/$($PrimaryUserUpdatesCount)*100))%] completed"
            }
            Else {
                Write-Progress -Activity "Processing Intune device $($update.DeviceName)" -Status "$i/$($PrimaryUserUpdatesCount)" -PercentComplete ($i/$($PrimaryUserUpdatesCount)*100)
            }  

            Write-Output "[$($update.DeviceName)] [$($update.AzureADDeviceID)]: Replacing Primary User [$($update.ExistingPrimaryUser)] with [$($update.NewPrimaryUser)]"
            $result = Set-IntuneDevicePrimaryUser -IntuneDeviceId $update.IntuneDeviceID -UserId $update.NewPrimaryUserID
            If ($result -match "Success") {
                $update | Add-Member -NotePropertyName "Result" -NotePropertyValue "Success"
            }
            Else {
                $update | Add-Member -NotePropertyName "Result" -NotePropertyValue "Error"
            }
        }  
        If ($outputToLogAnalytics) {        
            Write-Output "Sending the Primary User changes to Log Analytics table: [$logAnalyticsLogName]"
            $jsonOutput = $PrimaryUserUpdates | ConvertTo-Json
            Send-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($jsonOutput)) -logType $logAnalyticsLogName
        }
    }
    If (!($AzureAutomation)) {
        $PrimaryUserUpdates | OGV
    }
}

#endregion