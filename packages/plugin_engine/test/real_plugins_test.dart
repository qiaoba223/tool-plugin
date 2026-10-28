import 'dart:io';

import 'package:plugin_engine/plugin_engine.dart';
import 'package:test/test.dart';

/// 用 plugin-harbor 的 4 个真实插件验证：
/// 1. .qbpkg 信封能正确解码
/// 2. manifest 能通过结构校验
/// 3. 所有 goto/branch/poll 目标存在
/// 4. 模板与表达式能被解析（不执行）
void main() {
  final fixturesDir = Directory('test/fixtures');
  final files = fixturesDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  test('fixtures 存在', () {
    expect(files, isNotEmpty, reason: 'test/fixtures 下应有真实插件 .qbpkg');
  });

  for (final f in files) {
    final name = f.uri.pathSegments.last.replaceAll('.json', '');

    group('真实插件 $name', () {
      late Manifest manifest;

      test('.qbpkg 信封解码', () {
        final decoded = PluginPackage.decode(f.readAsStringSync());
        expect(decoded.isEnvelope, isTrue);
        expect(decoded.meta?['exportedBy'], isNotEmpty);
        expect(decoded.meta?['exportedAt'], isNotEmpty);
      });

      test('manifest 通过结构校验', () {
        final decoded = PluginPackage.decode(f.readAsStringSync());
        manifest = parseManifest(decoded.manifest);
        expect(manifest.id, name);
        expect(manifest.flow, isNotEmpty);
      });

      test('跳转目标全部存在', () {
        final ids = manifest.flow.map((s) => s.id).toSet();
        for (final s in manifest.flow) {
          if (s.goto != null && s.goto!.isNotEmpty && s.goto != 'next') {
            expect(ids, contains(s.goto),
                reason: '步骤 ${s.id} 的 goto="${s.goto}" 不存在');
          }
          for (final b in s.branch) {
            expect(ids, contains(b.goto),
                reason: '步骤 ${s.id} 的 branch goto="${b.goto}" 不存在');
          }
          if (s is PollStep) {
            for (final subId in s.poll.steps) {
              expect(ids, contains(subId),
                  reason: 'poll 引用的步骤 $subId 不在 flow 里');
            }
          }
        }
      });

      test('所有模板与表达式可解析', () {
        final engine = TemplateEngine();
        final scope = Scope(
          input: {for (final i in manifest.inputs) i.key: ''},
          vars: {for (final k in manifest.vars.keys) k: ''},
          steps: const {},
          env: const {},
          secrets: const {},
        );
        var count = 0;
        void checkTemplate(String? t) {
          if (t == null) return;
          // 只解析不求值：用空作用域渲染会抛 E_UNDEF，那是正常的
          try {
            engine.render(t, scope);
          } on PluginError catch (e) {
            // 只允许「路径不存在」类错误，语法错误必须失败
            expect(
              e.code,
              anyOf(ErrorCodes.undef, ErrorCodes.type, ErrorCodes.arg),
              reason: '模板 "$t" 有语法/结构问题: $e',
            );
          }
          count++;
        }

        for (final i in manifest.inputs) {
          checkTemplate(i.placeholder);
        }
        for (final v in manifest.vars.values) {
          if (v is String) checkTemplate(v);
        }
        for (final s in manifest.flow) {
          checkTemplate(s.when);
          if (s is RequestStep) {
            checkTemplate(s.request.url);
            for (final v in s.request.headers.values) {
              checkTemplate(v);
            }
          }
          if (s is SetStep) {
            for (final v in s.set.vars.values.whereType<String>()) {
              checkTemplate(v);
            }
          }
        }
        for (final o in manifest.output.fields) {
          checkTemplate(o.value);
        }
        expect(count, greaterThan(0));
      });
    });
  }

  test('插件里用到的 fn.* 全部已实现', () {
    final used = <String>{};
    final fnRe = RegExp(r'fn\.([A-Za-z_][A-Za-z0-9_]*)');
    for (final f in files) {
      for (final m in fnRe.allMatches(f.readAsStringSync())) {
        used.add(m.group(1)!);
      }
    }
    final missing = used.where((n) => !fnSpecs.containsKey(n)).toList();
    expect(missing, isEmpty, reason: '未实现的函数: $missing');
    print('插件用到的函数: ${used.toList()..sort()}');
  });
}
