package com.example.shake_alert_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.shake_alert_app/hardware_buttons"
    private var methodChannel: MethodChannel? = null
    
    private var lastPowerClickTime: Long = 0
    private var powerClickCount = 0

    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            intent?.action?.let { action ->
                if (action == Intent.ACTION_SCREEN_ON || action == Intent.ACTION_SCREEN_OFF) {
                    val currentTime = System.currentTimeMillis()
                    // If less than 1200ms between presses
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
            return true // Consume the event so volume doesn't change wildly during emergency press
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        
        val smsChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.shake_alert_app/background_sms")
        smsChannel.setMethodCallHandler { call, result ->
            if (call.method == "sendSms") {
                val phone = call.argument<String>("phone")
                val msg = call.argument<String>("msg")
                if (phone != null && msg != null) {
                    try {
                        // Fix: SmsManager.getDefault() is deprecated in Android 12+ (API 31)
                        val smsManager = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            applicationContext.getSystemService(android.telephony.SmsManager::class.java)
                        } else {
                            @Suppress("DEPRECATION")
                            android.telephony.SmsManager.getDefault()
                        }
                        // Use sendMultipartTextMessage to handle long messages (GPS links can exceed 160 chars)
                        val parts = smsManager.divideMessage(msg)
                        smsManager.sendMultipartTextMessage(phone, null, parts, null, null)
                        result.success("Sent")
                    } catch (e: Exception) {
                        result.error("ERROR", "Failed to send SMS", e.message)
                    }
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

    override fun onDestroy() {
        super.onDestroy()
        unregisterReceiver(screenReceiver)
    }
}
