[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\Config\pna.config.json'),
    [Parameter()]
    [switch]$WhatIf,
    [Parameter()]
    [ValidateSet('Workflow', 'AuthOnly', 'TafRun', 'TafResult')]
    [string]$Mode = 'Workflow',
    [Parameter()]
    [string]$TaskId
)

Set-StrictMode -Version Late
$ErrorActionPreference = 'Stop'

$moduleRoot = Resolve-Path (Join-Path $PSScriptRoot '..\Modules')
Import-Module (Join-Path $moduleRoot 'PNA.Core.psm1') -Force
Import-Module (Join-Path $moduleRoot 'PNA.NetBrain.psm1') -Force 
Import-Module (Join-Path $moduleRoot 'PNA.ServiceNow.psm1') -Force 
Import-Module (Join-Path $moduleRoot 'PNA.Workflow.psm1') -Force

$config = Get-PNAConfig -Path $ConfigPath
$statePath = $config.Workflow.StatePath
$logPath = $config.Workflow.LogPath

Write-PNALog -Message ('PNA starting in mode {0}.' -f $Mode) -LogPath $logPath

try {
    switch ($Mode) {
        'AuthOnly' {
            $nbSession = Connect-PNANetBrainSession -Config $config
            [pscustomobject]@{
                Mode        = 'AuthOnly'
                Token       = $nbSession.Token
                TokenLength = if ($nbSession.Token) { $nbSession.Token.Length } else { 0 }
            }
            exit 0
        }

        'TafRun' {
            $nbSession = Connect-PNANetBrainSession -Config $config
            $run = Start-PNATafLiteRun -Config $config -Token $nbSession.Token
            $taskId = $null
            if ($run.Body) { $taskId = $run.Body.taskId }
            if (-not $taskId) { throw "TAF Lite run failed: $($run.Raw)" }

            [pscustomobject]@{
                Mode   = 'TafRun'
                TaskId = $taskId
                Raw    = $run.Raw
            }
            exit 0
        }

        'TafResult' {
            if (-not $TaskId) {
                throw 'TaskId is required when Mode is TafResult.'
            }

            $nbSession = Connect-PNANetBrainSession -Config $config
            $complete = Wait-PNATafLiteCompletion -Config $config -Token $nbSession.Token -TaskId $TaskId -LogPath $logPath

            [pscustomobject]@{
                Mode         = 'TafResult'
                TaskId       = $TaskId
                Status = if ($complete -and $complete.PSObject.Properties.Name -contains 'status') {
                    $complete.status
                }
                elseif ($complete -and $complete.PSObject.Properties.Name -contains 'Status') {
                    $complete.Status
                }
                else {
                    $null
                }

#                Status       = $complete.status
                IntentCount  = @($complete.intents).Count
                ResultObject = $complete
            }
            exit 0
        }

        default {
            $lock = Acquire-PNARunLock -StatePath $statePath -Minutes ([int]$config.Workflow.RunLockMinutes)
            if (-not $lock.Acquired) {
                Write-PNALog -Message 'Run lock already held; skipping.' -Level 'WARN' -LogPath $logPath
                exit 0
            }

            try {
                if (-not (Get-Command Invoke-PNAWorkflow -ErrorAction SilentlyContinue)) {
                    throw 'Invoke-PNAWorkflow is not available yet. Build PNA.Workflow.psm1 next.'
                }

                $result = Invoke-PNAWorkflow -Config $config -WhatIf:$WhatIf
                Write-PNALog -Message ("PNA finished: {0}" -f (($result | ConvertTo-Json -Depth 8 -Compress))) -LogPath $logPath
                exit 0
            }
            finally {
                Release-PNARunLock -StatePath $statePath | Out-Null
            }
        }
    }
}
catch {
    Write-PNALog -Message $_.Exception.Message -Level 'ERROR' -LogPath $logPath
    throw
}
