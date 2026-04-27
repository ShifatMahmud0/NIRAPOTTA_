import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import '../data/sensor_repository.dart';
import '../data/sensor_reading_model.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Alert severity levels — the output of "The Brain"
// ─────────────────────────────────────────────────────────────────────────────

enum AlertSeverity {
  none,   // False alarm — do nothing
  minor,  // Possible struggle — show local warning
  major,  // High-confidence emergency — dispatch full SOS
}

// ─────────────────────────────────────────────────────────────────────────────
// Normalization parameters loaded from assets/ml/norm_params.json
// ─────────────────────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────────────────────
// BrainService — singleton that wraps TFLite inference
// ─────────────────────────────────────────────────────────────────────────────

class BrainService extends ChangeNotifier {
  // ── Singleton ──────────────────────────────────────────────────────────────
  static final BrainService _instance = BrainService._internal();
  factory BrainService() => _instance;
  BrainService._internal();

  // ── Features ───────────────────────────────────────────────────────────────
  static const int _numFeatures = 5; // Acc_X, Acc_Y, Acc_Z, Magnitude, DB_Level

  // ── Dynamic thresholds (tuned by sensitivity sliders) ──────────────────────
  static const double _majorThreshold = 0.60;
  static const double _minorThreshold = 0.40;

  // ── State ──────────────────────────────────────────────────────────────────
  Interpreter? _interpreter;   // ← tflite_flutter interpreter (pure Dart)
  _NormParams? _normParams;
  bool _isReady = false;

  /// Last output probabilities — useful for the debug overlay on HomeScreen
  List<double> lastProbabilities = [0.0, 0.0, 0.0];

  bool get isReady => _isReady;

  // ── Sensitivity tuning ─────────────────────────────────────────────────────

  /// Called from HomeScreen slider changes.
  /// Maps shakeValue 10 (high sensitivity) → 0.30 confidence needed
  ///                 30 (low  sensitivity) → 0.75 confidence needed
  // CHANGE the entire tuneSensitivity method to this:
  void tuneSensitivity(double shakeValue, double soundValue) {
    // The sensitivity sliders control when GestureService and SoundService
    // wake up the brain — not how confident the brain needs to be.
    // Brain thresholds are fixed to prevent false MAJOR alerts.
    debugPrint(
      '🧠 Gesture threshold: ${shakeValue} m/s²  '
          'Sound threshold: ${soundValue} dB  '
          'Brain: MAJOR needs 60%, MINOR needs 40%',
    );
  }

  // ── Initialization ─────────────────────────────────────────────────────────

  /// Loads model.tflite and norm_params.json from assets.
  /// Call once in main() before runApp().
  Future<void> initialize() async {
    try {
      // 1. Load normalization parameters
      final normJson =
      await rootBundle.loadString('assets/ml/norm_params.json');
      _normParams = _NormParams.fromJson(json.decode(normJson));

      // 2. Load the TFLite interpreter directly in Dart — no native code needed
      _interpreter = await Interpreter.fromAsset('assets/ml/model.tflite');
      _interpreter!.allocateTensors();

      _isReady = true;
      debugPrint(
        '✅ BrainService: model.tflite loaded and ready. '
            'Window=${_normParams!.windowSize}',
      );
    } catch (e) {
      _isReady = false;
      debugPrint('❌ BrainService: Failed to initialize — $e');
      debugPrint(
        '   Check that assets/ml/model.tflite and '
            'assets/ml/norm_params.json exist and are listed in pubspec.yaml',
      );
    }
  }

  // ── Main inference ─────────────────────────────────────────────────────────

  /// Fetches the sensor buffer, runs TFLite inference, returns AlertSeverity.
  Future<AlertSeverity> analyze() async {
    if (!_isReady || _interpreter == null || _normParams == null) {
      // Fail-safe: if model not loaded, allow a minor alert so the user
      // is never left completely unprotected.
      debugPrint('⚠️ BrainService: not ready — fail-safe minor alert');
      return AlertSeverity.minor;
    }

    try {
      // ── Step 1: Fetch raw sensor data ──────────────────────────────────────
      final List<SensorReading> rawData =
      SensorDataRepository().getRecentData();

      // ── Step 2: Build 2D input matrix (windowSize × 5) ────────────────────
      final int windowSize = _normParams!.windowSize;
      final inputMatrix = _buildInputMatrix(rawData, windowSize);

      // ── Step 3: Normalize using training-time min/max ──────────────────────
      final normalizedMatrix = _normalize(inputMatrix);

      // ── Step 4: Shape input as [1, windowSize, numFeatures] ───────────────
      // tflite_flutter needs a nested List that matches the tensor shape.
      final input = [normalizedMatrix];          // adds batch dimension

      // ── Step 5: Prepare output tensor [1, 3] ──────────────────────────────
      final output = [List<double>.filled(3, 0.0)];

      // ── Step 6: Run inference — takes under 50ms on a modern phone ─────────
      _interpreter!.run(input, output);

      final List<double> probs = output[0];
      lastProbabilities = List<double>.from(probs);
      notifyListeners();

      // ── Step 7: Log probabilities for debugging ────────────────────────────
      debugPrint(
        '🧠 Brain output → '
            'None: ${(probs[0] * 100).toStringAsFixed(1)}%  '
            'Minor: ${(probs[1] * 100).toStringAsFixed(1)}%  '
            'Major: ${(probs[2] * 100).toStringAsFixed(1)}%  '
            '| thresholds: major≥${(_majorThreshold * 100).toStringAsFixed(0)}%  '
            'minor≥${(_minorThreshold * 100).toStringAsFixed(0)}%',
      );

      // ── Step 8: Apply logic gate ───────────────────────────────────────────
      if (probs[2] >= _majorThreshold) return AlertSeverity.major;
      if (probs[1] >= _minorThreshold) return AlertSeverity.minor;
      return AlertSeverity.none;
    } catch (e) {
      debugPrint('❌ BrainService.analyze() error: $e');
      return AlertSeverity.none;
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Converts raw SensorReading list into a (windowSize × 5) matrix.
  /// Rows: [Acc_X, Acc_Y, Acc_Z, Magnitude, DB_Level]
  /// Short buffers are zero-padded at the beginning (matches training ZOH).
  List<List<double>> _buildInputMatrix(
      List<SensorReading> readings,
      int windowSize,
      ) {
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

  /// Min-max normalization to [0.0, 1.0] using training-time statistics.
  /// Uses the exact same formula as train_model.py — critical for accuracy.
  List<List<double>> _normalize(List<List<double>> matrix) {
    final fMin = _normParams!.min;
    final fMax = _normParams!.max;

    return matrix.map((row) {
      return List<double>.generate(_numFeatures, (f) {
        final range = fMax[f] - fMin[f];
        if (range == 0) return 0.0; // avoid division by zero
        return ((row[f] - fMin[f]) / range).clamp(0.0, 1.0);
      });
    }).toList();
  }

  // ── Cleanup ────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }
}