// lib/features/onboarding/onboarding_screen.dart
// First-launch experience: generate identity keypair, display public ID + QR.
// Security-first UX: no email, no password, no cloud sync.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/identity/identity_service.dart';
import '../../app_config.dart';
import 'panic_setup_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _identity = IdentityService();
  bool   _isGenerating = true;
  String _userId  = '';
  String _pubKeyB64 = '';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final kp = await _identity.generateIdentityKeyPair();
    final uid = await _identity.getUserId();
    final pk  = await _identity.getPublicKeyBase64();

    // Upload public key to Supabase (fire-and-forget; failure is non-fatal)
    unawaited(
      _identity.uploadPublicKey(
        supabaseUrl:      AppConfig.supabaseUrl,
        supabaseAnonKey:  AppConfig.supabaseAnonKey,
        jwtToken:         uid, // anonymous JWT; configure Supabase anon auth
      ),
    );

    setState(() {
      _isGenerating = false;
      _userId       = uid;
      _pubKeyB64    = pk;
    });
  }

  String get _inviteLink => '${AppConfig.deepLinkScheme}://${AppConfig.deepLinkHost}/$_userId/$_pubKeyB64';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: _isGenerating ? _buildGenerating() : _buildIdentityCard(cs),
      ),
    );
  }

  Widget _buildGenerating() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _GhostLogo(),
          const SizedBox(height: 32),
          Text(
            'Generating your identity…',
            style: GoogleFonts.inter(color: Colors.white70, fontSize: 14),
          ).animate().fadeIn(duration: 600.ms),
          const SizedBox(height: 16),
          const SizedBox(
            width: 24, height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentityCard(ColorScheme cs) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 32),
          const _GhostLogo()
              .animate()
              .fadeIn(duration: 800.ms)
              .slideY(begin: -0.2),

          const SizedBox(height: 16),
          Text(
            'You are now Ghost.',
            style: GoogleFonts.inter(
              fontSize: 26, fontWeight: FontWeight.w700, color: Colors.white,
            ),
          ).animate().fadeIn(delay: 200.ms),

          const SizedBox(height: 8),
          Text(
            'No phone. No email. Just a cryptographic identity.',
            style: GoogleFonts.inter(fontSize: 13, color: Colors.white54),
            textAlign: TextAlign.center,
          ).animate().fadeIn(delay: 300.ms),

          const SizedBox(height: 32),

          // QR code card
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color:        const Color(0xFF111318),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: cs.primary.withOpacity(0.3), width: 1),
            ),
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: QrImageView(
                    data:            _inviteLink,
                    version:         QrVersions.auto,
                    size:            200,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color:    Color(0xFF0A0B0D),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color:           Color(0xFF0A0B0D),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'Your Ghost ID',
                  style: GoogleFonts.inter(
                    fontSize: 12, color: Colors.white38, letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: _userId));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('ID copied')),
                    );
                  },
                  child: Text(
                    _formatId(_userId),
                    style: GoogleFonts.robotoMono(
                      fontSize: 11, color: cs.primary, letterSpacing: 1,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ).animate().fadeIn(delay: 400.ms).scale(begin: const Offset(0.95, 0.95)),

          const SizedBox(height: 24),

          // Share invite link
          ElevatedButton.icon(
            onPressed: () => Share.share(_inviteLink, subject: 'Add me on Ghost'),
            icon:  const Icon(Icons.share_rounded),
            label: const Text('Share Invite Link'),
          ).animate().fadeIn(delay: 500.ms).slideY(begin: 0.2),

          const SizedBox(height: 12),

          // Skip to home
          TextButton(
            onPressed: () => Navigator.pushReplacementNamed(context, '/home'),
            child: Text(
              'Continue to Contacts →',
              style: GoogleFonts.inter(color: Colors.white60),
            ),
          ).animate().fadeIn(delay: 600.ms),

          const SizedBox(height: 12),

          // Panic wipe setup (optional)
          OutlinedButton.icon(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PanicSetupScreen()),
            ),
            icon:  const Icon(Icons.shield_outlined, size: 18),
            label: const Text('Set Up Panic Code (Optional)'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white54,
              side: BorderSide(color: Colors.white24),
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ).animate().fadeIn(delay: 700.ms),

          const SizedBox(height: 32),
          _buildPrivacyNote(),
        ],
      ),
    );
  }

  Widget _buildPrivacyNote() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:        Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.lock_outline, size: 18, color: Color(0xFF00E5B0)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Your private key is stored only on this device. We cannot recover it '
              'if you uninstall the app.',
              style: GoogleFonts.inter(fontSize: 11, color: Colors.white38),
            ),
          ),
        ],
      ),
    );
  }

  String _formatId(String id) {
    if (id.length < 24) return id;
    return '${id.substring(0, 8)} ${id.substring(8, 16)} ${id.substring(16, 24)}...';
  }
}

// ── Ghost Logo ─────────────────────────────────────────────────────────────
class _GhostLogo extends StatelessWidget {
  const _GhostLogo();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72, height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              colors: [Color(0xFF00E5B0), Color(0xFF6C63FF)],
              begin:  Alignment.topLeft,
              end:    Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color:  const Color(0xFF00E5B0).withOpacity(0.4),
                blurRadius: 24,
                spreadRadius: 4,
              ),
            ],
          ),
          child: const Icon(Icons.shield_rounded, size: 36, color: Colors.white),
        ),
        const SizedBox(height: 12),
        Text(
          'GHOST',
          style: GoogleFonts.inter(
            fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 8,
            color:    Colors.white,
          ),
        ),
      ],
    );
  }
}
