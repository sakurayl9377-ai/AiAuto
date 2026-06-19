$ErrorActionPreference = 'Stop'

$rootPath = Split-Path -Parent $PSScriptRoot
$distPath = Join-Path $rootPath 'dist'
$workPath = Join-Path $rootPath '.build'
$payloadPath = Join-Path $workPath 'codemate-payload.zip'
$sourcePath = Join-Path $workPath 'CodeMateSetup.Launcher.cs'
$exePath = Join-Path $distPath 'CodeMateSetup.exe'

function New-DirectoryIfMissing {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-CodeMateCSharpCompiler {
    $candidates = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw 'Could not find .NET Framework C# compiler (csc.exe).'
}

function ConvertTo-CSharpLiteral {
    param([Parameter(Mandatory)][string]$Value)

    return $Value.Replace('\', '\\').Replace('"', '\"')
}

New-DirectoryIfMissing -Path $distPath
New-DirectoryIfMissing -Path $workPath

if (Test-Path -LiteralPath $payloadPath) {
    Remove-Item -LiteralPath $payloadPath -Force
}

$payloadItems = @('src', 'config', 'docs') | ForEach-Object {
    Join-Path $rootPath $_
}

Compress-Archive -Path $payloadItems -DestinationPath $payloadPath -CompressionLevel Optimal -Force
$payloadBytes = [System.IO.File]::ReadAllBytes($payloadPath)
$payloadBase64 = [Convert]::ToBase64String($payloadBytes)
$payloadHash = ([System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash($payloadBytes))).Replace('-', '').ToLowerInvariant()
$escapedPayload = ConvertTo-CSharpLiteral -Value $payloadBase64
$escapedHash = ConvertTo-CSharpLiteral -Value $payloadHash

$launcherSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;

internal static class Program
{
    private const string PayloadBase64 = "$escapedPayload";
    private const string PayloadHash = "$escapedHash";

    [STAThread]
    private static int Main()
    {
        try
        {
            string appRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodeMateSetup", "app-" + PayloadHash.Substring(0, 12));
            string markerPath = Path.Combine(appRoot, ".payload-hash");
            string scriptPath = Path.Combine(appRoot, "src", "CodeMate.Setup.ps1");

            if (!File.Exists(scriptPath) || !File.Exists(markerPath) || File.ReadAllText(markerPath) != PayloadHash)
            {
                if (Directory.Exists(appRoot))
                {
                    Directory.Delete(appRoot, true);
                }

                Directory.CreateDirectory(appRoot);
                string zipPath = Path.Combine(Path.GetTempPath(), "codemate-" + PayloadHash.Substring(0, 12) + ".zip");
                byte[] payload = Convert.FromBase64String(PayloadBase64);

                using (SHA256 sha256 = SHA256.Create())
                {
                    string actualHash = BitConverter.ToString(sha256.ComputeHash(payload)).Replace("-", "").ToLowerInvariant();
                    if (actualHash != PayloadHash)
                    {
                        throw new InvalidOperationException("Embedded payload hash mismatch.");
                    }
                }

                File.WriteAllBytes(zipPath, payload);
                ZipFile.ExtractToDirectory(zipPath, appRoot);
                File.WriteAllText(markerPath, PayloadHash);
                try { File.Delete(zipPath); } catch { }
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
            startInfo.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"";
            startInfo.WorkingDirectory = appRoot;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            Process.Start(startInfo);
            return 0;
        }
        catch (Exception ex)
        {
            System.Windows.Forms.MessageBox.Show(ex.Message, "CodeMate Setup", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
            return 1;
        }
    }
}
"@

[System.IO.File]::WriteAllText($sourcePath, $launcherSource, [System.Text.Encoding]::UTF8)

$compiler = Get-CodeMateCSharpCompiler
$arguments = @(
    '/nologo',
    '/target:winexe',
    ('/out:{0}' -f $exePath),
    '/reference:System.Windows.Forms.dll',
    '/reference:System.IO.Compression.dll',
    '/reference:System.IO.Compression.FileSystem.dll',
    $sourcePath
)

& $compiler @arguments
if ($LASTEXITCODE -ne 0) {
    throw ('csc.exe failed with exit code {0}' -f $LASTEXITCODE)
}

Write-Host ('Built {0}' -f $exePath)
