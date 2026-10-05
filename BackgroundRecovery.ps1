#requires -Version 5.1
param([switch]$Once)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ChargeControl.ps1')
. (Join-Path $PSScriptRoot 'PanelStartup.ps1')
$path=Join-Path $PSScriptRoot 'agent\background-recovery.json'
$gate=[Threading.Mutex]::new($false,'Global\BatteryGuard-BackgroundRecovery')
$owned=$false
function Invoke-BackgroundRecovery {
    $state=[ordered]@{pid=$PID;time=(Get-Date -Format o);maintenance=(Test-ControlMaintenance);started=@();error=''}
    if($state.maintenance -or (Test-Path (Join-Path $PSScriptRoot 'agent\performance-feedback.stop')) -or (Test-Path (Join-Path $PSScriptRoot 'agent\background-recovery.stop'))){Write-ControlJson $path $state;return}
    try{
        Start-ChargeObserver
        Start-ChargeSupervisor
        Start-PowerEventGuard
        Start-PerformanceFeedback
        $live=Get-ControlObservation
        if($live -and $live.ec_power_valid-ne $false){Start-FanCurveWorker}
        if(Test-PanelStartup){
            $panel=if(Test-Path (Join-Path $PSScriptRoot 'agent\panel-runtime.json')){Read-ControlJson (Join-Path $PSScriptRoot 'agent\panel-runtime.json')}else{$null}
            $process=if($panel){Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$panel.pid) -ErrorAction SilentlyContinue}else{$null}
            $alive=$process -and $process.Name-eq 'powershell.exe' -and $process.CommandLine-like ('*'+$PSScriptRoot+'\PerformanceControl.ps1*')
            $exited=$panel -and $panel.exit_requested -and $panel.exit_session-eq (Get-PanelSessionKey)
            if(-not $alive -and -not $exited){
                $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -File "'+(Join-Path $PSScriptRoot 'PerformanceControl.ps1')+'" -StartHidden')|Out-Null
                $state.started+=@('panel')
            }
        }
    }catch{$state.error=$_.Exception.Message}
    Write-ControlJson $path $state
}
try{
    try{$owned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){exit 0}
    do{Invoke-BackgroundRecovery;if($Once){break};Start-Sleep -Seconds 10}while(-not(Test-Path (Join-Path $PSScriptRoot 'agent\background-recovery.stop')))
}finally{if($owned){$gate.ReleaseMutex()};$gate.Dispose()}
