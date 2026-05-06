// lib/screens/search_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; // hide own gigs + favorites
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'gig_detail_screen.dart';

/// Shared key for recent searches (visible to both Search & Results pages)
const String kRecentSearchesKey = 'recent_searches_v1';

/* ── Brand / palette ───────────────────────────── */
const Color _accent = Color(0xFF7966FA); // app accent
const Color _ink = Color(0xFF1B133A);
const Color _primary = Color(0xFFD3C3F6);

// Pastel bubbles used by the category grid
const _pastelBlue = Color(0xFFBFE3FF);
const _pastelGreen = Color(0xFFCFEFD9);
const _pastelYellow = Color(0xFFFFE7A3);
const _pastelPeach = Color(0xFFFFD1B8);
const _pastelPink = Color(0xFFFFB6B6);
const _pastelbrown = Color(0xFFD3B9A8);
const _pastelgrey = Color(0xFFD3D3D3);
const _pastelpurple = Color(0xFFCBC3E3);
const _pastelorange = Color(0xFFEAB996);

/* ── Utilities used by both pages ───────────────── */
String _normalize(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _queryGigs(
    String raw,
    ) async {
  final q = _normalize(raw);
  if (q.isEmpty) return <QueryDocumentSnapshot<Map<String, dynamic>>>[];

  final fs = FirebaseFirestore.instance;
  final myUid = FirebaseAuth.instance.currentUser?.uid;

  List<QueryDocumentSnapshot<Map<String, dynamic>>> combineUnique(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> a,
      List<QueryDocumentSnapshot<Map<String, dynamic>>> b,
      ) {
    final map = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final d in a) map[d.id] = d;
    for (final d in b) map[d.id] = d;
    return map.values.toList();
  }

  try {
    final q1 = await fs
        .collection('gigs')
        .where('status', isEqualTo: 'active')
        .where('searchTokens', arrayContains: q)
        .get();

    final q2 = await fs
        .collection('gigs')
        .where('status', isEqualTo: 'active')
        .where('searchPrefixes', arrayContains: q)
        .get();

    var list = combineUnique(q1.docs, q2.docs);

    // 🚫 Hide my own gigs
    if (myUid != null) {
      list =
          list.where((d) => (d.data()['providerId'] ?? '') != myUid).toList();
    }

    // Newest first (if createdAt exists)
    list.sort((a, b) {
      final am = a.data();
      final bm = b.data();
      final ta = (am['createdAt'] is Timestamp)
          ? (am['createdAt'] as Timestamp).toDate()
          : DateTime.fromMillisecondsSinceEpoch(0);
      final tb = (bm['createdAt'] is Timestamp)
          ? (bm['createdAt'] as Timestamp).toDate()
          : DateTime.fromMillisecondsSinceEpoch(0);
      return tb.compareTo(ta);
    });

    // Fallback: if nothing matched (maybe tokens missing), pull recent actives and filter client-side.
    if (list.isEmpty) {
      final broad = await fs
          .collection('gigs')
          .where('status', isEqualTo: 'active')
          .limit(50)
          .get();

      var fallback = broad.docs;
      if (myUid != null) {
        fallback =
            fallback.where((d) => (d.data()['providerId'] ?? '') != myUid).toList();
      }

      final qq = q.toLowerCase();
      list = fallback.where((d) {
        final m = d.data();
        final title = (m['title'] ?? '').toString().toLowerCase();
        final cat = (m['category'] ?? '').toString().toLowerCase();
        final services = ((m['services'] as List?) ?? const [])
            .whereType<String>()
            .map((s) => s.toLowerCase());
        return title.contains(qq) ||
            cat.contains(qq) ||
            services.any((s) => s.contains(qq));
      }).toList();
    }

    return list;
  } catch (e) {
    debugPrint('Search query failed: $e');
    return const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  }
}

