#requires -Version 5.1
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$runtimePath = Join-Path $root 'agent\charge-runtime.json'
$statePath = Join-Path $root 'agent\supervisor-runtime.json'
$workerScript = Join-Path $root 'ChargeControl.ps1'
$hardwareBlock = Join-Path $root 'agent\hardware-access-block.json'
. (Join-Path $root 'ChargeControl.ps1')
$supervisorStopFile=Join-Path $root 'agent\supervisor.stop'
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$mutex = [Threading.Mutex]::new($false, 'Global\BatteryGuard-T142-Supervisor')
$owned = $false
$restarts = 0
$lastTick=Get-Date
$resumeGraceUntil=Get-Date
$lastRestartReason=''

function Write-SupervisorState([int]$workerPid, [string]$errorText) {
    $state = [ordered]@{ supervisor_pid=$PID; worker_pid=$workerPid; restarts=$restarts; last_restart_reason=$lastRestartReason; error=$errorText; updated_at=(Get-Date -Format o) }
    $temporary = $statePath + '.' + $PID + '.tmp'
    [IO.File]::WriteAllText($temporary, ($state | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $statePath) { [IO.File]::Replace($temporary, $statePath, [NullString]::Value) }
    else { [IO.File]::Move($temporary, $statePath) }
}

try {
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { exit 0 }
    while ($true) {
        if(Test-Path -LiteralPath $supervisorStopFile){break}
        $workerPid = 0
        $workerAlive = $false
        try {
            $now=Get-Date
            if(($now-$lastTick).TotalSeconds-gt 5){$resumeGraceUntil=$now.AddSeconds(20)}
            $lastTick=$now
            if(Test-ControlMaintenance){Write-SupervisorState 0 'Maintenance active';Start-Sleep -Seconds 2;continue}
            if (Test-Path -LiteralPath $hardwareBlock) {
                Write-SupervisorState 0 'Hardware transactions suspended after false Critical battery events'
                Start-Sleep -Seconds 2
                continue
            }
            if (Test-Path -LiteralPath $runtimePath) {
                $runtime = Get-ControlRuntime
                $workerPid = [int]$runtime.worker_pid
                $process=if($workerPid-gt 0){Get-CimInstance Win32_Process -Filter ('ProcessId='+$workerPid) -ErrorAction SilentlyContinue}else{$null}
                $workerAlive=$process -and $process.Name-eq 'powershell.exe' -and $process.CommandLine-like ('*'+$workerScript+'*') -and $process.CommandLine-like '*-Worker*'
                if($workerAlive -and $runtime.started_at){$workerAlive=[math]::Abs((([datetime]$process.CreationDate)-[datetime]$runtime.started_at).TotalSeconds)-lt 15}
                $age=if($runtime.updated_at){($now-[datetime]$runtime.updated_at).TotalSeconds}else{999}
                if($workerAlive -and $age-gt 20 -and $now-gt $resumeGraceUntil){
                    Stop-Process -Id $workerPid -Force -ErrorAction SilentlyContinue
                    $workerAlive=$false;$lastRestartReason='worker heartbeat stale'
                }
            }
            if (-not $workerAlive) {
                if(Test-Path -LiteralPath (Join-Path $root 'agent\charge-worker.stop')){Write-SupervisorState 0 'Worker explicitly stopped';Start-Sleep -Seconds 2;continue}
                if(-not $lastRestartReason){$lastRestartReason='worker process missing or identity mismatch'}
                $child = Start-Process -FilePath $powershell -WindowStyle Hidden -ArgumentList ('-NoProfile -File "'+$workerScript+'" -Worker') -PassThru
                $workerPid = $child.Id
                $restarts++
                Start-Sleep -Seconds 1
            }
            Write-SupervisorState $workerPid ''
        } catch { Write-SupervisorState $workerPid $_.Exception.Message }
        Start-Sleep -Seconds 1
    }
} finally {
    if ($owned) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
