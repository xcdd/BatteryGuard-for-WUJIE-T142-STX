$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'FanCurvePolicy.ps1')
$settingsFile=Join-Path $root 'defaults\fan-settings.json'
$settings=Get-Content -LiteralPath $settingsFile -Raw|ConvertFrom-Json
Assert-FanCurve $settings
$previous=0
foreach($temperature in 20..110){$value=Get-FanCurveDuty $settings $temperature;if($value-lt $previous -or $value-lt 35 -or $value-gt 100){throw 'Curve violates monotonic bounds'};$previous=$value}
if((Get-FanCurveDuty $settings 65)-ne 63){throw 'Curve interpolation failed'}
$snapshot=[pscustomobject]@{Online=$false;Mode=0;Temperature=55}
if((Get-FanControlDecision $settings $snapshot ([datetime]::MinValue))-ne 'battery_auto'){throw 'Manual curve ran on battery'}
$snapshot.Online=$true;$snapshot.Mode=1
if((Get-FanControlDecision $settings $snapshot ([datetime]::MinValue))-ne 'mode_auto'){throw 'Manual curve ran outside performance mode'}
$snapshot.Mode=0
foreach($temperature in @(85,90,99,110)){
 $snapshot.Temperature=$temperature
 if((Get-FanControlDecision $settings $snapshot ((Get-Date).AddSeconds(10)))-ne 'curve' -or (Get-FanCurveDuty $settings $temperature)-ne 100){throw 'Performance full-duty cooling was abandoned in the hot region'}
}
$reduced=$settings|ConvertTo-Json -Depth 5|ConvertFrom-Json
$reduced.maximum_duty=95
foreach($point in $reduced.curve){if($point.duty-gt 95){$point.duty=95}}
$snapshot.Temperature=91
if((Get-FanControlDecision $reduced $snapshot ([datetime]::MinValue))-ne 'thermal_auto'){throw 'A reduced curve must still hand off at its thermal threshold'}
$snapshot.Temperature=60
if((Get-FanControlDecision $settings $snapshot ((Get-Date).AddSeconds(10)))-ne 'firmware_yield'){throw 'Firmware takeover cooldown was bypassed'}
if((Get-FanControlDecision $settings $snapshot ([datetime]::MinValue))-ne 'curve'){throw 'Performance curve was not selected'}
$bad=$settings|ConvertTo-Json -Depth 5|ConvertFrom-Json;$bad.curve[2].duty=25
$rejected=$false;try{Assert-FanCurve $bad}catch{$rejected=$true};if(-not $rejected){throw 'A decreasing fan curve was accepted'}
'Fan policy: full-duty hot control, interpolation, bounds, source/mode gating, reduced-curve takeover and malformed-curve checks passed'
