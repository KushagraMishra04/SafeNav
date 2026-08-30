import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class DestinationScreen extends StatefulWidget {
  const DestinationScreen({super.key});

  @override
  State<DestinationScreen> createState() => _DestinationScreenState();
}

class _DestinationScreenState extends State<DestinationScreen> {
  final _controller = TextEditingController();
  final List<String> _suggestions = const [
    'Cyber Hub, Gurugram',
    'DLF Phase 3 Metro Station',
    'Sector 29 Market',
    'Ambience Mall',
    'Rajiv Chowk, New Delhi',
  ];
  String? _selected;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enter Destination')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(
                  step: 3, total: 13, label: 'Select your destination'),
              const SizedBox(height: 20),
              TextField(
                controller: _controller,
                onChanged: (v) => setState(() => _selected = null),
                decoration: const InputDecoration(
                  labelText: 'Where do you want to go?',
                  prefixIcon: Icon(Icons.location_on_outlined),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Suggested destinations',
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: AppColors.navy),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView.separated(
                  itemCount: _suggestions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final place = _suggestions[i];
                    final isSelected = _selected == place;
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () {
                        setState(() {
                          _selected = place;
                          _controller.text = place;
                        });
                      },
                      child: StepCard(
                        borderColor:
                            isSelected ? AppColors.purple : AppColors.cardBorder,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        child: Row(
                          children: [
                            Icon(Icons.place_outlined,
                                color: isSelected
                                    ? AppColors.purple
                                    : AppColors.navy.withOpacity(0.5)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(place,
                                  style: const TextStyle(
                                      color: AppColors.navy,
                                      fontWeight: FontWeight.w600)),
                            ),
                            if (isSelected)
                              const Icon(Icons.check_circle,
                                  color: AppColors.purple),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Find Safe Route'),
                  onPressed: _controller.text.trim().isEmpty
                      ? null
                      : () {
                          AppState.instance.destination =
                              _controller.text.trim();
                          Navigator.pushNamed(context, '/collection');
                        },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
