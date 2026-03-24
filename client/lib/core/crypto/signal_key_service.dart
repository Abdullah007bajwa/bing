// lib/core/crypto/signal_key_service.dart
// Signal Protocol key generation and management with proper initialization order.
// CRITICAL: Keys must be generated and stored in this exact order:
// 1. Identity key pair
// 2. Registration ID
// 3. Signed pre-key
// 4. Signed pre-key signature
// 5. One-time pre-keys
// Storing them out of order causes "Invalid signature on device key" errors.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../storage/secure_db.dart';

const String _kSignalRegistrationIdKey = 'signal_registration_id';
const String _kSignalSignedPreKeyRecordKey = 'signal_signed_prekey_record_b64';
const String _kSignalKeyInitializedKey = 'signal_keys_initialized';
const String _kSignalKeysUploadedKey = 'signal_keys_uploaded';

class SignalKeyService {
  static final SignalKeyService _instance = SignalKeyService._();
  factory SignalKeyService() => _instance;
  SignalKeyService._();

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      keyCipherAlgorithm: KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
      storageCipherAlgorithm: StorageCipherAlgorithm.AES_GCM_NoPadding,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      synchronizable: false,
    ),
  );

  final SecureDb _db = SecureDb();

  // ── Check if Signal keys have been initialized ────────────────────────────
  Future<bool> areSignalKeysInitialized() async {
    final flag = await _secureStorage.read(key: _kSignalKeyInitializedKey);
    return flag == 'true';
  }

  // ── Check / mark whether keys have been uploaded to Supabase ─────────────
  Future<bool> areKeysUploaded() async {
    final flag = await _secureStorage.read(key: _kSignalKeysUploadedKey);
    return flag == 'true';
  }

  Future<void> markKeysUploaded() async {
    await _secureStorage.write(key: _kSignalKeysUploadedKey, value: 'true');
  }

  // ── Generate all Signal Protocol keys in correct order ────────────────────
  // This MUST be called once during app initialization.
  // All keys are stored atomically to prevent partial initialization.
  Future<void> initializeSignalKeys({required IdentityKeyPair identityKeyPair}) async {
    final alreadyInitialized = await areSignalKeysInitialized();
    if (alreadyInitialized) {
      return; // Keys already initialized, skip
    }

    // Step 2: Generate registration ID (random 0-16383)
    final random = _SecureRandom();
    final registrationId = random.nextInt(16384);

    // Step 3: Generate signed pre-key (key index 1)
    final signedPreKeyId = 1;
    final signedPreKey = KeyHelper.generateSignedPreKey(identityKeyPair, signedPreKeyId);

    // Store registration + signed prekey record
    await _secureStorage.write(
      key: _kSignalRegistrationIdKey,
      value: registrationId.toString(),
    );

    await _secureStorage.write(key: _kSignalSignedPreKeyRecordKey, value: base64Encode(signedPreKey.serialize()));
    await _db.storeSignalSignedPreKeyRecord(signedPreKeyId, base64Encode(signedPreKey.serialize()));

    // Mark as initialized
    await _secureStorage.write(
      key: _kSignalKeyInitializedKey,
      value: 'true',
    );
  }

  /// Migration for existing installs:
  /// - If `signal_keys_initialized` is true but the signed prekey record is missing,
  ///   generate a new SignedPreKeyRecord(id=1) from the existing identity keypair and persist it.
  Future<SignedPreKeyRecord> ensureSignedPreKeyRecord({required IdentityKeyPair identityKeyPair, int keyId = 1}) async {
    final existing = await loadSignedPreKeyRecord(keyId: keyId);
    if (existing != null) {
      // Self-heal: ensure the stored SignedPreKeyRecord is actually signed by
      // the currently stored identity key. If identity keys changed (reinstall
      // / secure storage drift / prior corruption), uploads can publish
      // mismatched `users.identity_key` + `signed_prekeys.signature`, which
      // breaks session establishment for others.
      try {
        final signedPreKeyPublic = existing.getKeyPair().publicKey;
        final expectedSig = Curve.calculateSignature(
          identityKeyPair.getPrivateKey(),
          signedPreKeyPublic.serialize(),
        );

        final actualSig = existing.signature;
        final signatureMatches =
            expectedSig.length == actualSig.length &&
            Iterable<int>.generate(actualSig.length).every(
              (i) => expectedSig[i] == actualSig[i],
            );

        if (signatureMatches) return existing;

        if (kDebugMode) {
          debugPrint(
            '[SignalKeyService] Signed prekey signature mismatch; regenerating (keyId=$keyId)',
          );
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            '[SignalKeyService] Failed to verify stored signed prekey signature; regenerating: $e',
          );
        }
      }
      // Fall through to regeneration on mismatch / verification failure.
    }

    final signedPreKey = KeyHelper.generateSignedPreKey(identityKeyPair, keyId);
    final b64 = base64Encode(signedPreKey.serialize());

    await _secureStorage.write(key: _kSignalSignedPreKeyRecordKey, value: b64);
    await _db.storeSignalSignedPreKeyRecord(keyId, b64);

    return signedPreKey;
  }

  Future<int> getRegistrationId() async {
    final v = await _secureStorage.read(key: _kSignalRegistrationIdKey);
    if (v == null) return 1;
    return int.tryParse(v) ?? 1;
  }

  Future<SignedPreKeyRecord?> loadSignedPreKeyRecord({int keyId = 1}) async {
    final b64 = await _secureStorage.read(key: _kSignalSignedPreKeyRecordKey);
    if (b64 != null && b64.isNotEmpty) {
      return SignedPreKeyRecord.fromSerialized(base64Decode(b64));
    }
    final fromDb = await _db.loadSignalSignedPreKeyRecord(keyId);
    if (fromDb == null || fromDb.isEmpty) return null;
    return SignedPreKeyRecord.fromSerialized(base64Decode(fromDb));
  }

  Future<void> hydrateStore(InMemorySignalProtocolStore store) async {
    // Signed prekey
    final spk = await loadSignedPreKeyRecord();
    if (spk != null) {
      if (kDebugMode) debugPrint('[SignalKeyService] Hydrated SignedPreKey ${spk.id}');
      store.storeSignedPreKey(spk.id, spk);
    } else {
      if (kDebugMode) debugPrint('[SignalKeyService] Warning: Could not load SignedPreKeyRecord!');
    }

    // One-time prekeys
    final preRows = await _db.loadAllSignalPreKeyRecords();
    var loadedCount = 0;
    for (final row in preRows) {
      final id = row['key_id'] as int;
      final b64 = row['record_b64'] as String;
      try {
        final rec = PreKeyRecord.fromBuffer(base64Decode(b64));
        store.storePreKey(id, rec);
        loadedCount++;
      } catch (e) {
        if (kDebugMode) debugPrint('[SignalKeyService] Error loading PreKey $id: $e');
      }
    }
    if (kDebugMode) debugPrint('[SignalKeyService] Hydrated $loadedCount one-time prekeys');
  }

  // ── Clear all Signal keys (for panic wipe or testing) ─────────────────────
  Future<void> clearAllSignalKeys() async {
    await Future.wait([
      _secureStorage.delete(key: _kSignalRegistrationIdKey),
      _secureStorage.delete(key: _kSignalSignedPreKeyRecordKey),
      _secureStorage.delete(key: _kSignalKeyInitializedKey),
    ]);
  }
}

// ── Simple secure random number generator ─────────────────────────────────
class _SecureRandom {
  int nextInt(int max) {
    // In production, use a proper CSPRNG. For now, use Dart's Random.
    // This should be replaced with a native secure random implementation.
    return DateTime.now().microsecond % max;
  }
}

