import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'safety_engine.dart';

class AgentAdvice {
  final String recommendedId, explanation;
  final List<String> tips;
  final List<double>? weights; // [lighting, activity, help, community]
  final double? maxDetour;
  AgentAdvice(this.recommendedId, this.explanation, this.tips, this.weights, this.maxDetour);
}

class AgentChatResponse {
  final String text;
  final List<String> followUps;
  final String? actionType;
  final List<Place> attachedPlaces;

  AgentChatResponse({
    required this.text,
    this.followUps = const [],
    this.actionType,
    this.attachedPlaces = const [],
  });
}

class WatchdogVerdict {
  final bool shouldCheckIn;
  final String reason;
  final bool escalateSos;

  WatchdogVerdict({
    required this.shouldCheckIn,
    required this.reason,
    required this.escalateSos,
  });
}

/// Run with: flutter run --dart-define=AGENT_URL=http://10.0.2.2:8000 --dart-define=AGENT_KEY=safenav-secret
/// Without AGENT_URL the app still works completely using its on-device rule engine.
class AgentClient {
  static const baseUrl = String.fromEnvironment('AGENT_URL');
  static const appKey = String.fromEnvironment('AGENT_KEY');

  Future<AgentAdvice?> advise({
    required String message,
    required bool night,
    required List<ScoredRoute> routes,
  }) async {
    if (baseUrl.isNotEmpty && routes.isNotEmpty) {
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
                'notes': r.notes,
              }
          ],
        });
        final res = await http
            .post(
              Uri.parse('$baseUrl/agent/advise'),
              headers: {'Content-Type': 'application/json', 'X-App-Key': appKey},
              body: body,
            )
            .timeout(const Duration(seconds: 15));

        if (res.statusCode == 200) {
          final j = jsonDecode(res.body);
          return AgentAdvice(
            j['recommended_id'] as String,
            j['explanation'] as String,
            List<String>.from(j['tips'] ?? const []),
            (j['weights'] as List?)?.map((x) => (x as num).toDouble()).toList(),
            (j['max_detour'] as num?)?.toDouble(),
          );
        }
      } catch (_) {}
    }

    // On-device intelligent fallback
    return _localAdvice(routes, night, message);
  }

  /// Interactive conversational chat with SafeNav Guardian
  Future<AgentChatResponse> chat({
    required String message,
    LatLng? currentLocation,
    String? routeSummary,
    int? routeScore,
  }) async {
    if (baseUrl.isNotEmpty) {
      try {
        final body = jsonEncode({
          'message': message,
          if (currentLocation != null)
            'location': {
              'lat': currentLocation.latitude,
              'lng': currentLocation.longitude,
            },
          if (routeSummary != null) 'route_summary': routeSummary,
          if (routeScore != null) 'route_score': routeScore,
        });

        final res = await http
            .post(
              Uri.parse('$baseUrl/agent/chat'),
              headers: {'Content-Type': 'application/json', 'X-App-Key': appKey},
              body: body,
            )
            .timeout(const Duration(seconds: 20));

        if (res.statusCode == 200) {
          final j = jsonDecode(res.body);
          final attached = <Place>[];
          if (j['safe_places'] is List) {
            for (final sp in j['safe_places']) {
              if (sp is Map && sp['lat'] != null && sp['lng'] != null) {
                attached.add(Place(
                  sp['name'] ?? 'Safe Haven',
                  LatLng((sp['lat'] as num).toDouble(), (sp['lng'] as num).toDouble()),
                ));
              }
            }
          }
          if (attached.isEmpty && j['action_type'] == 'safe_place' && currentLocation != null) {
            try {
              final pol = await SafetyEngine().nearbyPlaces(currentLocation, 'police');
              final hosp = await SafetyEngine().nearbyPlaces(currentLocation, 'hospital');
              attached.addAll([...pol, ...hosp]);
              attached.sort((a, b) => meters(currentLocation, a.at).compareTo(meters(currentLocation, b.at)));
            } catch (_) {}
          }
          return AgentChatResponse(
            text: j['text'] ?? '',
            followUps: List<String>.from(j['follow_ups'] ?? const []),
            actionType: j['action_type'],
            attachedPlaces: attached.take(3).toList(),
          );
        }
      } catch (_) {}
    }

    // On-device fallback for conversational queries
    return _localChatFallback(message, currentLocation, routeScore);
  }

  /// Watchdog trip evaluation: analyzes stops, off-route deviations, or missed check-ins
  Future<WatchdogVerdict> watchdog({
    required double offRouteMeters,
    required int stoppedMinutes,
    required bool vehicleDeparture,
    required bool missedCheckIn,
  }) async {
    if (baseUrl.isNotEmpty) {
      try {
        final body = jsonEncode({
          'off_route_meters': offRouteMeters,
          'stopped_minutes': stoppedMinutes,
          'vehicle_departure': vehicleDeparture,
          'missed_checkin': missedCheckIn,
        });

        final res = await http
            .post(
              Uri.parse('$baseUrl/agent/watchdog'),
              headers: {'Content-Type': 'application/json', 'X-App-Key': appKey},
              body: body,
            )
            .timeout(const Duration(seconds: 10));

        if (res.statusCode == 200) {
          final j = jsonDecode(res.body);
          return WatchdogVerdict(
            shouldCheckIn: j['should_check_in'] ?? false,
            reason: j['reason'] ?? '',
            escalateSos: j['escalate_sos'] ?? false,
          );
        }
      } catch (_) {}
    }

    // Local watchdog logic: prompt first, escalate only if no reply
    if (missedCheckIn) {
      return WatchdogVerdict(
        shouldCheckIn: false,
        reason: 'Missed safety check-in prompt without response.',
        escalateSos: true,
      );
    }
    if (vehicleDeparture) {
      return WatchdogVerdict(
        shouldCheckIn: true,
        reason: 'Detected sudden vehicle departure away from planned route.',
        escalateSos: false,
      );
    }
    if (offRouteMeters > 150) {
      return WatchdogVerdict(
        shouldCheckIn: true,
        reason: 'You moved over 150m away from your planned path.',
        escalateSos: false,
      );
    }
    if (stoppedMinutes >= 4) {
      return WatchdogVerdict(
        shouldCheckIn: true,
        reason: 'You have been stopped for more than 4 minutes.',
        escalateSos: false,
      );
    }

    return WatchdogVerdict(shouldCheckIn: false, reason: '', escalateSos: false);
  }

  // ---------- Local Fallbacks ----------
  AgentAdvice _localAdvice(List<ScoredRoute> routes, bool night, String msg) {
    routes.sort((a, b) => b.score.compareTo(a.score));
    final best = routes.first;
    final fastest = routes.reduce((a, b) => a.raw.durationS <= b.raw.durationS ? a : b);

    final String expl;
    if (best.id == fastest.id) {
      expl = 'Recommended Route: This route is both the safest (${best.score}%) and the fastest option.';
    } else {
      final extraMin = ((best.raw.durationS - fastest.raw.durationS) / 60).round();
      expl = 'Recommended Route: Adds $extraMin min vs the fastest path, but increases safety by ${best.score - fastest.score} points with better lit and active stretches.';
    }

    return AgentAdvice(
      best.id,
      expl,
      [
        if (night) 'Stay on well-lit main corridors after dark',
        'Keep phone charged and share live trip with trusted contacts',
      ],
      night ? [0.30, 0.15, 0.20, 0.35] : [0.15, 0.25, 0.20, 0.40],
      1.4,
    );
  }

  Future<AgentChatResponse> _localChatFallback(String q, LatLng? loc, int? score) async {
    final lower = q.toLowerCase();

    if (lower.contains('11 pm') || lower.contains('night') || lower.contains('dark') || lower.contains('late')) {
      return AgentChatResponse(
        text: 'At late hours (after 10–11 PM), commercial footfall decreases significantly and smaller lanes become isolated. '
            'I recommend routes that follow illuminated transit routes and commercial roads. If you are travelling alone, '
            'activate Guardian Timer and share your live trip.',
        followUps: ['Find nearest safe place', 'Share live trip with contacts'],
      );
    }

    if (lower.contains('somewhere safe') ||
        lower.contains('safe place') ||
        lower.contains('safe haven') ||
        lower.contains('help') ||
        lower.contains('police') ||
        lower.contains('hospital')) {
      var places = <Place>[];
      if (loc != null) {
        try {
          final police = await SafetyEngine().nearbyPlaces(loc, 'police');
          final hospitals = await SafetyEngine().nearbyPlaces(loc, 'hospital');
          places = [...police, ...hospitals]
            ..sort((a, b) => meters(loc, a.at).compareTo(meters(loc, b.at)));
        } catch (_) {}
      }

      final attached = places.take(3).toList();
      return AgentChatResponse(
        text: attached.isNotEmpty
            ? 'I found ${attached.length} verified safe havens near your current location. Tap any place below to immediately plot the route and start guided navigation:'
            : 'I can guide you to the nearest verified safe haven immediately (police station, 24/7 hospital, or open transit station). Tap below to view mapped safe locations near you.',
        followUps: ['Nearest police station', 'Call 112 emergency'],
        actionType: 'safe_place',
        attachedPlaces: attached,
      );
    }

    if (lower.contains('score') || lower.contains('explain') || lower.contains('why')) {
      return AgentChatResponse(
        text: 'SafeNav calculates route safety transparently: 30% street lighting, 25% crowd activity, '
            '20% proximity to open hospitals/police, and 25% community reviews. Isolated stretches (~150m) with low activity '
            'are flagged beforehand so you can stay vigilant.',
        followUps: ['Is this area safe at night?', 'Take me somewhere safe now'],
      );
    }

    return AgentChatResponse(
      text: 'I am actively watching your journey. I look out for isolated stretches, monitor your route progress, '
          'and will prompt you if you stop for too long or deviate. You can ask me about lighting, safe havens, or request immediate emergency support.',
      followUps: ['Is this area safe at 11 PM?', 'Take me somewhere safe now', 'Explain my route score'],
    );
  }
}

class Sos {
  static Future<void> message(List<String> contacts, Position? pos) {
    final link = pos == null ? '' : ' My live location: https://maps.google.com/?q=${pos.latitude},${pos.longitude}';
    final body = 'SOS from SafeNav. I may need assistance.$link';
    return launchUrl(Uri.parse('sms:${contacts.join(',')}?body=${Uri.encodeComponent(body)}'));
  }

  static Future<void> call112() => launchUrl(Uri.parse('tel:112'));

  static Future<void> sms(List<String> contacts, String body) =>
      launchUrl(Uri.parse('sms:${contacts.join(',')}?body=${Uri.encodeComponent(body)}'));
}
