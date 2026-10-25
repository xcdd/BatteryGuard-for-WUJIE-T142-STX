#requires -Version 5.1
$script:PanelStartupRoot=$PSScriptRoot
$script:PanelStartupPreferencesPath=Join-Path $PSScriptRoot 'agent\panel-preferences.json'
function Get-PanelSessionKey {
    return ([string](Get-Process -Id $PID).SessionId+':'+(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o'))
}
function Get-PanelStartupCommand {
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return '"'+$exe+'" -NoProfile -STA -WindowStyle Hidden -File "'+(Join-Path $script:PanelStartupRoot 'PerformanceControl.ps1')+'" -StartHidden'
}
function Get-PanelStartupRegistryPath {
    # The Run entry is a compatibility fallback. Scheduled tasks can see a
    # different registry view even with the same SID; saved file preferences win.
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    return 'Registry::HKEY_USERS\'+$sid+'\Software\Microsoft\Windows\CurrentVersion\Run'
}
function Test-PanelStartup {
    if(Test-Path -LiteralPath $script:PanelStartupPreferencesPath){
        $saved=[IO.File]::ReadAllText($script:PanelStartupPreferencesPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
        if($null-eq $saved -or $saved.startup_enabled -isnot [bool]){throw 'Invalid saved panel startup preference'}
        return $saved.startup_enabled
    }
    $value=(Get-ItemProperty -LiteralPath (Get-PanelStartupRegistryPath) -Name BatteryGuardPanel -ErrorAction SilentlyContinue).BatteryGuardPanel
    return $value-eq (Get-PanelStartupCommand)
}
function Set-PanelStartup([bool]$enabled){
    $key=Get-PanelStartupRegistryPath
    if($enabled){
        New-Item -Path $key -Force|Out-Null
        New-ItemProperty -LiteralPath $key -Name BatteryGuardPanel -PropertyType String -Value (Get-PanelStartupCommand) -Force|Out-Null
    }else{Remove-ItemProperty -LiteralPath $key -Name BatteryGuardPanel -ErrorAction SilentlyContinue}
    $preferencesDirectory=Split-Path -Parent $script:PanelStartupPreferencesPath
    if(-not(Test-Path -LiteralPath $preferencesDirectory)){[void](New-Item -ItemType Directory -Path $preferencesDirectory -Force)}
    $temporary=$script:PanelStartupPreferencesPath+'.'+$PID+'.tmp'
    [IO.File]::WriteAllText($temporary,(@{startup_enabled=$enabled}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $script:PanelStartupPreferencesPath){[IO.File]::Replace($temporary,$script:PanelStartupPreferencesPath,[NullString]::Value)}else{[IO.File]::Move($temporary,$script:PanelStartupPreferencesPath)}
    $old=(Get-ItemProperty -LiteralPath $key -Name BatteryGuardFeedback -ErrorAction SilentlyContinue).BatteryGuardFeedback
    if($old -and $old.Contains($script:PanelStartupRoot)){Remove-ItemProperty -LiteralPath $key -Name BatteryGuardFeedback}
}
