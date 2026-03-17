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

// ── Relay client (WebSocket) ───────────────────────────────────────────────

class RelayConn {
  final WebSocketChannel channel;
  final StreamSubscription sub;
  final StreamController<Map<String, dynamic>> incoming;

  RelayConn({required this.channel, required this.sub, required this.incoming});

  Future<void> dispose() async {
    await sub.cancel();
    await channel.sink.close();
    await incoming.close();
  }
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
  final sub = ch.stream.listen((raw) {
    try {
      final packet = jsonDecode(raw as String) as Map<String, dynamic>;
      incoming.add(packet);
    } catch (_) {
      // ignore parse errors
    }
  });

  final hs = buildHandshake(uid: uid, identityKeyPair: identityKeyPair);
  ch.sink.add(jsonEncode(hs));
  logLine(name, '[CLIENT] auth handshake sent');

  await incoming.stream
      .where((p) => p['type'] == 'auth_ok' || p['auth'] == true)
      .first
      .timeout(authTimeout);

  logLine(name, '[CLIENT] authentication success');
  return RelayConn(channel: ch, sub: sub, incoming: incoming);
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

