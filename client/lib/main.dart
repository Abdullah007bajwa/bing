// lib/main.dart
// Vexa — end-to-end encrypted messaging.
// Entry point: security flags (screenshot block always on), services, onboarding or home.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' as foundation show debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/identity/identity_service.dart';
import 'core/security/app_security_service.dart';
import 'core/storage/ephemeral_cache.dart';
import 'core/storage/secure_db.dart';
import 'core/crypto/signal_session.dart';
import 'core/push/push_service.dart';
import 'core/crypto/prekey_management_service.dart';
import 'models/contact.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/contacts/contacts_screen.dart';
import 'features/chat/chat_screen.dart';
import 'core/auth/auth_gate.dart';
import 'features/security/biometric_lock_screen.dart';
import 'core/theme/vexa_colors.dart';
import 'app_config.dart';
import 'widgets/vexa_brand_mark.dart';
import 'features/marketing/marketing_landing_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Premium dark system UI styling (light icons on dark background).
  try {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: VexaColors.background,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: VexaColors.background,
        statusBarBrightness: Brightness.dark,
      ),
    );
  } catch (_) {
    // Best-effort; do not crash if a platform doesn't support a specific field.
  }

  var isNewUser = true;

  try {
    await dotenv.load(fileName: ".env");

    // ── Screenshot/screen record block: always on, no user toggle ────────────
    try {
      await AppSecurityService().enforceScreenshotProtection();
    } catch (e) {
      foundation.debugPrint('[Main] enforceScreenshotProtection failed: $e');
    }

    // ── Initialize Push Notifications (Silent Wake-ups) ────────────────────
    try {
      await PushService().initialize();
    } catch (e) {
      foundation.debugPrint('[Main] PushService.initialize failed: $e');
    }

    // ── Force portrait orientation ────────────────────────────────────────────
    try {
      await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    } catch (e) {
      foundation.debugPrint('[Main] setPreferredOrientations failed: $e');
    }

    // ── Initialize Supabase (anonymous — no auth session needed) ─────────────
    try {
      await Supabase.initialize(
        url:     AppConfig.supabaseUrl,
        anonKey: AppConfig.supabaseAnonKey,
      );
    } catch (e) {
      foundation.debugPrint('[Main] Supabase.initialize failed: $e');
    }

    // ── Check if user is initialized ─────────────────────────────────────────
    try {
      final identity  = IdentityService();
      final keyPair   = await identity.loadIdentityKeyPair();
      isNewUser = keyPair == null;

      // Existing user: ensure identity is registered in Supabase (idempotent, retry if was offline)
      if (!isNewUser) {
        try {
          await identity.registerToSupabase(
            supabaseUrl:     AppConfig.supabaseUrl,
            supabaseAnonKey: AppConfig.supabaseAnonKey,
          );
        } catch (e) {
          foundation.debugPrint('[Main] registerToSupabase failed: $e');
        }
      }
    } catch (e) {
      foundation.debugPrint('[Main] Identity initialization failed: $e');
      isNewUser = true; // safe fallback
    }
  } catch (e) {
    foundation.debugPrint('[Main] App bootstrap failed: $e');
    isNewUser = true;
  }

  // Always run the app (AuthGate will make final decision)
  runApp(GhostApp(isNewUser: isNewUser));
}

class GhostApp extends StatefulWidget {
  final bool isNewUser;
  const GhostApp({super.key, required this.isNewUser});

  @override
  State<GhostApp> createState() => _GhostAppState();
}

