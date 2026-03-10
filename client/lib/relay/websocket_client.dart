// lib/relay/websocket_client.dart
// Secure WebSocket relay client.
// Sends: { to, ciphertext, ttl_seconds, msg_type }
// Receives: { from, ciphertext, msg_type, id }
// Reconnects automatically with exponential backoff.
// Connection is WSS (TLS 1.3 on Render).

import 'dart:async';
import 'dart:convert';
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

  // ── Connect to relay server ───────────────────────────────────────────────
  Future<void> connect({
    required String relayUrl,
    required String userId,
  }) async {
    _relayUrl     = relayUrl;
    _userIdHeader = userId;
    await _doConnect();
  }

  Future<void> _doConnect() async {
    if (_disposed) return;
    try {
      // Connect with user_id as a URL param — no real auth (anonymous relay)
      final uri = Uri.parse('$_relayUrl?uid=$_userIdHeader');
      _channel = WebSocketChannel.connect(uri);
      await _channel!.ready;

      _reconnectAttempts = 0;
      onConnected?.call();

      _subscription = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone:  _onDone,
      );
    } catch (e) {
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

  // ── Exponential backoff reconnect ─────────────────────────────────────────
  void _scheduleReconnect() {
    if (_disposed) return;
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
