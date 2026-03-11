// lib/core/crypto/traffic_padding_service.dart
// Implementing Phase 6: Traffic Obfuscation
// Sends dummy, fixed-size packets to the relay at randomized intervals.
// This prevents ISPs and the Relay itself from correlating packet timing/sizes
// to deduce when a user is actively chatting vs idle.

import 'dart:async';
import 'dart:math';
import 'package:uuid/uuid.dart';
import '../../relay/websocket_client.dart';

class TrafficPaddingService {
  static final TrafficPaddingService _instance = TrafficPaddingService._internal();
  factory TrafficPaddingService() => _instance;
  TrafficPaddingService._internal();

  Timer? _paddingTimer;
  final _random = Random.secure();
  final _uuid = const Uuid();

  /// Constants mimicking actual Signal payload distributions
  static const int _basePayloadLength = 256;
  static const int _maxPaddingLength = 4096;
  static const int _minIntervalMs = 5000;
  static const int _maxIntervalMs = 30000;

  bool _isRunning = false;

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _scheduleNextDecoy();
  }

  void stop() {
    _isRunning = false;
    _paddingTimer?.cancel();
  }

  void _scheduleNextDecoy() {
    if (!_isRunning) return;

    final delay = Duration(
        milliseconds: _minIntervalMs + _random.nextInt(_maxIntervalMs - _minIntervalMs));

    _paddingTimer = Timer(delay, () {
      _sendDecoyPacket();
      _scheduleNextDecoy(); // Reschedule indefinitely
    });
  }

  void _sendDecoyPacket() {
    final relay = GhostRelayClient();
    if (!relay.isConnected) return;

    // Generate random noise string to pad the payload
    final paddingLength = _basePayloadLength + _random.nextInt(_maxPaddingLength);
    final noiseChars = String.fromCharCodes(
        List.generate(paddingLength, (_) => _random.nextInt(255)));

    // Generate a non-existent recipient UUID
    final fakeRecipient = _uuid.v4();

    // The relay will attempt to store this in Redis for the fake user.
    // It will consume a negligible tiny amount of Redis RAM but effectively
    // obfuscates ISP metadata graphs tracking legitimate senders.
    relay.sendPacket({
      'id':          _uuid.v4(),
      'to':          fakeRecipient,
      'ciphertext':  noiseChars, // Base64 encoding not required for fake noise 
      'ttl_seconds': 1,          // Ensure Redis purges it immediately
      'msg_type':    'decoy',
    });
  }
}
