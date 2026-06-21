package com.eduscan.app

import android.app.ActivityManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Kiosk lock-mode channel: Android screen pinning (Lock Task). Confines
        // the attendance scan screen so students can't reach Home/Recents.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, KIOSK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startLockTask" -> {
                        try {
                            // Only start if not already locked (avoids a no-op
                            // exception on repeated calls).
                            val am = getSystemService(Context.ACTIVITY_SERVICE)
                                as ActivityManager
                            val locked = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                am.lockTaskModeState != ActivityManager.LOCK_TASK_MODE_NONE
                            } else {
                                @Suppress("DEPRECATION")
                                am.isInLockTaskMode
                            }
                            if (!locked) startLockTask()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("LOCK_FAILED", e.message, null)
                        }
                    }
                    "stopLockTask" -> {
                        try {
                            stopLockTask()
                            result.success(true)
                        } catch (e: Exception) {
                            // Not in lock mode — treat as success so unlock is idempotent.
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java) ?: return

            // High-priority channel: WhatsApp disconnected / auth failure
            NotificationChannel(
                CHANNEL_WA_ALERTS,
                "WhatsApp Alerts",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "WhatsApp connection failures and reconnect alerts"
                enableLights(true)
                enableVibration(true)
            }.also { manager.createNotificationChannel(it) }

            // Default-priority channel: general attendance / session events
            NotificationChannel(
                CHANNEL_GENERAL,
                "EduScan Notifications",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Attendance records and session updates"
            }.also { manager.createNotificationChannel(it) }
        }
    }

    companion object {
        const val CHANNEL_WA_ALERTS = "eduscan_wa_alerts"
        const val CHANNEL_GENERAL   = "eduscan_general"
        const val KIOSK_CHANNEL     = "eduscan/kiosk"
    }
}
