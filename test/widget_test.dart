import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:projects/main.dart';

void main() {
  testWidgets('App launches and shows login screen', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const HazirApp());

    // Look for the login screen text
    expect(find.text('Login Screen UI will go here'), findsOneWidget);
  });
}
