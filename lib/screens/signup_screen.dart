import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'login_screen.dart';
import 'main_screen.dart';

// --- Fade transition helper ---
void pushWithFade(BuildContext context, Widget page) {
  Navigator.of(context).pushReplacement(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 500),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, __, child) =>
        FadeTransition(opacity: animation, child: child),
  ));
}

// ---------- Brand tokens (match Forgot/Login) ----------
const Color _accent   = Color(0xFF7966FA);
const Color _ink      = Color(0xFF22223B);
const Color _muted    = Color(0xFF55597D);
const Color _fieldBg  = Color(0xFFF7F8FA);
const Color _ok       = Color(0xFF1FBF6C);
const Color _warn     = Color(0xFFFFB020);
const Color _danger   = Color(0xFFE84D5B);

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _formKey = GlobalKey<FormState>();

  final TextEditingController nameController    = TextEditingController();
  final TextEditingController emailController   = TextEditingController();
  final TextEditingController passController    = TextEditingController();
  final TextEditingController confirmController = TextEditingController();
  final TextEditingController phoneController   = TextEditingController();

  // Focus nodes for sleek focus visuals (and to hide/show eye icons)
  final FocusNode _nameFocus    = FocusNode();
  final FocusNode _phoneFocus   = FocusNode();
  final FocusNode _emailFocus   = FocusNode();
  final FocusNode _passFocus    = FocusNode();
  final FocusNode _confirmFocus = FocusNode();

  bool _passwordVisible = false;
  bool _confirmVisible  = false;

  // Show red errors only after the user taps Sign Up
  bool _showErrors = false;

  bool loading = false;

  // ---------- Toasts (same look as Forgot/Login) ----------
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

    // Rebuild on focus changes (so borders/labels update). Hide eyes on blur.
    for (final f in [_nameFocus, _phoneFocus, _emailFocus]) {
      f.addListener(() => setState(() {}));
    }
    _passFocus.addListener(() {
      setState(() {
        if (!_passFocus.hasFocus) _passwordVisible = false;
      });
    });
    _confirmFocus.addListener(() {
      setState(() {
        if (!_confirmFocus.hasFocus) _confirmVisible = false;
      });
    });
  }

  @override
  void dispose() {
    _nameFocus.dispose();
    _phoneFocus.dispose();
    _emailFocus.dispose();
    _passFocus.dispose();
    _confirmFocus.dispose();

    nameController.dispose();
    emailController.dispose();
    passController.dispose();
    confirmController.dispose();
    phoneController.dispose();
    super.dispose();
  }

  // Reset validation visuals & focus before navigating away
  void _resetFormVisualState() {
    _formKey.currentState?.reset();
    _showErrors = false;
    _nameFocus.unfocus();
    _phoneFocus.unfocus();
    _emailFocus.unfocus();
    _passFocus.unfocus();
    _confirmFocus.unfocus();
    setState(() {
      _passwordVisible = false;
      _confirmVisible  = false;
    });
  }

  // ---------------- Username helpers ----------------
  String _slugify(String? s) {
    String v = (s ?? '').toLowerCase();
    v = v.replaceAll(RegExp(r'[^a-z0-9]+'), '');
    if (v.isEmpty) v = 'user';
    return v;
  }

  // Reserve username atomically with transaction
  Future<bool> _tryReserveUsername(String username, String uid) async {
    final ref = FirebaseFirestore.instance.collection('usernames').doc(username);
    return FirebaseFirestore.instance.runTransaction<bool>((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) return false; // already taken
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

  // ---------------- Post-auth routing (like login flow) ----------------
  Future<void> _routeAfterAuth({
    required User user,
    required bool isNewUser,
  }) async {
    final users = FirebaseFirestore.instance.collection('users').doc(user.uid);

    final snap = await users.get();
    final data = snap.data() ?? {};
    final existingMode = (data['last_mode'] as String?)?.trim();

    final String targetMode = isNewUser
        ? 'seeker'
        : (existingMode == null || existingMode.isEmpty ? 'seeker' : existingMode);

    await users.set({
      'last_mode': targetMode,
      'last_login_at': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (!mounted) return;
    pushWithFade(context, const MainScreen());
  }

  // ---------------- Email/Password sign-up ----------------
  Future<void> _signUp() async {
    // Show errors only after pressing the button
    setState(() => _showErrors = true);

    if (!_formKey.currentState!.validate()) {
      _toastWarn('Please fix the highlighted fields');
      return;
    }

    final phone = phoneController.text.trim();
    final email = emailController.text.trim();
    final pass  = passController.text.trim();
    final conf  = confirmController.text.trim();

    if (!RegExp(r'^\d{11}$').hasMatch(phone)) {
      _toastWarn('Phone must be 11 digits');
      return;
    }
    if (pass != conf) {
      _toastError('Passwords do not match');
      return;
    }

    setState(() => loading = true);

    try {
      // Prevent duplicate email
      final methods = await FirebaseAuth.instance.fetchSignInMethodsForEmail(email);
      if (methods.isNotEmpty) {
        final isGoogle   = methods.contains('google.com');
        final isPassword = methods.contains('password');
        String msg = 'This email is already registered. ';
        if (isPassword) msg += 'Please log in with your password. ';
        if (isGoogle)   msg += 'Or continue with Google.';
        _toastWarn(msg);
        setState(() => loading = false);
        return;
      }

      final userCred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: pass,
      );
      final uid = userCred.user!.uid;

      final username = await _generateUniqueUsername(
        displayName: nameController.text.trim(),
        uid: uid,
      );

      // Create user profile with default seeker mode
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'name'      : nameController.text.trim(),
        'username'  : username,
        'email'     : email,
        'phone'     : phone,
        'last_mode' : 'seeker',
        'created_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (!mounted) return;
      _toastSuccess('Registration successful!');
      await _routeAfterAuth(user: userCred.user!, isNewUser: true);
    } catch (e) {
      if (!mounted) return;
      _toastError('Error: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ---------------- Google Sign-In ----------------
  Future<void> _signInWithGoogle() async {
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
      final uid = userCred.user!.uid;

      final userDocRef = FirebaseFirestore.instance.collection('users').doc(uid);
      final userDoc = await userDocRef.get();
      final data = userDoc.data() ?? {};
      final isNew = !userDoc.exists;

      // Ensure username exists (only create if missing)
      String? username = (data['username'] as String?)?.trim();
      if (username == null || username.isEmpty) {
        username = await _generateUniqueUsername(
          displayName: userCred.user!.displayName,
          uid: uid,
        );
      }

      await userDocRef.set({
        'name'      : userCred.user!.displayName ?? data['name'] ?? '',
        'username'  : username,
        'email'     : userCred.user!.email ?? data['email'] ?? '',
        'phone'     : userCred.user!.phoneNumber ?? data['phone'] ?? '',
        'last_mode' : isNew ? 'seeker' : (data['last_mode'] ?? 'seeker'),
        'created_at': data['created_at'] ?? FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (mounted) {
        _toastSuccess('Sign in successful!');
        await _routeAfterAuth(user: userCred.user!, isNewUser: isNew);
      }
    } catch (e) {
      if (!mounted) return;
      _toastError('Google Sign-In Error: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    final autoMode = _showErrors ? AutovalidateMode.always : AutovalidateMode.disabled;

    return Scaffold(
      backgroundColor: Colors.white,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
        // Tap-anywhere-to-unfocus: fields return to neutral
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusScope.of(context).unfocus(),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                        onPressed: () {
                          _resetFormVisualState();
                          pushWithFade(context, const LoginScreen());
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Image.asset(
                      'assets/images/HAZIR_LOGO.png',
                      height: 90,
                      width: 90,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(top: 12.0, left: 2.0),
                      child: Text(
                        'Sign Up',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Continue with',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _socialCircleButton(
                        icon: 'assets/images/FACEBOOK.png',
                        bgColor: const Color(0xFF1877F2),
                        borderColor: const Color(0xFF1877F2),
                        onTap: () {}, // your FB flow here
                      ),
                      const SizedBox(width: 26),
                      _socialCircleButton(
                        icon: 'assets/images/GOOGLE.png',
                        bgColor: Colors.white,
                        borderColor: const Color(0xFFE0E0E0),
                        onTap: _signInWithGoogle,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: const [
                      Expanded(child: Divider(thickness: 1, color: _accent)),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text("or", style: TextStyle(color: Colors.grey, fontSize: 14)),
                      ),
                      Expanded(child: Divider(thickness: 1, color: _accent)),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // --- Sleek filled inputs (match Forgot/Login) ---
                  _filledField(
                    controller: nameController,
                    label: 'Name',
                    focusNode: _nameFocus,
                    autovalidateMode: autoMode,
                    validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter Name' : null,
                  ),
                  _filledField(
                    controller: phoneController,
                    label: 'Phone',
                    focusNode: _phoneFocus,
                    keyboardType: TextInputType.phone,
                    autovalidateMode: autoMode,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Enter Phone';
                      if (!RegExp(r'^\d{11}$').hasMatch(v.trim())) return 'Phone must be 11 digits';
                      return null;
                    },
                  ),
                  _filledField(
                    controller: emailController,
                    label: 'Email',
                    focusNode: _emailFocus,
                    keyboardType: TextInputType.emailAddress,
                    autovalidateMode: autoMode,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Enter Email';
                      final s = v.trim();
                      final ok = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s);
                      return ok ? null : 'Enter a valid email';
                    },
                  ),
                  _filledField(
                    controller: passController,
                    label: 'Password',
                    focusNode: _passFocus,
                    obscureText: !_passwordVisible,
                    isPassword: true,
                    onToggleObscure: () => setState(() => _passwordVisible = !_passwordVisible),
                    autovalidateMode: autoMode,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Enter Password';
                      if (v.trim().length < 6) return 'Password must be at least 6 characters';
                      return null;
                    },
                  ),
                  _filledField(
                    controller: confirmController,
                    label: 'Re-Enter Password',
                    focusNode: _confirmFocus,
                    obscureText: !_confirmVisible,
                    isPassword: true,
                    onToggleObscure: () => setState(() => _confirmVisible = !_confirmVisible),
                    autovalidateMode: autoMode,
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Confirm your password';
                      if (v.trim() != passController.text.trim()) return 'Passwords do not match';
                      return null;
                    },
                  ),

                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _signUp,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        minimumSize: const Size(0, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        'Sign Up',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: GestureDetector(
                      onTap: () {
                        _resetFormVisualState();
                        pushWithFade(context, const LoginScreen());
                      },
                      child: const Text(
                        'Already have an account',
                        style: TextStyle(
                          fontSize: 15,
                          color: Colors.black,
                          decoration: TextDecoration.underline,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
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

  // ---------- Input helper (focus/error-aware like Forgot/Login) ----------
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
    AutovalidateMode autovalidateMode = AutovalidateMode.disabled,
  }) {
    final bool isFocused = focusNode?.hasFocus ?? false;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        focusNode: focusNode,
        obscureText: obscureText,
        maxLength: maxLength,
        keyboardType: keyboardType,
        autovalidateMode: autovalidateMode,
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

          // eye icon only while focused (password fields)
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
      ),
    );
  }

  Widget _socialCircleButton({
    required String icon,
    required Color bgColor,
    required Color borderColor,
    required VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          color: bgColor,
          border: Border.all(color: borderColor, width: 1),
          borderRadius: BorderRadius.circular(14),
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
