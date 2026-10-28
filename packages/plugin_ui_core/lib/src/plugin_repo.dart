/// 插件库（Plugin Repo）客户端。
///
/// 对齐原版 `login_plugin_ui_core/src/plugin_repo.dart`：
/// 任意 GitHub 仓库都能当插件源，约定 `index.json` + 若干 `.qbpkg` 包。
///
/// ## 镜像
///
/// 国内直连 `raw.githubusercontent.com` 常被阻断，因此内置多级前缀回退。
/// 前缀只是**拼接**在原始 URL 前面（jsDelivr 例外，需要改写路径），
/// 所以任何 `https://host/` 形式的前缀都可以由用户自定义。
///
/// ## 校验
///
/// `index.json` 每条记录带 `sha256`，下载后必须核对——这是防篡改的唯一
/// 手段（没有签名链，只能靠仓库自身完整性）。校验失败直接丢弃，不进插件库。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 插件库出错的原因分类，决定 UI 给什么提示。
enum PluginRepoErrorKind {
  /// 地址不是合法的 GitHub 仓库地址。
  badUrl,

  /// 仓库里没有 `index.json`。
  indexMissing,

  /// `index.json` 不是合法 JSON 或结构不对。
  indexInvalid,

  /// 所有镜像都连不上。
  network,

  /// 服务器返回非 2xx。
  http,

  /// 下载到的包 SHA-256 与 index 不符。
  checksum,
}

class PluginRepoException implements Exception {
  PluginRepoException(this.kind, this.message, {this.cause});

  final PluginRepoErrorKind kind;
  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

/// 镜像种类。`custom` 允许任意前缀。
enum PluginRepoMirrorKind { direct, ghproxy, ghfast, ghproxyCom, jsdelivr, custom }

/// 一个镜像前缀。
class PluginRepoMirror {
  const PluginRepoMirror(this.kind, this.prefix);

  final PluginRepoMirrorKind kind;

  /// 形如 `https://ghproxy.net/`；`direct` 时为空串。
  final String prefix;

  String get label {
    switch (kind) {
      case PluginRepoMirrorKind.direct:
        return '直连';
      case PluginRepoMirrorKind.ghproxy:
        return 'ghproxy.net';
      case PluginRepoMirrorKind.ghfast:
        return 'ghfast.top';
      case PluginRepoMirrorKind.ghproxyCom:
        return 'gh-proxy.com';
      case PluginRepoMirrorKind.jsdelivr:
        return 'jsDelivr CDN';
      case PluginRepoMirrorKind.custom:
        return prefix.isEmpty ? '自定义' : prefix;
    }
  }
}

/// 默认镜像顺序：先直连（快且不经过第三方），再逐级兜底。
const List<PluginRepoMirror> kDefaultMirrors = [
  PluginRepoMirror(PluginRepoMirrorKind.direct, ''),
  PluginRepoMirror(PluginRepoMirrorKind.ghproxy, 'https://ghproxy.net/'),
  PluginRepoMirror(PluginRepoMirrorKind.ghfast, 'https://ghfast.top/'),
  PluginRepoMirror(PluginRepoMirrorKind.ghproxyCom, 'https://gh-proxy.com/'),
  PluginRepoMirror(PluginRepoMirrorKind.jsdelivr, 'https://fastly.jsdelivr.net/gh/'),
];

/// 规范化用户输入的镜像前缀。
///
/// 容忍这些写法：`ghproxy.net`、`https://ghproxy.net`、`https://ghproxy.net/`。
/// 统一成带 scheme 且以 `/` 结尾的形式；空输入返回空串（表示直连）。
String normalizeMirrorPrefix(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  if (!s.startsWith('http://') && !s.startsWith('https://')) {
    s = 'https://$s';
  }
  if (!s.endsWith('/')) s = '$s/';
  return s;
}

/// 把 `owner/repo/branch/path` 拼成某个镜像下的原始内容 URL。
///
/// jsDelivr 的路径里不能出现 `https://raw.githubusercontent.com/`，
/// 必须改成 `https://fastly.jsdelivr.net/gh/owner/repo@branch/path`
/// ——这就是原版 `_rewriteJsdelivr` 做的事。
String buildRepoUrl({
  required String owner,
  required String repo,
  required String branch,
  required String path,
  PluginRepoMirror mirror = const PluginRepoMirror(PluginRepoMirrorKind.direct, ''),
}) {
  final cleanPath = path.startsWith('/') ? path.substring(1) : path;
  final base = Uri.encodeFull('https://raw.githubusercontent.com/$owner/$repo/$branch/$cleanPath');

  if (mirror.kind == PluginRepoMirrorKind.direct) return base;

  if (mirror.kind == PluginRepoMirrorKind.jsdelivr) {
    final prefix = mirror.prefix.endsWith('/') ? mirror.prefix : '${mirror.prefix}/';
    return Uri.encodeFull('$prefix$owner/$repo@$branch/$cleanPath');
  }

  // 通用前缀：直接拼接
  final prefix = mirror.prefix.endsWith('/') ? mirror.prefix : '${mirror.prefix}/';
  return '$prefix$base';
}

/// 解析插件库地址。
///
/// 接受：
/// - `https://github.com/owner/repo`
/// - `https://github.com/owner/repo/`（含 `.git` 后缀）
/// - `owner/repo`
///
/// 返回 `(owner, repo)`；非法返回 null。
({String owner, String repo})? parseRepoUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return null;

