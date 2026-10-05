#requires -Version 5.1
param(
    [ValidateSet('Read','Set')][string]$Action='Read',
    [ValidateRange(0,2)][int]$Mode=0,
    [switch]$ElevatedChild
)
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$resultPath=Join-Path $root 'agent\firmware-mode-result.json'
$modeNames=@('Performance','Normal','Quiet')
$isAdmin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if($Action-eq'Read' -and -not $isAdmin){
    $cached=Join-Path $root 'agent\firmware-interface-read.json'
    if(-not(Test-Path -LiteralPath $cached)){throw 'Administrator read is required and no cached firmware read is available'}
    $raw=Get-Content -LiteralPath $cached -Raw|ConvertFrom-Json
    $row=@($raw.reads)|Where-Object name -eq 'performance_mode'|Select-Object -First 1
    $bytes=$row.output -split '-'
    $cachedMode=[Convert]::ToInt32($bytes[4],16)
    [pscustomobject]@{time=(Get-Date -Format o);observed_at=$raw.time;action='Read';source='cached-admin-read';mode_after=$cachedMode;mode_name=$modeNames[$cachedMode];read=$row}|ConvertTo-Json -Compress
    exit 0
}
if($Action-eq'Set' -and -not $isAdmin){
    $requestStarted=Get-Date
    $arguments='-NoProfile -File "'+$PSCommandPath+'" -Action Set -Mode '+$Mode+' -ElevatedChild'
    $child=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -PassThru
    $childHandle=$child.Handle
    $child.WaitForExit()
    if($child.ExitCode-ne 0){throw ('Firmware mode command did not succeed (exit '+$child.ExitCode+'); no successful readback is being reported')}
    $result=Get-Content $resultPath -Raw|ConvertFrom-Json
    if($result.error){throw $result.error}
    if([datetime]$result.time-lt $requestStarted -or $result.action-ne 'Set' -or
        $result.mode_requested-ne $Mode -or $result.mode_after-ne $Mode){throw 'Firmware mode result is stale or does not confirm this request'}
    $result|ConvertTo-Json -Depth 6 -Compress
    exit 0
}
$firmwareGate=[Threading.Mutex]::new($false,'Global\BatteryGuard-FirmwarePowerAccess')
$firmwareOwned=$false
$modeBefore=$null
$write=$null
try{
    try{$firmwareOwned=$firmwareGate.WaitOne(10000)}catch [Threading.AbandonedMutexException]{$firmwareOwned=$true}
    if(-not $firmwareOwned){throw 'Firmware power access is busy; no mode command was sent'}
$class=[System.Management.ManagementClass]::new('root\wmi:MICommonInterface')
$enumeration=[System.Management.EnumerationOptions]::new()
$enumeration.Timeout=[TimeSpan]::FromSeconds(5)
$instances=@($class.GetInstances($enumeration))
if($instances.Count-ne 1){throw "Expected one MICommonInterface instance; found $($instances.Count)"}
$instance=$instances[0]
function Invoke-Firmware([uint16]$Function1,[uint16]$Function2,[byte]$Function3=0){
    [byte[]]$payload=New-Object byte[] 32
    [Array]::Copy([BitConverter]::GetBytes($Function1),0,$payload,0,2)
    [Array]::Copy([BitConverter]::GetBytes($Function2),0,$payload,2,2)
    $payload[4]=$Function3
    $parameters=$instance.GetMethodParameters('MiInterface')
    $parameters['InData']=[byte[]]$payload
    $invokeOptions=[System.Management.InvokeMethodOptions]::new()
    $invokeOptions.Timeout=[TimeSpan]::FromSeconds(5)
    try{
        $result=$instance.InvokeMethod('MiInterface',$parameters,$invokeOptions)
    }catch{
        # A failed firmware call must not race further SMU requests.
        [IO.File]::WriteAllText((Join-Path $env:ProgramFiles 'BatteryGuardPerformanceTelemetry\stop'),'firmware method failed; automatic hardware retry is disabled')
        throw
    }
    [byte[]]$response=$result['OutData']
    if($response.Length-lt 6 -or [BitConverter]::ToUInt16($response,0)-ne 0x8000){throw 'Firmware did not report success'}
    if($Function1-eq 0xFA00 -and [BitConverter]::ToUInt16($response,2)-ne $Function2){throw 'Firmware returned a different function response'}
    [pscustomobject]@{input=[BitConverter]::ToString($payload);output=[BitConverter]::ToString($response);reserved=$result['Reserved']}
}
$before=Invoke-Firmware 0xFA00 0x0800
$modeBefore=[Convert]::ToInt32((($before.output -split '-')[4]),16)
$write=$null
if($Action-eq'Set'){
    $battery=Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus
    if($Mode-eq 0 -and -not $battery.PowerOnline){throw 'Performance mode is unavailable on battery; use normal or quiet'}
    if($battery.Critical){throw 'Performance changes suspended while Windows reports Critical battery'}
    $write=Invoke-Firmware 0xFB00 0x0800 ([byte]$Mode)
}
$after=if($write){Invoke-Firmware 0xFA00 0x0800}else{$before}
$afterBytes=$after.output -split '-'
$result=[ordered]@{time=(Get-Date -Format o);action=$Action;mode_requested=$(if($Action-eq'Set'){$Mode}else{$null});mode_before=$modeBefore;mode_after=[Convert]::ToInt32($afterBytes[4],16);read_before=$before;write=$write;read_after=$after;instance=[string]$instance.Path.Path}
$result.mode_name=$modeNames[$result.mode_after]
$result.error=''
if($Action-eq'Set' -and $result.mode_after-ne $Mode){$result.error='Firmware mode read-back did not match the request'}
[IO.File]::WriteAllText($resultPath,($result|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
$result|ConvertTo-Json -Compress
if($result.error){exit 1}
}catch{
    $failure=[ordered]@{time=(Get-Date -Format o);action=$Action;mode_requested=$(if($Action-eq 'Set'){$Mode}else{$null});mode_before=$modeBefore;mode_after=$null;write=$write;error=$_.Exception.Message}
    [IO.File]::WriteAllText($resultPath,($failure|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
    throw
}finally{
    if($firmwareOwned){$firmwareGate.ReleaseMutex()}
    $firmwareGate.Dispose()
}
