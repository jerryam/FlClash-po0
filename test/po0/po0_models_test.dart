import 'package:fl_clash/po0/po0_models.dart';
import 'package:test/test.dart';

const _token = 'pgnfw_abcdef0123456789';
const _other = 'pgnfw_zyxwvu9876543210';

void main() {
  group('parsePo0Token', () {
    test('accepts a bare token', () {
      expect(parsePo0Token('  $_token '), _token);
    });

    test('finds the token in a pasted link', () {
      expect(
        parsePo0Token('https://example.com/api/firewall/$_token/add?x=1'),
        _token,
      );
    });

    test('rejects text without a token', () {
      expect(parsePo0Token('pgnfw'), isNull);
      expect(parsePo0Token(''), isNull);
    });
  });

  test('maskPo0Token keeps the first 12 characters', () {
    expect(maskPo0Token(_token), 'pgnfw_abcdef…');
    expect(maskPo0Token('pgnfw_abc'), 'pgnfw_abc');
  });

  group('/24', () {
    test('samePo0C24 matches addresses and /24 entries', () {
      expect(samePo0C24('1.2.3.0/24', '1.2.3.77'), isTrue);
      expect(samePo0C24('1.2.3.4', '1.2.3.200'), isTrue);
      expect(samePo0C24('1.2.4.4', '1.2.3.4'), isFalse);
      expect(samePo0C24(null, '1.2.3.4'), isFalse);
      expect(samePo0C24('', ''), isFalse);
    });

    test('po0C24Of', () {
      expect(po0C24Of('1.2.3.4'), '1.2.3.0/24');
      expect(po0C24Of('1.2.3.0/24'), '1.2.3.0/24');
      expect(po0C24Of('::1'), '::1');
    });
  });

  group('Po0Settings', () {
    test('round-trips through JSON', () {
      const settings = Po0Settings(
        enabled: false,
        interval: 30,
        tokens: [
          Po0TokenEntry(token: _token, name: '东京'),
          Po0TokenEntry(token: _other, enabled: false),
        ],
      );
      final decoded = Po0Settings.fromJson(settings.toJson());
      expect(decoded.enabled, isFalse);
      expect(decoded.interval, 30);
      expect(decoded.tokens, settings.tokens);
    });

    test('drops invalid and repeated tokens and clamps the interval', () {
      final settings = Po0Settings.fromJson({
        'interval': 99999,
        'tokens': [
          {'token': _token},
          {'token': _token, 'name': 'again'},
          {'token': 'not-a-token'},
          'junk',
        ],
      });
      expect(settings.enabled, isTrue);
      expect(settings.interval, po0MaxInterval);
      expect(settings.tokens, [const Po0TokenEntry(token: _token)]);
    });

    test('reads the settings saved before tokens had a switch', () {
      final settings = Po0Settings.fromJson({
        'enabled': true,
        'interval': 5,
        'port': 34567,
        'username': 'u',
        'password': 'p',
        'tokens': [
          {'token': _token, 'name': 'a'},
        ],
      });
      expect(settings.tokens.single.enabled, isTrue);
    });

    test('activeTokens skips paused tokens and everything when off', () {
      const tokens = [
        Po0TokenEntry(token: _token),
        Po0TokenEntry(token: _other, enabled: false),
      ];
      expect(
        const Po0Settings(tokens: tokens).activeTokens.map((e) => e.token),
        [_token],
      );
      expect(
        const Po0Settings(enabled: false, tokens: tokens).activeTokens,
        isEmpty,
      );
      expect(
        const Po0Settings(
          tokens: [Po0TokenEntry(token: _other, enabled: false)],
        ).isActive,
        isFalse,
      );
    });
  });

  group('token lines', () {
    test('format and parse keep tokens and notes', () {
      const entries = [
        Po0TokenEntry(token: _token, name: '东京 1 号'),
        Po0TokenEntry(token: _other),
      ];
      expect(parsePo0TokenLines(formatPo0TokenLines(entries)), entries);
    });

    test('parse takes the rest of the line as the note', () {
      final entries = parsePo0TokenLines(
        '香港 $_token\r\n\nnothing here\n$_token again\n$_other',
      );
      expect(entries, [
        const Po0TokenEntry(token: _token, name: '香港'),
        const Po0TokenEntry(token: _other),
      ]);
    });
  });

  group('Po0Status.fromJson', () {
    test('reads the service status', () {
      final status = Po0Status.fromJson({
        'type': 'status',
        'lastRound': 1700000000000,
        'busy': true,
        'results': {
          _token: {
            'type': 'notApplied',
            'time': 1700000000000,
            'currentIp': '1.2.3.4',
            'whitelist': ['5.6.7.0/24'],
            'limit': 2,
            'message': null,
          },
          _other: {'type': 'unknown', 'time': 1},
        },
      });
      expect(status.busy, isTrue);
      expect(status.lastRound, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(status.results.keys, [_token]);
      final result = status.results[_token]!;
      expect(result.type, Po0ResultType.notApplied);
      expect(result.currentIp, '1.2.3.4');
      expect(result.whitelist, ['5.6.7.0/24']);
      expect(result.freeSlots, 1);
    });
  });

  group('slots', () {
    Po0Result result(Po0ResultType type, int listed, int? limit) => Po0Result(
      type: type,
      time: DateTime(2026),
      currentIp: '9.9.9.9',
      whitelist: [for (var i = 0; i < listed; i++) '10.0.$i.0/24'],
      limit: limit,
    );

    test('a full list blocks only an exit that is not listed', () {
      expect(result(Po0ResultType.rejected, 3, 3).isFull, isTrue);
      expect(result(Po0ResultType.applied, 3, 3).isFull, isFalse);
      expect(result(Po0ResultType.notApplied, 2, 3).isFull, isFalse);
      expect(result(Po0ResultType.notApplied, 2, null).freeSlots, isNull);
    });

    test('po0ResultText warns when slots run out', () {
      expect(
        po0ResultText(result(Po0ResultType.applied, 3, 3)),
        '已加白（出口 9.9.9.0/24） · 名额已用完',
      );
      expect(
        po0ResultText(result(Po0ResultType.notApplied, 2, 3)),
        '未加白（出口 9.9.9.0/24） · 只剩 1 个名额',
      );
      expect(
        po0ResultText(result(Po0ResultType.applied, 1, 3)),
        '已加白（出口 9.9.9.0/24）',
      );
    });
  });
}
