// lib/core/storage/ephemeral_cache.dart
// RAM-only cache for decrypted message content and view-once media.
// Content is NEVER written to disk in plaintext.
// Cache is cleared on app background / close.

import 'dart:typed_data';

class _CacheEntry<T> {
  final T data;
  final DateTime expiresAt;
  _CacheEntry(this.data, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class EphemeralCache {
  static final EphemeralCache _instance = EphemeralCache._();
  factory EphemeralCache() => _instance;
  EphemeralCache._();

  // Decrypted message text — keyed by message ID
  final Map<String, _CacheEntry<String>> _messageCache = {};

  // View-once media bytes — keyed by message ID
  final Map<String, _CacheEntry<Uint8List>> _mediaCache = {};

  static const _defaultMessageTtl = Duration(seconds: 30);
  static const _defaultMediaTtl   = Duration(seconds: 60);

  // ── Message cache ─────────────────────────────────────────────────────────
  void cacheMessage(String messageId, String plaintext, {Duration? ttl}) {
    _messageCache[messageId] = _CacheEntry(
      plaintext,
      DateTime.now().add(ttl ?? _defaultMessageTtl),
    );
  }

  String? getMessage(String messageId) {
    final entry = _messageCache[messageId];
    if (entry == null || entry.isExpired) {
      _messageCache.remove(messageId);
      return null;
    }
    return entry.data;
  }

  void evictMessage(String messageId) {
    _messageCache.remove(messageId);
  }

  // ── View-once media cache ─────────────────────────────────────────────────
  void cacheMedia(String messageId, Uint8List bytes, {Duration? ttl}) {
    _mediaCache[messageId] = _CacheEntry(
      bytes,
      DateTime.now().add(ttl ?? _defaultMediaTtl),
    );
  }

  Uint8List? getMedia(String messageId) {
    final entry = _mediaCache[messageId];
    if (entry == null || entry.isExpired) {
      _mediaCache.remove(messageId);
      return null;
    }
    return entry.data;
  }

  /// Must be called after user views view-once media
  void evictMedia(String messageId) {
    _mediaCache.remove(messageId);
  }

  // ── Purge expired entries ─────────────────────────────────────────────────
  void purgeExpired() {
    _messageCache.removeWhere((_, entry) => entry.isExpired);
    _mediaCache.removeWhere((_, entry) => entry.isExpired);
  }

  // ── Full wipe — called on app background / panic ──────────────────────────
  void clear() {
    _messageCache.clear();
    _mediaCache.clear();
  }

  int get messageCount => _messageCache.length;
  int get mediaCount   => _mediaCache.length;
}
