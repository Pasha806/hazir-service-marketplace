import 'dart:convert';
import 'dart:math';
import 'dart:ui';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'admin_login.dart';

// --- THEME CONSTANTS ---
const Color _accent = Color(0xFF7966FA);
const Color _text = Color(0xFF2D3436);
const Color _subText = Color(0xFF636E72);
const Color _success = Color(0xFF00B894);
const Color _danger = Color(0xFFD63031);
const Color _bg = Color(0xFFF7F8FA);

// Lavender Gradient
const LinearGradient _lavenderGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [
    Color(0xFFF8F7FF), // Very Light Lavender
    Color(0xFFECE6FF), // Soft Lavender
    Color(0xFFF5F7FA), // Soft White
  ],
);

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> with SingleTickerProviderStateMixin {
  int _selectedIndex = 0;
  String _myRole = 'employee';
  bool _loadingRole = true;
  bool _isSidebarOpen = true;
  late AnimationController _bgAnimController;

  @override
  void initState() {
    super.initState();
    _fetchMyRole();
    _bgAnimController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _bgAnimController.dispose();
    super.dispose();
  }

  Future<void> _fetchMyRole() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (mounted) {
        setState(() {
          _myRole = doc.data()?['role'] ?? 'employee';
          _loadingRole = false;
        });
      }
    } catch (e) {
      debugPrint("Error fetching role: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingRole) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }

    final bool isSuperAdmin = _myRole == 'admin';

    // Page mapping: Stats is now Index 0
    final List<Widget> pages = [
      const _StatsDashboardView(), // Analytics
      const _ProviderApprovalsView(),
      _UserManagementView(isSuperAdmin: isSuperAdmin),
      const _GigManagementView(),
      const _ReportsPlaceholderView(),
    ];

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: _lavenderGradient),
        child: Stack(
          children: [
            // --- Background Ambience ---
            Positioned(
              right: -100,
              bottom: -100,
              child: AnimatedBuilder(
                animation: _bgAnimController,
                builder: (context, child) {
                  return Transform.translate(
                    offset: Offset(0, 50 * _bgAnimController.value),
                    child: Transform.rotate(
                      angle: 0.05 * _bgAnimController.value,
                      child: Opacity(
                        opacity: 0.04,
                        child: Image.asset('assets/images/HAZIR_LOGO.png', width: 800),
                      ),
                    ),
                  );
                },
              ),
            ),

            // --- Layout ---
            Row(
              children: [
                _ModernSidebar(
                  selectedIndex: _selectedIndex,
                  role: _myRole,
                  isOpen: _isSidebarOpen,
                  onItemSelected: (index) => setState(() => _selectedIndex = index),
                  onLogout: () async {
                    await FirebaseAuth.instance.signOut();
                    if (!mounted) return;
                    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AdminLoginScreen()));
                  },
                ),

                // Main Content
                Expanded(
                  child: Column(
                    children: [
                      // Header
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 24, 24, 10),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => setState(() => _isSidebarOpen = !_isSidebarOpen),
                              icon: Icon(_isSidebarOpen ? Icons.menu_open_rounded : Icons.menu_rounded, color: _text),
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white,
                                shadowColor: Colors.black12,
                                elevation: 2,
                              ),
                            ),
                            const SizedBox(width: 16),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _getHeaderTitle(_selectedIndex),
                                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: _text),
                                ),
                                Text(
                                  "Overview & Management",
                                  style: TextStyle(fontSize: 13, color: _subText.withOpacity(0.8)),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),

                      // Glass Card Content
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.7),
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(color: Colors.white.withOpacity(0.6), width: 1),
                              boxShadow: [
                                BoxShadow(color: _accent.withOpacity(0.05), blurRadius: 20, offset: const Offset(0, 10)),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                                child: pages[_selectedIndex],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _getHeaderTitle(int index) {
    switch (index) {
      case 0: return "Analytics & Stats";
      case 1: return "Provider Approvals";
      case 2: return "User Management";
      case 3: return "Service Gigs";
      case 4: return "Reports & Flags";
      default: return "Dashboard";
    }
  }
}

// ==============================================================================
// 1. IMPROVED SIDEBAR (Fixed Icons & Smooth Hover)
// ==============================================================================
class _ModernSidebar extends StatelessWidget {
  final int selectedIndex;
  final String role;
  final bool isOpen;
  final Function(int) onItemSelected;
  final VoidCallback onLogout;

