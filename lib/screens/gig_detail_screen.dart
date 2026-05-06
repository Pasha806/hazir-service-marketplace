// lib/screens/gig_detail_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature, ImageFilter;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'chat_list_screen.dart';

import 'hire_address_screen.dart';
import 'seeker_requests_screen.dart'; // jump to "My Requests" with success banner

const _accent = Color(0xFF7966FA);
const _chipBg = Color(0xFFF6F7FB);
const _star = Color(0xFFFFB21D);
const _text = Color(0xFF121316);
const _sub = Color(0xFF6C7280);

// App-wide toast palette (align with seeker side)
const _ok = Color(0xFF17A34A);
const _info = Color(0xFF1677FF);
const _warn = Color(0xFFEF6C00);
const _danger = Color(0xFFD33A4A);

class GigDetailScreen extends StatefulWidget {
  final String gigId;
  final Map<String, dynamic> data; // pass from search/favourites to avoid extra read

  const GigDetailScreen({
    super.key,
    required this.gigId,
    required this.data,
  });

  @override
  State<GigDetailScreen> createState() => _GigDetailScreenState();
}

class _GigDetailScreenState extends State<GigDetailScreen> {
  final _page = PageController();
  int _pageIndex = 0;
  bool _creating = false;

  // Favourites
  StreamSubscription<QuerySnapshot>? _favSub;
  String? _favDocId; // null => not favourited
  bool _favBusy = false; // prevent double taps

  @override
  void initState() {
    super.initState();
    // Prevent keyboard from popping up when returning from other screens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
    _listenFav();
  }



