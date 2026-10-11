import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Spoken prompts and vibration, so you do not have to keep looking at the screen.
class Voice {
  final _tts = FlutterTts();
  bool enabled = true;
  bool _ready = false;

  Future<void> _init() async {
    if (_ready) return;
    _ready = true;
    try {
      await _tts.setLanguage('en-IN');
      await _tts.setSpeechRate(0.5);
    } catch (_) {}
  }

  Future<void> say(String text) async {
    if (!enabled) return;
    await _init();
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// A light tap for turns.
  static Future<void> tap() => HapticFeedback.mediumImpact();

  /// A double heavy buzz for warnings and check-ins.
  static Future<void> alert() async {
    await HapticFeedback.heavyImpact();
    await Future.delayed(const Duration(milliseconds: 250));
    await HapticFeedback.heavyImpact();
  }
}
