function Get-PanelRefreshErrorKind($record) {
    $exception=$record.Exception
    while($exception){
        if($exception -is [IO.IOException]){
            $code=$exception.HResult -band 0xFFFF
            if($code-in @(2,3,32,33)){return 'transient'}
        }
        $exception=$exception.InnerException
    }
    return 'error'
}
function Get-PanelRecoveredMessage([string]$source) {
    if($source-eq 'refresh'){return '状态已恢复'}
    return $null
}
