$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'ChargeControl.ps1')
$policy=Join-Path $root 'PanelStatusPolicy.ps1'
if(-not(Test-Path -LiteralPath $policy)){throw 'Panel refresh recovery policy is missing'}
. $policy
$tempFile=Join-Path ([IO.Path]::GetTempPath()) ('batteryguard-json-test-'+[guid]::NewGuid().ToString()+'.json')
$locked=$null
try {
 [IO.File]::WriteAllText($tempFile,'{"phase":"curve"}')
 $locked=[IO.FileStream]::new($tempFile,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $failure=$null
 try{Read-ControlJson $tempFile|Out-Null}catch{$failure=$_}
 if(-not $failure -or (Get-PanelRefreshErrorKind $failure)-ne 'transient'){throw 'A real exclusive JSON-file lock must be classified as a transient refresh failure'}
 $locked.Dispose();$locked=$null
 if((Read-ControlJson $tempFile).phase-ne 'curve'){throw 'The state did not become readable after releasing the lock'}
 # ASCII-only fixture: it must not be corrupted by the same source decoding as the policy.
 $expectedRecovery=-join (@(0x72B6,0x6001,0x5DF2,0x6062,0x590D)|ForEach-Object {[char]$_})
 if((Get-PanelRecoveredMessage 'refresh')-ne $expectedRecovery){throw 'Recovered Chinese status was corrupted by Windows PowerShell source decoding'}
 if($null-ne (Get-PanelRecoveredMessage 'action')){throw 'A healthy refresh must not erase an unconfirmed user action error'}
 if($null-ne (Get-PanelRecoveredMessage 'hardware')){throw 'A healthy refresh must not erase a genuine hardware error'}
 $denied=[Management.Automation.ErrorRecord]::new([UnauthorizedAccessException]::new('denied'),'test',[Management.Automation.ErrorCategory]::PermissionDenied,$null)
 if((Get-PanelRefreshErrorKind $denied)-ne 'error'){throw 'A permission failure must not be silently classified as a file-sharing transient'}
 'PASS: real JSON lock/recovery and action/hardware error preservation'
}finally{if($locked){$locked.Dispose()};if(Test-Path -LiteralPath $tempFile){Remove-Item -LiteralPath $tempFile}}
