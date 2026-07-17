// lib/features/settings/settings_screen.dart
// Security settings: Vexa ID, biometric lock, ephemeral timer, panic wipe.
// Screenshot blocking is always on (no toggle).

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:local_auth/local_auth.dart';
import '../../core/security/app_security_service.dart';
import '../../core/storage/secure_db.dart';
import '../../core/theme/vexa_colors.dart';
import 'panic_wipe_screen.dart';
import 'panic_setup_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _security = AppSecurityService();
  final _localAuth = LocalAuthentication();
  final _db = SecureDb();

  bool   _biometricLock = false;
  bool   _allowScreenshots = false;
  bool   _chatDisappearingEnabled = false;
  bool   _chatUpdating            = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bio = await _security.isBiometricLockEnabled();
    final allowShots = await _security.isScreenshotsAllowed();
    bool chatEnabled = false;
    try {
      final contacts = await _db.getAllContacts();
      chatEnabled =
          contacts.any((c) => (c['chat_ttl_seconds'] as int? ?? 0) > 0);
    } catch (_) {
      chatEnabled = false;
    }

    if (mounted) {
      setState(() {
        _biometricLock = bio;
        _allowScreenshots = allowShots;
        _chatDisappearingEnabled = chatEnabled;
      });
    }
  }

  Future<void> _toggleScreenshots(bool v) async {
    await _security.setScreenshotsAllowed(v);
    if (!mounted) return;
    setState(() => _allowScreenshots = v);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(v ? 'Screenshots enabled' : 'Screenshots blocked')),
    );
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

    // Some devices report "supported" but have no enrolled biometrics.
    if (val) {
      final types = await _localAuth.getAvailableBiometrics();
      if (types.isEmpty) {
        if (mounted) {
          setState(() => _biometricLock = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No biometrics enrolled. Add fingerprint/face/PIN in system settings.')),
          );
        }
        return;
      }
    }

    // If enabling, trigger biometric authentication immediately
    if (val) {
      try {
        // Add delay to ensure UI is stable before showing biometric prompt
        // (MIUI cancels biometric if called immediately after camera/navigation)
        await Future.delayed(const Duration(milliseconds: 300));

        final outcome = await _security.authenticateOutcome(
          reason: 'Set up biometric lock for Vexa',
          useErrorDialogs: true,
        );

        if (!mounted) return;

        switch (outcome) {
          case AuthOutcome.success:
            await _security.setBiometricLockEnabled(true);
            if (!mounted) return;
            setState(() => _biometricLock = true);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometric lock enabled')),
            );
            return;
          case AuthOutcome.notEnrolled:
          case AuthOutcome.noCredentials:
          case AuthOutcome.passcodeNotSet:
            setState(() => _biometricLock = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('No biometrics/PIN enrolled. Enable it in system settings.')),
            );
            return;
          case AuthOutcome.lockedOut:
            setState(() => _biometricLock = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometric temporarily locked. Try again later.')),
            );
            return;
          case AuthOutcome.permanentlyLockedOut:
            setState(() => _biometricLock = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometric locked. Unlock your device with PIN/password and try again.')),
            );
            return;
          case AuthOutcome.notAvailable:
            setState(() => _biometricLock = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Biometric not available on this device')),
            );
            return;
          case AuthOutcome.cancelledOrFailed:
          case AuthOutcome.error:
            setState(() => _biometricLock = false);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Authentication cancelled')),
            );
            return;
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

  Future<void> _toggleChatDisappearing(bool enabled) async {
    if (_chatUpdating) return;
    setState(() => _chatUpdating = true);

    try {
      final contacts = await _db.getAllContacts();
      for (final c in contacts) {
        final userId = c['user_id'] as String?;
        if (userId == null || userId.isEmpty) continue;
        await _db.setChatTtlSeconds(userId, enabled ? 15 : 0);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to update chat disappearing: $e')),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _chatDisappearingEnabled = enabled;
      _chatUpdating = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: VexaColors.background,
      appBar: AppBar(
        backgroundColor: VexaColors.background,
        elevation: 0,
        automaticallyImplyLeading: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          'Settings',
          style: GoogleFonts.inter(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
            color: Colors.white,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader('Settings'),
          const SizedBox(height: 16),

          _SettingsCard(
            children: [
              _BiometricRow(
                value: _biometricLock,
                onChanged: _toggleBiometricLock,
                busy: false,
              ),
              const Divider(height: 1, color: VexaColors.divider),
              SwitchListTile(
                value: _allowScreenshots,
                onChanged: _toggleScreenshots,
                activeColor: VexaColors.accent,
                title: Text('Allow screenshots', style: GoogleFonts.inter(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  'Temporary debug option. Disable before release.',
                  style: GoogleFonts.inter(color: Colors.white54, fontSize: 12),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          _SettingsCard(
            children: [
              _ChatDisappearingRow(
                value: _chatDisappearingEnabled,
                secondsLabel: '15s',
                busy: _chatUpdating,
                onChanged: _toggleChatDisappearing,
              ),
            ],
          ),

          const SizedBox(height: 24),

          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: VexaColors.danger,
              foregroundColor: VexaColors.textPrimary,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PanicSetupScreen()),
            ),
            child: Text(
              'SET UP PANIC CODE',
              style: GoogleFonts.inter(
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
          ),

          const SizedBox(height: 16),

          _NavRow(
            label: 'Emergency Contacts',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PanicWipeScreen()),
            ),
          ),

          const SizedBox(height: 12),

          _NavRow(
            label: 'Panic Code Log',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PanicSetupScreen()),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 4, bottom: 8),
    child: Text(
      text.toUpperCase(),
      style: GoogleFonts.inter(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: VexaColors.accent,
        letterSpacing: 2,
      ),
    ),
  );
}

class _SettingsCard extends StatelessWidget {
  final List<Widget> children;
  const _SettingsCard({required this.children});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: VexaColors.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
}

class _BiometricRow extends StatelessWidget {
  final bool value;
  final bool busy;
  final ValueChanged<bool> onChanged;
  const _BiometricRow({
    required this.value,
    required this.onChanged,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.fingerprint_rounded, color: VexaColors.accent, size: 26),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Biometric Login',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: VexaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value ? 'Active' : 'Inactive',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: value ? VexaColors.activeGreen : VexaColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: busy ? null : onChanged,
          activeColor: VexaColors.accent,
        ),
      ],
    );
  }
}

class _ChatDisappearingRow extends StatelessWidget {
  final bool value;
  final bool busy;
  final String secondsLabel;
  final ValueChanged<bool> onChanged;

  const _ChatDisappearingRow({
    required this.value,
    required this.onChanged,
    required this.busy,
    required this.secondsLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.timer_rounded, color: VexaColors.accent, size: 26),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Chat Disappearing',
                style: GoogleFonts.inter(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: VexaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value ? 'Active' : 'Inactive',
                style: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: value ? VexaColors.activeGreen : VexaColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: value,
              onChanged: busy ? null : onChanged,
              activeColor: VexaColors.accent,
            ),
            const SizedBox(width: 8),
            Text(
              secondsLabel,
              style: GoogleFonts.inter(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: VexaColors.accent,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _NavRow({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: VexaColors.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: VexaColors.textPrimary,
                  ),
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: VexaColors.accent),
            ],
          ),
        ),
      ),
    );
  }
}
