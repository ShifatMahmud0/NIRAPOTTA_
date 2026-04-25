import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'audio_recording_service.dart';
import 'camera_service.dart';
import 'notification_service.dart';
import 'app_globals.dart';
import 'screens/background_recording_screen.dart';
import 'services/brain_service.dart'; // ← NEW IMPORT

class EmergencyActionDispatcher {

  // ─────────────────────────────────────────────────────────────────────────
  // NEW: Brain-gated dispatch
  //
  // Call this instead of dispatch() for sensor-triggered events.
  // It runs the ML model first, then decides whether/how to escalate.
  //
  // Example usage in gesture_service.dart callback:
  //
  //   onGestureDetected: (GestureType type) async {
  //     final reason = type == GestureType.IMPACT ? 'IMPACT_DETECTED' : 'SHAKE_DETECTED';
  //     await EmergencyActionDispatcher.dispatchWithBrain(
  //       triggerKey: type == GestureType.IMPACT ? 'impact' : 'shake',
  //       reason: reason,
  //     );
  //   }
  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> dispatchWithBrain({
    required String triggerKey,
    required String reason,
  }) async {
    final brain = BrainService();

    if (!brain.isReady) {
      // Model not loaded — fall back to the original threshold-based dispatch
      debugPrint('⚠️  BrainService not ready, falling back to simple dispatch.');
      await dispatch(triggerKey, reason);
      return;
    }

    debugPrint('🧠  Consulting Brain for trigger: $triggerKey ($reason)');
    final AlertSeverity severity = await brain.analyze();

    switch (severity) {
      case AlertSeverity.major:
        debugPrint('🚨  Brain: MAJOR ALERT → Dispatching full SOS');
        // Force full emergency: override user prefs and trigger all actions
        await _dispatchMajorAlert(reason);
        break;

      case AlertSeverity.minor:
        debugPrint('⚠️   Brain: MINOR alert → Dispatching user-configured actions');
        // Respect the user's configured actions for this trigger
        await dispatch(triggerKey, reason);
        break;

      case AlertSeverity.none:
        debugPrint('✅  Brain: FALSE ALARM → Suppressed ($reason)');
        // Do nothing — dropped phone, normal walk, etc.
        break;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MAJOR ALERT — sends full SOS regardless of user config
  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> _dispatchMajorAlert(String reason) async {
    // 1. Send emergency SMS with GPS coordinates
    await NotificationService().sendEmergencyAlert(reason);

    // 2. Start audio recording immediately
    final audioSvc = AudioRecordingService();
    if (!audioSvc.isRecording) {
      await audioSvc.startRecording();
    }

    // 3. Take a silent photo
    final camSvc = CameraService();
    await camSvc.takeEvidencePhoto('MAJOR_ALERT');

    // 4. Start video recording
    if (!camSvc.isRecordingVideo) {
      await camSvc.startVideoRecording();
    }

    // 5. Navigate to the alert screen if the app is open
    if (navigatorKey.currentContext != null) {
      Navigator.of(navigatorKey.currentContext!).push(
        MaterialPageRoute(builder: (_) => const BackgroundRecordingScreen()),
      );
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // ORIGINAL dispatch (unchanged) — used for minor alerts & manual triggers
  // ─────────────────────────────────────────────────────────────────────────

  /// Dispatches the customized actions tied to a specific trigger event
  static Future<void> dispatch(String triggerKey, String reason) async {
    final prefs = await SharedPreferences.getInstance();

    List<String> actions =
        prefs.getStringList('trigger_$triggerKey') ?? _getDefault(triggerKey);

    debugPrint('Dispatching Trigger: $triggerKey with actions: $actions');

    if (actions.contains('sms')) {
      await NotificationService().sendEmergencyAlert(reason);
    }

    if (actions.contains('audio')) {
      final audioSvc = AudioRecordingService();
      if (!audioSvc.isRecording) {
        await audioSvc.startRecording();
      }
    }

    if (actions.contains('video')) {
      final camSvc = CameraService();
      if (!camSvc.isRecordingVideo) {
        await camSvc.startVideoRecording();
      }
    }

    if (triggerKey == 'triple_volume') {
      if (navigatorKey.currentContext != null) {
        Navigator.of(navigatorKey.currentContext!).push(
          MaterialPageRoute(builder: (_) => const BackgroundRecordingScreen()),
        );
      }
    }
  }

  static List<String> _getDefault(String key) {
    switch (key) {
      case 'shake':
        return ['sms'];
      case 'impact':
        return ['sms', 'audio', 'video'];
      case 'loud_noise':
        return ['sms'];
      case 'double_power':
        return ['audio'];
      case 'triple_power':
        return ['video'];
      case 'triple_volume':
        return ['video', 'audio'];
      default:
        return [];
    }
  }
}