param(
    [Parameter(Mandatory = $true)][string]$LicenseServer,
    [Parameter(Mandatory = $true)][string]$LicenseCode,
    [string]$Email
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\CodeMate.License.psm1'
Import-Module $modulePath -Force

$result = Activate-CodeMateLicense -LicenseServer $LicenseServer -LicenseCode $LicenseCode -Email $Email

Write-Host ''
Write-Host 'CodeMate Setup - License Activation' -ForegroundColor Cyan
Write-Host ('Success: {0}' -f $result.Success)
Write-Host ('Message: {0}' -f $result.Message)

if ($result.Success) {
    Write-Host ('Plan: {0}' -f $result.License.plan)
    Write-Host ('Status: {0}' -f $result.License.status)
    Write-Host ('Saved: {0}' -f $result.Path)
}

