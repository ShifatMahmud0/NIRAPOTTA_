package com.example.gps_sms

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.gps_sms/hardware_buttons"
    private var methodChannel: MethodChannel? = null
    
    private var lastPowerClickTime: Long = 0
    private var powerClickCount = 0

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.action?.let { action ->
                if (action == Intent.ACTION_SCREEN_ON || action == Intent.ACTION_SCREEN_OFF) {
                    val currentTime = System.currentTimeMillis()
                    if (currentTime - lastPowerClickTime < 1200) {
                        powerClickCount++
                        if (powerClickCount == 2) {
                            methodChannel?.invokeMethod("power_button_double_click", null)
                        } else if (powerClickCount >= 3) {
                            methodChannel?.invokeMethod("power_button_triple_click", null)
                            powerClickCount = 0
                        }
                    } else {
                        powerClickCount = 1
                    }
                    lastPowerClickTime = currentTime
                }
            }
        }
    }

    private var lastVolumeClickTime: Long = 0
    private var volumeClickCount = 0

    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent?): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) {
            val currentTime = System.currentTimeMillis()
            if (currentTime - lastVolumeClickTime < 1200) {
                volumeClickCount++
                if (volumeClickCount >= 3) {
                    methodChannel?.invokeMethod("volume_button_triple_click", null)
                    volumeClickCount = 0
                }
            } else {
                volumeClickCount = 1
            }
            lastVolumeClickTime = currentTime
            return true 
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        
        // Create Notification Channel for Background Alerts
        createNotificationChannel()

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        val smsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.gps_sms/background_sms")
        smsChannel.setMethodCallHandler { call, result ->
            if (call.method == "sendSms") {
                val phone = call.argument<String>("phone")
                val msg = call.argument<String>("msg")
                if (phone != null && msg != null) {
                    sendSmsWithStatus(phone, msg, result)
                } else {
                    result.error("INVALID", "Phone or message is null", null)
                }
            } else {
                result.notImplemented()
            }
        }

        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        }
        
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(screenReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            registerReceiver(screenReceiver, filter)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val name = "Emergency Alerts"
            val descriptionText = "High priority notifications for nearby emergencies"
            val importance = NotificationManager.IMPORTANCE_HIGH
            val channel = NotificationChannel("emergency_alerts_channel", name, importance).apply {
                description = descriptionText
                enableVibration(true)
                setVibrationPattern(longArrayOf(0, 500, 300, 500))
            }
            val notificationManager: NotificationManager =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun sendSmsWithStatus(phone: String, msg: String, result: MethodChannel.Result) {
        try {
            val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                applicationContext.getSystemService(SmsManager::class.java)
            } else {
                @Suppress("DEPRECATION")
                SmsManager.getDefault()
            }

            val SENT = "SMS_SENT"
            val sentPI = PendingIntent.getBroadcast(this, 0, Intent(SENT), PendingIntent.FLAG_IMMUTABLE)

            val sentReceiver = object : BroadcastReceiver() {
                override fun onReceive(arg0: Context?, arg1: Intent?) {
                    when (resultCode) {
                        Activity.RESULT_OK -> {
                            try { result.success("Sent") } catch (e: Exception) {}
                        }
                        else -> {
                            try { result.error("FAILED", "SMS Delivery Failed", null) } catch (e: Exception) {}
                        }
                    }
                    unregisterReceiver(this)
                }
            }
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(sentReceiver, IntentFilter(SENT), Context.RECEIVER_EXPORTED)
            } else {
                registerReceiver(sentReceiver, IntentFilter(SENT))
            }

            val parts = smsManager.divideMessage(msg)
            val sentIntents = ArrayList<PendingIntent>()
            for (i in 0 until parts.size) {
                sentIntents.add(sentPI)
            }
            smsManager.sendMultipartTextMessage(phone, null, parts, sentIntents, null)

        } catch (e: Exception) {
            result.error("ERROR", e.message, null)
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        try {
            unregisterReceiver(screenReceiver)
        } catch (e: Exception) {}
    }
}
