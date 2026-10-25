using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Management;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;

namespace BatteryGuard {
    public static class PerformanceTelemetry {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern bool SetDllDirectory(string path);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern IntPtr init_ryzenadj();
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int init_table(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int refresh_table(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern uint get_table_ver(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_stapm_limit(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_slow_limit(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_fast_limit(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_fast_value(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_stapm_value(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_apu_slow_limit(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_apu_slow_value(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_vrm_current(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_vrm_current_value(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int set_apu_slow_limit(IntPtr access, uint value);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_socket_power(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_tctl_temp_value(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern float get_tctl_temp(IntPtr access);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int set_stapm_limit(IntPtr access, uint value);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int set_fast_limit(IntPtr access, uint value);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int set_slow_limit(IntPtr access, uint value);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int set_skin_temp_power_limit(IntPtr access, uint value);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int set_apu_skin_temp_limit(IntPtr access, uint value);
        [DllImport("libryzenadj.dll", CallingConvention=CallingConvention.Cdecl)] static extern int set_tctl_temp(IntPtr access, uint value);
        [DllImport("WinRing0x64.dll")] static extern uint GetDllStatus();
        [DllImport("WinRing0x64.dll")] static extern bool Rdmsr(uint index, out uint eax, out uint edx);
        static readonly string Root=AppDomain.CurrentDomain.BaseDirectory;
        static readonly string Status=Path.Combine(Root,"status.json");
        static readonly string Stop=Path.Combine(Root,"stop");
        static readonly string ControlLive=Path.Combine(SourceRootConfiguration.Resolve(Root),"agent","control-live.json");
        static int policyWriteCount=0;
        static string lastPolicyWrite="";
        static int lastRequestedSkinPowerW=0;
        static int lastRequestedSurfaceRaw=0;
        static int lastProfileCommandsAcked=0;
        static int lastFactoryStapmTime=0,lastFactoryPlatformRaw=0;
        static object lastPolicyReadback=null;
        sealed class JournalEntry { public string Line; public bool ProgressWritten; }
        static readonly Queue<JournalEntry> Journal=new Queue<JournalEntry>();
        static string journalError="";
        static void RecordPolicyEvent(string kind,object evidence) {
            Journal.Enqueue(new JournalEntry {Line=new JavaScriptSerializer().Serialize(new {time=DateTime.UtcNow.ToString("o"),stage=kind,pid=System.Diagnostics.Process.GetCurrentProcess().Id,evidence=evidence})+Environment.NewLine});
        }
        static void FlushJournal() {
            try {
                string agent=Path.GetDirectoryName(ControlLive);
                while(Journal.Count>0){
                    JournalEntry entry=Journal.Peek();
                    if(!entry.ProgressWritten){File.AppendAllText(Path.Combine(agent,"progress.jsonl"),entry.Line);entry.ProgressWritten=true;}
                    File.AppendAllText(Path.Combine(agent,"findings.jsonl"),entry.Line);
                    Journal.Dequeue();
                }
                journalError="";
            }catch(IOException error){journalError=error.Message;}catch(UnauthorizedAccessException error){journalError=error.Message;}
        }
        static readonly System.Diagnostics.Stopwatch EnergyClock=System.Diagnostics.Stopwatch.StartNew();
        static bool raplInitialized=false,raplSupported=false,raplPrevious=false;
        static int raplEnergyUnit=0;
        static uint raplLastCounter=0;
        static double raplLastSeconds=0;
        static double? ReadRaplPackagePower() {
            uint low,high;
            if(!raplInitialized){
                raplInitialized=true;
                // AMD RAPL_POWER_UNIT and PACKAGE_ENERGY_STATUS are read-only.
                raplSupported=Rdmsr(0xC0010299U,out low,out high);
                if(!raplSupported)return null;
                raplEnergyUnit=(int)((low>>8)&31U);
            }
            if(!raplSupported || !Rdmsr(0xC001029BU,out low,out high)){raplSupported=false;return null;}
            double now=EnergyClock.Elapsed.TotalSeconds;
            double? power=null;
            if(raplPrevious && now>raplLastSeconds){
                double measured=RaplPower.Calculate(raplLastCounter,low,raplEnergyUnit,now-raplLastSeconds);
                if(measured>=0 && measured<=200)power=measured;
            }
            raplLastCounter=low;raplLastSeconds=now;raplPrevious=true;
            return power;
        }
        static void Save(object state) {
            string temp=Status+".tmp";
            File.WriteAllText(temp,new JavaScriptSerializer().Serialize(state));
            if(File.Exists(Status))File.Replace(temp,Status,null);else File.Move(temp,Status);
        }
        static bool SupportedBoard() {
            using(var query=new ManagementObjectSearcher("SELECT Product FROM Win32_BaseBoard"))
            using(var rows=query.Get())foreach(ManagementObject row in rows)
                if(Convert.ToString(row["Product"])=="WUJIE Series-T142-STX")return true;
            return false;
        }
        static bool TryReadPolicy(out PerformancePowerTarget target, out string source, out int mode, out int availableW, out string observedAt) {
            target=null;source="";mode=-1;availableW=0;observedAt="";
            try {
                var values=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(ControlLive));
                if(values==null || !values.ContainsKey("read_only") || !Convert.ToBoolean(values["read_only"]))return false;
                if(values.ContainsKey("fault") && !String.IsNullOrEmpty(Convert.ToString(values["fault"])))return false;
                if(!values.ContainsKey("time") || !values.ContainsKey("pid"))return false;
                DateTimeOffset timestamp;
                observedAt=Convert.ToString(values["time"]);
                if(!DateTimeOffset.TryParse(observedAt,CultureInfo.InvariantCulture,DateTimeStyles.None,out timestamp))return false;
                TimeSpan age=DateTimeOffset.UtcNow-timestamp.ToUniversalTime();
                if(age<TimeSpan.FromSeconds(-1) || age>TimeSpan.FromSeconds(8))return false;
                int pid=Convert.ToInt32(values["pid"],CultureInfo.InvariantCulture);
                using(var observer=System.Diagnostics.Process.GetProcessById(pid))if(observer.HasExited)return false;
                bool online=Convert.ToBoolean(values["online"]);
                source=Convert.ToString(values["power_source"]);
                mode=Convert.ToInt32(values["performance_mode_code"],CultureInfo.InvariantCulture);
                availableW=Convert.ToInt32(values["adapter_available_w"],CultureInfo.InvariantCulture);
                if(mode<0 || mode>2 || availableW<0 || availableW>300)return false;
                target=PerformancePowerPolicy.Select(online,source,mode,availableW);
                return true;
            }catch{return false;}
        }
        static bool Matches(float actual, int expectedW) {return Math.Abs(actual-expectedW)<=0.5F;}
        // These getters read the already refreshed PM table; they send no SMU requests.
        static float? TableValue(float value) {return float.IsNaN(value)||float.IsInfinity(value)?(float?)null:value;}
        static bool ApplyPowerTarget(IntPtr access, PerformancePowerTarget target, ref float stapm, ref float fast, ref float slow) {
            if(Matches(stapm,target.StapmW) && Matches(fast,target.FastPptW) && Matches(slow,target.SlowPptW) && Matches(get_apu_slow_limit(access),target.ApuSlowW) && lastRequestedSkinPowerW==target.SkinPowerW && lastRequestedSurfaceRaw==target.FactorySurfaceRaw && lastProfileCommandsAcked==19 && lastFactoryStapmTime==target.FactoryStapmTimeSeconds && lastFactoryPlatformRaw==target.FactoryPlatformRaw && Matches(get_tctl_temp(access),target.FactoryThermalC))return false;
            // Apply one coherent local OEM packet rather than retain Quiet
            // time constants and coefficients beneath Performance PPT values.
            lastProfileCommandsAcked=0;
            lastProfileCommandsAcked=OemSurfaceMailbox.ApplyProfile(target);
            lastFactoryStapmTime=target.FactoryStapmTimeSeconds;
            lastFactoryPlatformRaw=target.FactoryPlatformRaw;
            lastRequestedSurfaceRaw=target.FactorySurfaceRaw;
            lastRequestedSkinPowerW=target.SkinPowerW;
            int result=set_apu_slow_limit(access,(uint)(target.ApuSlowW*1000));
            if(result!=0)throw new InvalidOperationException("set_apu_slow_limit failed: "+result);
            SmuTableRefresh.Refresh(delegate{return refresh_table(access);});
            stapm=get_stapm_limit(access);fast=get_fast_limit(access);slow=get_slow_limit(access);
            float apu=get_apu_slow_limit(access),thermal=get_tctl_temp(access);
            PowerReadbackState classification=PerformancePowerPolicy.ClassifyReadback(target,stapm,fast,slow,apu,thermal);
            lastPolicyReadback=new {time=DateTime.UtcNow.ToString("o"),classification=classification.ToString(),requested=target,stapm_w=TableValue(stapm),fast_w=TableValue(fast),slow_w=TableValue(slow),apu_w=TableValue(apu),thermal_c=TableValue(thermal),commands_acked=lastProfileCommandsAcked};
            RecordPolicyEvent("live_power_policy_readback",lastPolicyReadback);
            if(classification==PowerReadbackState.Invalid)throw new InvalidOperationException("Invalid SMU policy readback; session ended without native retry");
            // Valid OEM overwrites are normal policy contention, not a failed
            // native session. Publish the real limits and revisit next poll.
            policyWriteCount++;
            lastPolicyWrite=DateTime.UtcNow.ToString("o");
            return true;
        }
        public static void Main() {
            bool owned=false;
            using(var gate=new Mutex(false,"Global\\BatteryGuard-PerformanceTelemetry"))
            using(var firmwareGate=new Mutex(false,"Global\\BatteryGuard-FirmwarePowerAccess")) {
                try {
                    try{owned=gate.WaitOne(0);}catch(AbandonedMutexException){owned=true;}
                    if(!owned)return;
                    if(File.Exists(Stop))return;
                    if(!SupportedBoard())throw new InvalidOperationException("Unsupported motherboard");
                    SetDllDirectory(Root);Directory.SetCurrentDirectory(Root);
                    IntPtr access=IntPtr.Zero;
                    int result=0;
                    uint version=0;
                    bool initializationOwned=false;
                    try{
                        try{initializationOwned=firmwareGate.WaitOne(10000);}catch(AbandonedMutexException){initializationOwned=true;}
                        if(!initializationOwned)throw new InvalidOperationException("Firmware power access is busy; SMU initialization was not attempted");
                        access=init_ryzenadj();
                        if(access==IntPtr.Zero)throw new InvalidOperationException("SMU telemetry interface could not be opened; WinRing0 status="+GetDllStatus()+"; process bits="+(IntPtr.Size*8)+"; user="+System.Security.Principal.WindowsIdentity.GetCurrent().Name);
                        result=init_table(access);
                        if(result!=0)throw new InvalidOperationException("SMU table initialization failed: "+result);
                        version=get_table_ver(access);
                    }finally{if(initializationOwned)firmwareGate.ReleaseMutex();}
                    if(version!=0x005D0008 && version!=0x005D0009 && version!=0x005D000B)
                        throw new InvalidOperationException("Unsupported Strix Point PM table: "+version.ToString("X"));
                    while(!File.Exists(Stop)) {
                        PerformancePowerTarget target=null;
                        string source="",observedAt="";
                        int mode=-1,availableW=0;
                        bool policyContext=TryReadPolicy(out target,out source,out mode,out availableW,out observedAt);
                        bool firmwareOwned=false;
                        try{
                        try{firmwareOwned=firmwareGate.WaitOne(0);}catch(AbandonedMutexException){firmwareOwned=true;}
                        if(!firmwareOwned){Thread.Sleep(250);continue;}
                        SmuTableRefresh.Refresh(delegate{return refresh_table(access);});
                        float stapm=get_stapm_limit(access),slow=get_slow_limit(access),fast=get_fast_limit(access);
                        if(float.IsNaN(stapm)||float.IsNaN(slow)||float.IsNaN(fast)||stapm<1||stapm>150||slow<1||slow>150||fast<1||fast>200)
                            throw new InvalidOperationException("Invalid power limit telemetry");
                        if(policyContext && target!=null && PerformancePowerPolicy.ClassifyReadback(target,stapm,fast,slow,get_apu_slow_limit(access),get_tctl_temp(access))==PowerReadbackState.Invalid)
                            throw new InvalidOperationException("Invalid native limit/thermal table; no policy write attempted");
                        bool policyWrite=policyContext && target!=null && ApplyPowerTarget(access,target,ref stapm,ref fast,ref slow);
                        bool policyApplied=policyContext && target!=null && lastProfileCommandsAcked==19 && PerformancePowerPolicy.ClassifyReadback(target,stapm,fast,slow,get_apu_slow_limit(access),get_tctl_temp(access))==PowerReadbackState.Matched;
                        float packagePower=get_socket_power(access),temperature=get_tctl_temp_value(access),fastValue=get_fast_value(access);
                        double? raplPower=ReadRaplPackagePower();
                        if(float.IsNaN(packagePower)||float.IsInfinity(packagePower)||packagePower<0||packagePower>200)throw new InvalidOperationException("Invalid package power telemetry");
                        Save(new {time=DateTime.UtcNow.ToString("o"),pid=System.Diagnostics.Process.GetCurrentProcess().Id,
                            smu_readback=true,sustained_limit_w=Math.Min(Math.Min(stapm,slow),get_apu_slow_limit(access)),stapm_limit_w=stapm,
                            slow_ppt_limit_w=slow,fast_ppt_limit_w=fast,package_power_w=packagePower,fast_ppt_power_w=fastValue,
                            cpu_temperature_c=temperature,table_version=version.ToString("X8"),error="",
                            stapm_average_power_w=TableValue(get_stapm_value(access)),
                            apu_slow_limit_w=TableValue(get_apu_slow_limit(access)),
                            apu_slow_power_w=TableValue(get_apu_slow_value(access)),
                            vrm_current_limit_a=TableValue(get_vrm_current(access)),
                            vrm_current_a=TableValue(get_vrm_current_value(access)),
                            policy_applied=policyApplied,policy_write=policyWrite,policy_write_count=policyWriteCount,
                            policy_last_write=lastPolicyWrite,policy_source=policyContext?source:"",
                            policy_mode_code=policyContext?(int?)mode:null,policy_adapter_available_w=policyContext?(int?)availableW:null,
                            policy_observation_time=policyContext?observedAt:"",
                            control_state=policyContext&&target!=null?(policyApplied?"applied":"restoring_firmware_override"):"monitoring",
                            last_policy_readback=lastPolicyReadback,
                            journal_pending=Journal.Count,journal_error=journalError,
                            target_sustained_limit_w=policyContext&&target!=null?(int?)Math.Min(target.StapmW,target.SlowPptW):null,
                            target_fast_ppt_limit_w=policyContext&&target!=null?(int?)target.FastPptW:null,
                            requested_skin_power_limit_w=lastRequestedSkinPowerW,
                            requested_factory_surface_raw=lastRequestedSurfaceRaw,
                            oem_profile_commands_acked=lastProfileCommandsAcked,
                            requested_factory_stapm_time_seconds=lastFactoryStapmTime,
                            requested_factory_platform_raw=lastFactoryPlatformRaw,
                            oem_profile_basis="Local DSDT THMP[0]/[1]/[2]/[4] and SSD1 A032; normal PPT follows user 45/54/45 W",
                            thermal_limit_c=get_tctl_temp(access),
                            skin_power_readback_available=false,
                            rapl_supported=raplSupported,rapl_package_power_w=raplPower,
                            rapl_source="AMD PACKAGE_ENERGY_STATUS 0xC001029B / monotonic interval",
                            rapl_energy_unit=raplSupported?(int?)raplEnergyUnit:null});
                        }catch(SmuTableTransferDeferredException deferred){
                            RecordPolicyEvent("smu_table_transfer_deferred",new {message=deferred.Message,source=source,mode=mode});
                            Save(new {time=DateTime.UtcNow.ToString("o"),pid=System.Diagnostics.Process.GetCurrentProcess().Id,smu_readback=false,error="",control_state="table_transfer_deferred",notice=deferred.Message,last_policy_readback=lastPolicyReadback});
                        }catch(OemMailboxBusyException busy){
                            RecordPolicyEvent("firmware_mailbox_occupied",new {message=busy.Message,source=source,mode=mode});
                            Save(new {time=DateTime.UtcNow.ToString("o"),pid=System.Diagnostics.Process.GetCurrentProcess().Id,smu_readback=false,error="",control_state="firmware_busy",notice=busy.Message,last_policy_readback=lastPolicyReadback});
                        }catch(Exception sampleError){
                            RecordPolicyEvent("native_power_session_ended",new {error=sampleError.Message,last_policy_readback=lastPolicyReadback});
                            Save(new {time=DateTime.UtcNow.ToString("o"),pid=System.Diagnostics.Process.GetCurrentProcess().Id,smu_readback=false,error=sampleError.Message,last_policy_readback=lastPolicyReadback});
                            // Native failures other than a rejected table transfer
                            // must not be remapped or retried.
                            // The mode-transition incident stalled firmware after this path.
                            throw;
                        }finally{if(firmwareOwned)firmwareGate.ReleaseMutex();}
                        FlushJournal();
                        int sleepCycles=20;
                        for(int n=0;n<sleepCycles&&!File.Exists(Stop);n++)Thread.Sleep(250);
                    }
                }catch(Exception error){FlushJournal();Save(new {time=DateTime.UtcNow.ToString("o"),smu_readback=false,error=error.ToString(),last_policy_readback=lastPolicyReadback,journal_pending=Journal.Count,journal_error=journalError});Environment.ExitCode=1;}
                finally{if(owned)gate.ReleaseMutex();}
            }
        }
    }
}
