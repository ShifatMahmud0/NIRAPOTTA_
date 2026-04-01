import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart'; // To navigate to HomePage
import 'disclaimer_screen.dart';
import 'pin_setup_screen.dart'; // To navigate to PIN setup
import 'package:firebase_auth/firebase_auth.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);

    _controller.forward();

    _navigateAfterDelay();
  }

  Future<void> _navigateAfterDelay() async {
    // Parallelize logic check
    final prefsFuture = SharedPreferences.getInstance();
    
    // Background Anonymous Auth sign-in if needed
    // This removes the need for the Google Sign-in screen entirely
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('Signing in anonymously in background...');
        await FirebaseAuth.instance.signInAnonymously();
      }
    } catch (e) {
      debugPrint('Silent Auth failed: $e');
    }

    await Future.wait([
      prefsFuture,
      Future.delayed(const Duration(seconds: 2)), 
    ]);

    if (!mounted) return;

    final prefs = await prefsFuture;
    final bool hasOnboarded = prefs.getBool('has_onboarded') ?? false;
    final bool hasPin = prefs.getString('gallery_pin') != null;

    if (hasOnboarded && hasPin) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomePage()),
      );
    } else if (hasOnboarded && !hasPin) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
            builder: (_) => const PinSetupScreen(isFromUpdate: true)),
      );
    } else {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const DisclaimerScreen()),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: Colors.transparent,
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
          child: Center(
            child: FadeTransition(
              opacity: _animation,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.security_outlined,
                    size: 100,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Nirapotta V3',
                    style: GoogleFonts.outfit(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Your Autonomous Sentinel',
                    style: GoogleFonts.outfit(
                      fontSize: 16,
                      color: Colors.white54,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
  }
}
