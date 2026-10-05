#requires -Version 5.1
#requires -RunAsAdministrator
param([switch]$Uninstall)
$ErrorActionPreference='Stop'
$nativeRoot=Join-Path $env:ProgramFiles 'BatteryGuardNativeStatus'
$taskName='BatteryGuard-NativeStatus'
$task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if($task){
    $expected=Join-Path $nativeRoot 'NativeProtectionHelper.ps1'
    if($task.Actions.Arguments -notlike ('*'+$expected+'*')){throw 'Existing task does not belong to BatteryGuard'}
    [IO.File]::WriteAllText((Join-Path $nativeRoot 'stop'),'stop')
    for($n=0;$n -lt 15;$n++){
        if((Get-ScheduledTask -TaskName $taskName).State -ne 'Running'){break}
        Start-Sleep -Milliseconds 500
    }
    if((Get-ScheduledTask -TaskName $taskName).State -eq 'Running'){throw 'Native helper did not finish restoring its notification'}
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
if($Uninstall){
    foreach($name in @('NativeProtectionHelper.ps1','manifest.json','ownership.json','status.json','stop')){
        $path=Join-Path $nativeRoot $name
        if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Force}
    }
    if((Test-Path -LiteralPath $nativeRoot) -and (Get-ChildItem -LiteralPath $nativeRoot -Force).Count -eq 0){Remove-Item -LiteralPath $nativeRoot}
    'Native protection helper removed'
    exit 0
}
$build=[int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
if($build -ne 26200){throw 'The native display interface has been verified only on build 26200'}
if(-not (Test-Path -LiteralPath $nativeRoot)){[void](New-Item -ItemType Directory -Path $nativeRoot)}
$acl=[Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach($identity in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')){
    $rights=if($identity -eq 'S-1-5-32-545'){'ReadAndExecute'}else{'FullControl'}
    $rule=[Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($identity),$rights,'ContainerInherit,ObjectInherit','None','Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $nativeRoot -AclObject $acl
if(Test-Path -LiteralPath (Join-Path $nativeRoot 'stop')){Remove-Item -LiteralPath (Join-Path $nativeRoot 'stop')}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'agent\NativeProtectionHelper.ps1') -Destination (Join-Path $nativeRoot 'NativeProtectionHelper.ps1') -Force
[IO.File]::WriteAllText((Join-Path $nativeRoot 'manifest.json'),(@{source_root=$PSScriptRoot;tested_build=$build;version=1}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action=New-ScheduledTaskAction -Execute $exe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $nativeRoot 'NativeProtectionHelper.ps1'))
$principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval ([TimeSpan]::FromMinutes(1))
$trigger=New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Trigger $trigger|Out-Null
Start-ScheduledTask -TaskName $taskName
'Native protection helper installed'
