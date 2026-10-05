$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\driver\OemSurfaceMailbox.cs'
$policySource=Join-Path $PSScriptRoot '..\driver\PerformancePowerPolicy.cs'
if(-not(Test-Path $source)){throw 'The OEM surface mailbox adapter is missing'}
$testSource=@'
public sealed class TestSurfaceMailbox : BatteryGuard.IOemMailbox {
 public uint Response=1,Completion=1;
 public System.Collections.Generic.List<uint> Addresses=new System.Collections.Generic.List<uint>(),Values=new System.Collections.Generic.List<uint>();
 public uint Read(uint address){return Response;}
 public void Write(uint address,uint value){Addresses.Add(address);Values.Add(value);if(address==0x03B10978)Response=value;if(address==0x03B10928)Response=Completion;}
}
'@
Add-Type -TypeDefinition ((Get-Content -Raw $source)+[Environment]::NewLine+(Get-Content -Raw $policySource).Replace('using System;','')+[Environment]::NewLine+$testSource)
$busy=[TestSurfaceMailbox]::new();$busy.Response=0;$rejected=$false
try{[BatteryGuard.OemSurfaceMailbox]::Apply($busy,15360)}catch{$rejected=$true}
if(-not $rejected -or $busy.Addresses.Count-ne 0){throw 'Busy firmware must receive no writes'}
$ok=[TestSurfaceMailbox]::new();[BatteryGuard.OemSurfaceMailbox]::Apply($ok,15360)
if($ok.Addresses.Count-ne 8 -or $ok.Addresses[1]-ne 0x03B10998 -or $ok.Values[1]-ne 15360 -or $ok.Addresses[7]-ne 0x03B10928 -or $ok.Values[7]-ne 0x33){throw 'OEM channel/message/raw argument mapping is wrong'}
$bad=[TestSurfaceMailbox]::new();$bad.Completion=0xFE;$rejected=$false
try{[BatteryGuard.OemSurfaceMailbox]::Apply($bad,15360)}catch{$rejected=$true}
if(-not $rejected -or $bad.Addresses.Count-ne 8){throw 'A rejected message must fail once without retransmission'}
'PASS: 3 OEM surface mailbox protocol cases'
# The omitted OEM fields must reach the actual transport in factory order.
# Fixtures are copied independently from this board's THMP[0]/[1]/[4] and A032.
$fixtures=@(
 @{mode=0;commands=@(0x14,0x15,0x16,0x18,0x1A,0x1C,0x1B,0x1D,0x20,0x17,0x19,0x37,0x38,0x3D,0x31,0x35,0x36,0x4A,0x33);raw=@(80000,96000,80000,300,80000,140000,30000,45000,160000,30,99,78,704,1716,1638,131,9830,80000,15360)},
 @{mode=1;commands=@(0x14,0x15,0x16,0x18,0x1A,0x1C,0x1B,0x1D,0x20,0x17,0x19,0x37,0x38,0x3D,0x31,0x35,0x36,0x4A,0x33);raw=@(45000,54000,45000,300,80000,140000,30000,45000,160000,30,96,87,662,2066,6554,33,9830,45000,10752)},
 @{mode=2;commands=@(0x14,0x15,0x16,0x18,0x1A,0x1C,0x1B,0x1D,0x20,0x17,0x19,0x37,0x38,0x3D,0x31,0x35,0x36,0x4A,0x33);raw=@(30000,35000,30000,50,80000,140000,30000,45000,80000,15,90,164,363,4219,3277,33,9830,30000,10752)},
 @{mode=1;online=$false;commands=@(0x14,0x15,0x16,0x18,0x1A,0x1C,0x1B,0x1D,0x20,0x17,0x19,0x37,0x38,0x3D,0x31,0x35,0x36,0x4A,0x33);raw=@(45000,54000,45000,100,80000,140000,30000,45000,120000,30,96,87,662,2066,6554,33,9830,45000,10752)}
)
foreach($fixture in $fixtures){
 $transport=[TestSurfaceMailbox]::new()
 $online=if($fixture.ContainsKey('online')){[bool]$fixture.online}else{$true}
 $target=[BatteryGuard.PerformancePowerPolicy]::Select($online,$(if($online){'TypeC'}else{'Battery'}),$fixture.mode,$(if($online){65}else{0}))
 [BatteryGuard.OemSurfaceMailbox]::ApplyProfile($transport,$target)
 if($transport.Addresses.Count-ne 152){throw 'A complete OEM profile must send 19 single-argument requests'}
 for($n=0;$n-lt 19;$n++){
  $offset=$n*8
  if($transport.Addresses[$offset]-ne 0x03B10978 -or $transport.Values[$offset]-ne 0 -or $transport.Values[$offset+1]-ne $fixture.raw[$n] -or $transport.Values[$offset+7]-ne $fixture.commands[$n]){throw "Mode $($fixture.mode) factory request $n was omitted, reordered or changed"}
  for($arg=2;$arg-le 6;$arg++){if($transport.Values[$offset+$arg]-ne 0){throw 'OEM reserved arguments must remain zero'}}
 }
}
$blocked=[TestSurfaceMailbox]::new();$blocked.Completion=0xFE;$rejected=$false
try{[BatteryGuard.OemSurfaceMailbox]::ApplyProfile($blocked,[BatteryGuard.PerformancePowerPolicy]::Select($true,'TypeC',0,65))}catch{$rejected=$true}
if(-not $rejected -or $blocked.Addresses.Count-ne 8){throw 'An OEM profile failure must stop after its first failed request without retrying or sending remaining fields'}
'PASS: 4 complete OEM profile mappings and failure-abort case'
