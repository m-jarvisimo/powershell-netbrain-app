Set-StrictMode -Version Latest

function Get-PNAConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "PNA config file not found: $Path"
    }

    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($section in 'NetBrain', 'ServiceNow', 'Workflow') {
        if (-not ($config.PSObject.Properties.Name -contains $section)) {
            throw "PNA config is missing required section: $section"
        }
    }

    return $config
}

function Get-PNASecretString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Secret file not found: $Path"
    }

    # Preferred path: DPAPI / Clixml serialized secret objects.
    try {
        $clixml = Import-Clixml -LiteralPath $Path -ErrorAction Stop
        if ($clixml -is [securestring]) {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($clixml)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        }
        if ($clixml -is [pscredential]) {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($clixml.Password)
            try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
            finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        }
        if ($clixml -is [string] -and $clixml.Trim()) {
            return $clixml.Trim()
        }
    }
    catch {
        # Fall back to secure-string text or, as a last resort, plaintext for non-production bootstrapping.
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if (-not $raw -or -not $raw.Trim()) {
        throw "Secret file is empty: $Path"
    }

    $text = $raw.Trim()
    try {
        $secure = $text | ConvertTo-SecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
    catch {
        return $text
    }
}

function Write-PNALog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO',
        [Parameter()]
        [string]$LogPath
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 's'), $Level, $Message
    Write-Host $line

    if ($LogPath) {
        $dir = Split-Path -Path $LogPath -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line
    }

    return $line
}

function Get-PNAState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{}
    }

    $raw = Get-Content -LiteralPath $Path -Raw
    if (-not $raw -or -not $raw.Trim()) {
        return [pscustomobject]@{}
    }

    try {
        return $raw | ConvertFrom-Json
    }
    catch {
        throw "PNA state file is not valid JSON: $Path"
    }
}

function Set-PNAState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [object]$State
    )

    $dir = Split-Path -Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 32 | Set-Content -LiteralPath $Path -Encoding utf8
    return $State
}

function Acquire-PNARunLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatePath,
        [Parameter()]
        [int]$Minutes = 30
    )

    $now = [DateTime]::UtcNow
    $state = Get-PNAState -Path $StatePath
    $lockUtc = $null
    if ($state.PSObject.Properties.Name -contains 'RunLockUtc' -and $state.RunLockUtc) {
        try { $lockUtc = [DateTime]::Parse($state.RunLockUtc).ToUniversalTime() } catch { $lockUtc = $null }
    }

    if ($lockUtc) {
        $age = $now - $lockUtc
        if ($age.TotalMinutes -lt $Minutes) {
            return [pscustomobject]@{
                Acquired = $false
                LockUtc  = $lockUtc.ToString('o')
                AgeMinutes = [math]::Round($age.TotalMinutes, 2)
            }
        }
    }

    $state | Add-Member -NotePropertyName RunLockUtc -NotePropertyValue $now.ToString('o') -Force
    $state | Add-Member -NotePropertyName RunLockHost -NotePropertyValue $env:COMPUTERNAME -Force
    Set-PNAState -Path $StatePath -State $state | Out-Null

    return [pscustomobject]@{
        Acquired = $true
        LockUtc  = $now.ToString('o')
        AgeMinutes = 0
    }
}

function Release-PNARunLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatePath
    )

    if (-not (Test-Path -LiteralPath $StatePath)) {
        return [pscustomobject]@{ Released = $true; Skipped = $true }
    }

    $state = Get-PNAState -Path $StatePath
    if ($state.PSObject.Properties.Name -contains 'RunLockUtc') {
        $state.PSObject.Properties.Remove('RunLockUtc')
    }
    if ($state.PSObject.Properties.Name -contains 'RunLockHost') {
        $state.PSObject.Properties.Remove('RunLockHost')
    }

    Set-PNAState -Path $StatePath -State $state | Out-Null
    return [pscustomobject]@{ Released = $true; Skipped = $false }
}

function Invoke-PNAHttpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseUrl,
        [Parameter(Mandatory)]
        [string]$Method,
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter()]
        [hashtable]$Headers = @{},
        [Parameter()]
        [object]$Body,
        [Parameter()]
        [int]$TimeoutSec = 180
    )

    $uri = $BaseUrl.TrimEnd('/') + '/' + $Path.TrimStart('/')
    $invokeParams = @{
        Uri        = $uri
        Method     = $Method
        Headers    = $Headers
        TimeoutSec = $TimeoutSec
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $invokeParams.ContentType = 'application/json'
        $invokeParams.Body = $Body | ConvertTo-Json -Depth 16 -Compress
    }

    try {
        $response = Invoke-RestMethod @invokeParams
        return [pscustomobject]@{
            StatusCode = 200
            Body       = $response
            Raw        = $response
            Error      = $null
        }
    }
    catch {
        $status = $null
        $raw = $null
        if ($_.Exception.Response) {
            try {
                $status = [int]$_.Exception.Response.StatusCode
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $raw = $reader.ReadToEnd()
                $reader.Close()
            }
            catch {
                $raw = $_.Exception.Message
            }
        }
        else {
            $raw = $_.Exception.Message
        }

        $body = $null
        if ($raw) {
            try { $body = $raw | ConvertFrom-Json } catch { $body = $raw }
        }

        return [pscustomobject]@{
            StatusCode = $status
            Body       = $body
            Raw        = $raw
            Error      = $_.Exception.Message
        }
    }
}

function ConvertTo-PNAIntentColumns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$InputObject
    )

    if ($InputObject -is [string]) {
        return @($InputObject -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    return @($InputObject | ForEach-Object { "$($_)".Trim() } | Where-Object { $_ })
}

Export-ModuleMember -Function @(
    'Get-PNAConfig',
    'Get-PNASecretString',
    'Write-PNALog',
    'Get-PNAState',
    'Set-PNAState',
    'Acquire-PNARunLock',
    'Release-PNARunLock',
    'Invoke-PNAHttpRequest',
    'ConvertTo-PNAIntentColumns'
)
