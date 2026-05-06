// lib/screens/home_screen.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';

import 'gig_detail_screen.dart';
import 'search_screen.dart'; // for SearchResultsPage
import 'live_request_sheet.dart';

class HomeScreen extends StatefulWidget {
  final void Function(int index)? onNavigateToTab; // callback to switch tabs

  const HomeScreen({
    super.key,
    this.onNavigateToTab,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Initialize immediately to avoid LateInitializationError
  late final Future<String> _displayNameFuture = _fetchDisplayName();

  void _openSearchTab() {
    // Ask MainScreen to switch to Search tab (index 1)
    if (widget.onNavigateToTab != null) {
      widget.onNavigateToTab!(1);
    }
  }

  void _handleCategoryTap(String label) {
    // "See All" just jumps to Search tab
    if (label == "See All") {
      _openSearchTab();
      return;
    }

    // For real categories, open the full results page
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchResultsPage(initialQuery: label),
      ),
    );
  }

  Future<String> _fetchDisplayName() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return "Guest";

    final snap = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .get();

    if (snap.exists && snap.data() != null) {
      final data = snap.data()!;
      final name = (data['name'] as String?)?.trim() ?? '';
      final username = (data['username'] as String?)?.trim() ?? '';
      if (name.isNotEmpty) return name;
      if (username.isNotEmpty) return username;
    }
    return "User";
  }

  // Extracted function to handle Live Request tap
  void _handleLiveRequest() {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: false, // tap outside won't close
        barrierColor: Colors.black.withOpacity(0.35),
        pageBuilder: (context, animation, secondaryAnimation) {
          return const _LiveRequestOverlay();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = [
      {
        "name": "AC Repair",
        "icon": Icons.ac_unit_rounded,
        "color": const Color(0xFFFFE4D4)
      },
      {
        "name": "Plumbing",
        "icon": Icons.plumbing_rounded,
        "color": const Color(0xFFE4F8CE)
      },
      {
        "name": "Painting",
        "icon": Icons.format_paint_rounded,
        "color": const Color(0xFFD6F5F1)
      },
      {
        "name": "See All",
        "icon": Icons.arrow_forward_ios_rounded,
        "color": const Color(0xFFF5F6FA)
      },
    ];

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        toolbarHeight: 0,
        systemOverlayStyle: const SystemUiOverlayStyle(
          statusBarIconBrightness: Brightness.light,
          statusBarBrightness: Brightness.light,
        ),
      ),
      body: SafeArea(
        child: FutureBuilder<String>(
          future: _displayNameFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            String displayName = snapshot.data ?? "User";

            return SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // HEADER CARD
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF7966FA).withOpacity(0.4),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "HELLO $displayName 👋",
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF8B8B9D),
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(height: 7),
                          const Text(
                            "What you are looking\nfor today",
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF22223B),
                              height: 1.2,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 18),

                    // CATEGORIES CARD
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: SizedBox(
                        height: 84,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: categories.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 18),
                          itemBuilder: (ctx, idx) {
                            final cat = categories[idx];
                            final label = cat["name"] as String;
                            return _ServiceCategoryButton(
                              icon: cat["icon"] as IconData,
                              label: label,
                              color: cat["color"] as Color,
                              onTap: () => _handleCategoryTap(label),
                              isLast: idx == categories.length - 1,
                            );
                          },
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),

                    // CLEANING SERVICES CARD
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Section Title
                          Row(
                            children: [
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8),
                                child: Text(
                                  "Cleaning Services",
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 17,
                                    color: Color(0xFF22223B),
                                  ),
                                ),
                              ),
                              const Spacer(),
                              TextButton(
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => SearchResultsPage(
                                        initialQuery: 'Cleaning',
                                      ),
                                    ),
                                  );
                                },
                                style: TextButton.styleFrom(
                                  foregroundColor: const Color(0xFF22223B),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                                  textStyle: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                                child: const Text("See All"),
                              ),
                            ],
                          ),
                          // Horizontal List of REAL Cleaning Gigs
                          SizedBox(
                            height: 180,
                            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                              stream: FirebaseFirestore.instance
                                  .collection('gigs')
                                  .where('status', isEqualTo: 'active')
                                  .where('category', isEqualTo: 'Cleaning')
                                  .limit(10)
                                  .snapshots(),
                              builder: (context, snapshot) {
                                if (snapshot.connectionState == ConnectionState.waiting) {
                                  return const Center(child: CircularProgressIndicator());
                                }

                                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                                  return const Center(
                                    child: Text(
                                      'No cleaning services yet',
                                      style: TextStyle(
                                        color: Color(0xFF8B8B9D),
                                        fontSize: 13,
                                      ),
                                    ),
                                  );
                                }

                                final docs = snapshot.data!.docs;

                                return ListView.separated(
                                  scrollDirection: Axis.horizontal,
                                  itemCount: docs.length,
                                  separatorBuilder: (_, __) => const SizedBox(width: 18),
                                  itemBuilder: (ctx, idx) {
                                    final doc = docs[idx];
                                    return _CleaningServiceCard(doc: doc);
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 100), // Extra space for FAB area
                  ],
                ),
              ),
            );
          },
        ),
      ),
      // ─────────────────────────────────────────────────────────
      // RESPONSIVE FAB GROUP (Banner + Button)
      // This guarantees the banner stays attached to the button on any screen size
      // ─────────────────────────────────────────────────────────
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // The Blinking Banner (Tappable)
          GestureDetector(
            onTap: _handleLiveRequest,
            child: const _BlinkingBanner(),
          ),
          const SizedBox(width: 10), // Spacing between banner and button
          // The actual Plus Button
          FloatingActionButton(
            onPressed: _handleLiveRequest,
            shape: const CircleBorder(),
            backgroundColor: const Color(0xFF7966FA),
            child: const Icon(Icons.add, size: 32, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

/* ── Small widgets ───────────────────────────────── */

class _BlinkingBanner extends StatefulWidget {
  const _BlinkingBanner();

  @override
  State<_BlinkingBanner> createState() => _BlinkingBannerState();
}

class _BlinkingBannerState extends State<_BlinkingBanner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // 2.5 seconds for a slower, calmer blink
    _controller = AnimationController(
      duration: const Duration(milliseconds: 2500),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF7966FA), Color(0xFF9B8FFF)],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF7966FA).withOpacity(0.4),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "To Request Live, Tap Here",
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 13,
                letterSpacing: 0.3,
              ),
            ),
            SizedBox(width: 6),
            Icon(
              Icons.arrow_forward_rounded, // Points right -> towards the FAB
              color: Colors.white,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

class _ServiceCategoryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  final bool isLast;

  const _ServiceCategoryButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          borderRadius: BorderRadius.circular(50),
          child: InkWell(
            borderRadius: BorderRadius.circular(50),
            onTap: onTap,
            child: Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              child: Icon(
                icon,
                size: label == "See All" ? 24 : 28,
                color: label == "See All"
                    ? const Color(0xFFB8B8CB)
                    : const Color(0xFF446CFF),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color:
            isLast ? const Color(0xFFB8B8CB) : const Color(0xFF22223B),
            fontWeight: isLast ? FontWeight.w500 : FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _CleaningServiceCard extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  const _CleaningServiceCard({
    required this.doc,
  });

  @override
  Widget build(BuildContext context) {
    final m = doc.data();

    final title = (m['title'] ?? 'Untitled').toString();

    final photosB64 =
        (m['photosB64'] as List?)?.cast<String>() ?? const <String>[];
    final photos =
        (m['photos'] as List?)?.cast<String>() ?? const <String>[];

    ImageProvider? imageProvider;
    if (photosB64.isNotEmpty) {
      try {
        imageProvider = MemoryImage(base64Decode(photosB64.first));
      } catch (_) {}
    }
    if (imageProvider == null && photos.isNotEmpty) {
      final url = photos.first.toString();
      if (url.isNotEmpty) {
        imageProvider = NetworkImage(url);
      }
    }

    String? discount;
    final promo = m['promoLabel'];
    if (promo is String && promo.trim().isNotEmpty) {
      discount = promo.trim();
    }

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GigDetailScreen(
              gigId: doc.id,
              data: m,
            ),
          ),
        );
      },
      child: Container(
        width: 135,
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 2,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Service Image
            Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                  child: imageProvider != null
                      ? Image(
                    image: imageProvider,
                    width: 135,
                    height: 85,
                    fit: BoxFit.cover,
                  )
                      : Container(
                    width: 135,
                    height: 85,
                    color: const Color(0xFFEDEBFF),
                    child: const Icon(
                      Icons.image_outlined,
                      color: Color(0xFF7966FA),
                    ),
                  ),
                ),
                if (discount != null)
                  Positioned(
                    left: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.redAccent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        discount!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                  color: Color(0xFF22223B),
                ),
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }
}

class _LiveRequestOverlay extends StatelessWidget {
  const _LiveRequestOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.transparent,
      body: LiveRequestSheet(),
    );
  }
}