class _GhostAppState extends State<GhostApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  bool _locked = true;
  bool _biometricEnabled = false;
  bool _checkedBiometric = false;
  DateTime _lastUnlockTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBiometricAndUnlock();
    _startBackgroundTasks();
    _bindPushNotificationTaps();
  }

  Future<void> _startBackgroundTasks() async {
    try {
      final userId = await IdentityService().getUserId();
      if (userId.isNotEmpty) {
        // Start automatic prekey rotation every 24 hours
        PrekeyManagementService().startAutoRotation(userId: userId);
      }
    } catch (e) {
      foundation.debugPrint('[Main] Failed to start background tasks: $e');
    }
  }

  void _bindPushNotificationTaps() {
    PushService().tappedSenderIds.listen((senderId) {
      unawaited(_openChatFromPush(senderId));
    });
  }

  Future<void> _openChatFromPush(String senderId) async {
    final sender = senderId.trim();
    if (sender.isEmpty) return;
    final row = await SecureDb().getContact(sender);
    if (row == null) {
      _navKey.currentState?.pushNamed('/home');
      return;
    }
    final contact = GhostContact.fromDbMap(row);
    _navKey.currentState?.pushNamed('/home');
    _navKey.currentState?.push(
      MaterialPageRoute(builder: (_) => ChatScreen(contact: contact)),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PrekeyManagementService().stopAutoRotation();
    super.dispose();
  }

  Future<void> _checkBiometricAndUnlock() async {
    final enabled = await AppSecurityService().isBiometricLockEnabled();
    if (mounted) {
      setState(() {
        _biometricEnabled = enabled;
        _checkedBiometric = true;
        _locked = enabled;
      });
      if (!enabled) _locked = false;
    }
  }

  void _onUnlocked() {
    if (mounted) {
      setState(() {
        _locked = false;
        _lastUnlockTime = DateTime.now();
      });
    }
  }

  /// Clears in-memory [SessionCipher] cache unless SQLCipher still has ciphertext
  /// rows awaiting decrypt — then keep cache so a resumed chat can reuse warm state.
  Future<void> _evictSessionCachesIfIdle() async {
    try {
      final uid = await IdentityService().getUserId();
      if (uid.isEmpty) {
        SignalSessionService().evictAllSessions();
        return;
      }
      final pending = await SecureDb().hasAnyPendingDecrypt(uid);
      if (pending) {
        foundation.debugPrint(
            '[Main] Session cache eviction skipped: pending decrypt messages');
        return;
      }
      SignalSessionService().evictAllSessions();
    } catch (e) {
      foundation.debugPrint('[Main] _evictSessionCachesIfIdle: $e');
      SignalSessionService().evictAllSessions();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      EphemeralCache().clear();
      unawaited(_evictSessionCachesIfIdle());
    }
    if (state == AppLifecycleState.resumed) {
      AppSecurityService().enforceScreenshotProtection();
      if (_biometricEnabled && mounted) {
        // Prevent instant re-lock if we just returned from the OS biometric prompt
        if (DateTime.now().difference(_lastUnlockTime).inSeconds > 2) {
          setState(() => _locked = true);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedBiometric) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: VexaLaunchShell(subtitle: 'Securing session…'),
      );
    }
    return MaterialApp(
      title: 'Vexa',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navKey,
      theme: _buildTheme(),
      home: _locked && _biometricEnabled
          ? BiometricLockScreen(key: const ValueKey('lock'), onUnlocked: _onUnlocked)
          : AuthGate(key: const ValueKey('gate'), isNewUser: widget.isNewUser),
      routes: {
        '/onboarding': (_) => const OnboardingScreen(),
        '/home':       (_) => const ContactsScreen(),
        '/marketing': (_) => const MarketingLandingScreen(),
      },
    );
  }

  ThemeData _buildTheme() {
    const bg = VexaColors.background;
    const surface = VexaColors.surface;
    const accent = VexaColors.accent;
    const text = VexaColors.textPrimary;
    const subtle = VexaColors.divider;

    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.dark(
        primary:   accent,
        secondary: accent,
        surface:   surface,
        error:     VexaColors.danger,
      ),
      textTheme: GoogleFonts.interTextTheme(base.textTheme).apply(
        bodyColor:    text,
        displayColor: text,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor:  bg,
        elevation:        0,
        centerTitle:      true,
        titleTextStyle: GoogleFonts.inter(
          color:      text,
          fontSize:   18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      cardTheme: CardTheme(
        color:        surface,
        elevation:    0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: subtle.withValues(alpha: 0.5),
            width: 0.5,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled:      true,
        fillColor:   surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide(color: VexaColors.inputBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide(color: VexaColors.inputBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: const TextStyle(color: VexaColors.textHint, fontSize: 15),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) {
          return s.contains(WidgetState.selected) ? accent : Colors.grey;
        }),
        trackColor: WidgetStateProperty.resolveWith((s) {
          return s.contains(WidgetState.selected)
              ? accent.withValues(alpha: 0.4)
              : Colors.grey.withValues(alpha: 0.3);
        }),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor:  accent,
          foregroundColor:  Colors.black,
          minimumSize:      const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 16),
          elevation: 0,
        ),
      ),
      dividerColor: VexaColors.divider,
    );
  }
}
