package com.example.sharedlogout

import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.RestrictionsManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * One-button app that asks the logout middleware to end the current
 * MobiControl Shared Device session. All settings come from managed
 * configuration pushed by MobiControl - nothing is hardcoded and no
 * MobiControl credentials ever live on the device.
 */
class MainActivity : Activity() {

    private data class Config(val endpoint: String, val key: String, val deviceId: String)

    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private lateinit var button: Button
    private lateinit var progress: ProgressBar
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        button = findViewById(R.id.logoutButton)
        progress = findViewById(R.id.progress)
        status = findViewById(R.id.status)
        button.setOnClickListener { readConfig()?.let { confirm(it) } }
    }

    override fun onResume() {
        super.onResume()
        // Re-read every time: MobiControl may push config after first launch.
        val configured = readConfig() != null
        button.isEnabled = configured
        status.text = if (configured) "" else getString(R.string.not_configured)
    }

    override fun onDestroy() {
        executor.shutdownNow()
        super.onDestroy()
    }

    private fun readConfig(): Config? {
        val rm = getSystemService(Context.RESTRICTIONS_SERVICE) as RestrictionsManager
        val r = rm.applicationRestrictions
        val endpoint = r.getString("endpoint_url")?.trim().orEmpty()
        val key = r.getString("api_key")?.trim().orEmpty()
        val deviceId = r.getString("device_id")?.trim().orEmpty()

        if (endpoint.isEmpty() || key.isEmpty() || deviceId.isEmpty()) return null
        if (!endpoint.startsWith("https://", ignoreCase = true)) return null
        // An unexpanded macro (e.g. "%DEVICEID%") means MobiControl didn't substitute it.
        if (deviceId.contains('%')) return null
        return Config(endpoint, key, deviceId)
    }

    private fun confirm(cfg: Config) {
        AlertDialog.Builder(this)
            .setTitle(R.string.confirm_title)
            .setMessage(R.string.confirm_msg)
            .setNegativeButton(R.string.cancel, null)
            .setPositiveButton(R.string.logout) { _, _ -> logout(cfg) }
            .show()
    }

    private fun logout(cfg: Config) {
        setBusy(true)
        status.text = getString(R.string.logging_out)
        executor.execute {
            val result = runCatching { postLogout(cfg) }
            mainHandler.post {
                if (isFinishing || isDestroyed) return@post
                setBusy(false)
                status.text = result.fold(
                    onSuccess = { code ->
                        if (code in 200..299) getString(R.string.success)
                        else getString(R.string.failed_code, code)
                    },
                    onFailure = { getString(R.string.failed_network) }
                )
            }
        }
    }

    private fun postLogout(cfg: Config): Int {
        val conn = URL(cfg.endpoint).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.connectTimeout = 10_000
            conn.readTimeout = 20_000
            conn.doOutput = true
            conn.setRequestProperty("Content-Type", "application/json")
            conn.setRequestProperty("x-functions-key", cfg.key)
            val body = JSONObject().put("deviceId", cfg.deviceId).toString()
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            return conn.responseCode
        } finally {
            conn.disconnect()
        }
    }

    private fun setBusy(busy: Boolean) {
        button.isEnabled = !busy
        progress.visibility = if (busy) View.VISIBLE else View.GONE
    }
}
