$ErrorActionPreference = 'Stop'

$ProgressPreference = 'SilentlyContinue'

$sourcePath = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $PSScriptRoot
} elseif (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
    Join-Path $ScriptRoot 'src'
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    Join-Path (Get-Location).Path 'src'
}
$rootPath = Split-Path -Parent $sourcePath
Import-Module (Join-Path $sourcePath 'CodeMate.Health.psm1') -Force
Import-Module (Join-Path $sourcePath 'CodeMate.Provider.psm1') -Force
Import-Module (Join-Path $sourcePath 'CodeMate.CCSwitch.psm1') -Force
Import-Module (Join-Path $sourcePath 'CodeMate.License.psm1') -Force

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Report = $null
$script:SelectedCheck = $null
$script:ProviderCatalog = Get-CodeMateProviderCatalog
$script:ProviderTestResult = $null
$script:CCSwitchExport = $null
$script:GuiSettingsPath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'CodeMate Setup\gui-settings.json'
$script:ToolStatusReport = @()
$script:SuppressBaseUrlWarning = $false
$script:TestMode = ($env:CODEMATE_TEST_MODE -eq '1')
$script:SimulatedInstalledTools = @{}
$script:HideEntryLicenseGate = ($env:CODEMATE_REQUIRE_LICENSE_GATE -ne '1')
$script:AutoRepairWorker = $null
$script:AutoRepairTimer = $null
$script:RepairProgressRows = @{}
$script:RepairProgressLog = $null
$script:ToolInstallWorker = $null
$script:ToolInstallTimer = $null
$script:ToolInstallLog = $null
$script:CurrentToolInstall = $null
$script:LicenseGateResult = $null
$script:ShowLicenseAdvancedFields = ($env:CODEMATE_LICENSE_ADVANCED -eq '1')

function Get-CodeMateGuiSettings {
    if (-not (Test-Path -LiteralPath $script:GuiSettingsPath)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $script:GuiSettingsPath -Raw | ConvertFrom-Json
    } catch {
        return $null
    }
}

function Test-CodeMateBoundsOnScreen {
    param([Parameter(Mandatory = $true)][System.Drawing.Rectangle]$Bounds)

    foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
        if ($screen.WorkingArea.IntersectsWith($Bounds)) {
            return $true
        }
    }

    return $false
}

function Initialize-CodeMateWindowBounds {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Form)

    $settings = Get-CodeMateGuiSettings
    if (-not $settings -or -not $settings.Window) {
        return
    }

    try {
        $width = [Math]::Max([int]$settings.Window.Width, $Form.MinimumSize.Width)
        $height = [Math]::Max([int]$settings.Window.Height, $Form.MinimumSize.Height)
        $bounds = New-Object System.Drawing.Rectangle(
            [int]$settings.Window.X,
            [int]$settings.Window.Y,
            $width,
            $height
        )

        if (Test-CodeMateBoundsOnScreen -Bounds $bounds) {
            $Form.StartPosition = 'Manual'
            $Form.Bounds = $bounds
        }
    } catch {
    }
}

function Save-CodeMateWindowBounds {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Form)

    if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        return
    }

    $bounds = if ($Form.WindowState -eq [System.Windows.Forms.FormWindowState]::Normal) {
        $Form.Bounds
    } else {
        $Form.RestoreBounds
    }

    if ($bounds.Width -lt $Form.MinimumSize.Width -or $bounds.Height -lt $Form.MinimumSize.Height) {
        return
    }

    $settings = [ordered]@{
        Window = [ordered]@{
            X      = $bounds.X
            Y      = $bounds.Y
            Width  = $bounds.Width
            Height = $bounds.Height
        }
    }

    try {
        $directory = Split-Path -Parent $script:GuiSettingsPath
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        $settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:GuiSettingsPath -Encoding UTF8
    } catch {
    }
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 120,
        [int]$Height = 24
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($Width, $Height)
    return $label
}

function New-TextBox {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width = 320,
        [string]$Text = '',
        [switch]$Password
    )

    $box = New-Object System.Windows.Forms.TextBox
    $box.Location = New-Object System.Drawing.Point($X, $Y)
    $box.Size = New-Object System.Drawing.Size($Width, 28)
    $box.Text = $Text
    if ($Password) {
        $box.UseSystemPasswordChar = $true
    }
    return $box
}

function New-Button {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$Width = 110
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($Width, 32)
    return $button
}

function Format-CodeMateLicenseStatusText {
    param([object]$GateResult)

    if (-not $GateResult -or -not $GateResult.Success) {
        return '未授权'
    }

    $license = $GateResult.License
    $plan = if ($license -and $license.plan) { $license.plan } else { 'unknown' }
    $mode = switch ($GateResult.Mode) {
        'Online' { '在线验证' }
        'OfflineGrace' { '离线宽限' }
        'Hidden' { '入口已隐藏' }
        default { $GateResult.Mode }
    }
    $expires = if ($license -and $license.expiresAt) { ('，到期：{0}' -f $license.expiresAt) } else { '' }
    return ('授权有效：{0}（{1}{2}）' -f $plan, $mode, $expires)
}

function Format-CodeMateLicenseUserMessage {
    param([string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return '请输入授权码完成验证。'
    }

    switch -Regex ($Message) {
        'No local license found|Local license is incomplete|activate again' {
            return '请输入授权码完成验证。'
        }
        'License code not found|not found' {
            return '授权码不存在，请检查后重试。'
        }
        'Activation limit reached' {
            return '该授权码已达到可绑定设备数量上限。'
        }
        'License expired|has expired' {
            return '授权码已过期。'
        }
        'License is not active|revoked' {
            return '授权码当前不可用，请联系管理员。'
        }
        'Invalid activation token|Activation not found|different machine|MachineMismatch' {
            return '当前设备未通过授权验证，请重新激活。'
        }
        'timed out|Unable to connect|No such host|NameResolutionFailure|connection|refused|server' {
            return '暂时无法连接授权服务器，请检查网络后重试。'
        }
        default {
            return $Message
        }
    }
}

function New-CodeMateBypassedLicenseGateResult {
    param(
        [string]$Mode = 'Bypass',
        [string]$Message = 'License gate bypassed.'
    )

    return [pscustomobject]@{
        Success = $true
        Mode = $Mode
        Message = $Message
        License = [pscustomobject]@{
            server = Get-CodeMateDefaultLicenseServer
            code = 'TEST-MODE'
            plan = 'test'
            status = 'active'
            expiresAt = $null
            machineId = Get-CodeMateMachineId
        }
    }
}

function Show-CodeMateLicenseGate {
    if ($script:TestMode -or $env:CODEMATE_SKIP_LICENSE_GATE -eq '1') {
        return New-CodeMateBypassedLicenseGateResult -Mode 'Bypass' -Message 'License gate bypassed for test mode.'
    }

    if ($script:HideEntryLicenseGate) {
        return New-CodeMateBypassedLicenseGateResult -Mode 'Hidden' -Message 'Entry license gate hidden for test build.'
    }

    $serverDefault = Get-CodeMateDefaultLicenseServer
    $localLicense = Get-CodeMateLocalLicense
    if ($localLicense -and $localLicense.server) {
        $serverDefault = $localLicense.server
    }

    $initialCheck = Test-CodeMateLicenseGate -LicenseServer $serverDefault
    if ($initialCheck.Success) {
        return $initialCheck
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'CodeMate 授权验证'
    $dialog.StartPosition = 'CenterScreen'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = if ($script:ShowLicenseAdvancedFields) {
        New-Object System.Drawing.Size(560, 420)
    } else {
        New-Object System.Drawing.Size(520, 330)
    }
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Location = New-Object System.Drawing.Point(22, 18)
    $titleLabel.Size = New-Object System.Drawing.Size(500, 28)
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = '请输入授权码后继续'
    $dialog.Controls.Add($titleLabel)

    $descLabel = New-Object System.Windows.Forms.Label
    $descLabel.Location = New-Object System.Drawing.Point(22, 54)
    $descLabel.Size = New-Object System.Drawing.Size(470, 48)
    $descLabel.Text = '请输入购买或管理员提供的授权码。验证通过后即可进入 CodeMate Setup。'
    $dialog.Controls.Add($descLabel)

    $serverBox = New-TextBox -X 140 -Y 104 -Width 340 -Text $serverDefault
    $serverBox.Visible = $false

    if ($script:ShowLicenseAdvancedFields) {
        $machineLabel = New-Object System.Windows.Forms.Label
        $machineLabel.Location = New-Object System.Drawing.Point(22, 104)
        $machineLabel.Size = New-Object System.Drawing.Size(510, 24)
        $machineLabel.Text = ('本机机器码：{0}...' -f (Get-CodeMateMachineId).Substring(0, 16))
        $machineLabel.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
        $dialog.Controls.Add($machineLabel)

        $dialog.Controls.Add((New-Label -Text '授权服务器' -X 22 -Y 144 -Width 110))
        $serverBox.Location = New-Object System.Drawing.Point(140, 140)
        $serverBox.Size = New-Object System.Drawing.Size(370, 28)
        $serverBox.Visible = $true
        $dialog.Controls.Add($serverBox)
    }

    $codeY = if ($script:ShowLicenseAdvancedFields) { 186 } else { 118 }
    $emailY = if ($script:ShowLicenseAdvancedFields) { 228 } else { 164 }
    $statusY = if ($script:ShowLicenseAdvancedFields) { 270 } else { 214 }
    $statusHeight = if ($script:ShowLicenseAdvancedFields) { 78 } else { 44 }
    $buttonY = if ($script:ShowLicenseAdvancedFields) { 362 } else { 276 }
    $fieldWidth = if ($script:ShowLicenseAdvancedFields) { 370 } else { 330 }

    $dialog.Controls.Add((New-Label -Text '授权码' -X 22 -Y $codeY -Width 110))
    $codeBox = New-TextBox -X 140 -Y ($codeY - 4) -Width $fieldWidth
    if ($localLicense -and $localLicense.code) {
        $codeBox.Text = $localLicense.code
    }
    $dialog.Controls.Add($codeBox)

    $dialog.Controls.Add((New-Label -Text '邮箱（选填）' -X 22 -Y $emailY -Width 110))
    $emailBoxLocal = New-TextBox -X 140 -Y ($emailY - 4) -Width $fieldWidth
    $dialog.Controls.Add($emailBoxLocal)

    $statusBox = New-Object System.Windows.Forms.TextBox
    $statusBox.Location = New-Object System.Drawing.Point(22, $statusY)
    $statusBox.Size = New-Object System.Drawing.Size(($dialog.ClientSize.Width - 44), $statusHeight)
    $statusBox.Multiline = $true
    $statusBox.ReadOnly = $true
    $statusBox.ScrollBars = if ($script:ShowLicenseAdvancedFields) { 'Vertical' } else { 'None' }
    $statusBox.Text = ('当前状态：{0}' -f (Format-CodeMateLicenseUserMessage -Message $initialCheck.Message))
    $dialog.Controls.Add($statusBox)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Location = New-Object System.Drawing.Point(22, $buttonY)
    $buttonPanel.Size = New-Object System.Drawing.Size(($dialog.ClientSize.Width - 44), 40)
    $buttonPanel.FlowDirection = 'RightToLeft'
    $dialog.Controls.Add($buttonPanel)

    $exitButton = New-Object System.Windows.Forms.Button
    $exitButton.Text = '退出'
    $exitButton.Width = 90
    $exitButton.Height = 32
    $exitButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($exitButton)

    $activateButton = New-Object System.Windows.Forms.Button
    $activateButton.Text = '激活并进入'
    $activateButton.Width = 120
    $activateButton.Height = 32
    $buttonPanel.Controls.Add($activateButton)

    $refreshButtonLocal = New-Object System.Windows.Forms.Button
    $refreshButtonLocal.Text = '重新验证'
    $refreshButtonLocal.Width = 100
    $refreshButtonLocal.Height = 32
    if ($script:ShowLicenseAdvancedFields) {
        $buttonPanel.Controls.Add($refreshButtonLocal)
    }

    $script:PendingLicenseGateResult = $null

    $refreshButtonLocal.Add_Click({
        $statusBox.Text = '正在重新验证本地授权...'
        $dialog.Refresh()
        $result = Test-CodeMateLicenseGate -LicenseServer $serverBox.Text
        if ($result.Success) {
            $script:PendingLicenseGateResult = $result
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        } else {
            $statusBox.Text = ('验证失败：{0}' -f (Format-CodeMateLicenseUserMessage -Message $result.Message))
        }
    })

    $activateButton.Add_Click({
        if ([string]::IsNullOrWhiteSpace($codeBox.Text)) {
            $statusBox.Text = '请输入授权码。'
            return
        }

        if ([string]::IsNullOrWhiteSpace($serverBox.Text)) {
            $serverBox.Text = Get-CodeMateDefaultLicenseServer
        }

        if ([string]::IsNullOrWhiteSpace($serverBox.Text)) {
            $statusBox.Text = '授权服务暂不可用，请稍后重试。'
            return
        }

        $activateButton.Enabled = $false
        $refreshButtonLocal.Enabled = $false
        $statusBox.Text = '正在激活授权码并绑定本机...'
        $dialog.Refresh()

        try {
            $result = Activate-CodeMateLicense -LicenseServer $serverBox.Text -LicenseCode $codeBox.Text -Email $emailBoxLocal.Text
            if ($result.Success) {
                $script:PendingLicenseGateResult = [pscustomobject]@{
                    Success = $true
                    Mode = 'Online'
                    Message = $result.Message
                    License = $result.License
                }
                $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
                $dialog.Close()
            } else {
                $statusBox.Text = ('激活失败：{0}' -f (Format-CodeMateLicenseUserMessage -Message $result.Message))
            }
        } catch {
            $statusBox.Text = ('激活失败：{0}' -f (Format-CodeMateLicenseUserMessage -Message $_.Exception.Message))
        } finally {
            $activateButton.Enabled = $true
            $refreshButtonLocal.Enabled = $true
        }
    })

    $dialog.AcceptButton = $activateButton
    $dialog.CancelButton = $exitButton

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK -or -not $script:PendingLicenseGateResult -or -not $script:PendingLicenseGateResult.Success) {
        $script:PendingLicenseGateResult = $null
        return [pscustomobject]@{
            Success = $false
            Mode = 'Cancelled'
            Message = 'License gate cancelled.'
            License = $null
        }
    }

    $result = $script:PendingLicenseGateResult
    $script:PendingLicenseGateResult = $null
    return $result
}

function New-CodeMateSimulatedReport {
    $checks = @(
        [pscustomobject]@{
            Id = 'os'
            Name = 'Windows 版本'
            Status = 'Pass'
            Message = '模拟：系统版本适合安装主流 AI 编程工具。'
            Detected = 'TEST MODE: Windows 11 64-bit'
            RepairAction = $null
            Details = @()
        },
        [pscustomobject]@{
            Id = 'powershell'
            Name = 'PowerShell 执行策略'
            Status = 'Pass'
            Message = '模拟：当前用户执行策略适合运行本地诊断和官方安装脚本。'
            Detected = 'TEST MODE: RemoteSigned'
            RepairAction = $null
            Details = @()
        },
        [pscustomobject]@{
            Id = 'path'
            Name = 'PATH 健康度'
            Status = 'Pass'
            Message = '模拟：PATH 没有明显异常。'
            Detected = 'TEST MODE: PATH OK'
            RepairAction = $null
            Details = @()
        },
        [pscustomobject]@{
            Id = 'winget'
            Name = 'Windows 包管理器 winget'
            Status = 'Pass'
            Message = '模拟：winget 已安装并可用。'
            Detected = 'TEST MODE: winget v1.x'
            RepairAction = $null
            Details = @()
        },
        [pscustomobject]@{
            Id = 'git'
            Name = 'Git'
            Status = 'Pass'
            Message = '模拟：Git 已安装并可用。'
            Detected = 'TEST MODE: git version 2.x'
            RepairAction = $null
            Details = @()
        },
        [pscustomobject]@{
            Id = 'node'
            Name = 'Node.js'
            Status = if ($script:SimulatedInstalledTools.ContainsKey('node')) { 'Pass' } else { 'Fail' }
            Message = if ($script:SimulatedInstalledTools.ContainsKey('node')) { '模拟：Node.js 已安装并可用。' } else { '模拟：未检测到 Node.js，需要一键安装环境。' }
            Detected = if ($script:SimulatedInstalledTools.ContainsKey('node')) { 'TEST MODE: v24.x' } else { 'TEST MODE: missing' }
            RepairAction = if ($script:SimulatedInstalledTools.ContainsKey('node')) { $null } else { [pscustomobject]@{ Id = 'install-node-winget'; Label = '模拟安装 Node.js LTS'; Description = '测试模式：不会下载或安装，只模拟安装完成。'; Risk = 'NeedsConfirmation'; Command = 'TEST MODE'; Url = $null } }
            Details = @()
        },
        [pscustomobject]@{
            Id = 'npm'
            Name = 'npm'
            Status = if ($script:SimulatedInstalledTools.ContainsKey('node')) { 'Pass' } else { 'Fail' }
            Message = if ($script:SimulatedInstalledTools.ContainsKey('node')) { '模拟：npm 已安装并可用。' } else { '模拟：npm 随 Node.js 缺失，需要一键安装环境。' }
            Detected = if ($script:SimulatedInstalledTools.ContainsKey('node')) { 'TEST MODE: npm 11.x' } else { 'TEST MODE: missing' }
            RepairAction = if ($script:SimulatedInstalledTools.ContainsKey('node')) { $null } else { [pscustomobject]@{ Id = 'install-node-winget'; Label = '模拟安装 Node.js LTS'; Description = '测试模式：不会下载或安装，只模拟安装完成。'; Risk = 'NeedsConfirmation'; Command = 'TEST MODE'; Url = $null } }
            Details = @()
        },
        [pscustomobject]@{
            Id = 'npm-global-path'
            Name = 'npm 全局命令 PATH'
            Status = if ($script:SimulatedInstalledTools.ContainsKey('node')) { 'Pass' } else { 'Warn' }
            Message = if ($script:SimulatedInstalledTools.ContainsKey('node')) { '模拟：npm 全局命令目录已在 PATH 中。' } else { '模拟：npm 全局命令目录缺失，安装环境后会自动配置。' }
            Detected = if ($script:SimulatedInstalledTools.ContainsKey('node')) { 'TEST MODE: %APPDATA%\npm' } else { 'TEST MODE: missing' }
            RepairAction = if ($script:SimulatedInstalledTools.ContainsKey('node')) { $null } else { [pscustomobject]@{ Id = 'add-npm-global-path'; Label = '模拟配置 npm 全局 PATH'; Description = '测试模式：不会修改 PATH，只模拟配置完成。'; Risk = 'Safe'; Command = 'TEST MODE'; Url = $null } }
            Details = @()
        }
    )

    [pscustomobject]@{
        Product = 'CodeMate Setup'
        GeneratedAt = (Get-Date).ToString('s')
        Checks = $checks
        Summary = [ordered]@{
            Pass = @($checks | Where-Object { $_.Status -eq 'Pass' }).Count
            Warn = @($checks | Where-Object { $_.Status -eq 'Warn' }).Count
            Fail = @($checks | Where-Object { $_.Status -eq 'Fail' }).Count
            Info = 0
        }
    }
}

function Get-CodeMateSimulatedToolStatuses {
    $definitions = @(
        @{ Id = 'codex-app'; Name = 'Codex 桌面版'; Installed = $true; Summary = '模拟：已安装 Codex 桌面版。'; Detected = 'TEST MODE: OpenAI.Codex AppX' },
        @{ Id = 'codex'; Name = 'Codex 命令行版'; Installed = $true; Summary = '模拟：已安装 Codex CLI。'; Detected = 'TEST MODE: codex 0.x' },
        @{ Id = 'claude'; Name = 'Claude Code 命令行版'; Installed = $true; Summary = '模拟：已安装 Claude Code。'; Detected = 'TEST MODE: claude 2.x' },
        @{ Id = 'cursor'; Name = 'Cursor 桌面版'; Installed = $script:SimulatedInstalledTools.ContainsKey('cursor'); Summary = '模拟：未安装 Cursor。'; Detected = 'TEST MODE: missing' },
        @{ Id = 'ccswitch'; Name = 'CC Switch 桌面版'; Installed = $script:SimulatedInstalledTools.ContainsKey('ccswitch'); Summary = '模拟：未安装 CC Switch。'; Detected = 'TEST MODE: missing' }
    )

    foreach ($definition in $definitions) {
        if ($definition.Installed) {
            [pscustomobject]@{
                Id = $definition.Id
                Name = $definition.Name
                Status = 'Installed'
                Summary = if ($definition.Id -eq 'cursor' -or $definition.Id -eq 'ccswitch') { ('模拟：已安装 {0}。' -f $definition.Name) } else { $definition.Summary }
                Detected = if ($definition.Id -eq 'cursor' -or $definition.Id -eq 'ccswitch') { ('TEST MODE: {0} installed' -f $definition.Id) } else { $definition.Detected }
            }
        } else {
            [pscustomobject]@{
                Id = $definition.Id
                Name = $definition.Name
                Status = 'Missing'
                Summary = $definition.Summary
                Detected = $definition.Detected
            }
        }
    }
}

function Remove-CodeMateProviderV1Suffix {
    param([string]$BaseUrl)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return ''
    }

    $trimmed = $BaseUrl.Trim().TrimEnd('/')
    if ($trimmed -match '(?i)/v1$') {
        return ($trimmed -replace '(?i)/v1$', '')
    }

    return $trimmed
}

