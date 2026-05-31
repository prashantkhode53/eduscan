import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';
import 'parent_api_service.dart';
import 'storage_service.dart';

/// Top-level handler — required by firebase_messaging for background messages.
/// Must be a top-level function (not a class method).
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // Firebase is already initialised by the time this is called.
  // Just log — the OS shows the notification automatically for data-only messages
  // that have a `notification` payload.
  debugPrint('[FCM] Background message: ${message.messageId}');
}

class FcmService {
  FcmService._();

  static final _localNotifications = FlutterLocalNotificationsPlugin();
  static const _channelId   = 'eduscan_alerts';
  static const _channelName = 'EduScan Alerts';
  static const _channelDesc = 'Attendance check-in/out alerts for parents';

  /// Call once from main() after Firebase.initializeApp().
  static Future<void> initialize(GlobalKey<NavigatorState> navigatorKey) async {
    // Background handler must be registered before calling any other FCM method
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Android notification channel (required for Android 8+)
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(
          const AndroidNotificationChannel(
            _channelId,
            _channelName,
            description: _channelDesc,
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ),
        );

    // Initialise flutter_local_notifications
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios     = DarwinInitializationSettings(
      requestAlertPermission:  true,
      requestBadgePermission:  true,
      requestSoundPermission:  true,
    );
    await _localNotifications.initialize(
      const InitializationSettings(android: android, iOS: ios),
      onDidReceiveNotificationResponse: (details) {
        _handleNotificationTap(details.payload, navigatorKey);
      },
    );

    // Request permission (Android 13+, iOS)
    await FirebaseMessaging.instance.requestPermission(
      alert:         true,
      announcement:  false,
      badge:         true,
      carPlay:       false,
      criticalAlert: false,
      provisional:   false,
      sound:         true,
    );

    // Foreground messages — show via flutter_local_notifications
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final n = message.notification;
      if (n != null) {
        _showLocalNotification(
          id:      message.hashCode,
          title:   n.title ?? '',
          body:    n.body  ?? '',
          payload: message.data['type'],
        );
      }
    });

    // User taps notification when app is in background (but not terminated)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      _handleNotificationTap(message.data['type'], navigatorKey);
    });

    // App opened from terminated state via notification
    final initial = await FirebaseMessaging.instance.getInitialMessage();
    if (initial != null) {
      _handleNotificationTap(initial.data['type'], navigatorKey);
    }

    // Save token whenever it refreshes
    FirebaseMessaging.instance.onTokenRefresh.listen(_uploadToken);
  }

  /// Call after parent login succeeds to register this device.
  static Future<void> uploadTokenIfParent() async {
    final token = await StorageService.getParentToken();
    if (token == null) return; // not logged in as parent
    final fcmToken = await FirebaseMessaging.instance.getToken();
    if (fcmToken == null) return;
    try {
      await ParentApiService.saveFcmToken(fcmToken);
      debugPrint('[FCM] token uploaded: ${fcmToken.substring(0, 20)}…');
    } catch (e) {
      debugPrint('[FCM] token upload failed: $e');
    }
  }

  static Future<void> _uploadToken(String fcmToken) async {
    final parentToken = await StorageService.getParentToken();
    if (parentToken == null) return;
    try {
      await ParentApiService.saveFcmToken(fcmToken);
    } catch (_) {}
  }

  static void _showLocalNotification({
    required int    id,
    required String title,
    required String body,
    String?         payload,
  }) {
    _localNotifications.show(
      id,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDesc,
          importance: Importance.max,
          priority:   Priority.high,
          icon:       '@mipmap/ic_launcher',
          playSound:  true,
          enableVibration: true,
        ),
        iOS: const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      ),
      payload: payload,
    );
  }

  static void _handleNotificationTap(
    String? type,
    GlobalKey<NavigatorState> navigatorKey,
  ) {
    if (type == 'attendance') {
      // Navigate to parent dashboard — it's already showing attendance
      final context = navigatorKey.currentContext;
      if (context != null) {
        Navigator.of(context)
            .pushNamedAndRemoveUntil('/parent/dashboard', (_) => false);
      }
    }
  }

  /// Delete FCM token on logout so no more notifications after sign-out.
  static Future<void> deleteToken() async {
    try {
      if (Platform.isAndroid || Platform.isIOS) {
        await FirebaseMessaging.instance.deleteToken();
      }
    } catch (_) {}
  }
}
