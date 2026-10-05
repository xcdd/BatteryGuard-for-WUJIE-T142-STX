#requires -Version 5.1
$script:PanelStartupRoot=$PSScriptRoot
function Get-PanelSessionKey {
    return ([string](Get-Process -Id $PID).SessionId+':'+(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o'))
}
function Get-PanelStartupCommand {
    $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return '"'+$exe+'" -NoProfile -STA -WindowStyle Hidden -File "'+(Join-Path $script:PanelStartupRoot 'PerformanceControl.ps1')+'" -StartHidden'
}
function Test-PanelStartup {
    $value=(Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name BatteryGuardPanel -ErrorAction SilentlyContinue).BatteryGuardPanel
    return $value-eq (Get-PanelStartupCommand)
}
function Set-PanelStartup([bool]$enabled){
    $key='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if($enabled){
        New-Item -Path $key -Force|Out-Null
        New-ItemProperty -LiteralPath $key -Name BatteryGuardPanel -PropertyType String -Value (Get-PanelStartupCommand) -Force|Out-Null
    }else{Remove-ItemProperty -LiteralPath $key -Name BatteryGuardPanel -ErrorAction SilentlyContinue}
    $old=(Get-ItemProperty -LiteralPath $key -Name BatteryGuardFeedback -ErrorAction SilentlyContinue).BatteryGuardFeedback
    if($old -and $old.Contains($script:PanelStartupRoot)){Remove-ItemProperty -LiteralPath $key -Name BatteryGuardFeedback}
}