function Test-CodeMateProviderBaseUrlHasV1Suffix {
    param([string]$BaseUrl)

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return $false
    }

    return ($BaseUrl.Trim().TrimEnd('/') -match '(?i)/v1$')
}

function Get-CodeMateProviderBaseRootUrl {
    param([string]$BaseUrl)

    return Remove-CodeMateProviderV1Suffix -BaseUrl $BaseUrl
}

function Get-CodeMateProviderEffectiveBaseUrl {
    param(
        [string]$BaseUrl,
        [switch]$ShowPrompt
    )

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return ''
    }

    $hasV1 = Test-CodeMateProviderBaseUrlHasV1Suffix -BaseUrl $BaseUrl
    $rootUrl = Get-CodeMateProviderBaseRootUrl -BaseUrl $BaseUrl

    if ($hasV1 -and $baseUrlBox) {
        $script:SuppressBaseUrlWarning = $true
        try {
            $baseUrlBox.Text = $rootUrl
        } finally {
            $script:SuppressBaseUrlWarning = $false
        }

        if ($ShowPrompt) {
            [System.Windows.Forms.MessageBox]::Show(
                ("Base URL 请填写根地址，不要以 /v1 结尾。`n`n程序会在测试和生成 CC Switch 配置时自动拼接 /v1。`n`n已自动改为：{0}" -f $rootUrl),
                'Base URL 格式提示',
                'OK',
                'Information'
            ) | Out-Null
        }
    }

    return ($rootUrl.TrimEnd('/') + '/v1')
}

function Normalize-ProviderBaseUrlInput {
    param([switch]$ShowPrompt)

    if (-not $baseUrlBox -or $script:SuppressBaseUrlWarning) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($baseUrlBox.Text)) {
        return
    }

    if (Test-CodeMateProviderBaseUrlHasV1Suffix -BaseUrl $baseUrlBox.Text) {
        Get-CodeMateProviderEffectiveBaseUrl -BaseUrl $baseUrlBox.Text -ShowPrompt:$ShowPrompt | Out-Null
    }
}

function Get-StatusColor {
    param([string]$Status)

    switch ($Status) {
        'Pass' { return [System.Drawing.Color]::FromArgb(32, 124, 67) }
        'Warn' { return [System.Drawing.Color]::FromArgb(173, 105, 0) }
        'Fail' { return [System.Drawing.Color]::FromArgb(186, 26, 26) }
        default { return [System.Drawing.Color]::FromArgb(80, 80, 80) }
    }
}

function Get-RepairModeText {
    param([string]$Risk)

    switch ($Risk) {
        'Safe' { return '一键修复' }
        'NeedsConfirmation' { return '确认后修复' }
        'Manual' { return '手动处理' }
        default { return '执行修复' }
    }
}

function Update-RepairUi {
    param([object]$Check)

    if (-not $repairButton -or -not $openUrlButton) {
        return
    }

    if (-not $Check -or -not $Check.RepairAction) {
        $repairButton.Text = '执行修复'
        $repairButton.Enabled = $false
        $openUrlButton.Text = '查看说明'
        $openUrlButton.Enabled = $false
        return
    }

    $repairButton.Text = Get-RepairModeText -Risk $Check.RepairAction.Risk
    $repairButton.Enabled = ($Check.RepairAction.Risk -ne 'Manual')
    $openUrlButton.Text = if ($Check.RepairAction.Url) { '查看说明' } else { '查看说明' }
    $openUrlButton.Enabled = -not [string]::IsNullOrWhiteSpace($Check.RepairAction.Url)
}

function Update-AutoRepairUi {
    if (-not $autoRepairButton) {
        return
    }

    if (-not $script:Report) {
        $autoRepairButton.Enabled = $true
        return
    }

    try {
        Get-CodeMateAutomaticRepairPlan -Report $script:Report | Out-Null
        $autoRepairButton.Enabled = $true
    } catch {
        $autoRepairButton.Enabled = $false
    }
}

function Get-ProgressEventValue {
    param(
        [object]$Event,
        [string]$Name,
        [object]$Default = ''
    )

    if (-not $Event -or -not $Event.PSObject.Properties[$Name] -or $null -eq $Event.$Name) {
        return $Default
    }

    return $Event.$Name
}

function Get-RepairProgressStatusText {
    param([string]$Status)

    switch ($Status) {
        'Pending' { return '等待' }
        'Running' { return '进行中' }
        'Succeeded' { return '成功' }
        'Failed' { return '失败' }
        default { return '信息' }
    }
}

function Get-RepairProgressStatusColor {
    param([string]$Status)

    switch ($Status) {
        'Pending' { return [System.Drawing.Color]::FromArgb(90, 90, 90) }
        'Running' { return [System.Drawing.Color]::FromArgb(0, 102, 204) }
        'Succeeded' { return [System.Drawing.Color]::FromArgb(32, 124, 67) }
        'Failed' { return [System.Drawing.Color]::FromArgb(186, 26, 26) }
        default { return [System.Drawing.Color]::FromArgb(70, 70, 70) }
    }
}

function Set-RepairProgressBarValue {
    param([object]$Percent)

    if (-not $repairProgressBar) {
        return
    }

    if ($null -eq $Percent -or $Percent -eq '') {
        $repairProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        return
    }

    try {
        $value = [Math]::Max(0, [Math]::Min(100, [int]$Percent))
        $repairProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $repairProgressBar.Value = $value
    } catch {
        $repairProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    }
}

function Resize-RepairProgressColumns {
    if (-not $repairProgressList -or $repairProgressList.Columns.Count -lt 4) {
        return
    }

    $clientWidth = [Math]::Max(720, $repairProgressList.ClientSize.Width)
    $repairProgressList.Columns[0].Width = 82
    $repairProgressList.Columns[1].Width = 210
    $repairProgressList.Columns[2].Width = 120
    $repairProgressList.Columns[3].Width = [Math]::Max(360, $clientWidth - 430)
}

function Set-RepairProgressRow {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Status = 'Info',
        [string]$Step = '',
        [string]$Stage = '',
        [string]$Detail = ''
    )

    if (-not $repairProgressList) {
        return
    }

    if (-not $script:RepairProgressRows.ContainsKey($Key)) {
        $item = New-Object System.Windows.Forms.ListViewItem((Get-RepairProgressStatusText -Status $Status))
        $item.SubItems.Add($Step) | Out-Null
        $item.SubItems.Add($Stage) | Out-Null
        $item.SubItems.Add($Detail) | Out-Null
        $script:RepairProgressRows[$Key] = $item
        [void]$repairProgressList.Items.Add($item)
    }

    $row = $script:RepairProgressRows[$Key]
    $row.Text = Get-RepairProgressStatusText -Status $Status
    $row.SubItems[1].Text = $Step
    $row.SubItems[2].Text = $Stage
    $row.SubItems[3].Text = $Detail
    $row.ForeColor = Get-RepairProgressStatusColor -Status $Status
    $row.EnsureVisible()
}

function Append-RepairProgressLog {
    param([object]$Event)

    if (-not $detailsBox) {
        return
    }

    if (-not $script:RepairProgressLog) {
        $script:RepairProgressLog = New-Object System.Collections.Generic.List[string]
    }

    $timestamp = Get-ProgressEventValue -Event $Event -Name 'Timestamp' -Default (Get-Date).ToString('HH:mm:ss')
    $status = Get-ProgressEventValue -Event $Event -Name 'Status' -Default 'Info'
    $step = Get-ProgressEventValue -Event $Event -Name 'Step' -Default ''
    $message = Get-ProgressEventValue -Event $Event -Name 'Message' -Default ''
    $detail = Get-ProgressEventValue -Event $Event -Name 'Detail' -Default ''
    $line = '[{0}] {1} {2} - {3}' -f $timestamp, (Get-RepairProgressStatusText -Status $status), $step, $message
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $line += (' | {0}' -f $detail)
    }

    $script:RepairProgressLog.Add($line)
    while ($script:RepairProgressLog.Count -gt 80) {
        $script:RepairProgressLog.RemoveAt(0)
    }

    $detailsBox.Text = ($script:RepairProgressLog -join [Environment]::NewLine)
}