  const _ModernSidebar({
    required this.selectedIndex,
    required this.role,
    required this.isOpen,
    required this.onItemSelected,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.fastOutSlowIn,
      width: isOpen ? 250 : 80,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 20)],
      ),
      child: Column(
        children: [
          // Logo Section
          SizedBox(
            height: 100,
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                child: isOpen
                    ? Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset('assets/images/HAZIR_LOGO.png', height: 40),
                    const SizedBox(height: 5),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(color: _accent.withOpacity(0.1), borderRadius: BorderRadius.circular(20)),
                      child: Text(role.toUpperCase(), style: const TextStyle(color: _accent, fontSize: 9, fontWeight: FontWeight.bold, letterSpacing: 1)),
                    )
                  ],
                )
                    : Image.asset('assets/images/HAZIR_LOGO.png', height: 30),
              ),
            ),
          ),

          Divider(height: 1, color: Colors.grey.withOpacity(0.1)),
          const SizedBox(height: 20),

          // Menu Items
          _HoverableTile(icon: Icons.bar_chart_rounded, label: "Analytics", isSelected: selectedIndex == 0, isOpen: isOpen, onTap: () => onItemSelected(0)),
          _HoverableTile(icon: Icons.verified_user_outlined, label: "Approvals", isSelected: selectedIndex == 1, isOpen: isOpen, onTap: () => onItemSelected(1)),
          _HoverableTile(icon: Icons.people_outline, label: "Users", isSelected: selectedIndex == 2, isOpen: isOpen, onTap: () => onItemSelected(2)),
          _HoverableTile(icon: Icons.work_outline, label: "Gigs", isSelected: selectedIndex == 3, isOpen: isOpen, onTap: () => onItemSelected(3)),
          _HoverableTile(icon: Icons.flag_outlined, label: "Reports", isSelected: selectedIndex == 4, isOpen: isOpen, onTap: () => onItemSelected(4)),

          const Spacer(),

          // Logout
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: InkWell(
              onTap: onLogout,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.logout, color: Colors.red, size: 20),
                    if (isOpen) ...[
                      const SizedBox(width: 8),
                      const Text("Logout", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HoverableTile extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final bool isOpen;
  final VoidCallback onTap;

  const _HoverableTile({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.isOpen,
    required this.onTap,
  });

  @override
  State<_HoverableTile> createState() => _HoverableTileState();
}

class _HoverableTileState extends State<_HoverableTile> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovering = true),
        onExit: (_) => setState(() => _isHovering = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: EdgeInsets.symmetric(vertical: 14, horizontal: widget.isOpen ? 16 : 0),
            // FIX: Always Center content if closed, Left align if open
            alignment: widget.isOpen ? Alignment.centerLeft : Alignment.center,
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? _accent
                  : (_isHovering ? _accent.withOpacity(0.05) : Colors.transparent),
              borderRadius: BorderRadius.circular(14),
              boxShadow: widget.isSelected
                  ? [BoxShadow(color: _accent.withOpacity(0.4), blurRadius: 8, offset: const Offset(0, 4))]
                  : [],
            ),
            child: widget.isOpen
            // OPEN STATE: Icon + Text
                ? Row(
              children: [
                Icon(widget.icon, color: widget.isSelected ? Colors.white : _subText, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: widget.isSelected ? Colors.white : _subText,
                      fontWeight: widget.isSelected ? FontWeight.w700 : FontWeight.w500,
                      fontSize: 14,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.isSelected) const Icon(Icons.chevron_right, color: Colors.white, size: 16),
              ],
            )
            // CLOSED STATE: Icon Only (Centered, no Text)
                : Icon(widget.icon, color: widget.isSelected ? Colors.white : _subText, size: 24),
          ),
        ),
      ),
    );
  }
}

// ==============================================================================
// 2. NEW STATS & ANALYTICS VIEW
// ==============================================================================
class _StatsDashboardView extends StatelessWidget {
  const _StatsDashboardView();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Platform Overview", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _text)),
          const SizedBox(height: 20),

