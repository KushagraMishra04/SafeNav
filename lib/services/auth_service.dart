import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'firestore_service.dart';

class AuthResult {
  final bool success;
  final User? user;
  final String? error;
  final bool isLocal;

  const AuthResult({required this.success, this.user, this.error, this.isLocal = false});

  factory AuthResult.ok(User? u) => AuthResult(success: true, user: u);
  factory AuthResult.local() => const AuthResult(success: true, isLocal: true);
  factory AuthResult.fail(String err) => AuthResult(success: false, error: err);
}

class AuthService {
  static final AuthService instance = AuthService._();
  AuthService._();

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  bool get isSignedIn => (currentUser != null && !currentUser!.isAnonymous);
  bool get isGuest => currentUser != null && currentUser!.isAnonymous;

  /// Sign up with email, password and optional display name.
  /// Falls back to local offline mode if Firebase Email provider is not yet enabled.
  Future<AuthResult> signUpWithEmail({
    required String email,
    required String password,
    String? name,
  }) async {
    final cleanEmail = email.trim();
    final cleanName = name?.trim().isNotEmpty == true ? name!.trim() : cleanEmail.split('@').first;

    try {
      final cred = await _auth.createUserWithEmailAndPassword(
        email: cleanEmail,
        password: password,
      );
      final user = cred.user;
      if (user != null) {
        if (cleanName.isNotEmpty) {
          try {
            await user.updateDisplayName(cleanName);
          } catch (_) {}
        }
        // Save initial user profile in Firestore safely
        try {
          await FirestoreService.instance.saveUserProfile(
            uid: user.uid,
            email: user.email ?? cleanEmail,
            name: cleanName,
          );
        } catch (_) {}
      }
      return AuthResult.ok(user);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'operation-not-allowed' || e.code == 'network-request-failed') {
        await _saveLocalSession(cleanName, cleanEmail);
        return AuthResult.local();
      }
      return AuthResult.fail(_humanError(e));
    } catch (e) {
      // Local fallback on connection or unexpected environment issues
      await _saveLocalSession(cleanName, cleanEmail);
      return AuthResult.local();
    }
  }

  /// Sign in with existing email and password.
  /// Falls back to local offline mode if Firebase Email provider is not yet enabled.
  Future<AuthResult> signInWithEmail({
    required String email,
    required String password,
  }) async {
    final cleanEmail = email.trim();
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: cleanEmail,
        password: password,
      );
      final user = cred.user;
      if (user != null) {
        try {
          await FirestoreService.instance.touchUserLogin(user.uid);
        } catch (_) {}
      }
      return AuthResult.ok(user);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'operation-not-allowed' || e.code == 'network-request-failed') {
        final sp = await SharedPreferences.getInstance();
        final savedName = sp.getString('local_auth_name') ?? cleanEmail.split('@').first;
        await _saveLocalSession(savedName, cleanEmail);
        return AuthResult.local();
      }
      return AuthResult.fail(_humanError(e));
    } catch (e) {
      final sp = await SharedPreferences.getInstance();
      final savedName = sp.getString('local_auth_name') ?? cleanEmail.split('@').first;
      await _saveLocalSession(savedName, cleanEmail);
      return AuthResult.local();
    }
  }

  /// Direct local sign-in without requiring Firebase server setup.
  Future<AuthResult> loginLocally({required String name, required String email}) async {
    await _saveLocalSession(name.trim(), email.trim());
    return AuthResult.local();
  }

  Future<void> _saveLocalSession(String name, String email) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('local_auth_name', name.isNotEmpty ? name : 'SafeNav User');
    await sp.setString('local_auth_email', email.isNotEmpty ? email : 'user@safenav.local');
  }

  /// Sign in with Google (OAuth credential).
  Future<AuthResult> signInWithGoogle() async {
    try {
      final GoogleSignInAccount? gUser = await _googleSignIn.signIn();
      if (gUser == null) {
        // User canceled the sign-in flow
        return const AuthResult(success: false, error: 'Sign in cancelled.');
      }

      final GoogleSignInAuthentication gAuth = await gUser.authentication;
      final OAuthCredential credential = GoogleAuthProvider.credential(
        accessToken: gAuth.accessToken,
        idToken: gAuth.idToken,
      );

      final cred = await _auth.signInWithCredential(credential);
      final user = cred.user;
      if (user != null) {
        try {
          await FirestoreService.instance.saveUserProfile(
            uid: user.uid,
            email: user.email ?? gUser.email,
            name: user.displayName ?? gUser.displayName ?? 'Google User',
            photoUrl: user.photoURL ?? gUser.photoUrl,
          );
        } catch (_) {}
      }
      return AuthResult.ok(user);
    } on FirebaseAuthException catch (e) {
      return AuthResult.fail(_humanError(e));
    } catch (e) {
      return AuthResult.fail('Google sign-in error: $e');
    }
  }

  /// Continue as a guest without creating an account.
  Future<AuthResult> signInAnonymously() async {
    try {
      final cred = await _auth.signInAnonymously();
      return AuthResult.ok(cred.user);
    } catch (_) {
      await _saveLocalSession('Guest User', 'guest@safenav.local');
      return AuthResult.local();
    }
  }

  /// Sign out the current user and clear local session.
  Future<void> signOut() async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove('local_auth_name');
      await sp.remove('local_auth_email');
    } catch (_) {}
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    try {
      await _auth.signOut();
    } catch (_) {}
  }

  /// Privacy compliance: Delete all Firestore records and remove the user account.
  Future<AuthResult> deleteAccountAndData() async {
    final user = _auth.currentUser;
    if (user == null) {
      await signOut();
      return const AuthResult(success: true);
    }
    try {
      // 1. Delete Firestore records
      try {
        await FirestoreService.instance.deleteUserData(user.uid);
      } catch (_) {}
      // 2. Delete the Firebase Auth account
      await user.delete();
      return const AuthResult(success: true);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'requires-recent-login') {
        return AuthResult.fail('Please sign out and sign back in before deleting your account.');
      }
      return AuthResult.fail(_humanError(e));
    } catch (e) {
      return AuthResult.fail('Failed to delete account data: $e');
    }
  }

  static String _humanError(FirebaseAuthException e) {
    switch (e.code) {
      case 'user-not-found':
        return 'No account found with this email.';
      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect password or email. Please check and try again.';
      case 'email-already-in-use':
        return 'An account already exists for this email.';
      case 'invalid-email':
        return 'Please enter a valid email address.';
      case 'weak-password':
        return 'Password should be at least 6 characters.';
      case 'network-request-failed':
        return 'Network connection issue. Please check your internet.';
      case 'operation-not-allowed':
        return 'Email/password sign-in is disabled in Firebase Console. You can use Local Mode to continue.';
      case 'user-disabled':
        return 'This account has been disabled.';
      default:
        return e.message ?? 'Authentication error occurred.';
    }
  }
}
