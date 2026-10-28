import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_version.dart';

/// 一次可用的更新。
class UpdateInfo {
  const UpdateInfo({
    required this.tagName,
    required this.version,
    required this.notes,
    required this.publishedAt,
    required this.assets,
    required this.pageUrl,
  });

  /// 原始 tag，如 `v1.1.0`。
  final String tagName;

  /// 去掉前缀 `v` 的可比较版本。
  final String version;
  final String notes;
  final DateTime? publishedAt;

  /// 本平台可下载的资源（已按平台过滤）。
  final List<UpdateAsset> assets;

  /// Release 页面地址（浏览器打开用）。
  final String pageUrl;
}

class UpdateAsset {
  const UpdateAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
  });

  final String name;
  final String downloadUrl;
  final int sizeBytes;
}

/// 更新过程中的可预期失败（网络、解析、下载）。
class UpdateException implements Exception {
  UpdateException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null ? message : '$message（$cause）';
}

/// 速率限制重置时间的粗略描述（Unix 秒 → "N"）。
String _minutesUntil(String unixSeconds) {
  final secs = int.tryParse(unixSeconds);
  if (secs == null) return '稍';
  final diff = DateTime.fromMillisecondsSinceEpoch(secs * 1000)
      .difference(DateTime.now())
      .inMinutes;
  return diff <= 0 ? '1' : '$diff';
}

