// lib/screens/edit_profile_screen.dart
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  // THEME TOKENS (match your global pattern)
  static const Color _accent = Color(0xFF7966FA);
  static const Color _ok = Color(0xFF12B76A);
  static const Color _info = Color(0xFF3B82F6);
  static const Color _warn = Color(0xFFF59E0B);
  static const Color _danger = Color(0xFFEF4444);

  static const Color _fieldBg = Color(0xFFF6F7FB);
  static const Color _fieldBorder = Color(0xFFE2E3E9);

  static const Color _headerColor = _accent;
  static const Color _bgCard = Color(0xFFF6F7FB);

  // Controllers
  final TextEditingController _nameC = TextEditingController();
  final TextEditingController _usernameC = TextEditingController();
  final TextEditingController _emailC = TextEditingController();
  final TextEditingController _phoneC = TextEditingController();

  // Data
  bool _loading = true;
  bool _emailVerified = false;
  bool _phoneVerified = false; // wire to real field if you add verification
  bool _hasPasswordProvider = false;
  String? _base64Image;

  // Connected providers
  bool _googleConnected = false;
  bool _facebookConnected = false;
  bool _appleConnected = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameC.dispose();
    _usernameC.dispose();
    _emailC.dispose();
    _phoneC.dispose();
    super.dispose();
  }

  // ===================== Toasts (global pattern) =====================
  void _toast({
    required String msg,
    required IconData icon,
    required Color color,
  }) {
    final snack = SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
      backgroundColor: Colors.white,
      elevation: 6,
      margin: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(snack);
  }

  void _toastSuccess(String msg) =>
      _toast(msg: msg, icon: Icons.check_circle_rounded, color: _ok);
  void _toastInfo(String msg) =>
      _toast(msg: msg, icon: Icons.info_rounded, color: _info);
  void _toastWarn(String msg) =>
      _toast(msg: msg, icon: Icons.warning_amber_rounded, color: _warn);
  void _toastError(String msg) =>
      _toast(msg: msg, icon: Icons.error_rounded, color: _danger);

  // ===================== Username helpers =====================
  String _slugify(String input) {
    final v = input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
    return v.isEmpty ? 'user' : v;
  }

  Future<bool> _reserveUsernameIfAvailable(String username, String uid) async {
    final ref = FirebaseFirestore.instance.collection('usernames').doc(username);
    return FirebaseFirestore.instance.runTransaction<bool>((tx) async {
      final snap = await tx.get(ref);
      if (snap.exists) return false; // taken
      tx.set(ref, {
        'uid': uid,
        'created_at': FieldValue.serverTimestamp(),
      });
      return true;
    });
  }

  // ===================== Phone normalization =====================
  String _normalizePhone(String raw, {String defaultCountry = 'PK'}) {
    String v = raw.trim().replaceAll(RegExp(r'\s+|-|\(|\)'), '');

    if (RegExp(r'^\+\d{8,15}$').hasMatch(v)) return v;

    final pkLocal = RegExp(r'^03\d{9}$');
    final inLocal = RegExp(r'^[6-9]\d{9}$');
    final usLocal = RegExp(r'^[2-9]\d{2}[2-9]\d{6}$');
    final uaeLocal = RegExp(r'^05\d{8}$');
    final ksaLocal = RegExp(r'^05\d{8}$');

    if (pkLocal.hasMatch(v)) return '+92${v.substring(1)}';
    if (inLocal.hasMatch(v)) return '+91$v';
    if (usLocal.hasMatch(v)) return '+1$v';
    if (uaeLocal.hasMatch(v)) return '+971${v.substring(1)}';
    if (ksaLocal.hasMatch(v)) return '+966${v.substring(1)}';

    switch (defaultCountry.toUpperCase()) {
      case 'PK':
        if (RegExp(r'^\d{10,11}$').hasMatch(v)) {
          if (v.length == 10 && v.startsWith('3')) return '+923$v';
          if (v.length == 11 && v.startsWith('03')) return '+92${v.substring(1)}';
        }
        break;
      case 'IN':
        if (inLocal.hasMatch(v)) return '+91$v';
        break;
      case 'US':
      case 'CA':
        if (usLocal.hasMatch(v)) return '+1$v';
        break;
      case 'AE':
        if (uaeLocal.hasMatch(v)) return '+971${v.substring(1)}';
        break;
      case 'SA':
        if (ksaLocal.hasMatch(v)) return '+966${v.substring(1)}';
        break;
    }

    throw const FormatException('Invalid phone format. Try +923001234567 or 03001234567');
  }

  // ===================== Load profile =====================
  Future<void> _load() async {
    final user = FirebaseAuth.instance.currentUser;

    if (user == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    _emailVerified = user.emailVerified;
    _googleConnected = user.providerData.any((p) => p.providerId == 'google.com');
    _facebookConnected = user.providerData.any((p) => p.providerId == 'facebook.com');
    _appleConnected = user.providerData.any((p) => p.providerId == 'apple.com');
    _hasPasswordProvider = user.providerData.any((p) => p.providerId == 'password');

    final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final data = doc.data() ?? {};

    _nameC.text = (data['name'] ?? '').toString();
    _usernameC.text = (data['username'] ?? '').toString();
    _emailC.text = (data['email'] ?? user.email ?? '').toString();
    _phoneC.text = (data['phone'] ?? user.phoneNumber ?? '').toString();
    _base64Image = data['profile_image'];

    if (mounted) setState(() => _loading = false);
  }

  // ===================== Reusable input decoration =====================
  InputDecoration _decoration({
    required String label,
    String? hint,
    Widget? suffix,
    String? helperText,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helperText,
      filled: true,
      fillColor: _fieldBg,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      labelStyle: const TextStyle(fontSize: 12.5, color: Colors.black54),
      hintStyle: const TextStyle(fontSize: 13.5, color: Colors.black45),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _fieldBorder, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _danger, width: 1.25),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: _danger, width: 1.25),
      ),
      suffixIcon: suffix,
    );
  }

  // ===================== UI Actions =====================
  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.gallery);
    if (img == null) return;

    final bytes = await File(img.path).readAsBytes();
    final b64 = base64Encode(bytes);

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set({'profile_image': b64}, SetOptions(merge: true));

    if (!mounted) return;
    setState(() => _base64Image = b64);
    _toastSuccess('Profile photo updated');
  }

  Future<void> _saveName(String newName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set({'name': newName}, SetOptions(merge: true));

    if (!mounted) return;
    setState(() => _nameC.text = newName);
    _toastSuccess('Name updated');
  }

  // ===== FIXED: All reads occur before any writes inside the transaction =====
  Future<void> _saveUsername(String requested) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final desired = _slugify(requested.trim());
    if (desired.length < 3) {
      _toastError('Username must be at least 3 characters');
      return;
    }

    final uid = user.uid;
    final usersCol = FirebaseFirestore.instance.collection('users');
    final usernamesCol = FirebaseFirestore.instance.collection('usernames');
    final userRef = usersCol.doc(uid);
    final currentUsername = _usernameC.text.trim();

    if (desired == currentUsername) {
      _toastInfo('Username unchanged');
      return;
    }

    try {
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final newRef = usernamesCol.doc(desired);

        // ---- READS (must be before any writes) ----
        final newSnap = await tx.get(newRef);

        DocumentReference<Map<String, dynamic>>? oldRef;
        DocumentSnapshot<Map<String, dynamic>>? oldSnap;
        if (currentUsername.isNotEmpty) {
          oldRef = usernamesCol.doc(currentUsername);
          oldSnap = await tx.get(oldRef);
        }

        // If desired is taken by someone else, block
        if (newSnap.exists && newSnap.data()?['uid'] != uid) {
          throw Exception('TAKEN');
        }

        // ---- WRITES (after all reads) ----
        // 1) Update user doc
        tx.set(userRef, {'username': desired}, SetOptions(merge: true));

        // 2) Upsert reservation for new username (idempotent if already yours)
        tx.set(newRef, {
          'uid': uid,
          'created_at': FieldValue.serverTimestamp(),
        });

        // 3) Remove old reservation if it belonged to this user and is different
        if (oldRef != null &&
            oldSnap != null &&
            oldSnap.exists &&
            oldSnap.data()?['uid'] == uid &&
            oldRef.id != newRef.id) {
          tx.delete(oldRef);
        }
      });

      if (!mounted) return;
      setState(() => _usernameC.text = desired);
      _toastSuccess('Username updated');
    } catch (e) {
      final msg = e.toString().contains('TAKEN')
          ? 'Sorry, "$desired" is taken. Try another.'
          : 'Error updating username';
      _toastError(msg);
    }
  }

  Future<void> _savePhone(String requested, {String defaultCountry = 'PK'}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final normalized = _normalizePhone(requested, defaultCountry: defaultCountry);
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'phone': normalized}, SetOptions(merge: true));

      if (!mounted) return;
      setState(() => _phoneC.text = normalized);
      _toastSuccess('Mobile number saved');
    } on FormatException catch (e) {
      _toastError(e.message);
    } catch (_) {
      _toastError('Error saving phone');
    }
  }

  Future<void> _sendEmailVerification() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await user.sendEmailVerification();
      _toastSuccess('Verification email sent');
    } catch (_) {
      _toastError('Could not send verification email');
    }
  }

  // ===================== Dialogs with compact fields =====================
  Future<void> _editNameDialog() async {
    final c = TextEditingController(text: _nameC.text);
    bool showErrors = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          return AlertDialog(
            title: const Text('Edit name'),
            content: Form(
              autovalidateMode:
              showErrors ? AutovalidateMode.always : AutovalidateMode.disabled,
              child: TextFormField(
                controller: c,
                textInputAction: TextInputAction.done,
                decoration: _decoration(label: 'Name', hint: 'Your full name'),
                validator: (v) => (v == null || v.trim().length < 2)
                    ? 'Please enter a valid name'
                    : null,
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  setD(() => showErrors = true);
                  if (c.text.trim().length < 2) return;
                  Navigator.pop(ctx);
                  await _saveName(c.text.trim());
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editUsernameDialog() async {
    final c = TextEditingController(text: _usernameC.text);
    bool showErrors = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          return AlertDialog(
            title: const Text('Edit username'),
            content: Form(
              autovalidateMode:
              showErrors ? AutovalidateMode.always : AutovalidateMode.disabled,
              child: TextFormField(
                controller: c,
                textInputAction: TextInputAction.done,
                decoration: _decoration(
                  label: 'Username',
                  hint: 'letters & numbers only',
                ),
                validator: (v) {
                  final s = (v ?? '').trim();
                  if (s.isEmpty) return 'Enter a username';
                  if (s.length < 3) return 'Must be at least 3 characters';
                  if (!RegExp(r'^[a-zA-Z0-9]+$').hasMatch(s)) {
                    return 'Only letters and numbers';
                  }
                  return null;
                },
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  setD(() => showErrors = true);
                  final s = c.text.trim();
                  if (s.isEmpty || s.length < 3 || !RegExp(r'^[a-zA-Z0-9]+$').hasMatch(s)) {
                    return;
                  }
                  Navigator.pop(ctx);
                  await _saveUsername(s);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editPhoneDialog() async {
    final c = TextEditingController(text: _phoneC.text);
    String inferredCountry = 'PK';
    final p = c.text.trim();
    if (p.startsWith('+92') || p.startsWith('03')) inferredCountry = 'PK';
    else if (p.startsWith('+91')) inferredCountry = 'IN';
    else if (p.startsWith('+971') || RegExp(r'^05\d{8}$').hasMatch(p)) inferredCountry = 'AE';
    else if (p.startsWith('+966')) inferredCountry = 'SA';
    else if (p.startsWith('+1')) inferredCountry = 'US';

    bool showErrors = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          return AlertDialog(
            title: const Text('Edit mobile number'),
            content: Form(
              autovalidateMode:
              showErrors ? AutovalidateMode.always : AutovalidateMode.disabled,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _fieldBorder),
                      color: _fieldBg,
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: inferredCountry,
                        onChanged: (val) => setD(() {
                          inferredCountry = val ?? 'PK';
                        }),
                        items: const [
                          DropdownMenuItem(
                            value: 'PK',
                            child: _CountryItem(label: 'Pakistan (+92)', flag: '🇵🇰'),
                          ),
                          DropdownMenuItem(
                            value: 'IN',
                            child: _CountryItem(label: 'India (+91)', flag: '🇮🇳'),
                          ),
                          DropdownMenuItem(
                            value: 'AE',
                            child: _CountryItem(label: 'UAE (+971)', flag: '🇦🇪'),
                          ),
                          DropdownMenuItem(
                            value: 'SA',
                            child: _CountryItem(label: 'Saudi Arabia (+966)', flag: '🇸🇦'),
                          ),
                          DropdownMenuItem(
                            value: 'US',
                            child: _CountryItem(label: 'United States (+1)', flag: '🇺🇸'),
                          ),
                          DropdownMenuItem(
                            value: 'CA',
                            child: _CountryItem(label: 'Canada (+1)', flag: '🇨🇦'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: c,
                    keyboardType: TextInputType.phone,
                    decoration: _decoration(
                      label: 'Mobile number',
                      hint: 'e.g. +923001234567 or 03001234567',
                    ),
                    validator: (v) {
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return 'Enter your mobile number';
                      if (s.length < 10) return 'Enter a valid number';
                      return null;
                    },
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  setD(() => showErrors = true);
                  if ((c.text.trim()).length < 10) return;
                  Navigator.pop(ctx);
                  await _savePhone(c.text, defaultCountry: inferredCountry);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _changePasswordDialog() async {
    final currentC = TextEditingController();
    final newC = TextEditingController();
    final fCurrent = FocusNode();
    final fNew = FocusNode();
    bool showCurrent = false;
    bool showNew = false;
    bool showErrors = false;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final hasPasswordProvider =
    user.providerData.any((p) => p.providerId == 'password');

    if (!hasPasswordProvider || (user.email == null || user.email!.isEmpty)) {
      _toastInfo(
          'Your account uses Google/Apple/Facebook. Link an email & password first or use "Forgot password".');
      return;
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          void _resetEyes() {
            if (!fCurrent.hasFocus) setD(() => showCurrent = false);
            if (!fNew.hasFocus) setD(() => showNew = false);
          }

          fCurrent.addListener(_resetEyes);
          fNew.addListener(_resetEyes);

          return AlertDialog(
            title: const Text('Change password'),
            content: Form(
              autovalidateMode:
              showErrors ? AutovalidateMode.always : AutovalidateMode.disabled,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: currentC,
                    focusNode: fCurrent,
                    obscureText: !showCurrent,
                    decoration: _decoration(
                      label: 'Current password',
                      suffix: fCurrent.hasFocus
                          ? IconButton(
                        icon: Icon(
                          showCurrent ? Icons.visibility_off : Icons.visibility,
                          color: Colors.black45,
                        ),
                        onPressed: () => setD(() => showCurrent = !showCurrent),
                      )
                          : null,
                    ),
                    validator: (v) =>
                    (v == null || v.isEmpty) ? 'Enter current password' : null,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: newC,
                    focusNode: fNew,
                    obscureText: !showNew,
                    decoration: _decoration(
                      label: 'New password',
                      suffix: fNew.hasFocus
                          ? IconButton(
                        icon: Icon(
                          showNew ? Icons.visibility_off : Icons.visibility,
                          color: Colors.black45,
                        ),
                        onPressed: () => setD(() => showNew = !showNew),
                      )
                          : null,
                    ),
                    validator: (v) =>
                    (v == null || v.length < 6) ? 'Min 6 characters' : null,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  setD(() => showErrors = true);
                  if ((currentC.text).isEmpty || (newC.text).length < 6) return;
                  Navigator.pop(ctx);

                  try {
                    final cred = EmailAuthProvider.credential(
                      email: user.email!,
                      password: currentC.text.trim(),
                    );
                    await user.reauthenticateWithCredential(cred);
                    await user.updatePassword(newC.text.trim());
                    _toastSuccess('Password updated');
                  } on FirebaseAuthException catch (e) {
                    if (e.code == 'wrong-password') {
                      _toastError('Current password is incorrect');
                    } else if (e.code == 'too-many-requests') {
                      _toastWarn('Too many attempts. Try again later.');
                    } else {
                      _toastError('Auth error: ${e.code}');
                    }
                  } catch (_) {
                    _toastError('Error updating password');
                  }
                },
                child: const Text('Update'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _linkEmailPasswordDialog() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final emailC = TextEditingController(text: _emailC.text);
    final passC = TextEditingController();

    final fPass = FocusNode();
    bool showPass = false;
    bool showErrors = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          fPass.addListener(() {
            if (!fPass.hasFocus) setD(() => showPass = false);
          });

          return AlertDialog(
            title: const Text('Link email & password'),
            content: Form(
              autovalidateMode:
              showErrors ? AutovalidateMode.always : AutovalidateMode.disabled,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: emailC,
                    keyboardType: TextInputType.emailAddress,
                    decoration: _decoration(label: 'Email', hint: 'you@example.com'),
                    validator: (v) {
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return 'Enter email';
                      final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(s);
                      return ok ? null : 'Enter a valid email';
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: passC,
                    focusNode: fPass,
                    obscureText: !showPass,
                    decoration: _decoration(
                      label: 'New password',
                      suffix: fPass.hasFocus
                          ? IconButton(
                        icon: Icon(
                          showPass ? Icons.visibility_off : Icons.visibility,
                          color: Colors.black45,
                        ),
                        onPressed: () => setD(() => showPass = !showPass),
                      )
                          : null,
                    ),
                    validator: (v) =>
                    (v == null || v.length < 6) ? 'Min 6 characters' : null,
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () async {
                  setD(() => showErrors = true);
                  final validEmail =
                  RegExp(r'^[^@]+@[^@]+\.[^@]+$').hasMatch(emailC.text.trim());
                  if (!validEmail || passC.text.length < 6) return;

                  Navigator.pop(ctx);
                  try {
                    final cred = EmailAuthProvider.credential(
                      email: emailC.text.trim(),
                      password: passC.text.trim(),
                    );
                    await user.linkWithCredential(cred);

                    await FirebaseFirestore.instance
                        .collection('users')
                        .doc(user.uid)
                        .set({'email': emailC.text.trim()}, SetOptions(merge: true));

                    await user.reload();
                    final refreshed = FirebaseAuth.instance.currentUser;
                    _hasPasswordProvider =
                        refreshed?.providerData.any((p) => p.providerId == 'password') ??
                            true;

                    if (mounted) {
                      setState(() {
                        _emailC.text = emailC.text.trim();
                      });
                    }
                    _toastSuccess('Email & password linked to your account');
                  } on FirebaseAuthException catch (e) {
                    if (e.code == 'provider-already-linked') {
                      _toastInfo('Email/password already linked.');
                    } else if (e.code == 'email-already-in-use') {
                      _toastError('That email is already used by another account.');
                    } else if (e.code == 'requires-recent-login') {
                      _toastInfo('Please re-login and try linking again.');
                    } else {
                      _toastError('Auth error: ${e.code}');
                    }
                  } catch (_) {
                    _toastError('Error linking email/password');
                  }
                },
                child: const Text('Link'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _verifyPhone() async {
    _toastInfo('Phone verification coming soon');
  }

  Future<void> _disconnect(String providerId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await user.unlink(providerId);
      await user.reload();

      final fresh = FirebaseAuth.instance.currentUser;
      if (fresh != null) {
        _googleConnected = fresh.providerData.any((p) => p.providerId == 'google.com');
        _facebookConnected = fresh.providerData.any((p) => p.providerId == 'facebook.com');
        _appleConnected = fresh.providerData.any((p) => p.providerId == 'apple.com');
        _hasPasswordProvider = fresh.providerData.any((p) => p.providerId == 'password');
      }

      if (!mounted) return;
      setState(() {});
      _toastSuccess('Disconnected');
    } catch (_) {
      _toastError('Could not disconnect');
    }
  }

  // ===================== BUILD =====================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(), // tap-to-unfocus
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            // Top bar
            Container(
              color: _headerColor,
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top,
                left: 8,
                right: 8,
              ),
              child: SizedBox(
                height: 50,
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'Profile',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),

            // Header with avatar
            Container(
              width: double.infinity,
              color: _headerColor,
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
              child: Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 110,
                      height: 110,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withOpacity(0.95),
                            Colors.white.withOpacity(0.75),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.08),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.all(4),
                      child: CircleAvatar(
                        radius: 51,
                        backgroundColor: _accent.withOpacity(0.08),
                        backgroundImage: (_base64Image != null && _base64Image!.isNotEmpty)
                            ? MemoryImage(base64Decode(_base64Image!))
                            : const AssetImage('assets/images/dp.png') as ImageProvider,
                      ),
                    ),
                    Positioned(
                      right: -2,
                      bottom: -2,
                      child: GestureDetector(
                        onTap: _pickPhoto,
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.15),
                                blurRadius: 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(7),
                          child: const Icon(Icons.edit, size: 18, color: _accent),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Scrollable content
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Container(
                  width: double.infinity,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sectionHeader('Personal details'),
                      const SizedBox(height: 8),

                      // Name
                      _rowTile(
                        leading: const Icon(Icons.person_outline, color: _accent),
                        title: 'Name',
                        subtitle: _nameC.text.isEmpty ? '—' : _nameC.text,
                        trailing: _smallAction('Edit', _editNameDialog),
                      ),

                      // Username
                      _rowTile(
                        leading: const Icon(Icons.tag, color: _accent),
                        title: 'Username',
                        subtitle: _usernameC.text.isEmpty ? '—' : _usernameC.text,
                        trailing: _smallAction('Edit', _editUsernameDialog),
                      ),

                      // Email
                      _rowTile(
                        leading: const Icon(Icons.alternate_email, color: _accent),
                        title: 'Email',
                        subtitle: _emailC.text,
                        trailing: !_emailVerified
                            ? _outlinedChip('Verify', onTap: _sendEmailVerification)
                            : _verifiedChip(),
                      ),

                      // Password
                      _rowTile(
                        leading:
                        const Icon(Icons.lock_outline_rounded, color: _accent),
                        title: 'Password',
                        subtitle: _hasPasswordProvider ? '••••••••' : 'Not set',
                        trailing: _hasPasswordProvider
                            ? _smallAction('Change', _changePasswordDialog)
                            : const SizedBox.shrink(),
                      ),

                      // Phone
                      _rowTile(
                        leading: const Icon(Icons.phone_iphone, color: _accent),
                        title: 'Mobile number',
                        subtitle: _phoneC.text.isEmpty ? '—' : _phoneC.text,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _smallAction('Edit', _editPhoneDialog),
                            const SizedBox(width: 12),
                            !_phoneVerified
                                ? _outlinedChip('Verify', onTap: _verifyPhone)
                                : _verifiedChip(),
                          ],
                        ),
                      ),

                      const SizedBox(height: 18),

                      _sectionHeader('Connected accounts'),
                      const SizedBox(height: 8),

                      if (!_hasPasswordProvider)
                        _connectRow(
                          icon: Icons.alternate_email_rounded,
                          label: 'Email & Password',
                          connected: false,
                          onDisconnect: () {},
                          onConnect: _linkEmailPasswordDialog,
                        ),

                      _connectRow(
                        icon: Icons.g_mobiledata_rounded,
                        label: 'Google',
                        connected: _googleConnected,
                        onDisconnect: () => _disconnect('google.com'),
                        onConnect: () => _toastInfo('Connect Google coming soon'),
                      ),
                      _connectRow(
                        icon: Icons.facebook_rounded,
                        label: 'Facebook',
                        connected: _facebookConnected,
                        onDisconnect: () => _disconnect('facebook.com'),
                        onConnect: () => _toastInfo('Connect Facebook coming soon'),
                      ),
                      _connectRow(
                        icon: Icons.apple_rounded,
                        label: 'Apple',
                        connected: _appleConnected,
                        onDisconnect: () => _disconnect('apple.com'),
                        onConnect: () => _toastInfo('Connect Apple coming soon'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ===================== Small UI builders =====================
  Widget _sectionHeader(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 14.5,
        fontWeight: FontWeight.w700,
        color: Colors.black87,
      ),
    );
  }

  Widget _rowTile({
    required Widget leading,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Colors.black54,
                    )),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 10),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _smallAction(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Text(
        label,
        style: const TextStyle(
          color: _accent,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _outlinedChip(String label, {required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _accent, width: 1.2),
          ),
          child: Text(
            label,
            style: const TextStyle(
              color: _accent,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _verifiedChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F3FF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Text(
        'Verified',
        style: TextStyle(
          color: _accent,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _connectRow({
    required IconData icon,
    required String label,
    required bool connected,
    required VoidCallback onDisconnect,
    required VoidCallback onConnect,
  }) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: _bgCard,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: _accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                color: Colors.black87,
              ),
            ),
          ),
          if (connected)
            IconButton(
              tooltip: 'Disconnect',
              onPressed: onDisconnect,
              icon: const Icon(Icons.close_rounded, color: Colors.black54),
            )
          else
            _smallAction('Connect', onConnect),
        ],
      ),
    );
  }
}

class _CountryItem extends StatelessWidget {
  final String label;
  final String flag;
  const _CountryItem({required this.label, required this.flag});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(flag, style: const TextStyle(fontSize: 16)),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 14)),
      ],
    );
  }
}
