// lib/features/settings/settings_screen.dart
// Security settings: screenshot protection toggle, ephemeral TTL config,
// biometric lock, view Ghost ID, and panic wipe access.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_windowmanager/flutter_windowmanager.dart';
import 'package:local_auth/local_auth.dart';
import 'package:share_plus/share_plus.dart';
import '../../core/identity/identity_service.dart';
import '../../app_config.dart';
import 'panic_wipe_screen.dart';
import 'panic_setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _identity  = IdentityService();
  final _localAuth = LocalAuthentication();

  bool   _screenshotBlocked = true;
  bool   _biometricLock     = false;
  int    _ttlSeconds        = AppConfig.defaultTtlSeconds;
  String _userId            = '';
  String _pubKeyB64         = '';

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final uid = await _identity.getUserId();
    final pk  = await _identity.getPublicKeyBase64();
    setState(() { _userId = uid; _pubKeyB64 = pk; });
  }

  Future<void> _toggleScreenshotBlock(bool val) async {
    if (val) {
      await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
    } else {
      await FlutterWindowManager.clearFlags(FlutterWindowManager.FLAG_SECURE);
    }
    setState(() => _screenshotBlocked = val);
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
              title: const Text('Your Ghost ID'),
              subtitle: Text(
                _userId.isNotEmpty
                    ? '${_userId.substring(0, 12)}…${_userId.substring(_userId.length - 8)}'
                    : '—',
                style: GoogleFonts.robotoMono(fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.share_rounded, size: 18),
                onPressed: () => Share.share(
                  'ghost://add/$_userId/$_pubKeyB64',
                  subject: 'My Ghost ID',
                ),
              ),
            ),
          ]),

          const SizedBox(height: 16),
          _SectionHeader('Privacy & Security'),
          _SettingsCard(children: [
            SwitchListTile(
              secondary: Icon(Icons.screenshot_monitor_rounded, color: cs.primary),
              title: const Text('Block Screenshots'),
              subtitle: const Text('Prevent screen capture (Android)'),
              value:    _screenshotBlocked,
              onChanged: _toggleScreenshotBlock,
              activeColor: cs.primary,
            ),
            const Divider(height: 1, indent: 64),
            SwitchListTile(
              secondary: Icon(Icons.lock_outlined, color: cs.primary),
              title: const Text('Biometric Lock'),
              subtitle: const Text('Require fingerprint to open app'),
              value:    _biometricLock,
              onChanged: (val) async {
                final avail = await _localAuth.isDeviceSupported();
                if (!avail) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Biometric not available on this device')),
                  );
                  return;
                }
                setState(() => _biometricLock = val);
              },
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
