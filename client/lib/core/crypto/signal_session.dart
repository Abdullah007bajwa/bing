// lib/core/crypto/signal_session.dart
// Signal Protocol Double Ratchet session management.
// Every send/receive ratchets forward — forward secrecy guaranteed.

import 'dart:convert';
import 'dart:typed_data';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import '../storage/secure_db.dart';

class SignalSessionService {
  static final SignalSessionService _instance = SignalSessionService._();
  factory SignalSessionService() => _instance;
  SignalSessionService._();

  // In-memory session cache keyed by userId
  final Map<String, SessionCipher> _sessionCache = {};

  // ── Initialize or restore a session with a contact ───────────────────────
  Future<SessionCipher> getOrCreateSession({
    required String contactUserId,
    required String contactPublicKeyB64,
    required InMemorySignalProtocolStore store,
    required int deviceId,
  }) async {
    if (_sessionCache.containsKey(contactUserId)) {
      return _sessionCache[contactUserId]!;
    }

    final remoteAddress = SignalProtocolAddress(contactUserId, deviceId);

    // Check if session exists in local DB already
    final hasSession = await store.containsSession(remoteAddress);
    if (!hasSession) {
      // Perform X3DH key agreement and build initial session
      await _buildInitialSession(
        store: store,
        remoteAddress: remoteAddress,
        contactPublicKeyB64: contactPublicKeyB64,
      );
    }

    final cipher = SessionCipher.fromStore(store, remoteAddress);
    _sessionCache[contactUserId] = cipher;
    return cipher;
  }

  // ── Encrypt a plaintext message ───────────────────────────────────────────
  Future<Map<String, dynamic>> encryptMessage({
    required SessionCipher cipher,
    required String plaintext,
  }) async {
    final ciphertext = await cipher.encrypt(Uint8List.fromList(
      utf8.encode(plaintext),
    ));
    return {
      'type':       ciphertext.getType(),            // 1=PreKey, 2=Signal
      'ciphertext': base64Encode(ciphertext.serialize()),
    };
  }

  // ── Decrypt an incoming message ───────────────────────────────────────────
  Future<String> decryptMessage({
    required SessionCipher cipher,
    required Map<String, dynamic> packet,
  }) async {
    final ciphertextBytes = base64Decode(packet['ciphertext'] as String);
    final type            = packet['type'] as int;

    Uint8List plaintext;
    if (type == CiphertextMessage.prekeyType) {
      final preKeyMsg = PreKeySignalMessage(ciphertextBytes);
      plaintext = await cipher.decryptWithCallback(
        preKeyMsg,
        (identity) => true, // Trust on first use (TOFU); verify fingerprint separately
      );
    } else {
      final signalMsg = SignalMessage.fromSerialized(ciphertextBytes);
      plaintext = await cipher.decryptFromSignal(signalMsg);
    }
    return utf8.decode(plaintext);
  }

  // ── Build initial X3DH session from remote public key ────────────────────
  Future<void> _buildInitialSession({
    required InMemorySignalProtocolStore store,
    required SignalProtocolAddress remoteAddress,
    required String contactPublicKeyB64,
  }) async {
    // Build a minimal PreKeyBundle from the contact's long-term identity key
    // In production this would include signed prekeys fetched from Supabase
    final identityKeyBytes = base64Decode(contactPublicKeyB64);
    final identityKey      = IdentityKey(
      Curve.decodePoint(identityKeyBytes, 0),
    );

    // Generate ephemeral signed prekey for the session
    final signedPreKeyPair     = Curve.generateKeyPair();
    final signedPreKeyId       = 1;
    final signedPreKeyPublic   = signedPreKeyPair.publicKey;
    final ourIdentityKeyPair   = await store.getIdentityKeyPair();
    final signedPreKeySignature = Curve.calculateSignature(
      ourIdentityKeyPair.getPrivateKey(),
      signedPreKeyPublic.serialize(),
    );

    final bundle = PreKeyBundle(
      store.getLocalRegistrationId(),     // registration ID
      remoteAddress.getDeviceId(),         // device ID
      0,                                   // prekey ID (0 = none in minimal flow)
      null,                                // prekey public key (null in minimal flow)
      signedPreKeyId,
      signedPreKeyPublic,
      signedPreKeySignature,
      identityKey,
    );

    await SessionBuilder.fromSignalStore(store, remoteAddress)
        .processPreKeyBundle(bundle);
  }

  // ── Evict session from memory (e.g., on app background) ──────────────────
  void evictSession(String contactUserId) {
    _sessionCache.remove(contactUserId);
  }

  void evictAllSessions() {
    _sessionCache.clear();
  }
}
