import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Navigate back to your login UI for Google sign-in
import 'login_screen.dart';

const String _kEmailCooldownUntilKey = 'forgot_pw_email_cooldown_until';

// Toggle: require 'password' provider to send reset link (disables button if false)
// WARNING: Enabling this can leak whether an email exists. Keep false to avoid enumeration.
const bool kResetOnlyWhenPasswordExists = false;

// If enumeration protection hides providers (empty []), gently nudge Gmail users anyway
const bool kShowGmailHeuristicHint = true;

// Brand tokens
const Color _accent   = Color(0xFF7966FA);
const Color _ink      = Color(0xFF22223B);
const Color _muted    = Color(0xFF55597D);
const Color _fieldBg  = Color(0xFFF7F8FA);
const Color _ok       = Color(0xFF1FBF6C);
const Color _warn     = Color(0xFFFFB020);
const Color _danger   = Color(0xFFE84D5B);
const Color _lavTonal = Color(0xFFF2EDFF); // subtler lavender wash

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  // Email flow
  final _emailCtl = TextEditingController();
  final _emailFocus = FocusNode();
  bool _sendingEmail = false;
  int _emailCooldown = 0;
  Timer? _emailTimer;
  Timer? _emailHintDebounce;

  // Provider hint
  String? _providerHint;                 // UI nudge for Google-only etc.
  bool _emailHasPasswordProvider = true; // updates live from fetchSignInMethods
  final Map<String, List<String>> _methodsCache = HashMap(); // tiny cache

  // Phone flow
  final _phoneCtl = TextEditingController(); // Use E.164 (+92…)
  final _codeCtl = TextEditingController();
  final _newPassCtl = TextEditingController();
  final _confirmCtl = TextEditingController();

  String? _verificationId;
  int? _resendToken;
  int _phoneStep = 0; // 0: phone, 1: code, 2: set new password
  bool _busyPhone = false;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _restoreEmailCooldown();

    // Recompute hint when user finishes editing
    _emailFocus.addListener(() {
      if (!_emailFocus.hasFocus) {
        final email = _emailCtl.text.trim().toLowerCase();
        if (email.isNotEmpty) _checkProviderHint(email);
      }
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    _emailTimer?.cancel();
    _emailHintDebounce?.cancel();
    _emailFocus.dispose();
    _emailCtl.dispose();
    _phoneCtl.dispose();
    _codeCtl.dispose();
    _newPassCtl.dispose();
    _confirmCtl.dispose();
    super.dispose();
  }

  // ---------- Toasts ----------
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

  // ---------- Helpers ----------
  bool _looksLikeEmail(String e) {
    final s = e.trim();
    if (s.isEmpty) return false;
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(s);
  }

  Set<String> _gmailCandidates(String raw) {
    final e = raw.trim().toLowerCase();
    final candidates = <String>{};
    candidates.add(e); // always try the original first

    final at = e.indexOf('@');
    if (at <= 0) return candidates;

    var local = e.substring(0, at);
    var domain = e.substring(at + 1);

    final isGmail = domain == 'gmail.com' || domain == 'googlemail.com';
    if (!isGmail) return candidates;

    final plus = local.indexOf('+');
    if (plus > -1) local = local.substring(0, plus);

    final noDotsLocal = local.replaceAll('.', '');

    for (final d in const ['gmail.com', 'googlemail.com']) {
      candidates.add('$local@$d');
      candidates.add('$noDotsLocal@$d');
    }
    return candidates;
  }

  Future<List<String>> _lookupMethods(String email) async {
    if (_methodsCache.containsKey(email)) return _methodsCache[email]!;
    final tries = _gmailCandidates(email).toList();

    for (final candidate in tries) {
      try {
        final methods = await FirebaseAuth.instance.fetchSignInMethodsForEmail(candidate);
        if (methods.isNotEmpty) {
          _methodsCache[email] = methods;
          if (kDebugMode) debugPrint('[ForgotPassword] hit for $candidate -> $methods');
          return methods;
        } else {
          if (kDebugMode) debugPrint('[ForgotPassword] empty for $candidate');
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[ForgotPassword] lookup failed for $candidate: $e');
      }
    }

    _methodsCache[email] = const [];
    return const [];
  }

  // ---------- EMAIL RESET ----------
  Future<void> _sendEmailReset() async {
    final email = _emailCtl.text.trim().toLowerCase();
    if (email.isEmpty || !_looksLikeEmail(email)) {
      _toastWarn('Enter a valid email');
      return;
    }

    await _checkProviderHint(email);

    if (kResetOnlyWhenPasswordExists && !_emailHasPasswordProvider) {
      _toastInfo(_providerHint ?? 'This email uses a social sign-in. Try Continue with Google.');
      return;
    }

    setState(() => _sendingEmail = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      await _startEmailCooldown();
      _toastSuccess('If an account exists, a reset link has been sent.');
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'invalid-email'          => 'Enter a valid email',
        'too-many-requests'      => 'Too many attempts; try again shortly',
        'network-request-failed' => 'Check your connection and try again',
        'user-not-found'         => 'If an account exists, a reset link has been sent.',
        _                        => 'Could not send reset email',
      };
      _toastError(msg);
    } finally {
      if (mounted) setState(() => _sendingEmail = false);
    }
  }

  Future<void> _checkProviderHint(String email) async {
    try {
      // debounce a bit while typing
      _emailHintDebounce?.cancel();
      _emailHintDebounce = Timer(const Duration(milliseconds: 320), () async {
        final methods = await _lookupMethods(email.toLowerCase());
        if (kDebugMode) debugPrint('[ForgotPassword] methods (final) for $email -> $methods');

        final hasPassword = methods.contains('password');
        _emailHasPasswordProvider = hasPassword;

        String? hint;
        if (methods.contains('google.com') && !hasPassword) {
          hint = 'Tip: This account usually signs in with Google. Try "Continue with Google".';
        } else if (methods.isNotEmpty && !hasPassword) {
          hint = 'Tip: This email uses ${methods.join(', ')} sign-in.';
        } else {
          hint = null; // password available or truly unknown
        }

        // If enumeration protection returns [], optionally show a Gmail heuristic hint
        if (hint == null && kShowGmailHeuristicHint) {
          final e = email.toLowerCase();
          final looksGmail = e.endsWith('@gmail.com') || e.endsWith('@googlemail.com');
          if (looksGmail) {
            hint = 'Tip: This account may use Google sign-in. Try "Continue with Google".';
          }
        }

        if (mounted) setState(() => _providerHint = hint);
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[ForgotPassword] fetchSignInMethods failed: $e');
      // keep hint optional
    }
  }

  Future<void> _startEmailCooldown() async {
    _emailTimer?.cancel();
    final untilMs = DateTime.now().millisecondsSinceEpoch + 60 * 1000;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kEmailCooldownUntilKey, untilMs);
    _runEmailTimer(untilMs);
  }

  void _runEmailTimer(int untilMs) {
    _tickEmailRemaining(untilMs);
    _emailTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      if (!mounted) return;
      final remaining = _secondsRemaining(untilMs);
      if (remaining <= 0) {
        t.cancel();
        setState(() => _emailCooldown = 0);
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_kEmailCooldownUntilKey);
      } else {
        setState(() => _emailCooldown = remaining);
      }
    });
  }

  int _secondsRemaining(int untilMs) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final diff = ((untilMs - nowMs) / 1000).ceil();
    return diff <= 0 ? 0 : diff;
  }

  void _tickEmailRemaining(int untilMs) {
    final remaining = _secondsRemaining(untilMs);
    setState(() => _emailCooldown = remaining);
  }

  Future<void> _restoreEmailCooldown() async {
    final prefs = await SharedPreferences.getInstance();
    final untilMs = prefs.getInt(_kEmailCooldownUntilKey);
    if (untilMs == null) return;
    final remaining = _secondsRemaining(untilMs);
    if (remaining > 0) {
      _runEmailTimer(untilMs);
    } else {
      await prefs.remove(_kEmailCooldownUntilKey);
    }
  }

  Future<void> _openEmailApp() async {
    final uri = Uri(scheme: 'mailto', path: '');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  void _goToLoginForGoogle() {
    _toastInfo('Use "Continue with Google" to sign in.');
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  // ---------- PHONE RESET ----------
  Future<void> _startPhoneVerification() async {
    final phone = _phoneCtl.text.trim();
    if (!phone.startsWith('+') || phone.length < 8) {
      _toastWarn('Enter phone in international format (e.g., +92…)');
      return;
    }
    setState(() => _busyPhone = true);
    await FirebaseAuth.instance.verifyPhoneNumber(
      phoneNumber: phone,
      forceResendingToken: _resendToken,
      verificationCompleted: (PhoneAuthCredential cred) async {
        try {
          final uc = await FirebaseAuth.instance.signInWithCredential(cred);
          await _afterPhoneSignIn(uc);
        } catch (_) {/* ignore */}
      },
      verificationFailed: (FirebaseAuthException e) {
        _toastError(
          e.code == 'too-many-requests'
              ? 'Too many attempts; wait a bit and retry'
              : 'Verification failed: ${e.message ?? e.code}',
        );
        setState(() => _busyPhone = false);
      },
      codeSent: (String verificationId, int? resendToken) {
        setState(() {
          _verificationId = verificationId;
          _resendToken = resendToken;
          _phoneStep = 1;
          _busyPhone = false;
        });
        _toastInfo('Code sent via SMS');
      },
      codeAutoRetrievalTimeout: (String verificationId) {
        _verificationId = verificationId;
      },
      timeout: const Duration(seconds: 60),
    );
  }

  Future<void> _verifySmsCode() async {
    if (_verificationId == null) {
      _toastWarn('Request a code first');
      return;
    }
    final code = _codeCtl.text.trim();
    if (code.length < 6) {
      _toastWarn('Enter the 6-digit code');
      return;
    }
    setState(() => _busyPhone = true);
    try {
      final cred = PhoneAuthProvider.credential(
        verificationId: _verificationId!,
        smsCode: code,
      );
      final uc = await FirebaseAuth.instance.signInWithCredential(cred);
      await _afterPhoneSignIn(uc);
    } on FirebaseAuthException catch (e) {
      _toastError(e.code == 'invalid-verification-code'
          ? 'Invalid code'
          : 'Could not verify code');
    } finally {
      if (mounted) setState(() => _busyPhone = false);
    }
  }

  Future<void> _afterPhoneSignIn(UserCredential uc) async {
    final isNew = uc.additionalUserInfo?.isNewUser ?? false;
    final user = uc.user;
    if (isNew) {
      try { await user?.delete(); } catch (_) {}
      await FirebaseAuth.instance.signOut();
      if (mounted) {
        setState(() => _phoneStep = 0);
        _toastWarn('This phone isn’t linked to an account. Use email reset or sign up.');
      }
      return;
    }
    if (mounted) {
      setState(() => _phoneStep = 2);
      _toastInfo('Phone verified. Set a new password.');
    }
  }

  Future<void> _setNewPassword() async {
    final p1 = _newPassCtl.text.trim();
    final p2 = _confirmCtl.text.trim();
    if (p1.length < 6) { _toastWarn('Password must be at least 6 characters'); return; }
    if (p1 != p2) { _toastWarn('Passwords do not match'); return; }

    setState(() => _busyPhone = true);
    try {
      final user = FirebaseAuth.instance.currentUser!;
      await user.updatePassword(p1);
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      _toastSuccess('Password updated. Sign in with your email and new password.');
      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      final msg = switch (e.code) {
        'requires-recent-login' => 'Session expired. Verify phone again.',
        _ => 'Could not update password',
      };
      _toastError(msg);
    } finally {
      if (mounted) setState(() => _busyPhone = false);
    }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final bool disableSend =
        (_sendingEmail || _emailCooldown > 0) ||
            (kResetOnlyWhenPasswordExists && !_emailHasPasswordProvider);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        foregroundColor: _ink,
        title: const Text(
          'Reset password',
          style: TextStyle(fontWeight: FontWeight.w800, color: _ink),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(62),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: _fieldBg,
                borderRadius: BorderRadius.circular(12),
              ),
              child: TabBar(
                controller: _tab,
                dividerColor: Colors.transparent,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700),
                unselectedLabelColor: _muted,
                labelColor: Colors.white,
                indicator: BoxDecoration(
                  color: _accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                tabs: const [
                  Tab(text: 'Email'),
                  Tab(text: 'Phone'),
                ],
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: TabBarView(
          controller: _tab,
          children: [
            _emailTab(disableSend),
            _phoneTab(),
          ],
        ),
      ),
    );
  }

  // -------- EMAIL TAB --------
  Widget _emailTab(bool disableSend) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'link shared on your email to reset your password.',
            style: TextStyle(color: _muted, fontSize: 14, height: 1.3),
          ),
          const SizedBox(height: 12),
          _filledField(
            controller: _emailCtl,
            focusNode: _emailFocus,
            label: 'Email',
            keyboardType: TextInputType.emailAddress,
            onChanged: (v) {
              if (v.contains('@')) {
                _checkProviderHint(v.trim().toLowerCase());
              } else {
                setState(() {
                  _providerHint = null;
                  _emailHasPasswordProvider = true;
                });
              }
            },
            onSubmitted: (_) {
              if (!disableSend) _sendEmailReset();
            },
          ),
          const SizedBox(height: 8),

          // Sleeker hint card
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeIn,
            child: (_providerHint != null && _providerHint!.isNotEmpty)
                ? Container(
              key: const ValueKey('hint'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: _lavTonal,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _accent.withOpacity(0.18)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, size: 18, color: _muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _providerHint!,
                          style: const TextStyle(fontSize: 13, color: _muted, height: 1.25),
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _goToLoginForGoogle,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: Image.asset('assets/images/GOOGLE.png',
                                width: 16, height: 16, fit: BoxFit.contain),
                            label: const Text(
                              'Continue with Google',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _ink,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            )
                : const SizedBox.shrink(key: ValueKey('nohint')),
          ),

          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: disableSend ? null : _sendEmailReset,
              style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                minimumSize: const Size.fromHeight(48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              child: Text(
                _emailCooldown > 0
                    ? 'Resend in $_emailCooldown s'
                    : (kResetOnlyWhenPasswordExists && !_emailHasPasswordProvider
                    ? 'Use Google sign-in'
                    : 'Send reset link'),
                style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _openEmailApp,
              icon: const Icon(Icons.email_outlined, color: _ink),
              label: const Text(
                'Open your email app',
                style: TextStyle(color: _ink, fontWeight: FontWeight.w600),
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                side: const BorderSide(color: _accent),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                foregroundColor: _ink,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------- PHONE TAB --------
  Widget _phoneTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: switch (_phoneStep) {
        0 => _phoneStep0(),
        1 => _phoneStep1(),
        2 => _phoneStep2(),
        _ => const SizedBox.shrink(),
      },
    );
  }

  Widget _phoneStep0() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Verify your phone to reset your password.',
            style: TextStyle(color: _muted, fontSize: 14)),
        const SizedBox(height: 12),
        _filledField(
          controller: _phoneCtl,
          label: 'Phone',
          keyboardType: TextInputType.phone,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busyPhone ? null : _startPhoneVerification,
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _busyPhone
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Send code', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  Widget _phoneStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Enter the 6-digit code we sent by SMS.',
            style: TextStyle(color: _muted, fontSize: 14)),
        const SizedBox(height: 12),
        _filledField(
          controller: _codeCtl,
          label: 'SMS code',
          keyboardType: TextInputType.number,
          maxLength: 6,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busyPhone ? null : _verifySmsCode,
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _busyPhone
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Verify', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
        TextButton(
          onPressed: _busyPhone ? null : _startPhoneVerification,
          child: const Text('Resend code', style: TextStyle(color: _ink, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }

  Widget _phoneStep2() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Create a new password for your account.',
            style: TextStyle(color: _muted, fontSize: 14)),
        const SizedBox(height: 12),
        _filledField(
          controller: _newPassCtl,
          label: 'New password',
          obscureText: true,
        ),
        const SizedBox(height: 12),
        _filledField(
          controller: _confirmCtl,
          label: 'Confirm password',
          obscureText: true,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _busyPhone ? null : _setNewPassword,
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _busyPhone
                ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Save new password', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }

  // ---------- Input helper ----------
  Widget _filledField({
    required TextEditingController controller,
    required String label,
    FocusNode? focusNode,
    bool obscureText = false,
    int? maxLength,
    TextInputType? keyboardType,
    void Function(String)? onSubmitted,
    void Function(String)? onChanged,
  }) {
    return TextField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      maxLength: maxLength,
      keyboardType: keyboardType,
      style: const TextStyle(fontSize: 16, color: _ink),
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        counterText: '',
        labelStyle: const TextStyle(color: _muted, fontWeight: FontWeight.w600),
        filled: true,
        fillColor: _fieldBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}
