<#
  Phase 1 - Prove the SharedDeviceLogout action works, straight from your PC.
  Run in PowerShell 7 on your Windows machine (not on the device, not in Azure).
  Prompts for credentials - nothing is hardcoded, safe to commit.

  Before running: log in on the test S24 FE as a Shared Device (Entra) user.
#>

param(
    [string]$BaseUrl    = "https://s116505.mobicontrolcloud.com/MobiControl/api",
    [Parameter(Mandatory)] [string]$DeviceName,          # device name as shown in the MobiControl console
    [string]$Action     = "LogOut"
)

$BaseUrl = $BaseUrl.TrimEnd('/')

# --- Credentials (prompted, never stored) ---
$clientId  = Read-Host "API Client ID"
$secret    = Read-Host "API Client Secret" -AsSecureString
$userCred  = Get-Credential -Message "MobiControl API user"

$plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secret))
$basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${clientId}:${plainSecret}"))

# --- 1. Token ---
$token = Invoke-RestMethod -Method Post -Uri "$BaseUrl/token" `
    -Headers @{ Authorization = "Basic $basic" } `
    -ContentType 'application/x-www-form-urlencoded' `
    -Body @{
        grant_type = 'password'
        username   = $userCred.UserName
        password   = $userCred.GetNetworkCredential().Password
    }
$headers = @{ Authorization = "Bearer $($token.access_token)" }
Write-Host "Token OK" -ForegroundColor Green

# --- 2. Find the device ---
$devices = Invoke-RestMethod -Uri "$BaseUrl/devices?take=4000" -Headers $headers
$device  = $devices | Where-Object { $_.DeviceName -eq $DeviceName }

if (-not $device) { Write-Host "No device named '$DeviceName' found." -ForegroundColor Red; return }
if (@($device).Count -gt 1) { Write-Host "More than one device named '$DeviceName'. Rename or pick by ID." -ForegroundColor Red; return }

Write-Host "Device ID : $($device.DeviceId)"
Write-Host "Path      : $($device.Path)"

# --- 3. Confirm, then send the logout action ---
$answer = Read-Host "Send '$Action' to this device? (y/n)"
if ($answer -ne 'y') { Write-Host "Cancelled."; return }

$body = @{ Action = $Action } | ConvertTo-Json -Compress
try {
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/devices/$([uri]::EscapeDataString($device.DeviceId))/actions" `
        -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
    Write-Host "Action accepted. Watch the device - it should return to the login screen." -ForegroundColor Green
}
catch {
    Write-Host "Action failed: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
}