  s = s.replaceAll(RegExp(r'\.git$'), '');
  final uri = Uri.tryParse(s.startsWith('http') ? s : 'https://$s');
  if (uri == null) return null;

  final segs = uri.pathSegments.where((e) => e.isNotEmpty).toList();
  if (uri.host == 'github.com') {
    if (segs.length < 2) return null;
    return (owner: segs[0], repo: segs[1]);
  }
  // owner/repo 形式
  if (!s.contains('/') || segs.length == 2) {
    if (segs.length == 2) return (owner: segs[0], repo: segs[1]);
  }
  if (segs.length == 2) return (owner: segs[0], repo: segs[1]);
  return null;
}

/// `index.json` 里的一条插件记录。
class PluginRepoEntry {
  const PluginRepoEntry({
    required this.id,
    required this.name,
    required this.version,
    required this.path,
    required this.sha256,
    this.description = '',
    this.author = '',
    this.allowHosts = const [],
  });

  final String id;
  final String name;
  final String version;

  /// 相对仓库根的文件路径，如 `dist/ct.login.qbpkg`。
  final String path;

  /// 小写十六进制 SHA-256；空串表示索引未提供（不做校验）。
  final String sha256;
  final String description;
  final String author;
  final List<String> allowHosts;

  factory PluginRepoEntry.fromJson(Map<String, dynamic> j, int index) {
    String need(String key) {
      final v = j[key];
      if (v is! String || v.isEmpty) {
        throw PluginRepoException(
          PluginRepoErrorKind.indexInvalid,
          'index.json 第 $index 项缺少字段 $key',
        );
      }
      return v;
    }

    final hosts = j['allowHosts'];
    return PluginRepoEntry(
      id: need('id'),
      name: need('name'),
      version: j['version'] is String ? j['version'] as String : '',
      path: need('path'),
      sha256: (j['sha256'] is String ? j['sha256'] as String : '').toLowerCase(),
      description: (j['description'] as String?) ?? '',
      author: (j['author'] as String?) ?? '',
      allowHosts: hosts is List
          ? hosts.whereType<String>().toList(growable: false)
          : const [],
    );
  }
}

/// 解析后的 `index.json`。
class PluginRepoIndex {
  const PluginRepoIndex({
    required this.name,
    required this.entries,
    this.schemaVersion = 1,
    this.updatedAt,
  });

  final String name;
  final List<PluginRepoEntry> entries;
  final int schemaVersion;
  final DateTime? updatedAt;