function Initialize-AutoRepairProgress {
    param([object]$Plan)

    if ($repairProgressList) {
        $repairProgressList.Items.Clear()
    }

    $script:RepairProgressRows = @{}
    $script:RepairProgressLog = New-Object System.Collections.Generic.List[string]
    Set-RepairProgressBarValue -Percent 0

    if ($repairProgressStatusLabel) {
        $repairProgressStatusLabel.Text = '准备执行一键安装环境'
    }

    foreach ($action in @($Plan.RunnableActions)) {
        Set-RepairProgressRow `
            -Key $action.ActionId `
            -Status 'Pending' `
            -Step $action.CheckName `
            -Stage '等待' `
            -Detail $action.Label
    }

    if (@($Plan.RunnableActions).Count -eq 0) {
        Set-RepairProgressRow -Key 'no-action' -Status 'Succeeded' -Step '基础环境' -Stage '检查' -Detail '没有需要自动处理的项目。'
    }

    Resize-RepairProgressColumns
}

function Initialize-SelectedRepairProgress {
    param(
        [Parameter(Mandatory = $true)][object]$Check,
        [Parameter(Mandatory = $true)][object]$Action
    )

    if ($repairProgressList) {
        $repairProgressList.Items.Clear()
    }

    $script:RepairProgressRows = @{}
    $script:RepairProgressLog = New-Object System.Collections.Generic.List[string]
    Set-RepairProgressBarValue -Percent 0

    if ($repairProgressStatusLabel) {
        $repairProgressStatusLabel.Text = ('准备修复：{0}' -f $Check.Name)
    }

    Set-RepairProgressRow `
        -Key $Action.Id `
        -Status 'Pending' `
        -Step $Check.Name `
        -Stage '等待' `
        -Detail $Action.Label

    Resize-RepairProgressColumns
}

function Update-AutoRepairProgressFromEvent {
    param(
        [object]$Event,
        [object]$ProgressPercentage
    )

    if (-not $Event) {
        return
    }

    $actionId = Get-ProgressEventValue -Event $Event -Name 'ActionId' -Default ''
    $sequence = Get-ProgressEventValue -Event $Event -Name 'Sequence' -Default ([guid]::NewGuid().ToString())
    $key = if (-not [string]::IsNullOrWhiteSpace($actionId)) { $actionId } else { ('event-{0}' -f $sequence) }
    $status = Get-ProgressEventValue -Event $Event -Name 'Status' -Default 'Info'
    $step = Get-ProgressEventValue -Event $Event -Name 'Step' -Default ''
    $stage = Get-ProgressEventValue -Event $Event -Name 'Stage' -Default ''
    $message = Get-ProgressEventValue -Event $Event -Name 'Message' -Default ''
    $detail = Get-ProgressEventValue -Event $Event -Name 'Detail' -Default ''
    $percent = Get-ProgressEventValue -Event $Event -Name 'Percent' -Default $ProgressPercentage
    $rowDetail = $message

    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $rowDetail = if ([string]::IsNullOrWhiteSpace($rowDetail)) { $detail } else { '{0} | {1}' -f $rowDetail, $detail }
    }

    Set-RepairProgressRow -Key $key -Status $status -Step $step -Stage $stage -Detail $rowDetail
    Set-RepairProgressBarValue -Percent $percent
    Append-RepairProgressLog -Event $Event

    if ($repairProgressStatusLabel) {
        $repairProgressStatusLabel.Text = $message
    }
}

function Set-EnvironmentBusyState {
    param([bool]$Busy)

    if ($refreshButton) { $refreshButton.Enabled = -not $Busy }
    if ($autoRepairButton) { $autoRepairButton.Enabled = -not $Busy }
    if ($repairButton) { $repairButton.Enabled = -not $Busy }
    if ($openUrlButton) { $openUrlButton.Enabled = -not $Busy }
    if ($exportButton) { $exportButton.Enabled = -not $Busy }

    if ($form) {
        $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    }

    if (-not $Busy) {
        Update-AutoRepairUi
        if ($script:SelectedCheck) {
            Update-RepairUi -Check $script:SelectedCheck
        }
    }
}

function Get-WorkerProgressPercent {
    param([object]$Event)

    try {
        if ($Event -and $Event.PSObject.Properties['Percent'] -and $null -ne $Event.Percent -and $Event.Percent -ne '') {
            return [Math]::Max(0, [Math]::Min(100, [int]$Event.Percent))
        }
    } catch {
    }

    return 0
}

function New-AutoRepairWorkerState {
    param([Parameter(Mandatory = $true)][object]$Report)

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $powerShell = [powershell]::Create()
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $powerShell.Runspace = $runspace

    $scriptText = @'
param($Report, $Queue, $ModulePath)

$ErrorActionPreference = 'Stop'
$global:ProgressPreference = 'SilentlyContinue'
Import-Module $ModulePath -Force

try {
    Set-CodeMateProgressCallback -Callback {
        param($progressEvent)
        $Queue.Enqueue([pscustomobject]@{
            Kind  = 'Progress'
            Event = $progressEvent
        })
    }

    $result = Invoke-CodeMateAutomaticRepair -Report $Report
    $Queue.Enqueue([pscustomobject]@{
        Kind   = 'Completed'
        Result = $result
    })
} catch {
    $Queue.Enqueue([pscustomobject]@{
        Kind    = 'Failed'
        Message = $_.Exception.Message
    })
} finally {
    Set-CodeMateProgressCallback -Callback $null
}
'@

    [void]$powerShell.AddScript($scriptText).AddArgument($Report).AddArgument($queue).AddArgument((Join-Path $PSScriptRoot 'CodeMate.Health.psm1'))

    [pscustomobject]@{
        PowerShell = $powerShell
        Runspace   = $runspace
        Handle     = $powerShell.BeginInvoke()
        Queue      = $queue
        Completed  = $false
        Ended      = $false
    }
}

function New-SelectedRepairWorkerState {
    param(
        [Parameter(Mandatory = $true)][object]$Check,
        [Parameter(Mandatory = $true)][object]$Action
    )

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $powerShell = [powershell]::Create()
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $powerShell.Runspace = $runspace

    $scriptText = @'
param($Check, $Action, $Queue, $ModulePath)

$ErrorActionPreference = 'Stop'
$global:ProgressPreference = 'SilentlyContinue'
Import-Module $ModulePath -Force

try {
    Set-CodeMateProgressCallback -Callback {
        param($progressEvent)
        $Queue.Enqueue([pscustomobject]@{
            Kind  = 'Progress'
            Event = $progressEvent
        })
    }

    $result = Invoke-CodeMateRepair -ActionId $Action.Id -Context $Action
    $Queue.Enqueue([pscustomobject]@{
        Kind   = 'SingleCompleted'
        Result = [pscustomobject]@{
            Check       = $Check
            Action      = $Action
            Repair      = $result
            FinalReport = Get-CodeMateHealthReport
        }
    })
} catch {
    $Queue.Enqueue([pscustomobject]@{
        Kind    = 'Failed'
        Message = $_.Exception.Message
    })
} finally {
    Set-CodeMateProgressCallback -Callback $null
}
'@

    [void]$powerShell.AddScript($scriptText).AddArgument($Check).AddArgument($Action).AddArgument($queue).AddArgument((Join-Path $PSScriptRoot 'CodeMate.Health.psm1'))

    [pscustomobject]@{
        PowerShell = $powerShell
        Runspace   = $runspace
        Handle     = $powerShell.BeginInvoke()
        Queue      = $queue
        Completed  = $false
        Ended      = $false
        Mode       = 'Selected'
    }
}

function Stop-AutoRepairWorkerState {
    param(
        [object]$State,
        [switch]$Force
    )

    if (-not $State) {
        return
    }

    try {
        if ($Force -and $State.PowerShell -and $State.Handle -and -not $State.Handle.IsCompleted) {
            $State.PowerShell.Stop()
        }
    } catch {
    }

    try {
        if (-not $Force -and $State.Handle -and -not $State.Handle.IsCompleted) {
            $State.Handle.AsyncWaitHandle.WaitOne(5000) | Out-Null
        }
    } catch {
    }

    try {
        if ($State.PowerShell -and $State.Handle -and -not $State.Ended -and $State.Handle.IsCompleted) {
            $State.PowerShell.EndInvoke($State.Handle) | Out-Null
            $State.Ended = $true
        }
    } catch {
    }

    try {
        if ($State.PowerShell) {
            $State.PowerShell.Dispose()
        }
    } catch {
    }

    try {
        if ($State.Runspace) {
            $State.Runspace.Close()
            $State.Runspace.Dispose()
        }
    } catch {
    }
}

function Start-AutoRepairWorker {
    param([Parameter(Mandatory = $true)][object]$Report)

    $script:AutoRepairWorker = New-AutoRepairWorkerState -Report $Report

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ Pump-AutoRepairWorkerQueue })
    $script:AutoRepairTimer = $timer
    $timer.Start()
}

function Start-SelectedRepairWorker {
    param(
        [Parameter(Mandatory = $true)][object]$Check,
        [Parameter(Mandatory = $true)][object]$Action
    )

    $script:AutoRepairWorker = New-SelectedRepairWorkerState -Check $Check -Action $Action

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ Pump-AutoRepairWorkerQueue })
    $script:AutoRepairTimer = $timer
    $timer.Start()
}

function Pump-AutoRepairWorkerQueue {
    if (-not $script:AutoRepairWorker) {
        return
    }

    $state = $script:AutoRepairWorker
    $item = $null

    while ($state.Queue.TryDequeue([ref]$item)) {
        switch ($item.Kind) {
            'Progress' {
                Update-AutoRepairProgressFromEvent -Event $item.Event -ProgressPercentage (Get-WorkerProgressPercent -Event $item.Event)
            }

            'Completed' {
                Complete-AutoRepairEnvironment -Result $item.Result
                return
            }

            'SingleCompleted' {
                Complete-SelectedRepairEnvironment -Result $item.Result
                return
            }

            'Failed' {
                Complete-AutoRepairEnvironment -ErrorMessage $item.Message
                return
            }
        }
    }

    if ($state.Handle.IsCompleted -and -not $state.Completed) {
        $state.Completed = $true
        try {
            $state.PowerShell.EndInvoke($state.Handle) | Out-Null
            $state.Ended = $true
            if ($state.PowerShell.Streams.Error.Count -gt 0) {
                $streamErrors = @($state.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
                Complete-AutoRepairEnvironment -ErrorMessage $streamErrors
                return
            }

            if ($script:AutoRepairWorker) {
                Complete-AutoRepairEnvironment -ErrorMessage '后台任务已结束，但没有返回完成结果。'
            }
        } catch {
            Complete-AutoRepairEnvironment -ErrorMessage $_.Exception.Message
            return
        }
    }
}

function Complete-AutoRepairEnvironment {
    param(
        [object]$Result,
        [string]$ErrorMessage
    )

    if ($script:AutoRepairTimer) {
        $script:AutoRepairTimer.Stop()
        $script:AutoRepairTimer.Dispose()
        $script:AutoRepairTimer = $null
    }

    Stop-AutoRepairWorkerState -State $script:AutoRepairWorker
    $script:AutoRepairWorker = $null
    Set-EnvironmentBusyState -Busy $false

    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        $statusLabel.Text = '一键安装环境失败'
        Set-RepairProgressRow -Key 'automatic-repair' -Status 'Failed' -Step '自动修复' -Stage '失败' -Detail $ErrorMessage
        [System.Windows.Forms.MessageBox]::Show($ErrorMessage, '一键安装环境失败', 'OK', 'Error') | Out-Null
        Refresh-Report
        return
    }

    if (-not $Result) {
        $statusLabel.Text = '一键安装环境失败'
        Set-RepairProgressRow -Key 'automatic-repair' -Status 'Failed' -Step '自动修复' -Stage '失败' -Detail '后台任务没有返回结果。'
        Refresh-Report
        return
    }

    $script:Report = $Result.FinalReport
    $checksList.Items.Clear()
    foreach ($check in $script:Report.Checks) {
        Add-CheckToList -Check $check
    }

    $summaryLabel.Text = ('Pass {0} | Warn {1} | Fail {2}' -f $script:Report.Summary.Pass, $script:Report.Summary.Warn, $script:Report.Summary.Fail)
    Resize-HealthColumns
    Refresh-ToolStatuses
    Update-AutoRepairUi
    Set-RepairProgressBarValue -Percent 100

    $lines = New-Object System.Collections.Generic.List[string]
    if (@($Result.ExecutedActions).Count -gt 0) {
        $lines.Add('已执行：')
        foreach ($action in @($Result.ExecutedActions)) {
            $lines.Add(('- {0}: {1}' -f $action.Label, $action.Result))
        }
    } else {
        $lines.Add('没有需要安装或调整的环境项。')
    }

    if (@($Result.FailedActions).Count -gt 0) {
        $lines.Add('')
        $lines.Add('失败项：')
        foreach ($action in @($Result.FailedActions)) {
            $lines.Add(('- {0}: {1}' -f $action.Label, $action.Error))
        }
    }

    if (@($Result.Notes).Count -gt 0) {
        $lines.Add('')
        $lines.Add('提示：')
        foreach ($note in @($Result.Notes)) {
            $lines.Add(('- {0}' -f $note))
        }
    }

    $lines.Add('')
    $lines.Add(('复检结果：Pass {0} | Warn {1} | Fail {2}' -f $script:Report.Summary.Pass, $script:Report.Summary.Warn, $script:Report.Summary.Fail))
    $detailsBox.Text = ($lines -join [Environment]::NewLine)

    if (@($Result.FailedActions).Count -gt 0) {
        $statusLabel.Text = '一键安装环境完成，但存在失败项'
        if ($repairProgressStatusLabel) { $repairProgressStatusLabel.Text = '一键安装环境完成，但存在失败项' }
        [System.Windows.Forms.MessageBox]::Show($detailsBox.Text, '一键安装环境结果', 'OK', 'Warning') | Out-Null
    } else {
        $statusLabel.Text = '一键安装环境完成'
        if ($repairProgressStatusLabel) { $repairProgressStatusLabel.Text = '一键安装环境完成' }
        [System.Windows.Forms.MessageBox]::Show($detailsBox.Text, '一键安装环境结果', 'OK', 'Information') | Out-Null
    }
}

