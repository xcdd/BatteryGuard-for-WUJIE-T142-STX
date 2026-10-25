#requires -Version 5.1
param([string]$Destination=(Join-Path $PSScriptRoot 'release\battery-guard-source'))
$ErrorActionPreference='Stop'
$destinationRoot=[IO.Path]::GetFullPath($Destination)
$sourceRoot=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if($destinationRoot-eq $sourceRoot -or $sourceRoot.StartsWith($destinationRoot.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Export destination must not contain the working source'}
if(Test-Path -LiteralPath $destinationRoot){throw 'Export destination already exists; choose a new directory rather than overwrite review files'}
$files=@(
    '.gitignore','.gitattributes','LICENSE','README.md','DEPENDENCIES.md','THIRD_PARTY_NOTICES.md',
    'Setup.ps1','Uninstall.ps1','DependencyPolicy.ps1','VerifySourcePackage.ps1','BuildSourcePackage.ps1',
    'BackgroundRecovery.ps1','BatteryGuardSupervisor.ps1','ChargeControl.ps1',
    'FanControl.ps1','FanCurvePolicy.ps1','FanCurveWorker.ps1',
    'FirmwarePerformanceMode.ps1','FirmwarePowerPolicy.ps1',
    'InstallBackgroundRecovery.ps1','InstallNativeProtection.ps1','InstallPerformanceTelemetry.ps1',
    'PanelStartup.ps1','PanelStatusPolicy.ps1','PanelPowerStatus.ps1','PerformanceControl.ps1','PerformanceFeedback.ps1',
    'PowerEventGuard.ps1','PowerSourceState.ps1','TypeCPower.ps1','Start-PerformanceControl.bat','ui\ControlPanel.xaml',
    'driver\WindowsBatteryStatus.cs','driver\T142Charger.cs','driver\T142Fan.cs','driver\DisplayRefresh.cs',
    'driver\RaplPower.cs','driver\PerformancePowerPolicy.cs','driver\OemSurfaceMailbox.cs','driver\PerformanceTelemetry.cs','driver\SourceRootConfiguration.cs','driver\SmuTableRefresh.cs',
    'driver\license.txt','driver\ryzenadj\LICENSE','driver\ryzenadj\manifest.json',
    'licenses\wujie-fan-control-MIT.txt','defaults\charge-settings.json','defaults\fan-settings.json',
    'agent\ObserveChargeSession.ps1','agent\NativeProtectionHelper.ps1',
    'agent\TestSourceRootConfiguration.ps1','agent\TestPerformancePowerPolicy.ps1','agent\TestOemSurfaceMailbox.ps1',
    'agent\TestFanFullDuty.ps1','agent\VerifyFanPolicy.ps1','agent\TestRaplPower.ps1','agent\TestPanelStatusRecovery.ps1','agent\TestTrayStartupRecovery.ps1','agent\TestPanelStartupRegistry.ps1','agent\TestSmuTableRefresh.ps1','agent\TestPanelPowerStatus.ps1'
)
foreach($relative in $files){if(-not(Test-Path -LiteralPath (Join-Path $sourceRoot $relative) -PathType Leaf)){throw ('Allowlisted source is missing: '+$relative)}}
New-Item -ItemType Directory -Path $destinationRoot -Force|Out-Null
foreach($relative in $files){
    $target=Join-Path $destinationRoot $relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $sourceRoot $relative) -Destination $target
}
# Retain hardware facts used by the runtime, not the private dump's provenance/path/hash.
$table=Get-Content -LiteralPath (Join-Path $sourceRoot 'agent\firmware-power-table.json') -Raw|ConvertFrom-Json
$sanitized=[ordered]@{board=$table.board;bios=$table.bios;basis=$table.basis;packages=$table.packages}
[IO.File]::WriteAllText((Join-Path $destinationRoot 'agent\firmware-power-table.json'),($sanitized|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Join-Path $destinationRoot 'driver\x64') -Force|Out-Null
$manifest=Get-Content -LiteralPath (Join-Path $destinationRoot 'driver\ryzenadj\manifest.json') -Raw|ConvertFrom-Json
$functions=[regex]::Matches([IO.File]::ReadAllText((Join-Path $sourceRoot 'driver\PerformanceTelemetry.cs')),'extern\s+(?:IntPtr|int|uint|float)\s+((?:init_|refresh_|get_|set_)[a-z0-9_]+)\(')|ForEach-Object {$_.Groups[1].Value}|Sort-Object -Unique
$manifest.used_functions=@($functions)
[IO.File]::WriteAllText((Join-Path $destinationRoot 'driver\ryzenadj\manifest.json'),($manifest|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$exported=@(Get-ChildItem -LiteralPath $destinationRoot -File -Recurse -Force)
if($exported.Count-ne ($files.Count+1)){throw 'Unexpected export contents'}
$privatePattern='(?i)'+[regex]::Escape($env:USERNAME)+'|sess_[0-9a-f-]{20,}|C:\\Users\\'
foreach($file in $exported){
    if($file.Extension-in @('.jsonl','.dll','.sys','.exe','.png','.dmp')){throw ('Private/binary file entered the source export: '+$file.Name)}
    $content=[IO.File]::ReadAllText($file.FullName)
    if($content-match $privatePattern){throw ('Personal session/path data found in '+$file.Name)}
}
'Source-only export: '+$destinationRoot+' ('+$exported.Count+' files)'
