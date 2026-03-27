// lib/features/chat/chat_screen.dart
// Encrypted 1:1 chat screen.
// Messages encrypted before touch network. Decrypted in RAM only.
// Ephemeral: auto-deletes after TTL or after reading.
// Screenshot blocked app-wide (FLAG_SECURE / screen_protector).

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';
import '../../core/crypto/signal_session.dart';
import '../../core/crypto/decrypt_failure.dart';
import '../../core/crypto/base64_util.dart';
import '../../core/storage/secure_db.dart';
import '../../core/storage/ephemeral_cache.dart';
import '../../core/identity/identity_service.dart';
import '../../core/crypto/signal_key_service.dart';
import '../../relay/relay_coordinator.dart';
import '../../relay/websocket_client.dart';
import '../../models/contact.dart';
import '../../models/message.dart';
import '../../app_config.dart';

class ChatScreen extends StatefulWidget {
  final GhostContact contact;
  const ChatScreen({super.key, required this.contact});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const int _maxDecryptAttempts = 50;
  static const int _autoRepairAfterDecryptAttempts = 3;
  static const int _autoRepairCooldownMs = 15000;

  final _composeController = TextEditingController();
  final _scrollController  = ScrollController();
  final _db       = SecureDb();
  final _cache    = EphemeralCache();
  final _coordinator = RelayCoordinator();
  final _signal   = SignalSessionService();
  final _signalKeys = SignalKeyService();
  final _identity = IdentityService();
  final _uuid     = const Uuid();

  GhostRelayClient get _relay => _coordinator.relay;

  late final InMemorySignalProtocolStore _signalStore;
  SessionCipher? _cipher;

  List<GhostMessage> _messages = [];
  bool   _isConnected = false;
  bool   _canSend     = false;
  Timer? _purgeTimer;
  String _myUserId = '';
  bool   _ephemeralEnabled = true;
  int    _ttlSeconds       = AppConfig.defaultTtlSeconds;

  /// Throttle decrypt-triggered repairs (send-path repair sets this too).
  final Map<String, int> _lastSessionAutoRepairMs = {};

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    // Load identity
    final kp = await _identity.loadIdentityKeyPair();
    _myUserId = await _identity.getUserId();
    if (kp == null || !mounted) return;

    final regId = await _signalKeys.getRegistrationId();
    print("[DEBUG] receiver known identity: ${base64Encode(kp.getPublicKey().publicKey.serialize())}");
    print("[DEBUG] receiver registrationId: $regId");
    
    // Initialize Signal store (in-memory; we hydrate private prekeys/signed-prekey from SQLCipher/secure storage)
    _signalStore = InMemorySignalProtocolStore(kp, regId);
    await _signalKeys.hydrateStore(_signalStore);

    // Load persisted session so ratchet state survives navigation (Bug 2 fix)
    final address = SignalProtocolAddress(widget.contact.userId, 1);
    final sessionB64 = await _db.loadSessionState('${widget.contact.userId}.1');
    if (sessionB64 != null && sessionB64.isNotEmpty) {
      try {
        final record = SessionRecord.fromSerialized(safeBase64Decode(sessionB64));
        // Restore whatever ratchet state exists (sender-only, receiver-only, or both).
        // Encrypt can self-heal if sender state is missing.
        await _signalStore.storeSession(address, record);
      } catch (_) {
        // Stale or corrupt session — will build new session below
      }
    }

    // Init session with contact
    try {
      _cipher = await _signal.getOrCreateSession(
        contactUserId:      widget.contact.userId,
        contactPublicKeyB64: widget.contact.publicKeyB64,
        store:              _signalStore,
        deviceId:           1,
      );
    } catch (e) {
      if (mounted) debugPrint('[ChatScreen] Session creation failed: $e');
      return;
    }

    if (!mounted) return;

    final contactRow = await _db.getContact(widget.contact.userId);
    final storedTtl = (contactRow?['chat_ttl_seconds'] as int?) ?? AppConfig.defaultTtlSeconds;
    _ephemeralEnabled = storedTtl > 0;
    _ttlSeconds = (storedTtl > 0 ? storedTtl : AppConfig.defaultTtlSeconds)
        .clamp(300, AppConfig.maxTtlSeconds);

