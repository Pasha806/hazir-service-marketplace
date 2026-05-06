import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'signin_onboarding_screen.dart';
import 'signup_screen.dart';
import 'main_screen.dart';
import 'forgot_password_screen.dart';

// --- Fade transition helper ---
void pushWithFade(BuildContext context, Widget page) {
  Navigator.of(context).pushReplacement(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 500),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, __, child) =>
        FadeTransition(opacity: animation, child: child),
  ));
}

// ---------- Brand tokens (match Forgot Password) ----------
const Color _accent   = Color(0xFF7966FA);
const Color _ink      = Color(0xFF22223B);
const Color _muted    = Color(0xFF55597D);
const Color _fieldBg  = Color(0xFFF7F8FA);
const Color _ok       = Color(0xFF1FBF6C);
const Color _warn     = Color(0xFFFFB020);
const Color _danger   = Color(0xFFE84D5B);

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController phoneOrEmailController = TextEditingController();
  final TextEditingController passController = TextEditingController();

  // Focus + visibility
  final FocusNode _emailFocus = FocusNode();
  final FocusNode _passFocus  = FocusNode();
  bool _passwordVisible = false;

  // Show errors only after Sign In is tapped
  bool _validatedOnce = false;

  bool loading = false;

  // ---------- Toasts (same look as Forgot Password) ----------
  void _showToast(String msg, {Color? bg, IconData? icon}) {
    final sb = SnackBar(
      behavior: SnackBarBehavior.floating,
      elevation: 1,
      backgroundColor: bg ?? Colors.black87,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      duration: const Duration(seconds: 2),
    );
    ScaffoldMessenger.of(context).showSnackBar(sb);
  }

  void _toastSuccess(String m) => _showToast(m, bg: _ok,     icon: Icons.check_circle_rounded);
  void _toastInfo(String m)    => _showToast(m, bg: _accent, icon: Icons.info_outline_rounded);
  void _toastWarn(String m)    => _showToast(m, bg: _warn,   icon: Icons.warning_amber_rounded);
  void _toastError(String m)   => _showToast(m, bg: _danger, icon: Icons.error_outline_rounded);

  @override
  void initState() {
    super.initState();

    // Rebuild on focus changes; for password, hide eye on blur
    _emailFocus.addListener(() {
      setState(() {}); // triggers border/label color refresh
    });
    _passFocus.addListener(() {
      setState(() {
        if (!_passFocus.hasFocus) _passwordVisible = false;
      });
    });
  }

  @override
  void dispose() {
    _emailFocus.dispose();
    _passFocus.dispose();
    phoneOrEmailController.dispose();
    passController.dispose();
    super.dispose();
  }

  // Reset validation visuals & focus before navigating away
  void _resetFormVisualState() {
    _formKey.currentState?.reset(); // clears red errors/messages
    _emailFocus.unfocus();
    _passFocus.unfocus();
    setState(() {
      _passwordVisible = false;
      _validatedOnce = false;       // <— important so errors are hidden next time
    });
  }

  // ---------------- Username helpers (for Google username-once) ----------------
  String _slugify(String? s) {
    String v = (s ?? '').toLowerCase();
    v = v.replaceAll(RegExp(r'[^a-z0-9]+'), '');
    if (v.isEmpty) v = 'user';
    return v;
  }

  Future<bool> _tryReserveUsername(String username, String uid) async {
    final ref = FirebaseFirestore.instance.collection('usernames').doc(username);
    return FirebaseFirestore.instance.runTransaction<bool>((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) return false;
      tx.set(ref, {
        'uid': uid,
        'created_at': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  Future<String> _generateUniqueUsername({
    required String? displayName,
    required String uid,
  }) async {
    final rand = Random();
    final base = _slugify(displayName);

    if (await _tryReserveUsername(base, uid)) return base;

    for (int i = 0; i < 25; i++) {
      final suffix = (rand.nextInt(9000) + 1000).toString();
      final candidate = '$base$suffix';
      if (await _tryReserveUsername(candidate, uid)) return candidate;
    }

    final fallbackUser = 'user${(rand.nextInt(9000) + 1000)}';
    if (await _tryReserveUsername(fallbackUser, uid)) return fallbackUser;

    final tail = uid.length >= 6 ? uid.substring(uid.length - 6) : uid;
    final finalCandidate = '$base$tail';
    if (await _tryReserveUsername(finalCandidate, uid)) return finalCandidate;

    throw Exception('Could not reserve a unique username. Please try again.');
  }

  // ---------------- Email/Password login ----------------
  Future<void> _login() async {
    // Show errors for the first time
    setState(() => _validatedOnce = true);

    if (!_formKey.currentState!.validate()) {
      return; // stop here; errors are now visible
    }

    setState(() => loading = true);
    try {
      final input = phoneOrEmailController.text.trim();
      final password = passController.text.trim();

      // 1. Attempt Sign In
      final userCred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: input,
        password: password,
      );

      // 2. [NEW] Check if User is Blocked by Admin
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(userCred.user!.uid).get();
      if (userDoc.exists && userDoc.data()?['isBlocked'] == true) {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        _toastError('Access denied: Your account is blocked.');
        setState(() => loading = false);
        return; // STOP execution
      }

      if (!mounted) return;
      _toastSuccess('Sign in successful!');
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      pushWithFade(context, const MainScreen());
    } on FirebaseAuthException catch (_) {
      if (mounted) _toastError('Incorrect email or password');
    } catch (e) {
      if (mounted) _toastError('Sign-in error: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ---------------- Google Sign-In (username only if missing) ----------------
  Future<void> _loginWithGoogle() async {
    setState(() => loading = true);
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) {
        setState(() => loading = false);
        return;
      }
      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final userCred = await FirebaseAuth.instance.signInWithCredential(credential);
      final user = userCred.user!;

      final userRef = FirebaseFirestore.instance.collection('users').doc(user.uid);
      final snap = await userRef.get();

      // 1. [NEW] Check if User is Blocked by Admin
      if (snap.exists && snap.data()?['isBlocked'] == true) {
        await FirebaseAuth.instance.signOut();
        if (!mounted) return;
        _toastError('Access denied: Your account is blocked.');
        setState(() => loading = false);
        return; // STOP execution
      }

      final data = snap.data() ?? {};

      String? username = (data['username'] as String?)?.trim();
      if (username == null || username.isEmpty) {
        username = await _generateUniqueUsername(
          displayName: user.displayName,
          uid: user.uid,
        );
      }

      await userRef.set({
        'name'      : user.displayName ?? data['name'] ?? '',
        'username'  : username,
        'email'     : user.email ?? data['email'] ?? '',
        'phone'     : user.phoneNumber ?? data['phone'] ?? '',
        'last_mode' : data['last_mode'] ?? 'seeker',
        'created_at': data['created_at'] ?? FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (mounted) {
        _toastSuccess('Sign in successful!');
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) return;
        pushWithFade(context, const MainScreen());
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) _toastError('Google Sign-In Error: ${e.message ?? e.code}');
    } catch (e) {
      if (mounted) _toastError('Google Sign-In Error: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
        // Tap-anywhere-to-unfocus
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                    onPressed: () {
                      _resetFormVisualState();
                      pushWithFade(context, const SignInOnboardingScreen());
                    },
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Image.asset(
                      'assets/images/HAZIR_LOGO.png',
                      height: 82,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Sign in',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Email / Phone
                  _filledField(
                    controller: phoneOrEmailController,
                    label: 'Email or phone',
                    keyboardType: TextInputType.emailAddress,
                    focusNode: _emailFocus,
                    validator: (v) =>
                        _requiredWhenUnfocused(v, _emailFocus, 'Email or phone'),
                  ),
                  const SizedBox(height: 14),

                  // Password
                  _filledField(
                    controller: passController,
                    label: 'Password',
                    obscureText: !_passwordVisible,
                    focusNode: _passFocus,
                    isPassword: true,
                    onToggleObscure: () =>
                        setState(() => _passwordVisible = !_passwordVisible),
                    validator: (v) =>
                        _requiredWhenUnfocused(v, _passFocus, 'Password'),
                  ),

                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        GestureDetector(
                          onTap: () {
                            _resetFormVisualState();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const ForgotPasswordScreen(),
                              ),
                            );
                          },
                          child: const Text(
                            "forgot password?",
                            style: TextStyle(
                              fontSize: 14,
                              color: _muted,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _login,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text(
                        "Sign In",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),

                  Row(
                    children: [
                      Expanded(child: Divider(thickness: 1, color: Colors.grey[300])),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text(
                          "or",
                          style: TextStyle(color: Colors.grey, fontSize: 14),
                        ),
                      ),
                      Expanded(child: Divider(thickness: 1, color: Colors.grey[300])),
                    ],
                  ),
                  const SizedBox(height: 24),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _socialCircleButton(
                        icon: 'assets/images/GOOGLE.png',
                        onTap: _loginWithGoogle,
                        bgColor: Colors.white,
                        borderColor: const Color(0xFFEEEEEE),
                      ),
                      const SizedBox(width: 24),
                      _socialCircleButton(
                        icon: 'assets/images/FACEBOOK.png',
                        onTap: () {},
                        bgColor: const Color(0xFF1877F2),
                        borderColor: const Color(0xFF1877F2),
                      ),
                    ],
                  ),
                  const SizedBox(height: 28),

                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton(
                      onPressed: () {
                        _resetFormVisualState();
                        // guest flow (kept as-is)
                      },
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: const BorderSide(color: _accent),
                        minimumSize: const Size(0, 50),
                      ),
                      child: const Text(
                        "Continue as a Guest",
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 16,
                          color: _ink,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        "Create a New Account? ",
                        style: TextStyle(fontSize: 14, color: _ink),
                      ),
                      GestureDetector(
                        onTap: () {
                          _resetFormVisualState();
                          pushWithFade(context, const SignUpScreen());
                        },
                        child: const Text(
                          "Sign up",
                          style: TextStyle(
                            fontSize: 14,
                            color: _accent,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Hide error while focused; when unfocused and invalid -> show message (but only after Sign In)
  String? _requiredWhenUnfocused(String? value, FocusNode node, String label) {
    if (node.hasFocus) return null; // suppress red error while editing
    if (!_validatedOnce) return null; // don't show any error until Sign In is tapped
    if (value == null || value.trim().isEmpty) return 'Enter $label';
    return null;
  }

  // ---------- Input helper (focus/error-aware like Forgot Password) ----------
  Widget _filledField({
    required TextEditingController controller,
    required String label,
    FocusNode? focusNode,
    bool obscureText = false,
    bool isPassword = false,
    int? maxLength,
    TextInputType? keyboardType,
    VoidCallback? onToggleObscure,
    String? Function(String?)? validator,
  }) {
    final bool isFocused = focusNode?.hasFocus ?? false;

    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      maxLength: maxLength,
      keyboardType: keyboardType,
      // Only start showing validation after Sign In attempt
      autovalidateMode:
      _validatedOnce ? AutovalidateMode.always : AutovalidateMode.disabled,
      validator: validator,
      style: const TextStyle(fontSize: 16, color: _ink),
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        labelStyle: TextStyle(
          color: isFocused ? _accent : _muted,
          fontWeight: FontWeight.w600,
        ),
        errorStyle: const TextStyle(fontSize: 12, color: _danger, height: 1.1),
        filled: true,
        fillColor: _fieldBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),

        // neutral when idle
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),

        // accent when focused
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _accent, width: 2),
        ),

        // red when error & not focused
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _danger, width: 1.5),
        ),

        // when error + focused: still show accent (nice recovery)
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _accent, width: 2),
        ),

        // eye icon only while focused (password)
        suffixIcon: isPassword && isFocused
            ? IconButton(
          onPressed: onToggleObscure,
          icon: Icon(
            obscureText ? Icons.visibility_off_rounded : Icons.visibility_rounded,
            color: _muted,
          ),
        )
            : null,
      ),
    );
  }

  Widget _socialCircleButton({
    required String icon,
    required VoidCallback onTap,
    required Color bgColor,
    required Color borderColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor, width: 1),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Image.asset(
            icon,
            width: 28,
            height: 28,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}