import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class AIAnalysisScreen extends StatefulWidget {
  const AIAnalysisScreen({super.key});

  @override
  State<AIAnalysisScreen> createState() => _AIAnalysisScreenState();
}

class _AIAnalysisScreenState extends State<AIAnalysisScreen> {
  @override
  void initState() {
    super.initState();
    _runAnalysis();
  }

  Future<void> _runAnalysis() async {
    await Future.delayed(const Duration(seconds: 2));
    final rand = Random();
    // Mock AI computation for the prototype demo.
    final state = AppState.instance;
    state.safetyScore = 60 + rand.nextInt(36); // 60-95
    state.crowdConfidence = 70 + rand.nextInt(26);
    state.lightingConfidence = 65 + rand.nextInt(31);
    state.dataConfidence = 85 + rand.nextInt(13);
    state.helpAvailability =
        state.safetyScore > 80 ? 'High' : (state.safetyScore > 65 ? 'Medium' : 'Low');
    if (mounted) {
      Navigator.pushReplacementNamed(context, '/routecheck');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AI Safety Analysis')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 5, total: 13, label: 'AI is calculating your safety score'),
              const SizedBox(height: 40),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 140,
                        height: 140,
                        decoration: BoxDecoration(
                          color: AppColors.blueLight,
                          shape: BoxShape.circle,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(28),
                          child: Icon(Icons.psychology_alt_outlined,
                              size: 60, color: AppColors.blue),
                        ),
                      ),
                      const SizedBox(height: 30),
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(
                            strokeWidth: 3, color: AppColors.blue),
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'AI calculates Safety Score\nfor all possible routes',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppColors.navy,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            height: 1.4),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Analyzing lighting, crowd, incidents & more…',
                        style: TextStyle(color: AppColors.navy.withOpacity(0.55)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