    if (!mounted) return;

    // Load saved messages
    var rows = await _db.getMessages(widget.contact.userId);
    _messages = rows.map(GhostMessage.fromDbMap).toList();
    await _db.markConversationRead(widget.contact.userId);

    await _drainPendingDecrypts();

    if (!mounted) return;

    // Process any buffered packets (received while contact list was open)
    final buffered = _coordinator.getBufferedPackets(widget.contact.userId);
    for (final packet in buffered) {
      try {
        if (packet['type'] == 'receipt' || packet['receipt'] == 'read') {
          final msgId = packet['msg_id'] as String?;
          if (msgId == null || msgId.isEmpty) continue;
          await _db.updateMessageStatus(msgId, MessageStatus.read.index);
          if (mounted) {
            setState(() {
              final idx = _messages.indexWhere((m) => m.id == msgId);
              if (idx != -1) {
                _messages[idx] = _messages[idx].copyWith(status: MessageStatus.read);
              }
            });
          }
          continue;
        }
        if (_packetIsSessionReset(packet)) {
          await _handlePeerSessionReset();
          continue;
        }
        final ciphertext = packet['ciphertext'] as String?;
        if (ciphertext == null || ciphertext.isEmpty) continue;

        final packetId = (packet['id'] as String?)?.trim() ?? '';
        Map<String, dynamic>? row;
        if (packetId.isNotEmpty) {
          row = await _db.getMessageById(packetId);
        }
        GhostMessage? target =
            row != null ? GhostMessage.fromDbMap(row) : null;
        if (target == null) {
          final msgType = packet['msg_type'];
          final typeInt = (msgType == 'prekey' || msgType == 0) ? 3 : 2;
          final now = DateTime.now().millisecondsSinceEpoch;
          final msgId = packetId.isNotEmpty ? packetId : _uuid.v4();
          target = GhostMessage(
            id: msgId,
            conversationId: widget.contact.userId,
            senderId: widget.contact.userId,
            ciphertext: ciphertext,
            msgType: typeInt == 3 ? MessageType.preKey : MessageType.signal,
            createdAt: now,
            ttlSeconds: packet['ttl_seconds'] as int? ?? _ttlSeconds,
            viewOnce: packet['view_once'] as bool? ?? false,
            status: MessageStatus.delivered,
            decryptPending: 1,
            decryptAttempts: 0,
          );
          await _db.insertMessage(target.toDbMap());
        }
        final ok = await _decryptAndSettleOnce(target, markReadOnSuccess: false);
        if (ok) await _drainPendingDecrypts();
      } catch (e) {
        if (mounted) {
          debugPrint('[Chat] Buffered packet failed id ${packet['id']}: $e');
        }
      }
    }

    if (!mounted) return;

    final prevOnConnected = _relay.onConnected;
    final prevOnDisconnected = _relay.onDisconnected;
    _relay.onConnected = () {
      prevOnConnected?.call();
      if (mounted) setState(() => _isConnected = true);
    };
    _relay.onDisconnected = (reason) {
      prevOnDisconnected?.call(reason);
      if (mounted) setState(() => _isConnected = false);
    };
    _isConnected = _relay.isConnected || _coordinator.isConnected;

    _coordinator.setCurrentChat(widget.contact.userId, _onIncomingPacket);

    if (!mounted) return;

    setState(() {
      _messages = _messages;
      _canSend  = true;
    });

    // Periodic message purge (every 15s)

