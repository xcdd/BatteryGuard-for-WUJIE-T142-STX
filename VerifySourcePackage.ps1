#requires -Version 5.1
$ErrorActionPreference='Stop'
if($PSVersionTable.PSEdition-ne 'Desktop'){throw 'Run with Windows PowerShell 5.1'}
$parseFailures=@()
$nestedExport=(Join-Path $PSScriptRoot 'release').TrimEnd('\')+'\'
$scripts=@(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -Recurse|Where-Object {-not $_.FullName.StartsWith($nestedExport,[StringComparison]::OrdinalIgnoreCase)})
if($scripts.Count-eq 0){throw 'No PowerShell files were discovered; syntax verification cannot pass'}
foreach($file in $scripts){
    $bytes=[IO.File]::ReadAllBytes($file.FullName)
    $text=[Text.Encoding]::UTF8.GetString($bytes)
    $hasBom=$bytes.Length-ge 3 -and $bytes[0]-eq 0xEF -and $bytes[1]-eq 0xBB -and $bytes[2]-eq 0xBF
    if($text-match '[^\x00-\x7F]' -and -not $hasBom){throw ($file.Name+': non-ASCII PowerShell source requires UTF-8 BOM for Windows PowerShell 5.1')}
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    foreach($error in $errors){$parseFailures+=@($file.Name+': '+$error.Message)}
}
if($parseFailures.Count){throw ($parseFailures -join [Environment]::NewLine)}
'PASS: PowerShell parse ('+$scripts.Count+' files)'
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
foreach($test in @('TestSourceRootConfiguration.ps1','TestPerformancePowerPolicy.ps1','TestOemSurfaceMailbox.ps1','TestFanFullDuty.ps1','VerifyFanPolicy.ps1','TestRaplPower.ps1','TestPanelStatusRecovery.ps1')){
    & $exe -NoProfile -File (Join-Path $PSScriptRoot ('agent\'+$test))
    if($LASTEXITCODE-ne 0){throw ('Software test failed: '+$test)}
}
$temporary=Join-Path ([IO.Path]::GetTempPath()) ('BatteryGuard-build-'+[guid]::NewGuid()+'.exe')
try{
    $sources=@(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'driver') -Filter '*.cs'|ForEach-Object FullName)
    Add-Type -Path $sources -ReferencedAssemblies System.dll,System.Management.dll,System.Web.Extensions.dll -OutputAssembly $temporary -OutputType WindowsApplication
    'PASS: all C# components compiled; hardware entry point was not executed'
}finally{
    if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}
}
& $exe -NoProfile -File (Join-Path $PSScriptRoot 'Setup.ps1') -WhatIf
if($LASTEXITCODE-ne 0){throw 'Setup preview failed'}
& $exe -NoProfile -File (Join-Path $PSScriptRoot 'Uninstall.ps1') -WhatIf
if($LASTEXITCODE-ne 0){throw 'Uninstall preview failed'}
'PASS: source package offline verification'
