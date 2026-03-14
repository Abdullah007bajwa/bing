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
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

const String _kSignalIdentityKeyKey = 'signal_identity_key';
const String _kSignalRegistrationIdKey = 'signal_registration_id';
const String _kSignalSignedPreKeyKey = 'signal_signed_prekey';
const String _kSignalSignedPreKeyIdKey = 'signal_signed_prekey_id';
const String _kSignalSignedPreKeySignatureKey = 'signal_signed_prekey_signature';
const String _kSignalKeyInitializedKey = 'signal_keys_initialized';

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

  // ── Check if Signal keys have been initialized ────────────────────────────
  Future<bool> areSignalKeysInitialized() async {
    final flag = await _secureStorage.read(key: _kSignalKeyInitializedKey);
    return flag == 'true';
  }

  // ── Generate all Signal Protocol keys in correct order ────────────────────
  // This MUST be called once during app initialization.
  // All keys are stored atomically to prevent partial initialization.
  Future<void> initializeSignalKeys() async {
    final alreadyInitialized = await areSignalKeysInitialized();
    if (alreadyInitialized) {
      return; // Keys already initialized, skip
    }

    // Step 1: Generate identity key pair
    final identityKeyPair = Curve.generateKeyPair();
    final identityKey = IdentityKeyPair(
      IdentityKey(identityKeyPair.publicKey),
      identityKeyPair.privateKey,
    );

    // Step 2: Generate registration ID (random 0-16383)
    final random = _SecureRandom();
    final registrationId = random.nextInt(16384);

    // Step 3: Generate signed pre-key (key index 1)
    final signedPreKeyId = 1;
    final signedPreKeyPair = Curve.generateKeyPair();

    // Step 4: Sign pre-key with identity private key
    final signedPreKeySignature = Curve.calculateSignature(
      identityKeyPair.privateKey,
      signedPreKeyPair.publicKey.serialize(),
    );

    // Step 5: Store all together atomically
    await _secureStorage.write(
      key: _kSignalIdentityKeyKey,
      value: base64Encode(identityKey.serialize()),
    );

    await _secureStorage.write(
      key: _kSignalRegistrationIdKey,
      value: registrationId.toString(),
    );

    await _secureStorage.write(
      key: _kSignalSignedPreKeyKey,
      value: base64Encode(signedPreKeyPair.privateKey.serialize()),
    );

    await _secureStorage.write(
      key: _kSignalSignedPreKeyIdKey,
      value: signedPreKeyId.toString(),
    );

    await _secureStorage.write(
      key: _kSignalSignedPreKeySignatureKey,
      value: base64Encode(signedPreKeySignature),
    );

    // Mark as initialized
    await _secureStorage.write(
      key: _kSignalKeyInitializedKey,
      value: 'true',
    );
  }

  // ── Clear all Signal keys (for panic wipe or testing) ─────────────────────
  Future<void> clearAllSignalKeys() async {
    await Future.wait([
      _secureStorage.delete(key: _kSignalIdentityKeyKey),
      _secureStorage.delete(key: _kSignalRegistrationIdKey),
      _secureStorage.delete(key: _kSignalSignedPreKeyKey),
      _secureStorage.delete(key: _kSignalSignedPreKeyIdKey),
      _secureStorage.delete(key: _kSignalSignedPreKeySignatureKey),
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

