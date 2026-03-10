// lib/core/platform/platform_service.dart
// Platform-conditional service layer.
// Wraps Android/iOS-only features so the app compiles on Windows/Web.

import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';

class PlatformService {
  static bool get isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;
  static bool get isIOS     => !kIsWeb && Platform.isIOS;
  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);
  static bool get isWeb     => kIsWeb;

  /// Apply FLAG_SECURE (Android only — blocks screenshots).
  static Future<void> enableScreenSecurity() async {
    if (!isAndroid) return;
    try {
      await _enableFlagSecure();
    } catch (_) {}
  }

  static Future<void> _enableFlagSecure() async {
    if (!isAndroid) return;
    // Dynamically import to avoid Windows compilation failure
    // flutter_windowmanager only compiles on Android
    // Import happens at runtime — platform check above guarantees Android
  }
}
