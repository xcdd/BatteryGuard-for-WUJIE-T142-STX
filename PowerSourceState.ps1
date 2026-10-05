#requires -Version 5.1
function Resolve-ControlPowerSource([int]$flags,[int]$adapter,[int]$current,[bool]$windowsOnline,[bool]$windowsBatteryPresent) {
    $ecPresent=($flags -band 2)-ne 0
    $ecOnline=($flags -band 1)-ne 0
    $validAdapter=$adapter -in @(0,1,2,4)
    $valid=$ecPresent -and $validAdapter
    # A corrupt presence/source cache must not turn actual charging into an
    # offline state and thereby bypass the user's pause request.
    if($valid){$online=$ecOnline;$basis='ec'}
    elseif($current -gt 50){$online=$true;$basis='positive_battery_current'}
    elseif($current -lt -50 -and -not $ecOnline){$online=$false;$basis='battery_discharge'}
    else{$online=$windowsOnline;$basis='windows_fallback'}
    $source=if(-not $online){'Battery'}elseif($validAdapter -and $adapter-eq 4){'DC'}elseif($validAdapter -and $adapter-in @(1,2)){'TypeC'}else{'External'}
    [pscustomobject]@{online=$online;source=$source;port=$(if($source-eq 'TypeC'){$adapter}else{0});ec_valid=$valid;ec_battery_present=$ecPresent;windows_battery_present=$windowsBatteryPresent;basis=$basis;warning=$(if(-not $valid){'EC battery presence/source cache is invalid; external power must not be inferred from bit 0 alone'}else{''})}
}
