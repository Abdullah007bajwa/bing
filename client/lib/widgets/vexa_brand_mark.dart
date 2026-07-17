// Shared Vexa logo + wordmark: high-res asset, cutout-style presentation, subtle motion.

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';

const String kVexaAppIconAsset = 'assets/images/app_icon.png';

/// App bar / compact row: rounded-square icon + title.
class VexaAppBarTitle extends StatelessWidget {
  const VexaAppBarTitle({super.key, this.iconSize = 30});

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _IconTile(size: iconSize),
        const SizedBox(width: 10),
        Text(
          'Vexa',
          style: GoogleFonts.syne(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: cs.onSurface,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

/// Hero-style mark: circular cutout of the real icon, soft glow, optional pulse.
class VexaBrandMark extends StatelessWidget {
  const VexaBrandMark({
    super.key,
    this.logoSize = 88,
    this.showWordmark = true,
    this.pulseLogo = true,
  });

  final double logoSize;
  final bool showWordmark;
  /// Subtle breathing scale on the icon (not the flutter_animate `.animate()` API).
  final bool pulseLogo;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final glow = cs.primary.withValues(alpha: 0.45);

    Widget logo = _GlowOrb(
      size: logoSize,
      glowColor: glow,
      child: ClipOval(
        child: Image.asset(
          kVexaAppIconAsset,
          width: logoSize,
          height: logoSize,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
          gaplessPlayback: true,
        ),
      ),
    );

    if (pulseLogo) {
      logo = logo
          .animate(onPlay: (c) => c.repeat(reverse: true))
          .scale(
            begin: const Offset(0.97, 0.97),
            end: const Offset(1, 1),
            duration: 2200.ms,
            curve: Curves.easeInOutCubic,
          );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        logo,
        if (showWordmark) ...[
          SizedBox(height: logoSize * 0.14),
          ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) => LinearGradient(
              colors: [
                cs.primary,
                const Color(0xFF6C63FF),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ).createShader(bounds),
            child: Text(
              'VEXA',
              style: GoogleFonts.syne(
                fontSize: (logoSize * 0.32).clamp(22.0, 34.0),
                fontWeight: FontWeight.w800,
                letterSpacing: 6,
                height: 1,
                color: Colors.white,
              ),
            ),
          ).animate().fadeIn(duration: 500.ms).slideY(begin: 0.12, curve: Curves.easeOutCubic),
        ],
      ],
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        boxShadow: [
          BoxShadow(
            color: cs.primary.withValues(alpha: 0.25),
            blurRadius: 12,
            spreadRadius: 0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * 0.28),
        child: Image.asset(
          kVexaAppIconAsset,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.high,
        ),
      ),
    );
  }
}

class _GlowOrb extends StatelessWidget {
  const _GlowOrb({
    required this.size,
    required this.glowColor,
    required this.child,
  });

  final double size;
  final Color glowColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: glowColor,
            blurRadius: size * 0.42,
            spreadRadius: size * 0.02,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Full-screen bootstrap: dark canvas + animated mark + optional subtitle.
class VexaLaunchShell extends StatelessWidget {
  const VexaLaunchShell({
    super.key,
    this.subtitle,
    this.showProgress = true,
  });

  final String? subtitle;
  final bool showProgress;

  @override
  Widget build(BuildContext context) {
    final shellTheme = ThemeData.dark().copyWith(
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00E5B0),
        secondary: Color(0xFF6C63FF),
        surface: Color(0xFF111318),
      ),
    );
    return Theme(
      data: shellTheme,
      child: Scaffold(
        backgroundColor: const Color(0xFF0A0B0D),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const VexaBrandMark(logoSize: 96, showWordmark: true, pulseLogo: true),
              if (subtitle != null) ...[
                const SizedBox(height: 28),
                Text(
                  subtitle!,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Colors.white54,
                  ),
                ).animate().fadeIn(delay: 200.ms),
              ],
              if (showProgress) ...[
                const SizedBox(height: 32),
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
