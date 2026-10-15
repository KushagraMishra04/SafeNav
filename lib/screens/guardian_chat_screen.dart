import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../theme/app_theme.dart';
import '../services/agent_client.dart';
import '../services/safety_engine.dart';
import '../services/voice.dart';

class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime time;
  final List<String> suggestions;
  final String? actionType; // 'safe_place', 'share_trip', 'call_112', etc.
  final List<Place> attachedPlaces;

  ChatMessage({
    required this.text,
    required this.isUser,
    required this.time,
    this.suggestions = const [],
    this.actionType,
    this.attachedPlaces = const [],
  });
}

class GuardianChatScreen extends StatefulWidget {
  final LatLng? currentLocation;
  final String? currentRouteSummary;
  final int? currentRouteScore;

  const GuardianChatScreen({
    super.key,
    this.currentLocation,
    this.currentRouteSummary,
    this.currentRouteScore,
  });

  @override
  State<GuardianChatScreen> createState() => _GuardianChatScreenState();
}

class _GuardianChatScreenState extends State<GuardianChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _agent = AgentClient();
  final _voice = Voice();
  final List<ChatMessage> _messages = [];
  bool _thinking = false;
  bool _ttsEnabled = true;
  LatLng? _userLocation;

  final List<String> _quickPrompts = [
    'Is this area safe at 11 PM?',
    'Take me somewhere safe now',
    'Explain my route safety score',
    'Summarize recent reports nearby',
    'Find nearest police station or hospital',
  ];

  @override
  void initState() {
    super.initState();
    _userLocation = widget.currentLocation;
    if (_userLocation == null) {
      _initLocation();
    }
    // Welcome message explaining role & guardrails
    _messages.add(ChatMessage(
      text: 'Hello, I am SafeNav Guardian — your AI safety companion. '
          'I monitor route conditions, check street lighting, crowd signals, and safe havens. '
          'How can I help you feel more secure on your journey?',
      isUser: false,
      time: DateTime.now(),
      suggestions: [
        'Is this area safe at 11 PM?',
        'Take me somewhere safe now',
      ],
    ));
  }

  Future<void> _initLocation() async {
    try {
      final pos = await Geolocator.getLastKnownPosition();
      if (pos != null && mounted) {
        setState(() => _userLocation = LatLng(pos.latitude, pos.longitude));
      } else {
        final current = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium, timeLimit: Duration(seconds: 4)),
        );
        if (mounted) setState(() => _userLocation = LatLng(current.latitude, current.longitude));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage(String text) async {
    final query = text.trim();
    if (query.isEmpty) return;

    _controller.clear();
    setState(() {
      _messages.add(ChatMessage(
        text: query,
        isUser: true,
        time: DateTime.now(),
      ));
      _thinking = true;
    });
    _scrollToBottom();

    // Call the server-side Guardian agent (with local fallback if offline)
    final reply = await _agent.chat(
      message: query,
      currentLocation: _userLocation ?? widget.currentLocation,
      routeSummary: widget.currentRouteSummary,
      routeScore: widget.currentRouteScore,
    );

    if (!mounted) return;

    setState(() {
      _thinking = false;
      _messages.add(ChatMessage(
        text: reply.text,
        isUser: false,
        time: DateTime.now(),
        suggestions: reply.followUps,
        actionType: reply.actionType,
        attachedPlaces: reply.attachedPlaces,
      ));
    });
    _scrollToBottom();

    if (_ttsEnabled) {
      _voice.say(reply.text.replaceAll(RegExp(r'[*_#]'), ''));
    }
  }

  void _handleAction(String actionType) {
    switch (actionType) {
      case 'safe_place':
      case 'police':
      case 'hospital':
        Navigator.pop(context, 'find_safe_place');
        break;
      case 'call_112':
        Navigator.pop(context, 'call_112');
        break;
      case 'share_trip':
        Navigator.pop(context, 'share_trip');
        break;
      default:
        break;
    }
  }

  void _onPlaceSelected(Place p) {
    Navigator.pop(context, SafePlaceNavRequest(p, autoStart: true));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppColors.blue.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.shield_rounded, color: AppColors.blue, size: 22),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: AppColors.green,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 1.5),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 10),
            const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('SafeNav Guardian', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Text('Active AI Safety Companion', style: TextStyle(fontSize: 11, color: AppColors.muted)),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _ttsEnabled ? 'Mute voice replies' : 'Enable voice replies',
            icon: Icon(_ttsEnabled ? Icons.volume_up : Icons.volume_off),
            onPressed: () => setState(() => _ttsEnabled = !_ttsEnabled),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Guardrail banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              color: Colors.amber.shade50,
              child: Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.amber.shade900),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Guardian provides risk estimates based on community reports & street data. In an emergency, call 112.',
                      style: TextStyle(fontSize: 11, color: Colors.amber.shade900),
                    ),
                  ),
                ],
              ),
            ),

            // Message stream
            Expanded(
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.all(16),
                itemCount: _messages.length,
                itemBuilder: (context, index) {
                  final m = _messages[index];
                  return _MessageBubble(
                    message: m,
                    onAction: _handleAction,
                    onSuggestionTap: _sendMessage,
                    onPlaceSelected: _onPlaceSelected,
                  );
                },
              ),
            ),

            if (_thinking)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.blue),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'Guardian is checking safety signals…',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),

            // Quick suggestion chips
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: _quickPrompts.map((p) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ActionChip(
                      label: Text(p, style: const TextStyle(fontSize: 12)),
                      backgroundColor: AppColors.blueLight,
                      side: BorderSide(color: AppColors.blue.withValues(alpha: 0.3)),
                      onPressed: () => _sendMessage(p),
                    ),
                  );
                }).toList(),
              ),
            ),

            // Input bar
            Container(
              padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    offset: const Offset(0, -2),
                    blurRadius: 6,
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      textInputAction: TextInputAction.send,
                      onSubmitted: _sendMessage,
                      decoration: InputDecoration(
                        hintText: 'Ask Guardian (e.g. Is this road well-lit?)',
                        hintStyle: const TextStyle(fontSize: 14),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(color: AppColors.cardBorder),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    style: IconButton.styleFrom(backgroundColor: AppColors.blue, foregroundColor: Colors.white),
                    icon: const Icon(Icons.send_rounded, size: 20),
                    onPressed: () => _sendMessage(_controller.text),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final void Function(String) onAction;
  final void Function(String) onSuggestionTap;
  final void Function(Place) onPlaceSelected;

  const _MessageBubble({
    required this.message,
    required this.onAction,
    required this.onSuggestionTap,
    required this.onPlaceSelected,
  });

  @override
  Widget build(BuildContext context) {
    final isUser = message.isUser;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!isUser) ...[
                CircleAvatar(
                  radius: 14,
                  backgroundColor: AppColors.blue.withValues(alpha: 0.15),
                  child: const Icon(Icons.shield_outlined, size: 16, color: AppColors.blue),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: isUser ? AppColors.blue : Colors.grey.shade100,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isUser ? 16 : 4),
                      bottomRight: Radius.circular(isUser ? 4 : 16),
                    ),
                    border: isUser ? null : Border.all(color: Colors.grey.shade300),
                  ),
                  child: Text(
                    message.text,
                    style: TextStyle(
                      color: isUser ? Colors.white : AppColors.navy,
                      fontSize: 14,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ],
          ),

          // Attached safe haven cards with 1-tap route & navigation
          if (message.attachedPlaces.isNotEmpty) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: message.attachedPlaces.map((p) {
                  final lower = p.name.toLowerCase();
                  final isPolice = lower.contains('police');
                  final isHospital = lower.contains('hospital') || lower.contains('clinic');
                  final icon = isPolice
                      ? Icons.local_police_rounded
                      : (isHospital ? Icons.local_hospital_rounded : Icons.shield_rounded);
                  final badgeColor = isPolice ? AppColors.blue : (isHospital ? Colors.redAccent : Colors.teal);
                  final nameParts = p.name.split('·');
                  final title = nameParts.first.trim();
                  final dist = nameParts.length > 1 ? nameParts[1].trim() : 'Nearby';

                  return Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: badgeColor.withValues(alpha: 0.35), width: 1.2),
                      boxShadow: [
                        BoxShadow(
                          color: badgeColor.withValues(alpha: 0.08),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Material(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => onPlaceSelected(p),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: badgeColor.withValues(alpha: 0.12),
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(icon, color: badgeColor, size: 20),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          title,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.navy,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Row(
                                          children: [
                                            Text(
                                              dist,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                color: badgeColor,
                                              ),
                                            ),
                                            const Text(' • ', style: TextStyle(color: AppColors.muted, fontSize: 11)),
                                            const Text(
                                              'Verified 24/7 Haven',
                                              style: TextStyle(color: AppColors.muted, fontSize: 11),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: badgeColor,
                                    foregroundColor: Colors.white,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                    padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
                                  ),
                                  icon: const Icon(Icons.navigation_rounded, size: 16),
                                  label: const Text(
                                    'Start Route & Navigate',
                                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                                  ),
                                  onPressed: () => onPlaceSelected(p),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],

          // Action shortcut fallback if no attached cards
          if (message.actionType != null && message.attachedPlaces.isEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.local_police_outlined, size: 18),
                label: const Text('Open Nearest Safe Places'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.blue,
                  side: const BorderSide(color: AppColors.blue),
                ),
                onPressed: () => onAction(message.actionType!),
              ),
            ),
          ],

          // Follow-up suggestion pills
          if (message.suggestions.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 36),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: message.suggestions.map((s) {
                  return InkWell(
                    onTap: () => onSuggestionTap(s),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        border: Border.all(color: AppColors.blue.withValues(alpha: 0.4)),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '💡 $s',
                        style: const TextStyle(fontSize: 11, color: AppColors.blue, fontWeight: FontWeight.w500),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
