#requires -Version 5.1
$ErrorActionPreference='Stop'
$source=Join-Path $PSScriptRoot '..\driver\SourceRootConfiguration.cs'
if(-not(Test-Path -LiteralPath $source)){throw 'Portable source-root configuration is missing'}
Add-Type -Path $source
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('BatteryGuard source test '+[guid]::NewGuid())
$install=Join-Path $fixture 'install'
$sourceRoot=Join-Path $fixture 'clone with spaces'
New-Item -ItemType Directory -Path $install,(Join-Path $sourceRoot 'agent') -Force|Out-Null
$configuration=Join-Path $install 'source-root.txt'
try{
    $rejected=$false
    try{[void][BatteryGuard.SourceRootConfiguration]::Resolve($install)}catch{$rejected=$true}
    if(-not $rejected){throw 'Missing source-root configuration must fail before hardware startup'}
    [IO.File]::WriteAllText($configuration,$sourceRoot+[Environment]::NewLine)
    $actual=[BatteryGuard.SourceRootConfiguration]::Resolve($install)
    if($actual-ne $sourceRoot){throw 'An arbitrary clone path containing spaces was not resolved'}
    [IO.File]::WriteAllText($configuration,'..\clone with spaces')
    $rejected=$false
    try{[void][BatteryGuard.SourceRootConfiguration]::Resolve($install)}catch{$rejected=$true}
    if(-not $rejected){throw 'Relative configuration must not depend on the scheduled task working directory'}
    [IO.File]::WriteAllText($configuration,(Join-Path $fixture 'missing'))
    $rejected=$false
    try{[void][BatteryGuard.SourceRootConfiguration]::Resolve($install)}catch{$rejected=$true}
    if(-not $rejected){throw 'A removed clone must be rejected before hardware startup'}
    'PASS: 4 portable source-root configuration cases'
}finally{
    $absolute=[IO.Path]::GetFullPath($fixture)
    if(-not $absolute.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)){throw 'Fixture cleanup escaped temp'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
