#requires -Version 5.1
$script:FirmwarePowerTablePath=Join-Path $PSScriptRoot 'agent\firmware-power-table.json'
function Get-FirmwarePowerBudget($observation){
    if(-not $observation -or $observation.performance_mode_code-notin @(0,1,2)){return $null}
    $mode=[int]$observation.performance_mode_code
    $available=[int]$observation.adapter_available_w
    $online=[bool]$observation.online
    # The <=65 W AC branch precedes CPUR and all mode branches in FNQS.
    if($online -and $available-le 65){$index=4}
    else{
        if($null-eq $observation.cpu_profile_code -or $null-eq $observation.battery_design_capacity_raw){return $null}
        if([int]$observation.cpu_profile_code-eq 1){
            switch($mode){
                2{$index=if($online){3}else{4}}
                1{$index=if($online){if($available-gt 100){1}else{13}}elseif([int]$observation.battery_design_capacity_raw-lt 9000){10}else{2}}
                0{if(-not $online){return $null};$index=if($available-gt 100){0}else{12}}
            }
        }else{
            switch($mode){
                2{$index=if($online){8}else{9}}
                1{$index=if($online){6}elseif([int]$observation.battery_design_capacity_raw-lt 9000){11}else{7}}
                0{if(-not $online){return $null};$index=if($available-gt 100){5}else{14}}
            }
        }
    }
    $table=Read-ControlJson $script:FirmwarePowerTablePath
    $entry=@($table.packages)|Where-Object index -eq $index|Select-Object -First 1
    if(-not $entry){return $null}
    [pscustomobject]@{
        package_index=$index;selector_05_w=($entry.alib_05_mw/1000.0)
        selector_06_w=($entry.alib_06_mw/1000.0);selector_07_w=($entry.alib_07_mw/1000.0)
        sustained_limit_w=([math]::Min($entry.alib_05_mw,$entry.alib_07_mw)/1000.0)
        fast_ppt_limit_w=($entry.alib_06_mw/1000.0)
        parameter_definition_source='RyzenAdj v0.19.0 lib/api.c: ALIB 05=STAPM, 06=Fast PPT, 07=Slow PPT'
        basis='firmware-configured';smu_readback=$false;observed_at=$observation.time
    }
}
