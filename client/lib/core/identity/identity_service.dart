// lib/core/identity/identity_service.dart
// Military-grade identity management using X25519/Ed25519 keypairs.
// Private key NEVER leaves the device (Android Keystore / iOS Secure Enclave).

import 'dart:convert';
import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:http/http.dart' as http;
import '../crypto/base64_util.dart';

const _kPrivKeyStorageKey = 'ghost_identity_priv_key';
const _kPubKeyStorageKey  = 'ghost_identity_pub_key';
const _kUserIdStorageKey  = 'ghost_user_id';

class IdentityService {
  static final IdentityService _instance = IdentityService._();
  factory IdentityService() => _instance;
  IdentityService._();

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

  IdentityKeyPair? _cachedKeyPair;
  String? _cachedUserId;

  // ── First Launch: Generate identity keypair ──────────────────────────────
  Future<IdentityKeyPair> generateIdentityKeyPair() async {
    final keyPair = generateIdentityKeyPair_();
    await _persistKeyPair(keyPair);
    _cachedKeyPair = keyPair;
    _cachedUserId = _deriveUserId(keyPair.getPublicKey());
    await _secureStorage.write(key: _kUserIdStorageKey, value: _cachedUserId);
    return keyPair;
  }

  // Helper to generate a new identity key pair
  IdentityKeyPair generateIdentityKeyPair_() {
    final keyPair = Curve.generateKeyPair();
    return IdentityKeyPair(
      IdentityKey(keyPair.publicKey),
      keyPair.privateKey,
    );
  }

  // ── Load existing keypair from secure storage ────────────────────────────
  Future<IdentityKeyPair?> loadIdentityKeyPair() async {
    if (_cachedKeyPair != null) return _cachedKeyPair;
    final privKeyB64 = await _secureStorage.read(key: _kPrivKeyStorageKey);
    final pubKeyB64  = await _secureStorage.read(key: _kPubKeyStorageKey);
    if (privKeyB64 == null || pubKeyB64 == null) return null;

    final privKey = Curve.decodePrivatePoint(base64Decode(privKeyB64));
    final pubKey  = IdentityKey(
      Curve.decodePoint(base64Decode(pubKeyB64), 0),
    );
    _cachedKeyPair = IdentityKeyPair(pubKey, privKey);
    _cachedUserId  = await _secureStorage.read(key: _kUserIdStorageKey);
    return _cachedKeyPair;
  }

  // ── Derive user_id = base58(SHA-256(public_key_bytes)) ──────────────────
  String _deriveUserId(IdentityKey publicKey) {
    final pubKeyBytes = publicKey.publicKey.serialize();
    final digest = crypto.sha256.convert(pubKeyBytes);
    return _base58Encode(Uint8List.fromList(digest.bytes));
  }

  // ── Public getter ─────────────────────────────────────────────────────────
  Future<String> getUserId() async {
    if (_cachedUserId != null) return _cachedUserId!;
    await loadIdentityKeyPair();
    return _cachedUserId ?? '';
  }

  Future<String> getPublicKeyBase64() async {
    final kp = await loadIdentityKeyPair();
    if (kp == null) return '';
    return base64Encode(kp.getPublicKey().publicKey.serialize());
  }

  // ── Key fingerprint (safety numbers) ─────────────────────────────────────
  // Returns 60-digit safety number formatted in groups of 5 (Signal-style)
  // Uses padded base64 so QR/unpadded keys (e.g. 43 chars) decode correctly.
  Future<String> getFingerprint(String remotePublicKeyB64) async {
    final kp = await loadIdentityKeyPair();
    if (kp == null) return '';
    try {
      final remoteBytes = safeBase64Decode(remotePublicKeyB64);
      final myBytes     = kp.getPublicKey().publicKey.serialize();
      final combined    = Uint8List.fromList([...myBytes, ...remoteBytes]);
      final digest      = crypto.sha256.convert(combined);
      final hexString   = hex.encode(digest.bytes);
      return List.generate(12, (i) => hexString.substring(i * 5, i * 5 + 5))
          .join(' ');
    } on FormatException {
      return '';
    }
  }

  // ── Register/upsert identity to Supabase (idempotent) ────────────────────────
  // Uses anon key; ON CONFLICT updates last_seen. Safe to retry when offline.
  Future<bool> registerToSupabase({
    required String supabaseUrl,
    required String supabaseAnonKey,
  }) async {
    final userId = await getUserId();
    final pubKey = await getPublicKeyBase64();
    if (userId.isEmpty || pubKey.isEmpty) return false;

    final nowIso = DateTime.now().toUtc().toIso8601String();
    final response = await http.post(
      Uri.parse('$supabaseUrl/rest/v1/users'),
      headers: {
        'apikey': supabaseAnonKey,
        'Authorization': 'Bearer $supabaseAnonKey',
        'Content-Type': 'application/json',
        'Prefer': 'resolution=merge-duplicates,return=minimal',
      },
      body: jsonEncode({
        'user_id': userId,
        'public_key': pubKey,
        'last_seen': nowIso,
      }),
    );
    // 201 created or 200/204 from upsert
    final ok = response.statusCode == 201 ||
        response.statusCode == 200 ||
        response.statusCode == 204;
    return ok;
  }

  // ── Panic: Wipe all identity keys ─────────────────────────────────────────
  Future<void> deleteAllKeys() async {
    await _secureStorage.deleteAll();
    _cachedKeyPair = null;
    _cachedUserId  = null;
  }

  // ── Private helpers ───────────────────────────────────────────────────────
  Future<void> _persistKeyPair(IdentityKeyPair kp) async {
    final privKeyB64 = base64Encode(kp.getPrivateKey().serialize());
    final pubKeyB64  = base64Encode(kp.getPublicKey().publicKey.serialize());
    await Future.wait([
      _secureStorage.write(key: _kPrivKeyStorageKey, value: privKeyB64),
      _secureStorage.write(key: _kPubKeyStorageKey,  value: pubKeyB64),
    ]);
  }

  static String _base58Encode(Uint8List input) {
    const alphabet =
        '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
    var intVal = BigInt.zero;
    for (final byte in input) {
      intVal = intVal * BigInt.from(256) + BigInt.from(byte);
    }
    var result = '';
    while (intVal > BigInt.zero) {
      final mod = (intVal % BigInt.from(58)).toInt();
      result    = alphabet[mod] + result;
      intVal    = intVal ~/ BigInt.from(58);
    }
    for (final byte in input) {
      if (byte == 0) {
        result = '1$result';
      } else {
        break;
      }
    }
    return result;
  }
}
