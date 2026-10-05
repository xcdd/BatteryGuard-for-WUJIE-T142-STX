$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\driver\T142Fan.cs'
$tests=@'
public static class TestFanFullDuty {
 public static void Run() {
  var method=typeof(BatteryGuard.T142Fan).GetMethod("ApplyManualDutyCore",System.Reflection.BindingFlags.Static|System.Reflection.BindingFlags.NonPublic);
  if(method==null)throw new System.Exception("Full-duty maintenance operation is missing");
  var regs=new System.Collections.Generic.Dictionary<ushort,byte>{{0x0741,0},{0x1804,4},{0x1805,24},{0x0460,1},{0x04E4,0}};
  var writes=new System.Collections.Generic.List<ushort>();
  System.Func<ushort,byte> read=delegate(ushort a){return regs[a];};
  System.Action<ushort,byte> write=delegate(ushort a,byte v){writes.Add(a);regs[a]=v;};
  bool kept=(bool)method.Invoke(null,new object[]{read,write,100,100,false,true});
  if(!kept||regs[0x0741]!=1||regs[0x1804]!=100||regs[0x1805]!=100)throw new System.Exception("A firmware pulse must be corrected to manual dual-fan 100 percent");
  regs[0x0460]=0;writes.Clear();
  kept=(bool)method.Invoke(null,new object[]{read,write,100,100,false,true});
  if(kept||writes.Count!=0)throw new System.Exception("Full-duty maintenance must issue no writes when power disconnects");
  regs[0x0460]=1;regs[0x04E4]=1;writes.Clear();
  kept=(bool)method.Invoke(null,new object[]{read,write,100,100,false,true});
  if(kept||writes.Count!=0)throw new System.Exception("Full-duty maintenance must issue no writes outside Performance");
  regs[0x04E4]=0;regs[0x0741]=0;writes.Clear();
  kept=(bool)method.Invoke(null,new object[]{read,write,55,55,false,false});
  if(kept||writes.Count!=0)throw new System.Exception("A lower curve must yield without stopping the worker or fighting a firmware takeover");
  System.Action<ushort,byte> pulse=delegate(ushort a,byte v){write(a,v);if(a==0x0741)regs[a]=0;};
  kept=(bool)method.Invoke(null,new object[]{read,pulse,100,100,false,true});
  if(kept)throw new System.Exception("A rejected full-duty command must not be reported as retained");
  regs[0x0741]=1;
  System.Action<ushort,byte> pull=delegate(ushort a,byte v){write(a,v);if(a==0x1804)regs[a]=50;};
  kept=(bool)method.Invoke(null,new object[]{read,pull,55,55,false,false});
  if(!kept||regs[0x0741]!=1)throw new System.Exception("A lower-duty pull-down must not abandon ownership while manual mode remains enabled");
 }
}
'@
Add-Type -TypeDefinition ((Get-Content -LiteralPath $source -Raw)+[Environment]::NewLine+$tests)
[TestFanFullDuty]::Run()
'PASS: 6 fan full-duty transport cases'