function Complete-SelectedRepairEnvironment {
    param([object]$Result)

    if ($script:AutoRepairTimer) {
        $script:AutoRepairTimer.Stop()
        $script:AutoRepairTimer.Dispose()
        $script:AutoRepairTimer = $null
    }

    Stop-AutoRepairWorkerState -State $script:AutoRepairWorker
    $script:AutoRepairWorker = $null
    Set-EnvironmentBusyState -Busy $false

    if (-not $Result) {
        $statusLabel.Text = '修复失败'
        Set-RepairProgressRow -Key 'selected-repair' -Status 'Failed' -Step '单项修复' -Stage '失败' -Detail '后台任务没有返回结果。'
        Refresh-Report
        return
    }

    $script:Report = $Result.FinalReport
    $checksList.Items.Clear()
    foreach ($check in $script:Report.Checks) {
        Add-CheckToList -Check $check
    }

    $summaryLabel.Text = ('Pass {0} | Warn {1} | Fail {2}' -f $script:Report.Summary.Pass, $script:Report.Summary.Warn, $script:Report.Summary.Fail)
    Resize-HealthColumns
    Refresh-ToolStatuses
    Update-AutoRepairUi
    Set-RepairProgressBarValue -Percent 100

    $action = $Result.Action
    Set-RepairProgressRow `
        -Key $action.Id `
        -Status 'Succeeded' `
        -Step $Result.Check.Name `
        -Stage '完成' `
        -Detail $Result.Repair.Message

    $detailsBox.Text = @(
        ('修复完成：{0}' -f $action.Label),
        '',
        $Result.Repair.Message,
        '',
        ('复检结果：Pass {0} | Warn {1} | Fail {2}' -f $script:Report.Summary.Pass, $script:Report.Summary.Warn, $script:Report.Summary.Fail)
    ) -join [Environment]::NewLine

    $statusLabel.Text = '修复完成'
    if ($repairProgressStatusLabel) {
        $repairProgressStatusLabel.Text = ('修复完成：{0}' -f $action.Label)
    }
    [System.Windows.Forms.MessageBox]::Show($Result.Repair.Message, '修复完成', 'OK', 'Information') | Out-Null
}

function Stop-AutoRepairUiRuntime {
    if ($script:AutoRepairTimer) {
        try {
            $script:AutoRepairTimer.Stop()
            $script:AutoRepairTimer.Dispose()
        } catch {
        }
        $script:AutoRepairTimer = $null
    }

    Stop-AutoRepairWorkerState -State $script:AutoRepairWorker -Force
    $script:AutoRepairWorker = $null
}

function Set-ToolInstallProgressBarValue {
    param([object]$Percent)

    if (-not $toolInstallProgressBar) {
        return
    }

    if ($null -eq $Percent -or $Percent -eq '') {
        $toolInstallProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $toolInstallProgressBar.MarqueeAnimationSpeed = 30
        return
    }

    try {
        $value = [Math]::Max(0, [Math]::Min(100, [int]$Percent))
        $toolInstallProgressBar.MarqueeAnimationSpeed = 0
        $toolInstallProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Continuous
        $toolInstallProgressBar.Value = $value
    } catch {
        $toolInstallProgressBar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
        $toolInstallProgressBar.MarqueeAnimationSpeed = 30
    }
}

function Get-ToolInstallHeaderLines {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec,
        [string]$InstallPath,
        [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install'
    )

    $operationText = if ($Operation -eq 'Uninstall') { '卸载' } else { '安装' }
    $sourceText = if ($Operation -eq 'Uninstall') {
        if ($Spec.PSObject.Properties['UninstallNote'] -and $Spec.UninstallNote) { $Spec.UninstallNote } else { $Spec.SourceLabel }
    } else {
        $Spec.SourceLabel
    }

    $lines = @(
        ('正在{0} {1}，请不要关闭窗口。' -f $operationText, $Spec.Name),
        ('{0}方式：{1}' -f $operationText, $sourceText)
    )

    if ($Operation -eq 'Install') {
        $lines += ('预选位置：{0}' -f $(if ($InstallPath) { $InstallPath } else { '默认位置' }))
    }

    $lines += @(
        '',
        ('{0}过程可能需要数分钟。如果系统弹出授权窗口，请确认后继续。' -f $operationText),
        ''
    )

    return $lines
}

function Get-CCSwitchNextStepsText {
    param([string]$InstallMessage)

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($InstallMessage)) {
        $lines.Add($InstallMessage)
        $lines.Add('')
    }

    $lines.Add('下一步：选择一种连接方式，让 Codex、Claude Code、Cursor 等工具真正可用。')
    $lines.Add('')
    $lines.Add('方式一：官方登录')
    $lines.Add('1. 打开目标工具，使用官方账号登录。')
    $lines.Add('2. 适合已有官方账号、订阅或网络环境可以稳定访问官方服务的用户。')
    $lines.Add('')
    $lines.Add('方式二：API Key / OpenAI-compatible 网关')
    $lines.Add('1. 在 API 服务站或网关后台获取 Base URL、API Key 和模型名。')
    $lines.Add('2. 回到 CodeMate 的 Provider Test 页填写 Base URL、API Key、Model，然后点击 Test Locally。')
    $lines.Add('3. 测试通过后进入 CC Switch 页点击 Generate，再用 Copy Link 或保存 profile 导入 CC Switch。')
    $lines.Add('4. 在 CC Switch 中切换到该配置，然后重新打开 Codex、Claude Code、Cursor 或相关终端。')
    $lines.Add('')
    $lines.Add('提示：Base URL 填根地址即可，不要手动加 /v1；CodeMate 会在测试和生成配置时自动拼接。')

    return ($lines -join [Environment]::NewLine)
}

function Get-CCSwitchGuidePath {
    return (Join-Path $rootPath 'docs\ccswitch-login-guide.md')
}

function Open-CCSwitchGuideDocument {
    $guidePath = Get-CCSwitchGuidePath
    if (Test-Path -LiteralPath $guidePath) {
        Start-Process $guidePath
        return
    }

    [System.Windows.Forms.MessageBox]::Show(
        ('未找到教程文档：{0}' -f $guidePath),
        'CC Switch 教程',
        'OK',
        'Warning'
    ) | Out-Null
}

function Show-CCSwitchLoginGuideDialog {
    param([string]$InstallMessage)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'CC Switch 登录与接入教程'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(720, 520)
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    $layout.Padding = New-Object System.Windows.Forms.Padding(18)
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52))) | Out-Null
    $dialog.Controls.Add($layout)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Dock = 'Fill'
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = '下一步：让 Codex 等工具真正可用'
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($titleLabel, 0, 0)

    $guideBox = New-Object System.Windows.Forms.TextBox
    $guideBox.Dock = 'Fill'
    $guideBox.Multiline = $true
    $guideBox.ReadOnly = $true
    $guideBox.ScrollBars = 'Vertical'
    $guideBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
    $guideBox.Text = @(
        $(if (-not [string]::IsNullOrWhiteSpace($InstallMessage)) { $InstallMessage } else { 'CC Switch 已安装完成。' }),
        '',
        '请选择一种使用路线：',
        '',
        '路线 A：官方登录',
        '1. 打开 Codex、Claude Code、Cursor 等目标工具。',
        '2. 按工具内提示使用官方账号登录。',
        '3. 登录后发送一个简单问题测试是否可用。',
        '',
        '路线 B：API Key / 中转站 / OpenAI-compatible 网关',
        '1. 到 API 服务站或网关后台获取 Base URL、API Key 和 Model。',
        '2. 回到 CodeMate 的 Provider Test 页填写并点击 Test Locally。',
        '3. 测试成功后到 CC Switch 页点击 Generate。',
        '4. 点击 Open Link 导入 CC Switch，或 Copy Link / Save JSON 手动导入。',
        '5. 在 CC Switch 中切换到新 profile，然后重启目标工具或终端。',
        '',
        '重要：Provider Test 的 Base URL 填根地址，不要手动加 /v1；CodeMate 会自动拼接。',
        '',
        '完整图文级步骤请打开本地教程文档。'
    ) -join [Environment]::NewLine
    $layout.Controls.Add($guideBox, 0, 1)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = 'Fill'
    $buttonPanel.FlowDirection = 'RightToLeft'
    $buttonPanel.WrapContents = $false
    $layout.Controls.Add($buttonPanel, 0, 2)

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = '关闭'
    $closeButton.Width = 90
    $closeButton.Height = 32
    $closeButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonPanel.Controls.Add($closeButton)

    $ccSwitchButton = New-Object System.Windows.Forms.Button
    $ccSwitchButton.Text = '去 CC Switch'
    $ccSwitchButton.Width = 112
    $ccSwitchButton.Height = 32
    $ccSwitchButton.Add_Click({
        $tabs.SelectedTab = $ccswitchTab
        $dialog.Close()
    })
    $buttonPanel.Controls.Add($ccSwitchButton)

    $providerButton = New-Object System.Windows.Forms.Button
    $providerButton.Text = '去 Provider Test'
    $providerButton.Width = 128
    $providerButton.Height = 32
    $providerButton.Add_Click({
        $tabs.SelectedTab = $providerTab
        $dialog.Close()
    })
    $buttonPanel.Controls.Add($providerButton)

    $docButton = New-Object System.Windows.Forms.Button
    $docButton.Text = '打开本地教程'
    $docButton.Width = 126
    $docButton.Height = 32
    $docButton.Add_Click({ Open-CCSwitchGuideDocument })
    $buttonPanel.Controls.Add($docButton)

    $dialog.AcceptButton = $closeButton
    [void]$dialog.ShowDialog($form)
}

function Get-ToolInstallSuccessMessage {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec,
        [object]$Result,
        [string]$InstallPath,
        [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install'
    )

    $operationText = if ($Operation -eq 'Uninstall') { '卸载' } else { '安装' }
    $installMessage = if ($Result -and $Result.PSObject.Properties['Message'] -and $Result.Message) {
        $Result.Message
    } else {
        ('{0} {1}完成。' -f $Spec.Name, $operationText)
    }

    if ($Operation -eq 'Install' -and $Tool.Id -eq 'ccswitch') {
        return Get-CCSwitchNextStepsText -InstallMessage $installMessage
    }

    return @(
        $installMessage,
        '',
        ('{0}源：{1}' -f $operationText, $Spec.SourceLabel),
        ('预选位置：{0}' -f $(if ($InstallPath) { $InstallPath } else { '默认位置' }))
    ) -join [Environment]::NewLine
}

function Initialize-ToolInstallProgress {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install'
    )

    $script:CurrentToolInstall = [pscustomobject]@{
        Tool        = $Tool
        Spec        = $Spec
        InstallPath = $InstallPath
        Operation   = $Operation
    }
    $script:ToolInstallLog = New-Object System.Collections.Generic.List[string]
    $operationText = if ($Operation -eq 'Uninstall') { '卸载' } else { '安装' }

    if ($toolInstallProgressStatusLabel) {
        $toolInstallProgressStatusLabel.Text = ('正在准备{0} {1}...' -f $operationText, $Spec.Name)
    }

    Set-ToolInstallProgressBarValue -Percent $null

    if ($toolDetailsBox) {
        $toolDetailsBox.Text = ((Get-ToolInstallHeaderLines -Tool $Tool -Spec $Spec -InstallPath $InstallPath -Operation $Operation) -join [Environment]::NewLine)
    }
}

function Append-ToolInstallProgressLog {
    param([object]$Event)

    if (-not $toolDetailsBox) {
        return
    }

    if (-not $script:ToolInstallLog) {
        $script:ToolInstallLog = New-Object System.Collections.Generic.List[string]
    }

    $timestamp = Get-ProgressEventValue -Event $Event -Name 'Timestamp' -Default (Get-Date).ToString('HH:mm:ss')
    $status = Get-ProgressEventValue -Event $Event -Name 'Status' -Default 'Info'
    $stage = Get-ProgressEventValue -Event $Event -Name 'Stage' -Default ''
    $message = Get-ProgressEventValue -Event $Event -Name 'Message' -Default ''
    $detail = Get-ProgressEventValue -Event $Event -Name 'Detail' -Default ''
    $line = '[{0}] {1} {2} - {3}' -f $timestamp, (Get-RepairProgressStatusText -Status $status), $stage, $message
    if (-not [string]::IsNullOrWhiteSpace($detail)) {
        $line += (' | {0}' -f $detail)
    }

    $script:ToolInstallLog.Add($line)
    while ($script:ToolInstallLog.Count -gt 80) {
        $script:ToolInstallLog.RemoveAt(0)
    }

    $current = $script:CurrentToolInstall
    $header = if ($current) {
        Get-ToolInstallHeaderLines -Tool $current.Tool -Spec $current.Spec -InstallPath $current.InstallPath -Operation $current.Operation
    } else {
        @('正在处理工具任务...', '')
    }

    $toolDetailsBox.Text = (@($header) + @('任务进度：') + @($script:ToolInstallLog)) -join [Environment]::NewLine
}

function Update-ToolInstallProgressFromEvent {
    param([object]$Event)

    if (-not $Event) {
        return
    }

    $status = Get-ProgressEventValue -Event $Event -Name 'Status' -Default 'Info'
    $message = Get-ProgressEventValue -Event $Event -Name 'Message' -Default ''
    $percent = Get-ProgressEventValue -Event $Event -Name 'Percent' -Default $null

    if (($null -eq $percent -or $percent -eq '') -and $status -eq 'Succeeded') {
        $percent = 100
    } elseif (($null -eq $percent -or $percent -eq '') -and $status -eq 'Failed') {
        $percent = 0
    }

    Set-ToolInstallProgressBarValue -Percent $percent
    Append-ToolInstallProgressLog -Event $Event

    if ($toolInstallProgressStatusLabel -and -not [string]::IsNullOrWhiteSpace($message)) {
        $toolInstallProgressStatusLabel.Text = $message
    }
}

function Set-ToolInstallBusyState {
    param([bool]$Busy)

    if ($toolsList) { $toolsList.Enabled = -not $Busy }
    if ($toolInstallButton) { $toolInstallButton.Enabled = -not $Busy }
    if ($toolUninstallButton) { $toolUninstallButton.Enabled = -not $Busy }
    if ($toolDocsButton) { $toolDocsButton.Enabled = -not $Busy }

    if ($form) {
        $form.Cursor = if ($Busy) { [System.Windows.Forms.Cursors]::WaitCursor } else { [System.Windows.Forms.Cursors]::Default }
    }

    if (-not $Busy) {
        if ($toolsList -and $toolsList.SelectedItems.Count -gt 0) {
            Set-ToolDetail
        } else {
            if ($toolInstallButton) { $toolInstallButton.Enabled = $false }
            if ($toolUninstallButton) { $toolUninstallButton.Enabled = $false }
            if ($toolDocsButton) { $toolDocsButton.Enabled = $false }
        }
    }
}

function New-ToolInstallWorkerState {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install'
    )

    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $powerShell = [powershell]::Create()
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'MTA'
    $runspace.ThreadOptions = 'ReuseThread'
    $runspace.Open()
    $powerShell.Runspace = $runspace

    $scriptText = @'
param($Tool, $InstallPath, $Operation, $Queue, $ModulePath)

$ErrorActionPreference = 'Stop'
$global:ProgressPreference = 'SilentlyContinue'
Import-Module $ModulePath -Force

try {
    Set-CodeMateProgressCallback -Callback {
        param($progressEvent)
        $Queue.Enqueue([pscustomobject]@{
            Kind  = 'Progress'
            Event = $progressEvent
        })
    }

    if ($Operation -eq 'Uninstall') {
        $result = Invoke-CodeMateToolUninstall -ToolId $Tool.Id
    } else {
        $result = Invoke-CodeMateToolInstall -ToolId $Tool.Id -InstallPath $InstallPath
    }

    $Queue.Enqueue([pscustomobject]@{
        Kind   = 'Completed'
        Result = $result
    })
} catch {
    $Queue.Enqueue([pscustomobject]@{
        Kind    = 'Failed'
        Message = $_.Exception.Message
    })
} finally {
    Set-CodeMateProgressCallback -Callback $null
}
'@

    [void]$powerShell.AddScript($scriptText).AddArgument($Tool).AddArgument($InstallPath).AddArgument($Operation).AddArgument($queue).AddArgument((Join-Path $PSScriptRoot 'CodeMate.Health.psm1'))

    [pscustomobject]@{
        PowerShell  = $powerShell
        Runspace    = $runspace
        Handle      = $powerShell.BeginInvoke()
        Queue       = $queue
        Completed   = $false
        Ended       = $false
        Tool        = $Tool
        Spec        = $Spec
        InstallPath = $InstallPath
        Operation   = $Operation
    }
}

function Start-ToolInstallWorker {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][string]$InstallPath,
        [ValidateSet('Install', 'Uninstall')][string]$Operation = 'Install'
    )

    $script:ToolInstallWorker = New-ToolInstallWorkerState -Tool $Tool -Spec $Spec -InstallPath $InstallPath -Operation $Operation

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ Pump-ToolInstallWorkerQueue })
    $script:ToolInstallTimer = $timer
    $timer.Start()
}

function Pump-ToolInstallWorkerQueue {
    if (-not $script:ToolInstallWorker) {
        return
    }

    $state = $script:ToolInstallWorker
    $item = $null

    while ($state.Queue.TryDequeue([ref]$item)) {
        switch ($item.Kind) {
            'Progress' {
                Update-ToolInstallProgressFromEvent -Event $item.Event
            }

            'Completed' {
                Complete-ToolInstall -Result $item.Result
                return
            }

            'Failed' {
                Complete-ToolInstall -ErrorMessage $item.Message
                return
            }
        }
    }

    if ($state.Handle.IsCompleted -and -not $state.Completed) {
        $state.Completed = $true
        try {
            $state.PowerShell.EndInvoke($state.Handle) | Out-Null
            $state.Ended = $true
            if ($state.PowerShell.Streams.Error.Count -gt 0) {
                $streamErrors = @($state.PowerShell.Streams.Error | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
                Complete-ToolInstall -ErrorMessage $streamErrors
                return
            }

            if ($script:ToolInstallWorker) {
                Complete-ToolInstall -ErrorMessage '后台安装任务已结束，但没有返回完成结果。'
            }
        } catch {
            Complete-ToolInstall -ErrorMessage $_.Exception.Message
            return
        }
    }
}

function Complete-ToolInstall {
    param(
        [object]$Result,
        [string]$ErrorMessage
    )

    if ($script:ToolInstallTimer) {
        $script:ToolInstallTimer.Stop()
        $script:ToolInstallTimer.Dispose()
        $script:ToolInstallTimer = $null
    }

    $state = $script:ToolInstallWorker
    Stop-AutoRepairWorkerState -State $script:ToolInstallWorker
    $script:ToolInstallWorker = $null
    Refresh-ToolStatuses
    Set-ToolInstallBusyState -Busy $false

    $tool = if ($state) { $state.Tool } else { $null }
    $spec = if ($state) { $state.Spec } else { $null }
    $installPath = if ($state) { $state.InstallPath } else { '' }
    $operation = if ($state -and $state.Operation) { $state.Operation } else { 'Install' }
    $operationText = if ($operation -eq 'Uninstall') { '卸载' } else { '安装' }

    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Set-ToolInstallProgressBarValue -Percent 0
        if ($toolInstallProgressStatusLabel) {
            $toolInstallProgressStatusLabel.Text = if ($spec) { ('{0} {1}失败' -f $spec.Name, $operationText) } else { ('工具{0}失败' -f $operationText) }
        }
        if ($statusLabel) {
            $statusLabel.Text = if ($spec) { ('{0} {1}失败' -f $spec.Name, $operationText) } else { ('工具{0}失败' -f $operationText) }
        }
        if ($toolDetailsBox) {
            $toolDetailsBox.Text = $ErrorMessage
        }
        [System.Windows.Forms.MessageBox]::Show($ErrorMessage, ('{0}失败' -f $operationText), 'OK', 'Error') | Out-Null
        return
    }

    Set-ToolInstallProgressBarValue -Percent 100
    if ($toolInstallProgressStatusLabel) {
        $toolInstallProgressStatusLabel.Text = if ($spec) { ('{0} {1}完成' -f $spec.Name, $operationText) } else { ('工具{0}完成' -f $operationText) }
    }
    if ($statusLabel) {
        $statusLabel.Text = if ($spec) { ('{0} {1}完成' -f $spec.Name, $operationText) } else { ('工具{0}完成' -f $operationText) }
    }

    $message = if ($tool -and $spec) {
        Get-ToolInstallSuccessMessage -Tool $tool -Spec $spec -Result $Result -InstallPath $installPath -Operation $operation
    } elseif ($Result -and $Result.PSObject.Properties['Message']) {
        $Result.Message
    } else {
        ('{0}完成。' -f $operationText)
    }

    if ($toolDetailsBox) {
        $toolDetailsBox.Text = $message
    }

    if ($operation -eq 'Install' -and $tool -and $tool.Id -eq 'ccswitch') {
        Show-CCSwitchLoginGuideDialog -InstallMessage $(if ($Result -and $Result.PSObject.Properties['Message']) { $Result.Message } else { $message })
    } else {
        [System.Windows.Forms.MessageBox]::Show($message, ('{0}完成' -f $operationText), 'OK', 'Information') | Out-Null
    }

    if ($operation -eq 'Install' -and $tool -and $tool.Id -ne 'ccswitch') {
        Prompt-InstallCCSwitchAfterToolInstall -InstalledTool $tool
    }
}

function Stop-ToolInstallUiRuntime {
    if ($script:ToolInstallTimer) {
        try {
            $script:ToolInstallTimer.Stop()
            $script:ToolInstallTimer.Dispose()
        } catch {
        }
        $script:ToolInstallTimer = $null
    }

    Stop-AutoRepairWorkerState -State $script:ToolInstallWorker -Force
    $script:ToolInstallWorker = $null
    $script:CurrentToolInstall = $null
}

function Set-DetailText {
    param([object]$Check)

    if (-not $Check) {
        $detailsBox.Text = '选择左侧检测项后，可查看问题详情和修复方式。'
        Update-RepairUi -Check $null
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(('Name: {0}' -f $Check.Name))
    $lines.Add(('Status: {0}' -f $Check.Status))
    $lines.Add(('Message: {0}' -f $Check.Message))

    if ($Check.Detected) {
        $lines.Add(('Detected: {0}' -f $Check.Detected))
    }

    if ($Check.RepairAction) {
        $lines.Add('')
        $lines.Add(('Repair: {0}' -f $Check.RepairAction.Label))
        $lines.Add(('Action: {0}' -f $Check.RepairAction.Description))
        $lines.Add(('Mode: {0}' -f (Get-RepairModeText -Risk $Check.RepairAction.Risk)))

        if ($Check.RepairAction.Command) {
            $lines.Add(('Command/Value: {0}' -f $Check.RepairAction.Command))
        }

        if ($Check.RepairAction.Url) {
            $lines.Add(('URL: {0}' -f $Check.RepairAction.Url))
        }
    }

    $detailsBox.Text = ($lines -join [Environment]::NewLine)
    Update-RepairUi -Check $Check
}

function Add-CheckToList {
    param([object]$Check)

    $item = New-Object System.Windows.Forms.ListViewItem($Check.Status)
    $item.SubItems.Add($Check.Name) | Out-Null
    $item.SubItems.Add($Check.Message) | Out-Null
    $item.ForeColor = Get-StatusColor -Status $Check.Status
    $item.Tag = $Check
    [void]$checksList.Items.Add($item)
}

function Resize-HealthColumns {
    if (-not $checksList -or $checksList.Columns.Count -lt 3) {
        return
    }

    $clientWidth = [Math]::Max(720, $checksList.ClientSize.Width)
    $checksList.Columns[0].Width = 90
    $checksList.Columns[1].Width = 250
    $checksList.Columns[2].Width = [Math]::Max(360, $clientWidth - 360)
}

function Refresh-Report {
    $statusLabel.Text = 'Checking environment...'
    $form.Refresh()

    try {
        $script:Report = if ($script:TestMode) { New-CodeMateSimulatedReport } else { Get-CodeMateHealthReport }
        $checksList.Items.Clear()

        foreach ($check in $script:Report.Checks) {
            Add-CheckToList -Check $check
        }

        $summaryLabel.Text = ('Pass {0} | Warn {1} | Fail {2}' -f $script:Report.Summary.Pass, $script:Report.Summary.Warn, $script:Report.Summary.Fail)
        $statusLabel.Text = if ($script:TestMode) { ('TEST MODE - simulated check: {0}' -f $script:Report.GeneratedAt) } else { ('Last check: {0}' -f $script:Report.GeneratedAt) }
        Resize-HealthColumns
        Refresh-ToolStatuses
        Update-AutoRepairUi

        if ($checksList.Items.Count -gt 0) {
            $checksList.Items[0].Selected = $true
            $checksList.Select()
        }
    } catch {
        $statusLabel.Text = 'Check failed'
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'CodeMate Setup', 'OK', 'Error') | Out-Null
    }
}

function Invoke-SelectedRepair {
    if (-not $script:SelectedCheck -or -not $script:SelectedCheck.RepairAction) {
        return
    }

    $action = $script:SelectedCheck.RepairAction
    $modeText = Get-RepairModeText -Risk $action.Risk
    $message = "修复方式：$modeText`n`n将执行：$($action.Label)`n`n$($action.Description)"
    if ($action.Command) {
        $message += "`n`n命令/内容：`n$($action.Command)"
    }

    $answer = [System.Windows.Forms.MessageBox]::Show($message, '确认修复', 'OKCancel', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    Initialize-SelectedRepairProgress -Check $script:SelectedCheck -Action $action
    Set-EnvironmentBusyState -Busy $true
    $statusLabel.Text = ('正在修复：{0}' -f $script:SelectedCheck.Name)
    $detailsBox.Text = ('正在修复：{0}{1}{1}{2}' -f $action.Label, [Environment]::NewLine, $action.Description)
    Start-SelectedRepairWorker -Check $script:SelectedCheck -Action $action
}

