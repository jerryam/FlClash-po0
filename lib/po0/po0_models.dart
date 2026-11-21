import 'dart:math';

/// The po0 firewall API answers on this address only, and whitelists the /24
/// of whatever address the request arrives from.
const po0ApiHost = '124.221.69.228';

const po0TokenPrefix = 'pgnfw_';

/// The listener the core runs for po0 requests only; its `proxy: DIRECT`
/// wins over the mode, rules and TUN, so a request through it always leaves
/// on the physical network.
const po0ListenerName = 'po0-direct';

const po0MinInterval = 1;
const po0MaxInterval = 3600;
const po0DefaultInterval = 5;

final _po0TokenPattern = RegExp(r'^pgnfw_[^\s,|;@/?#&]+$');
final _po0TokenInText = RegExp(r'pgnfw_[^\s,|;@/?#&]+');

/// A bare token, or the first token inside a pasted po0 link.
String? parsePo0Token(String input) {
  final text = input.trim();
  if (_po0TokenPattern.hasMatch(text)) {
    return text;
  }
  return _po0TokenInText.firstMatch(text)?.group(0);
}

String maskPo0Token(String token) =>
    token.length <= 12 ? token : '${token.substring(0, 12)}…';

int clampPo0Interval(int value) =>
    value.clamp(po0MinInterval, po0MaxInterval).toInt();

String generatePo0Secret(int length) {
  const chars =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random.secure();
  return List.generate(
    length,
    (_) => chars[random.nextInt(chars.length)],
  ).join();
}

class Po0TokenEntry {
  const Po0TokenEntry({required this.token, this.name = ''});

  final String token;
  final String name;

  String get label => name.isNotEmpty ? name : maskPo0Token(token);

  Po0TokenEntry copyWith({String? token, String? name}) =>
      Po0TokenEntry(token: token ?? this.token, name: name ?? this.name);

  Map<String, Object?> toJson() => {'token': token, 'name': name};

  static Po0TokenEntry? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final token = json['token'];
    if (token is! String || parsePo0Token(token) != token) {
      return null;
    }
    final name = json['name'];
    return Po0TokenEntry(token: token, name: name is String ? name : '');
  }

  @override
  bool operator ==(Object other) =>
      other is Po0TokenEntry && other.token == token && other.name == name;

  @override
  int get hashCode => Object.hash(token, name);
}

class Po0Settings {
  const Po0Settings({
    this.enabled = true,
    this.tokens = const [],
    this.interval = po0DefaultInterval,
    this.port = 0,
    this.username = '',
    this.password = '',
  });

  /// The master switch: off sends nothing and keeps the listener out of the
  /// config.
  final bool enabled;
  final List<Po0TokenEntry> tokens;

  /// Seconds between two checks, [po0MinInterval] to [po0MaxInterval].
  final int interval;

  /// The DIRECT listener's port and credentials. They are kept across
  /// restarts because the Android service can run the last applied config
  /// before the app starts again.
  final int port;
  final String username;
  final String password;

  bool get hasListener =>
      port > 0 && username.isNotEmpty && password.isNotEmpty;

  /// Whether there is anything to whitelist.
  bool get isActive => enabled && tokens.isNotEmpty;

  /// Whether the config the core runs needs the DIRECT listener.
  bool get wantsListener => isActive && hasListener;

  Po0Settings copyWith({
    bool? enabled,
    List<Po0TokenEntry>? tokens,
    int? interval,
    int? port,
    String? username,
    String? password,
  }) => Po0Settings(
    enabled: enabled ?? this.enabled,
    tokens: tokens ?? this.tokens,
    interval: interval ?? this.interval,
    port: port ?? this.port,
    username: username ?? this.username,
    password: password ?? this.password,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'tokens': [for (final entry in tokens) entry.toJson()],
    'interval': interval,
    'port': port,
    'username': username,
    'password': password,
  };

  static Po0Settings fromJson(Object? json) {
    if (json is! Map) {
      return const Po0Settings();
    }
    final rawTokens = json['tokens'];
    final seen = <String>{};
    final tokens = <Po0TokenEntry>[
      if (rawTokens is List)
        for (final item in rawTokens)
          if (Po0TokenEntry.fromJson(item) case final entry?
              when seen.add(entry.token))
            entry,
    ];
    final interval = json['interval'];
    final port = json['port'];
    final username = json['username'];
    final password = json['password'];
    return Po0Settings(
      enabled: json['enabled'] != false,
      tokens: tokens,
      interval: interval is num
          ? clampPo0Interval(interval.toInt())
          : po0DefaultInterval,
      port: port is num && port > 0 && port < 65536 ? port.toInt() : 0,
      username: username is String ? username : '',
      password: password is String ? password : '',
    );
  }
}

enum Po0ResultType {
  /// The current exit's /24 is on the whitelist.
  applied,

  /// The current exit's /24 is not on the whitelist.
  notApplied,

  /// The machine's firewall is switched off on the po0 side.
  disabled,

  /// The API refused the token.
  rejected,

  /// The request failed.
  error,
}

class Po0Result {
  const Po0Result({
    required this.type,
    required this.time,
    this.currentIp,
    this.whitelist = const [],
    this.limit,
    this.message,
  });

  final Po0ResultType type;
  final DateTime time;
  final String? currentIp;
  final List<String> whitelist;
  final int? limit;
  final String? message;

  Po0Result copyWith({Po0ResultType? type, String? message}) => Po0Result(
    type: type ?? this.type,
    time: time,
    currentIp: currentIp,
    whitelist: whitelist,
    limit: limit,
    message: message ?? this.message,
  );
}

class Po0Status {
  const Po0Status({this.results = const {}, this.lastRound, this.busy = false});

  /// The latest result of each token, by token.
  final Map<String, Po0Result> results;
  final DateTime? lastRound;

  /// A manual run is in progress.
  final bool busy;

  Po0Status copyWith({
    Map<String, Po0Result>? results,
    DateTime? lastRound,
    bool? busy,
  }) => Po0Status(
    results: results ?? this.results,
    lastRound: lastRound ?? this.lastRound,
    busy: busy ?? this.busy,
  );
}

/// The server whitelists whole /24s and lists entries as IPs or `x.x.x.0/24`.
bool samePo0C24(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) {
    return false;
  }
  if (a == b) {
    return true;
  }
  final pa = a.replaceAll('/24', '').split('.');
  final pb = b.replaceAll('/24', '').split('.');
  return pa.length == 4 &&
      pb.length == 4 &&
      pa[0] == pb[0] &&
      pa[1] == pb[1] &&
      pa[2] == pb[2];
}

/// `1.2.3.4` → `1.2.3.0/24`.
String po0C24Of(String ip) {
  final parts = ip.replaceAll('/24', '').split('.');
  if (parts.length != 4) {
    return ip;
  }
  return '${parts[0]}.${parts[1]}.${parts[2]}.0/24';
}
