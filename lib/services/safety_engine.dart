import 'dart:convert';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

// Nominatim / Overpass / OSRM policies require an identifying User-Agent.
const _headers = {'User-Agent': 'SafeNav/1.0 (college prototype; your-email@example.com)'};

// ---------- geometry helpers (fast equirectangular approximation) ----------
double meters(LatLng a, LatLng b) {
  final dy = (a.latitude - b.latitude) * 110540.0;
  final dx = (a.longitude - b.longitude) * 111320.0 * math.cos(a.latitude * math.pi / 180);
  return math.sqrt(dx * dx + dy * dy);
}

bool within(LatLng p, List<LatLng> pts, double r) {
  for (final q in pts) {
    if (meters(p, q) <= r) return true;
  }
  return false;
}

double nearest(LatLng p, List<LatLng> pts) {
  var best = double.infinity;
  for (final q in pts) {
    final d = meters(p, q);
    if (d < best) best = d;
  }
  return best;
}

double c01(num x) => x < 0 ? 0.0 : (x > 1 ? 1.0 : x.toDouble());

List<LatLng> densify(List<LatLng> pts, double stepM) {
  if (pts.length < 2) return List.of(pts);
  final out = <LatLng>[pts.first];
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final n = (meters(a, b) / stepM).floor();
    for (var j = 1; j <= n; j++) {
      final t = j / (n + 1);
      out.add(LatLng(a.latitude + (b.latitude - a.latitude) * t,
          a.longitude + (b.longitude - a.longitude) * t));
    }
    out.add(b);
  }
  return out;
}

// ---------- models ----------
class Place {
  final String name;
  final LatLng at;
  Place(this.name, this.at);
}

class Review {
  final LatLng at;
  final int rating; // 1..5
  final List<String> tags;
  final String text;
  final DateTime createdAt;
  Review(this.at, this.rating, this.tags, this.text, this.createdAt);
}

/// One instruction, e.g. "Turn left onto Main Road", located where the turn happens.
class NavStep {
  final LatLng at;
  final String text;
  final double distanceM;
  NavStep(this.at, this.text, this.distanceM);
}

String _say(String type, String? mod, String? name) {
  final road = (name == null || name.isEmpty) ? 'the path' : name;
  switch (type) {
    case 'depart':
      return 'Start on $road';
    case 'arrive':
      return 'You have arrived';
    case 'roundabout':
    case 'rotary':
    case 'roundabout turn':
      return 'Take the roundabout toward $road';
    case 'continue':
    case 'new name':
      return 'Continue on $road';
  }
  switch (mod) {
    case 'left':
    case 'right':
      return 'Turn $mod onto $road';
    case 'sharp left':
    case 'sharp right':
      return 'Make a $mod onto $road';
    case 'slight left':
      return 'Bear left onto $road';
    case 'slight right':
      return 'Bear right onto $road';
    case 'uturn':
      return 'Make a U-turn';
    default:
      return 'Continue on $road';
  }
}

class RawRoute {
  final List<LatLng> points;
  final double distanceM, durationS;
  final List<NavStep> steps;
  RawRoute(this.points, this.distanceM, this.durationS, [this.steps = const []]);
}

/// Each factor is 0..1, or null when there is no data for it.
class Factors {
  final double? lighting, activity, help, community;
  Factors(this.lighting, this.activity, this.help, this.community);
  List<double?> get list => [lighting, activity, help, community];
}

class ScoredRoute {
  final String id;
  final RawRoute raw;
  final Factors factors;
  final int score; // 0..100
  final double confidence; // share of the scoring weight backed by real data
  final List<LatLng> havens;
  final List<String> notes;
  ScoredRoute(this.id, this.raw, this.factors, this.score, this.confidence, this.havens, this.notes);
}

class Osm {
  final lamps = <LatLng>[], lit = <LatLng>[], unlit = <LatLng>[], activity = <LatLng>[], help = <LatLng>[];
  bool failed = false;
}

// ---------- engine ----------
class SafetyEngine {
  /// Set when a geocoder failed (network or server problem), so the UI can say so
  /// instead of pretending nothing was found.
  String? lastError;

