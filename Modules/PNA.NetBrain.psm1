Set-StrictMode -Version Latest

function Connect-PNANetBrainSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

#    $password = Get-PNASecretString -Path $Config.NetBrain.PasswordSecretPath
    $result = Invoke-PNAHttpRequest -BaseUrl $Config.NetBrain.BaseUrl -Method 'Post' -Path '/ServicesAPI/API/V1/Session' -Body @{
        username = $Config.NetBrain.Username
        password = $Config.NetBrain.TempPassword
    }

    $token = $null
    if ($result.Body) {
        $token = $result.Body.token
        if (-not $token) { $token = $result.Body.Token }
    }

    if (-not $token) {
        throw "NetBrain login failed: $($result.Raw)"
    }

    [pscustomobject]@{
        Token  = $token
        Result = $result
    }
}

function Set-PNANetBrainCurrentDomain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Token
    )

    if (-not $Config.NetBrain.TenantId -or -not $Config.NetBrain.DomainId) {
        return [pscustomobject]@{ Skipped = $true }
    }

    return Invoke-PNAHttpRequest -BaseUrl $Config.NetBrain.BaseUrl -Method 'Put' -Path '/ServicesAPI/API/V1/Session/CurrentDomain' -Headers @{
        token = $Token
    } -Body @{
        tenantId = $Config.NetBrain.TenantId
        domainId = $Config.NetBrain.DomainId
    }
}

function Start-PNATafLiteRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Token
    )

#    $intentColumns = ConvertTo-PNAIntentColumns -InputObject $Config.NetBrain.IntentColumns
    $maxCols = [int]$Config.NetBrain.MaxExecuteNiColumns

    return Invoke-PNAHttpRequest -BaseUrl $Config.NetBrain.BaseUrl -Method 'Post' -Path '/ServicesAPI/API/V3/TAF/Lite/run' -Headers @{
        token = $Token
    } -Body @{
        endpoint      = $Config.NetBrain.TafEndpoint
        passKey       = $Config.NetBrain.TafPasskey
#        passKey       = (Get-PNASecretString -Path $Config.NetBrain.TafPasskeySecretPath)
#        intentColumns = $intentColumns
#        option        = @{ rawData = $true; dataSource = 0}
        option        = @{ rawData = $true; dataSource = 0; maxExecuteNIColumn = $maxCols }
    }
}

function Get-PNATafLiteResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [string]$TaskId
    )

    return Invoke-PNAHttpRequest -BaseUrl $Config.NetBrain.BaseUrl -Method 'Post' -Path '/ServicesAPI/API/V3/TAF/Lite/result' -Headers @{
        token = $Token
    } -Body @{
        endpoint = $Config.NetBrain.TafEndpoint
        taskId   = $TaskId
    }
}

function Get-PNATafLiteResultDatas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [string]$ResultId,
        [Parameter()]
        [int[]]$Output = @(1)
    )

    return Invoke-PNAHttpRequest -BaseUrl $Config.NetBrain.BaseUrl -Method 'Post' -Path '/ServicesAPI/API/V3/TAF/Lite/result/datas' -Headers @{
        token = $Token
    } -Body @{
        endpoint   = $Config.NetBrain.TafEndpoint
        niResultId = $ResultId
        output     = $Output
    }
}

function Wait-PNATafLiteCompletion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [string]$TaskId,
        [Parameter()]
        [string]$LogPath
    )

    $attempts = [int]$Config.NetBrain.PollAttempts
    $seconds = [int]$Config.NetBrain.PollSeconds
    $need = [int]$Config.NetBrain.StablePolls
    $result = $null
    $lastSig = ''
    $stable = 0

    for ($i = 0; $i -lt $attempts; $i++) {
        $result = Get-PNATafLiteResult -Config $Config -Token $Token -TaskId $TaskId
        $body = $result.Body
#        $status = "$($body.status)" <-old version
        $status = if ($body -and $body.PSObject.Properties.Name -contains 'status') {
            [string]$body.status
        }
        elseif ($body -and $body.PSObject.Properties.Name -contains 'Status') {
            [string]$body.Status
        }
        else {
            ''
        }
        $intents = @($body.intents)
        $withId = @($intents | Where-Object {
            ($_.PSObject.Properties.Name -contains 'resultId' -and $_.resultId) -or
            ($_.PSObject.Properties.Name -contains 'resultID' -and $_.resultID) -or
            ($_.PSObject.Properties.Name -contains 'ResultId' -and $_.ResultId)
        }).Count
        $noId = $intents.Count - $withId
        $sig = '{0}|{1}' -f $intents.Count, $withId

        Write-PNALog -Message ("NetBrain poll {0}/{1}: status={2}, intents={3}, noResultId={4}, stable={5}/{6}" -f ($i + 1), $attempts, $status, $intents.Count, $noId, $stable, $need) -LogPath $LogPath

        if ($status -in @('3', '4')) {
            throw "TAF Lite task ended status=${status}: $($result.Raw)"
        }

        if ($status -eq '2' -and $noId -eq 0) {
            if ($sig -eq $lastSig) { $stable++ } else { $stable = 1 }
            $lastSig = $sig
            if ($stable -ge $need) {
                return $body
            }
        }
        else {
            $stable = 0
            $lastSig = $sig
        }

        Start-Sleep -Seconds $seconds
    }

    throw "TAF Lite result never completed in $($attempts * $seconds) seconds; aborting without partial records."
}

