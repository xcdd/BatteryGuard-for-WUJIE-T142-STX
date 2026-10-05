#requires -Version 5.1
param([switch]$SelfTest)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root 'ChargeControl.ps1')
$statePath=Join-Path $root 'agent\power-event-guard.json'
$stopPath=Join-Path $root 'agent\power-event-guard.stop'
$subscriptionId='BatteryGuard-PowerEvents-'+$PID
$gate=$null
$owned=$false

function ConvertTo-PowerEventStateMap($state){
    $copy=[ordered]@{}
    if($state -is [Collections.IDictionary]){foreach($key in $state.Keys){$copy[$key]=$state[$key]}}
    elseif($state){foreach($property in $state.PSObject.Properties){$copy[$property.Name]=$property.Value}}
    return $copy
}

function Update-PowerEventHeartbeat($state,[string]$timestamp=(Get-Date -Format o),[int]$ownerPid=$PID){
    $state=ConvertTo-PowerEventStateMap $state
    if(-not $state -or [int]$state.pid-ne $ownerPid){return $null}
    $state.time=$timestamp
    $state.heartbeat_at=$timestamp
    return $state
}

function Get-PowerEventAction {
    param([int]$eventType,$settings=$null,[int]$soc=-1,[bool]$pausedByUs=$false)
    if($eventType-in @(4,7)){return 'pause_and_verify'}
    if($eventType-eq 10 -and $settings){
        $explicitPause=[bool]$settings.pause
        $thresholdHold=$settings.enabled -and [int]$settings.limit-lt 100 -and $soc-ge 0 -and $soc-le 100 -and (
            $soc-ge [int]$settings.limit -or ($pausedByUs -and $soc-gt ([int]$settings.limit-[int]$settings.hysteresis)))
        if($explicitPause -or $thresholdHold){return 'pause_on_external'}
    }
    return 'observe_only'
}

function Test-PowerEventExternalSource([int]$flags,[int]$adapter,[int]$soc){
    return ($flags-band 0x03)-eq 0x03 -and ($flags-band 0x10)-eq 0 -and
        $adapter-in @(1,2,4) -and $soc-ge 0 -and $soc-le 100
}

function Update-PowerEventNotification($state,[int]$eventType,[string]$timestamp=(Get-Date -Format o),[int]$ownerPid=$PID){
    $state=ConvertTo-PowerEventStateMap $state
    if(-not $state -or [int]$state.pid-ne $ownerPid){return $null}
    if(-not $state.Contains('received_events')){$state.received_events=0}
    $state.received_events=[int]$state.received_events+1
    $state.last_received_event_type=$eventType
    $state.last_received_at=$timestamp
    return Update-PowerEventHeartbeat $state $timestamp $ownerPid
}

function Save-PowerEventState($state){
    if(-not $state.Contains('received_events')){
        $previous=if(Test-Path -LiteralPath $statePath){try{Read-ControlJson $statePath}catch{$null}}else{$null}
        if($previous){$state.received_events=[int]$previous.received_events;$state.last_received_event_type=$previous.last_received_event_type;$state.last_received_at=$previous.last_received_at}
        else{$state.received_events=0;$state.last_received_event_type=$null;$state.last_received_at=''}
    }
    $state=Update-PowerEventHeartbeat $state
    Write-ControlJson $statePath $state
}

function Invoke-PowerEventPause([int]$eventType,[switch]$VerifiedExternal,[int]$AdapterCode=0,[int]$SoC=-1){
    $name=switch($eventType){4{'suspend'}7{'resume'}default{'power'}}
    $entry=[ordered]@{event=$name;event_type=$eventType;time=(Get-Date -Format o);online=$null;source_confirmed=[bool]$VerifiedExternal;adapter=$AdapterCode;soc=$SoC;action=$(if($VerifiedExternal){'pause_on_external'}else{'pause_and_verify'});written=$false;verified_current=$null;error=''}
    try{
        $live=Get-ControlObservation
        if($VerifiedExternal){$entry.online=$true}
        elseif($live){$entry.online=[bool]$live.online;if(-not $live.online){$entry.error='offline; no charger transaction needed';Save-PowerEventState ([ordered]@{pid=$PID;last=$entry;events=0;error=''});return}}
        Initialize-ChargeHardware
        [BatteryGuard.T142Charger]::EmergencyPauseCharging()
        $entry.written=$true
        $entry.verified_current=[BatteryGuard.T142Charger]::ReadEmergencyChargeCurrent()
        if([int]$entry.verified_current -ne 0){throw 'power-event zero write did not read back zero'}
    }catch{$entry.error=$_.Exception.Message}
    $old=if(Test-Path -LiteralPath $statePath){try{Read-ControlJson $statePath}catch{$null}}else{$null}
    $count=if($old){[int]$old.events+1}else{1}
    Save-PowerEventState ([ordered]@{pid=$PID;last=$entry;events=$count;error=$entry.error})
}

