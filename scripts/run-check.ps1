param(
    [switch]$Json,
    [string]$ExportPath
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '..\src\CodeMate.Health.psm1'
Import-Module $modulePath -Force

$report = Get-CodeMateHealthReport

if ($ExportPath) {
    Export-CodeMateHealthReport -Report $report -Path $ExportPath | Out-Null
}

if ($Json) {
    $report | ConvertTo-Json -Depth 8
    return
}

Write-Host ''
Write-Host 'CodeMate Setup - Pre-install Environment Check' -ForegroundColor Cyan
Write-Host ('Generated: {0}' -f $report.GeneratedAt)
Write-Host ''

foreach ($check in $report.Checks) {
    $color = switch ($check.Status) {
        'Pass' { 'Green' }
        'Warn' { 'Yellow' }
        'Fail' { 'Red' }
        default { 'Gray' }
    }

    Write-Host ('[{0}] {1}' -f $check.Status.ToUpperInvariant(), $check.Name) -ForegroundColor $color
    Write-Host ('      {0}' -f $check.Message)

    if ($check.Detected) {
        Write-Host ('      Detected: {0}' -f $check.Detected)
    }

    if ($check.RepairAction) {
        Write-Host ('      Repair: {0}' -f $check.RepairAction.Label) -ForegroundColor DarkCyan
    }
}

Write-Host ''
Write-Host ('Summary: {0} pass, {1} warning, {2} failed' -f $report.Summary.Pass, $report.Summary.Warn, $report.Summary.Fail)

if ($ExportPath) {
    Write-Host ('Report exported: {0}' -f (Resolve-Path -LiteralPath $ExportPath))
}

