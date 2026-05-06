import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main_screen.dart';
import 'provider_dashboard_screen.dart';

class ProviderRegistrationScreen extends StatefulWidget {
  const ProviderRegistrationScreen({super.key});

  @override
  State<ProviderRegistrationScreen> createState() => _ProviderRegistrationScreenState();
}

class _ProviderRegistrationScreenState extends State<ProviderRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final picker = ImagePicker();

  final TextEditingController nameController = TextEditingController();
  final TextEditingController phoneController = TextEditingController();
  String? selectedCity;
  final Set<String> selectedProfessions = {};

  // --- Images ---
  File? selfieImage; // NEW: Selfie File
  File? cnicFront;
  File? cnicBack;
  List<File> experienceImages = [];

  // In-memory for restoring
  String? _base64Selfie; // NEW: Restore string
  String? _base64Front, _base64Back;
  List<String>? _base64ExperienceList;

  // one-time autofill from user profile
  bool _prefilledFromProfile = false;

  final List<String> cities = const [
    'Karachi', 'Lahore', 'Islamabad', 'Rawalpindi', 'Faisalabad', 'Multan',
    'Peshawar', 'Quetta', 'Sialkot', 'Gujranwala', 'Hyderabad', 'Sargodha',
    'Bahawalpur', 'Sukkur', 'Jhelum'
  ];

  final List<Map<String, dynamic>> professions = const [
    {'label': 'Cleaning', 'icon': 'assets/images/cleaning.png'},
    {'label': 'Plumber', 'icon': 'assets/images/plumber.png'},
    {'label': 'Electrician', 'icon': 'assets/images/electrician.png'},
    {'label': 'Carpenter', 'icon': 'assets/images/carpenter.png'},
    {'label': 'Mechanic', 'icon': 'assets/images/mechanic.png'},
    {'label': 'Beauty', 'icon': 'assets/images/park.png'},
    {'label': 'Freelancer', 'icon': 'assets/images/drawing.png'},
  ];

  Stream<DocumentSnapshot>? _userStream;

  @override
  void initState() {
    super.initState();
    _attachUserStream();
  }

  void _attachUserStream() {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      setState(() {
        _userStream = FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots();
      });
    }
  }

  Future<void> _setLastMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_mode', mode);
  }

  Future<void> _prefillFromUserProfile(Map<String, dynamic> userDoc) async {
    if (_prefilledFromProfile) return;

    final String? name = (userDoc['name'] ?? userDoc['username'])?.toString();
    final String? phone = userDoc['phone']?.toString();
    final String? city  = userDoc['city']?.toString();

    if (nameController.text.isEmpty && name != null) nameController.text = name;
    if (phoneController.text.isEmpty && phone != null) phoneController.text = phone;
    if (selectedCity == null && city != null && cities.contains(city)) {
      selectedCity = city;
    }

    _prefilledFromProfile = true;
    if (mounted) setState(() {});
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    // NEW: Validation for Selfie
    if (selfieImage == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please upload a Selfie for verification')));
      return;
    }

    if (cnicFront == null || cnicBack == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please upload CNIC images')));
      return;
    }
    if (selectedProfessions.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please select at least one profession')));
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // --- Convert images to base64
    // NEW: Selfie Conversion
    final String base64Selfie = base64Encode(await selfieImage!.readAsBytes());

    final String base64Front = base64Encode(await cnicFront!.readAsBytes());
    final String base64Back  = base64Encode(await cnicBack!.readAsBytes());
    final List<String> base64ExperienceList = [];
    for (final img in experienceImages) {
      base64ExperienceList.add(base64Encode(await img.readAsBytes()));
    }

    // --- Prepare provider data
    final providerData = {
      'status': 'pending',
      'name': nameController.text.trim(),
      'phone': phoneController.text.trim(),
      'city': selectedCity,
      'professions': selectedProfessions.toList(),
      // NEW: Add Selfie field
      'selfie_image': base64Selfie,
      'cnic_front': base64Front,
      'cnic_back': base64Back,
      'experience_images': base64ExperienceList,
      'services': [],
      'reviews': [],
      'payment_history': [],
      'submitted_at': FieldValue.serverTimestamp(),
      'review': {
        'notes': null,
        'reviewer_uid': null,
        'reviewed_at': null,
      },
    };

    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'provider': providerData,
      'last_mode': 'provider',
    }, SetOptions(merge: true));
    await _setLastMode('provider');

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Registration Submitted'),
        content: const Text('Your provider registration is under review. You will be notified once approved.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      ),
    );
  }

  void _switchToSeeker() async {
    await _setLastMode("seeker");
    if (!mounted) return;
    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainScreen()));
  }

  Future<void> _restoreProviderFields(Map<String, dynamic> provider) async {
    nameController.text = (provider['name'] ?? '').toString();
    phoneController.text = (provider['phone'] ?? '').toString();
    selectedCity = provider['city']?.toString();

    selectedProfessions.clear();
    if (provider['professions'] is List) {
      for (var p in provider['professions']) {
        selectedProfessions.add(p.toString());
      }
    }

    // Images
    _base64Selfie = provider['selfie_image']; // NEW
    _base64Front = provider['cnic_front'];
    _base64Back  = provider['cnic_back'];
    _base64ExperienceList = List<String>.from(provider['experience_images'] ?? []);

    // NEW: Restore Selfie
    if (_base64Selfie != null) {
      final tmp = await _writeTempImage(_base64Selfie!);
      if (tmp != null) selfieImage = tmp;
    }

    if (_base64Front != null) {
      final tmp = await _writeTempImage(_base64Front!);
      if (tmp != null) cnicFront = tmp;
    }
    if (_base64Back != null) {
      final tmp = await _writeTempImage(_base64Back!);
      if (tmp != null) cnicBack = tmp;
    }

    experienceImages.clear();
    if (_base64ExperienceList != null) {
      for (final b64 in _base64ExperienceList!) {
        final tmp = await _writeTempImage(b64);
        if (tmp != null) experienceImages.add(tmp);
      }
    }
    if (mounted) setState(() {});
  }

  Future<File?> _writeTempImage(String b64) async {
    try {
      final bytes = base64Decode(b64);
      final tmp = await File('${Directory.systemTemp.path}/${DateTime.now().millisecondsSinceEpoch}.jpg')
          .writeAsBytes(bytes);
      return tmp;
    } catch (_) {
      return null;
    }
  }

  Future<void> _pickImage(Function(File) onPick) async {
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked != null) onPick(File(picked.path));
  }

  // NEW: Specific picker for Selfie (can force Camera if needed, but keeping consistent for now)
  Future<void> _pickSelfie() async {
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 70); // Camera preferred for selfie
    if (picked != null) {
      setState(() => selfieImage = File(picked.path));
    }
  }

  Future<void> _pickExperienceImage() async {
    if (experienceImages.length >= 3) return;
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked != null && mounted) setState(() => experienceImages.add(File(picked.path)));
  }

  @override
  Widget build(BuildContext context) {
    final dark = Colors.black;
    final accent = const Color(0xFF7966FA);

    return Scaffold(
      backgroundColor: dark,
      appBar: AppBar(
        backgroundColor: dark,
        foregroundColor: Colors.white,
        centerTitle: true,
        elevation: 0,
        title: const Text('Provider Registration', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 21)),
        automaticallyImplyLeading: false,
      ),
      body: _userStream == null
          ? const Center(child: CircularProgressIndicator())
          : StreamBuilder<DocumentSnapshot>(
        stream: _userStream,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final doc = snapshot.data!;
          final userMap = (doc.data() as Map?)?.map((k, v) => MapEntry(k.toString(), v));
          final providerRaw = (userMap?['provider'] as Map?)?.map((k, v) => MapEntry(k.toString(), v));
          final String? status = providerRaw?['status']?.toString();

          if (providerRaw == null && userMap != null && !_prefilledFromProfile) {
            Future.microtask(() => _prefillFromUserProfile(userMap));
          }

          if (providerRaw != null &&
              (status == 'pending' || status == 'rejected') &&
              nameController.text.isEmpty &&
              phoneController.text.isEmpty &&
              selectedCity == null) {
            Future.microtask(() => _restoreProviderFields(providerRaw));
          }

          if (status == 'approved') {
            Future.microtask(() async {
              await _setLastMode("provider");
              if (!mounted) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (_) => const ProviderDashboardScreen()),
              );
            });
            return const Center(child: CircularProgressIndicator());
          }

          if (status == 'pending') {
            return Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 12),
                  color: Colors.orange.shade900,
                  child: Row(
                    children: const [
                      Icon(Icons.info_outline, color: Colors.white, size: 24),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "Your provider registration is under review. You will be notified when approved.",
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 15.3),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 30),
                Expanded(child: _registrationForm(accent, disabled: true)),
              ],
            );
          }

          if (status == 'rejected') {
            return Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
                  color: Colors.red.shade700,
                  child: Row(
                    children: const [
                      Icon(Icons.warning_amber_rounded, color: Colors.white, size: 24),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          "Your provider registration was rejected. Please review and update your details.",
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 15.3),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 25),
                Expanded(child: _registrationForm(accent, disabled: false)),
              ],
            );
          }

          return _registrationForm(accent, disabled: false);
        },
      ),
    );
  }

  Widget _registrationForm(Color accent, {required bool disabled}) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: nameController,
                    style: const TextStyle(color: Colors.white),
                    enabled: !disabled,
                    decoration: _inputDeco('Full Name'),
                    validator: (v) => v == null || v.isEmpty ? 'Enter your name' : null,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: TextFormField(
                    controller: phoneController,
                    style: const TextStyle(color: Colors.white),
                    keyboardType: TextInputType.phone,
                    enabled: !disabled,
                    decoration: _inputDeco('Phone'),
                    validator: (v) => v == null || v.isEmpty ? 'Enter phone' : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),

            DropdownButtonFormField<String>(
              value: selectedCity,
              dropdownColor: const Color(0xFF1E1E1E),
              style: const TextStyle(color: Colors.white),
              iconEnabledColor: Colors.white70,
              iconDisabledColor: Colors.white38,
              decoration: _inputDeco('City').copyWith(
                filled: true,
                fillColor: accent.withOpacity(0.18),
                hintStyle: const TextStyle(color: Colors.white54),
              ),
              items: cities
                  .map(
                    (c) => DropdownMenuItem(
                  value: c,
                  child: Text(c, style: const TextStyle(color: Colors.white)),
                ),
              )
                  .toList(),
              onChanged: disabled ? null : (v) => setState(() => selectedCity = v),
              validator: (v) => v == null ? 'Select city' : null,
            ),

            const SizedBox(height: 22),

            const Text(
              "Select Profession(s)",
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 78,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: professions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 13),
                itemBuilder: (context, i) {
                  final p = professions[i];
                  final isSelected = selectedProfessions.contains(p['label']);
                  return GestureDetector(
                    onTap: disabled
                        ? null
                        : () {
                      setState(() {
                        if (isSelected) {
                          selectedProfessions.remove(p['label']);
                        } else {
                          selectedProfessions.add(p['label']);
                        }
                      });
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: isSelected ? accent : Colors.white10,
                        borderRadius: BorderRadius.circular(15),
                        border: isSelected ? Border.all(color: accent, width: 2) : null,
                        boxShadow: isSelected
                            ? [BoxShadow(color: accent.withOpacity(0.11), blurRadius: 8, offset: const Offset(0, 4))]
                            : [],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Image.asset(p['icon'], width: 32, height: 32),
                          const SizedBox(height: 4),
                          Text(
                            p['label'],
                            style: TextStyle(
                              color: isSelected ? Colors.white : Colors.white70,
                              fontWeight: FontWeight.w500,
                              fontSize: 13.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 20),

            // --- NEW: Selfie Upload Section ---
            const Text(
              "Identity Verification",
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: disabled ? null : _pickSelfie,
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        color: Colors.white12,
                        shape: BoxShape.circle,
                        border: Border.all(color: accent.withOpacity(0.5), width: 1.5),
                        image: selfieImage != null
                            ? DecorationImage(image: FileImage(selfieImage!), fit: BoxFit.cover)
                            : null,
                      ),
                      child: selfieImage == null
                          ? const Icon(Icons.camera_alt_rounded, color: Colors.white70, size: 28)
                          : null,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Upload Your Selfie", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text(
                          "This photo will be used to match with your CNIC for verification purposes.",
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // --- CNIC Upload ---
            const Text(
              "CNIC Documents",
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _uploadBox(
                  file: cnicFront,
                  label: "CNIC Front",
                  onPick: disabled ? null : () => _pickImage((f) => setState(() => cnicFront = f)),
                ),
                const SizedBox(width: 16),
                _uploadBox(
                  file: cnicBack,
                  label: "CNIC Back",
                  onPick: disabled ? null : () => _pickImage((f) => setState(() => cnicBack = f)),
                ),
              ],
            ),

            const SizedBox(height: 20),

            const Text(
              "Previous Work Experience (Images)",
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 15),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 78,
              child: Row(
                children: [
                  ...experienceImages.map(
                        (img) => Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: Stack(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(img, width: 68, height: 68, fit: BoxFit.cover),
                          ),
                          if (!disabled)
                            Positioned(
                              top: -7,
                              right: -7,
                              child: IconButton(
                                icon: const Icon(Icons.cancel, color: Colors.redAccent, size: 20),
                                onPressed: () => setState(() => experienceImages.remove(img)),
                                splashRadius: 15,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (experienceImages.length < 3 && !disabled)
                    GestureDetector(
                      onTap: _pickExperienceImage,
                      child: Container(
                        width: 68,
                        height: 68,
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: accent, width: 1.2),
                        ),
                        child: const Icon(Icons.add_a_photo, color: Colors.white54, size: 28),
                      ),
                    ),
                ],
              ),
            ),

            const SizedBox(height: 26),

            if (!disabled)
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.check_circle_outline, color: Colors.white, size: 22),
                  label: const Text(
                    "Submit for Approval",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accent,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
                  ),
                  onPressed: _submit,
                ),
              ),

            if (!disabled) const SizedBox(height: 17),

            SizedBox(
              width: double.infinity,
              height: 44,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.sync_alt, color: Color(0xFF7966FA), size: 22),
                label: const Text(
                  "Switch to Seeker Mode",
                  style: TextStyle(
                    color: Color(0xFF7966FA),
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF7966FA), width: 1.5),
                  backgroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _switchToSeeker,
              ),
            ),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint) {
    final accent = const Color(0xFF7966FA);
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      filled: true,
      fillColor: accent.withOpacity(0.18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    );
  }

  Widget _uploadBox({required File? file, required String label, required VoidCallback? onPick}) {
    final accent = const Color(0xFF7966FA);
    return Expanded(
      child: GestureDetector(
        onTap: onPick,
        child: Container(
          height: 84,
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: accent.withOpacity(0.4)),
          ),
          child: file == null
              ? Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.add_photo_alternate_outlined, color: Colors.white54, size: 27),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
            ],
          )
              : ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Image.file(file, width: double.infinity, height: 84, fit: BoxFit.cover),
          ),
        ),
      ),
    );
  }
}