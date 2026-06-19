Set-StrictMode -Version 2.0

$script:CodeMateRootPath = Split-Path -Parent $PSScriptRoot
$script:InstallSourcesPath = Join-Path $script:CodeMateRootPath 'config\install-sources.json'
$script:InstallSources = $null
$script:CodeMateProgressCallback = $null
$script:CodeMateProgressSequence = 0

function Set-CodeMateProgressCallback {
    param([scriptblock]$Callback)

    $script:CodeMateProgressCallback = $Callback
}

function Write-CodeMateProgressEvent {
    param(
        [string]$ActionId,
        [string]$Step,
        [string]$Stage,
        [ValidateSet('Pending', 'Running', 'Succeeded', 'Failed', 'Info')][string]$Status = 'Info',
        [string]$Message,
        [object]$Percent,
        [string]$Detail
    )

    $script:CodeMateProgressSequence++
    $event = [pscustomobject]@{
        Sequence  = $script:CodeMateProgressSequence
        Timestamp = (Get-Date).ToString('HH:mm:ss')
        ActionId  = $ActionId
        Step      = $Step
        Stage     = $Stage
        Status    = $Status
        Message   = $Message
        Percent   = $Percent
        Detail    = $Detail
    }

    if ($script:CodeMateProgressCallback) {
        try {
            & $script:CodeMateProgressCallback $event
        } catch {
        }
    }
}

function Format-CodeMateByteSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) {
        return ('{0:N1} GB' -f ($Bytes / 1GB))
    }

    if ($Bytes -ge 1MB) {
        return ('{0:N1} MB' -f ($Bytes / 1MB))
    }

    if ($Bytes -ge 1KB) {
        return ('{0:N1} KB' -f ($Bytes / 1KB))
    }

    return ('{0} B' -f $Bytes)
}

function New-CodeMateCheck {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Pass', 'Warn', 'Fail', 'Info')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Detected,
        [object]$RepairAction,
        [object[]]$Details = @()
    )

    [pscustomobject]@{
        Id           = $Id
        Name         = $Name
        Status       = $Status
        Message      = $Message
        Detected     = $Detected
        RepairAction = $RepairAction
        Details      = $Details
    }
}

function New-CodeMateRepairAction {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Description,
        [ValidateSet('Safe', 'NeedsConfirmation', 'Manual')][string]$Risk = 'NeedsConfirmation',
        [string]$Command,
        [string]$Url
    )

    [pscustomobject]@{
        Id          = $Id
        Label       = $Label
        Description = $Description
        Risk        = $Risk
        Command     = $Command
        Url         = $Url
    }
}

function ConvertTo-CodeMateProcessArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    '"' + ($Argument -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function ConvertTo-CodeMateProcessArgumentString {
    param([string[]]$ArgumentList = @())

    (@($ArgumentList) | ForEach-Object { ConvertTo-CodeMateProcessArgument -Argument $_ }) -join ' '
}

function Get-CodeMateInstallSources {
    if ($script:InstallSources) {
        return $script:InstallSources
    }

    if (Test-Path -LiteralPath $script:InstallSourcesPath) {
        try {
            $script:InstallSources = Get-Content -LiteralPath $script:InstallSourcesPath -Raw | ConvertFrom-Json
            return $script:InstallSources
        } catch {
        }
    }

    $script:InstallSources = [pscustomobject]@{
        node = [pscustomobject]@{
            indexSources = @(
                [pscustomobject]@{
                    name = 'Node.js official'
                    indexUrl = 'https://nodejs.org/dist/index.json'
                    distBaseUrl = 'https://nodejs.org/dist'
                }
            )
        }
        git = [pscustomobject]@{
            releaseSources = @(
                [pscustomobject]@{
                    name = 'Git for Windows GitHub API'
                    type = 'github-release-api'
                    url = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
                }
            )
        }
        winget = [pscustomobject]@{
            bundleSources = @(
                [pscustomobject]@{
                    name = 'Microsoft App Installer'
                    url = 'https://aka.ms/getwinget'
                }
            )
        }
    }

    return $script:InstallSources
}

function Test-CodeMateUrlAvailable {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [int]$TimeoutSeconds = 12
    )

    $oldProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    try {
        $response = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSeconds -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
        return [pscustomobject]@{
            Available = $true
            StatusCode = [int]$response.StatusCode
            Error = $null
        }
    } catch {
        try {
            $response = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
            return [pscustomobject]@{
                Available = $true
                StatusCode = [int]$response.StatusCode
                Error = $null
            }
        } catch {
            return [pscustomobject]@{
                Available = $false
                StatusCode = $null
                Error = $_.Exception.Message
            }
        }
    } finally {
        $ProgressPreference = $oldProgressPreference
    }
}

function Join-CodeMateUrl {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Child
    )

    $BaseUrl.TrimEnd('/') + '/' + $Child.TrimStart('/')
}

function Invoke-CodeMateProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 8,
        [string]$ActionId,
        [string]$Step
    )

    try {
        $resolvedFilePath = $FilePath
        $resolvedArguments = $ArgumentList
        $extension = [System.IO.Path]::GetExtension($FilePath).ToLowerInvariant()

        if ($extension -eq '.ps1') {
            $resolvedFilePath = (Get-Command powershell.exe -ErrorAction Stop).Source
            $resolvedArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + $ArgumentList
        } elseif ($extension -eq '.cmd' -or $extension -eq '.bat') {
            $resolvedFilePath = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
            $commandLine = (ConvertTo-CodeMateProcessArgument -Argument $FilePath)
            if ($ArgumentList.Count -gt 0) {
                $commandLine += ' ' + (ConvertTo-CodeMateProcessArgumentString -ArgumentList $ArgumentList)
            }

            $resolvedArguments = @('/d', '/c', $commandLine)
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $resolvedFilePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = ConvertTo-CodeMateProcessArgumentString -ArgumentList $resolvedArguments

        $displayCommand = (ConvertTo-CodeMateProcessArgument -Argument $resolvedFilePath)
        if ($psi.Arguments) {
            $displayCommand += ' ' + $psi.Arguments
        }
        $shouldReportProgress = -not [string]::IsNullOrWhiteSpace($ActionId) -or -not [string]::IsNullOrWhiteSpace($Step)

        if ($shouldReportProgress) {
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step $(if ($Step) { $Step } else { '运行命令' }) `
                -Stage 'process' `
                -Status 'Running' `
                -Message ('正在执行：{0}' -f $displayCommand)
        }

        $process = [System.Diagnostics.Process]::Start($psi)
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $nextReportMs = 1500

        while (-not $process.WaitForExit(500)) {
            if ($TimeoutSeconds -gt 0 -and $stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                try {
                    $process.Kill()
                } catch {
                }

                if ($shouldReportProgress) {
                    Write-CodeMateProgressEvent `
                        -ActionId $ActionId `
                        -Step $(if ($Step) { $Step } else { '运行命令' }) `
                        -Stage 'process' `
                        -Status 'Failed' `
                        -Message ('命令超时：{0}' -f $displayCommand) `
                        -Detail ('已等待 {0:N0} 秒。' -f $stopwatch.Elapsed.TotalSeconds)
                }

                return [pscustomobject]@{
                    ExitCode = -1
                    Output   = ''
                    Error    = 'Timed out.'
                }
            }

            if ($shouldReportProgress -and $stopwatch.ElapsedMilliseconds -ge $nextReportMs) {
                Write-CodeMateProgressEvent `
                    -ActionId $ActionId `
                    -Step $(if ($Step) { $Step } else { '运行命令' }) `
                    -Stage 'process' `
                    -Status 'Running' `
                    -Message ('仍在执行：{0}' -f $displayCommand) `
                    -Detail ('已用时 {0:N0} 秒。' -f $stopwatch.Elapsed.TotalSeconds)
                $nextReportMs += 5000
            }
        }

        $process.WaitForExit()
        $output = ''
        $errorText = ''
        try {
            $output = $outputTask.Result.Trim()
        } catch {
        }
        try {
            $errorText = $errorTask.Result.Trim()
        } catch {
        }

        $processStatus = if ($process.ExitCode -eq 0) { 'Succeeded' } else { 'Failed' }
        if ($shouldReportProgress) {
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step $(if ($Step) { $Step } else { '运行命令' }) `
                -Stage 'process' `
                -Status $processStatus `
                -Message ('命令结束，退出码 {0}：{1}' -f $process.ExitCode, $displayCommand) `
                -Detail ('用时 {0:N0} 秒。' -f $stopwatch.Elapsed.TotalSeconds)
        }

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output   = $output
            Error    = $errorText
        }
    } catch {
        if (-not [string]::IsNullOrWhiteSpace($ActionId) -or -not [string]::IsNullOrWhiteSpace($Step)) {
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step $(if ($Step) { $Step } else { '运行命令' }) `
                -Stage 'process' `
                -Status 'Failed' `
                -Message $_.Exception.Message
        }

        [pscustomobject]@{
            ExitCode = -1
            Output   = ''
            Error    = $_.Exception.Message
        }
    }
}

function Get-CodeMateCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name
    )

    try {
        $cmd = Get-Command $Name -ErrorAction Stop
        return $cmd
    } catch {
        return $null
    }
}

function ConvertTo-CodeMateVersion {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match($Text, '(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $match.Success) {
        return $null
    }

    $major = $match.Groups[1].Value
    $minor = $match.Groups[2].Value
    $patch = if ($match.Groups[3].Success) { $match.Groups[3].Value } else { '0' }

    try {
        return [version]::new([int]$major, [int]$minor, [int]$patch)
    } catch {
        return $null
    }
}

function Test-CodeMateCommandVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @('--version'),
        [string]$MinimumVersion,
        [object]$MissingRepairAction,
        [ValidateSet('Required', 'Recommended', 'Optional')][string]$Importance = 'Required'
    )

    $cmd = Get-CodeMateCommand -Name $Command

    if (-not $cmd) {
        $status = if ($Importance -eq 'Required') { 'Fail' } else { 'Warn' }
        $prefix = if ($Importance -eq 'Required') { '需要安装' } else { '建议安装' }

        return New-CodeMateCheck `
            -Id $Id `
            -Name $Name `
            -Status $status `
            -Message ("{0}，当前 PATH 里没有找到 {1}。" -f $prefix, $Command) `
            -RepairAction $MissingRepairAction
    }

    $result = Invoke-CodeMateProcess -FilePath $cmd.Source -ArgumentList $Arguments
    if ($result.ExitCode -ne 0) {
        Start-Sleep -Milliseconds 250
        $result = Invoke-CodeMateProcess -FilePath $cmd.Source -ArgumentList $Arguments
    }

    $rawVersion = if ($result.Output) { $result.Output.Split("`n")[0].Trim() } else { $result.Error.Split("`n")[0].Trim() }
    $parsedVersion = ConvertTo-CodeMateVersion -Text $rawVersion
    $detected = if ($rawVersion) { '{0} at {1}' -f $rawVersion, $cmd.Source } else { $cmd.Source }

    if ($result.ExitCode -ne 0) {
        $status = if ($Importance -eq 'Required') { 'Fail' } else { 'Warn' }

        return New-CodeMateCheck `
            -Id $Id `
            -Name $Name `
            -Status $status `
            -Message ("找到了 {0}，但执行版本检测失败。可能是安装损坏、权限不足或命令入口失效。" -f $Command) `
            -Detected $detected `
            -RepairAction $MissingRepairAction
    }

    if ($MinimumVersion -and $parsedVersion) {
        $minimum = [version]$MinimumVersion
        if ($parsedVersion -lt $minimum) {
            return New-CodeMateCheck `
                -Id $Id `
                -Name $Name `
                -Status 'Warn' `
                -Message ("已安装，但版本偏旧。建议升级到 {0} 或更高。" -f $MinimumVersion) `
                -Detected $detected `
                -RepairAction $MissingRepairAction
        }
    }

    return New-CodeMateCheck `
        -Id $Id `
        -Name $Name `
        -Status 'Pass' `
        -Message '已安装并且可以从当前终端调用。' `
        -Detected $detected
}

