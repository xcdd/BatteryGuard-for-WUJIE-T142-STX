#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess)]
param([switch]$NativeStatus)
$ErrorActionPreference='Stop'
if(-not $PSCmdlet.ShouldProcess($PSScriptRoot,'Validate dependencies, install login policies and start BatteryGuard')){return}
if($PSVersionTable.PSEdition-ne 'Desktop' -or -not[Environment]::Is64BitProcess){throw 'Use 64-bit Windows PowerShell 5.1'}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run Setup.ps1 from an administrator Windows PowerShell session'}
if((Get-CimInstance Win32_BaseBoard).Product-ne 'WUJIE Series-T142-STX'){throw 'Unsupported motherboard: only WUJIE Series-T142-STX is verified'}
if((Get-CimInstance Win32_BIOS).SMBIOSBIOSVersion-ne 'T142_STXKRK_V13'){throw 'Unsupported BIOS: this release is verified only on T142_STXKRK_V13'}
if($NativeStatus -and [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild-ne 26200){throw 'Native protection display is optional and verified only on Windows build 26200; omit -NativeStatus'}
. (Join-Path $PSScriptRoot 'DependencyPolicy.ps1')
Assert-BatteryGuardDependencies $PSScriptRoot
# A second clone must not replace the currently active installation.
$recovery=Get-ScheduledTask -TaskName 'BatteryGuard-BackgroundRecovery' -ErrorAction SilentlyContinue
$expected=Join-Path $PSScriptRoot 'BackgroundRecovery.ps1'
if($recovery -and $recovery.Actions.Arguments-notlike ('*"'+$expected+'"*')){throw 'Another BatteryGuard installation owns the login policy; uninstall it before changing clones'}
New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'agent') -Force|Out-Null
foreach($file in @('charge-settings.json','fan-settings.json')){
    $target=Join-Path $PSScriptRoot ('agent\'+$file)
    if(-not(Test-Path -LiteralPath $target)){Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('defaults\'+$file)) -Destination $target}
}
foreach($flag in @('maintenance.json','background-recovery.stop','control-observer.stop','supervisor.stop','charge-worker.stop','power-event-guard.stop','performance-feedback.stop','fan-control.stop')){
    $path=Join-Path $PSScriptRoot ('agent\'+$flag)
    if(Test-Path -LiteralPath $path){throw ('An explicit stop/maintenance flag exists: '+$flag+'. Inspect it before reinstalling; settings were preserved')}
}
& (Join-Path $PSScriptRoot 'InstallPerformanceTelemetry.ps1')
if($NativeStatus){& (Join-Path $PSScriptRoot 'InstallNativeProtection.ps1')}
. (Join-Path $PSScriptRoot 'PanelStartup.ps1')
Set-PanelStartup $true
& (Join-Path $PSScriptRoot 'InstallBackgroundRecovery.ps1')
$result=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'agent\background-recovery-install.json') -Raw|ConvertFrom-Json
if(-not $result.installed -or $result.error){throw ('Login recovery installation failed: '+$result.error)}
'Installed: automatic login policies and tray panel. Native status is opt-in. No system restart requested.'
