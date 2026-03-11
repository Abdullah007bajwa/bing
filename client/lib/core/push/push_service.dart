// lib/core/push/push_service.dart
// Handles opaque encrypted push notifications.
// Unlike standard apps, Ghost pushes NEVER contain message content or sender info.
// They are simply "wake up" signals. The OS wakes the app, and the app
// connects to the WSS relay to securely fetch its pending packets.

import 'dart:developer';
import 'package:flutter/foundation.dart';
import '../../relay/websocket_client.dart';
import '../../app_config.dart';
import '../identity/identity_service.dart';

class PushService {
  static final PushService _instance = PushService._internal();
  factory PushService() => _instance;
  PushService._internal();

  /// Represents an APNS/FCM device token
  String? _deviceToken;

  /// Call this when the app starts to register for push notifications.
  /// (Implementation requires Firebase/APNS setup in OS developer portals)
  Future<void> initialize() async {
    if (kIsWeb) return;
    
    // In a production environment:
    // 1. Request permissions from OS
    // 2. Fetch APNS/FCM token
    // 3. Send securely to a push-distributor server (NOT the relay)
    
    _deviceToken = "mock_device_token_awaiting_apns";
    log('PushService initialized. App will wake silently on encrypted pushes.');
  }

  /// Called by the OS push handler when a background data message arrives.
  /// Payload must be purely opaque, e.g., {"type": "ghost_wakeup"}
  Future<void> handleBackgroundMessage(Map<String, dynamic> data) async {
    if (data['type'] != 'ghost_wakeup') {
      log('Ignored non-wakeup push payload');
      return;
    }

    log('Received encrypted wakeup push. Connecting to relay to fetch data...');
    
    // Wake up the WebSocket client to pull down Redis offline messages
    // The websocket client handles decryption and saving to SQLCipher
    final wsClient = GhostRelayClient();
    final userId = await IdentityService().getUserId();

    // Wait for it to connect, drain the offline queue, and disconnect
    // (In background execution, OS usually gives ~30 seconds for this)
    await wsClient.connect(
      relayUrl: AppConfig.relayWssUrl,
      userId: userId,
    );

    // Wait a brief moment to allow queue draining before OS kills background process
    await Future.delayed(const Duration(seconds: 15));
    wsClient.disconnect();
    
    log('Wakeup cycle complete. Offline messages synced to secure local DB.');
  }
}
