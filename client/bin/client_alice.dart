import 'dart:async';
import 'dart:convert';

import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';

import '_e2e/common.dart';

Future<void> main() async {
  const name = 'client_alice';
  try {
    final cfg = await loadConfig();
    final supa = SupabaseRest(baseUrl: cfg.supabaseUrl, anonKey: cfg.supabaseAnonKey);

    final state = await readState(timeout: const Duration(seconds: 30));
    if (state == null || (state['bob_uid'] as String?) == null) {
      throw StateError('Missing Bob state file (run Bob first via the runner script).');
    }
    final bobUid = state['bob_uid'] as String;

    logLine(name, '[CLIENT] generating identity');
    final me = generateIdentity();
    logLine(name, '[CLIENT] uid=${me.userId.substring(0, 12)}… reg=${me.registrationId}');

    final identityKeyB64 = base64Encode(me.keyPair.getPublicKey().publicKey.serialize());

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

    final conn = await connectAndAuth(
      name: name,
      relayWssUrl: cfg.relayWssUrl,
      uid: me.userId,
      identityKeyPair: me.keyPair,
    );

    // Build outbound session to Bob using Bob's published keys
    final built = await buildSession(name: name, me: me, supa: supa, contactUserId: bobUid);
    final cipher = built.cipher;

    // Send msg1
    const msg1 = 'Hello Bob 🔐 — message 1';
    final enc1 = await encryptAsync(cipher: cipher, plaintext: msg1);
    logLine(name, '[ENCRYPT] plaintext->ciphertext_len=${(enc1['ciphertext'] as String).length} msg_type=${enc1['type'] == 1 ? "prekey" : "signal"}');

    final id1 = newMsgId();
    final pkt1 = {
      'type': 'message',
      'from': me.userId,
      'to': bobUid,
      'id': id1,
      'ciphertext': enc1['ciphertext'],
      'msg_type': enc1['type'] == 1 ? 'prekey' : 'signal',
      'ttl_seconds': 3600,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    conn.channel.sink.add(jsonEncode(pkt1));
    logLine(name, '[RELAY] sending id=${id1.substring(0, 8)}… to=${bobUid.substring(0, 8)}…');

    // Receive Bob reply and decrypt
    logLine(name, '[CLIENT] waiting for Bob reply');
    final replyPkt = await conn.incoming.stream
        .where((p) => (p['from'] as String?) == bobUid && p.containsKey('ciphertext'))
        .first
        .timeout(const Duration(seconds: 20));

    final replyPlain = await decryptAsync(store: built.store, cipher: cipher, packet: replyPkt);
    logLine(name, '[DECRYPT] reply plaintext="$replyPlain"');

    // Send msg2 to verify ratchet advance (should be Signal/Whisper)
    const msg2 = 'Ratchet step 2 — different key material';
    final enc2 = await encryptAsync(cipher: cipher, plaintext: msg2);
    final id2 = newMsgId();
    final pkt2 = {
      'type': 'message',
      'from': me.userId,
      'to': bobUid,
      'id': id2,
      'ciphertext': enc2['ciphertext'],
      'msg_type': enc2['type'] == 1 ? 'prekey' : 'signal',
      'ttl_seconds': 3600,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    conn.channel.sink.add(jsonEncode(pkt2));
    logLine(name, '[RELAY] sending msg2 id=${id2.substring(0, 8)}… to=${bobUid.substring(0, 8)}…');

    logLine(name, '[OK] alice complete');
    await conn.dispose();
  } catch (e, st) {
    fail(name, 'e2e failed', e, st);
  }
}

