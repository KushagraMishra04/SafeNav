import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/agent_client.dart';
import '../services/emergency.dart';
import '../services/plan_cache.dart';
import '../services/review_service.dart';
import '../services/safety_engine.dart';
import '../services/shake_detector.dart';
import '../services/stretch_engine.dart';
import '../services/sun.dart';
import '../services/trip_share.dart';
import '../services/voice.dart';
import '../services/auth_service.dart';
import '../services/firestore_service.dart';
import 'guardian_chat_screen.dart';
import '../theme/app_theme.dart';

class SosContact {
  final String name;
  final String phone;
  final String relationship;

  const SosContact({required this.name, required this.phone, this.relationship = 'Contact'});

  Map<String, String> toMap() => {'name': name, 'phone': phone, 'relationship': relationship};

  factory SosContact.fromMap(Map<String, dynamic> m) => SosContact(
        name: m['name']?.toString() ?? '',
        phone: m['phone']?.toString() ?? '',
        relationship: m['relationship']?.toString() ?? 'Contact',
      );
}

class RouteMapScreen extends StatefulWidget {
  final List<String> contacts; // phone numbers from your emergency-contacts screen
  const RouteMapScreen({super.key, this.contacts = const []});
  @override
  State<RouteMapScreen> createState() => _RouteMapScreenState();
}

class _RouteMapScreenState extends State<RouteMapScreen> {
  final _map = MapController();
  final _engine = SafetyEngine();
  final _reviews = ReviewService();
  final _agent = AgentClient();
  final _search = TextEditingController();
  final _tripId = DateTime.now().millisecondsSinceEpoch.toString();

  LatLng? _me, _lastPos;
  Place? _dest;
  List<Place> _results = [];
  List<RawRoute> _raws = [];
  Osm? _osm;
  List<Review> _revs = [];
  List<ScoredRoute> _routes = [];
  String? _selId;
  String _stage = '', _advice = '';
  bool _busy = false, _navigating = false, _checkInOpen = false;
  bool _night = _isNight();
  List<double>? _weights;
  List<String> _contacts = [];
  List<SosContact> _contactItems = [];
  String _userName = '';
  bool _autoArrive = true, _autoBattery = true, _batteryAlerted = false, _fromCache = false;
  int _fastCount = 0;
  Timer? _batTimer, _sunTimer;
  bool _nightAuto = true;
  final _cache = PlanCache();
  List<Place> _recent = [];
  int _stepIdx = 0;
  Timer? _demo;
  bool _demoMode = false;
  double _maxDetour = 1.4;
  final _voice = Voice();
  final _trip = TripShare();
  late final ShakeDetector _shake = ShakeDetector(_onShake, onHit: (_) => Voice.tap());
  final _ssCache = <String, StretchSet>{};
  final _warned = <int>{};
  String _warning = '';
  Timer? _warnTimer, _gTicker;
  int _spokenStep = -1;
  bool _headingUp = true;
  double? _heading;
  LatLng? _hPrev;
  DateTime? _guardianEnd;
  DateTime _lastMove = DateTime.now();
  StreamSubscription<Position>? _sub;

  static bool _isNight() {
    final h = DateTime.now().hour;
    return h >= 19 || h < 6;
  }

  ScoredRoute? get _sel => _routes.where((r) => r.id == _selId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _locate();
    _loadContacts();
    _loadRecent();
    _shake.start();
    _sunTimer = Timer.periodic(const Duration(minutes: 5), (_) => _syncSun());
    WidgetsBinding.instance.addPostFrameCallback((_) => _consentGate());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _demo?.cancel();
    _warnTimer?.cancel();
    _gTicker?.cancel();
    _sunTimer?.cancel();
    _batTimer?.cancel();
    _shake.stop();
    _voice.stop();
    WakelockPlus.disable();
    unawaited(_trip.end('stopped'));
    _search.dispose();
    super.dispose();
  }

  void _toast(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _locate() async {
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      _toast('Location permission is needed to plan a safe route.');
      return;
    }
    final p = await Geolocator.getCurrentPosition();
    if (!mounted) return;
    setState(() {
      _me = LatLng(p.latitude, p.longitude);
      _night = isNightAt(_me!.latitude, _me!.longitude);
    });
    _map.move(_me!, 15);
  }

  Future<void> _searchPlaces(String q) async {
    if (q.trim().length < 3) return;
    final r = await _engine.search(q, near: _me);
    if (!mounted) return;
    setState(() => _results = r);
    if (r.isEmpty) {
      _toast(_engine.lastError != null
          ? 'Search failed (${_engine.lastError}). Check your internet connection.'
          : 'No places found. Try a more specific name.');
    }
  }

