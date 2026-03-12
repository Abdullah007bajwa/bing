// lib/main.dart
// Ghost — Military-grade private messaging.
// Entry point: security flags (screenshot block always on), services, onboarding or home.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/identity/identity_service.dart';
import 'core/security/app_security_service.dart';
import 'core/storage/ephemeral_cache.dart';
import 'core/push/push_service.dart';
import 'features/onboarding/onboarding_screen.dart';
import 'features/contacts/contacts_screen.dart';
import 'features/security/biometric_lock_screen.dart';
import 'app_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");

  // ── Screenshot/screen record block: always on, no user toggle ────────────
  await AppSecurityService().enforceScreenshotProtection();

  // ── Initialize Push Notifications (Silent Wake-ups) ────────────────────
  await PushService().initialize();

  // ── Force portrait orientation ────────────────────────────────────────────
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // ── Initialize Supabase (anonymous — no auth session needed) ─────────────
  await Supabase.initialize(
    url:     AppConfig.supabaseUrl,
    anonKey: AppConfig.supabaseAnonKey,
  );

  // ── Check if user is initialized ─────────────────────────────────────────
  final identity  = IdentityService();
  final keyPair   = await identity.loadIdentityKeyPair();
  final isNewUser = keyPair == null;

  // Existing user: ensure identity is registered in Supabase (idempotent, retry if was offline)
  if (!isNewUser) {
    await identity.registerToSupabase(
      supabaseUrl:     AppConfig.supabaseUrl,
      supabaseAnonKey: AppConfig.supabaseAnonKey,
    );
  }

  runApp(GhostApp(isNewUser: isNewUser));
}

class GhostApp extends StatefulWidget {
  final bool isNewUser;
  const GhostApp({super.key, required this.isNewUser});

  @override
  State<GhostApp> createState() => _GhostAppState();
}

class _GhostAppState extends State<GhostApp> with WidgetsBindingObserver {
  bool _locked = true;
  bool _biometricEnabled = false;
  bool _checkedBiometric = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBiometricAndUnlock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (mounted) setState(() => _locked = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      EphemeralCache().clear();
    }
    if (state == AppLifecycleState.resumed) {
      AppSecurityService().enforceScreenshotProtection();
      if (_biometricEnabled && mounted) setState(() => _locked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_checkedBiometric) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Color(0xFF0A0B0D),
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (_locked && _biometricEnabled) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _buildTheme(),
        home: BiometricLockScreen(onUnlocked: _onUnlocked),
      );
    }
    return MaterialApp(
      title:            'Ghost',
      debugShowCheckedModeBanner: false,
      theme:            _buildTheme(),
      initialRoute:     widget.isNewUser ? '/onboarding' : '/home',
      routes: {
        '/onboarding': (_) => const OnboardingScreen(),
        '/home':       (_) => const ContactsScreen(),
      },
    );
  }

  ThemeData _buildTheme() {
    const bg     = Color(0xFF0A0B0D);
    const surface = Color(0xFF111318);
    const accent  = Color(0xFF00E5B0);    // Ghost teal
    const text    = Color(0xFFF0F2F5);
    const subtle  = Color(0xFF3A3D47);

    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: ColorScheme.dark(
        primary:   accent,
        secondary: const Color(0xFF6C63FF),
        surface:   surface,
        error:     const Color(0xFFFF4D6A),
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
          fontSize:   17,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
        iconTheme: const IconThemeData(color: text),
      ),
      cardTheme: CardTheme(
        color:        surface,
        elevation:    0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: subtle.withOpacity(0.5), width: 0.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled:      true,
        fillColor:   surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide(color: subtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide(color: subtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:   BorderSide(color: accent, width: 1.5),
        ),
        hintStyle: TextStyle(color: text.withOpacity(0.35)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor:  accent,
          foregroundColor:  bg,
          minimumSize:      const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 16),
          elevation: 0,
        ),
      ),
    );
  }
}
