import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// opens gig details on reorder
import 'gig_detail_screen.dart';
// opens live sheet for re-requesting
import 'live_request_sheet.dart';

const _text = Color(0xFF121316);
const _sub = Color(0xFF6C7280);
const _cardBorder = Color(0xFFE8E9EF);
const _pink = Color(0xFF7966FA);
const _orange = Color(0xFFFF7A00);

// App-wide toast palette
const _ok = Color(0xFF17A34A);
const _info = Color(0xFF1677FF);
const _warn = Color(0xFFEF6C00);
const _danger = Color(0xFFD33A4A);

class OrdersHistoryScreen extends StatefulWidget {
  const OrdersHistoryScreen({super.key});

  @override
  State<OrdersHistoryScreen> createState() => _OrdersHistoryScreenState();
}

class _OrdersHistoryScreenState extends State<OrdersHistoryScreen> {
  bool _isClearing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      FocusManager.instance.primaryFocus?.unfocus();
    });
  }

  // ===================== Toasts (Global Pattern) =====================
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

  // ===================== Clear All Logic =====================
  Future<void> _clearAllHistory(String uid) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text(
            'This will permanently remove all orders from your history. This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isClearing = true);

    try {
      final snap = await FirebaseFirestore.instance
          .collection('orders')
          .where('userId', isEqualTo: uid)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
      _toastSuccess('History cleared successfully');
    } catch (e) {
      _toastError('Failed to clear history');
    } finally {
      if (mounted) setState(() => _isClearing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: _text),
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.of(context).maybePop();
          },
        ),
        title: const Text('Orders History', style: TextStyle(color: _text, fontWeight: FontWeight.w800)),
        centerTitle: false,
        actions: [
          if (uid != null)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: _isClearing
                  ? const Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: _sub),
                ),
              )
                  : TextButton(
                onPressed: () => _clearAllHistory(uid),
                child: const Text('Clear All', style: TextStyle(color: _danger, fontWeight: FontWeight.w700)),
              ),
            )
        ],
      ),
      body: SafeArea(
        child: uid == null
            ? const _EmptySimple(text: 'Please log in to see past orders.')
            : _OrdersList(
          uid: uid,
          toastSuccess: _toastSuccess,
          toastError: _toastError,
          toastInfo: _toastInfo,
        ),
      ),
    );
  }
}

/* ------------------------- Orders list ------------------------- */

class _OrdersList extends StatelessWidget {
  final String uid;
  final Function(String) toastSuccess;
  final Function(String) toastError;
  final Function(String) toastInfo;

  const _OrdersList({
    required this.uid,
    required this.toastSuccess,
    required this.toastError,
    required this.toastInfo,
  });

  Stream<QuerySnapshot> _ordersStream() {
    return FirebaseFirestore.instance
        .collection('orders')
        .where('userId', isEqualTo: uid)
        .orderBy('deliveredAt', descending: true)
        .snapshots();
  }

  Future<void> _deleteOrder(String orderId) async {
    try {
      await FirebaseFirestore.instance.collection('orders').doc(orderId).delete();
      toastSuccess('Order removed from history');
    } catch (e) {
      toastError('Failed to remove order');
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: _ordersStream(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _Error(text: 'Error: ${snap.error}');
        }
        final docs = snap.data?.docs ?? [];
        if (docs.isEmpty) {
          return const _EmptyOrders(
            title: 'No past orders yet',
            subtitle: 'When you complete a service, it will show up here.',
            buttonLabel: 'Request now',
          );
        }

        return ListView.separated(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          itemCount: docs.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 12),
          itemBuilder: (context, i) {
            if (i == 0) {
              return const Padding(
                padding: EdgeInsets.only(bottom: 8, top: 4),
                child: Text('Past orders',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _text)),
              );
            }
            final doc = docs[i - 1];
            final o = _Order.from(doc);

            // Wrap card in Dismissible for slide-to-delete
            return Dismissible(
              key: Key(o.id),
              direction: DismissDirection.endToStart,
              background: Container(
                decoration: BoxDecoration(
                  color: _danger,
                  borderRadius: BorderRadius.circular(14),
                ),
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: const Icon(Icons.delete_outline_rounded, color: Colors.white, size: 28),
              ),
              confirmDismiss: (direction) async {
                return await showDialog(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Delete from history?'),
                    content: const Text('This will remove this item from your history.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancel'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _danger),
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Delete'),
                      ),
                    ],
                  ),
                );
              },
              onDismissed: (direction) {
                _deleteOrder(o.id);
              },
              child: _OrderCard(
                order: o,
                toastSuccess: toastSuccess,
                toastError: toastError,
                toastInfo: toastInfo,
              ),
            );
          },
        );
      },
    );
  }
}

