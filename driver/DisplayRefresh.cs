using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace BatteryGuard {
    public static class DisplayRefresh {
        const int ENUM_CURRENT_SETTINGS = -1;
        // A fullscreen mode is reverted when its caller exits. Use a dynamic
        // desktop change without writing the user's display registry settings.
        const int CDS_DYNAMIC = 0;
        const int DISP_CHANGE_SUCCESSFUL = 0;
        const int DM_DISPLAYFREQUENCY = 0x400000;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DEVMODE {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public uint dmFields;
            public short dmOrientation, dmPaperSize, dmPaperLength, dmPaperWidth;
            public short dmScale, dmCopies, dmDefaultSource, dmPrintQuality;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public ushort dmLogPixels;
            public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
            public uint dmPanningWidth, dmPanningHeight;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE devMode, IntPtr hwnd, int flags, IntPtr lParam);

        static DEVMODE Current(string device) {
            DEVMODE mode = new DEVMODE();
            mode.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
            if (!EnumDisplaySettings(device, ENUM_CURRENT_SETTINGS, ref mode)) throw new InvalidOperationException("Cannot read display mode");
            return mode;
        }

        public static string CurrentSummary() {
            DEVMODE mode = Current(null);
            return mode.dmPelsWidth + "x" + mode.dmPelsHeight + "@" + mode.dmDisplayFrequency;
        }

        static uint HighestRefresh(uint width, uint height) {
            var rates = new HashSet<uint>();
            for (int index = 0; index < 1024; index++) {
                DEVMODE mode = new DEVMODE();
                mode.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
                if (!EnumDisplaySettings(null, index, ref mode)) break;
                if (mode.dmPelsWidth == width && mode.dmPelsHeight == height && mode.dmDisplayFrequency > 0)
                    rates.Add(mode.dmDisplayFrequency);
            }
            uint best = 0;
            foreach (uint rate in rates) if (rate > best) best = rate;
            return best;
        }

        public static bool ApplyForSource(string source) {
            DEVMODE current = Current(null);
            uint target;
            if (source == "Battery") {
                target = 60;
                bool supports60 = false;
                for (int index = 0; index < 1024; index++) {
                    DEVMODE candidate = new DEVMODE();
                    candidate.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
                    if (!EnumDisplaySettings(null, index, ref candidate)) break;
                    if (candidate.dmPelsWidth == current.dmPelsWidth && candidate.dmPelsHeight == current.dmPelsHeight && candidate.dmDisplayFrequency == 60) { supports60 = true; break; }
                }
                if (!supports60) return false;
            } else if (source == "DC" || source == "TypeC" || source == "External" || source == "Unknown") {
                target = HighestRefresh(current.dmPelsWidth, current.dmPelsHeight);
            } else return false;
            if (target == 0 || current.dmDisplayFrequency == target) return false;
            current.dmDisplayFrequency = target;
            current.dmFields = DM_DISPLAYFREQUENCY;
            int result = ChangeDisplaySettingsEx(null, ref current, IntPtr.Zero, CDS_DYNAMIC, IntPtr.Zero);
            if (result != DISP_CHANGE_SUCCESSFUL) throw new InvalidOperationException("Display refresh change failed: " + result);
            return true;
        }
    }
}
