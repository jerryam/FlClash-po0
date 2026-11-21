import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'po0_client.dart';
import 'po0_models.dart';
import 'po0_screen.dart';

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

/// Keeps the current exit's /24 on every po0 token's whitelist while the app
/// runs and the screen is on.
///
/// Each round reads the whitelist (read-only, it takes no slot) and adds the
/// exit only when it is missing. A request leaves on the physical network:
/// directly while the core is stopped, and through the core's DIRECT-only
/// listener while it runs, so neither the mode, the rules nor the VPN can
/// send it through a proxy node.
class Po0Firewall {
  Po0Firewall._();

  static const _preferencesKey = 'po0Firewall';
  static const _maxBackoff = Duration(seconds: 30);
  static const _reapplyGap = Duration(seconds: 20);

  ProviderContainer? _container;
  late final _client = Po0Client(_route);
  Timer? _timer;
  StreamSubscription<Object?>? _networkSubscription;
  StreamSubscription<bool>? _screenSubscription;
  Future<void> _updates = Future.value();
  Future<void>? _loading;
  var _settings = const Po0Settings();
  var _loaded = false;
  var _screenOn = true;
  var _running = false;
  var _rerun = false;
  var _failures = 0;
  var _routeFailures = 0;
  DateTime? _lastReapply;

  Po0Settings get settings => _settings;

  /// Reads the saved settings. main awaits it before the first profile apply,
  /// so that apply already carries the DIRECT listener.
  Future<void> load() => _loading ??= _readSettings();

  void attach(ProviderContainer container) {
    if (!system.isAndroid || _container != null) {
      return;
    }
    _container = container;
    container.read(po0SettingsProvider.notifier).replace(_settings);
    container.listen<bool>(initProvider, (_, _) => _kick());
    container.listen<bool>(isStartProvider, (_, _) {
      _client.reset();
      _routeFailures = 0;
      _kick(delay: const Duration(seconds: 2));
    });
    container.listen<bool>(suspendProvider, (_, _) {
      _client.reset();
      _kick(delay: const Duration(seconds: 1));
    });
    container.listen<bool>(appVisibleProvider, (previous, next) {
      if (next && previous == false) {
        _kick();
      }
    });
    container.listen<Po0Settings>(po0SettingsProvider, _onSettingsChanged);
    unawaited(_networkSubscription?.cancel());
    _networkSubscription = app?.networkChanges.listen((_) {
      _client.reset();
      _failures = 0;
      _kick(delay: const Duration(seconds: 1));
    });
    unawaited(_screenSubscription?.cancel());
    _screenSubscription = po0ScreenStates().listen(
      _onScreen,
      onError: (Object _) {},
    );
    unawaited(
      load().then((_) {
        container.read(po0SettingsProvider.notifier).replace(_settings);
        _kick();
      }),
    );
  }

  /// Adds this session's DIRECT listener to a profile about to be applied.
  Map<String, dynamic> patchRawConfig(Map<String, dynamic> rawConfig) {
    final current = settings;
    if (!current.wantsListener) {
      return rawConfig;
    }
    final listeners = rawConfig['listeners'];
    return {
      ...rawConfig,
      'listeners': [
        if (listeners is List)
          for (final listener in listeners)
            if (listener is! Map || listener['name'] != po0ListenerName)
              listener,
        {
          'name': po0ListenerName,
          'type': 'http',
          'listen': '127.0.0.1',
          'port': current.port,
          'users': [
            {'username': current.username, 'password': current.password},
          ],
          'proxy': 'DIRECT',
        },
      ],
    };
  }

  /// Changes the settings one at a time, as a new listener port is found
  /// asynchronously.
  Future<void> update(Po0Settings Function(Po0Settings current) change) {
    return _updates = _updates.then((_) => _apply(change));
  }

  Future<void> _apply(Po0Settings Function(Po0Settings current) change) async {
    final container = _container;
    if (container == null) {
      return;
    }
    try {
      var updated = change(_settings);
      if (updated.isActive && !updated.hasListener) {
        updated = await _withListener(updated);
      }
      _settings = updated;
      container.read(po0SettingsProvider.notifier).replace(updated);
      await _save(updated);
    } catch (error) {
      _log('保存设置失败：$error', LogLevel.warning);
    }
  }

