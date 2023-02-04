// Copyright © Luka S (JaffaKetchup) under GPL-v3
// A full license can be found at .\LICENSE

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_background/flutter_background.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:permission_handler/permission_handler.dart';

/// Extends [DownloadManagement] (accessed through [StoreDirectory.download])
/// with the background downloading functionality on Android
extension FMTCBackgroundDownloadingModule on DownloadManagement {
  /// Download a specified [DownloadableRegion] in the background, and show a
  /// progress notification (by default)
  ///
  /// To check the number of tiles that need to be downloaded before using this
  /// function, use [check].
  ///
  /// Only available on Android devices, due to limitations with other operating
  /// systems. Background downloading is complicated: see the documentation
  /// website for more information.
  ///
  /// Calling this method will automatically request the necessary permissions.
  /// You may want to call [requestIgnoreBatteryOptimizations] beforehand, as
  /// this will allow you more control.
  ///
  /// Uses a foreground service internally, meaning the process should be stable
  /// unless the application is force stopped/fully closed. However, you should
  /// still read the Limitations page, available in the online documentation.
  ///
  /// Displays two notifications:
  /// * A service notification, informing the user that the process is running.
  /// This is unavoidable due to the system limitations, however it can be easily
  /// hidden by the user. The default text explains this process roughly.
  /// * A progress notification, informing the user of the current state of the
  /// download. Includes a progress bar and time estimate by default.
  ///
  /// Configure the progress notification using:
  /// * `showProgressNotification`: set to `false` to disable the progress
  /// notification - not recommended
  /// * `progressNotificationIcon`: set to a string in the format
  /// '@\<type\>/\<name\>' (found in the 'android\app\src\main\res') to override
  /// the default icon ('@mipmap/ic_notification_icon': only available in the
  /// example application)
  /// * `progressNotificationTitle`: set to a `String` to override the default
  /// title
  /// * `progressNotificationText`: set to a `String` to override the default
  /// body text
  /// * `progressNotificationConfig`: use to further customise the notification
  /// properties
  ///
  /// Configure the background notification using:
  /// * `backgroundNotificationIcon`: set to an `AndroidResource` to override the
  /// default icon ('@mipmap/ic_launcher': the app's launcher icon)
  /// * `backgroundNotificationTitle`: set to a `String` to override the default
  /// title
  /// * `backgroundNotificationText`: set to a `String` to override the default
  /// body text
  Future<void> startBackground({
    required DownloadableRegion region,
    FMTCTileProviderSettings? tileProviderSettings,
    bool disableRecovery = false,
    String backgroundNotificationTitle = 'App Running In Background',
    String backgroundNotificationText =
        "Hide this notification by holding down and opening the notification's settings. Then disable this notification only.",
    AndroidResource? backgroundNotificationIcon,
    bool showProgressNotification = true,
    AndroidNotificationDetails? progressNotificationConfig,
    String progressNotificationIcon = '@mipmap/ic_notification_icon',
    String progressNotificationTitle = 'Downloading Map...',
    String Function(DownloadProgress)? progressNotificationBody,
  }) async {
    if (Platform.isAndroid) {
      final bool initSuccess = await FlutterBackground.initialize(
        androidConfig: FlutterBackgroundAndroidConfig(
          notificationTitle: backgroundNotificationTitle,
          notificationText: backgroundNotificationText,
          notificationIcon: backgroundNotificationIcon ??
              const AndroidResource(name: 'ic_launcher', defType: 'mipmap'),
        ),
      );
      if (!initSuccess) {
        throw StateError(
          'Failed to acquire the necessary permissions to run the background process',
        );
      }

      final bool startSuccess =
          await FlutterBackground.enableBackgroundExecution();
      if (!startSuccess) {
        throw StateError('Failed to start the background process');
      }

      final notification = FlutterLocalNotificationsPlugin();
      await notification.initialize(
        InitializationSettings(
          android: AndroidInitializationSettings(progressNotificationIcon),
        ),
      );
      await notification
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()!
          .requestPermission();

      final Stream<DownloadProgress> downloadStream = startForeground(
        region: region,
        tileProviderSettings: tileProviderSettings,
        disableRecovery: disableRecovery,
      ).asBroadcastStream();

      final AndroidNotificationDetails androidNotificationDetails =
          progressNotificationConfig?.copyWith(
                channelId: 'FMTCMapDownloader',
                ongoing: true,
              ) ??
              const AndroidNotificationDetails(
                'FMTCMapDownloader',
                'Map Download Progress',
                channelDescription:
                    'Displays progress notifications to inform the user about the progress of their map download',
                showProgress: true,
                visibility: NotificationVisibility.public,
                subText: 'Map Downloader',
                importance: Importance.low,
                priority: Priority.low,
                showWhen: false,
                playSound: false,
                enableVibration: false,
                onlyAlertOnce: true,
                autoCancel: false,
                ongoing: true,
              );

      late final StreamSubscription<DownloadProgress> subscription;

      subscription = downloadStream.listen(
        (event) async {
          if (showProgressNotification) {
            await notification.show(
              0,
              progressNotificationTitle,
              progressNotificationBody == null
                  ? '${event.attemptedTiles}/${event.maxTiles} (${event.percentageProgress.round()}%)'
                  : progressNotificationBody(event),
              NotificationDetails(
                android: androidNotificationDetails.copyWith(
                  maxProgress: event.maxTiles,
                  progress: event.attemptedTiles,
                ),
              ),
            );
          }
        },
        onDone: () async {
          if (showProgressNotification) await notification.cancel(0);
          await subscription.cancel();

          await cancel();
          if (FlutterBackground.isBackgroundExecutionEnabled) {
            await FlutterBackground.disableBackgroundExecution();
          }
        },
      );
    } else {
      throw PlatformException(
        code: 'notAndroid',
        message:
            'The background download feature is only available on Android due to internal limitations.',
      );
    }
  }

