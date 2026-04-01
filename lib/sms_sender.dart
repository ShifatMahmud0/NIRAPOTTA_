import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Sends SMS via the native Android MethodChannel already implemented in MainActivity.kt.
/// Uses the existing channel: com.example.gps_sms/background_sms
class SmsSender {
  static const _channel =
      MethodChannel('com.example.gps_sms/background_sms');

  static Future<bool> sendSms(String phoneNumber, String message) async {
    try {
      final String? result = await _channel.invokeMethod('sendSms', {
        'phone': phoneNumber,
        'msg': message,
      });
      return result == 'Sent';
    } catch (e) {
      debugPrint('SmsSender error: $e');
      return false;
    }
  }
}
