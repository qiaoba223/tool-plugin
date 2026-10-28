import 'dart:typed_data';

import 'package:plugin_engine/plugin_engine.dart';
import 'package:test/test.dart';

/// 不联网的传输：按 URL 返回预置响应，并记录调用次数。
class _FakeTransport implements Transport {
  _FakeTransport(this.responses);

  final Map<String, String> responses;
  final List<String> calls = [];

  @override
  Future<ResponseView> send(HttpRequestSpec req, Duration timeout) async {
    calls.add(req.uri.toString());
    final body = responses[req.uri.toString()] ?? '';
    return ResponseView(
      statusCode: 200,
      headers: const {'content-type': 'text/plain'},
      bodyBytes: Uint8List.fromList(body.codeUnits),
    );
  }
}

Map<String, Object?> _manifest({
  required List<Map<String, Object?>> flow,
  Map<String, Object?> output = const {
    'title': '结果',
    'fields': [
      {'label': '值', 'value': 'ok'},
    ],
  },
}) =>
    {
      'id': 'test.plugin',
      'name': '测试插件',
      'version': '1.0.0',
      'engine': '>=1.0',
      'allowHosts': ['example.com'],
      'inputs': const <Map<String, Object?>>[],
      'flow': flow,
      'output': output,
    };

Map<String, Object?> _req(String id, String url) => {
      'id': id,
      'type': 'request',
      'request': {'method': 'GET', 'url': url},
      'extract': [
        {'name': 'body', 'from': 'raw', 'offset': 0},
      ],
    };

Future<RunResult> _run(
  Map<String, Object?> m, {
  Transport? transport,
  bool Function()? shouldAbort,
  void Function(EngineEvent)? onEvent,
}) {
  final engine = Engine(
    manifest: parseManifest(m),
    transport: transport ?? _FakeTransport(const {}),
    shouldAbort: shouldAbort,
  );
  return engine.run(const {}, onEvent: onEvent);
}

void main() {
  group('步骤流', () {
    test('顺序执行且记录完整', () async {
      final t = _FakeTransport({'https://example.com/a': 'x'});
      final r = await _run(
        _manifest(flow: [_req('s1', 'https://example.com/a')]),
        transport: t,
      );
      expect(r.outcome, RunOutcome.succeeded);
      expect(r.records, hasLength(1));
      expect(t.calls, ['https://example.com/a']);
    });

    test('end:"ok" 提前终止，后续步骤不执行', () async {
      final t = _FakeTransport({
        'https://example.com/a': 'x',
        'https://example.com/b': 'y',
      });
      final r = await _run(
        _manifest(flow: [
          {..._req('s1', 'https://example.com/a'), 'end': true},
          _req('s2', 'https://example.com/b'),
        ]),
        transport: t,
      );
      expect(r.outcome, RunOutcome.succeeded);
      expect(t.calls, ['https://example.com/a']);
      expect(r.records.map((e) => e.stepId), ['s1']);
    });

    test('end:"cancelled" 返回 cancelled 且不渲染 output', () async {
      final r = await _run(
        _manifest(flow: [
          {..._req('s1', 'https://example.com/a'), 'end': 'cancelled'},
        ]),
      );
      expect(r.outcome, RunOutcome.cancelled);
      expect(r.outputValues, isNull);
    });
  });

  group('宿主中断', () {
    test('shouldAbort 为真时不执行任何步骤', () async {
      final t = _FakeTransport(const {});
      final r = await _run(
        _manifest(flow: [_req('s1', 'https://example.com/a')]),
        transport: t,
        shouldAbort: () => true,
      );
      expect(r.outcome, RunOutcome.cancelled);
      expect(t.calls, isEmpty);
      expect(r.records, isEmpty);
    });

    test('在步骤边界中断：已完成的步骤保留记录，未开始的不执行', () async {
      final t = _FakeTransport({'https://example.com/a': 'x'});
      var calls = 0;
      final r = await _run(
        _manifest(flow: [
          _req('s1', 'https://example.com/a'),
          _req('s2', 'https://example.com/b'),
          _req('s3', 'https://example.com/c'),
        ]),
        transport: t,
        // 第一次询问放行，之后一律中断
        shouldAbort: () => calls++ > 0,
      );
      expect(r.outcome, RunOutcome.cancelled);
      expect(t.calls, ['https://example.com/a']);
      expect(r.records.map((e) => e.stepId), ['s1']);
    });

    test('不传 shouldAbort 时行为不变', () async {
      final r = await _run(
        _manifest(flow: [_req('s1', 'https://example.com/a')]),
      );
      expect(r.outcome, RunOutcome.succeeded);
    });
  });

  group('when 语义（§5.2）', () {
    test('when 为假的步骤记录为 skipped 且不请求', () async {
      final t = _FakeTransport(const {});
      final r = await _run(
        _manifest(flow: [
          {..._req('s1', 'https://example.com/a'), 'when': 'false'},
        ]),
        transport: t,
      );
      expect(t.calls, isEmpty);
      expect(r.records.single.status, StepStatus.skipped);
    });
  });
}
