// lib/features/settings/panic_wipe_screen.dart
// Panic wipe execution screen.
// Verifies panic code against PBKDF2 hash, then triggers full wipe.

import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/storage/secure_db.dart';
import '../../core/identity/identity_service.dart';
import '../../core/storage/ephemeral_cache.dart';
import '../../relay/websocket_client.dart';
import '../../app_config.dart';
import '../../core/theme/vexa_colors.dart';

class PanicWipeScreen extends StatefulWidget {
  const PanicWipeScreen({super.key});

  @override
  State<PanicWipeScreen> createState() => _PanicWipeScreenState();
}

class _PanicWipeScreenState extends State<PanicWipeScreen> {
  final _codeController = TextEditingController();
  bool  _isWiping = false;
  bool  _flashToggles = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _triggerWipe() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;

    setState(() { _isWiping = true; _error = null; });

    // Load stored hash + salt
    final db   = SecureDb();
    final d    = await db.db;
    final rows = await d.query('panic_config', limit: 1);

    if (rows.isEmpty) {
      setState(() { _error = 'No panic code configured.'; _isWiping = false; });
      return;
    }

    final storedHash = base64Decode(rows.first['code_hash_b64'] as String);
    final salt       = base64Decode(rows.first['salt_b64']      as String);
    final iterations = rows.first['iterations'] as int;

    // Re-derive hash from entered code
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations:   iterations,
      bits:         AppConfig.pbkdf2KeyLength * 8,
    );
    final derivedKey  = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(code)),
      nonce:     salt,
    );
    final derivedHash = await derivedKey.extractBytes();

    // Constant-time comparison
    if (!_constantTimeEquals(storedHash, derivedHash)) {
      setState(() { _error = 'Incorrect panic code.'; _isWiping = false; });
      return;
    }

    // ── WIPE ──────────────────────────────────────────────────────────────
    // 1. Disconnect relay
    await GhostRelayClient().disconnect();
    // 2. Clear in-memory cache
    EphemeralCache().clear();
    // 3. Wipe encrypted DB (overwrites then deletes)
    await SecureDb().wipeDatabase();
    // 4. Delete identity keys from Keystore / Secure Enclave
    await IdentityService().deleteAllKeys();

    // Navigate to blank state
    if (mounted) {
      Navigator.pushNamedAndRemoveUntil(context, '/onboarding', (_) => false);
    }
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  Future<void> _callEmergency() async {
    final uri = Uri(scheme: 'tel', path: '112');
    if (!await canLaunchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cannot open dialer on this device')),
      );
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _shareLocation({String? prefix}) async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location services are disabled')),
        );
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission denied')),
        );
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      final lat = pos.latitude;
      final lng = pos.longitude;

      final coords = '$lat,$lng';
      final mapsUri =
          Uri.parse('https://www.google.com/maps?q=$lat,$lng');

      await launchUrl(mapsUri, mode: LaunchMode.externalApplication);
      await Clipboard.setData(ClipboardData(text: coords));

      if (!mounted) return;
      final msg = '${prefix != null ? '$prefix: ' : ''}Location $coords';
      await SharePlus.instance.share(ShareParams(text: msg));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to get location: $e')),
      );
    }
  }

  Future<void> _sendDistressGps() async {
    await _shareLocation(prefix: 'DISTRESS GPS');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VexaColors.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const SizedBox.shrink(),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [VexaColors.emergencyGradientStart, VexaColors.background],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 8),
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 160,
                      height: 160,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Container(
                          width: 140,
                          height: 140,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: VexaColors.danger.withValues(alpha: 0.35),
                                blurRadius: 70,
                                spreadRadius: 25,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.shield_rounded,
                      size: 92,
                      color: VexaColors.danger,
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  'EMERGENCY MODE',
                  style: GoogleFonts.inter(
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                    color: VexaColors.textPrimary,
                    letterSpacing: 0.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),

                // Flashing toggles row (UI only for now)
                Row(
                  children: [
                    Icon(Icons.flash_on_rounded,
                        color: VexaColors.accent, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Flashing toggles',
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: VexaColors.textPrimary,
                        ),
                      ),
                    ),
                    Switch(
                      value: _flashToggles,
                      onChanged: (v) => setState(() => _flashToggles = v),
                      activeColor: VexaColors.accent,
                    ),
                  ],
                ),

                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'CONTACT TRUSTED FRIENDS',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                      color: VexaColors.accent,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.phone_rounded,
                            size: 20, color: Colors.white),
                        label: const Text(
                          'Call',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white),
                          backgroundColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        onPressed: _callEmergency,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.location_on_rounded,
                            size: 20, color: Colors.white),
                        label: const Text(
                          'Location',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white),
                          backgroundColor: Colors.transparent,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        onPressed: () => _shareLocation(),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 18),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VexaColors.accent,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(double.infinity, 48),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _sendDistressGps,
                    child: Text(
                      'SEND DISTRESS GPS',
                      style: GoogleFonts.inter(
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.2,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                TextField(
                  controller: _codeController,
                  keyboardType: TextInputType.number,
                  obscureText: true,
                  maxLength: 8,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  style: GoogleFonts.robotoMono(
                    color: VexaColors.danger,
                    fontSize: 20,
                    letterSpacing: 4,
                  ),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'Panic Code',
                    counterText: '',
                  ),
                ),

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: GoogleFonts.inter(
                      color: VexaColors.danger,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isWiping ? null : _triggerWipe,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: VexaColors.danger,
                      foregroundColor: VexaColors.textPrimary,
                      minimumSize: const Size(double.infinity, 56),
                      elevation: 0,
                    ),
                    child: _isWiping
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : Text(
                            'ACTIVATE PANIC CODE',
                            style: GoogleFonts.inter(
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.3,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
