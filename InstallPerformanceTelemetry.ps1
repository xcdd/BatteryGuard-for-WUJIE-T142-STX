#requires -Version 5.1
#requires -RunAsAdministrator
$ErrorActionPreference='Stop'
$destination=Join-Path $env:ProgramFiles 'BatteryGuardPerformanceTelemetry'
$taskName='BatteryGuard-PerformanceTelemetry'
$installResult=Join-Path $PSScriptRoot 'agent\performance-telemetry-install.json'
$report=[ordered]@{time=(Get-Date -Format o);destination=$destination;task=$taskName;success=$false;error=''}
try{
    if((Get-CimInstance Win32_BaseBoard).Product-ne 'WUJIE Series-T142-STX'){throw 'Unsupported motherboard'}
    . (Join-Path $PSScriptRoot 'DependencyPolicy.ps1')
    Assert-BatteryGuardDependencies $PSScriptRoot
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $application=Join-Path $destination 'PerformanceTelemetry.exe'
    if(Test-Path -LiteralPath $destination){
        [IO.File]::WriteAllText((Join-Path $destination 'stop'),'stop')
        for($i=0;$i-lt 30;$i++){
            $running=@(Get-CimInstance Win32_Process -Filter "Name='PerformanceTelemetry.exe'"|Where-Object ExecutablePath -eq $application)
            if($running.Count-eq 0){break};Start-Sleep -Milliseconds 250
        }
        if($running.Count-gt 0){throw 'Existing telemetry process did not stop'}
    }
    if($task){
        if($task.Actions.Execute-ne $application){throw 'Existing task does not belong to this application'}
        [IO.File]::WriteAllText((Join-Path $destination 'stop'),'stop')
        for($i=0;$i-lt 20;$i++){if((Get-ScheduledTask -TaskName $taskName).State-ne 'Running'){break};Start-Sleep -Milliseconds 250}
        if((Get-ScheduledTask -TaskName $taskName).State-eq 'Running'){throw 'Existing telemetry did not stop'}
    }
    New-Item -ItemType Directory -Path $destination -Force|Out-Null
    $acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    foreach($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-32-545')){
        $rights=if($sid-eq 'S-1-5-32-545'){'ReadAndExecute'}else{'FullControl'}
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),$rights,'ContainerInherit,ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $destination -AclObject $acl
    $vendor=Join-Path $PSScriptRoot 'driver\ryzenadj'
    $manifest=Get-Content (Join-Path $vendor 'manifest.json') -Raw|ConvertFrom-Json
    foreach($file in $manifest.files){
        $source=Join-Path $vendor $file.name
        Copy-Item -LiteralPath $source -Destination (Join-Path $destination $file.name) -Force
    }
    if(Test-Path -LiteralPath $application){Remove-Item -LiteralPath $application}
    [IO.File]::WriteAllText((Join-Path $destination 'source-root.txt'),$PSScriptRoot,[Text.UTF8Encoding]::new($false))
    $sources=@((Join-Path $PSScriptRoot 'driver\SourceRootConfiguration.cs'),(Join-Path $PSScriptRoot 'driver\PerformancePowerPolicy.cs'),(Join-Path $PSScriptRoot 'driver\RaplPower.cs'),(Join-Path $PSScriptRoot 'driver\OemSurfaceMailbox.cs'),(Join-Path $PSScriptRoot 'driver\PerformanceTelemetry.cs'))
    Add-Type -Path $sources -ReferencedAssemblies System.dll,System.Management.dll,System.Web.Extensions.dll -OutputAssembly $application -OutputType WindowsApplication
    if(Test-Path -LiteralPath (Join-Path $destination 'stop')){Remove-Item -LiteralPath (Join-Path $destination 'stop')}
    $action=New-ScheduledTaskAction -Execute $application
    $user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $user) -Settings $settings -Force|Out-Null
    Start-ScheduledTask -TaskName $taskName
    $deadline=(Get-Date).AddSeconds(15)
    do{
        Start-Sleep -Milliseconds 500
        $statusFile=Join-Path $destination 'status.json'
        if(Test-Path -LiteralPath $statusFile){
            $status=Get-Content -LiteralPath $statusFile -Raw|ConvertFrom-Json
            if([datetime]$status.time -ge [datetime]$report.time){
                if($status.error){throw ('Installed telemetry failed to start: '+$status.error)}
                if($status.smu_readback -and (Get-ScheduledTask -TaskName $taskName).State-eq 'Running'){break}
            }
        }
    }while((Get-Date)-lt $deadline)
    if(-not $status.smu_readback -or (Get-ScheduledTask -TaskName $taskName).State-ne 'Running'){throw 'Installed telemetry did not publish a verified live sample'}
    $report.success=$true
}catch{$report.error=$_.Exception.ToString();throw}
finally{[IO.File]::WriteAllText($installResult,($report|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))}
