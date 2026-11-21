import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'po0_models.dart';

const _apiBase = 'https://$po0ApiHost/api/firewall';

/// No route would leave on the physical network: the core runs, but the
/// config it runs lacks this session's DIRECT listener. Nothing is sent
/// another way, as any other route could reach the API from a proxy node and
/// whitelist the node instead.
class Po0RouteUnavailable implements Exception {
  const Po0RouteUnavailable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Returns the `findProxy` route for the next request, or null when no route
/// would leave on the physical network.
typedef Po0Route = String? Function();

SecurityContext? _po0Context;

/// Android 7 lacks ISRG Root X1, the root of the API's Let's Encrypt chain.
SecurityContext get _securityContext {
  final current = _po0Context;
  if (current != null) {
    return current;
  }
  final context = SecurityContext(withTrustedRoots: true);
  try {
    context.setTrustedCertificatesBytes(utf8.encode(_isrgRootX1));
  } catch (_) {
    // Already among the system roots.
  }
  return _po0Context = context;
}

class Po0Client {
  Po0Client(this._route);

  final Po0Route _route;
  HttpClient? _client;
  String? _clientRoute;

  static const _checkTimeout = Duration(seconds: 5);
  static const _addTimeout = Duration(seconds: 20);
  static const _retryDelay = Duration(milliseconds: 1500);

  /// Read-only: it never takes a whitelist slot.
  Future<Po0Result> check(String token) =>
      _call(token, 'GET', _uri(token), attempts: 1, timeout: _checkTimeout);

  /// Adds the current exit's /24; the server treats a listed /24 as done, so
  /// a retry is safe.
  Future<Po0Result> add(String token) => _call(
    token,
    'POST',
    _uri(token, '/add'),
    attempts: 3,
    timeout: _addTimeout,
  );

  /// The pooled connection outlives a network switch, so it is dropped then.
  void reset() {
    _client?.close(force: true);
    _client = null;
  }

  Uri _uri(String token, [String action = '']) =>
      Uri.parse('$_apiBase/${Uri.encodeComponent(token)}$action');

  HttpClient _clientFor(String route) {
    if (route != _clientRoute) {
      reset();
      _clientRoute = route;
    }
    return _client ??= HttpClient(context: _securityContext)
      ..findProxy = ((_) => route)
      ..connectionTimeout = const Duration(seconds: 5)
      ..idleTimeout = const Duration(seconds: 30);
  }

  Future<({int status, String body})> _send(
    String method,
    Uri uri,
    Duration timeout,
  ) async {
    final route = _route();
    if (route == null) {
      throw const Po0RouteUnavailable('代理运行中，但 po0 直连入口还没有写入配置');
    }
    final client = _clientFor(route);
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.contentType = ContentType.json;
      final response = await request.close().timeout(timeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return (status: response.statusCode, body: body);
    } catch (error) {
      if (identical(client, _client)) {
        reset();
      }
      if (route != 'DIRECT' && _isListenerFailure(error)) {
        throw Po0RouteUnavailable('po0 直连入口无响应：$error');
      }
      rethrow;
    }
  }

  /// A refused connection to the loopback proxy, or its 407, means the core
  /// runs a config without this session's listener.
  bool _isListenerFailure(Object error) {
    if (error is SocketException) {
      final address = error.address;
      final text = '${error.osError?.message ?? ''} ${error.message}';
      final refused =
          error.osError?.errorCode == 111 ||
          text.toLowerCase().contains('refused');
      return refused && (address == null || address.isLoopback);
    }
    if (error is HttpException) {
      return error.message.contains('407');
    }
    return false;
  }

  Future<Po0Result> _call(
    String token,
    String method,
    Uri uri, {
    required int attempts,
    required Duration timeout,
  }) async {
    Object? lastError;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (attempt > 1) {
        await Future<void>.delayed(_retryDelay * (attempt - 1));
      }
      try {
        final response = await _send(method, uri, timeout);
        if (_isTransient(response.status, response.body)) {
          lastError = 'HTTP ${response.status}';
          continue;
        }
        return _parse(token, response.status, response.body);
      } on Po0RouteUnavailable {
        rethrow;
      } on TimeoutException {
        lastError = '请求超时';
        reset();
      } catch (error) {
        lastError = error;
      }
    }
    return Po0Result(
      type: Po0ResultType.error,
      time: DateTime.now(),
      message: _redact('$lastError', token),
    );
  }

  // The API now and then answers a bare 400 "Error" or a 5xx that succeeds a
  // few seconds later; a JSON error body (an invalid token) is final.
  bool _isTransient(int status, String body) {
    if (status >= 500 || status == HttpStatus.tooManyRequests) {
      return true;
    }
    if ((status >= 200 && status < 300) || status == HttpStatus.forbidden) {
      return false;
    }
    return _decodeMap(body) == null;
  }

  Po0Result _parse(String token, int status, String body) {
    final now = DateTime.now();
    final data = _decodeMap(body);
    if (data == null) {
      return Po0Result(
        type: Po0ResultType.error,
        time: now,
        message: 'HTTP $status: ${_snippet(_redact(body, token))}',
      );
    }
    final currentIp = data['currentIp']?.toString();
    if (status < 200 || status >= 300) {
      final message = data['message'] ?? data['msg'] ?? data['error'];
      return Po0Result(
        type: Po0ResultType.rejected,
        time: now,
        currentIp: currentIp,
        message: _redact('${message ?? 'HTTP $status'}', token),
      );
    }
    final rawWhitelist = data['whitelist'];
    if (rawWhitelist is! List) {
      return Po0Result(
        type: Po0ResultType.error,
        time: now,
        currentIp: currentIp,
        message: _snippet(_redact(body, token)),
      );
    }
    final whitelist = [
      for (final item in rawWhitelist)
        if (item is Map) '${item['ip']}' else '$item',
    ];
    final limit = data['limit'];
    final listed = whitelist.any((ip) => samePo0C24(ip, currentIp));
    return Po0Result(
      type: data['enabled'] == false
          ? Po0ResultType.disabled
          : listed
          ? Po0ResultType.applied
          : Po0ResultType.notApplied,
      time: now,
      currentIp: currentIp,
      whitelist: whitelist,
      limit: limit is num ? limit.toInt() : null,
    );
  }

