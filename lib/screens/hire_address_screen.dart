// lib/screens/hire_address_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/* ── THEME ─────────────────────────── */
const _accent = Color(0xFF7966FA);
const _sheetBg = Colors.white;
const _pillBg = Color(0xFFF2F2F2);
const _recentKey = 'recent_addresses_v1';

/* ── Insert your Google API key ─────── */
const String _googleApiKey = "AIzaSyBzvWeiJ8Jc9nRPBr_8aqLNPkiaSI0u2O0";

/* ── Data model for returning result ── */
class HireAddressResult {
  final double lat;
  final double lng;
  final String address;
  final String label;
  final String visitType;
  final String phone;

  HireAddressResult({
    required this.lat,
    required this.lng,
    required this.address,
    required this.label,
    required this.visitType,
    required this.phone,
  });

  Map<String, dynamic> toMap() => {
    'lat': lat,
    'lng': lng,
    'address': address,
    'label': label,
    'visitType': visitType,
    'phone': phone,
  };
}

class HireAddressScreen extends StatefulWidget {
  const HireAddressScreen({super.key});
  @override
  State<HireAddressScreen> createState() => _HireAddressScreenState();
}

class _HireAddressScreenState extends State<HireAddressScreen> {
  GoogleMapController? _gmaps;
  CameraPosition _initialCamera =
  const CameraPosition(target: LatLng(33.6844, 73.0479), zoom: 15);
  LatLng _center = const LatLng(33.6844, 73.0479);
  double _zoom = 15;
  bool _mapReady = false;

  String _primary = 'Locating...';
  String _full = '';

  final _phoneCtrl = TextEditingController();
  bool _loadingPhone = true;

  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  final _searchDebounce = _Debouncer(const Duration(milliseconds: 300));
  bool _loadingSuggest = false;
  List<_Place> _suggestions = [];

  final List<_VisitType> _types = const [
    _VisitType('Standard', Icons.handyman_outlined),
    _VisitType('Emergency', Icons.warning_amber_rounded),
    _VisitType('Inspection', Icons.search_rounded),
    _VisitType('With Parts', Icons.inventory_2_outlined),
  ];
  int _typeIndex = 0;

  List<_RecentAddress> _recents = [];
  List<String> _savedAddresses = [];

  final _revDebounce = _Debouncer(const Duration(milliseconds: 350));

  @override
  void initState() {
    super.initState();
    _initPhone();
    _loadRecents();
    _loadSaved();
    _initLocation();

    _searchFocus.addListener(() {
      setState(() {}); // rebuild so recents show/hide smoothly
    });
  }