  // ---------- planning ----------
  Future<void> _plan(Place d, {bool quick = false, bool autoStartNav = false}) async {
    if (_me == null) return;
    final km = meters(_me!, d.at) / 1000;
    if (km > 8) {
      _toast('That is ${km.toStringAsFixed(0)} km away. Pick a place within walking distance (about 8 km).');
      setState(() => _results = []);
      return;
    }
    setState(() {
      _dest = d;
      _results = [];
      _busy = true;
      _routes = [];
      _advice = '';
      _weights = null;
      _stage = 'Finding walking routes…';
    });
    try {
      var fromCache = false;
      try {
        _raws = await _engine.candidateRoutes(_me!, d.at, quick: quick);
      } catch (_) {
        _raws = [];
      }
      CachedPlan? saved;
      if (_raws.isEmpty) {
        saved = await _cache.load(_me!, d.at);
        if (saved == null) throw 'No walking route found. Check your internet connection.';
        _raws = saved.raws;
        fromCache = true;
      }
      final all = _raws.expand((r) => r.points).toList();
      setState(() => _stage = 'Reading street lighting, shops and help points…');
      _osm = await _engine.osm(all, userLocation: _me);
      if (_osm!.failed) {
        saved ??= await _cache.load(_me!, d.at);
        if (saved != null) {
          if (saved.osm.help.isNotEmpty && _osm!.help.isEmpty) {
            _osm!.help.addAll(saved.osm.help);
          }
          if (saved.osm.lamps.isNotEmpty && _osm!.lamps.isEmpty) {
            _osm!.lamps.addAll(saved.osm.lamps);
            _osm!.lit.addAll(saved.osm.lit);
            _osm!.unlit.addAll(saved.osm.unlit);
            _osm!.activity.addAll(saved.osm.activity);
          }
          fromCache = true;
        }
      }
      _fromCache = fromCache;
      setState(() => _stage = 'Checking community reviews…');
      try {
        _revs = await _reviews.nearRoute(all);
      } catch (_) {
        _revs = [];
      }
      setState(() => _stage = 'Scoring routes…');
      _rescore();
      _stepIdx = 0;
      _spokenStep = -1;
      _warned.clear();
      final best = _sel!;
      if (!fromCache && !(_osm?.failed ?? true)) {
        unawaited(_cache.save(_me!, d.at, d.name, _raws, _osm!).then((_) => _loadRecent()));
      }
      unawaited(_trip.update(_me!, dest: d.name, force: true));
      _fit(best);
      _advice = _localAdvice(best) + _darkSoon(best);
      if (!quick) _askAgent(null);
      if (autoStartNav && mounted) {
        _startNav();
      }
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _rescore({bool keepSelection = false}) {
    if (_osm == null || _raws.isEmpty) return;
    final scored = _engine.score(_raws, _osm!, _revs, night: _night, weights: _weights);
    final best = _engine.pickBest(scored, maxDetour: _maxDetour);
    _ssCache.clear();
    setState(() {
      _routes = scored;
      if (!(keepSelection && scored.any((r) => r.id == _selId))) _selId = best.id;
    });
  }

  void _fit(ScoredRoute r) => _map.fitCamera(CameraFit.bounds(
      bounds: LatLngBounds.fromPoints(r.raw.points),
      padding: const EdgeInsets.fromLTRB(40, 130, 40, 360)));

  String _localAdvice(ScoredRoute best) {
    final fastest = _routes.reduce((a, b) => a.raw.durationS <= b.raw.durationS ? a : b);
    if (best.id == fastest.id) return 'This is both the safest and the fastest option.';
    final extra = ((best.raw.durationS - fastest.raw.durationS) / 60).round();
    return 'Takes about $extra min longer than the fastest route, but scores '
        '${best.score - fastest.score} points higher.';
  }

  Future<bool> _askAgent(String? msg) async {
    final a = await _agent.advise(
        message: msg ?? 'Find me the safest reasonable route.', night: _night, routes: _routes);
    if (!mounted) return false;
    if (a == null) {
      if (msg != null) _builtInAssistant(msg); // cloud agent not connected: keyword fallback
      return false;
    }
    _weights = a.weights;
    _maxDetour = a.maxDetour ?? 1.4;
    _rescore();
    setState(() => _advice = 'AI agent: ${a.explanation}${a.tips.isEmpty ? '' : '\n${a.tips.map((t) => '• $t').join('\n')}'}');
    return true;
  }

  Future<void> _openGuardianChat() async {
    final action = await Navigator.push<dynamic>(
      context,
      MaterialPageRoute(
        builder: (_) => GuardianChatScreen(
          currentLocation: _me,
          currentRouteSummary: _sel?.notes.join('; '),
          currentRouteScore: _sel?.score,
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action is SafePlaceNavRequest) {
      final title = action.place.name.split('·').first.trim();
      _voice.say('Routing to safe haven: $title');
      _plan(action.place, quick: true, autoStartNav: action.autoStart);
    } else if (action is Place) {
      final title = action.name.split('·').first.trim();
      _voice.say('Routing to safe haven: $title');
      _plan(action, quick: true, autoStartNav: true);
    } else if (action == 'find_safe_place') {
      _safePlace();
    } else if (action == 'call_112') {
      _emergencyAlert(call: true);
    } else if (action == 'share_trip') {
      _shareTrip();
    }
  }

  Future<void> _accountPrivacyDialog() async {
    final user = AuthService.instance.currentUser;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.privacy_tip_outlined, color: AppColors.blue),
            SizedBox(width: 8),
            Text('Account & Privacy'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('User: ${user?.email ?? (user?.isAnonymous == true ? "Guest Mode" : "Local User")}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              const Text(
                '• Location shared only during active navigation or emergency SOS.\n'
                '• Live tracking links expire automatically after 12 hours.\n'
                '• Community reviews do not store your name or phone number.\n'
                '• You can delete your account and all data at any time.',
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
              const Divider(height: 24),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.delete_forever, color: Colors.red),
                title: const Text('Delete My Account & Data', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 14)),
                subtitle: const Text('Irreversibly remove all your data from Firebase.', style: TextStyle(fontSize: 11)),
                onTap: () async {
                  Navigator.pop(ctx);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Delete All Data?'),
                      content: const Text('Are you sure you want to delete your account and personal records? This cannot be undone.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: Colors.red),
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    final res = await AuthService.instance.deleteAccountAndData();
                    if (mounted) {
                      _toast(res.success ? 'Account and data deleted.' : 'Failed: ${res.error}');
                      if (res.success) {
                        Navigator.pushNamedAndRemoveUntil(context, '/auth', (route) => false);
                      }
                    }
                  }
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await AuthService.instance.signOut();
              if (mounted) {
                Navigator.pushNamedAndRemoveUntil(context, '/auth', (route) => false);
              }
            },
            child: const Text('Sign Out'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  // ---------- contacts, offline assistant ----------

  Future<void> _loadContacts() async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getStringList('sos_contacts') ?? [];
    final jsonList = sp.getStringList('sos_contacts_json') ?? [];
    final name = sp.getString('sos_name') ?? '';
    final arrive = sp.getBool('auto_arrive') ?? true;
    final battery = sp.getBool('auto_battery') ?? true;

    final items = <SosContact>[];
    for (final raw in jsonList) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          items.add(SosContact.fromMap(decoded));
        }
      } catch (_) {}
    }

    // Merge plain numbers from widget.contacts or saved if not present in items
    for (final p in {...widget.contacts, ...saved}) {
      if (p.trim().isNotEmpty && !items.any((c) => c.phone == p.trim())) {
        items.add(SosContact(name: 'Contact ${items.length + 1}', phone: p.trim()));
      }
    }

    if (mounted) {
      setState(() {
        _contactItems = items;
        _contacts = items.map((c) => c.phone).toList();
        _userName = name;
        _autoArrive = arrive;
        _autoBattery = battery;
      });
    }
  }

  Future<void> _editContacts() async {
    final n = TextEditingController(text: _userName);
    final newNameCtrl = TextEditingController();
    final newPhoneCtrl = TextEditingController();
    String newRelation = 'Family';
    var arrive = _autoArrive, battery = _autoBattery;

    final tempItems = List<SosContact>.from(_contactItems);

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.contact_phone_outlined, color: AppColors.blue),
              SizedBox(width: 8),
              Expanded(child: Text('Emergency contacts', style: TextStyle(fontSize: 18))),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Add multiple trusted contacts. In an emergency, SafeNav texts them your live location link.',
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: n,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Your name (shown in alerts)',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Saved Contacts (${tempItems.length})',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      if (tempItems.isNotEmpty)
                        Text('${tempItems.length} active',
                            style: const TextStyle(fontSize: 12, color: AppColors.blue)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (tempItems.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Center(
                        child: Text(
                          'No contacts yet. Add your family or trusted friends below.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: AppColors.muted),
                        ),
                      ),
                    )
                  else
                    Column(
                      children: [
                        for (var i = 0; i < tempItems.length; i++)
                          Card(
                            margin: const EdgeInsets.only(bottom: 6),
                            elevation: 1,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            child: ListTile(
                              dense: true,
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: AppColors.blue.withValues(alpha: 0.15),
                                child: Text(
                                  tempItems[i].name.isNotEmpty ? tempItems[i].name[0].toUpperCase() : 'C',
                                  style: const TextStyle(color: AppColors.blue, fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                              ),
                              title: Text(tempItems[i].name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: Text('${tempItems[i].phone} · ${tempItems[i].relationship}'),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                                onPressed: () => setD(() => tempItems.removeAt(i)),
                              ),
                            ),
                          ),
                      ],
                    ),
                  const Divider(height: 24),
                  const Text('Add new contact:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: newNameCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Contact name (e.g. Mom, Alex)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: newPhoneCtrl,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Phone number (e.g. +91 9876543210)',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    children: [
                      for (final rel in ['Family', 'Friend', 'Partner', 'Guardian', 'Colleague'])
                        ChoiceChip(
                          label: Text(rel, style: const TextStyle(fontSize: 11)),
                          selected: newRelation == rel,
                          onSelected: (val) {
                            if (val) setD(() => newRelation = rel);
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.person_add_alt_1, size: 16),
                      label: const Text('Add to contact list'),
                      onPressed: () {
                        final rawPhone = newPhoneCtrl.text.replaceAll(RegExp(r'[^0-9+]'), '');
                        final rawName = newNameCtrl.text.trim();
                        if (rawPhone.length < 7) {
                          _toast('Please enter a valid phone number with country code.');
                          return;
                        }
                        setD(() {
                          tempItems.add(SosContact(
                            name: rawName.isNotEmpty ? rawName : 'Contact ${tempItems.length + 1}',
                            phone: rawPhone,
                            relationship: newRelation,
                          ));
                          newNameCtrl.clear();
                          newPhoneCtrl.clear();
                        });
                      },
                    ),
                  ),
                  const Divider(height: 24),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Text them when I arrive safely', style: TextStyle(fontSize: 13)),
                    value: arrive,
                    onChanged: (x) => setD(() => arrive = x ?? true),
                  ),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Text them my location if my battery gets low', style: TextStyle(fontSize: 13)),
                    value: battery,
                    onChanged: (x) => setD(() => battery = x ?? true),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save contacts'),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;

    final phoneList = tempItems.map((c) => c.phone).where((p) => p.length >= 7).toSet().toList();
    final jsonList = tempItems.map((c) => jsonEncode(c.toMap())).toList();

    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('sos_contacts', phoneList);
    await sp.setStringList('sos_contacts_json', jsonList);
    await sp.setString('sos_name', n.text.trim());
    await sp.setBool('auto_arrive', arrive);
    await sp.setBool('auto_battery', battery);

    // If user is authenticated with Firebase, also sync to Firestore
    final user = AuthService.instance.currentUser;
    if (user != null) {
      for (final item in tempItems) {
        try {
          await FirestoreService.instance.addContact(TrustedContact(
            id: '',
            uid: user.uid,
            name: item.name,
            phone: item.phone,
            relationship: item.relationship,
          ));
        } catch (_) {}
      }
    }

    if (mounted) {
      setState(() {
        _contactItems = tempItems;
        _contacts = phoneList;
        _userName = n.text.trim();
        _autoArrive = arrive;
        _autoBattery = battery;
      });
    }

    if (phoneList.isNotEmpty) {
      final ok = await Emergency.prepare();
      if (!mounted) return;
      _toast(ok
          ? 'Saved ${phoneList.length} contacts. Emergency alerts ready.'
          : 'Saved ${phoneList.length} contacts. SMS permission not granted, alerts will open message app.');
    } else {
      _toast('Contacts updated.');
    }
  }

  /// Offline fallback for "Ask AI": maps keywords in the message to factor weights.
  void _builtInAssistant(String msg) {
    final t = msg.toLowerCase();
    final w = List<double>.from(_night ? [0.30, 0.15, 0.20, 0.35] : [0.15, 0.25, 0.20, 0.40]);
    final why = <String>[];
    void bump(int i, double d, String s) {
      w[i] += d;
      why.add(s);
    }
    if (RegExp(r'dark|light|lit\b|lamp').hasMatch(t)) bump(0, .25, 'well-lit streets');
    if (RegExp(r'busy|crowd|people|alone|lonely|isolat|empty|deserted').hasMatch(t)) bump(1, .25, 'busy streets');
    if (RegExp(r'police|help|hospital|emergency').hasMatch(t)) bump(2, .20, 'nearby help');
    if (RegExp(r'review|community|reported|others').hasMatch(t)) bump(3, .20, 'community reviews');
    if (why.isEmpty) {
      setState(() => _advice = 'Built-in assistant: I could not tell what to prioritise. '
          'Try mentioning lighting, busy streets, police nearby or reviews.');
      return;
    }
    final sum = w.fold<double>(0, (a, b) => a + b);
    _weights = w.map((x) => x / sum).toList();
    _rescore();
    setState(() => _advice = 'Built-in assistant (cloud AI not connected): weighting ${why.join(', ')} '
        'more heavily. ${_localAdvice(_sel!)}');
  }

  // ---------- navigation ----------
  StretchSet? get _sset {
    final r = _sel, o = _osm;
    if (r == null || o == null) return null;
    return _ssCache.putIfAbsent(
        r.id, () => buildStretches(r.raw, o, _revs, night: _night, weights: _weights));
  }

  LocationSettings _locSettings() => defaultTargetPlatform == TargetPlatform.android
      ? AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 8,
          // foreground service: keeps tracking alive when the screen turns off
          foregroundNotificationConfig: const ForegroundNotificationConfig(
              notificationTitle: 'SafeNav is guarding your trip',
              notificationText: 'Live location is on',
              enableWakeLock: true))
      : const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 8);

