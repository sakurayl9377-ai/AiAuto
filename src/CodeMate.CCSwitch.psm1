Set-StrictMode -Version 2.0

function ConvertTo-CodeMateBase64Url {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $base64 = [Convert]::ToBase64String($bytes)
    return $base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Protect-CodeMateConfigSecret {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $patterns = @(
        'sk-[A-Za-z0-9_-]{8,}',
        'sk-ant-[A-Za-z0-9_-]{8,}',
        '(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*["'']?[^"''\s,;]+'
    )

    $redacted = $Text
    foreach ($pattern in $patterns) {
        $redacted = [regex]::Replace($redacted, $pattern, '[REDACTED]')
    }

    return $redacted
}

function New-CodeMateCCSwitchProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [string]$Model,
        [string]$ProviderId = 'custom',
        [string[]]$Targets = @('codex', 'claude', 'gemini')
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw 'Profile name is required.'
    }

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        throw 'Base URL is required.'
    }

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        throw 'API Key is required.'
    }

    $profile = [ordered]@{
        schema = 'codemate.ccswitch.profile.v1'
        name = $Name
        provider = [ordered]@{
            id = $ProviderId
            type = 'openai-compatible'
            base_url = $BaseUrl.TrimEnd('/')
            api_key = $ApiKey
            model = $Model
        }
        targets = @($Targets)
        created_at = (Get-Date).ToString('s')
        security = [ordered]@{
            generated_locally = $true
            api_key_uploaded_to_codemate = $false
        }
    }

    return [pscustomobject]$profile
}

function New-CodeMateCCSwitchDeepLink {
    param(
        [Parameter(Mandatory = $true)][object]$Profile
    )

    $json = $Profile | ConvertTo-Json -Depth 10 -Compress
    $encoded = ConvertTo-CodeMateBase64Url -Text $json
    return 'ccswitch://import?profile=' + $encoded
}

function Export-CodeMateCCSwitchProfile {
    param(
        [Parameter(Mandatory = $true)][object]$Profile,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Redacted
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $Profile | ConvertTo-Json -Depth 10
    if ($Redacted) {
        $json = Protect-CodeMateConfigSecret -Text $json
    }

    $json | Set-Content -LiteralPath $Path -Encoding UTF8
    return $Path
}

function New-CodeMateCCSwitchExport {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [string]$Model,
        [string]$ProviderId = 'custom',
        [string[]]$Targets = @('codex', 'claude', 'gemini')
    )

    $profile = New-CodeMateCCSwitchProfile -Name $Name -BaseUrl $BaseUrl -ApiKey $ApiKey -Model $Model -ProviderId $ProviderId -Targets $Targets
    $deepLink = New-CodeMateCCSwitchDeepLink -Profile $profile

    return [pscustomobject]@{
        Profile = $profile
        DeepLink = $deepLink
        RedactedProfileJson = Protect-CodeMateConfigSecret -Text ($profile | ConvertTo-Json -Depth 10)
    }
}

Export-ModuleMember -Function @(
    'New-CodeMateCCSwitchProfile',
    'New-CodeMateCCSwitchDeepLink',
    'Export-CodeMateCCSwitchProfile',
    'New-CodeMateCCSwitchExport',
    'Protect-CodeMateConfigSecret'
)

