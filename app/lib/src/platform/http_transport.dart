import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:plugin_engine/plugin_engine.dart';

/// 用 `dart:io` HttpClient 实现引擎的 [Transport]。
///
/// 为什么不直接用 `package:http`：插件需要写原始字节 body（`Uint8List`）、
/// 读原始字节响应、控制重定向，`HttpClient` 这些都能直接做，少一层适配；
/// 另外能设置 `badCertificateCallback` 给少数证书链异常的运营商网关兜底。
bool _acceptAll(X509Certificate cert, String host, int port) => true;

class HttpClientTransport implements Transport {
  HttpClientTransport({
    this.userAgent,
    this.defaultTimeout = const Duration(seconds: 20),
    this.allowBadCertificate = false,
  });

  /// 兜底的 User-Agent（插件自身的 `headers` 优先）。
  final String? userAgent;
  final Duration defaultTimeout;

  /// 是否容忍自签名/证书链异常的服务器。
  ///
  /// 默认关闭。部分运营商网关证书链确实不规范，用户可在设置里自行开启，
  /// **开启意味着放弃该连接的身份校验**，UI 上必须明确提示。
  final bool allowBadCertificate;

  @override
  Future<ResponseView> send(HttpRequestSpec req, Duration timeout) async {
    final client = HttpClient()
      ..userAgent = userAgent
      ..connectionTimeout = timeout > defaultTimeout ? timeout : defaultTimeout;

    if (allowBadCertificate) {
      // 仅用于调试自签证书；生产环境请保持关闭（见 E_INSECURE 的语义）
      client.badCertificateCallback = _acceptAll;
    }

    try {
      final request = await client
          .openUrl(req.method, req.uri)
          .timeout(
            timeout,
            onTimeout: () {
              throw TimeoutException('连接超时（$timeout）', timeout);
            },
          );

      req.headers.forEach(request.headers.set);
      // `followRedirects` 是 HttpClientRequest 的属性；插件声明不跟随时必须
      // 显式关闭，否则 302 会被静默吞掉、后续断言针对错误的响应体。
      request.followRedirects = req.followRedirects;
      if (userAgent != null &&
          !req.headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
        request.headers.set(HttpHeaders.userAgentHeader, userAgent!);
      }
      final body = req.body;
      if (body != null && body.isNotEmpty) {
        request.add(body);
      }

      final response = await request.close().timeout(
        timeout,
        onTimeout: () {
          throw TimeoutException('等待响应超时（$timeout）', timeout);
        },
      );

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
      }

      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        if (values.isNotEmpty) headers[name] = values.join(', ');
      });

      return ResponseView(
        statusCode: response.statusCode,
        headers: headers,
        bodyBytes: builder.takeBytes(),
      );
    } on TimeoutException {
      rethrow;
    } on HandshakeException catch (e) {
      throw PluginError(
        ErrorCodes.http,
        'TLS 握手失败：${e.message}。'
        '若确认是目标站点证书链不规范，可在设置中开启「容忍异常证书」。',
      );
    } on SocketException catch (e) {
      throw PluginError(ErrorCodes.http, '网络不可达：${e.message}');
    } on HttpException catch (e) {
      throw PluginError(ErrorCodes.http, 'HTTP 错误：${e.message}');
    } finally {
      client.close(force: true);
    }
  }
}

/// 把一组响应头转成可展示的文本（调试用）。
String dumpHeaders(ResponseView r) {
  final keys = r.headers.keys.toList()..sort();
  return keys.map((k) => '$k: ${r.headers[k]}').join('\n');
}

/// 判断响应体是否为可读文本（粗略：UTF-8 能否解析且不含大量控制字符）。
bool looksLikeText(Uint8List bytes) {
  if (bytes.isEmpty) return true;
  final sample = bytes.length > 512 ? bytes.sublist(0, 512) : bytes;
  var control = 0;
  for (final b in sample) {
    if (b == 0) return false;
    if (b < 0x09 || (b > 0x0d && b < 0x20 && b != 0x1b)) control++;
  }
  return control * 10 < sample.length;
}
