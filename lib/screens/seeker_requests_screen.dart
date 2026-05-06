// lib/screens/seeker_requests_screen.dart
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'chat_list_screen.dart';

// Map + distance math for live tracking
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';

// open gig details on tap
import 'gig_detail_screen.dart';
// reuse hire address flow for editing
import 'hire_address_screen.dart';

const _accent = Color(0xFF7966FA);
const _text = Color(0xFF121316);
const _sub = Color(0xFF6C7280);

// App-wide toast palette (align with your Edit Profile screen)
const _ok = Color(0xFF17A34A);
const _info = Color(0xFF1677FF);
const _warn = Color(0xFFEF6C00);
const _danger = Color(0xFFD33A4A);

// NEW: add Not Completed bucket
enum _Bucket { all, pending, accepted, enroute, not_completed, cancelled, declined, completed }

class SeekerRequestsScreen extends StatefulWidget {
  final bool showSuccess;
  final String successTitle;
  final String successSubtitle;

  const SeekerRequestsScreen({
    super.key,
    this.showSuccess = false,
    this.successTitle = 'Request sent!',
    this.successSubtitle = 'We\'ve notified the provider. You can track status here.',
  });

  @override
  State<SeekerRequestsScreen> createState() => _SeekerRequestsScreenState();
}

class _SeekerRequestsScreenState extends State<SeekerRequestsScreen> {
  _Bucket _selected = _Bucket.all;

