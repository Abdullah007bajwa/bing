// lib/core/crypto/signal_keys_upload_service.dart
// Upload Signal Protocol public keys to Supabase for session establishment
// Critical: Recipients cannot initiate sessions without these keys

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SignalKeysUploadService {
  static final SignalKeysUploadService _instance = SignalKeysUploadService._();
  factory SignalKeysUploadService() => _instance;
  SignalKeysUploadService._();

  final _supabase = Supabase.instance.client;

  /// Upload user's public Signal keys to Supabase
  /// Call this once after key generation and periodically for rotation
  Future<bool> uploadSignalKeys({
    required String userId,
    required IdentityKeyPair identityKeyPair,
    required int registrationId,
    required ECKeyPair signedPreKeyPair,
    required int signedPreKeyId,
    required Uint8List signedPreKeySignature,
  }) async {
    try {
      // Step 1: Upload identity key and registration ID to users table
      final identityKeyB64 = base64Encode(
        identityKeyPair.getPublicKey().publicKey.serialize(),
      );

      if (kDebugMode) {
        debugPrint(
          '[SignalKeysUpload] Uploading identity key for $userId',
        );
      }

      await _supabase.from('users').upsert(
        {
          'user_id': userId,
          'identity_key': identityKeyB64,
          'registration_id': registrationId,
          'public_key': identityKeyB64,
          'last_seen': DateTime.now().toIso8601String(),
        },
        onConflict: 'user_id',
      );

      // Step 2: Upload signed pre-key to signed_prekeys table
      final signedPreKeyB64 = base64Encode(
        signedPreKeyPair.publicKey.serialize(),
      );
      final signatureB64 = base64Encode(signedPreKeySignature);

      if (kDebugMode) {
        debugPrint(
          '[SignalKeysUpload] Uploading signed prekey $signedPreKeyId',
        );
      }

      await _supabase.from('signed_prekeys').upsert(
        {
          'user_id': userId,
          'key_id': signedPreKeyId,
          'public_key': signedPreKeyB64,
          'signature': signatureB64,
        },
        onConflict: 'user_id,key_id',
      );

      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Successfully uploaded keys for $userId');
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Error uploading keys: $e');
      }
      return false;
    }
  }

  /// Upload one-time prekeys for forward secrecy
  /// Generate 50+ at startup, maintain by refilling when count < 10
  Future<bool> uploadOneTimePreKeys({
    required String userId,
    required List<MapEntry<int, ECKeyPair>> preKeys,
  }) async {
    if (preKeys.isEmpty) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] No prekeys to upload');
      }
      return true;
    }

    try {
      final rows = preKeys.map((entry) {
        return {
          'user_id': userId,
          'key_id': entry.key,
          'public_key': base64Encode(entry.value.publicKey.serialize()),
        };
      }).toList();

      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Uploading ${rows.length} one-time prekeys');
      }

      await _supabase.from('prekeys').insert(rows);

      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Successfully uploaded ${rows.length} prekeys');
      }

      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Error uploading prekeys: $e');
      }
      return false;
    }
  }

  /// Fetch recipient's keys for session establishment
  /// Returns null if recipient not found or keys incomplete
  Future<Map<String, dynamic>?> fetchRecipientKeys({
    required String recipientUserId,
  }) async {
    try {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Fetching keys for $recipientUserId');
      }

      // Fetch identity key and registration ID
      final userResponse = await _supabase
          .from('users')
          .select()
          .eq('user_id', recipientUserId)
          .maybeSingle();

      if (userResponse == null) {
        if (kDebugMode) {
          debugPrint('[SignalKeysUpload] User not found: $recipientUserId');
        }
        return null;
      }

      // Fetch signed prekey
      final signedPreKeyResponse = await _supabase
          .from('signed_prekeys')
          .select()
          .eq('user_id', recipientUserId)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (signedPreKeyResponse == null) {
        if (kDebugMode) {
          debugPrint(
            '[SignalKeysUpload] No signed prekey for: $recipientUserId',
          );
        }
        return null;
      }

      // Fetch one-time prekey (prefer unused)
      final oneTimePreKeyResponse = await _supabase
          .from('prekeys')
          .select()
          .eq('user_id', recipientUserId)
          .filter('used_at', 'is', null)
          // Prefer the newest unused prekey. If older prekeys were lost
          // locally (e.g., device storage wipe without server cleanup),
          // using the newest reduces the chance of selecting a prekey the
          // receiver cannot decrypt.
          .order('key_id', ascending: false)
          .limit(1)
          .maybeSingle();

      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Successfully fetched keys for $recipientUserId');
      }

      return {
        'identity_key': userResponse['identity_key'] as String,
        'registration_id': userResponse['registration_id'] as int,
        'signed_prekey_id': signedPreKeyResponse['key_id'] as int,
        'signed_prekey': signedPreKeyResponse['public_key'] as String,
        'signed_prekey_signature':
            signedPreKeyResponse['signature'] as String,
        'prekey_id': oneTimePreKeyResponse?['key_id'] as int?,
        'prekey': oneTimePreKeyResponse?['public_key'] as String?,
      };
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Error fetching keys: $e');
      }
      return null;
    }
  }

  /// Mark a one-time prekey as used after session establishment
  Future<void> markPrekeyUsed({
    required String userId,
    required int prekeyId,
  }) async {
    try {
      await _supabase
          .from('prekeys')
          .update({'used_at': DateTime.now().toIso8601String()})
          .eq('user_id', userId)
          .eq('key_id', prekeyId);

      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Marked prekey $prekeyId as used');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Error marking prekey as used: $e');
      }
    }
  }

  /// Check if a signed prekey exists in Supabase for this user.
  /// Used to detect when external DB resets require a re-upload.
  Future<bool> signedPreKeyExists({required String userId}) async {
    try {
      final resp = await _supabase
          .from('signed_prekeys')
          .select('key_id')
          .eq('user_id', userId)
          .limit(1)
          .maybeSingle();
      return resp != null;
    } catch (_) {
      return false; // If we can't check, assume missing → force upload
    }
  }

  /// Highest `key_id` present in `prekeys` for this user (used or unused).
  /// New one-time prekey IDs must be strictly greater to avoid insert conflicts
  /// and to stay consistent with [PrekeyManagementService.generateOneTimePreKeys].
  Future<int> fetchMaxPrekeyKeyId({required String userId}) async {
    try {
      final row = await _supabase
          .from('prekeys')
          .select('key_id')
          .eq('user_id', userId)
          .order('key_id', ascending: false)
          .limit(1)
          .maybeSingle();
      if (row == null) return 0;
      final id = row['key_id'];
      if (id is int) return id;
      return 0;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Error fetching max prekey id: $e');
      }
      return 0;
    }
  }

  /// Get count of unused prekeys
  Future<int> getUnusedPrekeyCount({required String userId}) async {
    try {
      final response = await _supabase
          .from('prekeys')
          .select()
          .eq('user_id', userId)
          .filter('used_at', 'is', null);

      return response.length;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Error fetching prekey count: $e');
      }
      return 0;
    }
  }

  /// Check if prekey refill is needed (maintain at least 50 keys)
  Future<bool> shouldRefillPrekeys({required String userId}) async {
    final count = await getUnusedPrekeyCount(userId: userId);
    return count < 10; // Refill when below 10
  }

  /// Ensure user exists in Supabase before attempting FK operations
  /// Creates user row if it doesn't exist (prevents FK constraint violations)
  Future<void> ensureUserExists(String userId) async {
    try {
      // Check if user already exists
      final existing = await _supabase
          .from('users')
          .select()
          .eq('user_id', userId)
          .maybeSingle();

      if (existing != null) {
        if (kDebugMode) {
          debugPrint('[SignalKeysUpload] User already exists: $userId');
        }
        return; // User exists, nothing to do
      }

      // User doesn't exist, create placeholder row
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Creating user row for FK constraint: $userId');
      }

      await _supabase.from('users').insert({
        'user_id': userId,
        'identity_key': '', // Will be updated by uploadSignalKeys
        'registration_id': 0, // Will be updated by uploadSignalKeys
        'public_key': '', // Will be updated by uploadSignalKeys
        'last_seen': DateTime.now().toIso8601String(),
      });

      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] User row created successfully: $userId');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalKeysUpload] Error ensuring user exists: $e');
      }
      rethrow; // Re-throw so caller knows it failed
    }
  }
}

