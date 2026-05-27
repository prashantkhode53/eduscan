package com.eduscan.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        createNotificationChannels()
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
    }
}
