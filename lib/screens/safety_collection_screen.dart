import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class _DataSource {
  final String label;
  final IconData icon;
  _DataSource(this.label, this.icon);
}

class SafetyCollectionScreen extends StatefulWidget {
  const SafetyCollectionScreen({super.key});

  @override
  State<SafetyCollectionScreen> createState() =>
      _SafetyCollectionScreenState();
}

class _SafetyCollectionScreenState extends State<SafetyCollectionScreen> {
  final List<_DataSource> _sources = [
    _DataSource('Lighting Data', Icons.light_mode_outlined),
    _DataSource('Crowd Density', Icons.groups_outlined),
    _DataSource('Police Stations', Icons.local_police_outlined),
    _DataSource('Incident Reports', Icons.warning_amber_rounded),
    _DataSource('Community Feedback', Icons.forum_outlined),
    _DataSource('Time & Weather', Icons.wb_cloudy_outlined),
  ];

  int _loadedCount = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 450), (t) {
      setState(() => _loadedCount++);
      if (_loadedCount >= _sources.length) {
        t.cancel();
        Timer(const Duration(milliseconds: 500), () {
          if (mounted) Navigator.pushReplacementNamed(context, '/analysis');
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety Data Collection')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 4,
                  total: 13,
                  label: 'Gathering real-time safety signals'),
              const SizedBox(height: 6),
              Text(
                'Route to ${AppState.instance.destination}',
                style: TextStyle(color: AppColors.navy.withOpacity(0.6)),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: GridView.builder(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 14,
                    crossAxisSpacing: 14,
                    childAspectRatio: 1.15,
                  ),
                  itemCount: _sources.length,
                  itemBuilder: (context, i) {
                    final loaded = i < _loadedCount;
                    final source = _sources[i];
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      decoration: BoxDecoration(
                        color: loaded ? AppColors.blueLight : Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: loaded ? AppColors.blue : AppColors.cardBorder,
                        ),
                      ),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(source.icon,
                              size: 30,
                              color:
                                  loaded ? AppColors.blue : Colors.grey.shade400),
                          const SizedBox(height: 10),
                          Text(
                            source.label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: loaded ? AppColors.navy : Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 8),
                          loaded
                              ? const Icon(Icons.check_circle,
                                  color: AppColors.green, size: 18)
                              : const SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)),
                        ],
                      ),
                    );
                  },
                ),
              ),
              Text(
                '$_loadedCount / ${_sources.length} sources collected',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppColors.navy, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