function Find-PNAMismatchEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        $Datas
    )

    if (-not $Datas -or -not $Datas.niResultDatas) {
        return ''
    }

    $pattern = if ($Config.NetBrain.AlertMessageRegex) {
        [regex]$Config.NetBrain.AlertMessageRegex
    }
    else {
        [regex]'not\s+match|mismatch|missing\s+lines|extra\s+lines|failed|failure|violation|non[- ]?compliant|out\s+of\s+(alignment|compliance)|drift'
    }

    foreach ($row in @($Datas.niResultDatas)) {
        $messages = @()
        if ($row.statusCodes) { $messages += @($row.statusCodes) }
        if ($row.deviceStatusCodes) { $messages += @($row.deviceStatusCodes) }

        foreach ($msg in $messages) {
            if ($pattern.IsMatch("$msg")) {
                return "$msg"
            }
        }
    }

    return ''
}

function Get-PNATriggerReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Intent,
        [Parameter(Mandatory)]
        $Datas,
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $alert = $false
    foreach ($candidate in @($Intent.hasAlert, $Intent.HasAlert)) {
        if ($candidate -eq $true -or $candidate -eq 1 -or $candidate -eq '1' -or $candidate -eq 'true') {
            $alert = $true
        }
    }

    $evidence = Find-PNAMismatchEvidence -Config $Config -Datas $Datas
    if ($alert) {
        return [pscustomobject]@{
            ShouldCreate = $true
            Message      = $(if ($evidence) { $evidence } else { $Intent.name })
        }
    }

    if ($evidence) {
        return [pscustomobject]@{
            ShouldCreate = $true
            Message      = $evidence
        }
    }

    return [pscustomobject]@{
        ShouldCreate = $false
        Message      = ''
    }
}

function Get-PNARemediationGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [Parameter()]
        [string]$IntentName
    )

    $m = if ($Message) { $Message.ToLowerInvariant() } else { '' }
    if ($m.Contains('aaa device policy')) { return [pscustomobject]@{ Key = 'aaa_device_policy'; Label = 'AAA device policy mismatch' } }
    if ($m.Contains('radius source-interface')) { return [pscustomobject]@{ Key = 'radius_source_interface'; Label = 'RADIUS source-interface mismatch' } }
    if ($m.Contains('aaa group cppm')) { return [pscustomobject]@{ Key = 'aaa_group_cppm'; Label = 'AAA group CPPM mismatch' } }
    if ($m.Contains('win2016radius')) { return [pscustomobject]@{ Key = 'aaa_group_win2016radius'; Label = 'AAA group win2016radius mismatch' } }
    if ($m.Contains('password policy')) { return [pscustomobject]@{ Key = 'password_policy'; Label = 'Password policy mismatch' } }

    $basis = if ($Message) { $Message } elseif ($IntentName) { $IntentName } else { 'general_mismatch' }
    $clean = ($basis.ToLowerInvariant() -replace '\([^)]*\)', '' -replace '[^a-z0-9]+', '_' -replace '^_+|_+$', '')
    if ($clean.Length -gt 80) { $clean = $clean.Substring(0, 80) }
    if (-not $clean) { $clean = 'general_mismatch' }

    return [pscustomobject]@{
        Key   = $clean
        Label = 'General remediation mismatch'
    }
}