/* ------------------------- Order Card ------------------------- */

class _OrderCard extends StatelessWidget {
  final _Order order;
  final Function(String) toastSuccess;
  final Function(String) toastError;
  final Function(String) toastInfo;

  const _OrderCard({
    required this.order,
    required this.toastSuccess,
    required this.toastError,
    required this.toastInfo,
  });

  String _fmtMoney(num? v) {
    if (v == null) return '—';
    final f = NumberFormat.currency(locale: 'en_PK', symbol: 'Rs. ', decimalDigits: 0);
    return f.format(v);
  }

  String _fmtDelivered(DateTime? dt) {
    if (dt == null) return '—';
    final day = DateFormat('d MMM').format(dt);
    final time = DateFormat('HH:mm').format(dt);
    return 'Completed On $day, $time';
  }

  String _fmtRateBy(DateTime? delivered) {
    final due = (delivered ?? DateTime.now()).add(const Duration(days: 7));
    return DateFormat("dd MMM yyyy").format(due);
  }

  // --- ACTIONS ---

  Future<void> _openGig(BuildContext context) async {
    if (order.gigId == null || order.gigId!.isEmpty) {
      toastInfo('This order has no linked service');
      return;
    }

    final data = <String, dynamic>{
      'providerId': order.providerId ?? '',
      'title': order.serviceTitle.isEmpty ? 'Service' : order.serviceTitle,
      'category': order.category ?? 'General',
      'price': order.total ?? order.price,
      'phone': order.providerPhone ?? '',
      'profileB64': order.imageB64 ?? '',
      'description': '',
    };

    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GigDetailScreen(gigId: order.gigId!, data: data),
    ));
  }

  Future<void> _requestLiveAgain(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) {
          // Assuming LiveRequestSheet handles its own UI inside a scaffold/container
          return const LiveRequestSheet();
        },
      ),
    );
  }

  Future<void> _rate(BuildContext context) async {
    int stars = order.rating?.round() ?? 0;
    final ctl = TextEditingController(text: order.review ?? '');

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final pad = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + pad),
          child: StatefulBuilder(
            builder: (ctx, setSB) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(4))),
                const SizedBox(height: 12),

                // Header showing Provider Name and Job
                Text('Rate ${order.providerName}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 4),
                Text('for ${order.serviceTitle}',
                  style: const TextStyle(color: _sub, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),

                // Selectable Stars
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (i) {
                    final filled = i < stars;
                    return IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
                      onPressed: () => setSB(() => stars = i + 1),
                      icon: Icon(filled ? Icons.star_rounded : Icons.star_border_rounded,
                          color: filled ? _orange : Colors.black26, size: 32),
                    );
                  }),
                ),

                const SizedBox(height: 10),
                TextField(
                  controller: ctl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    hintText: 'Add a comment (optional)',
                    filled: true,
                    fillColor: Color(0xFFF6F7FB),
                    border: OutlineInputBorder(borderSide: BorderSide.none, borderRadius: BorderRadius.all(Radius.circular(12))),
                    contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('Later', style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: _pink),
                        onPressed: stars == 0 ? null : () async {
                          try {
                            // Update the Order history doc
                            await FirebaseFirestore.instance.collection('orders').doc(order.id).set({
                              'rating': stars.toDouble(),
                              'review': ctl.text.trim(),
                              'ratedAt': FieldValue.serverTimestamp(),
                              'rated': true,
                            }, SetOptions(merge: true));

                            // Also add to public reviews collection
                            if (order.providerId != null) {
                              await FirebaseFirestore.instance.collection('gig_reviews').add({
                                'providerId': order.providerId,
                                'seekerId': FirebaseAuth.instance.currentUser?.uid,
                                'authorName': 'Seeker', // Ideally fetch current user name
                                'rating': stars.toDouble(),
                                'review': ctl.text.trim(),
                                'gigTitle': order.serviceTitle,
                                'createdAt': FieldValue.serverTimestamp(),
                              });
                            }

                            if (context.mounted) {
                              Navigator.pop(ctx);
                              toastSuccess('Thanks! Rating added');
                            }
                          } catch (e) {
                            toastError('Could not save rating');
                          }
                        },
                        child: const Text('Submit', style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final delivered = order.deliveredAt;
    final rated = (order.rating ?? 0) > 0;
    final isLive = order.isLiveRequest;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // HEADER: left info + right price
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SquareThumb(imageUrl: order.imageUrl, imageB64: order.imageB64, isLive: isLive),
                const SizedBox(width: 12),

                // LEFT info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // TITLE ROW with Live Badge if needed
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              order.serviceTitle.isEmpty ? 'Service' : order.serviceTitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: _text),
                            ),
                          ),
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
                          ]
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(_fmtDelivered(delivered), style: const TextStyle(color: _sub, fontSize: 13)),
                      const SizedBox(height: 2),
                      // Provider name
                      Text(
                        order.providerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _text, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 8),
                // Price on right
                Text(_fmtMoney(order.total),
                    style: const TextStyle(fontWeight: FontWeight.w800, color: _text)),
              ],
            ),

            const SizedBox(height: 12),

            // BUTTON: Logic changes based on Live vs Gig
            SizedBox(
              width: double.infinity,
              height: 44,
              child: isLive
                  ? OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _pink,
                  side: const BorderSide(color: _pink),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.bolt_rounded, size: 18),
                label: const Text('Request Live Again', style: TextStyle(fontWeight: FontWeight.w800)),
                onPressed: () => _requestLiveAgain(context),
              )
                  : ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _pink,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () => _openGig(context),
                child: const Text(
                  'Request Service Again',
                  style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
            ),

            // Divider only ABOVE the rating block
            const SizedBox(height: 10),
            const Divider(height: 1, color: _cardBorder),
            const SizedBox(height: 10),

            // Rating block
            if (rated) ...[
              Row(
                children: [
                  const Text('You rated this', style: TextStyle(color: _sub)),
                  const SizedBox(width: 6),
                  const Icon(Icons.star_rounded, color: _orange, size: 18),
                  const SizedBox(width: 4),
                  Text('${order.rating!.toStringAsFixed(1)}',
                      style: const TextStyle(fontWeight: FontWeight.w800, color: _text)),
                ],
              ),
            ] else ...[
              // "Tap to rate"
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Tap to rate', style: TextStyle(color: _sub)),
                        const SizedBox(height: 2),
                        Text('by ${_fmtRateBy(delivered)}',
                            style: const TextStyle(color: _sub, fontSize: 12.5)),
                      ],
                    ),
                  ),
                  // Stars
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(5, (i) {
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _rate(context),
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 2),
                          child: Icon(Icons.star_border_rounded, color: _orange, size: 20),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/* ------------------------- Thumb ------------------------- */

class _SquareThumb extends StatelessWidget {
  final String? imageUrl;
  final String? imageB64;
  final bool isLive;
  const _SquareThumb({this.imageUrl, this.imageB64, this.isLive = false});

  @override
  Widget build(BuildContext context) {
    ImageProvider? img;
    if (imageB64 != null && imageB64!.isNotEmpty) {
      try {
        img = MemoryImage(base64Decode(imageB64!));
      } catch (_) {}
    }
    if (img == null && imageUrl != null && imageUrl!.isNotEmpty) {
      img = NetworkImage(imageUrl!);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 64,
        height: 64,
        color: const Color(0xFFF2F2F6),
        child: img == null
        // If no image, show generic icon (Bolt for live, Image for gig)
            ? Center(child: Icon(isLive ? Icons.bolt_rounded : Icons.image_outlined, color: _sub, size: 28))
            : Image(image: img, fit: BoxFit.cover),
      ),
    );
  }
}

