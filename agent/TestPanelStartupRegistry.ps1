#requires -Version 5.1
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'PanelStartup.ps1')
$script:fixtureRegistryKey='Registry::HKEY_USERS\'+[Security.Principal.WindowsIdentity]::GetCurrent().User.Value+'\Software\Microsoft\Windows\CurrentVersion\Run'
$script:fixtureStartupCommand='fixture command with a spaced clone path'
$script:fixtureRegisteredCommand=$script:fixtureStartupCommand
$script:PanelStartupPreferencesPath=Join-Path ([IO.Path]::GetTempPath()) ('BatteryGuard-startup-preference-'+[guid]::NewGuid().ToString('N')+'.json')
function Get-PanelStartupCommand {return $script:fixtureStartupCommand}
# Characterize the observed task boundary: HKCU returns no value while the same
# user's loaded hive contains it. No real startup preference is written here.
function Get-ItemProperty {
    param([string]$LiteralPath,[string]$Name,$ErrorAction)
    if($LiteralPath-eq $script:fixtureRegistryKey){return [pscustomobject]@{BatteryGuardPanel=$script:fixtureRegisteredCommand}}
    return $null
}
try{
    $script:fixtureRegisteredCommand=$null
    [IO.File]::WriteAllText($script:PanelStartupPreferencesPath,'{"startup_enabled":true}')
    if(-not(Test-PanelStartup)){throw 'The saved startup preference was ignored when the task could not see the Run registry entry'}
    [IO.File]::WriteAllText($script:PanelStartupPreferencesPath,'{"startup_enabled":false}')
    $script:fixtureRegisteredCommand=$script:fixtureStartupCommand
    if(Test-PanelStartup){throw 'The saved disabled preference was overridden by a legacy Run entry'}
    [IO.File]::WriteAllText($script:PanelStartupPreferencesPath,'{"startup_enabled":')
    $rejected=$false;try{[void](Test-PanelStartup)}catch{$rejected=$true}
    if(-not $rejected){throw 'A corrupt preference was silently mistaken for disabled startup'}
    Remove-Item -LiteralPath $script:PanelStartupPreferencesPath
    if(-not(Test-PanelStartup)){throw 'The visible legacy Run entry could not be read during migration'}
    $script:fixtureRegisteredCommand='a different installation'
    if(Test-PanelStartup){throw 'Another installation was treated as this panel startup entry'}
    $script:fixtureRegisteredCommand=$null
    if(Test-PanelStartup){throw 'A missing user-hive startup entry was treated as enabled'}
    'PASS: 6 startup preference cases; registry isolation, disable, corrupt preferences and legacy migration'
}finally{if(Test-Path -LiteralPath $script:PanelStartupPreferencesPath){Remove-Item -LiteralPath $script:PanelStartupPreferencesPath}}
