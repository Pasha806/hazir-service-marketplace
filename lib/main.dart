// lib/main.dart
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ✅ Intl date formatting (Option B)
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'firebase_options.dart';
import 'screens/splash_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/signin_onboarding_screen.dart';
import 'screens/login_screen.dart';
import 'screens/main_screen.dart';
import 'screens/provider_dashboard_screen.dart';
import 'admin/admin_login.dart';

// Use a navigator key so we can navigate even if a widget is unmounted.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Firebase first
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // ✅ Initialize intl DateFormat symbols once (works for mobile + web).
  try {
    final deviceLocale = WidgetsBinding.instance.platformDispatcher.locale;
    final lang = deviceLocale.languageCode; // e.g., "en"
    final country = deviceLocale.countryCode; // e.g., "US"
    final chosen =
    (country == null || country.isEmpty) ? lang : '${lang}_$country';

    Intl.defaultLocale = chosen;
    await initializeDateFormatting(chosen);
  } catch (_) {
    // Fallback to plain English to avoid "Lookup failed: DateFormat"
    Intl.defaultLocale = 'en';
    await initializeDateFormatting('en');
  }

  runApp(const HazirApp());
}

class HazirApp extends StatelessWidget {
  const HazirApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: appNavigatorKey,
      title: 'Hazir Service App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      debugShowCheckedModeBanner: false,
      home: const LaunchGate(),
      routes: {
        '/splash': (_) => const SplashScreen(),
        '/onboarding': (_) => const OnboardingScreen(),
        '/signin_onboarding': (_) => const SignInOnboardingScreen(),
        '/login': (_) => const LoginScreen(),
        '/home': (_) => const MainScreen(),
        '/provider_dashboard': (_) => const ProviderDashboardScreen(),
        '/admin-login': (_) => const AdminLoginScreen(),
      },
    );
  }
}

class LaunchGate extends StatefulWidget {
  const LaunchGate({super.key});
  @override
  State<LaunchGate> createState() => _LaunchGateState();
}

class _LaunchGateState extends State<LaunchGate> {
  // Start with splash and always show it for a short time on app open.
  Widget _screen = const SplashScreen();

  @override
  void initState() {
    super.initState();
    _decideFirstScreen();
  }

  Future<void> _decideFirstScreen() async {
    // Always hold splash for a moment so it shows on every cold start.
    const splashHold = Duration(milliseconds: 1500);
    final hold = Future<void>.delayed(splashHold);

    final prefs = await SharedPreferences.getInstance();
    final onboardingSeen = prefs.getBool('onboarding_seen') ?? false; // never reset this

    final user = FirebaseAuth.instance.currentUser;

    // If onboarding not seen: show onboarding after splash
    if (!onboardingSeen) {
      await hold;
      if (!mounted) return;
      setState(() {
        _screen = OnboardingScreen(
          onDone: () async {
            await prefs.setBool('onboarding_seen', true);
            final nav = appNavigatorKey.currentState;
            if (nav == null) return;
            nav.pushReplacement(
              PageRouteBuilder(
                transitionDuration: const Duration(milliseconds: 350),
                pageBuilder: (_, __, ___) => const SignInOnboardingScreen(),
                transitionsBuilder: (_, a, __, child) =>
                    FadeTransition(opacity: a, child: child),
              ),
            );
          },
        );
      });
      return;
    }

    // If not logged in → go to sign-in onboarding after splash
    if (user == null) {
      await hold;
      if (!mounted) return;
      setState(() => _screen = const SignInOnboardingScreen());
      return;
    }

    // Logged in → figure out the right destination after splash
    final dest = await _nextForLoggedIn(user);
    await hold;
    if (!mounted) return;
    setState(() => _screen = dest);
  }

  Future<Widget> _nextForLoggedIn(User user) async {
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final data = doc.data();
      final prefs = await SharedPreferences.getInstance();

      final lastMode =
          prefs.getString('last_mode') ?? (data?['last_mode'] as String?) ?? 'seeker';
      final provider = data?['provider'];
      final status =
      (provider is Map && provider['status'] is String) ? provider['status'] as String : null;

      if (status == 'approved' && lastMode == 'provider') {
        return const ProviderDashboardScreen();
      }
    } catch (_) {
      // If anything fails, just land on seeker main.
    }
    return const MainScreen();
  }

  @override
  Widget build(BuildContext context) => _screen;
}