    _purgeTimer = Timer.periodic(const Duration(seconds: 15), (_) => _purgeExpired());
    _scrollToBottom();
  }

  bool _packetIsSessionReset(Map<String, dynamic> packet) {
    final mt = packet['msg_type'];
    if (mt is String && mt == 'session_reset') return true;
    if ('$mt' == 'session_reset') return true;
    return packet['type'] == 'session_reset';
  }

  Future<void> _mergeMessageFromDb(String messageId) async {
    final row = await _db.getMessageById(messageId);
    if (row == null || !mounted) return;
    final gm = GhostMessage.fromDbMap(row);
    setState(() {
      final idx = _messages.indexWhere((m) => m.id == messageId);
      if (idx == -1) {
        final list = [..._messages, gm]
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        _messages = list;
      } else {
        _messages = List<GhostMessage>.from(_messages)..[idx] = gm;
      }
    });
  }

  bool _sessionAutoRepairOnCooldown(String peerId) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastSessionAutoRepairMs[peerId] ?? 0;
    return now - last < _autoRepairCooldownMs;
  }

  /// Notify peer, clear local ratchet, drop undecryptable backlog, refresh cipher.
  /// Matches production messengers: bilateral reset without manual key/session files.
  Future<void> _autoRepairSessionWithPeer() async {
    final peer = widget.contact.userId.trim();
    if (peer.isEmpty || !mounted) return;

    _lastSessionAutoRepairMs[peer] =
        DateTime.now().millisecondsSinceEpoch;

    _coordinator.sendSessionResetIfAllowed(
      fromUserId: _myUserId,
      toUserId: peer,
    );
    await _signal.clearSessionForPeer(
      store: _signalStore,
      contactUserId: peer,
    );
    _signal.evictSession(peer);
    await _db.abandonPendingDecryptsForConversation(peer, _myUserId);
    _cipher = await _signal.getOrCreateSession(
      contactUserId: peer,
      contactPublicKeyB64: widget.contact.publicKeyB64,
      store: _signalStore,
      deviceId: 1,
    );
    if (kDebugMode) {
      debugPrint(
        '[Chat] Session auto-repair: session_reset sent, local state cleared, '
        'stale decrypt queue abandoned',
      );
    }
    if (mounted) {
      setState(() {
        _messages = _messages
            .map((m) {
              if (m.senderId == _myUserId || m.decryptPending != 1) return m;
              return m.copyWith(
                decryptPending: 0,
                decryptPermanentFail: 1,
                lastDecryptError: 'session_auto_reset',
              );
            })
            .toList();
      });
    }
  }

  /// Drain pending decrypts in DB order; one success may unlock the next ratchet step.
  Future<void> _drainPendingDecrypts() async {
    if (!mounted || _cipher == null) return;
    while (mounted && _cipher != null) {
      final rows = await _db.getPendingDecryptMessages(
        widget.contact.userId,
        _myUserId,
        maxAttempts: _maxDecryptAttempts,
      );
      if (rows.isEmpty) break;
      var progressed = false;
      for (final row in rows) {
        final msg = GhostMessage.fromDbMap(row);
        if (await _decryptAndSettleOnce(msg, markReadOnSuccess: false)) {
          progressed = true;
          break;
        }
      }
      if (!progressed) break;
    }
  }

  Future<bool> _decryptAndSettleOnce(
    GhostMessage msg, {
    required bool markReadOnSuccess,
  }) async {
    final cipher = _cipher;
    if (cipher == null || !mounted) return false;
    if (msg.senderId == _myUserId) return false;
    if (msg.decryptPermanentFail == 1) return false;

    if (_cache.getMessage(msg.id) != null) {
      if (msg.decryptPending == 1) {
        await _db.updateMessageDecryptState(
          msg.id,
          decryptPending: 0,
          decryptAttempts: msg.decryptAttempts,
          lastDecryptError: null,
          decryptPermanentFail: 0,
        );
        await _mergeMessageFromDb(msg.id);
      }
      return false;
    }

    final nextAttempts = msg.decryptAttempts + 1;
    if (nextAttempts > _maxDecryptAttempts) {
      await _db.updateMessageDecryptState(
        msg.id,
        decryptPending: 0,
        decryptAttempts: nextAttempts,
        lastDecryptError: 'max_decrypt_attempts',
        decryptPermanentFail: 0,
      );
      await _mergeMessageFromDb(msg.id);
      return false;
    }

    final typeInt = msg.msgType == MessageType.preKey ? 3 : 2;
    final normalized = {
      'type': typeInt,
      'ciphertext': msg.ciphertext,
      'ttl_seconds': msg.ttlSeconds,
    };

    try {
      final plaintext = await _signal.decryptMessage(
        cipher: cipher,
        packet: normalized,
        store: _signalStore,
        contactUserId: widget.contact.userId,
        deviceId: 1,
      );
      await _db.updateMessageDecryptState(
        msg.id,
        decryptPending: 0,
        decryptAttempts: nextAttempts,
        lastDecryptError: null,
        decryptPermanentFail: 0,
      );
      await _db.updateMessageBodyPlaintext(msg.id, plaintext);
      _cache.cacheMessage(
        msg.id,
        plaintext,
        ttl: Duration(seconds: msg.ttlSeconds > 0 ? msg.ttlSeconds : 3600),
      );
      if (markReadOnSuccess) {
        await _db.updateMessageStatus(msg.id, MessageStatus.read.index);
        _sendReadReceipt(msg.id, msg.senderId);
      }
      await _mergeMessageFromDb(msg.id);
      return true;
    } on DecryptException catch (e) {
      final perm = e.permanentFailure ? 1 : 0;
      final pending = (e.retryLater && perm == 0) ? 1 : 0;
      await _db.updateMessageDecryptState(
        msg.id,
        decryptPending: pending,
        decryptAttempts: nextAttempts,
        lastDecryptError: e.message,
        decryptPermanentFail: perm,
      );
      await _mergeMessageFromDb(msg.id);

      final peer = widget.contact.userId.trim();
      final shouldRepair = perm == 0 &&
          nextAttempts >= _autoRepairAfterDecryptAttempts &&
          (e.failureType == DecryptFailureType.badMac ||
              e.failureType == DecryptFailureType.staleSession) &&
          peer.isNotEmpty &&
          !_sessionAutoRepairOnCooldown(peer);
      if (shouldRepair) {
        if (kDebugMode) {
          debugPrint(
            '[Chat] Repeated decrypt failure (${e.failureType.name}) — '
            'running bilateral auto-repair',
          );
        }
        await _autoRepairSessionWithPeer();
        await _drainPendingDecrypts();
      }
      return false;
    } catch (e) {
      await _db.updateMessageDecryptState(
        msg.id,
        decryptPending: 1,
        decryptAttempts: nextAttempts,
        lastDecryptError: e.toString(),
        decryptPermanentFail: 0,
      );
      await _mergeMessageFromDb(msg.id);
      return false;
    }
  }

  Future<void> _handlePeerSessionReset() async {
    if (_cipher == null || !mounted) return;
    try {
      // Peer cleared their send session; we must drop our receive state for them.
      // Do NOT run outbound X3DH here — that consumes their prekey and builds the wrong
      // ratchet for decrypting *their* next PreKey. Wait for their next establishing message.
      await _signal.clearSessionForPeer(
        store: _signalStore,
        contactUserId: widget.contact.userId,
      );
      _cipher = await _signal.getOrCreateSession(
        contactUserId: widget.contact.userId,
        contactPublicKeyB64: widget.contact.publicKeyB64,
        store: _signalStore,
        deviceId: 1,
      );
      await _drainPendingDecrypts();
    } catch (e) {
      if (kDebugMode) debugPrint('[Chat] Peer session_reset handling failed: $e');
    }
  }

  // ── Incoming encrypted packet ───────────────────────────────────────
  Future<void> _onIncomingPacket(Map<String, dynamic> packet) async {
    if (_cipher == null || !mounted) return;

    try {
      // Read receipt (double-tick): { type: "receipt", receipt: "read", msg_id: "...", from: "..." }
      if (packet['type'] == 'receipt' || packet['receipt'] == 'read') {
        final msgId = packet['msg_id'] as String?;
        if (msgId == null || msgId.isEmpty) return;
        await _db.updateMessageStatus(msgId, MessageStatus.read.index);
        if (!mounted) return;
        setState(() {
          final idx = _messages.indexWhere((m) => m.id == msgId);
          if (idx != -1) {
            _messages[idx] = _messages[idx].copyWith(status: MessageStatus.read);
          }
        });
        return;
      }

      if (_packetIsSessionReset(packet)) {
        await _handlePeerSessionReset();
        return;
      }

      final ciphertext = packet['ciphertext'] as String?;
      if (ciphertext == null || ciphertext.isEmpty) return;

      final incomingId = (packet['id'] as String?)?.trim() ?? '';
      Map<String, dynamic>? row;
      if (incomingId.isNotEmpty) {
        row = await _db.getMessageById(incomingId);
      }
      GhostMessage? target =
          row != null ? GhostMessage.fromDbMap(row) : null;
      if (target == null) {
        final msgType = packet['msg_type'];
        final typeInt = (msgType == 'prekey' || msgType == 0) ? 3 : 2;
        final now = DateTime.now().millisecondsSinceEpoch;
        final msgId = incomingId.isNotEmpty ? incomingId : _uuid.v4();
        target = GhostMessage(
          id: msgId,
          conversationId: widget.contact.userId,
          senderId: widget.contact.userId,
          ciphertext: ciphertext,
          msgType: typeInt == 3 ? MessageType.preKey : MessageType.signal,
          createdAt: now,
          ttlSeconds: packet['ttl_seconds'] as int? ?? _ttlSeconds,
          viewOnce: packet['view_once'] as bool? ?? false,
          status: MessageStatus.delivered,
          decryptPending: 1,
          decryptAttempts: 0,
        );
        await _db.insertMessage(target.toDbMap());
      }

      final ok =
          await _decryptAndSettleOnce(target, markReadOnSuccess: true);
      if (ok) {
        await _drainPendingDecrypts();
        _scrollToBottom();
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Chat] Incoming packet handling failed: $e');
        debugPrint('[Chat] Packet: $packet');
      }
    }
  }

  // ── Send a message ─────────────────────────────────────────────────────────
  Future<void> _sendMessage() async {
    final text = _composeController.text.trim();
    if (text.isEmpty || _cipher == null) return;

    // Recipient must be resolved (relay drops packets with empty to)
    final recipientId = widget.contact.userId.trim();
    if (recipientId.isEmpty) {
      if (kDebugMode) debugPrint('[Chat] ERROR: recipient userId is empty, aborting send');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Recipient not set. Open the contact again.')),
        );
      }
      return;
    }

    // Block send until relay is connected and authenticated
    if (!_relay.isConnected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relay not connected. Connect and try again.')),
        );
      }
      return;
    }

    _composeController.clear();
    HapticFeedback.lightImpact();

    Map<String, dynamic> encrypted;
    try {
      encrypted = await _signal.encryptMessage(
        cipher: _cipher!,
        plaintext: text,
        store: _signalStore,
        contactUserId: widget.contact.userId,
        deviceId: 1,
        onBeforeSessionRebuild: () {
          _coordinator.sendSessionResetIfAllowed(
            fromUserId: _myUserId,
            toUserId: widget.contact.userId,
          );
        },
      );
    } on SessionDesyncException catch (e) {
      if (kDebugMode) {
        debugPrint('[Chat] Session desync on send — auto-repair then retry: $e');
      }
      await _autoRepairSessionWithPeer();
      try {
        encrypted = await _signal.encryptMessage(
          cipher: _cipher!,
          plaintext: text,
          store: _signalStore,
          contactUserId: widget.contact.userId,
          deviceId: 1,
          onBeforeSessionRebuild: () {
            _coordinator.sendSessionResetIfAllowed(
              fromUserId: _myUserId,
              toUserId: widget.contact.userId,
            );
          },
        );
      } catch (e2) {
        if (kDebugMode) debugPrint('[Chat] Encrypt failed after auto-repair: $e2');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Encryption failed: $e2')),
          );
        }
        return;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[Chat] Encrypt failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Encryption failed: $e')),
        );
      }
      return;
    }

    _cipher = await _signal.getOrCreateSession(
      contactUserId: widget.contact.userId,
      contactPublicKeyB64: widget.contact.publicKeyB64,
      store: _signalStore,
      deviceId: 1,
    );
    final now       = DateTime.now().millisecondsSinceEpoch;
    final msgId     = _uuid.v4();

    final msg = GhostMessage(
      id:             msgId,
      conversationId: widget.contact.userId,
      senderId:       _myUserId,
      ciphertext:     encrypted['ciphertext'] as String,
      // libsignal_protocol_dart ciphertext.getType():
      // 3 = PREKEY_TYPE (PreKeySignalMessage), 2 = WHISPER_TYPE (SignalMessage)
      msgType:        encrypted['type'] == 3 ? MessageType.preKey : MessageType.signal,
      createdAt:      now,
      ttlSeconds:     _ephemeralEnabled ? _ttlSeconds : 0,
      status:         MessageStatus.sending,
      bodyPlaintext:  text,
    );

    // Cache plaintext for immediate display
    _cache.cacheMessage(msgId, text, ttl: Duration(seconds: _ttlSeconds));

    // Show bubble before awaiting DB so UI updates immediately (async gap used to skip setState).
    if (mounted) {
      setState(() => _messages = [..._messages, msg]);
    }
    _scrollToBottom();

    await _db.insertMessage(msg.toDbMap());

    if (!mounted) return;

    final ciphertext = encrypted['ciphertext'] as String?;
    if (ciphertext == null || ciphertext.isEmpty) {
      if (kDebugMode) debugPrint('[Chat] ERROR: ciphertext empty after encrypt, aborting send');
      return;
    }
    final packet = {
      'type':        'message',
      'id':          msgId,
      'to':          recipientId,
      'from':        _myUserId,
      'ciphertext':  ciphertext,
      'msg_type':    encrypted['type'] == 3 ? 'prekey' : 'signal',
      'ttl_seconds': msg.ttlSeconds,
      'timestamp':   now,
    };
    final sent = _relay.sendPacket(packet);
    if (!sent && kDebugMode) debugPrint('[Chat] Relay send failed');

    if (sent) await _db.updateMessageStatus(msg.id, MessageStatus.sent.index);
    if (mounted) {
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == msgId);
        if (idx != -1) {
          final next = msg.copyWith(
            status: sent ? MessageStatus.sent : MessageStatus.sending,
          );
          _messages = List<GhostMessage>.from(_messages)..[idx] = next;
        }
      });
    }
  }

  void _sendReadReceipt(String messageId, String senderId) {
    if (!_relay.isConnected) return;
    final packet = {
      'type': 'receipt',
      'receipt': 'read',
      'msg_id': messageId,
      'from': _myUserId,
      'to': senderId,
      'id': _uuid.v4(),
    };
    _relay.sendPacket(packet);
  }

  Future<void> _purgeExpired() async {
    final deleted = await _db.purgeExpiredMessages();
    if (deleted > 0) {
      final rows = await _db.getMessages(widget.contact.userId);
      if (mounted) setState(() => _messages = rows.map(GhostMessage.fromDbMap).toList());
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve:    Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _coordinator.setCurrentChat(null, null);
    _signal.evictSession(widget.contact.userId);
    _purgeTimer?.cancel();
    _composeController.dispose();
    _scrollController.dispose();
    // Do not clear cache on dispose — so reopening this chat shows plaintext (sent + received) until TTL
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: cs.primary.withOpacity(0.15),
              child: Text(widget.contact.displayName[0].toUpperCase(),
                  style: TextStyle(color: cs.primary, fontSize: 13, fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.contact.displayName,
                    style: GoogleFonts.inter(fontSize: 15, fontWeight: FontWeight.w600)),
                Row(children: [
                  Container(
                    width: 6, height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _isConnected ? const Color(0xFF00E5B0) : Colors.white30,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isConnected ? 'Encrypted' : 'Reconnecting…',
                    style: GoogleFonts.inter(fontSize: 10, color: Colors.white38),
                  ),
                ]),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              _ephemeralEnabled ? Icons.timer_rounded : Icons.timer_off_rounded,
              color: _ephemeralEnabled ? cs.primary : Colors.white30,
            ),
            onPressed: _openTimerPicker,
            tooltip: 'Disappearing timer',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller:  _scrollController,
              padding:     const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              itemCount:   _messages.length,
              itemBuilder: (_, i) {
                final m = _messages[i];
                return KeyedSubtree(
                  key: ValueKey<String>(m.id),
                  child: _buildBubble(m),
                );
              },
            ),
          ),
          _buildComposeBar(cs),
        ],
      ),
    );
  }

  Widget _buildBubble(GhostMessage msg) {
    final isMe      = msg.senderId == _myUserId;
    final cached = _cache.getMessage(msg.id);
    final persisted = msg.bodyPlaintext;
    final canTryDecrypt = !isMe &&
        cached == null &&
        (persisted == null || persisted.isEmpty) &&
        msg.decryptPermanentFail == 0;
    final plaintext = cached ??
        persisted ??
        (isMe
            ? (msg.status == MessageStatus.sending ? 'Sending…' : 'Sent')
            : '[Tap to decrypt]');
    final cs        = Theme.of(context).colorScheme;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onTap: canTryDecrypt ? () => _decryptForDisplay(msg) : null,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
          decoration: BoxDecoration(
            gradient: isMe
                ? LinearGradient(
                    colors: [cs.primary, const Color(0xFF6C63FF)],
                    begin:  Alignment.topLeft,
                    end:    Alignment.bottomRight,
                  )
                : null,
            color: isMe ? null : const Color(0xFF1C1F27),
            borderRadius: BorderRadius.only(
              topLeft:     const Radius.circular(18),
              topRight:    const Radius.circular(18),
              bottomLeft:  Radius.circular(isMe ? 18 : 4),
              bottomRight: Radius.circular(isMe ? 4  : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                plaintext,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color:    isMe ? Colors.black : Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (msg.isEphemeral)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.timer_rounded,
                          size: 10, color: isMe ? Colors.black54 : Colors.white30),
                    ),
                  Text(
                    _formatTime(msg.createdAt),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: isMe ? Colors.black54 : Colors.white30,
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 4),
                    Icon(
                      msg.status == MessageStatus.sending
                          ? Icons.access_time_rounded
                          : (msg.status == MessageStatus.read || msg.status == MessageStatus.delivered)
                              ? Icons.done_all_rounded
                              : Icons.check_rounded,
                      size:  12,
                      color: Colors.black54,
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _decryptForDisplay(GhostMessage msg) async {
    try {
      if (_cipher == null) return;
      final ok = await _decryptAndSettleOnce(msg, markReadOnSuccess: true);
      if (ok) {
        await _drainPendingDecrypts();
        return;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not decrypt message')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not decrypt message')),
        );
      }
    }
  }

  Widget _buildComposeBar(ColorScheme cs) {
    return Container(
      padding:    const EdgeInsets.fromLTRB(12, 8, 12, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1115),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller:  _composeController,
              maxLines:    null,
              keyboardType: TextInputType.multiline,
              style:      GoogleFonts.inter(fontSize: 15),
              decoration: const InputDecoration(
                hintText: 'Message…',
                contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onSubmitted: _canSend ? (_) => _sendMessage() : null,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _canSend ? _sendMessage : null,
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [cs.primary, const Color(0xFF6C63FF)],
                ),
                borderRadius: BorderRadius.circular(22),
              ),
              child: const Icon(Icons.send_rounded, color: Colors.black, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openTimerPicker() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF111318),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.timer_off_rounded),
              title: const Text('Off'),
              onTap: () => Navigator.pop(context, 0),
            ),
            ListTile(
              leading: const Icon(Icons.timer_rounded),
              title: const Text('5 minutes'),
              onTap: () => Navigator.pop(context, 300),
            ),
            ListTile(
              leading: const Icon(Icons.timer_rounded),
              title: const Text('1 hour'),
              onTap: () => Navigator.pop(context, 3600),
            ),
            ListTile(
              leading: const Icon(Icons.timer_rounded),
              title: const Text('24 hours'),
              onTap: () => Navigator.pop(context, 86400),
            ),
            ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('Custom'),
              onTap: () => Navigator.pop(context, -1),
            ),
          ],
        ),
      ),
    );
    if (selected == null) return;
    int ttl = selected;
    if (selected == -1) {
      if (!mounted) return;
      final c = TextEditingController(text: (_ttlSeconds ~/ 60).toString());
      final v = await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Custom timer (minutes)'),
          content: TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: 'e.g. 5'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final mins = int.tryParse(c.text.trim());
                if (mins == null || mins <= 0) return;
                Navigator.pop(ctx, mins * 60);
              },
              child: const Text('Set'),
            ),
          ],
        ),
      );
      if (v == null) return;
      ttl = v;
    }
    ttl = ttl.clamp(0, AppConfig.maxTtlSeconds);
    await _db.setChatTtlSeconds(widget.contact.userId, ttl);
    if (!mounted) return;
    setState(() {
      _ephemeralEnabled = ttl > 0;
      if (ttl > 0) _ttlSeconds = ttl;
    });
  }

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
