using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace BatteryGuard {
    public sealed class OemMailboxBusyException : InvalidOperationException {
        public OemMailboxBusyException():base("OEM MP1 mailbox is occupied; this request was not sent"){}
    }
    public interface IOemMailbox {
        uint Read(uint address);
        void Write(uint address,uint value);
    }
    public static class OemSurfaceMailbox {
        const uint Response=0x03B10978,Argument=0x03B10998,Message=0x03B10928;
        // Requests below are copied from local THMP and SSD1 A032/A018.
        public static void Apply(IOemMailbox mailbox,uint raw) {
            if(raw!=10752 && raw!=15360)throw new ArgumentOutOfRangeException("raw");
            Send(mailbox,0x33,raw);
        }
        static void Send(IOemMailbox mailbox,uint command,uint raw) {
            // THMD itself waits for ACK=1 before each ALIB request.
            uint ready=mailbox.Read(Response);
            if(ready==0)throw new OemMailboxBusyException();
            if(ready!=1)throw new InvalidOperationException("OEM MP1 mailbox has an unacknowledged failure; no request was sent");
            mailbox.Write(Response,0);
            for(uint n=0;n<6;n++)mailbox.Write(Argument+4*n,n==0?raw:0);
            mailbox.Write(Message,command);
            var deadline=Stopwatch.StartNew();
            uint reply=0;
            while(deadline.ElapsedMilliseconds<1000){reply=mailbox.Read(Response);if(reply!=0)break;Thread.Sleep(1);}
            if(reply!=1)throw new InvalidOperationException("OEM MP1 request 0x"+command.ToString("X")+" failed: 0x"+reply.ToString("X")+"; no automatic retransmission");
        }
        public static void Apply(uint raw) {Apply(new PciMailbox(),raw);}
        // Exact THMP[0]/[1]/[2]/[4] ordering and A032 selector-to-MP1 mapping
        // from this board's DSDT/SSD1. Only the user-selected normal 45/54/45
        // power values differ from THMP[1]/[2]; their OEM dynamic coefficients stay intact.
        public static int ApplyProfile(IOemMailbox mailbox,PerformancePowerTarget target) {
            if(target==null)throw new ArgumentNullException("target");
            bool performance=target.StapmW==80 && target.FastPptW==96 && target.SlowPptW==80 && target.FactorySurfaceRaw==15360 && target.FactoryThermalC==99;
            bool quiet=target.StapmW==30 && target.FastPptW==35 && target.SlowPptW==30 && target.FactorySurfaceRaw==10752 && target.FactoryThermalC==90;
            bool normal=target.StapmW==45 && target.FastPptW==54 && target.SlowPptW==45 && target.FactorySurfaceRaw==10752 && target.FactoryThermalC==96;
            if((!performance&&!quiet&&!normal) || target.ApuSlowW!=target.SlowPptW || target.SkinPowerW!=target.StapmW)
                throw new InvalidOperationException("No verified local OEM profile for the requested limits");
            bool batteryNormal=normal && target.FactoryStapmTimeSeconds==100 && target.FactoryPlatformRaw==120000;
            if(!batteryNormal && (target.FactoryStapmTimeSeconds!=(quiet?50:300) || target.FactoryPlatformRaw!=(quiet?80000:160000)))
                throw new InvalidOperationException("No verified local OEM dynamic profile for the requested limits");
            uint[] commands={0x14,0x15,0x16,0x18,0x1A,0x1C,0x1B,0x1D,0x20,0x17,0x19,0x37,0x38,0x3D,0x31,0x35,0x36,0x4A,0x33};
            uint[] values={
                (uint)(target.StapmW*1000),(uint)(target.FastPptW*1000),(uint)(target.SlowPptW*1000),
                (uint)target.FactoryStapmTimeSeconds,80000,140000,30000,45000,(uint)target.FactoryPlatformRaw,quiet?15U:30U,
                (uint)target.FactoryThermalC,
                performance?78U:(quiet?164U:87U),performance?704U:(quiet?363U:662U),
                performance?1716U:(quiet?4219U:2066U),performance?1638U:(quiet?3277U:6554U),
                performance?131U:33U,9830,(uint)(target.SkinPowerW*1000),(uint)target.FactorySurfaceRaw
            };
            for(int n=0;n<commands.Length;n++)Send(mailbox,commands[n],values[n]);
            return commands.Length;
        }
        public static int ApplyProfile(PerformancePowerTarget target) {return ApplyProfile(new PciMailbox(),target);}
        sealed class PciMailbox : IOemMailbox {
            [DllImport("WinRing0x64.dll")] static extern bool ReadPciConfigDwordEx(uint pciAddress,uint regAddress,out uint value);
            [DllImport("WinRing0x64.dll")] static extern bool WritePciConfigDwordEx(uint pciAddress,uint regAddress,uint value);
            public PciMailbox(){uint id;if(!ReadPciConfigDwordEx(0,0,out id) || (id&0xFFFF)!=0x1022)throw new InvalidOperationException("AMD host bridge could not be identified");}
            public uint Read(uint address){uint value;if(!WritePciConfigDwordEx(0,0xB8,address) || !ReadPciConfigDwordEx(0,0xBC,out value))throw new InvalidOperationException("OEM mailbox read failed");return value;}
            public void Write(uint address,uint value){if(!WritePciConfigDwordEx(0,0xB8,address) || !WritePciConfigDwordEx(0,0xBC,value))throw new InvalidOperationException("OEM mailbox write failed");}
        }
    }
}
