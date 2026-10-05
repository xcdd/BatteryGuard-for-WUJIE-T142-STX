$script:TypeCPowerCacheAt = [datetime]::MinValue
$script:TypeCPowerCachedSystem = $null

function Get-UcsiPowerModeName([int]$mode) {
    switch ($mode) {
        0 { 'none' }
        1 { 'usb-default' }
        2 { 'bc' }
        3 { 'pd' }
        4 { 'type-c-1.5a' }
        5 { 'type-c-3a' }
        default { "reserved-$mode" }
    }
}

function ConvertFrom-UcsiMirror($observation) {
    if(-not $observation){return $null}
    [byte[]]$control=@(([string]$observation.ucsi_control -split '-')|ForEach-Object{[Convert]::ToByte($_,16)})
    [byte[]]$message=@(([string]$observation.ucsi_message -split '-')|ForEach-Object{[Convert]::ToByte($_,16)})
    if($control.Length-ne 8 -or $message.Length-ne 16){throw 'Unexpected UCSI mirror size'}
    $cci=[Convert]::ToUInt32(([string]$observation.ucsi_cci).Replace('0x',''),16)
    $command=[int]$control[0]
    $rawStatus=[BitConverter]::ToUInt32($message,0)
    $mode=[int](($rawStatus-shr 16)-band 7)
    $complete=([uint64]$cci-band 0x80000000)-ne 0
    $dataLength=([uint64]$cci-shr 8)-band 0xFF
    $statusConnector=0
    if($command-eq 0x12 -and $complete -and $dataLength-ge 9){$statusConnector=[int]$control[2]-band 0x7F}
    if($observation.ucsi_response_correlated){$statusConnector=[int]$observation.ucsi_response_connector}
    $correlated=$statusConnector-gt 0 -and $observation.power_source-eq'TypeC' -and $statusConnector-eq[int]$observation.type_c_port
    [pscustomobject]@{
        command=$command
        command_connector=$(if($command-eq 0x12){[int]$control[2]-band 0x7F}else{$null})
        ack_flags=$(if($command-eq 4){[int]$control[2]-band 3}else{$null})
        ack_complete=([uint64]$cci-band 0x20000000)-ne 0
        busy=([uint64]$cci-band 0x10000000)-ne 0
        error=([uint64]$cci-band 0x40000000)-ne 0
        command_complete=$complete
        data_length=$dataLength
        reported_mode_code=$mode
        reported_mode=(Get-UcsiPowerModeName $mode)
        reported_connected=(($rawStatus-shr 19)-band 1)-ne 0
        response_correlated=$correlated
        response_connector=$statusConnector
        rdo=$(if($correlated -and $mode-eq 3){[BitConverter]::ToUInt32($message,4)}else{$null})
    }
}

function Get-UcsiCachedPhysicalSample {
    $path = Join-Path $script:ControlRoot 'agent\ucsi-after-restart.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Get-UcsiSystemState {
    if ($script:TypeCPowerCachedSystem -and ((Get-Date) - $script:TypeCPowerCacheAt).TotalSeconds -lt 30) {
        return $script:TypeCPowerCachedSystem
    }

    $deviceStatus = 'Missing'
    try {
        $device = Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID='ACPI\\USBC000\\0'" -ErrorAction Stop
        if ($device) {
            $deviceStatus = $(if ([int]$device.ConfigManagerErrorCode -eq 0) { 'OK' } else { "Problem-$([int]$device.ConfigManagerErrorCode)" })
        }
    } catch { $deviceStatus = 'Unavailable' }

    $lastTimeout = $null
    $lastCommand = ''
    try {
        $event = Get-WinEvent -FilterHashtable @{
            LogName='Microsoft-Windows-USB-UCMUCSICX/Operational'
            Id=1
            StartTime=(Get-Date).AddDays(-7)
        } -MaxEvents 1 -ErrorAction Stop
        if ($event -and $event.Message -match 'Command Timeout') {
            $lastTimeout = $event.TimeCreated
            if ($event.Message -match 'UCSI Command:\s*([^\r\n]+)') { $lastCommand = $Matches[1].Trim() }
        }
    } catch {}

    $script:TypeCPowerCachedSystem = [pscustomobject]@{
        device_status = $deviceStatus
        last_timeout_at = $(if ($lastTimeout) { $lastTimeout.ToString('o') } else { '' })
        last_timeout_command = $lastCommand
    }
    $script:TypeCPowerCacheAt = Get-Date
    return $script:TypeCPowerCachedSystem
}

