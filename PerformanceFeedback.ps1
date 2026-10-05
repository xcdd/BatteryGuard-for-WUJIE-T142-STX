#requires -Version 5.1
param([switch]$Preview)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$root=$PSScriptRoot
. (Join-Path $root 'ChargeControl.ps1')
Start-ChargeObserver
Start-FanCurveWorker
Start-ChargeSupervisor
$runtimePath=Join-Path $root 'agent\performance-feedback-runtime.json'
$stopPath=Join-Path $root 'agent\performance-feedback.stop'
$previewPath=Join-Path $root 'agent\performance-feedback.preview'
$gate=[Threading.Mutex]::new($false,'Global\BatteryGuard-PerformanceFeedback')
$owned=$false
$subscriptionId='BatteryGuard-Performance-'+$PID
$script:state=[ordered]@{
    pid=$PID;started_at=(Get-Date -Format o);updated_at='';mode=-1;mode_name=''
    subscribed=$false;events_received=0;notices_shown=0;last_event_at='';last_notice_at=''
    display_mode='';display_error='';fan_phase='';fan_error='';window_visible=$false;error=''
}
$script:pendingMode=-1
$script:pendingSince=[datetime]::MinValue
$script:hideAt=[datetime]::MaxValue
$script:lastSave=[datetime]::MinValue
$script:lastSource=''
$script:lastSourceCheck=[datetime]::MinValue
$script:initialized=$false
$script:closing=$false
$modeLabels=@('性能模式','普通模式','节能模式')
$modeGlyphs=@([char]0xE945,[char]0xE713,[char]0xE8BE)
function Save-FeedbackState {
    if($window){$script:state.window_visible=[bool]$window.IsVisible}
    $script:state.updated_at=Get-Date -Format o
    $temporary=$runtimePath+'.'+$PID+'.tmp'
    [IO.File]::WriteAllText($temporary,($script:state|ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $runtimePath){[IO.File]::Replace($temporary,$runtimePath,[NullString]::Value)}else{[IO.File]::Move($temporary,$runtimePath)}
    $script:lastSave=Get-Date
}
function Queue-PerformanceNotice([int]$mode) {
    if($mode-lt 0 -or $mode-gt 2){return}
    $script:pendingMode=$mode
    $script:pendingSince=Get-Date
}
function Show-PerformanceNotice([int]$mode) {
    $label.Text=$modeLabels[$mode]
    $script:state.last_notice_text=$label.Text
    $glyph.Text=[string]$modeGlyphs[$mode]
    $script:state.mode=$mode
    $script:state.mode_name=$modeLabels[$mode]
    $bounds=[Windows.SystemParameters]::WorkArea
    $window.Left=$bounds.Left+($bounds.Width-$window.Width)/2
    $window.Top=$bounds.Bottom-$window.Height-52
    $window.Show()
    $script:hideAt=(Get-Date).AddSeconds(2)
    $script:state.notices_shown++
    $script:state.last_notice_at=Get-Date -Format o
    Save-FeedbackState
}
try {
    try{$owned=$gate.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
    if(-not $owned){exit 0}
    Add-Type -Path (Join-Path $root 'driver\DisplayRefresh.cs')
    [xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="310" Height="76" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" ShowActivated="False"
        ShowInTaskbar="False" Topmost="True" IsHitTestVisible="False">
  <Border CornerRadius="12" Background="#ED20242C" BorderBrush="#6279A0" BorderThickness="1" Padding="22,16">
    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
      <TextBlock x:Name="ModeGlyph" FontFamily="Segoe MDL2 Assets" FontSize="25" Foreground="#A7C5FF" Margin="0,0,16,0" VerticalAlignment="Center"/>
      <StackPanel>
        <TextBlock x:Name="ModeLabel" FontFamily="Microsoft YaHei UI" FontSize="18" Foreground="#FFFFFF"/>
        <TextBlock Text="FN + X" FontFamily="Segoe UI" FontSize="10" Foreground="#A8B2C2" Margin="1,2,0,0"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $reader=[Xml.XmlNodeReader]::new($xaml)
    $window=[Windows.Markup.XamlReader]::Load($reader)
    $label=$window.FindName('ModeLabel')
    $glyph=$window.FindName('ModeGlyph')
    try {
        Register-WmiEvent -Namespace root\wmi -Query 'SELECT * FROM HID_EVENT20' -SourceIdentifier $subscriptionId -ErrorAction Stop|Out-Null
        [void](Get-EventSubscriber -SourceIdentifier $subscriptionId -ErrorAction Stop)
        $script:state.subscribed=$true
    }catch{$script:state.error=$_.Exception.Message}
    $timer=[Windows.Threading.DispatcherTimer]::new()
    $timer.Interval=[TimeSpan]::FromMilliseconds(100)
    $timer.Add_Tick({
        try {
            if(Test-Path -LiteralPath $stopPath){
                $script:closing=$true;$timer.Stop();$window.Close()
                [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
                return
            }
            if($script:state.subscribed){
                foreach($event in @(Get-Event -SourceIdentifier $subscriptionId -ErrorAction SilentlyContinue)){
                    $payload=$event.SourceEventArgs.NewEvent
                    $detail=$payload.EventDetail
                    if($payload.InstanceName-eq 'ACPI\PNP0C14\MIFS_0' -and $detail.Count-ge 3 -and $detail[0]-eq 1 -and $detail[1]-eq 15){
                        $script:state.events_received++
                        $script:state.last_event_at=Get-Date -Format o
                        Queue-PerformanceNotice ([int]$detail[2])
                    }
                    Remove-Event -EventIdentifier $event.EventIdentifier
                }
            }
            if(((Get-Date)-$script:lastSourceCheck).TotalSeconds-ge 2){
                if(-not(Get-ControlObservation)){Start-ChargeObserver}
                Start-FanCurveWorker
                Start-ChargeSupervisor
                try{$fan=Read-ControlJson (Join-Path $root 'agent\fan-runtime.json');$script:state.fan_phase=$fan.phase;$script:state.fan_error=$fan.error}catch{}
                $observed=Read-ControlJson (Join-Path $root 'agent\control-live.json')
                $fresh=((Get-Date)-[datetime]$observed.time).TotalSeconds-lt 8 -and -not $observed.fault
                if($fresh){
                    $actualMode=[int]$observed.performance_mode_code
                    if(-not $script:initialized){$script:state.mode=$actualMode;$script:state.mode_name=$modeLabels[$actualMode];$script:initialized=$true}
                    elseif(-not $script:state.subscribed -and $actualMode-ne $script:state.mode){Queue-PerformanceNotice $actualMode}
                    if($observed.power_source-ne $script:lastSource){
                        try {
                            [void][BatteryGuard.DisplayRefresh]::ApplyForSource([string]$observed.power_source)
                            $script:state.display_mode=[BatteryGuard.DisplayRefresh]::CurrentSummary()
                            $script:state.display_error='';$script:lastSource=[string]$observed.power_source
                        }catch{$script:state.display_error=$_.Exception.Message}
                    }
                    # Report the current display mode, not a cached transition.
                    try{$script:state.display_mode=[BatteryGuard.DisplayRefresh]::CurrentSummary()}catch{$script:state.display_error=$_.Exception.Message}
                }
                $script:lastSourceCheck=Get-Date
                $script:state.error=''
            }
            if(Test-Path -LiteralPath $previewPath){
                Remove-Item -LiteralPath $previewPath
                if($script:state.mode-in @(0,1,2)){Queue-PerformanceNotice $script:state.mode}
            }
            if($script:pendingMode-ge 0 -and ((Get-Date)-$script:pendingSince).TotalMilliseconds-ge 400){
                Show-PerformanceNotice $script:pendingMode
                $script:pendingMode=-1
            }
            if((Get-Date)-ge $script:hideAt){$window.Hide();$script:hideAt=[datetime]::MaxValue;Save-FeedbackState}
            if(((Get-Date)-$script:lastSave).TotalSeconds-ge 5){Save-FeedbackState}
        }catch{$script:state.error=$_.Exception.Message;Save-FeedbackState}
    })
    $timer.Start()
    if($Preview){
        $observed=Read-ControlJson (Join-Path $root 'agent\control-live.json')
        Queue-PerformanceNotice ([int]$observed.performance_mode_code)
    }
    Save-FeedbackState
    [Windows.Threading.Dispatcher]::Run()
}catch{$script:state.error=$_.Exception.ToString();Save-FeedbackState;throw}
finally {
    if($timer){$timer.Stop()}
    Unregister-Event -SourceIdentifier $subscriptionId -ErrorAction SilentlyContinue
    if($owned){$gate.ReleaseMutex()}
    $gate.Dispose()
}
