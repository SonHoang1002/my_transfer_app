package com.example.mytransferapp.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import com.example.mytransferapp.MainActivity
import com.example.mytransferapp.network.TransferEngine

class TransferService : Service {
    private val CHANNEL_ID = "swiftshare_channel_id"
    private val SERVICE_NOTIFICATION_ID = 1111
    private val TRANSFER_NOTIFICATION_ID = 2222
    private var notificationManager: NotificationManager? = null

    constructor() : super()

    override fun onCreate() {
        super.onCreate()
        notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == "STOP_SERVICE") {
            stopEngine()
            stopSelf()
            return START_NOT_STICKY
        }

        // 1. Prepare Persistent Foreground Notification
        val notificationIntent = Intent(this, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            notificationIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = Intent(this, TransferService::class.java).apply {
            this.action = "STOP_SERVICE"
        }
        val stopPendingIntent = PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Find current display details
        val deviceName = TransferEngine.getDeviceName()
        val ipAddress = TransferEngine.getLocalIpAddress()

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SwiftShare Đang Bật Nhận")
            .setContentText("Tên: $deviceName | IP: $ipAddress")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Tắt nhận file", stopPendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        // 2. Safely put Service inside foreground mode
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    SERVICE_NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(SERVICE_NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            Log.e("TransferService", "Không thể chạy foreground service trực tiếp", e)
        }

        // 3. Start Core Engine
        startEngine()

        return START_STICKY
    }

    private fun startEngine() {
        val deviceName = TransferEngine.getDeviceName()
        // Auto advertise UDP discovery and listen to TCP Socket
        TransferEngine.startAdvertising(deviceName)
        TransferEngine.startTcpServer(this) { title, body ->
            showLocalNotification(title, body)
        }
        Log.d("TransferService", "Hệ thống truyền nhận SwiftShare đã sẵn sàng phục vụ.")
    }

    private fun stopEngine() {
        TransferEngine.stopAdvertising()
        TransferEngine.stopTcpServer()
        Log.d("TransferService", "Đã ngắt kết nối hệ thống truyền nhận SwiftShare.")
    }

    override fun onDestroy() {
        stopEngine()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? {
        return null
    }

    private fun showLocalNotification(title: String, body: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .build()

        notificationManager?.notify(TRANSFER_NOTIFICATION_ID, notification)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "SwiftShare File Transmission Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Hiển thị thông báo trạng thái truyền nhận file không dây"
            }
            notificationManager?.createNotificationChannel(serviceChannel)
        }
    }
}