  Map<String, dynamic>? _decodeMap(String body) {
    try {
      final data = json.decode(body);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  String _snippet(String body) {
    final text = body.trim();
    return text.length > 80 ? '${text.substring(0, 80)}…' : text;
  }

  String _redact(String text, String token) =>
      text.replaceAll(token, maskPo0Token(token));
}

const _isrgRootX1 = '''
-----BEGIN CERTIFICATE-----
MIIFazCCA1OgAwIBAgIRAIIQz7DSQONZRGPgu2OCiwAwDQYJKoZIhvcNAQELBQAw
TzELMAkGA1UEBhMCVVMxKTAnBgNVBAoTIEludGVybmV0IFNlY3VyaXR5IFJlc2Vh
cmNoIEdyb3VwMRUwEwYDVQQDEwxJU1JHIFJvb3QgWDEwHhcNMTUwNjA0MTEwNDM4
WhcNMzUwNjA0MTEwNDM4WjBPMQswCQYDVQQGEwJVUzEpMCcGA1UEChMgSW50ZXJu
ZXQgU2VjdXJpdHkgUmVzZWFyY2ggR3JvdXAxFTATBgNVBAMTDElTUkcgUm9vdCBY
MTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAK3oJHP0FDfzm54rVygc
h77ct984kIxuPOZXoHj3dcKi/vVqbvYATyjb3miGbESTtrFj/RQSa78f0uoxmyF+
0TM8ukj13Xnfs7j/EvEhmkvBioZxaUpmZmyPfjxwv60pIgbz5MDmgK7iS4+3mX6U
A5/TR5d8mUgjU+g4rk8Kb4Mu0UlXjIB0ttov0DiNewNwIRt18jA8+o+u3dpjq+sW
T8KOEUt+zwvo/7V3LvSye0rgTBIlDHCNAymg4VMk7BPZ7hm/ELNKjD+Jo2FR3qyH
B5T0Y3HsLuJvW5iB4YlcNHlsdu87kGJ55tukmi8mxdAQ4Q7e2RCOFvu396j3x+UC
B5iPNgiV5+I3lg02dZ77DnKxHZu8A/lJBdiB3QW0KtZB6awBdpUKD9jf1b0SHzUv
KBds0pjBqAlkd25HN7rOrFleaJ1/ctaJxQZBKT5ZPt0m9STJEadao0xAH0ahmbWn
OlFuhjuefXKnEgV4We0+UXgVCwOPjdAvBbI+e0ocS3MFEvzG6uBQE3xDk3SzynTn
jh8BCNAw1FtxNrQHusEwMFxIt4I7mKZ9YIqioymCzLq9gwQbooMDQaHWBfEbwrbw
qHyGO0aoSCqI3Haadr8faqU9GY/rOPNk3sgrDQoo//fb4hVC1CLQJ13hef4Y53CI
rU7m2Ys6xt0nUW7/vGT1M0NPAgMBAAGjQjBAMA4GA1UdDwEB/wQEAwIBBjAPBgNV
HRMBAf8EBTADAQH/MB0GA1UdDgQWBBR5tFnme7bl5AFzgAiIyBpY9umbbjANBgkq
hkiG9w0BAQsFAAOCAgEAVR9YqbyyqFDQDLHYGmkgJykIrGF1XIpu+ILlaS/V9lZL
ubhzEFnTIZd+50xx+7LSYK05qAvqFyFWhfFQDlnrzuBZ6brJFe+GnY+EgPbk6ZGQ
3BebYhtF8GaV0nxvwuo77x/Py9auJ/GpsMiu/X1+mvoiBOv/2X/qkSsisRcOj/KK
NFtY2PwByVS5uCbMiogziUwthDyC3+6WVwW6LLv3xLfHTjuCvjHIInNzktHCgKQ5
ORAzI4JMPJ+GslWYHb4phowim57iaztXOoJwTdwJx4nLCgdNbOhdjsnvzqvHu7Ur
TkXWStAmzOVyyghqpZXjFaH3pO3JLF+l+/+sKAIuvtd7u+Nxe5AW0wdeRlN8NwdC
jNPElpzVmbUq4JUagEiuTDkHzsxHpFKVK7q4+63SM1N95R1NbdWhscdCb+ZAJzVc
oyi3B43njTOQ5yOf+1CceWxG1bQVs5ZufpsMljq4Ui0/1lvh+wjChP4kqKOJ2qxq
4RgqsahDYVvTH9w7jXbyLeiNdd8XM2w9U/t7y0Ff/9yi0GE44Za4rF2LN9d11TPA
mRGunUHBcnWEvgJBQl9nJEiU0Zsnvgc/ubhPgXRR4Xq37Z0j4r7g1SgEEzwxA57d
emyPxgcYxn/eR44/KJ4EBs+lVDR3veyJm+kXQ99b21/+jh5Xos1AnX5iItreGCc=
-----END CERTIFICATE-----
''';
