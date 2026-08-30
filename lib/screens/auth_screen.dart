import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../widgets/flow_progress.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _isSignUp = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign In / Sign Up')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const FlowProgress(step: 2, total: 13, label: 'Secure Authentication'),
              const SizedBox(height: 20),
              StepCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.purpleLight,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(Icons.lock_person_rounded,
                              color: AppColors.purple),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Your identity stays protected end-to-end.',
                            style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: AppColors.navy),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    ToggleButtons(
                      borderRadius: BorderRadius.circular(12),
                      isSelected: [_isSignUp, !_isSignUp],
                      onPressed: (i) => setState(() => _isSignUp = i == 0),
                      selectedColor: Colors.white,
                      fillColor: AppColors.purple,
                      color: AppColors.navy,
                      constraints: BoxConstraints(
                        minWidth: (MediaQuery.of(context).size.width - 76) / 2,
                        minHeight: 44,
                      ),
                      children: const [Text('Sign Up'), Text('Sign In')],
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                        labelText: 'Full Name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: _phoneController,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone Number',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const TextField(
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: 'Password / OTP',
                        prefixIcon: Icon(Icons.password_outlined),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    AppState.instance.userName =
                        _nameController.text.trim().isEmpty
                            ? 'Guest User'
                            : _nameController.text.trim();
                    Navigator.pushNamed(context, '/destination');
                  },
                  child: Text(_isSignUp ? 'Create Account & Continue' : 'Sign In & Continue'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
