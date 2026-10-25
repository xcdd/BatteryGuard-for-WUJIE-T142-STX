#requires -Version 5.1
if(-not ('BatteryGuard.PerformancePowerPolicy' -as [type])){
    Add-Type -Path (Join-Path $PSScriptRoot 'driver\PerformancePowerPolicy.cs')
}
function Get-PanelPowerStatus($observation,$telemetry,[bool]$processAlive,[datetime]$now=(Get-Date)) {
    $target=$null
    if($observation){$target=[BatteryGuard.PerformancePowerPolicy]::Select([bool]$observation.online,[string]$observation.power_source,[int]$observation.performance_mode_code,[int]$observation.adapter_available_w)}
    $result=[pscustomobject]@{verified=$false;state='unavailable';sustained_limit_w=$null;fast_ppt_limit_w=$null;requested_sustained_w=$null;requested_fast_w=$null;error=''}
    if($target){$result.requested_sustained_w=$target.StapmW;$result.requested_fast_w=$target.FastPptW}
    if(-not $telemetry){return $result}
    if($telemetry.error){$result.state='failed';$result.error=[string]$telemetry.error;return $result}
    if(-not $processAlive){$result.state='stopped';return $result}
    $time=[datetime]::MinValue
    if(-not [datetime]::TryParse([string]$telemetry.time,[ref]$time)){return $result}
    $age=($now.ToUniversalTime()-$time.ToUniversalTime()).TotalSeconds
    if($age-lt 0 -or $age-ge 15){$result.state='stale';return $result}
    if(-not $telemetry.smu_readback){$result.state='pending';return $result}
    $sustained=[double]$telemetry.sustained_limit_w;$fast=[double]$telemetry.fast_ppt_limit_w
    if([double]::IsNaN($sustained) -or [double]::IsNaN($fast) -or $sustained-lt 1 -or $sustained-gt 150 -or $fast-lt 1 -or $fast-gt 200){$result.state='invalid';return $result}
    $result.verified=$true;$result.state='verified';$result.sustained_limit_w=$sustained;$result.fast_ppt_limit_w=$fast
    return $result
}
