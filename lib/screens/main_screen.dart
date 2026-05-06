import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'provider_dashboard_screen.dart';
import 'home_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'seeker_requests_screen.dart';
import 'chat_list_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  bool _loading = true;
  bool _isProvider = false;
  String _lastMode = 'seeker';
  User? user;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _decideStartScreen();
  }

  Future<void> _decideStartScreen() async {
    user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      setState(() => _loading = false);
      return;
    }
    final doc = await FirebaseFirestore.instance.collection('users').doc(user!.uid).get();
    final data = doc.data();
    if (data != null && data['provider'] != null) {
      final provider = data['provider'] as Map<String, dynamic>;
      _isProvider = provider['status'] == 'approved';
    }
    final prefs = await SharedPreferences.getInstance();
    _lastMode = prefs.getString('last_mode') ?? data?['last_mode'] ?? (_isProvider ? 'provider' : 'seeker');
    setState(() => _loading = false);
  }

  void _onItemTapped(int index) => setState(() => _selectedIndex = index);

  Future<void> _handleSwitchToSeeker() async {
    await _decideStartScreen();
    setState(() {
      _lastMode = 'seeker';
      _selectedIndex = 0;
    });
  }

  void _handleLogout() {
    Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
  }

  Stream<int> _unreadChatCount() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return FirebaseFirestore.instance
        .collection('chats')
        .where('users', arrayContains: uid)
        .snapshots()
        .map((snap) {
      int total = 0;
      for (var doc in snap.docs) {
        final m = doc.data();
        final unreadMap = m['unreadCount'] as Map<String, dynamic>? ?? {};
        total += (unreadMap[uid] as num?)?.toInt() ?? 0;
      }
      return total;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    if (user != null) {
      return StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(user!.uid).snapshots(),
        builder: (context, snapshot) {
          bool showProviderDashboard = _isProvider && _lastMode == 'provider';
          if (snapshot.hasData && snapshot.data != null) {
            final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};
            final provider = data['provider'] as Map<String, dynamic>? ?? {};
            final providerApproved = provider['status'] == 'approved';
            final lastMode = data['last_mode'] ?? _lastMode;
            showProviderDashboard = providerApproved && lastMode == 'provider';
          }

          if (showProviderDashboard) {
            return ProviderDashboardScreen(
              onSwitchSeeker: _handleSwitchToSeeker,
              onLogout: _handleLogout,
            );
          }

          final pages = <Widget>[
            HomeScreen(onNavigateToTab: _onItemTapped),
            const SearchScreen(),
            const SeekerRequestsScreen(),
            const ChatListScreen(),
            const ProfileScreen(),
          ];

          return Scaffold(
            body: IndexedStack(
              index: _selectedIndex,
              children: pages,
            ),
            bottomNavigationBar: StreamBuilder<int>(
              stream: _unreadChatCount(),
              builder: (context, badgeSnap) {
                final unreadCount = badgeSnap.data ?? 0;

                return BottomNavigationBar(
                  type: BottomNavigationBarType.fixed,
                  currentIndex: _selectedIndex,
                  onTap: _onItemTapped,
                  selectedFontSize: 10,
                  unselectedFontSize: 10,
                  selectedIconTheme: const IconThemeData(size: 35),
                  unselectedIconTheme: const IconThemeData(size: 20),
                  selectedItemColor: const Color(0xFF7966FA),
                  unselectedItemColor: const Color(0xFFBDBDBD),
                  showUnselectedLabels: true,
                  selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, letterSpacing: -0.1),
                  unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, letterSpacing: -0.1),
                  items: [
                    const BottomNavigationBarItem(icon: Icon(Icons.home_outlined), label: "Home"),
                    const BottomNavigationBarItem(icon: Icon(Icons.search), label: "Search"),
                    const BottomNavigationBarItem(icon: Icon(Icons.assignment_outlined), label: "My Requests"),
                    BottomNavigationBarItem(
                      icon: Badge(
                        isLabelVisible: unreadCount > 0,
                        backgroundColor: Colors.redAccent,
                        label: Text('$unreadCount'),
                        child: const Icon(Icons.chat_bubble_outline),
                      ),
                      label: "Chats",
                    ),
                    const BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: "Account"),
                  ],
                );
              },
            ),
          );
        },
      );
    }
    return const Scaffold(body: Center(child: Text("Please log in")));
  }
}