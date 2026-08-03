# =============================================================================
# MC-CreateAndMap-CustomAttributes.ps1
# MobiControl - Create Custom Attributes and Map Values by Device Serial Number
#
# What this script does:
#   1. Authenticates to MobiControl using OAuth2 password grant
#   2. Creates custom attributes (WCC as Int, Outlet Name as Text) if not exist
#   3. Fetches all enrolled devices in one call
#   4. Matches each CSV row to a device by HardwareSerialNumber
#   5. Sets WCC and Outlet Name on each matched device
#
# CSV Format expected:
#   WCC, Serial Number, Outlet Name
# =============================================================================

[CmdletBinding()]
param (
    [string]$MCServer     = "https://a0024753.mobicontrol.cloud",
    [string]$ClientId     = "8e1695b27dda4b48a2e2afa4e09f9946",
    [string]$ClientSecret = "JDSCNn1pHQgViwFtkdMAFoCzTbkXTll0DYoGjQ/wTiM=",
    [string]$MCUsername   = "soticustom",
    [string]$MCPassword   = "Welcome@1234",
    [string]$CsvPath      = "C:\AP Reports\apstore.csv",
    [switch]$SkipCertCheck
)

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

$ApiBase  = "$MCServer/MobiControl/api"
$TokenUrl = "$MCServer/MobiControl/api/token"

$CustomAttributesToCreate = @(
    @{ Name = "WCC";         CustomAttributeDataType = "Int";  PropagateToDevice = $false },
    @{ Name = "Outlet Name"; CustomAttributeDataType = "Text"; PropagateToDevice = $false }
)

$script:LogMessages = @()

# -----------------------------------------------------------------------------
# TLS / CERTIFICATE HANDLING
# -----------------------------------------------------------------------------

if ($SkipCertCheck) {
    Write-Warning "Certificate validation is disabled. Use only in trusted environments."
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $PSDefaultParameterValues["Invoke-RestMethod:SkipCertificateCheck"] = $true
        $PSDefaultParameterValues["Invoke-WebRequest:SkipCertificateCheck"] = $true
    }
    else {
        Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(
        ServicePoint srvPoint, X509Certificate certificate,
        WebRequest request, int certificateProblem) { return true; }
}
"@
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    }
}

# -----------------------------------------------------------------------------
# FUNCTION: Write-Log
# Writes to console and accumulates messages for summary
# -----------------------------------------------------------------------------

function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"   # INFO, SUCCESS, WARN, ERROR
    )

    $timestamp = Get-Date -Format "HH:mm:ss"
    $line      = "[$timestamp][$Level] $Message"

    switch ($Level) {
        "SUCCESS" { Write-Host $line -ForegroundColor Green }
        "WARN"    { Write-Host $line -ForegroundColor Yellow }
        "ERROR"   { Write-Host $line -ForegroundColor Red }
        default   { Write-Host $line -ForegroundColor Cyan }
    }

    $script:LogMessages += $line
}

# -----------------------------------------------------------------------------
# FUNCTION: Get-MCAccessToken
# Uses OAuth2 password grant with Basic auth header (ClientId:ClientSecret)
# This is the working auth pattern confirmed by APstore_Update.ps1
# -----------------------------------------------------------------------------

function Get-MCAccessToken {
    Write-Log "Requesting OAuth2 access token..."

    # Encode ClientId:ClientSecret as Base64 for Basic auth header
    $AuthHeader = [Convert]::ToBase64String(
        [Text.Encoding]::ASCII.GetBytes("${ClientId}:${ClientSecret}")
    )

    try {
        $response = Invoke-RestMethod -Method POST -Uri $TokenUrl `
            -Headers @{ "Authorization" = "Basic $AuthHeader" } `
            -ContentType "application/x-www-form-urlencoded" `
            -Body "grant_type=password&username=$MCUsername&password=$MCPassword" `
            -ErrorAction Stop

        if ($response.access_token) {
            Write-Log "Access token obtained successfully." -Level "SUCCESS"
            return $response.access_token
        }
        else {
            Write-Log "Token response received but access_token is empty." -Level "ERROR"
            exit 1
        }
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody  = ""
        try {
            $reader    = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd()
        }
        catch {}
        Write-Log "Failed to obtain token (HTTP $statusCode): $errorBody" -Level "ERROR"
        exit 1
    }
}