  @override
  void dispose() {
    _gmaps?.dispose();
    _phoneCtrl.dispose();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  Future<void> _initPhone() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
        final phone = (doc.data() ?? {})['phone']?.toString();
        if (phone != null && phone.isNotEmpty) {
          _phoneCtrl.text = phone;
        }
      }
    } catch (_) {} finally {
      if (mounted) setState(() => _loadingPhone = false);
    }
  }

  Future<void> _initLocation() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm != LocationPermission.denied &&
          perm != LocationPermission.deniedForever) {
        final pos = await Geolocator.getCurrentPosition(
            desiredAccuracy: LocationAccuracy.high);
        _center = LatLng(pos.latitude, pos.longitude);
        _initialCamera = CameraPosition(target: _center, zoom: 16);
        await _reverseAt(_center);
      }
    } catch (_) {} finally {
      if (!mounted) return;
      setState(() => _mapReady = true);
    }
  }

  Future<void> _reverseAt(LatLng p) async {
    _revDebounce(() async {
      try {
        final res = await _reverseGeocodeGoogle(p.latitude, p.longitude);
        if (!mounted) return;
        setState(() {
          _primary = res.primary;
          _full = res.full;
          _searchCtrl.text = res.primary;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _primary = 'Dropped pin';
          _full = 'Unknown address';
          _searchCtrl.text = _primary;
        });
      }
    });
  }

  void _onCameraMove(CameraPosition pos) {
    _center = pos.target;
    _zoom = pos.zoom;
  }

  void _onCameraIdle() {
    _reverseAt(_center);
  }

  void _onQueryChanged(String q) {
    _searchDebounce(() async {
      final query = q.trim();
      if (query.isEmpty) {
        if (mounted) setState(() => _suggestions = []);
        return;
      }
      if (mounted) setState(() => _loadingSuggest = true);
      try {
        final suggestions = await _searchPlacesGoogle(query);
        if (!mounted) return;
        setState(() {
          _suggestions = suggestions;
          _loadingSuggest = false;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _suggestions = [];
          _loadingSuggest = false;
        });
      }
    });
  }

  Future<void> _selectSuggestion(_Place s) async {
    final target = LatLng(s.lat, s.lon);
    await _gmaps?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: target, zoom: math.max(_zoom, 16)),
      ),
    );
    setState(() {
      _suggestions = [];
      _primary = s.primary.isEmpty ? 'Dropped pin' : s.primary;
      _full = s.full;
      _center = target;
      _searchCtrl.text = s.primary;
    });
  }

  Future<void> _loadRecents() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_recentKey) ?? [];
    _recents = list.map((s) => _RecentAddress.fromMap(jsonDecode(s))).toList();
    setState(() {});
  }

  Future<void> _pushRecent(_RecentAddress a) async {
    final prefs = await SharedPreferences.getInstance();
    _recents.removeWhere((e) =>
    (e.lat.toStringAsFixed(6) == a.lat.toStringAsFixed(6)) &&
        (e.lng.toStringAsFixed(6) == a.lng.toStringAsFixed(6)));
    _recents.insert(0, a);

    if (_recents.length > 5) {
      _recents = _recents.sublist(0, 5);
    }

    await prefs.setStringList(
      _recentKey,
      _recents.map((e) => jsonEncode(e.toMap())).toList(),
    );
    setState(() {});
  }

  Future<void> _clearAllRecents() async {
    final prefs = await SharedPreferences.getInstance();
    _recents.clear();
    await prefs.remove(_recentKey);
    setState(() {});
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    _savedAddresses = prefs.getStringList("saved_address_names") ?? [];
    setState(() {});
  }

  Future<void> _saveAddressName(String name) async {
    final prefs = await SharedPreferences.getInstance();
    if (!_savedAddresses.contains(name)) {
      _savedAddresses.insert(0, name);
      if (_savedAddresses.length > 10) {
        _savedAddresses = _savedAddresses.sublist(0, 10);
      }
      await prefs.setStringList("saved_address_names", _savedAddresses);
    }
    setState(() {});
  }

  Future<void> _deleteSaved(String name) async {
    final prefs = await SharedPreferences.getInstance();
    _savedAddresses.remove(name);
    await prefs.setStringList("saved_address_names", _savedAddresses);
    setState(() {});
  }

  Future<void> _onContinue() async {
    final phone = _phoneCtrl.text.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a phone number')),
      );
      return;
    }

    final labelForSave = _primary.isEmpty ? 'Selected location' : _primary;
    final result = HireAddressResult(
      lat: _center.latitude,
      lng: _center.longitude,
      address: _full.isEmpty ? labelForSave : _full,
      label: labelForSave,
      visitType: _types[_typeIndex].name,
      phone: phone,
    );

    await _pushRecent(_RecentAddress(
      label: result.label,
      address: result.address,
      lat: result.lat,
      lng: result.lng,
    ));

    if (!mounted) return;
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.grey[200],
      body: Stack(
        children: [
          Positioned.fill(
            child: !_mapReady
                ? const Center(child: CircularProgressIndicator())
                : GoogleMap(
              initialCameraPosition: _initialCamera,
              onMapCreated: (c) => _gmaps = c,
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              onCameraMove: _onCameraMove,
              onCameraIdle: _onCameraIdle,
            ),
          ),
          IgnorePointer(
            child: Center(
              child: Transform.translate(
                offset: const Offset(0, -14),
                child: const Icon(Icons.place_rounded,
                    size: 40, color: Colors.redAccent),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            right: 8,
            child: _RoundIconButton(
              icon: Icons.my_location,
              onTap: () async {
                final pos = await Geolocator.getCurrentPosition(
                    desiredAccuracy: LocationAccuracy.high);
                final here = LatLng(pos.latitude, pos.longitude);
                await _gmaps?.animateCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(target: here, zoom: math.max(_zoom, 16)),
                  ),
                );
                await _reverseAt(here);
                setState(() {
                  _center = here;
                });
              },
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: 0.4,
            minChildSize: 0.25,
            maxChildSize: 0.92,
            builder: (context, controller) {
              return Container(
                decoration: const BoxDecoration(
                  color: _sheetBg,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: ListView(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.black26,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    _SearchField(
                      controller: _searchCtrl,
                      focusNode: _searchFocus,
                      hint: 'Search address or place',
                      onChanged: _onQueryChanged,
                      onClear: () {
                        _searchCtrl.clear();
                        setState(() => _suggestions = []);
                      },
                    ),
                    if (_loadingSuggest)
                      const LinearProgressIndicator(
                          minHeight: 2, color: _accent),
                    if (_searchFocus.hasFocus &&
                        _searchCtrl.text.isEmpty &&
                        _recents.isNotEmpty)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 12),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Recent Searches",
                                  style:
                                  TextStyle(fontWeight: FontWeight.bold)),
                              TextButton(
                                onPressed: _clearAllRecents,
                                child: const Text("Clear All",
                                    style: TextStyle(color: Colors.red)),
                              ),
                            ],
                          ),
                          ..._recents.map((r) => _RecentTile(
                            data: r,
                            onTap: () async {
                              final p = LatLng(r.lat, r.lng);
                              await _gmaps?.animateCamera(
                                CameraUpdate.newCameraPosition(
                                    CameraPosition(
                                        target: p,
                                        zoom: math.max(_zoom, 16))),
                              );
                              setState(() {
                                _primary = r.label;
                                _full = r.address;
                                _searchCtrl.text = r.label;
                                _center = p;
                              });
                            },
                          ))
                        ],
                      ),
                    if (_suggestions.isNotEmpty)
                      Column(
                        children: _suggestions
                            .map((s) => _SuggestionTile(
                          place: s,
                          onTap: () => _selectSuggestion(s),
                        ))
                            .toList(),
                      ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 48,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemBuilder: (_, i) {
                          final t = _types[i];
                          final selected = _typeIndex == i;
                          return ChoiceChip(
                            label: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(t.icon,
                                    size: 18,
                                    color: selected
                                        ? Colors.white
                                        : Colors.black54),
                                const SizedBox(width: 6),
                                Text(t.name),
                              ],
                            ),
                            selected: selected,
                            onSelected: (_) =>
                                setState(() => _typeIndex = i),
                            selectedColor: _accent,
                            backgroundColor: _pillBg,
                            labelStyle: TextStyle(
                                color: selected
                                    ? Colors.white
                                    : Colors.black),
                          );
                        },
                        separatorBuilder: (_, __) =>
                        const SizedBox(width: 8),
                        itemCount: _types.length,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text("Contact number",
                        style: Theme.of(context).textTheme.titleMedium),
                    _PhoneField(
                        controller: _phoneCtrl, loading: _loadingPhone),
                    const SizedBox(height: 12),
                    _CurrentSelectionCard(primary: _primary, full: _full),
                    if (_savedAddresses.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text("Saved addresses",
                          style: Theme.of(context).textTheme.titleMedium),
                      ..._savedAddresses.map((name) => ListTile(
                        leading:
                        const Icon(Icons.star, color: _accent),
                        title: Text(name),
                        onTap: () async {
                          final res =
                          await _searchPlacesGoogle(name);
                          if (res.isNotEmpty) {
                            final p = LatLng(
                                res.first.lat, res.first.lon);
                            await _gmaps?.animateCamera(
                              CameraUpdate.newCameraPosition(
                                  CameraPosition(
                                      target: p,
                                      zoom: math.max(_zoom, 16))),
                            );
                            setState(() {
                              _primary = res.first.primary;
                              _full = res.first.full;
                              _searchCtrl.text = res.first.primary;
                              _center = p;
                            });
                          }
                        },
                        trailing: IconButton(
                          icon: const Icon(Icons.delete,
                              color: Colors.red),
                          onPressed: () => _deleteSaved(name),
                        ),
                      )),
                    ],
                    const SizedBox(height: 80),
                  ],
                ),
              );
            },
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + MediaQuery.of(context).padding.bottom,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
              onPressed: _onContinue,
              child: const Text("Continue",
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18)),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: _RoundIconButton(
              icon: Icons.arrow_back_ios_new_rounded,
              onTap: () => Navigator.of(context).maybePop(),
            ),
          ),
        ],
      ),
    );
  }
}

