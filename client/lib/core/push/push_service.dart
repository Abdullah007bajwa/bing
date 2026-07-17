import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../app_config.dart';
import '../identity/identity_service.dart';

const AndroidNotificationChannel _kGhostNotificationsChannel =
    AndroidNotificationChannel(
  'vexa_messages',
  'Vexa Messages',
  description: 'Encrypted message notifications',
  importance: Importance.high,
  playSound: true,
  enableVibration: true,
  showBadge: true,
);

final FlutterLocalNotificationsPlugin _kLocalNotifications =
    FlutterLocalNotificationsPlugin();

final StreamController<String> _tapSenderController =
    StreamController<String>.broadcast();

@pragma('vm:entry-point')
Future<void> ghostFirebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

class PushService {
  static final PushService _instance = PushService._internal();
  factory PushService() => _instance;
  PushService._internal();

  String? _deviceToken;
  bool _localNotificationsReady = false;
  String? get deviceToken => _deviceToken;
  Stream<String> get tappedSenderIds => _tapSenderController.stream;

  /// Call even when Firebase is unavailable (e.g. Play Services [SERVICE_NOT_AVAILABLE]).
  Future<void> initialize() async {
    if (kIsWeb) return;

    // Always set up local notifications + Android 13+ permission first.
    // Previously Firebase ran first and threw, so nothing below ran.
    await _initLocalNotifications();
    await _requestAndroidPostNotificationsPermission();

    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(ghostFirebaseMessagingBackgroundHandler);
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        announcement: false,
        criticalAlert: false,
        provisional: false,
        carPlay: false,
      );
      await _refreshAndRegisterToken();
      FirebaseMessaging.instance.onTokenRefresh.listen((token) {
        _deviceToken = token;
        unawaited(_registerTokenWithRelay(token));
      });
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_onMessageOpened);
      final initial = await FirebaseMessaging.instance.getInitialMessage();
      if (initial != null) _onMessageOpened(initial);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[Push] Firebase/FCM unavailable (offline push disabled): $e');
      }
    }
  }

  /// Message arrived on the WebSocket while user is not in that chat — show system tray + badge.
  Future<void> showIncomingFromRelay({
    required String senderUserId,
    required bool viewingThisChat,
  }) async {
    if (kIsWeb || !_localNotificationsReady) return;
    if (viewingThisChat) return;
    final s = senderUserId.trim();
    if (s.isEmpty) return;

    final title = s.length <= 18 ? s : '${s.substring(0, 14)}…';
    const body = 'New message';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _kGhostNotificationsChannel.id,
        _kGhostNotificationsChannel.name,
        channelDescription: _kGhostNotificationsChannel.description,
        importance: Importance.high,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.public,
        ticker: 'Vexa message',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    final notificationId = s.hashCode & 0x7FFFFFFF;
    await _kLocalNotifications.show(
      notificationId,
      title,
      body,
      details,
      payload: s,
    );
  }

  Future<void> _initLocalNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    const settings = InitializationSettings(android: android, iOS: ios);
    await _kLocalNotifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (resp) {
        final sender = resp.payload;
        if (sender != null && sender.isNotEmpty) {
          _tapSenderController.add(sender);
        }
      },
    );
    await _kLocalNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_kGhostNotificationsChannel);
    _localNotificationsReady = true;
  }

  Future<void> _requestAndroidPostNotificationsPermission() async {
    await _kLocalNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  Future<void> _refreshAndRegisterToken() async {
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) return;
    _deviceToken = token;
    await _registerTokenWithRelay(token);
  }

  Future<void> _registerTokenWithRelay(String token) async {
    final userId = await IdentityService().getUserId();
    if (userId.isEmpty) return;
    final uri = Uri.parse('${AppConfig.relayApiUrl}/register_device');
    try {
      await http.post(
        uri,
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'user_id': userId,
          'fcm_token': token,
          'platform': defaultTargetPlatform.name,
        }),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[Push] register token failed: $e');
    }
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final sender = _extractSenderId(message);
    final title = message.notification?.title ??
        _shortSender(sender) ??
        'Vexa';
    const body = 'New message';
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _kGhostNotificationsChannel.id,
        _kGhostNotificationsChannel.name,
        channelDescription: _kGhostNotificationsChannel.description,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        visibility: NotificationVisibility.public,
        ticker: 'Vexa message',
      ),
      iOS: const DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    await _kLocalNotifications.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
      payload: sender,
    );
  }

  void _onMessageOpened(RemoteMessage message) {
    final sender = _extractSenderId(message);
    if (sender != null && sender.isNotEmpty) {
      _tapSenderController.add(sender);
    }
  }

  String? _extractSenderId(RemoteMessage message) {
    final fromData = message.data['sender_id']?.toString().trim();
    if (fromData != null && fromData.isNotEmpty) return fromData;
    final fromNotif = message.notification?.title?.trim();
    if (fromNotif != null && fromNotif.isNotEmpty) return fromNotif;
    return null;
  }

  String? _shortSender(String? sender) {
    if (sender == null || sender.isEmpty) return null;
    return sender.length <= 12 ? sender : sender.substring(0, 12);
  }
}
