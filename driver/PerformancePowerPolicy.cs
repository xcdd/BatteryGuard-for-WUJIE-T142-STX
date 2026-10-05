using System;

namespace BatteryGuard {
    public enum PowerReadbackState { Matched, FirmwareChanged, Invalid }
    public sealed class PerformancePowerTarget {
        public int StapmW { get; private set; }
        public int FastPptW { get; private set; }
        public int SlowPptW { get; private set; }
        public int ApuSlowW { get; private set; }
        public int SkinPowerW { get; private set; }
        public int FactorySurfaceRaw { get; private set; }
        public int FactoryThermalC { get; private set; }
        public int FactoryStapmTimeSeconds { get; private set; }
        public int FactoryPlatformRaw { get; private set; }

        public PerformancePowerTarget(int stapmW, int fastPptW, int slowPptW, int surfaceRaw, int thermalC, int factoryStapmTimeSeconds=300, int factoryPlatformRaw=160000) {
            StapmW=stapmW;
            FastPptW=fastPptW;
            SlowPptW=slowPptW;
            ApuSlowW=slowPptW;
            SkinPowerW=stapmW;
            FactorySurfaceRaw=surfaceRaw;
            FactoryThermalC=thermalC;
            FactoryStapmTimeSeconds=factoryStapmTimeSeconds;
            FactoryPlatformRaw=factoryPlatformRaw;
        }
    }

    public static class PerformancePowerPolicy {
        static bool Valid(float value,float maximum) {return !float.IsNaN(value)&&!float.IsInfinity(value)&&value>=1&&value<=maximum;}
        public static PowerReadbackState ClassifyReadback(PerformancePowerTarget target,float stapm,float fast,float slow,float apu,float thermal) {
            if(target==null || !Valid(stapm,150)||!Valid(fast,200)||!Valid(slow,150)||!Valid(apu,150)||!Valid(thermal,115))return PowerReadbackState.Invalid;
            if(Math.Abs(stapm-target.StapmW)<=0.5F && Math.Abs(fast-target.FastPptW)<=0.5F && Math.Abs(slow-target.SlowPptW)<=0.5F && Math.Abs(apu-target.ApuSlowW)<=0.5F && Math.Abs(thermal-target.FactoryThermalC)<=0.5F)return PowerReadbackState.Matched;
            return PowerReadbackState.FirmwareChanged;
        }
        static readonly PerformancePowerTarget Quiet=new PerformancePowerTarget(30,35,30,10752,90,50,80000);
        static readonly PerformancePowerTarget Normal=new PerformancePowerTarget(45,54,45,10752,96);
        static readonly PerformancePowerTarget NormalBattery=new PerformancePowerTarget(45,54,45,10752,96,100,120000);
        static readonly PerformancePowerTarget Performance=new PerformancePowerTarget(80,96,80,15360,99);

        public static PerformancePowerTarget Select(bool online, string source, int mode, int availableW) {
            if(mode==2)return Quiet;
            if(mode==1)return online?Normal:NormalBattery;
            if(mode!=0 || !online)return null;
            if(string.Equals(source,"DC",StringComparison.OrdinalIgnoreCase))return Performance;
            if(string.Equals(source,"TypeC",StringComparison.OrdinalIgnoreCase) && availableW>44)return Performance;
            return Normal;
        }
    }
}
