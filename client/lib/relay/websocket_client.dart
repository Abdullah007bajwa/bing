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

  /// Broadcast stream of incoming packets. Subscribe once (e.g. in coordinator) for app lifetime.
  /// Never cancelled by navigation; only closed on disconnect().
  final StreamController<Map<String, dynamic>> _incomingController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get incomingPackets => _incomingController.stream;

  int _reconnectAttempts = 0;
  static const int _maxReconnectDelay = 30; // seconds

  PacketHandler? onPacket;
  void Function()? onConnected;
  void Function(String reason)? onDisconnected;

  String? _userIdHeader;
  String? _relayUrl;
  /// Called on every connect/reconnect so the timestamp stays inside the server ±5m window.
  Future<Map<String, String>> Function()? _authHandshakeFactory;
  bool _authenticated = false;

  /// True only after the server sends [auth_ok] (not merely after the socket opens).
  bool get isAuthenticated => _authenticated;

  void setAuthHandshakeFactory(Future<Map<String, String>> Function()? factory) {
    _authHandshakeFactory = factory;
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

      _authenticated = false;
      Map<String, String>? handshake;
      if (_authHandshakeFactory != null) {
        try {
          handshake = await _authHandshakeFactory!();
        } catch (e) {
          if (kDebugMode) debugPrint('[Relay] Auth handshake build failed: $e');
        }
      }
      if (handshake != null) {
        _channel!.sink.add(jsonEncode(handshake));
      }
      onConnected?.call();
    } catch (e) {
      _authenticated = false;
      if (kDebugMode) debugPrint('[Relay] Connect failed: $e');
      onDisconnected?.call(e.toString());
      _scheduleReconnect();
    }
  }

  void _onData(dynamic raw) {
    // Log every received frame so we know the stream is alive (length only — never content)
    final rawStr = raw is String ? raw : raw?.toString() ?? '';
    if (kDebugMode) debugPrint('[Relay] RECEIVED len=${rawStr.length}');
    try {
      final packet = jsonDecode(rawStr) as Map<String, dynamic>;
      final authOk = packet['type'] == 'auth_ok' || packet['auth'] == true;
      if (authOk) {
        _authenticated = true;
        return;
      }
      if (packet.containsKey('from')) {
        final from = packet['from'] as String?;
        if (kDebugMode) debugPrint('[Relay] RECV from=${from != null && from.length > 6 ? "${from.substring(0, 6)}…" : from}');
      }
      _incomingController.add(packet);
      onPacket?.call(packet);
    } catch (e) {
      if (kDebugMode) debugPrint('[Relay] _onData parse error: $e');
    }
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
  /// Relay requires non-empty "to" and "id"; packets with empty to/id are rejected server-side.
  bool sendPacket(Map<String, dynamic> packet) {
    if (_channel == null) {
      if (kDebugMode) debugPrint('[Relay] sendPacket: not connected');
      return false;
    }
    if (!_authenticated) {
      if (kDebugMode) debugPrint('[Relay] sendPacket: not authenticated');
      return false;
    }
    final to = packet['to'] as String?;
    final id = packet['id'] as String?;
    if (to == null || to.trim().isEmpty || id == null || id.toString().trim().isEmpty) {
      if (kDebugMode) debugPrint('[Relay] sendPacket: empty to or id, rejected');
      return false;
    }
    try {
      final json = jsonEncode(packet);
      _channel!.sink.add(json);
      if (kDebugMode) {
        final hasCipher = packet['ciphertext'] != null && (packet['ciphertext'] as String).isNotEmpty;
        final idStr = id.toString();
        debugPrint('[Relay] SENT to=${to.length > 6 ? "${to.substring(0, 6)}…" : to} id=${idStr.length > 8 ? "${idStr.substring(0, 8)}…" : idStr} hasCipher=$hasCipher');
      }
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