function Get-TypeCPowerDiagnostics($snapshot) {
    $hardwareSuspended=Test-Path -LiteralPath (Join-Path $script:ControlRoot 'agent\hardware-access-block.json')
    $availableWatts=$null
    $featureByte=$null
    $performanceMode=$null
    $observation=Get-ControlObservation
    $liveUcsi=ConvertFrom-UcsiMirror $observation
    if($observation){$availableWatts=[int]$observation.adapter_available_w;$performanceMode=[int]$observation.performance_mode_code}
    if (-not $hardwareSuspended) {
        $availableBytes = [BatteryGuard.T142Charger]::ReadEcRam(0x048E, 2)
        $availableWatts = ([int]$availableBytes[0] -shl 8) + [int]$availableBytes[1]
        $featureByte = [BatteryGuard.T142Charger]::ReadEcRam(0x0425, 1)[0]
        $performanceMode = [BatteryGuard.T142Charger]::ReadEcRam(0x04E4, 1)[0]
    }
    if ($null -eq $performanceMode) {
        $firmwarePath=Join-Path $script:ControlRoot 'agent\firmware-interface-read.json'
        try {
            $firmware=Get-Content -LiteralPath $firmwarePath -Raw -Encoding UTF8|ConvertFrom-Json
            $row=@($firmware.reads)|Where-Object name -eq 'performance_mode'|Select-Object -First 1
            if($row -and $row.output -match '^00-80-00-08-([0-9A-Fa-f]{2})'){$performanceMode=[Convert]::ToInt32($Matches[1],16)}
        } catch {}
    }
    $system = Get-UcsiSystemState
    $sample = Get-UcsiCachedPhysicalSample

    $sampleTime = ''
    $sampleAgeSeconds = -1
    $modeCode = -1
    $mode = 'unknown'
    $connected = $false
    $cci = ''
    $control = ''
    $message = ''
    $ackComplete = $false
    $sampleMatchesPort = $false
    if ($sample) {
        try {
            $sampleTime = [string]$sample.time
            $sampleAgeSeconds = [math]::Round(((Get-Date) - [datetime]$sample.time).TotalSeconds)
        } catch {}
        $modeCode = [int]$sample.power_opmode
        $mode = Get-UcsiPowerModeName $modeCode
        $connected = ([int]$sample.connected -ne 0)
        $cci = [string]$sample.cci
        $control = [string]$sample.control
        $message = [string]$sample.message_in
        $ackComplete = ([int]$sample.cci_ack_complete -ne 0)
        if ($snapshot.PowerSource -eq 'TypeC') {
            $parts = $control -split '-'
            if ($parts.Count-ge 3 -and $parts[0]-eq '12') { $sampleMatchesPort=([Convert]::ToInt32($parts[2],16)-eq[int]$snapshot.TypeCPort) }
        }
    }
    if($liveUcsi){
        $version=[string]$observation.ucsi_version
        $sampleTime=[string]$observation.time
        $sampleAgeSeconds=[math]::Round(((Get-Date)-[datetime]$observation.time).TotalSeconds)
        $modeCode=$liveUcsi.reported_mode_code;$mode=$liveUcsi.reported_mode
        $connected=$liveUcsi.reported_connected;$cci=[string]$observation.ucsi_cci
        $control=[string]$observation.ucsi_control;$message=[string]$observation.ucsi_message
        $ackComplete=$liveUcsi.ack_complete;$sampleMatchesPort=$liveUcsi.response_correlated
    }

    $health = 'not_typec'
    $repair = 'none'
    $summary = "EC available $availableWatts W"
    $sampleFresh=$sampleMatchesPort -and $sampleAgeSeconds -ge 0 -and $sampleAgeSeconds -le 30
    if($observation){
        if($snapshot.PowerSource-eq 'TypeC'){
            if($availableWatts-gt 65){$health='high_power';$repair='none'}
            elseif($sampleFresh -and $modeCode-eq 3){$health='pd';$repair='none'}
            else{$health='protocol_unconfirmed';$repair='observe_reconnection'}
        }
        $summary='Live EC available '+$availableWatts+' W; UCSI reported '+$mode+'; connector response correlated='+$sampleMatchesPort
        if($ackComplete){$summary+='; ACK_COMPLETE alone is not a stall diagnosis'}
    } elseif ($hardwareSuspended) {
        $health='hardware_suspended'
        $repair='deferred_for_battery_fault'
        $summary='EC transactions suspended; PnP and event logs are read-only; UCSI bytes are historical evidence'
    } elseif ($snapshot.PowerSource -eq 'TypeC') {
        if ($system.device_status -ne 'OK') {
            $health = 'controller_error'
            $repair = 'device_restart_required'
            $summary += "; UCSI device $($system.device_status)"
        } elseif ($availableWatts -gt 65) {
            $health = 'high_power'
            $repair = 'none'
            $summary += '; EC confirms high-power input'
        } elseif (-not $sampleFresh) {
            $health='probe_unavailable'
            $repair='current_sample_required'
            $summary += '; historical UCSI sample cannot establish the current PD contract'
        } elseif ($sampleMatchesPort -and $modeCode -eq 3) {
            $health = 'pd'
            $summary += '; cached UCSI mode PD'
        } elseif ($sampleMatchesPort -and $modeCode -eq 5 -and $availableWatts -le 65) {
            $recentTimeout = $false
            if ($system.last_timeout_at) {
                try { $recentTimeout = ((Get-Date) - [datetime]$system.last_timeout_at).TotalDays -lt 1 } catch {}
            }
            if ($recentTimeout -and $ackComplete) {
                $health = 'ucsi_stalled'
                $repair = 'device_restart_required'
                $summary += "; UCSI stuck at Type-C 3 A / ACK_COMPLETE; $($system.last_timeout_command) timeout"
            } else {
                $health = 'limited_3a'
                $repair = 'passive_recheck'
                $summary += '; cached UCSI mode Type-C 3 A'
            }
        } elseif ($sampleMatchesPort) {
            $health = 'non_pd'
            $repair = 'passive_recheck'
            $summary += "; cached UCSI mode $mode"
        } else {
            $health = 'probe_unavailable'
            $repair = 'passive_recheck'
            $summary += '; no current-port UCSI sample'
        }
    }

    [pscustomobject]@{
        adapter_available_w = $availableWatts
        typec_performance_priority = $(if ($null -ne $featureByte) { ($featureByte -band 1) -ne 0 } else { $null })
        performance_mode_code = $performanceMode
        ucsi_device_status = $system.device_status
        ucsi_last_timeout_at = $system.last_timeout_at
        ucsi_last_timeout_command = $system.last_timeout_command
        ucsi_version = $(if ($liveUcsi) { $version } elseif($sample) { [string]$sample.version } else { '' })
        ucsi_cci = $cci
        ucsi_control = $control
        ucsi_message = $message
        ucsi_ack_complete = $ackComplete
        ucsi_power_mode_code = $(if ($sampleFresh) { $modeCode } else { -1 })
        ucsi_power_mode = $(if ($sampleFresh) { $mode } else { 'unknown' })
        ucsi_connected = $(if ($sampleFresh) { $connected } else { $null })
        ucsi_historical_power_mode = $(if($sample){Get-UcsiPowerModeName ([int]$sample.power_opmode)}else{'unknown'})
        ucsi_sample_is_current = $sampleFresh
        ucsi_reported_power_mode=$(if($liveUcsi){$liveUcsi.reported_mode}else{'unknown'})
        ucsi_response_correlated=$sampleMatchesPort
        ucsi_ack_flags=$(if($liveUcsi){$liveUcsi.ack_flags}else{$null})
        ucsi_status_connector=$(if($liveUcsi){$liveUcsi.response_connector}else{0})
        ucsi_rdo=$(if($liveUcsi){$liveUcsi.rdo}else{$null})
        hardware_control_suspended=$hardwareSuspended
        ucsi_sample_at = $sampleTime
        ucsi_sample_age_seconds = $sampleAgeSeconds
        ucsi_sample_matches_port = $sampleMatchesPort
        typec_health = $health
        typec_repair_state = $repair
        typec_diagnostic = $summary
    }
}

function Sync-TypeCPowerRuntime($runtime, $snapshot) {
    $diagnostics = Get-TypeCPowerDiagnostics $snapshot
    foreach ($property in $diagnostics.psobject.Properties) {
        if ($runtime.psobject.Properties[$property.Name]) { $runtime.($property.Name) = $property.Value }
    }
}
