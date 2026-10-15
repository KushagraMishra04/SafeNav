import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 28),
          child: Column(
            children: [
              const Spacer(flex: 2),
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  color: AppColors.blueLight,
                  borderRadius: BorderRadius.circular(28),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const Icon(Icons.location_on_outlined, color: AppColors.blue, size: 78),
                    Positioned(
                      top: 27,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: const BoxDecoration(
                          color: AppColors.blueLight,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.shield_outlined, color: AppColors.blue, size: 28),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              const Text('SafeNav', style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: AppColors.navy)),
              const SizedBox(height: 8),
              const Text('Travel safe, not just fast.', textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: AppColors.muted)),
              const Spacer(flex: 2),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pushNamed(context, '/auth'),
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('Get started'),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Safer routes. Connected journeys.', style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ],
          ),
        ),
      ),
    );
  }
}
