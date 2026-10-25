#requires -Version 5.1
param([switch]$Once)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ChargeControl.ps1')
. (Join-Path $PSScriptRoot 'PanelStartup.ps1')
$path=Join-Path $PSScriptRoot 'agent\background-recovery.json'
$gate=[Threading.Mutex]::new($false,'Global\BatteryGuard-BackgroundRecovery')
$owned=$false
function Invoke-BackgroundRecovery {
    $state=[ordered]@{pid=$PID;time=(Get-Date -Format o);maintenance=(Test-ControlMaintenance);started=@();error='';panel_cache_error='';panel_startup_enabled=$false;panel_decision='not_checked'}
    if($state.maintenance -or (Test-Path (Join-Path $PSScriptRoot 'agent\performance-feedback.stop')) -or (Test-Path (Join-Path $PSScriptRoot 'agent\background-recovery.stop'))){Write-ControlJson $path $state;return}
    try{
        $state.panel_startup_enabled=[bool](Test-PanelStartup)
        $state.panel_decision='startup_disabled'
        if($state.panel_startup_enabled){
            $panel=$null
            try{if(Test-Path (Join-Path $PSScriptRoot 'agent\panel-runtime.json')){$panel=Read-ControlJson (Join-Path $PSScriptRoot 'agent\panel-runtime.json')}}catch{$state.panel_cache_error=$_.Exception.Message}
            $process=if($panel -and [int]$panel.pid-gt 0){Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$panel.pid) -ErrorAction SilentlyContinue}else{$null}
            $alive=$process -and $process.Name-eq 'powershell.exe' -and $process.SessionId-eq (Get-Process -Id $PID).SessionId -and $process.CommandLine-like ('*'+$PSScriptRoot+'\PerformanceControl.ps1*')
            $exited=$panel -and $panel.exit_requested -and $panel.exit_session-eq (Get-PanelSessionKey)
            $state.panel_decision=$(if($alive){'running'}elseif($exited){'explicit_exit'}else{'missing'})
            if(-not $alive -and -not $exited){
                $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                Start-Process -FilePath $exe -WindowStyle Hidden -WorkingDirectory $PSScriptRoot -ArgumentList ('-NoProfile -STA -WindowStyle Hidden -File "'+(Join-Path $PSScriptRoot 'PerformanceControl.ps1')+'" -StartHidden')|Out-Null
                $state.started+=@('panel')
                $state.panel_decision='started'
            }
        }
    }catch{$state.error=$_.Exception.Message}
    # The tray must be recoverable even while a hardware worker cannot start.
    try{
        Start-ChargeObserver
        Start-ChargeSupervisor
        Start-PowerEventGuard
        Start-PerformanceFeedback
        $live=Get-ControlObservation
        if($live -and $live.ec_power_valid-ne $false){Start-FanCurveWorker}
    }catch{$state.error=(@($state.error,$_.Exception.Message)|Where-Object {$_})-join '; '}
    Write-ControlJson $path $state
}
try{
    try{$owned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){exit 0}
    do{
        try{Invoke-BackgroundRecovery}catch{
            # A transient state-file failure must not terminate the only recovery loop.
            try{Write-ControlJson $path @{pid=$PID;time=(Get-Date -Format o);error=$_.Exception.Message}}catch{}
        }
        if($Once){break};Start-Sleep -Seconds 10
    }while(-not(Test-Path (Join-Path $PSScriptRoot 'agent\background-recovery.stop')))
}finally{if($owned){$gate.ReleaseMutex()};$gate.Dispose()}
