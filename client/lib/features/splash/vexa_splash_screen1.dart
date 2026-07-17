import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/vexa_colors.dart';
import '../../widgets/vexa_brand_mark.dart';

class VexaSplashScreen1 extends StatefulWidget {
  final VoidCallback onNext;
  const VexaSplashScreen1({super.key, required this.onNext});

  @override
  State<VexaSplashScreen1> createState() => _VexaSplashScreen1State();
}

class _VexaSplashScreen1State extends State<VexaSplashScreen1>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _glowOpacity;

  @override
  void initState() {
    super.initState();

    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    _glowOpacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOut,
    );

    // Start animation on first frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _controller.forward();
      Future.delayed(const Duration(milliseconds: 1800), () {
        if (mounted) widget.onNext();
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glow = Container(
      width: 260,
      height: 260,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              VexaColors.accent.withOpacity(0.35),
              VexaColors.danger.withOpacity(0.22),
              Colors.transparent,
            ],
            stops: const [0.0, 0.35, 1.0],
          ),
        ),
      ),
    );

    return Scaffold(
      backgroundColor: VexaColors.background,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                FadeTransition(opacity: _glowOpacity, child: glow),
                Hero(
                  tag: 'ghost-logo',
                  child: Image.asset(
                    kVexaAppIconAsset,
                    width: 100,
                    height: 100,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.high,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'VEXA',
              style: GoogleFonts.inter(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
                color: VexaColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

