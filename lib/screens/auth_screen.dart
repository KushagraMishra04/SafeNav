import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../state/app_state.dart';
import '../services/auth_service.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = false;
  bool _hidePassword = true;
  bool _loading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _toast(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? Colors.red.shade700 : AppColors.blue,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _submitEmail() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();

    if (email.isEmpty || !email.contains('@')) {
      _toast('Please enter a valid email address.', isError: true);
      return;
    }
    if (password.length < 6) {
      _toast('Password must be at least 6 characters.', isError: true);
      return;
    }

    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final res = _isSignUp
        ? await AuthService.instance.signUpWithEmail(email: email, password: password, name: name)
        : await AuthService.instance.signInWithEmail(email: email, password: password);

    if (!mounted) return;
    setState(() => _loading = false);

    if (res.success) {
      final displayName = res.user?.displayName ?? (name.isNotEmpty ? name : email.split('@').first);
      AppState.instance.userName = displayName;
      _toast(res.isLocal
          ? 'Signed in (Local Mode).'
          : (_isSignUp ? 'Account created successfully!' : 'Welcome back!'));
      Navigator.pushReplacementNamed(context, '/destination');
    } else {
      setState(() => _errorMessage = res.error);
      _toast(res.error ?? 'Authentication failed', isError: true);
    }
  }

  Future<void> _continueLocally() async {
    final email = _emailController.text.trim();
    final name = _nameController.text.trim();
    final cleanName = name.isNotEmpty ? name : (email.isNotEmpty ? email.split('@').first : 'SafeNav User');
    final cleanEmail = email.isNotEmpty ? email : 'user@safenav.local';

    setState(() => _loading = true);
    await AuthService.instance.loginLocally(name: cleanName, email: cleanEmail);
    if (!mounted) return;
    setState(() => _loading = false);

    AppState.instance.userName = cleanName;
    _toast('Signed in (Local Mode).');
    Navigator.pushReplacementNamed(context, '/destination');
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    final res = await AuthService.instance.signInWithGoogle();
    if (!mounted) return;
    setState(() => _loading = false);

    if (res.success) {
      AppState.instance.userName = res.user?.displayName ?? 'SafeNav User';
      _toast('Signed in with Google!');
      Navigator.pushReplacementNamed(context, '/destination');
    } else if (res.error != null && res.error != 'Sign in cancelled.') {
      setState(() => _errorMessage = res.error);
      _toast(res.error!, isError: true);
    }
  }

  Future<void> _continueAsGuest() async {
    setState(() => _loading = true);
    await AuthService.instance.signInAnonymously();
    if (!mounted) return;
    setState(() => _loading = false);

    AppState.instance.userName = 'Guest User';
    Navigator.pushReplacementNamed(context, '/destination');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('SafeNav Account'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.shield_outlined, color: AppColors.blue, size: 36),
                  SizedBox(width: 10),
                  Text(
                    'SafeNav',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: AppColors.navy,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                _isSignUp ? 'Create your account' : 'Welcome back',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  color: AppColors.navy,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'AI-powered safe routing, live trip alerts & guardian monitoring.',
                style: TextStyle(fontSize: 14, color: AppColors.muted),
              ),
              const SizedBox(height: 24),

              // Mode toggle (Sign In vs Sign Up)
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: AppColors.blueLight,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    _modeButton('Sign in', !_isSignUp, () {
                      setState(() {
                        _isSignUp = false;
                        _errorMessage = null;
                      });
                    }),
                    _modeButton('Sign up', _isSignUp, () {
                      setState(() {
                        _isSignUp = true;
                        _errorMessage = null;
                      });
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              if (_errorMessage != null) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.error_outline, color: Colors.red.shade700, size: 20),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _errorMessage!,
                              style: TextStyle(color: Colors.red.shade800, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: _continueLocally,
                          icon: const Icon(Icons.offline_bolt_outlined, size: 16),
                          label: const Text('Continue in Offline / Local Mode',
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade900,
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              if (_isSignUp) ...[
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Full name',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 14),
              ],

              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
              ),
              const SizedBox(height: 14),

              TextField(
                controller: _passwordController,
                obscureText: _hidePassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _hidePassword = !_hidePassword),
                  ),
                ),
              ),
              const SizedBox(height: 22),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submitEmail,
                  child: _loading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : Text(_isSignUp ? 'Create account' : 'Sign in'),
                ),
              ),
              const SizedBox(height: 16),

              const Row(
                children: [
                  Expanded(child: Divider()),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('OR', style: TextStyle(color: AppColors.muted, fontSize: 12)),
                  ),
                  Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 16),

              // Google Sign-In Button
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _signInWithGoogle,
                  icon: const Icon(Icons.g_mobiledata, size: 28, color: Colors.redAccent),
                  label: const Text('Continue with Google'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.navy,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    side: const BorderSide(color: AppColors.cardBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Guest access
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _loading ? null : _continueAsGuest,
                  icon: const Icon(Icons.explore_outlined, color: AppColors.blue),
                  label: const Text('Continue as guest'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.blue,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    side: const BorderSide(color: AppColors.cardBorder),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              const Text(
                'By continuing, you agree to SafeNav’s privacy principles. Your live location is only shared during active navigation or emergency SOS.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeButton(String label, bool selected, VoidCallback onTap) => Expanded(
        child: TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            backgroundColor: selected ? Colors.white : Colors.transparent,
            foregroundColor: selected ? AppColors.blue : AppColors.muted,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      );
}
