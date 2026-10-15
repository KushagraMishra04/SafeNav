import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:ai_safe_route_finder/services/safety_engine.dart';
import 'package:ai_safe_route_finder/services/agent_client.dart';

void main() {
  test('SafePlaceNavRequest initializes correctly', () {
    final place = Place('Central Police Station · 0.4 km', const LatLng(28.6139, 77.2090));
    final req = SafePlaceNavRequest(place, autoStart: true);
    expect(req.place.name, contains('Central Police Station'));
    expect(req.autoStart, isTrue);
  });

  test('AgentChatResponse supports attachedPlaces', () {
    final place = Place('City Hospital', const LatLng(28.6140, 77.2100));
    final res = AgentChatResponse(
      text: 'Verified safe havens found nearby.',
      actionType: 'safe_place',
      attachedPlaces: [place],
    );
    expect(res.attachedPlaces.length, 1);
    expect(res.attachedPlaces.first.name, 'City Hospital');
  });

  test('AgentClient local fallback attaches safe havens for safe place queries', () async {
    final client = AgentClient();
    final res = await client.chat(
      message: 'Take me somewhere safe now',
      currentLocation: const LatLng(28.6139, 77.2090),
    );
    expect(res.actionType, 'safe_place');
    expect(res.attachedPlaces.isNotEmpty, isTrue);
    expect(res.attachedPlaces.first.name.isNotEmpty, isTrue);
  });

  test('candidateRoutes returns multiple distinct routes with valid distances', () async {
    final engine = SafetyEngine();
    // Two points in Delhi ~1.2 km apart
    final a = const LatLng(28.6139, 77.2090);
    final b = const LatLng(28.6239, 77.2190);
    final routes = await engine.candidateRoutes(a, b);
    expect(routes.length, greaterThanOrEqualTo(2));
    for (final r in routes) {
      expect(r.points.length, greaterThanOrEqualTo(2));
      expect(r.distanceM, greaterThan(500));
      expect(r.durationS, greaterThan(100));
    }
  });

  test('SafetyEngine produces non-null factors and confidence > 0 even without mapped lamps', () {
    final engine = SafetyEngine();
    final raw = RawRoute(
      [
        const LatLng(28.6139, 77.2090),
        const LatLng(28.6145, 77.2095),
        const LatLng(28.6150, 77.2100),
      ],
      400.0,
      300.0,
      [
        NavStep(const LatLng(28.6139, 77.2090), 'Start on Connaught Circus Road', 200.0),
        NavStep(const LatLng(28.6145, 77.2095), 'Turn right onto Barakhamba Avenue', 200.0),
      ],
    );

    // Empty OSM data simulating suburban/sparsely mapped area
    final emptyOsm = Osm();
    final scored = engine.score([raw], emptyOsm, [], night: false);

    expect(scored.length, 1);
    final r = scored.first;
    expect(r.score, greaterThanOrEqualTo(40));
    expect(r.score, lessThanOrEqualTo(100));
    expect(r.confidence, greaterThan(0.5));

    // What affects this score factors must never be null
    expect(r.factors.lighting, isNotNull);
    expect(r.factors.lighting!, inInclusiveRange(0.1, 1.0));
    expect(r.factors.activity, isNotNull);
    expect(r.factors.activity!, inInclusiveRange(0.1, 1.0));
    expect(r.factors.help, isNotNull);
    expect(r.factors.help!, inInclusiveRange(0.1, 1.0));
    expect(r.factors.community, isNotNull);
    expect(r.factors.community!, inInclusiveRange(0.1, 1.0));
  });
}
