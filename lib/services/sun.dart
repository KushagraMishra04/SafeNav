import 'dart:math' as math;

typedef SunTimes = ({DateTime rise, DateTime set});

/// Sunrise and sunset today (local time) from latitude and longitude, using the standard
/// sunrise equation. Good to a few minutes. Returns null near the poles.
SunTimes? sunTimes(DateTime now, double lat, double lng) {
  const rad = math.pi / 180;
  final day = DateTime(now.year, now.month, now.day);
  final jd = now.toUtc().millisecondsSinceEpoch / 86400000.0 + 2440587.5;
  final n0 = (jd - 2451545.0 + 0.0008).ceilToDouble();
  DateTime? rise, set;
  for (final k in [-1.0, 0.0, 1.0]) {
    final n = n0 + k;
    final jStar = n - lng / 360; // east longitudes reach solar noon earlier
    final m = (357.5291 + 0.98560028 * jStar) % 360;
    final c = 1.9148 * math.sin(m * rad) + 0.02 * math.sin(2 * m * rad) + 0.0003 * math.sin(3 * m * rad);
    final lambda = (m + c + 180 + 102.9372) % 360;
    final transit = 2451545.0 + jStar + 0.0053 * math.sin(m * rad) - 0.0069 * math.sin(2 * lambda * rad);
    final sinD = math.sin(lambda * rad) * math.sin(23.4397 * rad);
    final cosD = math.cos(math.asin(sinD));
    final cosW = (math.sin(-0.833 * rad) - math.sin(lat * rad) * sinD) / (math.cos(lat * rad) * cosD);
    if (cosW < -1 || cosW > 1) return null;
    final w = math.acos(cosW) / rad;
    DateTime at(double j) =>
        DateTime.fromMillisecondsSinceEpoch(((j - 2440587.5) * 86400000).round(), isUtc: true).toLocal();
    final r = at(transit - w / 360), s = at(transit + w / 360);
    bool today(DateTime d) => d.year == day.year && d.month == day.month && d.day == day.day;
    if (today(r)) rise = r;
    if (today(s)) set = s;
  }
  if (rise == null || set == null) return null;
  return (rise: rise, set: set);
}

/// True between sunset and sunrise. Falls back to 7 pm to 6 am if the sun times are unknown.
bool isNightAt(double lat, double lng, {DateTime? now}) {
  final t0 = now ?? DateTime.now();
  final t = sunTimes(t0, lat, lng);
  if (t == null) return t0.hour >= 19 || t0.hour < 6;
  return t0.isBefore(t.rise) || t0.isAfter(t.set);
}
