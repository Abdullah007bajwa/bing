// lib/features/settings/panic_setup_screen.dart
// Configure a panic code (4–8 digits).
// Stored as PBKDF2-SHA512 hash with salt — never plaintext.
// Entering this code triggers full app wipe.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/storage/secure_db.dart';
import '../../app_config.dart';

class PanicSetupScreen extends StatefulWidget {
  const PanicSetupScreen({super.key});

  @override
  State<PanicSetupScreen> createState() => _PanicSetupScreenState();
}

class _PanicSetupScreenState extends State<PanicSetupScreen> {
  final _codeController    = TextEditingController();
  final _confirmController = TextEditingController();
  bool  _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _codeController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code    = _codeController.text.trim();
    final confirm = _confirmController.text.trim();

    if (code.length < 4) {
      setState(() => _error = 'Code must be at least 4 digits');
      return;
    }
    if (code != confirm) {
      setState(() => _error = 'Codes do not match');
      return;
    }

    setState(() { _isSaving = true; _error = null; });

    final random     = Random.secure();
    final saltBytes  = Uint8List(32);
    for (var i = 0; i < 32; i++) saltBytes[i] = random.nextInt(256);

    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha512(),
      iterations:   AppConfig.pbkdf2Iterations,
      bits:         AppConfig.pbkdf2KeyLength * 8,
    );

    final secretKey = await pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(code)),
      nonce:     saltBytes,
    );
    final hashBytes = await secretKey.extractBytes();

    final db = SecureDb();
    final d  = await db.db;
    await d.delete('panic_config');                 // ensure single row
    await d.insert('panic_config', {
      'id':           1,
      'code_hash_b64': base64Encode(hashBytes),
      'salt_b64':     base64Encode(saltBytes),
      'iterations':   AppConfig.pbkdf2Iterations,
    });

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Panic code configured ✓')),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Panic Code Setup')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Warning banner
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color:        cs.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: cs.error.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: cs.error),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Entering this code wipes ALL messages, contacts, and keys permanently. '
                        'This cannot be undone.',
                        style: GoogleFonts.inter(fontSize: 12, color: cs.error),
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn().slideY(begin: -0.1),

              const SizedBox(height: 28),

              Text('Enter Panic Code', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller:   _codeController,
                keyboardType: TextInputType.number,
                obscureText:  true,
                maxLength:    8,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  hintText:  '4–8 digits',
                  counterText: '',
                ),
              ),

              const SizedBox(height: 16),
              Text('Confirm Panic Code', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              TextField(
                controller:   _confirmController,
                keyboardType: TextInputType.number,
                obscureText:  true,
                maxLength:    8,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  hintText: '4–8 digits',
                  counterText: '',
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: cs.error, fontSize: 12)),
              ],

              const SizedBox(height: 32),

              ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: cs.error,
                  foregroundColor: Colors.white,
                ),
                child: _isSaving
                    ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save Panic Code'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
