param([switch]$Worker)
$ErrorActionPreference = 'Stop'
$script:ControlRoot = $PSScriptRoot
$script:SettingsPath = Join-Path $PSScriptRoot 'agent\charge-settings.json'
$script:RuntimePath = Join-Path $PSScriptRoot 'agent\charge-runtime.json'
$script:HardwareBlockPath = Join-Path $PSScriptRoot 'agent\hardware-access-block.json'
$script:ChargerIdentityValidated=$false
. (Join-Path $script:ControlRoot 'TypeCPower.ps1')

function Write-ControlJson($path, $value) {
    $temporary = $path + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($temporary, $path, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $path) }
}

function Read-ControlJson($path) {
    $lastError = $null
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        try {
            $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
            try{
                $json=$reader.ReadToEnd()
                if([string]::IsNullOrWhiteSpace($json)){throw 'JSON state file is temporarily empty'}
                return $json|ConvertFrom-Json
            }finally{$reader.Dispose()}
        }
        catch {
            $lastError = $_
            Start-Sleep -Milliseconds 25
        }
    }
    throw $lastError
}

function Test-ControlProcessAlive([int]$processId) {
    if($processId -le 0){return $false}
    $process=$null
    try {
        $process=[Diagnostics.Process]::GetProcessById($processId)
        return -not $process.HasExited
    }catch{return $false}
    finally{if($process){$process.Dispose()}}
}

function Get-ControlSettings {
    if (Test-Path -LiteralPath $script:SettingsPath) {
        return Read-ControlJson $script:SettingsPath
    }
    return [pscustomobject]@{ enabled=$true; limit=80; pause=$false; hysteresis=3; revision='' }
}

function Test-ControlMaintenance {
    $path=Join-Path $script:ControlRoot 'agent\maintenance.json'
    if(-not(Test-Path -LiteralPath $path)){return $false}
    try{$state=Read-ControlJson $path;return $state.active -and [datetime]$state.expires_at-gt (Get-Date)}catch{return $true}
}

function Get-ControlRuntime {
    $state = [pscustomobject]@{
        paused_by_us=$false; restore_current=0; phase='starting'; error=''; updated_at=''; applied_revision=''; worker_pid=0
        acpi_flag_owned=$false; acpi_original_limit=$false; windows_charging=$false; windows_ac_online=$false
        acpi_charge_limited=$false; native_charge_protection=$false; power_source='Unknown'; type_c_port=0
        actual_current_ma=0; current_register=0; last_display_source=''; display_mode=''; display_error=''
        charge_reassertions=0; last_charge_reassertion_at=''
        controller='isolated_smbus_E';controller_verified=$false
        started_at='';last_gap_seconds=0;resumed_at='';consecutive_errors=0;last_verified_at=''
        last_pause_enforcement_ms=0;max_pause_enforcement_ms=0
        charger_inhibit_supported=$false;charger_inhibit_active=$false;charger_inhibit_probe_done=$true
        typec_probe_at=''; adapter_available_w=0; typec_performance_priority=$false; performance_mode_code=-1
        ucsi_device_status=''; ucsi_last_timeout_at=''; ucsi_last_timeout_command=''; ucsi_version=''
        ucsi_cci=''; ucsi_control=''; ucsi_message=''; ucsi_ack_complete=$false; ucsi_power_mode_code=-1
        ucsi_power_mode='unknown'; ucsi_connected=$false; ucsi_sample_at=''; ucsi_sample_age_seconds=-1
        ucsi_sample_matches_port=$false; typec_health='unknown'; typec_repair_state='none'; typec_diagnostic=''
        ucsi_historical_power_mode='unknown'; ucsi_sample_is_current=$false
        ucsi_reported_power_mode='unknown';ucsi_response_correlated=$false;ucsi_ack_flags=$null;ucsi_status_connector=0;ucsi_rdo=$null
        hardware_control_suspended=$false
        current_register_verified=$false;ec_power_valid=$null;power_warning=''
        runtime_load_error=''
        resume_current_candidate=0
    }
    # Open directly with retry: Test-Path can briefly report false while the
    # writer replaces a runtime file, producing a spurious starting state.
    try {
        $saved = Read-ControlJson $script:RuntimePath
        if($null-eq $saved -or $saved -isnot [System.Management.Automation.PSCustomObject]) {
            throw 'Charge runtime must be a JSON object'
        }
        foreach ($property in $saved.psobject.Properties) {
            if ($state.psobject.Properties[$property.Name]) { $state.($property.Name) = $property.Value }
        }
    } catch {
        # Runtime is derived telemetry, not the user's saved charge policy.
        # A truncated/NUL file after power loss must not prevent the owner
        # from restarting and enforcing the separate saved settings.
        $state.runtime_load_error=$_.Exception.Message
    }
    return $state
}

