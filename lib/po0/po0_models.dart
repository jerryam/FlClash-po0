const po0TokenPrefix = 'pgnfw_';

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

class Po0TokenEntry {
  const Po0TokenEntry({
    required this.token,
    this.name = '',
    this.enabled = true,
  });

  final String token;
  final String name;

  /// Off skips this token and keeps it in the list.
  final bool enabled;

  String get label => name.isNotEmpty ? name : maskPo0Token(token);

  Po0TokenEntry copyWith({String? name, bool? enabled}) => Po0TokenEntry(
    token: token,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => {
    'token': token,
    'name': name,
    'enabled': enabled,
  };

  static Po0TokenEntry? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final token = json['token'];
    if (token is! String || parsePo0Token(token) != token) {
      return null;
    }
    final name = json['name'];
    return Po0TokenEntry(
      token: token,
      name: name is String ? name : '',
      enabled: json['enabled'] != false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Po0TokenEntry &&
      other.token == token &&
      other.name == name &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(token, name, enabled);
}

/// One token per line, its note after it, as [parsePo0TokenLines] reads.
String formatPo0TokenLines(List<Po0TokenEntry> entries) => [
  for (final entry in entries)
    entry.name.isEmpty ? entry.token : '${entry.token} ${entry.name}',
].join('\n');

/// The tokens in pasted text, each with the rest of its line as its note.
List<Po0TokenEntry> parsePo0TokenLines(String text) {
  final seen = <String>{};
  return [
    for (final line in text.split(RegExp(r'\r?\n')))
      if (_po0TokenInText.firstMatch(line) case final match?
          when seen.add(match.group(0)!))
        Po0TokenEntry(
          token: match.group(0)!,
          name: line.replaceRange(match.start, match.end, ' ').trim(),
        ),
  ];
}

class Po0Settings {
  const Po0Settings({
    this.enabled = true,
    this.tokens = const [],
    this.interval = po0DefaultInterval,
  });

  /// The master switch: off sends nothing.
  final bool enabled;
  final List<Po0TokenEntry> tokens;

  /// Seconds between two checks, [po0MinInterval] to [po0MaxInterval].
  final int interval;

  List<Po0TokenEntry> get activeTokens => enabled
      ? [
          for (final entry in tokens)
            if (entry.enabled) entry,
        ]
      : const [];

  /// Whether there is anything to whitelist.
  bool get isActive => activeTokens.isNotEmpty;

  Po0Settings copyWith({
    bool? enabled,
    List<Po0TokenEntry>? tokens,
    int? interval,
  }) => Po0Settings(
    enabled: enabled ?? this.enabled,
    tokens: tokens ?? this.tokens,
    interval: interval ?? this.interval,
  );

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'tokens': [for (final entry in tokens) entry.toJson()],
    'interval': interval,
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
    return Po0Settings(
      enabled: json['enabled'] != false,
      tokens: tokens,
      interval: interval is num
          ? clampPo0Interval(interval.toInt())
          : po0DefaultInterval,
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

  /// Slots left on the whitelist, when the server says how many it has.
  int? get freeSlots {
    final limit = this.limit;
    return limit == null
        ? null
        : (limit - whitelist.length).clamp(0, limit).toInt();
  }

  /// No slot is left for an exit that is not listed yet.
  bool get isFull => type != Po0ResultType.applied && freeSlots == 0;

  static Po0Result? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final type = Po0ResultType.values.asNameMap()[json['type']];
    final time = json['time'];
    if (type == null || time is! num) {
      return null;
    }
    final whitelist = json['whitelist'];
    final limit = json['limit'];
    return Po0Result(
      type: type,
      time: DateTime.fromMillisecondsSinceEpoch(time.toInt()),
      currentIp: json['currentIp'] as String?,
      whitelist: whitelist is List ? [for (final ip in whitelist) '$ip'] : [],
      limit: limit is num ? limit.toInt() : null,
      message: json['message'] as String?,
    );
  }
}

class Po0Status {
  const Po0Status({this.results = const {}, this.lastRound, this.busy = false});

  /// The latest result of each token, by token.
  final Map<String, Po0Result> results;
  final DateTime? lastRound;

  /// A manual run is in progress.
  final bool busy;

  static Po0Status fromJson(Object? json) {
    if (json is! Map) {
      return const Po0Status();
    }
    final results = json['results'];
    final lastRound = json['lastRound'];
    return Po0Status(
      results: {
        if (results is Map)
          for (final MapEntry(:key, :value) in results.entries)
            if (key is String) key: ?Po0Result.fromJson(value),
      },
      lastRound: lastRound is num
          ? DateTime.fromMillisecondsSinceEpoch(lastRound.toInt())
          : null,
      busy: json['busy'] == true,
    );
  }
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

/// One line for a token's latest result.
String po0ResultText(Po0Result result) {
  final exit = result.currentIp == null || result.currentIp!.isEmpty
      ? ''
      : '（出口 ${po0C24Of(result.currentIp!)}）';
  final text = switch (result.type) {
    Po0ResultType.applied => '已加白$exit',
    Po0ResultType.notApplied => '未加白$exit',
    Po0ResultType.disabled => 'po0 端防火墙未开启',
    Po0ResultType.rejected => '被拒绝：${result.message ?? ''}',
    Po0ResultType.error => '失败：${result.message ?? ''}',
  };
  return switch (result.freeSlots) {
    0 when result.type == Po0ResultType.applied => '$text · 名额已用完',
    0 => '$text · 名额已满',
    1 => '$text · 只剩 1 个名额',
    _ => text,
  };
}
