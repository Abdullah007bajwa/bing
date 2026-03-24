// lib/features/security/biometric_lock_screen.dart
// Full-screen gate shown when biometric lock is enabled. Authenticate on launch/resume.

import 'package:flutter/foundation.dart';
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
    final outcome = await _security.authenticateOutcome(
      reason: 'Unlock Ghost to continue',
      useErrorDialogs: false,
    );
    if (!mounted) return;

    if (kDebugMode) debugPrint('[BiometricLockScreen] Auth outcome: $outcome');

    if (outcome == AuthOutcome.success) {
      widget.onUnlocked();
      return;
    }

    setState(() {
      _authenticating = false;
      switch (outcome) {
        case AuthOutcome.notEnrolled:
        case AuthOutcome.noCredentials:
        case AuthOutcome.passcodeNotSet:
          _error = 'No biometrics/PIN enrolled in system settings.';
          break;
        case AuthOutcome.lockedOut:
          _error = 'Biometric temporarily locked. Try again later.';
          break;
        case AuthOutcome.permanentlyLockedOut:
          _error = 'Biometric locked. Unlock device with PIN/password, then retry.';
          break;
        case AuthOutcome.notAvailable:
          _error = 'Biometric not available on this device.';
          break;
        case AuthOutcome.cancelledOrFailed:
        case AuthOutcome.error:
        case AuthOutcome.success:
          _error = 'Authentication cancelled. Try again.';
          break;
      }
    });
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
