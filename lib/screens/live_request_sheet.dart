import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// --- THEME COLORS (Matched to your app) ---
const Color _accent = Color(0xFF7966FA);
const Color _ok = Color(0xFF17A34A);
const Color _info = Color(0xFF1677FF);
const Color _warn = Color(0xFFEF6C00);
const Color _danger = Color(0xFFD33A4A);
const Color _text = Color(0xFF121316);
const Color _sub = Color(0xFF6C7280);

const double _ratePerKm = 70;
const String _googleApiKey = 'AIzaSyBzvWeiJ8Jc9nRPBr_8aqLNPkiaSI0u2O0'; // Replace with your key

class LiveRequestSheet extends StatefulWidget {
  const LiveRequestSheet({super.key});

  @override
  State<LiveRequestSheet> createState() => _LiveRequestSheetState();
}

class _LiveRequestSheetState extends State<LiveRequestSheet> {
  GoogleMapController? _mapController;

  // --- Inputs ---
  final TextEditingController _whereController = TextEditingController();
  final TextEditingController _pickupController = TextEditingController();
  final TextEditingController _dropController = TextEditingController();
  final TextEditingController _priceController = TextEditingController();

  // --- State ---
  int _selectedType = 0;
  bool _pickDropMode = false;

  // Map Targets
  LatLng _cameraTarget = const LatLng(34.1463, 73.2113); // Default
  LatLng? _pickupTarget;
  LatLng? _dropTarget;

  // Route & Fare
  double? _estimatedKm;
  double? _estimatedPrice;
  List<LatLng> _routePoints = []; // For creation preview

  // UI Flags
  bool _locating = false;
  bool _fetchingRoute = false;
  bool _submitting = false;

  // Active Request State
  String? _activeRequestId;
  bool _isRatingMode = false;

  // Live Tracking Data
  LatLng? _liveProviderPos;
  LatLng? _staticPickupPos;
  List<LatLng> _liveRoutePoints = []; // For active tracking
  bool _hasFitBounds = false;

  // Places Autocomplete
  final List<_PlaceSuggestion> _pickupSuggestions = [];
  final List<_PlaceSuggestion> _dropSuggestions = [];
  final FocusNode _pickupFocusNode = FocusNode();
  final FocusNode _dropFocusNode = FocusNode();

  final List<_LiveServiceType> _types = const [
    _LiveServiceType(label: 'Cleaning', icon: Icons.home_repair_service_rounded, people: 1),
    _LiveServiceType(label: 'AC', icon: Icons.ac_unit_rounded, people: 1),
    _LiveServiceType(label: 'Plumber', icon: Icons.plumbing_rounded, people: 1),
    _LiveServiceType(label: 'Electrician', icon: Icons.electrical_services_rounded, people: 1),
    _LiveServiceType(label: 'Driver', icon: Icons.directions_car_filled_rounded, people: 1),
  ];

  final List<_VehicleOption> _vehicles = const [
    _VehicleOption(label: 'Bike', icon: Icons.pedal_bike_rounded, ratePerKm: 30),
    _VehicleOption(label: 'Car Mini', icon: Icons.directions_car_filled_rounded, ratePerKm: 70),
    _VehicleOption(label: 'Car', icon: Icons.local_taxi_rounded, ratePerKm: 90),
  ];
  int _selectedVehicle = 0;

  bool get _isPickupMapMode => _pickDropMode && _pickupFocusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    _pickupFocusNode.addListener(() {
      if (!_pickupFocusNode.hasFocus && mounted) setState(() => _pickupSuggestions.clear());
    });
    _dropFocusNode.addListener(() {
      if (!_dropFocusNode.hasFocus && mounted) setState(() => _dropSuggestions.clear());
    });