/// 语义化版本比较，用于判断"有没有更新"。
///
/// 必须比字符串相等更严格：`1.0.10` 要比 `1.0.9` 新。只按数字段比较，
/// 忽略 `-beta` 这类后缀（上游 release 都是正式版）。
int compareVersions(String a, String b) {
  List<int> parse(String v) {
    final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '');
    // 去掉预发布/构建元数据，只留数字段
    final head = core.split(RegExp(r'[-+]')).first;
    return head
        .split('.')
        .map((s) => int.tryParse(s.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
  }

  final pa = parse(a);
  final pb = parse(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

/// 检查更新 + 下载安装包。
///
/// 网络走 [HttpClient]（与引擎的 transport 一样不引入额外依赖），
/// 这样更新逻辑和插件请求共用同一套证书策略。
class UpdateService {
  UpdateService({
    this.allowBadCertificate = false,
    this.timeout = const Duration(seconds: 20),
  });

  final bool allowBadCertificate;
  final Duration timeout;

  HttpClient _client() {
    final c = HttpClient()..connectionTimeout = timeout;
    if (allowBadCertificate) {
      c.badCertificateCallback = (cert, host, port) => true;
    }
    return c;
  }

  /// 拉取最新 Release。
  ///
  /// [mirror] 是加速前缀（见 [resolveMirrorUrl]），只影响下载地址，
  /// 不影响 API 探测——API 走 api.github.com，国内一般可达。
  Future<UpdateInfo?> fetchLatest({String? mirror}) async {
    final client = _client();
    try {
      final uri = Uri.parse(
        'https://api.github.com/repos/$kRepoOwner/$kRepoName/releases/latest',
      );
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
      req.headers.set(HttpHeaders.userAgentHeader, 'tool-plugin-app');
      final resp = await req.close().timeout(timeout);

      if (resp.statusCode == HttpStatus.notFound) return null;
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode == HttpStatus.forbidden ||
          resp.statusCode == HttpStatus.tooManyRequests) {
        // 403 通常是仓库私有或触发了 API 频率限制；两者都给出可操作提示，
        // 而不是甩一个裸状态码。
        final remaining = resp.headers.value('x-ratelimit-remaining');
        if (remaining == '0') {
          final reset = resp.headers.value('x-ratelimit-reset');
          throw UpdateException(
            '更新检查太频繁，GitHub 已限流'
            '${reset != null ? '，约 ${_minutesUntil(reset)} 分钟后可再试' : ''}',
          );
        }
        throw UpdateException(
          '无法读取更新信息（HTTP ${resp.statusCode}），'
          '请确认发布仓库是公开的',
        );
      }
      if (resp.statusCode != HttpStatus.ok) {
        throw UpdateException('检查更新失败（HTTP ${resp.statusCode}）');
      }

      final json = jsonDecode(text);
      if (json is! Map) throw UpdateException('Release 响应格式异常');
      return _parseRelease(json.cast<String, Object?>(), mirror: mirror);
    } on UpdateException {
      rethrow;
    } on SocketException catch (e) {
      throw UpdateException('无法连接更新服务器', cause: e.message);
    } on HttpException catch (e) {
      throw UpdateException('更新服务器返回异常', cause: e.message);
    } on FormatException catch (e) {
      throw UpdateException('无法解析更新信息', cause: e.message);
    } on TimeoutException catch (e) {
      throw UpdateException('检查更新超时', cause: e.message);
    } finally {
      client.close(force: true);
    }
  }

  UpdateInfo? _parseRelease(Map<String, Object?> j, {String? mirror}) {
    final tag = j['tag_name'];
    if (tag is! String || tag.isEmpty) return null;

    final rawAssets = j['assets'];
    final assets = <UpdateAsset>[];
    if (rawAssets is List) {
      for (final a in rawAssets) {
        if (a is! Map) continue;
        final am = a.cast<String, Object?>();
        final name = am['name'];
        final url = am['browser_download_url'];
        if (name is! String || url is! String) continue;
        if (!_matchesPlatform(name)) continue;
        assets.add(
          UpdateAsset(
            name: name,
            downloadUrl: resolveMirrorUrl(url, mirror),
            sizeBytes: (am['size'] as num?)?.toInt() ?? 0,
          ),
        );
      }
    }

    return UpdateInfo(
      tagName: tag,
      version: tag.replaceFirst(RegExp(r'^[vV]'), ''),
      notes: (j['body'] as String?)?.trim() ?? '',
      publishedAt: DateTime.tryParse((j['published_at'] as String?) ?? ''),
      assets: assets,
      pageUrl: (j['html_url'] as String?) ?? '',
    );
  }

  /// 当前平台只认自己的安装包，避免把 APK 下到 iOS 上。
  bool _matchesPlatform(String name) {
    final lower = name.toLowerCase();
    if (Platform.isAndroid) return lower.endsWith(kApkAssetKeyword);
    if (Platform.isIOS) return lower.endsWith(kIpaAssetKeyword);
    return false;
  }

  /// 下载安装包到 [destPath]，返回文件大小。
  ///
  /// 边下边写盘，避免把几十 MB 的包全塞进内存。
  Future<int> download(
    UpdateAsset asset,
    String destPath, {
    void Function(int received, int total)? onProgress,
  }) async {
    final client = _client();
    final tmp = File('$destPath.part');
    try {
      final req = await client
          .getUrl(Uri.parse(asset.downloadUrl))
          .timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, 'tool-plugin-app');
      final resp = await req.close().timeout(timeout);
      if (resp.statusCode != HttpStatus.ok) {
        throw UpdateException('下载失败（HTTP ${resp.statusCode}）');
      }
      final total = resp.contentLength >= 0
          ? resp.contentLength
          : asset.sizeBytes;
      final sink = tmp.openWrite();
      var received = 0;
      try {
        await for (final chunk in resp.timeout(timeout)) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      // 完整写完再改名，避免中断留下一个"看起来完整"的坏包
      await tmp.rename(destPath);
      return received;
    } on UpdateException {
      if (await tmp.exists()) await tmp.delete();
      rethrow;
    } on SocketException catch (e) {
      if (await tmp.exists()) await tmp.delete();
      throw UpdateException('下载中断', cause: e.message);
    } on TimeoutException catch (e) {
      if (await tmp.exists()) await tmp.delete();
      throw UpdateException('下载超时', cause: e.message);
    } finally {
      client.close(force: true);
    }
  }
}

/// 按镜像前缀重写下载地址。
///
/// GitHub Release 资源真实域名是 `github.com` / `objects.githubusercontent.com`，
/// 国内直连常失败。约定用代理前缀拼接原始 URL，如：
///   mirror = `https://ghproxy.net/`
///   -> `https://ghproxy.net/https://github.com/.../app.apk`
///
/// [mirror] 为空或非法时原样返回，保证"不配置也能用"。
String resolveMirrorUrl(String original, String? mirror) {
  final m = mirror?.trim();
  if (m == null || m.isEmpty) return original;
  var base = m;
  if (!base.endsWith('/')) base = '$base/';
  // 只接受 http(s)，避免把 file:// 之类塞进下载流程
  final scheme = Uri.tryParse(base)?.scheme;
  if (scheme != 'http' && scheme != 'https') return original;
  return '$base$original';
}
