// lib/core/crypto/signal_session_builder.dart
// Build Signal sessions using Supabase prekeys
// Fetches recipient's published keys and establishes X3DH session

import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'signal_keys_upload_service.dart';

class SignalSessionBuilder {
  final InMemorySignalProtocolStore store;
  final SignalKeysUploadService keysService;

  SignalSessionBuilder({
    required this.store,
    required this.keysService,
  });

  /// Build initial X3DH session from recipient's published keys
  /// Fetches keys from Supabase and creates PreKeyBundle
  Future<SessionCipher> buildSession({
    required String recipientUserId,
    required int deviceId,
  }) async {
    try {
      if (kDebugMode) {
        debugPrint('[SignalSessionBuilder] Building session with $recipientUserId');
      }

      // Fetch recipient's public keys from Supabase
      final recipientKeys = await keysService.fetchRecipientKeys(
        recipientUserId: recipientUserId,
      );

      if (recipientKeys == null) {
        throw Exception('Recipient keys not found for $recipientUserId');
      }

      // Decode identity key
      final identityKeyBytes = base64Decode(
        recipientKeys['identity_key'] as String,
      );
      final identityKey = IdentityKey(
        Curve.decodePoint(identityKeyBytes, 0),
      );

      // Decode signed prekey
      final signedPreKeyBytes = base64Decode(
        recipientKeys['signed_prekey'] as String,
      );
      final signedPreKeyPublic = Curve.decodePoint(signedPreKeyBytes, 0);
      final signedPreKeySignature = base64Decode(
        recipientKeys['signed_prekey_signature'] as String,
      );

      // Decode optional one-time prekey
      ECPublicKey? oneTimePreKeyPublic;
      int? oneTimePreKeyId;

      if (recipientKeys['prekey'] != null) {
        final oneTimePreKeyBytes = base64Decode(
          recipientKeys['prekey'] as String,
        );
        oneTimePreKeyPublic = Curve.decodePoint(oneTimePreKeyBytes, 0);
        oneTimePreKeyId = recipientKeys['prekey_id'] as int;
      }

      // Build PreKeyBundle for X3DH
      // If no one-time prekey, generate a dummy one for the constructor
      final finalOneTimePreKeyPublic = oneTimePreKeyPublic ??
          Curve.generateKeyPair().publicKey;
      final finalOneTimePreKeyId = oneTimePreKeyId ?? 0;

      final bundle = PreKeyBundle(
        recipientKeys['registration_id'] as int,
        deviceId,
        finalOneTimePreKeyId,
        finalOneTimePreKeyPublic,
        recipientKeys['signed_prekey_id'] as int,
        signedPreKeyPublic,
        signedPreKeySignature,
        identityKey,
      );

      if (kDebugMode) {
        debugPrint('[SignalSessionBuilder] PreKeyBundle created');
      }

      // Create session using X3DH
      final remoteAddress = SignalProtocolAddress(recipientUserId, deviceId);
      final sessionBuilder = SessionBuilder.fromSignalStore(store, remoteAddress);

      await sessionBuilder.processPreKeyBundle(bundle);

      if (kDebugMode) {
        debugPrint(
          '[SignalSessionBuilder] Session created for $recipientUserId',
        );
      }

      // Mark one-time prekey as consumed (if used)
      if (oneTimePreKeyId != null) {
        await keysService.markPrekeyUsed(
          userId: recipientUserId,
          prekeyId: oneTimePreKeyId,
        );
      }

      return SessionCipher.fromStore(store, remoteAddress);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SignalSessionBuilder] Error building session: $e');
      }
      rethrow;
    }
  }
}


