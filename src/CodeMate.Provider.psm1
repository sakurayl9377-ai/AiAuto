Set-StrictMode -Version 2.0

function Join-CodeMateUrl {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $base = $BaseUrl.TrimEnd('/')
    $suffix = if ($Path.StartsWith('/')) { $Path } else { '/' + $Path }
    return $base + $suffix
}

function Protect-CodeMateProviderSecret {
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

function Get-CodeMateProviderCatalog {
    param(
        [string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\providers.json')
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("Provider catalog not found: {0}" -f $Path)
    }

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    return $raw | ConvertFrom-Json
}

function Get-CodeMateProvider {
    param(
        [Parameter(Mandatory = $true)][string]$ProviderId,
        [string]$CatalogPath
    )

    $catalog = if ($CatalogPath) { Get-CodeMateProviderCatalog -Path $CatalogPath } else { Get-CodeMateProviderCatalog }
    $provider = $catalog.providers | Where-Object { $_.id -eq $ProviderId } | Select-Object -First 1
    if (-not $provider) {
        throw ("Provider not found: {0}" -f $ProviderId)
    }

    return $provider
}

function New-CodeMateProviderHeaders {
    param(
        [Parameter(Mandatory = $true)][object]$Provider,
        [string]$ApiKey
    )

    $headers = @{
        'Accept' = 'application/json'
        'Content-Type' = 'application/json'
    }

    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $headerName = if ($Provider.apiKeyHeader) { [string]$Provider.apiKeyHeader } else { 'Authorization' }
        $prefix = if ($null -ne $Provider.apiKeyPrefix) { [string]$Provider.apiKeyPrefix } else { 'Bearer ' }
        $headers[$headerName] = $prefix + $ApiKey
    }

    return $headers
}

function Invoke-CodeMateHttpJson {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Headers = @{},
        [object]$Body,
        [int]$TimeoutSeconds = 20
    )

    try {
        $params = @{
            Method = $Method
            Uri = $Url
            Headers = $Headers
            TimeoutSec = $TimeoutSeconds
            ErrorAction = 'Stop'
        }

        if ($null -ne $Body) {
            $params.Body = ($Body | ConvertTo-Json -Depth 10)
        }

        $started = Get-Date
        $response = Invoke-RestMethod @params
        $elapsed = [int]((Get-Date) - $started).TotalMilliseconds

        return [pscustomobject]@{
            Success = $true
            StatusCode = 200
            LatencyMs = $elapsed
            Body = $response
            Error = $null
        }
    } catch {
        $elapsed = if ($started) { [int]((Get-Date) - $started).TotalMilliseconds } else { 0 }
        $statusCode = $null

        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        return [pscustomobject]@{
            Success = $false
            StatusCode = $statusCode
            LatencyMs = $elapsed
            Body = $null
            Error = Protect-CodeMateProviderSecret -Text $_.Exception.Message
        }
    }
}

function Test-CodeMateProviderConnection {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [string]$ApiKey,
        [string]$Model,
        [string]$ProviderId = 'custom',
        [int]$TimeoutSeconds = 20
    )

    $provider = Get-CodeMateProvider -ProviderId $ProviderId
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        $BaseUrl = $provider.baseUrl
    }

    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        return [pscustomobject]@{
            Success = $false
            Message = 'Base URL is required.'
            BaseUrl = ''
            Models = @()
            SelectedModel = $Model
            LatencyMs = 0
            Capabilities = @()
            Error = 'Base URL is empty.'
        }
    }

    $headers = New-CodeMateProviderHeaders -Provider $provider -ApiKey $ApiKey
    $modelsUrl = Join-CodeMateUrl -BaseUrl $BaseUrl -Path $provider.modelsEndpoint
    $modelsResponse = Invoke-CodeMateHttpJson -Method 'GET' -Url $modelsUrl -Headers $headers -TimeoutSeconds $TimeoutSeconds

    $modelIds = @()
    if ($modelsResponse.Success -and $modelsResponse.Body) {
        if ($modelsResponse.Body.data) {
            $modelIds = @($modelsResponse.Body.data | ForEach-Object { $_.id } | Where-Object { $_ })
        } elseif ($modelsResponse.Body.models) {
            $modelIds = @($modelsResponse.Body.models | ForEach-Object { if ($_.id) { $_.id } else { $_ } } | Where-Object { $_ })
        }
    }

    $selectedModel = $Model
    if ([string]::IsNullOrWhiteSpace($selectedModel)) {
        if ($modelIds.Count -gt 0) {
            $selectedModel = [string]$modelIds[0]
        } elseif ($provider.defaultModel) {
            $selectedModel = [string]$provider.defaultModel
        }
    }

    $chatOk = $false
    $chatLatency = 0
    $chatError = $null

    if (-not [string]::IsNullOrWhiteSpace($selectedModel)) {
        $chatUrl = Join-CodeMateUrl -BaseUrl $BaseUrl -Path $provider.chatCompletionsEndpoint
        $body = @{
            model = $selectedModel
            messages = @(
                @{ role = 'user'; content = 'Reply with OK.' }
            )
            max_tokens = 8
            temperature = 0
            stream = $false
        }

        $chatResponse = Invoke-CodeMateHttpJson -Method 'POST' -Url $chatUrl -Headers $headers -Body $body -TimeoutSeconds $TimeoutSeconds
        $chatOk = $chatResponse.Success
        $chatLatency = $chatResponse.LatencyMs
        $chatError = $chatResponse.Error
    }

    $success = $modelsResponse.Success -or $chatOk
    $message = if ($success) {
        'Provider connection test passed.'
    } elseif ($modelsResponse.Error) {
        $modelsResponse.Error
    } else {
        'Provider connection test failed.'
    }

    [pscustomobject]@{
        Success = $success
        Message = $message
        BaseUrl = $BaseUrl
        Models = @($modelIds | Select-Object -First 30)
        SelectedModel = $selectedModel
        LatencyMs = if ($chatLatency -gt 0) { $chatLatency } else { $modelsResponse.LatencyMs }
        Capabilities = @($provider.supports)
        Error = if ($chatError) { $chatError } else { $modelsResponse.Error }
    }
}

Export-ModuleMember -Function @(
    'Get-CodeMateProviderCatalog',
    'Get-CodeMateProvider',
    'Test-CodeMateProviderConnection',
    'Protect-CodeMateProviderSecret'
)