    _restoreActiveRequestIfAny();
  }

  @override
  void dispose() {
    _whereController.dispose();
    _pickupController.dispose();
    _dropController.dispose();
    _priceController.dispose();
    _pickupFocusNode.dispose();
    _dropFocusNode.dispose();
    _mapController?.dispose();
    super.dispose();
  }

  void _dismissKeyboardAndSuggestions() => FocusScope.of(context).unfocus();

  // ===================== Toasts (global pattern) =====================
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

  // ───────────────── 1. AUTO-RESTORE LOGIC ─────────────────
  Future<void> _restoreActiveRequestIfAny() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      final now = DateTime.now();
      final snap = await FirebaseFirestore.instance
          .collection('live_requests')
          .where('seekerId', isEqualTo: user.uid)
          .where('status', whereIn: ['searching', 'ongoing'])
          .get();

      if (!mounted || snap.docs.isEmpty) return;

      for (final doc in snap.docs) {
        final data = doc.data();
        final ts = data['expiresAt'] as Timestamp?;
        final expiresAt = ts?.toDate();

        if (expiresAt != null && expiresAt.isAfter(now)) {
          setState(() {
            _activeRequestId = doc.id;
            _isRatingMode = false;
            _hasFitBounds = false;
          });
          return;
        }
      }
    } catch (_) {}
  }

  // ───────────────── 2. MAP & LOCATION ─────────────────
  Future<void> _goToCurrentLocation() async {
    if (_locating) return;
    setState(() => _locating = true);
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.deniedForever || permission == LocationPermission.denied) {
        setState(() => _locating = false);
        return;
      }

      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final target = LatLng(pos.latitude, pos.longitude);

      setState(() {
        _cameraTarget = target;
        _pickupTarget = target;
      });

      await _mapController?.animateCamera(CameraUpdate.newCameraPosition(CameraPosition(target: target, zoom: 16)));

      final addr = await _reverseGeocode(target);
      if (_pickDropMode) _pickupController.text = addr ?? 'Current Location';

      if (_pickDropMode && _dropTarget != null) _updateRoute();

    } catch (_) {
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<String?> _reverseGeocode(LatLng target) async {
    final url = Uri.parse('https://maps.googleapis.com/maps/api/geocode/json?latlng=${target.latitude},${target.longitude}&key=$_googleApiKey');
    try {
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['results'] != null && data['results'].isNotEmpty) {
          return data['results'][0]['formatted_address'];
        }
      }
    } catch (_) {}
    return null;
  }

  // ───────────────── 3. ROUTING & FARE ─────────────────
  Future<void> _updateRoute() async {
    if (!_pickDropMode || _dropTarget == null || _pickupTarget == null) {
      _clearFare();
      return;
    }
    if (_fetchingRoute) return;

    final start = _pickupTarget!;
    final end = _dropTarget!;
    _fetchingRoute = true;

    try {
      final url = Uri.parse('https://maps.googleapis.com/maps/api/directions/json?origin=${start.latitude},${start.longitude}&destination=${end.latitude},${end.longitude}&mode=driving&key=$_googleApiKey');
      final res = await http.get(url);

      double km = 0;
      List<LatLng> points = [start, end];

      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final legs = route['legs'] as List;
          final meters = legs[0]['distance']['value'] as num;
          km = meters / 1000.0;
          points = _decodePolyline(route['overview_polyline']['points']);
        } else {
          km = _calcDistance(start, end);
        }
      } else {
        km = _calcDistance(start, end);
      }

      final rate = _pickDropMode ? _vehicles[_selectedVehicle].ratePerKm : _ratePerKm;
      final fare = (km * rate).round();

      if (mounted) {
        setState(() {
          _routePoints = points;
          _estimatedKm = km;
          _estimatedPrice = fare.toDouble();
          _priceController.text = fare.toString();
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _fetchingRoute = false);
    }
  }

  void _recomputeFareFromKm() {
    if (_estimatedKm == null) return;
    final rate = _pickDropMode ? _vehicles[_selectedVehicle].ratePerKm : _ratePerKm;
    final fare = (_estimatedKm! * rate).round();
    setState(() {
      _estimatedPrice = fare.toDouble();
      _priceController.text = fare.toString();
    });
  }

  void _clearFare() {
    setState(() {
      _estimatedKm = null;
      _estimatedPrice = null;
      _priceController.clear();
      if(_pickDropMode && _dropTarget == null) _routePoints.clear();
    });
  }

  // ───────────────── 4. SUBMIT REQUEST ─────────────────
  Future<void> _submitLiveRequest({
    String? overrideMode,
    String? overrideServiceType,
    String? overrideVehicleType,
    String? overrideWhereText,
    double? overrideLat,
    double? overrideLng,
    String? overrideAddr,
    double? overrideDropLat,
    double? overrideDropLng,
    String? overrideDropAddr,
    int? overrideFare,
  }) async {
    if (_submitting) return;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      _toastError('Please log in.');
      return;
    }

    final fare = overrideFare ?? (int.tryParse(_priceController.text.trim()) ?? 0);
    if (fare <= 0) {
      _toastWarn('Please set a valid price.');
      return;
    }

    setState(() => _submitting = true);

    try {
      String? seekerName = user.displayName;
      String? seekerPhone = user.phoneNumber;
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      if(userDoc.exists) {
        final d = userDoc.data()!;
        seekerName ??= d['name'] ?? d['fullName'];
        seekerPhone ??= d['phone'];
      }

      final now = DateTime.now();
      final mode = overrideMode ?? (_pickDropMode ? 'pick_drop' : 'standard');

      final Map<String, dynamic> payload = {
        'seekerId': user.uid,
        'seekerName': seekerName ?? 'User',
        'seekerPhone': seekerPhone ?? '',
        'status': 'searching',
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': now.add(const Duration(minutes: 10)),
        'timeoutSeconds': 600,
        'mode': mode,
        'fare': fare,
        'baseFare': fare,
        'currency': 'PKR',
        'providerId': null,
        'providerLat': null,
        'providerLng': null,
        'isLiveRequest': true,
        'viewingCount': 0,
        'hideFromRecents': false,
      };

      if (mode == 'pick_drop') {
        final pLat = overrideLat ?? _pickupTarget?.latitude;
        final pLng = overrideLng ?? _pickupTarget?.longitude;
        final dLat = overrideDropLat ?? _dropTarget?.latitude;
        final dLng = overrideDropLng ?? _dropTarget?.longitude;
        final pAddr = overrideAddr ?? _pickupController.text;
        final dAddr = overrideDropAddr ?? _dropController.text;
        final vType = overrideVehicleType ?? _vehicles[_selectedVehicle].label;

        if (pLat == null || dLat == null) {
          _toastWarn('Invalid location data.');
          setState(() => _submitting = false);
          return;
        }

        payload.addAll({
          'vehicleType': vType,
          'whereText': "$vType delivery",
          'description': "$vType delivery",
          'pickupLat': pLat,
          'pickupLng': pLng,
          'pickupAddress': pAddr.isEmpty ? 'Pinned Pickup' : pAddr,
          'pickup': GeoPoint(pLat, pLng!),
          'dropLat': dLat,
          'dropLng': dLng,
          'dropAddress': dAddr.isEmpty ? 'Pinned Drop' : dAddr,
          'drop': GeoPoint(dLat, dLng!),
        });
      } else {
        // Standard
        final pLat = overrideLat ?? (_pickupTarget ?? _cameraTarget).latitude;
        final pLng = overrideLng ?? (_pickupTarget ?? _cameraTarget).longitude;
        final pAddr = overrideAddr ?? (await _reverseGeocode(LatLng(pLat, pLng)) ?? 'Pinned Location');
        final wText = overrideWhereText ?? _whereController.text.trim();
        final sType = overrideServiceType ?? _types[_selectedType].label;

        if (wText.isEmpty) {
          _toastWarn('Please describe what you need.');
          setState(() => _submitting = false);
          return;
        }

        payload.addAll({
          'serviceType': sType,
          'whereText': wText,
          'description': wText,
          'pickupLat': pLat,
          'pickupLng': pLng,
          'pickupAddress': pAddr,
          'pickup': GeoPoint(pLat, pLng),
          'dropLat': null,
          'dropLng': null,
          'dropAddress': null,
          'drop': null,
        });
      }

      final docRef = FirebaseFirestore.instance.collection('live_requests').doc();
      payload['id'] = docRef.id;
      await docRef.set(payload);

      if (!mounted) return;
      setState(() {
        _activeRequestId = docRef.id;
        _isRatingMode = false;
        _liveProviderPos = null;
        _hasFitBounds = false;
        final finalLat = overrideLat ?? (_pickupTarget ?? _cameraTarget).latitude;
        final finalLng = overrideLng ?? (_pickupTarget ?? _cameraTarget).longitude;
        _staticPickupPos = LatLng(finalLat, finalLng);
        _liveRoutePoints = [];
      });

    } catch (e) {
      _toastError('Error: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ───────────────── RECENT REQUESTS ─────────────────
  Future<void> _reSendFromRecent(Map<String, dynamic> data) async {
    await _submitLiveRequest(
      overrideMode: data['mode'],
      overrideServiceType: data['serviceType'],
      overrideVehicleType: data['vehicleType'],
      overrideWhereText: data['whereText'] ?? data['description'],
      overrideLat: data['pickupLat'],
      overrideLng: data['pickupLng'],
      overrideAddr: data['pickupAddress'],
      overrideDropLat: data['dropLat'],
      overrideDropLng: data['dropLng'],
      overrideDropAddr: data['dropAddress'],
      overrideFare: (data['fare'] ?? data['baseFare'])?.toInt(),
    );
  }

  Future<void> _clearRecentRequests() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final mode = _pickDropMode ? 'pick_drop' : 'standard';

    try {
      final snap = await FirebaseFirestore.instance
          .collection('live_requests')
          .where('seekerId', isEqualTo: user.uid)
          .where('mode', isEqualTo: mode)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        batch.update(doc.reference, {'hideFromRecents': true});
      }
      await batch.commit();
      setState(() {});
    } catch (_) {}
  }

  Widget _buildRecentRequests() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const SizedBox.shrink();

    final mode = _pickDropMode ? 'pick_drop' : 'standard';

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('live_requests')
          .where('seekerId', isEqualTo: user.uid)
          .where('mode', isEqualTo: mode)
          .orderBy('createdAt', descending: true)
          .limit(20)
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const SizedBox.shrink();

        final validDocs = snapshot.data!.docs.where((d) {
          final m = d.data() as Map<String, dynamic>;
          return (m['hideFromRecents'] ?? false) != true;
        }).take(3).toList();

        if (validDocs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Recent / Quick', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                TextButton(
                  onPressed: _clearRecentRequests,
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Clear all', style: TextStyle(fontSize: 12)),
                )
              ],
            ),
            ...validDocs.map((doc) {
              final d = doc.data() as Map<String, dynamic>;
              final fare = d['fare'] ?? 0;
              String title = '';
              String subtitle = '';

              if (mode == 'pick_drop') {
                title = '${d['pickupAddress']} → ${d['dropAddress']}';
                subtitle = '${d['vehicleType']} • PKR $fare';
              } else {
                title = d['whereText'] ?? d['serviceType'] ?? 'Service';
                subtitle = '${d['serviceType']} • PKR $fare';
              }

              return ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                  child: Icon(mode == 'pick_drop' ? Icons.directions_car : Icons.home_repair_service, size: 20, color: Colors.grey[700]),
                ),
                title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
                trailing: const Icon(Icons.history, size: 18, color: Colors.grey),
                onTap: () => _reSendFromRecent(d),
              );
            }),
            const SizedBox(height: 10),
          ],
        );
      },
    );
  }

  // ───────────────── 5. ACTIONS ─────────────────
  Future<void> _updateFare(int amount) async {
    if (_activeRequestId == null) return;
    try {
      await FirebaseFirestore.instance.collection('live_requests').doc(_activeRequestId).update({
        'fare': FieldValue.increment(amount),
        'baseFare': FieldValue.increment(amount),
      });
    } catch (_) {}
  }

  Future<void> _cancelRequest() async {
    if (_activeRequestId == null) return;
    try {
      await FirebaseFirestore.instance.collection('live_requests').doc(_activeRequestId).update({
        'status': 'cancelled',
        'cancelledBy': 'seeker',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    if (mounted) {
      setState(() {
        _activeRequestId = null;
        _isRatingMode = false;
        _routePoints.clear();
        _liveProviderPos = null;
        _liveRoutePoints.clear();
        _hasFitBounds = false;
      });
    }
  }

  /// Saves to Orders/History then deletes the Live Request
  Future<void> _moveToOrdersAndClose({
    required Map<String, dynamic> data,
    double? rating,
    String? reviewText,
    required bool rated,
  }) async {
    if (_activeRequestId == null) return;
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    try {
      // 1. Prepare Order Data
      final orderData = <String, dynamic>{
        'userId': uid,
        'requestId': _activeRequestId,
        'gigId': '', // Live requests don't have a pre-existing Gig ID
        'providerId': (data['providerId'] ?? '').toString(),
        'providerName': (data['providerName'] ?? 'Provider').toString(),
        'title': (data['whereText'] ?? data['serviceType'] ?? 'Live Service').toString(),
        'category': (data['serviceType'] ?? 'Live').toString(),
        'price': data['fare'],
        'thumbnailB64': '', // No thumb for live yet
        'deliveredAt': FieldValue.serverTimestamp(),
        'rated': rated,
        'rating': rating ?? 0.0,
        'review': reviewText ?? '',
        'createdAt': FieldValue.serverTimestamp(),
        'isLiveRequest': true,
      };

      // 2. Add to Orders
      await FirebaseFirestore.instance.collection('orders').add(orderData);

      // 3. If rated, add to Reviews collection too
      if (rated && rating != null) {
        await FirebaseFirestore.instance.collection('gig_reviews').add({
          'providerId': data['providerId'],
          'seekerId': uid,
          'authorId': uid,
          'authorName': data['seekerName'] ?? 'User',
          'rating': rating,
          'review': reviewText ?? '',
          'gigTitle': orderData['title'],
          'createdAt': FieldValue.serverTimestamp(),
        });
      }

      // 4. Delete the Live Request
      await FirebaseFirestore.instance.collection('live_requests').doc(_activeRequestId).delete();

      if (mounted) {
        _toastSuccess(rated ? 'Rating submitted' : 'Saved to history');
        setState(() {
          _activeRequestId = null;
          _isRatingMode = false;
          _routePoints.clear();
          _liveProviderPos = null;
          _hasFitBounds = false;
        });
      }
    } catch (e) {
      _toastError('Error saving: $e');
    }
  }

  // ───────────────── MAP GETTERS ─────────────────
  Set<Marker> get _markers {
    final markers = <Marker>{};

    // ACTIVE MODE
    if (_activeRequestId != null && !_isRatingMode) {
      // Pickup
      if (_staticPickupPos != null) {
        markers.add(Marker(
          markerId: const MarkerId('pickup'),
          position: _staticPickupPos!,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ));
      }
      // Provider (Live)
      if (_liveProviderPos != null) {
        markers.add(Marker(
          markerId: const MarkerId('provider'),
          position: _liveProviderPos!,
          rotation: 0,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
          infoWindow: const InfoWindow(title: 'Provider'),
        ));
      }
      return markers;
    }

    // CREATION MODE
    if (_pickDropMode && _dropTarget != null) {
      markers.add(Marker(
        markerId: const MarkerId('drop'),
        position: _dropTarget!,
        draggable: true,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRose),
        onDragEnd: (pos) {
          _dropTarget = pos;
          _updateRoute();
        },
      ));
    }
    return markers;
  }

  Set<Polyline> get _polylines {
    // Live Route (Provider -> Pickup)
    if (_activeRequestId != null) {
      if (_liveRoutePoints.isNotEmpty) {
        return {
          Polyline(
            polylineId: const PolylineId('live_route'),
            points: _liveRoutePoints,
            color: _accent,
            width: 5,
          )
        };
      }
      return {};
    }

    // Creation Route (Pickup -> Drop)
    if (_routePoints.isNotEmpty) {
      return {
        Polyline(
          polylineId: const PolylineId('creation_route'),
          points: _routePoints,
          color: _accent.withOpacity(0.7),
          width: 5,
          patterns: [PatternItem.dash(20), PatternItem.gap(10)],
        )
      };
    }
    return {};
  }

  // ───────────────── UI BUILD ─────────────────
  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final safeTop = (topPadding == 0) ? 24.0 : topPadding + 8;

    final bool isWaiting = _activeRequestId != null;

    return SizedBox.expand(
      child: Stack(
        children: [
          // 1. MAP LAYER
          Positioned.fill(
            child: GoogleMap(
              initialCameraPosition: CameraPosition(target: _cameraTarget, zoom: 14),
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              compassEnabled: false,
              onMapCreated: (c) => _mapController = c,
              onCameraMove: (pos) => _cameraTarget = pos.target,
              onCameraIdle: () {
                if (_isPickupMapMode && !isWaiting) _updatePickupFromCamera();
              },
              onTap: (pos) {
                if (_pickDropMode && !isWaiting) {
                  _dismissKeyboardAndSuggestions();
                  setState(() {
                    _dropTarget = pos;
                    _dropController.text = 'Selected on map';
                    _dropSuggestions.clear();
                  });
                  _updateRoute();
                }
              },
              markers: _markers,
              polylines: _polylines,
            ),
          ),

          // 2. TOP CONTROLS
          Positioned(
            top: safeTop,
            left: 16,
            right: 16,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _roundBtn(Icons.close_rounded, () {
                  _dismissKeyboardAndSuggestions();
                  Navigator.pop(context);
                }),
                _roundBtn(_locating ? Icons.timelapse_rounded : Icons.my_location_rounded, () {
                  _dismissKeyboardAndSuggestions();
                  _goToCurrentLocation();
                }),
              ],
            ),
          ),

          // 3. CENTER PIN (Pick & Drop Creation)
          if (_isPickupMapMode && !isWaiting)
            const Align(
              alignment: Alignment(0, -0.15),
              child: IgnorePointer(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.place_rounded, size: 38, color: Colors.white),
                    Icon(Icons.circle, size: 10, color: _accent),
                  ],
                ),
              ),
            ),

          // 4. BOTTOM SHEET
          if (isWaiting)
            DraggableScrollableSheet(
              initialChildSize: 0.50,
              minChildSize: 0.40,
              maxChildSize: 0.85,
              builder: (ctx, scroll) => _buildWaitingOrRatingPanel(scroll),
            )
          else
            DraggableScrollableSheet(
              initialChildSize: 0.55, // Taller to fit Recents
              minChildSize: 0.40,
              maxChildSize: 0.95,
              builder: (ctx, scroll) => _buildRequestFormPanel(scroll),
            ),
        ],
      ),
    );
  }

  // ───────────────── PANEL: WAITING / ONGOING / RATING ─────────────────
  Widget _buildWaitingOrRatingPanel(ScrollController scroll) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20)],
      ),
      child: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('live_requests').doc(_activeRequestId).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

          final data = snapshot.data!.data() as Map<String, dynamic>?;

          if (data == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _activeRequestId = null);
            });
            return const Center(child: Text('Request not found'));
          }

          final status = data['status'] as String? ?? 'searching';

          // COMPLETED -> RATING
          if (status == 'completed') {
            return _buildRatingView(scroll, data);
          }

          // CANCELLED
          if (status == 'cancelled') {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _activeRequestId = null);
            });
            return const SizedBox();
          }

          final isOngoing = status == 'ongoing';
          final fare = (data['fare'] ?? 0);
          final providerName = data['providerName'];
          final providerPhone = data['providerPhone'];

          // LIVE TRACKING SYNC
          if (isOngoing) {
            _updateMapForLiveTracking(data);
          }

          return ListView(
            controller: scroll,
            padding: const EdgeInsets.all(20),
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 16),

              // Status Title
              Row(
                children: [
                  if (!isOngoing)
                    const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: _accent)
                    )
                  else
                    const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      isOngoing ? 'Provider found!' : 'Searching for a provider...',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isOngoing
                    ? 'Your provider is on the way.'
                    : 'We are notifying nearby providers.',
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 24),

              // PROVIDER INFO (Ongoing)
              if (isOngoing && providerName != null) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: const Color(0xFFF5F6FA),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.green.withOpacity(0.3))
                  ),
                  child: Row(
                    children: [
                      const CircleAvatar(
                        backgroundColor: Colors.white,
                        child: Icon(Icons.person, color: Colors.black87),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(providerName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                            if(providerPhone != null)
                              Text(providerPhone, style: const TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.call, color: Colors.green),
                        onPressed: () => _callPhone(providerPhone),
                      )
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // FARE + SLEEK BUTTONS (Only searching)
              if (!isOngoing)
                Column(
                  children: [
                    const Text('Offering Fare', style: TextStyle(color: _sub, fontSize: 13)),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _circleBtn(Icons.remove, fare > 5 ? () => _updateFare(-5) : null),
                        const SizedBox(width: 20),
                        Text('PKR $fare', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: _text)),
                        const SizedBox(width: 20),
                        _circleBtn(Icons.add, () => _updateFare(5)),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(8)),
                      child: const Text('Cash', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _sub)),
                    ),
                  ],
                )
              else
              // Static Fare Display (Ongoing)
                Center(
                  child: Column(
                    children: [
                      Text('PKR $fare', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
                      const Text('Cash', style: TextStyle(color: _sub, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),

              const SizedBox(height: 30),

              // Cancel
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: Colors.red.shade200),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                  ),
                  onPressed: _cancelRequest,
                  child: Text(
                    isOngoing ? 'Cancel Request' : 'Stop Searching',
                    style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _circleBtn(IconData icon, VoidCallback? onTap) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: onTap == null ? Colors.grey[200] : Colors.white,
          border: Border.all(color: onTap == null ? Colors.transparent : Colors.grey.shade300),
          boxShadow: onTap == null ? [] : [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 4, offset: const Offset(0, 2))],
        ),
        child: Icon(icon, color: onTap == null ? Colors.grey : _text),
      ),
    );
  }

  // ───────────────── PANEL: RATING VIEW ─────────────────
  Widget _buildRatingView(ScrollController scroll, Map<String, dynamic> data) {
    final providerName = data['providerName'] ?? 'Provider';
    final serviceName = data['whereText'] ?? data['serviceType'] ?? 'Service';

    // Local state wrapper for stars
    return StatefulBuilder(
        builder: (ctx, setInnerState) {
          // You need to store rating in the parent State or use a ValueNotifier if you want it to persist across re-opens without saving.
          // For now, defaulting to 5 stars on open.
          double rating = _isRatingMode ? 5.0 : 5.0;
          final TextEditingController commentCtrl = TextEditingController();

          return ListView(
            controller: scroll,
            padding: const EdgeInsets.all(24),
            children: [
              const Icon(Icons.check_circle_rounded, size: 60, color: Colors.green),
              const SizedBox(height: 16),
              const Center(child: Text('Job Completed!', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
              const SizedBox(height: 8),
              Center(child: Text('Rate $providerName for $serviceName', style: const TextStyle(color: _sub, fontSize: 15), textAlign: TextAlign.center)),
              const SizedBox(height: 30),

              // Interactive Stars
              StatefulBuilder(
                  builder: (context, setStars) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(5, (index) {
                        final starVal = index + 1;
                        final filled = starVal <= rating;
                        return IconButton(
                          iconSize: 40,
                          icon: Icon(
                            filled ? Icons.star_rounded : Icons.star_outline_rounded,
                            color: Colors.amber,
                          ),
                          onPressed: () {
                            setStars(() => rating = starVal.toDouble());
                          },
                        );
                      }),
                    );
                  }
              ),

              const SizedBox(height: 30),
              TextField(
                controller: commentCtrl,
                decoration: InputDecoration(
                  hintText: 'Add a comment...',
                  filled: true,
                  fillColor: Colors.grey[100],
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 20),

              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      onPressed: () => _moveToOrdersAndClose(data: data, rated: false),
                      child: const Text('Later', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _accent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      ),
                      // We need to capture the current rating from the local state
                      // Since 'rating' var is inside the builder, it works.
                      onPressed: () => _moveToOrdersAndClose(
                          data: data,
                          rated: true,
                          rating: rating, // captures current star value
                          reviewText: commentCtrl.text.trim()
                      ),
                      child: const Text('Submit', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          );
        }
    );
  }

  // ───────────────── PANEL: REQUEST FORM ─────────────────
  Widget _buildRequestFormPanel(ScrollController scroll) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20)],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          controller: scroll,
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)))),
              const SizedBox(height: 16),

              // MODE TOGGLE
              Row(children: [
                Expanded(child: _ModeChip('Standard', !_pickDropMode, () => _toggleMode(false))),
                const SizedBox(width: 10),
                Expanded(child: _ModeChip('Pick & Drop', _pickDropMode, () => _toggleMode(true))),
              ]),
              const SizedBox(height: 16),

              // FIELDS
              if(!_pickDropMode) ...[
                _buildTextField(_whereController, 'What do you need?', Icons.search),
                const SizedBox(height: 12),
                SizedBox(
                  height: 80,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _types.length,
                    separatorBuilder: (_,__) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _ServiceTypeCard(_types[i], i == _selectedType, () => setState(()=>_selectedType = i)),
                  ),
                )
              ],

              if(_pickDropMode) ...[
                _AddressField(
                  controller: _pickupController,
                  hint: 'Pickup Location',
                  icon: Icons.my_location,
                  focus: _pickupFocusNode,
                  onChanged: (v) => _updateSuggestions(v, isPickup: true),
                  onTapIcon: () => _goToCurrentLocation(),
                  onTapSuffix: () => _searchAddress(isPickup: true),
                ),
                if(_pickupSuggestions.isNotEmpty && _pickupFocusNode.hasFocus)
                  _buildSuggestions(_pickupSuggestions, true),

                const SizedBox(height: 10),
                _AddressField(
                  controller: _dropController,
                  hint: 'Drop Location',
                  icon: Icons.flag,
                  focus: _dropFocusNode,
                  onChanged: (v) => _updateSuggestions(v, isPickup: false),
                  onTapSuffix: () => _searchAddress(isPickup: false),
                ),
                if(_dropSuggestions.isNotEmpty && _dropFocusNode.hasFocus)
                  _buildSuggestions(_dropSuggestions, false),

                const SizedBox(height: 12),
                SizedBox(
                  height: 50,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _vehicles.length,
                    separatorBuilder: (_,__) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _VehicleChip(_vehicles[i], i == _selectedVehicle, () {
                      setState(() => _selectedVehicle = i);
                      if(_estimatedKm != null) _recomputeFareFromKm();
                    }),
                  ),
                )
              ],

              const SizedBox(height: 16),
              _buildPriceField(),

              const SizedBox(height: 24),

              // RECENT REQUESTS SECTION (Above Send Button)
              _buildRecentRequests(),

              const SizedBox(height: 20),

              // SEND BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))
                  ),
                  onPressed: _submitting ? null : () => _submitLiveRequest(),
                  child: Text(_submitting ? 'Sending...' : 'Send Live Request', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ───────────────── MAP UPDATE LOGIC (FOR LIVE TRACKING) ─────────────────
  void _updateMapForLiveTracking(Map<String, dynamic> data) {
    // 1. Static Pickup
    final pLat = data['pickupLat'] as double?;
    final pLng = data['pickupLng'] as double?;
    if (pLat != null && pLng != null) {
      _staticPickupPos = LatLng(pLat, pLng);
    }

    // 2. Live Provider
    final provLat = data['providerLat'] as double?;
    final provLng = data['providerLng'] as double?;

    if (provLat != null && provLng != null) {
      final newPos = LatLng(provLat, provLng);

      // Check if this is the first time we've seen provider, or if they moved significantly
      if (_liveProviderPos == null || _calcDistance(_liveProviderPos!, newPos) > 0.005) {
        _liveProviderPos = newPos;
        _liveRoutePoints = [newPos, _staticPickupPos!]; // Draw route from Provider -> Pickup

        // Ensure we fit bounds so user can see provider and pickup (Once per session)
        if (!_hasFitBounds && _mapController != null && _staticPickupPos != null) {
          _hasFitBounds = true;
          LatLngBounds bounds = _boundsFromLatLngList([newPos, _staticPickupPos!]);
          // Add some padding
          _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 100));
        }
      }
    } else {
      _liveProviderPos = null;
    }
  }

  // Helper to fit map bounds
  LatLngBounds _boundsFromLatLngList(List<LatLng> list) {
    double minLat = list.first.latitude;
    double maxLat = list.first.latitude;
    double minLng = list.first.longitude;
    double maxLng = list.first.longitude;

    for (final latLng in list) {
      if (latLng.latitude > maxLat) maxLat = latLng.latitude;
      if (latLng.latitude < minLat) minLat = latLng.latitude;
      if (latLng.longitude > maxLng) maxLng = latLng.longitude;
      if (latLng.longitude < minLng) minLng = latLng.longitude;
    }
    return LatLngBounds(southwest: LatLng(minLat, minLng), northeast: LatLng(maxLat, maxLng));
  }


  // ───────────────── HELPER WIDGETS ─────────────────

  Widget _roundBtn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)]),
        child: Icon(icon, color: Colors.black87),
      ),
    );
  }

  void _toggleMode(bool isPickDrop) {
    _dismissKeyboardAndSuggestions();
    setState(() {
      _pickDropMode = isPickDrop;
      _routePoints.clear();
      _estimatedKm = null;
      _estimatedPrice = null;
      _priceController.clear();
      if(isPickDrop) {
        _pickupTarget = _cameraTarget;
      } else {
        _dropTarget = null;
      }
    });
  }

  Widget _buildSuggestions(List<_PlaceSuggestion> list, bool isPickup) {
    return Container(
      color: Colors.white,
      constraints: const BoxConstraints(maxHeight: 150),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: list.length,
        itemBuilder: (ctx, i) => ListTile(
          title: Text(list[i].description, style: const TextStyle(fontSize: 13)),
          leading: const Icon(Icons.place, size: 16),
          onTap: () => _onSuggestionTap(list[i], isPickup: isPickup),
        ),
      ),
    );
  }

  Widget _ModeChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: selected ? _accent : const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? _accent : const Color(0xFFE0E2EC)),
        ),
        alignment: Alignment.center,
        child: Text(label, style: TextStyle(color: selected ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _AddressField({required TextEditingController controller, required String hint, required IconData icon, required FocusNode focus, required Function(String) onChanged, VoidCallback? onTapIcon, VoidCallback? onTapSuffix}) {
    return Container(
      height: 48,
      decoration: BoxDecoration(color: const Color(0xFFF5F6FA), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE0E2EC))),
      child: Row(
        children: [
          const SizedBox(width: 12),
          GestureDetector(onTap: onTapIcon, child: Icon(icon, color: Colors.grey)),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: controller, focusNode: focus, onChanged: onChanged, decoration: InputDecoration(hintText: hint, border: InputBorder.none, isDense: true))),
          IconButton(icon: const Icon(Icons.search, color: Colors.grey), onPressed: onTapSuffix),
        ],
      ),
    );
  }

  Widget _buildPriceField() {
    return Container(
      height: 48,
      decoration: BoxDecoration(color: const Color(0xFFF5F6FA), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Text('PKR', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
          const VerticalDivider(indent: 8, endIndent: 8),
          Expanded(child: TextField(
              controller: _priceController,
              keyboardType: TextInputType.number,
              readOnly: _pickDropMode,
              decoration: InputDecoration(hintText: _pickDropMode ? 'Auto-calculated' : 'Your Offer', border: InputBorder.none)
          )),
        ],
      ),
    );
  }

  Widget _buildTextField(TextEditingController c, String hint, IconData icon) {
    return Container(
      height: 48,
      decoration: BoxDecoration(color: const Color(0xFFF5F6FA), borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(icon, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: c, decoration: InputDecoration(hintText: hint, border: InputBorder.none))),
        ],
      ),
    );
  }

  // ───────────────── LOGIC HELPERS ─────────────────

  void _updatePickupFromCamera() async {
    _pickupTarget = _cameraTarget;
    final addr = await _reverseGeocode(_cameraTarget);
    if(mounted && _isPickupMapMode) _pickupController.text = addr ?? 'Pinned Location';
    if(_pickDropMode && _dropTarget != null) _updateRoute();
  }

  Future<void> _updateSuggestions(String input, {required bool isPickup}) async {
    if(input.length < 3) return;
    final url = Uri.parse('https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$input&components=country:pk&key=$_googleApiKey');
    final res = await http.get(url);
    if(res.statusCode == 200) {
      final data = json.decode(res.body);
      final list = (data['predictions'] as List).map((p) => _PlaceSuggestion(p['description'], p['place_id'])).toList();
      setState(() {
        if(isPickup) _pickupSuggestions..clear()..addAll(list);
        else _dropSuggestions..clear()..addAll(list);
      });
    }
  }

  Future<void> _onSuggestionTap(_PlaceSuggestion s, {required bool isPickup}) async {
    _dismissKeyboardAndSuggestions();
    final url = Uri.parse('https://maps.googleapis.com/maps/api/place/details/json?place_id=${s.placeId}&key=$_googleApiKey');
    final res = await http.get(url);
    if(res.statusCode == 200) {
      final data = json.decode(res.body);
      final loc = data['result']['geometry']['location'];
      final latLng = LatLng(loc['lat'], loc['lng']);

      setState(() {
        if(isPickup) {
          _pickupTarget = latLng;
          _cameraTarget = latLng;
          _pickupController.text = s.description;
          _pickupSuggestions.clear();
          _mapController?.animateCamera(CameraUpdate.newLatLng(latLng));
        } else {
          _dropTarget = latLng;
          _dropController.text = s.description;
          _dropSuggestions.clear();
        }
      });
      if(_pickDropMode) _updateRoute();
    }
  }

  Future<void> _searchAddress({required bool isPickup}) async {
    final q = isPickup ? _pickupController.text : _dropController.text;
    if(q.isEmpty) return;
    final url = Uri.parse('https://maps.googleapis.com/maps/api/geocode/json?address=$q&key=$_googleApiKey');
    final res = await http.get(url);
    if(res.statusCode == 200) {
      final data = json.decode(res.body);
      if(data['results'].isNotEmpty) {
        final loc = data['results'][0]['geometry']['location'];
        final latLng = LatLng(loc['lat'], loc['lng']);
        setState(() {
          if(isPickup) { _pickupTarget = latLng; _cameraTarget = latLng; _mapController?.animateCamera(CameraUpdate.newLatLng(latLng)); }
          else { _dropTarget = latLng; }
        });
        if(_pickDropMode) _updateRoute();
      }
    }
  }

  double _calcDistance(LatLng p1, LatLng p2) {
    var p = 0.017453292519943295;
    var a = 0.5 - cos((p2.latitude - p1.latitude) * p)/2 +
        cos(p1.latitude * p) * cos(p2.latitude * p) * (1 - cos((p2.longitude - p1.longitude) * p))/2;
    return 12742 * asin(sqrt(a));
  }

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
      shift = 0;
      result = 0;
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

  Future<void> _callPhone(String? phone) async {
    if(phone == null || phone.isEmpty) return;
    final uri = Uri.parse('tel:$phone');
    if(await canLaunchUrl(uri)) launchUrl(uri);
  }
}

