import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:slide_to_act/slide_to_act.dart';
import 'package:google_fonts/google_fonts.dart';
import 'services/proximity_alert_service.dart';
import 'services/brain_service.dart';

class AlertScreen extends StatefulWidget {
  final String triggerReason; 
  final AlertSeverity severity; // New: Detect if major or minor

  const AlertScreen({
    super.key,
    required this.triggerReason,
    required this.severity,
  });

  @override
  State<AlertScreen> createState() => _AlertScreenState();
}

class _AlertScreenState extends State<AlertScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isStopping = false;

  @override
  void initState() {
    super.initState();
    _startAlarm();
    
    // ── AUTOMATIC BACKEND ACTION ──
    // Immediately perform the SOS logic based on what the Brain detected
    _performAutomaticSOS();
  }

  Future<void> _startAlarm() async {
    if (_isStopping || !mounted) return;
    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      await _audioPlayer.setSource(AssetSource('alert_sound.mp3'));
      await _audioPlayer.resume();
    } catch (e) {
      debugPrint('Error playing sound: $e');
    }
  }

  void _performAutomaticSOS() {
    // We wrap this in a microtask so the UI shows first
    Future.microtask(() {
      if (widget.severity == AlertSeverity.major) {
        debugPrint('🚀 AlertScreen: Executing Automatic MAJOR SOS...');
        ProximityAlertService().sendMajorAlert(context);
      } else if (widget.severity == AlertSeverity.minor) {
        debugPrint('🚀 AlertScreen: Executing Automatic MINOR Notification...');
        ProximityAlertService().sendMinorAlert(context);
      }
    });
  }

  Future<void> _stopAlarm() async {
    _isStopping = true; 
    await _audioPlayer.stop();
    await Vibration.cancel();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    Vibration.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isMajor = widget.severity == AlertSeverity.major;

    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isMajor 
              ? [const Color(0xFFB71C1C), const Color(0xFF1E1E1E), const Color(0xFF2D1B2E)] // Intense Red
              : [const Color(0xFFE65100), const Color(0xFF1E1E1E), const Color(0xFF2D1B2E)], // Warning Orange
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isMajor ? Icons.report_problem : Icons.warning_amber_rounded,
                size: 120,
                color: Colors.white,
              ),
              const SizedBox(height: 20),
              Text(
                isMajor ? '🚨 MAJOR EMERGENCY 🚨' : '⚠️ MINOR ALERT ⚠️',
                style: GoogleFonts.outfit(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1.5
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(30)
                ),
                child: Text(
                  widget.triggerReason,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: Colors.yellowAccent,
                  ),
                ),
              ),
              const SizedBox(height: 40),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  isMajor 
                    ? 'SOS Messages sent to contacts and nearby sentinel users.' 
                    : 'Nearby sentinel users are being notified of your status.',
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
              ),
              
              const Spacer(),
              
              // Slide to Stop (The only interaction allowed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
                child: SlideAction(
                  borderRadius: 30,
                  elevation: 0,
                  innerColor: isMajor ? Colors.red : Colors.orange,
                  outerColor: Colors.white,
                  sliderButtonIcon: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white),
                  text: 'SLIDE TO DISABLE',
                  textStyle: TextStyle(
                    color: isMajor ? Colors.red : Colors.orange,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                  onSubmit: () async {
                    await _stopAlarm();
                    return null;
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
