import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class SOSScreen extends StatefulWidget {
  const SOSScreen({super.key});

  @override
  State<SOSScreen> createState() => _SOSScreenState();
}

class _SOSScreenState extends State<SOSScreen> {
  int _stage = 0; // 0 = SOS triggered, 1 = alert sent, 2 = help on the way

  @override
  void initState() {
    super.initState();
    _advance();
  }

  Future<void> _advance() async {
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    setState(() => _stage = 1);
    await Future.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    setState(() => _stage = 2);
  }

  void _continueJourney() {
    AppState.instance.routeRecalculations++;
    Navigator.pop(context); // back to navigation ("recalculate safe route")
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.redLight,
      appBar: AppBar(
        backgroundColor: AppColors.redLight,
        title: const Text('Emergency Response'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 8, total: 13, label: 'Danger detected — responding'),
              const SizedBox(height: 22),
              _TimelineTile(
                active: _stage >= 0,
                done: _stage > 0,
                color: AppColors.red,
                icon: Icons.sos_rounded,
                title: 'Auto SOS Triggered',
                subtitle: 'Automatic alert with live location',
              ),
              _TimelineConnector(done: _stage > 0),
              _TimelineTile(
                active: _stage >= 1,
                done: _stage > 1,
                color: AppColors.red,
                icon: Icons.groups_2_outlined,
                title: 'Alert Sent To',
                subtitle: '3 Emergency Contacts + Nearest Authorities',
              ),
              _TimelineConnector(done: _stage > 1),
              _TimelineTile(
                active: _stage >= 2,
                done: false,
                color: AppColors.green,
                icon: Icons.health_and_safety_outlined,
                title: 'Help On The Way',
                subtitle: 'Guidance to nearest safe haven / help',
              ),
              const Spacer(),
              if (_stage == 2) ...[
                StepCard(
                  borderColor: AppColors.green,
                  child: Row(
                    children: const [
                      Icon(Icons.check_circle, color: AppColors.green),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'You are safe. Authorities and your contacts have been notified with your live location.',
                          style: TextStyle(
                              color: AppColors.navy,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style:
                        ElevatedButton.styleFrom(backgroundColor: AppColors.green),
                    onPressed: _continueJourney,
                    icon: const Icon(Icons.alt_route),
                    label: const Text('I\'m Safe — Recalculate Route & Continue'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelineTile extends StatelessWidget {
  final bool active;
  final bool done;
  final Color color;
  final IconData icon;
  final String title;
  final String subtitle;

  const _TimelineTile({
    required this.active,
    required this.done,
    required this.color,
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: active ? color : Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: color, width: 2),
          ),
          child: Icon(
            done ? Icons.check : icon,
            color: active ? Colors.white : color,
            size: 20,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: active ? AppColors.navy : Colors.grey)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: TextStyle(
                        color: active
                            ? AppColors.navy.withOpacity(0.6)
                            : Colors.grey)),
                if (active && !done)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: AppColors.red),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TimelineConnector extends StatelessWidget {
  final bool done;
  const _TimelineConnector({required this.done});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 21),
      child: Container(
        width: 2,
        height: 30,
        color: done ? AppColors.red : Colors.grey.shade300,
      ),
    );
  }
}