  /// Requests for app to be excluded from battery optimizations to aid running
  /// a background process
  ///
  /// Only available on Android devices, due to limitations with other operating
  /// systems.
  ///
  /// Background downloading is complicated: see the documentation website for
  /// more information.
  ///
  /// If [requestIfDenied] is `true` (default), and the permission has not been
  /// granted, an intrusive system dialog/screen will be displayed. If `false`,
  /// this method will only check whether it has been granted or not.
  ///
  /// Will return `true` if permission was granted, `false` if the permission was
  /// denied.
  Future<bool> requestIgnoreBatteryOptimizations({
    bool requestIfDenied = true,
  }) async {
    if (Platform.isAndroid) {
      final PermissionStatus status =
          await Permission.ignoreBatteryOptimizations.status;

      if ((status.isDenied || status.isLimited) && requestIfDenied) {
        final PermissionStatus statusAfter =
            await Permission.ignoreBatteryOptimizations.request();
        if (statusAfter.isGranted) return true;
        return false;
      } else if (status.isGranted) {
        return true;
      } else {
        return false;
      }
    } else {
      throw PlatformException(
        code: 'notAndroid',
        message:
            'The background download feature is only available on Android due to internal limitations.',
      );
    }
  }
}

extension on AndroidNotificationDetails {
  AndroidNotificationDetails copyWith({
    String? icon,
    String? channelId,
    String? channelName,
    String? channelDescription,
    bool? channelShowBadge,
    Importance? importance,
    Priority? priority,
    bool? playSound,
    AndroidNotificationSound? sound,
    bool? enableVibration,
    bool? enableLights,
    Int64List? vibrationPattern,
    StyleInformation? styleInformation,
    String? groupKey,
    bool? setAsGroupSummary,
    GroupAlertBehavior? groupAlertBehavior,
    bool? autoCancel,
    bool? ongoing,
    Color? color,
    AndroidBitmap<Object>? largeIcon,
    bool? onlyAlertOnce,
    bool? showWhen,
    int? when,
    bool? usesChronometer,
    bool? showProgress,
    int? maxProgress,
    int? progress,
    bool? indeterminate,
    Color? ledColor,
    int? ledOnMs,
    int? ledOffMs,
    String? ticker,
    AndroidNotificationChannelAction? channelAction,
    NotificationVisibility? visibility,
    int? timeoutAfter,
    AndroidNotificationCategory? category,
    bool? fullScreenIntent,
    String? shortcutId,
    Int32List? additionalFlags,
    String? subText,
    String? tag,
    bool? colorized,
    int? number,
  }) =>
      AndroidNotificationDetails(
        channelId ?? this.channelId,
        channelName ?? this.channelName,
        channelDescription: channelDescription ?? this.channelDescription,
        icon: icon ?? this.icon,
        channelShowBadge: channelShowBadge ?? this.channelShowBadge,
        importance: importance ?? this.importance,
        priority: priority ?? this.priority,
        playSound: playSound ?? this.playSound,
        sound: sound ?? this.sound,
        enableVibration: enableVibration ?? this.enableVibration,
        enableLights: enableLights ?? this.enableLights,
        vibrationPattern: vibrationPattern ?? this.vibrationPattern,
        styleInformation: styleInformation ?? this.styleInformation,
        groupKey: groupKey ?? this.groupKey,
        setAsGroupSummary: setAsGroupSummary ?? this.setAsGroupSummary,
        groupAlertBehavior: groupAlertBehavior ?? this.groupAlertBehavior,
        autoCancel: autoCancel ?? this.autoCancel,
        ongoing: ongoing ?? this.ongoing,
        color: color ?? this.color,
        largeIcon: largeIcon ?? this.largeIcon,
        onlyAlertOnce: onlyAlertOnce ?? this.onlyAlertOnce,
        showWhen: showWhen ?? this.showWhen,
        when: when ?? this.when,
        usesChronometer: usesChronometer ?? this.usesChronometer,
        showProgress: showProgress ?? this.showProgress,
        maxProgress: maxProgress ?? this.maxProgress,
        progress: progress ?? this.progress,
        indeterminate: indeterminate ?? this.indeterminate,
        ledColor: ledColor ?? this.ledColor,
        ledOnMs: ledOnMs ?? this.ledOnMs,
        ledOffMs: ledOffMs ?? this.ledOffMs,
        ticker: ticker ?? this.ticker,
        channelAction: channelAction ?? this.channelAction,
        visibility: visibility ?? this.visibility,
        timeoutAfter: timeoutAfter ?? this.timeoutAfter,
        category: category ?? this.category,
        fullScreenIntent: fullScreenIntent ?? this.fullScreenIntent,
        shortcutId: shortcutId ?? this.shortcutId,
        additionalFlags: additionalFlags ?? this.additionalFlags,
        subText: subText ?? this.subText,
        tag: tag ?? this.tag,
        colorized: colorized ?? this.colorized,
        number: number ?? this.number,
      );
}
