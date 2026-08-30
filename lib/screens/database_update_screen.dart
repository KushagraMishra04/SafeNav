import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class DatabaseUpdateScreen extends StatelessWidget {
  const DatabaseUpdateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety Database Updated')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 13, total: 13, label: 'Thank you for keeping the community safe'),
              const SizedBox(height: 30),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 110,
                        height: 110,
                        decoration: const BoxDecoration(
                          color: AppColors.purpleLight,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.storage_rounded,
                            size: 54, color: AppColors.purple),
                      ),
                      const SizedBox(height: 22),
                      const Text(
                        'Feedback verified & used to\nimprove future safety scores',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: AppColors.navy),
                      ),
                      const SizedBox(height: 20),
                      StepCard(
                        child: Row(
                          children: [
                            const Icon(Icons.star_rounded,
                                color: AppColors.orange),
                            const SizedBox(width: 10),
                            Text(
                              'Your rating: ${AppState.instance.userRating.toInt()} / 5',
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.navy),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.replay_outlined),
                  onPressed: () {
                    AppState.instance.resetForNewJourney();
                    Navigator.pushNamedAndRemoveUntil(
                        context, '/destination', (route) => false);
                  },
                  label: const Text('Start New Journey'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
