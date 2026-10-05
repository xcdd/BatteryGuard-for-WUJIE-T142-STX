$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\driver\RaplPower.cs'
if(-not(Test-Path $source)){throw 'Independent RAPL power conversion is not implemented'}
Add-Type -Path $source
$power=[BatteryGuard.RaplPower]::Calculate(100000,755360,16,0.5)
if([math]::Abs($power-20)-gt 0.00001){throw 'Energy units or interval conversion is wrong'}
$wrapped=[BatteryGuard.RaplPower]::Calculate([uint32]4294967040,[uint32]256,16,0.5)
if([math]::Abs($wrapped-0.015625)-gt 0.000001){throw '32-bit energy counter rollover is wrong'}
$caught=$false
try{[void][BatteryGuard.RaplPower]::Calculate(1,2,16,0)}catch{$caught=$true}
if(-not $caught){throw 'Zero-length intervals must not produce a fake watt reading'}
'PASS: 3 RAPL conversion cases'
