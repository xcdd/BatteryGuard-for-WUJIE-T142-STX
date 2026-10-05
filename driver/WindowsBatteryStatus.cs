using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using Microsoft.Win32.SafeHandles;

namespace BatteryGuard {
    public static class WindowsBatteryStatus {
        [StructLayout(LayoutKind.Sequential)]
        public struct SystemPowerStatus {
            public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
            public uint BatteryLifeTime, BatteryFullLifeTime;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct BatteryState {
            public byte AcOnLine, BatteryPresent, Charging, Discharging;
            public byte Spare1, Spare2, Spare3, Tag;
            public uint MaxCapacity, RemainingCapacity;
            public int Rate;
            public uint EstimatedTime, DefaultAlert1, DefaultAlert2;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetSystemPowerStatus(out SystemPowerStatus status);
        [DllImport("powrprof.dll")]
        static extern int CallNtPowerInformation(int level, IntPtr input, uint inputLength, out BatteryState output, uint outputLength);

        public static SystemPowerStatus ReadShellStatus() {
            SystemPowerStatus status;
            if (!GetSystemPowerStatus(out status)) throw new System.ComponentModel.Win32Exception();
            return status;
        }
        public static BatteryState ReadBatteryState() {
            BatteryState state;
            int result = CallNtPowerInformation(5, IntPtr.Zero, 0, out state, (uint)Marshal.SizeOf(typeof(BatteryState)));
            if (result != 0) throw new InvalidOperationException("Windows battery status: " + result.ToString("X8"));
            return state;
        }

        public class ChargeLimitingNotification {
            public bool Active;
            public uint ChangeStamp, Length;
        }
        static readonly ulong ChargeLimitingStateName = 0x41C6013DA3BD3875;
        [DllImport("ntdll.dll")]
        static extern int NtQueryWnfStateData(ref ulong state, IntPtr type, IntPtr scope, out uint stamp, byte[] buffer, ref uint length);
        public static ChargeLimitingNotification ReadChargeLimitingNotification() {
            ulong state=ChargeLimitingStateName;uint stamp;uint length=8;byte[] data=new byte[length];
            int status=NtQueryWnfStateData(ref state,IntPtr.Zero,IntPtr.Zero,out stamp,data,ref length);
            if(status!=0)throw new InvalidOperationException("Windows charge-limiting query: "+status.ToString("X8"));
            if(length>1 || (length==1 && data[0]>1))throw new InvalidOperationException("Unexpected Windows charge-limiting payload");
            return new ChargeLimitingNotification{Active=length==1 && data[0]!=0,ChangeStamp=stamp,Length=length};
        }

        [DllImport("user32.dll",CharSet=CharSet.Unicode)]
        static extern IntPtr FindWindow(string className,string windowName);
        [DllImport("user32.dll",SetLastError=true)]
        static extern IntPtr SendMessageTimeout(IntPtr window,uint message,UIntPtr parameter,IntPtr data,uint flags,uint timeout,out UIntPtr result);
        [DllImport("user32.dll",EntryPoint="SendMessageTimeout",CharSet=CharSet.Unicode,SetLastError=true)]
        static extern IntPtr SendMessageTimeoutText(IntPtr window,uint message,UIntPtr parameter,string data,uint flags,uint timeout,out UIntPtr result);
        // The ACPI battery device has been refreshed and GetSystemPowerStatus
        // already returns the repaired state. Notify the shell to query it
        // again; this does not change power policy or any hardware register.
        public static bool RefreshShellBatteryStatus() {
            UIntPtr result;
            bool power=SendMessageTimeout(new IntPtr(0xFFFF),0x218,new UIntPtr(0x000A),IntPtr.Zero,2,1000,out result)!=IntPtr.Zero;
            bool setting=SendMessageTimeoutText(new IntPtr(0xFFFF),0x001A,UIntPtr.Zero,"Power",2,1000,out result)!=IntPtr.Zero;
            return power || setting;
        }
        // Match the actual WNF mode, then send only the documented power-setting
        // change message for the charge-limiting GUID used by the native tray.
        // This prompts a redraw; it does not change battery charge or capacity.
        public static bool RefreshChargeProtectionIcon() {
            var mode=ReadChargeLimitingNotification();
            IntPtr data=Marshal.AllocHGlobal(24);
            try {
                byte[] bytes=new byte[24];
                Array.Copy(new Guid("cbbd8af5-3efd-4f36-b0eb-6487b3bfb68d").ToByteArray(),bytes,16);
                Array.Copy(BitConverter.GetBytes((uint)1),0,bytes,16,4);
                bytes[20]=(byte)(mode.Active?1:0);
                Marshal.Copy(bytes,0,data,24);
                IntPtr window=FindWindow("SystemTray_Main",null);
                if(window==IntPtr.Zero)window=new IntPtr(0xFFFF);
                UIntPtr result;
                return SendMessageTimeout(window,0x218,new UIntPtr(0x8013),data,2,1000,out result)!=IntPtr.Zero;
            } finally { Marshal.FreeHGlobal(data); }
        }

        [StructLayout(LayoutKind.Sequential)]
        struct InterfaceData {
            public uint Size;
            public Guid Guid;
            public uint Flags;
            public UIntPtr Reserved;
        }
        public class DeviceStatus {
            public uint Tag, PowerState, Capacity, Voltage, Capabilities;
            public int Rate;
            public bool CanSetCharge { get { return (Capabilities & 0x00000001) != 0; } }
            public bool CanSetDischarge { get { return (Capabilities & 0x00000002) != 0; } }
        }
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr SetupDiGetClassDevs(ref Guid guid, string enumerator, IntPtr parent, uint flags);
        [DllImport("setupapi.dll", SetLastError=true)]
        static extern bool SetupDiEnumDeviceInterfaces(IntPtr devices, IntPtr device, ref Guid guid, uint index, ref InterfaceData data);
        [DllImport("setupapi.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr devices, ref InterfaceData data, IntPtr detail, uint size, out uint required, IntPtr info);
        [DllImport("setupapi.dll")]
        static extern bool SetupDiDestroyDeviceInfoList(IntPtr devices);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        static extern bool DeviceIoControl(SafeFileHandle handle, uint code, byte[] input, uint inLength, byte[] output, uint outLength, out uint returned, IntPtr overlapped);
        static byte[] Query(SafeFileHandle handle, uint code, byte[] input, int outSize) {
            byte[] output = new byte[outSize]; uint returned;
            if (!DeviceIoControl(handle, code, input, (uint)input.Length, output, (uint)outSize, out returned, IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            return output;
        }
        public static DeviceStatus[] ReadDeviceStatus() {
            Guid guid = new Guid("72631e54-78a4-11d0-bcf7-00aa00b7b32a");
            IntPtr devices = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, 0x12);
            if (devices == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
            var results = new List<DeviceStatus>();
            try {
                for (uint index=0; ; index++) {
                    InterfaceData data = new InterfaceData(); data.Size=(uint)Marshal.SizeOf(typeof(InterfaceData));
                    if (!SetupDiEnumDeviceInterfaces(devices, IntPtr.Zero, ref guid, index, ref data)) {
                        if (Marshal.GetLastWin32Error()==259) break;
                        throw new System.ComponentModel.Win32Exception();
                    }
                    uint required;
                    SetupDiGetDeviceInterfaceDetail(devices, ref data, IntPtr.Zero, 0, out required, IntPtr.Zero);
                    IntPtr detail=Marshal.AllocHGlobal((int)required);
                    try {
                        Marshal.WriteInt32(detail, IntPtr.Size==8 ? 8 : 6);
                        if (!SetupDiGetDeviceInterfaceDetail(devices, ref data, detail, required, out required, IntPtr.Zero))
                            throw new System.ComponentModel.Win32Exception();
                        string path=Marshal.PtrToStringUni(IntPtr.Add(detail,4));
                        using (SafeFileHandle handle=CreateFile(path,0x80000000,3,IntPtr.Zero,3,0,IntPtr.Zero)) {
                            if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception();
                            uint tag=BitConverter.ToUInt32(Query(handle,0x294040,new byte[4],4),0);
                            byte[] wait=new byte[20]; Array.Copy(BitConverter.GetBytes(tag),wait,4);
                            Array.Copy(BitConverter.GetBytes(uint.MaxValue),0,wait,16,4);
                            byte[] status=Query(handle,0x29404C,wait,16);
                            byte[] infoInput=new byte[12];Array.Copy(BitConverter.GetBytes(tag),infoInput,4);
                            byte[] info=Query(handle,0x294044,infoInput,36);
                            results.Add(new DeviceStatus{Tag=tag,PowerState=BitConverter.ToUInt32(status,0),Capacity=BitConverter.ToUInt32(status,4),Voltage=BitConverter.ToUInt32(status,8),Rate=BitConverter.ToInt32(status,12),Capabilities=BitConverter.ToUInt32(info,0)});
                        }
                    } finally { Marshal.FreeHGlobal(detail); }
                }
            } finally { SetupDiDestroyDeviceInfoList(devices); }
            return results.ToArray();
        }
    }
}