          // --- COUNTER CARDS STREAM ---
          StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('users').snapshots(),
            builder: (context, userSnap) {
              // We also need gig counts, so we can nest streams or use a combinator.
              // For simplicity in this structure, we nest the Gig stream.
              return StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance.collection('gigs').snapshots(),
                builder: (context, gigSnap) {

                  if (!userSnap.hasData || !gigSnap.hasData) return const LinearProgressIndicator(color: _accent);

                  // User Stats
                  final users = userSnap.data!.docs;
                  final totalUsers = users.length;
                  final providers = users.where((u) => (u.data() as Map)['role'] == 'provider' || (u.data() as Map)['last_mode'] == 'provider').length;
                  final employees = users.where((u) => (u.data() as Map)['role'] == 'employee').length;
                  final admins = users.where((u) => (u.data() as Map)['role'] == 'admin').length;
                  final seekers = totalUsers - (providers + employees + admins);

                  // Gig Stats
                  final gigs = gigSnap.data!.docs;
                  final totalGigs = gigs.length;

                  // Placeholder Data (Since collections might not exist yet)
                  final reportsCount = 0; // Replace with reports collection query later
                  final proUsers = (totalUsers * 0.15).round(); // Mock: 15% are Pro
                  final downloads = 12500 + totalUsers; // Mock: Base + live users

                  return Column(
                    children: [
                      // --- ROW 1: PRIMARY STATS ---
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          _StatCard(title: "Total Users", value: "$totalUsers", icon: Icons.group, color: Colors.blue, width: 220),
                          _StatCard(title: "Providers", value: "$providers", icon: Icons.engineering, color: _accent, width: 220),
                          _StatCard(title: "Seekers", value: "$seekers", icon: Icons.person_search, color: Colors.orange, width: 220),
                          _StatCard(title: "Active Gigs", value: "$totalGigs", icon: Icons.work, color: Colors.green, width: 220),
                        ],
                      ),
                      const SizedBox(height: 24),

                      // --- ROW 2: DETAILED STATS ---
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: [
                          _StatCard(title: "Total Admins", value: "$admins", icon: Icons.admin_panel_settings, color: Colors.purple, width: 160, isSmall: true),
                          _StatCard(title: "Employees", value: "$employees", icon: Icons.badge, color: Colors.teal, width: 160, isSmall: true),
                          _StatCard(title: "Reports", value: "$reportsCount", icon: Icons.flag, color: _danger, width: 160, isSmall: true),
                          _StatCard(title: "Hazir Pro", value: "$proUsers", icon: Icons.star, color: Colors.amber, width: 160, isSmall: true),
                          _StatCard(title: "Downloads", value: "${(downloads/1000).toStringAsFixed(1)}k", icon: Icons.cloud_download, color: Colors.cyan, width: 160, isSmall: true),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // --- ROW 3: CHARTS ---
                      // FIX: Increased height from 300 to 350 to prevent overflow
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Bar Chart
                          Expanded(
                            flex: 2,
                            child: Container(
                              height: 350,
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 15)],
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text("User Distribution", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _text)),
                                  const SizedBox(height: 40),
                                  Expanded(
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        _ChartBar(label: "Seekers", value: seekers, color: Colors.orange, max: totalUsers),
                                        _ChartBar(label: "Providers", value: providers, color: _accent, max: totalUsers),
                                        _ChartBar(label: "Employees", value: employees, color: Colors.teal, max: totalUsers),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 20),
                          // Pie Chart
                          Expanded(
                            flex: 1,
                            child: Container(
                              height: 350,
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.8),
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 15)],
                              ),
                              child: Column(
                                children: [
                                  const Text("Demographics", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: _text)),
                                  const SizedBox(height: 20),
                                  Expanded(
                                    child: CustomPaint(
                                      painter: _PieChartPainter(
                                        [
                                          _PieSegment(seekers.toDouble(), Colors.orange),
                                          _PieSegment(providers.toDouble(), _accent),
                                          _PieSegment(employees.toDouble(), Colors.teal),
                                        ],
                                        totalUsers > 0 ? totalUsers.toDouble() : 1.0,
                                      ),
                                      child: Center(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text("$totalUsers", style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: _text)),
                                            const Text("Users", style: TextStyle(fontSize: 12, color: _subText)),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  // Legend
                                  Wrap(
                                    spacing: 10,
                                    children: [
                                      _LegendItem(color: Colors.orange, label: "Seeker"),
                                      _LegendItem(color: _accent, label: "Provider"),
                                      _LegendItem(color: Colors.teal, label: "Emp"),
                                    ],
                                  )
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final double width;
  final bool isSmall;

  const _StatCard({required this.title, required this.value, required this.icon, required this.color, required this.width, this.isSmall = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: EdgeInsets.all(isSmall ? 16 : 24),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: color.withOpacity(0.1), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(isSmall ? 8 : 12),
            decoration: BoxDecoration(color: color.withOpacity(0.1), shape: BoxShape.circle),
            child: Icon(icon, color: color, size: isSmall ? 20 : 28),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: _subText, fontSize: isSmall ? 11 : 13, fontWeight: FontWeight.w600)),
              Text(value, style: TextStyle(color: _text, fontSize: isSmall ? 18 : 26, fontWeight: FontWeight.bold)),
            ],
          ),
        ],
      ),
    );
  }
}

