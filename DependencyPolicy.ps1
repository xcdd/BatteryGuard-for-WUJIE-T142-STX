#requires -Version 5.1
function Assert-BatteryGuardDependencies([string]$root) {
    $vendor=Join-Path $root 'driver\ryzenadj'
    $manifest=Get-Content -LiteralPath (Join-Path $vendor 'manifest.json') -Raw|ConvertFrom-Json
    foreach($entry in $manifest.files){
        $file=Join-Path $vendor $entry.name
        if(-not(Test-Path -LiteralPath $file -PathType Leaf)){throw ('Missing dependency: '+$file+'. See DEPENDENCIES.md')}
        if((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash-ne $entry.sha256){throw ('Dependency hash mismatch: '+$entry.name)}
    }
    $io=Join-Path $root 'driver\x64\inpoutx64.dll'
    $expected=($manifest.files|Where-Object name -eq 'inpoutx64.dll').sha256
    if(-not(Test-Path -LiteralPath $io -PathType Leaf)){throw 'Missing driver\x64\inpoutx64.dll. See DEPENDENCIES.md'}
    if((Get-FileHash -LiteralPath $io -Algorithm SHA256).Hash-ne $expected){throw 'InpOut dependency hash mismatch'}
}
