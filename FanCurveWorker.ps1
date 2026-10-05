#requires -Version 5.1
param([switch]$Watchdog,[switch]$Verify,[switch]$VerifyWatchdog,[int]$WatchPid=0,[string]$WatchStartedAt='')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root 'ChargeControl.ps1')
. (Join-Path $root 'FanCurvePolicy.ps1')
$runtimePath=Join-Path $root 'agent\fan-runtime.json'
$settingsPath=Join-Path $root 'agent\fan-settings.json'
$stopPath=Join-Path $root 'agent\fan-control.stop'
$state=[pscustomobject]@{pid=$PID;started_at=(Get-Date -Format o);updated_at='';owns_manual=$false;phase='starting';mode=-1;source_code=0;online=$false;temperature=0;right_duty=0;left_duty=0;right_duty_before_write=0;left_duty_before_write=0;manual_mode_before_write=0;right_rpm=$null;left_rpm=$null;rpm_valid=$false;requested_duty=$null;full_duty_requested=$false;full_duty_retained=$false;firmware_pulse_observations=0;writes=0;restored=$false;error=''}
$owned=$false
$gate=[Threading.Mutex]::new($false,$(if($Watchdog){'Global\BatteryGuard-FanWatchdog'}else{'Global\BatteryGuard-FanWorker'}))
function Save-FanRuntime {
    $state.updated_at=Get-Date -Format o
    Write-ControlJson $runtimePath $state
}
function Release-Fans {
    if($state.owns_manual){
        [BatteryGuard.T142Fan]::RestoreAutomatic()
        $state.owns_manual=$false;$state.restored=$true
        Save-FanRuntime
    }
}
function Update-FanSnapshot($snapshot) {
    $state.mode=$snapshot.Mode;$state.source_code=$snapshot.SourceCode;$state.online=$snapshot.Online
    $state.temperature=$snapshot.Temperature;$state.right_duty=$snapshot.RightDuty;$state.left_duty=$snapshot.LeftDuty
    $state.right_duty_before_write=$snapshot.RightDuty;$state.left_duty_before_write=$snapshot.LeftDuty;$state.manual_mode_before_write=$snapshot.ManualMode
    $state.rpm_valid=$snapshot.RpmValid
    $state.right_rpm=$(if($snapshot.RpmValid){$snapshot.RightRpm}else{$null})
    $state.left_rpm=$(if($snapshot.RpmValid){$snapshot.LeftRpm}else{$null})
}
try {
    try{$owned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){exit 0}
    if((Get-CimInstance Win32_BaseBoard).Product-ne 'WUJIE Series-T142-STX'){throw 'Unexpected motherboard'}
    Add-Type -Path (Join-Path $root 'driver\T142Fan.cs')
    if([BatteryGuard.T142Fan]::LoadLibrary((Join-Path $root 'driver\x64\inpoutx64.dll'))-eq [IntPtr]::Zero){throw 'Cannot load fan interface'}
    [BatteryGuard.T142Fan]::Validate()
    if($Watchdog){
        $watchdogPath=Join-Path $root 'agent\fan-watchdog-runtime.json'
        while($true){
            $claim=$null
            try{$claim=Read-ControlJson $runtimePath}catch{}
            if($claim -and [int]$claim.pid-eq $WatchPid -and [string]$claim.started_at-eq $WatchStartedAt){
                $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$WatchPid) -ErrorAction SilentlyContinue
                $matches=$process -and $process.Name-eq 'powershell.exe' -and $process.CommandLine-like ('*'+$root+'\FanCurveWorker.ps1*') -and
                    [math]::Abs((([datetime]$process.CreationDate)-[datetime]$WatchStartedAt).TotalSeconds)-lt 10
                $age=((Get-Date)-[datetime]$claim.updated_at).TotalSeconds
                if($claim.owns_manual -and (-not $matches -or $age-gt 8)){
                    if($matches){Stop-Process -Id $WatchPid -Force}
                    [BatteryGuard.T142Fan]::RestoreAutomatic()
                    $intentionalStop=Test-Path -LiteralPath $stopPath
                    $claim.owns_manual=$false;$claim.restored=$true
                    $claim.phase=$(if($intentionalStop){'stopped'}else{'watchdog_restored'})
                    $claim.error=$(if($intentionalStop){''}else{'Fan worker lost its heartbeat; automatic fan control restored'})
                    $claim.updated_at=Get-Date -Format o
                    Write-ControlJson $runtimePath $claim
                    Write-ControlJson $watchdogPath @{pid=$PID;worker_pid=$WatchPid;updated_at=(Get-Date -Format o);restored=$true;error=''}
                    break
                }
                Write-ControlJson $watchdogPath @{pid=$PID;worker_pid=$WatchPid;updated_at=(Get-Date -Format o);restored=$false;error=''}
                if(-not $matches){break}
            }elseif($claim){break}
            Start-Sleep -Seconds 1
        }
        return
    }
    $snapshot=[BatteryGuard.T142Fan]::ReadSnapshot()
    if($snapshot.ManualMode-ne 0){throw 'An existing manual fan controller is active; leaving it in control'}
    Update-FanSnapshot $snapshot;Save-FanRuntime
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $watchArgs='-NoProfile -File "'+$PSCommandPath+'" -Watchdog -WatchPid '+$PID+' -WatchStartedAt "'+$state.started_at+'"'
    $watchProcess=Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList $watchArgs -PassThru
    $watchDeadline=(Get-Date).AddSeconds(6)
    $watchReady=$false
    do{
        Start-Sleep -Milliseconds 100
        try{$watchState=Read-ControlJson (Join-Path $root 'agent\fan-watchdog-runtime.json');$watchReady=[int]$watchState.worker_pid-eq $PID -and [int]$watchState.pid-eq $watchProcess.Id}catch{}
    }while(-not $watchReady -and (Get-Date)-lt $watchDeadline)
    if(-not $watchReady){throw 'Fan recovery watchdog did not start'}
    if($Verify -or $VerifyWatchdog){
        $baseline=$snapshot
        if($baseline.Temperature-ge 75){throw 'Fan verification requires temperature below 75 C'}
        $state.owns_manual=$true;$state.phase='verification';Save-FanRuntime
        [BatteryGuard.T142Fan]::ApplyManualDuty(55,55,$true)
        $sampleRows=@()
        $watch=[Diagnostics.Stopwatch]::StartNew()
        while($watch.Elapsed.TotalSeconds-lt $(if($VerifyWatchdog){20}else{8})){
            $snapshot=[BatteryGuard.T142Fan]::ReadSnapshot()
            if($snapshot.Temperature-ge 85){throw 'Temperature exceeded verification bound'}
            [BatteryGuard.T142Fan]::ApplyManualDuty(55,55,$false)
            $state.writes++;Update-FanSnapshot $snapshot;Save-FanRuntime
            $sampleRows+=@(@{time=(Get-Date -Format o);manual=$snapshot.ManualMode;right_duty=$snapshot.RightDuty;left_duty=$snapshot.LeftDuty;temperature=$snapshot.Temperature;rpm_valid=$snapshot.RpmValid})
            Start-Sleep -Milliseconds 100
        }
        Release-Fans
        $snapshot=[BatteryGuard.T142Fan]::ReadSnapshot()
        $report=@{time=(Get-Date -Format o);success=($snapshot.ManualMode-eq 0);baseline=$baseline;samples=$sampleRows;after=$snapshot;automatic_restored=$true;charge_register_writes='none'}
        Write-ControlJson (Join-Path $root 'agent\fan-verification.json') $report
        $state.phase='verification_completed';Update-FanSnapshot $snapshot;Save-FanRuntime
        return
    }
    $yieldUntil=[datetime]::MinValue;$lastSettings=[datetime]::MinValue;$settings=$null
    $lastSave=[datetime]::MinValue;$lastDuty=0;$lastDown=[datetime]::MinValue
    while(-not(Test-Path -LiteralPath $stopPath)){
        if(((Get-Date)-$lastSettings).TotalSeconds-ge 2){$settings=Read-ControlJson $settingsPath;Assert-FanCurve $settings;$lastSettings=Get-Date}
        $snapshot=[BatteryGuard.T142Fan]::ReadSnapshot();Update-FanSnapshot $snapshot
        if($snapshot.CpuTemperatureA-lt 10 -or $snapshot.CpuTemperatureC-lt 10 -or $snapshot.Temperature-gt 120){throw 'Invalid thermal sensor reading'}
        if($state.owns_manual -and $snapshot.ManualMode-ne 1){
            $state.firmware_pulse_observations++
            $state.owns_manual=$false;$yieldUntil=(Get-Date).AddSeconds(15)
        }
        $decision=Get-FanControlDecision $settings $snapshot $yieldUntil
        if($decision-eq 'curve'){
            $duty=Get-FanCurveDuty $settings $snapshot.Temperature
            if($state.owns_manual -and $duty-lt $lastDuty){
                if(((Get-Date)-$lastDown).TotalSeconds-lt 2){$duty=$lastDuty}else{$duty=[math]::Max($duty,$lastDuty-3);$lastDown=Get-Date}
            }else{$lastDown=Get-Date}
            $acquire=-not $state.owns_manual
            if($acquire){$state.owns_manual=$true;$state.restored=$false;$state.phase='acquiring';Save-FanRuntime}
            $state.full_duty_requested=$duty-eq 100
            $retained=[BatteryGuard.T142Fan]::MaintainManualDuty($duty,$duty,$acquire,$state.full_duty_requested)
            $state.full_duty_retained=$state.full_duty_requested -and $retained
            if($state.full_duty_retained){
                $state.right_duty=100;$state.left_duty=100
                $state.rpm_valid=$false;$state.right_rpm=$null;$state.left_rpm=$null
            }
            if(-not $retained -and -not $state.full_duty_requested){
                $state.owns_manual=$false;$yieldUntil=(Get-Date).AddSeconds(15);$decision='firmware_yield'
            }
            $state.writes++;$state.requested_duty=$duty;$lastDuty=$duty
        }else{Release-Fans;$state.requested_duty=$null;$state.full_duty_requested=$false;$state.full_duty_retained=$false}
        $state.phase=$decision;$state.error=''
        if(((Get-Date)-$lastSave).TotalSeconds-ge 1){Save-FanRuntime;$lastSave=Get-Date}
        Start-Sleep -Milliseconds $(if($state.full_duty_requested){50}elseif($state.owns_manual){100}else{1000})
    }
    $state.phase='stopped'
}catch{
    $state.phase='error';$state.error=$_.Exception.ToString()
    if(-not $Watchdog){Save-FanRuntime}
}finally{
    if(-not $Watchdog){try{Release-Fans}catch{$state.error+='; restore: '+$_.Exception.Message};if($owned){Save-FanRuntime}}
    if($owned){$gate.ReleaseMutex()};$gate.Dispose()
}
