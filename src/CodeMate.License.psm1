Set-StrictMode -Version 2.0

function Get-CodeMateMachineId {
    $parts = @()

    try {
        $computer = Get-CimInstance Win32_ComputerSystemProduct
        if ($computer.UUID) { $parts += $computer.UUID }
    } catch {
    }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($os.SerialNumber) { $parts += $os.SerialNumber }
    } catch {
    }

    $parts += $env:COMPUTERNAME
    $parts += $env:USERNAME

    $joined = ($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join '|'
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $hash = $sha.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
}

function Get-CodeMateLicenseStorePath {
    $dir = Join-Path $env:LOCALAPPDATA 'CodeMateSetup'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    return Join-Path $dir 'license.json'
}

function Get-CodeMateDefaultLicenseServer {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEMATE_LICENSE_SERVER)) {
        return $env:CODEMATE_LICENSE_SERVER.TrimEnd('/')
    }

    return 'http://127.0.0.1:8787'
}

function Save-CodeMateLocalLicense {
    param([Parameter(Mandatory = $true)][object]$License)

    $path = Get-CodeMateLicenseStorePath
    $License | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-CodeMateObjectPropertyValue {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Default = $null
    )

    if (-not $Object -or -not $Object.PSObject.Properties[$Name]) {
        return $Default
    }

    $value = $Object.PSObject.Properties[$Name].Value
    if ($null -eq $value) {
        return $Default
    }

    return $value
}

function Set-CodeMateObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [object]$Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.PSObject.Properties[$Name].Value = $Value
    } else {
        Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value -Force
    }
}

function Protect-CodeMateLicenseSecret {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $patterns = @(
        'CM-[A-Z0-9-]{8,}',
        '(?i)(license|token|secret|password)\s*[:=]\s*["'']?[^"''\s,;]+'
    )

    $redacted = $Text
    foreach ($pattern in $patterns) {
        $redacted = [regex]::Replace($redacted, $pattern, '[REDACTED]')
    }

    return $redacted
}

function Invoke-CodeMateLicenseApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [object]$Body,
        [int]$TimeoutSeconds = 15
    )

    try {
        $params = @{
            Method = $Method
            Uri = $Url
            ContentType = 'application/json'
            TimeoutSec = $TimeoutSeconds
            ErrorAction = 'Stop'
        }

        if ($null -ne $Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
        }

        $response = Invoke-RestMethod @params
        return [pscustomobject]@{
            Success = $true
            Body = $response
            Error = $null
        }
    } catch {
        return [pscustomobject]@{
            Success = $false
            Body = $null
            Error = Protect-CodeMateLicenseSecret -Text $_.Exception.Message
        }
    }
}

function Enable-CodeMateLicense {
    param(
        [Parameter(Mandatory = $true)][string]$LicenseServer,
        [Parameter(Mandatory = $true)][string]$LicenseCode,
        [string]$Email
    )

    $server = if ([string]::IsNullOrWhiteSpace($LicenseServer)) { Get-CodeMateDefaultLicenseServer } else { $LicenseServer.TrimEnd('/') }
    $machineId = Get-CodeMateMachineId
    $body = @{
        code = $LicenseCode.Trim()
        machineId = $machineId
        email = $Email
        product = 'codemate-setup'
        version = '0.1.0'
    }

    $response = Invoke-CodeMateLicenseApi -Method 'POST' -Url ($server + '/api/licenses/activate') -Body $body
    if (-not $response.Success) {
        return [pscustomobject]@{
            Success = $false
            Message = $response.Error
            License = $null
        }
    }

    if (-not $response.Body.ok) {
        return [pscustomobject]@{
            Success = $false
            Message = $response.Body.message
            License = $null
        }
    }

    $license = [pscustomobject]@{
        server = $server
        code = $LicenseCode.Trim()
        token = $response.Body.token
        plan = $response.Body.plan
        status = $response.Body.status
        expiresAt = $response.Body.expiresAt
        activatedAt = (Get-Date).ToString('s')
        lastValidatedAt = (Get-Date).ToString('s')
        machineId = $machineId
    }

    $path = Save-CodeMateLocalLicense -License $license

    return [pscustomobject]@{
        Success = $true
        Message = 'License activated.'
        License = $license
        Path = $path
    }
}

