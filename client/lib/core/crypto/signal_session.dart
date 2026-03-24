// lib/core/crypto/signal_session.dart
// Signal Protocol Double Ratchet session management.
// Session state is persisted to SQLCipher; [SessionCipher] cache is bound to store identity.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'base64_util.dart';
import 'decrypt_failure.dart';
import 'signal_session_builder.dart';
import 'signal_keys_upload_service.dart';
import '../storage/secure_db.dart';

class _CipherCacheEntry {
  _CipherCacheEntry(this.cipher, this.storeIdentity);
  final SessionCipher cipher;
  final int storeIdentity;
}

class SignalSessionService {
  static final SignalSessionService _instance = SignalSessionService._();
  factory SignalSessionService() => _instance;
  SignalSessionService._();

  final SecureDb _db = SecureDb();

  final Map<String, _CipherCacheEntry> _sessionCache = {};

  static int _storeIdentity(InMemorySignalProtocolStore store) => identityHashCode(store);

  void _putCipherCache(
    String contactUserId,
    InMemorySignalProtocolStore store,
    SessionCipher cipher,
  ) {
    _sessionCache[contactUserId] =
        _CipherCacheEntry(cipher, _storeIdentity(store));
  }

  void _logCryptoMetric(String event, Map<String, Object?> data) {
    if (kDebugMode) debugPrint('[CryptoMetric] $event $data');
  }

  /// Load persisted ratchet state from SQLCipher into [store] (established sessions only).
  Future<void> reloadSessionFromDb({
    required InMemorySignalProtocolStore store,
    required String contactUserId,
    int deviceId = 1,
  }) async {
    final address = SignalProtocolAddress(contactUserId, deviceId);
    final sessionB64 = await _db.loadSessionState('$contactUserId.$deviceId');
    if (sessionB64 == null || sessionB64.isEmpty) return;
    try {
      final record = SessionRecord.fromSerialized(safeBase64Decode(sessionB64));
      if (record.sessionState.hasSenderChain()) {
        await store.storeSession(address, record);
      }
    } catch (_) {}
  }

  Future<void> _clearSession({
    required InMemorySignalProtocolStore store,
    required String contactUserId,
    required int deviceId,
  }) async {
    final address = SignalProtocolAddress(contactUserId, deviceId);
    await _db.deleteSessionState('$contactUserId.$deviceId');
    await store.deleteSession(address);
    _sessionCache.remove(contactUserId);
    _logCryptoMetric('session_cleared', {'contact': contactUserId});
  }

  /// Public: peer asked for reset or UI recovery.
  Future<void> clearSessionForPeer({
    required InMemorySignalProtocolStore store,
    required String contactUserId,
    int deviceId = 1,
  }) =>
      _clearSession(store: store, contactUserId: contactUserId, deviceId: deviceId);

  // ── Initialize or restore a session with a contact ───────────────────────
  Future<SessionCipher> getOrCreateSession({
    required String contactUserId,
    required String contactPublicKeyB64,
    required InMemorySignalProtocolStore store,
    required int deviceId,
  }) async {
    final sid = _storeIdentity(store);
    final hit = _sessionCache[contactUserId];
    if (hit != null && hit.storeIdentity == sid) {
      return hit.cipher;
    }

    final remoteAddress = SignalProtocolAddress(contactUserId, deviceId);
    final cipher = SessionCipher.fromStore(store, remoteAddress);
    _putCipherCache(contactUserId, store, cipher);
    return cipher;
  }

  Future<void> _persistSession(
      InMemorySignalProtocolStore store, String contactUserId, int deviceId) async {
    try {
      final address = SignalProtocolAddress(contactUserId, deviceId);
      final record = await store.loadSession(address);
      if (!record.sessionState.hasSenderChain()) return;
      final b64 = base64Encode(record.serialize());
      await _db.storeSessionState('$contactUserId.$deviceId', b64);
    } catch (_) {}
  }

  Future<Uint8List> _decryptBody({
    required SessionCipher cipher,
    required Uint8List ciphertextBytes,
    required int type,
    required String? contactUserId,
  }) async {
    if (type == 3) {
      if (kDebugMode) {
        debugPrint('[SignalSession] Decrypting PreKeySignalMessage (type 3) for $contactUserId');
      }
      final preKeyMsg = PreKeySignalMessage(ciphertextBytes);
      return cipher.decryptWithCallback(
        preKeyMsg,
        (identity) => true,
      );
    }
    if (kDebugMode) {
      debugPrint('[SignalSession] Decrypting SignalMessage (type 2) for $contactUserId');
    }
    final signalMsg = SignalMessage.fromSerialized(ciphertextBytes);
    return cipher.decryptFromSignal(signalMsg);
  }

