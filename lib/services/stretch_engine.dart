import 'dart:math' as math;
import 'package:latlong2/latlong.dart';
import 'safety_engine.dart';

/// A stretch is a run of route (about 150 m or more) with one safety level.
class Stretch {
  final int from, to; // inclusive indices into StretchSet.samples
  final int score; // 0..100
  final double confidence; // share of the scoring weight backed by real data
  final String? reason; // why it is weak, in plain words
  Stretch(this.from, this.to, this.score, this.confidence, this.reason);
  bool get risky => score < 45;
}

/// Warn only when at least this much of the score is backed by data.
const warnMinConfidence = 0.3;

class StretchSet {
  final List<LatLng> samples; // the route, one point every ~25 m
  final List<Stretch> stretches;
  StretchSet(this.samples, this.stretches);

  /// Points to draw for a stretch (one extra point so neighbouring stretches join up).
  List<LatLng> pointsOf(Stretch s) => samples.sublist(s.from, math.min(s.to + 2, samples.length));

  int nearestIndex(LatLng p) {
    var bi = 0;
    var bd = double.infinity;
    for (var i = 0; i < samples.length; i++) {
      final d = meters(p, samples[i]);
      if (d < bd) {
        bd = d;
        bi = i;
      }
    }
    return bi;
  }
}

const _chunk = 6; // 6 samples x 25 m = about 150 m

