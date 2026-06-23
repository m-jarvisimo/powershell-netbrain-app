Set-StrictMode -Version Latest

function Invoke-PNAWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter()]
        [switch]$WhatIf
    )

    $logPath = $Config.Workflow.LogPath
    $statePath = $Config.Workflow.StatePath
    $summary = [ordered]@{
        TaskId          = ''
        TotalIntents    = 0
        LargeResults    = 0
        NoMismatch      = 0
        Candidates      = 0
        Groups          = 0
        NetBrainChanges = 0
        SNTasks         = 0
        SNChanges       = 0
        Duplicates      = 0
        ParserIssues    = 0
        Skipped         = $false
    }

    Write-PNALog -Message 'PNA workflow starting.' -LogPath $logPath
    Set-PNAState -Path $statePath -State ([pscustomobject]@{
        LastRunUtc = [DateTime]::UtcNow.ToString('o')
        Status     = 'running'
    }) | Out-Null

    $nbSession = Connect-PNANetBrainSession -Config $Config
    [void](Set-PNANetBrainCurrentDomain -Config $Config -Token $nbSession.Token)

    $run = Start-PNATafLiteRun -Config $Config -Token $nbSession.Token
    $taskId = $null
    if ($run.Body) { $taskId = $run.Body.taskId }
    if (-not $taskId) { throw "TAF Lite run failed: $($run.Raw)" }
    $summary.TaskId = $taskId

    $complete = Wait-PNATafLiteCompletion -Config $Config -Token $nbSession.Token -TaskId $taskId -LogPath $logPath
    $intents = @($complete.intents)
    $summary.TotalIntents = $intents.Count

    $failures = New-Object System.Collections.Generic.List[object]
    foreach ($intent in $intents) {
        if (-not $intent.resultId) { continue }

        $datas = Get-PNATafLiteResultDatas -Config $Config -Token $nbSession.Token -ResultId $intent.resultId -Output @(1)
        if ($datas.Body -and $datas.Body.downloadTicketId) {
            $summary.LargeResults++
            Write-PNALog -Message ('NetBrain result too large to inspect: {0}' -f $intent.name) -Level 'WARN' -LogPath $logPath
            continue
        }

        $trigger = Get-PNATriggerReason -Intent $intent -Datas $datas.Body -Config $Config
        if (-not $trigger.ShouldCreate) {
            $summary.NoMismatch++
            continue
        }

        $failure = ConvertTo-PNAFailureRecord -Intent $intent -TaskId $taskId -Trigger $trigger -Config $Config
        if (-not $failure.Device -or $failure.Device -eq 'UNKNOWN_DEVICE') {
            $summary.ParserIssues++
            Write-PNALog -Message ('NetBrain failure could not be mapped to a device: {0}' -f $failure.IntentName) -Level 'WARN' -LogPath $logPath
            continue
        }

        $summary.Candidates++
        [void]$failures.Add($failure)
    }

    $groups = Group-PNAFailuresByRemediation -Failures $failures
    $summary.Groups = $groups.Count

    $snSession = Connect-PNAServiceNowSession -Config $Config
    foreach ($group in $groups) {
        $dedupeKey = Build-PNAServiceNowDedupeKey -Group $group -Config $Config

        $shouldCreate = Should-Create-PNAServiceNowRecord -Session $snSession -Table $Config.ServiceNow.ChangeTable -DedupeKey $dedupeKey
        if (-not $shouldCreate.ShouldCreate) {
            $summary.Duplicates++
            Write-PNALog -Message ('Skipping duplicate ServiceNow record for key {0}' -f $dedupeKey) -Level 'WARN' -LogPath $logPath
            continue
        }

        $netbrainPayload = New-PNANetworkChangePayload -Group $group
        $netbrainChange = $null
        if ($WhatIf) {
            Write-PNALog -Message ('WHATIF: would create NetBrain change for {0}' -f $group.DedupeKey) -LogPath $logPath
            $netbrainChange = [pscustomobject]@{
                runbookId  = 'WHATIF-RUNBOOK'
                runbookUrl  = 'WHATIF-URL'
            }
        }
        else {
            $nbResponse = New-PNANetworkChange -Config $Config -Token $nbSession.Token -Payload $netbrainPayload
            $netbrainChange = if ($nbResponse.Body) { $nbResponse.Body } else { $nbResponse }
        }

        if (-not $netbrainChange -or -not $netbrainChange.runbookId) {
            Write-PNALog -Message ('NetBrain CM creation failed for group {0}' -f $group.DedupeKey) -Level 'ERROR' -LogPath $logPath
            continue
        }

        $summary.NetBrainChanges++

        $taskPayload = New-PNAServiceNowTaskPayload -Group $group -NetBrainChange $netbrainChange
        $changePayload = New-PNAServiceNowChangePayload -Group $group -NetBrainChange $netbrainChange -DedupeKey $dedupeKey -ChangeType $Config.ServiceNow.ChangeType

        if ($WhatIf) {
            Write-PNALog -Message ('WHATIF: would create ServiceNow task/change for {0}' -f $group.DedupeKey) -LogPath $logPath
            $summary.SNTasks++
            $summary.SNChanges++
            continue
        }

        $taskResponse = New-PNAServiceNowTask -Session $snSession -Table $Config.ServiceNow.ScTaskTable -Payload $taskPayload
        $taskResult = if ($taskResponse.Body) { $taskResponse.Body.result } else { $null }
        if (-not $taskResult) {
            Write-PNALog -Message ('ServiceNow task create failed for {0}' -f $group.DedupeKey) -Level 'ERROR' -LogPath $logPath
            continue
        }
        $summary.SNTasks++

        $changeResponse = New-PNAServiceNowChange -Session $snSession -Table $Config.ServiceNow.ChangeTable -Payload $changePayload
        $changeResult = if ($changeResponse.Body) { $changeResponse.Body.result } else { $null }
        if (-not $changeResult) {
            Write-PNALog -Message ('ServiceNow change create failed for {0}' -f $group.DedupeKey) -Level 'ERROR' -LogPath $logPath
            continue
        }
        $summary.SNChanges++

        $snChangeUrl = Get-PNAServiceNowRecordUrl -Session $snSession -Table $Config.ServiceNow.ChangeTable -SysId $changeResult.sys_id
        [void](Add-PNAServiceNowWorkNote -Session $snSession -Table $Config.ServiceNow.ScTaskTable -SysId $taskResult.sys_id -WorkNote ("Created ServiceNow change {0}. NetBrain URL: {1}" -f $changeResult.number, $netbrainChange.runbookUrl))
        [void](Add-PNAServiceNowWorkNote -Session $snSession -Table $Config.ServiceNow.ChangeTable -SysId $changeResult.sys_id -WorkNote ("NetBrain change URL: {0}`nServiceNow change URL: {1}" -f $netbrainChange.runbookUrl, $snChangeUrl))

        # Optional NetBrain binding back to the ServiceNow change record.
        [void](Bind-PNANetworkChangeToServiceNow -Config $Config -Token $nbSession.Token -RunbookId $netbrainChange.runbookId -TicketId $changeResult.number -TicketName $changeResult.number -TicketUrl $snChangeUrl)

        Write-PNALog -Message ('Created SN task {0} and change {1} for group {2}' -f $taskResult.number, $changeResult.number, $group.DedupeKey) -LogPath $logPath

        $state = Get-PNAState -Path $statePath
        $createdTasks = @()
        $createdChanges = @()
        if ($state.PSObject.Properties.Name -contains 'CreatedTasks' -and $state.CreatedTasks) { $createdTasks = @($state.CreatedTasks) }
        if ($state.PSObject.Properties.Name -contains 'CreatedChanges' -and $state.CreatedChanges) { $createdChanges = @($state.CreatedChanges) }
        $createdTasks += $taskResult.number
        $createdChanges += $changeResult.number
        $state | Add-Member -NotePropertyName CreatedTasks -NotePropertyValue $createdTasks -Force
        $state | Add-Member -NotePropertyName CreatedChanges -NotePropertyValue $createdChanges -Force
        $state | Add-Member -NotePropertyName LastTaskId -NotePropertyValue $taskId -Force
        $state | Add-Member -NotePropertyName Status -NotePropertyValue 'running' -Force
        Set-PNAState -Path $statePath -State $state | Out-Null
    }

    $summary.Status = 'success'
    Set-PNAState -Path $statePath -State ([pscustomobject]@{
        LastRunUtc = [DateTime]::UtcNow.ToString('o')
        Status     = 'success'
        Summary    = $summary
        TaskId     = $taskId
    }) | Out-Null

    Write-PNALog -Message ("PNA workflow finished: {0}" -f (($summary | ConvertTo-Json -Depth 8 -Compress))) -LogPath $logPath
    return [pscustomobject]$summary
}

function Invoke-PNANetBrainPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    throw 'Invoke-PNANetBrainPhase is not yet separated from Invoke-PNAWorkflow. Use Invoke-PNAWorkflow for now.'
}

function Invoke-PNAServiceNowPhase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config
    )

    throw 'Invoke-PNAServiceNowPhase is not yet separated from Invoke-PNAWorkflow. Use Invoke-PNAWorkflow for now.'
}

function Build-PNAWorkflowSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Result
    )

    return $Result
}

function Write-PNAWorkflowState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Config,
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    Set-PNAState -Path $Config.Workflow.StatePath -State $State | Out-Null
    return $State
}

function Get-PNARunOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Summary
    )

    return $Summary.Status
}

Export-ModuleMember -Function @(
    'Invoke-PNAWorkflow',
    'Invoke-PNANetBrainPhase',
    'Invoke-PNAServiceNowPhase',
    'Build-PNAWorkflowSummary',
    'Write-PNAWorkflowState',
    'Get-PNARunOutcome'
)
