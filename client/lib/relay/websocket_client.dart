// lib/relay/websocket_client.dart
// Secure WebSocket relay client.
// Relay requires: wss://<host>/ws?uid=<ghost_id>. Server rejects "missing uid" otherwise.
// Sends: { id, to, ciphertext, ttl_seconds, msg_type }
// Receives: { from, ciphertext, msg_type, id }. Exponential backoff reconnect (max 30s).

import 'dart:async';
import 'dart:convert';
import 'dart:foundation.dart' show debugPrint, kDebugMode;
import 'dart:math';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

typedef PacketHandler = void Function(Map<String, dynamic> packet);

class GhostRelayClient {
  static final GhostRelayClient _instance = GhostRelayClient._();
  factory GhostRelayClient() => _instance;
  GhostRelayClient._();

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  bool _disposed = false;

  int _reconnectAttempts = 0;
  static const int _maxReconnectDelay = 30; // seconds

  PacketHandler? onPacket;
  void Function()? onConnected;
  void Function(String reason)? onDisconnected;

  String? _userIdHeader;
  String? _relayUrl;

  /// Builds WSS URL with required uid query param. Relay rejects connection without it.
  static Uri buildConnectionUri(String relayUrl, String userId) {
    final base = Uri.parse(relayUrl);
    final query = Map<String, String>.from(base.queryParameters)..['uid'] = userId;
    return base.replace(queryParameters: query);
  }

  // ── Connect to relay server ───────────────────────────────────────────────
  /// Requires non-empty [userId] from identity service. Does not connect if userId is empty.
  Future<void> connect({
    required String relayUrl,
    required String userId,
  }) async {
    final uid = userId.trim();
    if (uid.isEmpty) {
      if (kDebugMode) debugPrint('[GhostRelay] Cannot connect: userId is empty');
      onDisconnected?.call('missing uid');
      return;
    }
    _relayUrl     = relayUrl;
    _userIdHeader = uid;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_disposed) return;
    final uid = _userIdHeader;
    if (uid == null || uid.isEmpty) {
      if (kDebugMode) debugPrint('[GhostRelay] Reconnect skipped: no uid');
      return;
    }
    final uri = buildConnectionUri(_relayUrl!, uid);
    if (kDebugMode) {
      debugPrint('[GhostRelay] Connecting to ${uri.origin}${uri.path}?uid=${uid.length > 4 ? "${uid.substring(0, 4)}…" : "***"}');
    }
    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _reconnectAttempts = 0;
      if (kDebugMode) debugPrint('[GhostRelay] Connected');
      onConnected?.call();

      _subscription = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone:  _onDone,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[GhostRelay] Connect failed: $e');
      onDisconnected?.call(e.toString());
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    try {
      final packet = jsonDecode(raw as String) as Map<String, dynamic>;
      onPacket?.call(packet);
    } catch (_) {
      // Malformed packet — silently discard (never crash on relay data)
    }
  }

  void _onError(Object error) {
    onDisconnected?.call(error.toString());
    _scheduleReconnect();
  }

  void _onDone() {
    onDisconnected?.call('Connection closed');
    _scheduleReconnect();
  }

  // ── Send encrypted packet ─────────────────────────────────────────────────
  bool sendPacket(Map<String, dynamic> packet) {
    if (_channel == null) return false;
    try {
      _channel!.sink.add(jsonEncode(packet));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ── Exponential backoff reconnect (preserves uid) ─────────────────────────
  void _scheduleReconnect() {
    if (_disposed) return;
    if (_userIdHeader == null || _userIdHeader!.isEmpty) return;
    _reconnectTimer?.cancel();
    final delay = Duration(
      seconds: min(
        _maxReconnectDelay,
        (pow(2, _reconnectAttempts) + Random().nextDouble()).round(),
      ),
    );
    _reconnectAttempts++;
    if (kDebugMode) debugPrint('[GhostRelay] Reconnecting in ${delay.inSeconds}s (attempt $_reconnectAttempts)');
    _reconnectTimer = Timer(delay, _doConnect);
  }

  // ── Disconnect ────────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    await _subscription?.cancel();
    await _channel?.sink.close(status.normalClosure);
    _channel = null;
  }

  bool get isConnected => _channel != null;
}
