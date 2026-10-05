using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace BatteryGuard {
    public sealed class FanSnapshot {
        public int ManualMode, RightDuty, LeftDuty, RightRpm, LeftRpm;
        public int CpuTemperatureA, CpuTemperatureC, Temperature, Mode, SourceCode, AvailableWatts;
        public bool Online, RpmValid;
    }

    // This class exposes only fan writes. It has no charger/SMBus operation.
    public static class T142Fan {
        [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
        public static extern IntPtr LoadLibrary(string path);
        [DllImport("inpoutx64.dll",EntryPoint="IsInpOutDriverOpen")]
        static extern bool IsOpen();
        [DllImport("inpoutx64.dll",EntryPoint="DlPortReadPortUchar")]
        static extern byte In(ushort port);
        [DllImport("inpoutx64.dll",EntryPoint="DlPortWritePortUchar")]
        static extern void Out(ushort port,byte value);
        static readonly Mutex Bus=new Mutex(false,@"Global\BatteryGuard-T142-I2EC");
        static byte RegRead(byte reg){Out(0x4E,0x2E);Out(0x4F,reg);Out(0x4E,0x2F);return In(0x4F);}
        static void RegWrite(byte reg,byte value){Out(0x4E,0x2E);Out(0x4F,reg);Out(0x4E,0x2F);Out(0x4F,value);}
        static byte Read(ushort address){RegWrite(0x10,(byte)address);RegWrite(0x11,(byte)(address>>8));return RegRead(0x12);}
        static void WriteFan(ushort address,byte value){
            if(address!=0x0741 && address!=0x1804 && address!=0x1805)throw new InvalidOperationException("Not a fan register");
            if(address==0x0741 ? value>1 : (value<25 || value>100))throw new ArgumentOutOfRangeException("value");
            RegWrite(0x10,(byte)address);RegWrite(0x11,(byte)(address>>8));RegWrite(0x12,value);
        }
        static T Exclusive<T>(Func<T> action){
            bool owned=false;
            try{
                try{owned=Bus.WaitOne(1000);}catch(AbandonedMutexException){owned=true;}
                if(!owned)throw new TimeoutException("EC fan interface is busy");
                byte low=RegRead(0x10),high=RegRead(0x11);
                try{return action();}finally{RegWrite(0x10,low);RegWrite(0x11,high);}
            }finally{if(owned)Bus.ReleaseMutex();}
        }
        public static void Validate(){
            if(!IsOpen())throw new InvalidOperationException("InpOut driver unavailable");
            string signature=Exclusive(delegate{
                byte[] value=new byte[15];for(int i=0;i<15;i++)value[i]=Read((ushort)(0x04B0+i));
                return Encoding.ASCII.GetString(value);
            });
            if(signature!="AEC4168126-4S1P")throw new InvalidOperationException("Unexpected T142 battery signature");
        }
        public static FanSnapshot ReadSnapshot(){
            return Exclusive(delegate{
                var s=new FanSnapshot();
                s.ManualMode=Read(0x0741);s.RightDuty=Read(0x1804);s.LeftDuty=Read(0x1805);
                s.CpuTemperatureA=Read(0x0418);s.CpuTemperatureC=Read(0x041C);
                s.Temperature=Math.Max(s.CpuTemperatureA,s.CpuTemperatureC);
                s.RightRpm=Read(0x049B)*256+Read(0x049C);s.LeftRpm=Read(0x049D)*256+Read(0x049E);
                s.RpmValid=s.ManualMode==0;
                s.Online=(Read(0x0460)&1)!=0;s.SourceCode=Read(0x0461);s.Mode=Read(0x04E4);
                s.AvailableWatts=Read(0x048E)*256+Read(0x048F);
                return s;
            });
        }
        public static void ApplyManualDuty(int right,int left,bool acquire){
            Exclusive(delegate{return ApplyManualDutyCore(Read,WriteFan,right,left,acquire,false);});
        }
        internal static bool ApplyManualDutyCore(Func<ushort,byte> read,Action<ushort,byte> write,int right,int left,bool acquire,bool maintainFullDuty){
            if(right<25 || right>100 || left<25 || left>100)throw new ArgumentOutOfRangeException("duty");
                if(maintainFullDuty && (right!=100 || left!=100))throw new ArgumentException("Full-duty maintenance requires both fans at 100 percent");
                if(maintainFullDuty && ((read(0x0460)&1)==0 || read(0x04E4)!=0))return false;
                byte manual=read(0x0741);
                if(manual>1)throw new InvalidOperationException("Unexpected manual fan mode");
                if(!acquire && manual!=1 && !maintainFullDuty)return false;
                if(acquire && manual!=0 && !maintainFullDuty)throw new InvalidOperationException("Fan manual control already belongs to another controller");
                write(0x1804,(byte)right);write(0x1805,(byte)left);
                if(manual==0 && (acquire||maintainFullDuty)){write(0x0741,1);write(0x1804,(byte)right);write(0x1805,(byte)left);}
                if(read(0x0741)!=1){if(maintainFullDuty)return false;throw new InvalidOperationException("Firmware did not retain manual fan mode");}
                // At lower duty, retaining manual ownership is enough: EC may
                // trim PWM between writes. Full-duty maintenance additionally
                // confirms both requested 100 percent values.
                return !maintainFullDuty || (read(0x1804)==right && read(0x1805)==left);
        }
        public static bool MaintainManualDuty(int right,int left,bool acquire,bool maintainFullDuty){
            return Exclusive(delegate{return ApplyManualDutyCore(Read,WriteFan,right,left,acquire,maintainFullDuty);});
        }
        public static void RestoreAutomatic(){
            Exclusive(delegate{WriteFan(0x0741,0);if(Read(0x0741)!=0)throw new InvalidOperationException("Automatic fan mode was not restored");return 0;});
        }
    }
}
