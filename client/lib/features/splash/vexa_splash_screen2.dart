import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/vexa_colors.dart';
import '../../widgets/vexa_brand_mark.dart';

class VexaSplashScreen2 extends StatefulWidget {
  final VoidCallback onComplete;
  const VexaSplashScreen2({super.key, required this.onComplete});

  @override
  State<VexaSplashScreen2> createState() => _VexaSplashScreen2State();
}

class _VexaSplashScreen2State extends State<VexaSplashScreen2>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoFade;

  bool _showAppName = false;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    // Start logo animation immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.forward();

      // App name fades in 300ms after logo completes.
      Future.delayed(const Duration(milliseconds: 1100), () {
        if (!mounted) return;
        setState(() => _showAppName = true);
      });

      // Total intro duration for Screen 2.
      Future.delayed(const Duration(milliseconds: 2000), widget.onComplete);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VexaColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                Hero(
                  tag: 'ghost-logo',
                  child: ScaleTransition(
                    scale: _logoScale,
                    child: FadeTransition(
                      opacity: _logoFade,
                      child: Image.asset(
                        kVexaAppIconAsset,
                        width: 100,
                        height: 100,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.high,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            AnimatedOpacity(
              opacity: _showAppName ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
              child: Text(
                'VEXA',
                style: GoogleFonts.inter(
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                  color: VexaColors.textPrimary,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Container(
              width: 200,
              height: 4,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  valueColor:
                      const AlwaysStoppedAnimation<Color>(VexaColors.accent),
                  backgroundColor: VexaColors.surface,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'LOADING SECURE LAYERS...',
              style: GoogleFonts.inter(
                fontSize: 11,
                letterSpacing: 2,
                color: VexaColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

