/// 插件库的宿主侧接线：把 [PluginRepoClient] 的网络需求接到 dart:io。
///
/// 核心包刻意不依赖 dart:io（要能在纯 Dart 下单测），传输层在这里注入。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:plugin_engine/plugin_engine.dart';
import 'package:plugin_ui_core/plugin_ui_core.dart';

/// 用 dart:io 实现插件库请求。
///
/// 不额外加认证头：插件库是公开仓库，匿名读取即可；
/// 加 `Authorization` 反而会在镜像/CDN 上被拒。
class IoPluginRepoFetcher implements PluginRepoFetcher {
  IoPluginRepoFetcher({this.userAgent = 'ToolPlugin/1.0'});

  final String userAgent;

  @override
  Future<RepoHttpResponse> get(
    Uri uri, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, userAgent);
      final resp = await req.close().timeout(timeout);
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp.timeout(timeout)) {
        builder.add(chunk);
      }
      return RepoHttpResponse(resp.statusCode, builder.takeBytes());
    } finally {
      client.close(force: true);
    }
  }
}

/// 把插件库异常翻译成用户能看懂的话。
///
/// 区分"网络不通"和"仓库里没这个文件"——处理方式完全不同。
String describeRepoError(Object e) {
  if (e is PluginRepoException) {
    return switch (e.kind) {
      PluginRepoErrorKind.badUrl => '仓库地址无效：${e.message}',
      PluginRepoErrorKind.indexMissing =>
        '该仓库没有 index.json，可能不是插件库（或分支名不是 main）',
      PluginRepoErrorKind.indexInvalid => 'index.json 格式不正确：${e.message}',
      PluginRepoErrorKind.network => '网络连接失败，已尝试全部镜像：${e.message}',
      PluginRepoErrorKind.http => '仓库服务器返回错误：${e.message}',
      PluginRepoErrorKind.checksum => '插件包校验失败，文件可能被篡改或未更新完成',
    };
  }
  if (e is PluginError) return '插件包不合法：${e.message}';
  return '加载插件库失败：$e';
}

/// 从用户输入里解析 owner/repo（允许带协议、www、.git、尾部斜杠）。
({String owner, String repo})? parseRepoUrlInput(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;
  s = s.replaceFirst(RegExp(r'^https?://'), '');
  s = s.replaceFirst(RegExp(r'^www\.'), '');
  s = s.replaceFirst(RegExp(r'^github\.com/'), '');
  s = s.split('?').first.split('#').first;
  final parts = s.split('/').where((p) => p.isNotEmpty).toList();
  if (parts.length < 2) return null;
  var repo = parts[1];
  if (repo.endsWith('.git')) repo = repo.substring(0, repo.length - 4);
  if (parts[0].isEmpty || repo.isEmpty) return null;
  return (owner: parts[0], repo: repo);
}

/// 设置页即时校验用：地址看起来是否可用。
bool looksLikeRepoUrl(String s) => parseRepoUrlInput(s) != null;

/// 把 UTF-8 字节解读出来；代理塞进来的 HTML 错误页交给上层按格式错误处理。
String decodeUtf8(Uint8List bytes) {
  try {
    return const Utf8Decoder().convert(bytes);
  } catch (_) {
    return latin1.decode(bytes, allowInvalid: true);
  }
}

/// 供 UI 直接使用的门面。
class PluginRepoService {
  PluginRepoService({PluginRepoFetcher? fetcher})
    : _fetcher = fetcher ?? IoPluginRepoFetcher();

  final PluginRepoFetcher _fetcher;

  /// 按用户填的地址 + 镜像前缀构造 client。
  ///
  /// [mirrorPrefix] 为空表示按默认顺序自动回退；
  /// 用户显式填了就**只用它**（便于排查，也尊重用户选择）。
  PluginRepoClient clientFor({
    required String url,
    String? mirrorPrefix,
    String branch = 'main',
  }) {
    final p = parseRepoUrlInput(url);
    if (p == null) {
      throw PluginRepoException(
        PluginRepoErrorKind.badUrl,
        '地址应形如 https://github.com/用户名/仓库名，实际 "$url"',
      );
    }
    return PluginRepoClient(
      owner: p.owner,
      repo: p.repo,
      branch: branch,
      fetcher: _fetcher,
      mirrors: mirrorPrefix == null || mirrorPrefix.trim().isEmpty
          ? kDefaultMirrors
          : [
              PluginRepoMirror(
                PluginRepoMirrorKind.custom,
                normalizeMirrorPrefix(mirrorPrefix),
              ),
            ],
    );
  }
}