  double _speed(ScoredRoute r) => r.raw.distanceM / (r.raw.durationS == 0 ? 1 : r.raw.durationS);

  void _startNav({bool demo = false}) {
    final r = _sel;
    if (r == null) return;
    _lastMove = DateTime.now();
    _stepIdx = 0;
    _spokenStep = -1;
    _warned.clear();
    _heading = null;
    _hPrev = null;
    _demoMode = demo;
    setState(() => _navigating = true);
    WakelockPlus.enable();
    _shake.start();
    _fastCount = 0;
    if (!demo) _startBatteryWatch();
    final first = r.raw.steps.isEmpty ? '' : ' ${r.raw.steps.first.text}.';
    _voice.say('Navigation started.$first');
    if (demo) {
      // Simulated walk along the chosen route, so navigation can be shown indoors.
      final pts = densify(r.raw.points, 12);
      var i = 0;
      _demo = Timer.periodic(const Duration(milliseconds: 700), (t) {
        if (i >= pts.length) {
          t.cancel();
          return;
        }
        _onLoc(pts[i++]);
      });
    } else {
      _sub = Geolocator.getPositionStream(locationSettings: _locSettings()).listen((p) => _onLoc(
          LatLng(p.latitude, p.longitude),
          heading: (p.speed > 0.5 && p.heading >= 0) ? p.heading : null,
          speed: p.speed));
    }
  }

  Future<void> _stopNav({String trip = 'stopped'}) async {
    _demo?.cancel();
    _demo = null;
    final s = _sub;
    _sub = null;
    _batTimer?.cancel();
    _voice.stop();
    WakelockPlus.disable();
    _cancelGuardian();
    unawaited(_trip.end(trip));
    if (mounted) {
      setState(() {
        _navigating = false;
        _demoMode = false;
        _warning = '';
      });
      _map.rotate(0);
    }
    await s?.cancel();
  }

  void _onLoc(LatLng here, {double? heading, double? speed}) {
    if (!_navigating) return;
    setState(() => _me = here);
    final cur = _sel;
    if (cur != null) {
      // move on to the next instruction once the current turn point is reached
      while (_stepIdx < cur.raw.steps.length - 1 && meters(here, cur.raw.steps[_stepIdx].at) < 25) {
        _stepIdx++;
      }
      _speakStep(cur, here);
      _checkWarnings(here);
      unawaited(_trip.update(here, etaMin: (_remainingM(cur) / _speed(cur) / 60).ceil()));
    }

    // heading-up map, with the heading smoothed so the map does not jitter
    var h = heading;
    if (h == null && _hPrev != null && meters(here, _hPrev!) > 4) h = bearingDeg(_hPrev!, here);
    if (h != null) {
      _hPrev = here;
      final old = _heading;
      _heading = old == null ? h : (old + (((h - old + 540) % 360) - 180) * 0.35) % 360;
    }
    _hPrev ??= here;
    if (_headingUp && _heading != null) {
      _map.moveAndRotate(here, 18, -_heading!);
    } else {
      _map.move(here, 18);
    }

    if (_lastPos == null || meters(here, _lastPos!) > 15) {
      _lastPos = here;
      _lastMove = DateTime.now();
    }
    if (_dest != null && meters(here, _dest!.at) < 30) {
      _finish();
      return;
    }
    final route = _sel;
    if (route == null) return;
    final off = nearest(here, route.raw.points);
    // fast and away from the route for 3 readings in a row: probably in a vehicle
    _fastCount = (speed != null && speed > 7 && off > 100) ? _fastCount + 1 : 0;
    if (_fastCount >= 3) {
      _fastCount = 0;
      _checkIn(reason: 'It looks like you are in a vehicle, away from your route.');
    } else if (off > 150 || DateTime.now().difference(_lastMove).inMinutes >= 4) {
      _checkIn();
    } else if (off > 60 && !_busy) {
      _toast('You left the route. Finding a safe way back…');
      _plan(_dest!);
    }
  }

  void _speakStep(ScoredRoute r, LatLng here) {
    if (r.raw.steps.isEmpty || _spokenStep == _stepIdx) return;
    final st = r.raw.steps[_stepIdx];
    final d = meters(here, st.at);
    if (d <= 70) {
      _spokenStep = _stepIdx;
      Voice.tap();
      _voice.say(d < 20 ? st.text : 'In ${(d / 10).round() * 10} metres, ${st.text}');
    }
  }

  /// Warns once per risky stretch, about 150 m before you reach it.
  void _checkWarnings(LatLng here) {
    final ss = _sset;
    if (ss == null) return;
    final ni = ss.nearestIndex(here);
    for (var k = 0; k < ss.stretches.length; k++) {
      final st = ss.stretches[k];
      if (st.to < ni || !st.risky || st.confidence < warnMinConfidence || _warned.contains(k)) continue;
      final dist = st.from <= ni ? 0.0 : meters(here, ss.samples[st.from]);
      if (dist > 160) break;
      _warned.add(k);
      final len = ((st.to - st.from + 1) * 25).round();
      final where = dist < 30 ? 'You are entering' : 'In ${dist.round()} metres,';
      _showWarning('$where a risky stretch of about $len m: ${st.reason ?? 'low safety signals'}. Stay alert.');
      break;
    }
  }

  void _showWarning(String m) {
    if (!mounted) return;
    setState(() => _warning = m);
    Voice.alert();
    _voice.say(m);
    _warnTimer?.cancel();
    _warnTimer = Timer(const Duration(seconds: 12), () {
      if (mounted) setState(() => _warning = '');
    });
  }

  Future<void> _checkIn({String reason = 'You stopped or left your route.'}) async {
    if (_checkInOpen || !mounted) return;
    _checkInOpen = true;
    Voice.alert();
    final ok = await showDialog<bool>(
        context: context, barrierDismissible: false, builder: (_) => _CheckInDialog(reason));
    _checkInOpen = false;
    _lastMove = DateTime.now();
    if (ok != true) {
      unawaited(_trip.setStatus('noreply'));
      _sos(auto: true, call: false);
    }
  }

