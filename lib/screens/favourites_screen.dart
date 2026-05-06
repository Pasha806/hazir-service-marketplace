import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'gig_detail_screen.dart';

// --- THEME ---
const _text = Color(0xFF121316);
const _sub = Color(0xFF6C7280);
const _pink = Color(0xFF7966FA);
const _border = Color(0xFFE8E9EF);

// --- APP-WIDE TOAST COLORS ---
const _ok = Color(0xFF17A34A);
const _info = Color(0xFF1677FF);
const _warn = Color(0xFFEF6C00);
const _danger = Color(0xFFD33A4A);

class FavouritesScreen extends StatelessWidget {
  const FavouritesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: _text),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const Text('Favourites',
            style: TextStyle(color: _text, fontWeight: FontWeight.w800)),
        centerTitle: false,
      ),
      body: const _FavList(),
    );
  }
}

/* ------------------------------ Favourites list ------------------------------ */

class _FavList extends StatefulWidget {
  const _FavList();

  @override
  State<_FavList> createState() => _FavListState();
}

class _FavListState extends State<_FavList> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  // Keep removed items visible until page is dismissed.
  final Map<String, _FavItem> _linger = {};

  Stream<QuerySnapshot> _stream(String uid) {
    return FirebaseFirestore.instance
        .collection('favourites')
        .where('userId', isEqualTo: uid)
        .snapshots();
  }

  // ---------------- TOASTS (CONSISTENT) ----------------
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

  void _toastSuccess(String msg) => _toast(msg: msg, icon: Icons.check_circle_rounded, color: _ok);
  void _toastInfo(String msg) => _toast(msg: msg, icon: Icons.info_rounded, color: _info);
  void _toastWarn(String msg) => _toast(msg: msg, icon: Icons.warning_amber_rounded, color: _warn);
  void _toastError(String msg) => _toast(msg: msg, icon: Icons.error_rounded, color: _danger);

  // ---------------- ACTIONS ----------------

  Future<void> _removeAllForGig(String uid, String gigId) async {
    try {
      final q = await FirebaseFirestore.instance
          .collection('favourites')
          .where('userId', isEqualTo: uid)
          .where('gigId', isEqualTo: gigId)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (final d in q.docs) {
        batch.delete(d.reference);
        _linger[d.id] = _FavItem.fromDoc(d);
      }
      await batch.commit();

      if (mounted) {
        _toastInfo('Removed from favourites');
        setState(() {});
      }
    } catch (_) {
      _toastError('Failed to remove');
    }
  }

  Future<void> _refavourite(_FavItem item) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;

      final favId = '${uid}_${item.gigId}';
      await FirebaseFirestore.instance
          .collection('favourites')
          .doc(favId)
          .set(item.toFirestore(uid), SetOptions(merge: true));

      if (mounted) {
        _toastSuccess('Added to favourites');
        setState(() {});
      }
    } catch (_) {
      _toastError('Couldn’t add to favourites');
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const _EmptyState();

    return StreamBuilder<QuerySnapshot>(
      stream: _stream(uid),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final liveAll = (snap.data?.docs ?? const []).map(_FavItem.fromDoc).toList();

        final Map<String, _FavItem> liveByGig = {};
        for (final it in liveAll) {
          final deterministicId = '${uid}_${it.gigId}';
          if (!liveByGig.containsKey(it.gigId) || it.id == deterministicId) {
            liveByGig[it.gigId] = it;
          }
        }
        final live = liveByGig.values.toList();
        final liveIds = live.map((e) => e.id).toSet();

        for (final it in live) {
          _linger[it.id] = it;
        }

        final Map<String, _FavItem> visibleByGig = {...liveByGig};
        for (final it in _linger.values) {
          if (!visibleByGig.containsKey(it.gigId)) {
            visibleByGig[it.gigId] = it;
          }
        }
        final visible = visibleByGig.values.toList();

        if (visible.isEmpty) return const _EmptyState();

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            const SizedBox(height: 6),
            const Text('Services',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: _text)),
            const SizedBox(height: 10),
            ...visible.map((it) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _FavCard(
                item: it,
                isActive: liveIds.contains(it.id),
                onToggleHeart: () async {
                  if (it.gigId.isEmpty) return;
                  if (liveIds.contains(it.id)) {
                    await _removeAllForGig(uid, it.gigId);
                  } else {
                    await _refavourite(it);
                  }
                },
              ),
            )),
          ],
        );
      },
    );
  }
}

