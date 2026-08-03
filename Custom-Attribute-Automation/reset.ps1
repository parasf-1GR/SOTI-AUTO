# Define variables
$CsvPath = "C:\AP Reports\apstore.csv"

# CONFIG
$Server = "https://a0024753.mobicontrol.cloud"   # removed trailing slash
$ClientId = "8e1695b27dda4b48a2e2afa4e09f9946"
$ClientSecret = "JDSCNn1pHQgViwFtkdMAFoCzTbkXTll0DYoGjQ/wTiM="
$Username = "soticustom"
$Password = "Welcome@1234"
$script:logMessages = @()

function Log-Message {
    param ([string]$Message)
    Write-Host $Message
    $script:logMessages += $Message
}

# Validate CSV exists before doing anything
if (-not (Test-Path $CsvPath)) {
    Write-Host "ERROR: CSV file not found at $CsvPath"
    exit 1
}
$CsvData = Import-Csv -Path $CsvPath

# Encode client credentials
$AuthHeader = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${ClientId}:${ClientSecret}"))

# Get access token
$TokenResponse = Invoke-RestMethod -Method Post -Uri "$Server/MobiControl/api/token" `
    -Headers @{ "Authorization" = "Basic $AuthHeader" } `
    -ContentType "application/x-www-form-urlencoded" `
    -Body "grant_type=password&username=$Username&password=$Password"

$AccessToken = $TokenResponse.access_token
if (!$AccessToken) {
    Log-Message "Failed to retrieve access token"
    exit 1
}

# Get Devices
$Result = Invoke-RestMethod -Method Get -Uri "$Server/MobiControl/api/devices?take=4000" `
    -Headers @{ "Authorization" = "Bearer $AccessToken"; "Accept" = "application/json" }

# Trim serial numbers ONCE before looping
$Result | ForEach-Object {
    if ($_.HardwareSerialNumber) {
        $_.HardwareSerialNumber = $_.HardwareSerialNumber.Trim()
    }
}

# Iterate through each row in the CSV and RESET all custom attributes to empty
foreach ($row in $CsvData) {
    $serialNumber = ([string]$row."Serial Number").Trim()

    $matchedDevice = $Result | Where-Object {
        $_.HardwareSerialNumber -and $_.HardwareSerialNumber.ToLower() -eq $serialNumber.ToLower()
    } | Select-Object -First 1

    if ($matchedDevice) {
        $deviceId = $matchedDevice.DeviceId
        Log-Message "Match found: Serial=$serialNumber -> DeviceId=$deviceId. Resetting custom attributes..."

        # Reset all custom attributes to empty (null/unknown)
        $body = @{
            Attributes = @(
                @{
                    AttributeName  = "WCC"
                    AttributeValue = ""
                },
                @{
                    AttributeName  = "Outlet Name"
                    AttributeValue = ""
                }
            )
        } | ConvertTo-Json -Depth 3

        Invoke-RestMethod -Uri "$Server/MobiControl/api/devices/$deviceId/customattributes" `
            -Headers @{ "Authorization" = "Bearer $AccessToken"; "Accept" = "application/json" } `
            -Method Put -Body $body -ContentType "application/json"

        Log-Message "Reset device $deviceId — WCC and Outlet Name cleared."
    } else {
        Log-Message "No matching device found for serial number '$serialNumber'."

        $nearMatches = $Result | Where-Object { $_.HardwareSerialNumber -like "*$serialNumber*" }
        if ($nearMatches) {
            Log-Message "Possible near matches:"
            $nearMatches | ForEach-Object { Log-Message "`tFound: '$($_.HardwareSerialNumber)'" }
        }
    }
}
