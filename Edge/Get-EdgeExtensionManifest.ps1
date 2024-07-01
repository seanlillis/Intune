<#
.SYNOPSIS
    This script retrieves the Edge Extension manifest details from the Edge profile directory.
.DESCRIPTION
    This script retrieves the Edge Extension manifest details from the Edge profile directory including the extension name, version, manifest version, description, and update URL.
.NOTES
    File Name      : Get-EdgeExtensionManifest.ps1
    Author         : Sean Lillis / PSADT powered by PatchMyPC
    Version History: 1.0, 2021-09-30 - Initial script
.EXAMPLE
    Get-EdgeExtensionManifest.ps1
    Retrieves the Edge Extension manifest details from the Edge profile directory.
#>

# Get the Edge Extension manifest details
$edgeProfilePath = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default"
# Iterate through all the Edge Extension manifest files
Try {
    Write-Host "Retrieving Edge extension manifest details"
    $edgeExtensions = Get-ChildItem -Path "$edgeProfilePath\Extensions" -Directory
    $edgeExtensionManifestDetails = @()
    Foreach ($edgeExtension in $edgeExtensions) {
        $extensionId = $edgeExtension.Name
        $extensionVersions = Get-ChildItem -Path $edgeExtension.FullName -Directory
        Foreach ($extensionVersion in $extensionVersions) {
            $edgeExtensionManifestPath = "$edgeProfilePath\Extensions\$($extensionId)\$($extensionVersion)\manifest.json"
            # Get the Edge Extension manifest file content
            $edgeExtensionManifest = Get-Content -Path $edgeExtensionManifestPath -Raw | ConvertFrom-Json
            $edgeExtensionManifestDetail = [PSCustomObject]@{
                Name = $edgeExtensionManifest.name
                Version = $edgeExtensionManifest.version
                ManifestVersion = $edgeExtensionManifest.manifest_version
                Description = $edgeExtensionManifest.description
                UpdateURL = $edgeExtensionManifest.update_url
            }
            $edgeExtensionManifestDetails += $edgeExtensionManifestDetail
        }
    }
}
Catch {
    Write-Host "Failed to retrieve Edge extension manifest details: $_" -ForegroundColor Red
    Break
}
# Output the Edge Extension manifest details
$edgeExtensionManifestDetails