  Future<void> _finish() async {
    final dest = _dest?.name ?? 'my destination';
    final route = _sel;
    final wasDemo = _demoMode;
    await _stopNav(trip: 'arrived');
    Voice.alert();
    _voice.say('You have arrived.');
    if (!mounted) return;
    // tell contacts quietly that you arrived (never during a demo walk)
    var told = false;
    if (_autoArrive && _contacts.isNotEmpty && !wasDemo) {
      final res = await Emergency.sendAll(
          _contacts, '$_who arrived safely at $dest (SafeNav, ${TimeOfDay.now().format(context)}).');
      told = res.sent > 0;
      if (told && mounted) _toast('Your contacts were told you arrived safely.');
    }
    if (!mounted) return;
    final d = await showReviewForm(context, 'You arrived. How safe did this route feel?');
    if (d != null && route != null) {
      try {
        final online = await _reviews.addForTrip(
            points: route.raw.points, rating: d.rating, tags: d.tags, text: d.text, tripId: _tripId);
        final newRevs = [
          for (var i = 0; i < route.raw.points.length; i += 6)
            Review(route.raw.points[i], d.rating, d.tags, d.text, DateTime.now())
        ];
        if (mounted) {
          setState(() => _revs = [..._revs, ...newRevs]);
          _rescore(keepSelection: true);
        }
        _toast(online
            ? 'Thanks. Your feedback now helps score this route for others.'
            : 'Thanks. Saved on this device (cloud sync is not set up yet).');
      } catch (e) {
        _toast('Could not save feedback: $e');
      }
    }
    if (_contacts.isNotEmpty && !told && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 10),
          content: const Text('Let your contacts know you arrived?'),
          action: SnackBarAction(
              label: 'Message', onPressed: () => Sos.sms(_contacts, "I've arrived safely at $dest."))));
    }
  }

  // ---------- consent, saved trips, sunset, battery, quick reports ----------
  String get _who => _userName.isEmpty ? 'A SafeNav user' : _userName;

  Future<void> _loadRecent() async {
    final r = await _cache.recent();
    if (mounted) setState(() => _recent = r);
  }

  /// First launch only: say plainly what the app does with location, SMS and reviews.
  Future<void> _consentGate() async {
    final sp = await SharedPreferences.getInstance();
    if (sp.getBool('consent_v1') ?? false) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Before you start'),
        content: const SingleChildScrollView(
            child: Text('• SafeNav uses your location to plan routes, guide you and, only if you choose, share it with your contacts.\n\n'
                '• Safety scores come from OpenStreetMap data and community reviews. They show lower-risk routes. They do not guarantee safety.\n\n'
                '• Reviews you post are stored without your name or phone number.\n\n'
                '• Emergency alerts send SMS from your own SIM (normal charges apply) and can call 112.\n\n'
                '• Your emergency contacts stay on this phone.\n\n'
                '• Live trip links stop when you arrive or stop sharing, and expire after 12 hours.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Not now')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('I agree')),
        ],
      ),
    );
    if (ok != true) return;
    await sp.setBool('consent_v1', true);
    if (mounted && (sp.getStringList('sos_contacts') ?? const <String>[]).isEmpty) await _editContacts();
  }

  /// If the walk will end near or after sunset, say so.
  String _darkSoon(ScoredRoute best) {
    final p = _me;
    if (p == null || _night) return '';
    final t = sunTimes(DateTime.now(), p.latitude, p.longitude);
    if (t == null) return '';
    final arrive = DateTime.now().add(Duration(seconds: best.raw.durationS.round()));
    if (DateTime.now().isBefore(t.set) && t.set.difference(arrive).inMinutes < 30) {
      return ' It gets dark at ${TimeOfDay.fromDateTime(t.set).format(context)}, so lighting and busy streets matter more soon.';
    }
    return '';
  }

  void _startBatteryWatch() {
    _batteryAlerted = false;
    _batTimer?.cancel();
    _batTimer = Timer.periodic(const Duration(seconds: 60), (_) => _checkBattery());
  }

  /// Once per trip, at 15% or less: text contacts the last location (real walks only).
  Future<void> _checkBattery() async {
    if (!_navigating || _demoMode || !_autoBattery || _batteryAlerted || _contacts.isEmpty) return;
    try {
      final level = await Battery().batteryLevel;
      if (level > 15) return;
      _batteryAlerted = true;
      final at = _me;
      final b = StringBuffer("$_who's phone battery is at $level% during a SafeNav walk. ");
      if (at != null) {
        b.write('Last location: https://maps.google.com/?q=${at.latitude.toStringAsFixed(6)},${at.longitude.toStringAsFixed(6)} ');
      }
      final link = _trip.link;
      if (link != null) b.write('Live tracking: $link ');
      b.write('The phone may switch off soon.');
      await Emergency.sendAll(_contacts, b.toString());
      if (mounted) _toast('Battery is low. Your contacts have your last location.');
    } catch (_) {}
  }

  /// One tap while walking: no typing. Saved as a review at your position.
  Future<void> _quickReport() async {
    final at = _me;
    if (at == null) return;
    const options = <(String, int, List<String>)>[
      ('Poorly lit here', 2, ['poorly_lit']),
      ('Feels isolated', 2, ['isolated']),
      ('Harassment or being followed', 1, ['harassment']),
      ('Felt safe here', 5, ['felt_safe']),
      ('Road in poor condition', 2, ['broken_road']),
    ];
    final pick = await showModalBottomSheet<(String, int, List<String>)>(
      context: context,
      builder: (_) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Report this spot', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
        for (final o in options) ListTile(title: Text(o.$1), onTap: () => Navigator.pop(context, o)),
      ])),
    );
    if (pick == null || !mounted) return;
    try {
      final online = await _reviews.addAt(at, pick.$2, pick.$3, '', _tripId);
      if (!mounted) return;
      setState(() => _revs = [..._revs, Review(at, pick.$2, pick.$3, '', DateTime.now())]);
      _rescore(keepSelection: true);
      _toast(online ? 'Reported. Thank you.' : 'Reported on this device (cloud sync is not set up yet).');
    } on AlreadyReported {
      _toast('You already reported this spot today.');
    } catch (e) {
      _toast('Could not save the report: $e');
    }
    if (mounted && pick.$3.contains('harassment')) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 8),
          content: const Text('Need help right now?'),
          action: SnackBarAction(label: 'Emergency', onPressed: _sos)));
    }
  }

  // ---------- sun ----------
  /// Re-checks sunrise/sunset while the app stays open (only if you have not set Night yourself).
  void _syncSun() {
    final p = _me;
    if (!mounted || !_nightAuto || p == null) return;
    final n = isNightAt(p.latitude, p.longitude);
    if (n != _night) {
      setState(() => _night = n);
      _rescore();
      _toast(n ? 'Sunset has passed: night mode is on.' : 'Sunrise: night mode is off.');
    }
  }

  String _sunText() {
    final p = _me;
    if (p == null) return 'Waiting for your location to read sunrise and sunset.';
    final mode = _nightAuto ? 'Night mode follows the sun' : 'Night mode set by you';
    final t = sunTimes(DateTime.now(), p.latitude, p.longitude);
    if (t == null) return mode;
    String f(DateTime d) => TimeOfDay.fromDateTime(d).format(context);
    return 'Sunrise ${f(t.rise)} · Sunset ${f(t.set)} · $mode';
  }

  // ---------- guardian timer ----------
  String _mmss(Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _setGuardian() async {
    final r = _sel;
    final eta = r == null ? null : (r.raw.durationS / 60).ceil() + 10;
    final customCtrl = TextEditingController();
    int? selectedMins;

    final mins = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.timer_outlined, color: AppColors.blue),
              SizedBox(width: 8),
              Expanded(child: Text('Guardian safety timer', style: TextStyle(fontSize: 18))),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'If you do not tap "I\'m safe" before this timer ends, SafeNav asks if you are okay and alerts your emergency contacts.',
                  style: TextStyle(fontSize: 12, color: AppColors.muted),
                ),
                const SizedBox(height: 16),
                const Text('Quick presets:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in <int>[15, 30, 45, 60, if (eta != null) eta])
                      ChoiceChip(
                        label: Text(m == eta ? '$m min (ETA+10)' : '$m min'),
                        selected: selectedMins == m,
                        onSelected: (sel) {
                          setD(() {
                            selectedMins = sel ? m : null;
                            if (sel) customCtrl.text = '$m';
                          });
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text('Or enter custom minutes:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(height: 8),
                TextField(
                  controller: customCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Minutes',
                    hintText: 'e.g. 25, 90',
                    prefixIcon: Icon(Icons.edit_calendar_outlined),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (val) {
                    final v = int.tryParse(val.trim());
                    setD(() => selectedMins = v);
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.check, size: 18),
              label: const Text('Start timer'),
              onPressed: () {
                final val = int.tryParse(customCtrl.text.trim()) ?? selectedMins;
                if (val != null && val > 0) {
                  Navigator.pop(ctx, val);
                } else {
                  _toast('Please select or enter a valid number of minutes.');
                }
              },
            ),
          ],
        ),
      ),
    );

    if (mins == null || mins <= 0) return;
    _cancelGuardian();
    setState(() => _guardianEnd = DateTime.now().add(Duration(minutes: mins)));
    unawaited(_trip.setGuardian(_guardianEnd));
    _gTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final end = _guardianEnd;
      if (end == null || !mounted) return;
      if (DateTime.now().isAfter(end)) {
        _guardianExpired();
      } else {
        setState(() {});
      }
    });
    _toast('Guardian timer started for $mins min.');
  }

  Future<void> _guardianExpired() async {
    _cancelGuardian();
    await _checkIn(reason: 'Your guardian timer ended.');
  }

  void _cancelGuardian() {
    _gTicker?.cancel();
    _gTicker = null;
    if (_guardianEnd != null) {
      _guardianEnd = null;
      unawaited(_trip.setGuardian(null));
      if (mounted) setState(() {});
    }
  }

  // ---------- shake to SOS ----------
  void _onShake() => _sosCountdown(); // works any time this screen is open; 5-second cancel countdown

  // ---------- live trip sharing ----------
  Future<void> _shareTrip() async {
    if (_contacts.isEmpty) {
      _toast('Add emergency contacts first.');
      await _editContacts();
      if (_contacts.isEmpty) return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Share this trip?'),
        content: const Text('Your contacts get a link that shows your live location and ETA until you arrive or stop sharing.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Share')),
        ],
      ),
    );
    final at = _me;
    if (ok != true || at == null || !mounted) return;
    final dest = _dest?.name ?? 'my destination';
    final r = _sel;
    final eta = r == null ? 0 : (r.raw.durationS / 60).ceil();
    final live = await _trip.start(at: at, dest: dest, etaMin: eta, guardianEnd: _guardianEnd);
    if (!mounted) return;
    final link = _trip.link;
    if (live && link != null) {
      await Sos.sms(_contacts, "I'm walking to $dest (about $eta min). Follow my live location: $link");
    } else {
      _toast('Live link is not set up yet (see SETUP.md), so I am sending a one-time location.');
      await Sos.sms(_contacts,
          "I'm walking to $dest (about $eta min). I'm here now: https://maps.google.com/?q=${at.latitude},${at.longitude} . I'll message when I arrive.");
    }
    if (mounted) setState(() {});
  }

  Future<void> _stopSharing() async {
    await _trip.end('stopped');
    if (mounted) setState(() {});
  }

  // ---------- nearest safe place, even while navigating ----------
  Future<void> _safePlace() async {
    final me = _me;
    if (me == null) {
      _toast('Waiting for your location. Please enable location and try again.');
      return;
    }
    _toast('Looking for nearby police stations and hospitals…');
    // Run each category separately so service errors can be reported accurately.
    final police = await _engine.nearbyPlaces(me, 'police');
    final policeError = _engine.lastNearbyError;
    final hospitals = await _engine.nearbyPlaces(me, 'hospital');
    final hospitalError = _engine.lastNearbyError;
    final all = [...police, ...hospitals]..sort((a, b) => meters(me, a.at).compareTo(meters(me, b.at)));
    if (!mounted) return;
    if (all.isEmpty) {
      final serviceFailed = policeError != null && hospitalError != null;
      _toast(serviceFailed
          ? 'Nearby map data is temporarily unavailable. Check your internet connection and try again.'
          : 'No mapped police station or hospital found within 10 km. Try Police stations or Hospitals on the map.');
      return;
    }
    final pick = await showModalBottomSheet<Place>(
      context: context,
      builder: (_) => SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nearest help', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
        for (final p in all.take(4))
          ListTile(leading: const Icon(Icons.local_police), title: Text(p.name), onTap: () => Navigator.pop(context, p)),
      ])),
    );
    if (pick == null) return;
    _voice.say('Heading to ${pick.name}');
    _plan(pick, quick: true);
  }

  // ---------- reviews & SOS ----------
  Future<void> _reviewAt(LatLng? p) async {
    if (p == null) return;
    final near = _me != null && meters(_me!, p) <= 150;
    if (!near && !kDebugMode) {
      _toast('You can review a spot once you are within 150 m of it.');
      return;
    }
    final d = await showReviewForm(context, 'Review this spot');
    if (d == null) return;
    try {
      final online = await _reviews.addAt(p, d.rating, d.tags, d.text, _tripId);
      if (!mounted) return;
      setState(() => _revs = [..._revs, Review(p, d.rating, d.tags, d.text, DateTime.now())]);
      _rescore(keepSelection: true);
      _toast(online ? 'Review saved.' : 'Review saved on this device (cloud sync is not set up yet).');
    } catch (e) {
      _toast('Could not save review: $e');
    }
  }

  void _showReview(Review r) => showModalBottomSheet(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [for (var i = 1; i <= 5; i++) Icon(i <= r.rating ? Icons.star : Icons.star_border, color: Colors.orange)]),
            const SizedBox(height: 8),
            Text(r.tags.map((t) => t.replaceAll('_', ' ')).join(' · ')),
            if (r.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(r.text)),
            Text('${DateTime.now().difference(r.createdAt).inDays} days ago', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );

  Future<void> _sosCountdown() async {
    if (_checkInOpen || !mounted) return;
    _checkInOpen = true;
    Voice.alert();
    final go = await showDialog<bool>(
        context: context, barrierDismissible: false, builder: (_) => const _SosCountdown());
    _checkInOpen = false;
    if (go == true) _sos(auto: true);
  }

  /// Tap on SOS opens this sheet. auto: true (hold, shake, no reply) sends straight away.
  Future<void> _sos({bool auto = false, bool call = true}) async {
    if (auto) {
      await _emergencyAlert(call: call);
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Emergency help', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(_contacts.isEmpty
                ? 'No contacts saved yet. Add some so alerts can reach them.'
                : 'Alerts go to ${_contacts.length} contact(s) with your live location.'),
            const SizedBox(height: 14),
            FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(vertical: 18)),
                onPressed: () { Navigator.pop(ctx); _emergencyAlert(call: true); },
                icon: const Icon(Icons.sos),
                label: const Text('Alert contacts and call 112', style: TextStyle(fontSize: 16))),
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: () { Navigator.pop(ctx); _emergencyAlert(call: false); },
                child: const Text('Alert my contacts only (quiet)')),
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: () { Navigator.pop(ctx); Emergency.call('112'); },
                child: const Text('Call 112 only')),
            Row(children: [
              Expanded(child: TextButton(onPressed: () => Emergency.dial('1091'), child: const Text('Women helpline 1091'))),
              Expanded(child: TextButton(onPressed: () => Emergency.dial('1090'), child: const Text('Women helpline 1090 (UP)'))),
            ]),
            Row(children: [
              Expanded(
                  child: TextButton(
                      onPressed: () { Navigator.pop(ctx); _editContacts(); },
                      child: Text(_contacts.isEmpty ? 'Add contacts' : 'Edit contacts'))),
              Expanded(
                  child: TextButton(
                      onPressed: _contacts.isEmpty ? null : () { Navigator.pop(ctx); _testAlert(); },
                      child: const Text('Send test message'))),
            ]),
          ]),
        ),
      ),
    );
  }

  /// One tap: find the location, start the live link, text every contact in the background,
  /// then call 112 (last, because Android blocks SMS during an emergency call).
  Future<void> _emergencyAlert({required bool call}) async {
    if (!mounted) return;
    Voice.alert();
    showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
                content: Row(children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Expanded(child: Text('Sending your alert…')),
            ]))));

    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 4));
    } catch (_) {
      try {
        pos = await Geolocator.getLastKnownPosition();
      } catch (_) {}
    }
    final at = pos != null ? LatLng(pos.latitude, pos.longitude) : _me;

    // live link (best effort, never holds the alert up for long)
    if (!_trip.active && at != null) {
      await _trip
          .start(at: at, dest: _dest?.name ?? 'unknown', etaMin: 0, guardianEnd: _guardianEnd)
          .timeout(const Duration(seconds: 4), onTimeout: () => false);
    }
    unawaited(_trip.setStatus('sos', at: at)); // the tracking page turns red

    // Log to Firestore sos_events collection
    final user = AuthService.instance.currentUser;
    if (user != null && at != null) {
      unawaited(FirestoreService.instance.logSosEvent(
        uid: user.uid,
        at: at,
        triggerType: _demoMode ? 'demo_simulated_sos' : 'manual_sos',
        tripId: _trip.id,
        contactsNotified: _contacts,
      ));
    }

    if (_demoMode) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop(); // close the progress box
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.science, color: Colors.orange),
              SizedBox(width: 8),
              Text('Demo Mode SOS Simulation'),
            ],
          ),
          content: Text(
            'Emergency flow executed safely in Demo Mode!\n\n'
            '• Live Web Tracker status set to SOS (red alert banner active).\n'
            '• Logged to Firestore sos_events collection.\n'
            '• Simulated dispatch to ${_contacts.length} emergency contacts.\n'
            '• Real SIM SMS and 112 calls suppressed for presentation.',
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                unawaited(_trip.setStatus('walking'));
              },
              child: const Text('Reset to Walking'),
            ),
          ],
        ),
      );
      return;
    }

    final text = _alertText(at);
    final res = await Emergency.sendAll(_contacts, text);
    // silent sending not possible: open the message app so the person can still send it
    if (_contacts.isNotEmpty && res.sent == 0 && mounted) await Sos.sms(_contacts, text);
    if (mounted) Navigator.of(context, rootNavigator: true).pop(); // close the progress box

    var called = false;
    if (call) called = await Emergency.call('112');
    if (!mounted) return;

    final msg = StringBuffer();
    if (_contacts.isEmpty) {
      msg.write('No contacts are saved, so nobody was messaged. ');
    } else if (res.sent > 0) {
      msg.write('Alert sent to ${res.sent} of ${_contacts.length} contacts. ');
      if (res.failed > 0) msg.write('${res.failed} failed (${res.problem}). ');
    } else {
      msg.write('Silent sending failed (${res.problem ?? 'unknown'}), so your message app was opened. ');
    }
    if (call) msg.write(called ? 'Calling 112…' : 'Could not start the call. Dial 112 now.');
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Emergency alert'),
        content: Text(msg.toString()),
        actions: [
          if (!call)
            FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () { Navigator.pop(context); Emergency.call('112'); },
                child: const Text('Call 112 now')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
  }

  String _alertText(LatLng? at) {
    final who = _userName.isEmpty ? 'A SafeNav user' : _userName;
    final b = StringBuffer('SOS: $who needs help (SafeNav, ${TimeOfDay.now().format(context)}). ');
    if (at != null) {
      b.write('Location: https://maps.google.com/?q=${at.latitude.toStringAsFixed(6)},${at.longitude.toStringAsFixed(6)} ');
    }
    final link = _trip.link;
    if (link != null) b.write('Live tracking: $link ');
    final help = _nearestHelp(at);
    if (help != null) {
      b.write('Nearest police/hospital seen on this route: ${_fmt(help.$2)} away '
          '(https://maps.google.com/?q=${help.$1.latitude},${help.$1.longitude}). ');
    }
    b.write('Please call them now. If you cannot reach them, call 112.');
    return b.toString();
  }

  /// Nearest police station or hospital from the data already loaded for this route (instant).
  (LatLng, double)? _nearestHelp(LatLng? at) {
    final o = _osm;
    if (at == null || o == null || o.help.isEmpty) return null;
    var best = o.help.first;
    var bd = meters(at, best);
    for (final h in o.help) {
      final d = meters(at, h);
      if (d < bd) {
        bd = d;
        best = h;
      }
    }
    return (best, bd);
  }

  Future<void> _testAlert() async {
    if (_contacts.isEmpty) {
      _toast('Add contacts first.');
      return;
    }
    final who = _userName.isEmpty ? 'A SafeNav user' : _userName;
    final res = await Emergency.sendAll(
        _contacts, 'TEST from SafeNav: $who is setting up emergency alerts. No action needed.');
    if (!mounted) return;
    _toast(res.sent > 0
        ? 'Test sent to ${res.sent} contact(s).'
        : 'Test failed: ${res.problem ?? 'unknown'}. Check SMS permission and the default SMS SIM.');
  }

  // ---------- UI ----------
  Color _tierColor(int score) => score >= 70
      ? const Color(0xFF2E8B57)
      : score >= 45 ? const Color(0xFFE0A030) : const Color(0xFFD64545);

  Color _tier(ScoredRoute r) => _tierColor(r.score);

  Widget _dot(Color c) => Container(
      decoration: BoxDecoration(color: c, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)));

  /// The chosen route drawn stretch by stretch (green, amber, red). Walked parts turn grey.
  List<Polyline> _routeLines(ScoredRoute sel) {
    final ss = _sset;
    final out = <Polyline>[Polyline(points: sel.raw.points, strokeWidth: 10, color: Colors.white)];
    if (ss == null || ss.stretches.isEmpty) {
      out.add(Polyline(points: sel.raw.points, strokeWidth: 6, color: _tier(sel)));
      return out;
    }
    final ni = (_navigating && _me != null) ? ss.nearestIndex(_me!) : -1;
    for (final st in ss.stretches) {
      final walked = st.to < ni;
      out.add(Polyline(
          points: ss.pointsOf(st),
          strokeWidth: walked ? 4 : 6,
          color: walked ? Colors.grey.withValues(alpha: .6) : _tierColor(st.score)));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final sel = _sel;
    return Scaffold(
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: _me ?? const LatLng(28.4595, 77.0266),
            initialZoom: 14,
            onTap: (_, p) {
              if (!_navigating && _routes.length > 1) {
                for (final r in _routes) {
                  if (r.id != _selId && nearest(p, r.raw.points) <= 40) {
                    setState(() => _selId = r.id);
                    _fit(r);
                    break;
                  }
                }
              }
            },
            onLongPress: (_, p) => _reviewAt(p),
          ),
          children: [
            TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.safenav'), // use your real application id
            PolylineLayer(polylines: [
              for (final r in _routes.where((r) => r.id != _selId))
                Polyline(points: r.raw.points, strokeWidth: 5, color: _tier(r).withValues(alpha: .45)),
              if (sel != null) ..._routeLines(sel),
            ]),
            MarkerLayer(rotate: true, markers: [
              if (_me != null)
                Marker(point: _me!, width: 44, height: 44,
                    child: Stack(alignment: Alignment.center, children: [
                      Container(width: 44, height: 44,
                          decoration: BoxDecoration(color: Colors.blue.withValues(alpha: .18), shape: BoxShape.circle)),
                      SizedBox(width: 20, height: 20, child: _dot(Colors.blue)),
                    ])),
              if (_dest != null)
                Marker(point: _dest!.at, width: 40, height: 40,
                    child: const Icon(Icons.flag_circle, color: Color(0xFF1769C2), size: 36)),
              if (sel != null)
                for (final h in sel.havens)
                  Marker(point: h, width: 30, height: 30, child: const Icon(Icons.local_police, color: Colors.teal)),
              for (final r in _revs)
                Marker(point: r.at, width: 22, height: 22,
                    child: GestureDetector(
                        onTap: () => _showReview(r),
                        child: _dot(r.rating >= 4 ? Colors.green : r.rating <= 2 ? Colors.red : Colors.orange))),
            ]),
            const RichAttributionWidget(attributions: [TextSourceAttribution('© OpenStreetMap contributors')]),
          ],
        ),
        SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: _topBar())),
        // SafeNav Guardian Companion FAB
        Positioned(
          right: 14,
          top: MediaQuery.of(context).size.height * 0.40,
          child: FloatingActionButton.extended(
            heroTag: 'guardianAiMapFab',
            tooltip: 'SafeNav Guardian',
            backgroundColor: AppColors.blue,
            icon: const Icon(Icons.shield_rounded, color: Colors.white, size: 20),
            label: const Text('Guardian', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
            onPressed: _openGuardianChat,
          ),
        ),
        Positioned(
            left: 0, right: 0, bottom: 0,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_advice.isNotEmpty && !_navigating) _guardianAdviceBanner(),
              if (_warning.isNotEmpty) _warningBanner(),
              _busy ? _busyCard() : (sel != null ? (_navigating ? _navCard(sel) : _panel(sel)) : _hint()),
            ])),
      ]),
    );
  }

  Widget _guardianAdviceBanner() => Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: AppColors.blueLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.blue, width: 1.5)),
      child: Row(children: [
        const Icon(Icons.shield_rounded, color: AppColors.blue),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('SafeNav Guardian Advice', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: AppColors.navy)),
              const SizedBox(height: 2),
              Text(_advice, style: const TextStyle(fontSize: 12, color: AppColors.navy)),
            ],
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18, color: AppColors.muted),
          onPressed: () => setState(() => _advice = ''),
        ),
      ]));

  Widget _warningBanner() => Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: const Color(0xFFFFF4E0),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE0A030), width: 1.5)),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: Color(0xFFB36B00)),
        const SizedBox(width: 10),
        Expanded(child: Text(_warning, style: const TextStyle(color: Color(0xFF5A3A00)))),
        if (!_trip.active) TextButton(onPressed: _shareTrip, child: const Text('Share trip')),
      ]));

  Widget _topBar() => Column(children: [
        Row(children: [
          _navigating
              ? const Spacer()
              : Expanded(
                  child: Card(
                      margin: EdgeInsets.zero,
                      child: TextField(
                        controller: _search,
                        textInputAction: TextInputAction.search,
                        onSubmitted: _searchPlaces,
                        decoration: const InputDecoration(
                            hintText: 'Where do you want to go?',
                            prefixIcon: Icon(Icons.search),
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 14)),
                      ))),
          const SizedBox(width: 8),
          FloatingActionButton.small(
              heroTag: 'loc',
              onPressed: () { if (_me != null) _map.move(_me!, 16); },
              child: const Icon(Icons.my_location)),
          const SizedBox(width: 8),
          // tap: options. press and hold: instant 5-second SOS countdown
          Material(
              color: Colors.red,
              shape: const CircleBorder(),
              elevation: 4,
              child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _sos,
                  onLongPress: _sosCountdown,
                  child: const SizedBox(
                      width: 44,
                      height: 44,
                      child: Center(child: Text('SOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)))))),
        ]),
        if (_routes.isEmpty && _results.isEmpty && !_busy && _recent.isNotEmpty)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final p in _recent)
                      Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                              avatar: const Icon(Icons.history, size: 16),
                              label: Text(p.name.split(',').first),
                              onPressed: () => _plan(p))),
                  ]))),
        if (_results.isNotEmpty)
          Card(
              child: Column(children: [
            for (final p in _results)
              ListTile(dense: true, leading: const Icon(Icons.place_outlined), title: Text(p.name), onTap: () => _plan(p)),
          ])),
      ]);

  Widget _hint() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
    child: Card(
      elevation: 3,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Where are you heading?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('Search a destination to compare walking routes by safety, distance and time.', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.touch_app_outlined, size: 18),
            const SizedBox(width: 7),
            Expanded(child: Text('Long-press the map to leave a review.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
          ]),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.sos, size: 18, color: Color(0xFFD93636)),
            const SizedBox(width: 7),
            Expanded(child: Text('Hold SOS for 5 sec, or shake your phone 4 times during navigation.', style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
          ]),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _showMoreOptions,
              icon: const Icon(Icons.grid_view_rounded, size: 18),
              label: const Text('More options'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(40)),
            ),
          ),
        ]),
      ),
    ),
  );

  Widget _busyCard() => Padding(
      padding: const EdgeInsets.all(16),
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(width: 14),
                Expanded(child: Text(_stage)),
              ]))));

  Widget _bar(String label, double? v) {
    final pct = v != null ? (v * 100).round() : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          SizedBox(width: 130, child: Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500))),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: v ?? 0,
                minHeight: 6,
                color: pct != null ? _tierColor(pct) : null,
                backgroundColor: const Color(0xFFE6ECF5),
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              pct == null ? 'no data' : '$pct%',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: pct != null ? _tierColor(pct) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  double _remainingM(ScoredRoute r) {
    final pts = r.raw.points;
    if (_me == null || pts.length < 2) return r.raw.distanceM;
    var bi = 0;
    var bd = double.infinity;
    for (var i = 0; i < pts.length; i++) {
      final d = meters(_me!, pts[i]);
      if (d < bd) {
        bd = d;
        bi = i;
      }
    }
    var rem = bd;
    for (var i = bi; i < pts.length - 1; i++) {
      rem += meters(pts[i], pts[i + 1]);
    }
    return rem;
  }

  /// Opens Google Maps walking directions that follow this route (via waypoints).
  /// Free, no API key. SafeNav stops monitoring once you leave the app.
  Future<void> _openInGoogleMaps(ScoredRoute r) async {
    final pts = r.raw.points;
    if (pts.length < 2) return;
    String ll(LatLng p) => '${p.latitude},${p.longitude}';
    final k = math.min(6, pts.length ~/ 25);
    final via = [for (var i = 1; i <= k; i++) pts[(pts.length - 1) * i ~/ (k + 1)]];
    final uri = Uri.https('www.google.com', '/maps/dir/', {
      'api': '1',
      'origin': ll(_me ?? pts.first),
      'destination': ll(pts.last),
      'travelmode': 'walking',
      if (via.isNotEmpty) 'waypoints': via.map(ll).join('|'),
    });
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) _toast('Could not open Google Maps.');
  }

  /// One line summarising the risky stretches (computed by the scoring engine, no AI needed).
  (String, bool)? _riskLine() {
    final ss = _sset;
    if (ss == null) return null;
    final risky = ss.stretches.where((s) => s.risky && s.confidence >= warnMinConfidence).toList();
    if (risky.isEmpty) return ('No risky stretches detected with the data available.', false);
    final m = risky.fold<int>(0, (a, s) => a + (s.to - s.from + 1) * 25);
    return ('${risky.length} isolated stretch${risky.length == 1 ? '' : 'es'} flagged by available data (about $m m): ${risky.first.reason ?? 'limited safety signals'}.', true);
  }


  Future<void> _showMoreOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final cs = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('More options',
                    style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Trip tools and safety settings',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                const SizedBox(height: 14),
                GridView.count(
                  crossAxisCount: 2,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 2.65,
                  children: [
                    _moreOptionTile(
                      context: sheetContext,
                      icon: _trip.active ? Icons.link_off : Icons.share_outlined,
                      label: _trip.active ? 'Stop sharing' : 'Share trip',
                      onTap: () {
                        Navigator.pop(sheetContext);
                        if (_trip.active) {
                          _stopSharing();
                        } else {
                          _shareTrip();
                        }
                      },
                    ),
                    _moreOptionTile(
                      context: sheetContext,
                      icon: Icons.timer_outlined,
                      label: _guardianEnd == null ? 'Guardian timer' : "I'm safe",
                      onTap: () {
                        Navigator.pop(sheetContext);
                        if (_guardianEnd == null) {
                          _setGuardian();
                        } else {
                          _cancelGuardian();
                        }
                      },
                    ),
                    _moreOptionTile(
                      context: sheetContext,
                      icon: Icons.shield_outlined,
                      label: 'Guardian AI',
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _openGuardianChat();
                      },
                    ),
                    _moreOptionTile(
                      context: sheetContext,
                      icon: _demoMode ? Icons.science : Icons.science_outlined,
                      label: _demoMode ? 'Demo Mode (ON)' : 'Demo Mode (OFF)',
                      onTap: () {
                        setState(() => _demoMode = !_demoMode);
                        Navigator.pop(sheetContext);
                        _toast(_demoMode
                            ? 'Demo Mode ON: Safe emergency simulations (no real calls/SMS).'
                            : 'Demo Mode OFF: Real emergency response active.');
                      },
                    ),
                    _moreOptionTile(
                      context: sheetContext,
                      icon: Icons.privacy_tip_outlined,
                      label: 'Account & Data',
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _accountPrivacyDialog();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest.withValues(alpha: .45),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.vibration, color: Color(0xFFD93636), size: 22),
                      SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Shake for SOS', style: TextStyle(fontWeight: FontWeight.w600)),
                            SizedBox(height: 2),
                            Text('Shake your phone 4 times during navigation.', style: TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: cs.outlineVariant),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SwitchListTile.adaptive(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                    secondary: const Icon(Icons.dark_mode_outlined),
                    title: const Text('Night mode'),
                    subtitle: Text(_sunText()),
                    value: _night,
                    onChanged: (value) {
                      setState(() {
                        _night = value;
                        _nightAuto = false;
                      });
                      _rescore();
                      Navigator.pop(sheetContext);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _moreOptionTile({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surfaceContainerHighest.withValues(alpha: .45),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 21, color: const Color(0xFF1769C2)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel(ScoredRoute r) {
    final sorted = [..._routes]..sort((a, b) => b.score.compareTo(a.score));
    final fastest = _routes.reduce((a, b) => a.raw.durationS <= b.raw.durationS ? a : b);
    final extra = ((r.raw.durationS - fastest.raw.durationS) / 60).round();
    final f = r.factors;
    final risk = _riskLine();
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .60),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(8)))),
                const SizedBox(height: 12),
                Row(children: [
                  const Expanded(child: Text('Route options', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                  Text('${_routes.length} found', style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                ]),
                const SizedBox(height: 10),
                SizedBox(
                  height: 84,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final x in sorted)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () { setState(() => _selId = x.id); _fit(x); },
                            child: Container(
                              width: 142,
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: x.id == _selId ? const Color(0xFFEAF2FF) : cs.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: x.id == _selId ? const Color(0xFF1769C2) : cs.outlineVariant, width: x.id == _selId ? 1.5 : 1),
                              ),
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Row(children: [
                                  Container(width: 9, height: 9, decoration: BoxDecoration(color: _tier(x), shape: BoxShape.circle)),
                                  const SizedBox(width: 6),
                                  Text('${x.score}/100', style: TextStyle(fontWeight: FontWeight.w700, color: _tier(x))),
                                  if (x.id == _selId) ...[const Spacer(), const Icon(Icons.check_circle, size: 16, color: Color(0xFF1769C2))],
                                ]),
                                const Spacer(),
                                Text('${(x.raw.durationS / 60).round()} min · ${(x.raw.distanceM / 1000).toStringAsFixed(1)} km', style: const TextStyle(fontSize: 12)),
                                Text(x.id == _routes.reduce((a,b) => a.score >= b.score ? a : b).id ? 'Highest score' : (x.id == fastest.id ? 'Fastest' : 'Alternative'), style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
                              ]),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text('${r.score}', style: TextStyle(fontSize: 38, height: 1, fontWeight: FontWeight.w700, color: _tier(r))),
                  const Padding(padding: EdgeInsets.only(bottom: 3), child: Text(' / 100 safety score')),
                  const Spacer(),
                  Text('${(r.raw.durationS / 60).round()} min', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ]),
                const SizedBox(height: 3),
                Text('${(r.raw.distanceM / 1000).toStringAsFixed(1)} km${extra > 0 ? ' · $extra min slower than fastest' : ''} · Data confidence ${(r.confidence * 100).round()}%', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                if (_fromCache)
                  const Padding(padding: EdgeInsets.only(top: 6), child: Text('Using saved map data. Some information may be out of date.', style: TextStyle(fontSize: 12))),
                const SizedBox(height: 12),
                const Text('What affects this score?', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 5),
                _bar('Lighting', f.lighting),
                _bar('Active places', f.activity),
                _bar('Help nearby', f.help),
                _bar('Community reviews', f.community),
                if (risk != null)
                  Container(
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: risk.$2 ? const Color(0xFFFFF4E0) : const Color(0xFFEAF6EE), borderRadius: BorderRadius.circular(10)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(risk.$2 ? Icons.info_outline : Icons.check_circle_outline, size: 18, color: risk.$2 ? const Color(0xFF9A6500) : const Color(0xFF287A4B)),
                      const SizedBox(width: 8),
                      Expanded(child: Text(risk.$1.replaceAll('risky stretch', 'isolated stretch').replaceAll('risky stretches', 'isolated stretches'), style: TextStyle(fontSize: 12, color: risk.$2 ? const Color(0xFF704900) : const Color(0xFF236440)))),
                    ]),
                  ),
                if (_advice.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_advice, style: const TextStyle(fontSize: 13))),
                for (final n in r.notes) Padding(padding: const EdgeInsets.only(top: 3), child: Text('• $n', style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant))),
                const SizedBox(height: 12),
                SizedBox(width: double.infinity, child: FilledButton.icon(
                  onPressed: _navigating ? null : _startNav,
                  icon: const Icon(Icons.navigation_outlined),
                  label: Text(_navigating ? 'Navigation starting…' : 'Start safe route'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                )),
                const SizedBox(height: 8),
                Row(children: [
                  const Icon(Icons.dark_mode_outlined, size: 19),
                  const SizedBox(width: 7),
                  const Expanded(child: Text('Night mode')),
                  Switch.adaptive(
                    value: _night,
                    onChanged: (v) { setState(() { _night = v; _nightAuto = false; }); _rescore(); },
                  ),
                ]),
                Text(_sunText(), style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 4),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _startNav(demo: true),
                      icon: const Icon(Icons.play_circle_outline, size: 19),
                      label: const Text('Demo walk', maxLines: 1, overflow: TextOverflow.ellipsis),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _reviewAt(_me),
                      icon: const Icon(Icons.rate_review_outlined, size: 19),
                      label: const Text('Review spot', maxLines: 1, overflow: TextOverflow.ellipsis),
                      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _showMoreOptions,
                    icon: const Icon(Icons.grid_view_rounded, size: 18),
                    label: const Text('More options'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(42),
                      alignment: Alignment.center,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _navCard(ScoredRoute r) {
    final steps = r.raw.steps;
    final step = steps.isEmpty ? null : steps[_stepIdx.clamp(0, steps.length - 1).toInt()];
    final rem = _remainingM(r);
    final mins = (rem / _speed(r) / 60).ceil();
    final toStep = (step != null && _me != null) ? meters(_me!, step.at) : 0.0;
    final gEnd = _guardianEnd;
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: cs.surface,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .48),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: cs.outlineVariant, borderRadius: BorderRadius.circular(8)))),
              const SizedBox(height: 12),
              if (step != null) ...[
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0xFFEAF2FF), borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.turn_right, color: Color(0xFF1769C2), size: 26)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(step.text, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text('In ${_fmt(toStep)}', style: TextStyle(color: cs.onSurfaceVariant)),
                  ])),
                ]),
                const SizedBox(height: 12),
              ],
              Row(children: [
                const Icon(Icons.shield_outlined, color: Color(0xFF1769C2), size: 19),
                const SizedBox(width: 6),
                Text('Safety ${r.score}/100', style: TextStyle(fontWeight: FontWeight.w700, color: _tier(r))),
                const Spacer(),
                Text('${_fmt(rem)} · $mins min left', style: const TextStyle(fontWeight: FontWeight.w600)),
              ]),
              if (_warning.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: _warningBanner()),
              if (_demoMode) const Padding(padding: EdgeInsets.only(top: 5), child: Text('Demo walk · simulated location', style: TextStyle(fontSize: 12))),
              const SizedBox(height: 10),
              Wrap(spacing: 7, runSpacing: 4, children: [
                ActionChip(avatar: const Icon(Icons.share_outlined, size: 17), label: Text(_trip.active ? 'Stop sharing' : 'Share trip'), onPressed: _trip.active ? _stopSharing : _shareTrip),
                ActionChip(avatar: const Icon(Icons.place_outlined, size: 17), label: const Text('Nearest safe place'), onPressed: _safePlace),
                ActionChip(avatar: const Icon(Icons.flag_outlined, size: 17), label: const Text('Report'), onPressed: _quickReport),
                ActionChip(avatar: const Icon(Icons.timer_outlined, size: 17), label: Text(gEnd == null ? 'Guardian timer' : "I'm safe · ${_mmss(gEnd.difference(DateTime.now()))}"), onPressed: gEnd == null ? _setGuardian : _cancelGuardian),
                ActionChip(avatar: const Icon(Icons.explore_outlined, size: 17), label: Text(_headingUp ? 'Heading up' : 'North up'), onPressed: () { setState(() => _headingUp = !_headingUp); if (!_headingUp) _map.rotate(0); }),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD93636), foregroundColor: Colors.white, minimumSize: const Size.fromHeight(46)), onPressed: _stopNav, icon: const Icon(Icons.stop), label: const Text('End trip'))),
                const SizedBox(width: 8),
                Expanded(child: OutlinedButton.icon(onPressed: () => _openInGoogleMaps(r), icon: const Icon(Icons.open_in_new), label: const Text('Open Maps'), style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)))),
              ]),
              if (_demoMode) Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _checkIn, child: const Text('Test safety check-in'))),
            ]),
          ),
        ),
      ),
    );
  }

}