class _ChartBar extends StatelessWidget {
  final String label;
  final int value;
  final Color color;
  final int max;

  const _ChartBar({required this.label, required this.value, required this.color, required this.max});

  @override
  Widget build(BuildContext context) {
    double percentage = max == 0 ? 0 : (value / max);

    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text("$value", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
        const SizedBox(height: 8),
        Expanded(
          child: LayoutBuilder(
              builder: (ctx, constraints) {
                return Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    Container(width: 30, color: Colors.grey.withOpacity(0.1)),
                    TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0, end: percentage),
                      duration: const Duration(seconds: 1),
                      curve: Curves.easeOutBack,
                      builder: (context, val, _) {
                        return Container(
                          width: 30,
                          height: constraints.maxHeight * val,
                          decoration: BoxDecoration(
                            color: color,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
                          ),
                        );
                      },
                    ),
                  ],
                );
              }
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: _subText, fontSize: 12)),
      ],
    );
  }
}

// --- Custom Pie Chart Helpers ---
class _PieSegment {
  final double value;
  final Color color;
  _PieSegment(this.value, this.color);
}

class _PieChartPainter extends CustomPainter {
  final List<_PieSegment> segments;
  final double total;
  _PieChartPainter(this.segments, this.total);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width / 2, size.height / 2);
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()..style = PaintingStyle.stroke..strokeWidth = 20;

    double startAngle = -pi / 2;
    for (var segment in segments) {
      final sweepAngle = (segment.value / total) * 2 * pi;
      paint.color = segment.color;
      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
      startAngle += sweepAngle;
    }
  }
  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

class _LegendItem extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendItem({required this.color, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12, color: _subText))
    ]);
  }
}

// ==============================================================================
// 3. PROVIDER APPROVALS VIEW
// ==============================================================================
class _ProviderApprovalsView extends StatelessWidget {
  const _ProviderApprovalsView();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('users').where('provider.status', isEqualTo: 'pending').snapshots(),
      builder: (ctx, snap) {
        if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: _accent));
        final docs = snap.data!.docs;

        if (docs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: _success.withOpacity(0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: _success.withOpacity(0.3), width: 2),
                  ),
                  child: const Icon(Icons.verified_user_rounded, size: 60, color: _success),
                ),
                const SizedBox(height: 16),
                const Text("All Caught Up!", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _text)),
                const SizedBox(height: 8),
                const Text("There are no pending provider applications.", style: TextStyle(color: _subText)),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(20),
          itemCount: docs.length,
          itemBuilder: (ctx, i) {
            final doc = docs[i];
            final p = (doc.data() as Map)['provider'] ?? {};
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.6),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.02), blurRadius: 8)],
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                leading: CircleAvatar(
                  radius: 24,
                  backgroundColor: _accent.withOpacity(0.1),
                  child: const Icon(Icons.person, color: _accent),
                ),
                title: Text(p['name'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text("Applied for: ${(p['professions'] as List?)?.join(', ') ?? 'None'}", style: const TextStyle(color: _subText)),
                ),
                trailing: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    elevation: 4,
                    shadowColor: _accent.withOpacity(0.5),
                  ),
                  onPressed: () => _showReviewDialog(context, doc.id, p),
                  child: const Text("Review Application"),
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showReviewDialog(BuildContext context, String uid, Map p) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: "Review",
      pageBuilder: (_, __, ___) => _GlassReviewDialog(uid: uid, data: p),
      transitionBuilder: (ctx, anim, _, child) {
        return Transform.scale(scale: CurvedAnimation(parent: anim, curve: Curves.elasticOut).value, child: child);
      },
    );
  }
}

// GLASS REVIEW DIALOG
class _GlassReviewDialog extends StatelessWidget {
  final String uid;
  final Map data;
  const _GlassReviewDialog({required this.uid, required this.data});

