// lib/features/settings/panic_wipe_screen.dart
// Panic wipe execution screen.
// Verifies panic code against PBKDF2 hash, then triggers full wipe.

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/storage/secure_db.dart';
import '../../core/identity/identity_service.dart';
import '../../core/storage/ephemeral_cache.dart';
import '../../relay/websocket_client.dart';
import '../../app_config.dart';

class PanicWipeScreen extends StatefulWidget {
  const PanicWipeScreen({super.key});

  @override
  State<PanicWipeScreen> createState() => _PanicWipeScreenState();
}

class _PanicWipeScreenState extends State<PanicWipeScreen> {
  final _codeController = TextEditingController();
  bool  _isWiping = false;
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
    for (var i = 0; i < a.length; i++) result |= a[i] ^ b[i];
    return result == 0;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0608),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text('Emergency Wipe', style: TextStyle(color: cs.error)),
        iconTheme: IconThemeData(color: cs.error),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),

              Icon(Icons.local_fire_department_rounded, size: 72, color: cs.error)
                  .animate(onPlay: (c) => c.repeat())
                  .scaleXY(begin: 1, end: 1.08, duration: 800.ms, curve: Curves.easeInOut)
                  .then()
                  .scaleXY(begin: 1.08, end: 1, duration: 800.ms),

              const SizedBox(height: 24),

              Text(
                'PANIC WIPE',
                style: GoogleFonts.inter(
                  fontSize: 28, fontWeight: FontWeight.w900,
                  color: cs.error, letterSpacing: 4,
                ),
              ),

              const SizedBox(height: 12),
              Text(
                'All messages, contacts, and keys will be permanently destroyed.',
                style: GoogleFonts.inter(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: 40),

              TextField(
                controller:   _codeController,
                keyboardType: TextInputType.number,
                obscureText:  true,
                maxLength:    8,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: GoogleFonts.robotoMono(color: cs.error, fontSize: 20, letterSpacing: 4),
                textAlign: TextAlign.center,
                decoration: InputDecoration(
                  hintText:   'Panic Code',
                  counterText: '',
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:   BorderSide(color: cs.error.withOpacity(0.5)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:   BorderSide(color: cs.error, width: 2),
                  ),
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: cs.error, fontSize: 13)),
              ],

              const SizedBox(height: 24),

              ElevatedButton(
                onPressed: _isWiping ? null : _triggerWipe,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.error,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(double.infinity, 56),
                ),
                child: _isWiping
                    ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                    : Text(
                        'DESTROY EVERYTHING',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w900, letterSpacing: 2),
                      ),
              ),

              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}