function Invoke-AutoRepairEnvironment {
    if (-not $script:Report) {
        Refresh-Report
    }

    if ($script:TestMode) {
        if ($script:SimulatedInstalledTools.ContainsKey('node')) {
            [System.Windows.Forms.MessageBox]::Show('测试模式：模拟基础环境已准备好，可以进入第二步安装 AI 编程工具。', '一键安装环境（模拟）', 'OK', 'Information') | Out-Null
            return
        }

        $message = @(
            '测试模式将模拟准备以下基础环境：',
            '',
            '- Node.js: 模拟安装 Node.js LTS',
            '- npm: 模拟随 Node.js 安装',
            '- npm 全局命令 PATH: 模拟写入 PATH',
            '',
            '不会联网、不会下载、不会安装，也不会修改真实 PATH。'
        ) -join [Environment]::NewLine

        $answer = [System.Windows.Forms.MessageBox]::Show($message, '确认一键安装环境（模拟）', 'OKCancel', 'Information')
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
            return
        }

        $script:SimulatedInstalledTools['node'] = $true
        $detailsBox.Text = @(
            '测试模式已模拟完成：',
            '- Node.js: 已模拟安装',
            '- npm: 已模拟安装',
            '- npm 全局命令 PATH: 已模拟配置',
            '',
            '没有执行任何真实下载、安装或环境变量修改。'
        ) -join [Environment]::NewLine
        Refresh-Report
        [System.Windows.Forms.MessageBox]::Show($detailsBox.Text, '一键安装环境结果（模拟）', 'OK', 'Information') | Out-Null
        return
    }

    $plan = Get-CodeMateAutomaticRepairPlan -Report $script:Report
    if (@($plan.RunnableActions).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('当前基础环境已准备好，可以进入第二步安装 AI 编程工具。', '一键安装环境', 'OK', 'Information') | Out-Null
        return
    }

    $actionLines = @($plan.RunnableActions | ForEach-Object { '- {0}: {1}' -f $_.CheckName, $_.Label })
    $message = @(
        '软件将自动准备以下基础环境：',
        '',
        ($actionLines -join [Environment]::NewLine),
        '',
        '安装过程会尽量完成下载、安装、PATH 配置和复检。部分安装可能弹出系统权限确认。'
    ) -join [Environment]::NewLine

    $answer = [System.Windows.Forms.MessageBox]::Show($message, '确认一键安装环境', 'OKCancel', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    Initialize-AutoRepairProgress -Plan $plan
    Set-EnvironmentBusyState -Busy $true
    $statusLabel.Text = '正在一键安装环境...'
    $detailsBox.Text = '正在准备基础环境，请不要关闭窗口。'
    Start-AutoRepairWorker -Report $script:Report
}

function Export-CurrentReport {
    if (-not $script:Report) {
        Refresh-Report
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'JSON Report (*.json)|*.json'
    $dialog.FileName = ('codemate-health-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Export-CodeMateHealthReport -Report $script:Report -Path $dialog.FileName | Out-Null
        [System.Windows.Forms.MessageBox]::Show('Report exported.', 'CodeMate Setup', 'OK', 'Information') | Out-Null
    }
}

function Add-ToolRow {
    param(
        [string]$Name,
        [string]$Description,
        [string]$Command,
        [string]$Url,
        [string]$StatusId
    )

    $item = New-Object System.Windows.Forms.ListViewItem($Name)
    $item.SubItems.Add($Description) | Out-Null
    $item.SubItems.Add('Checking...') | Out-Null
    $item.Tag = [pscustomobject]@{
        Id = $StatusId
        Name = $Name
        Description = $Description
        Command = $Command
        Url = $Url
    }
    [void]$toolsList.Items.Add($item)
}

function Get-SelectedTool {
    if (-not $toolsList -or $toolsList.SelectedItems.Count -eq 0) {
        return $null
    }

    return $toolsList.SelectedItems[0].Tag
}

function Set-ToolDetail {
    $tool = Get-SelectedTool
    if (-not $tool) {
        $toolDetailsBox.Text = 'Select a tool to view install details.'
        $toolInstallButton.Enabled = $false
        $toolUninstallButton.Enabled = $false
        $toolDocsButton.Enabled = $false
        return
    }

    $toolInstallButton.Enabled = $true
    $toolDocsButton.Enabled = -not [string]::IsNullOrWhiteSpace($tool.Url)
    $status = $null
    if ($script:ToolStatusReport) {
        $status = $script:ToolStatusReport | Where-Object { $_.Id -eq $tool.Id } | Select-Object -First 1
    }

    $statusSummary = if ($status) { $status.Summary } else { '尚未检测。' }
    $statusDetected = if ($status -and $status.Detected) { $status.Detected } else { '无' }
    $isInstalled = ($status -and $status.Status -eq 'Installed')
    $installSpec = $null
    try {
        $installSpec = Get-CodeMateToolInstallSpec -ToolId $tool.Id
    } catch {
    }

    $installMethod = if ($installSpec) { $installSpec.SourceLabel } elseif ($tool.Command) { $tool.Command } else { '打开官方页面下载安装。' }
    $installPathNote = if ($installSpec) { $installSpec.InstallPathNote } else { '只有安装器支持自定义安装路径时，预选路径才会生效。' }
    $uninstallNote = if ($installSpec -and $installSpec.PSObject.Properties['UninstallNote'] -and $installSpec.UninstallNote) { $installSpec.UninstallNote } else { '未提供自动卸载方式。' }
    $toolUninstallButton.Enabled = $isInstalled -and $null -ne $installSpec

    $toolDetailsBox.Text = @(
        ('Name: {0}' -f $tool.Name),
        ('Status: {0}' -f $statusSummary),
        ('Description: {0}' -f $tool.Description),
        '',
        ('Detected: {0}' -f $statusDetected),
        '',
        ('Install: {0}' -f $installMethod),
        ('Path: {0}' -f $installPathNote),
        ('Uninstall: {0}' -f $uninstallNote),
        ('Docs: {0}' -f $tool.Url)
    ) -join [Environment]::NewLine
}

function Show-ToolInstallDialog {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = ('安装预选 - {0}' -f $Tool.Name)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(640, 390)
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 7
    $layout.Padding = New-Object System.Windows.Forms.Padding(18)
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 62))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 18))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48))) | Out-Null
    $dialog.Controls.Add($layout)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Dock = 'Fill'
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = ('准备安装 {0}' -f $Spec.Name)
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($titleLabel, 0, 0)

    $sourceLabel = New-Object System.Windows.Forms.Label
    $sourceLabel.Dock = 'Fill'
    $sourceLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $sourceLabel.Text = @(
        ('安装源：{0}' -f $Spec.SourceLabel),
        '程序会在本机完成下载和安装，不会上传你的 API Key 或本地配置。'
    ) -join [Environment]::NewLine
    $layout.Controls.Add($sourceLabel, 0, 1)

    $pathCaption = New-Object System.Windows.Forms.Label
    $pathCaption.Dock = 'Fill'
    $pathCaption.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $pathCaption.Text = '预选安装位置'
    $layout.Controls.Add($pathCaption, 0, 2)

    $pathPanel = New-Object System.Windows.Forms.TableLayoutPanel
    $pathPanel.Dock = 'Fill'
    $pathPanel.ColumnCount = 2
    $pathPanel.RowCount = 1
    $pathPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $pathPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 96))) | Out-Null
    $layout.Controls.Add($pathPanel, 0, 3)

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Dock = 'Fill'
    $pathBox.Text = if ($Spec.DefaultInstallPath) { $Spec.DefaultInstallPath } else { '' }
    $pathPanel.Controls.Add($pathBox, 0, 0)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Dock = 'Fill'
    $browseButton.Text = '浏览'
    $browseButton.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = '选择预选安装位置'
        if (-not [string]::IsNullOrWhiteSpace($pathBox.Text) -and (Test-Path -LiteralPath $pathBox.Text)) {
            $folderDialog.SelectedPath = $pathBox.Text
        }

        if ($folderDialog.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $pathBox.Text = $folderDialog.SelectedPath
        }
    })
    $pathPanel.Controls.Add($browseButton, 1, 0)

    $noteBox = New-Object System.Windows.Forms.TextBox
    $noteBox.Dock = 'Fill'
    $noteBox.Multiline = $true
    $noteBox.ReadOnly = $true
    $noteBox.ScrollBars = 'Vertical'
    $noteBox.Text = @(
        '重要提示：只有软件安装器本身支持更改安装路径时，预选位置才会生效。',
        ('当前工具路径支持：{0}' -f $(if ($Spec.SupportsInstallPath) { '支持或可尝试传递给安装器' } else { '不强制生效，安装器会使用默认位置' })),
        ('说明：{0}' -f $Spec.InstallPathNote),
        '',
        '点击“开始安装”后，CodeMate 会调用官方包源完成下载和安装。安装过程可能需要网络、UAC 授权或等待数分钟。'
    ) -join [Environment]::NewLine
    $layout.Controls.Add($noteBox, 0, 4)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = 'Fill'
    $buttonPanel.FlowDirection = 'RightToLeft'
    $layout.Controls.Add($buttonPanel, 0, 6)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = '取消'
    $cancelButton.Width = 96
    $cancelButton.Height = 32
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $buttonPanel.Controls.Add($cancelButton)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = '开始安装'
    $okButton.Width = 110
    $okButton.Height = 32
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $buttonPanel.Controls.Add($okButton)

    $dialog.AcceptButton = $okButton
    $dialog.CancelButton = $cancelButton

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return [pscustomobject]@{
        InstallPath = $pathBox.Text
    }
}