  Widget _img(String? b64, String label) {
    if (b64 == null || b64.isEmpty) {
      return Container(
        height: 200,
        decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(12)),
        alignment: Alignment.center,
        child: const Text("No Image", style: TextStyle(color: Colors.grey)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, left: 4),
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: _subText)),
        ),
        Container(
          height: 250,
          width: double.infinity,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.withOpacity(0.3)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.memory(base64Decode(b64), fit: BoxFit.contain),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          width: 900,
          height: 750,
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.95),
            borderRadius: BorderRadius.circular(24),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.15), blurRadius: 40)],
          ),
          child: Column(
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Review Application", style: TextStyle(color: _subText, fontSize: 14)),
                      Text(data['name'] ?? 'Unknown Applicant', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: _text)),
                    ],
                  ),
                  IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded, size: 28)),
                ],
              ),
              const SizedBox(height: 20),
              const Divider(),

              // Scrollable Content
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 20),
                      // Info Grid
                      Wrap(
                        spacing: 20,
                        runSpacing: 20,
                        children: [
                          _infoBox(Icons.location_on_outlined, "City", data['city']),
                          _infoBox(Icons.phone_outlined, "Phone", data['phone']),
                          _infoBox(Icons.calendar_today_outlined, "Submitted",
                              data['submitted_at'] != null
                                  ? DateFormat('dd MMM yyyy').format((data['submitted_at'] as Timestamp).toDate())
                                  : 'N/A'
                          ),
                        ],
                      ),
                      const SizedBox(height: 30),

                      // Images Section
                      const Text("Verification Documents", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: _text)),
                      const SizedBox(height: 15),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _img(data['selfie_image'], "SELFIE (LIVE)")),
                          const SizedBox(width: 15),
                          Expanded(child: _img(data['cnic_front'], "CNIC FRONT")),
                          const SizedBox(width: 15),
                          Expanded(child: _img(data['cnic_back'], "CNIC BACK")),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 20),

              // Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text("Cancel", style: TextStyle(color: _subText)),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.red.withOpacity(0.1),
                      foregroundColor: Colors.red,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.close_rounded),
                    label: const Text("Reject"),
                    onPressed: () {
                      FirebaseFirestore.instance.collection('users').doc(uid).set(
                          {'provider': {'status': 'rejected'}}, SetOptions(merge: true));
                      Navigator.pop(context);
                      _toast(context, "Application Rejected", isError: true);
                    },
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _success,
                      foregroundColor: Colors.white,
                      elevation: 4,
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      shadowColor: _success.withOpacity(0.4),
                    ),
                    icon: const Icon(Icons.check_rounded),
                    label: const Text("Approve Provider"),
                    onPressed: () {
                      FirebaseFirestore.instance.collection('users').doc(uid).set(
                          {'provider': {'status': 'approved'}}, SetOptions(merge: true));
                      Navigator.pop(context);
                      _toast(context, "Provider Approved Successfully");
                    },
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _infoBox(IconData icon, String title, String? value) {
    return Container(
      width: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _bg, // Error was here - now resolved with _bg constant
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: _accent, size: 20),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 12, color: _subText)),
              Text(value ?? '-', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: _text)),
            ],
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? _danger : _success,
      behavior: SnackBarBehavior.floating,
      width: 400,
    ));
  }
}

// ==============================================================================
// 4. USER MANAGEMENT
// ==============================================================================
class _UserManagementView extends StatefulWidget {
  final bool isSuperAdmin;
  const _UserManagementView({required this.isSuperAdmin});

  @override
  State<_UserManagementView> createState() => _UserManagementViewState();
}

