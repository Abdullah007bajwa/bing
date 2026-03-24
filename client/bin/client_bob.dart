import 'dart:async';
import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '_e2e/common.dart';

Future<void> main() async {
  const name = 'client_bob';
  try {
    final cfg = await loadConfig();
    final supa = SupabaseRest(baseUrl: cfg.supabaseUrl, anonKey: cfg.supabaseAnonKey);

    logLine(name, '[CLIENT] generating identity');
    final me = generateIdentity();
    logLine(name, '[CLIENT] uid=${me.userId.substring(0, 12)}… reg=${me.registrationId}');

    final identityKeyB64 = base64Encode(me.keyPair.getPublicKey().publicKey.serialize());

    // Local libsignal store must retain our private signed-prekey + one-time prekeys
    // so we can decrypt the first PreKeySignalMessage.
    final store = InMemorySignalProtocolStore(me.keyPair, me.registrationId);

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
    store.storeSignedPreKey(spkId, spk);

    final prekeys = KeyHelper.generatePreKeys(1, 10);
    await supa.insertPreKeys(
      userId: me.userId,
      preKeys: prekeys.map((p) => MapEntry(p.id, p.getKeyPair())).toList(),
    );
    for (final pk in prekeys) {
      store.storePreKey(pk.id, pk);
    }
    logLine(name, '[SUPABASE] upload ok');

    await writeState({
      'bob_uid': me.userId,
      'written_at': DateTime.now().toIso8601String(),
    });

    final conn = await connectAndAuth(
      name: name,
      relayWssUrl: cfg.relayWssUrl,
      uid: me.userId,
      identityKeyPair: me.keyPair,
    );
    final early = conn.detachPreRecvBufferAndStopBuffering();

    logLine(name, '[CLIENT] waiting for Alice message');

    Map<String, dynamic> firstMsg;
    firstMsg = firstCiphertextFromAny(early) ??
        await conn.incoming.stream
            .where((p) =>
                p.containsKey('ciphertext') &&
                (p['from'] as String?)?.isNotEmpty == true)
            .first
            .timeout(const Duration(seconds: 20));

    final from = firstMsg['from'] as String;
    final msgId = (firstMsg['id'] as String?) ?? '';
    final msgType = firstMsg['msg_type'];
    logLine(name, '[RELAY] received id=${msgId.isNotEmpty ? msgId.substring(0, 8) : "?"}… from=${from.substring(0, 8)}… msg_type=$msgType');

    // Build a cipher bound to Alice; PreKey decrypt will establish the session on first message.
    final addr = SignalProtocolAddress(from, 1);
    final cipher = SessionCipher.fromStore(store, addr);

    final plaintext = await decryptAsync(store: store, cipher: cipher, packet: firstMsg);
    logLine(name, '[DECRYPT] plaintext="$plaintext"');

    // Reply (should be Signal/WhisperMessage after session exists)
    const reply = 'Hi Alice — reply 1';
    final enc = await encryptAsync(cipher: cipher, plaintext: reply);
    final replyId = newMsgId();
    final packet = {
      'type': 'message',
      'from': me.userId,
      'to': from,
      'id': replyId,
      'ciphertext': enc['ciphertext'],
      'msg_type': enc['type'] == 3 ? 'prekey' : 'signal',
      'ttl_seconds': 3600,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    conn.channel.sink.add(jsonEncode(packet));
    logLine(name, '[RELAY] sending id=${replyId.substring(0, 8)}… to=${from.substring(0, 8)}…');

    // Wait for msg2 from Alice to verify ratchet continues
    logLine(name, '[CLIENT] waiting for Alice message 2 (ratchet)');
    final secondMsg = await conn.incoming.stream
        .where((p) => (p['from'] as String?) == from && p.containsKey('ciphertext'))
        .first
        .timeout(const Duration(seconds: 20));

    final pt2 = await decryptAsync(store: store, cipher: cipher, packet: secondMsg);
    logLine(name, '[DECRYPT] msg2 plaintext="$pt2"');
    logLine(name, '[OK] roundtrip complete');

    await conn.dispose();
  } catch (e, st) {
    fail(name, 'e2e failed', e, st);
  }
}