function Test-CodeMateCommandWithKnownPaths {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$Arguments = @('--version'),
        [string]$MinimumVersion,
        [object]$MissingRepairAction,
        [string[]]$KnownPaths = @(),
        [ValidateSet('Required', 'Recommended', 'Optional')][string]$Importance = 'Required'
    )

    if (Get-CodeMateCommand -Name $Command) {
        return Test-CodeMateCommandVersion `
            -Id $Id `
            -Name $Name `
            -Command $Command `
            -Arguments $Arguments `
            -MinimumVersion $MinimumVersion `
            -MissingRepairAction $MissingRepairAction `
            -Importance $Importance
    }

    $foundPaths = @(Get-CodeMateExistingPaths -Paths $KnownPaths)
    if ($foundPaths.Count -gt 0) {
        $pathToAdd = Split-Path -Parent $foundPaths[0]
        $status = if ($Importance -eq 'Required') { 'Warn' } else { 'Warn' }

        return New-CodeMateCheck `
            -Id $Id `
            -Name $Name `
            -Status $status `
            -Message '已检测到安装文件，但当前终端 PATH 中找不到命令入口。可自动写入用户 PATH。' `
            -Detected ($foundPaths -join '; ') `
            -RepairAction (New-CodeMateRepairAction `
                -Id 'add-known-tool-path' `
                -Label ('加入 {0} 到 PATH' -f $Name) `
                -Description ('把 {0} 的安装目录加入当前用户 PATH，并刷新当前进程 PATH。' -f $Name) `
                -Risk 'NeedsConfirmation' `
                -Command $pathToAdd)
    }

    return Test-CodeMateCommandVersion `
        -Id $Id `
        -Name $Name `
        -Command $Command `
        -Arguments $Arguments `
        -MinimumVersion $MinimumVersion `
        -MissingRepairAction $MissingRepairAction `
        -Importance $Importance
}

function Get-CodeMateUserPathItems {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        return @()
    }

    $userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

function Add-CodeMateUserPathItem {
    param(
        [Parameter(Mandatory = $true)][string]$PathItem
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($PathItem).TrimEnd('\')
    $items = @(Get-CodeMateUserPathItems)
    $exists = $false

    foreach ($item in $items) {
        if ([Environment]::ExpandEnvironmentVariables($item).TrimEnd('\').Equals($expanded, [System.StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }

    if ($exists) {
        return [pscustomobject]@{
            Changed = $false
            Message = 'PATH 已包含该目录。'
        }
    }

    $newPath = (@($items) + $PathItem) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')

    [pscustomobject]@{
        Changed = $true
        Message = '已写入用户 PATH。请重启终端或点击刷新 PATH。'
    }
}

function Update-CodeMateProcessPath {
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = @($machinePath, $userPath) -join ';'

    [pscustomobject]@{
        Changed = $true
        Message = '已刷新当前进程 PATH。已打开的旧终端仍需要重启。'
    }
}

function Get-CodeMateTempPath {
    param([string]$Name = 'CodeMateSetup')

    $path = Join-Path ([System.IO.Path]::GetTempPath()) $Name
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    return $path
}

function Invoke-CodeMateDownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$DisplayName = '下载文件',
        [string]$ActionId
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    Write-CodeMateProgressEvent `
        -ActionId $ActionId `
        -Step $DisplayName `
        -Stage 'download' `
        -Status 'Running' `
        -Message ('开始下载：{0}' -f $Url) `
        -Percent 0 `
        -Detail $Path

    $response = $null
    $responseStream = $null
    $fileStream = $null

    try {
        try {
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
        } catch {
        }

        $request = [System.Net.WebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = 30000

        if ($request -is [System.Net.HttpWebRequest]) {
            $request.AllowAutoRedirect = $true
            $request.MaximumAutomaticRedirections = 8
            $request.ReadWriteTimeout = 30000
            $request.UserAgent = 'CodeMate-Setup'
        }

        $response = $request.GetResponse()
        $totalBytes = [long]$response.ContentLength
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] 131072
        $downloadedBytes = [long]0
        $lastPercent = -1
        $lastReportMs = 0
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        while ($true) {
            $read = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }

            $fileStream.Write($buffer, 0, $read)
            $downloadedBytes += $read
            $percent = $null
            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(99, [int][Math]::Floor(($downloadedBytes * 100.0) / $totalBytes))
            }

            $shouldReport = $false
            if ($null -ne $percent -and $percent -ne $lastPercent) {
                $shouldReport = $true
                $lastPercent = $percent
            }

            if (($stopwatch.ElapsedMilliseconds - $lastReportMs) -ge 1000) {
                $shouldReport = $true
                $lastReportMs = $stopwatch.ElapsedMilliseconds
            }

            if ($shouldReport) {
                $detail = if ($totalBytes -gt 0) {
                    '{0} / {1}' -f (Format-CodeMateByteSize -Bytes $downloadedBytes), (Format-CodeMateByteSize -Bytes $totalBytes)
                } else {
                    '{0} downloaded' -f (Format-CodeMateByteSize -Bytes $downloadedBytes)
                }

                Write-CodeMateProgressEvent `
                    -ActionId $ActionId `
                    -Step $DisplayName `
                    -Stage 'download' `
                    -Status 'Running' `
                    -Message ('正在下载：{0}' -f $DisplayName) `
                    -Percent $percent `
                    -Detail $detail
            }
        }
    } catch {
        Write-CodeMateProgressEvent `
            -ActionId $ActionId `
            -Step $DisplayName `
            -Stage 'download' `
            -Status 'Failed' `
            -Message ('下载失败：{0}' -f $DisplayName) `
            -Detail $_.Exception.Message
        throw ("下载失败：{0}`n{1}" -f $Url, $_.Exception.Message)
    } finally {
        if ($fileStream) {
            $fileStream.Close()
        }
        if ($responseStream) {
            $responseStream.Close()
        }
        if ($response) {
            $response.Close()
        }
    }

    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -eq 0) {
        throw ("下载文件为空：{0}" -f $Url)
    }

    $fileSize = (Get-Item -LiteralPath $Path).Length
    Write-CodeMateProgressEvent `
        -ActionId $ActionId `
        -Step $DisplayName `
        -Stage 'download' `
        -Status 'Succeeded' `
        -Message ('下载完成：{0}' -f $DisplayName) `
        -Percent 100 `
        -Detail ('{0} -> {1}' -f (Format-CodeMateByteSize -Bytes $fileSize), $Path)

    return $Path
}

function Install-CodeMateWinget {
    $actionId = 'open-app-installer-store'

    Write-CodeMateProgressEvent `
        -ActionId $actionId `
        -Step 'Windows 包管理器 winget' `
        -Stage 'check' `
        -Status 'Running' `
        -Message '正在检查 winget 是否已可用。'

    $existing = Get-CodeMateCommand -Name 'winget'
    if ($existing) {
        Write-CodeMateProgressEvent `
            -ActionId $actionId `
            -Step 'Windows 包管理器 winget' `
            -Stage 'check' `
            -Status 'Succeeded' `
            -Message 'winget 已可用。' `
            -Detail $existing.Source
        return [pscustomobject]@{ Success = $true; Message = 'winget 已可用。' }
    }

    try {
        Write-CodeMateProgressEvent `
            -ActionId $actionId `
            -Step 'Windows 包管理器 winget' `
            -Stage 'register' `
            -Status 'Running' `
            -Message '正在尝试重新注册 App Installer。'
        Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop
        Update-CodeMateProcessPath | Out-Null
        if (Get-CodeMateCommand -Name 'winget') {
            Write-CodeMateProgressEvent `
                -ActionId $actionId `
                -Step 'Windows 包管理器 winget' `
                -Stage 'register' `
                -Status 'Succeeded' `
                -Message '已重新注册 App Installer，winget 现在可用。'
            return [pscustomobject]@{ Success = $true; Message = '已重新注册 App Installer，winget 现在可用。' }
        }
    } catch {
    }

    $sources = Get-CodeMateInstallSources
    $errors = New-Object System.Collections.Generic.List[string]
    $downloadPath = Join-Path (Get-CodeMateTempPath) 'Microsoft.DesktopAppInstaller.msixbundle'
    $downloaded = $false

    foreach ($source in @($sources.winget.bundleSources)) {
        try {
            Write-CodeMateProgressEvent `
                -ActionId $actionId `
                -Step 'Windows 包管理器 winget' `
                -Stage 'source' `
                -Status 'Running' `
                -Message ('正在检查下载源：{0}' -f $source.name) `
                -Detail $source.url

            $availability = Test-CodeMateUrlAvailable -Url $source.url
            if (-not $availability.Available) {
                $errors.Add(('{0}: {1}' -f $source.name, $availability.Error))
                Write-CodeMateProgressEvent `
                    -ActionId $actionId `
                    -Step 'Windows 包管理器 winget' `
                    -Stage 'source' `
                    -Status 'Failed' `
                    -Message ('下载源不可用：{0}' -f $source.name) `
                    -Detail $availability.Error
                continue
            }

            Invoke-CodeMateDownloadFile -Url $source.url -Path $downloadPath -DisplayName 'App Installer' -ActionId $actionId | Out-Null
            $downloaded = $true
            break
        } catch {
            $errors.Add(('{0}: {1}' -f $source.name, $_.Exception.Message))
        }
    }

    if (-not $downloaded) {
        throw ("没有可用的 App Installer 下载源。`n{0}" -f ($errors -join [Environment]::NewLine))
    }

    try {
        Write-CodeMateProgressEvent `
            -ActionId $actionId `
            -Step 'Windows 包管理器 winget' `
            -Stage 'install' `
            -Status 'Running' `
            -Message '正在安装 App Installer。'
        Add-AppxPackage -Path $downloadPath -ErrorAction Stop
    } catch {
        Write-CodeMateProgressEvent `
            -ActionId $actionId `
            -Step 'Windows 包管理器 winget' `
            -Stage 'install' `
            -Status 'Failed' `
            -Message 'App Installer 自动安装失败。' `
            -Detail $_.Exception.Message
        throw ("已下载 App Installer，但自动安装失败：{0}`n可能原因：系统商店组件损坏、缺少 MSIX 依赖、公司策略限制或当前系统不支持。" -f $_.Exception.Message)
    }

    Update-CodeMateProcessPath | Out-Null
    if (-not (Get-CodeMateCommand -Name 'winget')) {
        Write-CodeMateProgressEvent `
            -ActionId $actionId `
            -Step 'Windows 包管理器 winget' `
            -Stage 'verify' `
            -Status 'Failed' `
            -Message 'App Installer 安装完成，但当前用户仍无法调用 winget。'
        throw 'App Installer 安装完成，但当前用户仍无法调用 winget。请注销后重新登录，或重启电脑后重新检测。'
    }

    Write-CodeMateProgressEvent `
        -ActionId $actionId `
        -Step 'Windows 包管理器 winget' `
        -Stage 'verify' `
        -Status 'Succeeded' `
        -Message '已自动安装 App Installer，winget 现在可用。'

    return [pscustomobject]@{ Success = $true; Message = '已自动安装 App Installer，winget 现在可用。' }
}

