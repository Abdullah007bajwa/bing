// lib/relay/websocket_client.dart
// Secure WebSocket relay client.
// Relay requires: wss://<host>/ws?uid=<ghost_id>. Server rejects "missing uid" otherwise.
// Sends: { id, to, ciphertext, ttl_seconds, msg_type }
// Receives: { from, ciphertext, msg_type, id }. Exponential backoff reconnect (max 30s).

import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
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
  Map<String, String>? _authHandshake;
  bool _authenticated = false;

  /// Whether the relay has accepted the connection (handshake sent; server may or may not send auth_ok).
  bool get isAuthenticated => _authenticated;

  /// Set relay authentication handshake for signed connection
  void setAuthHandshake(Map<String, String> handshake) {
    _authHandshake = handshake;
  }

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
      if (kDebugMode) debugPrint('[Relay] Connect skipped: empty uid');
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
      if (kDebugMode) debugPrint('[Relay] Reconnect skipped: no uid');
      return;
    }
    final uri = buildConnectionUri(_relayUrl!, uid);
    try {
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _reconnectAttempts = 0;

      // Subscribe FIRST so we never miss a frame (e.g. deliverPending sent immediately after register)
      _subscription = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone:  _onDone,
      );

      if (_authHandshake != null) {
        _channel!.sink.add(jsonEncode(_authHandshake));
      }
      _authenticated = true;
      onConnected?.call();
    } catch (e) {
      _authenticated = false;
      if (kDebugMode) debugPrint('[Relay] Connect failed: $e');
      onDisconnected?.call(e.toString());
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    try {
      final packet = jsonDecode(raw as String) as Map<String, dynamic>;
      final authOk = packet['type'] == 'auth_ok' || packet['auth'] == true;
      if (authOk) {
        _authenticated = true;
        return;
      }
      if (packet.containsKey('from')) {
        final from = packet['from'] as String?;
        if (kDebugMode) debugPrint('[Relay] RECV from=${from != null && from.length > 6 ? "${from.substring(0, 6)}…" : from}');
      }
      onPacket?.call(packet);
    } catch (_) {}
  }

  void _onError(Object error) {
    _authenticated = false;
    onDisconnected?.call(error.toString());
    _scheduleReconnect();
  }

  void _onDone() {
    _authenticated = false;
    onDisconnected?.call('Connection closed');
    _scheduleReconnect();
  }

  // ── Send encrypted packet ─────────────────────────────────────────────────
  /// Sends only when channel is connected. Logs in debug. Returns false if not connected or on error.
  bool sendPacket(Map<String, dynamic> packet) {
    if (_channel == null) {
      if (kDebugMode) debugPrint('[Relay] sendPacket: not connected');
      return false;
    }
    if (!_authenticated) {
      if (kDebugMode) debugPrint('[Relay] sendPacket: not authenticated');
      return false;
    }
    try {
      final json = jsonEncode(packet);
      _channel!.sink.add(json);
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('[GhostRelay] sendPacket error: $e');
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
