// lib/features/chat/chat_screen.dart
// Encrypted 1:1 chat screen.
// Messages encrypted before touch network. Decrypted in RAM only.
// Ephemeral: auto-deletes after TTL or after reading.
// Screenshot blocked app-wide (FLAG_SECURE / screen_protector).

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:libsignal_protocol_dart/libsignal_protocol_dart.dart';
import 'package:uuid/uuid.dart';
import '../../core/crypto/signal_session.dart';
import '../../core/storage/secure_db.dart';
import '../../core/storage/ephemeral_cache.dart';
import '../../core/identity/identity_service.dart';
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
  final _composeController = TextEditingController();
  final _scrollController  = ScrollController();
  final _db       = SecureDb();
  final _cache    = EphemeralCache();
  final _coordinator = RelayCoordinator();
  final _signal   = SignalSessionService();
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

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    // Load identity
    final kp = await _identity.loadIdentityKeyPair();
    _myUserId = await _identity.getUserId();
    if (kp == null) return;

    // Initialize Signal store  
    _signalStore = InMemorySignalProtocolStore(kp, 1);

    // Init session with contact
    _cipher = await _signal.getOrCreateSession(
      contactUserId:      widget.contact.userId,
      contactPublicKeyB64: widget.contact.publicKeyB64,
      store:              _signalStore,
      deviceId:           1,
    );

    // Load saved messages
    var rows = await _db.getMessages(widget.contact.userId);
    _messages = rows.map(GhostMessage.fromDbMap).toList();

    // Process any buffered packets (received while contact list was open)
    final buffered = _coordinator.getBufferedPackets(widget.contact.userId);
    for (final packet in buffered) {
      try {
        final msgType = packet['msg_type'];
        final typeInt = msgType == 'prekey' ? 3 : 2;
        final normalized = Map<String, dynamic>.from(packet)..['type'] = typeInt;
        final plaintext = await _signal.decryptMessage(cipher: _cipher!, packet: normalized);
        final now = DateTime.now().millisecondsSinceEpoch;
        final msg = GhostMessage(
          id:             _uuid.v4(),
          conversationId: widget.contact.userId,
          senderId:       widget.contact.userId,
          ciphertext:     packet['ciphertext'] as String,
          msgType:        MessageType.signal,
          createdAt:      now,
          ttlSeconds:    packet['ttl_seconds'] as int? ?? _ttlSeconds,
          viewOnce:       packet['view_once'] as bool? ?? false,
          status:         MessageStatus.delivered,
        );
        _cache.cacheMessage(msg.id, plaintext, ttl: Duration(seconds: msg.ttlSeconds));
        await _db.insertMessage(msg.toDbMap());
        await _db.markMessageRead(msg.id);
        _messages.add(msg);
      } catch (_) { /* skip undecryptable */ }
    }

    _relay.onConnected    = () => setState(() => _isConnected = true);
    _relay.onDisconnected = (_) => setState(() => _isConnected = false);
    _isConnected = _coordinator.isConnected;

    _coordinator.setCurrentChat(widget.contact.userId, _onIncomingPacket);

    setState(() {
      _messages = _messages;
      _canSend  = true;
    });

    // Periodic message purge (every 15s)
    _purgeTimer = Timer.periodic(const Duration(seconds: 15), (_) => _purgeExpired());
    _scrollToBottom();
  }

  // ── Incoming encrypted packet ───────────────────────────────────────
  Future<void> _onIncomingPacket(Map<String, dynamic> packet) async {
    if (_cipher == null) return;

    try {
      // Relay sends msg_type (string); libsignal expects type (int): 3=PreKey, 2=Signal
      final msgType = packet['msg_type'];
      final typeInt = msgType == 'prekey' ? 3 : 2;
      final normalized = Map<String, dynamic>.from(packet)..['type'] = typeInt;

      final plaintext = await _signal.decryptMessage(cipher: _cipher!, packet: normalized);
      final now       = DateTime.now().millisecondsSinceEpoch;
      final msg       = GhostMessage(
        id:             _uuid.v4(),
        conversationId: widget.contact.userId,
        senderId:       widget.contact.userId,
        ciphertext:     packet['ciphertext'] as String,
        msgType:        MessageType.signal,
        createdAt:      now,
        ttlSeconds:     packet['ttl_seconds'] as int? ?? _ttlSeconds,
        viewOnce:       packet['view_once'] as bool? ?? false,
        status:         MessageStatus.delivered,
      );

      // Cache decrypted plaintext in RAM (never write to DB)
      _cache.cacheMessage(msg.id, plaintext,
          ttl: Duration(seconds: msg.ttlSeconds));

      // Persist only ciphertext to SQLCipher
      await _db.insertMessage(msg.toDbMap());
      await _db.markMessageRead(msg.id);

      setState(() => _messages.add(msg));
      _scrollToBottom();
    } catch (_) {/* decryption failure — discard silently */}
  }

  // ── Send a message ─────────────────────────────────────────────────────────
  Future<void> _sendMessage() async {
    final text = _composeController.text.trim();
    if (text.isEmpty || _cipher == null) return;

    _composeController.clear();
    HapticFeedback.lightImpact();

    final encrypted = await _signal.encryptMessage(cipher: _cipher!, plaintext: text);
    final now       = DateTime.now().millisecondsSinceEpoch;
    final msgId     = _uuid.v4();

    final msg = GhostMessage(
      id:             msgId,
      conversationId: widget.contact.userId,
      senderId:       _myUserId,
      ciphertext:     encrypted['ciphertext'] as String,
      msgType:        encrypted['type'] == 1 ? MessageType.preKey : MessageType.signal,
      createdAt:      now,
      ttlSeconds:     _ephemeralEnabled ? _ttlSeconds : 0,
      status:         MessageStatus.sending,
    );

    // Cache plaintext for immediate display
    _cache.cacheMessage(msgId, text, ttl: Duration(seconds: _ttlSeconds));

    // Persist ciphertext
    await _db.insertMessage(msg.toDbMap());

    setState(() => _messages.add(msg));
    _scrollToBottom();

    // Relay via WebSocket (id required by server for replay protection)
    final sent = _relay.sendPacket({
      'id':          msgId,
      'to':          widget.contact.userId,
      'ciphertext':  encrypted['ciphertext'],
      'msg_type':    encrypted['type'] == 1 ? 'prekey' : 'signal',
      'ttl_seconds': _ttlSeconds,
    });

    if (mounted) {
      setState(() {
        final idx = _messages.indexWhere((m) => m.id == msgId);
        if (idx != -1) {
          _messages[idx] = msg.copyWith(
              status: sent ? MessageStatus.sent : MessageStatus.sending);
        }
      });
    }
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
    _purgeTimer?.cancel();
    _composeController.dispose();
    _scrollController.dispose();
    _signal.evictSession(widget.contact.userId);
    _cache.clear();
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
          // Ephemeral timer toggle
          IconButton(
            icon: Icon(
              _ephemeralEnabled ? Icons.timer_rounded : Icons.timer_off_rounded,
              color: _ephemeralEnabled ? cs.primary : Colors.white30,
            ),
            onPressed: () => setState(() => _ephemeralEnabled = !_ephemeralEnabled),
            tooltip: 'Ephemeral messages',
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
              itemBuilder: (_, i) => _buildBubble(_messages[i]),
            ),
          ),
          _buildComposeBar(cs),
        ],
      ),
    );
  }

  Widget _buildBubble(GhostMessage msg) {
    final isMe      = msg.senderId == _myUserId;
    final plaintext = _cache.getMessage(msg.id) ?? '🔒 [encrypted]';
    final cs        = Theme.of(context).colorScheme;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
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
                    msg.status == MessageStatus.sent ? Icons.check_rounded : Icons.access_time_rounded,
                    size:  12,
                    color: Colors.black54,
                  ),
                ],
              ],
            ),
          ],
        ),
      ).animate().fadeIn(duration: 200.ms).slideY(begin: 0.1),
    );
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
              onSubmitted: (_) => _sendMessage(),
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

  String _formatTime(int timestampMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(timestampMs);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