class _UserManagementViewState extends State<_UserManagementView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchText = "";
  String _selectedRoleFilter = "All";
  final List<String> _roleOptions = const ['All', 'Seeker', 'Provider', 'Employee', 'Admin'];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Top Toolbar
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: _WebTextField(
                  controller: _searchCtrl,
                  hint: "Search users...",
                  icon: Icons.search,
                  onChanged: (v) => setState(() => _searchText = v.toLowerCase()),
                ),
              ),
              const SizedBox(width: 16),
              _WebDropdown(
                value: _selectedRoleFilter,
                items: _roleOptions,
                onChanged: (v) => setState(() => _selectedRoleFilter = v!),
              ),
              const SizedBox(width: 16),
              if (widget.isSuperAdmin)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 4,
                  ),
                  onPressed: () => _openAddStaffDialog(),
                  icon: const Icon(Icons.add_rounded),
                  label: const Text("Add Staff"),
                ),
            ],
          ),
        ),

        // User List
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('users').limit(200).snapshots(),
            builder: (ctx, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: _accent));

              final allUsers = snap.data!.docs;

              // Filtering
              final filteredUsers = allUsers.where((doc) {
                final m = doc.data() as Map;
                final name = (m['name'] ?? m['username'] ?? '').toString().toLowerCase();
                final email = (m['email'] ?? '').toString().toLowerCase();
                final phone = (m['phone'] ?? '').toString().toLowerCase();

                final bool matchesText = _searchText.isEmpty || name.contains(_searchText) || email.contains(_searchText) || phone.contains(_searchText);

                bool matchesRole = true;
                final String roleField = (m['role'] ?? '').toString().toLowerCase();
                final String lastMode = (m['last_mode'] ?? 'seeker').toString().toLowerCase();

                if (_selectedRoleFilter != "All") {
                  final filter = _selectedRoleFilter.toLowerCase();
                  if (filter == 'admin') matchesRole = roleField == 'admin';
                  else if (filter == 'employee') matchesRole = roleField == 'employee';
                  else if (filter == 'provider') matchesRole = lastMode == 'provider' || roleField == 'provider';
                  else if (filter == 'seeker') matchesRole = (lastMode == 'seeker' || lastMode.isEmpty) && roleField != 'admin' && roleField != 'employee';
                }

                return matchesText && matchesRole;
              }).toList();

              if (filteredUsers.isEmpty) return const Center(child: Text("No users found.", style: TextStyle(color: _subText)));

              return ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                itemCount: filteredUsers.length,
                separatorBuilder: (_,__) => const SizedBox(height: 10),
                itemBuilder: (ctx, i) {
                  final doc = filteredUsers[i];
                  final m = doc.data() as Map;
                  return _UserCard(
                    doc: doc,
                    data: m,
                    isSuperAdmin: widget.isSuperAdmin,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  void _openAddStaffDialog() {
    showDialog(context: context, builder: (_) => const _CreateStaffDialog());
  }
}

// Modern User Card
class _UserCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final Map data;
  final bool isSuperAdmin;

  const _UserCard({required this.doc, required this.data, required this.isSuperAdmin});

  @override
  Widget build(BuildContext context) {
    final isBlocked = data['isBlocked'] == true;
    final name = data['name'] ?? data['username'] ?? 'User';
    final roleField = data['role'];
    final lastMode = data['last_mode'] ?? 'seeker';
    final role = (roleField != null) ? roleField.toString() : lastMode.toString();
    final email = data['email'] ?? data['phone'] ?? 'No contact';

    Color roleColor = Colors.grey;
    if (role == 'admin') roleColor = Colors.purple;
    else if (role == 'employee') roleColor = Colors.orange;
    else if (role == 'provider') roleColor = _accent;
    else if (role == 'seeker') roleColor = Colors.blue;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.8),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.03), blurRadius: 10)],
      ),
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: roleColor.withOpacity(0.1),
            child: Icon(Icons.person, color: roleColor),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(name, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, decoration: isBlocked ? TextDecoration.lineThrough : null)),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: roleColor.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                      child: Text(role.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: roleColor)),
                    ),
                    if (isBlocked)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(color: _danger.withOpacity(0.1), borderRadius: BorderRadius.circular(6)),
                        child: const Text("BLOCKED", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: _danger)),
                      ),
                  ],
                ),
                Text(email, style: const TextStyle(color: _subText, fontSize: 13)),
              ],
            ),
          ),

          if (isSuperAdmin)
            IconButton(
              icon: const Icon(Icons.admin_panel_settings_outlined, color: Colors.purple),
              tooltip: "Change Role",
              onPressed: () => _changeRoleDialog(context, doc.id, roleField ?? 'seeker', name),
            ),

          Switch(
            value: isBlocked,
            activeColor: _danger,
            onChanged: (val) => _toggleBlock(doc.id, isBlocked),
          ),

          IconButton(
            icon: const Icon(Icons.delete_outline, color: _subText),
            onPressed: () => _deleteUser(context, doc.id),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleBlock(String uid, bool currentStatus) async {
    await FirebaseFirestore.instance.collection('users').doc(uid).update({'isBlocked': !currentStatus});
  }

  Future<void> _deleteUser(BuildContext context, String uid) async {
    final confirm = await showDialog(context: context, builder: (ctx) => AlertDialog(
      title: const Text("Delete User?"),
      content: const Text("This action cannot be undone."),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _danger),
          onPressed: () { Navigator.pop(ctx, true); },
          child: const Text("Delete"),
        ),
      ],
    ));
    if (confirm == true) {
      await FirebaseFirestore.instance.collection('users').doc(uid).delete();
    }
  }

  Future<void> _changeRoleDialog(BuildContext context, String uid, String currentRole, String name) async {
    String? newRole = currentRole;
    final roles = ["seeker", "provider", "employee", "admin"];
    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text("Manage Role: $name"),
          content: DropdownButton<String>(
            value: roles.contains(newRole) ? newRole : "seeker",
            isExpanded: true,
            items: roles.map((r) => DropdownMenuItem(value: r, child: Text(r.toUpperCase()))).toList(),
            onChanged: (v) => setState(() => newRole = v),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
            FilledButton(
              onPressed: () {
                FirebaseFirestore.instance.collection('users').doc(uid).update({'role': newRole});
                Navigator.pop(ctx);
              },
              child: const Text("Update Role"),
            ),
          ],
        ),
      ),
    );
  }
}

