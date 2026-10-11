import 'dart:convert';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'safety_engine.dart';

const reviewTags = [
  'well_lit', 'poorly_lit', 'crowded', 'isolated', 'felt_safe',
  'harassment', 'police_nearby', 'broken_road',
];

/// Reviews go to Firestore when it is set up. If Firebase is missing or offline, they are
/// saved on this device instead, so the demo keeps working. Writes return true when the
/// review reached the cloud, false when it was saved on the device only.
class ReviewService {
  static const _localKey = 'local_reviews';
  static const _wait = Duration(seconds: 6);

  // Lazy on purpose: if Firebase isn't initialised, only the calls fail (and are caught).
  CollectionReference<Map<String, dynamic>> get _col =>
      FirebaseFirestore.instance.collection('reviews');

  Future<User> _user() async {
    final auth = FirebaseAuth.instance;
    return auth.currentUser ?? (await auth.signInAnonymously()).user!;
  }

  (double, double, double, double) _bbox(List<LatLng> pts) {
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final p in pts) {
      s = math.min(s, p.latitude);
      n = math.max(n, p.latitude);
      w = math.min(w, p.longitude);
      e = math.max(e, p.longitude);
    }
    return (s, w, n, e);
  }

  Future<List<Review>> nearRoute(List<LatLng> pts) async {
    final (s, w, n, e) = _bbox(pts);
    const pad = 0.001;
    final out = <Review>[];
    try {
      // Firestore allows one range field: filter latitude there, longitude on the device.
      final snap = await _col
          .where('lat', isGreaterThanOrEqualTo: s - pad)
          .where('lat', isLessThanOrEqualTo: n + pad)
          .limit(500)
          .get()
          .timeout(_wait);
      out.addAll(snap.docs
          .map((d) => d.data())
          .where((m) => (m['lng'] as num) >= w - pad && (m['lng'] as num) <= e + pad)
          .map(_fromMap));
    } catch (_) {}
    for (final r in await _local()) {
      if (r.at.latitude >= s - pad && r.at.latitude <= n + pad &&
          r.at.longitude >= w - pad && r.at.longitude <= e + pad) {
        out.add(r);
      }
    }
    return out;
  }

  Review _fromMap(Map<String, dynamic> m) {
    final ts = m['createdAt'];
    return Review(
      LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
      (m['rating'] as num).toInt(),
      List<String>.from(m['tags'] ?? const []),
      (m['text'] ?? '') as String,
      ts is Timestamp ? ts.toDate() : DateTime.now(),
    );
  }

  String _clip(String text) {
    final t = text.trim();
    return t.length > 280 ? t.substring(0, 280) : t;
  }

  Map<String, dynamic> _doc(User u, LatLng at, int rating, List<String> tags, String text, String tripId, String kind) => {
        'uid': u.uid,
        'lat': at.latitude,
        'lng': at.longitude,
        'rating': rating,
        'tags': tags.take(8).toList(),
        'text': _clip(text),
        'tripId': tripId,
        'kind': kind, // 'spot' or 'trip'
        'createdAt': FieldValue.serverTimestamp(),
      };

  Future<bool> addAt(LatLng at, int rating, List<String> tags, String text, String tripId) async {
    try {
      final u = await _user().timeout(_wait);
      await _col.add(_doc(u, at, rating, tags, text, tripId, 'spot')).timeout(_wait);
      return true;
    } catch (_) {
      await _saveLocal([Review(at, rating, tags.take(8).toList(), _clip(text), DateTime.now())]);
      return false;
    }
  }

  /// Post-trip feedback: up to 6 samples along the route, tagged with the trip id
  /// so one trip can later be down-weighted as a single voice.
  Future<bool> addForTrip({
    required List<LatLng> points,
    required int rating,
    required List<String> tags,
    required String text,
    required String tripId,
  }) async {
    final s = densify(points, 300);
    final step = math.max(1, s.length ~/ 6);
    final spots = [for (var i = 0; i < s.length; i += step) s[i]];
    try {
      final u = await _user().timeout(_wait);
      final batch = FirebaseFirestore.instance.batch();
      for (final p in spots) {
        batch.set(_col.doc(), _doc(u, p, rating, tags, text, tripId, 'trip'));
      }
      await batch.commit().timeout(_wait);
      return true;
    } catch (_) {
      await _saveLocal([for (final p in spots) Review(p, rating, tags.take(8).toList(), _clip(text), DateTime.now())]);
      return false;
    }
  }

  // ---------- on-device fallback ----------
  Future<List<Review>> _local() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getStringList(_localKey) ?? []).map((s) {
      final m = jsonDecode(s) as Map<String, dynamic>;
      return Review(
        LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
        (m['rating'] as num).toInt(),
        List<String>.from(m['tags']),
        m['text'] as String,
        DateTime.fromMillisecondsSinceEpoch((m['t'] as num).toInt()),
      );
    }).toList();
  }

  Future<void> _saveLocal(List<Review> add) async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_localKey) ?? [];
    for (final r in add) {
      list.add(jsonEncode({
        'lat': r.at.latitude, 'lng': r.at.longitude, 'rating': r.rating,
        'tags': r.tags, 'text': r.text, 't': r.createdAt.millisecondsSinceEpoch,
      }));
    }
    await sp.setStringList(_localKey, list);
  }
}