// ---------- dialogs ----------
class ReviewDraft {
  final int rating;
  final List<String> tags;
  final String text;
  ReviewDraft(this.rating, this.tags, this.text);
}

Future<ReviewDraft?> showReviewForm(BuildContext context, String title) =>
    showDialog<ReviewDraft>(context: context, builder: (_) => _ReviewForm(title));

class _ReviewForm extends StatefulWidget {
  final String title;
  const _ReviewForm(this.title);
  @override
  State<_ReviewForm> createState() => _ReviewFormState();
}

class _ReviewFormState extends State<_ReviewForm> {
  int rating = 0;
  final tags = <String>{};
  final text = TextEditingController();

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 1; i <= 5; i++)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    icon: Icon(
                      i <= rating ? Icons.star_rounded : Icons.star_border_rounded,
                      color: Colors.orange,
                      size: 36,
                    ),
                    onPressed: () => setState(() => rating = i),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in reviewTags)
              FilterChip(
                  label: Text(t.replaceAll('_', ' ')),
                  selected: tags.contains(t),
                  onSelected: (v) => setState(() { if (v) { tags.add(t); } else { tags.remove(t); } })),
          ]),
          const SizedBox(height: 10),
          TextField(
              controller: text,
              maxLength: 280,
              maxLines: 3,
              decoration: const InputDecoration(hintText: 'Anything others should know? (optional)')),
        ])),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: rating == 0 ? null : () => Navigator.pop(context, ReviewDraft(rating, tags.toList(), text.text)),
              child: const Text('Submit')),
        ],
      );
}