function Suspend-ChargeHardware([string]$reason) {
    if (Test-Path -LiteralPath $script:HardwareBlockPath) { return }
    $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $startup=(Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).BatteryGuardWorker
    Write-ControlJson $script:HardwareBlockPath ([ordered]@{
        active=$true;reason=$reason;created_at=(Get-Date -Format o);original_startup=$startup
    })
    if ($startup -and $startup -like ('*'+$script:ControlRoot+'*')) {
        Remove-ItemProperty -LiteralPath $runKey -Name BatteryGuardWorker -ErrorAction SilentlyContinue
    }
}

function Get-EmergencyPauseStatus {
    $path=Join-Path $script:ControlRoot 'agent\emergency-pause-runtime.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $state=Read-ControlJson $path
        $fresh=((Get-Date)-[datetime]$state.time).TotalSeconds -lt 5
        $alive=Test-ControlProcessAlive ([int]$state.pid)
        if ($fresh -and $alive -and -not $state.error) { return $state }
    } catch {}
    return $null
}

function Get-ControlObservation {
    $path=Join-Path $script:ControlRoot 'agent\control-live.json'
    try {
        $state=Read-ControlJson $path
        $age=((Get-Date)-[datetime]$state.time).TotalSeconds
        if($age-ge 0 -and $age-lt 8 -and $state.read_only -and -not $state.fault -and
            (Test-ControlProcessAlive ([int]$state.pid))){return $state}
    }catch{}
    return $null
}

