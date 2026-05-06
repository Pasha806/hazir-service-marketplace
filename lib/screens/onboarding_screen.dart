import 'package:flutter/material.dart';
import 'signin_onboarding_screen.dart';

// --- Fade transition helper ---
void pushWithFade(BuildContext context, Widget page) {
  Navigator.of(context).pushReplacement(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 500),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, animation, __, child) =>
        FadeTransition(opacity: animation, child: child),
  ));
}

class OnboardingScreen extends StatefulWidget {
  final VoidCallback? onDone;

  const OnboardingScreen({super.key, this.onDone});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final PageController _controller = PageController();
  int _page = 0;

  void _goNext() {
    if (_page == 0) {
      _controller.nextPage(duration: const Duration(milliseconds: 400), curve: Curves.ease);
    } else {
      if (widget.onDone != null) {
        widget.onDone!();
      } else {
        pushWithFade(context, const SignInOnboardingScreen());
      }
    }
  }

  void _skip() {
    if (widget.onDone != null) {
      widget.onDone!();
    } else {
      pushWithFade(context, const SignInOnboardingScreen());
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Top-Left Ellipse, flush to corner
            Positioned(
              top: 0,
              left: 0,
              child: Image.asset(
                'assets/images/CORNER.png',
                width: 90,
                height: 90,
                fit: BoxFit.cover,
              ),
            ),
            // Main Onboarding Content
            PageView(
              controller: _controller,
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                _OnboardContent(
                  image: 'assets/images/SCREEN1.png',
                  title: "Professionals & Expert near to you",
                  description: "Connect with trusted professionals in your area for reliable services and more.",
                  showArrow: true,
                  showSkip: true,
                  onButton: _goNext,
                  onSkip: _skip,
                  buttonText: null,
                  indicatorPage: _page,
                  totalPages: 2,
                ),
                _OnboardContent(
                  image: 'assets/images/SCREEN2.png',
                  title: "Hire For Home Services",
                  description: "Book professional cleaning services tailored to your needs, ensuring a spotless and refreshing home environment.",
                  showArrow: false,
                  showSkip: true,
                  onButton: _skip,
                  onSkip: _skip,
                  buttonText: "Get Started",
                  indicatorPage: _page,
                  totalPages: 2,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OnboardContent extends StatelessWidget {
  final String image;
  final String title, description;
  final bool showArrow;
  final bool showSkip;
  final VoidCallback onButton;
  final VoidCallback onSkip;
  final String? buttonText;
  final int indicatorPage;
  final int totalPages;

  const _OnboardContent({
    required this.image,
    required this.title,
    required this.description,
    required this.showArrow,
    required this.showSkip,
    required this.onButton,
    required this.onSkip,
    this.buttonText,
    required this.indicatorPage,
    required this.totalPages,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Column(
      children: [
        // Top row with Skip
        Padding(
          padding: const EdgeInsets.only(top: 18, right: 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (showSkip)
                ElevatedButton(
                  onPressed: onSkip,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD2F4E3),
                    foregroundColor: const Color(0xFF3CA87B),
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 7),
                    textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                  ),
                  child: const Text('Skip'),
                ),
            ],
          ),
        ),
        // Big, edge-to-edge image, rounded, perfectly centered
        Padding(
          padding: EdgeInsets.only(top: size.height * 0.05, bottom: 22),
          child: Container(
            width: size.width,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(36),
            ),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: 1.13, // Adjust if needed for your figma look
              child: Image.asset(
                image,
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        // Title
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 16, right: 16),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.bold,
              color: Colors.black,
              height: 1.19,
              letterSpacing: -0.5,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        // Description
        Padding(
          padding: const EdgeInsets.only(top: 14, left: 26, right: 26),
          child: Text(
            description,
            style: const TextStyle(
              fontSize: 15.5,
              color: Color(0xFF64677A),
              height: 1.32,
              fontWeight: FontWeight.w400,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 22),
        // Page Indicator
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(totalPages, (i) => AnimatedContainer(
            duration: const Duration(milliseconds: 350),
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            width: indicatorPage == i ? 11 : 6,
            height: indicatorPage == i ? 11 : 6,
            decoration: BoxDecoration(
              color: indicatorPage == i ? const Color(0xFF7966FA) : const Color(0xFFDDDBFF),
              shape: BoxShape.circle,
            ),
          )),
        ),
        // Arrow or Button
        Padding(
          padding: const EdgeInsets.only(bottom: 38, left: 24, right: 24, top: 8),
          child: showArrow
              ? Center(
            child: Ink(
              decoration: const ShapeDecoration(
                color: Color(0xFF7966FA),
                shape: CircleBorder(),
              ),
              child: IconButton(
                icon: const Icon(Icons.arrow_forward, color: Colors.white, size: 28),
                onPressed: onButton,
              ),
            ),
          )
              : SizedBox(
            width: 192,
            height: 51,
            child: ElevatedButton(
              onPressed: onButton,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF7966FA),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(13)),
              ),
              child: Text(
                buttonText ?? "Get Started",
                style: const TextStyle(
                  fontSize: 17,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
