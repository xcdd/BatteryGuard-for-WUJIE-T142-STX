#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param()
$ErrorActionPreference='Stop'
if(-not $PSCmdlet.ShouldProcess($PSScriptRoot,'Release charge protection, restore automatic fans/OEM mode, stop owned tasks and remove login entries')){return}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run from an administrator Windows PowerShell session'}
$expected=Join-Path $PSScriptRoot 'BackgroundRecovery.ps1'
$recovery=Get-ScheduledTask -TaskName 'BatteryGuard-BackgroundRecovery' -ErrorAction SilentlyContinue
if(-not $recovery -or $recovery.Actions.Arguments-notlike ('*"'+$expected+'"*')){throw 'This clone does not own the installed background policy'}
$performanceRoot=Join-Path $env:ProgramFiles 'BatteryGuardPerformanceTelemetry'
$nativeRoot=Join-Path $env:ProgramFiles 'BatteryGuardNativeStatus'
$performanceTask=Get-ScheduledTask -TaskName 'BatteryGuard-PerformanceTelemetry' -ErrorAction SilentlyContinue
if($performanceTask -and $performanceTask.Actions.Execute-ne (Join-Path $performanceRoot 'PerformanceTelemetry.exe')){throw 'Another application owns the performance task'}
$configuration=Join-Path $performanceRoot 'source-root.txt'
if((Test-Path -LiteralPath $configuration) -and [IO.File]::ReadAllText($configuration).Trim()-ne $PSScriptRoot){throw 'Performance telemetry belongs to a different clone'}
$nativeTask=Get-ScheduledTask -TaskName 'BatteryGuard-NativeStatus' -ErrorAction SilentlyContinue
if($nativeTask){
    $manifest=Get-Content -LiteralPath (Join-Path $nativeRoot 'manifest.json') -Raw|ConvertFrom-Json
    if($manifest.source_root-ne $PSScriptRoot){throw 'Native status belongs to a different clone'}
}
. (Join-Path $PSScriptRoot 'ChargeControl.ps1')
. (Join-Path $PSScriptRoot 'PanelStartup.ps1')
$settings=Get-ControlSettings
$runtime=Get-ControlRuntime
if($runtime.paused_by_us){
    $live=Get-ControlObservation
    if(-not $live -or -not $live.online){throw 'Connect external power before uninstalling so the owned charging-current setting can be restored'}
}
# Disable protection through the running worker; stopping it alone does not restore charging.
Set-ControlSettings ([int]$settings.limit) $false $false
$revision=(Get-ControlSettings).revision
$deadline=(Get-Date).AddSeconds(30)
do{
    Start-Sleep -Milliseconds 250
    $runtime=Get-ControlRuntime
    $released=$runtime.applied_revision-eq $revision -and -not $runtime.paused_by_us -and -not $runtime.error -and $runtime.phase-in @('charging_allowed','battery')
}while(-not $released -and (Get-Date)-lt $deadline)
if(-not $released){throw 'Charge-current restoration is unconfirmed. Workers were left running; inspect the Charge tab before retrying'}
# Prevent respawn before issuing cooperative stop requests.
Write-ControlJson (Join-Path $PSScriptRoot 'agent\maintenance.json') @{active=$true;expires_at=(Get-Date).AddDays(365).ToString('o');reason='uninstall'}
Set-PanelStartup $false
Write-ControlJson (Join-Path $PSScriptRoot 'agent\panel-command.json') @{id=[guid]::NewGuid().ToString();command='exit';time=(Get-Date -Format o)}
foreach($flag in @('background-recovery.stop','supervisor.stop','charge-worker.stop','performance-feedback.stop','power-event-guard.stop','fan-control.stop','control-observer.stop')){
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot ('agent\'+$flag)),'stop')
}
if($performanceTask){[IO.File]::WriteAllText((Join-Path $performanceRoot 'stop'),'stop')}
$deadline=(Get-Date).AddSeconds(30)
do{
    Start-Sleep -Milliseconds 500
    $remaining=@(Get-CimInstance Win32_Process | Where-Object {
        ($_.Name-eq 'powershell.exe' -and $_.ProcessId-ne $PID -and $_.CommandLine-like ('*"'+$PSScriptRoot+'\*')) -or
        ($performanceTask -and $_.ExecutablePath-eq (Join-Path $performanceRoot 'PerformanceTelemetry.exe'))
    })
}while($remaining.Count -and (Get-Date)-lt $deadline)
if($remaining.Count){throw 'An owned worker has not stopped. Files and tasks were preserved; no forced termination or restart performed'}
$fan=Read-ControlJson (Join-Path $PSScriptRoot 'agent\fan-runtime.json')
if($fan.owns_manual -or $fan.error){throw 'Automatic fan restoration is unconfirmed; installation files were preserved'}
if($nativeTask){& (Join-Path $PSScriptRoot 'InstallNativeProtection.ps1') -Uninstall}
# One OEM request restores the selected factory profile after the software power loop has stopped.
$mode=if([bool]$runtime.windows_ac_online){1}else{2}
& (Join-Path $PSScriptRoot 'FirmwarePerformanceMode.ps1') -Action Set -Mode $mode|Out-Null
foreach($name in @('BatteryGuard-PerformanceTelemetry','BatteryGuard-BackgroundRecovery')){
    if(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue){Unregister-ScheduledTask -TaskName $name -Confirm:$false}
}
'Policies removed; charging released; automatic fans and OEM mode restored. Source, settings and diagnostic files retained. No restart requested.'
