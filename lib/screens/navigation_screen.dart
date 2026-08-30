import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';
import '../widgets/route_map_painter.dart';

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;
  Timer? _monitorTimer;
  int _secondsMonitored = 0;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _monitorTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _secondsMonitored++);
    });
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _monitorTimer?.cancel();
    super.dispose();
  }

  void _simulateDanger() {
    AppState.instance.sosAlertsTriggered++;
    Navigator.pushNamed(context, '/sos');
  }

  void _arrived() {
    Navigator.pushReplacementNamed(context, '/journeyend');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Safe Navigation')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 7, total: 13, label: 'Real-time monitoring active'),
              const SizedBox(height: 16),

              // --- Mock live map ---
              StepCard(
                borderColor: AppColors.green,
                padding: const EdgeInsets.all(10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    height: 220,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: RouteMapPainter(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // --- Safety metrics card ---
              StepCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.insights, color: AppColors.purple),
                        const SizedBox(width: 8),
                        const Text(
                          'Live Safety Metrics',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.navy,
                              fontSize: 15),
                        ),
                        const Spacer(),
                        _MonitorPulse(controller: _pulseController),
                      ],
                    ),
                    const Divider(height: 26),
                    _MetricRow(
                        icon: Icons.shield_outlined,
                        label: 'Safety Score',
                        value: '${state.safetyScore}%',
                        color: AppColors.green),
                    _MetricRow(
                        icon: Icons.groups_outlined,
                        label: 'Crowd Confidence',
                        value: state.crowdConfidence > 80 ? 'High' : 'Medium',
                        color: AppColors.blue),
                    _MetricRow(
                        icon: Icons.light_mode_outlined,
                        label: 'Lighting Confidence',
                        value: state.lightingConfidence > 80 ? 'High' : 'Medium',
                        color: AppColors.orange),
                    _MetricRow(
                        icon: Icons.support_agent_outlined,
                        label: 'Help Availability',
                        value: state.helpAvailability,
                        color: AppColors.purple),
                    _MetricRow(
                        icon: Icons.bar_chart_outlined,
                        label: 'Data Confidence',
                        value: '${state.dataConfidence}%',
                        color: AppColors.navy),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              StepCard(
                borderColor: AppColors.orange,
                child: Row(
                  children: [
                    const Icon(Icons.track_changes,
                        color: AppColors.orange),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Continuously monitoring route & surroundings — $_secondsMonitored s elapsed'
                        '${state.routeRecalculations > 0 ? '\nRoute recalculated ${state.routeRecalculations}× for safety' : ''}',
                        style: const TextStyle(
                            color: AppColors.navy, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              Text(
                'Destination: ${state.destination}',
                style: TextStyle(color: AppColors.navy.withOpacity(0.6)),
              ),
              const SizedBox(height: 12),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.red,
                        side: const BorderSide(color: AppColors.red),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _simulateDanger,
                      icon: const Icon(Icons.report_gmailerrorred),
                      label: const Text('Simulate Danger'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.green),
                      onPressed: _arrived,
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('I Arrived'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '(Demo controls — for mentor walkthrough only)',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 11, color: AppColors.navy.withOpacity(0.4)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: AppColors.navy, fontWeight: FontWeight.w500)),
          ),
          Text(value,
              style: TextStyle(color: color, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _MonitorPulse extends StatelessWidget {
  final AnimationController controller;
  const _MonitorPulse({required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.green
                    .withOpacity(0.4 + 0.6 * controller.value),
              ),
            ),
            const SizedBox(width: 6),
            const Text('LIVE',
                style: TextStyle(
                    color: AppColors.green,
                    fontSize: 11,
                    fontWeight: FontWeight.w800)),
          ],
        );
      },
    );
  }
}
