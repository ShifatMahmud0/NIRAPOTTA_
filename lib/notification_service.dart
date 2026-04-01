import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'location_service.dart';
import 'services/proximity_alert_service.dart';
import 'sms_sender.dart';

/// Handles both SMS alerts and Local System Notifications for nearby alerts.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

  Future<void> initialize() async {
    const androidInit = AndroidInitializationSettings('@mipmap/launcher_icon');
    const iosInit = DarwinInitializationSettings();
    const initSettings = InitializationSettings(android: androidInit, iOS: iosInit);
    
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (details) {
        // This handles tapping the notification while app is in background
        debugPrint('Notification Tapped');
      },
    );
  }

  /// Shows a high-priority system notification that stays on the lock screen.
  Future<void> showIncomingAlertNotification({
    required String title,
    required String body,
    String? payload,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'emergency_alerts_channel',
      'Emergency Alerts',
      channelDescription: 'High priority notifications for nearby emergencies',
      importance: Importance.max,
      priority: Priority.high,
      fullScreenIntent: true, // Crucial for showing over lock screen
      ongoing: true,         // Harder to accidentally swipe away
      styleInformation: BigTextStyleInformation(''),
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const platformDetails = NotificationDetails(android: androidDetails, iOS: iosDetails);

    await _localNotifications.show(
      DateTime.now().millisecond,
      title,
      body,
      platformDetails,
      payload: payload,
    );
  }

  Future<void> cancelAllNotifications() async {
    await _localNotifications.cancelAll();
  }

  /// Existing SMS logic
  Future<void> sendEmergencyAlert(String reason) async {
    final contacts = ProximityAlertService().emergencyContacts;

    if (contacts.isEmpty) {
      debugPrint('Cannot send alert. No emergency contacts saved.');
      return;
    }

    if (await Permission.sms.isGranted) {
      final locationLink = await LocationService().getMapsLink();
      final message =
          'EMERGENCY ALERT: $reason.\nLocation: $locationLink.\nSent automatically via Nirapotta.';

      for (final contact in contacts) {
        try {
          final success = await SmsSender.sendSms(contact.phone, message);
          debugPrint(success
              ? 'Alert sent to ${contact.name} (${contact.phone})'
              : 'Failed to send to ${contact.name} (${contact.phone})');
        } catch (e) {
          debugPrint('Error sending SMS to ${contact.name}: $e');
        }
      }
    } else {
      debugPrint('SMS Permission not granted. Cannot send background alerts.');
    }
  }
}
