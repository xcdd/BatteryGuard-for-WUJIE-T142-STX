#requires -Version 5.1
param([switch]$StartHidden,[ValidateSet('Performance','Fans','Charge','Settings')][string]$Tab='Performance')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
. (Join-Path $root 'ChargeControl.ps1')
. (Join-Path $root 'FanCurvePolicy.ps1')
. (Join-Path $root 'FirmwarePowerPolicy.ps1')
. (Join-Path $root 'PanelStartup.ps1')
. (Join-Path $root 'PanelStatusPolicy.ps1')
$panelRuntimePath=Join-Path $root 'agent\panel-runtime.json'
$panelCommandPath=Join-Path $root 'agent\panel-command.json'
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$panelGate=[Threading.Mutex]::new($false,('Local\BatteryGuard-ControlPanel-'+$sid))
$panelWake=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,('Local\BatteryGuard-PanelWake-'+$sid))
$panelOwned=$false
try{$panelOwned=$panelGate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$panelOwned=$true}
if(-not $panelOwned){
    if(-not $StartHidden){
        Write-ControlJson $panelCommandPath ([ordered]@{id=[guid]::NewGuid().ToString();command='show';tab=$Tab;time=(Get-Date -Format o)})
        [void]$panelWake.Set()
    }
    $panelWake.Dispose();$panelGate.Dispose();exit 0
}
$script:panelState=[ordered]@{pid=$PID;started_at=(Get-Date -Format o);updated_at='';visible=$false;tab='Performance';tray_visible=$false;startup_enabled=$false;wake_count=0;tray_clicks=0;last_command='';firmware_budget=$null;error=''}
$script:panelState.exit_requested=$false
$script:panelState.status_text=''
$script:panelState.status_source='none'
$script:panelState.status_ok=$true
$script:panelRefreshTransient=$false
$script:panelState.exit_session=''
$script:panelExit=$false
$script:lastPanelUpdate=[datetime]::MinValue
$script:lastFeedbackRecovery=[datetime]::MinValue
$script:lastPanelCommand=''
$script:pendingProcess=$null
$script:pendingMode=$null
$script:pendingStarted=[datetime]::MinValue
$script:chargeEditorDirty=$false
$script:chargeEditorSync=$false
$script:pendingChargeRevision=''
$script:pendingChargeSince=[datetime]::MinValue
$tabNames=@('Performance','Fans','Charge','Settings')
$labels=@('性能','普通','节能')
function Save-PanelState {
    $script:panelState.updated_at=Get-Date -Format o
    $script:panelState.visible=[bool]$window.IsVisible
    $script:panelState.tab=$tabNames[$controls.Tabs.SelectedIndex]
    $script:panelState.tray_visible=[bool]$tray.Visible
    $script:panelState.startup_enabled=Test-PanelStartup
    Write-ControlJson $panelRuntimePath $script:panelState
}
function Show-ControlMessage([string]$message,[bool]$ok=$true,[string]$source='action'){
    $script:panelState.status_text=$message;$script:panelState.status_source=$source;$script:panelState.status_ok=$ok
    $controls.Status.Text=$message
    $controls.Status.Foreground=$(if($ok){'#8FD6AF'}elseif($source-eq 'refresh' -and $script:panelRefreshTransient){'#FFD487'}else{'#FFB4AB'})
}
function Show-Panel([string]$page=''){
    if($page -in $tabNames){$controls.Tabs.SelectedIndex=[Array]::IndexOf($tabNames,$page)}
    $window.Show();$window.WindowState='Normal';[void]$window.Activate()
    $script:panelState.wake_count++;Save-PanelState
}
function Hide-Panel {$window.Hide();Save-PanelState}
function Save-PanelSnapshot {
    $window.UpdateLayout()
    $render=[Windows.Media.Imaging.RenderTargetBitmap]::new([int][math]::Ceiling($window.ActualWidth),[int][math]::Ceiling($window.ActualHeight),96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $render.Render($window)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($render))
    $file=Join-Path $root ('agent\panel-'+$tabNames[$controls.Tabs.SelectedIndex]+'.png')
    $stream=[IO.File]::Create($file)
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
}
function Exit-Panel {$script:panelExit=$true;$script:panelState.exit_requested=$true;$script:panelState.exit_session=Get-PanelSessionKey;Save-PanelState;$window.Close();[Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()}
function Request-Mode([int]$mode){
    try {
        if($script:pendingProcess -and -not $script:pendingProcess.HasExited){return}
        $live=Get-ControlObservation
        if(-not $live){throw '供电信息暂不可用，请稍后重试'}
        if($mode-eq 0 -and -not $live.online){throw '离电时可使用节能或普通模式'}
        $exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $file=Join-Path $root 'FirmwarePerformanceMode.ps1'
        $script:pendingMode=$mode;$script:pendingStarted=Get-Date
        $script:pendingProcess=Start-Process -FilePath $exe -WindowStyle Hidden -ArgumentList ('-NoProfile -File "'+$file+'" -Action Set -Mode '+$mode) -PassThru
        $script:pendingHandle=$script:pendingProcess.Handle
        Show-ControlMessage ('正在切换到'+$labels[$mode]+'模式')
    }catch{Show-ControlMessage $_.Exception.Message $false}
}
function Save-ChargeEditor([bool]$togglePause=$false){
    try{
        $preferences=Get-ControlSettings
        $paused=[bool]$preferences.pause
        if($togglePause){$paused=-not $paused}
        $limit=[int]$controls.LimitSlider.Value
        $enabled=[bool]$controls.EnableLimit.IsChecked
        if(Test-Path -LiteralPath $script:HardwareBlockPath){
            throw '停充控制因 EC SMBus 冲突故障禁用；本次操作未保存，也没有停充。'
        }
        Set-ControlSettings $limit $enabled $paused
        $script:pendingChargeRevision=[string](Get-ControlSettings).revision
        $script:pendingChargeSince=Get-Date
        Show-ControlMessage '正在应用并核验充电设置…'
        $script:chargeEditorDirty=$false;Update-PerformancePanel
    }catch{Show-ControlMessage $_.Exception.Message $false}
}
function Update-PerformancePanel {
    try{
        $live=Get-ControlObservation
        if(-not $live){
            Start-ChargeObserver
            $controls.Supply.Text='实时状态暂不可用'
            $controls.Mode.Text='当前档位待确认';$controls.Performance.IsEnabled=$false
            $controls.PowerPeak.Text='功率上限待确认';$controls.Budget.Text='等待新的固件采样'
            $controls.BatteryState.Text='电池状态待确认';$controls.BatteryCurrent.Text=''
            $script:panelState.firmware_budget=$null
        }else{
            $source=switch($live.power_source){'DC'{'DC 电源'}'TypeC'{switch([int]$live.type_c_port){1{'左侧 Type-C'}2{'后侧 Type-C'}default{'Type-C'}}}'Battery'{'离电使用'}default{'外部电源'}}
            $controls.Supply.Text=$source+' · 电量 '+$live.soc+'%'
            $mode=[int]$live.performance_mode_code
            $controls.Mode.Text=$(if($mode-in @(0,1,2)){'当前：'+$labels[$mode]+'模式'}else{'当前档位待确认'})
            $controls.Performance.IsEnabled=[bool]$live.online
            $budget=Get-FirmwarePowerBudget $live
            $script:panelState.firmware_budget=$budget
            $controls.PowerPeak.Text=$(if($budget){$budget.fast_ppt_limit_w.ToString('0.#')+' W'}else{'暂不可用'})
            $controls.Budget.Text=$(if($budget){'原厂配置 · 持续 '+$budget.sustained_limit_w.ToString('0.#')+' W · '+$source}else{'等待功率上限回读'})
            $telemetryFile=Join-Path $env:ProgramFiles 'BatteryGuardPerformanceTelemetry\status.json'
            $script:panelState.power_limit=$null
            if(Test-Path -LiteralPath $telemetryFile){
                $telemetry=Read-ControlJson $telemetryFile
                $telemetryAge=((Get-Date)-[datetime]$telemetry.time).TotalSeconds
                if($telemetry.smu_readback -and -not $telemetry.error -and $telemetryAge-ge 0 -and $telemetryAge-lt 15 -and (Test-ControlProcessAlive ([int]$telemetry.pid))){
                    $controls.PowerPeak.Text=([double]$telemetry.fast_ppt_limit_w).ToString('0.#')+' W'
                    $controls.Budget.Text='当前生效 · 持续 '+([double]$telemetry.sustained_limit_w).ToString('0.#')+' W · '+$source
                    $script:panelState.power_limit=$telemetry
                }
            }
            $current=[int]$live.current_ma
            $controls.BatteryState.Text=$live.soc.ToString()+'% · '+$(if(-not $live.online){'离电使用'}elseif($current-gt 50){'正在充电'}elseif($current-lt -50){'接电 · 电池仍在放电'}else{'接电 · 未充电'})
            $watts=[math]::Round(($current*[int]$live.voltage_mv/1000000.0),1)
            $controls.BatteryCurrent.Text='实际电流 '+$current+' mA · 电池功率 '+$watts+' W'
            $tray.Text=('电池与性能管家 · '+$(if($mode-in @(0,1,2)){$labels[$mode]}else{'未知档位'})+' · '+$live.soc+'%')
        }
        $feedback=Read-ControlJson (Join-Path $root 'agent\performance-feedback-runtime.json')
        $controls.Refresh.Text='屏幕：'+$(if([string]::IsNullOrEmpty([string]$feedback.display_mode)){'读取中'}else{$feedback.display_mode})
        $fan=Read-ControlJson (Join-Path $root 'agent\fan-runtime.json')
        $fanFresh=((Get-Date)-[datetime]$fan.updated_at).TotalSeconds-lt 8 -and (Test-ControlProcessAlive ([int]$fan.pid))
        if($fanFresh){
            $phase=switch($fan.phase){'curve'{'曲线运行'}'battery_auto'{'离电 · 自动'}'mode_auto'{'当前档位 · 自动'}'thermal_auto'{'温度保护 · 自动'}'firmware_yield'{'固件接管 · 自动'}'disabled'{'自动风扇'}'error'{'风扇控制异常'}default{$fan.phase}}
            $controls.FanState.Text=$(if($fan.full_duty_requested){if($fan.full_duty_retained){'满风扇 · 100%'}else{'正在维持满风扇 · 100%'}}else{$phase+$(if($fan.requested_duty){' · 目标 '+$fan.requested_duty+'%'}else{''})})
            $controls.Thermal.Text='温度 '+$fan.temperature+'°C · '+$(if($fan.rpm_valid){'右扇 '+$fan.right_rpm+' / 左扇 '+$fan.left_rpm+' RPM'}else{'手动模式下固件不提供可靠转速'})
            if($fan.error){Show-ControlMessage $fan.error $false 'hardware'}
        }else{$controls.FanState.Text='风扇状态待确认';$controls.Thermal.Text='等待后台采样'}
        $preferences=Get-ControlSettings
        if(-not $script:chargeEditorDirty){
            $script:chargeEditorSync=$true
            $controls.EnableLimit.IsChecked=[bool]$preferences.enabled;$controls.LimitSlider.Value=[int]$preferences.limit
            $script:chargeEditorSync=$false
        }
        $controls.LimitValue.Text=([int]$controls.LimitSlider.Value).ToString()+'%'
        $blocked=Test-Path -LiteralPath $script:HardwareBlockPath
        $chargeRuntime=Get-ControlRuntime
        $chargeFresh=$chargeRuntime.updated_at -and ((Get-Date)-[datetime]$chargeRuntime.updated_at).TotalSeconds-lt 8 -and
            (Test-ControlProcessAlive ([int]$chargeRuntime.worker_pid))
        $controls.ChargeAvailability.Text=if($blocked){'充电控制故障：'+$chargeRuntime.error}elseif(-not $chargeFresh){'正在启动充电守护…'}elseif($chargeRuntime.error){'正在重试：'+$chargeRuntime.error}elseif($chargeRuntime.phase-eq 'paused'){'正在充电保护'}elseif($chargeRuntime.phase-eq 'stopping'){'正在停止充电…'}elseif($chargeRuntime.phase-eq 'battery'){'离电使用，接电后自动应用设置'}elseif($chargeRuntime.phase-eq 'waiting_for_battery'){'等待电池允许充电'}else{'正常充电已允许'}
        $script:panelState.charge_control=[ordered]@{blocked=$blocked;fresh=[bool]$chargeFresh;phase=$chargeRuntime.phase;actual_current_ma=$chargeRuntime.actual_current_ma;current_register=$chargeRuntime.current_register;controller=$chargeRuntime.controller;applied_revision=$chargeRuntime.applied_revision;error=$chargeRuntime.error}
        $controls.EnableLimit.IsEnabled=-not $blocked;$controls.LimitSlider.IsEnabled=-not $blocked
        $controls.SaveLimit.IsEnabled=-not $blocked;$controls.PauseCharge.IsEnabled=-not $blocked
        $controls.SaveLimit.Content=$(if($blocked){'停充控制不可用'}else{'应用上限'})
        $controls.PauseCharge.Content=$(if($blocked){'暂停充电不可用'}elseif($preferences.pause){'恢复充电'}else{'暂停充电'})
        $controls.ChargePreference.Text=$(if($blocked){'上次配置（尚未执行）：'}else{'当前设置：'})+$(if($preferences.enabled){'上限 '+$preferences.limit+'%'}else{'限充关闭'})+'；'+$(if($preferences.pause){'暂停开启'}else{'暂停关闭'})
        if($script:pendingChargeRevision){
            if($chargeFresh -and -not $chargeRuntime.error -and $chargeRuntime.applied_revision-eq $script:pendingChargeRevision){
                Show-ControlMessage $(if($chargeRuntime.phase-eq 'paused' -and [math]::Abs($chargeRuntime.actual_current_ma)-le 50){'已确认停充，电池电流为零'}elseif($chargeRuntime.phase-eq 'paused'){'停充控制已生效'}elseif($chargeRuntime.phase-eq 'stopping'){'已下发停充，正在等待电池电流归零'}elseif($chargeRuntime.phase-eq 'charging_allowed'){'已允许正常充电'}else{'充电设置已应用'})
                if($chargeRuntime.phase-ne 'stopping'){$script:pendingChargeRevision=''}
            }elseif(((Get-Date)-$script:pendingChargeSince).TotalSeconds-gt 10){Show-ControlMessage '尚未确认设置生效，请查看充电状态。' $false;$script:pendingChargeRevision=''}
        }
        $controls.AutoStart.IsChecked=Test-PanelStartup
        $controls.StartupState.Text=$(if($controls.AutoStart.IsChecked){'已启用：登录后驻留托盘，同时启动档位提示、刷新率同步与风扇后台。'}else{'登录自动启动未启用。'})
        if($script:pendingProcess -and $script:pendingProcess.HasExited){
            $result=Read-ControlJson (Join-Path $root 'agent\firmware-mode-result.json')
            $success=$script:pendingProcess.ExitCode-eq 0 -and [datetime]$result.time-ge $script:pendingStarted -and $result.mode_requested-eq $script:pendingMode -and $result.mode_after-eq $script:pendingMode -and -not $result.error
            $script:pendingProcess=$null
            if($success){Show-ControlMessage ('已切换到'+$labels[[int]$result.mode_after]+'模式')}
            else{Show-ControlMessage $(if($result.error){$result.error}else{'档位切换未确认'}) $false}
        }
        $recovered=Get-PanelRecoveredMessage $script:panelState.status_source
        if($recovered){$script:panelRefreshTransient=$false;Show-ControlMessage $recovered $true 'health'}
        $script:panelState.error='';Save-PanelState
    }catch{
        $script:panelRefreshTransient=(Get-PanelRefreshErrorKind $_)-eq 'transient'
        $script:panelState.error=$(if($script:panelRefreshTransient){''}else{$_.Exception.Message})
        $script:panelState.refresh_detail=$_.Exception.Message
        Show-ControlMessage $(if($script:panelRefreshTransient){'状态正在同步…'}else{'状态读取失败，请检查后台状态。'}) $false 'refresh'
        Save-PanelState
    }
}
try{
    Start-ChargeObserver;Start-ChargeSupervisor;Start-PowerEventGuard;Start-PerformanceFeedback;Start-FanCurveWorker
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase,System.Windows.Forms,System.Drawing
    [xml]$layout=[IO.File]::ReadAllText((Join-Path $root 'ui\ControlPanel.xaml'))
    $window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($layout))
    $controls=@{}
    foreach($name in @('Tabs','Supply','Mode','Quiet','Normal','Performance','PowerPeak','Budget','Refresh','EnableCurve','FanState','Thermal','Curve','SaveCurve','Auto','Status','BatteryState','BatteryCurrent','ChargeAvailability','EnableLimit','LimitValue','LimitSlider','SaveLimit','PauseCharge','ChargePreference','AutoStart','StartupState','HidePanel')){$controls[$name]=$window.FindName($name)}
    $panelFanSettingsPath=Join-Path $root 'agent\fan-settings.json'
    $settings=Read-ControlJson $panelFanSettingsPath
    $controls.EnableCurve.IsChecked=[bool]$settings.enabled
    $controls.Curve.Text=(@($settings.curve|ForEach-Object{$_.temperature.ToString()+':'+$_.duty.ToString()})-join ', ')
    $controls.AutoStart.IsChecked=Test-PanelStartup
    $controls.Tabs.SelectedIndex=[Array]::IndexOf($tabNames,$Tab)
    $tray=[Windows.Forms.NotifyIcon]::new();$tray.Icon=[Drawing.SystemIcons]::Application;$tray.Text='电池与性能管家'
    $menu=[Windows.Forms.ContextMenuStrip]::new()
    $openMenu=$menu.Items.Add('打开控制面板');$openMenu.Add_Click({Show-Panel})
    $perfMenu=$menu.Items.Add('性能');$perfMenu.Add_Click({Show-Panel 'Performance'})
    $fanMenu=$menu.Items.Add('散热');$fanMenu.Add_Click({Show-Panel 'Fans'})
    $chargeMenu=$menu.Items.Add('充电');$chargeMenu.Add_Click({Show-Panel 'Charge'})
    $settingsMenu=$menu.Items.Add('设置');$settingsMenu.Add_Click({Show-Panel 'Settings'})
    [void]$menu.Items.Add([Windows.Forms.ToolStripSeparator]::new())
    $exitMenu=$menu.Items.Add('退出界面（后台继续）');$exitMenu.Add_Click({Exit-Panel})
    $tray.ContextMenuStrip=$menu
    $tray.Add_MouseClick({param($sender,$eventArgs) if($eventArgs.Button-eq [Windows.Forms.MouseButtons]::Left){$script:panelState.tray_clicks++;Show-Panel}})
    $tray.Visible=$true
    $trayFlags=[Reflection.BindingFlags]'NonPublic,Instance'
    $notifyWindow=[Windows.Forms.NotifyIcon].GetField('window',$trayFlags).GetValue($tray)
    $script:panelState.tray_hwnd=$notifyWindow.Handle.ToInt64()
    $script:panelState.tray_id=[Windows.Forms.NotifyIcon].GetField('id',$trayFlags).GetValue($tray)
    $controls.Quiet.Add_Click({Request-Mode 2});$controls.Normal.Add_Click({Request-Mode 1});$controls.Performance.Add_Click({Request-Mode 0})
    $controls.SaveCurve.Add_Click({
        try{
            $next=Read-ControlJson $panelFanSettingsPath;$points=@()
            foreach($part in ($controls.Curve.Text -split ',')){
                if($part -notmatch '^\s*(\d+)\s*:\s*(\d+)\s*$'){throw '曲线格式应为 40:35, 50:40, 60:55'}
                $points+=@([pscustomobject]@{temperature=[int]$Matches[1];duty=[int]$Matches[2]})
            }
            $next.curve=$points;$next.enabled=[bool]$controls.EnableCurve.IsChecked;Assert-FanCurve $next
            Write-ControlJson $panelFanSettingsPath $next
            & (Join-Path $root 'FanControl.ps1') -Action $(if($next.enabled){'Enable'}else{'Auto'})|Out-Null
            Show-ControlMessage '风扇设置已保存'
        }catch{Show-ControlMessage $_.Exception.Message $false}
    })
    $controls.EnableCurve.Add_Click({try{& (Join-Path $root 'FanControl.ps1') -Action $(if($controls.EnableCurve.IsChecked){'Enable'}else{'Auto'})|Out-Null;Show-ControlMessage '风扇设置已保存'}catch{Show-ControlMessage $_.Exception.Message $false}})
    $controls.Auto.Add_Click({try{& (Join-Path $root 'FanControl.ps1') -Action Auto|Out-Null;$controls.EnableCurve.IsChecked=$false;Show-ControlMessage '已恢复自动风扇'}catch{Show-ControlMessage $_.Exception.Message $false}})
    $controls.LimitSlider.Add_ValueChanged({$controls.LimitValue.Text=([int]$controls.LimitSlider.Value).ToString()+'%';if(-not $script:chargeEditorSync){$script:chargeEditorDirty=$true}})
    $controls.EnableLimit.Add_Click({$script:chargeEditorDirty=$true;Save-ChargeEditor})
    $controls.SaveLimit.Add_Click({Save-ChargeEditor});$controls.PauseCharge.Add_Click({Save-ChargeEditor $true})
    $controls.AutoStart.Add_Click({try{Set-PanelStartup ([bool]$controls.AutoStart.IsChecked);Show-ControlMessage '登录启动设置已保存';Save-PanelState}catch{Show-ControlMessage $_.Exception.Message $false}})
    $controls.HidePanel.Add_Click({Hide-Panel})
    $window.Add_Closing({param($sender,$eventArgs) if(-not $script:panelExit){$eventArgs.Cancel=$true;Hide-Panel}})
    $window.Add_StateChanged({if($window.WindowState-eq 'Minimized'){Hide-Panel}})
    $timer=[Windows.Threading.DispatcherTimer]::new();$timer.Interval=[TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({
        if($panelWake.WaitOne(0)){
            try{
                $request=Read-ControlJson $panelCommandPath
                if($request.id-ne $script:lastPanelCommand){
                    $script:lastPanelCommand=$request.id;$script:panelState.last_command=$request.id
                    switch($request.command){'show'{Show-Panel $request.tab}'hide'{Hide-Panel}'exit'{Exit-Panel}'snapshot'{Save-PanelSnapshot}}
                }
            }catch{Show-ControlMessage $_.Exception.Message $false}
        }
        if(((Get-Date)-$script:lastFeedbackRecovery).TotalSeconds-ge 5){Start-BackgroundRecovery;Start-PerformanceFeedback;$script:lastFeedbackRecovery=Get-Date}
        if(((Get-Date)-$script:lastPanelUpdate).TotalSeconds-ge 1){Start-ChargeSupervisor;Update-PerformancePanel;$script:lastPanelUpdate=Get-Date}
    })
    Update-PerformancePanel;$timer.Start()
    if(-not $StartHidden){Show-Panel $Tab}
    [Windows.Threading.Dispatcher]::Run()
}catch{
    $script:panelState.error=$_.Exception.ToString();$script:panelState.updated_at=Get-Date -Format o
    Write-ControlJson $panelRuntimePath $script:panelState;throw
}finally{
    if($timer){$timer.Stop()}
    if($tray){$tray.Visible=$false;$tray.Dispose()};if($menu){$menu.Dispose()}
    if($panelOwned){$panelGate.ReleaseMutex()};$panelGate.Dispose();$panelWake.Dispose()
}
