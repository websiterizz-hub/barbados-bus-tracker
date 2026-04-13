package com.example.barbados_bus_demo

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL_NAME = "barbados_bus/notifications"
        private const val ALERT_CHANNEL_ID = "barbados_bus_watch_alerts"
        private const val ALERT_CHANNEL_NAME = "Barbados Bus Tracker"
        private const val ALERT_CHANNEL_DESCRIPTION =
            "Pass-by, ETA, and close-range alerts for watched stops."
        private const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1907
    }

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> result.success(buildSetupMap())
                "requestPermission" -> requestNotificationPermission(result)
                "showEvent" -> {
                    val arguments = call.arguments as? Map<*, *> ?: emptyMap<String, Any?>()
                    result.success(mapOf("shown" to showEventNotification(arguments)))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        ensureNotificationChannel()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(buildSetupMap())
            return
        }

        if (ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(buildSetupMap())
            return
        }

        pendingPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST_CODE,
        )
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) {
            return
        }

        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermissionResult?.success(
            mapOf(
                "supported" to true,
                "granted" to granted,
                "needsPermission" to !granted,
                "label" to if (granted) "Phone alerts ready" else "Phone alerts blocked",
            ),
        )
        pendingPermissionResult = null
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }

        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            ALERT_CHANNEL_ID,
            ALERT_CHANNEL_NAME,
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = ALERT_CHANNEL_DESCRIPTION
            enableVibration(true)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildSetupMap(): Map<String, Any> {
        ensureNotificationChannel()
        val granted = notificationsGranted()
        return mapOf(
            "supported" to true,
            "granted" to granted,
            "needsPermission" to !granted,
            "label" to if (granted) "Phone alerts ready" else "Phone alerts blocked",
        )
    }

    private fun notificationsGranted(): Boolean {
        val enabled = NotificationManagerCompat.from(this).areNotificationsEnabled()
        if (!enabled) {
            return false
        }

        return Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
    }

    private fun showEventNotification(arguments: Map<*, *>): Boolean {
        if (!notificationsGranted()) {
            return false
        }

        ensureNotificationChannel()

        val notificationId = (arguments["id"] as? Number)?.toInt() ?: return false
        val title = arguments["title"] as? String ?: "Bus alert"
        val body = arguments["body"] as? String ?: ""
        val sticky = arguments["sticky"] == true

        val notification = NotificationCompat.Builder(this, ALERT_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setDefaults(NotificationCompat.DEFAULT_ALL)
            .setOnlyAlertOnce(false)
            .setOngoing(sticky)
            .setAutoCancel(!sticky)
            .build()

        NotificationManagerCompat.from(this).notify(notificationId, notification)
        return true
    }
}
