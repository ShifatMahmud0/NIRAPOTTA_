import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:avatar_glow/avatar_glow.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'gesture_service.dart';
import 'sound_service.dart';
import 'camera_service.dart';
import 'data/sensor_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'alert_screen.dart';
import 'screens/log_viewer_screen.dart';
import 'screens/calibration_screen.dart';
import 'screens/splash_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'screens/secure_gallery_auth_screen.dart';
import 'widgets/glass_container.dart';
import 'hardware_button_service.dart';
import 'action_dispatcher.dart';
import 'screens/emergency_contacts_screen.dart';
import 'screens/trigger_customization_screen.dart';
import 'services/proximity_alert_service.dart';
import 'app_globals.dart';
import 'notification_service.dart';
import 'services/brain_service.dart';

// ── FCM Background Handler ─────────────────────────────────────────────────
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  final notificationService = NotificationService();
  await notificationService.initialize(); 
  
  final data = message.data;
  final alertType = data['alertType'] ?? 'unknown';
  final isMajor = alertType == 'major';
  
  await notificationService.showIncomingAlertNotification(
    title: isMajor ? '🚨 EMERGENCY ALERT' : '⚠️ Warning Alert',
    body: 'Someone nearby needs help!',
    payload: 'alert_received',
  );
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await Firebase.initializeApp();
    await NotificationService().initialize();
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    ProximityAlertService().initialize();
    await BrainService().initialize();
  } catch (e) {
    debugPrint('Firebase init error: $e');
  }
  
  runApp(const ShakeAlertApp());
}

