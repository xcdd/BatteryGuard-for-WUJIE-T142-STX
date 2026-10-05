using System;

namespace BatteryGuard {
    public static class RaplPower {
        public static double Calculate(uint previous, uint current, int energyUnit, double seconds) {
            if(energyUnit<0 || energyUnit>31)throw new ArgumentOutOfRangeException("energyUnit");
            if(seconds<=0 || Double.IsNaN(seconds) || Double.IsInfinity(seconds))throw new ArgumentOutOfRangeException("seconds");
            uint delta=unchecked(current-previous);
            return delta*Math.Pow(0.5,energyUnit)/seconds;
        }
    }
}
