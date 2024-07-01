$PSDefaultParameterValues['Out-File:Encoding'] = 'utf8'

# Edge extension ID to be detected
$extensionID = ""

# ExtensionSettings Reg Key
$regKeyEdgeExtensions = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'

$installedExtensions = Get-ItemProperty -Path $regKeyEdgeExtensions -ErrorAction SilentlyContinue | Select-Object -Property "ExtensionSettings" -ExpandProperty "ExtensionSettings" -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue

If ($installedExtensions.$($extensionID)) {
    Write-Output "Installed"
    Exit 0
}
Else {
    Exit 1
}