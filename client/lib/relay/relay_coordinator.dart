// lib/relay/relay_coordinator.dart
// App-level relay coordination: ensure contact on first message, buffer packets,
// dispatch to current chat. Ensures "who was scanned" sees the sender in contact list
// when first message is received (no notification on add; conversation appears on first message).

import 'package:supabase_flutter/supabase_flutter.dart';
import '../core/identity/identity_service.dart';
import '../core/storage/secure_db.dart';
import '../models/contact.dart';
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

  bool get isConnected => _connected;

  /// Connect relay and install global packet handler. Call once when home screen loads.
  /// Requires non-empty userId (relay server returns "missing uid" otherwise).
  Future<void> connect({required String relayUrl, required String userId}) async {
    if (userId.trim().isEmpty) return;
    if (_relay.isConnected) return;
    _relay.onPacket = _onPacket;
    _relay.onConnected = () => _connected = true;
    _relay.onDisconnected = (_) => _connected = false;
    await _relay.connect(relayUrl: relayUrl, userId: userId);
    _connected = _relay.isConnected;
  }

  void _onPacket(Map<String, dynamic> packet) {
    final from = packet['from'] as String?;
    if (from == null || from.isEmpty) return;

    _ensureContactFor(from);
    _buffer.putIfAbsent(from, () => []).add(packet);

    if (_currentChatUserId == from && _currentChatCallback != null) {
      _currentChatCallback!(packet);
    }
  }

  Future<void> _ensureContactFor(String userId) async {
    final existing = await _db.getContact(userId);
    if (existing != null) return;

    try {
      final supabase = Supabase.instance.client;
      final pubKey = await supabase.rpc(
        'get_public_key_by_hash',
        params: {'lookup_hash': userId},
      );
      if (pubKey == null || pubKey is! String || (pubKey as String).isEmpty) return;

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
