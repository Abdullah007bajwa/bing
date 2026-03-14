// lib/features/settings/settings_screen.dart
// Security settings: Ghost ID, biometric lock, ephemeral timer, panic wipe.
// Screenshot blocking is always on (no toggle).

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:local_auth/local_auth.dart';
import '../../core/identity/identity_service.dart';
import '../../core/security/app_security_service.dart';
import '../../app_config.dart';
import 'panic_wipe_screen.dart';
import 'panic_setup_screen.dart';
import 'ghost_id_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _identity  = IdentityService();
  final _security = AppSecurityService();
  final _localAuth = LocalAuthentication();

  bool   _biometricLock = false;
  int    _ttlSeconds   = AppConfig.defaultTtlSeconds;
  String _userId        = '';
  String _pubKeyB64     = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = await _identity.getUserId();
    final pk  = await _identity.getPublicKeyBase64();
    final bio = await _security.isBiometricLockEnabled();
    if (mounted) setState(() {
      _userId = uid;
      _pubKeyB64 = pk;
      _biometricLock = bio;
    });
  }

  Future<void> _toggleBiometricLock(bool val) async {
    final avail = await _localAuth.isDeviceSupported();
    if (!avail) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biometric not available on this device')),
        );
      }
      return;
    }

    // If enabling, trigger biometric authentication immediately
    if (val) {
      try {
        // Add delay to ensure UI is stable before showing biometric prompt
        // (MIUI cancels biometric if called immediately after camera/navigation)
        await Future.delayed(const Duration(milliseconds: 300));

        final success = await _security.authenticate(
          reason: 'Set up biometric lock for Ghost',
          useErrorDialogs: true,
        );

        if (mounted) {
          if (success) {
            // User authenticated, enable the feature
            await _security.setBiometricLockEnabled(true);
            setState(() => _biometricLock = true);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometric lock enabled')),
            );
          } else {
            // Authentication failed or cancelled, don't enable
            setState(() => _biometricLock = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometric authentication cancelled')),
            );
          }
        }
      } catch (e) {
        if (mounted) {
          setState(() => _biometricLock = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')),
          );
        }
      }
    } else {
      // If disabling, just save the preference
      await _security.setBiometricLockEnabled(false);
      if (mounted) {
        setState(() => _biometricLock = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Biometric lock disabled')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Security Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader('Identity'),
          _SettingsCard(children: [
            ListTile(
              leading: Icon(Icons.fingerprint, color: cs.primary),
              title: const Text('Ghost ID'),
              subtitle: Text(
                _userId.isNotEmpty
                    ? '${_userId.substring(0, 12)}…${_userId.substring(_userId.length - 8)}'
                    : '—',
                style: GoogleFonts.robotoMono(fontSize: 11),
              ),
              trailing: const Icon(Icons.chevron_right_rounded, size: 20),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GhostIdScreen()),
              ),
            ),
          ]),

          const SizedBox(height: 16),
          _SectionHeader('Privacy & Security'),
          _SettingsCard(children: [
            SwitchListTile(
              secondary: Icon(Icons.lock_outlined, color: cs.primary),
              title: const Text('Biometric Lock'),
              subtitle: const Text('Require fingerprint, face, or PIN when opening or resuming app'),
              value:    _biometricLock,
              onChanged: _toggleBiometricLock,
              activeColor: cs.primary,
            ),
          ]),

          const SizedBox(height: 16),
          _SectionHeader('Ephemeral Messages'),
          _SettingsCard(children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Default message lifetime', style: GoogleFonts.inter(fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value:    _ttlSeconds.toDouble(),
                          min:      300,
                          max:      86400,
                          divisions: 20,
                          activeColor: cs.primary,
                          onChanged: (v) => setState(() => _ttlSeconds = v.round()),
                        ),
                      ),
                      Text(_formatTtl(_ttlSeconds),
                          style: GoogleFonts.robotoMono(color: cs.primary, fontSize: 12)),
                    ],
                  ),
                ],
              ),
            ),
          ]),

          const SizedBox(height: 16),
          _SectionHeader('Emergency'),
          _SettingsCard(children: [
            ListTile(
              leading: const Icon(Icons.shield_outlined, color: Colors.orange),
              title: const Text('Configure Panic Code'),
              subtitle: const Text('Set or change emergency wipe code'),
              trailing: const Icon(Icons.chevron_right_rounded, size: 16),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PanicSetupScreen())),
            ),
            const Divider(height: 1, indent: 64),
            ListTile(
              leading: Icon(Icons.local_fire_department_rounded, color: cs.error),
              title: Text('Panic Wipe', style: TextStyle(color: cs.error)),
              subtitle: const Text('Destroy all data immediately'),
              trailing: const Icon(Icons.chevron_right_rounded, size: 16),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const PanicWipeScreen())),
            ),
          ]),

          const SizedBox(height: 32),
          Center(
            child: Text(
              'Ghost v1.0.0 — Zero knowledge. Zero traces.',
              style: GoogleFonts.inter(fontSize: 11, color: Colors.white24),
            ),
          ),
          const SizedBox(height: 32),
        ].animate(interval: 50.ms).fadeIn().slideY(begin: 0.05),
      ),
    );
  }

  String _formatTtl(int s) {
    if (s < 3600) return '${s ~/ 60}m';
    if (s < 86400) return '${s ~/ 3600}h';
    return '24h';
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(text.toUpperCase(),
        style: GoogleFonts.inter(
          fontSize: 11, fontWeight: FontWeight.w700,
          color: Colors.white38, letterSpacing: 1.5,
        )),
  );
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color:        const Color(0xFF111318),
      borderRadius: BorderRadius.circular(14),
      border:       Border.all(color: Colors.white12),
    ),
    child: Column(children: children),
  );
}
