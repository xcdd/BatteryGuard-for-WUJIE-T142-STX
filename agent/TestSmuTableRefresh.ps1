#requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\driver\SmuTableRefresh.cs'
if(-not(Test-Path -LiteralPath $source)){throw 'SMU table-transfer rejection classification is missing'}
$fixture=@'
public static class SmuTableFixture {
 public static void Run() {
  int calls=0;bool deferred=false;
  try {BatteryGuard.SmuTableRefresh.Refresh(delegate {calls++;return -4;});}
  catch(BatteryGuard.SmuTableTransferDeferredException) {deferred=true;}
  if(!deferred||calls!=1)throw new System.Exception("A rejected transfer must defer after one native call, without a retry or remap");
  BatteryGuard.SmuTableRefresh.Refresh(delegate {calls++;return 0;});
  if(calls!=2)throw new System.Exception("The next ordinary poll must be able to reuse the existing session");
  foreach(int code in new int[]{-2,-3,-5}) {
   int count=0;bool fatal=false;
   try {BatteryGuard.SmuTableRefresh.Refresh(delegate {count++;return code;});}
   catch(BatteryGuard.SmuTableTransferDeferredException) {throw new System.Exception("A timeout, unsupported request or memory failure was incorrectly made retryable");}
   catch(System.InvalidOperationException) {fatal=true;}
   if(!fatal||count!=1)throw new System.Exception("A native failure must stop after one call");
  }
 }
}
'@
Add-Type -TypeDefinition ([IO.File]::ReadAllText($source)+[Environment]::NewLine+$fixture)
[SmuTableFixture]::Run()
'PASS: SMU rejection defers once; next normal poll succeeds; timeout/unsupported/memory errors remain fatal'
