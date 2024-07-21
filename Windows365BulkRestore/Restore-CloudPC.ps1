<#
.SYNOPSIS
    This script restores Cloud PCs that are inaccessible due to the status "ErrorResourceUnavailable" using the latest snapshot created before 19/07/2024 04:00 UTC just before the problematic Crowdstrike sensor update was released.
.DESCRIPTION
    The script retrieves the inaccessible Cloud PC report and filters on Cloud PCs with the status "ErrorResourceUnavailable".
    It then restores the Cloud PCs to the latest snapshot created before 19/07/2024 at 04:00 UTC just before the problematic Crowdstrike sensor update was released.   
.NOTES
    File Name      : Restore-CloudPC.ps1
    Author         : Sean Lillis
    Prerequisite   : PowerShell V5.1 or later
    Graph API Permissions: CloudPC.Read.All, CloudPC.ReadWrite.All
    Graph API Modules: Microsoft.Graph.Beta
    Disclaimer: This script is provided as-is and as available without warranty of any kind. The author makes no promise or guarantee that the script will be free from defects or that it will meet your specific needs or expectations. 
    The script should be tested in a non-production environment before running in production. The author is not responsible for any damages or losses caused by the use of this script.
    Your use of the script is at your own risk. You acknowledge that there are certain inherent risks in using the script, and you understand and assume each of those risks, including the risk of data loss.
    Waiver and Release: You will not hold the author responsible for any adverse or unintended consequences resulting from your use of the script, and you waive any legal or equitable rights or remedies you may have against the author relating to your use of the script.
.EXAMPLE    
    .\Restore-CloudPC.ps1
#>

#region Variables

# Number of devices with connection issues (Go to the Intune Portal -> Devices -> Overview -> Cloud PC Performance -> Devices with connection issues.)
# This number is an estimate and can be adjusted based on the number of devices with the status "ErrorResourceUnavailable" in the inaccessible Cloud PC report. 
# The script retrieves the inaccessible Cloud PC report in batches of 100 devices up to a maximum of $numberOfCloudPCsInaccessible devices.
$numberOfCloudPCsInaccessible = 1000
$testRun = $false # Set to $true to test the script without restoring the Cloud PCs
$dirReports = $env:PUBLIC + "\CloudPCReports"
# July 19, 2024 at 04:09 UTC is the date when the Crowdstrike sensor update was released that causes the BSOD. Here we set 04:00 as the latest restore point.
$restorePointDateTime = [datetime]::Parse("2024-07-19T04:00:00.000Z")

#endregion 

#region Functions

#Function to convert Graph API Json report in to a PowerShell Custom Object
Function Get-MgDeviceReportObject {
    [CmdletBinding()]
    Param (  
        [Parameter(Mandatory=$true)]
        [Array]$JsonFile
    )

    $reportData = Get-Content -Path $jsonFile -ErrorAction Stop | ConvertFrom-Json
    $reportColumns = $reportData  | Select -ExpandProperty "Schema" | Select -ExpandProperty "Column"
    $reportArray = @()

    Foreach ($value in $reportData.Values) {
        $data = [PSCustomObject]@{}

        For ($i=0; $i -le $($value.Count -1); $i++) {    
            $data | Add-Member -MemberType NoteProperty -Name $($reportColumns[$i]) -Value $($value[$i])
        }
        $reportArray += $data
    }
    Return $reportArray
}#end function

#endregion

#region Script Body

# Connect to MgGraph
$null = Connect-MgGraph

# Retrieve the inaccessible Cloud PC report in batches of 100 devices
$w365InaccessibleReportData = @()
Write-Host "Retrieving the inaccessible Cloud PC report, downloaded in batches of 100 devices up to a maximum of $numberOfCloudPCsInaccessible devices"
For ($i = 0; $i -lt $numberOfCloudPCsInaccessible; $i += 100) {
    $params = @{
        skip = $i
        top = 100
        search = ""
        filter = ""
        select = @(
        "cloudPcId"
        "userPrincipalName"
        "cloudPcName"
        "provisioningStatus"
        "deviceHealthStatus"
        "deviceHealthStatusDateTime"
        "systemStatus"
        "systemStatusDateTime"
        "region"
        "recentConnectionError"
        "lastConnectionFailureDatetime"
        "lastEventDatetime"
        )
        orderBy = @(
        "cloudPcName"
        )
    }
       
    $jsonw365InaccessibleReport = "VirtualEndpointReportInaccessibleCloudPcReport.json"
    Try {
        $null = Get-MgBetaDeviceManagementVirtualEndpointReportInaccessibleCloudPcReport -BodyParameter $params -OutFile "$dirReports\$jsonw365InaccessibleReport" -PassThru -ErrorAction Stop 
        $w365InaccessibleReportData += Get-MgDeviceReportObject -JsonFile "$dirReports\$jsonw365InaccessibleReport" 
    }
    Catch {
        Write-Host "Error retrieving the inaccessible Cloud PC report:" $PSItem.Exception $PSItem.Exception.Code
    }
}

