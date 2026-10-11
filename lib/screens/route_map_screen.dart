import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/agent_client.dart';
import '../services/review_service.dart';
import '../services/safety_engine.dart';
import '../services/shake_detector.dart';
import '../services/stretch_engine.dart';
import '../services/trip_share.dart';
import '../services/voice.dart';

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
  int _stepIdx = 0;
  Timer? _demo;
  bool _demoMode = false;
  double _maxDetour = 1.4;
  final _voice = Voice();
  final _trip = TripShare();
  late final ShakeDetector _shake = ShakeDetector(_onShake);
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
  }

  @override
  void dispose() {
    _sub?.cancel();
    _demo?.cancel();
    _warnTimer?.cancel();
    _gTicker?.cancel();
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
    setState(() => _me = LatLng(p.latitude, p.longitude));
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
  Future<void> _plan(Place d, {bool quick = false}) async {
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
      _raws = await _engine.candidateRoutes(_me!, d.at, quick: quick);
      if (_raws.isEmpty) throw 'No walking route found for this destination.';
      final all = _raws.expand((r) => r.points).toList();
      setState(() => _stage = 'Reading street lighting, shops and help points…');
      _osm = await _engine.osm(all);
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
      unawaited(_trip.update(_me!, dest: d.name, force: true));
      _fit(best);
      _advice = _localAdvice(best);
      if (!quick) _askAgent(null);
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
    setState(() => _advice = a.explanation + (a.tips.isEmpty ? '' : '\n${a.tips.map((t) => '• $t').join('\n')}'));
    return true;
  }

  Future<void> _askDialog() async {
    final c = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Ask SafeNav AI'),
        content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'e.g. I am alone and want busy, well-lit streets')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Ask')),
        ],
      ),
    );
    if (msg == null || msg.trim().isEmpty) return;
    final ok = await _askAgent(msg);
    if (!ok) _toast('Cloud AI is not connected, so the built-in assistant was used.');
  }

  // ---------- nearby help, contacts, offline assistant ----------
  Future<void> _nearby(String kind) async {
    if (_me == null) {
      _toast('Waiting for your location…');
      return;
    }
    final r = await _engine.nearbyPlaces(_me!, kind);
    if (!mounted) return;
    setState(() => _results = r);
    if (r.isEmpty) _toast('Nothing found within 5 km, or the map data service is busy. Try again.');
  }

  Future<void> _loadContacts() async {
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getStringList('sos_contacts') ?? [];
    if (mounted) setState(() => _contacts = {...widget.contacts, ...saved}.toList());
  }

  Future<void> _editContacts() async {
    final c = TextEditingController(text: _contacts.join(', '));
    final v = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Emergency contacts'),
        content: TextField(
            controller: c,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(hintText: 'Phone numbers, separated by commas')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Save')),
        ],
      ),
    );
    if (v == null) return;
    final list = v
        .split(RegExp(r'[,;\n]+'))
        .map((x) => x.replaceAll(RegExp(r'[^0-9+]'), ''))
        .where((x) => x.length >= 8)
        .toList();
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList('sos_contacts', list);
    if (mounted) setState(() => _contacts = list);
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
          heading: (p.speed > 0.5 && p.heading >= 0) ? p.heading : null));
    }
  }

  Future<void> _stopNav({String trip = 'stopped'}) async {
    _demo?.cancel();
    _demo = null;
    final s = _sub;
    _sub = null;
    _shake.stop();
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

  void _onLoc(LatLng here, {double? heading}) {
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
    if (off > 150 || DateTime.now().difference(_lastMove).inMinutes >= 4) {
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
      _sos(auto: true);
    }
  }

  Future<void> _finish() async {
    final dest = _dest?.name ?? 'my destination';
    final route = _sel;
    await _stopNav(trip: 'arrived');
    Voice.alert();
    _voice.say('You have arrived.');
    if (!mounted) return;
    final d = await showReviewForm(context, 'You arrived. How safe did this route feel?');
    if (d != null && route != null) {
      try {
        final online = await _reviews.addForTrip(
            points: route.raw.points, rating: d.rating, tags: d.tags, text: d.text, tripId: _tripId);
        _toast(online
            ? 'Thanks. Your feedback now helps score this route for others.'
            : 'Thanks. Saved on this device (cloud sync is not set up yet).');
      } catch (e) {
        _toast('Could not save feedback: $e');
      }
    }
    if (_contacts.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 10),
          content: const Text('Let your contacts know you arrived?'),
          action: SnackBarAction(
              label: 'Message', onPressed: () => Sos.sms(_contacts, "I've arrived safely at $dest."))));
    }
  }

  // ---------- guardian timer ----------
  String _mmss(Duration d) {
    final s = d.inSeconds < 0 ? 0 : d.inSeconds;
    return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Future<void> _setGuardian() async {
    final r = _sel;
    final eta = r == null ? null : (r.raw.durationS / 60).ceil() + 10;
    final mins = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(title: const Text('Guardian timer'), children: [
        const Padding(
            padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('If you do not tap "I\'m safe" in time, SafeNav asks if you are okay, then alerts your contacts.')),
        for (final m in <int>[15, 30, 45, 60, if (eta != null) eta])
          SimpleDialogOption(
              onPressed: () => Navigator.pop(context, m),
              child: Text(m == eta ? '$m min (trip time + 10)' : '$m min')),
      ]),
    );
    if (mins == null) return;
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
  void _onShake() {
    if (_navigating) _sosCountdown();
  }

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
    if (me == null) return;
    _toast('Looking for the nearest help…');
    final res = await Future.wait([_engine.nearbyPlaces(me, 'police'), _engine.nearbyPlaces(me, 'hospital')]);
    final all = [...res[0], ...res[1]]..sort((a, b) => meters(me, a.at).compareTo(meters(me, b.at)));
    if (!mounted) return;
    if (all.isEmpty) {
      _toast('No police station or hospital found within 5 km.');
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

  Future<void> _sos({bool auto = false}) async {
    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 4));
    } catch (_) {
      try {
        pos = await Geolocator.getLastKnownPosition();
      } catch (_) {}
    }
    final at = pos != null ? LatLng(pos.latitude, pos.longitude) : _me;
    unawaited(_trip.setStatus('sos', at: at)); // the live tracking page turns red
    if (auto && _contacts.isNotEmpty) await Sos.message(_contacts, pos);
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Emergency'),
        content: Text(auto
            ? 'SOS raised. If you shared your trip, your contacts can see it now. Call 112 if you need help right away.'
            : (_contacts.isEmpty
                ? 'No emergency contacts saved yet. Add some, or call 112.'
                : 'Send your live location to ${_contacts.length} contact(s)?')),
        actions: [
          if (_contacts.isNotEmpty)
            FilledButton(
                onPressed: () { Sos.message(_contacts, pos); Navigator.pop(context); },
                child: const Text('Message contacts')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () { Sos.call112(); Navigator.pop(context); },
              child: const Text('Call 112')),
          TextButton(
              onPressed: () { Navigator.pop(context); _editContacts(); },
              child: Text(_contacts.isEmpty ? 'Add contacts' : 'Edit contacts')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        ],
      ),
    );
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
            onLongPress: (_, p) => _reviewAt(p),
          ),
          children: [
            TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.safenav', // use your real application id
                ),
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
                    child: const Icon(Icons.flag_circle, color: Color(0xFF6C3FDB), size: 36)),
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
        Positioned(
            left: 0, right: 0, bottom: 0,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_warning.isNotEmpty) _warningBanner(),
              _busy ? _busyCard() : (sel != null ? (_navigating ? _navCard(sel) : _panel(sel)) : _hint()),
            ])),
      ]),
    );
  }

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
        if (_routes.isEmpty && _results.isEmpty && !_busy)
          Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    for (final c in const [('Police stations', 'police'), ('Hospitals', 'hospital'), ('Metro / rail', 'station')])
                      Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ActionChip(
                              avatar: const Icon(Icons.near_me, size: 16),
                              label: Text(c.$1),
                              onPressed: () => _nearby(c.$2))),
                  ]))),
        if (_results.isNotEmpty)
          Card(
              child: Column(children: [
            for (final p in _results)
              ListTile(dense: true, leading: const Icon(Icons.place_outlined), title: Text(p.name), onTap: () => _plan(p)),
          ])),
      ]);

  Widget _hint() => const Padding(
      padding: EdgeInsets.all(16),
      child: Card(
          child: Padding(
              padding: EdgeInsets.all(14),
              child: Text('Search a destination to find the safest walking route.\n'
                  'Long-press the map near you to review a spot.\n'
                  'Hold SOS for an instant 5-second alert. While navigating, shaking the phone 4 times does the same.'))));

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

  Widget _bar(String label, double? v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        SizedBox(width: 130, child: Text(label, style: const TextStyle(fontSize: 13))),
        Expanded(child: LinearProgressIndicator(value: v ?? 0, minHeight: 6, borderRadius: BorderRadius.circular(4))),
        SizedBox(width: 56, child: Text(v == null ? 'no data' : '${(v * 100).round()}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12))),
      ]));

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
    return ('${risky.length} risky stretch${risky.length == 1 ? '' : 'es'} (about $m m): ${risky.first.reason ?? 'low safety signals'}.', true);
  }

  Widget _navCard(ScoredRoute r) {
    final steps = r.raw.steps;
    final step = steps.isEmpty ? null : steps[_stepIdx.clamp(0, steps.length - 1).toInt()];
    final rem = _remainingM(r);
    final mins = (rem / _speed(r) / 60).ceil();
    final toStep = (step != null && _me != null) ? meters(_me!, step.at) : 0.0;
    final gEnd = _guardianEnd;
    return Material(
        elevation: 12,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: SafeArea(
            top: false,
            child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.5),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (step != null) ...[
                        Text(step.text, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                        Text('in ${_fmt(toStep)}', style: Theme.of(context).textTheme.bodyMedium),
                        const SizedBox(height: 10),
                      ],
                      Row(children: [
                        Text('${_fmt(rem)} left · $mins min'),
                        const Spacer(),
                        Text('Safety ${r.score}/100', style: TextStyle(color: _tier(r), fontWeight: FontWeight.w700)),
                      ]),
                      if (_demoMode) Text('Demo walk: simulated GPS', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, children: [
                        ActionChip(
                            avatar: const Icon(Icons.share_location, size: 18),
                            label: Text(_trip.active ? 'Stop sharing' : 'Share trip'),
                            onPressed: _trip.active ? _stopSharing : _shareTrip),
                        ActionChip(
                            avatar: const Icon(Icons.local_police, size: 18),
                            label: const Text('Safe place'),
                            onPressed: _safePlace),
                        ActionChip(
                            avatar: const Icon(Icons.timer, size: 18),
                            label: Text(gEnd == null ? 'Guardian timer' : "I'm safe · ${_mmss(gEnd.difference(DateTime.now()))}"),
                            onPressed: gEnd == null ? _setGuardian : _cancelGuardian),
                        ActionChip(
                            avatar: Icon(_voice.enabled ? Icons.volume_up : Icons.volume_off, size: 18),
                            label: const Text('Voice'),
                            onPressed: () => setState(() => _voice.enabled = !_voice.enabled)),
                        ActionChip(
                            avatar: const Icon(Icons.explore, size: 18),
                            label: Text(_headingUp ? 'Heading up' : 'North up'),
                            onPressed: () {
                              setState(() => _headingUp = !_headingUp);
                              if (!_headingUp) _map.rotate(0);
                            }),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: FilledButton.icon(
                                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                                onPressed: _stopNav,
                                icon: const Icon(Icons.stop),
                                label: const Text('Stop'))),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: () => _openInGoogleMaps(r), child: const Text('Google Maps')),
                      ]),
                      if (_demoMode) TextButton(onPressed: _checkIn, child: const Text('Test safety check-in')),
                    ])))));
  }

  Widget _panel(ScoredRoute r) {
    final sorted = [..._routes]..sort((a, b) => b.score.compareTo(a.score));
    final fastest = _routes.reduce((a, b) => a.raw.durationS <= b.raw.durationS ? a : b);
    final extra = ((r.raw.durationS - fastest.raw.durationS) / 60).round();
    final f = r.factors;
    final risk = _riskLine();
    return Material(
        elevation: 12,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: SafeArea(
            top: false,
            child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.62),
                child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                      SizedBox(
                          height: 44,
                          child: ListView(scrollDirection: Axis.horizontal, children: [
                            for (final x in sorted)
                              Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                      label: Text('${x.score} · ${(x.raw.durationS / 60).round()} min'),
                                      selected: x.id == _selId,
                                      selectedColor: _tier(x).withValues(alpha: .25),
                                      onSelected: (_) {
                                        setState(() => _selId = x.id);
                                        _fit(x);
                                      })),
                          ])),
                      const SizedBox(height: 8),
                      Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${r.score}', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: _tier(r))),
                        const Text(' / 100'),
                        const Spacer(),
                        Text('${(r.raw.distanceM / 1000).toStringAsFixed(1)} km · ${(r.raw.durationS / 60).round()} min${extra > 0 ? ' (+$extra)' : ''}'),
                      ]),
                      Text('Data confidence ${(r.confidence * 100).round()}%', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 6),
                      _bar('Lighting', f.lighting),
                      _bar('Active places', f.activity),
                      _bar('Help nearby', f.help),
                      _bar('Community reviews', f.community),
                      if (risk != null)
                        Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(risk.$1,
                                style: TextStyle(color: _tierColor(risk.$2 ? 20 : 80), fontWeight: FontWeight.w600))),
                      if (_advice.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_advice)),
                      for (final n in r.notes) Text('• $n', style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                            child: FilledButton.icon(
                                onPressed: _navigating ? null : _startNav,
                                icon: const Icon(Icons.navigation),
                                label: Text(_navigating ? 'Navigating…' : 'Start safe navigation'))),
                        const SizedBox(width: 8),
                        OutlinedButton(onPressed: _askDialog, child: const Text('Ask AI')),
                      ]),
                      Row(children: [
                        const Text('Night'),
                        Switch(value: _night, onChanged: (v) { _night = v; _rescore(); }),
                        const Spacer(),
                        TextButton(onPressed: () => _startNav(demo: true), child: const Text('Demo walk')),
                        TextButton(onPressed: () => _reviewAt(_me), child: const Text('Review here')),
                      ]),
                      Wrap(spacing: 8, children: [
                        ActionChip(
                            avatar: const Icon(Icons.share_location, size: 18),
                            label: Text(_trip.active ? 'Stop sharing' : 'Share trip'),
                            onPressed: _trip.active ? _stopSharing : _shareTrip),
                        ActionChip(
                            avatar: const Icon(Icons.timer, size: 18),
                            label: Text(_guardianEnd == null ? 'Guardian timer' : "I'm safe · ${_mmss(_guardianEnd!.difference(DateTime.now()))}"),
                            onPressed: _guardianEnd == null ? _setGuardian : _cancelGuardian),
                      ]),
                    ])))));
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
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 1; i <= 5; i++)
              IconButton(
                  icon: Icon(i <= rating ? Icons.star : Icons.star_border, color: Colors.orange),
                  onPressed: () => setState(() => rating = i)),
          ]),
          Wrap(spacing: 6, children: [
            for (final t in reviewTags)
              FilterChip(
                  label: Text(t.replaceAll('_', ' ')),
                  selected: tags.contains(t),
                  onSelected: (v) => setState(() { if (v) { tags.add(t); } else { tags.remove(t); } })),
          ]),
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