class _CheckInDialog extends StatefulWidget {
  final String reason;
  const _CheckInDialog(this.reason);
  @override
  State<_CheckInDialog> createState() => _CheckInState();
}

class _CheckInState extends State<_CheckInDialog> {
  int left = 20;
  Timer? t;

  @override
  void initState() {
    super.initState();
    t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (--left <= 0) {
        t?.cancel();
        Navigator.pop(context, false);
      } else {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Are you okay?'),
        content: Text('${widget.reason} With no reply in $left s, SafeNav alerts your contacts.'),
        actions: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text("I'm okay"))],
      );
}

class _SosCountdown extends StatefulWidget {
  const _SosCountdown();
  @override
  State<_SosCountdown> createState() => _SosCountdownState();
}

class _SosCountdownState extends State<_SosCountdown> {
  int left = 5;
  Timer? t;

  @override
  void initState() {
    super.initState();
    t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (--left <= 0) {
        t?.cancel();
        Navigator.pop(context, true);
      } else {
        Voice.alert();
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: const Color(0xFFFFE9E9),
        title: const Text('Sending SOS…', style: TextStyle(color: Colors.black87)),
        content: Text('$left',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w800, color: Colors.red)),
        actions: [FilledButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel, I'm fine"))],
      );
}

/// Compass bearing in degrees (0 = north) from a to b.
double bearingDeg(LatLng a, LatLng b) {
  double r(double d) => d * math.pi / 180;
  final y = math.sin(r(b.longitude - a.longitude)) * math.cos(r(b.latitude));
  final x = math.cos(r(a.latitude)) * math.sin(r(b.latitude)) -
      math.sin(r(a.latitude)) * math.cos(r(b.latitude)) * math.cos(r(b.longitude - a.longitude));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}
