import 'dart:convert';
import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';

class DirectionsResult {
  final List<LatLng> points;
  final int durationSec; // ETA seconds
  final int distanceMeters;

  DirectionsResult(this.points, this.durationSec, this.distanceMeters);
}

class DirectionsService {
  DirectionsService(this.apiKey);
  final String apiKey;

  Future<DirectionsResult?> route({
    required LatLng origin,
    required LatLng destination,
    String mode = 'driving',
  }) async {
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/directions/json'
          '?origin=${origin.latitude},${origin.longitude}'
          '&destination=${destination.latitude},${destination.longitude}'
          '&mode=$mode&key=$apiKey',
    );

    final res = await http.get(url);
    if (res.statusCode != 200) return null;
    final data = jsonDecode(res.body);
    if (data['status'] != 'OK') return null;

    final route = data['routes'][0];
    final leg = route['legs'][0];

    final poly = route['overview_polyline']['points'];
    final decoder = PolylinePoints();
    final decoded = decoder.decodePolyline(poly);
    final pts = decoded.map((p) => LatLng(p.latitude, p.longitude)).toList(growable: false);

    final dur = leg['duration']['value'] as int;
    final dist = leg['distance']['value'] as int;

    return DirectionsResult(pts, dur, dist);
  }
}
