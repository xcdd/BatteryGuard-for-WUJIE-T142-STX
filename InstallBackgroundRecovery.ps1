#requires -Version 5.1
$ErrorActionPreference='Stop'
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scriptFile=Join-Path $PSScriptRoot 'BackgroundRecovery.ps1'
$taskName='BatteryGuard-BackgroundRecovery'
$action=New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -WindowStyle Hidden -File "'+$scriptFile+'"') -WorkingDirectory $PSScriptRoot
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$trigger=@(
    (New-ScheduledTaskTrigger -AtLogOn -User $user),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval ([TimeSpan]::FromMinutes(1)))
)
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1)) -MultipleInstances IgnoreNew
$report=[ordered]@{time=(Get-Date -Format o);task=$taskName;user=$user;installed=$false;error=''}
try{
    $existing=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($existing -and $existing.Actions.Arguments -notlike ('*'+$scriptFile+'*')){throw 'Existing task belongs to another installation'}
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force|Out-Null
    $report.installed=$true
    Start-ScheduledTask -TaskName $taskName
}catch{$report.error=$_.Exception.Message}
finally{
    . (Join-Path $PSScriptRoot 'ChargeControl.ps1')
    Write-ControlJson (Join-Path $PSScriptRoot 'agent\background-recovery-install.json') $report
    $report|ConvertTo-Json
}
