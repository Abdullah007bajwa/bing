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
    if (args.isNotEmpty && args[0].contains('"')) {
      logLine(
        name,
        'FAIL: recipient id and message must be separate arguments (add a space before the message).',
      );
      logLine(
        name,
        'Example: dart run bin/client_sender.dart G52i4CGm…urMd "hello"',
      );
      exitCode = 64;
      return;
    }

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
      logLine(name, '[SUPABASE] user row + keys query ok');
    } catch (_) {
      logLine(name, '[SUPABASE] registering user row');
      await supa.upsertUser(
        userId: me.userId,
        identityKeyB64: identityKeyB64,
        registrationId: me.registrationId,
      );
    }

    await ensureCliSignalKeysPublished(logTag: name, me: me, supa: supa);

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
        'ciphertext': kRelaySessionResetCiphertextB64,
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
    /// True only if we restored ratchet state from [storeFile] this run — used to detect
    /// corrupt/stale disk state (encrypt still returns prekey). Must NOT use [storeFile.exists]
    /// alone: after [saveSession] the file always exists, but the first post-X3DH send is
    /// legitimately a prekey message.
    var usedDiskSessionAtStart = false;

    if (await storeFile.exists()) {
      try {
        final b64 = await storeFile.readAsString();
        final record = SessionRecord.fromSerialized(base64Decode(b64));
        final store = InMemorySignalProtocolStore(me.keyPair, me.registrationId);
        final okKeys = await hydrateCliSignalStore(store, me.userId);
        if (!okKeys) {
          logLine(
            name,
            '[SESSION] no local keystore while loading session — run once to publish keys',
          );
        }
        await store.storeSession(addr, record);
        built = BuiltSession(store: store, cipher: SessionCipher.fromStore(store, addr));
        usedDiskSessionAtStart = true;
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
      usedDiskSessionAtStart = false;
    }

    await saveSession(); // save initial build if generated

    // Serialize inbound handling: async [Stream.listen] runs handlers concurrently, so a
    // [session_reset] could still be in [resetSession] while the next frame decrypts with
    // the stale ratchet — phone then never catches up. Chain futures so each packet waits
    // for the previous handler to finish.
    Future<void> recvChain = Future<void>.value();

    Future<void> handleInboundPacket(Map<String, dynamic> p) async {
      try {
        if ((p['from'] as String?) != recipientUid) return;
        final mt = p['msg_type'];
        final mtStr = mt is String ? mt : '$mt';
        final isSessionReset = mt == 'session_reset' ||
            mtStr == 'session_reset' ||
            p['type'] == 'session_reset';
        if (isSessionReset) {
          logLine(name, '[SESSION] received session_reset from peer');
          await resetSession(reason: 'peer session_reset');
          return;
        }
        final ct = p['ciphertext'];
        if (ct is! String || ct.isEmpty) return;
        final pt = await decryptAsync(store: store, cipher: cipher, packet: p);
        await saveSession();
        logLine(name, '[RECV] from=${recipientUid.substring(0, 8)}… plaintext="$pt"');
      } catch (e, st) {
        logLine(name, '[RECV] decrypt failed: $e');
        logLine(name, '[RECV] stack: ${st.toString()}');
        final es = e.toString();
        if (es.contains('Bad Mac') ||
            es.contains('InvalidMessageException') ||
            es.contains('InvalidKeyException') ||
            es.contains('InvalidKeyIdException') ||
            es.contains('signedprekeyrecord') ||
            es.contains('No session') ||
            es.contains('NoSessionException') ||
            es.contains('Uninitialized session')) {
          try {
            await resetSession(reason: 'receive failure');
          } catch (rebuildErr) {
            logLine(name, '[RECV] session rebuild failed: $rebuildErr');
          }
        }
      }
    }

    final backlog = conn.detachPreRecvBufferAndStopBuffering();
    if (backlog.isNotEmpty) {
      logLine(
        name,
        '[RELAY] replaying ${backlog.length} inbound frame(s) buffered before recv attach',
      );
    }
    for (final p in backlog) {
      recvChain = recvChain
          .then((_) => handleInboundPacket(p))
          .catchError((Object e, StackTrace st) {
            logLine(name, '[RECV] inbound chain error: $e');
          });
    }

    final recvSub = conn.incoming.stream.listen((dynamic raw) {
      Map<String, dynamic>? p;
      try {
        p = raw as Map<String, dynamic>;
      } catch (_) {
        return;
      }
      recvChain = recvChain
          .then((_) => handleInboundPacket(p!))
          .catchError((Object e, StackTrace st) {
            logLine(name, '[RECV] inbound chain error: $e');
          });
    }, onError: (err, st) {
      logLine(name, '[RECV] stream onError: $err');
      logLine(name, '[RECV] stack: ${st.toString()}');
    });

    Future<void> sendText(String text) async {
      // Apply any queued [session_reset] / decrypts before encrypting so we do not send
      // with a stale ratchet after the phone cleared the session.
      await recvChain;
      Map<String, dynamic> enc;
      try {
        enc = await encryptAsync(cipher: cipher, plaintext: text);
      } catch (e) {
        logLine(name, '[SEND] encrypt failed, rebuilding session: $e');
        await resetSession(reason: 'encrypt failure', notifyPeer: true);
        enc = await encryptAsync(cipher: cipher, plaintext: text);
      }
      // If we *restored* from disk but encrypt still emits prekey, ratchet file is inconsistent.
      // One rebuild only; never key off [storeFile.exists] (true after every [saveSession]).
      if (enc['type'] == 3 && usedDiskSessionAtStart) {
        usedDiskSessionAtStart = false;
        await resetSession(
          reason: 'prekey after restored session (stale file)',
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
      usedDiskSessionAtStart = false;
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