if($SelfTest){return}
$gate=[Threading.Mutex]::new($false,'Global\BatteryGuard-PowerEventGuard')

try{
    try{$owned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){exit 0}
    Register-WmiEvent -Namespace root/cimv2 -Class Win32_PowerManagementEvent -SourceIdentifier $subscriptionId -ErrorAction Stop|Out-Null
    Save-PowerEventState ([ordered]@{pid=$PID;last=$null;events=0;received_events=0;last_received_event_type=$null;last_received_at='';error='';started_at=(Get-Date -Format o)})
    $lastHeartbeat=Get-Date
    while(-not(Test-Path -LiteralPath $stopPath)){
        foreach($event in @(Get-Event -SourceIdentifier $subscriptionId -ErrorAction SilentlyContinue)){
            try{
                $type=[int]$event.SourceEventArgs.NewEvent.EventType
                $state=Read-ControlJson $statePath
                $state=Update-PowerEventNotification $state $type
                if($state){Save-PowerEventState $state}
                $action=if($type-eq 10){
                    $settings=Get-ControlSettings
                    $runtime=Get-ControlRuntime
                    $live=Get-ControlObservation
                    $soc=-1
                    if($live -and ((Get-Date)-[datetime]$live.time).TotalSeconds-le 3){$soc=[int]$live.soc}
                    Get-PowerEventAction $type $settings $soc ([bool]$runtime.paused_by_us)
                }else{Get-PowerEventAction $type}
                if($action-eq 'pause_and_verify'){
                    Invoke-PowerEventPause $type
                }elseif($action-eq 'pause_on_external'){
                    Initialize-ChargeHardware
                    $ram=[BatteryGuard.T142Charger]::ReadEcRam(0x0460,0x1D)
                    $flags=[int]$ram[0];$adapter=[int]$ram[1];$soc=[int]$ram[0x1C]
                    $sourceConfirmed=Test-PowerEventExternalSource $flags $adapter $soc
                    $entry=[ordered]@{event='power_status_change';event_type=$type;time=(Get-Date -Format o);online=(($flags-band 1)-ne 0);adapter=$adapter;soc=$soc;source_confirmed=$sourceConfirmed;action='pause_on_external';written=$false;verified_current=$null;error=''}
                    if($sourceConfirmed){Invoke-PowerEventPause $type -VerifiedExternal -AdapterCode $adapter -SoC $soc}
                    else{$entry.error='EC did not confirm a valid external source; no charger transaction issued';Save-PowerEventState ([ordered]@{pid=$PID;last=$entry;events=0;error=''})}
                }
            }finally{Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue}
        }
        if(((Get-Date)-$lastHeartbeat).TotalSeconds-ge 5){
            try{$state=Read-ControlJson $statePath;$heartbeat=Update-PowerEventHeartbeat $state;if($heartbeat){Save-PowerEventState $heartbeat}}catch{}
            $lastHeartbeat=Get-Date
        }
        Start-Sleep -Milliseconds 250
    }
}catch{
    Save-PowerEventState ([ordered]@{pid=$PID;last=$null;events=0;error=$_.Exception.Message;started_at=(Get-Date -Format o)})
}finally{
    Unregister-Event -SourceIdentifier $subscriptionId -ErrorAction SilentlyContinue
    if($owned){$gate.ReleaseMutex()}
    $gate.Dispose()
}