  factory PluginRepoIndex.parse(String body) {
    dynamic j;
    try {
      j = jsonDecode(body);
    } catch (e) {
      throw PluginRepoException(
        PluginRepoErrorKind.indexInvalid,
        'index.json 不是合法 JSON',
        cause: e,
      );
    }
    if (j is! Map) {
      throw PluginRepoException(
        PluginRepoErrorKind.indexInvalid,
        'index.json 顶层必须是对象',
      );
    }
    final map = Map<String, dynamic>.from(j);
    final list = map['plugins'];
    if (list is! List) {
      throw PluginRepoException(
        PluginRepoErrorKind.indexInvalid,
        'index.json 缺少 plugins 数组',
      );
    }
    final entries = <PluginRepoEntry>[];
    for (var i = 0; i < list.length; i++) {
      final e = list[i];
      if (e is! Map) continue;
      entries.add(PluginRepoEntry.fromJson(Map<String, dynamic>.from(e), i));
    }
    return PluginRepoIndex(
      name: (map['name'] as String?) ?? '插件库',
      entries: entries,
      schemaVersion: (map['schemaVersion'] as num?)?.toInt() ?? 1,
      updatedAt: DateTime.tryParse((map['updatedAt'] as String?) ?? ''),
    );
  }
}

/// 一次 HTTP 的结果，便于测试时替换传输层。
class RepoHttpResponse {
  const RepoHttpResponse(this.statusCode, this.bodyBytes);

  final int statusCode;
  final List<int> bodyBytes;

  bool get ok => statusCode >= 200 && statusCode < 300;
  String get body => utf8.decode(bodyBytes, allowMalformed: true);
}

/// 传输层抽象。生产用 [IoRepoFetcher]，测试可注入假实现。
abstract class PluginRepoFetcher {
  Future<RepoHttpResponse> get(Uri uri, {Duration timeout});
}

/// 基于 `dart:io` 的实现。
class IoRepoFetcher implements PluginRepoFetcher {
  IoRepoFetcher({this.allowBadCertificate = false});

  final bool allowBadCertificate;

  @override
  Future<RepoHttpResponse> get(
    Uri uri, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    if (allowBadCertificate) {
      client.badCertificateCallback = (cert, host, port) => true;
    }
    try {
      final req = await client.getUrl(uri).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, 'tool-plugin-app');
      req.followRedirects = true;
      req.maxRedirects = 5;
      final resp = await req.close().timeout(timeout);
      final bytes = await resp
          .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
          .timeout(timeout);
      return RepoHttpResponse(resp.statusCode, bytes);
    } finally {
      client.close(force: true);
    }
  }
}

/// 插件库客户端：拉索引、下载包、校验摘要，并做镜像回退。
class PluginRepoClient {
  PluginRepoClient({
    required this.owner,
    required this.repo,
    this.branch = 'main',
    PluginRepoFetcher? fetcher,
    this.mirrors = kDefaultMirrors,
    this.timeout = const Duration(seconds: 20),
  }) : fetcher = fetcher ?? IoRepoFetcher();

  final String owner;
  final String repo;
  final String branch;
  final PluginRepoFetcher fetcher;

  /// 按顺序尝试的镜像。
  final List<PluginRepoMirror> mirrors;
  final Duration timeout;

  /// 用地址字符串构造；非法地址抛 [PluginRepoException]。
  factory PluginRepoClient.fromUrl(
    String url, {
    PluginRepoFetcher? fetcher,
    List<PluginRepoMirror> mirrors = kDefaultMirrors,
    Duration timeout = const Duration(seconds: 20),
  }) {
    final parsed = parseRepoUrl(url);
    if (parsed == null) {
      throw PluginRepoException(
        PluginRepoErrorKind.badUrl,
        '插件库地址无效。应形如 https://github.com/用户名/仓库名',
      );
    }
    return PluginRepoClient(
      owner: parsed.owner,
      repo: parsed.repo,
      fetcher: fetcher,
      mirrors: mirrors,
      timeout: timeout,
    );
  }