  /* ---------------- Toasts (standard SnackBars) ---------------- */

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

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    final bottomPad =
        MediaQuery.of(context).padding.bottom + kBottomNavigationBarHeight + 12;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: _accent,
        elevation: 0,
        title: const Text(
          'My Request',
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
        child: uid == null
            ? const Center(child: Text('Please log in'))
            : Column(
          children: [
            if (widget.showSuccess) const SizedBox(height: 10),
            if (widget.showSuccess)
              _SuccessBanner(
                title: widget.successTitle,
                subtitle: widget.successSubtitle,
              ),
            const SizedBox(height: 8),
            _CategoryChips(
              selected: _selected,
              onChanged: (b) => setState(() => _selected = b),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('service_requests')
                    .where('seekerId', isEqualTo: uid)
                    .orderBy('createdAt', descending: true)
                    .snapshots(),
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(child: Text('Error: ${snap.error}'));
                  }
                  final all = snap.data?.docs ?? [];
                  if (all.isEmpty) {
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No requests yet. Hire a provider from Search or Home.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: _sub),
                        ),
                      ),
                    );
                  }

                  // Filter by bucket
                  List<QueryDocumentSnapshot> filtered = all.where((d) {
                    final s = (d.get('status') ?? 'pending').toString();
                    switch (_selected) {
                      case _Bucket.all:
                        return true;
                      case _Bucket.pending:
                        return s == 'pending';
                      case _Bucket.accepted:
                        return s == 'accepted';
                      case _Bucket.enroute:
                        return s == 'enroute';
                      case _Bucket.not_completed:
                        return s == 'not_completed';
                      case _Bucket.cancelled:
                        return s == 'cancelled';
                      case _Bucket.declined:
                        return s == 'declined';
                      case _Bucket.completed:
                        return s == 'completed';
                    }
                  }).toList();

                  // Bring enroute to top in "All"
                  if (_selected == _Bucket.all) {
                    filtered.sort((a, b) {
                      final sa = (a.get('status') ?? '').toString();
                      final sb = (b.get('status') ?? '').toString();
                      final pa = sa == 'enroute' ? 0 : 1;
                      final pb = sb == 'enroute' ? 0 : 1;
                      if (pa != pb) return pa.compareTo(pb);
                      final ta = a.get('createdAt');
                      final tb = b.get('createdAt');
                      final da = ta is Timestamp ? ta.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                      final db = tb is Timestamp ? tb.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
                      return db.compareTo(da);
                    });
                  }

                  return ListView.separated(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final m = filtered[i].data() as Map<String, dynamic>;
                      final id = filtered[i].id;

                      return _DismissibleWrapper(
                        id: id,
                        data: m,
                        onArchiveCompleted: () => _archiveTerminal(context, id, m, reason: 'Saved in Orders'),
                        toastSuccess: _toastSuccess,
                        toastInfo: _toastInfo,
                        toastError: _toastError,
                        child: _RequestCard(
                          id: id,
                          data: m,
                          onEditAddress: () => _editAddressFlow(context, id, m),
                          onRateNow: () => _rateNowSheet(context, id, m),
                          onRateLater: () => _archiveTerminal(context, id, m, reason: 'Saved in Orders'),
                          // LIVE tracking (enroute) -> full-screen page
                          onTrack: () => _openTrackPage(id, m),
                          toastSuccess: _toastSuccess,
                          toastInfo: _toastInfo,
                          toastError: _toastError,
                          currentUserId: uid,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /* ---------------- Utilities: move completed request -> orders ---------------- */

  Future<void> _moveToOrdersFromRequest(
      String reqId,
      Map<String, dynamic> data, {
        double? rating,
        String? reviewText,
      }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // deliveredAt = provider's completedAt if present; else now
    DateTime delivered = DateTime.now();
    final completedAt = data['completedAt'];
    if (completedAt is Timestamp) delivered = completedAt.toDate();
    if (completedAt is DateTime) delivered = completedAt;

    final deadline = delivered.add(const Duration(days: 14));

    final order = <String, dynamic>{
      'userId': uid,
      'requestId': reqId,
      'gigId': (data['gigId'] ?? '').toString(),
      'providerId': (data['providerId'] ?? '').toString(),
      'providerName': (data['providerName'] ?? 'Provider').toString(),
      'title': (data['gigTitle'] ?? data['title'] ?? 'Service').toString(),
      'category': (data['gigCategory'] ?? data['category'] ?? '').toString(),
      'price': data['gigPrice'] ?? data['budget'] ?? data['amount'],
      'thumbnailB64': (data['profileB64'] ?? '').toString(),
      'deliveredAt': Timestamp.fromDate(delivered),
      'ratingDueAt': Timestamp.fromDate(deadline),
      'rated': rating != null,
      if (rating != null) 'rating': rating,
      if (reviewText != null && reviewText.trim().isNotEmpty) 'review': reviewText.trim(),
      'createdAt': FieldValue.serverTimestamp(),
    };

    // Use request id as order id to avoid duplicates; merge allows later rating updates.
    await FirebaseFirestore.instance.collection('orders').doc(reqId).set(order, SetOptions(merge: true));
  }

  /* ---------------- Address edit (PENDING only) ---------------- */
  Future<void> _editAddressFlow(BuildContext context, String id, Map<String, dynamic> data) async {
    final status = (data['status'] ?? '').toString();
    if (status != 'pending') {
      _toastInfo('Can only edit while pending');
      return;
    }

    final result = await Navigator.push<HireAddressResult>(
      context,
      MaterialPageRoute(builder: (_) => const HireAddressScreen()),
    );

    if (result == null) return;

    try {
      await FirebaseFirestore.instance.collection('service_requests').doc(id).update({
        'label': result.label,
        'address': result.address,
        'phone': result.phone,
        'visitType': result.visitType,
        'lat': result.lat,
        'lng': result.lng,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      _toastSuccess('Address changed. We\'ll notify the provider');
    } catch (e) {
      _toastError('Update failed');
    }
  }

  /* ---------------- Rating flow (COMPLETED) ---------------- */
  Future<void> _rateNowSheet(BuildContext context, String id, Map<String, dynamic> data) async {
    final s = (data['status'] ?? '').toString();
    if (s != 'completed') {
      _toastInfo('Rate after the job is completed');
      return;
    }

    int behavior = 5;
    int quality = 5;
    final reviewCtl = TextEditingController();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        final viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 16 + viewInsets),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(4))),
              const SizedBox(height: 12),
              const Text('Rate your experience', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('How was the service?', style: TextStyle(color: _sub)),
              const SizedBox(height: 12),
              StatefulBuilder(
                builder: (ctx, setSB) => Column(
                  children: [
                    _MiniStarPicker(label: 'Worker behaviour', value: behavior, onChanged: (v) => setSB(() => behavior = v)),
                    const SizedBox(height: 8),
                    _MiniStarPicker(label: 'Quality of work', value: quality, onChanged: (v) => setSB(() => quality = v)),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              TextField(controller: reviewCtl, maxLines: 3, decoration: _input('Leave a review (optional)')),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await _archiveTerminal(context, id, data, reason: 'Saved in Orders');
                      },
                      child: const Text('Later', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: _accent),
                      onPressed: () async {
                        try {
                          final uid = FirebaseAuth.instance.currentUser?.uid;
                          if (uid == null) {
                            _toastError('Please log in');
                            return;
                          }

                          String authorName = '';
                          try {
                            final udoc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
                            final um = udoc.data() ?? {};
                            authorName = (um['display_name'] ?? um['name'] ?? '').toString();
                          } catch (_) {}

                          final overall = (behavior + quality) / 2.0;

                          final review = {
                            'requestId': id,
                            'gigId': (data['gigId'] ?? '').toString(),
                            'providerId': (data['providerId'] ?? '').toString(),
                            'seekerId': uid,
                            'authorId': uid,
                            if (authorName.isNotEmpty) 'authorName': authorName,
                            'behavior': behavior,
                            'quality': quality,
                            'rating': overall,
                            'review': reviewCtl.text.trim(),
                            'createdAt': FieldValue.serverTimestamp(),
                          };

                          await FirebaseFirestore.instance.collection('gig_reviews').add(review);
                          await _moveToOrdersFromRequest(id, data, rating: overall, reviewText: reviewCtl.text.trim());
                          await FirebaseFirestore.instance.collection('service_requests').doc(id).delete();

                          if (!mounted) return;
                          _toastSuccess('Review submitted. Saved in Orders');
                        } catch (_) {
                          _toastError('Could not submit review');
                        }
                      },
                      child: const Text('Submit', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _archiveTerminal(BuildContext context, String id, Map<String, dynamic> data, {String? reason}) async {
    try {
      final s = (data['status'] ?? '').toString();
      if (s == 'completed') {
        await _moveToOrdersFromRequest(id, data);
        await FirebaseFirestore.instance.collection('service_requests').doc(id).delete();
        _toastSuccess(reason ?? 'Saved in Orders');
        return;
      }
      if (!(s == 'cancelled' || s == 'declined' || s == 'completed' || s == 'not_completed')) {
        _toastInfo('This request is still active');
        return;
      }
      await FirebaseFirestore.instance.collection('service_requests').doc(id).delete();
      _toastSuccess(reason ?? 'Removed');
    } catch (_) {
      _toastError('Action failed');
    }
  }

  /* ---------------- LIVE TRACK PAGE (full screen) ---------------- */

  void _openTrackPage(String requestId, Map<String, dynamic> data) {
    if (FirebaseAuth.instance.currentUser == null) {
      _toastInfo('Please log in');
      return;
    }

    final jobLat = (data['lat'] as num?)?.toDouble();
    final jobLng = (data['lng'] as num?)?.toDouble();
    final label = (data['label'] ?? '').toString();
    final address = (data['address'] ?? '').toString();

    if (jobLat == null || jobLng == null) {
      _toastInfo('No location on this request');
      return;
    }

    final jobLL = LatLng(jobLat, jobLng);
    final labelText = label.trim().isEmpty ? address : label;

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _LiveTrackPage(requestId: requestId, job: jobLL, labelText: labelText),
      fullscreenDialog: true,
    ));
  }

  InputDecoration _input(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: const Color(0xFFF6F7FB),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  );
}

/* ---------- Full-screen live track page ---------- */

class _LiveTrackPage extends StatefulWidget {
  final String requestId;
  final LatLng job;
  final String labelText;

  const _LiveTrackPage({
    required this.requestId,
    required this.job,
    required this.labelText,
  });

  @override
  State<_LiveTrackPage> createState() => _LiveTrackPageState();
}

class _LiveTrackPageState extends State<_LiveTrackPage> {
  GoogleMapController? _gCtrl;

  // Provider live
  LatLng? _provider;
  LatLng? _prevProvider;
  double _heading = 0;
  double? _speedMps;
  DateTime? _updatedAt;

  // Seeker device (optional)
  LatLng? _you;
  StreamSubscription<Position>? _posSub;

  // Firestore sub
  StreamSubscription<DocumentSnapshot>? _liveSub;

  // UI
  bool _follow = true; // auto-follow camera
  bool _targetYou = true; // distance mode (to you or to job)
  bool _alive = true;
  bool _animatingCamera = false;
  Timer? _camThrottle;

  // Trail
  final List<LatLng> _trail = [];
  static const int _trailMax = 60;

  // Distances
  double? _mToYou;
  double? _mToJob;

  @override
  void initState() {
    super.initState();
    _attachLive();
    _startLocation();
  }

  @override
  void dispose() {
    _alive = false;
    _liveSub?.cancel();
    _posSub?.cancel();
    _camThrottle?.cancel();
    super.dispose();
  }

  Future<void> _attachLive() async {
    final docRef = FirebaseFirestore.instance.collection('request_live').doc(widget.requestId);
    await _liveSub?.cancel();
    _liveSub = docRef.snapshots().listen((ds) {
      final m = ds.data() as Map<String, dynamic>?; if (m == null) return;

      final pLat = (m['providerLat'] as num?)?.toDouble();
      final pLng = (m['providerLng'] as num?)?.toDouble();
      final spd  = (m['speed'] as num?)?.toDouble();
      final hdg  = (m['heading'] as num?)?.toDouble();
      final upd  = m['updatedAt'];

      if (pLat == null || pLng == null) return;

      final newP = LatLng(pLat, pLng);
      if (!_alive) return;
      setState(() {
        _prevProvider = _provider ?? newP;
        _provider = newP;
        _speedMps = spd;
        _heading = (hdg ?? _bearing(_prevProvider!, newP));
        _updatedAt = (upd is Timestamp) ? upd.toDate() : DateTime.now();

        // Distances
        _mToJob = Geolocator.distanceBetween(_provider!.latitude, _provider!.longitude, widget.job.latitude, widget.job.longitude);
        if (_you != null) {
          _mToYou = Geolocator.distanceBetween(_provider!.latitude, _provider!.longitude, _you!.latitude, _you!.longitude);
        }

        // Trail
        _trail.add(_provider!);
        if (_trail.length > _trailMax) _trail.removeAt(0);
      });

      // camera follow (throttled)
      if (_follow && _gCtrl != null) {
        _camThrottle?.cancel();
        _camThrottle = Timer(const Duration(milliseconds: 350), () async {
          if (!_alive || _gCtrl == null || _provider == null) return;
          await _fitProviderAndTarget(animated: true);
        });
      }
    });
  }

  Future<void> _startLocation() async {
    try {
      final svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) return;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return;

      await _posSub?.cancel();
      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 8,
        ),
      ).listen((pos) {
        if (!_alive) return;
        setState(() {
          _you = LatLng(pos.latitude, pos.longitude);
          if (_provider != null) {
            _mToYou = Geolocator.distanceBetween(_provider!.latitude, _provider!.longitude, _you!.latitude, _you!.longitude);
          }
        });
      });

      // One-off initial
      final first = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.best);
      if (!_alive) return;
      setState(() {
        _you = LatLng(first.latitude, first.longitude);
      });
    } catch (_) {
      // ignore; still works with job distance
    }
  }

  /* ---------------- Map helpers ---------------- */

  Future<void> _fitProviderAndTarget({bool animated = true}) async {
    if (_gCtrl == null) return;

    // Choose target (you or job); if no "you", use job
    final target = (_targetYou && _you != null) ? _you! : widget.job;

    if (_provider != null) {
      final p = _provider!;
      final sw = LatLng(math.min(p.latitude, target.latitude), math.min(p.longitude, target.longitude));
      final ne = LatLng(math.max(p.latitude, target.latitude), math.max(p.longitude, target.longitude));
      final bounds = LatLngBounds(southwest: sw, northeast: ne);
      try {
        _animatingCamera = true;
        if (animated) {
          await _gCtrl!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 70));
        } else {
          await _gCtrl!.moveCamera(CameraUpdate.newLatLngBounds(bounds, 70));
        }
      } catch (_) {} finally {
        _animatingCamera = false;
      }
    } else {
      try {
        _animatingCamera = true;
        final zoomTarget = (_targetYou && _you != null) ? _you! : widget.job;
        if (animated) {
          await _gCtrl!.animateCamera(CameraUpdate.newLatLngZoom(zoomTarget, 15.5));
        } else {
          await _gCtrl!.moveCamera(CameraUpdate.newLatLngZoom(zoomTarget, 15.5));
        }
      } catch (_) {} finally {
        _animatingCamera = false;
      }
    }
  }

  double _bearing(LatLng from, LatLng to) {
    final lat1 = from.latitude * math.pi / 180.0;
    final lat2 = to.latitude * math.pi / 180.0;
    final dLon = (to.longitude - from.longitude) * math.pi / 180.0;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    double brng = math.atan2(y, x) * 180.0 / math.pi;
    if (brng < 0) brng += 360.0;
    return brng;
  }

  String _fmtDistance(double? m) {
    if (m == null) return '—';
    if (m < 1000) return '${m.toStringAsFixed(0)} m';
    return '${(m / 1000).toStringAsFixed(1)} km';
  }

  String _fmtETA(double? m) {
    if (m == null) return '—';
    double metersPerSec =
    (_speedMps != null && _speedMps! > 0.5) ? _speedMps!.clamp(0.5, 33.0) : (25000.0 / 3600.0);
    final secs = m / metersPerSec;
    if (secs < 60) return '< 1 min';
    final mins = secs / 60.0;
    if (mins < 60) return '${mins.round()} min';
    final h = (mins / 60).floor();
    final mm = (mins - h * 60).round();
    return mm == 0 ? '${h}h' : '${h}h ${mm}m';
  }

  String _ago(DateTime? t) {
    if (t == null) return '—';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return DateFormat('d MMM, h:mm a').format(t);
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      body: Stack(
        children: [
          // MAP FULL SCREEN
          GoogleMap(
            onMapCreated: (c) async {
              _gCtrl = c;
              // initial camera
              await _fitProviderAndTarget(animated: false);
            },
            initialCameraPosition: CameraPosition(target: widget.job, zoom: 15.5),
            onCameraMoveStarted: () {
              // If user starts panning (vs our programmatic move), disable follow
              if (!_animatingCamera) {
                setState(() => _follow = false);
              }
            },
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            compassEnabled: true,
            markers: {
              Marker(
                markerId: const MarkerId('job'),
                position: widget.job,
                infoWindow: const InfoWindow(title: 'Job location'),
              ),
              if (_you != null)
                Marker(
                  markerId: const MarkerId('you'),
                  position: _you!,
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
                  infoWindow: const InfoWindow(title: 'You'),
                ),
              if (_provider != null)
                Marker(
                  markerId: const MarkerId('provider'),
                  position: _provider!,
                  rotation: _heading,
                  anchor: const Offset(.5, .5),
                  flat: true,
                  icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
                  infoWindow: const InfoWindow(title: 'Provider'),
                ),
            },
            polylines: () {
              final lines = <Polyline>{};
              if (_provider != null) {
                // to target
                final target = (_targetYou && _you != null) ? _you! : widget.job;
                lines.add(Polyline(
                  polylineId: const PolylineId('to_target'),
                  points: [_provider!, target],
                  geodesic: true,
                  width: 4,
                ));
                // trail
                if (_trail.length >= 2) {
                  lines.add(Polyline(
                    polylineId: const PolylineId('trail'),
                    points: List.of(_trail),
                    geodesic: true,
                    width: 3,
                  ));
                }
              }
              return lines;
            }(),
          ),

          // TOP APP BAR OVERLAY
          Positioned(
            top: topPad + 8,
            left: 12,
            right: 12,
            child: Row(
              children: [
                // Back
                _roundBtn(
                  icon: Icons.chevron_left_rounded,
                  onTap: () => Navigator.of(context).pop(),
                  tooltip: 'Back',
                ),
                const SizedBox(width: 8),
                // Title + LIVE chip
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [BoxShadow(color: Colors.black.withOpacity(.08), blurRadius: 12)],
                      border: Border.all(color: const Color(0xFFE9EAF2)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.wifi_tethering, color: Colors.green),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('Live tracking',
                              maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w800)),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE7FFF2),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: const Color(0xFFCFF5E1)),
                          ),
                          child: const Text('LIVE',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF0F9155))),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // BOTTOM INFO CARD
          Positioned(
            left: 12,
            right: 12,
            bottom: 12 + MediaQuery.of(context).padding.bottom,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(.10), blurRadius: 16, offset: Offset(0, 6))],
                border: Border.all(color: const Color(0xFFE9EAF2)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Address / label
                  Row(
                    children: [
                      const Icon(Icons.location_pin, color: Colors.redAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.labelText,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Distances (wrap to avoid overflow)
                  Wrap(
                    alignment: WrapAlignment.start,
                    spacing: 10,
                    runSpacing: 6,
                    children: [
                      _pill(
                        icon: Icons.person_pin_circle,
                        text: 'To you: —', // Filled by parent screen’s map; left neutral here
                      ),
                      _pill(
                        icon: Icons.flag_circle_outlined,
                        text: 'To job: —',
                      ),
                      if (_updatedAt != null)
                        _pill(
                          icon: Icons.access_time,
                          text: 'Updated ${_ago(_updatedAt)}',
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Controls row (wrap-friendly)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Target toggle (chips)
                      Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF6F7FB),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE9EAF2)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ChoiceChip(
                              label: const Text('Target: You'),
                              selected: _targetYou,
                              onSelected: (_) => setState(() => _targetYou = true),
                              selectedColor: _accent,
                              labelStyle: TextStyle(
                                color: _targetYou ? Colors.white : _text,
                                fontWeight: FontWeight.w800,
                              ),
                              backgroundColor: const Color(0xFFF1F2F7),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            const SizedBox(width: 6),
                            ChoiceChip(
                              label: const Text('Target: Job'),
                              selected: !_targetYou,
                              onSelected: (_) => setState(() => _targetYou = false),
                              selectedColor: _accent,
                              labelStyle: TextStyle(
                                color: !_targetYou ? Colors.white : _text,
                                fontWeight: FontWeight.w800,
                              ),
                              backgroundColor: const Color(0xFFF1F2F7),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ],
                        ),
                      ),

                      // Follow toggle
                      FilterChip(
                        selected: _follow,
                        onSelected: (v) async {
                          setState(() => _follow = v);
                          if (v) await _fitProviderAndTarget(animated: true);
                        },
                        label: const Text('Follow'),
                        avatar: Icon(_follow ? Icons.location_searching : Icons.location_disabled,
                            size: 18, color: _follow ? _accent : _sub),
                        selectedColor: const Color(0xFFEFF3FF),
                        backgroundColor: const Color(0xFFF6F7FB),
                        labelStyle: const TextStyle(fontWeight: FontWeight.w800),
                      ),

                      // Recenter button
                      FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: _accent),
                        onPressed: () => _fitProviderAndTarget(animated: true),
                        icon: const Icon(Icons.center_focus_strong),
                        label: const Text('Recenter'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /* ---------- Small UI helpers ---------- */

  Widget _roundBtn({required IconData icon, String? tooltip, required VoidCallback onTap}) {
    return Material(
      color: Colors.white,
      shape: const CircleBorder(),
      elevation: 2,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8.0),
          child: Icon(icon, size: 26, color: _text),
        ),
      ),
    );
  }

  Widget _pill({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7FB),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE9EAF2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: _sub),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: _sub, fontSize: 12.5, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

/* ---------- Success banner ---------- */

class _SuccessBanner extends StatelessWidget {
  final String title;
  final String subtitle;
  const _SuccessBanner({
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: const Color(0xFFEDF5FF),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFD9E9FF)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CircleAvatar(
              radius: 16,
              backgroundColor: Color(0xFFDBEEFF),
              child: Icon(Icons.check_rounded, color: Color(0xFF1677FF)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: _text, fontWeight: FontWeight.w800, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(subtitle, style: const TextStyle(color: _sub, height: 1.3)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ---------- Category chips ---------- */

class _CategoryChips extends StatelessWidget {
  final _Bucket selected;
  final ValueChanged<_Bucket> onChanged;
  const _CategoryChips({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final items = const [
      [_Bucket.all, 'All'],
      [_Bucket.pending, 'Pending'],
      [_Bucket.accepted, 'Accepted'],
      [_Bucket.enroute, 'En route'],
      [_Bucket.not_completed, 'Not completed'],
      [_Bucket.cancelled, 'Cancelled'],
      [_Bucket.declined, 'Declined'],
      [_Bucket.completed, 'Completed'],
    ];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        scrollDirection: Axis.horizontal,
        itemBuilder: (_, i) {
          final v = items[i][0] as _Bucket;
          final label = items[i][1] as String;
          final active = v == selected;
          return ChoiceChip(
            label: Text(label),
            selected: active,
            onSelected: (_) => onChanged(v),
            selectedColor: _accent,
            labelStyle: TextStyle(
              color: active ? Colors.white : _text,
              fontWeight: FontWeight.w800,
            ),
            backgroundColor: const Color(0xFFF1F2F7),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          );
        },
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemCount: items.length,
      ),
    );
  }
}

/* ---------- Dismissible wrapper (swipe actions) ---------- */

class _DismissibleWrapper extends StatelessWidget {
  final String id;
  final Map<String, dynamic> data;
  final Widget child;

  // callbacks from parent to keep archive + toasts unified
  final Future<void> Function()? onArchiveCompleted;
  final void Function(String msg) toastSuccess;
  final void Function(String msg) toastInfo;
  final void Function(String msg) toastError;

  const _DismissibleWrapper({
    required this.id,
    required this.data,
    required this.child,
    required this.onArchiveCompleted,
    required this.toastSuccess,
    required this.toastInfo,
    required this.toastError,
  });

  String get _status => (data['status'] ?? '').toString();

  bool get _isEnroute => _status == 'enroute';

  bool get _isDeletable =>
      _status == 'cancelled' || _status == 'declined' || _status == 'completed' ;

  bool get _isCancelable =>
      _status == 'pending' || _status == 'accepted' || _status == 'not_completed';

  @override
  Widget build(BuildContext context) {
    // No swipe (delete/cancel) while enroute
    if (_isEnroute) return child;

    return Dismissible(
      key: ValueKey('req_$id'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (dir) async {
        if (_isDeletable) {
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('Delete request?'),
              content: Text(_status == 'completed'
                  ? 'This will save it in Orders and remove from here.'
                  : 'This removes it from your list.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
              ],
            ),
          );
          if (ok == true) {
            try {
              if (_status == 'completed') {
                // archive then delete via parent
                await onArchiveCompleted?.call();
              } else {
                await FirebaseFirestore.instance.collection('service_requests').doc(id).delete();
                toastSuccess('Removed');
              }
            } catch (_) {
              toastError('Delete failed');
            }
          }
          return false; // stream rebuild will remove it
        }

        if (_isCancelable) {
          final isOverdue = _status == 'not_completed';
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(isOverdue ? 'Cancel overdue request?' : 'Cancel request?'),
              content: Text(
                  isOverdue
                      ? 'This job missed the time window. Cancelling will mark it as "Cancelled by seeker" for both you and the provider.'
                      : 'The provider will see it as cancelled by you.'
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
                FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Yes, cancel')),
              ],
            ),
          );

          if (ok == true) {
            try {
              await FirebaseFirestore.instance
                  .collection('service_requests')
                  .doc(id)
                  .update({
                'status': 'cancelled',
                'cancelledBy': 'seeker',
                'cancelReason': isOverdue ? 'overdue_not_completed' : 'user_cancel',
                'cancelledAt': FieldValue.serverTimestamp(),
                'updatedAt': FieldValue.serverTimestamp(),
              });
              toastSuccess('Cancelled');
            } catch (_) {
              toastError('Action failed');
            }
          }
          return false; // stream will move it to Cancelled bucket
        }

        return false;
      },
      background: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        decoration: BoxDecoration(
          color: _isDeletable ? Colors.redAccent : Colors.orange,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Icon(
          _isDeletable ? Icons.delete_rounded : Icons.cancel,
          color: Colors.white,
        ),
      ),
      child: child,
    );
  }
}

/* ---------- Request Card ---------- */

class _RequestCard extends StatelessWidget {
  final String id;
  final Map<String, dynamic> data;
  final String currentUserId; // NEW

  final VoidCallback? onEditAddress;
  final VoidCallback? onRateNow;
  final VoidCallback? onRateLater;
  final VoidCallback? onTrack; // LIVE


  final void Function(String msg) toastSuccess;
  final void Function(String msg) toastInfo;
  final void Function(String msg) toastError;

  const _RequestCard({
    required this.id,
    required this.data,
    this.onEditAddress,
    this.onRateNow,
    this.onRateLater,
    this.onTrack,
    required this.toastSuccess,
    required this.toastInfo,
    required this.toastError,
    required this.currentUserId
  });

  void _openDetails(BuildContext context) {
    final gigId = (data['gigId'] ?? '').toString();
    if (gigId.isEmpty) {
      toastInfo('No linked service to open');
      return;
    }

    final gigData = <String, dynamic>{
      'providerId': (data['providerId'] ?? '').toString(),
      'title': (data['gigTitle'] ?? data['title'] ?? '').toString(),
      'category': (data['gigCategory'] ?? data['category'] ?? '').toString(),
      'price': data['gigPrice'],
      'phone': (data['providerPhone'] ?? '').toString(),
      'profileB64': (data['profileB64'] ?? '').toString(),
      'description': (data['description'] ?? '').toString(),
    };

    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => GigDetailScreen(gigId: gigId, data: gigData),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final title = (data['gigTitle'] ?? data['service'] ?? data['title'] ?? 'Service Request').toString();
    final category = (data['gigCategory'] ?? data['category'] ?? 'General').toString();
    final status = (data['status'] ?? 'pending').toString();
    final price = data['gigPrice'] ?? data['budget'] ?? data['amount'];

    final rawLabel = (data['label'] ?? '').toString();
    final address = (data['address'] ?? '').toString();
    final label = _cleanLabel(rawLabel, address);

    final providerName = (data['providerName'] ?? 'Provider').toString();
    final providerId = (data['providerId'] ?? '').toString(); // Need this for chat!

    ImageProvider? avatar;
    final profileB64 = (data['profileB64'] ?? '').toString();
    if (profileB64.isNotEmpty) {
      try {
        avatar = MemoryImage(base64Decode(profileB64));
      } catch (_) {}
    }

    DateTime? scheduledAt;
    final sch = data['scheduledAt'];
    if (sch is Timestamp) scheduledAt = sch.toDate();

    DateTime? dueBy;
    final due = data['dueBy'];
    if (due is Timestamp) dueBy = due.toDate();

    final providerCompleted = (data['providerCompleted'] ?? false) == true;

    final canDeleteDirect =
        status == 'cancelled' || status == 'declined' || status == 'completed' || status == 'not_completed';

    // Compute not_completed banner text
    Widget? overdueHint;
    if (status == 'not_completed') {
      final mins = _calcOverdueByMin(data, fallbackFrom: scheduledAt ?? dueBy);
      final kind = scheduledAt != null ? 'Scheduled time passed' : 'Due time passed';
      final details = mins != null && mins > 0 ? '' : 'Overdue';
      overdueHint = _OverdueHint(text: '$kind  $details');
    }

    // Badge colors: turn red when not_completed
    final badgeScheduledBg = status == 'not_completed' ? const Color(0xFFFFEEF0) : const Color(0xFFEFF3FF);
    final badgeScheduledFg = status == 'not_completed' ? _danger : const Color(0xFF3D6BFF);

    final badgeDueBg = status == 'not_completed' ? const Color(0xFFFFEEF0) : const Color(0xFFEFF3FF);
    final badgeDueFg = status == 'not_completed' ? _danger : const Color(0xFF3D6BFF);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDetails(context),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE9EAF2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
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
                // Header row
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: const Color(0xFFF1F2F7),
                      backgroundImage: avatar,
                      child: avatar == null ? const Icon(Icons.handyman_outlined, color: _sub) : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _text,
                          fontWeight: FontWeight.w800,
                          fontSize: 15.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusChip(status: status),
                  ],
                ),

                const SizedBox(height: 8),

                // meta row
                Row(
                  children: [
                    Icon(Icons.category_outlined, size: 16, color: _sub.withOpacity(0.9)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        category,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: _sub, fontSize: 13.5),
                      ),
                    ),
                    if (price != null) ...[
                      const SizedBox(width: 10),
                      Text(
                        'PKR $price',
                        style: const TextStyle(
                          color: Color(0xFF0E7D40),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 8),

                // location row (tap -> open map) + Edit (if pending)
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () async {
                          final lat = (data['lat'] as num?)?.toDouble();
                          final lng = (data['lng'] as num?)?.toDouble();
                          if (lat == null || lng == null) return;
                          final url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
                          if (await canLaunchUrl(url)) {
                            await launchUrl(url, mode: LaunchMode.externalApplication);
                          } else {
                            toastError('Could not open Maps');
                          }
                        },
                        child: Row(
                          children: [
                            Icon(Icons.location_on_outlined, size: 16, color: _sub.withOpacity(0.9)),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: _sub, fontSize: 13.5, height: 1.2),
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(Icons.map_outlined, color: _sub, size: 18),
                          ],
                        ),
                      ),
                    ),
                    if (status == 'pending') ...[
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: onEditAddress,
                        child: const Text('Edit', style: TextStyle(fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ],
                ),

                // OVERDUE BANNER (if not_completed)
                if (overdueHint != null) ...[
                  const SizedBox(height: 8),
                  overdueHint,
                ],

                // schedule + badges
                if (scheduledAt != null || providerCompleted || dueBy != null) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (scheduledAt != null)
                        _Badge(
                          icon: Icons.event_available_rounded,
                          label: 'Scheduled • ${_fmtDT(scheduledAt!)}',
                          bg: badgeScheduledBg,
                          fg: badgeScheduledFg,
                        ),

                      if (providerCompleted)
                        const _Badge(
                          icon: Icons.verified_rounded,
                          label: 'Provider marked complete',
                          bg: Color(0xFFE9F9EF),
                          fg: Color(0xFF178A4A),
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: 10),

                // provider + actions row
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        providerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: _text,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ActionButton(
                      icon: Icons.call_rounded,
                      label: 'Call',
                      onTap: (data['providerPhone'] ?? '').toString().isEmpty
                          ? null
                          : () async {
                        final phone = (data['providerPhone'] ?? '').toString();
                        final uri = Uri(scheme: 'tel', path: phone);
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri);
                        } else {
                          toastError('Could not launch dialer');
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    _ActionButton(
                      icon: Icons.chat_bubble_rounded,
                      label: 'Chat',
                      onTap: () {
                        if (providerId.isEmpty) {
                          toastError('Provider ID missing');
                          return;
                        }
                        // Open Chat using the static helper from ChatListScreen
                        ChatListScreen.openChat(
                          context,
                          myUid: currentUserId,
                          otherUid: providerId,
                          otherName: providerName,
                        );
                      },
                    ),
                  ],
                ),

                // Track live (only when provider is enroute)
                if (status == 'enroute') ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: _accent),
                      onPressed: onTrack,
                      icon: const Icon(Icons.wifi_tethering),
                      label: const Text('Track live', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                ],

                // Rate prompt (only when status==completed)
                if (status == 'completed') ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF5FF),
                      border: Border.all(color: const Color(0xFFD9E9FF)),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.star_rounded, color: Color(0xFF1677FF)),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Rate the provider',
                            style: TextStyle(fontWeight: FontWeight.w800, color: _text),
                          ),
                        ),
                        TextButton(onPressed: onRateLater, child: const Text('Later')),
                        const SizedBox(width: 6),
                        FilledButton(
                          style: FilledButton.styleFrom(backgroundColor: _accent),
                          onPressed: onRateNow,
                          child: const Text('Rate now'),
                        ),
                      ],
                    ),
                  ),
                ],

                if (canDeleteDirect) const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _fmtDT(DateTime dt) {
    final now = DateTime.now();
    final fmt = (dt.year == now.year) ? DateFormat('EEE, d MMM • h:mm a') : DateFormat('EEE, d MMM yyyy • h:mm a');
    return fmt.format(dt);
  }

  // derive overdue minutes either from field or from timestamps
  int? _calcOverdueByMin(Map<String, dynamic> m, {DateTime? fallbackFrom}) {
    final n = m['overdueByMin'];
    if (n is num) return n.toInt();
    final due = m['dueBy'];
    final dt = due is Timestamp ? due.toDate() : fallbackFrom;
    if (dt == null) return null;
    return DateTime.now().difference(dt).inMinutes.clamp(1, 999999);
  }

  String _fmtMins(int mins) {
    if (mins < 60) return '$mins min';
    final h = mins ~/ 60;
    final m = mins % 60;
    return m == 0 ? '${h}h' : '${h}h $m m';
  }

  String _cleanLabel(String raw, String address) {
    final r = raw.trim();
    if (r.isEmpty) return address;
    if (r.toLowerCase().contains('locating')) {
      return address.isNotEmpty ? address : 'Address';
    }
    return r;
  }
}