/* --------------------------------- Card UI ---------------------------------- */

class _FavCard extends StatelessWidget {
  final _FavItem item;
  final bool isActive;
  final VoidCallback onToggleHeart;
  const _FavCard({
    required this.item,
    required this.isActive,
    required this.onToggleHeart,
  });

  @override
  Widget build(BuildContext context) {
    final img = item.imageProvider;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        if (item.gigId.isEmpty) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GigDetailScreen(
              gigId: item.gigId,
              data: item.forwardMap(),
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _border),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: img == null
                        ? Container(
                      color: const Color(0xFFF2F2F6),
                      child: const Center(
                        child: Icon(Icons.image_outlined, color: _sub, size: 36),
                      ),
                    )
                        : Image(image: img, fit: BoxFit.cover),
                  ),
                ),
                Positioned(
                  right: 10,
                  top: 10,
                  child: Material(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                    elevation: 1.5,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: onToggleHeart,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Icon(
                          isActive ? Icons.favorite : Icons.favorite_border,
                          color: _pink,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          item.title.isEmpty ? 'Service' : item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                            color: _text,
                          ),
                        ),
                      ),
                      if (item.ratingAvg > 0) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.star_rounded, color: Color(0xFFFFB21D), size: 18),
                        const SizedBox(width: 4),
                        Text(
                          item.ratingAvg.toStringAsFixed(1),
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.ratingCount > 0 ? '(${item.ratingCount})' : '',
                          style: const TextStyle(color: _sub),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (item.category.isNotEmpty || item.providerName.isNotEmpty)
                    Text(
                      [
                        if (item.category.isNotEmpty) item.category,
                        if (item.providerName.isNotEmpty) item.providerName,
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _sub),
                    ),
                  if (item.location.isNotEmpty || item.experience.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (item.location.isNotEmpty) item.location,
                        if (item.experience.isNotEmpty) item.experience,
                      ].join(' • '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: _sub, fontSize: 13.5),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ---------------------------------- Model ----------------------------------- */

class _FavItem {
  final String id;
  final String gigId;
  final String title;
  final String imageUrl;
  final String imageB64;
  final double ratingAvg;
  final int ratingCount;
  final String category;
  final String providerName;
  final String providerId;
  final String phone;
  final num? price;

  final String location;
  final String experience;
  final String workingHours;
  final String description;
  final List<String> services;

  _FavItem({
    required this.id,
    required this.gigId,
    required this.title,
    required this.imageUrl,
    required this.imageB64,
    required this.ratingAvg,
    required this.ratingCount,
    required this.category,
    required this.providerName,
    required this.providerId,
    required this.phone,
    required this.price,
    required this.location,
    required this.experience,
    required this.workingHours,
    required this.description,
    required this.services,
  });

  ImageProvider? get imageProvider {
    if (imageB64.isNotEmpty) {
      try {
        return MemoryImage(base64Decode(imageB64));
      } catch (_) {}
    }
    if (imageUrl.isNotEmpty) return NetworkImage(imageUrl);
    return null;
  }

  Map<String, dynamic> forwardMap() => {
    'title': title,
    'category': category,
    'price': price,
    'ratingAvg': ratingAvg,
    'ratingCount': ratingCount,
    if (imageB64.isNotEmpty) 'photosB64': [imageB64],
    if (imageUrl.isNotEmpty) 'photos': [imageUrl],
    if (providerName.isNotEmpty) 'providerName': providerName,
    if (providerId.isNotEmpty) 'providerId': providerId,
    if (phone.isNotEmpty) 'phone': phone,
    if (location.isNotEmpty) 'location': location,
    if (experience.isNotEmpty) 'experience': experience,
    if (workingHours.isNotEmpty) 'workingHours': workingHours,
    if (description.isNotEmpty) 'description': description,
    if (services.isNotEmpty) 'services': services,
  };

  Map<String, dynamic> toFirestore(String uid) => {
    'userId': uid,
    'gigId': gigId,
    'title': title,
    'imageUrl': imageUrl,
    'imageB64': imageB64,
    'ratingAvg': ratingAvg,
    'ratingCount': ratingCount,
    'category': category,
    'providerName': providerName,
    'providerId': providerId,
    'phone': phone,
    'price': price,
    'location': location,
    'experience': experience,
    'workingHours': workingHours,
    'description': description,
    'services': services,
    'createdAt': FieldValue.serverTimestamp(),
  };

  static _FavItem fromDoc(DocumentSnapshot d) {
    final m = (d.data() as Map<String, dynamic>? ?? {});
    return _FavItem(
      id: d.id,
      gigId: (m['gigId'] ?? '').toString(),
      title: (m['title'] ?? m['name'] ?? 'Service').toString(),
      imageUrl: (m['imageUrl'] ?? m['thumbUrl'] ?? '').toString(),
      imageB64: (m['imageB64'] ?? '').toString(),
      ratingAvg: (m['ratingAvg'] is num) ? (m['ratingAvg'] as num).toDouble() : 0.0,
      ratingCount: (m['ratingCount'] is num) ? (m['ratingCount'] as num).toInt() : 0,
      category: (m['category'] ?? '').toString(),
      providerName: (m['providerName'] ?? '').toString(),
      providerId: (m['providerId'] ?? '').toString(),
      phone: (m['phone'] ?? '').toString(),
      price: (m['price'] ?? m['amount']),
      location: (m['location'] ?? '').toString(),
      experience: (m['experience'] ?? '').toString(),
      workingHours: (m['workingHours'] ?? '').toString(),
      description: (m['description'] ?? '').toString(),
      services: (m['services'] is List)
          ? (m['services'] as List).map((e) => e.toString()).toList()
          : const <String>[],
    );
  }
}

/* ------------------------------ Empty state UI ------------------------------ */

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  static Future<bool> _assetExists(String path) async {
    try { await rootBundle.load(path); return true; } catch (_) { return false; }
  }

  @override
  Widget build(BuildContext context) {
    const pandaPath = 'assets/illustrations/pink_heart_panda.png';
    final pad = MediaQuery.of(context).padding.bottom;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: Padding(
        padding: EdgeInsets.fromLTRB(24, 56, 24, 24 + pad),
        child: Column(
          children: [
            FutureBuilder<bool>(
              future: _assetExists(pandaPath),
              builder: (_, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const SizedBox(height: 180);
                }
                if (snap.data == true) {
                  return SizedBox(
                    height: 180,
                    child: Image.asset(pandaPath, fit: BoxFit.contain),
                  );
                }
                return const SizedBox(height: 180, child: _PandaFallback());
              },
            ),
            const SizedBox(height: 18),
            const Text(
              'No favourites saved',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _text,
                fontWeight: FontWeight.w900,
                fontSize: 22,
                height: 1.1,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              "To make Requesting even faster, you'll find all your faves here. Just look for the heart icon!",
              textAlign: TextAlign.center,
              style: TextStyle(color: _sub, fontSize: 15, height: 1.35),
            ),
            const SizedBox(height: 20),
            SizedBox(
              height: 48,
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _pink,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  Navigator.of(context).maybePop();
                },
                child: const Text(
                  "Let's find some favourites",
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PandaFallback extends StatelessWidget {
  const _PandaFallback();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 128,
            height: 128,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFFFEEF4),
            ),
          ),
          const Icon(Icons.favorite_rounded, color: _pink, size: 64),
        ],
      ),
    );
  }
}