param([int]$DurationSeconds=0)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'PowerSourceState.ps1')
$runtimePath=Join-Path $PSScriptRoot 'control-live.json'
$logPath=Join-Path $PSScriptRoot 'control-live-events.jsonl'
$stopPath=Join-Path $PSScriptRoot 'control-observer.stop'
$gate=[Threading.Mutex]::new($false,'Global\BatteryGuard-ControlObserver')
$owned=$false
$started=Get-Date
$lastEventCheck=[datetime]::MinValue
$lastWindowsCheck=[datetime]::MinValue
$lastLog=[datetime]::MinValue
$lastStateKey=''
$lastSoc=-1
$sequence=0
$initialCritical=(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=524} -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
$windows=$null
$correlatedConnector=0
$lastSource=''
function Save-LiveState($state) {
    $json=$state|ConvertTo-Json -Depth 4 -Compress
    $temporary=$runtimePath+'.'+$PID+'.tmp'
    [IO.File]::WriteAllText($temporary,$json,[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $runtimePath){[IO.File]::Replace($temporary,$runtimePath,[NullString]::Value)}else{[IO.File]::Move($temporary,$runtimePath)}
    $key=$state.power_source+':'+$state.type_c_port+':'+$state.soc+':'+$state.performance_mode_code+':'+$state.fault
    if($key -ne $script:lastStateKey -or ((Get-Date)-$script:lastLog).TotalSeconds -ge 30){
        [IO.File]::AppendAllText($logPath,$json+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        $script:lastStateKey=$key;$script:lastLog=Get-Date
    }
}
try {
    try{$owned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){exit 0}
    if((Get-CimInstance Win32_BaseBoard).Product -ne 'WUJIE Series-T142-STX'){throw 'Unexpected motherboard'}
    Add-Type -Path (Join-Path $root 'driver\T142Charger.cs')
    Add-Type -Path (Join-Path $root 'driver\WindowsBatteryStatus.cs')
    if([BatteryGuard.T142Charger]::LoadLibrary((Join-Path $root 'driver\x64\inpoutx64.dll'))-eq[IntPtr]::Zero){throw 'Cannot load InpOut'}
    [BatteryGuard.T142Charger]::ValidateBatterySignature()
    while(($DurationSeconds -le 0 -or ((Get-Date)-$started).TotalSeconds -lt $DurationSeconds) -and -not (Test-Path -LiteralPath $stopPath)) {
        $sequence++
        $b=[BatteryGuard.T142Charger]::ReadEcRam(0x0460,0x94)
        $flags=[int]$b[0];$adapter=[int]$b[1]
        $ecOnline=($flags-band 1)-ne 0
        $magnitude=[BitConverter]::ToUInt16($b,12)
        $signed=if(($flags-band 8)-ne 0){-$magnitude}else{$magnitude}
        $windowsAcOnline=$false
        $windowsPresent=$false
        try{$windowsShell=[BatteryGuard.WindowsBatteryStatus]::ReadShellStatus();$windowsAcOnline=([int]$windowsShell.ACLineStatus -eq 1);$windowsPresent=($windowsShell.BatteryFlag-ne 128 -and $windowsShell.BatteryLifePercent-ne 255)}catch{}
        # ECWR bit 0 and PAWT are the preferred source because they identify
        # DC and the two Type-C ports. When the EC cache contains an invalid
        # source code, Windows ACLineStatus is only a fallback. A negative EC
        # current is authoritative evidence that the pack is discharging and
        # must override a stale Windows AC flag after the charger is removed.
        $resolved=Resolve-ControlPowerSource $flags $adapter $signed $windowsAcOnline $windowsPresent
        $online=$resolved.online
        $source=$resolved.source
        $sourceKey=$source+':'+$adapter
        if($sourceKey -ne $lastSource){$correlatedConnector=0;$lastSource=$sourceKey}
        $soc=[int]$b[28]
        $fault=''
        if(($flags-band 0x10)-ne 0){$fault='critical_battery'}
        if($lastSoc-ge 0 -and [math]::Abs($soc-$lastSoc)-gt 3){$fault='capacity_discontinuity'}
        if(((Get-Date)-$lastWindowsCheck).TotalSeconds-ge 5){
            $windows=Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus
            $lastWindowsCheck=Get-Date
        }
        if($windows.Critical){$fault='windows_critical_battery'}
        if(((Get-Date)-$lastEventCheck).TotalSeconds-ge 10){
            $latest=(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=524} -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
            if($latest-gt $initialCritical){$fault='new_critical_event'}
            $lastEventCheck=Get-Date
        }
        $ucsi=[BatteryGuard.T142Charger]::ReadEcRam(0x0A90,0x30)
        $cci=[BitConverter]::ToUInt32($ucsi,4)
        $command=[int]$ucsi[8]
        # Connector number exists here only for GET_CONNECTOR_STATUS (0x12).
        # ACK_CC_CI (0x04) uses this byte for acknowledgement flags.
        $commandCompleted=([uint64]$cci -band 0x80000000)-ne 0
        $dataLength=([uint64]$cci -shr 8)-band 0xFF
        if($command-eq 0x12 -and $commandCompleted -and $dataLength-ge 9){$correlatedConnector=[int]$ucsi[10]-band 0x7F}
        $state=[ordered]@{
            time=(Get-Date -Format o);pid=$PID;sequence=$sequence;started_at=$started.ToString('o')
            read_only=$true;soc=$soc;online=$online;ec_online=$ecOnline;windows_ac_online=$windowsAcOnline;ec_flags=$flags;power_source=$source
            ec_power_valid=$resolved.ec_valid;ec_battery_present=$resolved.ec_battery_present;windows_battery_present=$resolved.windows_battery_present;power_source_basis=$resolved.basis;power_warning=$resolved.warning
            adapter_code=$adapter;type_c_port=$(if($source-eq'TypeC'){$adapter}else{0})
            current_ma=$signed;voltage_mv=[BitConverter]::ToUInt16($b,16)
            remaining_mwh=([BitConverter]::ToUInt16($b,14)*10);full_mwh=([BitConverter]::ToUInt16($b,8)*10)
            adapter_available_w=([int]$b[46]*256+[int]$b[47]);performance_mode_code=[int]$b[0x84]
            cpu_profile_code=[int]$b[0x93];battery_design_capacity_raw=[BitConverter]::ToUInt16($b,4)
            windows_charging=[bool]$windows.Charging;windows_critical=[bool]$windows.Critical
            windows_remaining_mwh=[int]$windows.RemainingCapacity
            ucsi_version=[BitConverter]::ToString($ucsi,0,2);ucsi_cci=('0x{0:X8}'-f[BitConverter]::ToUInt32($ucsi,4))
            ucsi_control=[BitConverter]::ToString($ucsi,8,8);ucsi_message=[BitConverter]::ToString($ucsi,16,16)
            ucsi_response_correlated=($correlatedConnector-gt 0 -and $source-eq 'TypeC' -and $correlatedConnector-eq $adapter)
            ucsi_response_connector=$correlatedConnector;fault=$fault
        }
        Save-LiveState $state
        $lastSoc=$soc
        Start-Sleep -Seconds 2
    }
}catch{Save-LiveState ([ordered]@{time=(Get-Date -Format o);pid=$PID;read_only=$true;fault=$_.Exception.Message});throw}
finally{if($owned){$gate.ReleaseMutex()};$gate.Dispose()}
