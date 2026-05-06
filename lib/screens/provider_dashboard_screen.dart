// lib/screens/provider_dashboard_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'chat_list_screen.dart';

class ProviderDashboardScreen extends StatefulWidget {
  final VoidCallback? onSwitchSeeker;
  final VoidCallback? onLogout;

  const ProviderDashboardScreen({
    super.key,
    this.onSwitchSeeker,
    this.onLogout,
  });

  @override
  State<ProviderDashboardScreen> createState() => _ProviderDashboardScreenState();
}

class _ProviderDashboardScreenState extends State<ProviderDashboardScreen> {
  // THEME / BRAND
  static const Color _accent = Color(0xFF7966FA);
  static const Color _lavender = Color(0xFFD3C3F6);
  static const Color _ok = Color(0xFF1FBF6C);
  static const Color _warn = Color(0xFFFFB020);
  static const Color _danger = Color(0xFFE84D5B);
  int _graceHours = 2; // default; can be 1 or 2 (or customized per provider)
  final Set<String> _overdueChecked = {}; // prevent re-processing same doc

  StreamSubscription? _cancellationSub;

  int _liveModeFilter = 0;

  bool darkTheme = false;

  // NAV STATE (5 tabs: Requests, Bookings, Services, Chats, Ratings)
  int _tabIndex = 0;

  // AVAILABILITY
  bool _online = true;
  bool _savingAvailability = false;

  // track toasts for cancellations (avoid duplicates)
  final Set<String> _seenCancelled = {};

  // Gig title cache for Ratings tab (to avoid showing raw ids)
  final Map<String, String> _gigTitleCache = {};
  StreamSubscription? _gigCacheSub;

  // ---- LIVE TRACKING (started in Part 2) ----
  final Map<String, StreamSubscription<Position>> _gpsSubs = {};
  final Set<String> _trackingReqIds = {};

  StreamSubscription? _autoOverdueSub;

  StreamSubscription<Position>? _liveReqTrackingSub;

  String _bookingFilter = 'all';

  static const Map<String, IconData> _statusIcons = {
    'all': Icons.all_inclusive,
    'accepted': Icons.event_available_outlined,
    'enroute': Icons.navigation_outlined,
    'cancelled': Icons.cancel_outlined,
    'not_completed': Icons.report_problem_outlined,
  };

  String _statusLabel(String k) {
    switch (k) {
      case 'accepted': return 'Accepted';
      case 'enroute': return 'Enroute';
      case 'cancelled': return 'Cancelled';
      case 'not_completed': return 'Not Completed';
      default: return 'All';
    }
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

  Widget _statusPills(Color fg, Color sub) {
    final items = const ['all','accepted','enroute','cancelled','not_completed'];
    final cs = Theme.of(context).colorScheme;
    final isDark = darkTheme;

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: items.map((k) {
          final selected = _bookingFilter == k;

          // Soft, theme-matched fill for selected chips
          final selectedBg  = cs.primaryContainer;       // soft container
          final selectedFg  = cs.onPrimaryContainer;     // readable on soft container
          final selectedBor = cs.primary.withOpacity(0.18);
          final idleBor     = sub.withOpacity(0.25);

          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Tooltip(
              message: _statusLabel(k),
              child: InkWell(
                onTap: () => setState(() => _bookingFilter = k),
                borderRadius: BorderRadius.circular(999),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: selected ? selectedBg : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: selected ? selectedBor : idleBor,
                      width: selected ? 1.2 : 1.0,
                    ),
                    boxShadow: selected
                        ? [
                      BoxShadow(
                        color: cs.primary.withOpacity(isDark ? 0.25 : 0.18),
                        blurRadius: 10,
                        offset: const Offset(0, 3),
                      ),
                    ]
                        : const [],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _statusIcons[k],
                        size: 20,
                        color: selected ? selectedFg : sub,
                      ),
                      if (selected) ...[
                        const SizedBox(width: 8),
                        Text(
                          _statusLabel(k),
                          style: TextStyle(
                            color: selected ? selectedFg : fg,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.15,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

// optional: tweak the buckets shown in Alerts
  final List<Duration> _deadlineWarnLevels = const [
    Duration(hours: 2),
    Duration(hours: 1),
    Duration(minutes: 30),
    Duration(minutes: 10),
  ];

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
    _loadAvailability();
    _listenSeekerCancellations();
    _primeGigTitleCache();
    _attachAutoOverdueListener(); // ← NEW
  }

  @override
  void dispose() {
    _liveReqTrackingSub?.cancel();
    _gigCacheSub?.cancel();
    _autoOverdueSub?.cancel(); // ← NEW
    // ADD THIS LINE:
    _cancellationSub?.cancel();

    for (final sub in _gpsSubs.values) {
      sub.cancel();
    }
    _gpsSubs.clear();
    super.dispose();
  }

  Future<void> _callPhone(String phone) async {
    if (phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  Future<void> _startTrackingLiveRequest(String requestId) async {
    await _liveReqTrackingSub?.cancel();

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return;
    }

    _liveReqTrackingSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      FirebaseFirestore.instance
          .collection('live_requests')
          .doc(requestId)
          .update({
        'providerLat': pos.latitude,
        'providerLng': pos.longitude,
        'providerLastSeen': DateTime.now(),
      }).catchError((_) {});
    });
  }

  // In _ProviderDashboardScreenState class

  Future<void> _acceptLiveRequest(QueryDocumentSnapshot doc) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // 1. CHECK FOR EXISTING ONGOING JOBS
    final ongoingSnap = await FirebaseFirestore.instance
        .collection('live_requests')
        .where('providerId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'ongoing')
        .get();

    if (ongoingSnap.docs.isNotEmpty) {
      _toastWarn('You already have an ongoing live request. Complete it first.');
      return;
    }

    // 2. GET PROVIDER INFO
    String? providerName;
    String? providerPhone = user.phoneNumber;

    // ... (Your existing profile fetch logic here is fine, keep it) ...
    try {
      final snap = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final data = snap.data();
      if (data != null) {
        final prov = data['provider'] ?? {};
        providerName = prov['name'] ?? data['displayName'];
        providerPhone = prov['phone'] ?? user.phoneNumber;
      }
    } catch (_) {}

    // 3. GET INITIAL LOCATION
    final ok = await Geolocator.requestPermission();
    if (ok == LocationPermission.denied || ok == LocationPermission.deniedForever) return;
    final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

    // 4. UPDATE STATUS -> 'ONGOING' (Not 'accepted')
    await doc.reference.update({
      'status': 'ongoing',
      'providerId': user.uid,
      'providerName': providerName ?? 'Provider',
      'providerPhone': providerPhone,
      'providerLat': pos.latitude,
      'providerLng': pos.longitude,
      'acceptedAt': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;

    // 5. OPEN FULL SCREEN MAP
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ProviderLiveMapScreen(
          requestId: doc.id,
          requestData: doc.data() as Map<String, dynamic>,
        ),
      ),
    );
  }


  void _attachAutoOverdueListener() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _autoOverdueSub?.cancel();
    _autoOverdueSub = FirebaseFirestore.instance
        .collection('service_requests')
        .where('providerId', isEqualTo: uid)
        .where('status', whereIn: ['accepted', 'enroute'])
        .snapshots()
        .listen(
          (snap) {
        // Reuse your existing logic; prevents re-processing with _overdueChecked
        _checkAndFlagOverdues(snap.docs.cast<QueryDocumentSnapshot>());
      },
      onError: (_) {}, // ignore transient
    );
  }

  // ---------- THEME PERSISTENCE ----------
  String _themeKeyFor(User? user) =>
      user != null ? 'provider_theme_${user.uid}' : 'provider_theme_default';

  Future<void> _loadThemePreference() async {
    final prefs = await SharedPreferences.getInstance();
    final user = FirebaseAuth.instance.currentUser;
    final key = _themeKeyFor(user);
    final saved = prefs.getBool(key);
    if (mounted) setState(() => darkTheme = saved ?? false);
  }

  Future<void> _saveThemePreference(bool isDark) async {
    final prefs = await SharedPreferences.getInstance();
    final user = FirebaseAuth.instance.currentUser;
    await prefs.setBool(_themeKeyFor(user), isDark);
  }

  void _toggleTheme() async {
    final next = !darkTheme;
    setState(() => darkTheme = next);
    await _saveThemePreference(next);
  }

  // ---------- AVAILABILITY ----------
  Future<void> _loadAvailability() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    final data = doc.data() ?? {};
    setState(() {
      _online = (data['provider']?['online'] as bool?) ?? true;
      _graceHours = (data['provider']?['graceHours'] as num?)?.toInt() ?? 2; // NEW
    });
  }

  DateTime _dueByFrom(Map<String, dynamic> m) {
    final ts = m['scheduledAt'] as Timestamp?;
    if (ts == null) return DateTime.fromMillisecondsSinceEpoch(0);
    final g = (m['graceHours'] as num?)?.toInt() ?? _graceHours;
    return ts.toDate().add(Duration(hours: g));
  }

  Future<void> _checkAndFlagOverdues(List<QueryDocumentSnapshot> docs) async {
    final now = DateTime.now();
    for (final d in docs) {
      if (_overdueChecked.contains(d.id)) continue;
      final m = d.data() as Map<String, dynamic>;
      final status = (m['status'] ?? '').toString().toLowerCase();
      if (status != 'accepted' && status != 'enroute') {
        _overdueChecked.add(d.id);
        continue;
      }
      final dueBy = _dueByFrom(m);
      final overdueBy = now.difference(dueBy);
      if (dueBy.isBefore(now)) {
        _overdueChecked.add(d.id);
        try {
          await FirebaseFirestore.instance.collection('service_requests').doc(d.id).set({
            'status': 'not_completed',
            'notCompletedAt': FieldValue.serverTimestamp(),
            'dueBy': Timestamp.fromDate(dueBy),
            'overdueByMin': overdueBy.inMinutes < 0 ? 0 : overdueBy.inMinutes,
            'updatedAt': FieldValue.serverTimestamp(),
            'lastAutoStatus': 'overdue_to_not_completed',
          }, SetOptions(merge: true));
          if (!mounted) return;
          _toastWarn('A job was marked Not completed (missed window).');
        } catch (_) {/* ignore */}
      }
    }
  }

  Future<void> _setAvailability(bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    setState(() {
      _online = value;
      _savingAvailability = true;
    });
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'provider': {
          'online': value,
          'updated_at': FieldValue.serverTimestamp(),
        }
      }, SetOptions(merge: true));
    } finally {
      if (mounted) setState(() => _savingAvailability = false);
    }
  }

  // ---------- CANCELLATION LISTENER ----------
  void _listenSeekerCancellations() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // CHANGE THIS BLOCK:
    _cancellationSub = FirebaseFirestore.instance
        .collection('service_requests')
        .where('providerId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'cancelled')
        .orderBy('updatedAt', descending: true)
        .snapshots()
        .listen((snap) {
      for (final d in snap.docChanges) {
        final id = d.doc.id;
        if (d.type == DocumentChangeType.added ||
            d.type == DocumentChangeType.modified) {
          if (!_seenCancelled.contains(id)) {
            _seenCancelled.add(id);
            final m = d.doc.data() as Map<String, dynamic>;
            final t = (m['gigTitle'] ?? 'Service').toString();
            final who = (m['cancelledBy'] ?? '').toString().toLowerCase();
            final msg = (who == 'provider')
                ? 'You cancelled • $t'
                : (who == 'seeker')
                ? 'Seeker cancelled • $t'
                : 'Cancelled • $t';
            _toastWarn(msg);
          }
        }
      }
    });
  }

