import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ── Logging ────────────────────────────────────────────────────────────────

void logLine(String tag, String msg) {
  final ts = DateTime.now().toIso8601String();
  stdout.writeln('[$ts] $tag $msg');
}

Never fail(String tag, String msg, Object e, StackTrace st) {
  logLine(tag, 'FAIL $msg :: $e');
  logLine(tag, st.toString());
  exitCode = 2;
  throw e;
}

// ── Config ────────────────────────────────────────────────────────────────

class E2EConfig {
  final String relayWssUrl;
  final String supabaseUrl;
  final String supabaseAnonKey;

  E2EConfig({
    required this.relayWssUrl,
    required this.supabaseUrl,
    required this.supabaseAnonKey,
  });
}

Future<E2EConfig> loadConfig() async {
  String? env(String k) => Platform.environment[k];

  var relay = env('RELAY_WSS_URL');
  var supaUrl = env('SUPABASE_URL');
  var supaKey = env('SUPABASE_ANON_KEY');

  // Fallback: read client/.env if not present in process env.
  if (relay == null || supaUrl == null || supaKey == null) {
    final envFile = File('${Directory.current.path}${Platform.pathSeparator}.env');
    if (await envFile.exists()) {
      final lines = await envFile.readAsLines();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#') || !trimmed.contains('=')) continue;
        final idx = trimmed.indexOf('=');
        final key = trimmed.substring(0, idx).trim();
        final val = trimmed.substring(idx + 1).trim();
        relay ??= key == 'RELAY_WSS_URL' ? val : null;
        supaUrl ??= key == 'SUPABASE_URL' ? val : null;
        supaKey ??= key == 'SUPABASE_ANON_KEY' ? val : null;
      }
    }
  }

  if (relay == null || relay.isEmpty) {
    throw StateError('Missing RELAY_WSS_URL (env var or .env)');
  }
  if (supaUrl == null || supaUrl.isEmpty) {
    throw StateError('Missing SUPABASE_URL (env var or .env)');
  }
  if (supaKey == null || supaKey.isEmpty) {
    throw StateError('Missing SUPABASE_ANON_KEY (env var or .env)');
  }

  return E2EConfig(relayWssUrl: relay, supabaseUrl: supaUrl, supabaseAnonKey: supaKey);
}

// ── Identity / IDs ─────────────────────────────────────────────────────────