/* MODELS */
class _Place {
  final String primary;
  final String full;
  final double lat;
  final double lon;
  _Place(
      {required this.primary,
        required this.full,
        required this.lat,
        required this.lon});
}

/* ✅ CLEANED GEOCODE (no Plus Codes) */
Future<_Place> _reverseGeocodeGoogle(double lat, double lon) async {
  final uri = Uri.parse(
      "https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lon&key=$_googleApiKey");
  final res = await http.get(uri);
  if (res.statusCode == 200) {
    final j = jsonDecode(res.body);
    final results = (j['results'] as List);
    if (results.isNotEmpty) {
      String formatted = results[0]['formatted_address'] ?? '';
      if (formatted.contains("+")) {
        final parts = formatted.split(" ");
        if (parts.first.contains("+")) {
          formatted = parts.sublist(1).join(" ").trim();
        }
      }
      return _Place(
          primary: formatted, full: formatted, lat: lat, lon: lon);
    }
  }
  return _Place(
      primary: "Unknown address",
      full: "Unknown address",
      lat: lat,
      lon: lon);
}

Future<List<_Place>> _searchPlacesGoogle(String q) async {
  final uri = Uri.parse(
      "https://maps.googleapis.com/maps/api/place/autocomplete/json?input=$q&key=$_googleApiKey");
  final res = await http.get(uri);
  if (res.statusCode != 200) return [];
  final j = jsonDecode(res.body);
  final preds = (j['predictions'] as List);
  List<_Place> results = [];
  for (var p in preds) {
    final desc = p['description'] ?? '';
    final placeId = p['place_id'];
    String cleanedDesc = desc;
    if (cleanedDesc.contains("+")) {
      final parts = cleanedDesc.split(" ");
      if (parts.first.contains("+")) {
        cleanedDesc = parts.sublist(1).join(" ").trim();
      }
    }
    final detUri = Uri.parse(
        "https://maps.googleapis.com/maps/api/place/details/json?place_id=$placeId&key=$_googleApiKey");
    final detRes = await http.get(detUri);
    if (detRes.statusCode == 200) {
      final dj = jsonDecode(detRes.body);
      final loc = dj['result']?['geometry']?['location'];
      if (loc != null) {
        results.add(_Place(
          primary: cleanedDesc,
          full: cleanedDesc,
          lat: loc['lat'],
          lon: loc['lng'],
        ));
      }
    }
  }
  return results;
}

