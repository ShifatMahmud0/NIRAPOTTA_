import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';
import 'package:slide_to_act/slide_to_act.dart';
import 'package:google_fonts/google_fonts.dart';
import 'services/proximity_alert_service.dart';

class AlertScreen extends StatefulWidget {
  final String triggerReason; // Added parameter

  const AlertScreen({
    super.key,
    this.triggerReason = "EMERGENCY DETECTED", // Default value
  });

  @override
  State<AlertScreen> createState() => _AlertScreenState();
}

class _AlertScreenState extends State<AlertScreen> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;

  bool _isStopping = false;

  @override
  void initState() {
    super.initState();
    _startAlarm();
  }

  Future<void> _startAlarm() async {
    // Check if we are already stopping before starting anything
    if (_isStopping || !mounted) return;

    // Play loud alert sound
    try {
      await _audioPlayer.setReleaseMode(ReleaseMode.loop);
      if (_isStopping || !mounted) return; // Re-check
      await _audioPlayer.setSource(AssetSource('alert_sound.mp3'));
      if (_isStopping || !mounted) return; // Re-check
      await _audioPlayer.resume();
      setState(() {
        _isPlaying = true;
      });
    } catch (e) {
      debugPrint('Error playing sound: $e');
    }
    // NOTE: Vibration intentionally removed here.
    // Vibration is triggered by ProximityAlertService when a notification
    // arrives FROM ANOTHER USER — not when the sensor-triggered alert screen opens.
  }

  Future<void> _stopAlarm() async {
    _isStopping = true; // Set flag immediately
    await _audioPlayer.stop();
    await Vibration.cancel();
    debugPrint('Alarm stopped');
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
    return Scaffold(
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF8B0000), // Dark Red
              Color(0xFF1E1E1E), // Dark Grey
              Color(0xFF2D1B2E), // Deep muted ruby
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 100,
                color: Colors.white,
              ),
              const SizedBox(height: 20),
              const Text(
                'EMERGENCY ALERT!',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              // Display dynamic Trigger Reason
              Text(
                widget.triggerReason,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.yellowAccent,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 5),
              const Text(
                'Tap below to send an emergency alert:',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.white70,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 30),

              // ── MAJOR ALERT button ──────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD32F2F),
                    minimumSize: const Size(double.infinity, 64),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: 8,
                  ),
                  icon: const Icon(Icons.warning_amber_rounded,
                      color: Colors.white, size: 28),
                  label: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('MAJOR ALERT',
                          style: GoogleFonts.outfit(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1.2)),
                      const Text('SMS to contacts + notify nearby users',
                          style:
                              TextStyle(fontSize: 10, color: Colors.white70)),
                    ],
                  ),
                  onPressed: () =>
                      ProximityAlertService().sendMajorAlert(context),
                ),
              ),

              const SizedBox(height: 16),

              // ── MINOR ALERT button ──────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE65100),
                    minimumSize: const Size(double.infinity, 64),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: 8,
                  ),
                  icon: const Icon(Icons.info_outline,
                      color: Colors.white, size: 28),
                  label: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('MINOR ALERT',
                          style: GoogleFonts.outfit(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: 1.2)),
                      const Text('Notify nearby users only',
                          style:
                              TextStyle(fontSize: 10, color: Colors.white70)),
                    ],
                  ),
                  onPressed: () =>
                      ProximityAlertService().sendMinorAlert(context),
                ),
              ),
              const Spacer(),
              // Slide to Stop (Modern Safety Feature)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: SlideAction(
                  borderRadius: 30,
                  elevation: 0,
                  innerColor: Colors.red,
                  outerColor: Colors.white,
                  sliderButtonIcon: const Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: Colors.white,
                  ),
                  text: 'SLIDE TO DISABLE',
                  textStyle: const TextStyle(
                    color: Colors.red,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                  onSubmit: () async {
                    await _stopAlarm();
                    return null; // Reset slider? No, we pop.
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

