# External dependencies

This source-only package contains no DLL, SYS or EXE files. Hardware access is through privileged third-party libraries. Windows policies may block these drivers; the application does not change driver-blocklist, Memory Integrity or Secure Boot settings.

Use the Windows x64 assets from [RyzenAdj v0.19.0](https://github.com/FlyGoat/RyzenAdj/releases/tag/v0.19.0). Keep `driver/ryzenadj/manifest.json` as the pinned checksum manifest and place the following four files in `driver/ryzenadj/`:

| File | SHA-256 |
| --- | --- |
| inpoutx64.dll | 5F27ED4D5CD58A1EE23DEEB802E09E73F3A1D884CE2135F6E827F67B171269E7 |
| libryzenadj.dll | 498DF2E9278C33BA7BA7BFB8BDCA93033941896D9E156C37AF382D31482EDCD5 |
| WinRing0x64.dll | A746FD5728E7485F741CC330A279674BC8590B1B8007D8614046C49F58698485 |
| WinRing0x64.sys | 11BD2C9F9E2397C9A16E0990E4ED2CF0679498FE0FD418A3DFDAC60B5C160EE5 |

Copy that same `inpoutx64.dll` into `driver/x64/`. The original InpOut source/distribution is [Highrez InpOut](https://www.highrez.co.uk/downloads/inpout32/default.htm). A different build will have a different checksum and needs a deliberate dependency update and validation; do not merely bypass the hash check.

To validate before installation:

```powershell
. .\DependencyPolicy.ps1
Assert-BatteryGuardDependencies $PWD.Path
```

RyzenAdj remains a dynamically loaded library, separate from our application. Source: [FlyGoat/RyzenAdj](https://github.com/FlyGoat/RyzenAdj/tree/v0.19.0). Rebuild/replace it according to its LGPL terms and update the checksum manifest after validation. The program does not use `set_stapm_time`, whose Strix path can issue an unintended extra request; timing is included through this board's OEM mailbox mapping.
