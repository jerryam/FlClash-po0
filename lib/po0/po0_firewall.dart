import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'po0_models.dart';

export 'po0_models.dart';

final po0SettingsProvider = NotifierProvider<Po0SettingsNotifier, Po0Settings>(
  Po0SettingsNotifier.new,
);

class Po0SettingsNotifier extends Notifier<Po0Settings> {
  @override
  Po0Settings build() => const Po0Settings();

  void replace(Po0Settings value) {
    state = value;
  }
}

final po0StatusProvider = NotifierProvider<Po0StatusNotifier, Po0Status>(
  Po0StatusNotifier.new,
);

class Po0StatusNotifier extends Notifier<Po0Status> {
  @override
  Po0Status build() => const Po0Status();

  void replace(Po0Status value) {
    state = value;
  }
}

final po0Firewall = Po0Firewall._();

/// The app's side of the po0 whitelist checks. They run in the Android
/// service (`Po0Firewall.kt`), which keeps them going after the app is swiped
/// away; this keeps the page's settings and status in step with it.
class Po0Firewall {
  Po0Firewall._();

  static const _methods = MethodChannel('$packageName/po0');
  static const _events = EventChannel('$packageName/po0_events');

  /// Where the settings lived while the checks ran in Dart.
  static const _legacyKey = 'po0Firewall';

  ProviderContainer? _container;
  Future<void> _updates = Future.value();
  bool _loaded = false;

  void attach(ProviderContainer container) {
    if (!system.isAndroid || _container != null) {
      return;
    }
    _container = container;
    _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) => _log('同步状态失败：$error', LogLevel.warning),
    );
    container.listen<bool>(appVisibleProvider, (previous, next) {
      if (next && previous == false) {
        unawaited(_invoke('kick'));
      }
    });
    _updates = _load();
  }

  /// Changes the settings one at a time, each saved by the service first.
  /// None is saved before the saved ones are read, or defaults replace them.
  Future<void> update(Po0Settings Function(Po0Settings current) change) {
    return _updates = _updates.then((_) async {
      final container = _container;
      if (container == null) {
        return;
      }
      if (!_loaded) {
        await _load();
      }
      if (!_loaded) {
        _log('没有读到已保存的设置，这次修改没有保存', LogLevel.warning);
        return;
      }
      try {
        _replace(await _save(change(container.read(po0SettingsProvider))));
      } catch (error) {
        _log('保存设置失败：$error', LogLevel.warning);
      }
    });
  }

  /// One round now, for the page's button.
  Future<void> runNow() => _invoke('runNow');

  Future<void> _load() async {
    final Po0Settings settings;
    try {
      final raw = await _methods.invokeMethod<String>('getSettings');
      settings = Po0Settings.fromJson(json.decode(raw ?? '{}'));
    } catch (error) {
      _log('读取设置失败：$error', LogLevel.warning);
      return;
    }
    _replace(settings);
    _loaded = true;
    try {
      await _migrateLegacy(settings);
    } catch (error) {
      _log('迁移旧设置失败：$error', LogLevel.warning);
    }
  }

  /// A key that does not decode is dropped too, or it would fail every launch.
  Future<void> _migrateLegacy(Po0Settings current) async {
    final preferences = await SharedPreferences.getInstance();
    final legacy = preferences.getString(_legacyKey);
    if (legacy == null) {
      return;
    }
    if (current.tokens.isEmpty) {
      final decoded = _tryDecode(legacy);
      if (decoded != null) {
        _replace(await _save(Po0Settings.fromJson(decoded)));
      }
    }
    await preferences.remove(_legacyKey);
  }

  Object? _tryDecode(String text) {
    try {
      return json.decode(text);
    } on FormatException {
      return null;
    }
  }

  Future<Po0Settings> _save(Po0Settings settings) async {
    final saved = await _methods.invokeMethod<String>(
      'setSettings',
      json.encode(settings.toJson()),
    );
    return saved == null ? settings : Po0Settings.fromJson(json.decode(saved));
  }

  Future<void> _invoke(String method) async {
    if (_container == null) {
      return;
    }
    try {
      await _methods.invokeMethod<void>(method);
    } catch (error) {
      _log('$method 失败：$error', LogLevel.warning);
    }
  }

  void _replace(Po0Settings settings) {
    _container?.read(po0SettingsProvider.notifier).replace(settings);
  }

  void _onEvent(Object? event) {
    final data = event is String ? json.decode(event) : null;
    if (data is! Map) {
      return;
    }
    switch (data['type']) {
      case 'status':
        _container
            ?.read(po0StatusProvider.notifier)
            .replace(Po0Status.fromJson(data));
      case 'log':
        commonPrint.log(
          '${data['message']}',
          logLevel: data['level'] == 'warning'
              ? LogLevel.warning
              : LogLevel.info,
        );
    }
  }

  void _log(String message, LogLevel level) {
    commonPrint.log('[po0] $message', logLevel: level);
  }
}