function Test-CodeMateToolInstalledInGui {
    param([Parameter(Mandatory = $true)][string]$ToolId)

    $status = $script:ToolStatusReport | Where-Object { $_.Id -eq $ToolId } | Select-Object -First 1
    return ($status -and $status.Status -eq 'Installed')
}

function Install-CodeMateToolFromSpec {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec,
        [Parameter(Mandatory = $true)][string]$InstallPath
    )

    if ($script:TestMode) {
        $script:SimulatedInstalledTools[$Tool.Id] = $true
        $statusLabel.Text = ('TEST MODE - {0} simulated install complete' -f $Spec.Name)
        $result = [pscustomobject]@{
            Success = $true
            Message = ('测试模式已模拟安装 {0}。' -f $Spec.Name)
        }
        $message = if ($Tool.Id -eq 'ccswitch') {
            Get-ToolInstallSuccessMessage -Tool $Tool -Spec $Spec -Result $result -InstallPath $InstallPath -Operation 'Install'
        } else {
            @(
            ('测试模式已模拟安装 {0}。' -f $Spec.Name),
            ('安装源：{0}' -f $Spec.SourceLabel),
            ('预选位置：{0}' -f $(if ($InstallPath) { $InstallPath } else { '默认位置' })),
            '',
            '没有联网、没有下载、没有启动安装器，也没有修改系统环境。'
            ) -join [Environment]::NewLine
        }
        $toolDetailsBox.Text = $message
        Refresh-ToolStatuses
        Set-ToolDetail
        $toolDetailsBox.Text = $message
        if ($toolInstallProgressStatusLabel) {
            $toolInstallProgressStatusLabel.Text = ('TEST MODE - {0} simulated install complete' -f $Spec.Name)
        }
        Set-ToolInstallProgressBarValue -Percent 100
        if ($Tool.Id -eq 'ccswitch') {
            Show-CCSwitchLoginGuideDialog -InstallMessage $result.Message
        } else {
            [System.Windows.Forms.MessageBox]::Show($message, '安装完成（模拟）', 'OK', 'Information') | Out-Null
        }
        return $true
    }

    $statusLabel.Text = ('正在安装 {0}...' -f $Spec.Name)
    Initialize-ToolInstallProgress -Tool $Tool -Spec $Spec -InstallPath $InstallPath -Operation 'Install'
    Set-ToolInstallBusyState -Busy $true
    $form.Refresh()
    Start-ToolInstallWorker -Tool $Tool -Spec $Spec -InstallPath $InstallPath -Operation 'Install'
    return $false
}

function Prompt-InstallCCSwitchAfterToolInstall {
    param([Parameter(Mandatory = $true)][object]$InstalledTool)

    if ($InstalledTool.Id -eq 'ccswitch') {
        return
    }

    if ($InstalledTool.Id -notin @('codex-app', 'codex', 'claude', 'cursor')) {
        return
    }

    if (Test-CodeMateToolInstalledInGui -ToolId 'ccswitch') {
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = '推荐安装 CC Switch'
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MinimizeBox = $false
    $dialog.MaximizeBox = $false
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 300)
    $dialog.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 3
    $layout.Padding = New-Object System.Windows.Forms.Padding(18)
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 36))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 48))) | Out-Null
    $dialog.Controls.Add($layout)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Dock = 'Fill'
    $titleLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
    $titleLabel.Text = ('{0} 已安装完成' -f $InstalledTool.Name)
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $layout.Controls.Add($titleLabel, 0, 0)

    $messageBox = New-Object System.Windows.Forms.TextBox
    $messageBox.Dock = 'Fill'
    $messageBox.Multiline = $true
    $messageBox.ReadOnly = $true
    $messageBox.BorderStyle = 'None'
    $messageBox.BackColor = $dialog.BackColor
    $messageBox.Text = @(
        '提示：部分地区或网络环境下，Codex / Claude Code 的官方登录、模型连接可能不稳定。',
        '',
        '如果你准备使用自备 API Key、OpenAI-compatible 网关，或后续把 Provider 配置导入多个 AI 编程工具，建议现在安装 CC Switch。',
        '',
        'CC Switch 可以帮助管理 Codex、Claude Code、Cursor 等工具的配置切换。是否现在下载并安装？'
    ) -join [Environment]::NewLine
    $layout.Controls.Add($messageBox, 0, 1)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = 'Fill'
    $buttonPanel.FlowDirection = 'RightToLeft'
    $layout.Controls.Add($buttonPanel, 0, 2)

    $noButton = New-Object System.Windows.Forms.Button
    $noButton.Text = '否，暂不需要'
    $noButton.Width = 120
    $noButton.Height = 32
    $noButton.DialogResult = [System.Windows.Forms.DialogResult]::No
    $buttonPanel.Controls.Add($noButton)

    $yesButton = New-Object System.Windows.Forms.Button
    $yesButton.Text = '是，推荐下载'
    $yesButton.Width = 130
    $yesButton.Height = 32
    $yesButton.BackColor = [System.Drawing.Color]::FromArgb(196, 37, 37)
    $yesButton.ForeColor = [System.Drawing.Color]::White
    $yesButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $yesButton.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(156, 26, 26)
    $yesButton.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $buttonPanel.Controls.Add($yesButton)

    $dialog.AcceptButton = $yesButton
    $dialog.CancelButton = $noButton

    if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::Yes) {
        return
    }

    $ccSwitchTool = $null
    foreach ($item in $toolsList.Items) {
        if ($item.Tag -and $item.Tag.Id -eq 'ccswitch') {
            $ccSwitchTool = $item.Tag
            break
        }
    }

    if (-not $ccSwitchTool) {
        [System.Windows.Forms.MessageBox]::Show('未找到 CC Switch 安装项。', 'CodeMate Setup', 'OK', 'Warning') | Out-Null
        return
    }

    $ccSwitchSpec = Get-CodeMateToolInstallSpec -ToolId 'ccswitch'
    $selection = Show-ToolInstallDialog -Tool $ccSwitchTool -Spec $ccSwitchSpec
    if (-not $selection) {
        return
    }

    Install-CodeMateToolFromSpec -Tool $ccSwitchTool -Spec $ccSwitchSpec -InstallPath $selection.InstallPath | Out-Null
}

function Open-SelectedToolInstall {
    $tool = Get-SelectedTool
    if (-not $tool) {
        return
    }

    try {
        $spec = Get-CodeMateToolInstallSpec -ToolId $tool.Id
    } catch {
        if ($tool.Url) {
            Start-Process $tool.Url
        }
        return
    }

    $selection = Show-ToolInstallDialog -Tool $tool -Spec $spec
    if (-not $selection) {
        return
    }

    $installed = Install-CodeMateToolFromSpec -Tool $tool -Spec $spec -InstallPath $selection.InstallPath
    if ($installed) {
        Prompt-InstallCCSwitchAfterToolInstall -InstalledTool $tool
    }
}

function Uninstall-CodeMateToolFromSpec {
    param(
        [Parameter(Mandatory = $true)][object]$Tool,
        [Parameter(Mandatory = $true)][object]$Spec
    )

    if ($script:TestMode) {
        if ($script:SimulatedInstalledTools.ContainsKey($Tool.Id)) {
            $script:SimulatedInstalledTools.Remove($Tool.Id)
        }

        $result = [pscustomobject]@{
            Success = $true
            Message = ('测试模式已模拟卸载 {0}。' -f $Spec.Name)
        }
        $message = Get-ToolInstallSuccessMessage -Tool $Tool -Spec $Spec -Result $result -InstallPath '' -Operation 'Uninstall'
        $statusLabel.Text = ('TEST MODE - {0} simulated uninstall complete' -f $Spec.Name)
        Refresh-ToolStatuses
        Set-ToolDetail
        $toolDetailsBox.Text = $message
        if ($toolInstallProgressStatusLabel) {
            $toolInstallProgressStatusLabel.Text = ('TEST MODE - {0} simulated uninstall complete' -f $Spec.Name)
        }
        Set-ToolInstallProgressBarValue -Percent 100
        [System.Windows.Forms.MessageBox]::Show($message, '卸载完成（模拟）', 'OK', 'Information') | Out-Null
        return
    }

    $uninstallKind = if ($Spec.PSObject.Properties['UninstallKind'] -and $Spec.UninstallKind) { $Spec.UninstallKind } else { $Spec.Kind }
    if ($uninstallKind -eq 'manual') {
        $message = @(
            $Spec.UninstallNote,
            '',
            'CodeMate 将打开 Windows「已安装的应用」页面，请在系统设置中搜索并卸载该应用。'
        ) -join [Environment]::NewLine
        $toolDetailsBox.Text = $message
        if ($toolInstallProgressStatusLabel) {
            $toolInstallProgressStatusLabel.Text = ('请在 Windows 设置中卸载 {0}' -f $Spec.Name)
        }
        Set-ToolInstallProgressBarValue -Percent 0
        try {
            Start-Process 'ms-settings:appsfeatures'
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开系统设置失败', 'OK', 'Error') | Out-Null
        }
        [System.Windows.Forms.MessageBox]::Show($message, '手动卸载指引', 'OK', 'Information') | Out-Null
        return
    }

    $statusLabel.Text = ('正在卸载 {0}...' -f $Spec.Name)
    Initialize-ToolInstallProgress -Tool $Tool -Spec $Spec -InstallPath '' -Operation 'Uninstall'
    Set-ToolInstallBusyState -Busy $true
    $form.Refresh()
    Start-ToolInstallWorker -Tool $Tool -Spec $Spec -InstallPath '' -Operation 'Uninstall'
}

function Open-SelectedToolUninstall {
    $tool = Get-SelectedTool
    if (-not $tool) {
        return
    }

    $status = $null
    if ($script:ToolStatusReport) {
        $status = $script:ToolStatusReport | Where-Object { $_.Id -eq $tool.Id } | Select-Object -First 1
    }

    if (-not $status -or $status.Status -ne 'Installed') {
        [System.Windows.Forms.MessageBox]::Show('当前未检测到该工具已安装，无法执行卸载。', '卸载工具', 'OK', 'Information') | Out-Null
        return
    }

    try {
        $spec = Get-CodeMateToolInstallSpec -ToolId $tool.Id
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '卸载工具', 'OK', 'Error') | Out-Null
        return
    }

    $uninstallNote = if ($spec.PSObject.Properties['UninstallNote'] -and $spec.UninstallNote) { $spec.UninstallNote } else { '将尝试卸载该工具。' }
    $extraNote = if ($tool.Id -eq 'ccswitch') {
        '卸载 CC Switch 后，已生成或导入的本地配置文件可能仍保留在用户目录中。'
    } elseif ($tool.Id -in @('codex', 'claude', 'cursor', 'codex-app')) {
        '卸载工具通常不会删除你在工具内保存的账号、项目或配置文件。'
    } else {
        ''
    }

    $message = @(
        ('将卸载：{0}' -f $spec.Name),
        '',
        $uninstallNote,
        $(if (-not [string]::IsNullOrWhiteSpace($extraNote)) { $extraNote } else { $null }),
        '',
        '确定继续吗？'
    ) | Where-Object { $null -ne $_ }
    $answer = [System.Windows.Forms.MessageBox]::Show(($message -join [Environment]::NewLine), '确认卸载', 'OKCancel', 'Warning')
    if ($answer -ne [System.Windows.Forms.DialogResult]::OK) {
        return
    }

    Uninstall-CodeMateToolFromSpec -Tool $tool -Spec $spec
}

function Open-SelectedToolDocs {
    $tool = Get-SelectedTool
    if ($tool -and $tool.Url) {
        Start-Process $tool.Url
    }
}

function Resize-ToolsColumns {
    if (-not $toolsList -or $toolsList.Columns.Count -lt 3) {
        return
    }

    $clientWidth = [Math]::Max(720, $toolsList.ClientSize.Width)
    $toolsList.Columns[0].Width = 190
    $toolsList.Columns[2].Width = 150
    $toolsList.Columns[1].Width = [Math]::Max(300, $clientWidth - 360)
}

function Resize-ToolsSplit {
    if (-not $toolsSplit -or $toolsSplit.Width -le 0) {
        return
    }

    $width = $toolsSplit.ClientSize.Width
    if ($width -le 160) {
        return
    }

    $toolsSplit.Panel1MinSize = 25
    $toolsSplit.Panel2MinSize = 25

    $rightTarget = 340
    $leftMin = if ($width -ge 820) { 420 } else { 260 }
    $rightMin = if ($width -ge 820) { 300 } else { 220 }
    $desiredDistance = $width - $rightTarget
    $desiredDistance = [Math]::Max($leftMin, $desiredDistance)
    $desiredDistance = [Math]::Min($desiredDistance, $width - $rightMin)

    if ($desiredDistance -gt 0 -and $desiredDistance -lt $width) {
        $toolsSplit.SplitterDistance = [int]$desiredDistance
        $toolsSplit.Panel1MinSize = [Math]::Min($leftMin, $toolsSplit.SplitterDistance)
        $toolsSplit.Panel2MinSize = [Math]::Min($rightMin, $width - $toolsSplit.SplitterDistance)
    }
}

function Get-ToolStatusColor {
    param([string]$Status)

    switch ($Status) {
        'Installed' { return [System.Drawing.Color]::FromArgb(32, 124, 67) }
        'Attention' { return [System.Drawing.Color]::FromArgb(173, 105, 0) }
        default { return [System.Drawing.Color]::FromArgb(120, 120, 120) }
    }
}

