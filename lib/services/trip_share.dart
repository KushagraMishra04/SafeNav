import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:latlong2/latlong.dart';

/// Live trip sharing. The phone writes its latest position to one Firestore document;
/// your contacts open a link to web_tracker/track.html, which watches that document.
class TripShare {
  static const _defaultTrackUrl = 'https://safenav-4b482.web.app/track.html';
  static const trackUrl = String.fromEnvironment('TRACK_URL', defaultValue: _defaultTrackUrl);
  static const _wait = Duration(seconds: 8);

  String? id;
  String? shareToken;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);

  bool get active => id != null;
  String? get link => (id == null || trackUrl.isEmpty)
      ? null
      : '$trackUrl?t=$id&token=${shareToken ?? ''}';

  static String _newId() {
    final r = math.Random.secure();
    const c = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(24, (_) => c[r.nextInt(c.length)]).join(); // unguessable
  }

  DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('trips').doc(id);

  /// True when the live link works. False when Firebase or TRACK_URL is not set up.
  Future<bool> start({
    required LatLng at,
    required String dest,
    required int etaMin,
    DateTime? guardianEnd,
  }) async {
    try {
      final auth = FirebaseAuth.instance;
      final u = auth.currentUser ?? (await auth.signInAnonymously()).user!;
      final newId = _newId();
      final newToken = _newId();
      await FirebaseFirestore.instance.collection('trips').doc(newId).set({
        'uid': u.uid,
        'shareToken': newToken,
        'lat': at.latitude,
        'lng': at.longitude,
        'dest': dest,
        'etaMin': etaMin,
        'status': 'walking',
        'guardianEnd': guardianEnd?.millisecondsSinceEpoch,
        'startedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        // TTL policy: old trips delete themselves after 12 hours for privacy
        'expiresAt': Timestamp.fromDate(DateTime.now().add(const Duration(hours: 12))),
      }).timeout(_wait);
      id = newId;
      shareToken = newToken;
      return true;
    } catch (_) {
      id = null;
      shareToken = null;
      return false;
    }
  }

  Future<void> update(LatLng at, {int? etaMin, String? dest, bool force = false}) async {
    if (id == null) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSent).inSeconds < 10) return;
    _lastSent = now;
    try {
      await _doc.update({
        'lat': at.latitude,
        'lng': at.longitude,
        if (etaMin != null) 'etaMin': etaMin,
        if (dest != null) 'dest': dest,
        'updatedAt': FieldValue.serverTimestamp(),
      }).timeout(_wait);
    } catch (_) {}
  }

  /// status: walking, arrived, stopped, sos or noreply
  Future<void> setStatus(String status, {LatLng? at}) async {
    if (id == null) return;
    try {
      await _doc.update({
        'status': status,
        if (at != null) 'lat': at.latitude,
        if (at != null) 'lng': at.longitude,
        'updatedAt': FieldValue.serverTimestamp(),
      }).timeout(_wait);
    } catch (_) {}
  }

  Future<void> setGuardian(DateTime? end) async {
    if (id == null) return;
    try {
      await _doc.update({'guardianEnd': end?.millisecondsSinceEpoch}).timeout(_wait);
    } catch (_) {}
  }

  Future<void> end(String status) async {
    if (id == null) return;
    await setStatus(status);
    id = null;
    shareToken = null;
  }
}
