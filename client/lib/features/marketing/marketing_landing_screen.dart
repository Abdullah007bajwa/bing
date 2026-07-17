import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/vexa_colors.dart';
import '../../widgets/vexa_brand_mark.dart';

class MarketingLandingScreen extends StatelessWidget {
  const MarketingLandingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VexaColors.background,
      body: SingleChildScrollView(
        child: Column(
          children: [
            _NavBar(),
            _HeroSection(),
            _FeatureCards(),
            _SecurityOverview(),
            _VisualPreview(),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

class _NavBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    const links = ['Features', 'Download', 'Security', 'Contact'];
    final isNarrow = MediaQuery.of(context).size.width < 900;

    return Container(
      color: VexaColors.background,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      child: Row(
        children: [
          const VexaBrandMark(showWordmark: true),
          const Spacer(),
          if (!isNarrow)
            Row(
              children: links
                  .map(
                    (t) => Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        t.toUpperCase(),
                        style: GoogleFonts.inter(
                          color: VexaColors.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          const Spacer(),
          _DownloadNowButton(),
        ],
      ),
    );
  }
}

class _DownloadNowButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: VexaColors.textPrimary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        'Download Now',
        style: GoogleFonts.inter(
          color: Colors.black,
          fontWeight: FontWeight.w900,
          fontSize: 13,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      color: VexaColors.background,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          if (constraints.maxWidth < 800) {
            return Column(
              children: [
                _PhoneMock(),
                const SizedBox(height: 22),
                _HeroCopy(),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: _PhoneMock()),
              Expanded(child: _HeroCopy()),
            ],
          );
        },
      ),
    );
  }
}

class _PhoneMock extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 240,
        height: 420,
        decoration: BoxDecoration(
          color: VexaColors.surface,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: VexaColors.divider),
        ),
        child: const Center(
          child: Icon(Icons.chat_bubble_outline_rounded, size: 74, color: Colors.white38),
        ),
      ),
    );
  }
}

class _HeroCopy extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'THE FUTURE OF PRIVACY.',
          style: GoogleFonts.inter(
            color: VexaColors.textPrimary,
            fontSize: 40,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Encrypted, Disappearing, Panic-Proof.',
          style: GoogleFonts.inter(
            color: VexaColors.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w300,
          ),
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: VexaColors.accent),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'DOWNLOAD VEXA',
                style: GoogleFonts.inter(
                  color: VexaColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _StoreButton('App Store'),
                  const SizedBox(width: 12),
                  _StoreButton('Google Play'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StoreButton extends StatelessWidget {
  final String label;
  const _StoreButton(this.label);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: VexaColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: VexaColors.accent),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.download_rounded, size: 18, color: VexaColors.accent),
          const SizedBox(width: 8),
          Text(
            label,
            style: GoogleFonts.inter(
              color: VexaColors.textPrimary,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCards extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 900;

    Widget card(
      IconData icon,
      String title,
      String desc,
    ) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: VexaColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: VexaColors.accent),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28, color: VexaColors.accent),
            const SizedBox(height: 12),
            Text(
              title,
              style: GoogleFonts.inter(
                color: VexaColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              desc,
              style: GoogleFonts.inter(
                color: VexaColors.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    }

    final cards = [
      card(Icons.timer_rounded, 'CHAT DISAPPEARING', 'Set self-destruct timers on your messages.'),
      card(Icons.security_rounded, 'EMERGENCY MODE', 'Instant panic protocol + distress signals.'),
      card(Icons.fingerprint_rounded, 'BIOMETRIC SECURITY', 'Face ID and Touch ID for secure access.'),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 18),
      child: LayoutBuilder(
        builder: (ctx, c) {
          if (isNarrow) {
            return Column(
              children: cards
                  .map((w) => Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: w,
                      ))
                  .toList(),
            );
          }

          return Row(
            children: [
              Expanded(child: cards[0]),
              const SizedBox(width: 14),
              Expanded(child: cards[1]),
              const SizedBox(width: 14),
              Expanded(child: cards[2]),
            ],
          );
        },
      ),
    );
  }
}

class _SecurityOverview extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 900;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final left = _SecurityCard();
          final right = Text(
            'Total control over your security landscape, all from one clean menu.',
            style: GoogleFonts.inter(
              color: VexaColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.3,
            ),
          );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                left,
                const SizedBox(height: 16),
                right,
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 2, child: left),
              const SizedBox(width: 18),
              Expanded(flex: 3, child: right),
            ],
          );
        },
      ),
    );
  }
}

class _SecurityCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: VexaColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VexaColors.accent.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SECURITY SETTINGS OVERVIEW',
            style: GoogleFonts.inter(
              color: VexaColors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Icon(Icons.fingerprint_rounded, color: VexaColors.accent),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Biometric Login',
                    style: GoogleFonts.inter(color: VexaColors.textPrimary, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Active',
                    style: GoogleFonts.inter(color: VexaColors.activeGreen, fontWeight: FontWeight.w900, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          _MiniLine(Icons.timer_rounded, 'Chat Disappearing Timer'),
          const SizedBox(height: 10),
          _MiniLine(Icons.shield_rounded, 'Panic Code Setup'),
        ],
      ),
    );
  }
}

class _MiniLine extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MiniLine(this.icon, this.label);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: VexaColors.accent),
        const SizedBox(width: 10),
        Text(
          label,
          style: GoogleFonts.inter(color: VexaColors.textSecondary, fontWeight: FontWeight.w700, fontSize: 13),
        ),
      ],
    );
  }
}

class _VisualPreview extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 900;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'VISUAL PREVIEW',
            style: GoogleFonts.inter(
              color: VexaColors.accent,
              fontSize: 13,
              letterSpacing: 2,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 16),
          if (isNarrow)
            Column(
              children: const [
                _SmallPhoneMock(),
                SizedBox(height: 14),
                _SmallPhoneMock(),
              ],
            )
          else
            Row(
              children: const [
                Expanded(child: _SmallPhoneMock()),
                SizedBox(width: 14),
                Expanded(child: _SmallPhoneMock()),
              ],
            ),
        ],
      ),
    );
  }
}

class _SmallPhoneMock extends StatelessWidget {
  const _SmallPhoneMock();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 360,
      decoration: BoxDecoration(
        color: VexaColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: VexaColors.divider),
      ),
      child: const Center(
        child: Icon(Icons.smartphone_rounded, size: 84, color: Colors.white38),
      ),
    );
  }
}

