// lib/screens/profile_screen.dart
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'edit_profile_screen.dart';
import 'login_screen.dart';
import 'provider_registration_screen.dart';
import 'provider_dashboard_screen.dart';

// NEW: link targets
import 'orders_history_screen.dart';
import 'favourites_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Data
  String? _username, _email, _phone, _city, _profileBase64;
  bool _loading = true;

  // Accent (match Search)
  Color get _primary => const Color(0xFF7966FA);

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }
    final doc =
    await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final data = doc.data();
    setState(() {
      _username = data?['username'] ?? '';
      _email = data?['email'] ?? '';
      _phone = data?['phone'] ?? '';
      _city = data?['city'] ?? '';
      _profileBase64 = data?['profile_image'];
      _loading = false;
    });
  }

  // ---------- Navigation helpers (BOTTOM SLIDE) ----------
  Future<void> _presentBottomPage(Widget page) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final h = MediaQuery.of(ctx).size.height;
        final viewInset = MediaQuery.of(ctx).viewInsets.bottom;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.only(bottom: viewInset),
          child: ClipRRect(
            child: SizedBox(
              height: h * 0.96,
              child: page, // page provides its own AppBar/status bar
            ),
          ),
        );
      },
    );
  }

  Future<void> _openOrders() => _presentBottomPage(const OrdersHistoryScreen());
  Future<void> _openFavourites() =>
      _presentBottomPage(const FavouritesScreen());

  // Actions
  Future<void> _logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('last_mode'); // do not touch onboarding_seen
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 300),
        pageBuilder: (_, __, ___) => const LoginScreen(),
        transitionsBuilder: (_, a, __, child) =>
            FadeTransition(opacity: a, child: child),
      ),
          (_) => false,
    );
  }

  Future<void> _openProviderMode() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_mode', 'provider');

    await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .set({'last_mode': 'provider'}, SetOptions(merge: true));

    final doc =
    await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final provider = doc.data()?['provider'];
    final status = provider != null ? provider['status'] : null;

    if (!mounted) return;
    if (status == 'approved') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ProviderDashboardScreen()),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const ProviderRegistrationScreen()),
      );
    }
  }

  void _inviteFriends() {
    Share.share('Check out Hazir Services app! Download now: [Your App Link]');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,

      // Simple AppBar like Search — no systemOverlayStyle here.
      appBar: AppBar(
        backgroundColor: _primary,
        elevation: 0,
        centerTitle: false,
        title: const Text(
          'Account',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: () {
              showModalBottomSheet(
                context: context,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius:
                  BorderRadius.vertical(top: Radius.circular(18)),
                ),
                builder: (_) => _settingsBottomSheet(),
              );
            },
            icon: const Icon(Icons.settings_outlined, color: Colors.white),
          ),
        ],
      ),

      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // Profile strip: avatar + name + View profile
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF6F7FB),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: const Color(0xFFE9ECF6),
                      backgroundImage: _profileBase64 == null
                          ? const AssetImage('assets/images/dp.png')
                      as ImageProvider
                          : MemoryImage(base64Decode(_profileBase64!)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (_username ?? '').isEmpty ? 'User' : _username!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.black87,
                              fontSize: 16.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) =>
                                    const EditProfileScreen()),
                              );
                              setState(() => _loading = true);
                              await _loadUserInfo();
                            },
                            child: Text(
                              'View profile',
                              style: TextStyle(
                                color: _primary,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // Brighter promo banner (solid accent + white text)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _proBannerBright(),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 16)),

          // Three compact boxes next to each other
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _quickBoxesRow(),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 16)),

          // Perks for you
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader('Perks for you'),
                  const SizedBox(height: 10),
                  _tile(
                    icon: Icons.workspace_premium_outlined,
                    title: 'HazirPro',
                    subtitle: 'Exclusive perks & faster service',
                    onTap: () {},
                  ),
                  _tile(
                    icon: Icons.confirmation_number_outlined,
                    title: 'Vouchers',
                    subtitle: 'Save with promo codes',
                    onTap: () {},
                  ),
                  _tile(
                    icon: Icons.card_giftcard_outlined,
                    title: 'Hazir Rewards',
                    subtitle: 'Earn points as you use Hazir',
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 22)),

          // General
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader('General'),
                  const SizedBox(height: 10),
                  _tile(
                    icon: Icons.help_outline_rounded,
                    title: 'Help Centre',
                    subtitle: 'FAQs & support',
                    onTap: () {},
                  ),
                  _tile(
                    icon: Icons.description_outlined,
                    title: 'Terms & Policies',
                    subtitle: 'Legal & data policy',
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 12)),

          // Provider Mode button
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _primaryButton(
                label: 'Provider Mode',
                icon: Icons.workspaces_outline,
                onTap: _openProviderMode,
              ),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 10)),

          // Logout
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _logoutTile(),
            ),
          ),

          const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  // ---------- UI Helpers ----------

  Widget _settingsBottomSheet() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              height: 4,
              width: 42,
              margin: const EdgeInsets.only(bottom: 14),
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(100),
              ),
            ),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Settings',
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 10),
            _tile(
              icon: Icons.color_lens_outlined,
              title: 'Theme',
              subtitle: 'Light / Dark',
              onTap: () => Navigator.pop(context),
            ),
            _tile(
              icon: Icons.group_add_outlined,
              title: 'Invite friends',
              subtitle: 'Share Hazir with friends',
              onTap: () {
                Navigator.pop(context);
                _inviteFriends();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // Brighter, solid banner (accent background)
  Widget _proBannerBright() {
    final r = BorderRadius.circular(14);
    return Material(
      color: _primary,
      borderRadius: r,
      child: InkWell(
        onTap: () {},
        borderRadius: r,
        splashColor: Colors.white24,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: Colors.white24,
                child: const Icon(Icons.workspace_premium,
                    color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Save with HazirPro',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Free for 14 days • Start your trial',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(width: 8),
              _chipButtonWhite(label: 'Try now', onTap: () {}),
            ],
          ),
        ),
      ),
    );
  }

  // 3 compact boxes side-by-side
  Widget _quickBoxesRow() {
    return Row(
      children: [
        _quickBox(
          icon: Icons.receipt_long_outlined,
          label: 'Orders',
          onTap: _openOrders,
        ),
        const SizedBox(width: 8),
        _quickBox(
          icon: Icons.favorite_border_rounded,
          label: 'Favourites',
          onTap: _openFavourites,
        ),
        const SizedBox(width: 8),
        _quickBox(
          icon: Icons.pin_drop_outlined,
          label: 'Addresses',
          onTap: () {}, // wire later
        ),
      ],
    );
  }

  Widget _quickBox({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    final r = BorderRadius.circular(12);
    return Expanded(
      child: Material(
        color: Colors.white,
        borderRadius: r,
        child: InkWell(
          onTap: onTap,
          borderRadius: r,
          splashColor: Colors.black12,
          highlightColor: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(color: Colors.black12),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.04),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: _primary, size: 30),
                const SizedBox(height: 5),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Shared tile (rounded splash; no square shade)
  Widget _tile({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    final r = BorderRadius.circular(12);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: const Color(0xFFF6F7FB),
        borderRadius: r,
        child: InkWell(
          onTap: onTap,
          borderRadius: r,
          splashColor: _primary.withOpacity(0.1),
          highlightColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: _primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.black87,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded, color: Colors.black45),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // Section header
  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Colors.black87,
        fontSize: 16,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
      ),
    );
  }

  Widget _logoutTile() {
    final r = BorderRadius.circular(12);
    return Material(
      color: const Color(0xFFF6F7FB),
      borderRadius: r,
      child: InkWell(
        onTap: _logout,
        borderRadius: r,
        splashColor: _primary.withOpacity(0.1),
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Row(
            children: const [
              Icon(Icons.logout, color: Colors.redAccent),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Log out',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: Colors.black45),
            ],
          ),
        ),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final r = BorderRadius.circular(12);
    return Material(
      color: _primary,
      borderRadius: r,
      child: InkWell(
        onTap: onTap,
        borderRadius: r,
        splashColor: Colors.white24,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Small white pill button in promo banner
  static Widget _chipButtonWhite({
    required String label,
    required VoidCallback onTap,
  }) {
    final r = BorderRadius.circular(20);
    return Material(
      color: Colors.white,
      borderRadius: r,
      child: InkWell(
        onTap: onTap,
        borderRadius: r,
        splashColor: Colors.black12,
        highlightColor: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.black87,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}


