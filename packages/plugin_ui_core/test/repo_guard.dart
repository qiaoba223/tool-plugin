import 'package:plugin_ui_core/src/plugin_repo.dart';

/// 假传输层：记录请求，按预设返回。
class FakeFetcher implements PluginRepoFetcher {
  FakeFetcher(this.handler);
  final RepoHttpResponse Function(Uri) handler;
  final List<String> seen = [];
  @override
  Future<RepoHttpResponse> get(Uri uri, {Duration timeout = const Duration(seconds: 20)}) async {
    seen.add(uri.toString());
    return handler(uri);
  }
}

Future<void> main() async {
  // 1) 直连失败 → 自动换镜像
  final f1 = FakeFetcher((uri) {
    if (uri.host == 'raw.githubusercontent.com') {
      throw const SocketExceptionStub();
    }
    return RepoHttpResponse(200, '''{"name":"t","plugins":[
      {"id":"a","name":"A","version":"1.0.0","path":"dist/a.qbpkg","sha256":"deadbeef"}
    ]}'''.codeUnits);
  });
  final c1 = PluginRepoClient(owner: 'o', repo: 'r', fetcher: f1);
  final r1 = await c1.fetchIndex();
  print('回退成功: 用了 ${r1.mirror.label}, 共请求 ${f1.seen.length} 次');
  print('  首次: ${f1.seen.first}');
  print('  末次: ${f1.seen.last}');

  // 2) 摘要不匹配 → 必须拒绝
  final f2 = FakeFetcher((uri) {
    if (uri.path.endsWith('index.json')) {
      return RepoHttpResponse(200, '''{"name":"t","plugins":[
        {"id":"a","name":"A","version":"1.0.0","path":"dist/a.qbpkg","sha256":"0000000000000000000000000000000000000000000000000000000000000000"}
      ]}'''.codeUnits);
    }
    return RepoHttpResponse(200, '{"qbpkg":"1.0","manifest":{}}'.codeUnits);
  });
  final c2 = PluginRepoClient(owner: 'o', repo: 'r', fetcher: f2);
  final idx = await c2.fetchIndex();
  try {
    await c2.downloadPackage(idx.index.entries.first);
    print('【错误】摘要不匹配却没拦住');
  } on PluginRepoException catch (e) {
    print('摘要拦截: ${e.kind.name} - ${e.message}');
  }

  // 3) jsDelivr 路径改写
  print('jsDelivr: ${buildRepoUrl(owner: "o", repo: "r", branch: "main", path: "index.json", mirror: const PluginRepoMirror(PluginRepoMirrorKind.jsdelivr, "https://fastly.jsdelivr.net/gh/"))}');
  print('ghproxy : ${buildRepoUrl(owner: "o", repo: "r", branch: "main", path: "index.json", mirror: const PluginRepoMirror(PluginRepoMirrorKind.ghproxy, "https://ghproxy.net/"))}');
  print('规范化  : "${normalizeMirrorPrefix("ghproxy.net")}" / "${normalizeMirrorPrefix("https://x.com/")}"');
}

class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
