import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'po0_firewall.dart';

String _summaryOf(Po0Settings settings, Po0Status status) {
  if (settings.tokens.isEmpty) {
    return '未添加 token';
  }
  if (!settings.enabled) {
    return '自动加白已关闭';
  }
  final active = settings.activeTokens;
  if (active.isEmpty) {
    return '所有 token 都已停用';
  }
  final results = [for (final entry in active) status.results[entry.token]];
  if (results.every((result) => result == null)) {
    return '等待检查';
  }
  final applied = results
      .where((result) => result?.type == Po0ResultType.applied)
      .length;
  final summary = applied == results.length
      ? '已加白'
      : '$applied/${results.length} 已加白';
  return results.any((result) => result?.isFull ?? false)
      ? '$summary · 有 token 名额已满'
      : summary;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _timeOf(DateTime time) =>
    '${_twoDigits(time.hour)}:${_twoDigits(time.minute)}:'
    '${_twoDigits(time.second)}';

String _detailOf(Po0Settings settings, Po0Status status) {
  final exits = <String>{
    for (final entry in settings.activeTokens)
      if (status.results[entry.token]?.currentIp case final ip?
          when ip.isNotEmpty)
        po0C24Of(ip),
  };
  final lastRound = status.lastRound;
  return [
    if (exits.isNotEmpty) '出口网段 ${exits.join('、')}',
    if (lastRound != null) '上次检查 ${_timeOf(lastRound)}',
    if (exits.isEmpty && lastRound == null) '每 ${settings.interval} 秒检查一次',
  ].join(' · ');
}

String _tokenLine(Po0TokenEntry entry, Po0Result? result) {
  final state = !entry.enabled
      ? '已停用'
      : result == null
      ? '等待检查'
      : po0ResultText(result);
  return entry.name.isEmpty ? state : '${maskPo0Token(entry.token)} · $state';
}

Future<String?> _showTokenDialog(List<Po0TokenEntry> entries) async {
  final value = await dialogs.showCommonDialog<String>(
    child: InputDialog(
      title: '添加 po0 token',
      value: '',
      labelText: 'pgnfw_ 开头的 token，或包含它的链接',
      inputFormatters: [
        FilteringTextInputFormatter.singleLineFormatter,
        LengthLimitingTextInputFormatter(512),
      ],
      validator: (value) {
        final token = parsePo0Token(value ?? '');
        if (token == null) {
          return '没有找到 pgnfw_ 开头的 token';
        }
        if (entries.any((entry) => entry.token == token)) {
          return '这个 token 已经添加过了';
        }
        return null;
      },
    ),
  );
  return value == null ? null : parsePo0Token(value);
}

Future<String?> _showNameDialog(String name) async {
  final value = await dialogs.showCommonDialog<String>(
    child: InputDialog(
      title: '备注',
      value: name,
      labelText: '备注（可留空，方便区分机器）',
      inputFormatters: [
        FilteringTextInputFormatter.singleLineFormatter,
        LengthLimitingTextInputFormatter(64),
      ],
    ),
  );
  return value?.trim();
}

Future<void> _addTokens(List<Po0TokenEntry> added) {
  return po0Firewall.update((settings) {
    final known = {for (final entry in settings.tokens) entry.token};
    return settings.copyWith(
      tokens: [
        ...settings.tokens,
        for (final entry in added)
          if (known.add(entry.token)) entry,
      ],
    );
  });
}

Future<void> _replaceToken(
  String token,
  Po0TokenEntry? Function(Po0TokenEntry) change,
) {
  return po0Firewall.update(
    (settings) => settings.copyWith(
      tokens: [
        for (final entry in settings.tokens)
          if (entry.token != token)
            entry
          else if (change(entry) case final changed?)
            changed,
      ],
    ),
  );
}

Future<void> _addToken(List<Po0TokenEntry> entries) async {
  final token = await _showTokenDialog(entries);
  if (token == null) {
    return;
  }
  final name = await _showNameDialog('');
  await _addTokens([Po0TokenEntry(token: token, name: name ?? '')]);
}

Future<void> _rename(Po0TokenEntry entry) async {
  final name = await _showNameDialog(entry.name);
  if (name == null || name == entry.name) {
    return;
  }
  await _replaceToken(entry.token, (item) => item.copyWith(name: name));
}

Future<void> _delete(Po0TokenEntry entry) async {
  final confirmed = await dialogs.showMessage(
    title: '删除 token',
    message: TextSpan(text: '删除「${entry.label}」后不再为它自动加白。'),
    destructive: true,
    confirmText: '删除',
  );
  if (confirmed != true) {
    return;
  }
  await _replaceToken(entry.token, (_) => null);
}

Future<void> _importTokens(List<Po0TokenEntry> entries) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final found = parsePo0TokenLines(data?.text ?? '');
  final known = {for (final entry in entries) entry.token};
  final added = [
    for (final entry in found)
      if (!known.contains(entry.token)) entry,
  ];
  if (added.isNotEmpty) {
    await _addTokens(added);
  }
  await dialogs.showAlert(
    title: '从剪贴板导入',
    message: TextSpan(
      text: found.isEmpty
          ? '剪贴板里没有 pgnfw_ 开头的 token。'
          : '导入了 ${added.length} 个 token'
                '${found.length > added.length ? '，${found.length - added.length} 个已经有了' : ''}。',
    ),
  );
}