function Get-CodeMateWingetActionId {
    param([string]$PackageId)

    switch ($PackageId) {
        'Git.Git' { return 'install-git-winget' }
        'OpenJS.NodeJS.LTS' { return 'install-node-winget' }
        'Microsoft.VisualStudioCode' { return 'install-vscode-winget' }
        'Anysphere.Cursor' { return 'install-cursor-winget' }
        default { return ('winget-{0}' -f ($PackageId -replace '[^A-Za-z0-9_.-]', '_')) }
    }
}

function Invoke-CodeMateWingetInstall {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [string]$InstallPath
    )

    $actionId = Get-CodeMateWingetActionId -PackageId $PackageId
    Write-CodeMateProgressEvent `
        -ActionId $actionId `
        -Step $DisplayName `
        -Stage 'winget' `
        -Status 'Running' `
        -Message ('正在准备通过 winget 安装 {0}。' -f $DisplayName) `
        -Detail $PackageId

    $winget = Get-CodeMateCommand -Name 'winget'
    if (-not $winget) {
        Install-CodeMateWinget | Out-Null
        $winget = Get-CodeMateCommand -Name 'winget'
    }

    if (-not $winget) {
        Write-CodeMateProgressEvent `
            -ActionId $actionId `
            -Step $DisplayName `
            -Stage 'winget' `
            -Status 'Failed' `
            -Message 'winget 不可用，无法继续自动安装。'
        throw 'winget 不可用，无法继续自动安装。'
    }

    $logPath = Join-Path (Get-CodeMateTempPath) ('winget-{0}.log' -f ($PackageId -replace '[^A-Za-z0-9_.-]', '_'))
    $args = @(
        'install',
        '--id', $PackageId,
        '-e',
        '--source', 'winget',
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--silent',
        '--log', $logPath
    )

    if (-not [string]::IsNullOrWhiteSpace($InstallPath)) {
        $args += @('--location', $InstallPath)
    }

    $result = Invoke-CodeMateProcess -FilePath $winget.Source -ArgumentList $args -TimeoutSeconds 1800 -ActionId $actionId -Step $DisplayName
    if ($result.ExitCode -ne 0) {
        $message = @(
            ('{0} 自动安装失败，退出码 {1}。' -f $DisplayName, $result.ExitCode),
            $result.Output,
            $result.Error,
            ('日志：{0}' -f $logPath)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        throw ($message -join [Environment]::NewLine)
    }

    Update-CodeMateProcessPath | Out-Null
    Write-CodeMateProgressEvent `
        -ActionId $actionId `
        -Step $DisplayName `
        -Stage 'verify' `
        -Status 'Succeeded' `
        -Message ('{0} 已通过 winget 自动安装，并已刷新当前 PATH。' -f $DisplayName) `
        -Detail ('日志：{0}' -f $logPath)

    return [pscustomobject]@{ Success = $true; Message = ('{0} 已通过 winget 自动安装，并已刷新当前 PATH。' -f $DisplayName) }
}

function Invoke-CodeMateWingetUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$PackageId,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $actionId = 'uninstall-{0}-winget' -f ($PackageId -replace '[^A-Za-z0-9_.-]', '_')
    Write-CodeMateProgressEvent `
        -ActionId $actionId `
        -Step $DisplayName `
        -Stage 'winget' `
        -Status 'Running' `
        -Message ('正在准备通过 winget 卸载 {0}。' -f $DisplayName) `
        -Detail $PackageId

    $winget = Get-CodeMateCommand -Name 'winget'
    if (-not $winget) {
        Write-CodeMateProgressEvent `
            -ActionId $actionId `
            -Step $DisplayName `
            -Stage 'winget' `
            -Status 'Failed' `
            -Message 'winget 不可用，无法继续自动卸载。'
        throw 'winget 不可用，无法继续自动卸载。'
    }

    $logPath = Join-Path (Get-CodeMateTempPath) ('winget-uninstall-{0}.log' -f ($PackageId -replace '[^A-Za-z0-9_.-]', '_'))
    $args = @(
        'uninstall',
        '--id', $PackageId,
        '-e',
        '--source', 'winget',
        '--accept-source-agreements',
        '--disable-interactivity',
        '--silent',
        '--log', $logPath
    )

    $result = Invoke-CodeMateProcess -FilePath $winget.Source -ArgumentList $args -TimeoutSeconds 1800 -ActionId $actionId -Step $DisplayName
    if ($result.ExitCode -ne 0) {
        $message = @(
            ('{0} 自动卸载失败，退出码 {1}。' -f $DisplayName, $result.ExitCode),
            $result.Output,
            $result.Error,
            ('日志：{0}' -f $logPath)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        throw ($message -join [Environment]::NewLine)
    }

    Update-CodeMateProcessPath | Out-Null
    Write-CodeMateProgressEvent `
        -ActionId $actionId `
        -Step $DisplayName `
        -Stage 'verify' `
        -Status 'Succeeded' `
        -Message ('{0} 已通过 winget 自动卸载，并已刷新当前 PATH。' -f $DisplayName) `
        -Detail ('日志：{0}' -f $logPath)

    return [pscustomobject]@{ Success = $true; Message = ('{0} 已通过 winget 自动卸载，并已刷新当前 PATH。' -f $DisplayName) }
}

function Invoke-CodeMateInstallerDownloadInstall {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$DisplayName,
        [Parameter(Mandatory = $true)][string]$FileName,
        [string[]]$ArgumentList = @(),
        [string]$ActionId
    )

    Write-CodeMateProgressEvent `
        -ActionId $ActionId `
        -Step $DisplayName `
        -Stage 'source' `
        -Status 'Running' `
        -Message ('正在检查下载源：{0}' -f $DisplayName) `
        -Detail $Url

    $availability = Test-CodeMateUrlAvailable -Url $Url
    if (-not $availability.Available) {
        Write-CodeMateProgressEvent `
            -ActionId $ActionId `
            -Step $DisplayName `
            -Stage 'source' `
            -Status 'Failed' `
            -Message ('{0} 下载源不可用。' -f $DisplayName) `
            -Detail $availability.Error
        throw ("{0} 下载源不可用：{1}" -f $DisplayName, $availability.Error)
    }

    $installerPath = Join-Path (Get-CodeMateTempPath) $FileName
    Invoke-CodeMateDownloadFile -Url $Url -Path $installerPath -DisplayName $DisplayName -ActionId $ActionId | Out-Null

    $result = Invoke-CodeMateProcess -FilePath $installerPath -ArgumentList $ArgumentList -TimeoutSeconds 1800 -ActionId $ActionId -Step $DisplayName
    if ($result.ExitCode -ne 0) {
        $message = @(
            ('{0} 安装器执行失败，退出码 {1}。' -f $DisplayName, $result.ExitCode),
            $result.Output,
            $result.Error,
            ('安装器：{0}' -f $installerPath)
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        throw ($message -join [Environment]::NewLine)
    }

    Update-CodeMateProcessPath | Out-Null
    Write-CodeMateProgressEvent `
        -ActionId $ActionId `
        -Step $DisplayName `
        -Stage 'verify' `
        -Status 'Succeeded' `
        -Message ('{0} 已下载安装器并执行安装。' -f $DisplayName) `
        -Detail $installerPath

    return [pscustomobject]@{
        Success = $true
        Message = ('{0} 已下载安装器并执行安装。' -f $DisplayName)
    }
}

function Get-CodeMateToolInstallSpec {
    param([Parameter(Mandatory = $true)][string]$ToolId)

    $defaultProgramRoot = Join-Path $env:LOCALAPPDATA 'Programs'

    switch ($ToolId) {
        'codex-app' {
            return [pscustomobject]@{
                Id                  = 'codex-app'
                Name                = 'Codex 桌面版'
                Kind                = 'installer'
                UninstallKind       = 'manual'
                PackageId           = $null
                PackageName         = $null
                DownloadUrl         = 'https://get.microsoft.com/installer/download/9PLM9XGG6VKS?cid=website_cta_psi'
                FileName            = 'Codex Installer.exe'
                Arguments           = @()
                SourceLabel         = 'OpenAI 官方 Codex App 下载入口（Microsoft App Installer）'
                DefaultInstallPath  = Join-Path $defaultProgramRoot 'OpenAI Codex'
                SupportsInstallPath = $false
                InstallPathNote     = 'Codex 桌面版通常由 Windows App Installer/MSIX 管理安装位置，预选路径一般不会生效。'
                UninstallNote       = 'Codex 桌面版由 Windows 应用安装器/系统应用管理。请在 Windows 设置 > 应用 > 已安装的应用中搜索 Codex 并卸载。'
            }
        }

        'codex' {
            return [pscustomobject]@{
                Id                  = 'codex'
                Name                = 'Codex 命令行版'
                Kind                = 'npm'
                UninstallKind       = 'npm'
                PackageId           = $null
                PackageName         = '@openai/codex'
                SourceLabel         = 'npm：@openai/codex'
                DefaultInstallPath  = ''
                SupportsInstallPath = $false
                InstallPathNote     = '命令行版通过 npm 全局目录安装，路径由 npm prefix 决定。'
                UninstallNote       = '将执行 npm uninstall -g @openai/codex。'
            }
        }

        'claude' {
            return [pscustomobject]@{
                Id                  = 'claude'
                Name                = 'Claude Code 命令行版'
                Kind                = 'npm'
                UninstallKind       = 'npm'
                PackageId           = $null
                PackageName         = '@anthropic-ai/claude-code'
                SourceLabel         = 'npm：@anthropic-ai/claude-code'
                DefaultInstallPath  = ''
                SupportsInstallPath = $false
                InstallPathNote     = '命令行版通过 npm 全局目录安装，路径由 npm prefix 决定。'
                UninstallNote       = '将执行 npm uninstall -g @anthropic-ai/claude-code。'
            }
        }

        'cursor' {
            return [pscustomobject]@{
                Id                  = 'cursor'
                Name                = 'Cursor 桌面版'
                Kind                = 'winget'
                UninstallKind       = 'winget'
                PackageId           = 'Anysphere.Cursor'
                PackageName         = $null
                SourceLabel         = 'winget 官方源：Anysphere.Cursor'
                DefaultInstallPath  = Join-Path $defaultProgramRoot 'Cursor'
                SupportsInstallPath = $false
                InstallPathNote     = 'Cursor 的官方安装器通常自行决定安装位置，预选路径仅作为用户期望记录。'
                UninstallNote       = '将尝试通过 winget 卸载 Anysphere.Cursor。若上游安装器需要确认，请按系统提示操作。'
            }
        }

        'ccswitch' {
            return [pscustomobject]@{
                Id                  = 'ccswitch'
                Name                = 'CC Switch 桌面版'
                Kind                = 'winget'
                UninstallKind       = 'winget'
                PackageId           = 'farion1231.CC-Switch'
                PackageName         = $null
                SourceLabel         = 'winget 官方源：farion1231.CC-Switch'
                DefaultInstallPath  = Join-Path $defaultProgramRoot 'CC Switch'
                SupportsInstallPath = $false
                InstallPathNote     = 'CC Switch 安装器是否接受自定义路径取决于上游安装包，本版本默认不强制写入路径。'
                UninstallNote       = '将尝试通过 winget 卸载 farion1231.CC-Switch。卸载后已导入的本地配置文件可能仍保留在用户目录中。'
            }
        }

        default {
            throw ("未知工具：{0}" -f $ToolId)
        }
    }
}