class ShakeAlertApp extends StatelessWidget {
  const ShakeAlertApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Nirapotta ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE53935), // Safety Red
          surface: Color(0xFF1E1E1E),
          onSurface: Colors.white,
        ),
        useMaterial3: true,
        textTheme: GoogleFonts.outfitTextTheme(
          ThemeData.dark().textTheme,
        ),
      ),
      home: const SplashScreen(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late GestureService _gestureService;
  late SoundService _soundService;

  bool _isListening = false;
  bool _isTriggering = false; 
  double _shakeSensitivity = 15.0;
  double _soundSensitivity = 85.0;

  @override
  void initState() {
    super.initState();
    _loadCustomPreferences();

    HardwareButtonService.platform.setMethodCallHandler((call) async {
      debugPrint('📞 Hardware Button Event: ${call.method}');
      if (_isTriggering) return;

      if (call.method == 'power_button_double_click') {
        _triggerAlert('Panic Button: Double Power Press');
      } else if (call.method == 'power_button_triple_click') {
        _triggerAlert('Panic Button: Triple Power Press');
      } else if (call.method == 'volume_button_triple_click') {
        _triggerAlert('Panic Button: Triple Volume Press');
      }
    });

    _gestureService = GestureService(
      onGestureDetected: _onGestureDetected,
      shakeThreshold: _shakeSensitivity,
    );

    _soundService = SoundService(
      onLoudNoiseDetected: _onLoudNoiseDetected,
      dbThreshold: _soundSensitivity,
    );
  }

  Future<void> _loadCustomPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _shakeSensitivity = prefs.getDouble('shake_sensitivity') ?? 15.0;
        _soundSensitivity = prefs.getDouble('sound_sensitivity') ?? 85.0;

        _gestureService.shakeThreshold = _shakeSensitivity;
        _soundService.dbThreshold = _soundSensitivity;
        
        BrainService().tuneSensitivity(_shakeSensitivity, _soundSensitivity);
      });
    }
  }

  void _onGestureDetected(GestureType type) {
    debugPrint('📳 Sensor detected gesture: $type (Listening: $_isListening)');
    if (!mounted || !_isListening || _isTriggering) return;
    String triggerType =
        type == GestureType.impact ? "IMPACT DETECTED" : "SHAKE DETECTED";
    _triggerAlert(triggerType);
  }

  void _onLoudNoiseDetected() {
    debugPrint('🎤 Sensor detected LOUD NOISE (Listening: $_isListening)');
    if (!mounted || !_isListening || _isTriggering) return;
    _triggerAlert("LOUD NOISE DETECTED");
  }

  void _triggerAlert(String reason) async {
    if (_isTriggering) return;
    
    debugPrint('🧠 BRAIN INFERENCE START: $reason');
    final AlertSeverity severity = await BrainService().analyze();
    debugPrint('🧠 BRAIN INFERENCE RESULT: $severity');
    
    if (severity == AlertSeverity.none) {
      debugPrint('🧠 Brain: Ignored false alarm.');
      return; 
    }

    setState(() {
      _isTriggering = true;
      _isListening = false; 
    });

    _gestureService.stopListening();
    _soundService.stopListening();
    ProximityAlertService().stopTracking();

    SensorDataRepository().lastTriggerReason = reason;

    // Background Buffer Handling
    Future.delayed(const Duration(seconds: 8), () {
      final String csvSnapshot = SensorDataRepository().getCSVData();
      SensorDataRepository().saveSnapshotToFile(csvSnapshot, reason);
    });

    String triggerKey = 'shake';
    if (reason.contains("LOUD NOISE")) {
      triggerKey = 'loud_noise';
    } else if (reason.contains("Double Power")) {
      triggerKey = 'double_power';
    } else if (reason.contains("Triple Power")) {
      triggerKey = 'triple_power';
    } else if (reason.contains("Triple Volume")) {
      triggerKey = 'triple_volume';
    }

    EmergencyActionDispatcher.dispatch(triggerKey, reason);

    if (severity == AlertSeverity.major) {
      try {
        await CameraService().takeEvidencePhoto(reason);
      } catch (e) {
        debugPrint("Failed to capture evidence: $e");
      }
    }

    if (!mounted) return;

    // Show the Alert Window with detected severity
    await Navigator.of(context).push(
      MaterialPageRoute(
          builder: (context) => AlertScreen(
            triggerReason: reason, 
            severity: severity,
          )),
    );

    if (mounted) {
      setState(() {
        _isTriggering = false;
        _isListening = false; 
      });
    }
  }

  void _toggleListening() async {
    if (_isListening) {
      debugPrint('⏹️ Disarming Sentinel...');
      _gestureService.stopListening();
      _soundService.stopListening();
      ProximityAlertService().stopTracking();
      setState(() {
        _isListening = false;
      });
    } else {
      debugPrint('🚀 Arming Sentinel...');
      _gestureService.startListening();
      await _soundService.startListening();
      ProximityAlertService().startTracking();
      setState(() {
        _isListening = true;
      });
    }
  }

  void _updateSensitivity(double value) async {
    setState(() {
      _shakeSensitivity = value;
      _gestureService.shakeThreshold = _shakeSensitivity;
      BrainService().tuneSensitivity(_shakeSensitivity, _soundSensitivity);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('shake_sensitivity', value);
  }

  void _updateSoundSensitivity(double value) async {
    setState(() {
      _soundSensitivity = value;
      _soundService.dbThreshold = _soundSensitivity;
      BrainService().tuneSensitivity(_shakeSensitivity, _soundSensitivity);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('sound_sensitivity', value);
  }

  @override
  void dispose() {
    _gestureService.stopListening();
    _soundService.stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          title: Text(
            'Nirapotta Safety V3',
            style: GoogleFonts.outfit(
                fontWeight: FontWeight.bold, letterSpacing: 1.0),
          ),
          centerTitle: true,
          backgroundColor: Colors.black.withValues(alpha: 0.3),
          elevation: 0,
          flexibleSpace: ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(color: Colors.transparent),
            ),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.lock_person),
              tooltip: 'Secure Gallery',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (context) => const SecureGalleryAuthScreen()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.tune),
              tooltip: 'Hardware Calibration',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (context) => const CalibrationScreen()),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.data_usage),
              tooltip: 'Sensor Logs',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (context) => const LogViewerScreen()),
                );
              },
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              onSelected: (String result) {
                if (result == 'contacts') {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (context) => const EmergencyContactsScreen()));
                } else if (result == 'triggers') {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (context) =>
                          const TriggerCustomizationScreen()));
                }
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'contacts',
                  child: Text('Emergency Contacts'),
                ),
                const PopupMenuItem<String>(
                  value: 'triggers',
                  child: Text('Customize Triggers'),
                ),
              ],
            ),
          ],
        ),
        body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0F172A),
                  Color(0xFF1E1E1E),
                  Color(0xFF2D1B2E),
                ],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Safety Disclaimer (Glass)
                    GlassContainer(
                      padding: const EdgeInsets.all(16),
                      opacity: 0.1,
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.15)),
                      child: Row(
                        children: [
                          Icon(Icons.shield_outlined,
                              color: Colors.amber.shade400, size: 28),
                          const SizedBox(width: 16),
                          const Expanded(
                            child: Text(
                              'AI Active: Monitoring sensors for falls, impacts, and distress signals.',
                              style: TextStyle(
                                  fontSize: 13,
                                  color: Colors.white,
                                  height: 1.4),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const Spacer(),

                    Center(
                      child: AvatarGlow(
                        animate: _isListening,
                        glowColor: _isListening
                            ? const Color(0xFFE53935)
                            : Colors.blueGrey,
                        duration: const Duration(milliseconds: 2000),
                        repeat: true,
                        child: GestureDetector(
                          onTap: _toggleListening,
                          child: Container(
                            width: 180,
                            height: 180,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: _isListening
                                    ? [
                                        const Color(0xFFFF5252),
                                        const Color(0xFFD32F2F)
                                      ]
                                    : [
                                        const Color(0xFF37474F),
                                        const Color(0xFF263238)
                                      ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _isListening
                                      ? Colors.redAccent.withValues(alpha: 0.4)
                                      : Colors.black.withValues(alpha: 0.5),
                                  blurRadius: 30,
                                  spreadRadius: 5,
                                )
                              ],
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.2),
                                width: 2,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _isListening
                                      ? Icons.security
                                      : Icons.power_settings_new,
                                  size: 50,
                                  color: Colors.white,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _isListening ? 'ARMED' : 'TAP TO\nACTIVATE',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.outfit(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                    letterSpacing: 1.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),

                    const Spacer(),

                    GlassContainer(
                      padding: const EdgeInsets.all(20),
                      opacity: 0.05,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'MOTION SENSITIVITY',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white54),
                              ),
                              Text(
                                '${_shakeSensitivity.toStringAsFixed(1)} m/s²',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.blueAccent),
                              ),
                            ],
                          ),
                          Slider(
                            value: _shakeSensitivity,
                            min: 10.0,
                            max: 30.0,
                            divisions: 20,
                            activeColor: Colors.blueAccent,
                            inactiveColor: Colors.white10,
                            label: _shakeSensitivity.toStringAsFixed(1),
                            onChanged: _isListening ? null : _updateSensitivity,
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'MIC SENSITIVITY (dB)',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white54),
                              ),
                              Text(
                                '${_soundSensitivity.toStringAsFixed(1)} dB',
                                style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.orangeAccent),
                              ),
                            ],
                          ),
                          Slider(
                            value: _soundSensitivity,
                            min: 50.0,
                            max: 100.0,
                            divisions: 50,
                            activeColor: Colors.orangeAccent,
                            inactiveColor: Colors.white10,
                            label: _soundSensitivity.toStringAsFixed(1),
                            onChanged:
                                _isListening ? null : _updateSoundSensitivity,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            )));
  }
}
