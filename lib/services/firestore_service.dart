import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:latlong2/latlong.dart';

/// Data models for Firestore
class TrustedContact {
  final String id;
  final String uid;
  final String name;
  final String phone;
  final String? email;
  final String? relationship;
  final bool notifyOnSos;
  final bool notifyOnCheckIn;

  const TrustedContact({
    required this.id,
    required this.uid,
    required this.name,
    required this.phone,
    this.email,
    this.relationship,
    this.notifyOnSos = true,
    this.notifyOnCheckIn = true,
  });

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'name': name,
        'phone': phone,
        'email': email,
        'relationship': relationship ?? 'Contact',
        'notifyOnSos': notifyOnSos,
        'notifyOnCheckIn': notifyOnCheckIn,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  factory TrustedContact.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? {};
    return TrustedContact(
      id: doc.id,
      uid: m['uid'] ?? '',
      name: m['name'] ?? '',
      phone: m['phone'] ?? '',
      email: m['email'],
      relationship: m['relationship'],
      notifyOnSos: m['notifyOnSos'] ?? true,
      notifyOnCheckIn: m['notifyOnCheckIn'] ?? true,
    );
  }
}

class CommunitySafetyReport {
  final String id;
  final String uid;
  final LatLng at;
  final String category; // 'poorly_lit', 'isolated', 'harassment', 'felt_safe', 'broken_road'
  final String timeOfDay; // 'day' or 'night'
  final int hour;
  final int rating; // 1..5
  final String text;
  final String tripId;
  final DateTime createdAt;

  CommunitySafetyReport({
    required this.id,
    required this.uid,
    required this.at,
    required this.category,
    required this.timeOfDay,
    required this.hour,
    required this.rating,
    required this.text,
    required this.tripId,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'uid': uid,
        'lat': at.latitude,
        'lng': at.longitude,
        'category': category,
        'timeOfDay': timeOfDay,
        'hour': hour,
        'rating': rating,
        'text': text,
        'tripId': tripId,
        'createdAt': FieldValue.serverTimestamp(),
      };
}

class AreaSafetyCell {
  final String cellId;
  final LatLng center;
  final int safetyScore; // 0..100
  final String riskLevel; // 'low_risk', 'moderate_risk', 'isolated_stretch'
  final int reportCount;
  final List<String> topTags;

  AreaSafetyCell({
    required this.cellId,
    required this.center,
    required this.safetyScore,
    required this.riskLevel,
    required this.reportCount,
    required this.topTags,
  });

  factory AreaSafetyCell.fromMap(String id, Map<String, dynamic> m) {
    return AreaSafetyCell(
      cellId: id,
      center: LatLng((m['lat'] as num).toDouble(), (m['lng'] as num).toDouble()),
      safetyScore: (m['safetyScore'] as num?)?.toInt() ?? 50,
      riskLevel: m['riskLevel'] ?? 'moderate_risk',
      reportCount: (m['reportCount'] as num?)?.toInt() ?? 0,
      topTags: List<String>.from(m['topTags'] ?? const []),
    );
  }
}

class FirestoreService {
  static final FirestoreService instance = FirestoreService._();
  FirestoreService._();

  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _users => _db.collection('users');
  CollectionReference<Map<String, dynamic>> get _contacts => _db.collection('trusted_contacts');
  CollectionReference<Map<String, dynamic>> get _trips => _db.collection('trips');
  CollectionReference<Map<String, dynamic>> get _reports => _db.collection('safety_reports');
  CollectionReference<Map<String, dynamic>> get _sosEvents => _db.collection('sos_events');
  CollectionReference<Map<String, dynamic>> get _areas => _db.collection('areas');