# -----------------------------------------------------------------------------
# FUNCTION: New-MCCustomAttribute
# Creates a custom attribute if it does not already exist
# -----------------------------------------------------------------------------

function New-MCCustomAttribute {
    param (
        [string]$Name,
        [string]$DataType,
        [bool]$PropagateToDevice
    )

    # Check if it already exists
    try {
        $existing = Invoke-RestMethod `
            -Uri "$ApiBase/customattributes/$([Uri]::EscapeDataString($Name))" `
            -Headers @{ "Authorization" = "Bearer $script:AccessToken"; "Accept" = "application/json" } `
            -Method GET -ErrorAction Stop

        Write-Log "Custom attribute '$Name' already exists - skipping creation." -Level "WARN"
        return $true
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -ne 404) {
            Write-Log "Unexpected error checking attribute '$Name' (HTTP $statusCode): $_" -Level "WARN"
        }
        # 404 = does not exist, fall through to create
    }

    # Create the attribute
    try {
        $payload = @{
            Name                    = $Name
            CustomAttributeDataType = $DataType
            PropagateToDevice       = $PropagateToDevice
        } | ConvertTo-Json -Depth 3

        Invoke-RestMethod `
            -Uri "$ApiBase/customattributes" `
            -Headers @{ "Authorization" = "Bearer $script:AccessToken"; "Accept" = "application/json" } `
            -Method POST -Body $payload -ContentType "application/json" -ErrorAction Stop | Out-Null

        Write-Log "Custom attribute '$Name' ($DataType) created successfully." -Level "SUCCESS"
        return $true
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody  = ""
        try {
            $reader    = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd()
        }
        catch {}
        Write-Log "Failed to create attribute '$Name' (HTTP $statusCode): $errorBody" -Level "ERROR"
        return $false
    }
}

# -----------------------------------------------------------------------------
# FUNCTION: Set-DeviceCustomAttributes
# Sets WCC and Outlet Name on a device by its DeviceId
# -----------------------------------------------------------------------------

