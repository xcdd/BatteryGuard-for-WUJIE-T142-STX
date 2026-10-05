#requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\driver\PerformancePowerPolicy.cs'
if(-not (Test-Path -LiteralPath $source)){
    Write-Error 'PerformancePowerPolicy is missing; power-policy mapping tests cannot pass.'
    exit 1
}
Add-Type -Path $source
$cases=@(
    @{name='battery quiet';online=$false;source='Battery';mode=2;available=0;expected='30/35/30'},
    @{name='TypeC quiet';online=$true;source='TypeC';mode=2;available=65;expected='30/35/30'},
    @{name='battery normal';online=$false;source='Battery';mode=1;available=0;expected='45/54/45'},
    @{name='TypeC normal';online=$true;source='TypeC';mode=1;available=65;expected='45/54/45'},
    @{name='battery performance rejected';online=$false;source='Battery';mode=0;available=0;expected='none'},
    @{name='TypeC performance below 45W';online=$true;source='TypeC';mode=0;available=44;expected='45/54/45'},
    @{name='TypeC performance above 44W';online=$true;source='TypeC';mode=0;available=45;expected='80/96/80'},
    @{name='current 65W TypeC budget';online=$true;source='TypeC';mode=0;available=65;expected='80/96/80'},
    @{name='100W adapter uses 96W fast tier';online=$true;source='TypeC';mode=0;available=100;expected='80/96/80'},
    @{name='DC performance';online=$true;source='DC';mode=0;available=0;expected='80/96/80'},
    @{name='unknown source remains normal-capped';online=$true;source='External';mode=0;available=120;expected='45/54/45'}
)
$failures=@()
foreach($case in $cases){
    $target=[BatteryGuard.PerformancePowerPolicy]::Select([bool]$case.online,[string]$case.source,[int]$case.mode,[int]$case.available)
    $actual=if($null-eq $target){'none'}else{'{0}/{1}/{2}' -f $target.StapmW,$target.FastPptW,$target.SlowPptW}
    if($actual-ne $case.expected){$failures+=@("$($case.name): expected $($case.expected), got $actual")}
    if($target -and ($null-eq $target.SkinPowerW -or $target.SkinPowerW-ne $target.StapmW)){
        $failures+=@("$($case.name): firmware ALIB 0x2E power constraint must follow the selected sustained package")
    }
    if($target){
        if($null-eq $target.ApuSlowW -or $target.ApuSlowW-ne [int]($case.expected.Split('/')[2])){
            $failures+=@("$($case.name): independent APU slow limit must not retain a lower previous-mode ceiling")
        }
        $performance=$actual-eq '80/96/80'
        $surface=if($performance){15360}else{10752}
        $thermal=if($performance){99}elseif($actual-eq '30/35/30'){90}else{96}
        if($target.FactorySurfaceRaw-ne $surface -or $target.FactoryThermalC-ne $thermal){
            $failures+=@("$($case.name): selected OEM surface/thermal profile was not restored")
        }
    }
}
if($failures.Count){$failures|ForEach-Object{Write-Error $_};exit 1}
"PASS: $($cases.Count) power-policy mapping cases"
$target=[BatteryGuard.PerformancePowerPolicy]::Select($true,'TypeC',0,65)
$readbacks=@(
 @{v=@(80,96,80,80,99);want='Matched'},
 @{v=@(30,35,30,45,90);want='FirmwareChanged'},
 @{v=@(80,96,80,45,99);want='FirmwareChanged'},
 @{v=@(80,96,80,80,90);want='FirmwareChanged'},
 @{v=@(0,96,80,80,99);want='Invalid'},
 @{v=@([float]::NaN,96,80,80,99);want='Invalid'}
)
foreach($case in $readbacks){
 $v=$case.v
 $result=[BatteryGuard.PerformancePowerPolicy]::ClassifyReadback($target,[float]$v[0],[float]$v[1],[float]$v[2],[float]$v[3],[float]$v[4]).ToString()
 if($result-ne $case.want){throw "Readback classification: expected $($case.want), got $result"}
}
'PASS: 6 readback cases separate valid firmware changes from invalid/native data'
