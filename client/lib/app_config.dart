// lib/app_config.dart
// Central configuration. Replace placeholders before deploying.

import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  AppConfig._();

  // ── Relay Server ───────────────────────────────────────────────────────────
  /// WSS URL of the Go relay on Render (or local)
  static String get relayWssUrl => dotenv.env['RELAY_WSS_URL'] ?? 'wss://ghost-relay.onrender.com/ws';

  // ── Supabase ───────────────────────────────────────────────────────────────
  /// Supabase project URL
  static String get supabaseUrl => dotenv.env['SUPABASE_URL'] ?? '';
  /// Supabase anon key
  static String get supabaseAnonKey => dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  // ── Deep-link scheme ──────────────────────────────────────────────────────
  static const String deepLinkScheme = 'ghost';
  static const String deepLinkHost   = 'add';

  // ── Ephemeral defaults ─────────────────────────────────────────────────────
  static const int defaultTtlSeconds   = 3600;   // 1 hour
  static const int maxTtlSeconds       = 86400;  // 24 hours

  // ── Panic wipe PBKDF2 settings ────────────────────────────────────────────
  static const int pbkdf2Iterations    = 600000;
  static const int pbkdf2KeyLength     = 32;     // bytes
}