/* HELPERS */
class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _RoundIconButton({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(0.75),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10.0),
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback onClear;

  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: _pillBg,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.search, color: Colors.black54),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              style: const TextStyle(color: Colors.black),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: const TextStyle(color: Colors.black45),
                border: InputBorder.none,
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            IconButton(
              onPressed: onClear,
              icon: const Icon(Icons.close, color: Colors.black45),
              splashRadius: 18,
            ),
        ],
      ),
    );
  }
}

class _PhoneField extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  const _PhoneField({required this.controller, required this.loading});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _pillBg,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          const Icon(Icons.phone_rounded, color: Colors.black54),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: Colors.black),
              decoration: InputDecoration(
                hintText: loading ? 'Loading…' : 'Enter phone number',
                hintStyle: const TextStyle(color: Colors.black45),
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CurrentSelectionCard extends StatelessWidget {
  final String primary;
  final String full;
  const _CurrentSelectionCard({required this.primary, required this.full});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _pillBg,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(Icons.location_pin, color: Colors.black54),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              full.isEmpty ? primary : full,
              style: const TextStyle(color: Colors.black),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SuggestionTile extends StatelessWidget {
  final _Place place;
  final VoidCallback onTap;
  const _SuggestionTile({required this.place, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.place_outlined, color: Colors.black54),
      title: Text(place.primary,
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.w700)),
      subtitle: Text(place.full,
          style: const TextStyle(color: Colors.black54),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      onTap: onTap,
    );
  }
}

class _VisitType {
  final String name;
  final IconData icon;
  const _VisitType(this.name, this.icon);
}

class _RecentAddress {
  final String label;
  final String address;
  final double lat;
  final double lng;
  _RecentAddress(
      {required this.label,
        required this.address,
        required this.lat,
        required this.lng});
  Map<String, dynamic> toMap() =>
      {'label': label, 'address': address, 'lat': lat, 'lng': lng};
  factory _RecentAddress.fromMap(Map<String, dynamic> m) => _RecentAddress(
    label: (m['label'] ?? '') as String,
    address: (m['address'] ?? '') as String,
    lat: (m['lat'] as num).toDouble(),
    lng: (m['lng'] as num).toDouble(),
  );
}

class _Debouncer {
  _Debouncer(this.delay);
  final Duration delay;
  Timer? _timer;
  Future<void> call(Future<void> Function() job) async {
    _timer?.cancel();
    _timer = Timer(delay, () {
      job();
    });
  }
}

class _RecentTile extends StatelessWidget {
  final _RecentAddress data;
  final VoidCallback onTap;
  const _RecentTile({required this.data, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.history, color: Colors.black45),
      title: Text(data.label.isEmpty ? 'Selected location' : data.label,
          style: const TextStyle(
              color: Colors.black, fontWeight: FontWeight.w700)),
      subtitle: Text(data.address,
          style: const TextStyle(color: Colors.black54),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
    );
  }
}
