Set-StrictMode -Version Latest

function Connect-PNAServiceNowSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $password = Get-PNASecretString -Path $Config.ServiceNow.PasswordSecretPath
    $pair = '{0}:{1}' -f $Config.ServiceNow.Username, $password
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
    $auth = [Convert]::ToBase64String($bytes)

    [pscustomobject]@{
        BaseUrl = $Config.ServiceNow.BaseUrl
        Headers = @{
            Authorization = "Basic $auth"
            Accept        = 'application/json'
        }
        Username = $Config.ServiceNow.Username
    }
}

function Get-PNAServiceNowRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [string]$SysId
    )

    return Invoke-PNAHttpRequest -BaseUrl $Session.BaseUrl -Method 'Get' -Path ("/api/now/table/{0}/{1}" -f $Table, $SysId) -Headers $Session.Headers
}

function Search-PNAServiceNowOpenRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [string]$EncodedQuery,
        [Parameter()]
        [string[]]$Fields = @('sys_id', 'number', 'state', 'short_description'),
        [Parameter()]
        [int]$Limit = 5
    )

    $query = [uri]::EscapeDataString($EncodedQuery)
    $fields = [uri]::EscapeDataString(($Fields -join ','))
    $path = '/api/now/table/{0}?sysparm_query={1}&sysparm_fields={2}&sysparm_limit={3}' -f $Table, $query, $fields, $Limit
    return Invoke-PNAHttpRequest -BaseUrl $Session.BaseUrl -Method 'Get' -Path $path -Headers $Session.Headers
}

function New-PNAServiceNowTaskPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Group,
        [Parameter(Mandatory)]
        [pscustomobject]$NetBrainChange
    )

    $lines = @(
        'PNA detected a failed NetBrain intent and created a remediation change.',
        '',
        'Intent: {0}' -f $Group.IntentName,
        'Remediation: {0}' -f $Group.RemediationLabel,
        'TAF Task ID: {0}' -f $Group.TaskId,
        'NetBrain Change ID: {0}' -f $NetBrainChange.runbookId,
        'NetBrain Change URL: {0}' -f $NetBrainChange.runbookUrl,
        '',
        'Devices and evidence:'
    )

    foreach ($failure in @($Group.Failures)) {
        $lines += ('- {0}: {1} [resultId {2}]' -f $failure.Device, $failure.Message, $failure.ResultId)
    }

    return [pscustomobject]@{
        short_description = 'PNA NetBrain intent failure: {0}' -f $Group.IntentName
        description       = ($lines -join [Environment]::NewLine)
    }
}

function New-PNAServiceNowChangePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Group,
        [Parameter(Mandatory)]
        [pscustomobject]$NetBrainChange,
        [Parameter(Mandatory)]
        [string]$DedupeKey,
        [Parameter()]
        [string]$ChangeType = 'normal'
    )

    $devices = @($Group.Devices) -join [Environment]::NewLine
    $lines = @(
        'PNA created this change after NetBrain detected a failed intent.',
        '',
        'Intent: {0}' -f $Group.IntentName,
        'Remediation: {0}' -f $Group.RemediationLabel,
        'TAF Task ID: {0}' -f $Group.TaskId,
        'Dedupe Key: {0}' -f $DedupeKey,
        'NetBrain Change ID: {0}' -f $NetBrainChange.runbookId,
        'NetBrain Change URL: {0}' -f $NetBrainChange.runbookUrl,
        '',
        'Devices:',
        $devices,
        '',
        'Evidence:'
    )

    foreach ($failure in @($Group.Failures)) {
        $lines += ('- {0}: {1} [resultId {2}]' -f $failure.Device, $failure.Message, $failure.ResultId)
    }

    return [pscustomobject]@{
        short_description   = 'PNA remediation: {0} - {1}' -f $Group.IntentName, $Group.RemediationLabel
        description         = ($lines -join [Environment]::NewLine)
        type                = $ChangeType
        u_netbrain_dedupe_key = $DedupeKey
        u_netbrain_device   = $devices
        u_netbrain_change_url = $NetBrainChange.runbookUrl
        u_netbrain_runbook_id  = $NetBrainChange.runbookId
    }
}

function New-PNAServiceNowTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [pscustomobject]$Payload
    )

    return Invoke-PNAHttpRequest -BaseUrl $Session.BaseUrl -Method 'Post' -Path ("/api/now/table/{0}" -f $Table) -Headers $Session.Headers -Body $Payload
}

function New-PNAServiceNowChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [pscustomobject]$Payload
    )

    return Invoke-PNAHttpRequest -BaseUrl $Session.BaseUrl -Method 'Post' -Path ("/api/now/table/{0}" -f $Table) -Headers $Session.Headers -Body $Payload
}

function Add-PNAServiceNowWorkNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [string]$SysId,
        [Parameter(Mandatory)]
        [string]$WorkNote
    )

    return Invoke-PNAHttpRequest -BaseUrl $Session.BaseUrl -Method 'Patch' -Path ("/api/now/table/{0}/{1}" -f $Table, $SysId) -Headers $Session.Headers -Body @{
        work_notes = $WorkNote
    }
}

function Update-PNAServiceNowRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [string]$SysId,
        [Parameter(Mandatory)]
        [pscustomobject]$Payload
    )

    return Invoke-PNAHttpRequest -BaseUrl $Session.BaseUrl -Method 'Patch' -Path ("/api/now/table/{0}/{1}" -f $Table, $SysId) -Headers $Session.Headers -Body $Payload
}

function Get-PNAServiceNowRecordUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [string]$SysId
    )

    $base = $Session.BaseUrl.TrimEnd('/') + '/'
    return ('{0}nav_to.do?uri={1}.do?sys_id={2}' -f $base, $Table, $SysId)
}

function Build-PNAServiceNowDedupeKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Group,
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    $devicePart = (@($Group.Devices) -join ',')
    $raw = '{0}|{1}|{2}|{3}|{4}' -f $Config.NetBrain.TafEndpoint, $Group.IntentName, $Group.RemediationLabel, $devicePart, ([DateTime]::UtcNow.ToString('yyyyMMdd'))
    return ($raw.ToLowerInvariant() -replace '\s+', '_' -replace '[^a-z0-9_\|,\-]+', '')
}

function Should-Create-PNAServiceNowRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Session,
        [Parameter(Mandatory)]
        [string]$Table,
        [Parameter(Mandatory)]
        [string]$DedupeKey
    )

    $query = 'u_netbrain_dedupe_key={0}^active=true' -f $DedupeKey
    $result = Search-PNAServiceNowOpenRecords -Session $Session -Table $Table -EncodedQuery $query -Fields @('sys_id', 'number', 'state', 'short_description', 'u_netbrain_dedupe_key') -Limit 1
    $rows = @()
    if ($result.Body -and $result.Body.result) { $rows = @($result.Body.result) }
    return [pscustomobject]@{
        ShouldCreate = ($rows.Count -eq 0)
        Existing     = $rows
    }
}

Export-ModuleMember -Function @(
    'Connect-PNAServiceNowSession',
    'Get-PNAServiceNowRecord',
    'Search-PNAServiceNowOpenRecords',
    'New-PNAServiceNowTaskPayload',
    'New-PNAServiceNowChangePayload',
    'New-PNAServiceNowTask',
    'New-PNAServiceNowChange',
    'Add-PNAServiceNowWorkNote',
    'Update-PNAServiceNowRecord',
    'Get-PNAServiceNowRecordUrl',
    'Build-PNAServiceNowDedupeKey',
    'Should-Create-PNAServiceNowRecord'
)