  // ── Encrypt a plaintext message ───────────────────────────────────────────
  Future<Map<String, dynamic>> encryptMessage({
    required SessionCipher cipher,
    required String plaintext,
    InMemorySignalProtocolStore? store,
    String? contactUserId,
    int deviceId = 1,
    void Function()? onBeforeSessionRebuild,
  }) async {
    var workCipher = cipher;
    if (store != null && contactUserId != null) {
      await reloadSessionFromDb(
        store: store,
        contactUserId: contactUserId,
        deviceId: deviceId,
      );
      workCipher = SessionCipher.fromStore(
        store,
        SignalProtocolAddress(contactUserId, deviceId),
      );
      _putCipherCache(contactUserId, store, workCipher);
    }

    try {
      if (store != null && contactUserId != null) {
        final remoteAddress = SignalProtocolAddress(contactUserId, deviceId);
        final hasSession = await store.containsSession(remoteAddress);

        if (!hasSession) {
          if (kDebugMode) {
            debugPrint('[SignalSession] JIT building session for $contactUserId');
          }
          final sessionBuilder = SignalSessionBuilder(
            store: store,
            keysService: SignalKeysUploadService(),
          );
          try {
            await sessionBuilder.buildSession(
              recipientUserId: contactUserId,
              deviceId: deviceId,
            );
          } catch (e) {
            if (kDebugMode) debugPrint('[SignalSession] JIT session build failed: $e');
          }
        }
      }

      final ciphertext = await workCipher.encrypt(Uint8List.fromList(
        utf8.encode(plaintext),
      ));
      if (store != null && contactUserId != null) {
        await _persistSession(store, contactUserId, deviceId);
      }
      _logCryptoMetric('encrypt_ok', {'contact': contactUserId ?? ''});
      return {
        'type': ciphertext.getType(),
        'ciphertext': base64Encode(ciphertext.serialize()),
      };
    } catch (e) {
      if (store == null || contactUserId == null) rethrow;

      _logCryptoMetric('encrypt_fail', {'contact': contactUserId, 'error': e.toString()});
      if (kDebugMode) {
        debugPrint('[SignalSession] Encrypt failed; self-healing: $e');
      }

      onBeforeSessionRebuild?.call();

      await _clearSession(
        store: store,
        contactUserId: contactUserId,
        deviceId: deviceId,
      );

      final remoteAddress = SignalProtocolAddress(contactUserId, deviceId);
      final sessionBuilder = SignalSessionBuilder(
        store: store,
        keysService: SignalKeysUploadService(),
      );
      await sessionBuilder.buildSession(
        recipientUserId: contactUserId,
        deviceId: deviceId,
      );

      final refreshedCipher = SessionCipher.fromStore(store, remoteAddress);
      _putCipherCache(contactUserId, store, refreshedCipher);

      final ciphertext = await refreshedCipher.encrypt(Uint8List.fromList(
        utf8.encode(plaintext),
      ));
      await _persistSession(store, contactUserId, deviceId);
      _logCryptoMetric('encrypt_ok_after_rebuild', {'contact': contactUserId});
      return {
        'type': ciphertext.getType(),
        'ciphertext': base64Encode(ciphertext.serialize()),
      };
    }
  }

  // ── Decrypt an incoming message ───────────────────────────────────────────
  Future<String> decryptMessage({
    required SessionCipher cipher,
    required Map<String, dynamic> packet,
    InMemorySignalProtocolStore? store,
    String? contactUserId,
    int deviceId = 1,
  }) async {
    final ciphertextBytes = safeBase64Decode(packet['ciphertext'] as String);
    final type = packet['type'] as int;

    SessionCipher workCipher = cipher;
    if (store != null && contactUserId != null) {
      await reloadSessionFromDb(
        store: store,
        contactUserId: contactUserId,
        deviceId: deviceId,
      );
      workCipher = SessionCipher.fromStore(
        store,
        SignalProtocolAddress(contactUserId, deviceId),
      );
      _putCipherCache(contactUserId, store, workCipher);
    }

    try {
      final plaintext = await _decryptBody(
        cipher: workCipher,
        ciphertextBytes: ciphertextBytes,
        type: type,
        contactUserId: contactUserId,
      );
      if (store != null && contactUserId != null) {
        await _persistSession(store, contactUserId, deviceId);
      }
      _logCryptoMetric('decrypt_ok', {'contact': contactUserId ?? '', 'packetType': type});
      return utf8.decode(plaintext);
    } catch (firstError) {
      final kind = classifyDecryptError(firstError);
      _logCryptoMetric('decrypt_fail', {
        'contact': contactUserId ?? '',
        'packetType': type,
        'kind': kind.name,
      });

      var thrown = firstError;
      if (store != null && contactUserId != null && kind != DecryptFailureType.duplicatePrekey) {
        await reloadSessionFromDb(
          store: store,
          contactUserId: contactUserId,
          deviceId: deviceId,
        );
        workCipher = SessionCipher.fromStore(
          store,
          SignalProtocolAddress(contactUserId, deviceId),
        );
        _putCipherCache(contactUserId, store, workCipher);
        try {
          final plaintext = await _decryptBody(
            cipher: workCipher,
            ciphertextBytes: ciphertextBytes,
            type: type,
            contactUserId: contactUserId,
          );
          await _persistSession(store, contactUserId, deviceId);
          _logCryptoMetric('decrypt_ok_after_reload', {
            'contact': contactUserId,
            'packetType': type,
          });
          return utf8.decode(plaintext);
        } catch (e2) {
          thrown = e2;
        }
      }

      final kind2 = classifyDecryptError(thrown);
      if (kind2 == DecryptFailureType.duplicatePrekey) {
        throw DecryptException(
          kind2,
          message: thrown.toString(),
          permanentFailure: true,
          retryLater: false,
        );
      }

      // Signal messages cannot be recovered after clearing local state; never clear here.
      if (type == 2) {
        throw DecryptException(
          kind2,
          message: thrown.toString(),
          permanentFailure: false,
          retryLater: true,
        );
      }

      throw DecryptException(
        kind2,
        message: thrown.toString(),
        permanentFailure: false,
        retryLater: true,
      );
    }
  }

  void evictSession(String contactUserId) {
    _sessionCache.remove(contactUserId);
  }

  void evictAllSessions() {
    _sessionCache.clear();
  }
}