/* ------------------------- Model ------------------------- */

class _Order {
  final String id;

  // display
  final String providerName;
  final String serviceTitle;
  final String? category;

  final num? price;
  final num? total;
  final DateTime? deliveredAt;

  final double? rating;
  final String? review;

  final String? imageUrl;
  final String? imageB64;

  // for navigation
  final String? gigId;
  final String? providerId;
  final String? providerPhone;
  final bool isLiveRequest; // NEW

  _Order({
    required this.id,
    required this.providerName,
    required this.serviceTitle,
    required this.total,
    required this.deliveredAt,
    required this.rating,
    required this.review,
    this.category,
    this.price,
    this.imageUrl,
    this.imageB64,
    this.gigId,
    this.providerId,
    this.providerPhone,
    this.isLiveRequest = false,
  });

  static _Order from(DocumentSnapshot d) {
    final m = (d.data() as Map<String, dynamic>? ?? {});

    // time
    DateTime? dt;
    final ra = m['deliveredAt'];
    if (ra is Timestamp) dt = ra.toDate();
    if (ra is DateTime) dt = ra;

    // provider
    final provider = (m['providerName'] ??
        m['provider'] ??
        m['vendorName'] ??
        m['outlet'] ??
        'Provider')
        .toString();

    // service/gig title
    final service = (m['gigTitle'] ?? m['serviceTitle'] ?? m['title'] ?? '').toString();

    // prefer gig/service image
    final b64 = (m['gigImageB64'] ??
        m['thumbnailB64'] ??
        m['imageB64'] ??
        m['profileB64'] ??
        '')
        .toString();
    final url = (m['gigImageUrl'] ?? m['thumbUrl'] ?? m['imageUrl'] ?? '').toString();

    return _Order(
      id: d.id,
      providerName: provider,
      serviceTitle: service,
      category: (m['category'] ?? m['gigCategory'] ?? '').toString(),
      price: (m['price'] as num?),
      total: (m['total'] ?? m['amount'] ?? m['price']) as num?,
      deliveredAt: dt,
      rating: (m['rating'] is num) ? (m['rating'] as num).toDouble() : null,
      review: (m['review'] ?? '').toString().isEmpty ? null : (m['review'] as String),
      imageUrl: url.isNotEmpty ? url : null,
      imageB64: b64.isNotEmpty ? b64 : null,
      gigId: (m['gigId'] ?? '').toString().isEmpty ? null : (m['gigId'] as String),
      providerId: (m['providerId'] ?? '').toString().isEmpty ? null : (m['providerId'] as String),
      providerPhone: (m['providerPhone'] ?? '').toString().isEmpty ? null : (m['providerPhone'] as String),
      isLiveRequest: (m['isLiveRequest'] == true),
    );
  }
}

/* ------------------------- Empty / Error ------------------------- */

class _EmptyOrders extends StatelessWidget {
  final String title;
  final String subtitle;
  final String buttonLabel;
  const _EmptyOrders({
    required this.title,
    required this.subtitle,
    required this.buttonLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 40, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 86,
              height: 86,
              decoration: BoxDecoration(
                color: const Color(0xFFF6F7FB),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _cardBorder),
              ),
              child: const Center(
                child: Icon(Icons.shopping_bag_outlined, color: _sub, size: 40),
              ),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _text),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _sub, height: 1.35),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 44,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _pink,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 0,
                ),
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  Navigator.of(context).maybePop();
                },
                child: Text(
                  buttonLabel,
                  style: const TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptySimple extends StatelessWidget {
  final String text;
  const _EmptySimple({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(text, style: const TextStyle(color: _sub)),
    );
  }
}

class _Error extends StatelessWidget {
  final String text;
  const _Error({required this.text});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(text, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
      ),
    );
  }
}