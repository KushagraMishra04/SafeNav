import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Calls [onShake] after four hard shakes within 2.5 seconds.
/// [onHit] fires on every hard shake peak, so the screen can give feedback (a buzz).
class ShakeDetector {
  final void Function() onShake;
  final void Function(int hits)? onHit;
  ShakeDetector(this.onShake, {this.onHit});

  /// m/s² with gravity removed. Walking stays well below this; a deliberate hard shake passes it.
  static const threshold = 20.0;
  static const hitsNeeded = 4;
  static const window = Duration(milliseconds: 2500);
  static const gap = Duration(milliseconds: 120);

  StreamSubscription<UserAccelerometerEvent>? _sub;
  final _hits = <DateTime>[];

  void start() {
    if (_sub != null) return;
    // Fast sampling (about 50 readings a second). The default of 5 a second misses most shake peaks.
    _sub = userAccelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) {
      final g = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      if (g < threshold) return;
      final now = DateTime.now();
      if (_hits.isNotEmpty && now.difference(_hits.last) < gap) return; // same shake
      _hits.add(now);
      _hits.removeWhere((t) => now.difference(t) > window);
      onHit?.call(_hits.length);
      if (_hits.length >= hitsNeeded) {
        _hits.clear();
        onShake();
      }
    }, onError: (Object e) => debugPrint('Shake sensor unavailable: $e'));
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _hits.clear();
  }
}
