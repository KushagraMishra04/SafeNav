import 'dart:async';
import 'dart:math' as math;
import 'package:sensors_plus/sensors_plus.dart';

/// Calls [onShake] after four hard shakes within about 1.5 seconds.
/// Walking and running do not reach this level. Only listens between start() and stop().
class ShakeDetector {
  final void Function() onShake;
  ShakeDetector(this.onShake);

  StreamSubscription<UserAccelerometerEvent>? _sub;
  final _hits = <DateTime>[];

  void start() {
    _sub ??= userAccelerometerEventStream().listen((e) {
      final g = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z); // gravity already removed
      if (g < 18) return;
      final now = DateTime.now();
      if (_hits.isNotEmpty && now.difference(_hits.last).inMilliseconds < 200) return; // same shake
      _hits.add(now);
      _hits.removeWhere((t) => now.difference(t).inMilliseconds > 1500);
      if (_hits.length >= 4) {
        _hits.clear();
        onShake();
      }
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _hits.clear();
  }
}
