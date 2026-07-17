// lib/core/security/app_security_service.dart
// Centralized security: screenshot protection (FLAG_SECURE), biometric lock preference.
// Screenshot blocking is always on and not user-configurable.

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_windowmanager/flutter_windowmanager.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kBiometricLockEnabledKey = 'ghost_biometric_lock_enabled';
const _kAllowScreenshotsKey = 'ghost_allow_screenshots';

enum AuthOutcome {
  success,
  cancelledOrFailed,
  notAvailable,
  notEnrolled,
  lockedOut,
  permanentlyLockedOut,
  noCredentials,
  passcodeNotSet,
  error,
}

class AppSecurityService {
  static final AppSecurityService _instance = AppSecurityService._();
  factory AppSecurityService() => _instance;
  AppSecurityService._();

  final LocalAuthentication _localAuth = LocalAuthentication();

  /// Apply FLAG_SECURE so screenshots and screen recording are blocked.
  /// Call at app startup and on resume.
  Future<void> enforceScreenshotProtection() async {
    if (!Platform.isAndroid) return;
    final allow = await isScreenshotsAllowed();
    if (allow) {
      await FlutterWindowManager.clearFlags(FlutterWindowManager.FLAG_SECURE);
    } else {
      await FlutterWindowManager.addFlags(FlutterWindowManager.FLAG_SECURE);
    }
  }

  /// Allow screenshots/screen recording (Android only).
  /// Default: true in debug builds, false in release builds.
  Future<bool> isScreenshotsAllowed() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getBool(_kAllowScreenshotsKey);
    return v ?? kDebugMode;
  }

  Future<void> setScreenshotsAllowed(bool allowed) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kAllowScreenshotsKey, allowed);
    await enforceScreenshotProtection();
  }

  Future<bool> isBiometricLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_kBiometricLockEnabledKey) ?? false;
    if (kDebugMode) debugPrint('[AppSecurityService] isBiometricLockEnabled: $enabled');
    return enabled;
  }

  Future<void> setBiometricLockEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBiometricLockEnabledKey, enabled);
  }

  Future<bool> isBiometricAvailable() async {
    final available = await _localAuth.isDeviceSupported();
    if (kDebugMode) debugPrint('[AppSecurityService] isBiometricAvailable: $available');
    return available;
  }

  /// Get list of available biometric types (fingerprint, face, etc.).
  Future<List<BiometricType>> getAvailableBiometrics() async {
    return _localAuth.getAvailableBiometrics();
  }

  /// Authenticate using OS: fingerprint, face, or device credential.
  /// Returns true if authenticated, false if failed/cancelled.
  Future<bool> authenticate({
    String reason = 'Unlock Vexa',
    bool useErrorDialogs = true,
  }) async {
    final r = await authenticateOutcome(reason: reason, useErrorDialogs: useErrorDialogs);
    return r == AuthOutcome.success;
  }

  Future<AuthOutcome> authenticateOutcome({
    String reason = 'Unlock Vexa',
    bool useErrorDialogs = true,
  }) async {
    try {
      final ok = await _localAuth.authenticate(
        localizedReason: reason,
        options: AuthenticationOptions(
          useErrorDialogs: useErrorDialogs,
          stickyAuth: true,
        ),
      );
      if (kDebugMode) debugPrint('[AppSecurityService] Biometric auth result: $ok');
      return ok ? AuthOutcome.success : AuthOutcome.cancelledOrFailed;
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('[AppSecurityService] Biometric PlatformException: ${e.code} / ${e.message}');
      // local_auth historically throws PlatformException with codes; newer versions
      // can surface structured enums internally, but PlatformException remains common on Android OEM skins.
      switch (e.code) {
        case 'NotAvailable':
        case 'notAvailable':
          return AuthOutcome.notAvailable;
        case 'NotEnrolled':
        case 'notEnrolled':
          return AuthOutcome.notEnrolled;
        case 'LockedOut':
        case 'lockedOut':
        case 'temporaryLockout':
          return AuthOutcome.lockedOut;
        case 'PermanentlyLockedOut':
        case 'permanentlyLockedOut':
          return AuthOutcome.permanentlyLockedOut;
        case 'PasscodeNotSet':
        case 'passcodeNotSet':
          return AuthOutcome.passcodeNotSet;
        case 'noCredentialsSet':
        case 'no_credentials':
        case 'noCredentials':
          return AuthOutcome.noCredentials;
        default:
          return AuthOutcome.error;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[AppSecurityService] Biometric unknown error: $e');
      return AuthOutcome.error;
    }
  }
}
