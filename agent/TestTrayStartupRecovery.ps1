#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('BatteryGuard-tray-recovery-'+[guid]::NewGuid().ToString('N'))
$agent=Join-Path $fixture 'agent'
New-Item -ItemType Directory -Path $agent -Force|Out-Null
$utf=[Text.UTF8Encoding]::new($false)
try{
    Copy-Item -LiteralPath (Join-Path $root 'BackgroundRecovery.ps1') -Destination $fixture
    $charge=@'
function Test-ControlMaintenance {return $false}
function Start-ChargeObserver {throw 'fixture: observation unavailable during logon'}
function Start-ChargeSupervisor {}
function Start-PowerEventGuard {}
function Start-PerformanceFeedback {}
function Start-FanCurveWorker {}
function Get-ControlObservation {return $null}
function Read-ControlJson($path) {Get-Content -LiteralPath $path -Raw|ConvertFrom-Json}
function Write-ControlJson($path,$value) {[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 6))}
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'ChargeControl.ps1'),$charge,$utf)
    $startup=@'
function Test-PanelStartup {return $true}
function Get-PanelStartupCommand {return 'fixture-startup-command'}
function Get-PanelStartupRegistryPath {return 'Registry::HKEY_CURRENT_USER\Software\BatteryGuardMissingFixture'}
function Get-PanelSessionKey {return 'fixture-current-logon'}
'@
    [IO.File]::WriteAllText((Join-Path $fixture 'PanelStartup.ps1'),$startup,$utf)
    [IO.File]::WriteAllText((Join-Path $fixture 'PerformanceControl.ps1'),'param([switch]$StartHidden); [IO.File]::WriteAllText((Join-Path $PSScriptRoot "agent\panel-started"),[string][bool]$StartHidden)',$utf)
    $fixtureSource=[IO.File]::ReadAllText((Join-Path $fixture 'BackgroundRecovery.ps1'))
    # Isolate only the process-wide owner name so this fixture cannot affect the real guard.
    $fixtureSource=$fixtureSource.Replace('Global\BatteryGuard-BackgroundRecovery','Local\BatteryGuard-RecoveryFixture-'+[guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText((Join-Path $fixture 'BackgroundRecovery.ps1'),$fixtureSource,$utf)
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $count=0
    foreach($case in @('no cached panel','corrupt cached panel','explicit exit in same logon')){
        $marker=Join-Path $agent 'panel-started'
        if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $marker}
        $runtime=Join-Path $agent 'panel-runtime.json'
        if($case-eq 'corrupt cached panel'){[IO.File]::WriteAllText($runtime,'{"pid":',$utf)}
        elseif($case-eq 'explicit exit in same logon'){[IO.File]::WriteAllText($runtime,'{"pid":0,"exit_requested":true,"exit_session":"fixture-current-logon"}',$utf)}
        & $exe -NoProfile -File (Join-Path $fixture 'BackgroundRecovery.ps1') -Once
        if($LASTEXITCODE-ne 0){throw 'Recovery cycle exited unexpectedly'}
        $state=Get-Content -LiteralPath (Join-Path $agent 'background-recovery.json') -Raw|ConvertFrom-Json
        if($case-eq 'explicit exit in same logon'){
            if($state.started-contains 'panel'){throw 'An explicit panel exit was ignored'}
        }else{
            if($state.started-notcontains 'panel'){throw ($case+': unavailable hardware prevented tray recovery')}
            $deadline=(Get-Date).AddSeconds(8)
            while(-not(Test-Path -LiteralPath $marker) -and (Get-Date)-lt $deadline){Start-Sleep -Milliseconds 100}
            if(-not(Test-Path -LiteralPath $marker) -or [IO.File]::ReadAllText($marker)-ne 'True'){throw ($case+': hidden panel was not actually launched')}
        }
        if($state.error-notmatch 'observation unavailable'){throw 'Hardware startup failure was hidden'}
        $count++
    }
    'PASS: '+$count+' isolated tray recovery cases; real hidden child launch, corrupt cache and explicit exit'
}finally{
    $absolute=[IO.Path]::GetFullPath($fixture)
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $absolute.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup escaped temp'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