  // ---------- User Management ----------
  Future<void> saveUserProfile({
    required String uid,
    required String email,
    required String name,
    String? photoUrl,
  }) async {
    try {
      await _users.doc(uid).set({
        'uid': uid,
        'email': email,
        'name': name,
        if (photoUrl != null) 'photoUrl': photoUrl,
        'lastLoginAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  Future<void> touchUserLogin(String uid) async {
    try {
      await _users.doc(uid).set({
        'lastLoginAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // ---------- Trusted Contacts ----------
  Stream<List<TrustedContact>> watchContacts(String uid) {
    return _contacts
        .where('uid', isEqualTo: uid)
        .snapshots()
        .map((snap) => snap.docs.map(TrustedContact.fromDoc).toList());
  }

  Future<List<TrustedContact>> getContacts(String uid) async {
    try {
      final snap = await _contacts.where('uid', isEqualTo: uid).get();
      return snap.docs.map(TrustedContact.fromDoc).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addContact(TrustedContact contact) async {
    await _contacts.add(contact.toMap());
  }

  Future<void> updateContact(TrustedContact contact) async {
    await _contacts.doc(contact.id).update(contact.toMap());
  }

  Future<void> deleteContact(String contactId) async {
    await _contacts.doc(contactId).delete();
  }

  // ---------- Live Trip Sharing with Secure Expiry ----------
  static String generateShareToken() {
    final r = math.Random.secure();
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    return List.generate(24, (_) => chars[r.nextInt(chars.length)]).join();
  }

  Future<String?> createLiveTrip({
    required String uid,
    required LatLng at,
    required String dest,
    required int etaMin,
    DateTime? guardianEnd,
  }) async {
    try {
      final tripId = generateShareToken();
      final shareToken = generateShareToken();
      final now = DateTime.now();

      await _trips.doc(tripId).set({
        'uid': uid,
        'shareToken': shareToken,
        'lat': at.latitude,
        'lng': at.longitude,
        'dest': dest,
        'etaMin': etaMin,
        'status': 'walking', // 'walking', 'arrived', 'stopped', 'noreply', 'sos'
        'guardianEnd': guardianEnd?.millisecondsSinceEpoch,
        'startedAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        // TTL policy: trip automatically deletes after 12 hours for user privacy
        'expiresAt': Timestamp.fromDate(now.add(const Duration(hours: 12))),
      });
      return tripId;
    } catch (_) {
      return null;
    }
  }

  Future<void> updateTripLocation(String tripId, LatLng at, {int? etaMin, String? dest}) async {
    try {
      await _trips.doc(tripId).update({
        'lat': at.latitude,
        'lng': at.longitude,
        if (etaMin != null) 'etaMin': etaMin,
        if (dest != null) 'dest': dest,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<void> setTripStatus(String tripId, String status, {LatLng? at}) async {
    try {
      await _trips.doc(tripId).update({
        'status': status,
        if (at != null) 'lat': at.latitude,
        if (at != null) 'lng': at.longitude,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  // ---------- Community Safety Reports ----------
  Future<bool> submitSafetyReport({
    required String uid,
    required LatLng at,
    required String category,
    required int rating,
    required String text,
    required String tripId,
  }) async {
    try {
      final now = DateTime.now();
      final isNight = now.hour >= 19 || now.hour < 6;
      final cellId = '${(at.latitude * 1000).round()}_${(at.longitude * 1000).round()}';

      await _reports.add({
        'uid': uid,
        'cellId': cellId,
        'lat': at.latitude,
        'lng': at.longitude,
        'category': category,
        'timeOfDay': isNight ? 'night' : 'day',
        'hour': now.hour,
        'rating': rating,
        'text': text.trim().length > 280 ? text.trim().substring(0, 280) : text.trim(),
        'tripId': tripId,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- SOS Events Logging ----------
  Future<String?> logSosEvent({
    required String uid,
    required LatLng at,
    required String triggerType, // 'manual', 'shake', 'guardian_timeout', 'missed_checkin'
    String? tripId,
    List<String> contactsNotified = const [],
  }) async {
    try {
      final docRef = await _sosEvents.add({
        'uid': uid,
        'tripId': tripId,
        'lat': at.latitude,
        'lng': at.longitude,
        'triggerType': triggerType,
        'status': 'active', // 'active', 'resolved'
        'contactsNotified': contactsNotified,
        'timeline': [
          {
            'event': 'SOS Triggered ($triggerType)',
            'time': Timestamp.now(),
          }
        ],
        'createdAt': FieldValue.serverTimestamp(),
      });
      return docRef.id;
    } catch (_) {
      return null;
    }
  }

  Future<void> resolveSosEvent(String sosEventId, {String note = 'User confirmed safe'}) async {
    try {
      await _sosEvents.doc(sosEventId).update({
        'status': 'resolved',
        'resolvedAt': FieldValue.serverTimestamp(),
        'timeline': FieldValue.arrayUnion([
          {
            'event': 'SOS Resolved: $note',
            'time': Timestamp.now(),
          }
        ]),
      });
    } catch (_) {}
  }

  // ---------- Aggregated Area Hotspots (SafeRoutes IEEE inspired) ----------
  Future<List<AreaSafetyCell>> getAreaHotspots({
    required double minLat,
    required double maxLat,
    required double minLng,
    required double maxLng,
  }) async {
    try {
      final snap = await _areas
          .where('lat', isGreaterThanOrEqualTo: minLat)
          .where('lat', isLessThanOrEqualTo: maxLat)
          .limit(100)
          .get();

      return snap.docs
          .map((d) => AreaSafetyCell.fromMap(d.id, d.data()))
          .where((cell) => cell.center.longitude >= minLng && cell.center.longitude <= maxLng)
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- Privacy: Delete All User Data ----------
  Future<void> deleteUserData(String uid) async {
    try {
      // 1. Delete user profile
      await _users.doc(uid).delete();

      // 2. Delete trusted contacts
      final contactsSnap = await _contacts.where('uid', isEqualTo: uid).get();
      for (final doc in contactsSnap.docs) {
        await doc.reference.delete();
      }

      // 3. Delete or anonymize trips
      final tripsSnap = await _trips.where('uid', isEqualTo: uid).get();
      for (final doc in tripsSnap.docs) {
        await doc.reference.delete();
      }

      // 4. Anonymize community reports so community knowledge stays helpful
      final reportsSnap = await _reports.where('uid', isEqualTo: uid).get();
      for (final doc in reportsSnap.docs) {
        await doc.reference.update({'uid': 'anonymous_deleted'});
      }
    } catch (_) {}
  }
}
