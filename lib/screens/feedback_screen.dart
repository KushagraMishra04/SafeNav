import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class FeedbackScreen extends StatefulWidget {
  const FeedbackScreen({super.key});

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  int _rating = 0;
  final _controller = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Post-Trip Feedback')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 12, total: 13, label: 'Rate your experience'),
              const SizedBox(height: 24),
              StepCard(
                child: Column(
                  children: [
                    const Text('How safe did this route feel?',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.navy,
                            fontSize: 16)),
                    const SizedBox(height: 16),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(5, (i) {
                          final filled = i < _rating;
                          return IconButton(
                            visualDensity: VisualDensity.compact,
                            constraints: const BoxConstraints(),
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                            iconSize: 36,
                            onPressed: () => setState(() => _rating = i + 1),
                            icon: Icon(
                              filled ? Icons.star_rounded : Icons.star_border_rounded,
                              color: AppColors.orange,
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _rating == 0
                          ? 'Tap to rate'
                          : ['Poor', 'Fair', 'Good', 'Very Good', 'Excellent']
                              [_rating - 1],
                      style: TextStyle(color: AppColors.navy.withOpacity(0.6)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _controller,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Share feedback (optional)',
                  hintText: 'e.g. Well-lit path, felt safe throughout…',
                  alignLabelWithHint: true,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.send_rounded),
                  onPressed: _rating == 0
                      ? null
                      : () {
                          AppState.instance.userRating = _rating.toDouble();
                          AppState.instance.feedbackText = _controller.text;
                          Navigator.pushReplacementNamed(context, '/dbupdate');
                        },
                  label: const Text('Submit Feedback'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
