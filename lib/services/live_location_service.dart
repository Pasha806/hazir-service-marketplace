import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';

class LiveLocationService {
  static final LiveLocationService _i = LiveLocationService._();
  LiveLocationService._();
  factory LiveLocationService() => _i;

  StreamSubscription<Position>? _sub;
  String? _activeRequestId;

  Future<bool> _ensurePermission() async {
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever || perm == LocationPermission.denied) {
      return false;
    }
    if (!(await Geolocator.isLocationServiceEnabled())) {
      return false;
    }
    return true;
  }

  /// Start uploading provider's live location for this request.
  Future<void> start(String requestId) async {
    if (_activeRequestId == requestId && _sub != null) return;
    _activeRequestId = requestId;

    if (!await _ensurePermission()) return;

    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    final ref = FirebaseFirestore.instance
        .collection('service_requests')
        .doc(requestId)
        .collection('live')
        .doc('provider');

    // Seed doc (optional)
    await ref.set({
      'lat': 0, 'lng': 0, 'speed': 0, 'heading': 0,
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    _sub?.cancel();
    _sub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 5,   // meters
      ),
    ).listen((pos) async {
      try {
        await ref.set({
          'lat': pos.latitude,
          'lng': pos.longitude,
          'speed': pos.speed,        // m/s
          'heading': pos.heading,    // degrees
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      } catch (_) {}
    });
  }

  /// Stop uploading and optionally delete the live doc.
  Future<void> stop({bool deleteDoc = true}) async {
    _sub?.cancel();
    _sub = null;
    final rid = _activeRequestId;
    _activeRequestId = null;
    if (rid != null && deleteDoc) {
      try {
        await FirebaseFirestore.instance
            .collection('service_requests')
            .doc(rid)
            .collection('live')
            .doc('provider')
            .delete();
      } catch (_) {}
    }
  }
}
