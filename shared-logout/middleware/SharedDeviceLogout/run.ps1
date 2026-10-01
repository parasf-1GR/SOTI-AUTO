using namespace System.Net

<#
  SharedDeviceLogout - Azure Function (PowerShell, HTTP trigger)

  Receives { "deviceId": "<MobiControl device ID>" } from the Log out app and
  asks MobiControl to end the Shared Device session on that device.

  The function key (x-functions-key) authenticates the caller.
  MobiControl API credentials live ONLY here, in App Settings (ideally Key Vault references):
    MC_BASE_URL          e.g. https://<tenant>.mobicontrol.cloud/MobiControl/api
    MC_CLIENT_ID / MC_CLIENT_SECRET / MC_USERNAME / MC_PASSWORD
    ALLOWED_PATH_PREFIX  optional, e.g. \\Customer\SharedDevices  (must cover BOTH the
                         login group and the logged-in group the device is relocated to)
    MC_LOGOUT_ACTION     optional, defaults to SharedDeviceLogout
#>

param($Request, $TriggerMetadata)

function Send-Response {
    param([HttpStatusCode]$Code, [string]$Message)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $Code
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ message = $Message } | ConvertTo-Json -Compress)
    })
}

# --- 1. Validate input ---------------------------------------------------
$deviceId = $Request.Body.deviceId
if ([string]::IsNullOrWhiteSpace($deviceId) -or $deviceId -notmatch '^[A-Za-z0-9_.\-]{1,128}$') {
    Send-Response -Code BadRequest -Message 'Invalid or missing deviceId.'
    return
}

foreach ($name in 'MC_BASE_URL','MC_CLIENT_ID','MC_CLIENT_SECRET','MC_USERNAME','MC_PASSWORD') {
    if (-not [Environment]::GetEnvironmentVariable($name)) {
        Write-Error "Missing app setting: $name"
        Send-Response -Code InternalServerError -Message 'Service not configured.'
        return
    }
}

$base     = $env:MC_BASE_URL.TrimEnd('/')
$action   = if ($env:MC_LOGOUT_ACTION) { $env:MC_LOGOUT_ACTION } else { 'SharedDeviceLogout' }
$idInPath = [uri]::EscapeDataString($deviceId)

# --- 2. Get a MobiControl token (password grant, Basic clientId:secret) ---
try {
    $basic = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:MC_CLIENT_ID):$($env:MC_CLIENT_SECRET)"))
    $token = Invoke-RestMethod -Method Post -Uri "$base/token" `
        -Headers @{ Authorization = "Basic $basic" } `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type = 'password'; username = $env:MC_USERNAME; password = $env:MC_PASSWORD }
}
catch {
    Write-Error "Token request failed: $($_.Exception.Message)"
    Send-Response -Code BadGateway -Message 'Could not authenticate to MobiControl.'
    return
}
$headers = @{ Authorization = "Bearer $($token.access_token)" }

# --- 3. Optional guard: only act on devices inside the allowed group tree --
if ($env:ALLOWED_PATH_PREFIX) {
    try {
        $device = Invoke-RestMethod -Method Get -Uri "$base/devices/$idInPath" -Headers $headers
    }
    catch {
        Send-Response -Code NotFound -Message 'Device not found.'
        return
    }
    if (-not $device.Path -or -not $device.Path.StartsWith($env:ALLOWED_PATH_PREFIX, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Warning "Rejected logout for $deviceId (path '$($device.Path)')"
        Send-Response -Code Forbidden -Message 'Device is not in an allowed group.'
        return
    }
}

# --- 4. Send the Shared Device logout action ------------------------------
try {
    $body = @{ Action = $action } | ConvertTo-Json -Compress
    Invoke-RestMethod -Method Post -Uri "$base/devices/$idInPath/actions" `
        -Headers $headers -ContentType 'application/json' -Body $body | Out-Null
}
catch {
    Write-Error "Logout action failed for ${deviceId}: $($_.Exception.Message)"
    Send-Response -Code BadGateway -Message 'MobiControl rejected the logout request.'
    return
}

Write-Information "Logout requested for $deviceId"
Send-Response -Code OK -Message 'Logout requested.'
