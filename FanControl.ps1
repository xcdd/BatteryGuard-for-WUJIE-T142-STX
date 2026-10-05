#requires -Version 5.1
param([ValidateSet('Status','Enable','Auto','Verify')][string]$Action='Status',[string]$CurveFile='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ChargeControl.ps1')
. (Join-Path $PSScriptRoot 'FanCurvePolicy.ps1')
$settingsPath=Join-Path $PSScriptRoot 'agent\fan-settings.json'
$runtimePath=Join-Path $PSScriptRoot 'agent\fan-runtime.json'
if($Action-eq 'Status'){
    @{settings=(Read-ControlJson $settingsPath);runtime=$(if(Test-Path $runtimePath){Read-ControlJson $runtimePath}else{$null})}|ConvertTo-Json -Depth 6
    return
}
if($Action-ne 'Verify'){
    $settings=Read-ControlJson $settingsPath
    if($CurveFile){$settings=Read-ControlJson $CurveFile}
    $settings.enabled=$Action-eq 'Enable'
    Assert-FanCurve $settings
    Write-ControlJson $settingsPath $settings
}
if(Test-Path $runtimePath){
    $runtime=Read-ControlJson $runtimePath
    $proc=Get-Process -Id ([int]$runtime.pid) -ErrorAction SilentlyContinue
    if($proc -and ((Get-Date)-[datetime]$runtime.updated_at).TotalSeconds-lt 8){
        if($Action-eq 'Verify'){throw 'Fan worker is already active'}
        return
    }
}
$fanWorkerScript=Join-Path $PSScriptRoot 'FanCurveWorker.ps1'
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments='-NoProfile -File "'+$fanWorkerScript+'"'+$(if($Action-eq 'Verify'){' -Verify'}else{''})
$process=Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList $arguments -PassThru
if($Action-eq 'Verify'){
    $heldHandle=$process.Handle
    if(-not $process.WaitForExit(20000)){throw 'Fan verification did not complete within 20 seconds'}
    Read-ControlJson (Join-Path $PSScriptRoot 'agent\fan-verification.json')|ConvertTo-Json -Depth 6
}
