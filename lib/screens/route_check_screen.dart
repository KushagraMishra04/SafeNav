import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

const int _safeThreshold = 70;

class RouteCheckScreen extends StatefulWidget {
  const RouteCheckScreen({super.key});

  @override
  State<RouteCheckScreen> createState() => _RouteCheckScreenState();
}

class _RouteCheckScreenState extends State<RouteCheckScreen> {
  bool _generatingAlternative = false;

  bool get _isSafe => AppState.instance.safetyScore >= _safeThreshold;

  Future<void> _generateAlternative() async {
    setState(() => _generatingAlternative = true);
    await Future.delayed(const Duration(seconds: 2));
    final state = AppState.instance;
    state.safetyScore = (state.safetyScore + 18).clamp(0, 97);
    state.lightingConfidence = (state.lightingConfidence + 10).clamp(0, 99);
    if (!mounted) return;
    setState(() => _generatingAlternative = false);
  }

  @override
  Widget build(BuildContext context) {
    final score = AppState.instance.safetyScore;
    return Scaffold(
      appBar: AppBar(title: const Text('Route Safety Check')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 5, total: 13, label: 'Is the route safe enough?'),
              const SizedBox(height: 20),
              StepCard(
                borderColor: _isSafe ? AppColors.green : AppColors.red,
                child: Column(
                  children: [
                    Text(
                      '$score%',
                      style: TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.w900,
                        color: _isSafe ? AppColors.green : AppColors.red,
                      ),
                    ),
                    Text(
                      'Overall Safety Score',
                      style: TextStyle(color: AppColors.navy.withOpacity(0.6)),
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: score / 100,
                      minHeight: 10,
                      borderRadius: BorderRadius.circular(8),
                      backgroundColor: AppColors.cardBorder,
                      valueColor: AlwaysStoppedAnimation(
                          _isSafe ? AppColors.green : AppColors.red),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _isSafe ? Icons.verified_user : Icons.error_outline,
                          color: _isSafe ? AppColors.green : AppColors.red,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isSafe
                              ? 'Route meets the safety threshold ($_safeThreshold%+)'
                              : 'Below safety threshold ($_safeThreshold%+) — needs a safer path',
                          style: TextStyle(
                            color: _isSafe ? AppColors.green : AppColors.red,
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (!_isSafe) ...[
                StepCard(
                  borderColor: AppColors.blue,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.blueLight,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: _generatingAlternative
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: AppColors.blue))
                            : const Icon(Icons.alt_route,
                                color: AppColors.blue),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _generatingAlternative
                              ? 'Generating a safer alternative route…'
                              : 'Alternative Safer Route Generated will be regenerated automatically.',
                          style: const TextStyle(
                              color: AppColors.navy,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.refresh),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.blue),
                    onPressed:
                        _generatingAlternative ? null : _generateAlternative,
                    label: const Text('Generate Safer Alternative Route'),
                  ),
                ),
              ] else
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.navigation_outlined),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.green),
                    onPressed: () =>
                        Navigator.pushReplacementNamed(context, '/navigation'),
                    label: const Text('Start Safe Navigation'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