// ==============================================================================
// 5. GIGS VIEW
// ==============================================================================
class _GigManagementView extends StatefulWidget {
  const _GigManagementView();

  @override
  State<_GigManagementView> createState() => _GigManagementViewState();
}

class _GigManagementViewState extends State<_GigManagementView> {
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchText = "";
  String _selectedCategory = "All";
  final List<String> _categories = const [
    'All', 'Cleaning', 'Plumbing', 'Electrician', 'Carpenter', 'Mechanic', 'Beauty', 'Freelancer', 'Ac Repair', 'Appliance', 'Driver'
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Toolbar
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Expanded(
                child: _WebTextField(
                  controller: _searchCtrl,
                  hint: "Search gigs by title...",
                  icon: Icons.search,
                  onChanged: (v) => setState(() => _searchText = v.toLowerCase()),
                ),
              ),
              const SizedBox(width: 16),
              _WebDropdown(
                value: _selectedCategory,
                items: _categories,
                onChanged: (v) => setState(() => _selectedCategory = v!),
              ),
            ],
          ),
        ),

        // Grid Content
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('gigs').orderBy('createdAt', descending: true).limit(200).snapshots(),
            builder: (ctx, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: _accent));
              final allGigs = snap.data!.docs;

              final filteredGigs = allGigs.where((doc) {
                final m = doc.data() as Map;
                final title = (m['title'] ?? '').toString().toLowerCase();
                final category = (m['category'] ?? '').toString();
                bool matchesSearch = _searchText.isEmpty || title.contains(_searchText);
                bool matchesCat = _selectedCategory == "All" || category == _selectedCategory;
                return matchesSearch && matchesCat;
              }).toList();

              if (filteredGigs.isEmpty) return const Center(child: Text("No gigs found", style: TextStyle(color: _subText)));

              return GridView.builder(
                padding: const EdgeInsets.all(20),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 350,
                  childAspectRatio: 0.8,
                  crossAxisSpacing: 20,
                  mainAxisSpacing: 20,
                ),
                itemCount: filteredGigs.length,
                itemBuilder: (ctx, i) {
                  final doc = filteredGigs[i];
                  return _GigCard(doc: doc);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _GigCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _GigCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final m = doc.data() as Map;
    final photos = (m['photosB64'] as List?) ?? [];
    String? thumb;
    if (photos.isNotEmpty) thumb = photos.first;

    final rating = (m['ratingAvg'] ?? 0).toStringAsFixed(1);
    final ratingCount = m['ratingCount'] ?? 0;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image Area
          Expanded(
            flex: 3,
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  thumb != null
                      ? Image.memory(base64Decode(thumb), fit: BoxFit.cover)
                      : Container(color: Colors.grey[200], child: const Icon(Icons.image, color: Colors.grey)),
                  Positioned(
                    top: 8, right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                      child: Row(children: [
                        const Icon(Icons.star, color: Colors.orange, size: 14),
                        const SizedBox(width: 4),
                        Text("$rating ($ratingCount)", style: const TextStyle(color: Colors.white, fontSize: 12))
                      ]),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Info Area
          Expanded(
            flex: 2,
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m['title'] ?? 'No Title', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text(m['category'] ?? 'General', style: const TextStyle(color: _subText, fontSize: 12)),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("PKR ${m['price']}", style: const TextStyle(color: _success, fontWeight: FontWeight.bold)),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: _bg, borderRadius: BorderRadius.circular(4)), // Uses _bg here as well
                        child: Text(m['status']?.toString().toUpperCase() ?? '', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                          onPressed: () => _showReviews(context, doc.id, m['title']),
                          child: const Text("Reviews", style: TextStyle(fontSize: 12)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20, color: _danger),
                        onPressed: () => _deleteGig(context, doc.id),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  )
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showReviews(BuildContext context, String gigId, String? title) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Container(
          width: 500,
          height: 600,
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Reviews: $title", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
              const Divider(),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('gig_reviews').where('gigId', isEqualTo: gigId).snapshots(),
                  builder: (ctx, snap) {
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final reviews = snap.data!.docs;
                    if (reviews.isEmpty) return const Center(child: Text("No reviews yet.", style: TextStyle(color: _subText)));

                    return ListView.separated(
                      itemCount: reviews.length,
                      separatorBuilder: (_,__) => const Divider(),
                      itemBuilder: (ctx, i) {
                        final r = reviews[i].data() as Map;
                        final rating = (r['rating'] ?? 0).toString();
                        final comment = r['review'] ?? r['text'] ?? 'No comment';
                        final author = r['authorName'] ?? 'Anonymous';
                        final date = r['createdAt'] != null
                            ? DateFormat('dd MMM yyyy').format((r['createdAt'] as Timestamp).toDate())
                            : '';
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.orange.shade100,
                            child: Text(rating, style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold)),
                          ),
                          title: Text(author, style: const TextStyle(fontWeight: FontWeight.bold)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(comment),
                              const SizedBox(height: 4),
                              Text(date, style: const TextStyle(fontSize: 12, color: _subText)),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Close")),
              )
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _deleteGig(BuildContext context, String id) async {
    final confirm = await showDialog(context: context, builder: (c) => AlertDialog(
      title: const Text("Delete Gig?"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text("Cancel")),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: _danger), onPressed: () => Navigator.pop(c, true), child: const Text("Delete")),
      ],
    ));
    if (confirm == true) {
      await FirebaseFirestore.instance.collection('gigs').doc(id).delete();
    }
  }
}

// ==============================================================================
// 6. REPORTS VIEW
// ==============================================================================
class _ReportsPlaceholderView extends StatelessWidget {
  const _ReportsPlaceholderView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(30),
            decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), shape: BoxShape.circle),
            child: const Icon(Icons.shield_outlined, size: 80, color: Colors.blue),
          ),
          const SizedBox(height: 24),
          const Text("No Reports Yet", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: _text)),
          const SizedBox(height: 12),
          const Text(
            "Great! There are no flagged items or user reports pending review.",
            style: TextStyle(fontSize: 16, color: _subText),
          ),
        ],
      ),
    );
  }
}

