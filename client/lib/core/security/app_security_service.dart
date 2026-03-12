// lib/core/security/app_security_service.dart
// Centralized security: screenshot protection (FLAG_SECURE), biometric lock preference.
// Screenshot blocking is always on and not user-configurable.

import 'dart:io';
import 'package:flutter_windowmanager/flutter_windowmanager.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kBiometricLockEnabledKey = 'ghost_biometric_lock_enabled';

class AppSecurityService {
  static final AppSecurityService _instance = AppSecurityService._();
  factory AppSecurityService() => _instance;
  AppSecurityService._();

  final LocalAuthentication _localAuth = LocalAuthentication();

  /// Apply FLAG_SECURE so screenshots and screen recording are blocked.
  /// Call at app startup and on resume. No toggle — always enforced.
  Future<void> enforceScreenshotProtection() async {
    if (!Platform.isAndroid) return;
    await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
  }

  /// Whether the user has enabled biometric app lock (stored in preferences).
  Future<bool> isBiometricLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kBiometricLockEnabledKey) ?? false;
  }

  Future<void> setBiometricLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBiometricLockEnabledKey, enabled);
  }

  /// Whether the device supports biometric or device credential.
  Future<bool> isBiometricAvailable() async {
    return _localAuth.isDeviceSupported();
  }

  /// Get list of available biometric types (fingerprint, face, etc.).
  Future<List<BiometricType>> getAvailableBiometrics() async {
    return _localAuth.getAvailableBiometrics();
  }

  /// Authenticate using OS: fingerprint, face, or device credential.
  /// Returns true if authenticated, false if failed/cancelled.
  Future<bool> authenticate({
    String reason = 'Unlock Ghost',
    bool useErrorDialogs = true,
  }) async {
    try {
      return await _localAuth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          useErrorDialogs: useErrorDialogs,
          stickyAuth: true,
        ),
      );
    } catch (_) {
      return false;
    }
  }
}