// ───────────────── DATA MODELS ─────────────────
class _PlaceSuggestion {
  final String description;
  final String placeId;
  _PlaceSuggestion(this.description, this.placeId);
}

class _LiveServiceType {
  final String label;
  final IconData icon;
  final int people;
  const _LiveServiceType({required this.label, required this.icon, required this.people});
}

class _VehicleOption {
  final String label;
  final IconData icon;
  final double ratePerKm;
  const _VehicleOption({required this.label, required this.icon, required this.ratePerKm});
}

class _ServiceTypeCard extends StatelessWidget {
  final _LiveServiceType type;
  final bool selected;
  final VoidCallback onTap;
  const _ServiceTypeCard(this.type, this.selected, this.onTap);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFFECE9FF) : const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: selected ? _accent : const Color(0xFFE0E2EC)),
        ),
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(type.icon, color: selected ? _accent : Colors.grey),
            const SizedBox(height: 4),
            Text(type.label, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}

class _VehicleChip extends StatelessWidget {
  final _VehicleOption option;
  final bool selected;
  final VoidCallback onTap;
  const _VehicleChip(this.option, this.selected, this.onTap);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? _accent : const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(20),
        ),
        alignment: Alignment.center,
        child: Row(
          children: [
            Icon(option.icon, size: 18, color: selected ? Colors.white : Colors.black87),
            const SizedBox(width: 6),
            Text(option.label, style: TextStyle(color: selected ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}