# Quick test of the deployed function from your PC (before involving the device).
param(
    [Parameter(Mandatory)] [string]$FunctionUrl,   # https://<app>.azurewebsites.net/api/SharedDeviceLogout
    [Parameter(Mandatory)] [string]$DeviceId
)
$key = Read-Host -Prompt 'Function key' -AsSecureString
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($key))
Invoke-RestMethod -Method Post -Uri $FunctionUrl `
    -Headers @{ 'x-functions-key' = $plain } `
    -ContentType 'application/json' `
    -Body (@{ deviceId = $DeviceId } | ConvertTo-Json)
