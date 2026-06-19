param(
    [string]$ProviderId = 'custom',
    [string]$BaseUrl,
    [string]$ApiKey,
    [string]$Model,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\CodeMate.Provider.psm1'
Import-Module $modulePath -Force

$result = Test-CodeMateProviderConnection -ProviderId $ProviderId -BaseUrl $BaseUrl -ApiKey $ApiKey -Model $Model

if ($Json) {
    $result | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
Write-Host 'CodeMate Setup - Provider Connection Test' -ForegroundColor Cyan
Write-Host ('Success: {0}' -f $result.Success)
Write-Host ('Message: {0}' -f $result.Message)
Write-Host ('Base URL: {0}' -f $result.BaseUrl)
Write-Host ('Model: {0}' -f $result.SelectedModel)
Write-Host ('Latency: {0} ms' -f $result.LatencyMs)

if ($result.Models.Count -gt 0) {
    Write-Host ''
    Write-Host 'Models:'
    $result.Models | ForEach-Object { Write-Host ('  - {0}' -f $_) }
}

if ($result.Error) {
    Write-Host ''
    Write-Host ('Error: {0}' -f $result.Error) -ForegroundColor Yellow
}