class _OverdueHint extends StatelessWidget {
  final String text;
  const _OverdueHint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFAF1),            // soft, eye-friendly
        borderRadius: BorderRadius.circular(999),  // pill
        border: Border.all(color: const Color(0xFFFFEAD5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.timelapse_rounded, size: 16, color: _warn),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: _warn,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFF4F6FF) : const Color(0xFFF2F2F2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled ? const Color(0xFFE1E5FF) : const Color(0xFFEAEAEA),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: enabled ? const Color(0xFF3D6BFF) : _sub),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
                color: enabled ? const Color(0xFF3D6BFF) : _sub,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color bg;
  final Color fg;
  const _Badge({
    required this.icon,
    required this.label,
    required this.bg,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: fg, size: 16),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: 12,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final s = status.toLowerCase();
    Color bg;
    Color fg;

    if (s == 'completed') {
      bg = const Color(0xFFE9F9EF);
      fg = const Color(0xFF178A4A);
    } else if (s == 'accepted') {
      bg = const Color(0xFFEFF3FF);
      fg = const Color(0xFF3D6BFF);
    } else if (s == 'enroute') {
      bg = const Color(0xFFFFF3E0);
      fg = const Color(0xFFEF6C00);
    } else if (s == 'not_completed') {
      bg = const Color(0xFFFFEEF0);
      fg = _danger;
    } else if (s == 'cancelled' || s == 'declined') {
      bg = const Color(0xFFFFEEF0);
      fg = const Color(0xFFD33A4A);
    } else {
      // pending / submitted
      bg = const Color(0xFFFFF6E8);
      fg = const Color(0xFF9A6A00);
    }

    final label = s.isEmpty ? '-' : (s[0].toUpperCase() + s.substring(1).replaceAll('_', ' '));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w800,
          fontSize: 12,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

/* ---------- Mini star picker (for sheet) ---------- */

class _MiniStarPicker extends StatelessWidget {
  final String label;
  final int value; // 1..5
  final ValueChanged<int> onChanged;

  const _MiniStarPicker({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w800, color: _text))),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(5, (i) {
            final filled = i < value;
            return IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 40, height: 40),
              onPressed: () => onChanged(i + 1),
              icon: Icon(
                filled ? Icons.star_rounded : Icons.star_border_rounded,
                size: 26,
                color: filled ? const Color(0xFFFFC107) : Colors.black26,
              ),
            );
          }),
        ),
      ],
    );
  }
}