function Get-CodeMateLocalLicense {
    $path = Get-CodeMateLicenseStorePath
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-CodeMateLicense {
    param(
        [string]$LicenseServer
    )

    $license = Get-CodeMateLocalLicense
    if (-not $license) {
        return [pscustomobject]@{
            Success = $false
            Message = 'No local license found.'
            License = $null
        }
    }

    $storedServer = Get-CodeMateObjectPropertyValue -Object $license -Name 'server' -Default ''
    $server = if ($LicenseServer) { $LicenseServer.TrimEnd('/') } elseif ($storedServer) { [string]$storedServer } else { Get-CodeMateDefaultLicenseServer }
    if ([string]::IsNullOrWhiteSpace($server)) {
        return [pscustomobject]@{
            Success = $false
            Message = 'License server is missing.'
            License = $license
        }
    }

    $storedCode = Get-CodeMateObjectPropertyValue -Object $license -Name 'code' -Default ''
    $storedToken = Get-CodeMateObjectPropertyValue -Object $license -Name 'token' -Default ''
    if ([string]::IsNullOrWhiteSpace([string]$storedCode) -or [string]::IsNullOrWhiteSpace([string]$storedToken)) {
        return [pscustomobject]@{
            Success = $false
            Message = 'Local license is incomplete. Please activate again.'
            License = $license
        }
    }

    $body = @{
        code = $storedCode
        token = $storedToken
        machineId = Get-CodeMateMachineId
        product = 'codemate-setup'
    }

    $response = Invoke-CodeMateLicenseApi -Method 'POST' -Url ($server + '/api/licenses/refresh') -Body $body
    if (-not $response.Success) {
        return [pscustomobject]@{
            Success = $false
            Message = $response.Error
            License = $license
        }
    }

    $success = [bool]$response.Body.ok
    if ($success) {
        Set-CodeMateObjectPropertyValue -Object $license -Name 'server' -Value $server
        Set-CodeMateObjectPropertyValue -Object $license -Name 'plan' -Value $response.Body.plan
        Set-CodeMateObjectPropertyValue -Object $license -Name 'status' -Value $response.Body.status
        Set-CodeMateObjectPropertyValue -Object $license -Name 'expiresAt' -Value $response.Body.expiresAt
        Set-CodeMateObjectPropertyValue -Object $license -Name 'lastValidatedAt' -Value (Get-Date).ToString('s')
        Save-CodeMateLocalLicense -License $license | Out-Null
    }

    return [pscustomobject]@{
        Success = $success
        Message = $response.Body.message
        License = $license
        ServerResponse = $response.Body
    }
}

function Test-CodeMateLicenseOfflineGrace {
    param(
        [object]$License,
        [int]$GraceDays = 3
    )

    $lastValidatedText = Get-CodeMateObjectPropertyValue -Object $License -Name 'lastValidatedAt' -Default ''
    if (-not $License -or -not $lastValidatedText) {
        return [pscustomobject]@{
            Success = $false
            Message = 'No validated local license is available for offline use.'
            RemainingDays = 0
        }
    }

    try {
        $lastValidatedAt = [datetime]::Parse([string]$lastValidatedText)
    } catch {
        return [pscustomobject]@{
            Success = $false
            Message = 'Local license validation timestamp is invalid.'
            RemainingDays = 0
        }
    }

    $expiresAtText = Get-CodeMateObjectPropertyValue -Object $License -Name 'expiresAt' -Default ''
    if ($expiresAtText) {
        try {
            $expiresAt = [datetime]::Parse([string]$expiresAtText)
            if ((Get-Date) -gt $expiresAt) {
                return [pscustomobject]@{
                    Success = $false
                    Message = 'Local license has expired.'
                    RemainingDays = 0
                }
            }
        } catch {
        }
    }

    $expiresGraceAt = $lastValidatedAt.AddDays($GraceDays)
    $remaining = [Math]::Max(0, [int][Math]::Ceiling(($expiresGraceAt - (Get-Date)).TotalDays))
    if ((Get-Date) -le $expiresGraceAt) {
        return [pscustomobject]@{
            Success = $true
            Message = ('Offline grace is active. Remaining days: {0}.' -f $remaining)
            RemainingDays = $remaining
        }
    }

    return [pscustomobject]@{
        Success = $false
        Message = 'Offline grace period has expired.'
        RemainingDays = 0
    }
}

function Test-CodeMateLicenseGate {
    param(
        [string]$LicenseServer,
        [int]$OfflineGraceDays = 3
    )

    $license = Get-CodeMateLocalLicense
    if (-not $license) {
        return [pscustomobject]@{
            Success = $false
            Mode = 'Missing'
            Message = 'No local license found.'
            License = $null
        }
    }

    $machineId = Get-CodeMateMachineId
    $storedMachineId = Get-CodeMateObjectPropertyValue -Object $license -Name 'machineId' -Default ''
    if ($storedMachineId -and $storedMachineId -ne $machineId) {
        return [pscustomobject]@{
            Success = $false
            Mode = 'MachineMismatch'
            Message = 'Local license is bound to a different machine.'
            License = $license
        }
    }

    $storedServer = Get-CodeMateObjectPropertyValue -Object $license -Name 'server' -Default ''
    $server = if ($LicenseServer) { $LicenseServer.TrimEnd('/') } elseif ($storedServer) { [string]$storedServer } else { Get-CodeMateDefaultLicenseServer }
    $online = Test-CodeMateLicense -LicenseServer $server
    if ($online.Success) {
        return [pscustomobject]@{
            Success = $true
            Mode = 'Online'
            Message = $online.Message
            License = $online.License
        }
    }

    $offline = Test-CodeMateLicenseOfflineGrace -License $license -GraceDays $OfflineGraceDays
    if ($offline.Success) {
        return [pscustomobject]@{
            Success = $true
            Mode = 'OfflineGrace'
            Message = ('{0} Latest server check failed: {1}' -f $offline.Message, $online.Message)
            License = $license
        }
    }

    return [pscustomobject]@{
        Success = $false
        Mode = 'Invalid'
        Message = $online.Message
        License = $license
    }
}

Set-Alias -Name Activate-CodeMateLicense -Value Enable-CodeMateLicense

Export-ModuleMember -Function @(
    'Get-CodeMateMachineId',
    'Get-CodeMateDefaultLicenseServer',
    'Enable-CodeMateLicense',
    'Get-CodeMateLocalLicense',
    'Test-CodeMateLicense',
    'Test-CodeMateLicenseGate',
    'Test-CodeMateLicenseOfflineGrace',
    'Protect-CodeMateLicenseSecret'
) -Alias 'Activate-CodeMateLicense'
