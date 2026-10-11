import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'safety_engine.dart';

class AgentAdvice {
  final String recommendedId, explanation;
  final List<String> tips;
  final List<double>? weights; // [lighting, activity, help, community]
  final double? maxDetour;
  AgentAdvice(this.recommendedId, this.explanation, this.tips, this.weights, this.maxDetour);
}

/// Run with: flutter run --dart-define=AGENT_URL=https://your-backend --dart-define=AGENT_KEY=secret
/// Without AGENT_URL the app still works and uses its built-in advice.
class AgentClient {
  static const baseUrl = String.fromEnvironment('AGENT_URL');
  static const appKey = String.fromEnvironment('AGENT_KEY');

  Future<AgentAdvice?> advise({
    required String message,
    required bool night,
    required List<ScoredRoute> routes,
  }) async {
    if (baseUrl.isEmpty || routes.isEmpty) return null;
    try {
      final body = jsonEncode({
        'message': message,
        'night': night,
        'routes': [
          for (final r in routes)
            {
              'id': r.id,
              'minutes': (r.raw.durationS / 60).round(),
              'km': double.parse((r.raw.distanceM / 1000).toStringAsFixed(2)),
              'score': r.score,
              'confidence': double.parse(r.confidence.toStringAsFixed(2)),
              'factors': {
                'lighting': r.factors.lighting,
                'activity': r.factors.activity,
                'help': r.factors.help,
                'community': r.factors.community,
              },
              'notes': r.notes, // generated on-device; raw review text is never sent
            }
        ],
      });
      final res = await http
          .post(Uri.parse('$baseUrl/agent/advise'),
              headers: {'Content-Type': 'application/json', 'X-App-Key': appKey}, body: body)
          .timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body);
      return AgentAdvice(
        j['recommended_id'] as String,
        j['explanation'] as String,
        List<String>.from(j['tips'] ?? const []),
        (j['weights'] as List?)?.map((x) => (x as num).toDouble()).toList(),
        (j['max_detour'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }
}

class Sos {
  /// Opens the SMS app pre-filled with a live-location link. The user taps send:
  /// silent background SMS is blocked by Android/Play policy. For fully automatic
  /// alerts, send from your backend (e.g. an SMS API) instead.
  static Future<void> message(List<String> contacts, Position? pos) {
    final link = pos == null ? '' : ' My live location: https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    final body = 'SOS from SafeNav. I may be in danger.$link';
    return launchUrl(Uri.parse('sms:${contacts.join(',')}?body=${Uri.encodeComponent(body)}'));
  }

  static Future<void> call112() => launchUrl(Uri.parse('tel:112'));

  /// Opens the SMS app with any pre-filled text (the user taps send).
  static Future<void> sms(List<String> contacts, String body) =>
      launchUrl(Uri.parse('sms:${contacts.join(',')}?body=${Uri.encodeComponent(body)}'));
}
