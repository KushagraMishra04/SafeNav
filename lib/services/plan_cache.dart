import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'safety_engine.dart';

class CachedPlan {
  final List<RawRoute> raws;
  final Osm osm;
  CachedPlan(this.raws, this.osm);
}

/// Keeps the last few planned trips on the phone, so a demo (or a walk) still works when
/// the free map servers are slow, down, or there is no internet.
class PlanCache {
  static const _key = 'plan_cache_v1';
  static const _max = 5;

  List<double> _ll(LatLng p) =>
      [double.parse(p.latitude.toStringAsFixed(5)), double.parse(p.longitude.toStringAsFixed(5))];
  List<List<double>> _pts(Iterable<LatLng> l) => [for (final p in l) _ll(p)];
  LatLng _pt(dynamic e) => LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble());
  List<LatLng> _unpts(dynamic j) => [for (final e in j as List) _pt(e)];

  Future<void> save(LatLng from, LatLng to, String name, List<RawRoute> raws, Osm osm) async {
    try {
      // keep only map features near the routes, so the saved data stays small
      final sparse = <LatLng>[
        for (final r in raws)
          for (var i = 0; i < r.points.length; i += 8) r.points[i]
      ];
      List<List<double>> near(List<LatLng> l) => _pts(l.where((p) => within(p, sparse, 250)));
      final entry = jsonEncode({
        't': DateTime.now().millisecondsSinceEpoch,
        'name': name,
        'from': _ll(from),
        'to': _ll(to),
        'routes': [
          for (final r in raws)
            {
              'p': _pts(r.points),
              'd': r.distanceM,
              't': r.durationS,
              's': [for (final s in r.steps) {'a': _ll(s.at), 'x': s.text, 'd': s.distanceM}],
            }
        ],
        'osm': {
          'lamps': near(osm.lamps),
          'lit': near(osm.lit),
          'unlit': near(osm.unlit),
          'act': near(osm.activity),
          'help': _pts(osm.help),
        },
      });
      final sp = await SharedPreferences.getInstance();
      final keep = <String>[];
      for (final s in sp.getStringList(_key) ?? const <String>[]) {
        try {
          final j = jsonDecode(s) as Map<String, dynamic>;
          if (meters(_pt(j['from']), from) < 150 && meters(_pt(j['to']), to) < 150) continue; // replaced
          keep.add(s);
        } catch (_) {}
      }
      await sp.setStringList(_key, [entry, ...keep].take(_max).toList());
    } catch (_) {}
  }

  /// A saved plan for roughly the same start and destination (within 150 m), if any.
  Future<CachedPlan?> load(LatLng from, LatLng to) async {
    final sp = await SharedPreferences.getInstance();
    for (final s in sp.getStringList(_key) ?? const <String>[]) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        if (meters(_pt(j['from']), from) > 150 || meters(_pt(j['to']), to) > 150) continue;
        final raws = [
          for (final r in j['routes'] as List)
            RawRoute(_unpts(r['p']), (r['d'] as num).toDouble(), (r['t'] as num).toDouble(), [
              for (final st in r['s'] as List)
                NavStep(_pt(st['a']), st['x'] as String, (st['d'] as num).toDouble())
            ])
        ];
        final o = j['osm'] as Map<String, dynamic>;
        final osm = Osm()
          ..lamps.addAll(_unpts(o['lamps']))
          ..lit.addAll(_unpts(o['lit']))
          ..unlit.addAll(_unpts(o['unlit']))
          ..activity.addAll(_unpts(o['act']))
          ..help.addAll(_unpts(o['help']));
        return CachedPlan(raws, osm);
      } catch (_) {}
    }
    return null;
  }

  /// Recently planned destinations, shown as one-tap chips (they work offline too).
  Future<List<Place>> recent() async {
    final sp = await SharedPreferences.getInstance();
    final out = <Place>[];
    for (final s in sp.getStringList(_key) ?? const <String>[]) {
      try {
        final j = jsonDecode(s) as Map<String, dynamic>;
        out.add(Place(j['name'] as String, _pt(j['to'])));
      } catch (_) {}
    }
    return out;
  }
}