// ==============================================================================
// 7. WEB COMPONENTS (Dropdowns & Inputs)
// ==============================================================================
class _WebTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  final Function(String) onChanged;

  const _WebTextField({required this.controller, required this.hint, required this.icon, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(icon, color: _subText),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        ),
      ),
    );
  }
}

class _WebDropdown extends StatelessWidget {
  final String value;
  final List<String> items;
  final Function(String?) onChanged;

  const _WebDropdown({required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)],
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          icon: const Icon(Icons.keyboard_arrow_down, color: _subText),
          borderRadius: BorderRadius.circular(12),
          items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

// ==============================================================================
// CREATE STAFF DIALOG (Secondary App - Logic from Old Code)
// ==============================================================================
class _CreateStaffDialog extends StatefulWidget {
  const _CreateStaffDialog();
  @override
  State<_CreateStaffDialog> createState() => _CreateStaffDialogState();
}

class _CreateStaffDialogState extends State<_CreateStaffDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  String _role = 'employee';
  bool _loading = false;

  Future<void> _create() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    FirebaseApp? secondaryApp;
    try {
      secondaryApp = await Firebase.initializeApp(name: 'SecondaryApp', options: Firebase.app().options);
      UserCredential uc = await FirebaseAuth.instanceFor(app: secondaryApp).createUserWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text.trim(),
      );

      await FirebaseFirestore.instance.collection('users').doc(uc.user!.uid).set({
        'name': _nameCtrl.text.trim(),
        'email': _emailCtrl.text.trim(),
        'role': _role,
        'created_at': FieldValue.serverTimestamp(),
        'last_mode': _role,
        'username': 'staff_${uc.user!.uid.substring(0, 5)}',
      });

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Staff created successfully!"), backgroundColor: _success));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: _danger));
    } finally {
      await secondaryApp?.delete();
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 400,
        padding: const EdgeInsets.all(30),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Create Staff Account", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: "Name", border: OutlineInputBorder()),
                validator: (v) => v!.isEmpty ? "Required" : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _emailCtrl,
                decoration: const InputDecoration(labelText: "Email", border: OutlineInputBorder()),
                validator: (v) => v!.contains('@') ? null : "Invalid email",
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _passCtrl,
                decoration: const InputDecoration(labelText: "Password", border: OutlineInputBorder()),
                obscureText: true,
                validator: (v) => v!.length < 6 ? "Min 8 chars" : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _role,
                decoration: const InputDecoration(labelText: "Role", border: OutlineInputBorder()),
                items: const [
                  DropdownMenuItem(value: "employee", child: Text("Employee (Limited Access)")),
                  DropdownMenuItem(value: "admin", child: Text("Admin (Full Access)")),
                ],
                onChanged: (v) => setState(() => _role = v!),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: _accent, foregroundColor: Colors.white),
                  onPressed: _loading ? null : _create,
                  child: _loading ? const CircularProgressIndicator(color: Colors.white) : const Text("Create Account"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}