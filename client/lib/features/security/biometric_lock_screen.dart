// lib/features/security/biometric_lock_screen.dart
// Full-screen gate shown when biometric lock is enabled. Authenticate on launch/resume.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../core/security/app_security_service.dart';

class BiometricLockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;

  const BiometricLockScreen({super.key, required this.onUnlocked});

  @override
  State<BiometricLockScreen> createState() => _BiometricLockScreenState();
}

class _BiometricLockScreenState extends State<BiometricLockScreen> {
  final _security = AppSecurityService();
  bool _authenticating = false;
  String? _error;

  Future<void> _authenticate() async {
    if (_authenticating) return;
    setState(() {
      _authenticating = true;
      _error = null;
    });
    try {
      final success = await _security.authenticate(
        reason: 'Unlock Ghost to continue',
        useErrorDialogs: false,
      );
      if (success && mounted) {
        widget.onUnlocked();
      } else if (mounted) {
        setState(() {
          _authenticating = false;
          _error = 'Authentication failed. Try again.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _authenticating = false;
          _error = 'Authentication failed. Try again.';
        });
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _authenticate());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0B0D),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.lock_rounded,
                  size: 72,
                  color: cs.primary.withOpacity(0.8),
                ),
                const SizedBox(height: 24),
                Text(
                  'Ghost is locked',
                  style: GoogleFonts.inter(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Use your fingerprint, face, or device PIN to unlock.',
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: Colors.white60,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    _error!,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: cs.error,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
                const SizedBox(height: 40),
                FilledButton.icon(
                  onPressed: _authenticating ? null : _authenticate,
                  icon: _authenticating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.fingerprint_rounded),
                  label: Text(_authenticating ? 'Authenticating…' : 'Unlock'),
                  style: FilledButton.styleFrom(
                    backgroundColor: cs.primary,
                    foregroundColor: const Color(0xFF0A0B0D),
                    minimumSize: const Size(double.infinity, 52),
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