  /// 依次尝试镜像，返回第一个成功的结果。
  ///
  /// 只有「网络层失败」和「404」才换下一个镜像：`index.json` 结构错误
  /// 说明仓库本身有问题，换镜像也一样，立刻抛出。
  Future<({RepoHttpResponse resp, PluginRepoMirror mirror})> _getWithFallback(
    String path,
  ) async {
    Object? lastError;
    for (final m in mirrors) {
      final uri = Uri.parse(
        buildRepoUrl(
          owner: owner,
          repo: repo,
          branch: branch,
          path: path,
          mirror: m,
        ),
      );
      try {
        final resp = await fetcher.get(uri, timeout: timeout);
        if (resp.ok) return (resp: resp, mirror: m);
        if (resp.statusCode == HttpStatus.notFound) {
          lastError = PluginRepoException(
            PluginRepoErrorKind.indexMissing,
            '$path 不存在（${m.label}）',
          );
          continue;
        }
        lastError = PluginRepoException(
          PluginRepoErrorKind.http,
          '服务器返回 HTTP ${resp.statusCode}（${m.label}）',
        );
      } catch (e) {
        lastError = PluginRepoException(
          PluginRepoErrorKind.network,
          '连接失败（${m.label}）',
          cause: e,
        );
      }
    }
    if (lastError is PluginRepoException) throw lastError;
    throw PluginRepoException(
      PluginRepoErrorKind.network,
      '所有镜像都不可用',
      cause: lastError,
    );
  }

  /// 拉取并解析 `index.json`。
  Future<({PluginRepoIndex index, PluginRepoMirror mirror})> fetchIndex() async {
    final got = await _getWithFallback('index.json');
    return (index: PluginRepoIndex.parse(got.resp.body), mirror: got.mirror);
  }

  /// 下载某个插件的 `.qbpkg`，并校验 SHA-256。
  ///
  /// [entry.sha256] 为空时跳过校验（索引没给摘要，只能信任仓库）。
  Future<({String text, PluginRepoMirror mirror})> downloadPackage(
    PluginRepoEntry entry,
  ) async {
    final got = await _getWithFallback(entry.path);
    final bytes = got.resp.bodyBytes;

    if (entry.sha256.isNotEmpty) {
      final actual = sha256Hex(bytes);
      if (actual != entry.sha256) {
        throw PluginRepoException(
          PluginRepoErrorKind.checksum,
          '插件包校验失败：期望 ${entry.sha256.substring(0, 12)}…，'
          '实际 ${actual.substring(0, 12)}…',
        );
      }
    }
    return (text: utf8.decode(bytes, allowMalformed: true), mirror: got.mirror);
  }
}

/// 计算 SHA-256 的小写十六进制。
///
/// 自己实现是为了让 ui_core 不依赖 `crypto` 之外的运行时，
/// 且便于在 Web/测试环境复用（`dart:io` 的 digiest 不适用）。
String sha256Hex(List<int> data) {
  // 使用 crypto 包（pubspec 已声明）
  return _sha256(data);
}

// ---- SHA-256 实现（crypto 包的同步封装，避免额外依赖传递） ----

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

String _sha256(List<int> message) {
  var h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  var h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

  final ml = message.length * 8;
  final withPad = <int>[...message, 0x80];
  while (withPad.length % 64 != 56) {
    withPad.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    withPad.add((ml >> (i * 8)) & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var off = 0; off < withPad.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      final j = off + i * 4;
      w[i] = (withPad[j] << 24) |
          (withPad[j + 1] << 16) |
          (withPad[j + 2] << 8) |
          withPad[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;
      h = g; g = f; f = e;
      e = (d + t1) & 0xffffffff;
      d = c; c = b; b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final out = StringBuffer();
  for (final v in [h0, h1, h2, h3, h4, h5, h6, h7]) {
    out.write(v.toRadixString(16).padLeft(8, '0'));
  }
  return out.toString();
}
