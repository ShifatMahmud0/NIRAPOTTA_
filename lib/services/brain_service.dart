import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../data/sensor_repository.dart';
import '../data/sensor_reading_model.dart';

enum AlertSeverity {
  none,   
  minor,  
  major,  
}

class _NormParams {
  final List<double> min;
  final List<double> max;
  final int windowSize;

  const _NormParams({
    required this.min,
    required this.max,
    required this.windowSize,
  });

  factory _NormParams.fromJson(Map<String, dynamic> json) {
    return _NormParams(
      min: List<double>.from(json['min'].map((v) => (v as num).toDouble())),
      max: List<double>.from(json['max'].map((v) => (v as num).toDouble())),
      windowSize: json['window_size'] as int,
    );
  }
}

class BrainService extends ChangeNotifier {
  static final BrainService _instance = BrainService._internal();
  factory BrainService() => _instance;
  BrainService._internal();

  static const _channel = MethodChannel('com.example.gps_sms/brain');

  // ── DYNAMIC THRESHOLDS ──
  double majorThreshold = 0.30; // Lowered default starting point
  double minorThreshold = 0.15;
  
  static const int _numFeatures = 5;

  _NormParams? _normParams;
  bool _isReady = false;
  List<double> lastProbabilities = [0.0, 0.0, 0.0];

  bool get isReady => _isReady;

  /// Updates the AI confidence requirements based on Home Screen Sensitivity Sliders.
  void tuneSensitivity(double shakeValue, double soundValue) {
    // Mapping 10 (High Sensitivity) -> 0.15 (15% confidence needed)
    // Mapping 30 (Low Sensitivity) -> 0.75 (75% confidence needed)
    majorThreshold = 0.15 + ((shakeValue - 10) / 20) * 0.60;
    
    // Minor threshold is always lower
    minorThreshold = (majorThreshold * 0.5).clamp(0.1, 0.5);
    
    debugPrint('🧠 Brain Tuned: Need ${(majorThreshold*100).toStringAsFixed(0)}% AI confidence for Major Alert');
  }

  Future<void> initialize() async {
    try {
      final normJson = await rootBundle.loadString('assets/ml/norm_params.json');
      _normParams = _NormParams.fromJson(json.decode(normJson));
      final bool? success = await _channel.invokeMethod('loadModel');
      _isReady = success ?? false;
      debugPrint(_isReady ? '✅ BrainService: Native model ready.' : '❌ BrainService: Native load failed.');
    } catch (e) {
      _isReady = false;
      debugPrint('❌ BrainService: Init error — $e');
    }
  }

  Future<AlertSeverity> analyze() async {
    if (!_isReady || _normParams == null) {
      debugPrint('⚠️ BrainService: Model not ready, allowing alert anyway for safety.');
      return AlertSeverity.minor; // Fail-safe: trigger minor alert if AI is offline
    }

    try {
      final List<SensorReading> rawData = SensorDataRepository().getRecentData();
      final int windowSize = _normParams!.windowSize;
      final inputMatrix = _buildInputMatrix(rawData, windowSize);
      final normalizedMatrix = _normalize(inputMatrix);

      final List<double> flattened = normalizedMatrix.expand((row) => row).toList();

      final List<dynamic>? result = await _channel.invokeMethod<List<dynamic>>(
        'runInference', 
        {'data': flattened, 'windowSize': windowSize, 'numFeatures': _numFeatures}
      );

      if (result == null || result.length < 3) return AlertSeverity.none;
      
      final List<double> probs = result.map((e) => (e as num).toDouble()).toList();

      lastProbabilities = probs;
      notifyListeners();

      // DEBUG LOG: Show exactly what the AI thinks
      debugPrint('🧠 AI Confidence → Major: ${(probs[2]*100).toStringAsFixed(1)}%, Minor: ${(probs[1]*100).toStringAsFixed(1)}%, Normal: ${(probs[0]*100).toStringAsFixed(1)}%');
      debugPrint('🧠 Required confidence to trigger: ${(majorThreshold*100).toStringAsFixed(0)}%');

      if (probs[2] >= majorThreshold) return AlertSeverity.major;
      if (probs[1] >= minorThreshold) return AlertSeverity.minor;
      return AlertSeverity.none;

    } catch (e) {
      debugPrint('❌ BrainService.analyze() error: $e');
      return AlertSeverity.none;
    }
  }

  List<List<double>> _buildInputMatrix(List<SensorReading> readings, int windowSize) {
    final relevant = readings.length > windowSize
        ? readings.sublist(readings.length - windowSize)
        : readings;

    return List<List<double>>.generate(windowSize, (i) {
        final dataOffset = windowSize - relevant.length;
        if (i < dataOffset) return [0.0, 0.0, 0.0, 0.0, 0.0];
        final r = relevant[i - dataOffset];
        final mag = sqrt(r.x * r.x + r.y * r.y + r.z * r.z);
        return [r.x, r.y, r.z, mag, r.dbLevel ?? 0.0];
    });
  }

  List<List<double>> _normalize(List<List<double>> matrix) {
    final fMin = _normParams!.min;
    final fMax = _normParams!.max;
    return matrix.map((row) {
      return List<double>.generate(_numFeatures, (f) {
        final range = fMax[f] - fMin[f];
        if (range == 0) return 0.0; 
        return ((row[f] - fMin[f]) / range).clamp(0.0, 1.0);
      });
    }).toList();
  }
}
