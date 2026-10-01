# Shared Device "Log out" app (POC)

A one-button Android app that ends the MobiControl Shared Device session without
users ever opening the MobiControl agent. Built for the S24 FE DeX POC, where the
logged-in group has no lockdown.

```
[Log out app] --HTTPS + function key--> [Azure Function] --REST API--> [MobiControl]
                                                         POST /devices/{id}/actions
                                                         { "Action": "SharedDeviceLogout" }
```

MobiControl credentials live only in the Function, never on the device. The device
only holds the Function URL and a Function key, delivered via managed configuration.

## 1. Confirm the API action name first
Search your Swagger spec (New_MCAPI.json) for the device actions body and confirm the
shared-device logout action value. The default here is `SharedDeviceLogout`; if yours
differs, set the `MC_LOGOUT_ACTION` app setting rather than editing code.

## 2. Deploy the middleware
1. Create an Azure Function App (PowerShell 7.4 runtime).
2. Deploy the `middleware` folder (VS Code Azure Functions extension is simplest).
3. App settings: `MC_BASE_URL`, `MC_CLIENT_ID`, `MC_CLIENT_SECRET`, `MC_USERNAME`,
   `MC_PASSWORD`, and ideally `ALLOWED_PATH_PREFIX`. Use Key Vault references for secrets.
4. Use a dedicated MobiControl API user with the minimum rights needed to view devices
   and send this action.
5. Test from your PC: `.\Test-Logout.ps1 -FunctionUrl <url> -DeviceId <id>`

`ALLOWED_PATH_PREFIX` must cover both the login group and the logged-in group,
because the device is relocated while a user is signed in.

## 3. Build and deploy the app
1. Open `android-app` in Android Studio, let Gradle sync, and build a signed release APK.
   Rename the package `com.example.sharedlogout` to your own namespace first.
2. Add the APK to MobiControl and install it on the shared device groups.
3. Managed app configuration:
   - `endpoint_url`: the Function URL (must be https)
   - `api_key`: the Function key
   - `device_id`: MobiControl's device ID macro. Confirm the exact macro name for your
     MobiControl version. The app refuses to run if it receives an unexpanded `%...%` value.

## 4. Surface it to users
- Phone: place it on the home screen or dock in the logged-in profile.
- DeX: add the package to KSP **Add application shortcuts on DeX**.
- Hide the MobiControl agent from launcher and DeX app drawer.

## 5. Keep the built-in safety nets on
In the Shared Device configuration, also enable automatic logout (after a set period
and/or when inactive) and "Relocate device back to home device group on logout".
The app is the convenient path; these make sure sessions end even when users forget.

## Notes
- The logout runs when the agent receives the action, usually within seconds when
  the device is online. With no network the button fails gracefully and auto-logout
  still applies.
- Anyone holding the Function key could request a logout for a device ID in the
  allowed groups. Acceptable for a POC; for production consider per-device secrets
  or certificate-based auth.