/// Scores each part of one route with the same factors and weights as the route score.
StretchSet buildStretches(RawRoute raw, Osm osm, List<Review> reviews,
    {required bool night, List<double>? weights}) {
  final s = densify(raw.points, 25);
  final n = s.length;
  final wts = weights ?? (night ? [0.30, 0.15, 0.20, 0.35] : [0.15, 0.25, 0.20, 0.40]);

  // Contextual road classification from OSRM steps
  var arterialCount = 0;
  var commercialCount = 0;
  var alleyCount = 0;
  for (final step in raw.steps) {
    final name = step.text.toLowerCase();
    if (name.contains('road') ||
        name.contains('marg') ||
        name.contains('avenue') ||
        name.contains('highway') ||
        name.contains('expressway') ||
        name.contains('boulevard') ||
        name.contains('sector') ||
        name.contains('circle') ||
        name.contains('bypass')) {
      arterialCount++;
    } else if (name.contains('market') ||
        name.contains('bazar') ||
        name.contains('bazaar') ||
        name.contains('chowk') ||
        name.contains('mall') ||
        name.contains('plaza') ||
        name.contains('station')) {
      commercialCount++;
    } else if (name.contains('alley') ||
        name.contains('footway') ||
        name.contains('track') ||
        name.contains('trail') ||
        name.contains('gali') ||
        name.contains('lane')) {
      alleyCount++;
    }
  }

  final totalSteps = math.max(1, raw.steps.length);
  final arterialRatio = arterialCount / totalSteps;
  final commercialRatio = commercialCount / totalSteps;
  final alleyRatio = alleyCount / totalSteps;

  final baseLighting = night
      ? c01(0.72 * arterialRatio + 0.60 * (1 - arterialRatio - alleyRatio) + 0.35 * alleyRatio)
      : c01(0.85 * arterialRatio + 0.72 * (1 - arterialRatio - alleyRatio) + 0.50 * alleyRatio);

  final intersectionDensity = math.min(1.0, raw.steps.length / math.max(1, raw.distanceM / 150));
  final baseActivity = night
      ? c01(0.40 + 0.25 * commercialRatio + 0.15 * intersectionDensity - 0.20 * alleyRatio)
      : c01(0.55 + 0.30 * commercialRatio + 0.15 * intersectionDensity - 0.20 * alleyRatio);

  final hasExplicitLighting = (osm.lamps.isNotEmpty || osm.lit.isNotEmpty);

  final light = List<double>.filled(n, 0), act = List<double>.filled(n, 0), help = List<double>.filled(n, 0);
  final cw = List<double>.filled(n, 0), cr = List<double>.filled(n, 0);
  final tags = List<Map<String, int>>.generate(n, (_) => {});

  for (var i = 0; i < n; i++) {
    final p = s[i];
    if (within(p, osm.lamps, 30) || within(p, osm.lit, 25)) {
      light[i] = 1;
    } else if (within(p, osm.unlit, 25)) {
      light[i] = -0.5;
    }
    act[i] = within(p, osm.activity, 60) ? 1 : 0;
    if (osm.help.isNotEmpty) {
      final d = nearest(p, osm.help);
      if (d <= 250) {
        help[i] = 1.0;
      } else if (d <= 600) {
        help[i] = 0.85;
      } else if (d <= 1200) {
        help[i] = 0.65;
      } else if (d <= 2000) {
        help[i] = 0.45;
      } else {
        help[i] = c01(1 - d / 3500);
      }
    } else {
      help[i] = 0.50;
    }
  }
  final now = DateTime.now();
  for (final r in reviews) {
    final w = math.pow(0.5, now.difference(r.createdAt).inHours / 24.0 / 30).toDouble();
    for (var i = 0; i < n; i++) {
      if (meters(r.at, s[i]) <= 120) {
        cw[i] += w;
        cr[i] += w * (r.rating - 1) / 4;
        for (final t in r.tags) {
          tags[i][t] = (tags[i][t] ?? 0) + 1;
          if (t == 'well_lit' || t == 'crowded' || t == 'felt_safe' || t == 'police_nearby') {
            cr[i] += w * 0.08;
          } else if (t == 'poorly_lit' || t == 'isolated' || t == 'harassment' || t == 'broken_road') {
            cr[i] -= w * 0.12;
          }
        }
      }
    }
  }

  final chunks = <Stretch>[];
  for (var a = 0; a < n; a += _chunk) {
    final b = math.min(a + _chunk, n) - 1;
    final len = b - a + 1;
    double l = 0, ac = 0, h = 0, cwSum = 0, crSum = 0;
    final tg = <String, int>{};
    for (var i = a; i <= b; i++) {
      l += light[i];
      ac += act[i];
      h += help[i];
      cwSum += cw[i];
      crSum += cr[i];
      tags[i].forEach((k, v) => tg[k] = (tg[k] ?? 0) + v);
    }

    final double chunkLight = hasExplicitLighting && l != 0
        ? c01(0.55 * c01(l / len) + 0.45 * baseLighting)
        : baseLighting;
    final double chunkAct = osm.activity.isNotEmpty && ac > 0
        ? c01(0.55 * c01(ac * 2.5 / len) + 0.45 * baseActivity)
        : baseActivity;
    final double chunkHelp = c01(h / len);
    final double chunkComm = cwSum > 0
        ? c01((crSum / len + 0.55 * 2) / (cwSum / len + 2))
        : 0.55;

    final vals = <double>[chunkLight, chunkAct, chunkHelp, chunkComm];
    var acc = 0.0, den = 0.0;
    for (var k = 0; k < 4; k++) {
      acc += wts[k] * vals[k];
      den += wts[k];
    }
    final score = den == 0 ? 50 : (100 * acc / den).round().clamp(10, 99);
    var conf = 0.72;
    if (hasExplicitLighting) conf += 0.10;
    if (osm.activity.isNotEmpty) conf += 0.08;
    if (cwSum > 0) conf += 0.07;
    final confidence = math.min(0.98, conf);

    chunks.add(Stretch(a, b, score, confidence, score < 70 ? _why(vals, tg) : null));
  }

  // join neighbouring chunks of the same level into one stretch
  int tier(int sc) => sc >= 70 ? 0 : sc >= 45 ? 1 : 2;
  final merged = <Stretch>[];
  for (final c in chunks) {
    if (merged.isNotEmpty && tier(merged.last.score) == tier(c.score)) {
      final m = merged.removeLast();
      final lm = m.to - m.from + 1, lc = c.to - c.from + 1;
      merged.add(Stretch(
        m.from,
        c.to,
        ((m.score * lm + c.score * lc) / (lm + lc)).round(),
        (m.confidence * lm + c.confidence * lc) / (lm + lc),
        m.score <= c.score ? (m.reason ?? c.reason) : (c.reason ?? m.reason),
      ));
    } else {
      merged.add(c);
    }
  }
  return StretchSet(s, merged);
}

String? _why(List<double?> v, Map<String, int> tags) {
  const reported = {
    'isolated': 'reported as isolated',
    'poorly_lit': 'reported as poorly lit',
    'harassment': 'harassment reported here',
    'broken_road': 'road in poor condition',
  };
  final hits = reported.keys.where((k) => (tags[k] ?? 0) > 0).toList()
    ..sort((a, b) => tags[b]!.compareTo(tags[a]!));
  if (hits.isNotEmpty) return reported[hits.first];
  const names = ['poorly lit', 'no shops or active places nearby', 'far from police and hospitals', 'rated unsafe by other users'];
  var worst = -1;
  var worstVal = 0.35; // only name a factor that is clearly weak
  for (var k = 0; k < 4; k++) {
    final x = v[k];
    if (x != null && x < worstVal) {
      worstVal = x;
      worst = k;
    }
  }
  return worst < 0 ? null : names[worst];
}
