using System;

namespace BatteryGuard {
    public sealed class SmuTableTransferDeferredException : InvalidOperationException {
        public SmuTableTransferDeferredException():base("SMU table transfer was rejected; wait for the next ordinary poll without remapping"){}
    }
    public static class SmuTableRefresh {
        public static void Refresh(Func<int> transfer) {
            int result=transfer();
            // RyzenAdj v0.19.0: -4 is ADJ_ERR_SMU_REJECTED, not memory access.
            // Upstream documents rejection when PM-table transfers overlap.
            if(result==-4)throw new SmuTableTransferDeferredException();
            if(result!=0)throw new InvalidOperationException("SMU table refresh failed: "+result);
        }
    }
}