  void _listenFav() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _favSub = FirebaseFirestore.instance
        .collection('favourites')
        .where('userId', isEqualTo: uid)
        .where('gigId', isEqualTo: widget.gigId)
        .limit(1)
        .snapshots()
        .listen((snap) {
      final doc = snap.docs.isNotEmpty ? snap.docs.first : null;
      if (mounted) {
        setState(() => _favDocId = doc?.id);
      }
    });
  }

  @override
  void dispose() {
    _page.dispose();
    _favSub?.cancel();
    super.dispose();
  }

  Future<void> _shareGig() async {
    final m = widget.data;
    final title = (m['title'] ?? 'Service').toString();
    final provider = (m['providerName'] ?? 'Provider').toString();
    final price = m['price'];

    // Create a shareable text
    final String shareText =
        "Check out this service on Hazir!\n\n"
        "$title by $provider\n"
        "Starts from PKR $price\n\n"
        "Download Hazir to book now!";

    // You can add a link here if you have deep linking set up, e.g., https://hazir.app/gig/${widget.gigId}

    await Share.share(shareText);
  }

  Future<void> _startHireFlow() async {
    final result = await Navigator.push<HireAddressResult>(
      context,
      MaterialPageRoute(builder: (_) => const HireAddressScreen()),
    );
    if (result == null) return;
    await _createServiceRequest(result);
  }

  Future<void> _createServiceRequest(HireAddressResult addr) async {
    if (_creating) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _toastError('Please log in to place a request');
      return;
    }

    final m = widget.data;
    String providerId = (m['providerId'] ?? '').toString();
    if (providerId.isEmpty) {
      // If missing, try to get from gigs/{gigId}
      try {
        final g = await FirebaseFirestore.instance.collection('gigs').doc(widget.gigId).get();
        providerId = (g.data()?['providerId'] ?? '').toString();
      } catch (_) {}
    }
    if (providerId.isEmpty) {
      _toastError('Missing provider info on this gig');
      return;
    }

    setState(() => _creating = true);

    try {
      String providerName = '';
      String providerPhone = (m['phone'] ?? '').toString(); // prefer phone saved on gig

      try {
        // Fallback name/phone from users/{providerId}
        if (providerName.isEmpty || providerPhone.isEmpty) {
          final pdoc = await FirebaseFirestore.instance.collection('users').doc(providerId).get();
          final pdata = pdoc.data() ?? {};
          final pmap = (pdata['provider'] is Map)
              ? (pdata['provider'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          providerName = (pmap['name'] ?? '').toString();
          providerPhone = providerPhone.isNotEmpty ? providerPhone : (pdata['phone'] ?? '').toString();
        }
      } catch (_) {}

      final gigTitle = (m['title'] ?? '').toString();
      final gigCategory = (m['category'] ?? '').toString();
      final gigPrice = m['price'];

      final doc = FirebaseFirestore.instance.collection('service_requests').doc();
      await doc.set({
        'seekerId': user.uid,
        'gigId': widget.gigId,
        'providerId': providerId,
        'visitType': addr.visitType,
        'phone': addr.phone,
        'address': addr.address,
        'label': addr.label,
        'lat': addr.lat,
        'lng': addr.lng,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'gigTitle': gigTitle,
        'gigCategory': gigCategory,
        'gigPrice': gigPrice,
        'providerName': providerName,
        'providerPhone': providerPhone,
      });

      if (!mounted) return;

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => const SeekerRequestsScreen(
            showSuccess: true,
            successTitle: 'Request sent!',
            successSubtitle: 'We’ve notified the provider. Track status here.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      _toastError('Could not place request');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Stream<QuerySnapshot> _activeRequestStream(String uid) {
    final providerId = (widget.data['providerId'] ?? '').toString();
    return FirebaseFirestore.instance
        .collection('service_requests')
        .where('seekerId', isEqualTo: uid)
        .where('providerId', isEqualTo: providerId)
        .where('gigId', isEqualTo: widget.gigId)
        .where('status', whereIn: ['pending', 'accepted', 'enroute'])
        .orderBy('createdAt', descending: true)
        .limit(1)
        .snapshots();
  }

  Future<void> _cancelRequest(String reqId) async {
    try {
      await FirebaseFirestore.instance.collection('service_requests').doc(reqId).update({
        'status': 'cancelled',
        'cancelledBy': 'seeker',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
      if (!mounted) return;
      _toastSuccess('Request cancelled');
    } catch (e) {
      if (!mounted) return;
      _toastError('Failed to cancel');
    }
  }

  // ---------- Favourites ----------
  Map<String, dynamic> _favPayload(String uid) {
    final m = widget.data;
    String imageUrl = '';
    if (m['photos'] is List && (m['photos'] as List).isNotEmpty) {
      final p = (m['photos'] as List).first;
      imageUrl = p?.toString() ?? '';
    }

    String imageB64 = '';
    if (m['photosB64'] is List && (m['photosB64'] as List).isNotEmpty) {
      final p = (m['photosB64'] as List).first;
      imageB64 = p?.toString() ?? '';
    }

    return {
      'userId': uid,
      'gigId': widget.gigId,
      'title': (m['title'] ?? '').toString(),
      'imageUrl': imageUrl,
      'imageB64': imageB64,
      'ratingAvg': (m['ratingAvg'] is num) ? (m['ratingAvg'] as num).toDouble() : 0.0,
      'ratingCount': (m['ratingCount'] is num) ? (m['ratingCount'] as num).toInt() : 0,
      'category': (m['category'] ?? '').toString(),
      'providerName': (m['providerName'] ?? '').toString(),
      'providerId': (m['providerId'] ?? '').toString(),
      'phone': (m['phone'] ?? '').toString(),
      'price': m['price'],
      'createdAt': FieldValue.serverTimestamp(),
    };
  }

  Future<void> _toggleFavourite() async {
    if (_favBusy) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _toastError('Please log in to use favourites');
      return;
    }
    setState(() => _favBusy = true);
    try {
      if (_favDocId == null) {
        await FirebaseFirestore.instance.collection('favourites').add(_favPayload(uid));
        _toastSuccess('Added to favourites');
      } else {
        await FirebaseFirestore.instance.collection('favourites').doc(_favDocId!).delete();
        _toastInfo('Removed from favourites');
      }
    } catch (e) {
      _toastError('Could not update favourites');
    } finally {
      if (mounted) setState(() => _favBusy = false);
    }
  }

  String _twoDigits(int x) => x < 10 ? '0$x' : '$x';
  String _fmtShort(DateTime dt) {
    const w = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const m = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final wd = w[(dt.weekday - 1).clamp(0, 6)];
    final mon = m[(dt.month - 1).clamp(0, 11)];
    final hh = _twoDigits(dt.hour);
    final mm = _twoDigits(dt.minute);
    return '$wd, $mon ${dt.day} • $hh:$mm';
  }

  // ===================== Toasts (seeker-style) =====================
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

  Future<void> _openEditReviewDialog() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      _toastError('Please log in to review');
      return;
    }

    final providerId = (widget.data['providerId'] ?? '').toString();

    // Guard: only after a completed request for this gig+provider by this seeker
    try {
      final q = await FirebaseFirestore.instance
          .collection('service_requests')
          .where('seekerId', isEqualTo: uid)
          .where('providerId', isEqualTo: providerId)
          .where('gigId', isEqualTo: widget.gigId)
          .where('status', isEqualTo: 'completed')
          .limit(1)
          .get();

      if (q.docs.isEmpty) {
        _toastInfo('You can review after the job is completed');
        return;
      }
    } catch (_) {
      _toastInfo('You can review after the job is completed');
      return;
    }

    // Prefill if this seeker already reviewed this gig
    DocumentSnapshot<Map<String, dynamic>>? existingDoc;
    try {
      final q = await FirebaseFirestore.instance
          .collection('gig_reviews')
          .where('gigId', isEqualTo: widget.gigId)
          .where('seekerId', isEqualTo: uid)
          .limit(1)
          .get();
      if (q.docs.isNotEmpty) existingDoc = q.docs.first;
    } catch (_) {}

    int behavior = (existingDoc?.data()?['behavior'] as num?)?.toInt() ?? 5;
    int quality = (existingDoc?.data()?['quality'] as num?)?.toInt() ?? 5;
    final ctl = TextEditingController(text: (existingDoc?.data()?['review'] ?? '').toString());
    bool saving = false;

    String authorName = '';
    try {
      final udoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      final um = udoc.data() ?? {};
      authorName = (um['display_name'] ?? um['name'] ?? '').toString();
    } catch (_) {}

    final dialogTitle = existingDoc == null ? 'Write rating & review' : 'Edit rating & review';

    await showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Review',
      barrierColor: Colors.black26,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
      transitionBuilder: (ctx, anim, _, __child) {
        final scale = Tween<double>(begin: .96, end: 1).animate(
          CurvedAnimation(parent: anim, curve: Curves.easeOutCubic),
        );
        return Stack(
          children: [
            Positioned.fill(
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 4 * anim.value, sigmaY: 4 * anim.value),
                child: Container(color: Colors.transparent),
              ),
            ),
            Center(
              child: ScaleTransition(
                scale: scale,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  elevation: 10,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: StatefulBuilder(
                      builder: (ctx, setSB) => Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Text(
                                  dialogTitle,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const Spacer(),
                                IconButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  icon: const Icon(Icons.close_rounded),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            _StarPicker(
                              label: 'Worker behaviour',
                              value: behavior,
                              onChanged: (v) => setSB(() => behavior = v),
                            ),
                            const SizedBox(height: 4),
                            _StarPicker(
                              label: 'Quality of work',
                              value: quality,
                              onChanged: (v) => setSB(() => quality = v),
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: ctl,
                              maxLines: 3,
                              decoration: const InputDecoration(
                                hintText: 'Share a few details (optional)',
                                filled: true,
                                fillColor: Color(0xFFF6F7FB),
                                border: OutlineInputBorder(
                                  borderSide: BorderSide.none,
                                  borderRadius: BorderRadius.all(Radius.circular(12)),
                                ),
                                contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: saving ? null : () => Navigator.pop(ctx),
                                    child: const Text(
                                      'Later',
                                      style: TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: FilledButton(
                                    style: FilledButton.styleFrom(backgroundColor: _accent),
                                    onPressed: saving
                                        ? null
                                        : () async {
                                      setSB(() => saving = true);
                                      try {
                                        final overall = ((behavior + quality) / 2.0);
                                        final data = {
                                          'gigId': widget.gigId,
                                          'providerId': (widget.data['providerId'] ?? '').toString(),
                                          'seekerId': uid,
                                          'authorId': uid,
                                          if (authorName.isNotEmpty) 'authorName': authorName,
                                          'rating': overall,
                                          'behavior': behavior,
                                          'quality': quality,
                                          'review': ctl.text.trim(),
                                          'createdAt': FieldValue.serverTimestamp(),
                                        };
                                        if (existingDoc == null) {
                                          await FirebaseFirestore.instance
                                              .collection('gig_reviews')
                                              .add(data);
                                        } else {
                                          await FirebaseFirestore.instance
                                              .collection('gig_reviews')
                                              .doc(existingDoc!.id)
                                              .set(data, SetOptions(merge: true));
                                        }
                                        if (mounted) {
                                          Navigator.pop(ctx);
                                          _toastSuccess('Review saved');
                                        }
                                      } catch (e) {
                                        _toastError('Could not save review');
                                        setSB(() => saving = false);
                                      }
                                    },
                                    child: saving
                                        ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                        : const Text(
                                      'Save',
                                      style: TextStyle(fontWeight: FontWeight.w800),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.data;

    final jobTitle = (m['title'] ?? '').toString();
    final category = (m['category'] ?? '').toString();
    final location = (m['location'] ?? '').toString();
    final price = m['price'];
    final workHours = (m['workingHours'] ?? '').toString();
    final services = (m['services'] as List?)?.cast<String>() ?? const <String>[];
    final providerId = (m['providerId'] ?? '').toString();
    final desc = (m['description'] ?? '').toString();
    final photos = (m['photosB64'] as List?)?.cast<String>() ?? const <String>[];
    final profileB64 = (m['profileB64'] ?? '').toString();
    final gigPhone = (m['phone'] ?? '').toString();

    List<ImageProvider?> gallery = [];
    for (final b64 in photos) {
      try {
        gallery.add(MemoryImage(base64Decode(b64)));
      } catch (_) {
        gallery.add(null);
      }
    }
    if (gallery.isEmpty) gallery = [null];

    ImageProvider? avatar;
    if (profileB64.isNotEmpty) {
      try {
        avatar = MemoryImage(base64Decode(profileB64));
      } catch (_) {}
    }

    String years = '';
    final expStr = (m['experience'] ?? '').toString();
    final expNum = int.tryParse(RegExp(r'\d+').firstMatch(expStr)?.group(0) ?? '');
    if (expNum != null) years = '$expNum Years';

    String jobType = 'Flexible';
    final wh = workHours.toLowerCase();
    if (wh.contains('full')) {
      jobType = 'Full Time';
    } else if (wh.contains('part')) {
      jobType = 'Part Time';
    }

    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Colors.white,
      body: Stack(
        children: [
          CustomScrollView(
            physics: const BouncingScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: _HeaderCarousel(
                  gallery: gallery,
                  controller: _page,
                  index: _pageIndex,
                  onChanged: (i) => setState(() => _pageIndex = i),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 26,
                        backgroundColor: _chipBg,
                        backgroundImage: avatar,
                        child: avatar == null
                            ? const Icon(Icons.person, color: _sub)
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: _ProviderName(providerId: providerId)),
                      IconButton(
                        icon: const Icon(Icons.more_horiz_rounded),
                        onPressed: () {},
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _ContactCard(
                    providerId: providerId,
                    fallbackPhone: gigPhone,
                    providerName: (m['providerName'] ?? 'Provider').toString(),
                    providerAvatar: profileB64,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      _InfoPill(
                        icon: Icons.location_pin,
                        label: location.isEmpty ? '—' : location,
                      ),
                      const SizedBox(width: 10),
                      _InfoPill(
                        icon: Icons.workspace_premium_outlined,
                        label: years.isEmpty ? '—' : years,
                      ),
                      const SizedBox(width: 10),
                      _InfoPill(
                        icon: Icons.bolt,
                        label: jobType,
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _Section(
                  title: 'Job Title',
                  child: Text(
                    jobTitle.isEmpty ? category : jobTitle,
                    style: const TextStyle(fontSize: 16.5, color: _text),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _Section(
                  title: 'Description',
                  child: Text(
                    desc.isEmpty ? 'No description added.' : desc,
                    style: const TextStyle(height: 1.45, color: _text),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _Section(
                  title: 'Services I Offer',
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: services.isEmpty
                        ? const [
                      Text(
                        'No services listed yet.',
                        style: TextStyle(color: _sub),
                      ),
                    ]
                        : services
                        .map(
                          (s) => Padding(
                        padding:
                        const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.check_circle,
                                color: Colors.green),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                s,
                                style: const TextStyle(fontSize: 15.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                        .toList(),
                  ),
                ),
              ),
              // Ratings summary card (live overall, compact edit)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 16,
                          offset: const Offset(0, 8),
                        ),
                      ],
                      border: Border.all(color: const Color(0xFFE9EAF2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _OverallRatingRow(
                          gigId: widget.gigId,
                          seekerId: uid,
                          providerId: providerId,
                          onEdit: _openEditReviewDialog,
                        ),
                        const SizedBox(height: 12),
                        _SubRatingRow(
                          label: 'Worker behaviour',
                          gigId: widget.gigId,
                          field: 'behavior',
                        ),
                        const SizedBox(height: 8),
                        _SubRatingRow(
                          label: 'Quality of work',
                          gigId: widget.gigId,
                          field: 'quality',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _ReviewsStrip(gigId: widget.gigId),
              ),
              const SliverToBoxAdapter(
                child: SizedBox(height: 120),
              ),
            ],
          ),
          // Top bar (back + favourite + price chip)
          // Top bar (back + price + share + favorite)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), // Tweaked padding
              child: Row(
                children: [
                  _CircleBtn(
                    icon: Icons.arrow_back_ios_new_rounded,
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const Spacer(),
                  if (price != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.06),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Text(
                        'PKR $price',
                        style: const TextStyle(
                          color: Color(0xFF0E7D40),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),

                  const SizedBox(width: 8),

                  // --- NEW SHARE BUTTON ---
                  _CircleBtn(
                    icon: Icons.share_rounded,
                    onTap: _shareGig,
                  ),

                  const SizedBox(width: 8),

                  // Heart button
                  Material(
                    color: Colors.white,
                    shape: const CircleBorder(),
                    elevation: 2,
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _favBusy ? null : _toggleFavourite,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Icon(
                          _favDocId == null
                              ? Icons.favorite_border
                              : Icons.favorite,
                          color: _accent,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Bottom CTA (Hire / View / Cancel)
          Positioned(
            left: 16,
            right: 16,
            bottom: 20 + MediaQuery.of(context).padding.bottom,
            child: SizedBox(
              height: 56,
              child: Builder(
                builder: (ctx) {
                  final uid = FirebaseAuth.instance.currentUser?.uid;
                  if (uid == null) {
                    return _HireButton(
                      loading: _creating,
                      onPressed: _creating ? null : _startHireFlow,
                    );
                  }

                  return StreamBuilder<QuerySnapshot>(
                    stream: _activeRequestStream(uid),
                    builder: (context, snap) {
                      final docs = snap.data?.docs ?? const [];
                      if (docs.isEmpty) {
                        return _HireButton(
                          loading: _creating,
                          onPressed: _creating ? null : _startHireFlow,
                        );
                      }

                      final d = docs.first;
                      final dm = (d.data() as Map<String, dynamic>);
                      final reqId = d.id;
                      final status = (dm['status'] ?? 'pending').toString();

                      DateTime? scheduled;
                      final schedRaw = dm['scheduledAt'];
                      if (schedRaw is Timestamp) {
                        scheduled = schedRaw.toDate().toLocal();
                      }
                      if (schedRaw is DateTime) {
                        scheduled = schedRaw.toLocal();
                      }

                      if (status == 'enroute') {
                        return ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFFFA726),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(32),
                            ),
                          ),
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SeekerRequestsScreen(),
                              ),
                            );
                          },
                          icon: const Icon(
                            Icons.directions_walk_rounded,
                            color: Colors.white,
                          ),
                          label: const Text(
                            'En route • View',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                            ),
                          ),
                        );
                      }

                      if (status == 'accepted') {
                        return Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                  side: const BorderSide(
                                    color: _accent,
                                    width: 1.4,
                                  ),
                                ),
                                onPressed: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) =>
                                      const SeekerRequestsScreen(),
                                    ),
                                  );
                                },
                                icon: const Icon(
                                  Icons.visibility_rounded,
                                  color: _accent,
                                ),
                                label: Text(
                                  scheduled != null
                                      ? 'View • ${_fmtShort(scheduled)}'
                                      : 'View',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: _accent,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(32),
                                  ),
                                ),
                                onPressed: () async {
                                  final ok = await showDialog<bool>(
                                    context: context,
                                    builder: (_) => AlertDialog(
                                      title: const Text('Cancel request?'),
                                      content: const Text(
                                        'This will notify the provider and stop this request.',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('No'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('Yes, cancel'),
                                        ),
                                      ],
                                    ),
                                  );
                                  if (ok == true) {
                                    await _cancelRequest(reqId);
                                  }
                                },
                                icon: const Icon(
                                  Icons.cancel,
                                  color: Colors.white,
                                ),
                                label: const Text(
                                  'Cancel',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      }

                      return ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.redAccent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(32),
                          ),
                        ),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Cancel request?'),
                              content: const Text(
                                'This will notify the provider and stop this request.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('No'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(context, true),
                                  child: const Text('Yes, cancel'),
                                ),
                              ],
                            ),
                          );
                          if (ok == true) {
                            await _cancelRequest(reqId);
                          }
                        },
                        icon: const Icon(
                          Icons.cancel,
                          color: Colors.white,
                        ),
                        label: const Text(
                          'Cancel request',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ----------------- Widgets ----------------- */

class _HeaderCarousel extends StatelessWidget {
  final List<ImageProvider?> gallery;
  final PageController controller;
  final int index;
  final ValueChanged<int> onChanged;

  const _HeaderCarousel({
    required this.gallery,
    required this.controller,
    required this.index,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          SizedBox(
            height: 260,
            width: double.infinity,
            child: PageView.builder(
              controller: controller,
              onPageChanged: onChanged,
              itemCount: gallery.length,
              itemBuilder: (_, i) {
                final img = gallery[i];
                return img == null
                    ? Container(
                  color: const Color(0xFFEDEBFF),
                  child: const Center(
                    child: Icon(
                      Icons.image_outlined,
                      color: _accent,
                      size: 48,
                    ),
                  ),
                )
                    : Image(
                  image: img,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                );
              },
            ),
          ),
          Positioned(
            bottom: 10,
            child: Row(
              children: List.generate(
                gallery.length,
                    (i) => Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == index ? 8 : 6,
                  height: i == index ? 8 : 6,
                  decoration: BoxDecoration(
                    color: Colors.white
                        .withOpacity(i == index ? 0.95 : 0.7),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _CircleBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox( // Removed const here so we can use widget.icon
          width: 40,
          height: 40,
          child: Icon(
            icon, // <--- FIXED: uses the passed icon variable
            size: 18,
            color: _text, // Ensure color is visible (using your _text constant)
          ),
        ),
      ),
    );
  }
}

class _ProviderName extends StatelessWidget {
  final String providerId;

  const _ProviderName({required this.providerId});

  @override
  Widget build(BuildContext context) {
    if (providerId.isEmpty) {
      return const Text(
        'Service Provider',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          fontSize: 16,
        ),
      );
    }
    return StreamBuilder<DocumentSnapshot>(
      stream:
      FirebaseFirestore.instance.collection('users').doc(providerId).snapshots(),
      builder: (_, snap) {
        const loading = SizedBox(
          height: 18,
          width: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        if (snap.hasError) {
          return const Text(
            'Service Provider',
            style: TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 16,
            ),
          );
        }
        if (!snap.hasData) return loading;

        final data = snap.data!.data() as Map<String, dynamic>? ?? {};
        final p = data['provider'] as Map<String, dynamic>? ?? {};
        final name = (p['name'] ?? '').toString();

        return Text(
          name.isEmpty ? 'Service Provider' : name,
          style: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }
}

class _ContactCard extends StatelessWidget {
  final String providerId;
  final String providerName; // Added
  final String? providerAvatar; // Added (Base64 string)
  final String fallbackPhone;

  const _ContactCard({
    required this.providerId,
    required this.providerName,
    this.providerAvatar,
    required this.fallbackPhone,
  });

  void _toast(
      BuildContext context, {
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
      ),
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

  void _toastInfo(BuildContext context, String msg) =>
      _toast(context, msg: msg, icon: Icons.info_rounded, color: _info);
  void _toastError(BuildContext context, String msg) =>
      _toast(context, msg: msg, icon: Icons.error_rounded, color: _danger);

  Future<void> _call(String phone, BuildContext context) async {
    final tel = 'tel:$phone';
    try {
      final uri = Uri.parse(tel);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      } else {
        _toastError(context, 'Cannot place a call on this device');
      }
    } catch (_) {
      _toastError(context, 'Failed to launch dialer');
    }
  }

  // --- NEW: Handle Chat Logic ---
  void _openChat(BuildContext context) {
    final myUid = FirebaseAuth.instance.currentUser?.uid;
    if (myUid == null) {
      _toastError(context, 'Please log in to chat');
      return;
    }

    if (providerId.isEmpty) {
      _toastError(context, 'Provider info missing');
      return;
    }

    if (myUid == providerId) {
      _toastInfo(context, 'You cannot chat with yourself');
      return;
    }

    // Use the static helper from ChatListScreen
    ChatListScreen.openChat(
      context,
      myUid: myUid,
      otherUid: providerId,
      otherName: providerName,
      otherAvatar: providerAvatar,
    );
  }

  @override
  Widget build(BuildContext context) {
    final titleStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: Colors.white.withOpacity(0.85),
      letterSpacing: .3,
      fontWeight: FontWeight.w700,
    );

    Widget phoneBlock(String phone) {
      final ph = phone.trim();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.all(8),
                child: const Icon(
                  Icons.phone_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SelectableText(
                  ph.isEmpty ? 'No phone provided' : ph,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontFeatures: [FontFeature.tabularFigures()],
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
              ),
              if (ph.isNotEmpty) ...[
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: ph));
                    if (context.mounted) {
                      _toastInfo(context, 'Number copied');
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.copy_rounded,
                      color: Colors.white,
                      size: 16,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // CALL BUTTON
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    backgroundColor: Colors.white,
                    foregroundColor: _accent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                  ),
                  onPressed: ph.isEmpty ? null : () => _call(ph, context),
                  icon: const Icon(Icons.call_rounded),
                  label: const Text(
                    'Call',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // CHAT BUTTON
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white, width: 1.2),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                  ),
                  onPressed: () => _openChat(context), // <--- Linked here
                  icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  label: const Text(
                    'Chat',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
            ],
          ),
        ],
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [_accent, Color(0xFF5B4CE6)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: _accent.withOpacity(.22),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Contact', style: titleStyle),
          const SizedBox(height: 10),
          if (providerId.isEmpty)
            phoneBlock(fallbackPhone)
          else
            StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('users')
                  .doc(providerId)
                  .snapshots(),
              builder: (_, snap) {
                String phone = fallbackPhone;
                if (snap.hasData) {
                  final data = snap.data!.data() as Map<String, dynamic>? ?? {};
                  final pPhone = (data['phone'] ?? '').toString();
                  if (pPhone.isNotEmpty) phone = pPhone;
                }
                return phoneBlock(phone);
              },
            ),
        ],
      ),
    );
  }
}

class _InfoPill extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoPill({
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
          border: Border.all(color: const Color(0xFFE9EAF2)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _accent),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label.isEmpty ? '—' : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;
  final EdgeInsets? padding;

  const _Section({
    required this.title,
    required this.child,
    this.padding,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ?? const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: _text,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _Stars extends StatelessWidget {
  final double value;
  final double size;

  const _Stars({
    required this.value,
    this.size = 16,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0, 5).toDouble();
    final full = clamped.floor();
    final half = (clamped - full) >= 0.5;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < full; i++)
          Icon(Icons.star_rounded, color: _star, size: size),
        if (half) Icon(Icons.star_half_rounded, color: _star, size: size),
        for (var i = 0; i < (half ? 4 - full : 5 - full); i++)
          Icon(Icons.star_border_rounded, color: _star, size: size),
      ],
    );
  }
}

/* ---------- Overall rating row (live + gated edit) ---------- */
class _OverallRatingRow extends StatelessWidget {
  final String gigId;
  final String? seekerId; // current user
  final String providerId; // this gig's provider
  final VoidCallback onEdit;

  const _OverallRatingRow({
    required this.gigId,
    required this.seekerId,
    required this.providerId,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    // live overall from gig_reviews
    final overallStream = FirebaseFirestore.instance
        .collection('gig_reviews')
        .where('gigId', isEqualTo: gigId)
        .snapshots();

    return StreamBuilder<QuerySnapshot>(
      stream: overallStream,
      builder: (_, snap) {
        double avg = 0;
        int n = 0;
        if (snap.hasData && snap.data!.docs.isNotEmpty) {
          final vals = snap.data!.docs.map((d) {
            final m = d.data() as Map<String, dynamic>;
            if (m['rating'] is num) return (m['rating'] as num).toDouble();
            final b = (m['behavior'] is num)
                ? (m['behavior'] as num).toDouble()
                : 0.0;
            final q = (m['quality'] is num)
                ? (m['quality'] as num).toDouble()
                : 0.0;
            return (b + q) / 2.0;
          }).toList();
          n = vals.length;
          if (n > 0) avg = vals.reduce((a, b) => a + b) / n;
        }

        Widget trailing = const SizedBox.shrink();

        // Only seekers (not provider) and only if logged in can possibly review/edit
        if (seekerId != null &&
            seekerId!.isNotEmpty &&
            seekerId != providerId) {
          // Eligibility: must have at least one completed request for this gig+provider
          final eligibleStream = FirebaseFirestore.instance
              .collection('service_requests')
              .where('seekerId', isEqualTo: seekerId)
              .where('providerId', isEqualTo: providerId)
              .where('gigId', isEqualTo: gigId)
              .where('status', isEqualTo: 'completed')
              .limit(1)
              .snapshots();

          trailing = StreamBuilder<QuerySnapshot>(
            stream: eligibleStream,
            builder: (_, eligSnap) {
              final eligible =
                  eligSnap.hasData && eligSnap.data!.docs.isNotEmpty;
              if (!eligible) return const SizedBox.shrink();

              // If eligible, see if this user already has a review to pick label
              final myReviewStream = FirebaseFirestore.instance
                  .collection('gig_reviews')
                  .where('gigId', isEqualTo: gigId)
                  .where('seekerId', isEqualTo: seekerId)
                  .limit(1)
                  .snapshots();

              return StreamBuilder<QuerySnapshot>(
                stream: myReviewStream,
                builder: (_, mySnap) {
                  final hasReview =
                      mySnap.hasData && mySnap.data!.docs.isNotEmpty;
                  final label = hasReview ? 'Edit' : 'Review';
                  return TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(0, 36),
                    ),
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(
                      label,
                      style:
                      const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  );
                },
              );
            },
          );
        }

        return Row(
          children: [
            Expanded(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Stars(value: avg, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    n == 0 ? '—' : avg.toStringAsFixed(1),
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 18,
                      color: _text,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      '($n)',
                      style: const TextStyle(color: _sub),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            trailing,
          ],
        );
      },
    );
  }
}

class _SubRatingRow extends StatelessWidget {
  final String label;
  final String field; // 'behavior' or 'quality'
  final String gigId;

  const _SubRatingRow({
    required this.label,
    required this.field,
    required this.gigId,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('gig_reviews')
          .where('gigId', isEqualTo: gigId)
          .snapshots(),
      builder: (_, snap) {
        double avg = 0;
        int n = 0;
        if (snap.hasData && snap.data!.docs.isNotEmpty) {
          final vals = snap.data!.docs
              .map(
                (d) =>
            (d.data() as Map<String, dynamic>)[field],
          )
              .where((v) => v is num)
              .map((v) => (v as num).toDouble())
              .toList();
          if (vals.isNotEmpty) {
            n = vals.length;
            avg = vals.reduce((a, b) => a + b) / vals.length;
          }
        }
        final show = n == 0 ? 0.0 : avg;
        return Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _text,
                ),
              ),
            ),
            _Stars(value: show, size: 18),
            const SizedBox(width: 6),
            Text(
              show == 0 ? '—' : show.toStringAsFixed(1),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: _text,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReviewsStrip extends StatelessWidget {
  final String gigId;

  const _ReviewsStrip({required this.gigId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('gig_reviews')
          .where('gigId', isEqualTo: gigId)
          .orderBy('createdAt', descending: true)
          .limit(10)
          .snapshots(),
      builder: (_, snap) {
        final docs = snap.data?.docs ?? const [];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding:
              const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  Text(
                    '${docs.isEmpty ? 0 : docs.length} Reviews',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: _text,
                    ),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () {},
                    child: const Text('See All'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 138,
              child: docs.isEmpty
                  ? const Center(
                child: Text(
                  'No reviews yet',
                  style: TextStyle(color: _sub),
                ),
              )
                  : ListView.separated(
                padding: const EdgeInsets.only(
                  left: 16,
                  right: 16,
                ),
                scrollDirection: Axis.horizontal,
                itemCount: docs.length,
                separatorBuilder: (_, __) =>
                const SizedBox(width: 12),
                itemBuilder: (_, i) {
                  final d =
                  docs[i].data() as Map<String, dynamic>;
                  final name =
                  (d['authorName'] ?? 'Customer').toString();
                  final text =
                  (d['review'] ?? d['text'] ?? '').toString();
                  double rating = 0.0;
                  if (d['rating'] is num) {
                    rating = (d['rating'] as num).toDouble();
                  } else {
                    final b = (d['behavior'] is num)
                        ? (d['behavior'] as num).toDouble()
                        : 0.0;
                    final q = (d['quality'] is num)
                        ? (d['quality'] as num).toDouble()
                        : 0.0;
                    rating = (b + q) / 2.0;
                  }
                  return Container(
                    width: 280,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xFFE9EAF2),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black
                              .withOpacity(0.04),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment:
                      CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const CircleAvatar(
                              backgroundColor: _chipBg,
                              child: Icon(
                                Icons.person,
                                color: _sub,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: Text(
                            text.isEmpty
                                ? 'No comment.'
                                : text,
                            maxLines: 3,
                            overflow:
                            TextOverflow.ellipsis,
                            style: const TextStyle(
                              height: 1.35,
                              color: _text,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            _Stars(value: rating),
                            const SizedBox(width: 6),
                            Text(
                              rating == 0
                                  ? '—'
                                  : rating
                                  .toStringAsFixed(1),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
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
  }
}

class _HireButton extends StatelessWidget {
  final bool loading;
  final VoidCallback? onPressed;

  const _HireButton({
    required this.loading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white24,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(32),
        ),
        elevation: 1,
      ),
      onPressed: onPressed,
      child: loading
          ? const SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(
          color: Colors.white,
          strokeWidth: 2,
        ),
      )
          : const Text(
        'Hire',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

/* ---------------- Star picker (used in editor) ---------------- */

class _StarPicker extends StatelessWidget {
  final String label;
  final int value; // 1..5
  final ValueChanged<int> onChanged;

  const _StarPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: _text,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(5, (i) {
            final filled = i < value;
            return IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(
                width: 40,
                height: 40,
              ),
              onPressed: () => onChanged(i + 1),
              icon: Icon(
                filled
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                size: 26,
                color: filled
                    ? const Color(0xFFFFC107)
                    : Colors.black26,
              ),
            );
          }),
        ),
      ],
    );
  }
}