  /// One round now, for the page's button.
  Future<void> runNow() async {
    if (_container == null || !settings.isActive) {
      return;
    }
    if (_running) {
      _rerun = true;
      return;
    }
    await _round(manual: true);
  }

  Future<void> _readSettings() async {
    if (!system.isAndroid) {
      return;
    }
    try {
      final preferences = await SharedPreferences.getInstance();
      final raw = preferences.getString(_preferencesKey);
      if (raw != null) {
        _settings = Po0Settings.fromJson(json.decode(raw));
      }
    } catch (error) {
      _log('读取设置失败：$error', LogLevel.warning);
    }
    _loaded = true;
  }

  Future<void> _save(Po0Settings value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_preferencesKey, json.encode(value.toJson()));
  }

  Future<Po0Settings> _withListener(Po0Settings value) async {
    var port = 0;
    try {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = socket.port;
      await socket.close();
    } catch (_) {
      port = 20000 + Random.secure().nextInt(30000);
    }
    return value.copyWith(
      port: port,
      username: generatePo0Secret(12),
      password: generatePo0Secret(24),
    );
  }

  void _onSettingsChanged(Po0Settings? previous, Po0Settings next) {
    if (!_loaded || previous == null) {
      return;
    }
    final listenerChanged =
        previous.wantsListener != next.wantsListener ||
        (next.wantsListener &&
            (previous.port != next.port ||
                previous.username != next.username ||
                previous.password != next.password));
    if (listenerChanged) {
      _reapply();
    }
    _pruneResults();
    final tokensChanged = !_sameTokens(previous.tokens, next.tokens);
    if (tokensChanged || previous.enabled != next.enabled) {
      _failures = 0;
      _routeFailures = 0;
      // A new listener reaches the core with the next apply.
      _kick(
        delay: listenerChanged ? const Duration(seconds: 2) : Duration.zero,
      );
    } else if (previous.interval != next.interval) {
      _schedule();
    }
  }

  bool _sameTokens(List<Po0TokenEntry> a, List<Po0TokenEntry> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i].token == b[i].token);

  void _onScreen(bool on) {
    if (_screenOn == on) {
      return;
    }
    _screenOn = on;
    if (on) {
      _client.reset();
      _kick();
    } else {
      _cancelTimer();
    }
  }

  bool get _shouldRun {
    final container = _container;
    return container != null &&
        _loaded &&
        _screenOn &&
        container.read(initProvider) &&
        settings.isActive;
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _kick({Duration delay = Duration.zero}) {
    _cancelTimer();
    if (!_shouldRun) {
      return;
    }
    if (_running) {
      _rerun = true;
      return;
    }
    _timer = Timer(delay, () => unawaited(_round()));
  }

  void _schedule() {
    _cancelTimer();
    if (!_shouldRun || _running) {
      return;
    }
    _timer = Timer(_nextDelay, () => unawaited(_round()));
  }

  /// The interval, or 2/4/8/16 times it after failures, at most 30 seconds
  /// unless the interval itself is longer.
  Duration get _nextDelay {
    final interval = Duration(seconds: settings.interval);
    if (_failures == 0 || interval >= _maxBackoff) {
      return interval;
    }
    final backoff = interval * (1 << min(_failures, 4));
    return backoff > _maxBackoff ? _maxBackoff : backoff;
  }

  String? _route() {
    final container = _container;
    if (container == null ||
        !container.read(isStartProvider) ||
        container.read(suspendProvider)) {
      return 'DIRECT';
    }
    final current = settings;
    if (!current.hasListener) {
      return null;
    }
    return 'PROXY ${current.username}:${current.password}'
        '@127.0.0.1:${current.port}';
  }

  void _reapply() {
    final container = _container;
    if (container == null || !container.read(isStartProvider)) {
      return;
    }
    _lastReapply = DateTime.now();
    container
        .read(setupActionProvider.notifier)
        .applyProfileDebounce(silence: true, force: true);
  }

  Future<void> _round({bool manual = false}) async {
    final container = _container;
    if (container == null || _running) {
      return;
    }
    if (!manual && !_shouldRun) {
      return;
    }
    final current = settings;
    if (!current.isActive) {
      return;
    }
    _cancelTimer();
    _running = true;
    final status = container.read(po0StatusProvider.notifier);
    if (manual) {
      status.replace(container.read(po0StatusProvider).copyWith(busy: true));
    }
    var failed = false;
    try {
      for (final entry in current.tokens) {
        final result = await _whitelist(entry);
        failed |= result.type == Po0ResultType.error;
        _put(entry, result);
      }
      _routeFailures = 0;
    } on Po0RouteUnavailable catch (error) {
      failed = true;
      _routeFailures++;
      for (final entry in current.tokens) {
        _put(
          entry,
          Po0Result(
            type: Po0ResultType.error,
            time: DateTime.now(),
            message: '$error',
          ),
        );
      }
      final lastReapply = _lastReapply;
      if (_routeFailures >= 2 &&
          (lastReapply == null ||
              DateTime.now().difference(lastReapply) > _reapplyGap)) {
        _log('直连入口不可用，重新应用配置', LogLevel.warning);
        _reapply();
      }
    } catch (error) {
      failed = true;
      _log('检查出错：$error', LogLevel.warning);
    } finally {
      _running = false;
      final latest = container.read(po0StatusProvider);
      status.replace(
        Po0Status(
          results: _currentResults(latest.results),
          lastRound: DateTime.now(),
        ),
      );
    }
    _failures = failed ? _failures + 1 : 0;
    if (_rerun) {
      _rerun = false;
      _kick();
    } else {
      _schedule();
    }
  }

  Future<Po0Result> _whitelist(Po0TokenEntry entry) async {
    final checked = await _client.check(entry.token);
    if (checked.type != Po0ResultType.notApplied) {
      return checked;
    }
    final added = await _client.add(entry.token);
    if (added.type == Po0ResultType.applied) {
      _log('${entry.label}：已加白 ${po0C24Of(added.currentIp ?? '')}');
    }
    return added;
  }

  void _put(Po0TokenEntry entry, Po0Result result) {
    final container = _container;
    if (container == null) {
      return;
    }
    final latest = container.read(po0StatusProvider);
    final previous = latest.results[entry.token];
    container
        .read(po0StatusProvider.notifier)
        .replace(
          latest.copyWith(results: {...latest.results, entry.token: result}),
        );
    if (previous?.type != result.type ||
        previous?.currentIp != result.currentIp) {
      _log(
        '${entry.label}：${po0ResultText(result)}',
        result.type == Po0ResultType.error ? LogLevel.warning : LogLevel.info,
      );
    }
  }

  Map<String, Po0Result> _currentResults(Map<String, Po0Result> results) {
    final tokens = {for (final entry in settings.tokens) entry.token};
    return {
      for (final MapEntry(:key, :value) in results.entries)
        if (tokens.contains(key)) key: value,
    };
  }

  void _pruneResults() {
    final container = _container;
    if (container == null) {
      return;
    }
    final latest = container.read(po0StatusProvider);
    final results = _currentResults(latest.results);
    if (results.length != latest.results.length) {
      container
          .read(po0StatusProvider.notifier)
          .replace(latest.copyWith(results: results));
    }
  }

  void _log(String message, [LogLevel level = LogLevel.info]) {
    commonPrint.log('[po0] $message', logLevel: level);
  }
}

/// One line for a token's latest result.
String po0ResultText(Po0Result result) {
  final exit = result.currentIp == null || result.currentIp!.isEmpty
      ? ''
      : '（出口 ${po0C24Of(result.currentIp!)}）';
  return switch (result.type) {
    Po0ResultType.applied => '已加白$exit',
    Po0ResultType.notApplied => '未加白$exit',
    Po0ResultType.disabled => 'po0 端防火墙未开启',
    Po0ResultType.rejected => '被拒绝：${result.message ?? ''}',
    Po0ResultType.error => '失败：${result.message ?? ''}',
  };
}