  // ---------- GIG TITLE CACHE ----------
  void _primeGigTitleCache() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _gigCacheSub = FirebaseFirestore.instance
        .collection('gigs')
        .where('providerId', isEqualTo: uid)
        .snapshots()
        .listen((snap) {
      for (final d in snap.docs) {
        final m = d.data() as Map<String, dynamic>;
        final title = (m['title'] ?? '').toString();
        if (title.isNotEmpty) {
          _gigTitleCache[d.id] = title;
          final gid = (m['gigId'] ?? '').toString();
          if (gid.isNotEmpty) _gigTitleCache[gid] = title;
        }
      }
      if (mounted) setState(() {});
    });
  }

  Future<void> _logout() async {
    // 1. Unmount UI immediately
    if (widget.onLogout != null) {
      widget.onLogout!();
    } else {
      if (!mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    }

    // 2. Wait for dispose() to run and cancel subscriptions
    await Future.delayed(const Duration(milliseconds: 200));

    // 3. NOW sign out safely
    await FirebaseAuth.instance.signOut();
  }

  Future<void> _switchToSeekerMode() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_mode', 'seeker');
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'last_mode': 'seeker'}, SetOptions(merge: true));
    }
    if (widget.onSwitchSeeker != null) {
      widget.onSwitchSeeker!();
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
  }

  // ---------- UTILS ----------
  String _fmtTS(Timestamp? ts) {
    if (ts == null) return '—';
    final d = ts.toDate();
    final dd = '${d.year}-${_two(d.month)}-${_two(d.day)}';
    final hh = '${_two(d.hour)}:${_two(d.minute)}';
    return '$dd  •  $hh';
  }

  String _fmtDT(DateTime d) {
    final wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][(d.weekday - 1)
        .clamp(0, 6)];
    final mo = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec'
    ][(d.month - 1).clamp(0, 11)];
    return '$wd, $mo ${d.day} • ${_two(d.hour)}:${_two(d.minute)}';
  }

  String _two(int v) => v < 10 ? '0$v' : '$v';

  // --- External intents (phone / maps) ---
  Future<void> _launchTel(String phone) async {
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      } else {
        _toastWarn('Cannot place a call on this device.');
      }
    } catch (_) {
      _toastError('Failed to open dialer.');
    }
  }

  Future<void> _launchMapsByLatLng(double lat, double lng,
      {String? label}) async {
    final query = label != null && label
        .trim()
        .isNotEmpty
        ? '$lat,$lng(${Uri.encodeComponent(label)})'
        : '$lat,$lng';
    final geo = Uri.parse('geo:$lat,$lng?q=$query');
    final web = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$lat,$lng');
    try {
      if (await canLaunchUrl(geo)) {
        await launchUrl(geo, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      _toastError('Could not open Maps.');
    }
  }

  Future<void> _launchMapsByAddress(String address) async {
    if (address
        .trim()
        .isEmpty) {
      _toastWarn('Address not available.');
      return;
    }
    final encoded = Uri.encodeComponent(address);
    final geo = Uri.parse('geo:0,0?q=$encoded');
    final web = Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$encoded');
    try {
      if (await canLaunchUrl(geo)) {
        await launchUrl(geo, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(web, mode: LaunchMode.externalApplication);
      }
    } catch (_) {
      _toastError('Could not open Maps.');
    }
  }

  // --- Toasts ---
  void _showToast(String msg, {Color? bg, IconData? icon}) {
    final themeBg = bg ?? Colors.black87;
    final sb = SnackBar(
      behavior: SnackBarBehavior.floating,
      elevation: 1,
      backgroundColor: themeBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: Colors.white),
            const SizedBox(width: 10),
          ],
          Expanded(child: Text(msg, style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w700))),
        ],
      ),
      duration: const Duration(seconds: 2),
    );
    ScaffoldMessenger.of(context).showSnackBar(sb);
  }

  void _toastSuccess(String msg) =>
      _showToast(
          msg, bg: const Color(0xFF1FBF6C), icon: Icons.check_circle_rounded);

  void _toastInfo(String msg) =>
      _showToast(msg, bg: _accent, icon: Icons.info_outline_rounded);

  void _toastWarn(String msg) =>
      _showToast(
          msg, bg: const Color(0xFFFFB020), icon: Icons.warning_amber_rounded);

  void _toastError(String msg) =>
      _showToast(
          msg, bg: const Color(0xFFE84D5B), icon: Icons.error_outline_rounded);

  // Count ongoing (accepted/enroute) for bell badge
  Stream<int> _ongoingCount(String uid) {
    return FirebaseFirestore.instance
        .collection('service_requests')
        .where('providerId', isEqualTo: uid)
        .where('status', isEqualTo: 'enroute') // was whereIn: ['accepted','enroute']
        .snapshots()
        .map((s) => s.docs.length);
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext context) {
    final bg = darkTheme ? const Color(0xFF111111) : Colors.white;
    final cardColor = darkTheme ? const Color(0xFF1A1A1A) : Colors.white;
    final fg = darkTheme ? Colors.white : Colors.black;
    final subtitle = darkTheme ? Colors.white70 : Colors.black54;

    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      drawer: _drawer(_accent, fg, bg, subtitle),
      appBar: AppBar(
        backgroundColor: _accent,
        elevation: 0,
        centerTitle: true,
        leading: Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.menu, color: Colors.white),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: InkWell(
          onTap: () => _setAvailability(!_online),
          borderRadius: BorderRadius.circular(999),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Colors.white24, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  width: 10, height: 10,
                  decoration: BoxDecoration(
                    color: _online ? Colors.greenAccent : Colors.orangeAccent,
                    shape: BoxShape.circle,
                    boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 4, offset: const Offset(0, 2))],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _savingAvailability ? 'Updating...' : (_online ? 'Online' : 'Offline'),
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, letterSpacing: 0.2),
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (user != null)
            StreamBuilder<int>(
              stream: _ongoingCount(user.uid),
              builder: (_, snap) {
                final c = snap.data ?? 0;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.notifications_none_rounded, color: Colors.white),
                      onPressed: () { _openAlertsAndOngoingSheet(context, user.uid); },
                    ),
                    if (c > 0)
                      Positioned(
                        right: 8, top: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(10)),
                          child: Text('$c', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)),
                        ),
                      ),
                  ],
                );
              },
            )
          else
            IconButton(icon: const Icon(Icons.notifications_none_rounded, color: Colors.white), onPressed: () {}),
        ],
      ),
      backgroundColor: bg,

      body: user == null
          ? Center(child: Text("Please log in", style: TextStyle(color: fg)))
          : _buildTabScaffold(user.uid, fg, subtitle, cardColor),

      // FAB: Add Service only for Services tab
      floatingActionButton: _tabIndex == 2
          ? FloatingActionButton(
        backgroundColor: _accent,
        onPressed: () async {
          final created = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => AddServiceScreen(isDark: darkTheme)),
          );
          if (created == true && mounted) {
            _toastSuccess('Service added successfully');
          }
        },
        child: const Icon(Icons.add, color: Colors.white),
      )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,

      bottomNavigationBar: StreamBuilder<int>(
          stream: _unreadChatCount(),
          builder: (context, badgeSnap) {
            final unreadCount = badgeSnap.data ?? 0;

            return Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: darkTheme ? Colors.white12 : Colors.black12, width: 1)),
              ),
              child: NavigationBarTheme(
                data: NavigationBarThemeData(
                  indicatorColor: _lavender.withOpacity(0.45),
                  surfaceTintColor: Colors.transparent,
                  labelTextStyle: MaterialStateProperty.resolveWith<TextStyle>((states) {
                    final selected = states.contains(MaterialState.selected);
                    return TextStyle(
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                      color: selected ? _accent : (darkTheme ? Colors.white70 : Colors.black54),
                    );
                  }),
                  iconTheme: MaterialStateProperty.resolveWith<IconThemeData>((states) {
                    final selected = states.contains(MaterialState.selected);
                    return IconThemeData(
                      color: selected ? _accent : (darkTheme ? Colors.white60 : Colors.black38),
                    );
                  }),
                ),
                child: NavigationBar(
                  height: 64,
                  backgroundColor: bg,
                  selectedIndex: _tabIndex,
                  onDestinationSelected: (i) => setState(() => _tabIndex = i),
                  destinations: [
                    const NavigationDestination(icon: Icon(Icons.inbox_outlined), selectedIcon: Icon(Icons.inbox), label: 'Requests'),
                    const NavigationDestination(icon: Icon(Icons.event_note_outlined), selectedIcon: Icon(Icons.event_note), label: 'Bookings'),
                    const NavigationDestination(icon: Icon(Icons.book_online_outlined), selectedIcon: Icon(Icons.book_online), label: 'Services'),

                    // CHAT TAB WITH BADGE
                    NavigationDestination(
                      icon: Badge(
                        isLabelVisible: unreadCount > 0,
                        label: Text('$unreadCount'),
                        backgroundColor: Colors.redAccent,
                        child: const Icon(Icons.chat_bubble_outline),
                      ),
                      selectedIcon: Badge(
                        isLabelVisible: unreadCount > 0,
                        label: Text('$unreadCount'),
                        backgroundColor: Colors.redAccent,
                        child: const Icon(Icons.chat_bubble),
                      ),
                      label: 'Chats',
                    ),

                    const NavigationDestination(icon: Icon(Icons.star_border_rounded), selectedIcon: Icon(Icons.star_rounded), label: 'Ratings'),
                  ],
                ),
              ),
            );
          }
      ),
    );
  }

  Widget _buildTabScaffold(String uid, Color fg, Color sub, Color card) {
    switch (_tabIndex) {
      case 0:
        return _requestsTab(uid, fg, sub, card);
      case 1:
        return _bookingsTab(uid, fg, sub, card);
      case 2:
        return _servicesTab(uid, fg, sub, card);
      case 3:
        return const ChatListScreen();
      case 4:
        return _tabRatings(uid, fg, sub, card);
      default:
        return const SizedBox.shrink();
    }
  }

  /* ======================= REQUESTS TAB (Live + Requests) ======================= */
  Widget _requestsTab(String uid, Color fg, Color sub, Color cardColor) {
    final borderColor = darkTheme ? Colors.white12 : const Color(0xFFE9EAF2);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: const [
                Spacer(),
              ],
            ),
          ),

          // Tabs bar
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 1),
            child: Builder(
              builder: (context) {
                final tc = DefaultTabController.of(context)!;
                final Color bg     = darkTheme ? const Color(0xFF14151A) : const Color(0xFFF5F6FA);
                final Color border = darkTheme ? Colors.white10 : const Color(0xFFE9EAF2);
                final Color unSel  = darkTheme ? Colors.white70 : const Color(0xFF55597D);

                return SizedBox(
                  height: 46,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const int n = 2;
                      final double w    = constraints.maxWidth;
                      final double segW = (w - 8) / n;

                      return Stack(
                        children: [
                          // Track
                          Container(
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: border),
                            ),
                          ),

                          // Floating pill indicator
                          AnimatedBuilder(
                            animation: tc.animation!,
                            builder: (_, __) {
                              final double t    = tc.animation!.value.clamp(0.0, (n - 1).toDouble());
                              final double left = 4 + (t * segW);
                              return Positioned(
                                top: 4,
                                bottom: 4,
                                left: left,
                                width: segW,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [_accent, _accent.withOpacity(0.9)],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: _accent.withOpacity(0.26),
                                        blurRadius: 16,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),

                          // Tabs
                          TabBar(
                            controller: tc,
                            indicatorColor: Colors.transparent,
                            dividerColor: Colors.transparent,
                            overlayColor: MaterialStateProperty.all(Colors.transparent),
                            splashFactory: NoSplash.splashFactory,
                            labelPadding: EdgeInsets.zero,
                            labelStyle: const TextStyle(fontWeight: FontWeight.w800),
                            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
                            labelColor: Colors.white,
                            unselectedLabelColor: unSel,
                            tabs: const [
                              Tab(child: Center(child: Text('Live', maxLines: 1, overflow: TextOverflow.ellipsis))),
                              Tab(child: Center(child: Text('Requests', maxLines: 1, overflow: TextOverflow.ellipsis))),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),

          // Content
          Expanded(
            child: TabBarView(
              physics: const BouncingScrollPhysics(),
              children: [
                // ======================= LIVE TAB =======================
                Column(
                  children: [
                    // 1. CHECK FOR ACTIVE ONGOING REQUEST (Resume Navigation)
                    StreamBuilder<QuerySnapshot>(
                      stream: FirebaseFirestore.instance
                          .collection('live_requests')
                          .where('providerId', isEqualTo: uid)
                          .where('status', isEqualTo: 'ongoing')
                          .limit(1)
                          .snapshots(),
                      builder: (ctx, snap) {
                        if (!snap.hasData || snap.data!.docs.isEmpty) return const SizedBox.shrink();

                        final activeDoc = snap.data!.docs.first;
                        final activeData = activeDoc.data() as Map<String, dynamic>;

                        return Container(
                          margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _accent,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(color: _accent.withOpacity(0.4), blurRadius: 10, offset: const Offset(0, 4))
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Row(
                                children: [
                                  Icon(Icons.navigation_rounded, color: Colors.white),
                                  SizedBox(width: 8),
                                  Text('Ongoing Live Job', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                'Tap to resume navigation',
                                style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 13),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: _accent,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    elevation: 0,
                                  ),
                                  onPressed: () {
                                    // Resume Map
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => ProviderLiveMapScreen(
                                          requestId: activeDoc.id,
                                          requestData: activeData,
                                        ),
                                      ),
                                    );
                                  },
                                  child: const Text('OPEN MAP', style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              )
                            ],
                          ),
                        );
                      },
                    ),

                    // 2. Filter row
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            _LiveFilterChip(
                              label: 'All',
                              selected: _liveModeFilter == 0,
                              dark: darkTheme,
                              onTap: () => setState(() => _liveModeFilter = 0),
                            ),
                            const SizedBox(width: 8),
                            _LiveFilterChip(
                              label: 'Standard',
                              selected: _liveModeFilter == 1,
                              dark: darkTheme,
                              onTap: () => setState(() => _liveModeFilter = 1),
                            ),
                            const SizedBox(width: 8),
                            _LiveFilterChip(
                              label: 'Pick & Drop',
                              selected: _liveModeFilter == 2,
                              dark: darkTheme,
                              onTap: () => setState(() => _liveModeFilter = 2),
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 3. List of "Searching" requests
                    Expanded(
                      child: StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance
                            .collection('live_requests')
                            .where('status', isEqualTo: 'searching')
                            .orderBy('createdAt', descending: true)
                            .snapshots(),
                        builder: (_, snap) {
                          if (snap.connectionState == ConnectionState.waiting) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          if (snap.hasError) {
                            return Center(
                              child: Text(
                                'Error: ${snap.error}',
                                style: TextStyle(color: sub),
                              ),
                            );
                          }

                          // Filter by local mode (Standard vs PickDrop)
                          final allDocs = (snap.data?.docs ?? const []);
                          final docs = allDocs.where((d) {
                            final data = d.data() as Map<String, dynamic>;
                            // expired check? (optional, but good practice)
                            final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();
                            if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
                              return false;
                            }

                            if (_liveModeFilter == 0) return true;
                            final mode = data['mode'] ?? 'standard';
                            if (_liveModeFilter == 1) return mode == 'standard';
                            if (_liveModeFilter == 2) return mode == 'pick_drop';
                            return true;
                          }).toList();

                          if (docs.isEmpty) {
                            return _emptyState(
                              icon: Icons.wifi_tethering_off_outlined,
                              title: 'No Live Requests',
                              subtitle: 'New live requests will appear here.',
                              fg: fg,
                              sub: sub,
                            );
                          }

                          return ListView.separated(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                            itemCount: docs.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (_, i) {
                              final doc = docs[i] as QueryDocumentSnapshot;
                              return _LiveRequestCard(
                                doc: doc,
                                dark: darkTheme,
                                fg: fg,
                                sub: sub,
                                cardColor: cardColor,
                                onAccept: _acceptLiveRequest,
                                onCall: _callPhone,
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),

                // ======================= REQUESTS TAB (BOOKED PENDING) =======================
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('service_requests')
                      .where('providerId', isEqualTo: uid)
                      .where('status', isEqualTo: 'pending')
                      .orderBy('createdAt', descending: true)
                      .snapshots(),
                  builder: (_, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return Center(
                        child: Text('Error: ${snap.error}', style: TextStyle(color: sub)),
                      );
                    }

                    final docs = (snap.data?.docs ?? const [])
                        .where((d) {
                      final m = d.data() as Map<String, dynamic>;
                      return (m['providerHidden'] ?? false) != true;
                    })
                        .toList();

                    if (docs.isEmpty) {
                      return _emptyState(
                        icon: Icons.inbox_outlined,
                        title: 'No Requests Yet',
                        subtitle: 'New service bookings from seekers will appear here.',
                        fg: fg,
                        sub: sub,
                      );
                    }

                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                      itemCount: docs.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (_, i) {
                        return _RequestBookingCard(
                          doc: docs[i] as QueryDocumentSnapshot,
                          dark: darkTheme,
                          mode: _RBMode.request,
                          onAccept: (doc) => _acceptFlow(context, doc),
                          onReject: (doc) => _updateStatus(doc.id, 'declined'),
                          onOpenMap: (rid, data) => _openMapSheet(rid, data),
                          onMarkCompleted: null,
                          onEditSchedule: null,
                          onStartEnroute: null,
                          onCancel: null,
                          onDelete: null,
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }


  /* ======================= BOOKINGS TAB ======================= */
  Widget _bookingsTab(String uid, Color fg, Color sub, Color cardColor) {
    Query _buildQuery() {
      final base = FirebaseFirestore.instance
          .collection('service_requests')
          .where('providerId', isEqualTo: uid);

      // exclude completed; include cancelled
      if (_bookingFilter == 'all') {
        return base
            .where('status', whereIn: ['accepted', 'enroute', 'cancelled', 'not_completed'])
            .orderBy('createdAt', descending: true);
      } else {
        return base
            .where('status', isEqualTo: _bookingFilter)
            .orderBy('createdAt', descending: true);
      }
    }

    return Column(
      children: [
        _statusPills(fg, sub),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            key: ValueKey(_bookingFilter), // force rebuild when filter changes
            stream: _buildQuery().snapshots(),
            builder: (_, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return Center(
                  child: Text('Error: ${snap.error}', style: TextStyle(color: sub)),
                );
              }

              final docs = (snap.data?.docs ?? const [])
                  .where((d) {
                final m = d.data() as Map<String, dynamic>;
                return (m['providerHidden'] ?? false) != true;
              })
                  .toList();

              if (docs.isEmpty) {
                return _emptyState(
                  icon: Icons.event_note_outlined,
                  title: 'No Bookings Yet',
                  subtitle: 'Accepted, ongoing, and cancelled jobs will appear here.',
                  fg: fg,
                  sub: sub,
                );
              }

              WidgetsBinding.instance.addPostFrameCallback((_) {
                _checkAndFlagOverdues(docs.cast<QueryDocumentSnapshot>());
              });

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (_, i) {
                  return _RequestBookingCard(
                    doc: docs[i] as QueryDocumentSnapshot,
                    dark: darkTheme,
                    mode: _RBMode.booking,
                    onAccept: null,
                    onReject: (doc) => _updateStatus(doc.id, 'declined'),
                    onOpenMap: (rid, data) => _openMapSheet(rid, data),
                    onMarkCompleted: (doc) => _providerComplete(doc),
                    onEditSchedule: (doc) => _rescheduleFlow(context, doc),
                    onStartEnroute: (doc) => _startEnroute(doc),
                    onCancel: (doc) => _providerCancel(doc),
                    onDelete: (doc) => _hideForProvider(doc),
                    graceHours: _graceHours,
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }


/* ======================= SERVICES TAB ======================= */
/* ======================= SERVICES TAB (now with tabs) ======================= */
  Widget _servicesTab(String uid, Color fg, Color subtitle, Color cardColor) {
    final borderColor = darkTheme ? Colors.white12 : const Color(0xFFE9EAF2);

    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          // Header row
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Text(
                  'My Services',
                  style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    backgroundColor: _accent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                  ),
                  onPressed: () async {
                    final created = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(builder: (_) => AddServiceScreen(isDark: darkTheme)),
                    );
                    if (created == true && mounted) {
                      _toastSuccess('Service added');
                    }
                  },
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Service'),
                ),
              ],
            ),
          ),

          // Tabs bar (modern segmented control)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Builder(
              builder: (context) {
                final tc = DefaultTabController.of(context)!;
                final Color bg     = darkTheme ? const Color(0xFF14151A) : const Color(0xFFF5F6FA);
                final Color border = darkTheme ? Colors.white10 : const Color(0xFFE9EAF2);
                final Color unSel  = darkTheme ? Colors.white70 : const Color(0xFF55597D);

                return SizedBox(
                  height: 46,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      const int n = 2;
                      final double w = constraints.maxWidth;
                      final double segW = (w - 8) / n; // 4px insets left/right

                      return Stack(
                        children: [
                          // Track
                          Container(
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: border),
                            ),
                          ),

                          // Floating pill indicator
                          AnimatedBuilder(
                            animation: tc.animation!,
                            builder: (_, __) {
                              final double t = tc.animation!.value.clamp(0.0, (n - 1).toDouble());
                              final double left = 4 + (t * segW);
                              return Positioned(
                                top: 4,
                                bottom: 4,
                                left: left,
                                width: segW,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    gradient: LinearGradient(
                                      begin: Alignment.topLeft,
                                      end: Alignment.bottomRight,
                                      colors: [_accent, _accent.withOpacity(0.9)],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: _accent.withOpacity(0.26),
                                        blurRadius: 16,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),

                          // Tabs (indicator hidden; we use the animated pill)
                          TabBar(
                            controller: tc,
                            indicatorColor: Colors.transparent,
                            dividerColor: Colors.transparent,
                            overlayColor: MaterialStateProperty.all(Colors.transparent),
                            splashFactory: NoSplash.splashFactory,
                            labelPadding: EdgeInsets.zero,
                            labelStyle: const TextStyle(fontWeight: FontWeight.w800),
                            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
                            labelColor: Colors.white,
                            unselectedLabelColor: unSel,
                            tabs: const [
                              Tab(child: Center(child: Text('Published', maxLines: 1, overflow: TextOverflow.ellipsis))),
                              Tab(child: Center(child: Text('Drafts', maxLines: 1, overflow: TextOverflow.ellipsis))),
                            ],
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),

          // Content
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('gigs')
                  .where('providerId', isEqualTo: uid)
                  .snapshots(),
              builder: (context, snap) {
                // ---- NEW: sleek loading state (no blue flash) ----
                if (snap.connectionState == ConnectionState.waiting) {
                  Widget _skeletonCard() {
                    final base = darkTheme ? Colors.white10 : const Color(0xFFEFF1F6);
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: borderColor),
                      ),
                      child: Row(
                        children: [
                          // thumb box
                          Container(
                            width: 48, height: 48,
                            decoration: BoxDecoration(
                              color: base,
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          const SizedBox(width: 12),
                          // text lines
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(height: 14, width: 160, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(6))),
                                const SizedBox(height: 8),
                                Container(height: 12, width: 220, decoration: BoxDecoration(color: base, borderRadius: BorderRadius.circular(6))),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(width: 20, height: 20, decoration: BoxDecoration(color: base, shape: BoxShape.circle)),
                        ],
                      ),
                    );
                  }

                  return Column(
                    children: [
                      // top thin accent loader
                      SizedBox(
                        height: 2,
                        child: LinearProgressIndicator(
                          minHeight: 2,
                          valueColor: AlwaysStoppedAnimation<Color>(_accent),
                          backgroundColor: Colors.transparent,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                          itemBuilder: (_, i) => _skeletonCard(),
                          separatorBuilder: (_, __) => const SizedBox(height: 10),
                          itemCount: 4,
                        ),
                      ),
                    ],
                  );
                }
                // -----------------------------------------------

                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: _infoTile('Could not load services: ${snap.error}', subtitle),
                  );
                }

                final allDocs = (snap.data?.docs ?? []).toList();

                // newest first
                allDocs.sort((a, b) {
                  final am = a.data() as Map<String, dynamic>;
                  final bm = b.data() as Map<String, dynamic>;
                  final da = am['createdAt'];
                  final db = bm['createdAt'];
                  final ta = (da is Timestamp) ? da.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                  final tb = (db is Timestamp) ? db.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                  return tb.compareTo(ta);
                });

                final published = allDocs.where((d) {
                  final m = d.data() as Map<String, dynamic>;
                  return (m['status'] ?? 'active') == 'active';
                }).toList();

                final drafts = allDocs.where((d) {
                  final m = d.data() as Map<String, dynamic>;
                  return (m['status'] ?? '') == 'draft';
                }).toList();

                Widget gigTile(QueryDocumentSnapshot d) {
                  final data = d.data() as Map<String, dynamic>;
                  final id = d.id;
                  final title = (data['title'] ?? 'Untitled').toString();
                  final category = (data['category'] ?? '').toString();
                  final hours = (data['workingHours'] ?? '').toString();
                  final price = data['price'];
                  final status = (data['status'] ?? 'active').toString();
                  final photosB64 = (data['photosB64'] as List?)?.cast<String>() ?? const [];

                  ImageProvider? thumb;
                  if (photosB64.isNotEmpty) {
                    try { thumb = MemoryImage(base64Decode(photosB64.first)); } catch (_) {}
                  }

                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cardColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: borderColor),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Thumb
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: thumb != null
                              ? Image(image: thumb, width: 48, height: 48, fit: BoxFit.cover)
                              : Container(
                            width: 48,
                            height: 48,
                            color: _accent.withOpacity(0.12),
                            child: const Icon(Icons.image_outlined, color: _accent),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Texts
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: fg,
                                        fontSize: 15.5,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                  if (status == 'draft')
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.withOpacity(0.15),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'DRAFT',
                                        style: TextStyle(
                                          color: Colors.orange,
                                          fontWeight: FontWeight.w800,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _composeSubtitle(category, hours, price),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: subtitle, fontSize: 12.5, height: 1.1),
                              ),
                            ],
                          ),
                        ),

                        // Menu
                        PopupMenuButton<String>(
                          icon: Icon(Icons.more_vert, color: darkTheme ? Colors.white70 : Colors.black54),
                          onSelected: (v) async {
                            if (v == 'edit') {
                              await Navigator.push<bool>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => AddServiceScreen(
                                    gigId: id,
                                    initialData: data,
                                  ),
                                ),
                              );
                            } else if (v == 'publish') {
                              await FirebaseFirestore.instance
                                  .collection('gigs')
                                  .doc(id)
                                  .set({'status': 'active'}, SetOptions(merge: true));
                              if (mounted) _toastSuccess('Published');
                            } else if (v == 'delete') {
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (_) => AlertDialog(
                                  title: const Text('Confirm delete'),
                                  content: const Text('This action cannot be undone.'),
                                  actions: [
                                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                                    FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
                                  ],
                                ),
                              );
                              if (ok == true) {
                                await FirebaseFirestore.instance.collection('gigs').doc(id).delete();
                                if (mounted) _toastSuccess('Service deleted');
                              }
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'edit', child: Text('Edit')),
                            if (status == 'draft') const PopupMenuItem(value: 'publish', child: Text('Publish')),
                            const PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ],
                    ),
                  );
                }

                Widget listFor(List<QueryDocumentSnapshot> items, {required bool isDrafts}) {
                  if (items.isEmpty) {
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      children: [
                        _infoTile(
                          isDrafts
                              ? 'No drafts yet. Use "Save Draft" on the form.'
                              : (allDocs.isEmpty ? 'No services yet. Tap "Add Service".' : 'No published services yet.'),
                          subtitle,
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                    itemCount: items.length,
                    itemBuilder: (_, i) => gigTile(items[i]),
                  );
                }

                return TabBarView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // Published
                    listFor(published, isDrafts: false),
                    // Drafts
                    listFor(drafts, isDrafts: true),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }



// ======================= ALERTS + ONGOING SHEET =======================
  Future<void> _clearAllAlerts(String uid) async {
    try {
      final fs = FirebaseFirestore.instance;

      final snap = await fs
          .collection('service_requests')
          .where('providerId', isEqualTo: uid)
          .where('status', whereIn: ['cancelled', 'completed', 'declined', 'not_completed'])
          .limit(500) // safety cap
          .get();

      if (snap.docs.isEmpty) {
        _toastInfo('No alerts to remove.');
        return;
      }

      final batch = fs.batch();
      for (final d in snap.docs) {
        final m = d.data() as Map<String, dynamic>;
        // Extra guard: skip if this doc doesn’t belong to this provider
        if ((m['providerId'] ?? '') != uid) continue;

        batch.update(d.reference, {
          'providerAlertHidden': true,
          'providerClearedAt': FieldValue.serverTimestamp(),
        });
      }

      await batch.commit();
      _toastSuccess('Removed ${snap.docs.length} alert(s).');
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        _toastError('Permissions error: can’t clear alerts. Check Firestore rules.');
      } else {
        _toastError('Failed to clear alerts: ${e.message}');
      }
    } catch (e) {
      _toastError('Failed to clear alerts: $e');
    }
  }

  void _openAlertsAndOngoingSheet(BuildContext ctx, String uid) {
    final media      = MediaQuery.of(ctx);
    final screenH    = media.size.height;
    final statusBarH = media.padding.top;
    const appBarH    = kToolbarHeight; // adjust if your bookings AppBar height differs
    final targetH    = screenH - (statusBarH + appBarH);

    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      useSafeArea: false,
      backgroundColor: darkTheme ? const Color(0xFF1A1A1A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      constraints: BoxConstraints(maxHeight: targetH),
      builder: (_) {
        return SizedBox(
          height: targetH,
          child: DefaultTabController(
            length: 2,
            child: StatefulBuilder(
              builder: (c, setSt) {
                final fg  = darkTheme ? Colors.white : Colors.black;
                final sub = darkTheme ? Colors.white70 : Colors.black54;

                // ---------------- helpers ----------------
                String h2(int v) => v < 10 ? '0$v' : '$v';
                String dd(DateTime d) => '${d.year}-${h2(d.month)}-${h2(d.day)}';

                // Match bookings card: scheduledAt + (graceHours or default 2h), or use explicit dueBy if present.
                DateTime _dueByFrom(Map<String, dynamic> m) {
                  if (m['dueBy'] is Timestamp) return (m['dueBy'] as Timestamp).toDate();
                  final sch  = (m['scheduledAt'] as Timestamp?)?.toDate();
                  final gh   = (m['graceHours'] is num) ? (m['graceHours'] as num).round() : 2; // default 2h to match bookings
                  if (sch != null) return sch.add(Duration(hours: gh));
                  final created = (m['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now();
                  return created.add(Duration(hours: 1 + gh));
                }

                String durText(Duration diff) {
                  final s = diff.inSeconds;
                  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
                  if (h > 0) return '${h}h ${m}m';
                  if (m > 0) return '${m}m ${sec}s';
                  return '${sec}s';
                }

                String fmtTS(Timestamp? ts) {
                  if (ts == null) return '—';
                  final d = ts.toDate();
                  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
                  final ampm = d.hour >= 12 ? 'PM' : 'AM';
                  return '${dd(d)} • $h12:${h2(d.minute)} $ampm';
                }

                // ---------------- UI bits ----------------
                Widget segmentedTabs() {
                  final Color trackBg  = darkTheme ? const Color(0xFF14151A) : const Color(0xFFF5F6FA);
                  final Color trackBr  = darkTheme ? Colors.white10 : const Color(0xFFE9EAF2);
                  final Color unSelTxt = darkTheme ? Colors.white70 : const Color(0xFF55597D);
                  final tc = DefaultTabController.of(c)!;

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: SizedBox(
                      height: 46,
                      child: LayoutBuilder(
                        builder: (context, cons) {
                          const n = 2;
                          final segW = (cons.maxWidth - 8) / n;
                          return Stack(
                            children: [
                              Container(
                                decoration: BoxDecoration(
                                  color: trackBg,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: trackBr),
                                ),
                              ),
                              AnimatedBuilder(
                                animation: tc.animation!,
                                builder: (_, __) {
                                  final t = tc.animation!.value.clamp(0.0, (n - 1).toDouble());
                                  final left = 4 + (t * segW);
                                  return Positioned(
                                    top: 4, bottom: 4, left: left, width: segW,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [_accent, _accent.withOpacity(0.9)],
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: _accent.withOpacity(0.26),
                                            blurRadius: 16,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                              TabBar(
                                indicatorColor: Colors.transparent,
                                dividerColor: Colors.transparent,
                                overlayColor: MaterialStateProperty.all(Colors.transparent),
                                splashFactory: NoSplash.splashFactory,
                                labelPadding: EdgeInsets.zero,
                                labelStyle: const TextStyle(fontWeight: FontWeight.w800),
                                unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
                                labelColor: Colors.white,
                                unselectedLabelColor: unSelTxt,
                                tabs: const [
                                  Tab(child: Center(child: Text('Alerts',  maxLines: 1, overflow: TextOverflow.ellipsis))),
                                  Tab(child: Center(child: Text('Ongoing', maxLines: 1, overflow: TextOverflow.ellipsis))),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  );
                }

                // Compact alert tile with an inline single-dismiss (×)
                Widget alertTile({
                  required IconData icon,
                  required Color color,
                  required String title,
                  required String subtitle,
                  required VoidCallback onDismiss,
                }) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: darkTheme ? const Color(0xFF232323) : const Color(0xFFF7F8FD),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: darkTheme ? Colors.white10 : const Color(0xFFE9EAF2)),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: color.withOpacity(.12),
                          child: Icon(icon, color: color, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 14.5)),
                              const SizedBox(height: 2),
                              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: sub, fontSize: 12.5)),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: onDismiss,
                          tooltip: 'Dismiss',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                        ),
                      ],
                    ),
                  );
                }

                // ---------------- Alerts Tab ----------------
                Widget alertsTab() {
                  final fs = FirebaseFirestore.instance;

                  // Finished/cancelled/declined
                  final finished$ = fs
                      .collection('service_requests')
                      .where('providerId', isEqualTo: uid)
                      .where('status', whereIn: ['cancelled', 'completed', 'declined', 'not_completed'])
                      .orderBy('updatedAt', descending: true)
                      .limit(80)
                      .snapshots();

                  // Accepted (newly accepted jobs)
                  final accepted$ = fs
                      .collection('service_requests')
                      .where('providerId', isEqualTo: uid)
                      .where('status', isEqualTo: 'accepted')
                      .orderBy('updatedAt', descending: true)
                      .limit(80)
                      .snapshots();

                  // Due soon (accepted/enroute within next 2h)
                  final now = DateTime.now();
                  final soonEnd = now.add(const Duration(hours: 2));
                  final dueSoon$ = fs
                      .collection('service_requests')
                      .where('providerId', isEqualTo: uid)
                      .where('status', whereIn: ['accepted', 'enroute'])
                      .where('scheduledAt', isGreaterThan: Timestamp.fromDate(now))
                      .where('scheduledAt', isLessThanOrEqualTo: Timestamp.fromDate(soonEnd))
                      .limit(120)
                      .snapshots();

                  // Provider-side dismissed map (so we can hide accepted/dueSoon without touching requests)
                  final user$ = fs.collection('users').doc(uid).snapshots();

                  return StreamBuilder<QuerySnapshot>(
                    stream: finished$,
                    builder: (_, finSnap) {
                      final finDocsRaw = (finSnap.data?.docs ?? const []);
                      final finDocs = finDocsRaw.where((d) {
                        final m = d.data() as Map<String, dynamic>;
                        final hidden = (m['providerHidden'] ?? false) == true;
                        final alertHidden = (m['providerAlertHidden'] ?? false) == true;
                        return !hidden && !alertHidden;
                      }).toList();

                      return StreamBuilder<QuerySnapshot>(
                        stream: accepted$,
                        builder: (_, accSnap) {
                          final accDocs = (accSnap.data?.docs ?? const []);

                          return StreamBuilder<QuerySnapshot>(
                            stream: dueSoon$,
                            builder: (_, soonSnap) {
                              final soonDocs = (soonSnap.data?.docs ?? const []);

                              return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                                stream: user$,
                                builder: (_, snap) {
                                  final userMap   = snap.data?.data() ?? <String, dynamic>{};
                                  final dismissed = Map<String, bool>.from(userMap['dismissedAlerts'] ?? {});

                                  // Build a single list: [dueSoon*, accepted, finished/cancelled/declined]
                                  final tiles = <Widget>[];

                                  // Top-right "Remove all" inside Alerts tab
                                  tiles.add(
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        IconButton(
                                          tooltip: 'Remove all',
                                          onPressed: () async {
                                            // 1) Hide finished/cancelled/declined on request docs (non-destructive)
                                            if (finDocs.isNotEmpty) {
                                              final batch = fs.batch();
                                              for (final d in finDocs) {
                                                batch.update(d.reference, {
                                                  'providerAlertHidden': true,
                                                  'updatedAt': FieldValue.serverTimestamp(),
                                                });
                                              }
                                              await batch.commit();
                                            }
                                            // 2) Dismiss accepted + dueSoon via users/{uid}.dismissedAlerts map
                                            final ids = <String>{};
                                            for (final d in accDocs)  { ids.add(d.id); }
                                            for (final d in soonDocs) { ids.add(d.id); }
                                            if (ids.isNotEmpty) {
                                              final payload = <String, dynamic>{};
                                              for (final id in ids) { payload['dismissedAlerts.$id'] = true; }
                                              await fs.collection('users').doc(uid).set(payload, SetOptions(merge: true));
                                            }
                                          },
                                          icon: const Icon(Icons.delete_sweep_rounded),
                                          visualDensity: VisualDensity.compact,
                                        ),
                                      ],
                                    ),
                                  );

                                  // ------------- Due soon (virtual) -------------
                                  for (final d in soonDocs) {
                                    if (dismissed['${d.id}'] == true) continue; // hidden by provider
                                    final m = d.data() as Map<String, dynamic>;
                                    final title = (m['gigTitle'] ?? m['title'] ?? 'Service').toString();
                                    final due   = _dueByFrom(m);
                                    final diff  = due.difference(DateTime.now());
                                    // Only show if <= 2h
                                    if (diff > const Duration(hours: 2)) continue;

                                    tiles.add(
                                      alertTile(
                                        icon: Icons.timer_rounded,
                                        color: _accent,
                                        title: '$title • due in ≤ 2h',
                                        subtitle: diff.isNegative
                                            ? 'Overdue by ${durText(-diff)}'
                                            : 'Due in ${durText(diff)} • ${fmtTS(m['scheduledAt'] as Timestamp?)}',
                                        onDismiss: () async {
                                          await fs.collection('users').doc(uid).set(
                                            {'dismissedAlerts.${d.id}': true},
                                            SetOptions(merge: true),
                                          );
                                        },
                                      ),
                                    );
                                    tiles.add(const SizedBox(height: 8));
                                  }

                                  // ------------- Accepted -------------
                                  for (final d in accDocs) {
                                    if (dismissed['${d.id}'] == true) continue;
                                    final m   = d.data() as Map<String, dynamic>;
                                    final t   = (m['gigTitle'] ?? m['title'] ?? 'Service').toString();
                                    final ts  = fmtTS(m['updatedAt'] as Timestamp?);
                                    tiles.add(
                                      alertTile(
                                        icon: Icons.task_alt_rounded,
                                        color: _ok,
                                        title: 'Accepted • $t',
                                        subtitle: ts,
                                        onDismiss: () async {
                                          await fs.collection('users').doc(uid).set(
                                            {'dismissedAlerts.${d.id}': true},
                                            SetOptions(merge: true),
                                          );
                                        },
                                      ),
                                    );
                                    tiles.add(const SizedBox(height: 8));
                                  }

                                  // ------------- Finished / Cancelled / Declined -------------
                                  for (final d in finDocs) {
                                    final m = d.data() as Map<String, dynamic>;
                                    final status = (m['status'] ?? '').toString().toLowerCase();
                                    final t      = (m['gigTitle'] ?? m['title'] ?? 'Service').toString();
                                    final addr   = (m['label'] ?? m['address'] ?? '').toString();
                                    final ts     = fmtTS(m['updatedAt'] as Timestamp?);
                                    final who    = (m['cancelledBy'] ?? '').toString().toLowerCase();

                                    IconData icon; Color color; String title; String subtitleTxt;
                                    if (status == 'not_completed') {
                                      icon = Icons.schedule_rounded;
                                      color = const Color(0xFF8E8E93); // neutral grey
                                      final dueByTs = m['dueBy'] as Timestamp?;
                                      final dueTxt = dueByTs == null ? '' : ' • Due: ${fmtTS(dueByTs)}';
                                      final ovMin = (m['overdueByMin'] is num) ? (m['overdueByMin'] as num).toInt() : null;
                                      final overTxt = (ovMin == null || ovMin <= 0) ? '' : ' • Overdue by ${ovMin}m';
                                      title = 'Not completed • ${t}';
                                      subtitleTxt = (addr.isEmpty ? ts : '$addr  •  $ts') + dueTxt + overTxt;
                                    } else if (status == 'cancelled' || status == 'declined') {
                                      icon = Icons.cancel_rounded; color = _danger;
                                      final whoTxt = (who == 'provider') ? 'You' : (who == 'seeker') ? 'Seeker' : 'Someone';
                                      title = (status == 'declined') ? 'Declined • $t' : 'Cancelled by $whoTxt • $t';
                                      subtitleTxt = addr.isEmpty ? ts : '$addr  •  $ts';
                                    } else { // completed
                                      icon = Icons.check_circle_rounded; color = _ok;
                                      title = 'Completed • $t';
                                      subtitleTxt = ts;
                                    }

                                    tiles.add(
                                      alertTile(
                                        icon: icon,
                                        color: color,
                                        title: title,
                                        subtitle: subtitleTxt,
                                        onDismiss: () async {
                                          await d.reference.update({
                                            'providerAlertHidden': true,
                                            'updatedAt': FieldValue.serverTimestamp(),
                                          });
                                        },
                                      ),
                                    );
                                    tiles.add(const SizedBox(height: 8));
                                  }

                                  // Empty state centered
                                  if (tiles.length <= 1) {
                                    return const Center(child: Text('No alerts'));
                                  }

                                  return ListView(
                                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                                    children: tiles,
                                  );
                                },
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                }

                // ---------------- Ongoing (enroute only) ----------------
                Widget ongoingCompactTile(QueryDocumentSnapshot d) {
                  final m = d.data() as Map<String, dynamic>;
                  final title = (m['gigTitle'] ?? m['title'] ?? 'Service').toString();
                  final status = (m['status'] ?? '').toString();
                  final scheduledAt = m['scheduledAt'] as Timestamp?;
                  final dueBy = _dueByFrom(m);

                  final chipBg = const Color(0xFFEFF3FF);
                  final chipFg = const Color(0xFF3D6BFF);

                  return Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: darkTheme ? const Color(0xFF232323) : const Color(0xFFF7F8FD),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: darkTheme ? Colors.white10 : const Color(0xFFE9EAF2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: fg, fontWeight: FontWeight.w800),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(999)),
                              child: Text(
                                status.isNotEmpty ? status[0].toUpperCase() + status.substring(1) : '—',
                                style: TextStyle(color: chipFg, fontWeight: FontWeight.w800, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        StreamBuilder<DateTime>(
                          stream: Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()),
                          builder: (_, snapNow) {
                            final now = snapNow.data ?? DateTime.now();
                            final diff = dueBy.difference(now);
                            final overdue = diff.isNegative;
                            final badgeBg = overdue ? const Color(0xFFFFEEF0) : const Color(0xFFEFF8FF);
                            final badgeFg = overdue ? const Color(0xFFD33A4A) : const Color(0xFF0A66C2);

                            return Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: badgeBg,
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: badgeBg),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(overdue ? Icons.schedule_outlined : Icons.timer_outlined, size: 14, color: badgeFg),
                                      const SizedBox(width: 6),
                                      Text(
                                        overdue ? 'Overdue by ${durText(-diff)}' : 'Due in ${durText(diff)}',
                                        style: TextStyle(color: badgeFg, fontWeight: FontWeight.w800, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                Text('Scheduled: ${fmtTS(scheduledAt)}', style: TextStyle(color: sub, fontSize: 12.5)),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  );
                }

                Widget ongoingTab() {
                  return StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('service_requests')
                        .where('providerId', isEqualTo: uid)
                        .where('status', isEqualTo: 'enroute')
                        .orderBy('createdAt', descending: true)
                        .snapshots(),
                    builder: (_, snap) {
                      final docs = (snap.data?.docs ?? const []).where((d) {
                        final m = d.data() as Map<String, dynamic>;
                        return (m['providerHidden'] ?? false) != true;
                      }).toList();

                      if (docs.isEmpty) {
                        return const Center(child: Text('No ongoing jobs'));
                      }

                      docs.sort((a, b) {
                        final am = a.data() as Map<String, dynamic>;
                        final bm = b.data() as Map<String, dynamic>;
                        final ad = _dueByFrom(am);
                        final bd = _dueByFrom(bm);
                        return ad.compareTo(bd);
                      });

                      return ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        itemCount: docs.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) => ongoingCompactTile(docs[i] as QueryDocumentSnapshot),
                      );
                    },
                  );
                }

                // ---------------- Sheet Layout ----------------
                return FractionallySizedBox(
                  heightFactor: 0.98,
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(width: 42, height: 4,
                        decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(4)),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Row(
                          children: [
                            Icon(Icons.notifications_active_rounded, color: _accent),
                            const SizedBox(width: 8),
                            Text('Updates', style: TextStyle(color: fg, fontWeight: FontWeight.w900)),
                            const Spacer(),
                            // (No trailing button here to keep header width identical across tabs)
                          ],
                        ),
                      ),
                      segmentedTabs(),
                      const Divider(height: 0),
                      Expanded(
                        child: TabBarView(
                          physics: const BouncingScrollPhysics(),
                          children: [
                            alertsTab(),
                            ongoingTab(),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

// ======================= MAP SHEET (live provider tracking) =======================
  // ======================= MAP SHEET (live provider tracking) =======================
  void _openMapSheet(String requestId, Map<String, dynamic> data) {
    // Auth guard: if user got signed out, don't open anything (prevents PERMISSION_DENIED spam).
    if (FirebaseAuth.instance.currentUser == null) {
      _toastWarn('Please log in to view map');
      return;
    }

    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    final label = (data['label'] ?? '').toString();
    final address = (data['address'] ?? '').toString();

    if (lat == null || lng == null) {
      _toastWarn('No location on this request');
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: darkTheme ? const Color(0xFF1A1A1A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            GoogleMapController? gCtrl;
            Position? me;
            double? meters;
            bool locating = false;

            // lifecycle flag for this sheet — prevents setState after dispose
            bool alive = true;
            void safeSet(void Function() fn) {
              if (!alive) return;
              try { setSt(fn); } catch (_) {}
            }

            // Firestore live doc
            final liveDocRef = FirebaseFirestore.instance.collection('request_live').doc(requestId);
            StreamSubscription<DocumentSnapshot>? liveSub;
            LatLng? liveFromFirestore;

            Future<void> _attachLive() async {
              await liveSub?.cancel();
              liveSub = liveDocRef.snapshots().listen((ds) {
                final m = ds.data() as Map<String, dynamic>?;
                if (m == null) return;
                final pLat = (m['providerLat'] as num?)?.toDouble();
                final pLng = (m['providerLng'] as num?)?.toDouble();
                if (pLat != null && pLng != null) {
                  safeSet(() {
                    liveFromFirestore = LatLng(pLat, pLng);
                    meters = Geolocator.distanceBetween(pLat, pLng, lat, lng);
                  });
                }
              }, onError: (_) {
                // Ignore permission denied noise if the user signs out while open
              });
            }

            Future<void> _detachLive() async {
              await liveSub?.cancel();
              liveSub = null;
            }

            Future<void> _getMeOnce() async {
              try {
                safeSet(() => locating = true);

                LocationPermission permission = await Geolocator.checkPermission();
                if (permission == LocationPermission.denied) {
                  permission = await Geolocator.requestPermission();
                }
                if (permission == LocationPermission.denied ||
                    permission == LocationPermission.deniedForever) {
                  safeSet(() => locating = false);
                  _toastWarn('Location permission denied');
                  return;
                }

                final p = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
                final m = Geolocator.distanceBetween(p.latitude, p.longitude, lat, lng);

                safeSet(() {
                  me = p;
                  meters = m;
                  locating = false;
                });

                if (gCtrl != null) {
                  final bounds = LatLngBounds(
                    southwest: LatLng(
                      (p.latitude < lat) ? p.latitude : lat,
                      (p.longitude < lng) ? p.longitude : lng,
                    ),
                    northeast: LatLng(
                      (p.latitude > lat) ? p.latitude : lat,
                      (p.longitude > lng) ? p.longitude : lng,
                    ),
                  );
                  await gCtrl!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
                }
              } catch (_) {
                safeSet(() => locating = false);
              }
            }

            String _distanceText() {
              if (meters == null) return '—';
              if (meters! < 1000) return '${meters!.toStringAsFixed(0)} m';
              return '${(meters! / 1000).toStringAsFixed(1)} km';
            }

            String _etaText() {
              if (meters == null) return '—';
              final km = meters! / 1000;
              final mins = (km / 25.0) * 60.0; // ~25 km/h
              if (mins < 1) return '< 1 min';
              if (mins < 60) return '${mins.toStringAsFixed(0)} min';
              final h = (mins / 60).floor();
              final m = (mins - (h * 60)).round();
              return m == 0 ? '${h}h' : '${h}h ${m}m';
            }

            final seekerLatLng = LatLng(lat, lng);
            final labelText = (label.isEmpty ? address : label);

            // attach on open
            _attachLive();
            _getMeOnce();

            return WillPopScope(
              onWillPop: () async {
                // close: cancel listeners & stop setState
                alive = false;
                await _detachLive();
                return true;
              },
              child: SizedBox(
                height: 540,
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(width: 40, height: 4,
                      decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(4)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Use WRAP instead of a tight Row to avoid overflows on small screens
                          Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.location_pin, color: Colors.redAccent),
                                  const SizedBox(width: 8),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(maxWidth: 260),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          labelText,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w800,
                                            color: darkTheme ? Colors.white : Colors.black,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 2),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(Icons.route, size: 14, color: Colors.grey),
                                            const SizedBox(width: 4),
                                            Text(
                                              'Distance: ${_distanceText()} • ETA: ${_etaText()}',
                                              style: TextStyle(
                                                color: darkTheme ? Colors.white70 : Colors.black54,
                                                fontSize: 12.5,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Locate me',
                                    onPressed: locating ? null : _getMeOnce,
                                    icon: locating
                                        ? const SizedBox(
                                      height: 18, width: 18,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                        : const Icon(Icons.my_location_rounded),
                                  ),
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      minimumSize: const Size(0, 40),
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    onPressed: () => _launchMapsByLatLng(lat, lng, label: labelText),
                                    icon: const Icon(Icons.map_rounded, size: 18),
                                    // shorter label to reduce overflow risk
                                    label: const Text('Nav'),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                        child: GoogleMap(
                          onMapCreated: (c) => gCtrl = c,
                          initialCameraPosition: CameraPosition(target: seekerLatLng, zoom: 15.5),
                          markers: {
                            Marker(
                              markerId: const MarkerId('seeker'),
                              position: seekerLatLng,
                              infoWindow: const InfoWindow(title: 'Seeker'),
                            ),
                            if (liveFromFirestore != null)
                              Marker(
                                markerId: const MarkerId('provider_live'),
                                position: liveFromFirestore!,
                                icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                                infoWindow: const InfoWindow(title: 'You (Live)'),
                              ),
                          },
                          myLocationButtonEnabled: false,
                          myLocationEnabled: false,
                          zoomControlsEnabled: false,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _gpsSubs.containsKey(requestId)
                                  ? () => _stopLiveShare(requestId)
                                  : () => _startLiveShare(requestId),
                              icon: Icon(_gpsSubs.containsKey(requestId)
                                  ? Icons.wifi_tethering_off
                                  : Icons.wifi_tethering),
                              label: Text(_gpsSubs.containsKey(requestId)
                                  ? 'Stop live share'
                                  : 'Start live share'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () async {
                                if (gCtrl == null) return;
                                final p = liveFromFirestore;
                                if (p != null) {
                                  final bounds = LatLngBounds(
                                    southwest: LatLng(
                                      (p.latitude < lat) ? p.latitude : lat,
                                      (p.longitude < lng) ? p.longitude : lng,
                                    ),
                                    northeast: LatLng(
                                      (p.latitude > lat) ? p.latitude : lat,
                                      (p.longitude > lng) ? p.longitude : lng,
                                    ),
                                  );
                                  await gCtrl!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 60));
                                } else {
                                  await gCtrl!.animateCamera(CameraUpdate.newLatLng(seekerLatLng));
                                }
                              },
                              icon: const Icon(Icons.center_focus_strong),
                              label: const Text('Recenter'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }



// ======================= ACTIONS =======================
  Future<void> _acceptFlow(BuildContext context,
      QueryDocumentSnapshot doc) async {
    final when = await _pickDateTime(context);
    if (when == null) return;

    final m = doc.data() as Map<String, dynamic>;
    final gigTitle = (m['gigTitle'] ?? m['title'] ?? '').toString();

    await FirebaseFirestore.instance
        .collection('service_requests')
        .doc(doc.id)
        .update({
      'status': 'accepted',
      'scheduledAt': Timestamp.fromDate(when),
      'providerCompleted': false,
      'cancelledBy': FieldValue.delete(),
      'providerCancelled': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
      if (gigTitle.isNotEmpty) 'gigTitle': gigTitle,
    });
    if (!mounted) return;
    _toastSuccess('Accepted • ${_fmtDT(when)}');
  }

  Future<void> _rescheduleFlow(BuildContext context, QueryDocumentSnapshot doc) async {
    final when = await _pickDateTime(context);
    if (when == null) return;

    // Check current status to decide whether to "reopen"
    final fresh = await FirebaseFirestore.instance.collection('service_requests').doc(doc.id).get();
    final fm = (fresh.data() as Map<String, dynamic>?) ?? {};
    final isNC = (fm['status'] ?? '').toString().toLowerCase() == 'not_completed';

    final payload = <String, dynamic>{
      'scheduledAt': Timestamp.fromDate(when),
      'rescheduledAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (isNC) {
      payload.addAll({
        'status': 'accepted',
        'notCompletedAt': FieldValue.delete(),
        'overdueByMin': FieldValue.delete(),
        'dueBy': FieldValue.delete(),
        'lastAutoStatus': FieldValue.delete(),
      });
    }

    await FirebaseFirestore.instance.collection('service_requests').doc(doc.id).update(payload);
    if (!mounted) return;
    _toastInfo(isNC ? 'Rescheduled and reopened • ${_fmtDT(when)}' : 'Schedule updated • ${_fmtDT(when)}');
  }


// ---- Mark completed -> archive to services_history
  Future<void> _providerComplete(QueryDocumentSnapshot doc) async {
    // Fresh-status guard: only allow when current status == 'enroute'
    try {
      final fresh = await FirebaseFirestore.instance
          .collection('service_requests')
          .doc(doc.id)
          .get();

      final fm = fresh.data() as Map<String, dynamic>? ?? {};
      final currentStatus = (fm['status'] ?? '').toString().toLowerCase();
      if (currentStatus != 'enroute') {
        _toastWarn('You can only mark completed after you have started Enroute.');
        return;
      }
    } catch (_) {
      // If we can’t verify, do not proceed
      _toastError('Could not verify current status. Try again.');
      return;
    }

    final updates = <String, dynamic>{
      'providerCompleted': true,
      'status': 'completed',
      'completedAt': FieldValue.serverTimestamp(),
      'cancelledBy': FieldValue.delete(),
      'providerCancelled': FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    await FirebaseFirestore.instance
        .collection('service_requests')
        .doc(doc.id)
        .update(updates);

    await _archiveRequest(doc, reason: 'completed_auto');

    // stop live share if running
    await _stopLiveShare(doc.id);

    if (!mounted) return;
    _toastSuccess('Marked as completed');
  }


// ---- Provider cancel
  Future<void> _providerCancel(QueryDocumentSnapshot doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) =>
          AlertDialog(
            title: const Text('Cancel booking?'),
            content: const Text(
                'This will cancel the job for both sides. Continue?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false),
                  child: const Text('No')),
              FilledButton(onPressed: () => Navigator.pop(context, true),
                  child: const Text('Yes, cancel')),
            ],
          ),
    );
    if (ok != true) return;

    await FirebaseFirestore.instance
        .collection('service_requests')
        .doc(doc.id)
        .update({
      'status': 'cancelled',
      'providerCancelled': true,
      'cancelledBy': 'provider',
      'updatedAt': FieldValue.serverTimestamp(),
    });

    // stop live share if running
    await _stopLiveShare(doc.id);

    if (!mounted) return;
    _toastWarn('Job cancelled');
  }

// ---- Hide for provider (optionally archive if completed)
  Future<void> _hideForProvider(QueryDocumentSnapshot doc) async {
    final m = doc.data() as Map<String, dynamic>;
    final status = (m['status'] ?? '').toString().toLowerCase();

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) =>
          AlertDialog(
            title: const Text('Remove from your list?'),
            content: Text(
              status == 'completed'
                  ? 'This will keep a copy in Service History and remove it from your Bookings.'
                  : 'This will remove it from your Bookings (seeker will still see it).',
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(context, true),
                  child: const Text('Remove')),
            ],
          ),
    );
    if (ok != true) return;

    try {
      if (status == 'completed') {
        await _archiveRequest(doc, reason: 'provider_hide_completed');
      }
      await FirebaseFirestore.instance.collection('service_requests').doc(
          doc.id).set(
        {
          'providerHidden': true,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      _toastInfo('Removed from your list');
    } catch (e) {
      _toastError('Failed: $e');
    }
  }

  Future<void> _archiveRequest(QueryDocumentSnapshot doc,
      {required String reason}) async {
    final m = doc.data() as Map<String, dynamic>;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final historyId = 'req_${doc.id}_$uid';
    await FirebaseFirestore.instance.collection('services_history').doc(
        historyId).set({
      'providerId': uid,
      'sourceId': doc.id,
      'archivedAt': FieldValue.serverTimestamp(),
      'archivedReason': reason,
      'data': m,
    }, SetOptions(merge: true));
  }

  Future<void> _updateStatus(String id, String status) async {
    final data = <String, dynamic>{
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (status == 'enroute') {
      data['enrouteAt'] = FieldValue.serverTimestamp();
    }
    await FirebaseFirestore.instance
        .collection('service_requests')
        .doc(id)
        .update(data);
    if (!mounted) return;
    final nice = status[0].toUpperCase() + status.substring(1);
    if (status == 'declined') {
      _toastWarn('Status: $nice');
    } else if (status == 'enroute') {
      _toastInfo('En route started');
    } else {
      _toastInfo('Status: $nice');
    }
  }

// ---- Enroute: update status + start live share stream
  Future<void> _startEnroute(QueryDocumentSnapshot doc) async {
    await _updateStatus(doc.id, 'enroute');
    await _startLiveShare(doc.id);
  }

// ======================= LIVE SHARE (provider → Firestore) =======================
// Writes provider location to: request_live/{requestId}
// Seeker app can subscribe to the same document to see live movement.
  Future<void> _startLiveShare(String requestId) async {
    if (_gpsSubs.containsKey(requestId)) return; // already on

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _toastWarn('Location permission denied');
      return;
    }
    final providerId = FirebaseAuth.instance.currentUser?.uid;
    if (providerId == null) return;

    final docRef = FirebaseFirestore.instance.collection('request_live').doc(
        requestId);

    final sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 10, // meters
      ),
    ).listen((pos) async {
      try {
        await docRef.set({
          'requestId': requestId,
          'providerId': providerId,
          'providerLat': pos.latitude,
          'providerLng': pos.longitude,
          'heading': pos.heading,
          'speed': pos.speed,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {
        // ignore transient errors
      }
    });

    _gpsSubs[requestId] = sub;
    _trackingReqIds.add(requestId);
    _toastInfo('Live share started');
  }

  Future<void> _stopLiveShare(String requestId) async {
    final sub = _gpsSubs.remove(requestId);
    await sub?.cancel();
    _trackingReqIds.remove(requestId);

    // Optionally mark stopped (don’t delete so seeker can still see last point briefly)
    try {
      await FirebaseFirestore.instance
          .collection('request_live')
          .doc(requestId)
          .set({
        'stoppedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}

    _toastInfo('Live share stopped');
  }

  Future<DateTime?> _pickDateTime(BuildContext context) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: now.add(const Duration(days: 120)),
      helpText: 'Select visit date',
    );
    if (d == null) return null;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(now.add(const Duration(minutes: 30))),
      helpText: 'Select visit time',
    );
    if (t == null) return null;
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

// (Chats stub in Part 3)
// (Ratings tab + AddService categories update in Part 3)
// ======================= CHATS (stub) =======================
  Widget _tabChats(Color fg, Color subtitle, Color cardColor) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      children: [
        Text('Chats', style: TextStyle(
            color: fg, fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _infoTile('Chat will be wired soon.', subtitle),
      ],
    );
  }

// ======================= RATINGS TAB (UPDATED: Correct Pill Tabs) =======================
  Widget _tabRatings(String uid, Color fg, Color subtitle, Color cardColor) {
    final borderColor = darkTheme ? Colors.white12 : const Color(0xFFE9EAF2);

    // Standard Bookings Streams
    final completedStream = FirebaseFirestore.instance.collection('service_requests')
        .where('providerId', isEqualTo: uid).where('status', isEqualTo: 'completed').snapshots();

    final cancelledStream = FirebaseFirestore.instance.collection('service_requests')
        .where('providerId', isEqualTo: uid).where('status', isEqualTo: 'cancelled')
        .where('cancelledBy', isEqualTo: 'provider').snapshots();

    final notCompletedStream = FirebaseFirestore.instance.collection('service_requests')
        .where('providerId', isEqualTo: uid).where('status', isEqualTo: 'not_completed').snapshots();

    // LIVE HISTORY STREAM (To calculate Live Completed/Cancelled)
    final historyStream = FirebaseFirestore.instance.collection('services_history')
        .where('providerId', isEqualTo: uid)
        .where('isLive', isEqualTo: true)
        .snapshots();

    final reviewsStream = FirebaseFirestore.instance.collection('gig_reviews')
        .where('providerId', isEqualTo: uid).snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: reviewsStream,
      builder: (ctx, revSnap) {
        final reviews = (revSnap.data?.docs ?? const [])
            .map((d) => (d.data() as Map<String, dynamic>?) ?? <String, dynamic>{})
            .toList();

        final ratings = reviews
            .map((m) => (m['rating'] is num) ? (m['rating'] as num).toDouble() : 0.0)
            .toList();

        final avg = ratings.isEmpty ? 0.0 : (ratings.reduce((a, b) => a + b) / ratings.length);
        final avgStr = ratings.isEmpty ? '—' : avg.toStringAsFixed(1);
        final fourPlusCount = ratings.where((r) => r >= 4.0).length;

        final Map<String, List<Map<String, dynamic>>> byService = {};
        for (final r in reviews) {
          final fromTitle = (r['gigTitle'] ?? r['title'] ?? '').toString();
          final bool isLiveReview = (r['isLiveRequest'] == true) || ((r['gigId'] ?? '').toString().isEmpty);
          final key = fromTitle.isNotEmpty ? fromTitle : (isLiveReview ? 'Live Service' : 'Service');
          byService.putIfAbsent(key, () => []).add(r);
        }

        return DefaultTabController(
          length: 2,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Text('Ratings Overview', style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w800)),
                    const Spacer(),
                  ],
                ),
              ),

              // ====== TABS BAR (PILL STYLE) ======
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Builder(
                  builder: (context) {
                    final tc = DefaultTabController.of(context)!;
                    final Color bg     = darkTheme ? const Color(0xFF14151A) : const Color(0xFFF5F6FA);
                    final Color border = darkTheme ? Colors.white10 : const Color(0xFFE9EAF2);
                    final Color unSel  = darkTheme ? Colors.white70 : const Color(0xFF55597D);

                    return SizedBox(
                      height: 46,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          const int n = 2;
                          final double w = constraints.maxWidth;
                          final double segW = (w - 8) / n; // 4px insets left/right

                          return Stack(
                            children: [
                              // Track
                              Container(
                                decoration: BoxDecoration(
                                  color: bg,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: border),
                                ),
                              ),

                              // Floating pill indicator
                              AnimatedBuilder(
                                animation: tc.animation!,
                                builder: (_, __) {
                                  final double t = tc.animation!.value.clamp(0.0, (n - 1).toDouble());
                                  final double left = 4 + (t * segW);
                                  return Positioned(
                                    top: 4,
                                    bottom: 4,
                                    left: left,
                                    width: segW,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        gradient: LinearGradient(
                                          begin: Alignment.topLeft,
                                          end: Alignment.bottomRight,
                                          colors: [_accent, _accent.withOpacity(0.9)],
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: _accent.withOpacity(0.26),
                                            blurRadius: 16,
                                            offset: const Offset(0, 8),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),

                              // Tabs (indicator hidden; we use the animated pill)
                              TabBar(
                                controller: tc,
                                indicatorColor: Colors.transparent,
                                dividerColor: Colors.transparent,
                                overlayColor: MaterialStateProperty.all(Colors.transparent),
                                splashFactory: NoSplash.splashFactory,
                                labelPadding: EdgeInsets.zero,
                                labelStyle: const TextStyle(fontWeight: FontWeight.w800),
                                unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
                                labelColor: Colors.white,
                                unselectedLabelColor: unSel,
                                tabs: const [
                                  Tab(child: Center(child: Text('Overall', maxLines: 1, overflow: TextOverflow.ellipsis))),
                                  Tab(child: Center(child: Text('Reviews', maxLines: 1, overflow: TextOverflow.ellipsis))),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  },
                ),
              ),

              // ====== CONTENT ======
              Expanded(
                child: TabBarView(
                  physics: const BouncingScrollPhysics(),
                  children: [
                    // --- TAB 1: OVERALL / PERFORMANCE ---
                    StreamBuilder<QuerySnapshot>(
                        stream: completedStream,
                        builder: (ctx, compSnap) {
                          final stdCompleted = compSnap.data?.docs.length ?? 0;

                          return StreamBuilder<QuerySnapshot>(
                              stream: cancelledStream,
                              builder: (ctx, cancSnap) {
                                final stdCancelled = cancSnap.data?.docs.length ?? 0;

                                return StreamBuilder<QuerySnapshot>(
                                    stream: notCompletedStream,
                                    builder: (ctx, ncSnap) {
                                      final stdNotCompleted = ncSnap.data?.docs.length ?? 0;

                                      // MERGE LIVE COUNTS
                                      return StreamBuilder<QuerySnapshot>(
                                          stream: historyStream,
                                          builder: (ctx, histSnap) {
                                            final historyDocs = histSnap.data?.docs ?? [];

                                            // Count Live Completed
                                            final liveCompleted = historyDocs.where((d) {
                                              final m = d.data() as Map<String, dynamic>;
                                              final data = m['data'] as Map? ?? {};
                                              final status = (data['status'] ?? '').toString();
                                              return status == 'completed';
                                            }).length;

                                            // Count Live Cancelled by Provider
                                            final liveCancelled = historyDocs.where((d) {
                                              final m = d.data() as Map<String, dynamic>;
                                              final data = m['data'] as Map? ?? {};
                                              final status = (data['status'] ?? '').toString();
                                              final by = (data['cancelledBy'] ?? '').toString();
                                              return status == 'cancelled' && by == 'provider';
                                            }).length;

                                            // TOTALS
                                            final totalCompleted = stdCompleted + liveCompleted;
                                            final totalCancelled = stdCancelled + liveCancelled;

                                            return Padding(
                                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 45),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                                children: [
                                                  Expanded(
                                                    child: Row(
                                                      children: [
                                                        Expanded(child: _metricCard(title: 'Average Rating', value: avgStr, icon: Icons.star_rounded, color: const Color(0xFFFFB21D), dark: darkTheme)),
                                                        const SizedBox(width: 10),
                                                        Expanded(child: _metricCard(title: 'Total Completed', value: '$totalCompleted', icon: Icons.check_circle_rounded, color: _ok, dark: darkTheme)),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Expanded(
                                                    child: Row(
                                                      children: [
                                                        Expanded(child: _metricCard(title: 'Cancelled (You)', value: '$totalCancelled', icon: Icons.cancel_rounded, color: _danger, dark: darkTheme)),
                                                        const SizedBox(width: 10),
                                                        Expanded(child: _metricCard(title: 'Not completed', value: '$stdNotCompleted', icon: Icons.schedule_rounded, color: const Color(0xFF8E8E93), dark: darkTheme)),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Expanded(
                                                    child: Row(
                                                      children: [
                                                        Expanded(child: _metricCard(title: 'Total Reviews', value: '${ratings.length}', icon: Icons.rate_review_rounded, color: _accent, dark: darkTheme)),
                                                        const SizedBox(width: 10),
                                                        Expanded(child: _metricCard(title: 'Total 4+ Ratings', value: '$fourPlusCount', icon: Icons.stars_rounded, color: Colors.cyan, dark: darkTheme)),
                                                      ],
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          }
                                      );
                                    }
                                );
                              }
                          );
                        }
                    ),

                    // --- TAB 2: REVIEWS ---
                    ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                      children: [
                        if (revSnap.connectionState == ConnectionState.waiting)
                          const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: Center(child: CircularProgressIndicator()))
                        else if (byService.isEmpty)
                          _infoTile('No reviews yet.', subtitle)
                        else
                          ...byService.entries.map((e) => _gigReviewsSection(
                            title: e.key,
                            reviews: e.value,
                            subtitle: subtitle,
                            fg: fg,
                            dark: darkTheme,
                            cardBg: cardColor,
                            borderColor: borderColor,
                          )),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

// ======== METRIC CARD (icon top-left, title centered, number below; theme-consistent) ========
  Widget _metricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    required bool dark,
  }) {
    final bg = dark ? color.withOpacity(.18) : color.withOpacity(.12);
    final iconBg = dark ? color.withOpacity(.22) : color.withOpacity(.16);
    final titleColor = dark ? Colors.white70 : Colors.black54;
    final valueColor = dark ? Colors.white : Colors.black;

    return Container(
      padding: const EdgeInsets.all(14),
      constraints: const BoxConstraints(minHeight: 116),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: bg),
      ),
      child: Stack(
        children: [
          // Icon top-left
          Positioned(
            top: 0,
            left: 4,
            child: Container(
              width: 120,
              height: 30,
              decoration: BoxDecoration(
                color: iconBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
          ),

          // Centered title + value
          Align(
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Title (center)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor,
                      fontWeight: FontWeight.w800,
                      letterSpacing: .2,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Number (below title)
                Text(
                  value,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 26,
                    height: 1.0,
                    fontWeight: FontWeight.w900,
                    color: valueColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _gigReviewsSection({
    required String title,
    required List<Map<String, dynamic>> reviews,
    required Color subtitle,
    required Color fg,
    required bool dark,
    required Color cardBg,
    required Color borderColor,
  }) {
    // 1. Detect if this group is for Live Requests
    // (Based on the logic that live requests have empty gigId or explicitly set flag)
    final bool isLive = reviews.isNotEmpty && (
        (reviews.first['isLiveRequest'] == true) ||
            (reviews.first['gigId'] ?? '').toString().isEmpty
    );

    // Sort newest first
    final sorted = [...reviews];
    sorted.sort((a, b) {
      final ta = a['createdAt'];
      final tb = b['createdAt'];
      final da = (ta is Timestamp) ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
      final db = (tb is Timestamp) ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
      return db.compareTo(da);
    });

    final latest = sorted.isNotEmpty ? sorted.first : null;
    final others = sorted.length > 1 ? sorted.sublist(1) : const <Map<String, dynamic>>[];

    final tileBg = dark ? const Color(0xFF232323) : const Color(0xFFF7F8FD);
    final tileBorder = dark ? Colors.white10 : const Color(0xFFE9EAF2);

    Widget _reviewTile(Map<String, dynamic> r) {
      final rating = (r['rating'] is num) ? (r['rating'] as num).toDouble() : 0.0;
      final author = (r['authorName'] ?? 'Anonymous').toString();
      final txt = (r['text'] ?? r['review'] ?? '').toString();
      final created = r['createdAt'] as Timestamp?;
      final when = created == null ? '' : _fmtTS(created);

      return Container(
        padding: const EdgeInsets.all(10), // compact
        margin: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
          color: tileBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: tileBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.star_rounded, color: Color(0xFFFFB21D), size: 18),
                const SizedBox(width: 6),
                Text(rating.toStringAsFixed(1), style: TextStyle(fontWeight: FontWeight.w900, color: fg)),
                const SizedBox(width: 8),
                Expanded(child: Text(author, style: TextStyle(color: fg, fontWeight: FontWeight.w700))),
                Text(when, style: TextStyle(color: subtitle, fontSize: 12)),
              ],
            ),
            if (txt.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                txt,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: fg, height: 1.2),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: cardBg,
        border: Border.all(color: borderColor),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + Badge + Count
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(color: fg, fontWeight: FontWeight.w800),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // SHOW LIVE BADGE
                    if (isLive) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE7FFF2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFFCFF5E1)),
                        ),
                        child: const Text(
                            'LIVE',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF0F9155))
                        ),
                      )
                    ],
                  ],
                ),
              ),
              if (sorted.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                  decoration: BoxDecoration(
                    color: _accent.withOpacity(dark ? .18 : .12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${sorted.length}',
                    style: TextStyle(
                      color: dark ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),

          // Latest only on card
          if (latest != null) _reviewTile(latest),

          // View more -> opens bottom sheet with the remaining reviews
          if (others.isNotEmpty)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => _openAllReviewsSheet(title, others),
                icon: const Icon(Icons.expand_more),
                label: Text('View more (${others.length})'),
              ),
            ),
        ],
      ),
    );
  }

  void _openAllReviewsSheet(String title, List<Map<String, dynamic>> reviews) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: darkTheme ? const Color(0xFF1A1A1A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        final dark = darkTheme;
        final textColor = dark ? Colors.white : Colors.black;
        final subColor = dark ? Colors.white70 : Colors.black54;
        final tileBg = dark ? const Color(0xFF232323) : const Color(0xFFF7F8FD);
        final tileBorder = dark ? Colors.white10 : const Color(0xFFE9EAF2);

        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.8,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          builder: (c, controller) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 42, height: 4,
                  decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(4)),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      const Icon(Icons.reviews_rounded),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Reviews • $title',
                          style: TextStyle(fontWeight: FontWeight.w900, color: textColor),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: reviews.length,
                    itemBuilder: (_, i) {
                      final r = reviews[i];
                      final rating = (r['rating'] is num) ? (r['rating'] as num).toDouble() : 0.0;
                      final author = (r['authorName'] ?? 'Anonymous').toString();
                      final txt = (r['text'] ?? r['review'] ?? '').toString();
                      final created = r['createdAt'] as Timestamp?;
                      final when = created == null ? '' : _fmtTS(created);
                      return Container(
                        padding: const EdgeInsets.all(12),
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: tileBg,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: tileBorder),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const Icon(Icons.star_rounded, color: Color(0xFFFFB21D), size: 18),
                                const SizedBox(width: 6),
                                Text(rating.toStringAsFixed(1), style: TextStyle(fontWeight: FontWeight.w900, color: textColor)),
                                const SizedBox(width: 8),
                                Expanded(child: Text(author, style: TextStyle(fontWeight: FontWeight.w700, color: textColor))),
                                Text(when, style: TextStyle(color: subColor, fontSize: 12)),
                              ],
                            ),
                            if (txt.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(txt, style: TextStyle(color: textColor)),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }


// ======================= LIVE SHARE STATE (fields) =======================
// (declared here to keep file cohesive; class fields can appear anywhere)
  //final Map<String, StreamSubscription<Position>> _gpsSubs = {};
//  final Set<String> _trackingReqIds = <String>{};

// ======================= SHARED HELPERS =======================
  Widget _emptyState({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color fg,
    required Color sub,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: sub.withOpacity(0.6)),
            const SizedBox(height: 12),
            Text(title, style: TextStyle(
                color: fg, fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 6),
            Text(subtitle, style: TextStyle(color: sub),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Widget _infoTile(String msg, Color subtitleColor) =>
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _accent.withOpacity(0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(msg, style: TextStyle(color: subtitleColor)),
      );

  String _composeSubtitle(String category, String hours, dynamic price) {
    final parts = <String>[];
    if (category.isNotEmpty) parts.add(category);
    if (hours.isNotEmpty) parts.add(hours);
    if (price != null && price
        .toString()
        .isNotEmpty) parts.add('PKR $price');
    return parts.join(' • ');
  }

  // ---------- DRAWER ----------
  Drawer _drawer(Color accent, Color fg, Color bg, Color subtitle) {
    final user = FirebaseAuth.instance.currentUser;

    Widget _bottomButtons() {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _switchToSeekerMode,
                icon: const Icon(Icons.switch_access_shortcut),
                label: const Text('Switch to Seeker Mode', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE84D5B),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _logout,
                icon: const Icon(Icons.logout),
                label: const Text('Logout', style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ),
          ],
        ),
      );
    }

    return Drawer(
      backgroundColor: bg,
      child: SafeArea(
        child: Column(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: accent.withOpacity(0.13)),
              child: StreamBuilder<DocumentSnapshot>(
                stream: user != null
                    ? FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots()
                    : const Stream.empty(),
                builder: (context, snapshot) {
                  final userDoc = snapshot.data?.data() as Map<String, dynamic>? ?? {};
                  final provider = userDoc['provider'] as Map<String, dynamic>? ?? {};
                  final base64img = provider['avatar'] ?? userDoc['profile_image'];

                  ImageProvider imgProv;
                  if (base64img is String && base64img.isNotEmpty) {
                    try {
                      imgProv = MemoryImage(base64Decode(base64img));
                    } catch (_) {
                      imgProv = const AssetImage('assets/images/dp.png');
                    }
                  } else {
                    imgProv = const AssetImage('assets/images/dp.png');
                  }

                  return Row(
                    children: [
                      CircleAvatar(
                        radius: 28,
                        backgroundColor: accent.withOpacity(0.09),
                        backgroundImage: imgProv,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              (provider['name'] ?? user?.displayName ?? '').toString(),
                              style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 18),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              (provider['city'] ?? user?.email ?? '').toString(),
                              style: TextStyle(color: subtitle, fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),

            // Main list
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  ListTile(
                    leading: Icon(Icons.manage_accounts_rounded, color: accent),
                    title: Text('Manage Profile', style: TextStyle(color: fg)),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const _ManageProfilePage()));
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.account_balance_wallet_outlined, color: accent),
                    title: Text('My Income', style: TextStyle(color: fg)),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const _IncomePage()));
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.account_balance_outlined, color: accent),
                    title: Text('Payouts', style: TextStyle(color: fg)),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const _PayoutsPage()));
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.history_rounded, color: accent),
                    title: Text('Services History', style: TextStyle(color: fg)),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const _ServicesHistoryPage()));
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.brightness_6, color: accent),
                    title: Text('Theme', style: TextStyle(color: fg)),
                    trailing: Switch(
                      value: darkTheme,
                      onChanged: (_) => _toggleTheme(),
                      activeColor: accent,
                    ),
                  ),
                ],
              ),
            ),

            // Bottom buttons
            _bottomButtons(),
          ],
        ),
      ),
    );
  }

}
// ======================= REQUEST/BOOKING CARD =======================


enum _RBMode { request, booking }

class _RequestBookingCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final bool dark;
  final _RBMode mode;
  final int graceHours; // NEW

  final Future<void> Function(QueryDocumentSnapshot doc)? onAccept;
  final Future<void> Function(QueryDocumentSnapshot doc)? onReject;

  // UPDATED: include requestId when opening in-app map
  final void Function(String requestId, Map<String, dynamic> data)? onOpenMap;

  final Future<void> Function(QueryDocumentSnapshot doc)? onMarkCompleted;
  final Future<void> Function(QueryDocumentSnapshot doc)? onEditSchedule;
  final Future<void> Function(QueryDocumentSnapshot doc)? onStartEnroute;
  final Future<void> Function(QueryDocumentSnapshot doc)? onCancel;
  final Future<void> Function(QueryDocumentSnapshot doc)? onDelete;

  const _RequestBookingCard({
    required this.doc,
    required this.dark,
    required this.mode,
    this.onAccept,
    this.onReject,
    this.onOpenMap,
    this.onMarkCompleted,
    this.onEditSchedule,
    this.onStartEnroute,
    this.onCancel,
    this.onDelete,
    this.graceHours = 0,
  });

  Widget _countdownChip(DateTime scheduledAt, int graceHours) {
    final dueBy = scheduledAt.add(Duration(hours: graceHours));
    return StreamBuilder<DateTime>(
      stream: Stream.periodic(const Duration(seconds: 1), (_) => DateTime.now()),
      builder: (_, snap) {
        final now = snap.data ?? DateTime.now();
        final diff = dueBy.difference(now);
        final overdue = diff.isNegative;
        final text = overdue
            ? 'Overdue by ${_fmtDuration(-diff)}'
            : 'Due in ${_fmtDuration(diff)}';
        final bg  = overdue ? const Color(0xFFFFEEF0) : const Color(0xFFEFF8FF);
        final col = overdue ? const Color(0xFFD33A4A) : const Color(0xFF0A66C2);
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: bg),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(overdue ? Icons.schedule_outlined : Icons.timer_outlined, size: 16, color: col),
              const SizedBox(width: 6),
              Text(text, style: TextStyle(color: col, fontWeight: FontWeight.w800, fontSize: 12.5)),
            ],
          ),
        );
      },
    );
  }

  String _fmtDuration(Duration d) {
    final s = d.inSeconds;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${sec}s';
    return '${sec}s';
  }

  // Local helpers (phone/maps)
  Future<void> _call(BuildContext context, String phone) async {
    if (phone.trim().isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.platformDefault);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot place a call on this device')),
        );
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to open dialer')),
      );
    }
  }

  Future<void> _openExternalMaps(Map<String, dynamic> m) async {
    final label = (m['label'] ?? '').toString();
    final address = (m['address'] ?? '').toString();
    final lat = (m['lat'] as num?)?.toDouble();
    final lng = (m['lng'] as num?)?.toDouble();

    try {
      if (lat != null && lng != null) {
        final query = label.isNotEmpty ? '$lat,$lng(${Uri.encodeComponent(label)})' : '$lat,$lng';
        final geo = Uri.parse('geo:$lat,$lng?q=$query');
        final web = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
        if (await canLaunchUrl(geo)) {
          await launchUrl(geo, mode: LaunchMode.externalApplication);
        } else {
          await launchUrl(web, mode: LaunchMode.externalApplication);
        }
      } else if (address.isNotEmpty) {
        final encoded = Uri.encodeComponent(address);
        final geo = Uri.parse('geo:0,0?q=$encoded');
        final web = Uri.parse('https://www.google.com/maps/search/?api=1&query=$encoded');
        if (await canLaunchUrl(geo)) {
          await launchUrl(geo, mode: LaunchMode.externalApplication);
        } else {
          await launchUrl(web, mode: LaunchMode.externalApplication);
        }
      }
    } catch (_) {
      // ignore
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = doc.data() as Map<String, dynamic>;

    final title = (m['gigTitle'] ?? m['title'] ?? 'Service Request').toString();
    final category = (m['gigCategory'] ?? m['category'] ?? 'General').toString();
    final status = (m['status'] ?? 'pending').toString();
    final price = m['gigPrice'] ?? m['budget'] ?? m['amount'];
    final visitType = (m['visitType'] ?? 'Standard').toString();

    final label = (m['label'] ?? '').toString();
    final address = (m['address'] ?? '').toString();

    final seekerPhone = (m['phone'] ?? '').toString();
    String seekerName = (m['seekerName'] ?? '').toString();
    String seekerHandle = (() {
      final raw = (m['seekerUsername'] ?? m['seekerHandle'] ?? '').toString().trim();
      if (raw.isEmpty) return '';
      return raw.startsWith('@') ? raw : '@$raw';
    })();

    // ensure seeker details (name/@username) appear when missing
    final seekerId = (m['seekerId'] ?? m['seekerUID'] ?? '').toString();

    final scheduledAt = m['scheduledAt'] as Timestamp?;
    final providerDone = (m['providerCompleted'] as bool?) ?? false;

    final fg = dark ? Colors.white : Colors.black;
    final sub = dark ? Colors.white70 : Colors.black54;
    final cardColor = dark ? const Color(0xFF1A1A1A) : Colors.white;

    Color chipBg;
    Color chipFg;
    final s = status.toLowerCase();
    if (s == 'completed') {
      chipBg = const Color(0xFFE9F9EF);
      chipFg = const Color(0xFF178A4A);
    } else if (s == 'accepted' || s == 'enroute') {
      chipBg = const Color(0xFFEFF3FF);
      chipFg = const Color(0xFF3D6BFF);
    } else if (s == 'declined' || s == 'cancelled') {
      chipBg = const Color(0xFFFFEEF0);
      chipFg = const Color(0xFFD33A4A);
    } else if (s == 'not_completed') {
      chipBg = const Color(0xFFF1F2F6);
      chipFg = const Color(0xFF6B7280); // gray-500 vibe
    } else {
      chipBg = const Color(0xFFFFF6E8);
      chipFg = const Color(0xFF9A6A00);
    }

    final isAccepted  = s == 'accepted';
    final isEnroute   = s == 'enroute';
    final isCompleted = s == 'completed';
    final isCancelled = s == 'cancelled';

    String _fmtTS(Timestamp? ts) {
      if (ts == null) return '—';
      final d = ts.toDate();
      final dd = '${d.year}-${_two(d.month)}-${_two(d.day)}';
      final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
      final ampm = d.hour >= 12 ? 'PM' : 'AM';
      final hhmm = '$hour12:${_two(d.minute)} $ampm';
      return '$dd  •  $hhmm';
    }

    Widget _seekerHeader(String name, String handle) {
      return Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isNotEmpty ? name : 'Seeker',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w700, height: 1.2),
                ),
                if (handle.isNotEmpty)
                  Text(
                    handle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: sub, fontSize: 12),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _tinyBtn(
            icon: Icons.call_rounded,
            label: 'Call',
            enabled: seekerPhone.isNotEmpty,
            onTap: () => _call(context, seekerPhone),
          ),
          const SizedBox(width: 8),
          _tinyBtn(
            icon: Icons.chat_bubble_rounded,
            label: 'Chat',
            onTap: () {
              // Get Seeker details
              final m = doc.data() as Map<String, dynamic>;
              final seekerId = (m['seekerId'] ?? '').toString();
              final seekerName = (m['seekerName'] ?? 'Seeker').toString();

              if (seekerId.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Seeker info missing")));
                return;
              }

              // Open Chat
              ChatListScreen.openChat(
                  context,
                  myUid: FirebaseAuth.instance.currentUser!.uid,
                  otherUid: seekerId,
                  otherName: seekerName
              );
            },
          ),
        ],
      );
    }

    final body = Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dark ? Colors.white12 : const Color(0xFFE9EAF2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // header
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F2F7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.home_repair_service_outlined, color: Colors.black45),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 15.5),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(999)),
                  child: Text(
                    s[0].toUpperCase() + s.substring(1),
                    style: TextStyle(color: chipFg, fontWeight: FontWeight.w800, fontSize: 12),
                  ),
                ),
                if (mode == _RBMode.booking && (isCompleted || isCancelled)) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Remove from your list',
                    icon: Icon(
                      Icons.delete_outline_rounded,
                      color: dark ? Colors.white70 : Colors.black54,
                    ),
                    onPressed: onDelete == null ? null : () => onDelete!(doc),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 10),

            _metaRow(icon: Icons.category_outlined, text: category, sub: sub),
            if (price != null) const SizedBox(height: 6),
            if (price != null)
              _metaRow(icon: Icons.attach_money_rounded, text: 'PKR $price', sub: sub),
            const SizedBox(height: 6),

            // Address row: text → external maps; chip → in-app live map (with requestId)
            _metaRow(
              icon: Icons.pin_drop_outlined,
              text: label.isEmpty ? address : label,
              sub: sub,
              onTap: () => _openExternalMaps(m),
              onMapSheet: () => onOpenMap?.call(doc.id, m),
            ),
            const SizedBox(height: 6),

            _metaRow(icon: Icons.handyman_outlined, text: 'Visit type: $visitType', sub: sub),

            if (scheduledAt != null) ...[
              const SizedBox(height: 6),
              _metaRow(icon: Icons.event_available_outlined, text: 'Scheduled: ${_fmtTS(scheduledAt)}', sub: sub),
            ],

            if ((isAccepted || isEnroute) && scheduledAt != null) ...[
              const SizedBox(height: 6),
              _countdownChip(scheduledAt.toDate(), graceHours),
            ],


            if (s == 'cancelled') ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFEEF0),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline_rounded, color: Color(0xFFD33A4A)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                            () {
                          final who = (m['cancelledBy'] ?? '').toString();
                          if (who == 'provider') return 'Cancelled by provider';
                          if (who == 'seeker') return 'Cancelled by seeker';
                          return 'Cancelled';
                        }(),
                        style: TextStyle(color: sub),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const Divider(height: 22),

            // Seeker details (auto-lookup if missing)
            if (seekerName.isNotEmpty || seekerHandle.isNotEmpty)
              _seekerHeader(seekerName, seekerHandle)
            else if (seekerId.isNotEmpty)
              FutureBuilder<DocumentSnapshot>(
                future: FirebaseFirestore.instance.collection('users').doc(seekerId).get(),
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return _seekerHeader('Seeker', seekerHandle);
                  }
                  final um = (snap.data!.data() as Map<String, dynamic>?) ?? {};
                  final profile = (um['seeker'] as Map<String, dynamic>?) ??
                      (um['profile'] as Map<String, dynamic>?) ?? {};
                  final display = (um['displayName'] ?? um['name'] ?? '').toString();
                  final resolvedName = (profile['name'] ?? display).toString();
                  final username = (profile['username'] ?? um['username'] ?? '').toString().trim();

                  seekerName = resolvedName.isNotEmpty ? resolvedName : 'Seeker';
                  if (username.isNotEmpty) {
                    final handle = username.startsWith('@') ? username : '@$username';
                    seekerHandle = handle; // always the real handle from user doc
                  } else {
                    // keep whatever we had (may be empty if none on request)
                  }

                  return _seekerHeader(seekerName, seekerHandle);
                },
              )
            else
              _seekerHeader('Seeker', seekerHandle),

            const SizedBox(height: 10),

            // footer actions
            if (mode == _RBMode.request) _requestActions(context)
            else _bookingActions(context, s, providerDone),
          ],
        ),
      ),
    );

    return body;
  }

  Widget _requestActions(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.close),
            label: const Text('Reject', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: onReject == null ? null : () => onReject!(doc),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            icon: const Icon(Icons.check_rounded),
            label: const Text('Accept', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: onAccept == null ? null : () => onAccept!(doc),
          ),
        ),
      ],
    );
  }

  Widget _bookingActions(BuildContext context, String status, bool providerDone) {
    final isAccepted  = status == 'accepted';
    final isEnroute   = status == 'enroute';
    final isCompleted = status == 'completed';
    final isCancelled = status == 'cancelled';
    final isNotCompleted = status == 'not_completed';

    return Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        if (isAccepted)
          OutlinedButton.icon(
            icon: const Icon(Icons.directions_walk_rounded),
            label: const Text('Enroute', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: onStartEnroute == null ? null : () => onStartEnroute!(doc),
          ),
        if (isAccepted)
          OutlinedButton.icon(
            icon: const Icon(Icons.edit_calendar_rounded),
            label: const Text('Edit schedule', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: onEditSchedule == null ? null : () => onEditSchedule!(doc),
          ),
        if (isAccepted || isEnroute)
          OutlinedButton.icon(
            icon: const Icon(Icons.cancel_rounded),
            label: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: onCancel == null ? null : () => onCancel!(doc),
          ),
        if (isEnroute)
          FilledButton.icon(
            icon: const Icon(Icons.check_circle),
            label: const Text('Mark completed', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: (onMarkCompleted == null || providerDone || isCancelled)
                ? null
                : () => onMarkCompleted!(doc),
          ),
        if (isNotCompleted) ...[
          FilledButton.icon(
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Reschedule', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: onEditSchedule == null ? null : () => onEditSchedule!(doc),
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.cancel_rounded),
            label: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w800)),
            onPressed: onCancel == null ? null : () => onCancel!(doc),
          ),
        ]
      ],
    );
  }

  Widget _metaRow({
    required IconData icon,
    required String text,
    required Color sub,
    VoidCallback? onTap,
    VoidCallback? onMapSheet,
  }) {
    final row = Row(
      children: [
        Icon(icon, size: 16, color: sub.withOpacity(0.9)),
        const SizedBox(width: 6),
        Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: onTap != null ? sub.withOpacity(0.95) : sub,
                  fontSize: 13.5,
                  height: 1.2,
                  decoration: onTap != null ? TextDecoration.underline : TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
        if (onMapSheet != null) ...[
          const SizedBox(width: 6),
          InkWell(
            onTap: onMapSheet,
            borderRadius: BorderRadius.circular(999),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF4F6FF),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0xFFE1E5FF)),
              ),
              child: Text('Map', style: TextStyle(color: Colors.blue.shade600, fontWeight: FontWeight.w800, fontSize: 12.5)),
            ),
          ),
        ],
      ],
    );
    return row;
  }

  Widget _tinyBtn({required IconData icon, required String label, bool enabled = true, VoidCallback? onTap}) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFF4F6FF) : const Color(0xFFF2F2F2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: enabled ? const Color(0xFFE1E5FF) : const Color(0xFFEAEAEA)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: enabled ? const Color(0xFF3D6BFF) : Colors.black38),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                color: enabled ? const Color(0xFF3D6BFF) : Colors.black45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _two(int v) => v < 10 ? '0$v' : '$v';
}