String base58Encode(Uint8List input) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  var intVal = BigInt.zero;
  for (final byte in input) {
    intVal = intVal * BigInt.from(256) + BigInt.from(byte);
  }
  var result = '';
  while (intVal > BigInt.zero) {
    final mod = (intVal % BigInt.from(58)).toInt();
    result = alphabet[mod] + result;
    intVal = intVal ~/ BigInt.from(58);
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

String deriveUserIdFromPubBytes(Uint8List pubKeyBytes) {
  final digest = crypto.sha256.convert(pubKeyBytes);
  return base58Encode(Uint8List.fromList(digest.bytes));
}

class E2EIdentity {
  final IdentityKeyPair keyPair;
  final int registrationId;
  final String userId;

  E2EIdentity({required this.keyPair, required this.registrationId, required this.userId});
}

E2EIdentity generateIdentity() {
  final kp = KeyHelper.generateIdentityKeyPair();
  final pubBytes = kp.getPublicKey().publicKey.serialize();
  final regId = Random.secure().nextInt(16383) + 1;
  final uid = deriveUserIdFromPubBytes(pubBytes);
  return E2EIdentity(keyPair: kp, registrationId: regId, userId: uid);
}

// ── Supabase REST helpers (PostgREST) ──────────────────────────────────────

class SupabaseRest {
  final String baseUrl;
  final String anonKey;
  final http.Client _http;

  SupabaseRest({required this.baseUrl, required this.anonKey, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  Uri _u(String pathAndQuery) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$pathAndQuery');

  Map<String, String> _headers({bool preferReturnMinimal = true}) => {
        'apikey': anonKey,
        'Authorization': 'Bearer $anonKey',
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        if (preferReturnMinimal) 'Prefer': 'return=minimal',
      };

  Future<void> upsertUser({
    required String userId,
    required String identityKeyB64,
    required int registrationId,
  }) async {
    final body = jsonEncode({
      'user_id': userId,
      'identity_key': identityKeyB64,
      'registration_id': registrationId,
      'public_key': identityKeyB64,
    });
    final resp = await _http.post(
      _u('/rest/v1/users?on_conflict=user_id'),
      headers: _headers(),
      body: body,
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('users upsert failed: ${resp.statusCode} ${resp.body}');
    }
  }

  Future<void> upsertSignedPreKey({
    required String userId,
    required int keyId,
    required String publicKeyB64,
    required String signatureB64,
  }) async {
    final body = jsonEncode({
      'user_id': userId,
      'key_id': keyId,
      'public_key': publicKeyB64,
      'signature': signatureB64,
    });
    final resp = await _http.post(
      _u('/rest/v1/signed_prekeys?on_conflict=user_id,key_id'),
      headers: _headers(),
      body: body,
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('signed_prekeys upsert failed: ${resp.statusCode} ${resp.body}');
    }
  }

  Future<void> insertPreKeys({
    required String userId,
    required List<MapEntry<int, ECKeyPair>> preKeys,
  }) async {
    final rows = preKeys
        .map((e) => {
              'user_id': userId,
              'key_id': e.key,
              'public_key': base64Encode(e.value.publicKey.serialize()),
            })
        .toList();
    final resp = await _http.post(
      _u('/rest/v1/prekeys'),
      headers: _headers(),
      body: jsonEncode(rows),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('prekeys insert failed: ${resp.statusCode} ${resp.body}');
    }
  }

  Future<Map<String, dynamic>> fetchRecipientKeys(String recipientUserId) async {
    final userResp = await _http.get(
      _u('/rest/v1/users?select=identity_key,registration_id&user_id=eq.$recipientUserId&limit=1'),
      headers: _headers(),
    );
    if (userResp.statusCode < 200 || userResp.statusCode >= 300) {
      throw StateError('users fetch failed: ${userResp.statusCode} ${userResp.body}');
    }
    final userRows = jsonDecode(userResp.body) as List<dynamic>;
    if (userRows.isEmpty) throw StateError('recipient not found');
    final user = userRows.first as Map<String, dynamic>;

    final spkResp = await _http.get(
      _u('/rest/v1/signed_prekeys?select=key_id,public_key,signature&user_id=eq.$recipientUserId&order=created_at.desc&limit=1'),
      headers: _headers(),
    );
    if (spkResp.statusCode < 200 || spkResp.statusCode >= 300) {
      throw StateError('signed_prekeys fetch failed: ${spkResp.statusCode} ${spkResp.body}');
    }
    final spkRows = jsonDecode(spkResp.body) as List<dynamic>;
    if (spkRows.isEmpty) throw StateError('recipient signed_prekey missing');
    final spk = spkRows.first as Map<String, dynamic>;

    final opkResp = await _http.get(
      _u('/rest/v1/prekeys?select=key_id,public_key&user_id=eq.$recipientUserId&used_at=is.null&limit=1'),
      headers: _headers(preferReturnMinimal: false),
    );
    if (opkResp.statusCode < 200 || opkResp.statusCode >= 300) {
      throw StateError('prekeys fetch failed: ${opkResp.statusCode} ${opkResp.body}');
    }
    final opkRows = jsonDecode(opkResp.body) as List<dynamic>;
    final opk = opkRows.isNotEmpty ? (opkRows.first as Map<String, dynamic>) : null;

    return {
      'identity_key': user['identity_key'] as String,
      'registration_id': user['registration_id'] as int,
      'signed_prekey_id': spk['key_id'] as int,
      'signed_prekey': spk['public_key'] as String,
      'signed_prekey_signature': spk['signature'] as String,
      'prekey_id': opk?['key_id'] as int?,
      'prekey': opk?['public_key'] as String?,
    };
  }

  Future<void> markPrekeyUsed({required String userId, required int prekeyId}) async {
    final nowIso = DateTime.now().toIso8601String();
    final resp = await _http.patch(
      _u('/rest/v1/prekeys?user_id=eq.$userId&key_id=eq.$prekeyId'),
      headers: _headers(),
      body: jsonEncode({'used_at': nowIso}),
    );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw StateError('prekey mark used failed: ${resp.statusCode} ${resp.body}');
    }
  }
}

// ── CLI local Signal keystore (signed prekey + one-time prekeys) ────────────
// Inbound PreKeySignalMessages require the recipient's *private* signed prekey
// in [InMemorySignalProtocolStore]. Supabase only holds public material.

File cliSignalKeysFile(String userId) => File(
      '${Directory.current.path}${Platform.pathSeparator}tool${Platform.pathSeparator}signal_local_keys_$userId.json',
    );

Future<void> persistCliSignalKeysFile({
  required String userId,
  required SignedPreKeyRecord signedPreKey,
  required List<PreKeyRecord> preKeys,
}) async {
  final f = cliSignalKeysFile(userId);
  await f.parent.create(recursive: true);
  await f.writeAsString(jsonEncode({
    'signed_prekey_record_b64': base64Encode(signedPreKey.serialize()),
    'prekeys': preKeys
        .map((p) => {'id': p.id, 'record_b64': base64Encode(p.serialize())})
        .toList(),
  }));
}

/// Loads private signed prekey + one-time prekeys into [store]. Returns false if missing/corrupt.
Future<bool> hydrateCliSignalStore(
  InMemorySignalProtocolStore store,
  String userId,
) async {
  final f = cliSignalKeysFile(userId);
  if (!await f.exists()) return false;
  try {
    final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final spkB64 = m['signed_prekey_record_b64'] as String?;
    if (spkB64 == null || spkB64.isEmpty) return false;
    final spk = SignedPreKeyRecord.fromSerialized(base64Decode(spkB64));
    store.storeSignedPreKey(spk.id, spk);
    final list = m['prekeys'] as List<dynamic>? ?? [];
    for (final raw in list) {
      final row = raw as Map<String, dynamic>;
      final id = row['id'] as int;
      final b64 = row['record_b64'] as String;
      store.storePreKey(id, PreKeyRecord.fromBuffer(base64Decode(b64)));
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Ensures Supabase latest signed_prekey_id matches serialized private material on disk.
/// If not, uploads a new signed prekey + batch of one-time prekeys and rewrites the local file.
Future<void> ensureCliSignalKeysPublished({
  required String logTag,
  required E2EIdentity me,
  required SupabaseRest supa,
}) async {
  Map<String, dynamic>? serverKeys;
  try {
    serverKeys = await supa.fetchRecipientKeys(me.userId);
  } catch (e) {
    logLine(logTag, '[KEYS] fetch published keys: $e');
    serverKeys = null;
  }

  final serverSpkId = serverKeys != null ? serverKeys['signed_prekey_id'] as int? : null;

  SignedPreKeyRecord? diskSpk;
  final kf = cliSignalKeysFile(me.userId);
  if (await kf.exists()) {
    try {
      final m = jsonDecode(await kf.readAsString()) as Map<String, dynamic>;
      final b64 = m['signed_prekey_record_b64'] as String?;
      if (b64 != null && b64.isNotEmpty) {
        diskSpk = SignedPreKeyRecord.fromSerialized(base64Decode(b64));
      }
    } catch (_) {}
  }

  final aligned = diskSpk != null && serverSpkId != null && diskSpk.id == serverSpkId;
  if (aligned) {
    logLine(logTag, '[KEYS] local keystore matches server (signed_prekey_id=$serverSpkId)');
    return;
  }

  if (diskSpk != null && serverSpkId != null) {
    logLine(
      logTag,
      '[KEYS] local SPK id ${diskSpk.id} != server $serverSpkId — publishing new SPK + prekeys',
    );
  } else {
    logLine(logTag, '[KEYS] publishing signed prekey + one-time prekeys');
  }

  final spkId = DateTime.now().millisecondsSinceEpoch % 0xFFFF;
  final nonZeroSpkId = spkId == 0 ? 1 : spkId;
  final spk = KeyHelper.generateSignedPreKey(me.keyPair, nonZeroSpkId);
  await supa.upsertSignedPreKey(
    userId: me.userId,
    keyId: nonZeroSpkId,
    publicKeyB64: base64Encode(spk.getKeyPair().publicKey.serialize()),
    signatureB64: base64Encode(spk.signature),
  );

  final startId = Random.secure().nextInt(900000) + 100000;
  final prekeys = KeyHelper.generatePreKeys(startId, 10);
  await supa.insertPreKeys(
    userId: me.userId,
    preKeys: prekeys.map((p) => MapEntry(p.id, p.getKeyPair())).toList(),
  );
  await persistCliSignalKeysFile(
    userId: me.userId,
    signedPreKey: spk,
    preKeys: prekeys,
  );
  logLine(logTag, '[KEYS] saved local keystore (signed_prekey_id=$nonZeroSpkId, ${prekeys.length} prekeys)');
}

/// Base64(utf8("session_reset")) — relay rejects empty ciphertext on type message.
const kRelaySessionResetCiphertextB64 = 'c2Vzc2lvbl9yZXNldA==';

// ── Relay client (WebSocket) ───────────────────────────────────────────────

class RelayConn {
  RelayConn({
    required this.channel,
    required this.sub,
    required this.incoming,
  });

  final WebSocketChannel channel;
  final StreamSubscription sub;
  final StreamController<Map<String, dynamic>> incoming;

  /// While true, every decoded frame is also appended here. Broadcast [incoming]
  /// drops events when no listener is attached — the gap between [auth_ok] and
  /// [incoming.stream.listen] in CLIs would lose [session_reset] and ciphertext.
  final List<Map<String, dynamic>> preRecvBuffer = [];
  bool bufferInboundFrames = true;

  /// Call once you are ready to subscribe to [incoming] for app traffic. Returns
  /// all frames received so far (including [auth_ok]), stops buffering, then attach
  /// your listener so subsequent frames are delivered exactly once.
  List<Map<String, dynamic>> detachPreRecvBufferAndStopBuffering() {
    final out = List<Map<String, dynamic>>.from(preRecvBuffer);
    preRecvBuffer.clear();
    bufferInboundFrames = false;
    return out;
  }

  Future<void> dispose() async {
    await sub.cancel();
    await channel.sink.close();
    await incoming.close();
  }
}

/// First relay payload with non-empty ciphertext (any peer), for startup replay.
Map<String, dynamic>? firstCiphertextFromAny(
  Iterable<Map<String, dynamic>> packets,
) {
  for (final p in packets) {
    final from = p['from'] as String?;
    final ct = p['ciphertext'];
    if (from != null &&
        from.isNotEmpty &&
        ct is String &&
        ct.isNotEmpty) {
      return p;
    }
  }
  return null;
}

Map<String, String> buildHandshake({
  required String uid,
  required IdentityKeyPair identityKeyPair,
}) {
  final ts = DateTime.now().millisecondsSinceEpoch.toString();
  final msg = '$uid:$ts';
  final sig = Curve.calculateSignature(identityKeyPair.getPrivateKey(), Uint8List.fromList(utf8.encode(msg)));
  return {
    'uid': uid,
    'timestamp': ts,
    'signature': base64Encode(sig),
  };
}

Future<RelayConn> connectAndAuth({
  required String name,
  required String relayWssUrl,
  required String uid,
  required IdentityKeyPair identityKeyPair,
  Duration authTimeout = const Duration(seconds: 5),
}) async {
  logLine(name, '[CLIENT] connecting to relay');
  final base = Uri.parse(relayWssUrl);
  final uri = base.replace(queryParameters: {...base.queryParameters, 'uid': uid});

  final ch = WebSocketChannel.connect(uri);
  await ch.ready;

  final incoming = StreamController<Map<String, dynamic>>.broadcast();
  late final RelayConn conn;
  final sub = ch.stream.listen((raw) {
    try {
      final packet = jsonDecode(raw as String) as Map<String, dynamic>;
      if (conn.bufferInboundFrames) {
        conn.preRecvBuffer.add(packet);
      }
      incoming.add(packet);
    } catch (_) {
      // ignore parse errors
    }
  });

  conn = RelayConn(channel: ch, sub: sub, incoming: incoming);

  final hs = buildHandshake(uid: uid, identityKeyPair: identityKeyPair);
  ch.sink.add(jsonEncode(hs));
  logLine(name, '[CLIENT] auth handshake sent');

  await incoming.stream
      .where((p) => p['type'] == 'auth_ok' || p['auth'] == true)
      .first
      .timeout(authTimeout);

  logLine(name, '[CLIENT] authentication success');
  return conn;
}

// ── Signal session build (X3DH via PreKeyBundle) ────────────────────────────

class BuiltSession {
  final InMemorySignalProtocolStore store;
  final SessionCipher cipher;

  BuiltSession({required this.store, required this.cipher});
}

Future<BuiltSession> buildSession({
  required String name,
  required E2EIdentity me,
  required SupabaseRest supa,
  required String contactUserId,
}) async {
  logLine(name, '[SESSION] building session with ${contactUserId.substring(0, 8)}…');

  final store = InMemorySignalProtocolStore(me.keyPair, me.registrationId);
  final hydrated = await hydrateCliSignalStore(store, me.userId);
  if (!hydrated) {
    logLine(
      name,
      '[SESSION] warning: no local signal keystore — inbound PreKey decrypt may fail',
    );
  }

  final keys = await supa.fetchRecipientKeys(contactUserId);

  final identityKeyBytes = base64Decode(keys['identity_key'] as String);
  final identityKey = IdentityKey(Curve.decodePoint(identityKeyBytes, 0));

  final regId = keys['registration_id'] as int;
  final spkId = keys['signed_prekey_id'] as int;
  final spkBytes = base64Decode(keys['signed_prekey'] as String);
  final spkPub = Curve.decodePoint(spkBytes, 0);
  final spkSig = base64Decode(keys['signed_prekey_signature'] as String);

  final preKeyId = keys['prekey_id'] as int?;
  final preKeyB64 = keys['prekey'] as String?;
  if (preKeyId == null || preKeyB64 == null || preKeyB64.isEmpty) {
    throw StateError('recipient has no available one-time prekey');
  }
  final preKeyPub = Curve.decodePoint(base64Decode(preKeyB64), 0);

  final addr = SignalProtocolAddress(contactUserId, 1);

  final bundle = PreKeyBundle(
    regId,
    addr.getDeviceId(),
    preKeyId,
    preKeyPub,
    spkId,
    spkPub,
    spkSig,
    identityKey,
  );

  final builder = SessionBuilder.fromSignalStore(store, addr);
  await builder.processPreKeyBundle(bundle);

  await supa.markPrekeyUsed(userId: contactUserId, prekeyId: preKeyId);

  final cipher = SessionCipher.fromStore(store, addr);
  logLine(name, '[SESSION] session established');
  return BuiltSession(store: store, cipher: cipher);
}

Future<Map<String, dynamic>> encryptAsync({
  required SessionCipher cipher,
  required String plaintext,
}) async {
  final ct = await cipher.encrypt(Uint8List.fromList(utf8.encode(plaintext)));
  return {
    // libsignal_protocol_dart uses CiphertextMessage types:
    // 3 = PREKEY_TYPE, 2 = WHISPER_TYPE (SignalMessage)
    'type': ct.getType(),
    'ciphertext': base64Encode(ct.serialize()),
  };
}

Future<String> decryptAsync({
  required InMemorySignalProtocolStore store,
  required SessionCipher cipher,
  required Map<String, dynamic> packet,
}) async {
  final msgType = packet['msg_type'];
  final typeInt = (msgType == 'prekey' || msgType == 0) ? 3 : 2;
  final ciphertextBytes = base64Decode(packet['ciphertext'] as String);

  Uint8List plaintext;
  if (typeInt == 3) {
    final preKeyMsg = PreKeySignalMessage(ciphertextBytes);
    plaintext = await cipher.decryptWithCallback(preKeyMsg, (_) => true);
  } else {
    final signalMsg = SignalMessage.fromSerialized(ciphertextBytes);
    plaintext = await cipher.decryptFromSignal(signalMsg);
  }

  return utf8.decode(plaintext);
}

// ── Simple state file for coordination between processes ────────────────────

File stateFile() => File('${Directory.current.path}${Platform.pathSeparator}tool${Platform.pathSeparator}e2e_state.json');

Future<void> writeState(Map<String, dynamic> state) async {
  final f = stateFile();
  await f.parent.create(recursive: true);
  await f.writeAsString(jsonEncode(state));
}

Future<Map<String, dynamic>?> readState({Duration timeout = const Duration(seconds: 20)}) async {
  final f = stateFile();
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await f.exists()) {
      try {
        final txt = await f.readAsString();
        return jsonDecode(txt) as Map<String, dynamic>;
      } catch (_) {}
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return null;
}

final _uuid = const Uuid();

String newMsgId() => _uuid.v4();