function Set-DeviceCustomAttributes {
    param (
        [string]$DeviceId,
        [string]$SerialNumber,
        [string]$WCC,
        [string]$OutletName
    )

    $payload = @{
        Attributes = @(
            @{ AttributeName = "WCC";         AttributeValue = $WCC },
            @{ AttributeName = "Outlet Name"; AttributeValue = $OutletName }
        )
    } | ConvertTo-Json -Depth 3

    try {
        Invoke-RestMethod `
            -Uri "$ApiBase/devices/$DeviceId/customattributes" `
            -Headers @{ "Authorization" = "Bearer $script:AccessToken"; "Accept" = "application/json" } `
            -Method PUT -Body $payload -ContentType "application/json" -ErrorAction Stop | Out-Null

        Write-Log "Mapped -> Serial: $SerialNumber | DeviceId: $DeviceId | WCC: $WCC | Outlet Name: $OutletName" -Level "SUCCESS"
        return $true
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorBody  = ""
        try {
            $reader    = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd()
        }
        catch {}
        Write-Log "Failed to update DeviceId '$DeviceId' for serial '$SerialNumber' (HTTP $statusCode): $errorBody" -Level "ERROR"
        return $false
    }
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  MobiControl - Custom Attribute Creator and Mapper"          -ForegroundColor Magenta
Write-Host "  Server : $MCServer"                                         -ForegroundColor Magenta
Write-Host "  CSV    : $CsvPath"                                          -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host ""

# STEP 0: Validate CSV exists before doing anything
if (-not (Test-Path $CsvPath)) {
    Write-Log "CSV file not found at: $CsvPath" -Level "ERROR"
    exit 1
}

$CsvData = Import-Csv -Path $CsvPath
Write-Log "Loaded $($CsvData.Count) record(s) from CSV."
Write-Host ""
$CsvData | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor Gray

# STEP 1: Authenticate
$script:AccessToken = Get-MCAccessToken
Write-Host ""

# STEP 2: Create Custom Attributes (skip if already exist)
Write-Host "------------------------------------------------------------" -ForegroundColor White
Write-Host "  STEP 1 of 3: Ensuring Custom Attributes exist"              -ForegroundColor White
Write-Host "------------------------------------------------------------" -ForegroundColor White

foreach ($attr in $CustomAttributesToCreate) {
    New-MCCustomAttribute -Name $attr.Name -DataType $attr.CustomAttributeDataType `
                          -PropagateToDevice $attr.PropagateToDevice | Out-Null
}

Write-Host ""

# STEP 3: Fetch ALL devices in one call (matched in memory - confirmed working approach)
Write-Host "------------------------------------------------------------" -ForegroundColor White
Write-Host "  STEP 2 of 3: Fetching all enrolled devices"                 -ForegroundColor White
Write-Host "------------------------------------------------------------" -ForegroundColor White

try {
    $AllDevices = Invoke-RestMethod `
        -Method GET `
        -Uri "$ApiBase/devices?take=4000" `
        -Headers @{ "Authorization" = "Bearer $script:AccessToken"; "Accept" = "application/json" } `
        -ErrorAction Stop

    Write-Log "Retrieved $($AllDevices.Count) device(s) from MobiControl." -Level "SUCCESS"
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    $errorBody  = ""
    try {
        $reader    = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
        $errorBody = $reader.ReadToEnd()
    }
    catch {}
    Write-Log "Failed to retrieve devices (HTTP $statusCode): $errorBody" -Level "ERROR"
    exit 1
}

# Pre-trim all HardwareSerialNumbers once for efficient matching
$AllDevices | ForEach-Object {
    if ($_.HardwareSerialNumber) {
        $_.HardwareSerialNumber = $_.HardwareSerialNumber.Trim()
    }
}

Write-Host ""

# STEP 4: Match CSV rows to devices and set custom attributes
Write-Host "------------------------------------------------------------" -ForegroundColor White
Write-Host "  STEP 3 of 3: Mapping attributes to devices"                 -ForegroundColor White
Write-Host "------------------------------------------------------------" -ForegroundColor White
Write-Host ""

$successCount  = 0
$failCount     = 0
$notFoundCount = 0

foreach ($row in $CsvData) {
    $serialNumber = ([string]$row."Serial Number").Trim()
    $wccCode      = ([string]$row."WCC").Trim()
    $outletName   = ([string]$row."Outlet Name").Trim()

    if ([string]::IsNullOrWhiteSpace($serialNumber)) {
        Write-Log "Skipping row with empty serial number." -Level "WARN"
        $failCount++
        continue
    }

    # Match device by HardwareSerialNumber (case-insensitive)
    $matchedDevice = $AllDevices | Where-Object {
        $_.HardwareSerialNumber -and
        $_.HardwareSerialNumber.ToLower() -eq $serialNumber.ToLower()
    } | Select-Object -First 1

    if ($matchedDevice) {
        $deviceId = $matchedDevice.DeviceId
        Write-Log "Match found: Serial=$serialNumber -> DeviceId=$deviceId"

        $ok = Set-DeviceCustomAttributes `
                -DeviceId     $deviceId `
                -SerialNumber $serialNumber `
                -WCC          $wccCode `
                -OutletName   $outletName

        if ($ok) { $successCount++ } else { $failCount++ }
    }
    else {
        Write-Log "No device found for serial number '$serialNumber'." -Level "WARN"

        # Show near matches to help diagnose typos
        $nearMatches = $AllDevices | Where-Object {
            $_.HardwareSerialNumber -like "*$serialNumber*"
        }
        if ($nearMatches) {
            Write-Log "  Possible near matches:" -Level "WARN"
            $nearMatches | ForEach-Object {
                Write-Log "    -> '$($_.HardwareSerialNumber)' (DeviceId: $($_.DeviceId))" -Level "WARN"
            }
        }

        $notFoundCount++
    }
}

# =============================================================================
# SUMMARY
# =============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  SUMMARY"                                                     -ForegroundColor Magenta
Write-Host "  Total CSV records  : $($CsvData.Count)"                     -ForegroundColor White
Write-Host "  Successfully mapped: $successCount"                          -ForegroundColor Green
Write-Host "  Device not found   : $notFoundCount"                         -ForegroundColor Yellow
Write-Host "  Errors             : $failCount"                             -ForegroundColor Red
Write-Host "============================================================"  -ForegroundColor Magenta
