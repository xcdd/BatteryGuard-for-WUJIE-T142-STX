# BatteryGuard for WUJIE T142 STX

Windows 11 charge protection, FN+X performance profiles, display refresh policy, cooling and a tray control panel for the **WUJIE Series-T142-STX** motherboard with **T142_STXKRK_V13** BIOS.

This is a source-only preview for this specific machine. Other EC layouts, firmware versions and AMD platforms are not supported. Installation checks the board and BIOS before starting hardware control.

## Features

- Charge limit and pause controls use the independently verified SMBus E path, with current readback and a worker/supervisor. Firmware reassertions are corrected; repeated pause notifications are suppressed.
- FN+X selects Quiet, Normal and Performance. Battery use allows Quiet and Normal. The brief on-screen message shows the mode only.
- CPU limits: Quiet 30 W sustained / 35 W fast; Normal 45 / 54 W; externally powered Performance 80 / 96 W with the factory 99 C thermal setting. DC and the tested Type-C source use the same CPU package. Whole-machine consumption is a separate measurement. Known Type-C budgets below 45 W retain the Normal cap; unknown sources remain capped.
- Performance requests apply the full 19-command native firmware profile. Valid firmware changes are reapplied in the same session; failed native sessions are not repeatedly remapped.
- Battery use selects 60 Hz; external power restores the highest available display refresh rate.
- Performance cooling requests both fans at 100% from 85 C, maintained every 50 ms. Other modes, battery operation and worker failure restore automatic fans. Duty readback is reported; manual-mode RPM is not presented as a measured value.
- The WPF interface has separate Performance, Fans, Charge and Settings tabs, a tray icon and login startup. Temporary JSON sharing conflicts clear automatically after a successful refresh; genuine hardware/action errors remain visible.

## Installation

Use a permanent local folder for the clone; scheduled tasks continue to reference it. Required environment: 64-bit Windows PowerShell 5.1, .NET Framework, administrator access and the board/BIOS above. Obtain and verify the external libraries as described in [DEPENDENCIES.md](DEPENDENCIES.md). They are deliberately not included in this source package.

From an **administrator Windows PowerShell 5.1** window in the source directory:

```powershell
.\Setup.ps1 -WhatIf
.\Setup.ps1
```

Setup preserves existing charge/fan preferences, checks dependency hashes, compiles the performance backend and configures login startup plus the hidden tray panel. It does not force Performance at every boot: policy follows the actual firmware mode and current power source. Default charge limit is 80%, with pause off. Default cooling is restricted to externally powered Performance.

Windows native charge-protection text is an optional, build-specific integration:

```powershell
.\Setup.ps1 -NativeStatus
```

That interface is tested only on Windows build **26200**. It changes the native protection notification; the taskbar heart overlay has **not** been achieved on the tested shell. The app's charge state is based on actual current. On other builds omit the option. The integration is not an ACPI patch or a replacement battery device.

## Daily startup

`BatteryGuard-PerformanceTelemetry` and `BatteryGuard-BackgroundRecovery` run at the user's login. Recovery maintains the charge observer/supervisor, power events, FN+X/display policy and fan worker. `HKCU Run\BatteryGuardPanel` opens the interface hidden in the tray; clicking the tray icon opens it. The optional `BatteryGuard-NativeStatus` task runs at system startup as SYSTEM.

An explicit Exit closes the panel for the current login session while the hardware policies continue. No reboot, logout or hibernation is performed by Setup or Uninstall.

## Restore and remove startup policies

Do **not** terminate the charge worker as an uninstall method: stopping it alone can leave the charge-current register at zero.

```powershell
.\Uninstall.ps1 -WhatIf
.\Uninstall.ps1
```

Uninstall first turns charge protection off through the worker and waits for the matching applied revision and confirmed release. If our pause is active, external power must be connected so restoration can be verified. If the battery cannot yet request charging or the worker is unavailable, it stops with an error and leaves the workers installed. It then prevents respawn, requests cooperative shutdown, verifies automatic fans, restores an OEM Normal/Quiet profile and removes only owned startup entries. Source files, installed dependency files, preferences and diagnostics are retained for inspection. Stop/maintenance flags are retained; inspect and remove those explicit flags before a later reinstall.

The new unified installer/uninstaller has been checked offline and with `-WhatIf`. A clean-machine installation and live uninstall have not been exercised on the production laptop, to avoid disturbing its verified controls. The individual installed policies have been verified running on the target laptop.

## Verification and development

Run software-only validation without loading hardware drivers or stress-testing the laptop:

```powershell
.\VerifySourcePackage.ps1
```

It parses all PowerShell sources, compiles the C# components without executing their entry points, runs the power-policy, OEM mailbox transport, RAPL conversion, fan policy/transport, path configuration and panel-recovery tests, and previews Setup/Uninstall. Tests use controlled transport/file fixtures; they do not lock live runtime files.

`BuildSourcePackage.ps1` exports an explicit source allowlist, sanitized firmware facts and safe defaults. Personal session logs, runtime files, memory/firmware dumps, screenshots, benchmarks and obsolete diagnostic/repair scripts are excluded. `agent/progress.jsonl` and `agent/findings.jsonl` are the two development journals; they are private and ignored by Git. Runtime diagnostic files are also ignored.

## Validation on the target machine

Externally powered CPU Package power reached approximately 92.28 W; the independent RAPL measurement was 92.21 W at approximately 95.71 C. Quiet/Normal/Performance limit readback and all 19 acknowledgements were checked. A battery cycle verified the battery profiles, automatic fans and 60 Hz, then restored 80/96 W and the highest refresh on reconnection. High-temperature duty readback showed 99-100% before maintenance and 100% after it. These are measurements from one machine, not performance guarantees for other devices.

Type-C PD renegotiation/repair and increasing the factory temperature limit are outside this release. The reported adapter budget is firmware telemetry, not a measurement of whole-machine consumption. No additional idle-power saving beyond Quiet's verified factory policy and the battery refresh policy is claimed.

## License

Original project code is MIT licensed. External dependencies and the fan-control reference retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Do not add DLL/SYS binaries to a public release without preserving and reviewing their upstream licensing obligations.
