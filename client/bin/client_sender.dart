import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '_e2e/common.dart';

Future<E2EIdentity> loadOrCreateIdentity() async {
  final file = File('${Directory.current.path}${Platform.pathSeparator}tool${Platform.pathSeparator}identity.json');
  if (await file.exists()) {
    try {
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final pubKey = IdentityKey(Curve.decodePoint(base64Decode(data['pub'] as String), 0));
      final privKey = Curve.decodePrivatePoint(base64Decode(data['priv'] as String));
      return E2EIdentity(
        keyPair: IdentityKeyPair(pubKey, privKey),
        registrationId: data['reg'] as int,
        userId: data['uid'] as String,
      );
    } catch (_) {}
  }
  final me = generateIdentity();
  await file.parent.create(recursive: true);
  await file.writeAsString(jsonEncode({
    'uid': me.userId,
    'reg': me.registrationId,
    'pub': base64Encode(me.keyPair.getPublicKey().publicKey.serialize()),
    'priv': base64Encode(me.keyPair.getPrivateKey().serialize()),
  }));
  return me;
}

/// CLI sender (interactive by default):
/// - generates an ephemeral identity
/// - uploads keys + prekeys to Supabase
/// - connects to relay and waits for auth_ok
/// - builds session with recipient (X3DH)
/// - encrypts/sends messages and receives/decrypts replies
///
/// Usage:
///   dart run bin/client_sender.dart recipient_uid "message"
///   dart run bin/client_sender.dart recipient_uid            (interactive; type 'bye' to quit)
Future<void> main(List<String> args) async {
  const name = 'client_sender';
  try {
    final recipientUid = (args.isNotEmpty ? args[0] : '')
        .trim()
        .isNotEmpty
        ? args[0].trim()
        : '73BfoyivvoJ4jxxgyD2saKMbFPJwT9YCPnKXgCZ6Zgmj';
    final initialMessage = args.length >= 2 ? args.sublist(1).join(' ') : null;

    final cfg = await loadConfig();
    final supa = SupabaseRest(baseUrl: cfg.supabaseUrl, anonKey: cfg.supabaseAnonKey);

    logLine(name, '[CLIENT] recipient=${recipientUid.substring(0, 12)}…');
    logLine(name, '[CLIENT] loading or generating identity');
    final me = await loadOrCreateIdentity();
    logLine(name, '[CLIENT] uid=${me.userId.substring(0, 12)}… reg=${me.registrationId}');
    print("[DEBUG] sender identity: ${base64Encode(me.keyPair.getPublicKey().publicKey.serialize())}");
    print("[DEBUG] registrationId: ${me.registrationId}");

    final identityKeyB64 = base64Encode(me.keyPair.getPublicKey().publicKey.serialize());

    try {
      await supa.fetchRecipientKeys(me.userId);
      logLine(name, '[SUPABASE] identity exists, skipping upload');
    } catch (_) {
      logLine(name, '[SUPABASE] uploading identity + prekeys');
      await supa.upsertUser(userId: me.userId, identityKeyB64: identityKeyB64, registrationId: me.registrationId);

    final spkId = DateTime.now().millisecondsSinceEpoch % 0xFFFF;
    final spk = KeyHelper.generateSignedPreKey(me.keyPair, spkId);
    await supa.upsertSignedPreKey(
      userId: me.userId,
      keyId: spkId,
      publicKeyB64: base64Encode(spk.getKeyPair().publicKey.serialize()),
      signatureB64: base64Encode(spk.signature),
    );

      final prekeys = KeyHelper.generatePreKeys(1, 10);
      await supa.insertPreKeys(
        userId: me.userId,
        preKeys: prekeys.map((p) => MapEntry(p.id, p.getKeyPair())).toList(),
      );
      logLine(name, '[SUPABASE] upload ok');
    }

    final conn = await connectAndAuth(
      name: name,
      relayWssUrl: cfg.relayWssUrl,
      uid: me.userId,
      identityKeyPair: me.keyPair,
    );

    var lastSessionResetNotifyMs = 0;
    const sessionResetCooldownMs = 30000;

    /// Matches app [RelayCoordinator.sendSessionResetIfAllowed]: warn peer before local X3DH rebuild.
    void sendSessionResetIfAllowed() {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastSessionResetNotifyMs < sessionResetCooldownMs) return;
      lastSessionResetNotifyMs = now;
      final pkt = <String, dynamic>{
        'type': 'message',
        'from': me.userId,
        'to': recipientUid,
        'id': newMsgId(),
        'msg_type': 'session_reset',
        'ciphertext': '',
        'ttl_seconds': 3600,
        'timestamp': now,
      };
      try {
        conn.channel.sink.add(jsonEncode(pkt));
        logLine(name, '[SESSION] sent session_reset to peer (cooldown ok)');
      } catch (e) {
        logLine(name, '[SESSION] session_reset send failed: $e');
      }
    }

    final storeFile = File('${Directory.current.path}${Platform.pathSeparator}tool${Platform.pathSeparator}session_$recipientUid.json');
    final addr = SignalProtocolAddress(recipientUid, 1);
    BuiltSession? built;
    
    if (await storeFile.exists()) {
      try {
        final b64 = await storeFile.readAsString();
        final record = SessionRecord.fromSerialized(base64Decode(b64));
        final store = InMemorySignalProtocolStore(me.keyPair, me.registrationId);
        await store.storeSession(addr, record);
        built = BuiltSession(store: store, cipher: SessionCipher.fromStore(store, addr));
        logLine(name, '[SESSION] loaded existing session');
      } catch (_) {}
    }

    if (built == null) {
      built = await buildSession(name: name, me: me, supa: supa, contactUserId: recipientUid);
    }
    
    InMemorySignalProtocolStore store = built.store;
    SessionCipher cipher = built.cipher;

    Future<void> saveSession() async {
      try {
        final rec = await store.loadSession(addr);
        await storeFile.writeAsString(base64Encode(rec.serialize()));
      } catch (_) {}
    }

    Future<void> resetSession({
      required String reason,
      bool notifyPeer = false,
    }) async {
      if (notifyPeer) sendSessionResetIfAllowed();
      logLine(name, '[SESSION] resetting local session: $reason');
      try {
        if (await storeFile.exists()) {
          await storeFile.delete();
        }
      } catch (_) {}
      final fresh = await buildSession(
        name: name,
        me: me,
        supa: supa,
        contactUserId: recipientUid,
      );
      built = fresh;
      store = fresh.store;
      cipher = fresh.cipher;
      await saveSession();
    }

    await saveSession(); // save initial build if generated

    // Receive loop (decrypt any message from recipientUid)
    final recvSub = conn.incoming.stream.listen((p) async {
      try {
        if ((p['from'] as String?) != recipientUid) return;
        final mt = p['msg_type'];
        if (mt == 'session_reset' || p['type'] == 'session_reset') {
          await resetSession(reason: 'peer session_reset');
          return;
        }
        final ct = p['ciphertext'];
        if (ct is! String || ct.isEmpty) return;
        final pt = await decryptAsync(store: store, cipher: cipher, packet: p);
        await saveSession();
        logLine(name, '[RECV] from=${recipientUid.substring(0, 8)}… plaintext="$pt"');
      } catch (e) {
        logLine(name, '[RECV] decrypt failed: $e');
        // Auto-recover stale sender-side session state used for long convo testing.
        if ('$e'.contains('Bad Mac') ||
            '$e'.contains('InvalidMessageException') ||
            '$e'.contains('InvalidKeyException')) {
          try {
            await resetSession(reason: 'receive failure');
          } catch (rebuildErr) {
            logLine(name, '[RECV] session rebuild failed: $rebuildErr');
          }
        }
      }
    });

    Future<void> sendText(String text) async {
      Map<String, dynamic> enc;
      try {
        enc = await encryptAsync(cipher: cipher, plaintext: text);
      } catch (e) {
        logLine(name, '[SEND] encrypt failed, rebuilding session: $e');
        await resetSession(reason: 'encrypt failure', notifyPeer: true);
        enc = await encryptAsync(cipher: cipher, plaintext: text);
      }
      // If we loaded an existing session but still emit prekey, it's usually stale.
      // Rebuild once so extended back-and-forth tests can continue.
      if (enc['type'] == 3 && await storeFile.exists()) {
        await resetSession(
          reason: 'prekey from persisted session',
          notifyPeer: true,
        );
        enc = await encryptAsync(cipher: cipher, plaintext: text);
      }
      await saveSession();
      final msgId = newMsgId();
      final pkt = {
        'type': 'message',
        'from': me.userId,
        'to': recipientUid,
        'id': msgId,
        'ciphertext': enc['ciphertext'],
        'msg_type': enc['type'] == 3 ? 'prekey' : 'signal',
        'ttl_seconds': 3600,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      conn.channel.sink.add(jsonEncode(pkt));
      logLine(name, '[SEND] id=${msgId.substring(0, 8)}… msg_type=${pkt['msg_type']}');
    }

    if (initialMessage != null && initialMessage.trim().isNotEmpty) {
      await sendText(initialMessage.trim());
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    logLine(name, "[CLIENT] interactive mode: type messages; type 'bye' to quit");
    await for (final line in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
      final text = line.trim();
      if (text.isEmpty) continue;
      if (text.toLowerCase() == 'bye') break;
      await sendText(text);
    }

    await recvSub.cancel();
    await conn.dispose();
    logLine(name, '[OK] bye');
  } catch (e, st) {
    fail(name, 'send failed', e, st);
  }
}

