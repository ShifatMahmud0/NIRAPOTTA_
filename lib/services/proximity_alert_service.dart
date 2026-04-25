import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vibration/vibration.dart';
import 'package:permission_handler/permission_handler.dart';
import '../app_globals.dart';
import '../sms_sender.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────────────────

class EmergencyContact {
  final String name;
  final String phone;

  EmergencyContact({required this.name, required this.phone});

  Map<String, dynamic> toMap() => {'name': name, 'phone': phone};

  factory EmergencyContact.fromMap(Map<String, dynamic> map) =>
      EmergencyContact(
        name: map['name'] as String? ?? '',
        phone: map['phone'] as String? ?? '',
      );
}

class NearbyUser {
  final String userId;
  final double latitude;
  final double longitude;
  final double distance;

  const NearbyUser({
    required this.userId,
    required this.latitude,
    required this.longitude,
    required this.distance,
  });

  String get formattedDistance {
    if (distance < 1000) return '${distance.toStringAsFixed(0)} m away';
    return '${(distance / 1000).toStringAsFixed(2)} km away';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Service
// ─────────────────────────────────────────────────────────────────────────────

/// Singleton service that handles GPS tracking, nearby user detection,
/// Firestore-based alert sending/receiving, and FCM push notifications.
class ProximityAlertService extends ChangeNotifier {
  // Singleton
  static final ProximityAlertService _instance =
      ProximityAlertService._internal();
  factory ProximityAlertService() => _instance;
  ProximityAlertService._internal();

  // ── State ──────────────────────────────────────────────────────────────────
  String? _userId;
  String? _fcmToken;
  Position? _currentPosition;
  List<NearbyUser> _nearbyUsers = [];
  bool _isTracking = false;
  double _alertRadius = 8.0;
  List<EmergencyContact> _emergencyContacts = [];
  DateTime? _lastAlertCheck;

  StreamSubscription? _locationStreamSubscription;
  StreamSubscription? _usersSubscription;
  StreamSubscription? _alertsSubscription;

  // ── Getters ────────────────────────────────────────────────────────────────
  String? get userId => _userId;
  Position? get currentPosition => _currentPosition;
  List<NearbyUser> get nearbyUsers => List.unmodifiable(_nearbyUsers);
  bool get isTracking => _isTracking;
  double get alertRadius => _alertRadius;
  List<EmergencyContact> get emergencyContacts =>
      List.unmodifiable(_emergencyContacts);
  int get nearbyUsersCount => _nearbyUsers.length;

  set alertRadius(double value) {
    _alertRadius = value;
    notifyListeners();
  }

  // ── Initialization ─────────────────────────────────────────────────────────

  /// Call once at app startup (from main.dart after Firebase.initializeApp).
  Future<void> initialize() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        _userId = user.uid;
      } else {
        final cred = await FirebaseAuth.instance.signInAnonymously();
        _userId = cred.user?.uid;
      }

      if (_userId == null) {
        debugPrint('❌ ProximityAlertService: No user ID available');
        return;
      }

      // ── BATTERY OPTIMIZATION CHECK ──
      if (await Permission.ignoreBatteryOptimizations.isDenied) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      // Get FCM token for push notifications
      _fcmToken = await FirebaseMessaging.instance.getToken();
      debugPrint('📱 FCM Token: ${_fcmToken?.substring(0, 20)}...');

      // Request notification permissions
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      // Handle foreground FCM messages
      FirebaseMessaging.onMessage.listen((RemoteMessage message) {
        debugPrint('📬 Foreground FCM: ${message.notification?.title}');
        _handleFcmNotification(message);
      });

      // Handle notification tap when app was in background
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        debugPrint('📲 Notification tapped from background');
        _handleNotificationTap(message);
      });

      // Upsert user document in Firestore (stores FCM token)
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_userId)
          .set({
        'userId': _userId,
        'fcmToken': _fcmToken,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // Start listening for incoming alerts (even before tracking)
      _listenForAlerts();

      // Load emergency contacts from Firestore
      await loadEmergencyContacts();

      // Initial location fetch to make user visible immediately
      await _fetchInitialLocation();

      debugPrint('✅ ProximityAlertService initialized for user: $_userId');
    } catch (e) {
      debugPrint('❌ ProximityAlertService init error: $e');
    }
  }

  Future<void> _fetchInitialLocation() async {
     try {
       LocationPermission permission = await Geolocator.checkPermission();
       if (permission == LocationPermission.whileInUse || permission == LocationPermission.always) {
          final position = await Geolocator.getCurrentPosition(
              desiredAccuracy: LocationAccuracy.high);
          _currentPosition = position;
          if (_userId != null) {
            await FirebaseFirestore.instance
                .collection('users')
                .doc(_userId)
                .update({
              'latitude': position.latitude,
              'longitude': position.longitude,
              'accuracy': position.accuracy,
              'lastSeen': FieldValue.serverTimestamp(),
            });
          }
       }
     } catch(e) {
       debugPrint('Initial location fetch failed: $e');
     }
  }

  // ── Emergency Contacts ────────────────────────────────────────────────────

  Future<void> loadEmergencyContacts() async {
    try {
      if (_userId == null) return;
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_userId)
          .get();

      if (doc.exists) {
        final data = doc.data();
        final list = data?['emergencyContacts'] as List<dynamic>?;
        if (list != null) {
          _emergencyContacts = list
              .map((c) =>
                  EmergencyContact.fromMap(c as Map<String, dynamic>))
              .toList();
        }
      }
      debugPrint('✅ Loaded ${_emergencyContacts.length} emergency contacts');
      notifyListeners();
    } catch (e) {
      debugPrint('Error loading emergency contacts: $e');
    }
  }

  // ── Incoming Alert Handling ───────────────────────────────────────────────

  void _handleFcmNotification(RemoteMessage message) {
    final data = message.data;
    final alertType = data['alertType'] ?? 'unknown';
    final latitude = double.tryParse(data['latitude'] ?? '0');
    final longitude = double.tryParse(data['longitude'] ?? '0');
    final distance = double.tryParse(data['distance'] ?? '0');
    _showIncomingAlertDialog(
      alertType: alertType,
      distance: distance,
      latitude: latitude,
      longitude: longitude,
    );
  }

  void _handleNotificationTap(RemoteMessage message) {
    final data = message.data;
    final lat = double.tryParse(data['latitude'] ?? '0');
    final lng = double.tryParse(data['longitude'] ?? '0');
    if (lat != null && lng != null && lat != 0 && lng != 0) {
      _navigateToLocation(lat, lng);
    }
  }

  void _listenForAlerts() {
    _lastAlertCheck = DateTime.now();
    _alertsSubscription?.cancel();

    _alertsSubscription = FirebaseFirestore.instance
        .collection('alerts')
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data()!;
          final alertTime =
              (data['timestamp'] as Timestamp?)?.toDate();

          if (alertTime != null &&
              _lastAlertCheck != null &&
              alertTime.isAfter(
                _lastAlertCheck!
                    .subtract(const Duration(seconds: 5)),
              )) {
            final senderId = data['senderId'] as String?;
            final recipientIds =
                List<String>.from(data['recipientIds'] ?? []);

            if (senderId != _userId &&
                recipientIds.contains(_userId)) {
              final alertType =
                  data['alertType'] as String? ?? 'unknown';
              final senderLocation =
                  data['location'] as GeoPoint?;

              double? distance;
              if (_currentPosition != null &&
                  senderLocation != null) {
                distance = Geolocator.distanceBetween(
                  _currentPosition!.latitude,
                  _currentPosition!.longitude,
                  senderLocation.latitude,
                  senderLocation.longitude,
                );
              }

              debugPrint('🔔 Incoming alert! Type: $alertType');
              _showIncomingAlertDialog(
                alertType: alertType,
                distance: distance,
                latitude: senderLocation?.latitude,
                longitude: senderLocation?.longitude,
              );
            }
          }
        }
      }
    });

    debugPrint('👂 Listening for incoming alerts...');
  }

  void _showIncomingAlertDialog({
    required String alertType,
    required double? distance,
    double? latitude,
    double? longitude,
  }) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;

    Vibration.hasVibrator().then((hasVibrator) {
      if (hasVibrator ?? false) {
        Vibration.vibrate(
            pattern: [0, 500, 300, 500, 300, 1000], repeat: 0);
      }
    });

    final isMajor = alertType == 'major';
    final title = isMajor ? '🚨 EMERGENCY ALERT' : '⚠️ Warning Alert';
    final distanceText = distance != null
        ? distance < 1000
            ? '${distance.toStringAsFixed(0)}m away'
            : '${(distance / 1000).toStringAsFixed(1)}km away'
        : 'nearby';

    showDialog(
      context: ctx,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor:
            isMajor ? Colors.red[50] : Colors.orange[50],
        title: Row(
          children: [
            Icon(
              isMajor ? Icons.warning : Icons.info,
              color: isMajor ? Colors.red : Colors.orange,
              size: 32,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: isMajor
                      ? Colors.red[900]
                      : Colors.orange[900],
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Someone needs help $distanceText!',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w500),
            ),
            if (latitude != null && longitude != null) ...[
              const SizedBox(height: 12),
              Text(
                'Location: ${latitude.toStringAsFixed(5)}, '
                '${longitude.toStringAsFixed(5)}',
                style: const TextStyle(
                    fontSize: 11, fontFamily: 'monospace'),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Vibration.cancel();
              Navigator.pop(context);
            },
            child: const Text('DISMISS'),
          ),
          if (latitude != null && longitude != null)
            ElevatedButton.icon(
              onPressed: () {
                Vibration.cancel();
                Navigator.pop(context);
                _navigateToLocation(latitude, longitude);
              },
              icon: const Icon(Icons.navigation),
              label: const Text('NAVIGATE'),
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isMajor ? Colors.red : Colors.orange,
                foregroundColor: Colors.white,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _navigateToLocation(
      double latitude, double longitude) async {
    debugPrint('🗺️ Navigating to: $latitude, $longitude');
    try {
      final uri = Uri.parse(
          'geo:$latitude,$longitude?q=$latitude,$longitude');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    } catch (_) {}

    try {
      final uri = Uri.parse(
          'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    } catch (_) {}
  }

  // ── Location Tracking ─────────────────────────────────────────────────────

  Future<void> startTracking() async {
    debugPrint('🎯 Starting location tracking with Foreground Service...');

    LocationPermission permission =
        await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever) {
      debugPrint('❌ Location permission denied forever');
      return;
    }

    _isTracking = true;
    notifyListeners();

    final LocationSettings locationSettings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
        forceLocationManager: true,
        intervalDuration: const Duration(seconds: 5),
        foregroundNotificationConfig: ForegroundNotificationConfig(
            notificationText: "Nirapotta is protecting you in the background",
            notificationTitle: "Sentinel Active",
            enableWakeLock: true,
        )
    );

    _locationStreamSubscription = Geolocator.getPositionStream(locationSettings: locationSettings).listen(
      (Position position) {
        _currentPosition = position;
        if (_userId != null) {
          FirebaseFirestore.instance
              .collection('users')
              .doc(_userId)
              .update({
            'latitude': position.latitude,
            'longitude': position.longitude,
            'accuracy': position.accuracy,
            'isActive': true,
            'lastSeen': FieldValue.serverTimestamp(),
          });
        }
        notifyListeners();
        debugPrint('📍 Stream Location: ${position.latitude}, ${position.longitude}');
      }
    );

    _listenToNearbyUsers();

    debugPrint('✅ Tracking started with stream');
  }

  void _listenToNearbyUsers() {
    _usersSubscription?.cancel();
    _usersSubscription = FirebaseFirestore.instance
        .collection('users')
        .snapshots() 
        .listen((snapshot) {
      if (_currentPosition == null) return;

      final nearby = <NearbyUser>[];
      final now = DateTime.now();

      for (final doc in snapshot.docs) {
        if (doc.id == _userId) continue;

        final data = doc.data();
        final lat = data['latitude'] as double?;
        final lng = data['longitude'] as double?;
        final token = data['fcmToken'] as String?;
        final lastSeen = data['lastSeen'] as Timestamp?;

        // 1. Must have a valid FCM token to be "Active"
        if (token == null || token.isEmpty) continue;

        // 2. Must have updated location in the last 10 minutes (prevents ghost users)
        if (lastSeen != null) {
          final difference = now.difference(lastSeen.toDate());
          if (difference.inMinutes > 10) continue;
        } else {
          // If they never updated location, they aren't active
          continue;
        }

        if (lat != null && lng != null) {
          final dist = Geolocator.distanceBetween(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
            lat,
            lng,
          );
          if (dist <= _alertRadius) {
            nearby.add(NearbyUser(
              userId: doc.id,
              latitude: lat,
              longitude: lng,
              distance: dist,
            ));
          }
        }
      }

      nearby.sort((a, b) => a.distance.compareTo(b.distance));
      _nearbyUsers = nearby;
      notifyListeners();
    });
  }

  Future<void> stopTracking() async {
    _locationStreamSubscription?.cancel();
    _usersSubscription?.cancel();
    _locationStreamSubscription = null;
    _usersSubscription = null;

    if (_userId != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_userId)
            .update({'isActive': false});
      } catch (_) {}
    }

    _isTracking = false;
    _nearbyUsers = [];
    notifyListeners();
    debugPrint('🛑 Tracking stopped');
  }

  // ── Alert Sending ─────────────────────────────────────────────────────────

  Future<void> sendMajorAlert(BuildContext context) async {
    debugPrint('🚨 MAJOR EMERGENCY - Processing...');

    var status = await Permission.sms.status;
    if (!status.isGranted) {
      status = await Permission.sms.request();
    }

    if (!status.isGranted) {
      if (context.mounted) {
        _showSnack(context, 'SMS Permission denied. Cannot send emergency texts.', Colors.red);
      }
    }

    if (!_isTracking || _currentPosition == null) {
      _showSnack(context, 'Location tracking is not active.', Colors.red);
      return;
    }

    final canSendSMS = _emergencyContacts.isNotEmpty && status.isGranted;
    final canSendNotifications = _nearbyUsers.isNotEmpty;

    if (!canSendSMS && !canSendNotifications) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1E1E),
          title: const Text('Cannot Send Alert',
              style: TextStyle(color: Colors.white)),
          content: Text(
            !status.isGranted 
                ? 'SMS Permission is required to send alerts to contacts.'
                : 'You have no emergency contacts for SMS and no active app users nearby.',
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK',
                  style: TextStyle(color: Colors.white54)),
            ),
          ],
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
                color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(
              canSendSMS && canSendNotifications
                  ? 'Sending SMS to ${_emergencyContacts.length} & notifying ${_nearbyUsers.length} user(s)...'
                  : canSendSMS
                      ? 'Sending SMS to '
                          '${_emergencyContacts.length} contact(s)...'
                      : 'Notifying ${_nearbyUsers.length} '
                          'nearby user(s)...',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );

    int smsCount = 0;
    bool notificationsSaved = false;

    try {
      if (canSendSMS) {
        final mapsLink =
            'https://www.google.com/maps/search/?api=1&query='
            '${_currentPosition!.latitude},'
            '${_currentPosition!.longitude}';
        final message = '🚨 EMERGENCY ALERT!\n'
            'Help needed immediately at:\n'
            '$mapsLink\n\n'
            '- Sent from Nirapotta Safety App';

        for (int i = 0; i < _emergencyContacts.length; i++) {
          final contact = _emergencyContacts[i];
          try {
            final success =
                await SmsSender.sendSms(contact.phone, message);
            if (success) smsCount++;
            if (i < _emergencyContacts.length - 1) {
              await Future.delayed(const Duration(milliseconds: 1500));
            }
          } catch (_) {}
        }
      }

      if (canSendNotifications) {
        final recipientIds =
            _nearbyUsers.map((u) => u.userId).toList();

        await FirebaseFirestore.instance
            .collection('alerts')
            .add({
          'senderId': _userId,
          'alertType': 'major',
          'location': GeoPoint(
            _currentPosition!.latitude,
            _currentPosition!.longitude,
          ),
          'radius': _alertRadius,
          'recipientIds': recipientIds,
          'recipientCount': _nearbyUsers.length,
          'timestamp': FieldValue.serverTimestamp(),
          'message': 'MAJOR EMERGENCY',
          'smsSent': canSendSMS,
          'smsContactCount': _emergencyContacts.length,
        });
        notificationsSaved = true;
      }

      if (context.mounted) {
        Navigator.pop(context); // close progress dialog
        String msg = '✅ MAJOR ALERT SENT!\n';
        if (smsCount > 0) {
          msg += '📱 SMS to $smsCount contact(s)\n';
        } else if (canSendSMS) {
          msg += '❌ SMS failed to send. Check credit/SIM.\n';
        }
        if (notificationsSaved) {
          msg += '📲 Notified ${_nearbyUsers.length} nearby user(s)';
        }
        _showSnack(context, msg, smsCount > 0 ? Colors.green : Colors.orange,
            duration: const Duration(seconds: 5));
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        _showSnack(context, 'Error sending alert: $e', Colors.red);
      }
    }
  }

  Future<void> sendMinorAlert(BuildContext context) async {
    if (!_isTracking || _currentPosition == null) {
      _showSnack(context, 'Location tracking is not active.', Colors.red);
      return;
    }

    if (_nearbyUsers.isEmpty) {
      _showSnack(
        context,
        'No active app users within ${_alertRadius.toStringAsFixed(0)}m to notify.',
        Colors.orange,
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(
                color: Colors.orangeAccent),
            const SizedBox(height: 16),
            Text(
              'Notifying ${_nearbyUsers.length} active user(s)...',
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
    );

    try {
      final recipientIds =
          _nearbyUsers.map((u) => u.userId).toList();

      await FirebaseFirestore.instance
          .collection('alerts')
          .add({
        'senderId': _userId,
        'alertType': 'minor',
        'location': GeoPoint(
          _currentPosition!.latitude,
          _currentPosition!.longitude,
        ),
        'radius': _alertRadius,
        'recipientIds': recipientIds,
        'recipientCount': _nearbyUsers.length,
        'timestamp': FieldValue.serverTimestamp(),
        'message': 'Minor Issue',
        'smsSent': false,
        'smsContactCount': 0,
      });

      if (context.mounted) {
        Navigator.pop(context);
        _showSnack(
          context,
          '✅ Alert sent to ${_nearbyUsers.length} active user(s)',
          Colors.orange,
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        _showSnack(context, 'Error: $e', Colors.red);
      }
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _showSnack(BuildContext context, String message, Color color,
      {Duration duration = const Duration(seconds: 3)}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: duration,
      ),
    );
  }

  @override
  void dispose() {
    _locationStreamSubscription?.cancel();
    _usersSubscription?.cancel();
    _alertsSubscription?.cancel();
    super.dispose();
  }
}
