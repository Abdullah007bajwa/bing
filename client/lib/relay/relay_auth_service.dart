// lib/relay/relay_auth_service.dart
// Relay authentication with signed handshakes to prevent impersonation
// Client sends: uid + timestamp + signature(identity_private_key)
// Relay verifies signature before accepting connection

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

class RelayAuthService {
  static final RelayAuthService _instance = RelayAuthService._();
  factory RelayAuthService() => _instance;
  RelayAuthService._();

  /// Generate signed relay authentication handshake
  /// Returns JSON: { uid, timestamp, signature }
  /// signature = Ed25519(identity_private_key, uid + timestamp)
  Future<Map<String, String>> generateAuthHandshake({
    required String userId,
    required IdentityKeyPair identityKeyPair,
  }) async {
    try {
      // Timestamp in milliseconds (deterministic for testing)
      final timestamp = DateTime.now().millisecondsSinceEpoch.toString();

      // Message to sign: uid + timestamp
      final messageToSign = '$userId:$timestamp';
      final messageBytes = Uint8List.fromList(utf8.encode(messageToSign));

      // Sign with identity private key
      final signature = Curve.calculateSignature(
        identityKeyPair.getPrivateKey(),
        messageBytes,
      );
      final signatureB64 = base64Encode(signature);

      if (kDebugMode) {
        debugPrint(
          '[RelayAuth] Generated handshake for $userId at $timestamp',
        );
      }

      return {
        'uid': userId,
        'timestamp': timestamp,
        'signature': signatureB64,
      };
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[RelayAuth] Error generating handshake: $e');
      }
      rethrow;
    }
  }

  /// Verify relay authentication handshake (for relay server)
  /// Returns true if signature is valid and timestamp is fresh (within 5 minutes)
  static bool verifyAuthHandshake({
    required String userId,
    required String timestamp,
    required String signatureB64,
    required String publicKeyB64,
    int toleranceSeconds = 300, // 5 minutes
  }) {
    try {
      // Verify timestamp freshness
      final ts = int.parse(timestamp);
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      final ageSec = (nowMs - ts) ~/ 1000;

      if (ageSec < 0 || ageSec > toleranceSeconds) {
        debugPrint(
          '[RelayAuth] Handshake timestamp out of tolerance: ${ageSec}s',
        );
        return false;
      }

      // Reconstruct signed message
      final messageToSign = '$userId:$timestamp';
      final messageBytes = Uint8List.fromList(utf8.encode(messageToSign));

      // Decode signature and public key
      final signature = base64Decode(signatureB64);
      final publicKeyBytes = base64Decode(publicKeyB64);

      // Verify signature
      final publicKey = Curve.decodePoint(publicKeyBytes, 0);
      final isValid = Curve.verifySignature(publicKey, messageBytes, signature);

      if (kDebugMode) {
        debugPrint(
          '[RelayAuth] Handshake verification: ${isValid ? "VALID" : "INVALID"}',
        );
      }

      return isValid;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[RelayAuth] Error verifying handshake: $e');
      }
      return false;
    }
  }
}