function Refresh-ToolStatuses {
    $script:ToolStatusReport = if ($script:TestMode) { @(Get-CodeMateSimulatedToolStatuses) } else { @(Get-CodeMateInstallToolStatusReport) }
    $statusById = @{}

    foreach ($entry in $script:ToolStatusReport) {
        $statusById[$entry.Id] = $entry
    }

    foreach ($item in $toolsList.Items) {
        $tool = $item.Tag
        $entry = $null
        if ($tool -and $tool.Id -and $statusById.ContainsKey($tool.Id)) {
            $entry = $statusById[$tool.Id]
        }

        if ($entry) {
            $item.SubItems[2].Text = $entry.Status
            $item.UseItemStyleForSubItems = $false
            $item.SubItems[2].ForeColor = Get-ToolStatusColor -Status $entry.Status
        } else {
            $item.SubItems[2].Text = 'Unknown'
            $item.UseItemStyleForSubItems = $false
            $item.SubItems[2].ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
        }
    }

    if ($toolsList.SelectedItems.Count -gt 0) {
        Set-ToolDetail
    }
}

function Load-ProviderSelection {
    $providerCombo.Items.Clear()
    foreach ($provider in $script:ProviderCatalog.providers) {
        [void]$providerCombo.Items.Add(('{0} [{1}]' -f $provider.name, $provider.risk))
    }
    if ($providerCombo.Items.Count -gt 0) {
        $providerCombo.SelectedIndex = 0
    }
}

function Get-SelectedProvider {
    $index = $providerCombo.SelectedIndex
    if ($index -lt 0) {
        return $script:ProviderCatalog.providers[0]
    }
    return $script:ProviderCatalog.providers[$index]
}

function Update-ProviderFields {
    $provider = Get-SelectedProvider
    $baseUrlBox.Text = Get-CodeMateProviderBaseRootUrl -BaseUrl $provider.baseUrl
    $modelBox.Text = $provider.defaultModel
    $providerNotesBox.Text = ('Risk: {0}{1}{1}{2}' -f $provider.risk, [Environment]::NewLine, $provider.notes)
}

function Test-SelectedProvider {
    $provider = Get-SelectedProvider
    $providerResultBox.Text = 'Testing provider locally...'
    $form.Refresh()

    try {
        $effectiveBaseUrl = Get-CodeMateProviderEffectiveBaseUrl -BaseUrl $baseUrlBox.Text -ShowPrompt
        $script:ProviderTestResult = Test-CodeMateProviderConnection `
            -ProviderId $provider.id `
            -BaseUrl $effectiveBaseUrl `
            -ApiKey $apiKeyBox.Text `
            -Model $modelBox.Text

        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add(('Success: {0}' -f $script:ProviderTestResult.Success))
        $lines.Add(('Message: {0}' -f $script:ProviderTestResult.Message))
        $lines.Add(('Input Base Root: {0}' -f (Get-CodeMateProviderBaseRootUrl -BaseUrl $baseUrlBox.Text)))
        $lines.Add(('Base URL: {0}' -f $script:ProviderTestResult.BaseUrl))
        $lines.Add(('Model: {0}' -f $script:ProviderTestResult.SelectedModel))
        $lines.Add(('Latency: {0} ms' -f $script:ProviderTestResult.LatencyMs))

        if ($script:ProviderTestResult.Capabilities.Count -gt 0) {
            $lines.Add(('Capabilities: {0}' -f ($script:ProviderTestResult.Capabilities -join ', ')))
        }

        if ($script:ProviderTestResult.Models.Count -gt 0) {
            $lines.Add('')
            $lines.Add('Models:')
            foreach ($model in $script:ProviderTestResult.Models) {
                $lines.Add(('  - {0}' -f $model))
            }
        }

        if ($script:ProviderTestResult.Error) {
            $lines.Add('')
            $lines.Add(('Error: {0}' -f $script:ProviderTestResult.Error))
        }

        $providerResultBox.Text = ($lines -join [Environment]::NewLine)
        if ($script:ProviderTestResult.SelectedModel) {
            $modelBox.Text = $script:ProviderTestResult.SelectedModel
        }
    } catch {
        $providerResultBox.Text = $_.Exception.Message
    }
}