Future<void> _exportTokens(List<Po0TokenEntry> entries) async {
  await Clipboard.setData(ClipboardData(text: formatPo0TokenLines(entries)));
  await dialogs.showAlert(
    title: '复制全部 token',
    message: TextSpan(
      text:
          '已复制 ${entries.length} 个 token 和备注。'
          '找个安全的地方保存，换机或重装后用「从剪贴板导入」恢复。',
    ),
  );
}

/// The entry on the tools page.
class Po0ToolItem extends ConsumerWidget {
  const Po0ToolItem({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(po0SettingsProvider);
    final status = ref.watch(po0StatusProvider);
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.lock),
      title: const Text('po0 加白'),
      subtitle: Text(_summaryOf(settings, status)),
      widget: const Po0View(),
    );
  }
}

class Po0View extends ConsumerWidget {
  const Po0View({super.key});

  Widget _statusSection(Po0Settings settings, Po0Status status) {
    return generateSection(
      title: '状态',
      items: [
        ListItem(
          leading: const GlyphIcon(AppGlyphs.verified),
          title: Text(_summaryOf(settings, status)),
          subtitle: Text(_detailOf(settings, status)),
        ),
        ListItem(
          leading: const GlyphIcon(AppGlyphs.refresh),
          title: Text(status.busy ? '正在加白…' : '立即加白'),
          onTap: settings.isActive && !status.busy
              ? () => unawaited(po0Firewall.runNow())
              : null,
        ),
      ],
    );
  }

  Widget _settingsSection(Po0Settings settings) {
    return generateSection(
      title: '设置',
      items: [
        ListItem.toggle(
          title: const Text('自动加白'),
          subtitle: const Text('当前出口不在白名单里时自动加上'),
          value: settings.enabled,
          onChanged: (value) {
            unawaited(
              po0Firewall.update((current) => current.copyWith(enabled: value)),
            );
          },
        ),
        ListItem.input(
          title: const Text('检查间隔'),
          subtitle: Text('每 ${settings.interval} 秒检查一次'),
          dialogTitle: '检查间隔（秒）',
          value: '${settings.interval}',
          suffixText: '秒',
          keyboardType: TextInputType.number,
          resetValue: '$po0DefaultInterval',
          validator: (value) {
            final seconds = int.tryParse(value?.trim() ?? '');
            if (seconds == null ||
                seconds < po0MinInterval ||
                seconds > po0MaxInterval) {
              return '请输入 $po0MinInterval～$po0MaxInterval 之间的整数';
            }
            return null;
          },
          onChanged: (value) {
            final seconds = int.tryParse(value?.trim() ?? '');
            if (seconds == null) {
              return;
            }
            unawaited(
              po0Firewall.update(
                (current) =>
                    current.copyWith(interval: clampPo0Interval(seconds)),
              ),
            );
          },
        ),
      ],
      footer:
          '检查只读白名单，不占用名额；当前出口不在名单里时才写入。'
          '代理运行时由后台服务检查，从最近任务里划掉应用也不停；'
          '亮屏时按间隔检查，熄屏后只在网络切换时检查。',
    );
  }

  Widget _tokensSection(Po0Settings settings, Po0Status status) {
    return generateSection(
      title: 'Token',
      items: [
        for (final entry in settings.tokens)
          ListItem(
            title: Text(entry.label),
            subtitle: Text(_tokenLine(entry, status.results[entry.token])),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Switch(
                  value: entry.enabled,
                  semanticLabel: '为「${entry.label}」自动加白',
                  onChanged: (value) => unawaited(
                    _replaceToken(
                      entry.token,
                      (item) => item.copyWith(enabled: value),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () => unawaited(_delete(entry)),
                  icon: const GlyphIcon(AppGlyphs.delete),
                ),
              ],
            ),
            onTap: () => unawaited(_rename(entry)),
          ),
        ListItem(
          leading: const GlyphIcon(AppGlyphs.addCircle),
          title: const Text('添加 token'),
          onTap: () => unawaited(_addToken(settings.tokens)),
        ),
        ListItem(
          leading: const GlyphIcon(AppGlyphs.paste),
          title: const Text('从剪贴板导入'),
          subtitle: const Text('每行一个 token，后面可以跟备注'),
          onTap: () => unawaited(_importTokens(settings.tokens)),
        ),
        ListItem(
          leading: const GlyphIcon(AppGlyphs.copy),
          title: const Text('复制全部 token'),
          onTap: settings.tokens.isEmpty
              ? null
              : () => unawaited(_exportTokens(settings.tokens)),
        ),
      ],
      footer:
          '点按 token 修改备注，开关可以暂停单个 token。'
          'token 只保存在这台设备上，FlClash 的备份不包含它们，请用「复制全部 token」另存。',
    );
  }

  List<Widget> _whitelistSections(Po0Settings settings, Po0Status status) {
    return [
      for (final entry in settings.activeTokens)
        if (status.results[entry.token] case final result?
            when result.whitelist.isNotEmpty)
          generateSection(
            title: result.limit == null
                ? '白名单 · ${entry.label}'
                : '白名单 · ${entry.label}'
                      '（${result.whitelist.length}/${result.limit}）',
            items: [
              for (final ip in result.whitelist)
                ListItem(
                  title: Text(ip),
                  subtitle: samePo0C24(ip, result.currentIp)
                      ? const Text('当前出口')
                      : null,
                ),
            ],
          ),
    ];
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(po0SettingsProvider);
    final status = ref.watch(po0StatusProvider);
    return BaseScaffold(
      title: 'po0 加白',
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          _statusSection(settings, status),
          _settingsSection(settings),
          _tokensSection(settings, status),
          ..._whitelistSections(settings, status),
        ],
      ),
    );
  }
}