Future<List<String>> _suggest(String raw, {int limit = 6}) async {
  final p = _normalize(raw);
  if (p.isEmpty) return const <String>[];

  final myUid = FirebaseAuth.instance.currentUser?.uid;

  final snap = await FirebaseFirestore.instance
      .collection('gigs')
      .where('status', isEqualTo: 'active')
      .where('searchPrefixes', arrayContains: p)
      .limit(50) // fetch a few more then filter
      .get();

  final set = <String>{};
  for (final d in snap.docs) {
    final m = d.data();
    // 🚫 Skip my own gigs for suggestions too
    if (myUid != null && (m['providerId'] ?? '') == myUid) continue;

    if (m['title'] is String) set.add((m['title'] as String).trim());
    if (m['category'] is String) set.add((m['category'] as String).trim());
    if (m['services'] is List) {
      for (final s in (m['services'] as List)) {
        if (s is String && s.trim().isNotEmpty) set.add(s.trim());
      }
    }
  }
  // Rank by contains ordering: starts-with first
  final starts = set.where((s) => s.toLowerCase().startsWith(p)).toList();
  final contains = set.where((s) => !s.toLowerCase().startsWith(p)).toList();
  return [...starts, ...contains].take(limit).toList();
}

/* ── Search entry page (tab with bottom nav) ────── */
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _focus = FocusNode();

  final List<_Category> _categories = const [
    _Category('AC Repair', Icons.ac_unit, _pastelPeach),
    _Category('Appliance', Icons.kitchen, _pastelBlue),
    _Category('Painting', Icons.format_paint, _pastelorange),
    _Category('Cleaning', Icons.cleaning_services, _pastelYellow),
    _Category('Plumbing', Icons.plumbing, _pastelGreen),
    _Category('Electretion', Icons.electrical_services, _pastelPink),

    // New categories
    _Category('Driver', Icons.directions_car_filled_rounded, _pastelgrey),
    _Category('Consultation', Icons.support_agent_rounded, _pastelbrown),
    _Category('Free Lancing', Icons.laptop_mac_rounded, _pastelpurple),
  ];

  bool _showOverlay = false;
  List<String> _recent = [];
  final List<String> _popular = const [
    'Home Cleaning',
    'Plumbing Repair',
    'AC Installation',
    'Electrical Wiring',
    'Car Wash',
    'Painting'
  ];

  String _suggestQuery = '';
  Future<List<String>>? _suggestFuture;

  @override
  void initState() {
    super.initState();
    _loadRecent();
    _focus.addListener(() {
      if (_focus.hasFocus) {
        setState(() => _showOverlay = true);
      } else {
        setState(() => _showOverlay = false);
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _recent = p.getStringList(kRecentSearchesKey) ?? [];
    });
  }

  Future<void> _pushRecent(String term) async {
    final t = term.trim();
    if (t.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(kRecentSearchesKey) ?? [];
    list.removeWhere((e) => e.toLowerCase() == t.toLowerCase());
    list.insert(0, t);
    if (list.length > 10) list.removeRange(10, list.length);
    await p.setStringList(kRecentSearchesKey, list);
    setState(() => _recent = list);
  }

  Future<void> _removeRecent(String term) async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(kRecentSearchesKey) ?? [];
    list.removeWhere((e) => e.toLowerCase() == term.toLowerCase());
    await p.setStringList(kRecentSearchesKey, list);
    setState(() => _recent = list);
  }

  void _openResults(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    await _pushRecent(q);
    if (!mounted) return;
    // Push full results (bottom nav disappears there).
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchResultsPage(initialQuery: q),
      ),
    );
  }

  void _onBackTap() {
    // Return to All Categories state without popping the tab.
    _search.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _showOverlay = false;
      _suggestQuery = '';
      _suggestFuture = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    const pageBg = Colors.white;
    const card = Colors.white;
    const text = Color(0xFF1B1C20);
    const hint = Color(0xFF8D91A1);

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: _accent,
        elevation: 0,
        title: const Text(
          'Search',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            // Search bar row
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x11000000)),
                      ),
                      child: Row(
                        children: [
                          InkWell(
                            onTap: _onBackTap,
                            borderRadius: BorderRadius.circular(12),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 10),
                              child: Icon(
                                Icons.arrow_back_ios_new_rounded,
                                size: 18,
                              ),
                            ),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _search,
                              focusNode: _focus,
                              textInputAction: TextInputAction.search,
                              onSubmitted: _openResults,
                              onChanged: (v) {
                                final p = v.trim();
                                setState(() {
                                  _suggestQuery = p;
                                  _suggestFuture =
                                  p.isEmpty ? null : _suggest(p, limit: 8);
                                });
                              },
                              style:
                              const TextStyle(color: text, fontSize: 15),
                              decoration: const InputDecoration(
                                hintText: 'Search Category',
                                hintStyle:
                                TextStyle(color: hint, fontSize: 15),
                                border: InputBorder.none,
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 44,
                    width: 44,
                    child: Material(
                      color: _accent,
                      borderRadius: BorderRadius.circular(12),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () => _openResults(_search.text),
                        child: const Icon(Icons.search, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Title or overlay title spacing
            SizedBox(height: _showOverlay ? 10 : 26),

            // Either All Categories label + grid, OR overlay with suggestions + recent/popular
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: !_showOverlay
                    ? Column(
                  key: const ValueKey('categories'),
                  children: [
                    const Text(
                      'All Categories',
                      style: TextStyle(
                        color: Color(0xFF1B1C20),
                        fontWeight: FontWeight.w700,
                        fontSize: 18,
                        height: 1.0,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: Padding(
                        padding:
                        const EdgeInsets.symmetric(horizontal: 30),
                        child: GridView.builder(
                          padding: const EdgeInsets.only(
                              top: 4, bottom: 12),
                          physics: const BouncingScrollPhysics(),
                          itemCount: _categories.length,
                          gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            mainAxisSpacing: 10,
                            crossAxisSpacing: 18,
                            mainAxisExtent: 110,
                          ),
                          itemBuilder: (context, i) {
                            final c = _categories[i];
                            return _CategoryTile(
                              category: c,
                              onTap: () => _openResults(c.title),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                )
                    : _RecentPopularOverlay(
                  key: const ValueKey('overlay'),
                  suggestQuery: _suggestQuery,
                  suggestFuture: _suggestFuture,
                  recent: _recent,
                  popular: _popular,
                  onTapTerm: _openResults,
                  onRemoveRecent: _removeRecent,
                  onClearAll: () async {
                    final p = await SharedPreferences.getInstance();
                    await p.remove(kRecentSearchesKey);
                    if (!context.mounted) return;
                    (context as Element).markNeedsBuild();
                    _recent = [];
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ── Overlay with suggestions + recent + popular ─ */
class _RecentPopularOverlay extends StatelessWidget {
  final String suggestQuery;
  final Future<List<String>>? suggestFuture;
  final List<String> recent;
  final List<String> popular;
  final void Function(String term) onTapTerm;
  final void Function(String term) onRemoveRecent;
  final Future<void> Function() onClearAll;

  const _RecentPopularOverlay({
    super.key,
    required this.suggestQuery,
    required this.suggestFuture,
    required this.recent,
    required this.popular,
    required this.onTapTerm,
    required this.onRemoveRecent,
    required this.onClearAll,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        // Live suggestions (if typing)
        if (suggestFuture != null)
          FutureBuilder<List<String>>(
            future: suggestFuture,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              final items = snap.data ?? const <String>[];
              if (items.isEmpty) return const SizedBox.shrink();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _SectionTitle('Suggestions'),
                  const SizedBox(height: 6),
                  ...items.map(
                        (e) => _SuggestionTile(text: e, onTap: () => onTapTerm(e)),
                  ),
                  const SizedBox(height: 16),
                ],
              );
            },
          ),

        // Recent
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const _SectionTitle('Recent searches'),
            if (recent.isNotEmpty)
              TextButton(
                onPressed: onClearAll,
                child: const Text('Clear All'),
              ),
          ],
        ),
        const SizedBox(height: 6),
        if (recent.isEmpty)
          const Text('No recent searches yet.',
              style: TextStyle(color: Colors.black54))
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: recent
                .map(
                  (t) => _PillChip(
                label: t,
                onTap: () => onTapTerm(t),
                onDelete: () => onRemoveRecent(t),
              ),
            )
                .toList(),
          ),
        const SizedBox(height: 18),

        // Popular
        const _SectionTitle('Popular searches'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: popular
              .map((t) => _PillChip(label: t, onTap: () => onTapTerm(t)))
              .toList(),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
    );
  }
}

class _PillChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _PillChip({
    super.key,
    required this.label,
    required this.onTap,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InputChip(
      label: Padding(
        padding: const EdgeInsets.only(bottom: 2), // avoid bottom cut look
        child: Text(label),
      ),
      onPressed: onTap,
      onDeleted: onDelete,
      deleteIcon:
      onDelete != null ? const Icon(Icons.close, size: 16) : null,
      backgroundColor: const Color(0xFFF3F4F8),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: const VisualDensity(horizontal: -2, vertical: -2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _SuggestionTile({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.search, color: Colors.black45),
      title: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}

/* ── Results page (pushed; bottom nav hidden) ─── */
class SearchResultsPage extends StatefulWidget {
  final String initialQuery;
  const SearchResultsPage({required this.initialQuery});

  @override
  State<SearchResultsPage> createState() => _SearchResultsPageState();
}

class _SearchResultsPageState extends State<SearchResultsPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _loading = false;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = [];

  // Filters (client-side for now)
  double? _minPrice;
  double? _maxPrice;
  double? _minRating;
  bool _nearMe = false;
  String? _category;

  // Categories to choose from
  List<String> _allCategories = [];

  // ❤️ Favorites live map + optimistic overrides
  StreamSubscription<QuerySnapshot>? _favSub;
  final Map<String, String> _favByGig = {}; // gigId -> favDocId
  final Map<String, bool> _optimisticFav = {}; // gigId -> override state

  // 👇 Results-page suggestions
  String _suggestQuery = '';
  Future<List<String>>? _suggestFuture;
  bool get _showSuggest => _focus.hasFocus && _suggestQuery.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _controller.text = widget.initialQuery;
    _run(widget.initialQuery);
    _attachFavListener();
    _loadAllCategories();

    _focus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _favSub?.cancel();
    super.dispose();
  }

  Future<void> _run(String raw) async {
    setState(() => _loading = true);
    final res = await _queryGigs(raw);
    if (!mounted) return;
    setState(() {
      _docs = res;
      _loading = false;
    });
    _saveRecent(raw);
  }

  Future<void> _saveRecent(String raw) async {
    final t = raw.trim();
    if (t.isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList(kRecentSearchesKey) ?? [];
    list.removeWhere((e) => e.toLowerCase() == t.toLowerCase());
    list.insert(0, t);
    if (list.length > 10) list.removeRange(10, list.length);
    await p.setStringList(kRecentSearchesKey, list);
  }

  void _onPickSuggestion(String term) {
    _controller.text = term;
    _focus.unfocus();
    setState(() {
      _suggestQuery = '';
      _suggestFuture = null;
    });
    _run(term);
  }

  bool _isFav(String gigId) =>
      _optimisticFav[gigId] ?? _favByGig.containsKey(gigId);

  void _attachFavListener() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    _favSub = FirebaseFirestore.instance
        .collection('favourites')
        .where('userId', isEqualTo: uid)
        .snapshots()
        .listen((snap) {
      _favByGig.clear();
      for (final d in snap.docs) {
        final m = (d.data() as Map<String, dynamic>? ?? {});
        final gid = (m['gigId'] ?? '').toString();
        if (gid.isNotEmpty) _favByGig[gid] = d.id;
      }
      setState(() {
        // Let server truth win once it arrives
        _optimisticFav.removeWhere((_, __) => true);
      });
    });
  }

  Future<void> _toggleFav(String gigId, Map<String, dynamic> gigData) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final makeFav = !_isFav(gigId);
    setState(() => _optimisticFav[gigId] = makeFav);

    try {
      if (makeFav) {
        // Add
        final imageB64s =
            (gigData['photosB64'] as List?)?.cast<String>() ?? const <String>[];
        final images =
            (gigData['photos'] as List?)?.cast<String>() ?? const <String>[];
        await FirebaseFirestore.instance.collection('favourites').add({
          'userId': uid,
          'gigId': gigId,
          'title': (gigData['title'] ?? '').toString(),
          'imageUrl': images.isNotEmpty ? images.first : '',
          'imageB64': imageB64s.isNotEmpty ? imageB64s.first : '',
          'ratingAvg': (gigData['ratingAvg'] is num)
              ? (gigData['ratingAvg'] as num).toDouble()
              : 0.0,
          'ratingCount': (gigData['ratingCount'] is num)
              ? (gigData['ratingCount'] as num).toInt()
              : 0,
          'category': (gigData['category'] ?? '').toString(),
          'providerName': (gigData['providerName'] ?? '').toString(),
          'price': gigData['price'],
          'createdAt': FieldValue.serverTimestamp(),
        });
      } else {
        // Remove
        final favId = _favByGig[gigId];
        if (favId != null) {
          await FirebaseFirestore.instance
              .collection('favourites')
              .doc(favId)
              .delete();
        } else {
          final q = await FirebaseFirestore.instance
              .collection('favourites')
              .where('userId', isEqualTo: uid)
              .where('gigId', isEqualTo: gigId)
              .limit(1)
              .get();
          for (final d in q.docs) {
            await d.reference.delete();
          }
        }
      }
    } catch (e) {
      // rollback optimistic if failed
      setState(() => _optimisticFav[gigId] = !makeFav);
      debugPrint('Fav toggle failed: $e');
    }
  }

  Future<void> _loadAllCategories() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('gigs')
          .where('status', isEqualTo: 'active')
          .limit(200)
          .get();
      final set = <String>{};
      for (final d in snap.docs) {
        final c = (d.data()['category'] ?? '').toString().trim();
        if (c.isNotEmpty) set.add(c);
      }
      setState(() => _allCategories = set.toList()..sort());
    } catch (e) {
      debugPrint('Load categories failed: $e');
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _filteredDocs {
    return _docs.where((d) {
      final m = d.data();
      // price
      final price =
      (m['price'] is num) ? (m['price'] as num).toDouble() : null;
      if (_minPrice != null && (price == null || price < _minPrice!)) {
        return false;
      }
      if (_maxPrice != null && (price == null || price > _maxPrice!)) {
        return false;
      }
      // rating (uses gig doc field for filtering only; display uses live reviews)
      final r = (m['ratingAvg'] is num)
          ? (m['ratingAvg'] as num).toDouble()
          : 0.0;
      if (_minRating != null && r < _minRating!) return false;
      // category
      final cat = (m['category'] ?? '').toString();
      if (_category != null && _category!.isNotEmpty && cat != _category) {
        return false;
      }
      // near me (placeholder; just let it pass for now)
      return true;
    }).toList();
  }

  // ── Filter sheets (each chip) ──────────────────────────────────────────────
  Future<void> _openPriceFilter() async {
    final minCtl =
    TextEditingController(text: _minPrice?.round().toString() ?? '');
    final maxCtl =
    TextEditingController(text: _maxPrice?.round().toString() ?? '');
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SheetHandle(title: 'Price'),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: minCtl,
                        keyboardType: TextInputType.number,
                        decoration:
                        const InputDecoration(labelText: 'Min'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: maxCtl,
                        keyboardType: TextInputType.number,
                        decoration:
                        const InputDecoration(labelText: 'Max'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      setState(() {
                        _minPrice = double.tryParse(minCtl.text.trim());
                        _maxPrice = double.tryParse(maxCtl.text.trim());
                      });
                      Navigator.pop(context);
                    },
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openRatingFilter() async {
    double tmp = _minRating ?? 0.0;
    await showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _SheetHandle(title: 'Minimum rating'),
              const SizedBox(height: 10),
              StatefulBuilder(
                builder: (_, setSB) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (i) {
                    final filled = i < (tmp.round());
                    return IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(
                          width: 40, height: 40),
                      onPressed: () =>
                          setSB(() => tmp = (i + 1).toDouble()),
                      icon: Icon(
                        filled
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: const Color(0xFFFFB21D),
                      ),
                    );
                  }),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    setState(() => _minRating = tmp <= 0 ? null : tmp);
                    Navigator.pop(context);
                  },
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openCategoryFilter() async {
    await showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: SizedBox(
            height: 360,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _SheetHandle(title: 'Categories'),
                const SizedBox(height: 8),
                Expanded(
                  child: _allCategories.isEmpty
                      ? const Center(
                      child: CircularProgressIndicator())
                      : ListView.separated(
                    itemCount: _allCategories.length,
                    separatorBuilder: (_, __) =>
                    const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final c = _allCategories[i];
                      final selected = _category == c;
                      return ListTile(
                        title: Text(c),
                        trailing: selected
                            ? const Icon(Icons.check,
                            color: _accent)
                            : null,
                        onTap: () {
                          setState(() =>
                          _category = selected ? null : c);
                          Navigator.pop(context);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openNearMe() async {
    // Placeholder UX, just toggles for now.
    setState(() => _nearMe = !_nearMe);
  }

  Future<void> _openAllFilters() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 12,
            bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _SheetHandle(title: 'Filters'),
                const SizedBox(height: 10),
                // Quick summary chips inside full sheet too
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _FilterChip(
                      label: _minPrice == null && _maxPrice == null
                          ? 'Price'
                          : 'Price ${_minPrice?.round() ?? 0} - ${_maxPrice?.round() ?? '∞'}',
                      onTap: _openPriceFilter,
                    ),
                    _FilterChip(
                      label: _minRating == null
                          ? 'Ratings'
                          : '≥ ${_minRating!.toStringAsFixed(0)}★',
                      onTap: _openRatingFilter,
                    ),
                    _FilterChip(
                      label: _nearMe ? 'Near me ✓' : 'Near me',
                      onTap: _openNearMe,
                    ),
                    _FilterChip(
                      label:
                      _category == null ? 'Categories' : _category!,
                      onTap: _openCategoryFilter,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () {
                      setState(() {
                        _minPrice = null;
                        _maxPrice = null;
                        _minRating = null;
                        _nearMe = false;
                        _category = null;
                      });
                      Navigator.pop(context);
                    },
                    child: const Text('Clear all'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const pageBg = Colors.white;

    // ── CHANGED: horizontally scrollable filter chips (like service types)
    final chips = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _FilterChip(
            label: _minPrice == null && _maxPrice == null
                ? 'Price'
                : 'Price ${_minPrice?.round() ?? 0} - ${_maxPrice?.round() ?? '∞'}',
            onTap: _openPriceFilter,
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: _minRating == null
                ? 'Ratings'
                : '≥ ${_minRating!.toStringAsFixed(0)}★',
            onTap: _openRatingFilter,
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: _nearMe ? 'Near me ✓' : 'Near me',
            onTap: _openNearMe,
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: _category == null ? 'Categories' : _category!,
            onTap: _openCategoryFilter,
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'Filters',
            leading: const Icon(Icons.tune_rounded, size: 16),
            onTap: _openAllFilters,
            strong: true,
          ),
        ],
      ),
    );

    final filtered = _filteredDocs;

    return Scaffold(
      backgroundColor: pageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Container(
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F8),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const SizedBox(width: 10),
              const Icon(Icons.search, color: Colors.black45),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (v) => _run(v),
                  onChanged: (v) {
                    final p = v.trim();
                    setState(() {
                      _suggestQuery = p;
                      _suggestFuture =
                      p.isEmpty ? null : _suggest(p, limit: 8);
                    });
                  },
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Search services',
                  ),
                ),
              ),
              if (_controller.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.black45),
                  onPressed: () {
                    _controller.clear();
                    setState(() {
                      _suggestQuery = '';
                      _suggestFuture = null;
                    });
                  },
                ),
            ],
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune_outlined),
            onPressed: _openAllFilters,
          ),
        ],
      ),
      body: Column(
        children: [
          // 🔎 Suggestions panel under the app bar (when typing)
          if (_showSuggest && _suggestFuture != null)
            FutureBuilder<List<String>>(
              future: _suggestFuture,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const LinearProgressIndicator(minHeight: 2);
                }
                final items = snap.data ?? const <String>[];
                if (items.isEmpty) return const SizedBox.shrink();
                return Container(
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(
                      bottom: BorderSide(color: Color(0x11000000)),
                      top: BorderSide(color: Color(0x11000000)),
                    ),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(
                        height: 1, color: Color(0x11000000)),
                    itemBuilder: (_, i) => _SuggestionTile(
                      text: items[i],
                      onTap: () => _onPickSuggestion(items[i]),
                    ),
                  ),
                );
              },
            ),

          // Filters chips row (horizontal scroll)
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
            child: Align(alignment: Alignment.centerLeft, child: chips),
          ),

          // Results list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : filtered.isEmpty
                ? Center(
              child: Text(
                'No results for “${_controller.text.trim()}”.',
                style: const TextStyle(color: Colors.black54),
              ),
            )
                : ListView.separated(
              padding:
              const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: filtered.length,
              separatorBuilder: (_, __) =>
              const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final doc = filtered[i];
                return _ResultCard(
                  doc: doc,
                  isFav: _isFav(doc.id),
                  onToggleFav: () =>
                      _toggleFav(doc.id, doc.data()),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: _accent,
        onPressed: () {
          // Optional: quick create request
        },
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }
}

/* ── Filter chip widget ────────────────────────────────────────────────────── */

class _FilterChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Widget? leading;
  final bool strong;

  const _FilterChip({
    required this.label,
    required this.onTap,
    this.leading,
    this.strong = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg =
    strong ? const Color(0xFFECE9FF) : const Color(0xFFF3F4F8);
    final fg = strong ? _ink : Colors.black87;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: 6)
              ],
              Padding(
                padding:
                const EdgeInsets.only(bottom: 1), // avoid label bottom cut
                child: Text(
                  label,
                  style: TextStyle(
                    color: fg,
                    fontWeight:
                    strong ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  final String title;
  const _SheetHandle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(title,
              style: const TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 16)),
        ),
      ],
    );
  }
}

/* ── Result card (modern list item) ─────────────── */
class _ResultCard extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final bool isFav;
  final VoidCallback onToggleFav;

  const _ResultCard({
    required this.doc,
    required this.isFav,
    required this.onToggleFav,
  });

  @override
  Widget build(BuildContext context) {
    final m = doc.data();

    final title = (m['title'] ?? 'Untitled').toString();
    final category = (m['category'] ?? '').toString();
    final price = m['price'];
    final photos =
        (m['photosB64'] as List?)?.cast<String>() ?? const <String>[];

    ImageProvider? thumb;
    if (photos.isNotEmpty) {
      try {
        thumb = MemoryImage(base64Decode(photos.first));
      } catch (_) {}
    }

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GigDetailScreen(
              gigId: doc.id,
              data: m, // pass the map you already extracted
            ),
          ),
        );
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE9EAF2)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              // Image
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: thumb != null
                    ? Image(
                  image: thumb,
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                )
                    : Container(
                  width: 80,
                  height: 80,
                  color: const Color(0xFFEDEBFF),
                  child: const Icon(Icons.image_outlined,
                      color: _accent),
                ),
              ),
              const SizedBox(width: 12),

              // Info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── CHANGED: Live ratings from `gig_reviews` (avg + count)
                    StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                      stream: FirebaseFirestore.instance
                          .collection('gig_reviews')
                          .where('gigId', isEqualTo: doc.id)
                          .snapshots(),
                      builder: (_, snap) {
                        double ratingAvg = 0.0;
                        int ratingCount = 0;

                        if (snap.hasData) {
                          final reviews = snap.data!.docs;
                          ratingCount = reviews.length;
                          if (ratingCount > 0) {
                            final total = reviews.fold<double>(
                              0.0,
                                  (sum, d) {
                                final mm = d.data();
                                if (mm['rating'] is num) {
                                  return sum +
                                      (mm['rating'] as num).toDouble();
                                }
                                final b = (mm['behavior'] is num)
                                    ? (mm['behavior'] as num).toDouble()
                                    : 0.0;
                                final q = (mm['quality'] is num)
                                    ? (mm['quality'] as num).toDouble()
                                    : 0.0;
                                return sum + ((b + q) / 2.0);
                              },
                            );
                            ratingAvg = total / ratingCount;
                          }
                        }

                        return Row(
                          children: [
                            const Icon(Icons.star_rounded,
                                color: Color(0xFFFFB21D), size: 18),
                            const SizedBox(width: 4),
                            Text(
                              ratingAvg.toStringAsFixed(1),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(width: 4),
                            Text('($ratingCount)',
                                style: const TextStyle(
                                    color: Colors.black54)),
                            const Spacer(),
                            // ♥️ Heart instead of 3-dots
                            IconButton(
                              icon: Icon(
                                  isFav
                                      ? Icons.favorite
                                      : Icons.favorite_border,
                                  color: _accent),
                              onPressed: onToggleFav,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              tooltip: isFav
                                  ? 'Remove from favourites'
                                  : 'Add to favourites',
                            ),
                          ],
                        );
                      },
                    ),
                    // Title
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15.5),
                    ),
                    const SizedBox(height: 2),
                    // Category
                    Text(
                      category.isEmpty ? '—' : category,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                      const TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 8),
                    // Starts From tag
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE0F6E7),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            price == null
                                ? 'Starts From —'
                                : 'Starts From  PKR $price',
                            style: const TextStyle(
                              color: Color(0xFF0E7D40),
                              fontWeight: FontWeight.w700,
                              fontSize: 12.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ── Categories grid parts ─────────────────────── */
class _Category {
  final String title;
  final IconData icon;
  final Color bg;
  const _Category(this.title, this.icon, this.bg);
}

class _CategoryTile extends StatelessWidget {
  final _Category category;
  final VoidCallback onTap;

  const _CategoryTile({
    required this.category,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const label = Color(0xFF2E2F36);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: category.bg,
              shape: BoxShape.circle,
            ),
            child: Icon(category.icon, size: 26, color: _ink),
          ),
          const SizedBox(height: 8),
          Text(
            category.title,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: label,
              fontWeight: FontWeight.w600,
              fontSize: 13,
              height: 1.15,
            ),
          ),
        ],
      ),
    );
  }
}
