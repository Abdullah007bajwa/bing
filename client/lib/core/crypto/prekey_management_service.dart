// lib/core/crypto/prekey_management_service.dart
// Generate and manage one-time prekeys for forward secrecy
// Maintains at least 50 keys, refills when count drops below 10

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'signal_keys_upload_service.dart';
import '../storage/secure_db.dart';

class PrekeyManagementService {
  static final PrekeyManagementService _instance =
      PrekeyManagementService._();
  factory PrekeyManagementService() => _instance;
  PrekeyManagementService._();

  final _keysUploadService = SignalKeysUploadService();
  final _db = SecureDb();
  Timer? _rotationTimer;

  static const int _targetPrekeyCount = 50;
  static const int _refillThreshold = 10;
  static const int _rotationIntervalHours = 24;

  /// Ensure this device has local private prekeys stored (SQLCipher) and that
  /// Supabase has enough public prekeys available for others to initiate sessions.
  /// This is a migration helper for existing installs that previously never persisted prekeys.
  Future<void> ensureLocalPrekeysAndUpload({required String userId}) async {
    try {
      final localRows = await _db.loadAllSignalPreKeyRecords();
      final localCount = localRows.length;
      var maxId = 0;
      for (final r in localRows) {
        final id = r['key_id'];
        if (id is int && id > maxId) maxId = id;
      }

      if (localCount >= _targetPrekeyCount) return;

      final toGenerate = _targetPrekeyCount - localCount;
      final startId = (maxId > 0) ? (maxId + 1) : 1;

      if (kDebugMode) {
        debugPrint('[PrekeyManagement] Local prekeys missing; generating $toGenerate (start $startId)');
      }

      await _keysUploadService.ensureUserExists(userId);
      final newPreKeys = await generateOneTimePreKeys(startId: startId, count: toGenerate);
      await _keysUploadService.uploadOneTimePreKeys(userId: userId, preKeys: newPreKeys);
    } catch (e) {
      if (kDebugMode) debugPrint('[PrekeyManagement] ensureLocalPrekeysAndUpload error: $e');
    }
  }

  /// Start background prekey rotation task
  /// Call this once during app initialization
  void startAutoRotation({required String userId}) {
    // Cancel existing timer
    _rotationTimer?.cancel();

    // Initial check immediately
    _checkAndRefillPrekeys(userId: userId);

    // Then check every 24 hours
    _rotationTimer = Timer.periodic(
      Duration(hours: _rotationIntervalHours),
      (_) => _checkAndRefillPrekeys(userId: userId),
    );

    if (kDebugMode) {
      debugPrint(
        '[PrekeyManagement] Started auto-rotation (check every $_rotationIntervalHours hours)',
      );
    }
  }

  /// Stop background rotation
  void stopAutoRotation() {
    _rotationTimer?.cancel();
    if (kDebugMode) {
      debugPrint('[PrekeyManagement] Stopped auto-rotation');
    }
  }

  /// Check if refill needed, generate and upload new keys
  Future<void> _checkAndRefillPrekeys({required String userId}) async {
    try {
      // First, ensure user exists in Supabase before checking prekey count
      // This prevents FK constraint errors when user table row doesn't exist yet
      try {
        await _keysUploadService.ensureUserExists(userId);
        if (kDebugMode) {
          debugPrint('[PrekeyManagement] User verified in Supabase');
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint('[PrekeyManagement] Could not verify user exists: $e (will retry later)');
        }
        return; // Don't proceed if user can't be verified
      }

      // Check current count
      final count = await _keysUploadService.getUnusedPrekeyCount(
        userId: userId,
      );

      if (kDebugMode) {
        debugPrint('[PrekeyManagement] Current prekey count: $count');
      }

      // Refill if needed
      if (count < _refillThreshold) {
        final toGenerate = _targetPrekeyCount - count;
        if (kDebugMode) {
          debugPrint('[PrekeyManagement] Generating $toGenerate new prekeys...');
        }

        final newPreKeys = await generateOneTimePreKeys(
          startId: count + 1,
          count: toGenerate,
        );

        final uploadSuccess = await _keysUploadService.uploadOneTimePreKeys(
          userId: userId,
          preKeys: newPreKeys,
        );

        if (uploadSuccess) {
          if (kDebugMode) {
            debugPrint(
              '[PrekeyManagement] Successfully uploaded $toGenerate prekeys',
            );
          }
        } else {
          if (kDebugMode) {
            debugPrint('[PrekeyManagement] Failed to upload prekeys');
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PrekeyManagement] Error during refill: $e');
      }
    }
  }

  /// Generate N one-time prekeys starting from given ID
  Future<List<MapEntry<int, ECKeyPair>>> generateOneTimePreKeys({
    required int startId,
    required int count,
  }) async {
    try {
      final preKeys = <MapEntry<int, ECKeyPair>>[];

      for (int i = 0; i < count; i++) {
        final keyId = startId + i;
        final keyPair = Curve.generateKeyPair();
        preKeys.add(MapEntry(keyId, keyPair));

        // Persist the private prekey locally (SQLCipher) so we can decrypt incoming PreKeySignalMessages.
        final record = PreKeyRecord(keyId, keyPair);
        await _db.storeSignalPreKeyRecord(keyId, base64Encode(record.serialize()));
      }

      if (kDebugMode) {
        debugPrint(
          '[PrekeyManagement] Generated $count prekeys (IDs $startId-${startId + count - 1})',
        );
      }

      return preKeys;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PrekeyManagement] Error generating prekeys: $e');
      }
      rethrow;
    }
  }

  /// Initial prekey generation during onboarding
  /// Generates full set of one-time prekeys for new user
  Future<List<MapEntry<int, ECKeyPair>>> generateInitialPreKeys({
    int count = _targetPrekeyCount,
  }) async {
    try {
      if (kDebugMode) {
        debugPrint('[PrekeyManagement] Generating initial $count prekeys...');
      }

      return await generateOneTimePreKeys(
        startId: 1,
        count: count,
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[PrekeyManagement] Error generating initial prekeys: $e');
      }
      rethrow;
    }
  }
}

