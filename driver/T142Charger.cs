using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace BatteryGuard {
    public class PauseEnforcementResult {
        public int ObservedCurrent;
        public bool ZeroWritten;
        public double ElapsedMilliseconds;
    }
    public class SmbusArbitrationException : IOException {
        public SmbusArbitrationException(string message):base(message){}
    }
    public class SmbusRetryableException : IOException {
        public SmbusRetryableException(string message):base(message){}
    }
    public static class T142Charger {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr LoadLibrary(string path);
        [DllImport("inpoutx64.dll", EntryPoint = "IsInpOutDriverOpen")]
        public static extern bool IsOpen();
        [DllImport("inpoutx64.dll", EntryPoint = "DlPortReadPortUchar")]
        static extern byte In(ushort port);
        [DllImport("inpoutx64.dll", EntryPoint = "DlPortWritePortUchar")]
        static extern void Out(ushort port, byte value);

        static readonly Mutex Bus = new Mutex(false, "Global\\BatteryGuard-T142-I2EC");
        static string hardwareBlockPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory,
            "agent", "hardware-access-block.json");
        public static string HardwareBlockPath {
            get { return hardwareBlockPath; }
            set { hardwareBlockPath = value; }
        }

        static void CheckHardwareAccess(bool emergencyStop) {
            if (!emergencyStop && !String.IsNullOrEmpty(HardwareBlockPath) && File.Exists(HardwareBlockPath))
                throw new InvalidOperationException("Shared EC SMBus access is suspended after false Critical battery events");
        }

        static byte RegisterRead(byte register) {
            Out(0x4E, 0x2E); Out(0x4F, register); Out(0x4E, 0x2F);
            return In(0x4F);
        }
        static void RegisterWrite(byte register, byte value) {
            Out(0x4E, 0x2E); Out(0x4F, register); Out(0x4E, 0x2F); Out(0x4F, value);
        }
        static byte Read(ushort address) {
            RegisterWrite(0x10, (byte)address); RegisterWrite(0x11, (byte)(address >> 8));
            return RegisterRead(0x12);
        }
        static void Write(ushort address, byte value) {
            RegisterWrite(0x10, (byte)address); RegisterWrite(0x11, (byte)(address >> 8));
            RegisterWrite(0x12, value);
        }

        static T Exclusive<T>(Func<T> operation) {
            bool acquired = false;
            try {
                try { acquired = Bus.WaitOne(2000); }
                catch (AbandonedMutexException) { acquired = true; }
                if (!acquired) throw new TimeoutException("I2EC is busy");
                byte low = RegisterRead(0x10), high = RegisterRead(0x11);
                try { return operation(); }
                finally { RegisterWrite(0x10, low); RegisterWrite(0x11, high); }
            } finally { if (acquired) Bus.ReleaseMutex(); }
        }

        public static void Validate() {
            ValidateBatterySignature();
            if (ReadCharger(0xFE) != 0x4F32 || ReadCharger(0xFF) != 0x000A)
                throw new InvalidOperationException("Unexpected charger identity");
        }

        public static void ValidateBatterySignature() {
            if (!IsOpen()) throw new InvalidOperationException("InpOut driver is unavailable");
            string battery = Exclusive(delegate {
                byte[] bytes = new byte[15];
                for (int i = 0; i < bytes.Length; i++) bytes[i] = Read((ushort)(0x4B0 + i));
                return Encoding.ASCII.GetString(bytes);
            });
            if (battery != "AEC4168126-4S1P") throw new InvalidOperationException("Unexpected EC battery signature");
        }

        // The original implementation borrowed master A's live firmware mailbox.
        // Use the unused master E with its own register file and native bus arbitration.
        static int Transfer(byte address, byte command, bool read, int value, bool emergencyStop = false) {
            if (emergencyStop && (address != 0x09 || command != 0x14 || value != 0))
                throw new InvalidOperationException("Emergency access permits only zero-current writes and their current-register verification");
            CheckHardwareAccess(emergencyStop);
            return Exclusive(delegate {
                CheckHardwareAccess(emergencyStop);
                const ushort routeRegister=0x1C99,masterE=0x1CA0,masterEData1=0x1CA6,masterEControl2=0x1CAA;
                byte savedRoute=Read(routeRegister);
                byte savedStatus=Read(masterE),savedControl=Read((ushort)(masterE+1));
                byte savedCommand=Read((ushort)(masterE+2)),savedAddress=Read((ushort)(masterE+3));
                byte savedData0=Read((ushort)(masterE+4)),savedData1=Read(masterEData1);
                byte savedControl2=Read(masterEControl2);
                if ((savedStatus&1)!=0 || (savedControl2&1)!=0)
                    throw new InvalidOperationException("Independent SMBus master E is owned or busy");
                bool routeMayHaveChanged=false,transactionStarted=false;
                try {
                    // E and F share route configuration, so preserve F while
                    // routing the otherwise-disabled E master onto interface 0.
                    routeMayHaveChanged=true;
                    Write(routeRegister,(byte)((savedRoute&0xF8)|0x01));
                    Write(masterEControl2,(byte)(savedControl2|0x01));
                    if ((Read(masterEControl2)&1)==0) throw new InvalidOperationException("SMBus master E did not enable");

                    Write(masterE,0xFE); // HOSTA flags are write-one-to-clear.
                    Write((ushort)(masterE+2),command);
                    byte slave=(byte)((address<<1)|(read?1:0));
                    Write((ushort)(masterE+3),slave);
                    Write((ushort)(masterE+4),(byte)value);
                    Write(masterEData1,(byte)(value>>8));
                    Stopwatch busFree=Stopwatch.StartNew();
                    while((Read(0x1C00)&1)!=0 || (Read(0x1C0A)&3)!=3){
                        if(busFree.ElapsedMilliseconds>250)throw new SmbusRetryableException("Firmware SMBus master A is still using the physical bus");
                        Thread.Sleep(1);
                    }
                    transactionStarted=true;
                    Write((ushort)(masterE+1),0x4C); // START + SMBus Read/Write Word.
                    Stopwatch timeout=Stopwatch.StartNew();
                    byte status;
                    do {
                        status=Read(masterE);
                        if ((status&1)==0 && (status&0x7E)!=0) break;
                        Thread.Sleep(1);
                    } while(timeout.ElapsedMilliseconds<100);
                    if ((status&1)!=0) throw new TimeoutException("SMBus master E did not finish within 100 ms");
                    int result=Read((ushort)(masterE+4))|(Read(masterEData1)<<8);
                    if (Read((ushort)(masterE+2))!=command || Read((ushort)(masterE+3))!=slave)
                        throw new InvalidOperationException("SMBus master E response does not match its request");
                    if ((status&0x08)!=0 && (status&0x75)==0)
                        throw new SmbusArbitrationException("SMBus master E yielded arbitration to another bus master");
                    if ((status&0x7D)==0x24)
                        throw new SmbusRetryableException("SMBus master E received NACK while the charger/bus was temporarily busy");
                    if ((status&0x7D)!=0 || (status&0x02)==0)
                        throw new InvalidOperationException("SMBus master E failed; HOSTA=0x"+status.ToString("X2"));
                    if (!read && result!=value)
                        throw new InvalidOperationException("SMBus master E write data did not match the request");
                    Write(masterE,(byte)(status&0xFE));
                    if ((Read(masterE)&0xFE)!=0) throw new InvalidOperationException("SMBus master E completion did not clear");
                    return result;
                } finally {
                    if (routeMayHaveChanged) {
                        if (transactionStarted && (Read(masterE)&1)!=0) {
                            Write((ushort)(masterE+1),(byte)(Read((ushort)(masterE+1))|0x02));
                            Thread.Sleep(2);
                            Write((ushort)(masterE+1),(byte)(Read((ushort)(masterE+1))&0xFD));
                        }
                        if ((Read(masterE)&1)==0)Write(masterE,(byte)(Read(masterE)&0xFE));
                        Write(masterEControl2,savedControl2);
                        Write((ushort)(masterE+1),savedControl);
                        Write((ushort)(masterE+2),savedCommand);
                        Write((ushort)(masterE+3),savedAddress);
                        Write((ushort)(masterE+4),savedData0);
                        Write(masterEData1,savedData1);
                        Write(routeRegister,savedRoute);
                        if(Read(masterEControl2)!=savedControl2 || Read(routeRegister)!=savedRoute)
                            throw new InvalidOperationException("SMBus master E enable/route restoration failed");
                    }
                }
            });
        }

        static int ReadWord(byte address, byte command) {
            Exception last = null;
            for (int attempt = 0; attempt < 8; attempt++) {
                try { return Transfer(address, command, true, 0); }
                catch (SmbusArbitrationException error) { last = error; Thread.Sleep(5+attempt*5); }
                catch (SmbusRetryableException error) { last = error; Thread.Sleep(5+attempt*5); }
            }
            throw new InvalidOperationException("EC SMBus read failed", last);
        }
        public static int ReadCharger(byte command) {
            if(command!=0x14)return ReadWord(0x09,command);
            // Resume current must never be learnt from an implausible or torn
            // read such as FF00. Repeated consistent reads establish this word.
            for(int attempt=0;attempt<4;attempt++){
                int first=ReadWord(0x09,command);
                int second=ReadWord(0x09,command);
                if(first==second && first<=0x0F00 && (first&0x3F)==0)return first;
                Thread.Sleep(5);
            }
            throw new SmbusRetryableException("Charger current register is inconsistent or outside its verified range");
        }
        public static int ReadBattery(byte command) { return ReadWord(0x0B, command); }
        public static int BatteryCurrent() { return (short)ReadBattery(0x0A); }

        public static byte[] ReadEcRam(ushort address, int length) {
            if (address < 0x0400 || length < 1 || (int)address + length > 0x1000)
                throw new ArgumentOutOfRangeException("address");
            return Exclusive(delegate {
                byte[] bytes = new byte[length];
                for (int i = 0; i < length; i++) bytes[i] = Read((ushort)(address + i));
                return bytes;
            });
        }

        // Repair only the captured missing BAT0._STA presence bit. This is
        // EC RAM, not a charger command. The exact offline fault, the original
        // pack signature and coherent live discharge telemetry are mandatory.
        // Preserve every other flag, including Critical and AC state.
        public static byte RepairCapturedBatteryPresence() {
            ValidateBatterySignature();
            return Exclusive(delegate {
                byte flags=Read(0x0460);
                if(flags!=0xA8 || Read(0x0461)!=0x98)
                    throw new InvalidOperationException("Captured offline cache fault is not present; no repair write issued");
                int design=Read(0x0464)|(Read(0x0465)<<8);
                int full=Read(0x0468)|(Read(0x0469)<<8);
                int current=Read(0x046C)|(Read(0x046D)<<8);
                int remaining=Read(0x046E)|(Read(0x046F)<<8);
                int voltage=Read(0x0470)|(Read(0x0471)<<8);
                int soc=Read(0x047C);
                int available=(Read(0x048E)<<8)|Read(0x048F);
                if(design!=9594 || full!=9594 || current<100 || current>6000 ||
                    remaining<full/5 || remaining>full || voltage<12000 || voltage>18000 ||
                    soc<20 || soc>100 || Math.Abs(soc-100.0*remaining/full)>2 || available!=0)
                    throw new InvalidOperationException("Live pack does not confirm coherent offline discharge; no repair write issued");
                if(Read(0x0460)!=flags || Read(0x0461)!=0x98)
                    throw new InvalidOperationException("Supply state changed during repair; no write issued");
                Write(0x0460,(byte)(flags|2));
                byte after=Read(0x0460);
                if(after!=(byte)(flags|2))
                    throw new InvalidOperationException("Presence repair read-back differs from the single-bit request");
                return after;
            });
        }

        // Fixed, read-only controller diagnostics. No transaction is submitted.
        public static byte RepairCapturedOfflineAdapterCode() {
            ValidateBatterySignature();
            return Exclusive(delegate {
                byte flags=Read(0x0460);
                if(flags!=0xAA || Read(0x0461)!=0x98)
                    throw new InvalidOperationException("Captured remaining offline source fault is not present");
                int current=Read(0x046C)|(Read(0x046D)<<8);
                int available=(Read(0x048E)<<8)|Read(0x048F);
                if(current<100 || current>6000 || available!=0 || Read(0x0460)!=flags)
                    throw new InvalidOperationException("Offline source cannot be confirmed; no repair write issued");
                // PAWT=0 is the previously captured no-adapter state. No
                // charging, battery alarm, capacity or reserved flag is changed.
                Write(0x0461,0);
                byte after=Read(0x0461);
                if(after!=0)throw new InvalidOperationException("Offline source repair did not read back zero");
                return after;
            });
        }

        public static string CaptureSmbusController() {
            return Exclusive(delegate {
                byte[] frame=new byte[6];
                for(int i=0;i<frame.Length;i++)frame[i]=Read((ushort)(0x1C00+i));
                return "frame="+BitConverter.ToString(frame)+"; irq_status="+Read(0x1101).ToString("X2")+
                    "; irq_enable="+Read(0x1105).ToString("X2")+"; irq_mode="+Read(0x1109).ToString("X2")+
                    "; control2="+Read(0x1C10).ToString("X2");
            });
        }

        public static string CaptureSmbusChannels() {
            return Exclusive(delegate {
                StringBuilder result=new StringBuilder();
                ushort[] bases={0x1C00,0x1C11,0x1C29,0x1C35,0x1CA0,0x1CB0};
                ushort[] controls={0x1C10,0x1C21,0x1C32,0x1C3E,0x1CAA,0x1CBA};
                for(int c=0;c<bases.Length;c++){
                    byte[] frame=new byte[6];
                    for(int i=0;i<frame.Length;i++)frame[i]=Read((ushort)(bases[c]+i));
                    result.Append((char)('A'+c)).Append('=').Append(BitConverter.ToString(frame)).Append('/').Append(Read(controls[c]).ToString("X2")).Append(';');
                }
                return result.Append("route=").Append(Read(0x1C60).ToString("X2")).Append('-').Append(Read(0x1C61).ToString("X2")).Append('-').Append(Read(0x1C99).ToString("X2")).ToString();
            });
        }

        public static void SetChargeCurrent(int value) {
            if (value < 0 || value > 0x0F00 || (value&0x3F)!=0)
                throw new ArgumentOutOfRangeException("value", "Current exceeds the verified original setting");
            for(int attempt=0;attempt<8;attempt++){
                try{
                    Transfer(0x09,0x14,false,value);
                    if(ReadCharger(0x14)!=value)throw new SmbusRetryableException("Firmware changed the requested current before verification");
                    return;
                }catch(SmbusArbitrationException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
                catch(SmbusRetryableException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
            }
        }

        public static PauseEnforcementResult EnforceChargePause() {
            // A requested pause always writes zero, regardless of an implausible
            // positive read. Do not postpone stopping to learn a resume value.
            Stopwatch elapsed=Stopwatch.StartNew();
            for(int attempt=0;attempt<8;attempt++){
                try{
                    int before=Transfer(0x09,0x14,true,0);
                    if(before==0)return new PauseEnforcementResult{ObservedCurrent=0,ZeroWritten=false,ElapsedMilliseconds=elapsed.Elapsed.TotalMilliseconds};
                    Transfer(0x09,0x14,false,0);
                    if(Transfer(0x09,0x14,true,0)!=0)throw new SmbusRetryableException("Charger current was restored before zero verification");
                    return new PauseEnforcementResult{ObservedCurrent=before,ZeroWritten=true,ElapsedMilliseconds=elapsed.Elapsed.TotalMilliseconds};
                }catch(SmbusArbitrationException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
                catch(SmbusRetryableException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
            }
            throw new InvalidOperationException("Unable to confirm zero charger current");
        }

        public static bool SetChargerInhibit(bool inhibit) {
            int value=inhibit?1:0;
            for(int attempt=0;attempt<8;attempt++){
                try{
                    // SBS Smart Battery Charger Specification 1.1:
                    // ChargerMode(0x12) bit 0 is INHIBIT_CHARGE; ChargerStatus
                    // (0x13) bit 0 reports the resulting state.
                    Transfer(0x09,0x12,false,value);
                    int status=ReadWord(0x09,0x13);
                    if(((status&1)!=0)!=inhibit)
                        throw new SmbusRetryableException("ChargerStatus bit 0 did not match ChargerMode inhibit request");
                    return true;
                }catch(SmbusArbitrationException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
                catch(SmbusRetryableException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
                catch(InvalidOperationException error){
                    if(error.Message.Contains("HOSTA=") || error.Message.Contains("NACK") || error.Message.Contains("status") || error.Message.Contains("response") || error.Message.Contains("SMBus master E failed")){
                        if(attempt==7)throw;Thread.Sleep(5+attempt*5);
                    }else{throw;}
                }
            }
            throw new InvalidOperationException("ChargerMode inhibit request was not confirmed");
        }

        // Explicitly invoked containment: write zero, then verify only the
        // charger current register. No smart-battery transactions or retries.
        public static void EmergencyPauseCharging() {
            ValidateBatterySignature();
            for(int attempt=0;attempt<8;attempt++){
                try{
                    Transfer(0x09, 0x14, false, 0, true);
                    if (Transfer(0x09, 0x14, true, 0, true) != 0)
                        throw new InvalidOperationException("Zero charging current was not retained");
                    return;
                }catch(SmbusArbitrationException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
                catch(SmbusRetryableException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
            }
        }

        public static int ReadObservedChargeCurrent() {
            // This reads the last completed firmware frame, not the charger.
            // -1 means no suitable cached frame is currently available.
            return Exclusive(delegate {
                byte[] first=new byte[6];
                for(int i=0;i<6;i++)first[i]=Read((ushort)(0x1C00+i));
                if(first[0]!=0 || first[2]!=0x14 || (first[3]>>1)!=0x09)return -1;
                for(int i=0;i<6;i++)if(Read((ushort)(0x1C00+i))!=first[i])return -1;
                return first[4] | (first[5]<<8);
            });
        }

        public static int ReadEmergencyChargeCurrent() {
            for(int attempt=0;attempt<8;attempt++){
                try{return Transfer(0x09,0x14,true,0,true);}
                catch(SmbusArbitrationException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
                catch(SmbusRetryableException){if(attempt==7)throw;Thread.Sleep(5+attempt*5);}
            }
            throw new InvalidOperationException("Charger current could not be read");
        }

        public static int ReadChargerThroughFirmwareMailbox(byte command) {
            if (command != 0x14 && command != 0xFE && command != 0xFF)
                throw new ArgumentOutOfRangeException("command");
            // Queue a read for firmware instead of modifying its host controller.
            // This operation never writes a register on the charger or battery.
            return Exclusive(delegate {
                byte[] saved=new byte[6];
                for(int i=0;i<saved.Length;i++)saved[i]=Read((ushort)(0x0428+i));
                if(saved[0]!=0)throw new InvalidOperationException("Firmware SMBus mailbox is busy");
                for(int i=0;i<saved.Length;i++)
                    if(Read((ushort)(0x0428+i))!=saved[i])
                        throw new InvalidOperationException("Firmware mailbox changed before request");
                byte address=0x12;
                bool issued=false;
                try {
                    Write(0x042B,command);Write(0x042A,address);
                    Write(0x0429,0);Write(0x0428,0x09);issued=true;
                    Stopwatch timeout=Stopwatch.StartNew();
                    while(timeout.ElapsedMilliseconds<1200) {
                        byte status=Read(0x0429);
                        if(Read(0x042A)!=address || Read(0x042B)!=command)
                            throw new InvalidOperationException("Firmware mailbox response does not belong to this request");
                        if((status&0x80)!=0) {
                            if((status&0x1F)!=0)throw new InvalidOperationException("Firmware mailbox returned error "+status.ToString("X2"));
                            return Read(0x042C)|(Read(0x042D)<<8);
                        }
                        Thread.Sleep(10);
                    }
                    throw new TimeoutException("Firmware did not complete the charger mailbox read");
                } finally {
                    if(issued && Read(0x042A)==address && Read(0x042B)==command &&
                        (Read(0x0428)==0x09 || Read(0x0428)==0)) {
                        Write(0x0428,0);
                        for(int i=1;i<saved.Length;i++)Write((ushort)(0x0428+i),saved[i]);
                    }
                }
            });
        }
    }
}
