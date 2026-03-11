// lib/core/identity/device_sync_service.dart
// Multi-Device Sync implementation (Phase 5).
// Allows a user to link a secondary device (e.g. iPad, Desktop) to their primary Identity Key.

import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import '../../models/message.dart'; // Just for typing if needed

class DeviceSyncService {
  static final _x25519 = X25519();
  static final _chacha20 = Chacha20.poly1305Aead();

  /// Step 1 (Device B): Generate ephemeral linking key and display as QR code.
  Future<Map<String, dynamic>> generateLinkingRequest() async {
    final kp = await _x25519.newKeyPair();
    final pub = await kp.extractPublicKey();
    
    // The QR code will contain this JSON
    return {
      'type': 'ghost_link_v1',
      'ephemeral_pub': base64Encode(pub.bytes),
    };
  }

  /// Step 2 (Device A): Scan Device B's QR code. 
  /// Device A initiates an encrypted payload containing its Master Identity Private Key
  /// and the entire local SQLCipher DB dump.
  Future<Map<String, dynamic>> generateSyncPayload({
    required String deviceBPublicKeyB64,
    required String identityPrivateKeyB64,
    required String sqlCipherDbBackupPath,
  }) async {
    // 1. Generate an ephemeral keypair for Device A
    final kpA = await _x25519.newKeyPair();
    final pubA = await kpA.extractPublicKey();

    // 2. Compute shared secret with Device B
    final pubBBytes = base64Decode(deviceBPublicKeyB64);
    final pubB = SimplePublicKey(pubBBytes, type: KeyPairType.x25519);
    
    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: kpA,
      remotePublicKey: pubB,
    );

    // 3. Assemble the highly sensitive sync payload
    final sensitiveData = jsonEncode({
      'identity_private_key': identityPrivateKeyB64,
      'db_backup_path':       sqlCipherDbBackupPath, // In reality, we'd read the SQLite file bytes here
    });

    // 4. Encrypt the sync payload using the shared secret
    final secretBox = await _chacha20.encrypt(
      utf8.encode(sensitiveData),
      secretKey: sharedSecret,
    );

    // 5. Return the package to be relayed to Device B natively
    return {
      'ephemeral_pub_A': base64Encode(pubA.bytes),
      'nonce':           base64Encode(secretBox.nonce),
      'mac':             base64Encode(secretBox.mac.bytes),
      'ciphertext':      base64Encode(secretBox.cipherText),
    };
  }

  /// Step 3 (Device B): Receive the sync payload from Relay, decrypt it using the 
  /// ephemeral private key generated in Step 1, and clone the identity.
  Future<void> processSyncPayload({
    required Map<String, dynamic> relayPayload,
    required SimpleKeyPair deviceBPrivateKey,
  }) async {
    final pubABytes = base64Decode(relayPayload['ephemeral_pub_A'] as String);
    final pubA      = SimplePublicKey(pubABytes, type: KeyPairType.x25519);

    final sharedSecret = await _x25519.sharedSecretKey(
      keyPair: deviceBPrivateKey,
      remotePublicKey: pubA,
    );

    final secretBox = SecretBox(
      base64Decode(relayPayload['ciphertext'] as String),
      nonce: base64Decode(relayPayload['nonce'] as String),
      mac:   Mac(base64Decode(relayPayload['mac'] as String)),
    );

    final cleartextBytes = await _chacha20.decrypt(
      secretBox,
      secretKey: sharedSecret,
    );

    final sensitiveData = jsonDecode(utf8.decode(cleartextBytes)) as Map<String, dynamic>;
    
    // sensitiveData['identity_private_key'] -> Inject into SecureStorage
    // sensitiveData['db_backup_path'] -> Overwrite local SQLCipher DB
    // CLONE COMPLETE.
  }
}
