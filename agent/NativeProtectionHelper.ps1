#requires -Version 5.1
$ErrorActionPreference='Stop'
$nativeRoot=$PSScriptRoot
$manifest=Get-Content -LiteralPath (Join-Path $nativeRoot 'manifest.json') -Raw|ConvertFrom-Json
$sourceRuntime=Join-Path $manifest.source_root 'agent\charge-runtime.json'
$statusPath=Join-Path $nativeRoot 'status.json'
$ownershipPath=Join-Path $nativeRoot 'ownership.json'
$stopPath=Join-Path $nativeRoot 'stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BatteryGuardNativeProtection {
    static readonly ulong StateName=0x41C6013DA3BD3875;
    [DllImport("ntdll.dll")] static extern int NtQueryWnfStateData(ref ulong name,IntPtr type,IntPtr scope,out uint stamp,byte[] data,ref uint size);
    [DllImport("ntdll.dll")] static extern int NtUpdateWnfStateData(ref ulong name,byte[] data,uint size,IntPtr type,IntPtr scope,uint stamp,uint check);
    public class Notice {public uint Stamp,Length;public byte Value;}
    [StructLayout(LayoutKind.Sequential)] public struct Power {public byte Ac,Battery,Charging,Discharging,S1,S2,S3,Tag;public uint Full,Remaining;public int Rate;public uint Time,A1,A2;}
    [DllImport("powrprof.dll")] static extern int CallNtPowerInformation(int level,IntPtr input,uint inputSize,out Power output,uint outputSize);
    public static Power ReadPower(){Power p;int status=CallNtPowerInformation(5,IntPtr.Zero,0,out p,36);if(status!=0)throw new Exception("Power query: "+status.ToString("X8"));return p;}
    public static Notice Read(){ulong name=StateName;uint stamp;uint size=8;byte[] b=new byte[8];int status=NtQueryWnfStateData(ref name,IntPtr.Zero,IntPtr.Zero,out stamp,b,ref size);if(status!=0)throw new Exception("Protection query: "+status.ToString("X8"));if(size>1 || (size==1 && b[0]>1))throw new Exception("Unexpected protection notification format");return new Notice{Stamp=stamp,Length=size,Value=size==1?b[0]:(byte)0};}
    public static void Publish(bool active,uint stamp){ulong name=StateName;int status=NtUpdateWnfStateData(ref name,new byte[]{(byte)(active?1:0)},1,IntPtr.Zero,IntPtr.Zero,stamp,1);if(status!=0)throw new Exception("Protection update: "+status.ToString("X8"));}
}
'@
function Save-NativeJson($path,$value){
    $temp=$path+'.tmp'
    [IO.File]::WriteAllText($temp,($value|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $path){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
}
$ownership=[pscustomobject]@{owned=$false;original=$false;stamp=0}
function Restore-NativeProtection {
    if($ownership.owned){
        $now=[BatteryGuardNativeProtection]::Read()
        if($now.Stamp -eq $ownership.stamp){[BatteryGuardNativeProtection]::Publish($ownership.original,$now.Stamp)}
        $ownership.owned=$false
        Save-NativeJson $ownershipPath $ownership
    }
}
$mutex=[Threading.Mutex]::new($false,'Global\BatteryGuard-NativeProtection')
$acquired=$false
try{
    try{$acquired=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$acquired=$true}
    if(-not $acquired){exit 0}
    $build=[int](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
    if($build -ne [int]$manifest.tested_build){throw 'Windows build differs from the tested native protection interface'}
    if(Test-Path -LiteralPath $ownershipPath){
        $saved=Get-Content -LiteralPath $ownershipPath -Raw|ConvertFrom-Json
        $current=[BatteryGuardNativeProtection]::Read()
        if($saved.owned -and $saved.stamp -eq $current.Stamp){$ownership=$saved}
    }
    while(-not (Test-Path -LiteralPath $stopPath)){
        try{
            $request=$false
            $runtime=$null
            if(Test-Path -LiteralPath $sourceRuntime){
                $runtime=Get-Content -LiteralPath $sourceRuntime -Raw -Encoding UTF8|ConvertFrom-Json
                $age=if($runtime.updated_at){((Get-Date)-[datetime]$runtime.updated_at).TotalSeconds}else{999}
                $request=$age -ge 0 -and $age -lt 8 -and $runtime.paused_by_us -and $runtime.phase -eq 'paused' -and -not $runtime.error -and $runtime.current_register -eq 0 -and [math]::Abs($runtime.actual_current_ma) -le 50
            }
            $power=[BatteryGuardNativeProtection]::ReadPower()
            # Kernel charging/rate flags may lag the smart battery by ~30 seconds.
            # The fresh hardware snapshot establishes actual pause; kernel data
            # is used only to confirm that the battery and external power exist.
            $request=$request -and $power.Ac -eq 1 -and $power.Battery -eq 1
            $notice=[BatteryGuardNativeProtection]::Read()
            if($ownership.owned -and $notice.Stamp -ne $ownership.stamp){$ownership.owned=$false}
            if($request -and $notice.Value -eq 0){
                $ownership.original=$false
                [BatteryGuardNativeProtection]::Publish($true,$notice.Stamp)
                $ownership.stamp=[BatteryGuardNativeProtection]::Read().Stamp
                $ownership.owned=$true
                Save-NativeJson $ownershipPath $ownership
            }elseif(-not $request){Restore-NativeProtection}
            $notice=[BatteryGuardNativeProtection]::Read()
            Save-NativeJson $statusPath @{updated_at=(Get-Date -Format o);requested=$request;active=($notice.Value -ne 0);error='';source_worker_pid=$(if($runtime){$runtime.worker_pid}else{0})}
        }catch{
            $errorText=$_.Exception.Message
            try{Restore-NativeProtection}catch{}
            Save-NativeJson $statusPath @{updated_at=(Get-Date -Format o);requested=$false;active=$false;error=$errorText}
        }
        Start-Sleep -Seconds 2
    }
}catch{
    Save-NativeJson $statusPath @{updated_at=(Get-Date -Format o);requested=$false;active=$false;error=$_.Exception.Message}
}finally{
    if($acquired){try{Restore-NativeProtection}catch{};$mutex.ReleaseMutex()}
    $mutex.Dispose()
}