function Start-ChargeObserver {
    if((Test-ControlMaintenance) -or (Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\control-observer.stop'))){return}
    if(Get-ControlObservation){return}
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $observer=Join-Path $script:ControlRoot 'agent\ObserveChargeSession.ps1'
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -File "'+$observer+'"')|Out-Null
}

function Start-PerformanceFeedback {
    if((Test-ControlMaintenance) -or (Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\performance-feedback.stop'))){return}
    $path=Join-Path $script:ControlRoot 'agent\performance-feedback-runtime.json'
    if(Test-Path -LiteralPath $path){
        try{
            $state=Read-ControlJson $path
            $age=((Get-Date)-[datetime]$state.updated_at).TotalSeconds
            if($age-ge 0 -and $age-lt 12 -and (Test-ControlProcessAlive ([int]$state.pid))){return}
        }catch{}
    }
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $file=Join-Path $script:ControlRoot 'PerformanceFeedback.ps1'
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -STA -File "'+$file+'"')|Out-Null
}

function Start-FanCurveWorker {
    if((Test-ControlMaintenance) -or (Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\fan-control.stop'))){return}
    $live=Get-ControlObservation
    if(-not $live -or $live.ec_power_valid-eq $false){return}
    $path=Join-Path $script:ControlRoot 'agent\fan-runtime.json'
    if(Test-Path -LiteralPath $path){
        try{
            $state=Read-ControlJson $path
            $age=((Get-Date)-[datetime]$state.updated_at).TotalSeconds
            if($age-ge 0 -and $age-lt 8 -and (Test-ControlProcessAlive ([int]$state.pid))){return}
            if($state.error){
                if(-not(Get-Command Test-FanWorkerRecoveryAllowed -ErrorAction SilentlyContinue)){
                    . (Join-Path $script:ControlRoot 'FanCurvePolicy.ps1')
                }
                $bootTime=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
                if(-not(Test-FanWorkerRecoveryAllowed $state $bootTime)){return}
            }
        }catch{}
    }
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $file=Join-Path $script:ControlRoot 'FanCurveWorker.ps1'
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -File "'+$file+'"')|Out-Null
}

function Initialize-ChargeHardware {
    if (-not ('BatteryGuard.WindowsBatteryStatus' -as [type])) {
        Add-Type -Path (Join-Path $script:ControlRoot 'driver\WindowsBatteryStatus.cs')
    }
    if (Test-Path -LiteralPath $script:HardwareBlockPath) { return }
    if (-not ('BatteryGuard.T142Charger' -as [type])) {
        Add-Type -Path (Join-Path $script:ControlRoot 'driver\T142Charger.cs')
    }
    [BatteryGuard.T142Charger]::HardwareBlockPath = $script:HardwareBlockPath
    if (-not ('BatteryGuard.WindowsBatteryStatus' -as [type])) {
        Add-Type -Path (Join-Path $script:ControlRoot 'driver\WindowsBatteryStatus.cs')
    }
    if (-not ('BatteryGuard.DisplayRefresh' -as [type])) {
        Add-Type -Path (Join-Path $script:ControlRoot 'driver\DisplayRefresh.cs')
    }
    if ([BatteryGuard.T142Charger]::LoadLibrary((Join-Path $script:ControlRoot 'driver\x64\inpoutx64.dll')) -eq [IntPtr]::Zero) {
        throw 'Cannot load InpOut DLL'
    }
    $board = Get-CimInstance Win32_BaseBoard
    if ($board.Product -ne 'WUJIE Series-T142-STX') { throw 'Unsupported motherboard' }
    [BatteryGuard.T142Charger]::ValidateBatterySignature()
}

function Confirm-ChargerIdentity {
    if(-not $script:ChargerIdentityValidated){
        [BatteryGuard.T142Charger]::Validate()
        $script:ChargerIdentityValidated=$true
    }
}

function Start-ChargeWorker {
    if((Test-ControlMaintenance) -or (Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\charge-worker.stop'))){return}
    if (Test-Path -LiteralPath $script:HardwareBlockPath) { return }
    $state = Get-ControlRuntime
    if ($state.updated_at) {
        $age = (Get-Date) - [datetime]$state.updated_at
        if ($age.TotalSeconds -lt 10 -and (Test-ControlProcessAlive ([int]$state.worker_pid))) { return }
    }
    $agent = Join-Path $script:ControlRoot 'ChargeControl.ps1'
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -File "'+$agent+'" -Worker') | Out-Null
}

function Start-ChargeSupervisor {
    if((Test-ControlMaintenance) -or (Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\supervisor.stop'))){return}
    if(Test-Path -LiteralPath $script:HardwareBlockPath){return}
    $path=Join-Path $script:ControlRoot 'agent\supervisor-runtime.json'
    if(Test-Path -LiteralPath $path){
        try{$state=Read-ControlJson $path;if(((Get-Date)-[datetime]$state.updated_at).TotalSeconds-lt 8 -and (Test-ControlProcessAlive ([int]$state.supervisor_pid))){return}}catch{}
    }
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $file=Join-Path $script:ControlRoot 'BatteryGuardSupervisor.ps1'
    Start-Process $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -File "'+$file+'"')|Out-Null
}

function Start-BackgroundRecovery {
    if(Test-ControlMaintenance){return}
    if(Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\background-recovery.stop')){return}
    $path=Join-Path $script:ControlRoot 'agent\background-recovery.json'
    if(Test-Path -LiteralPath $path){
        try{
            $state=Read-ControlJson $path
            $age=((Get-Date)-[datetime]$state.time).TotalSeconds
            if($age-ge 0 -and $age-lt 30 -and (Test-ControlProcessAlive ([int]$state.pid))){return}
        }catch{}
    }
    # The scheduled logon task may already own this process. Check the exact
    # script before starting a replacement; its mutex is the final arbiter.
    $file=Join-Path $script:ControlRoot 'BackgroundRecovery.ps1'
    $process=Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object {$_.CommandLine-like ('*"'+$file+'"*') -and $_.CommandLine-notmatch '(?i)(?:^|\s)-Once(?:\s|$)'}
    if($process){return}
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -WindowStyle Hidden -File "'+$file+'"')|Out-Null
}

function Start-PowerEventGuard {
    if(Test-ControlMaintenance){return}
    if(Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\power-event-guard.stop')){return}
    $path=Join-Path $script:ControlRoot 'agent\power-event-guard.json'
    if(Test-Path -LiteralPath $path){
        try{
            $state=Read-ControlJson $path
            $age=((Get-Date)-[datetime]$state.time).TotalSeconds
            if($age-ge 0 -and $age-lt 30 -and (Test-ControlProcessAlive ([int]$state.pid))){return}
        }catch{}
    }
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $file=Join-Path $script:ControlRoot 'PowerEventGuard.ps1'
    Start-Process $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -File "'+$file+'"')|Out-Null
}

function Set-ControlSettings([int]$limit, [bool]$enabled, [bool]$pause) {
    if (Test-Path -LiteralPath $script:HardwareBlockPath) {
        throw 'Charge control is suspended after false Critical battery events; saved settings are preserved'
    }
    Save-ControlPreferences $limit $enabled $pause
    Start-ChargeWorker
}

function Save-ControlPreferences([int]$limit, [bool]$enabled, [bool]$pause) {
    if ($limit -lt 20 -or $limit -gt 100) { throw 'Charge limit must be between 20 and 100' }
    Write-ControlJson $script:SettingsPath ([ordered]@{ enabled=$enabled; limit=$limit; pause=$pause; hysteresis=3; revision=[guid]::NewGuid().ToString() })
}

function Get-WindowsBatterySnapshot {
    $st = Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus
    $fc = Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity
    $cy = $null
    try { $cy = Get-CimInstance -Namespace root/wmi -ClassName BatteryCycleCount } catch {}
    $windows = [BatteryGuard.WindowsBatteryStatus]::ReadBatteryState()
    $nativeProtection=$false
    try{$nativeProtection=[BatteryGuard.WindowsBatteryStatus]::ReadChargeLimitingNotification().Active}catch{}
    $online = [bool]$st.PowerOnline
    $source = $(if ($online) { 'Unknown' } else { 'Battery' })
    $signedRate = $(if ($st.Charging) { [double]$st.ChargeRate } elseif ($st.Discharging) { -[double]$st.DischargeRate } else { 0 })
    $current = $(if ([int]$st.Voltage -gt 0) { [int][math]::Round($signedRate * 1000 / [int]$st.Voltage) } else { 0 })
    $percentage = $(if ([int]$fc.FullChargedCapacity -gt 0) { [int][math]::Floor(100.0 * [int]$st.RemainingCapacity / [int]$fc.FullChargedCapacity) } else { -1 })
    [pscustomobject]@{
        SoC = $percentage
        Online = $online
        Charging = [bool]$st.Charging
        Discharging = [bool]$st.Discharging
        ChargeRate = $(if ($st.Charging) { [int]$st.ChargeRate } else { 0 })
        DischargeRate = $(if ($st.Discharging) { [int]$st.DischargeRate } else { 0 })
        Current = $current
        Voltage = [int]$st.Voltage
        Remaining = [int]$st.RemainingCapacity
        FullCap = [int]$fc.FullChargedCapacity
        Cycle = $(if ($cy) { [int]$cy.CycleCount } else { -1 })
        EcPowerFlags = 0
        AdapterCode = 0
        AcpiChargeLimited = $false
        WindowsCharging = ($windows.Charging -ne 0)
        WindowsOnline = ($windows.AcOnLine -ne 0)
        WindowsRate = $windows.Rate
        PowerSource = $source
        PowerSourceLabel = $(if ($online) { 'External power' } else { 'Battery' })
        TypeCPort = 0
        NativeChargeProtection = $nativeProtection
        Critical = [bool]$st.Critical
        TelemetrySource = 'Windows battery driver (cached)'
        CurrentIsEstimated = $true
        EcPowerValid = $null
        PowerWarning = ''
    }
}

function New-ControlBatterySnapshot($observed,$windows,$nativeProtection){
    $current=[int]$observed.current_ma
    $voltage=[int]$observed.voltage_mv
    $power=[math]::Round($current*$voltage/1000.0)
    return [pscustomobject]@{
        SoC=[int]$observed.soc
        Online=[bool]$observed.online
        Charging=([bool]$observed.online -and $current -gt 50)
        Discharging=($current -lt -50)
        ChargeRate=[math]::Max(0,$power)
        DischargeRate=[math]::Max(0,-$power)
        Current=$current
        Voltage=$voltage
        Remaining=[int]$observed.remaining_mwh
        FullCap=[int]$observed.full_mwh
        Cycle=-1
        EcPowerFlags=[int]$observed.ec_flags
        AdapterCode=[int]$observed.adapter_code
        AcpiChargeLimited=$false
        WindowsCharging=[bool]$observed.windows_charging
        WindowsOnline=[bool]$observed.windows_ac_online
        WindowsRate=[int]$windows.Rate
        PowerSource=[string]$observed.power_source
        PowerSourceLabel=$(if($observed.online){'External power'}else{'Battery'})
        TypeCPort=[int]$observed.type_c_port
        NativeChargeProtection=[bool]$nativeProtection.Active
        Critical=[bool]$windows.Critical
        TelemetrySource='EC battery cache (read-only); Windows charging flag may lag'
        CurrentIsEstimated=$false
        EcPowerValid=$observed.ec_power_valid
        PowerWarning=[string]$observed.power_warning
    }
}

function Get-ControlBatterySnapshot($observed){
    $windows=[BatteryGuard.WindowsBatteryStatus]::ReadBatteryState()
    try{$nativeProtection=[BatteryGuard.WindowsBatteryStatus]::ReadChargeLimitingNotification()}catch{$nativeProtection=[pscustomobject]@{Active=$false}}
    return New-ControlBatterySnapshot $observed $windows $nativeProtection
}

function Get-BatterySnapshot([object]$Observation=$null) {
    if($Observation){return Get-ControlBatterySnapshot $Observation}
    # Do not inject SBS reads into the firmware-owned SMBus to obtain telemetry.
    # Windows and the EC RAM cache are read without starting SMBus transactions.
    $snapshot = Get-WindowsBatterySnapshot
    $observed=Get-ControlObservation
    if($observed){
        $snapshot.Online=[bool]$observed.online
        $snapshot.SoC=[int]$observed.soc
        $snapshot.EcPowerFlags=[int]$observed.ec_flags
        $snapshot.AdapterCode=[int]$observed.adapter_code
        $snapshot.PowerSource=[string]$observed.power_source
        $snapshot.TypeCPort=[int]$observed.type_c_port
        $snapshot.Current=[int]$observed.current_ma
        $snapshot.Voltage=[int]$observed.voltage_mv
        $snapshot.Remaining=[int]$observed.remaining_mwh
        $snapshot.FullCap=[int]$observed.full_mwh
        $snapshot.Charging=$snapshot.Online -and $snapshot.Current-gt 50
        $snapshot.Discharging=$snapshot.Current-lt -50
        $power=[math]::Round($snapshot.Current*$snapshot.Voltage/1000.0)
        $snapshot.ChargeRate=[math]::Max(0,$power)
        $snapshot.DischargeRate=[math]::Max(0,-$power)
        $snapshot.TelemetrySource='EC battery cache (read-only); Windows charging flag may lag'
        $snapshot.CurrentIsEstimated=$false
        $snapshot.EcPowerValid=$observed.ec_power_valid
        $snapshot.PowerWarning=[string]$observed.power_warning
        return $snapshot
    }
    if (Test-Path -LiteralPath $script:HardwareBlockPath) { return $snapshot }
    if ($snapshot.Critical) {
        Suspend-ChargeHardware 'Windows reported Critical battery; suspend shared SMBus access to prevent further corruption'
        throw 'Windows reported Critical battery; hardware control suspended'
    }
    $ecPower = [BatteryGuard.T142Charger]::ReadEcRam(0x0460, 2)
    $snapshot.EcPowerFlags = [int]$ecPower[0]
    $snapshot.AdapterCode = [int]$ecPower[1]
    $snapshot.Online = ($ecPower[0] -band 1) -ne 0
    if (-not $snapshot.Online) { $snapshot.PowerSource='Battery' }
    elseif ($ecPower[1] -eq 4) { $snapshot.PowerSource='DC' }
    elseif ($ecPower[1] -in @(1,2)) { $snapshot.PowerSource='TypeC'; $snapshot.TypeCPort=[int]$ecPower[1] }
    if (($ecPower[0] -band 0x10) -ne 0 -and $snapshot.SoC -gt 20) {
        Suspend-ChargeHardware 'EC reports Critical battery while Windows remaining capacity exceeds 20%'
        throw 'EC reports Critical battery while remaining capacity exceeds 20%; suspend hardware access'
    }
    $snapshot
}

function Send-ChargeToast([string]$title, [string]$body) {
    if(Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\charge-verification.suppress-toasts')){return}
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $xml.GetElementsByTagName('text')
        [void]$texts.Item(0).AppendChild($xml.CreateTextNode($title))
        [void]$texts.Item(1).AppendChild($xml.CreateTextNode($body))
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {}
}

function Invoke-ChargePolicy($settings, $runtime, $snapshot) {
    if($snapshot.Critical -or ($snapshot.EcPowerFlags-band 0x10)-ne 0){
        Suspend-ChargeHardware 'Critical battery indication during isolated-E charger control'
        throw 'Critical battery indication; charger control stopped'
    }
    if($snapshot.SoC-lt 0 -or $snapshot.SoC-gt 100){throw 'Battery state is unavailable; no charge-current command issued'}
    # No charger transactions are needed while confirmed offline. This keeps
    # battery-only use passive, and avoids polling an irrelevant register.
    $current=$null
    if($snapshot.Online){Confirm-ChargerIdentity;$current=[BatteryGuard.T142Charger]::ReadCharger(0x14)}
    $runtime.current_register_verified=[bool]$snapshot.Online
    $runtime.ec_power_valid=$snapshot.EcPowerValid
    $runtime.power_warning=$snapshot.PowerWarning
    $runtime.controller='isolated_smbus_E';$runtime.controller_verified=$true
    $runtime.hardware_control_suspended=$false
    if (-not $snapshot.Online) {
        $runtime.phase = 'battery'
    } else {
        $thresholdStop = $settings.enabled -and $settings.limit -lt 100 -and (
            $snapshot.SoC -ge $settings.limit -or ($runtime.paused_by_us -and $snapshot.SoC -gt ($settings.limit - $settings.hysteresis)))
        if ($settings.pause -or $thresholdStop) {
            $runtime.paused_by_us=$true
            # Unknown persistent-inhibit commands are not part of normal startup.
            # Only retain this path for an already verified active inhibit.
            if($runtime.charger_inhibit_supported-eq $true -and $runtime.charger_inhibit_active){
                try{
                    [void][BatteryGuard.T142Charger]::SetChargerInhibit($true)
                    $runtime.charger_inhibit_supported=$true;$runtime.charger_inhibit_active=$true;$runtime.charger_inhibit_probe_done=$true
                }catch{
                    if($runtime.charger_inhibit_supported-eq $true){throw}
                    $runtime.charger_inhibit_supported=$false;$runtime.charger_inhibit_active=$false;$runtime.charger_inhibit_probe_done=$true
                }
            }
            if ($current -gt 0) {
                if ($current -gt 0x0F00) { throw 'Firmware current is outside the verified range' }
                if ($runtime.paused_by_us) {
                    $runtime.charge_reassertions = [int]$runtime.charge_reassertions + 1
                    $runtime.last_charge_reassertion_at = Get-Date -Format o
                }
                $runtime.restore_current = $current
                $runtime.paused_by_us = $true
                Write-ControlJson $script:RuntimePath $runtime
                [BatteryGuard.T142Charger]::SetChargeCurrent(0)
                $current=0
            }
            $runtime.phase = $(if ($snapshot.Current -le 50) { 'paused' } else { 'stopping' })
        } elseif ($runtime.paused_by_us) {
            # Resume only while the pack itself requests charging and reports no charge alarm.
            $request = [BatteryGuard.T142Charger]::ReadBattery(0x14)
            $status = [BatteryGuard.T142Charger]::ReadBattery(0x16)
            if ($current -gt 0) {
                if($runtime.charger_inhibit_supported){
                    [void][BatteryGuard.T142Charger]::SetChargerInhibit($false)
                    $runtime.charger_inhibit_active=$false
                }
                $runtime.paused_by_us = $false
                $runtime.phase = 'charging_allowed'
            } elseif ($request -gt 0 -and ($status -band 0xD000) -eq 0 -and $snapshot.SoC -lt 100) {
                if ($runtime.restore_current -le 0) { throw 'Missing original charging current' }
                $current=[math]::Min($runtime.restore_current, ($request -band 0x3FC0))
                if($runtime.charger_inhibit_supported){
                    [void][BatteryGuard.T142Charger]::SetChargerInhibit($false)
                    $runtime.charger_inhibit_active=$false
                }
                [BatteryGuard.T142Charger]::SetChargeCurrent($current)
                $runtime.paused_by_us = $false
                $runtime.phase = 'charging_allowed'
            } else { $runtime.phase = 'waiting_for_battery' }
        } else { $runtime.phase = 'charging_allowed' }
    }
    $runtime.error = ''
    $runtime.acpi_flag_owned = $false
    $runtime.windows_charging = $snapshot.WindowsCharging
    $runtime.windows_ac_online = $snapshot.WindowsOnline
    $runtime.native_charge_protection = $snapshot.NativeChargeProtection
    $powerSourceChanged = ($runtime.power_source -ne $snapshot.PowerSource -or $runtime.type_c_port -ne $snapshot.TypeCPort)
    $runtime.power_source = $snapshot.PowerSource
    $runtime.type_c_port = $snapshot.TypeCPort
    $runtime.actual_current_ma = $snapshot.Current
    $runtime.current_register = $current
    # Display refresh is owned by PerformanceFeedback, avoiding competing writes.
    $runtime.acpi_charge_limited = ([BatteryGuard.T142Charger]::ReadEcRam(0x0490,1)[0] -band 1) -ne 0
    # Use the existing read-only observation for source/budget. Charger control
    # does not restart the separately ended Type-C diagnosis/repair workflow.
    $observed=Get-ControlObservation
    if($observed){$runtime.adapter_available_w=[int]$observed.adapter_available_w;$runtime.performance_mode_code=[int]$observed.performance_mode_code}
    $feedbackFile=Join-Path $script:ControlRoot 'agent\performance-feedback-runtime.json'
    if(Test-Path -LiteralPath $feedbackFile){try{$feedbackState=Read-ControlJson $feedbackFile;$runtime.display_mode=$feedbackState.display_mode;$runtime.display_error=$feedbackState.display_error}catch{}}
    $runtime.applied_revision = $settings.revision
    $runtime.updated_at = Get-Date -Format o
    $runtime.last_verified_at=$runtime.updated_at
    $runtime.consecutive_errors=0
    Write-ControlJson $script:RuntimePath $runtime
}

if ($Worker) {
    if(Test-ControlMaintenance){exit 0}
    if (Test-Path -LiteralPath $script:HardwareBlockPath) { exit 0 }
    $workerMutex = [Threading.Mutex]::new($false, 'Global\BatteryGuard-T142-Worker')
    $chargeOwner = [Threading.Mutex]::new($false, 'Global\BatteryGuard-EmergencyPause')
    $chargeOwned=$false
    $owned = $false
    try {
        try { $owned = $workerMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { exit 0 }
        try{$chargeOwned=$chargeOwner.WaitOne(0)}catch [Threading.AbandonedMutexException]{$chargeOwned=$true}
        if(-not $chargeOwned){exit 0}
        Initialize-ChargeHardware
        $runtime = Get-ControlRuntime
        $runtime.worker_pid = $PID
        $runtime.started_at=Get-Date -Format o
        $runtime.phase='starting';$runtime.error='';$runtime.hardware_control_suspended=$false
        $runtime.controller='isolated_smbus_E'
        Write-ControlJson $script:RuntimePath $runtime
        # A protection session survives short EC current pulses and worker restarts.
        # Only a confirmed release allows another pause notification.
        $pauseNotified = [bool]$runtime.paused_by_us
        $lastNativeProtection = $null
        $lastPolicyAt=[datetime]::MinValue
        $lastPolicyRevision=''
        $lastTick=Get-Date
        $lastCriticalCheck=[datetime]::MinValue
        $criticalBaseline=(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=524} -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
        $stopFile=Join-Path $script:ControlRoot 'agent\charge-worker.stop'
        while ($true) {
            if(Test-Path -LiteralPath $stopFile){break}
            if (Test-Path -LiteralPath $script:HardwareBlockPath) {
                $runtime.phase='hardware_suspended'
                $runtime.error='Hardware transactions suspended after false Critical battery events'
                $runtime.worker_pid=0
                $runtime.updated_at=Get-Date -Format o
                Write-ControlJson $script:RuntimePath $runtime
                break
            }
            $fastHold=$false
            try {
                $now=Get-Date
                $gap=($now-$lastTick).TotalSeconds;$lastTick=$now
                if($gap-gt 5){$runtime.last_gap_seconds=[math]::Round($gap,1);$runtime.resumed_at=$now.ToString('o');$lastPolicyAt=[datetime]::MinValue}
                if(($now-$lastCriticalCheck).TotalSeconds-ge 5){
                    $critical=(Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Kernel-Power';Id=524} -MaxEvents 1 -ErrorAction SilentlyContinue).RecordId
                    if($critical-gt $criticalBaseline){Suspend-ChargeHardware 'New critical battery event during isolated SMBus E control';throw 'New critical battery event; hardware control stopped'}
                    $lastCriticalCheck=$now
                }
                $activeSettings=Get-ControlSettings
                $live=Get-ControlObservation
                if(-not $live){Start-ChargeObserver;throw 'Waiting for fresh EC battery observation; charging state not confirmed'}
                if($live.windows_critical -or ($live.ec_flags-band 0x10)-ne 0){Suspend-ChargeHardware 'Critical EC/Windows battery flag during isolated SMBus E control';throw 'Critical battery flag; hardware control stopped'}
                if($live){
                    if($live.online){Confirm-ChargerIdentity}
                    $thresholdHold=$activeSettings.enabled -and $activeSettings.limit-lt 100 -and (
                        $live.soc-ge $activeSettings.limit -or ($runtime.paused_by_us -and $live.soc-gt ($activeSettings.limit-$activeSettings.hysteresis)))
                    $fastHold=$live.online -and ($activeSettings.pause -or $thresholdHold)
                    if($fastHold){
                        $holdResult=[BatteryGuard.T142Charger]::EnforceChargePause()
                        if($holdResult.ZeroWritten){
                            # Learn only matching plausible values from two
                            # independent firmware reassertions, after stopping.
                            # Never delay the zero write or learn a torn FF00 read.
                            $observedCurrent=[int]$holdResult.ObservedCurrent
                            if($observedCurrent-gt 0 -and $observedCurrent-le 0x0F00 -and ($observedCurrent-band 0x3F)-eq 0){
                                if($runtime.resume_current_candidate-eq $observedCurrent){$runtime.restore_current=$observedCurrent}
                                $runtime.resume_current_candidate=$observedCurrent
                            }
                            $runtime.paused_by_us=$true
                            $runtime.charge_reassertions=[int]$runtime.charge_reassertions+1
                            $runtime.last_charge_reassertion_at=Get-Date -Format o
                            $runtime.last_pause_enforcement_ms=[math]::Round($holdResult.ElapsedMilliseconds,2)
                            $runtime.max_pause_enforcement_ms=[math]::Max($runtime.max_pause_enforcement_ms,$runtime.last_pause_enforcement_ms)
                            $entry=[ordered]@{time=$runtime.last_charge_reassertion_at;worker_pid=$PID;controller=$runtime.controller;observed_register=$holdResult.ObservedCurrent;verified_register=0;elapsed_ms=$runtime.last_pause_enforcement_ms;cached_current_ma=$live.current_ma;soc=$live.soc}
                            [IO.File]::AppendAllText((Join-Path $script:ControlRoot 'agent\charge-reassertions.jsonl'),($entry|ConvertTo-Json -Compress)+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
                        }
                    }
                }
                if(((Get-Date)-$lastPolicyAt).TotalSeconds-ge 1 -or $activeSettings.revision-ne $lastPolicyRevision){
                    Invoke-ChargePolicy $activeSettings $runtime (Get-BatterySnapshot $live)
                    $lastPolicyAt=Get-Date;$lastPolicyRevision=$activeSettings.revision
                }
            }
            catch {
                $runtime.phase = 'error'
                $runtime.error = $_.Exception.Message
                $runtime.consecutive_errors=[int]$runtime.consecutive_errors+1
                $runtime.updated_at = Get-Date -Format o
                Write-ControlJson $script:RuntimePath $runtime
            }
            if ($runtime.phase -eq 'paused' -and -not $pauseNotified) {
                Send-ChargeToast '🛡 充电保护' ('已暂停充电，上限 ' + (Get-ControlSettings).limit + '%')
                $pauseNotified = $true
            } elseif ($runtime.phase -eq 'charging_allowed' -and -not $runtime.paused_by_us -and $pauseNotified) {
                Send-ChargeToast '充电保护解除' '已恢复充电'
                $pauseNotified = $false
            }
            try{
                $nativeProtection=[BatteryGuard.WindowsBatteryStatus]::ReadChargeLimitingNotification().Active
                if($lastNativeProtection -ne $nativeProtection){
                    [void][BatteryGuard.WindowsBatteryStatus]::RefreshChargeProtectionIcon()
                    $lastNativeProtection=$nativeProtection
                }
            }catch{}
            Start-Sleep -Milliseconds $(if($fastHold){50}else{1000})
        }
    } finally {
        if($runtime -and $chargeOwned){$runtime.worker_pid=0;$runtime.phase='stopped';$runtime.updated_at=Get-Date -Format o;Write-ControlJson $script:RuntimePath $runtime}
        if($chargeOwned){$chargeOwner.ReleaseMutex()};$chargeOwner.Dispose()
        if ($owned) { $workerMutex.ReleaseMutex() }; $workerMutex.Dispose()
    }
}
