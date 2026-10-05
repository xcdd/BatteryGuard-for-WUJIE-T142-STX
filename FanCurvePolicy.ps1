function Test-FanWorkerRecoveryAllowed($state,[datetime]$bootTime){
    if(-not $state -or -not $state.error){return $true}
    if(-not $state.updated_at){return $false}
    try{return [datetime]$state.updated_at-lt $bootTime}catch{return $false}
}
function Assert-FanCurve($settings) {
    if([int]$settings.minimum_duty-lt 25 -or [int]$settings.maximum_duty-gt 100 -or
        [int]$settings.minimum_duty-gt [int]$settings.maximum_duty){throw 'Fan duty bounds must be 25-100'}
    if([int]$settings.firmware_takeover_temperature-lt 85 -or [int]$settings.firmware_takeover_temperature-gt 95){throw 'Invalid firmware takeover temperature'}
    $points=@($settings.curve)
    if($points.Count-lt 2 -or $points.Count-gt 16){throw 'A fan curve requires 2-16 points'}
    $previousTemperature=-1;$previousDuty=-1
    foreach($point in $points){
        $t=[double]$point.temperature;$d=[double]$point.duty
        if($t-lt 20 -or $t-gt 100 -or $t-le $previousTemperature){throw 'Curve temperatures must increase within 20-100 C'}
        if($d-lt [int]$settings.minimum_duty -or $d-gt [int]$settings.maximum_duty -or $d-lt $previousDuty){throw 'Curve duty must increase within the configured bounds'}
        $previousTemperature=$t;$previousDuty=$d
    }
}
function Get-FanCurveDuty($settings,[double]$temperature) {
    if([double]::IsNaN($temperature) -or $temperature-lt 0 -or $temperature-gt 125){throw 'Invalid temperature measurement'}
    $points=@($settings.curve)
    if($temperature-le [double]$points[0].temperature){return [int]$points[0].duty}
    for($i=1;$i-lt $points.Count;$i++){
        if($temperature-le [double]$points[$i].temperature){
            $lower=$points[$i-1];$upper=$points[$i]
            $value=[double]$lower.duty+($temperature-[double]$lower.temperature)*([double]$upper.duty-[double]$lower.duty)/([double]$upper.temperature-[double]$lower.temperature)
            return [int][math]::Ceiling($value)
        }
    }
    return [int]$points[-1].duty
}
function Get-FanControlDecision($settings,$snapshot,[datetime]$yieldUntil) {
    if(-not $settings.enabled){return 'disabled'}
    if(-not $snapshot.Online){return 'battery_auto'}
    if($settings.performance_mode_only -and $snapshot.Mode-ne 0){return 'mode_auto'}
    $fullDuty=(Get-FanCurveDuty $settings $snapshot.Temperature)-eq 100
    if($snapshot.Temperature-ge [int]$settings.firmware_takeover_temperature -and -not $fullDuty){return 'thermal_auto'}
    if((Get-Date)-lt $yieldUntil -and -not $fullDuty){return 'firmware_yield'}
    return 'curve'
}
