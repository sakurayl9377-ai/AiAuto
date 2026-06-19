param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [Parameter(Mandatory = $true)][string]$ApiKey,
    [string]$Model,
    [string]$ProviderId = 'custom',
    [string]$OutputPath,
    [switch]$OpenDeepLink
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\CodeMate.CCSwitch.psm1'
Import-Module $modulePath -Force

$export = New-CodeMateCCSwitchExport -Name $Name -BaseUrl $BaseUrl -ApiKey $ApiKey -Model $Model -ProviderId $ProviderId

Write-Host ''
Write-Host 'CodeMate Setup - CC Switch Profile' -ForegroundColor Cyan
Write-Host ''
Write-Host $export.RedactedProfileJson
Write-Host ''
Write-Host 'Deep Link:'
Write-Host $export.DeepLink

if ($OutputPath) {
    Export-CodeMateCCSwitchProfile -Profile $export.Profile -Path $OutputPath | Out-Null
    Write-Host ''
    Write-Host ('Profile exported: {0}' -f (Resolve-Path -LiteralPath $OutputPath))
}

if ($OpenDeepLink) {
    Start-Process $export.DeepLink
}

