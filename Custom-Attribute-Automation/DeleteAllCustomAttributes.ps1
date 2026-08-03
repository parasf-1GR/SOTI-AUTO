# =============================================================================
# DeleteAllCustomAttributes.ps1
#
# Generic script — works on ANY MobiControl environment.
# No need to specify attribute names manually.
#
# Step 1: Fetch ALL custom attributes from Global Settings
#         GET /customattributes
#
# Step 2: Clear (null) each attribute value on ALL devices
#         DELETE /devices/{deviceId}/customAttributes/{customAttributeId}
#
# Step 3: Delete ALL custom attributes from Global Settings
#         DELETE /customattributes/{name}
# =============================================================================

# CONFIG — update these for your environment
$Server       = "https://a0024753.mobicontrol.cloud"
$ClientId     = "8e1695b27dda4b48a2e2afa4e09f9946"
$ClientSecret = "JDSCNn1pHQgViwFtkdMAFoCzTbkXTll0DYoGjQ/wTiM="
$Username     = "soticustom"
$Password     = "Welcome@1234"

$script:logMessages = @()

function Log-Message {
    param ([string]$Message)
    Write-Host $Message
    $script:logMessages += $Message
}

# ---------------------------------------------------------------------------
# Authenticate — get access token
# ---------------------------------------------------------------------------
$AuthHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${ClientId}:${ClientSecret}"))

$TokenResponse = Invoke-RestMethod -Method Post -Uri "$Server/MobiControl/api/token" `
    -Headers @{ "Authorization" = "Basic $AuthHeader" } `
    -ContentType "application/x-www-form-urlencoded" `
    -Body "grant_type=password&username=$Username&password=$Password"

$AccessToken = $TokenResponse.access_token
if (!$AccessToken) {
    Log-Message "ERROR: Failed to retrieve access token. Exiting."
    exit 1
}
Log-Message "Access token retrieved successfully."

# ---------------------------------------------------------------------------
# STEP 1: Fetch ALL custom attributes from Global Settings
# ---------------------------------------------------------------------------
Log-Message ""
Log-Message "===== STEP 1: Fetching all custom attributes from Global Settings ====="

$AllAttributes = Invoke-RestMethod -Method Get -Uri "$Server/MobiControl/api/customattributes" `
    -Headers @{ "Authorization" = "Bearer $AccessToken"; "Accept" = "application/json" }

if (!$AllAttributes -or $AllAttributes.Count -eq 0) {
    Log-Message "No custom attributes found in Global Settings. Nothing to do."
    exit 0
}

$AttributeNames = $AllAttributes | ForEach-Object { $_.Name }
Log-Message "Found $($AttributeNames.Count) custom attribute(s): $($AttributeNames -join ', ')"

# ---------------------------------------------------------------------------
# STEP 2: Fetch ALL devices and clear each attribute value
# ---------------------------------------------------------------------------
Log-Message ""
Log-Message "===== STEP 2: Clearing attribute values on all devices ====="

$AllDevices = Invoke-RestMethod -Method Get -Uri "$Server/MobiControl/api/devices?take=4000" `
    -Headers @{ "Authorization" = "Bearer $AccessToken"; "Accept" = "application/json" }

Log-Message "Retrieved $($AllDevices.Count) device(s) from MobiControl."

foreach ($device in $AllDevices) {
    $deviceId = $device.DeviceId
    $serial   = $device.HardwareSerialNumber

    foreach ($attrName in $AttributeNames) {
        try {
            $encodedAttr = [Uri]::EscapeDataString($attrName)

            Invoke-RestMethod `
                -Uri "$Server/MobiControl/api/devices/$deviceId/customAttributes/$encodedAttr" `
                -Headers @{ "Authorization" = "Bearer $AccessToken"; "Accept" = "application/json" } `
                -Method Delete

            Log-Message "  Cleared '$attrName' on device $deviceId (Serial: $serial)."
        } catch {
            Log-Message "  SKIP: '$attrName' on device $deviceId may already be empty. $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# STEP 3: Delete ALL custom attributes from Global Settings
# ---------------------------------------------------------------------------
Log-Message ""
Log-Message "===== STEP 3: Deleting all custom attributes from Global Settings ====="

foreach ($attrName in $AttributeNames) {
    try {
        $encodedAttr = [Uri]::EscapeDataString($attrName)

        Invoke-RestMethod `
            -Uri "$Server/MobiControl/api/customattributes/$encodedAttr" `
            -Headers @{ "Authorization" = "Bearer $AccessToken"; "Accept" = "application/json" } `
            -Method Delete

        Log-Message "Deleted global custom attribute '$attrName'."
    } catch {
        Log-Message "WARNING: Could not delete '$attrName'. Error: $($_.Exception.Message)"
    }
}

Log-Message ""
Log-Message "===== COMPLETED ====="