class _LiveFilterChip extends StatelessWidget {
  static const Color _accent = Color(0xFF7966FA);
  final String label;
  final bool selected;
  final bool dark;
  final VoidCallback onTap;

  const _LiveFilterChip({
    Key? key,
    required this.label,
    required this.selected,
    required this.dark,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final bg     = selected ? _accent : (dark ? const Color(0xFF22232A) : const Color(0xFFF5F6FA));
    final border = selected ? _accent : (dark ? Colors.white10 : const Color(0xFFE0E2EC));
    final fg     = selected ? Colors.white : (dark ? Colors.white : const Color(0xFF1B1C20));

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: border),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: fg,
            fontWeight: FontWeight.w700,
            fontSize: 12.5,
          ),
        ),
      ),
    );
  }
}

class _LiveRequestCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final bool dark;
  final Color fg;
  final Color sub;
  final Color cardColor;
  final void Function(QueryDocumentSnapshot doc)? onAccept;
  final void Function(String phone)? onCall;
  static const Color _accent = Color(0xFF7966FA);
  const _LiveRequestCard({
    super.key,
    required this.doc,
    required this.dark,
    required this.fg,
    required this.sub,
    required this.cardColor,
    this.onAccept,
    this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final String mode = (data['mode'] ?? 'standard') as String;
    final bool isPickDrop = mode == 'pick_drop';

    final String seekerName =
    (data['seekerName'] ?? 'User') as String;
    final String seekerPhone =
    (data['seekerPhone'] ?? '') as String;

    final String whereText =
    (data['whereText'] ?? data['description'] ?? '') as String;
    final String pickup =
    (data['pickupAddress'] ?? '') as String;
    final String drop =
    (data['dropAddress'] ?? '') as String;

    final num fareNum =
    (data['fare'] ?? data['baseFare'] ?? 0) as num;
    final String fareLabel =
    fareNum > 0 ? 'PKR ${fareNum.round()}' : '';

    DateTime? createdAt;
    final createdAtRaw = data['createdAt'];
    if (createdAtRaw is Timestamp) {
      createdAt = createdAtRaw.toDate();
    }
    final String timeAgo = _formatLiveTimeAgo(createdAt);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: dark ? Colors.white12 : const Color(0xFFE9EAF2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // top row: seeker + time
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor:
                dark ? Colors.white10 : const Color(0xFFF1F2FB),
                child: Text(
                  seekerName.isNotEmpty
                      ? seekerName[0].toUpperCase()
                      : 'U',
                  style: TextStyle(
                    color: dark ? Colors.white : _accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  seekerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              if (timeAgo.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  timeAgo,
                  style: TextStyle(
                    color: sub,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),

          const SizedBox(height: 8),

          // main description
          if (isPickDrop) ...[
            Text(
              '$pickup → $drop',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ] else ...[
            Text(
              whereText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: fg,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (pickup.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                pickup,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: sub,
                  fontSize: 12,
                ),
              ),
            ],
          ],

          const SizedBox(height: 8),

          Row(
            children: [
              if (fareLabel.isNotEmpty)
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: dark
                        ? Colors.white10
                        : _accent.withOpacity(0.06),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    fareLabel,
                    style: TextStyle(
                      color: dark ? Colors.white : _accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const Spacer(),
              if (seekerPhone.isNotEmpty)
                IconButton(
                  onPressed: () => onCall?.call(seekerPhone),
                  icon: Icon(
                    Icons.call_rounded,
                    size: 20,
                    color: dark ? Colors.greenAccent : _accent,
                  ),
                ),
              const SizedBox(width: 4),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                onPressed: () => onAccept?.call(doc),
                child: const Text(
                  'Accept',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}


String _formatLiveTimeAgo(DateTime? createdAt) {
  if (createdAt == null) return '';
  final diff = DateTime.now().difference(createdAt);

  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';

  final d = createdAt.day.toString().padLeft(2, '0');
  final m = createdAt.month.toString().padLeft(2, '0');
  return '$d/$m';
}


/* ---------------- Separate Income Page ---------------- */
class _IncomePage extends StatelessWidget {
  const _IncomePage({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF7966FA);
    final user = FirebaseAuth.instance.currentUser;

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Income'),
        backgroundColor: accent,
        foregroundColor: Colors.white,
      ),
      body: user == null
          ? const Center(child: Text('Not logged in'))
          : StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};
          final provider = data['provider'] as Map<String, dynamic>? ?? {};
          final List payments = provider['payment_history'] ?? data['payment_history'] ?? [];
          final double total = payments.fold<double>(
            0.0,
                (sum, e) => sum + (double.tryParse('${e['amount']}') ?? 0.0),
          );

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.account_balance_wallet_outlined, color: accent),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text('Total Earnings', style: TextStyle(color: Colors.black54)),
                    ),
                    Text('PKR ${total.toStringAsFixed(0)}',
                        style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ...payments.map<Widget>((pmt) => Card(
                elevation: 0,
                margin: const EdgeInsets.symmetric(vertical: 6),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                child: ListTile(
                  leading: Icon(
                    Icons.payments_outlined,
                    color: (pmt['status'] == 'paid') ? Colors.green : Colors.orange,
                  ),
                  title: Text('${pmt['service']} Payment',
                      style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
                  subtitle: Text('${pmt['date']}\nPKR ${pmt['amount'] ?? ''}',
                      style: const TextStyle(color: Colors.black54, height: 1.25)),
                  isThreeLine: true,
                ),
              )),
            ],
          );
        },
      ),
    );
  }
}

/* ---------------- Separate Payouts Page ---------------- */
class _PayoutsPage extends StatelessWidget {
  const _PayoutsPage({super.key});

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF7966FA);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payouts'),
        backgroundColor: accent,
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(color: accent.withOpacity(0.08), borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                const Icon(Icons.account_balance_outlined, color: accent),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text('Connect bank to receive payouts', style: TextStyle(color: Colors.black54)),
                ),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: accent, width: 1.2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: () {},
                  child: const Text('Set up', style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---------------- Services History Page (compact, with Clear All) ---------------- */
class _ServicesHistoryPage extends StatefulWidget {
  const _ServicesHistoryPage({super.key});

  @override
  State<_ServicesHistoryPage> createState() => _ServicesHistoryPageState();
}

class _ServicesHistoryPageState extends State<_ServicesHistoryPage> {
  static const Color _accent = Color(0xFF7966FA);
  bool _clearing = false;

  String _two(int v) => v < 10 ? '0$v' : '$v';

  String _fmtTS(Timestamp? ts) {
    if (ts == null) return '—';
    final d = ts.toDate();
    final dd = '${d.year}-${_two(d.month)}-${_two(d.day)}';
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    final hhmm = '$h12:${_two(d.minute)} $ampm';
    return '$dd • $hhmm';
  }

  void _toast(String msg, {bool error = false}) {
    final bg = Colors.white;
    final iconColor = error ? const Color(0xFFE84D5B) : const Color(0xFF1FBF6C);
    final textColor = Colors.black.withOpacity(0.9);

    final sb = SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: bg,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      duration: const Duration(seconds: 2),
      content: Row(
        children: [
          Icon(
            error ? Icons.error_outline_rounded : Icons.check_circle_rounded,
            color: iconColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(sb);
  }

  Future<void> _clearAll(String uid) async {
    if (_clearing) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
          'This will permanently remove all archived services from your history. '
              'Seekers will NOT be affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => _clearing = true);

    try {
      final fs = FirebaseFirestore.instance;
      // Single-page clear (up to 450 docs to respect batch limit 500)
      const int limit = 450;

      final snap = await fs
          .collection('services_history')
          .where('providerId', isEqualTo: uid)
          .limit(limit)
          .get();

      if (snap.docs.isEmpty) {
        _toast('No history to clear.', error: false);
        return;
      }

      final batch = fs.batch();
      for (final d in snap.docs) {
        batch.delete(d.reference);
      }
      await batch.commit();

      _toast('Cleared ${snap.docs.length} item(s) from history.');
    } on FirebaseException catch (e) {
      _toast('Failed to clear: ${e.message ?? e.code}', error: true);
    } catch (e) {
      _toast('Failed to clear: $e', error: true);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;

    final bg = dark ? const Color(0xFF111111) : Colors.white;
    final card = dark ? const Color(0xFF1A1A1A) : const Color(0xFFF7F8FC);
    final border = dark ? Colors.white12 : const Color(0xFFE1E4F0);
    final fg = dark ? Colors.white : Colors.black87;
    final sub = dark ? Colors.white70 : Colors.black54;

    Color statusBg(String s) {
      s = s.toLowerCase();
      if (s == 'completed') return const Color(0xFFE9F9EF);
      if (s == 'cancelled' || s == 'declined') return const Color(0xFFFFEEF0);
      if (s == 'not_completed') return const Color(0xFFF1F2F6);
      return const Color(0xFFFFF6E8);
    }

    Color statusFg(String s) {
      s = s.toLowerCase();
      if (s == 'completed') return const Color(0xFF178A4A);
      if (s == 'cancelled' || s == 'declined') return const Color(0xFFD33A4A);
      if (s == 'not_completed') return const Color(0xFF6B7280);
      return const Color(0xFF9A6A00);
    }

    String niceStatus(String s) {
      if (s.isEmpty) return 'Unknown';
      return s[0].toUpperCase() + s.substring(1);
    }

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Services History'),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        actions: [
          if (uid != null)
            TextButton.icon(
              onPressed: _clearing ? null : () => _clearAll(uid),
              icon: _clearing
                  ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
                  : const Icon(Icons.delete_sweep_rounded, color: Colors.white, size: 18),
              label: const Text(
                'Clear all',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
      body: uid == null
          ? Center(
        child: Text(
          'Not logged in',
          style: TextStyle(color: fg),
        ),
      )
          : StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('services_history')
            .where('providerId', isEqualTo: uid)
            .orderBy('archivedAt', descending: true)
            .snapshots(),
        builder: (_, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snap.data?.docs ?? const [];
          if (docs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.history_rounded,
                        size: 52, color: sub.withOpacity(0.7)),
                    const SizedBox(height: 10),
                    Text(
                      'No archived services yet.',
                      style: TextStyle(
                        color: fg,
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Completed jobs you hide from bookings will appear here.',
                      style: TextStyle(color: sub),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.separated(
            key: const PageStorageKey('services_history_list'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            // Inside _ServicesHistoryPage -> itemBuilder

            itemBuilder: (_, i) {
              final m = docs[i].data() as Map<String, dynamic>;
              final data = (m['data'] as Map?)?.cast<String, dynamic>() ?? {};

              // Check for Live Flag
              final bool isLive = (m['isLive'] == true) || (data['isLive'] == true);

              final rawTitle = (data['gigTitle'] ?? data['title'] ?? '').toString();
              final title = rawTitle.isNotEmpty ? rawTitle : 'Service';

              final status = (data['status'] ?? 'completed').toString();
              final archivedAt = m['archivedAt'] as Timestamp?;
              final location = (data['label'] ?? data['pickupAddress'] ?? data['address'] ?? '').toString();

              final chipBg = statusBg(status);
              final chipFg = statusFg(status);

              return Container(
                decoration: BoxDecoration(
                  color: card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: border),
                ),
                child: ListTile(
                  key: ValueKey(docs[i].id),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  leading: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: isLive ? const Color(0xFFE7FFF2) : _accent.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      isLive ? Icons.wifi_tethering : Icons.history_rounded,
                      color: isLive ? const Color(0xFF0F9155) : _accent,
                    ),
                  ),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: fg, fontWeight: FontWeight.w700),
                        ),
                      ),
                      // BADGE IN HISTORY
                      if (isLive) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE7FFF2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFCFF5E1)),
                          ),
                          child: const Text('LIVE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF0F9155))),
                        )
                      ],
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 2),
                      if (location.isNotEmpty)
                        Text(
                          location,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: sub, fontSize: 12.5),
                        ),
                      const SizedBox(height: 2),
                      Text(_fmtTS(archivedAt), style: TextStyle(color: sub, fontSize: 12.5)),
                    ],
                  ),
                  trailing: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: chipBg, borderRadius: BorderRadius.circular(999)),
                    child: Text(
                      niceStatus(status),
                      style: TextStyle(color: chipFg, fontSize: 11.5, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}



/* ---------------- Manage Profile Page ---------------- */
class _ManageProfilePage extends StatefulWidget {
  const _ManageProfilePage({super.key});

  @override
  State<_ManageProfilePage> createState() => _ManageProfilePageState();
}

class _ManageProfilePageState extends State<_ManageProfilePage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _phone = TextEditingController();
  String? _avatarB64;
  final ImagePicker _picker = ImagePicker();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    final m = doc.data() ?? {};
    final p = (m['provider'] as Map<String, dynamic>?) ?? {};
    _name.text = (p['name'] ?? '').toString();
    _city.text = (p['city'] ?? '').toString();
    _phone.text = (p['phone'] ?? m['phone'] ?? '').toString();
    final a = (p['avatar'] ?? '').toString();
    if (a.isNotEmpty) _avatarB64 = a;
    setState(() {});
  }

  Future<void> _pickAvatar() async {
    final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 75);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _avatarB64 = base64Encode(bytes));
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    setState(() => _saving = true);
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).set({
        'provider': {
          'name': _name.text.trim(),
          'city': _city.text.trim(),
          'phone': _phone.text.trim(),
          if (_avatarB64 != null) 'avatar': _avatarB64,
          'updated_at': FieldValue.serverTimestamp(),
        }
      }, SetOptions(merge: true));
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).brightness == Brightness.dark ? const Color(0xFF111111) : Colors.white;
    final tile = Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1A1A1A) : Colors.white;
    final fill = Theme.of(context).brightness == Brightness.dark ? const Color(0xFF1A1A1A) : const Color(0xFFF6F7FB);
    final text = Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.black87;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Manage Profile'),
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
      ),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: tile, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    InkWell(
                      onTap: _pickAvatar,
                      borderRadius: BorderRadius.circular(28),
                      child: CircleAvatar(
                        radius: 28,
                        backgroundColor: fill,
                        backgroundImage: (_avatarB64 != null) ? MemoryImage(base64Decode(_avatarB64!)) : null,
                        child: (_avatarB64 == null) ? const Icon(Icons.camera_alt_outlined, color: Colors.black45) : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Update your profile details and avatar.', style: TextStyle(color: text.withOpacity(0.7))),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _field(_name, 'Full Name', fill),
              const SizedBox(height: 12),
              _field(_city, 'City', fill, validate: false),
              const SizedBox(height: 12),
              _field(_phone, 'Phone', fill, validate: false, keyboard: TextInputType.phone),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, Color fill, {bool validate = true, TextInputType keyboard = TextInputType.text}) {
    return TextFormField(
      controller: c,
      keyboardType: keyboard,
      validator: validate ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null : null,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}

/* ======================= ADD SERVICE (GIG) ======================= */
class AddServiceScreen extends StatefulWidget {
  final String? gigId; // for editing existing gig
  final Map<String, dynamic>? initialData; // prefill for edit
  final bool isDark; // ← NEW

  const AddServiceScreen({super.key, this.gigId, this.initialData, this.isDark = false,});

  @override
  State<AddServiceScreen> createState() => _AddServiceScreenState();
}

class _AddServiceScreenState extends State<AddServiceScreen> {
  static const Color accent = Color(0xFF7966FA);

  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _category = ValueNotifier<String?>('Choose the category');
  final _desc = TextEditingController();
  final _serviceChip = TextEditingController();
  final List<String> _services = [];
  final _experience = TextEditingController();
  final _location = TextEditingController();
  final _hours = TextEditingController();
  final _price = TextEditingController();
  final _phone = TextEditingController();

  final ImagePicker _picker = ImagePicker();
  final List<String> _photosB64 = [];
  String? _profileB64;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _prefillFromAccount();
    _prefillFromEditing();
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _serviceChip.dispose();
    _experience.dispose();
    _location.dispose();
    _hours.dispose();
    _price.dispose();
    _phone.dispose();
    _category.dispose();
    super.dispose();
  }

  Future<void> _prefillFromAccount() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final doc = await FirebaseFirestore.instance
        .collection('users')
        .doc(uid)
        .get();
    final m = doc.data() ?? {};
    final provider = (m['provider'] as Map<String, dynamic>?) ?? {};
    final accountPhone = (provider['phone'] ?? m['phone'] ??
        provider['contact'] ?? '').toString();
    if (_phone.text.isEmpty && accountPhone.isNotEmpty) {
      setState(() => _phone.text = accountPhone);
    }
  }

  void _prefillFromEditing() {
    final d = widget.initialData;
    if (d == null) return;
    _title.text = (d['title'] ?? '').toString();
    _category.value = (d['category'] ?? 'Choose the category').toString();
    _desc.text = (d['description'] ?? '').toString();
    final List serv = (d['services'] as List?) ?? [];
    _services
      ..clear()
      ..addAll(serv.cast<String>());
    _experience.text = (d['experience'] ?? '').toString();
    _location.text = (d['location'] ?? '').toString();
    _hours.text = (d['workingHours'] ?? '').toString();
    final pr = d['price'];
    if (pr != null) _price.text = pr.toString();
    final ph = (d['phone'] ?? '').toString();
    if (ph.isNotEmpty) _phone.text = ph;
    final profile = (d['profileB64'] ?? '').toString();
    if (profile.isNotEmpty) _profileB64 = profile;
    final photos = (d['photosB64'] as List?)?.cast<String>() ?? [];
    _photosB64
      ..clear()
      ..addAll(photos);
  }

  Future<void> _pickProfile() async {
    final x = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 75);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _profileB64 = base64Encode(bytes));
  }

  Future<void> _pickPhoto() async {
    if (_photosB64.length >= 8) return;
    final x = await _picker.pickImage(
        source: ImageSource.gallery, imageQuality: 75);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() => _photosB64.add(base64Encode(bytes)));
  }

  // Search helpers
  String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').replaceAll(
          RegExp(r'\s+'), ' ').trim();

  Set<String> _tokenize(String s, {int minLen = 2}) {
    final norm = _normalize(s);
    final parts = norm.split(' ');
    final out = <String>{};
    for (final p in parts) {
      if (p.length >= minLen) out.add(p);
    }
    return out;
  }

  Set<String> _tokenizeStrings(List<String> items, {int minLen = 2}) {
    final all = <String>{};
    for (final s in items) {
      if (s.isEmpty) continue;
      all.addAll(_tokenize(s, minLen: minLen));
    }
    return all;
  }

  Set<String> _makeSearchPrefixes(Iterable<String> tokens, {int maxLen = 10}) {
    final out = <String>{};
    for (final t in tokens) {
      final stop = t.length < maxLen ? t.length : maxLen;
      for (int i = 1; i <= stop; i++) {
        out.add(t.substring(0, i));
      }
    }
    return out;
  }

  Future<void> _save({required bool publish}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please log in')));
      return;
    }

    if (publish && !_form.currentState!.validate()) return;

    if (_photosB64
        .join()
        .length > 700000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(
            'Images too large. Please add fewer/smaller photos.')),
      );
      return;
    }

    setState(() => _saving = true);
    try {
      final selectedCategory = _category.value == 'Choose the category'
          ? 'Other'
          : (_category.value ?? 'Other');

      final searchBase = _tokenizeStrings([
        _title.text.isNotEmpty ? _title.text : 'draft',
        selectedCategory,
        _desc.text,
        _location.text,
        ..._services,
      ], minLen: 2);
      final prefixes = _makeSearchPrefixes(searchBase, maxLen: 10);

      final gigs = FirebaseFirestore.instance.collection('gigs');
      final isEditing = widget.gigId != null;

      final data = {
        'providerId': uid,
        'title': (_title.text
            .trim()
            .isNotEmpty) ? _title.text.trim() : 'Draft',
        'category': selectedCategory,
        'description': _desc.text.trim(),
        'services': _services,
        'experience': _experience.text.trim(),
        'location': _location.text.trim(),
        'workingHours': _hours.text.trim(),
        'price': num.tryParse(_price.text.trim()) ?? 0,
        'phone': _phone.text.trim(),
        'profileB64': _profileB64,
        'photosB64': _photosB64,
        'status': publish ? 'active' : 'draft',
        'ratingAvg': (widget.initialData?['ratingAvg'] ?? 0.0),
        'ratingCount': (widget.initialData?['ratingCount'] ?? 0),
        'searchTokens': searchBase.toList(),
        'searchPrefixes': prefixes.toList(),
      };

      if (isEditing) {
        await gigs.doc(widget.gigId!).set({
          ...data,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } else {
        final doc = gigs.doc();
        await doc.set({
          'gigId': doc.id,
          ...data,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool dark = widget.isDark || Theme.of(context).brightness == Brightness.dark;
    final bg       = dark ? const Color(0xFF111111) : Colors.white;
    final tile     = dark ? const Color(0xFF1A1A1A) : Colors.white;
    final fieldFill= dark ? const Color(0xFF1A1A1A) : const Color(0xFFF6F7FB);
    final text     = dark ? Colors.white : Colors.black87;
    final hint     = dark ? Colors.white70 : Colors.black54;
    final border   = dark ? Colors.white12 : const Color(0xFFE9EAF2); // <— NEW (use where helpful)

    final isEditing = widget.gigId != null;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: Text(isEditing ? 'Edit Service Gig' : 'Add Service Gig'),
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
      ),
      body: Theme(
        data: Theme.of(context).copyWith(
          inputDecorationTheme: InputDecorationTheme(
            // only text-related; borders remain NONE/unchanged
            hintStyle: TextStyle(color: hint),
            labelStyle: TextStyle(color: hint),
            floatingLabelStyle: TextStyle(color: hint),
            helperStyle: TextStyle(color: hint.withOpacity(0.85)),
            prefixStyle: TextStyle(color: text),
            suffixStyle: TextStyle(color: text),
          ),
        ),
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _sectionTitle('Profile Picture', text),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                    color: tile, borderRadius: BorderRadius.circular(16)),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Add a profile picture of yourself so customers will know exactly who they'll be working with.",
                        style: TextStyle(color: hint, height: 1.25),
                      ),
                    ),
                    const SizedBox(width: 12),
                    InkWell(
                      onTap: _pickProfile,
                      borderRadius: BorderRadius.circular(28),
                      child: CircleAvatar(
                        radius: 28,
                        backgroundColor: fieldFill,
                        backgroundImage: (_profileB64 != null)
                            ? MemoryImage(base64Decode(_profileB64!))
                            : null,
                        child: (_profileB64 == null)
                            ? Icon(Icons.camera_alt_outlined, color: hint)
                            : null,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              _sectionTitle('Job Title', text),
              _field(_title, 'Add Title of your work', fieldFill),

              const SizedBox(height: 16),
              _sectionTitle('Category', text),
              ValueListenableBuilder<String?>(
                valueListenable: _category,
                builder: (_, value, __) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(color: fieldFill,
                        borderRadius: BorderRadius.circular(12)),
                    child: DropdownButtonFormField<String>(
                      value: value,
                      dropdownColor: fieldFill,
                      style: TextStyle(color: text),
                      decoration: const InputDecoration(
                          border: InputBorder.none),
                      items: const [
                        DropdownMenuItem(
                            value: 'Choose the category', child: Text(
                            'Choose the category')),
                        DropdownMenuItem(value: 'Ac Repair', child: Text(
                            'Ac Repair')),
                        DropdownMenuItem(value: 'Appliance', child: Text(
                            'Appliance')),
                        DropdownMenuItem(value: 'Painting', child: Text(
                            'Painting')),
                        DropdownMenuItem(value: 'Cleaning', child: Text(
                            'Cleaning')),
                        DropdownMenuItem(value: 'Plumbing', child: Text(
                            'Plumbing')),
                        DropdownMenuItem(value: 'Electrician', child: Text(
                            'Electrician')),
                        DropdownMenuItem(value: 'Driver', child: Text(
                            'Driver')),
                        DropdownMenuItem(value: 'Consultation', child: Text(
                            'Consultation')),
                        DropdownMenuItem(value: 'Free Lancing', child: Text(
                            'Free Lancing')),
                        DropdownMenuItem(value: 'Beauty', child: Text(
                            'Beauty')),
                        DropdownMenuItem(value: 'Ride', child: Text('Ride')),
                        DropdownMenuItem(value: 'Other', child: Text('Other')),
                      ],
                      onChanged: (v) => _category.value = v,
                    ),
                  );
                },
              ),

              const SizedBox(height: 16),
              _sectionTitle('Description', text),
              _multi(_desc,
                  'Share a bit about your work experience and your area of expertise.',
                  fieldFill),

              const SizedBox(height: 16),
              _sectionTitle('Add Services you Offer', text),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: tile, borderRadius: BorderRadius.circular(16)),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(child: _field(
                            _serviceChip, 'Add service', fieldFill,
                            validate: false)),
                        const SizedBox(width: 8),
                        FilledButton(
                          style: FilledButton.styleFrom(
                              backgroundColor: accent),
                          onPressed: () {
                            final s = _serviceChip.text.trim();
                            if (s.isEmpty) return;
                            setState(() {
                              _services.add(s);
                              _serviceChip.clear();
                            });
                          },
                          child: const Text('Add'),
                        ),
                      ],
                    ),
                    if (_services.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Builder(builder: (_) {
                          // Use the 'dark' boolean already defined earlier in build()
                          final chipBg     = dark ? const Color(0xFF262626) : accent.withOpacity(0.12);
                          final chipBorder = dark ? Colors.white12 : const Color(0xFFE1E5FF);
                          final labelCol   = dark ? Colors.white : Colors.black87;
                          final delCol     = dark ? Colors.white70 : Colors.black54;

                          return Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: _services.map((s) => Chip(
                              label: Text(
                                s,
                                style: TextStyle(
                                  color: labelCol,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12.5,
                                ),
                              ),
                              deleteIcon: Icon(Icons.close, size: 16, color: delCol),
                              onDeleted: () => setState(() => _services.remove(s)),
                              backgroundColor: chipBg,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                                side: BorderSide(color: chipBorder, width: 1),
                              ),
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            )).toList(),
                          );
                        }),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 16),
              _sectionTitle('Experience', text),
              _field(_experience, 'Enter your experience', fieldFill,
                  validate: false),

              const SizedBox(height: 16),
              _sectionTitle('Add Location', text),
              _field(_location, 'Enter location', fieldFill, validate: false),

              const SizedBox(height: 16),
              _sectionTitle('Working Hours', text),
              _field(
                  _hours, 'Enter your working hours and availability for work',
                  fieldFill, validate: false),

              const SizedBox(height: 16),
              _sectionTitle('Price', text),
              _field(_price, 'Enter Price', fieldFill,
                  keyboard: TextInputType.number),

              const SizedBox(height: 16),
              _sectionTitle('Phone Number', text),
              _field(_phone, 'Add phone number (e.g. 03xx-xxxxxxx)', fieldFill,
                  validate: false, keyboard: TextInputType.phone),

              const SizedBox(height: 16),
              _sectionTitle('Pictures', text),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: tile, borderRadius: BorderRadius.circular(16)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_photosB64.isEmpty)
                      Row(
                        children: [
                          InkWell(
                            onTap: _pickPhoto,
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: fieldFill,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(Icons.add_a_photo_outlined, color: hint),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text('Add Photo', style: TextStyle(color: hint)),
                        ],
                      )
                    else
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ..._photosB64
                              .asMap()
                              .entries
                              .map((e) =>
                              Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: Image.memory(
                                      base64Decode(e.value),
                                      width: 86,
                                      height: 86,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  Positioned(
                                    right: 4,
                                    top: 4,
                                    child: InkWell(
                                      onTap: () =>
                                          setState(() =>
                                              _photosB64.removeAt(e.key)),
                                      child: Container(
                                        decoration: BoxDecoration(
                                            color: Colors.black54,
                                            borderRadius: BorderRadius.circular(
                                                20)),
                                        padding: const EdgeInsets.all(2),
                                        child: const Icon(Icons.close, size: 16,
                                            color: Colors.white),
                                      ),
                                    ),
                                  )
                                ],
                              )),
                          InkWell(
                            onTap: _pickPhoto,
                            child: Container(
                              width: 86,
                              height: 86,
                              decoration: BoxDecoration(color: fieldFill,
                                  borderRadius: BorderRadius.circular(10)),
                              child: Icon(Icons.add_a_photo_outlined, color: hint),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                        side: const BorderSide(color: accent, width: 1.4),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _saving ? null : () => _save(publish: false),
                      child: const Text('Save Draft',
                          style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: accent,
                        minimumSize: const Size(double.infinity, 52),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: _saving ? null : () => _save(publish: true),
                      child: _saving
                          ? const SizedBox(height: 22,
                          width: 22,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                          : Text(isEditing ? 'Update & Publish' : 'Publish',
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, Color color) =>
      Padding(padding: const EdgeInsets.only(bottom: 8),
          child: Text(text,
              style: TextStyle(color: color, fontWeight: FontWeight.w700)));

  Widget _field(
      TextEditingController c,
      String hintText,
      Color fill, {
        bool validate = true,
        TextInputType keyboard = TextInputType.text,
      }) {
    final dark = widget.isDark;
    final textColor = dark ? Colors.white : Colors.black87;
    final hintColor = dark ? Colors.white70 : Colors.black54;

    return TextFormField(
      controller: c,
      keyboardType: keyboard,
      style: TextStyle(color: textColor),      // ← typed text
      cursorColor: accent,
      validator: validate
          ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
          : null,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: hintColor), // ← placeholder
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,          // ← unchanged
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  Widget _multi(TextEditingController c, String hintText, Color fill) {
    final dark = widget.isDark;
    final textColor = dark ? Colors.white : Colors.black87;
    final hintColor = dark ? Colors.white70 : Colors.black54;

    return TextFormField(
      controller: c,
      minLines: 4,
      maxLines: 8,
      style: TextStyle(color: textColor),        // ← typed text
      cursorColor: accent,
      validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(color: hintColor),   // ← placeholder
        filled: true,
        fillColor: fill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,            // ← unchanged
        ),
        contentPadding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      ),
    );
  }
}
// ---------------------------------------------------------------------------
// NEW: Full Screen Map for Ongoing Live Request (Updated with Custom Toasts)
// ---------------------------------------------------------------------------
class ProviderLiveMapScreen extends StatefulWidget {
  final String requestId;
  final Map<String, dynamic> requestData;

  const ProviderLiveMapScreen({
    super.key,
    required this.requestId,
    required this.requestData
  });

  @override
  State<ProviderLiveMapScreen> createState() => _ProviderLiveMapScreenState();
}

class _ProviderLiveMapScreenState extends State<ProviderLiveMapScreen> {
  GoogleMapController? _mapController;
  StreamSubscription<Position>? _gpsSub;

  // Route
  List<LatLng> _routePoints = [];
  final Set<Marker> _markers = {};

  // Status
  bool _isCompleting = false;
  LatLng? _currentPos;

  static const Color _accent = Color(0xFF7966FA);
  static const Color _ok = Color(0xFF1FBF6C);
  static const Color _danger = Color(0xFFE84D5B);

  final String _googleApiKey = 'AIzaSyBzvWeiJ8Jc9nRPBr_8aqLNPkiaSI0u2O0';

  @override
  void initState() {
    super.initState();
    _startLiveTracking();
    _fetchRoute();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  // ───────────────── CUSTOM TOASTS (Provider Style) ─────────────────
  void _showToast(String msg, {Color? bg, IconData? icon}) {
    final themeBg = bg ?? Colors.black87;
    final sb = SnackBar(
      behavior: SnackBarBehavior.floating,
      elevation: 2,
      backgroundColor: themeBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      content: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
      duration: const Duration(seconds: 2),
    );
    ScaffoldMessenger.of(context).showSnackBar(sb);
  }

  void _toastSuccess(String msg) =>
      _showToast(msg, bg: _ok, icon: Icons.check_circle_rounded);

  void _toastError(String msg) =>
      _showToast(msg, bg: _danger, icon: Icons.error_outline_rounded);

  // ───────────────── LOGIC ─────────────────

  // 1. Start streaming GPS -> Firestore
  Future<void> _startLiveTracking() async {
    final locationSettings = const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 10,
    );

    _gpsSub = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((pos) {
      _currentPos = LatLng(pos.latitude, pos.longitude);
      _updateMarker();

      // Update Firestore live
      FirebaseFirestore.instance
          .collection('live_requests')
          .doc(widget.requestId)
          .update({
        'providerLat': pos.latitude,
        'providerLng': pos.longitude,
      });
    });
  }

  // 2. Fetch Polyline (Provider -> Seeker)
  Future<void> _fetchRoute() async {
    final double pLat = widget.requestData['pickupLat'];
    final double pLng = widget.requestData['pickupLng'];

    final pos = await Geolocator.getCurrentPosition();

    final url = Uri.parse(
        'https://maps.googleapis.com/maps/api/directions/json?origin=${pos.latitude},${pos.longitude}&destination=$pLat,$pLng&mode=driving&key=$_googleApiKey');

    try {
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if ((data['routes'] as List).isNotEmpty) {
          final points = data['routes'][0]['overview_polyline']['points'];
          setState(() {
            _routePoints = _decodePolyline(points);
          });
        }
      }
    } catch (_) {}
  }

  // 3. Complete Job (With Updated History Logic + Badges)
  Future<void> _completeJob() async {
    setState(() => _isCompleting = true);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      // 1. Update Live Request Status
      await FirebaseFirestore.instance
          .collection('live_requests')
          .doc(widget.requestId)
          .update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });

      // 2. Archive to History (with isLive flag for badges)
      final historyData = Map<String, dynamic>.from(widget.requestData);
      historyData['status'] = 'completed';
      historyData['isLive'] = true;
      historyData['gigTitle'] = widget.requestData['serviceType'] ?? 'Live Service'; // Ensure title exists

      await FirebaseFirestore.instance.collection('services_history').add({
        'providerId': uid,
        'sourceId': widget.requestId,
        'archivedAt': FieldValue.serverTimestamp(),
        'archivedReason': 'live_completed',
        'isLive': true, // Top-level flag for easy querying
        'data': historyData,
      });

      // Stop GPS
      _gpsSub?.cancel();

      if (mounted) {
        Navigator.pop(context); // Return to dashboard
        _toastSuccess('Job Completed! Saved to history.');
      }
    } catch (e) {
      setState(() => _isCompleting = false);
      _toastError('Error: $e');
    }
  }

  // 4. Cancel Job
  Future<void> _cancelJob() async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cancel Job?'),
          content: const Text('This will release the request back to other providers.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, Cancel')),
          ],
        )
    );

    if (confirm != true) return;

    await FirebaseFirestore.instance
        .collection('live_requests')
        .doc(widget.requestId)
        .update({
      'status': 'searching',
      'providerId': null,
      'providerName': null,
      'providerPhone': null,
      'providerLat': null,
      'providerLng': null,
      'cancelledBy': 'provider',
    });

    if(mounted) Navigator.pop(context);
  }

  // Helper: Decode Polyline
  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> poly = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;
    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lat += dlat;
      shift = 0; result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0) ? ~(result >> 1) : (result >> 1);
      lng += dlng;
      poly.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return poly;
  }

  void _updateMarker() {
    setState(() {
      _markers.clear();
      if(_currentPos != null) {
        _markers.add(Marker(
          markerId: const MarkerId('me'),
          position: _currentPos!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          rotation: 0,
        ));
      }
      _markers.add(Marker(
        markerId: const MarkerId('seeker'),
        position: LatLng(widget.requestData['pickupLat'], widget.requestData['pickupLng']),
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.requestData['seekerName'] ?? 'Seeker';
    final fare = widget.requestData['fare'];
    final pickup = widget.requestData['pickupAddress'] ?? 'Pickup Location';

    return Scaffold(
      body: Stack(
        children: [
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: LatLng(widget.requestData['pickupLat'], widget.requestData['pickupLng']),
              zoom: 14,
            ),
            markers: _markers,
            polylines: {
              if(_routePoints.isNotEmpty)
                Polyline(
                  polylineId: const PolylineId('route'),
                  points: _routePoints,
                  color: _accent,
                  width: 5,
                )
            },
            onMapCreated: (c) => _mapController = c,
            myLocationEnabled: false,
            zoomControlsEnabled: false,
          ),

          // TOP CARD
          Positioned(
            top: 50, left: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      const Icon(Icons.person, color: Colors.grey),
                      const SizedBox(width: 8),
                      Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const Spacer(),
                      Text('PKR $fare', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.green)),
                    ],
                  ),
                  const Divider(),
                  Row(
                    children: [
                      const Icon(Icons.place, color: _accent),
                      const SizedBox(width: 8),
                      Expanded(child: Text(pickup, maxLines: 2, overflow: TextOverflow.ellipsis)),
                    ],
                  )
                ],
              ),
            ),
          ),

          // BOTTOM BUTTONS
          Positioned(
            bottom: 30, left: 16, right: 16,
            child: Column(
              children: [
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                    ),
                    onPressed: _isCompleting ? null : _completeJob,
                    child: _isCompleting
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text('MARK COMPLETE', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: TextButton(
                    style: TextButton.styleFrom(
                        foregroundColor: Colors.red,
                        backgroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                    ),
                    onPressed: _cancelJob,
                    child: const Text('CANCEL JOB', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