# Get all devices with the status "ErrorResourceUnavailable"
$cloudPCsToRestore = $w365InaccessibleReportData | Where-Object { $_.deviceHealthStatus -contains "ErrorResourceUnavailable"}
Write-Host "Windows 365 devices with status ErrorResourceUnavailable: [$($w365InaccessibleReportData.Count)]"
If ($cloudPCsToRestore.Count -gt 0) {
    Write-Host "Restoring inaccessible Cloud PCs using the latest snapshot created before $restorePointDateTime"
    $restoreJobs = @()
    $cloudPCsProcessed = 0
    Foreach ($cloudPC in $cloudPCsToRestore) {
        Try {
            $cloudPCsProcessed++
            # Get the latest snapshots filtering on those created before $restorePointDateTime
            Write-Host "Getting snapshots for Cloud PC [$($cloudPC.cloudPcName)] [$($cloudPC.cloudPcId)]" 
            $snapshots = Get-MgBetaDeviceManagementVirtualEndpointSnapshot -Filter "cloudPcId eq '$($cloudPC.cloudPcId)'" | Sort-Object -Property createdDateTime -Descending            
            # Add a member to the snapshot to store the created date time as datetime object
            Foreach ($snapshot in $snapshots) {
                $null = $snapshot | Add-Member -MemberType NoteProperty -Name "CreatedDateTimeValue" -Value $([datetime]::ParseExact($snapshot.createdDateTime, "MM/dd/yyyy HH:mm:ss", $null)) -Force
            }
            # Get the latest snapshot created before the specified restore point date time in $restorePointDateTime
            $snapshotForRestore = $snapshots | Where-Object { $_.createdDateTimeValue -lt $restorePointDateTime } | Select -First 1            
            If ($snapshotForRestore -eq $null) {
                Write-Host "No snapshots found for Cloud PC [$($cloudPC.cloudPcName)] [$($cloudPC.cloudPcId)] created before $restorePointDateTime"
            }
            Else {
                # Restore the Cloud PC to the selected snapshot
                If ($testRun -eq $false) {
                    Write-Host "Restoring Cloud PC [$($cloudPC.cloudPcName)] to snapshot created on [$($snapshotForRestore.createdDateTimeValue)]"
                    $params = @{
                        cloudPcSnapshotId = $($snapshotForRestore.id)
                    }
                    $null = Restore-MgBetaDeviceManagementVirtualEndpointCloudPc -CloudPcId $cloudPC.cloudPcId -BodyParameter $params -ErrorAction Stop -confirm:$false
                    Write-Host "Cloud PC [$($cloudPC.cloudPcName)] restoration started. Check the status in the Windows 365 portal."
                    $cloudPC | Add-Member -MemberType NoteProperty -Name "RestorationStatus" -Value "Started"
                }
            Else {
                    Write-Host "Test run: Restoring Cloud PC [$($cloudPC.cloudPcName)] to snapshot created on [$($snapshotForRestore.createdDateTimeValue)]"
                    $cloudPC | Add-Member -MemberType NoteProperty -Name "RestorationStatus" -Value "NotStarted"
                }
                $cloudPC | Add-Member -MemberType NoteProperty -Name "SnapshotCreatedDateTime" -Value $($snapshotForRestore.createdDateTimeValue)
                $cloudPC | Add-Member -MemberType NoteProperty -Name "SnapshotId" -Value $snapshotForRestore.id                
            }
        }
        Catch {
            Write-Host "Error restoring Cloud PC [$($cloudPC.cloudPcName)]" $PSItem.Exception $PSItem.Exception.Code
            $cloudPC | Add-Member -MemberType NoteProperty -Name "RestorationStatus" -Value "NotStarted"
        }
    }
}
Else {
    Write-Host "No Cloud PCs to restore."
}

# Report on the Cloud PCs restored
$cloudPCsRestored = $cloudPCsToRestore | Where-Object { $_.RestorationStatus -eq "Started" }
Write-Host "Cloud PCs restored: [$($cloudPCsRestored.Count) / $($cloudPCsToRestore.Count)]"
$date = $(Get-Date -Format "yyyyMMdd_HHmmss")
$csvReportPath = Join-Path $dirReports "CloudPCsToRestore_$date.csv"
$cloudPCsToRestore | Select * | Export-Csv -Path $csvReportPath -NoTypeInformation -Force
Write-Host "Report saved to: $csvReportPath"
Write-Host "Script completed. Check the Cloud PC restoration status in the Windows 365 portal."
#endregion