function Generate-CCSwitchProfile {
    $provider = Get-SelectedProvider

    try {
        $effectiveBaseUrl = Get-CodeMateProviderEffectiveBaseUrl -BaseUrl $baseUrlBox.Text -ShowPrompt
        $script:CCSwitchExport = New-CodeMateCCSwitchExport `
            -Name $profileNameBox.Text `
            -BaseUrl $effectiveBaseUrl `
            -ApiKey $apiKeyBox.Text `
            -Model $modelBox.Text `
            -ProviderId $provider.id

        $ccswitchOutputBox.Text = ("Deep Link:{0}{1}{0}{0}Redacted Profile:{0}{2}" -f [Environment]::NewLine, $script:CCSwitchExport.DeepLink, $script:CCSwitchExport.RedactedProfileJson)
    } catch {
        $ccswitchOutputBox.Text = $_.Exception.Message
    }
}

function Copy-CCSwitchDeepLink {
    if (-not $script:CCSwitchExport) {
        Generate-CCSwitchProfile
    }

    if ($script:CCSwitchExport) {
        [System.Windows.Forms.Clipboard]::SetText($script:CCSwitchExport.DeepLink)
        [System.Windows.Forms.MessageBox]::Show('Deep link copied.', 'CodeMate Setup', 'OK', 'Information') | Out-Null
    }
}

function Save-CCSwitchProfile {
    if (-not $script:CCSwitchExport) {
        Generate-CCSwitchProfile
    }

    if (-not $script:CCSwitchExport) {
        return
    }

    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'JSON Profile (*.json)|*.json'
    $dialog.FileName = 'ccswitch-profile.json'

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Export-CodeMateCCSwitchProfile -Profile $script:CCSwitchExport.Profile -Path $dialog.FileName | Out-Null
        [System.Windows.Forms.MessageBox]::Show('Profile exported.', 'CodeMate Setup', 'OK', 'Information') | Out-Null
    }
}

function Activate-LicenseFromGui {
    $licenseResultBox.Text = 'Activating license...'
    $form.Refresh()

    try {
        $result = Activate-CodeMateLicense -LicenseServer $licenseServerBox.Text -LicenseCode $licenseCodeBox.Text -Email $emailBox.Text
        if ($result.Success) {
            $script:LicenseGateResult = [pscustomobject]@{
                Success = $true
                Mode = 'Online'
                Message = $result.Message
                License = $result.License
            }
            if ($statusLabel) {
                $statusLabel.Text = Format-CodeMateLicenseStatusText -GateResult $script:LicenseGateResult
            }
        }
        $licenseResultBox.Text = ($result | ConvertTo-Json -Depth 8)
    } catch {
        $licenseResultBox.Text = $_.Exception.Message
    }
}

function Check-LicenseFromGui {
    $licenseResultBox.Text = 'Checking license...'
    $form.Refresh()

    try {
        $result = Test-CodeMateLicense -LicenseServer $licenseServerBox.Text
        if ($result.Success) {
            $script:LicenseGateResult = [pscustomobject]@{
                Success = $true
                Mode = 'Online'
                Message = $result.Message
                License = $result.License
            }
            if ($statusLabel) {
                $statusLabel.Text = Format-CodeMateLicenseStatusText -GateResult $script:LicenseGateResult
            }
        }
        $licenseResultBox.Text = ($result | ConvertTo-Json -Depth 8)
    } catch {
        $licenseResultBox.Text = $_.Exception.Message
    }
}

$script:LicenseGateResult = Show-CodeMateLicenseGate
if (-not $script:LicenseGateResult -or -not $script:LicenseGateResult.Success) {
    return
}

$form = New-Object System.Windows.Forms.Form
$form.Text = if ($script:TestMode) { 'CodeMate Setup - AI Coding Setup Assistant [TEST MODE - SIMULATION]' } else { 'CodeMate Setup - AI Coding Setup Assistant' }
$form.StartPosition = 'CenterScreen'
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Size = New-Object System.Drawing.Size(1120, 760)
$form.MinimumSize = New-Object System.Drawing.Size(900, 640)
Initialize-CodeMateWindowBounds -Form $form

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point(12, 5)
$tabs.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.Controls.Add($tabs)

$healthTab = New-Object System.Windows.Forms.TabPage
$healthTab.Text = 'Environment'
$toolsTab = New-Object System.Windows.Forms.TabPage
$toolsTab.Text = 'Install Tools'
$providerTab = New-Object System.Windows.Forms.TabPage
$providerTab.Text = 'Provider Test'
$ccswitchTab = New-Object System.Windows.Forms.TabPage
$ccswitchTab.Text = 'CC Switch'
$licenseTab = New-Object System.Windows.Forms.TabPage
$licenseTab.Text = 'License'

$providerTab.AutoScroll = $true
$ccswitchTab.AutoScroll = $true
$licenseTab.AutoScroll = $true

[void]$tabs.TabPages.Add($healthTab)
[void]$tabs.TabPages.Add($toolsTab)
[void]$tabs.TabPages.Add($providerTab)
[void]$tabs.TabPages.Add($ccswitchTab)
if ($script:ShowLicenseAdvancedFields) {
    [void]$tabs.TabPages.Add($licenseTab)
}

$healthLayout = New-Object System.Windows.Forms.TableLayoutPanel
$healthLayout.Dock = 'Fill'
$healthLayout.ColumnCount = 1
$healthLayout.RowCount = 3
$healthLayout.Padding = New-Object System.Windows.Forms.Padding(0)
$healthLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $(if ($script:TestMode) { 142 } else { 112 })))) | Out-Null
$healthLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$healthLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 172))) | Out-Null
$healthTab.Controls.Add($healthLayout)

$headerPanel = New-Object System.Windows.Forms.Panel
$headerPanel.Dock = 'Fill'
$headerPanel.Padding = New-Object System.Windows.Forms.Padding(18, 14, 18, 12)
$healthLayout.Controls.Add($headerPanel, 0, 0)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = 'Not checked yet'
$summaryLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
$summaryLabel.Dock = 'Top'
$summaryLabel.Height = 38
$summaryLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$summaryLabel.AutoEllipsis = $true
$headerPanel.Controls.Add($summaryLabel)

if ($script:TestMode) {
    $testModeBanner = New-Object System.Windows.Forms.Label
    $testModeBanner.Text = '模拟测试模式：不会联网、不会下载、不会安装、不会修改 PATH。'
    $testModeBanner.ForeColor = [System.Drawing.Color]::White
    $testModeBanner.BackColor = [System.Drawing.Color]::FromArgb(196, 37, 37)
    $testModeBanner.Dock = 'Top'
    $testModeBanner.Height = 28
    $testModeBanner.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $testModeBanner.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $headerPanel.Controls.Add($testModeBanner)
}

$buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$buttonPanel.Dock = 'Bottom'
$buttonPanel.FlowDirection = 'LeftToRight'
$buttonPanel.WrapContents = $true
$buttonPanel.Height = 46
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
$headerPanel.Controls.Add($buttonPanel)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = 'Recheck'
$refreshButton.Width = 100
$refreshButton.Height = 38
$refreshButton.Add_Click({ Refresh-Report })
$buttonPanel.Controls.Add($refreshButton)

$autoRepairButton = New-Object System.Windows.Forms.Button
$autoRepairButton.Text = '一键安装环境'
$autoRepairButton.Width = 142
$autoRepairButton.Height = 38
$autoRepairButton.Enabled = $false
$autoRepairButton.Add_Click({ Invoke-AutoRepairEnvironment })
$buttonPanel.Controls.Add($autoRepairButton)

$repairButton = New-Object System.Windows.Forms.Button
$repairButton.Text = '执行修复'
$repairButton.Width = 100
$repairButton.Height = 38
$repairButton.Enabled = $false
$repairButton.Add_Click({ Invoke-SelectedRepair })
$buttonPanel.Controls.Add($repairButton)

$openUrlButton = New-Object System.Windows.Forms.Button
$openUrlButton.Text = '查看说明'
$openUrlButton.Width = 112
$openUrlButton.Height = 38
$openUrlButton.Enabled = $false
$openUrlButton.Add_Click({
    if ($script:SelectedCheck -and $script:SelectedCheck.RepairAction -and $script:SelectedCheck.RepairAction.Url) {
        Start-Process $script:SelectedCheck.RepairAction.Url
    }
})
$buttonPanel.Controls.Add($openUrlButton)

$exportButton = New-Object System.Windows.Forms.Button
$exportButton.Text = 'Export'
$exportButton.Width = 100
$exportButton.Height = 38
$exportButton.Add_Click({ Export-CurrentReport })
$buttonPanel.Controls.Add($exportButton)

$mainSplit = New-Object System.Windows.Forms.SplitContainer
$mainSplit.Dock = 'Fill'
$mainSplit.Orientation = 'Vertical'
$mainSplit.SplitterDistance = 640
$mainSplit.Panel1.Padding = New-Object System.Windows.Forms.Padding(16, 10, 8, 12)
$mainSplit.Panel2.Padding = New-Object System.Windows.Forms.Padding(8, 10, 16, 12)
$healthLayout.Controls.Add($mainSplit, 0, 1)

$checksList = New-Object System.Windows.Forms.ListView
$checksList.Dock = 'Fill'
$checksList.View = 'Details'
$checksList.FullRowSelect = $true
$checksList.HideSelection = $false
$checksList.GridLines = $true
$checksList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$checksList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$checksList.Scrollable = $true
[void]$checksList.Columns.Add('Status', 90)
[void]$checksList.Columns.Add('Check', 250)
[void]$checksList.Columns.Add('Result', 600)
$checksList.Add_SelectedIndexChanged({
    if ($checksList.SelectedItems.Count -gt 0) {
        $script:SelectedCheck = $checksList.SelectedItems[0].Tag
        Set-DetailText -Check $script:SelectedCheck
    }
})
$checksList.Add_Resize({ Resize-HealthColumns })
$mainSplit.Panel1.Controls.Add($checksList)

$detailsBox = New-Object System.Windows.Forms.TextBox
$detailsBox.Dock = 'Fill'
$detailsBox.Multiline = $true
$detailsBox.ReadOnly = $true
$detailsBox.ScrollBars = 'Vertical'
$detailsBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$detailsBox.Text = '选择左侧检测项后，可查看问题详情和修复方式。'
$mainSplit.Panel2.Controls.Add($detailsBox)

$repairProgressPanel = New-Object System.Windows.Forms.TableLayoutPanel
$repairProgressPanel.Dock = 'Fill'
$repairProgressPanel.ColumnCount = 1
$repairProgressPanel.RowCount = 3
$repairProgressPanel.Padding = New-Object System.Windows.Forms.Padding(16, 0, 16, 12)
$repairProgressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28))) | Out-Null
$repairProgressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 20))) | Out-Null
$repairProgressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$healthLayout.Controls.Add($repairProgressPanel, 0, 2)

$repairProgressStatusLabel = New-Object System.Windows.Forms.Label
$repairProgressStatusLabel.Dock = 'Fill'
$repairProgressStatusLabel.Text = '修复进度会显示在这里。'
$repairProgressStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$repairProgressStatusLabel.AutoEllipsis = $true
$repairProgressPanel.Controls.Add($repairProgressStatusLabel, 0, 0)

$repairProgressBar = New-Object System.Windows.Forms.ProgressBar
$repairProgressBar.Dock = 'Fill'
$repairProgressBar.Minimum = 0
$repairProgressBar.Maximum = 100
$repairProgressBar.Value = 0
$repairProgressPanel.Controls.Add($repairProgressBar, 0, 1)

$repairProgressList = New-Object System.Windows.Forms.ListView
$repairProgressList.Dock = 'Fill'
$repairProgressList.View = 'Details'
$repairProgressList.FullRowSelect = $true
$repairProgressList.HideSelection = $false
$repairProgressList.GridLines = $true
$repairProgressList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9.5)
$repairProgressList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
$repairProgressList.Scrollable = $true
[void]$repairProgressList.Columns.Add('Status', 82)
[void]$repairProgressList.Columns.Add('Step', 210)
[void]$repairProgressList.Columns.Add('Stage', 120)
[void]$repairProgressList.Columns.Add('Detail', 600)
$repairProgressList.Add_Resize({ Resize-RepairProgressColumns })
$repairProgressPanel.Controls.Add($repairProgressList, 0, 2)
Set-RepairProgressRow -Key 'idle' -Status 'Info' -Step '基础环境' -Stage '待命' -Detail '点击一键安装环境后，会逐项显示下载、安装、复检结果。'

$toolsLayout = New-Object System.Windows.Forms.TableLayoutPanel
$toolsLayout.Dock = 'Fill'
$toolsLayout.ColumnCount = 1
$toolsLayout.RowCount = 2
$toolsLayout.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 12)
$toolsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42))) | Out-Null
$toolsLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$toolsTab.Controls.Add($toolsLayout)

$toolsIntro = New-Object System.Windows.Forms.Label
$toolsIntro.Dock = 'Fill'
$toolsIntro.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$toolsIntro.AutoEllipsis = $true
$toolsIntro.Text = '第二步安装 AI 编程工具。基础运行环境已在 Environment 页处理；这里选择 Codex、Claude Code、Cursor、CC Switch 等工具。'
$toolsLayout.Controls.Add($toolsIntro, 0, 0)

$toolsSplit = New-Object System.Windows.Forms.SplitContainer
$toolsSplit.Dock = 'Fill'
$toolsSplit.Orientation = 'Vertical'
$toolsSplit.Panel1MinSize = 25
$toolsSplit.Panel2MinSize = 25
$toolsSplit.Panel1.Padding = New-Object System.Windows.Forms.Padding(0, 8, 8, 0)
$toolsSplit.Panel2.Padding = New-Object System.Windows.Forms.Padding(8, 8, 0, 0)
$toolsSplit.Add_SizeChanged({ Resize-ToolsSplit })
$toolsLayout.Controls.Add($toolsSplit, 0, 1)

$toolsList = New-Object System.Windows.Forms.ListView
$toolsList.Dock = 'Fill'
$toolsList.View = 'Details'
$toolsList.FullRowSelect = $true
$toolsList.HideSelection = $false
$toolsList.GridLines = $true
$toolsList.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)
$toolsList.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
[void]$toolsList.Columns.Add('Tool', 180)
[void]$toolsList.Columns.Add('Purpose', 360)
[void]$toolsList.Columns.Add('Status', 150)
$toolsList.Add_SelectedIndexChanged({ Set-ToolDetail })
$toolsList.Add_Resize({ Resize-ToolsColumns })
$toolsSplit.Panel1.Controls.Add($toolsList)

$toolRightLayout = New-Object System.Windows.Forms.TableLayoutPanel
$toolRightLayout.Dock = 'Fill'
$toolRightLayout.ColumnCount = 1
$toolRightLayout.RowCount = 3
$toolRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54))) | Out-Null
$toolRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 52))) | Out-Null
$toolRightLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$toolsSplit.Panel2.Controls.Add($toolRightLayout)

$toolButtonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$toolButtonPanel.Dock = 'Fill'
$toolButtonPanel.FlowDirection = 'LeftToRight'
$toolButtonPanel.WrapContents = $true
$toolButtonPanel.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 0)
$toolRightLayout.Controls.Add($toolButtonPanel, 0, 0)

$toolInstallButton = New-Object System.Windows.Forms.Button
$toolInstallButton.Text = '安装'
$toolInstallButton.Width = 92
$toolInstallButton.Height = 36
$toolInstallButton.Enabled = $false
$toolInstallButton.Add_Click({ Open-SelectedToolInstall })
$toolButtonPanel.Controls.Add($toolInstallButton)

$toolUninstallButton = New-Object System.Windows.Forms.Button
$toolUninstallButton.Text = '卸载'
$toolUninstallButton.Width = 92
$toolUninstallButton.Height = 36
$toolUninstallButton.Enabled = $false
$toolUninstallButton.Add_Click({ Open-SelectedToolUninstall })
$toolButtonPanel.Controls.Add($toolUninstallButton)

$toolDocsButton = New-Object System.Windows.Forms.Button
$toolDocsButton.Text = '文档'
$toolDocsButton.Width = 92
$toolDocsButton.Height = 36
$toolDocsButton.Enabled = $false
$toolDocsButton.Add_Click({ Open-SelectedToolDocs })
$toolButtonPanel.Controls.Add($toolDocsButton)

$toolInstallProgressPanel = New-Object System.Windows.Forms.TableLayoutPanel
$toolInstallProgressPanel.Dock = 'Fill'
$toolInstallProgressPanel.ColumnCount = 1
$toolInstallProgressPanel.RowCount = 2
$toolInstallProgressPanel.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$toolInstallProgressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 26))) | Out-Null
$toolInstallProgressPanel.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 20))) | Out-Null
$toolRightLayout.Controls.Add($toolInstallProgressPanel, 0, 1)

$toolInstallProgressStatusLabel = New-Object System.Windows.Forms.Label
$toolInstallProgressStatusLabel.Dock = 'Fill'
$toolInstallProgressStatusLabel.Text = '安装或卸载进度会显示在这里。'
$toolInstallProgressStatusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$toolInstallProgressStatusLabel.AutoEllipsis = $true
$toolInstallProgressPanel.Controls.Add($toolInstallProgressStatusLabel, 0, 0)

$toolInstallProgressBar = New-Object System.Windows.Forms.ProgressBar
$toolInstallProgressBar.Dock = 'Fill'
$toolInstallProgressBar.Minimum = 0
$toolInstallProgressBar.Maximum = 100
$toolInstallProgressBar.Value = 0
$toolInstallProgressPanel.Controls.Add($toolInstallProgressBar, 0, 1)

$toolDetailsBox = New-Object System.Windows.Forms.TextBox
$toolDetailsBox.Dock = 'Fill'
$toolDetailsBox.Multiline = $true
$toolDetailsBox.ReadOnly = $true
$toolDetailsBox.ScrollBars = 'Vertical'
$toolDetailsBox.Font = New-Object System.Drawing.Font('Consolas', 9.5)
$toolDetailsBox.Text = 'Select a tool to view install details.'
$toolRightLayout.Controls.Add($toolDetailsBox, 0, 2)

Add-ToolRow -Name 'Codex 桌面版' -Description 'OpenAI Codex desktop app.' -Command '' -Url 'https://developers.openai.com/codex/app' -StatusId 'codex-app'
Add-ToolRow -Name 'Codex 命令行版' -Description 'OpenAI Codex command-line tool.' -Command 'npm install -g @openai/codex' -Url 'https://developers.openai.com/codex/cli' -StatusId 'codex'
Add-ToolRow -Name 'Claude Code 命令行版' -Description 'Anthropic Claude Code command-line assistant.' -Command 'npm install -g @anthropic-ai/claude-code' -Url 'https://code.claude.com/docs/en/setup' -StatusId 'claude'
Add-ToolRow -Name 'Cursor 桌面版' -Description 'AI editor with BYOK support.' -Command 'winget install --id Anysphere.Cursor -e --source winget' -Url 'https://cursor.com/' -StatusId 'cursor'
Add-ToolRow -Name 'CC Switch 桌面版' -Description 'Configuration switcher for multiple AI coding tools.' -Command '' -Url 'https://github.com/farion1231/cc-switch' -StatusId 'ccswitch'
Resize-ToolsColumns

$providerTab.Controls.Add((New-Label -Text 'Provider' -X 22 -Y 24 -Width 110))
$providerCombo = New-Object System.Windows.Forms.ComboBox
$providerCombo.Location = New-Object System.Drawing.Point(150, 20)
$providerCombo.Size = New-Object System.Drawing.Size(360, 28)
$providerCombo.DropDownStyle = 'DropDownList'
$providerCombo.Add_SelectedIndexChanged({ Update-ProviderFields })
$providerTab.Controls.Add($providerCombo)

$providerTab.Controls.Add((New-Label -Text 'Base URL' -X 22 -Y 66 -Width 110))
$baseUrlBox = New-TextBox -X 150 -Y 62 -Width 500
$baseUrlBox.Add_Leave({ Normalize-ProviderBaseUrlInput -ShowPrompt })
$providerTab.Controls.Add($baseUrlBox)

$baseUrlHint = New-Label -Text '填写根地址，不要带 /v1；程序测试和生成配置时会自动拼接 /v1。' -X 150 -Y 91 -Width 780 -Height 22
$baseUrlHint.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$providerTab.Controls.Add($baseUrlHint)

$providerTab.Controls.Add((New-Label -Text 'API Key' -X 22 -Y 108 -Width 110))
$apiKeyBox = New-TextBox -X 150 -Y 104 -Width 500 -Password
$providerTab.Controls.Add($apiKeyBox)

$providerTab.Controls.Add((New-Label -Text 'Model' -X 22 -Y 150 -Width 110))
$modelBox = New-TextBox -X 150 -Y 146 -Width 300
$providerTab.Controls.Add($modelBox)

$testProviderButton = New-Button -Text 'Test Locally' -X 470 -Y 144 -Width 120
$testProviderButton.Add_Click({ Test-SelectedProvider })
$providerTab.Controls.Add($testProviderButton)

$providerNotesBox = New-Object System.Windows.Forms.TextBox
$providerNotesBox.Location = New-Object System.Drawing.Point(680, 20)
$providerNotesBox.Size = New-Object System.Drawing.Size(320, 160)
$providerNotesBox.Multiline = $true
$providerNotesBox.ReadOnly = $true
$providerNotesBox.ScrollBars = 'Vertical'
$providerTab.Controls.Add($providerNotesBox)

$providerResultBox = New-Object System.Windows.Forms.TextBox
$providerResultBox.Location = New-Object System.Drawing.Point(22, 205)
$providerResultBox.Size = New-Object System.Drawing.Size(978, 390)
$providerResultBox.Multiline = $true
$providerResultBox.ReadOnly = $true
$providerResultBox.ScrollBars = 'Both'
$providerResultBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$providerResultBox.Text = 'Provider test results will appear here.'
$providerTab.Controls.Add($providerResultBox)

$ccswitchTab.Controls.Add((New-Label -Text 'Profile Name' -X 22 -Y 24 -Width 120))
$profileNameBox = New-TextBox -X 150 -Y 20 -Width 360 -Text 'CodeMate Provider'
$ccswitchTab.Controls.Add($profileNameBox)

$generateProfileButton = New-Button -Text 'Generate' -X 530 -Y 18 -Width 110
$generateProfileButton.Add_Click({ Generate-CCSwitchProfile })
$ccswitchTab.Controls.Add($generateProfileButton)

$copyDeepLinkButton = New-Button -Text 'Copy Link' -X 650 -Y 18 -Width 110
$copyDeepLinkButton.Add_Click({ Copy-CCSwitchDeepLink })
$ccswitchTab.Controls.Add($copyDeepLinkButton)

$saveProfileButton = New-Button -Text 'Save JSON' -X 770 -Y 18 -Width 110
$saveProfileButton.Add_Click({ Save-CCSwitchProfile })
$ccswitchTab.Controls.Add($saveProfileButton)

$openDeepLinkButton = New-Button -Text 'Open Link' -X 890 -Y 18 -Width 110
$openDeepLinkButton.Add_Click({
    if (-not $script:CCSwitchExport) { Generate-CCSwitchProfile }
    if ($script:CCSwitchExport) { Start-Process $script:CCSwitchExport.DeepLink }
})
$ccswitchTab.Controls.Add($openDeepLinkButton)

$ccswitchGuideButton = New-Button -Text '教程' -X 22 -Y 62 -Width 90
$ccswitchGuideButton.Add_Click({ Open-CCSwitchGuideDocument })
$ccswitchTab.Controls.Add($ccswitchGuideButton)

$ccswitchHelp = New-Label -Text 'This uses the Provider Test tab fields. API Key is only used locally to generate the profile.' -X 130 -Y 66 -Width 870
$ccswitchTab.Controls.Add($ccswitchHelp)

$ccswitchOutputBox = New-Object System.Windows.Forms.TextBox
$ccswitchOutputBox.Location = New-Object System.Drawing.Point(22, 100)
$ccswitchOutputBox.Size = New-Object System.Drawing.Size(978, 495)
$ccswitchOutputBox.Multiline = $true
$ccswitchOutputBox.ReadOnly = $true
$ccswitchOutputBox.ScrollBars = 'Both'
$ccswitchOutputBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$ccswitchOutputBox.Text = 'Generated CC Switch profile will appear here.'
$ccswitchTab.Controls.Add($ccswitchOutputBox)

$licenseTab.Controls.Add((New-Label -Text 'License Server' -X 22 -Y 24 -Width 120))
$licenseServerBox = New-TextBox -X 150 -Y 20 -Width 430 -Text 'http://127.0.0.1:8787'
$licenseTab.Controls.Add($licenseServerBox)

$licenseTab.Controls.Add((New-Label -Text 'License Code' -X 22 -Y 66 -Width 120))
$licenseCodeBox = New-TextBox -X 150 -Y 62 -Width 430
$licenseTab.Controls.Add($licenseCodeBox)

$licenseTab.Controls.Add((New-Label -Text 'Email' -X 22 -Y 108 -Width 120))
$emailBox = New-TextBox -X 150 -Y 104 -Width 430
$licenseTab.Controls.Add($emailBox)

$activateLicenseButton = New-Button -Text 'Activate' -X 610 -Y 60 -Width 110
$activateLicenseButton.Add_Click({ Activate-LicenseFromGui })
$licenseTab.Controls.Add($activateLicenseButton)

$checkLicenseButton = New-Button -Text 'Check' -X 730 -Y 60 -Width 110
$checkLicenseButton.Add_Click({ Check-LicenseFromGui })
$licenseTab.Controls.Add($checkLicenseButton)

$licenseTip = New-Label -Text '启动时必须通过授权验证。授权数据保存在 %LOCALAPPDATA%\\CodeMateSetup；服务器只保存授权/机器绑定状态，不接收 API provider keys。' -X 22 -Y 150 -Width 930
$licenseTab.Controls.Add($licenseTip)

$licenseResultBox = New-Object System.Windows.Forms.TextBox
$licenseResultBox.Location = New-Object System.Drawing.Point(22, 190)
$licenseResultBox.Size = New-Object System.Drawing.Size(978, 405)
$licenseResultBox.Multiline = $true
$licenseResultBox.ReadOnly = $true
$licenseResultBox.ScrollBars = 'Both'
$licenseResultBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$licenseResultBox.Text = 'License activation result will appear here.'
$licenseTab.Controls.Add($licenseResultBox)

$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = if ($script:TestMode) { 'TEST MODE - simulation only, no download/install/PATH changes' } else { Format-CodeMateLicenseStatusText -GateResult $script:LicenseGateResult }
[void]$statusStrip.Items.Add($statusLabel)
$form.Controls.Add($statusStrip)

Load-ProviderSelection
if ($script:LicenseGateResult -and $script:LicenseGateResult.License) {
    if ($licenseServerBox) { $licenseServerBox.Text = $script:LicenseGateResult.License.server }
    if ($licenseCodeBox) { $licenseCodeBox.Text = $script:LicenseGateResult.License.code }
    if ($licenseResultBox) { $licenseResultBox.Text = ($script:LicenseGateResult | ConvertTo-Json -Depth 8) }
}
$form.Add_FormClosing({
    Stop-AutoRepairUiRuntime
    Stop-ToolInstallUiRuntime
    Save-CodeMateWindowBounds -Form $form
})
$form.Add_Shown({ Refresh-Report })

[void][System.Windows.Forms.Application]::Run($form)