  /// Photon (typo-tolerant, biased toward the user) first, Nominatim as backup.
  Future<List<Place>> search(String q, {LatLng? near}) async {
    lastError = null;
    try {
      final r = await http.get(
          Uri.https('photon.komoot.io', '/api/', {
            'q': q,
            'limit': '8',
            if (near != null) 'lat': '${near.latitude}',
            if (near != null) 'lon': '${near.longitude}',
          }),
          headers: _headers).timeout(const Duration(seconds: 12));
      if (r.statusCode == 200) {
        final out = <Place>[];
        for (final f in jsonDecode(r.body)['features'] as List) {
          final p = f['properties'] as Map;
          if (p['countrycode'] != null && p['countrycode'] != 'IN') continue;
          final c = f['geometry']['coordinates'] as List;
          final label = [p['name'], p['street'], p['district'] ?? p['city'], p['state']]
              .where((x) => x != null && '$x'.isNotEmpty)
              .join(', ');
          out.add(Place(label.isEmpty ? q : label,
              LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())));
        }
        if (out.isNotEmpty) return out.take(6).toList();
      } else {
        lastError = 'Photon ${r.statusCode}';
      }
    } catch (e) {
      lastError = 'Photon: $e';
    }
    try {
      final r = await http.get(
          Uri.https('nominatim.openstreetmap.org', '/search', {
            'q': q,
            'format': 'jsonv2',
            'limit': '6',
            'countrycodes': 'in',
            if (near != null)
              'viewbox': '${near.longitude - 0.5},${near.latitude + 0.5},${near.longitude + 0.5},${near.latitude - 0.5}',
          }),
          headers: _headers).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) {
        lastError = 'Nominatim ${r.statusCode}';
        return [];
      }
      lastError = null; // the service answered, there was just nothing to find
      return (jsonDecode(r.body) as List)
          .map((e) => Place((e['display_name'] as String).split(',').take(3).join(','),
              LatLng(double.parse(e['lat']), double.parse(e['lon']))))
          .toList();
    } catch (e) {
      lastError = 'Nominatim: $e';
      return [];
    }
  }

  /// Nearest police stations, hospitals or rail/metro stations within 5 km.
  Future<List<Place>> nearbyPlaces(LatLng me, String kind) async {
    final f = kind == 'police'
        ? '["amenity"="police"]'
        : kind == 'hospital'
            ? '["amenity"~"^(hospital|clinic)\$"]'
            : '["railway"~"^(station|subway_entrance)\$"]';
    final label = kind == 'police' ? 'Police station' : kind == 'hospital' ? 'Hospital' : 'Station';
    final around = '(around:5000,${me.latitude},${me.longitude})';
    final q = '[out:json][timeout:20];(node$f$around;way$f$around;);out tags center 40;';
    try {
      final r = await http
          .post(Uri.parse('https://overpass-api.de/api/interpreter'), headers: _headers, body: {'data': q})
          .timeout(const Duration(seconds: 25));
      if (r.statusCode != 200) return [];
      final out = <Place>[];
      for (final el in jsonDecode(r.body)['elements'] as List) {
        final t = (el['tags'] ?? {}) as Map;
        final c = el['type'] == 'node' ? el : el['center'];
        if (c == null) continue;
        final at = LatLng((c['lat'] as num).toDouble(), (c['lon'] as num).toDouble());
        out.add(Place('${t['name'] ?? label} · ${(meters(me, at) / 1000).toStringAsFixed(1)} km', at));
      }
      out.sort((a, b) => meters(me, a.at).compareTo(meters(me, b.at)));
      return out.take(5).toList();
    } catch (_) {
      return [];
    }
  }

  Future<List<RawRoute>> _osrm(List<LatLng> stops, {String alternatives = 'false'}) async {
    final coords = stops.map((p) => '${p.longitude},${p.latitude}').join(';');
    // FOSSGIS demo server has a real walking profile. Its path quirk: always "driving".
    final uri = Uri.parse('https://routing.openstreetmap.de/routed-foot/route/v1/driving/$coords'
        '?overview=full&geometries=geojson&steps=true&alternatives=$alternatives');
    final r = await http.get(uri, headers: _headers);
    if (r.statusCode != 200) return [];
    final j = jsonDecode(r.body);
    if (j['code'] != 'Ok') return [];
    return (j['routes'] as List).map((x) {
      final pts = (x['geometry']['coordinates'] as List)
          .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
          .toList();
      final steps = <NavStep>[];
      final legs = (x['legs'] as List?) ?? const [];
      for (var li = 0; li < legs.length; li++) {
        for (final st in (legs[li]['steps'] as List?) ?? const []) {
          final m = st['maneuver'] as Map;
          final type = (m['type'] ?? '') as String;
          // detour routes have several legs: keep only the first "depart" and the last "arrive"
          if (type == 'arrive' && li < legs.length - 1) continue;
          if (type == 'depart' && li > 0) continue;
          final loc = m['location'] as List;
          steps.add(NavStep(
              LatLng((loc[1] as num).toDouble(), (loc[0] as num).toDouble()),
              _say(type, m['modifier'] as String?, st['name'] as String?),
              (st['distance'] as num).toDouble()));
        }
      }
      return RawRoute(pts, (x['distance'] as num).toDouble(), (x['duration'] as num).toDouble(), steps);
    }).toList();
  }

  /// OSRM alternatives + two sideways detours, so the scorer has real choices.
  Future<List<RawRoute>> candidateRoutes(LatLng a, LatLng b, {bool quick = false}) async {
    // quick: one direct route and no detour requests, for emergencies where speed matters
    if (quick) return (await _osrm([a, b])).take(1).toList();
    final out = await _osrm([a, b], alternatives: '3');
    final mid = LatLng((a.latitude + b.latitude) / 2, (a.longitude + b.longitude) / 2);
    final dx = b.longitude - a.longitude, dy = b.latitude - a.latitude;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 0) {
      final off = math.min(0.004, len * 0.3); // roughly 400 m at most
      for (final s in [1.0, -1.0]) {
        await Future.delayed(const Duration(milliseconds: 1100)); // demo server: max 1 req/s
        final via = LatLng(mid.latitude + s * off * dx / len, mid.longitude - s * off * dy / len);
        out.addAll(await _osrm([a, via, b]));
      }
    }
    final uniq = <RawRoute>[];
    for (final r in out) {
      final dup = uniq.any((u) => (u.distanceM - r.distanceM).abs() < 40 && (u.durationS - r.durationS).abs() < 30);
      if (!dup) uniq.add(r);
    }
    return uniq.take(5).toList();
  }

  /// Real map data: street lamps, lit/unlit roads, active places, police/hospitals.
  Future<Osm> osm(List<LatLng> all) async {
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final p in all) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    String bb(double d) => '${s - d},${w - d},${n + d},${e + d}';
    const pad = 0.002, big = 0.012; // ~200 m for street features, ~1.3 km for help points
    final q = '''[out:json][timeout:25];
(
  node["highway"="street_lamp"](${bb(pad)});
  way["highway"]["lit"~"^(yes|24/7|automatic)\$"](${bb(pad)});
  way["highway"]["lit"="no"](${bb(pad)});
  node["shop"](${bb(pad)});
  node["amenity"~"^(restaurant|cafe|fast_food|pharmacy|atm|bank|fuel|bus_station|marketplace)\$"](${bb(pad)});
  node["amenity"~"^(police|hospital|clinic)\$"](${bb(big)});
);
out tags geom;''';
    final o = Osm();
    try {
      final r = await http.post(Uri.parse('https://overpass-api.de/api/interpreter'),
          headers: _headers, body: {'data': q});
      if (r.statusCode != 200) return o..failed = true;
      for (final el in jsonDecode(r.body)['elements'] as List) {
        final t = (el['tags'] ?? {}) as Map;
        if (el['type'] == 'node') {
          final p = LatLng((el['lat'] as num).toDouble(), (el['lon'] as num).toDouble());
          final am = t['amenity'];
          if (t['highway'] == 'street_lamp') {
            o.lamps.add(p);
          } else if (am == 'police' || am == 'hospital' || am == 'clinic') {
            o.help.add(p);
          } else {
            o.activity.add(p);
          }
        } else if (el['type'] == 'way' && el['geometry'] != null) {
          final g = (el['geometry'] as List)
              .map((c) => LatLng((c['lat'] as num).toDouble(), (c['lon'] as num).toDouble()))
              .toList();
          (t['lit'] == 'no' ? o.unlit : o.lit).addAll(densify(g, 20));
        }
      }
    } catch (_) {
      o.failed = true;
    }
    return o;
  }

  /// Transparent weighted score. Factors with no data are left out and the
  /// remaining weights are re-normalised, so missing data never fakes a score.
  List<ScoredRoute> score(List<RawRoute> raws, Osm osm, List<Review> reviews,
      {required bool night, List<double>? weights}) {
    final lightingKnown = !osm.failed && (osm.lamps.length + osm.lit.length) >= 8;
    // [lighting, activity, help, community]
    final wts = weights ?? (night ? [0.30, 0.15, 0.20, 0.35] : [0.15, 0.25, 0.20, 0.40]);
    return [
      for (var i = 0; i < raws.length; i++) _scoreOne('r$i', raws[i], osm, reviews, lightingKnown, wts)
    ];
  }

  ScoredRoute _scoreOne(String id, RawRoute raw, Osm osm, List<Review> reviews, bool lightingKnown, List<double> wts) {
    final pts = densify(raw.points, 25);
    var lit = 0, unlit = 0, act = 0;
    var help = 0.0;
    for (final p in pts) {
      if (within(p, osm.lamps, 30) || within(p, osm.lit, 25)) {
        lit++;
      } else if (within(p, osm.unlit, 25)) {
        unlit++;
      }
      if (within(p, osm.activity, 60)) act++;
      if (osm.help.isNotEmpty) help += c01(1 - nearest(p, osm.help) / 1500);
    }
    final n = pts.length;

    // community: time-decayed (30-day half-life), pulled toward neutral when few reviews
    double wSum = 0, rSum = 0;
    final tagCount = <String, int>{};
    var reviewCount = 0;
    for (final r in reviews) {
      if (nearest(r.at, pts) > 80) continue;
      reviewCount++;
      final ageDays = DateTime.now().difference(r.createdAt).inHours / 24.0;
      final w = math.pow(0.5, ageDays / 30).toDouble();
      wSum += w;
      rSum += w * (r.rating - 1) / 4;
      for (final t in r.tags) {
        tagCount[t] = (tagCount[t] ?? 0) + 1;
      }
    }

    final factors = Factors(
      lightingKnown ? c01((lit - 0.5 * unlit) / n) : null,
      osm.failed ? null : act / n,
      osm.failed ? null : help / n,
      wSum > 0 ? (rSum + 0.5 * 2) / (wSum + 2) : null,
    );

    var acc = 0.0, den = 0.0;
    for (var k = 0; k < 4; k++) {
      final v = factors.list[k];
      if (v != null) {
        acc += wts[k] * v;
        den += wts[k];
      }
    }
    final score = den == 0 ? 0 : (100 * acc / den).round();
    final totalW = wts.fold<double>(0, (a, b) => a + b);

    final havens = osm.help.where((h) => nearest(h, pts) <= 200).toList();
    final notes = <String>[];
    if (osm.failed) notes.add('Map data service was unreachable, so only reviews were used.');
    if (!osm.failed && !lightingKnown) notes.add('Street-light data is sparse here, so lighting was not scored.');
    if (reviewCount > 0) {
      final top = tagCount.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
      notes.add('$reviewCount community review${reviewCount == 1 ? '' : 's'} along this route'
          '${top.isEmpty ? '' : ' (most mentioned: ${top.first.key.replaceAll('_', ' ')})'}.');
    }
    if (!osm.failed && havens.isEmpty) notes.add('No police station or hospital within 200 m of this route.');

    return ScoredRoute(id, raw, factors, score, totalW == 0 ? 0 : den / totalW, havens, notes);
  }

  /// Highest score among routes within the allowed detour (1.4 = up to 40% longer).
  ScoredRoute pickBest(List<ScoredRoute> rs, {double maxDetour = 1.4}) {
    final fastest = rs.map((r) => r.raw.durationS).reduce(math.min);
    final ok = rs.where((r) => r.raw.durationS <= fastest * maxDetour).toList();
    ok.sort((a, b) => b.score != a.score
        ? b.score.compareTo(a.score)
        : a.raw.durationS.compareTo(b.raw.durationS));
    return ok.first;
  }
}
