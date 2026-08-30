import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class JourneyEndScreen extends StatelessWidget {
  const JourneyEndScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppState.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Journey Complete')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 11, total: 13, label: 'You reached your destination'),
              const SizedBox(height: 40),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 120,
                        height: 120,
                        decoration: const BoxDecoration(
                          color: AppColors.greenLight,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.flag_circle_rounded,
                            size: 64, color: AppColors.green),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        'You have reached your\ndestination safely',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: AppColors.navy),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        state.destination,
                        style: TextStyle(color: AppColors.navy.withOpacity(0.6)),
                      ),
                      const SizedBox(height: 20),
                      if (state.routeRecalculations > 0)
                        StepBadge(
                          text:
                              'Route recalculated ${state.routeRecalculations}× to keep you safe',
                          color: AppColors.orange,
                        ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, '/feedback'),
                  child: const Text('Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