function Invoke-CodeMateToolInstall {
    param(
        [Parameter(Mandatory = $true)][string]$ToolId,
        [string]$InstallPath
    )

    $spec = Get-CodeMateToolInstallSpec -ToolId $ToolId
    $effectiveInstallPath = if ($spec.SupportsInstallPath -and -not [string]::IsNullOrWhiteSpace($InstallPath)) {
        $InstallPath
    } else {
        $null
    }

    switch ($spec.Kind) {
        'installer' {
            return Invoke-CodeMateInstallerDownloadInstall `
                -Url $spec.DownloadUrl `
                -DisplayName $spec.Name `
                -FileName $spec.FileName `
                -ArgumentList @($spec.Arguments) `
                -ActionId ('install-{0}' -f $spec.Id)
        }

        'winget' {
            return Invoke-CodeMateWingetInstall -PackageId $spec.PackageId -DisplayName $spec.Name -InstallPath $effectiveInstallPath
        }

        'npm' {
            $npm = Get-CodeMateCommand -Name 'npm'
            if (-not $npm) {
                throw 'npm 不可用。请先在 Environment 页一键修复 Node.js / npm 环境。'
            }

            $actionId = ('install-{0}-npm' -f $spec.Id)
            Write-CodeMateProgressEvent `
                -ActionId $actionId `
                -Step $spec.Name `
                -Stage 'npm' `
                -Status 'Running' `
                -Message ('正在通过 npm 安装 {0}。' -f $spec.PackageName)

            $result = Invoke-CodeMateProcess -FilePath $npm.Source -ArgumentList @('install', '-g', $spec.PackageName) -TimeoutSeconds 1800 -ActionId $actionId -Step $spec.Name
            if ($result.ExitCode -ne 0) {
                $message = @(
                    ('{0} 自动安装失败，退出码 {1}。' -f $spec.Name, $result.ExitCode),
                    $result.Output,
                    $result.Error
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                throw ($message -join [Environment]::NewLine)
            }

            Update-CodeMateProcessPath | Out-Null
            Write-CodeMateProgressEvent `
                -ActionId $actionId `
                -Step $spec.Name `
                -Stage 'verify' `
                -Status 'Succeeded' `
                -Message ('{0} 已通过 npm 全局安装，并已刷新当前 PATH。' -f $spec.Name)

            return [pscustomobject]@{
                Success = $true
                Message = ('{0} 已通过 npm 全局安装，并已刷新当前 PATH。' -f $spec.Name)
            }
        }

        default {
            throw ("暂不支持该安装方式：{0}" -f $spec.Kind)
        }
    }
}

function Invoke-CodeMateToolUninstall {
    param([Parameter(Mandatory = $true)][string]$ToolId)

    $spec = Get-CodeMateToolInstallSpec -ToolId $ToolId
    $uninstallKind = if ($spec.PSObject.Properties['UninstallKind'] -and $spec.UninstallKind) {
        $spec.UninstallKind
    } else {
        $spec.Kind
    }

    switch ($uninstallKind) {
        'winget' {
            if ([string]::IsNullOrWhiteSpace($spec.PackageId)) {
                throw ('{0} 缺少 winget 包 ID，无法自动卸载。' -f $spec.Name)
            }

            return Invoke-CodeMateWingetUninstall -PackageId $spec.PackageId -DisplayName $spec.Name
        }

        'npm' {
            if ([string]::IsNullOrWhiteSpace($spec.PackageName)) {
                throw ('{0} 缺少 npm 包名，无法自动卸载。' -f $spec.Name)
            }

            $npm = Get-CodeMateCommand -Name 'npm'
            if (-not $npm) {
                throw 'npm 不可用，无法自动卸载 npm 全局工具。'
            }

            $actionId = ('uninstall-{0}-npm' -f $spec.Id)
            Write-CodeMateProgressEvent `
                -ActionId $actionId `
                -Step $spec.Name `
                -Stage 'npm' `
                -Status 'Running' `
                -Message ('正在通过 npm 卸载 {0}。' -f $spec.PackageName)

            $result = Invoke-CodeMateProcess -FilePath $npm.Source -ArgumentList @('uninstall', '-g', $spec.PackageName) -TimeoutSeconds 1800 -ActionId $actionId -Step $spec.Name
            if ($result.ExitCode -ne 0) {
                $message = @(
                    ('{0} 自动卸载失败，退出码 {1}。' -f $spec.Name, $result.ExitCode),
                    $result.Output,
                    $result.Error
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                throw ($message -join [Environment]::NewLine)
            }

            Update-CodeMateProcessPath | Out-Null
            Write-CodeMateProgressEvent `
                -ActionId $actionId `
                -Step $spec.Name `
                -Stage 'verify' `
                -Status 'Succeeded' `
                -Message ('{0} 已通过 npm 全局卸载，并已刷新当前 PATH。' -f $spec.Name)

            return [pscustomobject]@{
                Success = $true
                Message = ('{0} 已通过 npm 全局卸载，并已刷新当前 PATH。' -f $spec.Name)
            }
        }

        'manual' {
            Write-CodeMateProgressEvent `
                -ActionId ('uninstall-{0}-manual' -f $spec.Id) `
                -Step $spec.Name `
                -Stage 'manual' `
                -Status 'Info' `
                -Message $spec.UninstallNote
            throw $spec.UninstallNote
        }

        default {
            throw ("暂不支持该卸载方式：{0}" -f $uninstallKind)
        }
    }
}

function Get-CodeMateNodeInstallerCandidate {
    $sources = Get-CodeMateInstallSources
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($source in @($sources.node.indexSources)) {
        try {
            Write-CodeMateProgressEvent `
                -ActionId 'install-node-winget' `
                -Step 'Node.js LTS' `
                -Stage 'source' `
                -Status 'Running' `
                -Message ('正在检查 Node.js 下载源：{0}' -f $source.name) `
                -Detail $source.indexUrl

            $availability = Test-CodeMateUrlAvailable -Url $source.indexUrl
            if (-not $availability.Available) {
                $errors.Add(('{0}: {1}' -f $source.name, $availability.Error))
                Write-CodeMateProgressEvent `
                    -ActionId 'install-node-winget' `
                    -Step 'Node.js LTS' `
                    -Stage 'source' `
                    -Status 'Failed' `
                    -Message ('Node.js 下载源不可用：{0}' -f $source.name) `
                    -Detail $availability.Error
                continue
            }

            $oldProgressPreference = $ProgressPreference
            try {
                $ProgressPreference = 'SilentlyContinue'
                $index = Invoke-RestMethod -Uri $source.indexUrl -TimeoutSec 20 -ErrorAction Stop
            } finally {
                $ProgressPreference = $oldProgressPreference
            }
            $latestLts = @($index | Where-Object { $_.lts -and $_.files -contains 'win-x64-msi' } | Select-Object -First 1)
            if (-not $latestLts) {
                $errors.Add(('{0}: 未找到 LTS win-x64-msi。' -f $source.name))
                continue
            }

            $fileName = 'node-{0}-x64.msi' -f $latestLts.version
            $downloadUrl = Join-CodeMateUrl -BaseUrl $source.distBaseUrl -Child ('{0}/{1}' -f $latestLts.version, $fileName)
            $downloadAvailable = Test-CodeMateUrlAvailable -Url $downloadUrl
            if (-not $downloadAvailable.Available) {
                $errors.Add(('{0}: {1}' -f $source.name, $downloadAvailable.Error))
                Write-CodeMateProgressEvent `
                    -ActionId 'install-node-winget' `
                    -Step 'Node.js LTS' `
                    -Stage 'source' `
                    -Status 'Failed' `
                    -Message ('Node.js 安装包不可用：{0}' -f $source.name) `
                    -Detail $downloadAvailable.Error
                continue
            }

            Write-CodeMateProgressEvent `
                -ActionId 'install-node-winget' `
                -Step 'Node.js LTS' `
                -Stage 'source' `
                -Status 'Succeeded' `
                -Message ('已选择 Node.js 下载源：{0}' -f $source.name) `
                -Detail $downloadUrl

            return [pscustomobject]@{
                Name = $source.name
                Version = $latestLts.version
                Url = $downloadUrl
                FileName = $fileName
            }
        } catch {
            $errors.Add(('{0}: {1}' -f $source.name, $_.Exception.Message))
        }
    }

    throw ("没有可用的 Node.js 下载源。`n{0}" -f ($errors -join [Environment]::NewLine))
}

function Install-CodeMateNodeFromSources {
    $candidate = Get-CodeMateNodeInstallerCandidate
    $installerPath = Join-Path (Get-CodeMateTempPath) $candidate.FileName
    Invoke-CodeMateDownloadFile -Url $candidate.Url -Path $installerPath -DisplayName ('Node.js {0}' -f $candidate.Version) -ActionId 'install-node-winget' | Out-Null

    $result = Invoke-CodeMateProcess -FilePath 'msiexec.exe' -ArgumentList @('/i', $installerPath, '/qn', '/norestart') -TimeoutSeconds 1800 -ActionId 'install-node-winget' -Step ('Node.js {0}' -f $candidate.Version)
    if ($result.ExitCode -ne 0) {
        throw ("Node.js 安装失败，退出码 {0}。`n来源：{1}`n{2}`n{3}" -f $result.ExitCode, $candidate.Name, $result.Output, $result.Error)
    }

    Update-CodeMateProcessPath | Out-Null
    Write-CodeMateProgressEvent `
        -ActionId 'install-node-winget' `
        -Step 'Node.js LTS' `
        -Stage 'verify' `
        -Status 'Succeeded' `
        -Message ('Node.js {0} 已从 {1} 自动下载安装，并已刷新 PATH。' -f $candidate.Version, $candidate.Name)

    return [pscustomobject]@{ Success = $true; Message = ('Node.js {0} 已从 {1} 自动下载安装，并已刷新 PATH。' -f $candidate.Version, $candidate.Name) }
}

function Get-CodeMateGitInstallerFromGithubApi {
    param([Parameter(Mandatory = $true)][object]$Source)

    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        $release = Invoke-RestMethod -Uri $Source.url -TimeoutSec 20 -Headers @{ 'User-Agent' = 'CodeMate-Setup' } -ErrorAction Stop
    } finally {
        $ProgressPreference = $oldProgressPreference
    }
    $asset = @($release.assets | Where-Object {
            $_.name -match '^Git-\d+\.\d+\.\d+.*-64-bit\.exe$' -and $_.name -notmatch 'portable|minGit|busybox'
        } | Select-Object -First 1)

    if (-not $asset) {
        throw '未找到 Git for Windows 64-bit 安装包。'
    }

    [pscustomobject]@{
        Name = $Source.name
        Version = $release.tag_name
        Url = $asset.browser_download_url
        FileName = $asset.name
    }
}

function Get-CodeMateGitInstallerFromDirectoryIndex {
    param([Parameter(Mandatory = $true)][object]$Source)

    $oldProgressPreference = $ProgressPreference
    try {
        $ProgressPreference = 'SilentlyContinue'
        $page = Invoke-WebRequest -Uri $Source.url -TimeoutSec 20 -UseBasicParsing -ErrorAction Stop
    } finally {
        $ProgressPreference = $oldProgressPreference
    }
    $links = @($page.Links | Where-Object { $_.href } | ForEach-Object { $_.href })
    $installerLinks = @($links | Where-Object { $_ -match 'Git-\d+\.\d+\.\d+.*-64-bit\.exe$' -and $_ -notmatch 'portable|minGit|busybox' })

    if (-not $installerLinks -or $installerLinks.Count -eq 0) {
        $matches = [regex]::Matches($page.Content, 'href="([^"]*Git-\d+\.\d+\.\d+[^"]*-64-bit\.exe)"')
        $installerLinks = @($matches | ForEach-Object { $_.Groups[1].Value })
    }

    if (-not $installerLinks -or $installerLinks.Count -eq 0) {
        throw '未找到 Git for Windows 64-bit 安装包。'
    }

    $href = @($installerLinks | Sort-Object -Descending | Select-Object -First 1)[0]
    $downloadUrl = if ($href -match '^https?://') {
        $href
    } else {
        Join-CodeMateUrl -BaseUrl $Source.url -Child $href
    }

    [pscustomobject]@{
        Name = $Source.name
        Version = 'latest'
        Url = $downloadUrl
        FileName = [System.IO.Path]::GetFileName(([uri]$downloadUrl).LocalPath)
    }
}

function Get-CodeMateGitInstallerCandidate {
    $sources = Get-CodeMateInstallSources
    $errors = New-Object System.Collections.Generic.List[string]

    foreach ($source in @($sources.git.releaseSources)) {
        try {
            Write-CodeMateProgressEvent `
                -ActionId 'install-git-winget' `
                -Step 'Git' `
                -Stage 'source' `
                -Status 'Running' `
                -Message ('正在检查 Git 下载源：{0}' -f $source.name) `
                -Detail $source.url

            $availability = Test-CodeMateUrlAvailable -Url $source.url
            if (-not $availability.Available) {
                $errors.Add(('{0}: {1}' -f $source.name, $availability.Error))
                Write-CodeMateProgressEvent `
                    -ActionId 'install-git-winget' `
                    -Step 'Git' `
                    -Stage 'source' `
                    -Status 'Failed' `
                    -Message ('Git 下载源不可用：{0}' -f $source.name) `
                    -Detail $availability.Error
                continue
            }

            $candidate = switch ($source.type) {
                'github-release-api' { Get-CodeMateGitInstallerFromGithubApi -Source $source }
                'directory-index' { Get-CodeMateGitInstallerFromDirectoryIndex -Source $source }
                default { throw ('未知源类型：{0}' -f $source.type) }
            }

            $downloadAvailable = Test-CodeMateUrlAvailable -Url $candidate.Url
            if (-not $downloadAvailable.Available) {
                $errors.Add(('{0}: {1}' -f $source.name, $downloadAvailable.Error))
                Write-CodeMateProgressEvent `
                    -ActionId 'install-git-winget' `
                    -Step 'Git' `
                    -Stage 'source' `
                    -Status 'Failed' `
                    -Message ('Git 安装包不可用：{0}' -f $source.name) `
                    -Detail $downloadAvailable.Error
                continue
            }

            Write-CodeMateProgressEvent `
                -ActionId 'install-git-winget' `
                -Step 'Git' `
                -Stage 'source' `
                -Status 'Succeeded' `
                -Message ('已选择 Git 下载源：{0}' -f $source.name) `
                -Detail $candidate.Url

            return $candidate
        } catch {
            $errors.Add(('{0}: {1}' -f $source.name, $_.Exception.Message))
        }
    }

    throw ("没有可用的 Git 下载源。`n{0}" -f ($errors -join [Environment]::NewLine))
}

function Install-CodeMateGitFromSources {
    $candidate = Get-CodeMateGitInstallerCandidate
    $installerPath = Join-Path (Get-CodeMateTempPath) $candidate.FileName
    Invoke-CodeMateDownloadFile -Url $candidate.Url -Path $installerPath -DisplayName ('Git {0}' -f $candidate.Version) -ActionId 'install-git-winget' | Out-Null

    $result = Invoke-CodeMateProcess -FilePath $installerPath -ArgumentList @('/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-') -TimeoutSeconds 1800 -ActionId 'install-git-winget' -Step ('Git {0}' -f $candidate.Version)
    if ($result.ExitCode -ne 0) {
        throw ("Git 安装失败，退出码 {0}。`n来源：{1}`n{2}`n{3}" -f $result.ExitCode, $candidate.Name, $result.Output, $result.Error)
    }

    Update-CodeMateProcessPath | Out-Null
    Write-CodeMateProgressEvent `
        -ActionId 'install-git-winget' `
        -Step 'Git' `
        -Stage 'verify' `
        -Status 'Succeeded' `
        -Message ('Git 已从 {0} 自动下载安装，并已刷新 PATH。' -f $candidate.Name)

    return [pscustomobject]@{ Success = $true; Message = ('Git 已从 {0} 自动下载安装，并已刷新 PATH。' -f $candidate.Name) }
}

function Add-CodeMateKnownToolPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $result = Add-CodeMateUserPathItem -PathItem $Directory
    Update-CodeMateProcessPath | Out-Null

    [pscustomobject]@{
        Success = $true
        Message = ('{0} 已处理。{1}' -f $Directory, $result.Message)
    }
}

function Protect-CodeMateSecretText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $patterns = @(
        'sk-[A-Za-z0-9_-]{12,}',
        'sk-ant-[A-Za-z0-9_-]{12,}',
        'xox[baprs]-[A-Za-z0-9-]{12,}',
        'gh[pousr]_[A-Za-z0-9_]{12,}',
        '(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*["'']?[^"''\s,;]+'
    )

    $redacted = $Text
    foreach ($pattern in $patterns) {
        $redacted = [regex]::Replace($redacted, $pattern, '[REDACTED]')
    }

    return $redacted
}

function ConvertTo-CodeMateRedactedReport {
    param([Parameter(Mandatory = $true)][object]$Value)

    $json = $Value | ConvertTo-Json -Depth 12
    $json = Protect-CodeMateSecretText -Text $json
    return $json | ConvertFrom-Json
}

function Test-CodeMatePowerShell {
    $policy = Get-ExecutionPolicy -Scope CurrentUser
    $version = $PSVersionTable.PSVersion.ToString()
    $details = @(
        [pscustomobject]@{ Name = 'CurrentUserExecutionPolicy'; Value = $policy.ToString() },
        [pscustomobject]@{ Name = 'PSVersion'; Value = $version }
    )

    if ($policy -in @('Restricted', 'Undefined')) {
        return New-CodeMateCheck `
            -Id 'powershell-policy' `
            -Name 'PowerShell 执行策略' `
            -Status 'Warn' `
            -Message '当前用户执行策略可能阻止安装脚本或诊断脚本运行。' `
            -Detected ("CurrentUser: {0}, PowerShell: {1}" -f $policy, $version) `
            -Details $details `
            -RepairAction (New-CodeMateRepairAction `
                -Id 'set-execution-policy' `
                -Label '设为 RemoteSigned' `
                -Description '仅修改当前用户的 PowerShell 执行策略，不需要管理员权限。' `
                -Risk 'NeedsConfirmation' `
                -Command 'Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force')
    }

    return New-CodeMateCheck `
        -Id 'powershell-policy' `
        -Name 'PowerShell 执行策略' `
        -Status 'Pass' `
        -Message '当前用户执行策略适合运行本地诊断和官方安装脚本。' `
        -Detected ("CurrentUser: {0}, PowerShell: {1}" -f $policy, $version) `
        -Details $details
}

function Test-CodeMateOperatingSystem {
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = $os.Caption
    $version = [version]$os.Version
    $arch = $os.OSArchitecture

    if ($version.Major -lt 10) {
        return New-CodeMateCheck `
            -Id 'windows-version' `
            -Name 'Windows 版本' `
            -Status 'Fail' `
            -Message 'Windows 版本过旧，很多 AI 编程工具可能不再支持。' `
            -Detected ("{0} {1} {2}" -f $caption, $os.Version, $arch)
    }

    return New-CodeMateCheck `
        -Id 'windows-version' `
        -Name 'Windows 版本' `
        -Status 'Pass' `
        -Message '系统版本适合安装主流 AI 编程工具。' `
        -Detected ("{0} {1} {2}" -f $caption, $os.Version, $arch)
}

function Test-CodeMateWinget {
    $repair = New-CodeMateRepairAction `
        -Id 'open-app-installer-store' `
        -Label '打开 App Installer 商店页' `
        -Description '自动打开 Microsoft Store 的 App Installer 页面。安装完成后即可获得 winget。' `
        -Risk 'NeedsConfirmation' `
        -Command 'ms-windows-store://pdp/?ProductId=9NBLGGH4NNS1' `
        -Url 'https://learn.microsoft.com/windows/package-manager/winget/'

    return Test-CodeMateCommandVersion `
        -Id 'winget' `
        -Name 'Windows 包管理器 winget' `
        -Command 'winget' `
        -Arguments @('--version') `
        -MissingRepairAction $repair `
        -Importance 'Recommended'
}

function Test-CodeMateGit {
    $repair = New-CodeMateRepairAction `
        -Id 'install-git-winget' `
        -Label '自动安装 Git' `
        -Description '通过 winget 自动安装官方 Git for Windows，并刷新 PATH。需要网络，安装过程中可能弹出 UAC。' `
        -Risk 'NeedsConfirmation' `
        -Command 'winget install --id Git.Git -e --source winget'

    return Test-CodeMateCommandWithKnownPaths `
        -Id 'git' `
        -Name 'Git' `
        -Command 'git' `
        -Arguments @('--version') `
        -MinimumVersion '2.40.0' `
        -MissingRepairAction $repair `
        -KnownPaths @(
            "$env:ProgramFiles\Git\cmd\git.exe",
            "$env:ProgramFiles\Git\bin\git.exe",
            "${env:ProgramFiles(x86)}\Git\cmd\git.exe",
            "${env:ProgramFiles(x86)}\Git\bin\git.exe"
        ) `
        -Importance 'Required'
}

function Test-CodeMateNode {
    $repair = New-CodeMateRepairAction `
        -Id 'install-node-winget' `
        -Label '自动安装 Node.js LTS' `
        -Description '通过 winget 自动安装官方 Node.js LTS，并刷新 PATH。Codex CLI、Claude Code npm 安装方式等会用到 Node/npm。' `
        -Risk 'NeedsConfirmation' `
        -Command 'winget install --id OpenJS.NodeJS.LTS -e --source winget'

    return Test-CodeMateCommandWithKnownPaths `
        -Id 'node' `
        -Name 'Node.js' `
        -Command 'node' `
        -Arguments @('--version') `
        -MinimumVersion '18.0.0' `
        -MissingRepairAction $repair `
        -KnownPaths @(
            "$env:ProgramFiles\nodejs\node.exe",
            "${env:ProgramFiles(x86)}\nodejs\node.exe"
        ) `
        -Importance 'Required'
}

function Test-CodeMateNpm {
    $repair = New-CodeMateRepairAction `
        -Id 'install-node-winget' `
        -Label '安装 Node.js LTS' `
        -Description 'npm 随 Node.js 一起安装。若 node 已存在但 npm 缺失，建议重新安装官方 LTS 版本。' `
        -Risk 'NeedsConfirmation' `
        -Command 'winget install --id OpenJS.NodeJS.LTS -e --source winget'

    return Test-CodeMateCommandWithKnownPaths `
        -Id 'npm' `
        -Name 'npm' `
        -Command 'npm' `
        -Arguments @('--version') `
        -MinimumVersion '9.0.0' `
        -MissingRepairAction $repair `
        -KnownPaths @(
            "$env:ProgramFiles\nodejs\npm.cmd",
            "${env:ProgramFiles(x86)}\nodejs\npm.cmd"
        ) `
        -Importance 'Required'
}

function Test-CodeMateNpmGlobalPath {
    $npm = Get-CodeMateCommand -Name 'npm'
    if (-not $npm) {
        return New-CodeMateCheck `
            -Id 'npm-global-path' `
            -Name 'npm 全局命令 PATH' `
            -Status 'Warn' `
            -Message 'npm 未安装，暂时无法检测全局命令目录。'
    }

    $result = Invoke-CodeMateProcess -FilePath $npm.Source -ArgumentList @('prefix', '-g')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Output)) {
        return New-CodeMateCheck `
            -Id 'npm-global-path' `
            -Name 'npm 全局命令 PATH' `
            -Status 'Warn' `
            -Message '无法读取 npm 全局目录。' `
            -Detected $result.Error
    }

    $prefix = $result.Output.Split("`n")[0].Trim()
    $candidate = if (Test-Path -LiteralPath (Join-Path $prefix 'node_modules')) {
        $prefix
    } else {
        Join-Path $prefix ''
    }

    $pathItems = $env:Path -split ';'
    $expandedCandidate = [Environment]::ExpandEnvironmentVariables($candidate).TrimEnd('\')
    $inPath = $false

    foreach ($item in $pathItems) {
        if ([Environment]::ExpandEnvironmentVariables($item).TrimEnd('\').Equals($expandedCandidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            $inPath = $true
            break
        }
    }

    if (-not $inPath) {
        return New-CodeMateCheck `
            -Id 'npm-global-path' `
            -Name 'npm 全局命令 PATH' `
            -Status 'Warn' `
            -Message 'npm 全局命令目录不在当前 PATH 中，安装 Codex/Claude Code 后可能提示命令不存在。' `
            -Detected $candidate `
            -RepairAction (New-CodeMateRepairAction `
                -Id 'add-npm-global-path' `
                -Label '加入用户 PATH' `
                -Description '把 npm prefix -g 返回的目录加入当前用户 PATH。' `
                -Risk 'NeedsConfirmation' `
                -Command $candidate)
    }

    return New-CodeMateCheck `
        -Id 'npm-global-path' `
        -Name 'npm 全局命令 PATH' `
        -Status 'Pass' `
        -Message 'npm 全局命令目录已在 PATH 中。' `
        -Detected $candidate
}

function Test-CodeMateEditor {
    $vscodeRepair = New-CodeMateRepairAction `
        -Id 'install-vscode-winget' `
        -Label '用 winget 安装 VS Code' `
        -Description '安装 Microsoft Visual Studio Code。Cursor 用户也可以跳过。' `
        -Risk 'NeedsConfirmation' `
        -Command 'winget install --id Microsoft.VisualStudioCode -e --source winget'

    $cursorRepair = New-CodeMateRepairAction `
        -Id 'install-cursor-winget' `
        -Label '用 winget 安装 Cursor' `
        -Description '安装 Cursor 编辑器。若 winget 源不可用，请改用官网安装。' `
        -Risk 'NeedsConfirmation' `
        -Command 'winget install --id Anysphere.Cursor -e --source winget'

    $code = Get-CodeMateCommand -Name 'code'
    $cursor = Get-CodeMateCommand -Name 'cursor'

    if ($code -or $cursor) {
        $detected = @()
        if ($code) { $detected += ('VS Code CLI: {0}' -f $code.Source) }
        if ($cursor) { $detected += ('Cursor CLI: {0}' -f $cursor.Source) }

        return New-CodeMateCheck `
            -Id 'editor' `
            -Name 'VS Code / Cursor' `
            -Status 'Pass' `
            -Message '已检测到可从终端调用的编辑器命令。' `
            -Detected ($detected -join '; ')
    }

    $commonPaths = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\Code.exe",
        "$env:ProgramFiles\Microsoft VS Code\Code.exe",
        "$env:LOCALAPPDATA\Programs\cursor\Cursor.exe",
        "$env:ProgramFiles\Cursor\Cursor.exe"
    )

    $found = $commonPaths | Where-Object { Test-Path -LiteralPath $_ }
    if ($found.Count -gt 0) {
        return New-CodeMateCheck `
            -Id 'editor' `
            -Name 'VS Code / Cursor' `
            -Status 'Warn' `
            -Message '检测到编辑器已安装，但命令行入口不在 PATH 中。' `
            -Detected ($found -join '; ') `
            -RepairAction (New-CodeMateRepairAction `
                -Id 'refresh-path' `
                -Label '刷新当前 PATH' `
                -Description '重新读取系统和用户 PATH。若仍不可用，请在编辑器内安装 Shell Command。' `
                -Risk 'Safe')
    }

    return New-CodeMateCheck `
        -Id 'editor' `
        -Name 'VS Code / Cursor' `
        -Status 'Warn' `
        -Message '未检测到 VS Code 或 Cursor。AI 编程工具通常需要至少一个编辑器。' `
        -RepairAction $vscodeRepair `
        -Details @(
            [pscustomobject]@{ Alternative = 'Cursor'; RepairAction = $cursorRepair }
        )
}

function Get-CodeMateShortcutTarget {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($Path)
        return $shortcut.TargetPath
    } catch {
        return $null
    }
}

function Get-CodeMateExecutableFromCommandLine {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }

    $trimmed = $CommandLine.Trim()
    $path = $null

    if ($trimmed.StartsWith('"')) {
        $endQuote = $trimmed.IndexOf('"', 1)
        if ($endQuote -gt 1) {
            $path = $trimmed.Substring(1, $endQuote - 1)
        }
    } else {
        $space = $trimmed.IndexOf(' ')
        $path = if ($space -gt 0) { $trimmed.Substring(0, $space) } else { $trimmed }
    }

    if ([string]::IsNullOrWhiteSpace($path)) {
        return $null
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($path)
    if (Test-Path -LiteralPath $expanded -PathType Leaf) {
        try {
            return (Get-Item -LiteralPath $expanded).FullName
        } catch {
            return $expanded
        }
    }

    return $expanded
}

function Find-CodeMateInstalledApp {
    param(
        [Parameter(Mandatory = $true)][string[]]$NamePatterns,
        [string[]]$KnownPaths = @()
    )

    $foundApps = @()

    $shortcutRoots = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        [Environment]::GetFolderPath('StartMenu'),
        [Environment]::GetFolderPath('CommonStartMenu')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    foreach ($root in $shortcutRoots) {
        $shortcuts = Get-ChildItem -LiteralPath $root -Recurse -Filter '*.lnk' -ErrorAction SilentlyContinue
        foreach ($shortcut in $shortcuts) {
            foreach ($pattern in $NamePatterns) {
                if ($shortcut.BaseName -match $pattern) {
                    $target = Get-CodeMateShortcutTarget -Path $shortcut.FullName
                    if ($target) {
                        $foundApps += [pscustomobject]@{
                            Source = 'shortcut'
                            Path = $target
                            Evidence = $shortcut.FullName
                        }
                    }
                }
            }
        }
    }

    foreach ($candidate in $KnownPaths) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            try {
                $resolved = (Get-Item -LiteralPath $expanded).FullName
            } catch {
                $resolved = $expanded
            }

            $foundApps += [pscustomobject]@{
                Source = 'install-path'
                Path = $resolved
                Evidence = $candidate
            }
        }
    }

    $foundApps | Sort-Object Path -Unique
}

function Find-CodeMateAppxPackage {
    param(
        [Parameter(Mandatory = $true)][string[]]$NamePatterns
    )

    $foundPackages = @()

    try {
        $packages = @(Get-AppxPackage -ErrorAction Stop)
    } catch {
        return $foundPackages
    }

    foreach ($package in $packages) {
        $fields = @(
            [string]$package.Name,
            [string]$package.PackageFullName,
            [string]$package.InstallLocation,
            [string]$package.Publisher
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        foreach ($pattern in $NamePatterns) {
            if ($fields | Where-Object { $_ -match $pattern } | Select-Object -First 1) {
                $foundPackages += [pscustomobject]@{
                    Source   = 'appx'
                    Path     = $package.InstallLocation
                    Evidence = $package.PackageFullName
                }
                break
            }
        }
    }

    $foundPackages | Sort-Object Evidence -Unique
}

function Test-CodeMateUrlProtocol {
    param([Parameter(Mandatory = $true)][string]$Protocol)

    $paths = @(
        "HKCU:\Software\Classes\$Protocol",
        "Registry::HKEY_CLASSES_ROOT\$Protocol"
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            $commandPath = Join-Path $path 'shell\open\command'
            $command = $null
            if (Test-Path -LiteralPath $commandPath) {
                $command = (Get-ItemProperty -LiteralPath $commandPath -ErrorAction SilentlyContinue).'(default)'
            }

            return [pscustomobject]@{
                Found = $true
                Path = $path
                Command = $command
            }
        }
    }

    return [pscustomobject]@{
        Found = $false
        Path = $null
        Command = $null
    }
}

function Test-CodeMateCCSwitch {
    $repair = New-CodeMateRepairAction `
        -Id 'open-ccswitch-setup' `
        -Label '打开官方安装说明' `
        -Description '跳转到官方项目页面，按官方流程安装。' `
        -Risk 'Manual' `
        -Url 'https://github.com/farion1231/cc-switch'

    $cli = Get-CodeMateCommand -Name 'ccswitch'
    $cliAlt = Get-CodeMateCommand -Name 'cc-switch'
    $protocol = Test-CodeMateUrlProtocol -Protocol 'ccswitch'
    $protocolExecutable = Get-CodeMateExecutableFromCommandLine -CommandLine $protocol.Command
    $knownPaths = @(
        "$env:LOCALAPPDATA\Programs\CC Switch\cc-switch.exe",
        "$env:LOCALAPPDATA\Programs\CC Switch\CC Switch.exe",
        "$env:LOCALAPPDATA\Programs\cc-switch\cc-switch.exe",
        "$env:LOCALAPPDATA\Programs\ccswitch\ccswitch.exe",
        "$env:ProgramFiles\CC Switch\cc-switch.exe",
        "$env:ProgramFiles\CC Switch\CC Switch.exe",
        "${env:ProgramFiles(x86)}\CC Switch\cc-switch.exe",
        "${env:ProgramFiles(x86)}\CC Switch\CC Switch.exe"
    )

    if ($protocolExecutable) {
        $knownPaths += $protocolExecutable
    }

    $apps = @(Find-CodeMateInstalledApp `
        -NamePatterns @('(?i)cc\s*switch', '(?i)ccswitch', '(?i)cc-switch') `
        -KnownPaths $knownPaths)

    $detected = @()
    if ($cli) { $detected += ('CLI ccswitch: {0}' -f $cli.Source) }
    if ($cliAlt) { $detected += ('CLI cc-switch: {0}' -f $cliAlt.Source) }
    if ($protocol.Found) { $detected += ('ccswitch:// 协议: {0}' -f $protocol.Command) }
    foreach ($app in $apps | Select-Object -First 5) {
        if ($app.Source -eq 'shortcut') {
            $detected += ('快捷方式: {0} -> {1}' -f $app.Evidence, $app.Path)
        } else {
            $detected += ('安装路径: {0}' -f $app.Path)
        }
    }

    if ($detected.Count -gt 0) {
        $hasCli = $null -ne $cli -or $null -ne $cliAlt
        $message = if ($hasCli) {
            '已检测到 CC Switch，并且命令行入口可用。'
        } else {
            '已检测到 CC Switch 桌面版/协议。命令行入口未检测到，但不影响图形界面和 deep link 导入。'
        }

        return New-CodeMateCheck `
            -Id 'ccswitch' `
            -Name 'CC Switch' `
            -Status 'Pass' `
            -Message $message `
            -Detected ($detected -join '; ')
    }

    return New-CodeMateCheck `
        -Id 'ccswitch' `
        -Name 'CC Switch' `
        -Status 'Warn' `
        -Message '未检测到 CC Switch 桌面版、ccswitch:// 协议或命令行入口。' `
        -RepairAction $repair
}

function Test-CodeMateAiTools {
    $tools = @(
        @{ Id = 'codex'; Name = 'Codex CLI'; Command = 'codex'; Importance = 'Optional'; Url = 'https://developers.openai.com/codex/cli' },
        @{ Id = 'claude'; Name = 'Claude Code'; Command = 'claude'; Importance = 'Optional'; Url = 'https://code.claude.com/docs/en/setup' }
    )

    $checks = @()

    foreach ($tool in $tools) {
        $repair = New-CodeMateRepairAction `
            -Id ('open-{0}-setup' -f $tool.Id) `
            -Label '打开官方安装说明' `
            -Description '跳转到官方文档或项目页面，按官方流程安装。' `
            -Risk 'Manual' `
            -Url $tool.Url

        $checks += Test-CodeMateCommandVersion `
            -Id $tool.Id `
            -Name $tool.Name `
            -Command $tool.Command `
            -Arguments @('--version') `
            -MissingRepairAction $repair `
            -Importance 'Optional'
    }

    $checks += Test-CodeMateCCSwitch

    return $checks
}

function Get-CodeMateExistingPaths {
    param([string[]]$Paths = @())

    $found = @()
    foreach ($candidate in $Paths) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded -PathType Leaf) {
            try {
                $found += (Get-Item -LiteralPath $expanded).FullName
            } catch {
                $found += $expanded
            }
        }
    }

    return @($found | Sort-Object -Unique)
}

function New-CodeMateToolStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Installed', 'Attention', 'Missing')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Summary,
        [string]$Detected
    )

    [pscustomobject]@{
        Id       = $Id
        Name     = $Name
        Status   = $Status
        Summary  = $Summary
        Detected = $Detected
    }
}

function Get-CodeMateCommandInstallStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Command,
        [string[]]$KnownPaths = @(),
        [string[]]$VersionArguments = @('--version'),
        [switch]$AllowKnownPathsAsInstalled
    )

    $cmd = Get-CodeMateCommand -Name $Command
    if ($cmd) {
        $result = Invoke-CodeMateProcess -FilePath $cmd.Source -ArgumentList $VersionArguments
        $detected = if ($result.Output) {
            '{0} at {1}' -f $result.Output.Split("`n")[0].Trim(), $cmd.Source
        } else {
            $cmd.Source
        }

        if ($result.ExitCode -eq 0) {
            return New-CodeMateToolStatus `
                -Id $Id `
                -Name $Name `
                -Status 'Installed' `
                -Summary '已安装，命令入口可用。' `
                -Detected $detected
        }

        return New-CodeMateToolStatus `
            -Id $Id `
            -Name $Name `
            -Status 'Attention' `
            -Summary '已找到命令入口，但版本检测失败。建议重新安装或修复 PATH。' `
            -Detected $detected
    }

    $foundPaths = @(Get-CodeMateExistingPaths -Paths $KnownPaths)
    if ($foundPaths.Count -gt 0) {
        $status = if ($AllowKnownPathsAsInstalled) { 'Installed' } else { 'Attention' }
        $summary = if ($AllowKnownPathsAsInstalled) {
            '已安装桌面版，但命令入口当前不可用。'
        } else {
            '检测到安装目录，但当前终端无法直接调用。'
        }

        return New-CodeMateToolStatus `
            -Id $Id `
            -Name $Name `
            -Status $status `
            -Summary $summary `
            -Detected ($foundPaths -join '; ')
    }

    return New-CodeMateToolStatus `
        -Id $Id `
        -Name $Name `
        -Status 'Missing' `
        -Summary '未检测到安装。'
}

function Get-CodeMateInstallToolStatusReport {
    $statuses = @()

    $codexAppPaths = @(
        "$env:LOCALAPPDATA\Programs\Codex\Codex.exe",
        "$env:LOCALAPPDATA\Programs\OpenAI Codex\Codex.exe",
        "$env:ProgramFiles\Codex\Codex.exe",
        "$env:ProgramFiles\OpenAI Codex\Codex.exe"
    )
    $codexApp = @(Find-CodeMateInstalledApp `
        -NamePatterns @('(?i)^codex$', '(?i)openai\s*codex') `
        -KnownPaths $codexAppPaths)
    $codexAppx = @(Find-CodeMateAppxPackage -NamePatterns @('(?i)^OpenAI\.Codex$', '(?i)OpenAI\.Codex_', '(?i)\bCodex\b'))
    $codexEvidence = @(@(
        $codexApp | Select-Object -First 3 | ForEach-Object { $_.Path }
        $codexAppx | Select-Object -First 3 | ForEach-Object { '{0} ({1})' -f $_.Evidence, $_.Path }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($codexEvidence.Count -gt 0) {
        $statuses += New-CodeMateToolStatus `
            -Id 'codex-app' `
            -Name 'Codex 桌面版' `
            -Status 'Installed' `
            -Summary '已检测到 Codex 桌面版安装。' `
            -Detected ($codexEvidence -join '; ')
    } else {
        $statuses += New-CodeMateToolStatus `
            -Id 'codex-app' `
            -Name 'Codex 桌面版' `
            -Status 'Missing' `
            -Summary '未检测到桌面版安装。'
    }

    $statuses += Get-CodeMateCommandInstallStatus `
        -Id 'cursor' `
        -Name 'Cursor 桌面版' `
        -Command 'cursor' `
        -KnownPaths @(
            "$env:LOCALAPPDATA\Programs\cursor\Cursor.exe",
            "$env:ProgramFiles\Cursor\Cursor.exe"
        ) `
        -AllowKnownPathsAsInstalled

    $statuses += Get-CodeMateCommandInstallStatus `
        -Id 'codex' `
        -Name 'Codex 命令行版' `
        -Command 'codex'

    $statuses += Get-CodeMateCommandInstallStatus `
        -Id 'claude' `
        -Name 'Claude Code 命令行版' `
        -Command 'claude'

    $ccSwitchCheck = Test-CodeMateCCSwitch
    if ($ccSwitchCheck.Status -eq 'Pass') {
        $statuses += New-CodeMateToolStatus `
            -Id 'ccswitch' `
            -Name 'CC Switch 桌面版' `
            -Status 'Installed' `
            -Summary '已检测到桌面版或 deep link 协议。' `
            -Detected $ccSwitchCheck.Detected
    } else {
        $statuses += New-CodeMateToolStatus `
            -Id 'ccswitch' `
            -Name 'CC Switch 桌面版' `
            -Status 'Missing' `
            -Summary '未检测到安装。'
    }

    return $statuses
}

function Get-CodeMateRepairPriority {
    param([string]$ActionId)

    switch ($ActionId) {
        'open-app-installer-store' { return 10 }
        'set-execution-policy' { return 20 }
        'add-known-tool-path' { return 25 }
        'install-git-winget' { return 30 }
        'install-node-winget' { return 40 }
        'add-npm-global-path' { return 50 }
        'refresh-path' { return 90 }
        default { return 100 }
    }
}

function Get-CodeMateAutomaticRepairPlan {
    param([object]$Report)

    if (-not $Report) {
        $Report = Get-CodeMateHealthReport
    }

    $actions = @{}
    $manualActions = @()
    $wingetBlocked = $false

    foreach ($check in @($Report.Checks)) {
        if ($check.Status -eq 'Pass' -or -not $check.RepairAction) {
            continue
        }

        if ($check.Id -eq 'winget' -and $check.Status -ne 'Pass') {
            $wingetBlocked = $true
        }

        $entry = [pscustomobject]@{
            CheckId      = $check.Id
            CheckName    = $check.Name
            ActionId     = $check.RepairAction.Id
            Label        = $check.RepairAction.Label
            Description  = $check.RepairAction.Description
            Risk         = $check.RepairAction.Risk
            Command      = $check.RepairAction.Command
            Url          = $check.RepairAction.Url
        }

        if ($check.RepairAction.Risk -eq 'Manual') {
            $manualActions += $entry
            continue
        }

        if (-not $actions.ContainsKey($entry.ActionId)) {
            $actions[$entry.ActionId] = $entry
        }
    }

    $runnableActions = @($actions.Values | Sort-Object @{ Expression = { Get-CodeMateRepairPriority -ActionId $_.ActionId } }, @{ Expression = { $_.CheckName } })

    [pscustomobject]@{
        RunnableActions = $runnableActions
        ManualActions   = @($manualActions | Sort-Object CheckName)
        WingetBlocked   = $wingetBlocked
    }
}

function Invoke-CodeMateAutomaticRepair {
    param(
        [object]$Report,
        [int]$MaxActions = 8
    )

    if (-not $Report) {
        $Report = Get-CodeMateHealthReport
    }

    $executed = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[object]
    $notes = New-Object System.Collections.Generic.List[string]
    $executedActionIds = @{}
    $needsUserCompletion = $false
    $initialPlan = Get-CodeMateAutomaticRepairPlan -Report $Report
    $initialActionCount = [Math]::Max(1, @($initialPlan.RunnableActions).Count)

    Write-CodeMateProgressEvent `
        -ActionId 'automatic-repair' `
        -Step '自动修复' `
        -Stage 'plan' `
        -Status 'Running' `
        -Message ('已生成修复计划：{0} 个自动步骤。' -f @($initialPlan.RunnableActions).Count) `
        -Percent 0

    for ($index = 0; $index -lt $MaxActions; $index++) {
        $plan = Get-CodeMateAutomaticRepairPlan -Report $Report
        $nextAction = $null

        foreach ($candidate in @($plan.RunnableActions)) {
            if (-not $executedActionIds.ContainsKey($candidate.ActionId)) {
                $nextAction = $candidate
                break
            }
        }

        if (-not $nextAction) {
            if ($plan.ManualActions.Count -gt 0) {
                $notes.Add('仍有需要手动处理的项目。')
            }
            break
        }

        $executedActionIds[$nextAction.ActionId] = $true
        $stepNumber = $executedActionIds.Count
        $basePercent = [Math]::Min(95, [int][Math]::Floor((($stepNumber - 1) * 100.0) / $initialActionCount))

        Write-CodeMateProgressEvent `
            -ActionId $nextAction.ActionId `
            -Step $nextAction.CheckName `
            -Stage 'repair' `
            -Status 'Running' `
            -Message ('开始修复：{0}' -f $nextAction.Label) `
            -Percent $basePercent `
            -Detail $nextAction.Description

        try {
            $result = Invoke-CodeMateRepair -ActionId $nextAction.ActionId -Context $nextAction
            $executed.Add([pscustomobject]@{
                ActionId = $nextAction.ActionId
                Label    = $nextAction.Label
                Result   = $result.Message
            })
            Write-CodeMateProgressEvent `
                -ActionId $nextAction.ActionId `
                -Step $nextAction.CheckName `
                -Stage 'repair' `
                -Status 'Succeeded' `
                -Message ('修复完成：{0}' -f $nextAction.Label) `
                -Percent ([Math]::Min(95, [int][Math]::Floor(($stepNumber * 100.0) / $initialActionCount))) `
                -Detail $result.Message
        } catch {
            $failed.Add([pscustomobject]@{
                ActionId = $nextAction.ActionId
                Label    = $nextAction.Label
                Error    = $_.Exception.Message
            })
            Write-CodeMateProgressEvent `
                -ActionId $nextAction.ActionId `
                -Step $nextAction.CheckName `
                -Stage 'repair' `
                -Status 'Failed' `
                -Message ('修复失败：{0}' -f $nextAction.Label) `
                -Percent ([Math]::Min(95, [int][Math]::Floor(($stepNumber * 100.0) / $initialActionCount))) `
                -Detail $_.Exception.Message
        }

        Write-CodeMateProgressEvent `
            -ActionId 'automatic-repair' `
            -Step '环境复检' `
            -Stage 'recheck' `
            -Status 'Running' `
            -Message '正在重新检测环境状态。'

        $Report = Get-CodeMateHealthReport
    }

    Write-CodeMateProgressEvent `
        -ActionId 'automatic-repair' `
        -Step '最终复检' `
        -Stage 'recheck' `
        -Status 'Running' `
        -Message '正在执行最终环境复检。' `
        -Percent 96

    $finalReport = Get-CodeMateHealthReport
    $finalPlan = Get-CodeMateAutomaticRepairPlan -Report $finalReport

    $executedCount = $executed.Count
    $failedCount = $failed.Count
    $finalStatus = if ($failedCount -gt 0) { 'Failed' } else { 'Succeeded' }
    Write-CodeMateProgressEvent `
        -ActionId 'automatic-repair' `
        -Step '自动修复' `
        -Stage 'complete' `
        -Status $finalStatus `
        -Message ('自动修复流程结束：成功 {0}，失败 {1}。' -f $executedCount, $failedCount) `
        -Percent 100

    [pscustomobject]@{
        ExecutedActions     = @($executed.ToArray())
        FailedActions       = @($failed.ToArray())
        Notes               = @($notes.ToArray())
        NeedsUserCompletion = $needsUserCompletion
        FinalReport         = $finalReport
        FinalPlan           = $finalPlan
    }
}

function Test-CodeMatePathHealth {
    $pathItems = @($env:Path -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $missing = @()
    $duplicates = @{}
    $normalizedSeen = @{}

    foreach ($item in $pathItems) {
        $expanded = [Environment]::ExpandEnvironmentVariables($item).TrimEnd('\')
        if (-not [string]::IsNullOrWhiteSpace($expanded) -and -not (Test-Path -LiteralPath $expanded)) {
            $missing += $item
        }

        $key = $expanded.ToLowerInvariant()
        if ($normalizedSeen.ContainsKey($key)) {
            $duplicates[$key] = $true
        } else {
            $normalizedSeen[$key] = $true
        }
    }

    $details = @(
        [pscustomobject]@{ Name = 'PathItemCount'; Value = $pathItems.Count },
        [pscustomobject]@{ Name = 'MissingPathCount'; Value = $missing.Count },
        [pscustomobject]@{ Name = 'DuplicatePathCount'; Value = $duplicates.Count }
    )

    if ($missing.Count -gt 8) {
        return New-CodeMateCheck `
            -Id 'path-health' `
            -Name 'PATH 健康度' `
            -Status 'Warn' `
            -Message 'PATH 中存在较多失效目录，可能拖慢命令查找或导致版本混乱。' `
            -Detected ("失效目录 {0} 个，重复目录 {1} 个。" -f $missing.Count, $duplicates.Count) `
            -Details $details `
            -RepairAction (New-CodeMateRepairAction `
                -Id 'refresh-path' `
                -Label '刷新当前 PATH' `
                -Description '重新读取系统和用户 PATH，适合刚安装完工具但当前窗口识别不到的场景。' `
                -Risk 'Safe')
    }

    return New-CodeMateCheck `
        -Id 'path-health' `
        -Name 'PATH 健康度' `
        -Status 'Pass' `
        -Message 'PATH 没有明显异常。' `
        -Detected ("目录 {0} 个，失效 {1} 个，重复 {2} 个。" -f $pathItems.Count, $missing.Count, $duplicates.Count) `
        -Details $details
}

function Get-CodeMateHealthReport {
    $checks = @()

    $checks += Test-CodeMateOperatingSystem
    $checks += Test-CodeMatePowerShell
    $checks += Test-CodeMatePathHealth
    $checks += Test-CodeMateWinget
    $checks += Test-CodeMateGit
    $checks += Test-CodeMateNode
    $checks += Test-CodeMateNpm
    $checks += Test-CodeMateNpmGlobalPath

    $summary = [ordered]@{
        Pass = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
        Warn = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
        Fail = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
        Info = @($checks | Where-Object { $_.Status -eq 'Info' }).Count
    }

    [pscustomobject]@{
        Product     = 'CodeMate Setup'
        Version     = '0.1.0'
        GeneratedAt = (Get-Date).ToString('s')
        Computer    = $env:COMPUTERNAME
        User        = $env:USERNAME
        Summary     = [pscustomobject]$summary
        Checks      = $checks
    }
}

function Export-CodeMateHealthReport {
    param(
        [Parameter(Mandatory = $true)][object]$Report,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $safeReport = ConvertTo-CodeMateRedactedReport -Value $Report
    $safeReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function Invoke-CodeMateRepair {
    param(
        [Parameter(Mandatory = $true)][string]$ActionId,
        [object]$Context
    )

    switch ($ActionId) {
        'set-execution-policy' {
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'PowerShell 执行策略' `
                -Stage 'repair' `
                -Status 'Running' `
                -Message '正在设置当前用户执行策略为 RemoteSigned。'
            Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'PowerShell 执行策略' `
                -Stage 'repair' `
                -Status 'Succeeded' `
                -Message '已将当前用户执行策略设为 RemoteSigned。'
            return [pscustomobject]@{ Success = $true; Message = '已将当前用户执行策略设为 RemoteSigned。' }
        }

        'open-app-installer-store' {
            return Install-CodeMateWinget
        }

        'refresh-path' {
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'PATH' `
                -Stage 'repair' `
                -Status 'Running' `
                -Message '正在刷新当前进程 PATH。'
            $result = Update-CodeMateProcessPath
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'PATH' `
                -Stage 'repair' `
                -Status 'Succeeded' `
                -Message $result.Message
            return $result
        }

        'add-npm-global-path' {
            if (-not $Context -or -not $Context.Command) {
                throw '缺少 npm 全局目录。'
            }

            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'npm 全局命令 PATH' `
                -Stage 'repair' `
                -Status 'Running' `
                -Message ('正在写入用户 PATH：{0}' -f $Context.Command)
            $result = Add-CodeMateUserPathItem -PathItem $Context.Command
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'npm 全局命令 PATH' `
                -Stage 'repair' `
                -Status 'Succeeded' `
                -Message $result.Message
            return $result
        }

        'add-known-tool-path' {
            if (-not $Context -or -not $Context.Command) {
                throw '缺少要加入 PATH 的目录。'
            }

            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'PATH' `
                -Stage 'repair' `
                -Status 'Running' `
                -Message ('正在加入工具目录到 PATH：{0}' -f $Context.Command)
            $result = Add-CodeMateKnownToolPath -Directory $Context.Command
            Write-CodeMateProgressEvent `
                -ActionId $ActionId `
                -Step 'PATH' `
                -Stage 'repair' `
                -Status 'Succeeded' `
                -Message $result.Message
            return $result
        }

        'install-git-winget' {
            try {
                return Invoke-CodeMateWingetInstall -PackageId 'Git.Git' -DisplayName 'Git'
            } catch {
                $wingetError = $_.Exception.Message
                try {
                    $fallback = Install-CodeMateGitFromSources
                    $fallback.Message = ('winget 安装失败，已切换备用下载源。{0}' -f $fallback.Message)
                    return $fallback
                } catch {
                    throw ("Git 自动安装失败。`nwinget 错误：{0}`n备用源错误：{1}" -f $wingetError, $_.Exception.Message)
                }
            }
        }

        'install-node-winget' {
            try {
                return Invoke-CodeMateWingetInstall -PackageId 'OpenJS.NodeJS.LTS' -DisplayName 'Node.js LTS'
            } catch {
                $wingetError = $_.Exception.Message
                try {
                    $fallback = Install-CodeMateNodeFromSources
                    $fallback.Message = ('winget 安装失败，已切换备用下载源。{0}' -f $fallback.Message)
                    return $fallback
                } catch {
                    throw ("Node.js 自动安装失败。`nwinget 错误：{0}`n备用源错误：{1}" -f $wingetError, $_.Exception.Message)
                }
            }
        }

        'install-vscode-winget' {
            return Invoke-CodeMateWingetInstall -PackageId 'Microsoft.VisualStudioCode' -DisplayName 'VS Code'
        }

        'install-cursor-winget' {
            return Invoke-CodeMateWingetInstall -PackageId 'Anysphere.Cursor' -DisplayName 'Cursor'
        }

        default {
            throw ("暂不支持自动执行该修复动作：{0}" -f $ActionId)
        }
    }
}

Export-ModuleMember -Function @(
    'Get-CodeMateHealthReport',
    'Get-CodeMateInstallToolStatusReport',
    'Get-CodeMateToolInstallSpec',
    'Get-CodeMateAutomaticRepairPlan',
    'Set-CodeMateProgressCallback',
    'Export-CodeMateHealthReport',
    'Invoke-CodeMateRepair',
    'Invoke-CodeMateToolInstall',
    'Invoke-CodeMateToolUninstall',
    'Invoke-CodeMateAutomaticRepair'
)