function ConvertTo-PNAFailureRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Intent,
        [Parameter(Mandatory)]
        [string]$TaskId,
        [Parameter(Mandatory)]
        $Trigger,
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $parts = @($Intent.name -split '\s+') | Where-Object { $_ }
    $device = 'UNKNOWN_DEVICE'
    $name = if ($Intent.name) { ($Intent.name).Trim() } else { 'Unknown Intent' }

    if ($parts.Count -ge 3) {
        $parts = $parts[0..($parts.Count - 2)]
        $device = $parts[-1]
        $name = ($parts[0..($parts.Count - 2)] -join ' ').Trim()
    }

    $rem = Get-PNARemediationGroup -Message $Trigger.Message -IntentName $name
    [pscustomobject]@{
        TaskId           = $TaskId
        IntentName       = $name
        Device           = $device
        ResultId         = $Intent.resultId
        Message          = $Trigger.Message
        RemediationLabel = $rem.Label
        DedupeKey        = ('{0}|{1}|{2}' -f $Config.NetBrain.TafEndpoint, $name, $rem.Key)
    }
}

function Group-PNAFailuresByRemediation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Failures
    )

    $groups = @{}
    $ordered = New-Object System.Collections.Generic.List[object]

    foreach ($f in $Failures) {
        if (-not $groups.ContainsKey($f.DedupeKey)) {
            $groups[$f.DedupeKey] = [pscustomobject]@{
                DedupeKey        = $f.DedupeKey
                TaskId           = $f.TaskId
                IntentName       = $f.IntentName
                RemediationLabel = $f.RemediationLabel
                Devices          = New-Object System.Collections.Generic.List[string]
                Failures         = New-Object System.Collections.Generic.List[object]
            }
            [void]$ordered.Add($groups[$f.DedupeKey])
        }

        if ($f.Device -and -not $groups[$f.DedupeKey].Devices.Contains($f.Device)) {
            [void]$groups[$f.DedupeKey].Devices.Add($f.Device)
        }

        [void]$groups[$f.DedupeKey].Failures.Add($f)
    }

    return $ordered
}

function New-PNANetworkChangePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Group
    )

    $devices = @($Group.Devices)
    return [pscustomobject]@{
        name              = 'PNA remediation for {0}' -f $Group.IntentName
        runbookTemplate   = ''
        mapPath           = ''
        createIncident    = $false
        defineChangeNodes = @(
            [pscustomobject]@{
                nodeName          = ''
                configlet         = '! PNA placeholder for {0} ({1})' -f $Group.IntentName, ($devices -join ', ')
                configletTemplate = ''
                rollback          = ''
                rollbackTemplate  = ''
                devices           = $devices
            }
        )
        templateVars      = [pscustomobject]@{ singleVars = @(); tableVars = @() }
    }
}

function New-PNANetworkChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [pscustomobject]$Payload
    )

    return Invoke-PNAHttpRequest -BaseUrl $Config.NetBrain.BaseUrl -Method 'Post' -Path '/ServicesAPI/API/V3/CM' -Headers @{
        token = $Token
    } -Body $Payload
}

function Bind-PNANetworkChangeToServiceNow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [string]$Token,
        [Parameter(Mandatory)]
        [string]$RunbookId,
        [Parameter(Mandatory)]
        [string]$TicketId,
        [Parameter(Mandatory)]
        [string]$TicketName,
        [Parameter(Mandatory)]
        [string]$TicketUrl
    )

    return Invoke-PNAHttpRequest -BaseUrl $Config.NetBrain.BaseUrl -Method 'Post' -Path '/ServicesAPI/API/V1/CM/Binding' -Headers @{
        token = $Token
    } -Body @{
        runbookId  = $RunbookId
        ticketId   = $TicketId
        vendor     = 'serviceNow'
        ticketName = $TicketName
        ticketUrl  = $TicketUrl
    }
}

Export-ModuleMember -Function @(
    'Connect-PNANetBrainSession',
    'Set-PNANetBrainCurrentDomain',
    'Start-PNATafLiteRun',
    'Get-PNATafLiteResult',
    'Get-PNATafLiteResultDatas',
    'Wait-PNATafLiteCompletion',
    'Find-PNAMismatchEvidence',
    'Get-PNATriggerReason',
    'ConvertTo-PNAFailureRecord',
    'Get-PNARemediationGroup',
    'Group-PNAFailuresByRemediation',
    'New-PNANetworkChangePayload',
    'New-PNANetworkChange',
    'Bind-PNANetworkChangeToServiceNow'
)
