param(
    [string]$Ps2ExeRoot = 'E:\ps2exe',
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$rootPath = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $rootPath 'dist\CodeMateSetup-ps2exe.exe'
}

$moduleManifest = Join-Path $Ps2ExeRoot 'ps2exe\ps2exe.psd1'
if (-not (Test-Path -LiteralPath $moduleManifest)) {
    throw ('ps2exe module was not found at {0}' -f $moduleManifest)
}

$distPath = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $distPath)) {
    New-Item -ItemType Directory -Path $distPath | Out-Null
}

$inputFile = Join-Path $rootPath 'src\CodeMate.Setup.ps1'
$payloadRoots = @('src', 'config', 'docs') | ForEach-Object {
    Join-Path $rootPath $_
}

$inputFileInfo = Get-Item -LiteralPath $inputFile
$payloadFiles = @(
    foreach ($payloadRoot in $payloadRoots) {
        Get-ChildItem -LiteralPath $payloadRoot -File -Recurse | Sort-Object FullName
    }
) | Where-Object {
    $_.FullName -ne $inputFileInfo.FullName
}

$duplicateNames = @(
    $payloadFiles |
        Group-Object Name |
        Where-Object Count -gt 1 |
        Select-Object -ExpandProperty Name
)
if ($duplicateNames.Count -gt 0) {
    throw ('ps2exe embedFiles requires unique source file names. Duplicates: {0}' -f ($duplicateNames -join ', '))
}

$embedFiles = @{}
foreach ($file in $payloadFiles) {
    $relativePath = $file.FullName.Substring($rootPath.Length).TrimStart('\')
    $targetPath = '.\' + $relativePath
    $embedFiles[$targetPath] = $file.FullName
}

Import-Module $moduleManifest -Force

Invoke-ps2exe `
    -inputFile $inputFile `
    -outputFile $OutputPath `
    -embedFiles $embedFiles `
    -noConsole `
    -STA `
    -DPIAware `
    -title 'CodeMate Setup' `
    -description 'CodeMate Setup AI coding environment assistant' `
    -company 'CodeMate' `
    -product 'CodeMate Setup' `
    -version '0.1.0.0'

Write-Host ('Built {0}' -f $OutputPath)
