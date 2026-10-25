#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$policy=Join-Path $root 'PanelPowerStatus.ps1'
if(-not(Test-Path -LiteralPath $policy)){throw 'Actual-versus-requested power-limit presentation policy is missing'}
. $policy
$now=[datetime]'2026-10-25T17:20:00Z'
$live=[pscustomobject]@{online=$true;power_source='TypeC';performance_mode_code=0;adapter_available_w=65}
$old=[pscustomobject]@{time='2026-10-25T13:21:00Z';smu_readback=$false;error='SMU table refresh failed: -4'}
$view=Get-PanelPowerStatus $live $old $false $now
if($view.verified -or $null-ne $view.fast_ppt_limit_w -or $view.requested_sustained_w-ne 80 -or $view.requested_fast_w-ne 96 -or $view.state-ne 'failed'){throw 'A stopped backend was presented as an effective 30/35 W factory limit'}
$fresh=[pscustomobject]@{time='2026-10-25T17:19:59Z';smu_readback=$true;error='';sustained_limit_w=80;fast_ppt_limit_w=96}
$view=Get-PanelPowerStatus $live $fresh $true $now
if(-not $view.verified -or $view.sustained_limit_w-ne 80 -or $view.fast_ppt_limit_w-ne 96){throw 'A fresh actual 80/96 W reading was discarded'}
$view=Get-PanelPowerStatus $live $fresh $false $now
if($view.verified -or $null-ne $view.fast_ppt_limit_w){throw 'A dead process retained a verified actual PPT'}
$fresh.time='2026-10-25T17:19:00Z'
$view=Get-PanelPowerStatus $live $fresh $true $now
if($view.verified){throw 'A stale actual limit was presented as live'}
$fresh.time='2026-10-25T17:19:59Z';$fresh.fast_ppt_limit_w=0
if((Get-PanelPowerStatus $live $fresh $true $now).verified){throw 'An invalid PPT was presented as live'}
$live.online=$false;$live.power_source='Battery';$live.performance_mode_code=1
$view=Get-PanelPowerStatus $live $null $false $now
if($view.requested_sustained_w-ne 45 -or $view.requested_fast_w-ne 54 -or $view.verified){throw 'Battery Normal target was confused with actual readback'}
'PASS: 6 power-status cases; failed, fresh, dead, stale, invalid and battery targets'
