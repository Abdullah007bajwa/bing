// lib/relay/relay_coordinator.dart
// App-level relay coordination: ensure contact on first message, buffer packets,
// dispatch to current chat. Ensures "who was scanned" sees the sender in contact list
// when first message is received (no notification on add; conversation appears on first message).

import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:uuid/uuid.dart';
import '../core/identity/identity_service.dart';
import '../core/storage/secure_db.dart';
import '../relay/relay_auth_service.dart';
import '../models/contact.dart';
import '../models/message.dart';
import 'websocket_client.dart';

typedef IncomingPacketCallback = void Function(Map<String, dynamic> packet);

class RelayCoordinator {
  static final RelayCoordinator _instance = RelayCoordinator._();
  factory RelayCoordinator() => _instance;
  RelayCoordinator._();

  final GhostRelayClient _relay = GhostRelayClient();
  final SecureDb _db = SecureDb();
  final IdentityService _identity = IdentityService();

  final Map<String, List<Map<String, dynamic>>> _buffer = {};
  String? _currentChatUserId;
  IncomingPacketCallback? _currentChatCallback;
  bool _connected = false;

  static const int _sessionResetCooldownMs = 30000;
  final Map<String, int> _lastSessionResetSentMs = {};
  final _uuid = const Uuid();

  bool get isConnected => _connected;

  // Broadcast notification for UI refresh (no ciphertext/metadata; just sender uid).
  final StreamController<String> _incomingNotify = StreamController<String>.broadcast();
  Stream<String> get incomingNotify => _incomingNotify.stream;

  /// Connect relay and install global packet handler. Call once at app startup.
  /// onPacket must be set before connect() so deliverPending packets are not dropped.
  Future<void> connect({required String relayUrl, required String userId}) async {
    if (userId.trim().isEmpty) return;

    _relay.onConnected = () => _connected = true;
    _relay.onDisconnected = (_) => _connected = false;

    // Wire the global packet handler before connect so deliverPending and all incoming messages are handled
    _relay.onPacket = _onPacket;

    if (_relay.isConnected) {
      _connected = true;
      return;
    }

    try {
      final identityKeyPair = await _identity.loadIdentityKeyPair();
      if (identityKeyPair != null) {
        final authService = RelayAuthService();
        final handshake = await authService.generateAuthHandshake(
          userId: userId,
          identityKeyPair: identityKeyPair,
        );
        _relay.setAuthHandshake(handshake);
      }
    } catch (e) {
      debugPrint('[RelayCoordinator] Failed to generate handshake: $e');
    }

    await _relay.connect(relayUrl: relayUrl, userId: userId);
    _connected = _relay.isConnected;
  }

  bool _isSessionResetPacket(Map<String, dynamic> packet) {
    final mt = packet['msg_type'];
    if (mt is String && mt == 'session_reset') return true;
    return packet['type'] == 'session_reset';
  }

  /// Rate-limited notify to peer that we rebuilt our sending session (encrypt self-heal).
  bool sendSessionResetIfAllowed({
    required String fromUserId,
    required String toUserId,
  }) {
    final to = toUserId.trim();
    if (to.isEmpty) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastSessionResetSentMs[to] ?? 0;
    if (now - last < _sessionResetCooldownMs) return false;
    _lastSessionResetSentMs[to] = now;
    return _relay.sendPacket({
      'type': 'message',
      'id': _uuid.v4(),
      'to': to,
      'from': fromUserId,
      'msg_type': 'session_reset',
      'ttl_seconds': 3600,
      'ciphertext': '',
    });
  }

  void _onPacket(Map<String, dynamic> packet) {
    Future<void>(() async {
      final from = packet['from'] as String?;
      if (from == null || from.isEmpty) return;

      await _ensureContactFor(from);

      if (_isSessionResetPacket(packet)) {
        _buffer.putIfAbsent(from, () => []).add(packet);
        if (!_incomingNotify.isClosed) _incomingNotify.add(from);
        if (_currentChatUserId == from && _currentChatCallback != null) {
          _currentChatCallback!(packet);
        }
        return;
      }

      // Persist ciphertext immediately so messages are visible even if user isn't in the chat screen.
      // Never store plaintext; decrypt happens later in ChatScreen.
      final ciphertext = packet['ciphertext'] as String?;
      if (ciphertext != null && ciphertext.isNotEmpty) {
        final now = DateTime.now().millisecondsSinceEpoch;
        final incomingId = (packet['id'] as String?)?.trim();
        final msgType = packet['msg_type'];
        final isPreKey = msgType == 'prekey' || msgType == 0;
        final ttl = packet['ttl_seconds'] as int?;
        final msg = GhostMessage(
          id: (incomingId != null && incomingId.isNotEmpty) ? incomingId : now.toString(),
          conversationId: from,
          senderId: from,
          ciphertext: ciphertext,
          msgType: isPreKey ? MessageType.preKey : MessageType.signal,
          createdAt: now,
          ttlSeconds: ttl ?? 3600,
          status: MessageStatus.delivered,
          isRead: false,
          decryptPending: 1,
          decryptAttempts: 0,
        );
        await _db.insertMessage(msg.toDbMap());

        // In-app feedback (sound/haptic) when a message arrives while app is open.
        try {
          FlutterRingtonePlayer().playNotification();
          HapticFeedback.selectionClick();
        } catch (_) {}
      }

      _buffer.putIfAbsent(from, () => []).add(packet);

      // Notify listeners (e.g. ContactsScreen) to refresh UI.
      if (!_incomingNotify.isClosed) _incomingNotify.add(from);

      if (_currentChatUserId == from && _currentChatCallback != null) {
        _currentChatCallback!(packet);
      }
    });
  }

  Future<void> _ensureContactFor(String userId) async {
    final existing = await _db.getContact(userId);
    if (existing != null) return;

    try {
      final supabase = Supabase.instance.client;
      final response = await supabase
          .from('users')
          .select('public_key')
          .eq('user_id', userId)
          .maybeSingle();
      
      final pubKey = response?['public_key'] as String?;
      if (pubKey == null || pubKey.isEmpty) {
        debugPrint('[RelayCoordinator] Public key not found for incoming contact: $userId');
        return;
      }

      final fingerprint = await _identity.getFingerprint(pubKey);
      final now = DateTime.now().millisecondsSinceEpoch;
      final contact = GhostContact(
        userId:       userId,
        publicKeyB64: pubKey,
        fingerprint:  fingerprint,
        nickname:     null,
        verified:     false,
        addedAt:      now,
      );
      await _db.upsertContact(contact.toDbMap());
    } catch (_) {
      // Offline or RPC error — contact will stay missing until next time
    }
  }

  /// Returns and clears buffered packets for this contact. Call when opening ChatScreen.
  List<Map<String, dynamic>> getBufferedPackets(String contactUserId) {
    final list = _buffer.remove(contactUserId);
    return list ?? [];
  }

  /// Set current chat so incoming packets for this contact are delivered to callback.
  void setCurrentChat(String? contactUserId, IncomingPacketCallback? callback) {
    _currentChatUserId = contactUserId;
    _currentChatCallback = callback;
  }

  GhostRelayClient get relay => _relay;
}
