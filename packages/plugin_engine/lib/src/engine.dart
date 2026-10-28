/// 流程执行器（对应上游第 5 节「游标 + 声明式跳转」与 §1.2 防死循环）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'conditions.dart';
import 'errors.dart';
import 'extractor.dart';
import 'js/js_bridge.dart';
import 'manifest.dart';
import 'template.dart';
import 'values.dart';

/// 步骤执行状态。
enum StepStatus { pending, running, succeeded, failed, skipped }

/// 执行过程中向外层（UI）汇报的事件。
sealed class EngineEvent {
  const EngineEvent();
}

/// 某一步开始。
class StepStarted extends EngineEvent {
  final String stepId;
  final StepType type;
  const StepStarted(this.stepId, this.type);
}

/// 某一步结束。
class StepFinished extends EngineEvent {
  final String stepId;
  final StepStatus status;
  final String? message;
  final Duration elapsed;
  const StepFinished(this.stepId, this.status, this.elapsed, {this.message});
}

/// 需要用户交互（`ui` 步骤）。引擎挂起等待 [UiResponder] 回填。
class UiRequested extends EngineEvent {
  final String stepId;
  final UiSpec spec;
  const UiRequested(this.stepId, this.spec);
}

/// 流程终态。
enum RunOutcome { succeeded, failed, cancelled }

/// 一次运行的完整结果。
class RunResult {
  final RunOutcome outcome;
  final Map<String, Object?> vars;

  /// 终态为 succeeded / failed 时才有 output（`end:"cancelled"` 不渲染）。
  final OutputSpec? output;
  final List<OutputValue>? outputValues;

  /// 失败原因。
  final PluginError? error;

  /// 每一步的执行记录，供 UI 展示步骤流。
  final List<StepRecord> records;

  const RunResult({
    required this.outcome,
    required this.vars,
    required this.records,
    this.output,
    this.outputValues,
    this.error,
  });
}

class OutputValue {
  final String label;
  final String value;
  final bool copyable;
  final bool sensitive;
  final bool multiline;
  const OutputValue({
    required this.label,
    required this.value,
    required this.copyable,
    required this.sensitive,
    required this.multiline,
  });
}

class StepRecord {
  final String stepId;
  final StepType type;
  final StepStatus status;
  final Duration elapsed;
  final String? requestUrl;
  final int? statusCode;
  final String? message;
  StepRecord({
    required this.stepId,
    required this.type,
    required this.status,
    required this.elapsed,
    this.requestUrl,
    this.statusCode,
    this.message,
  });
}

/// HTTP 传输抽象：引擎不依赖具体实现，Flutter 侧可注入代理/证书策略。
abstract class Transport {
  Future<ResponseView> send(
    HttpRequestSpec req,
    Duration timeout,
  );
}

class HttpRequestSpec {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final Uint8List? body;
  final bool followRedirects;
  const HttpRequestSpec({
    required this.method,
    required this.uri,
    required this.headers,
    required this.body,
    required this.followRedirects,
  });
}

/// 用户交互回填。
abstract class UiResponder {
  /// 返回用户输入的值；取消时返回 [UiCancelled]。
  Future<Object?> ask(UiSpec spec, Scope scope);
}

/// 用户取消的哨兵。
class UiCancelled {
  const UiCancelled();
}

/// 引擎入口。
class Engine {
  final Manifest manifest;
  final Transport transport;
  final TemplateEngine tmpl;
  final UiResponder? responder;

  /// 环境变量区（`env.*`）。
  final Map<String, Object?> env;

  /// 安全存储区（`secrets.*`）。
  final Map<String, Object?> secrets;

  /// JS 沙箱注入点。
  ///
  /// 为 null 时使用引擎内置的纯 Dart 沙箱（见 `src/js/` 与 `js_bridge.dart`）——
  /// 它零原生依赖，Android/iOS 同一份代码；宿主若想换实现（例如接 QuickJS）
  /// 仍可通过此参数覆盖。仅在宿主完全禁用 JS 时才需要显式关闭。
  final Future<Object?> Function(
      String code, Map<String, Object?> inputs, String stepId)? jsRuntime;

  /// 宿主中断钩子：每个步骤开始前询问一次，返回 true 即终止。
  ///
  /// 上游规范没有「宿主主动取消」的契约（只有 `ui` 步骤用户取消），
  /// 这是宿主侧补充能力。放在步骤边界而非步骤内部，是为了不打断
  /// 已完成一半的请求——中断点可预测，记录的 StepRecord 也保持完整。
  final bool Function()? shouldAbort;

  Engine({
    required this.manifest,
    required this.transport,
    this.responder,
    this.env = const {},
    this.secrets = const {},
    this.jsRuntime,
    this.shouldAbort,
    TemplateEngine? templateEngine,
  }) : tmpl = templateEngine ?? TemplateEngine();

  /// 执行整个流程。
  ///
  /// [inputs] 是表单收集到的值；[onEvent] 用于向 UI 汇报进度。
  Future<RunResult> run(
    Map<String, Object?> inputs, {
    void Function(EngineEvent)? onEvent,
  }) async {
    final vars = <String, Object?>{};
    final stepsStore = <String, Map<String, Object?>>{};
    final records = <StepRecord>[];
    final visits = <String, int>{};

    // 初始 vars：按声明顺序求值，后者可引用前者（§2.1）
    var scope = Scope(
      input: inputs,
      vars: vars,
      steps: stepsStore,
      env: env,
      secrets: secrets,
    );
    for (final e in manifest.vars.entries) {
      vars[e.key] = _renderAny(e.value, scope);
      scope = scope.copyWith(vars: vars);
    }

    var cursor = 0;
    final flow = manifest.flow;
    final maxVisits = flow.length * 3;

    while (cursor >= 0 && cursor < flow.length) {
      if (shouldAbort?.call() ?? false) {
        return RunResult(
          outcome: RunOutcome.cancelled,
          vars: vars,
          records: records,
        );
      }
      final step = flow[cursor];
      visits[step.id] = (visits[step.id] ?? 0) + 1;
      if (visits[step.id]! > maxVisits) {
        final e = PluginError(ErrorCodes.loop,
            '步骤 "${step.id}" 访问次数超过上限 $maxVisits（疑似死循环）',
            stepId: step.id);
        return RunResult(
          outcome: RunOutcome.failed,
          vars: vars,
          records: records,
          error: e,
        );
      }

      onEvent?.call(StepStarted(step.id, step.type));
      final sw = Stopwatch()..start();
      var next = cursor + 1;

      // 1) when 为假：跳过执行，但跳转仍生效（§5.2）
      if (step.when != null) {
        bool cond;
        try {
          cond = tmpl.evaluateBool(step.when!, scope.copyWith(vars: vars),
              stepId: step.id);
        } on PluginError catch (e) {
          records.add(StepRecord(
            stepId: step.id,
            type: step.type,
            status: StepStatus.failed,
            elapsed: sw.elapsed,
            message: e.message,
          ));
          onEvent?.call(StepFinished(
              step.id, StepStatus.failed, sw.elapsed, message: e.message));
          return RunResult(
            outcome: RunOutcome.failed,
            vars: vars,
            records: records,
            error: e.withStep(step.id),
          );
        }
        if (!cond) {
          records.add(StepRecord(
            stepId: step.id,
            type: step.type,
            status: StepStatus.skipped,
            elapsed: sw.elapsed,
          ));
          onEvent?.call(
              StepFinished(step.id, StepStatus.skipped, sw.elapsed));
          final jumped = _resolveJump(step, scope.copyWith(vars: vars));
          if (jumped != null) next = _indexOf(jumped, step.id);
          cursor = next;
          continue;
        }
      }

      // 2) 执行本步
      try {
        final outcome = await _executeStep(
          step,
          scope.copyWith(vars: vars),
          vars,
          stepsStore,
          onEvent,
        );

        records.add(StepRecord(
          stepId: step.id,
          type: step.type,
          status: outcome.cancelled ? StepStatus.failed : StepStatus.succeeded,
          elapsed: sw.elapsed,
          requestUrl: outcome.requestUrl,
          statusCode: outcome.statusCode,
        ));
        onEvent?.call(StepFinished(step.id, StepStatus.succeeded, sw.elapsed));

        if (outcome.cancelled) {
          return RunResult(
            outcome: RunOutcome.cancelled,
            vars: vars,
            records: records,
          );
        }

        // 3) end 语义
        switch (step.end) {
          case StepEnd.none:
            break;
          case StepEnd.ok:
            return _finishSucceeded(vars, stepsStore, records);
          case StepEnd.error:
            final e = PluginError(
                ErrorCodes.end, '流程以 end:"error" 终止于步骤 "${step.id}"',
                stepId: step.id);
            return _finishFailed(vars, stepsStore, records, e);
          case StepEnd.cancelled:
            return RunResult(
              outcome: RunOutcome.cancelled,
              vars: vars,
              records: records,
            );
        }

        // 4) 跳转
        final jumped = _resolveJump(step, scope.copyWith(vars: vars));
        if (jumped != null) {
          next = _indexOf(jumped, step.id);
        }
      } on PluginError catch (e) {
        sw.stop();
        records.add(StepRecord(
          stepId: step.id,
          type: step.type,
          status: StepStatus.failed,
          elapsed: sw.elapsed,
          message: e.message,
        ));
        onEvent?.call(
            StepFinished(step.id, StepStatus.failed, sw.elapsed, message: e.message));

        // onFail 处理（§6.7）
        final of = step.onFail;
        if (of != null) {
          if (of.goto != null && of.goto!.isNotEmpty) {
            next = _indexOf(of.goto!, step.id);
            cursor = next;
            continue;
          }
          if (of.message != null && of.message!.isNotEmpty) {
            // message 模式：把错误消息渲染进 vars，然后失败终止
            final respScope = scope.copyWith(
              vars: vars,
              response: {
                'status': (e.detail?['status'] as int?) ?? 0,
                'body': (e.detail?['body'] as String?) ?? '',
                'message': e.message,
                'code': e.code,
              },
            );
            final rendered = tmpl.render(of.message!, respScope);
            final ee = PluginError(ErrorCodes.http, rendered,
                stepId: step.id, detail: {'originCode': e.code});
            return _finishFailed(vars, stepsStore, records, ee);
          }
        }
        return _finishFailed(vars, stepsStore, records, e.withStep(step.id));
      }

      cursor = next;
    }

    // 走到 flow 末尾即成功
    return _finishSucceeded(vars, stepsStore, records);
  }

  RunResult _finishSucceeded(
    Map<String, Object?> vars,
    Map<String, Map<String, Object?>> stepsStore,
    List<StepRecord> records,
  ) {
    final scope = Scope(
      input: const {},
      vars: vars,
      steps: stepsStore,
      env: env,
      secrets: secrets,
    );
    final values = _renderOutput(scope);
    return RunResult(
      outcome: RunOutcome.succeeded,
      vars: vars,
      records: records,
      output: manifest.output,
      outputValues: values,
    );
  }

  RunResult _finishFailed(
    Map<String, Object?> vars,
    Map<String, Map<String, Object?>> stepsStore,
    List<StepRecord> records,
    PluginError error,
  ) {
    // end:"error" 时 output 仍渲染（§5.1）
    final scope = Scope(
      input: const {},
      vars: vars,
      steps: stepsStore,
      env: env,
      secrets: secrets,
    );
    List<OutputValue>? values;
    try {
      values = _renderOutput(scope);
    } catch (_) {
      values = null;
    }
    return RunResult(
      outcome: RunOutcome.failed,
      vars: vars,
      records: records,
      output: manifest.output,
      outputValues: values,
      error: error,
    );
  }

  List<OutputValue> _renderOutput(Scope scope) {
    return [
      for (final f in manifest.output.fields)
        OutputValue(
          label: f.label,
          value: tmpl.render(f.value, scope),
          copyable: f.copyable,
          sensitive: f.sensitive,
          multiline: f.multiline,
        ),
    ];
  }

  String? _resolveJump(StepBase step, Scope scope) {
    final branch = step.branch;
    if (branch.isNotEmpty) {
      for (final b in branch) {
        if (tmpl.evaluateBool(b.when, scope, stepId: step.id)) {
          return b.goto;
        }
      }
    }
    final g = step.goto;
    if (g == null) return null;
    if (g.isEmpty || g == 'next') return null;
    return g;
  }

  int _indexOf(String stepId, String fromStep) {
    final idx = manifest.flow.indexWhere((s) => s.id == stepId);
    if (idx < 0) {
      throw PluginError(ErrorCodes.goto,
          'goto 指向不存在的步骤 "$stepId"（来自 "$fromStep"）',
          stepId: fromStep);
    }
    return idx;
  }

  Object? _renderAny(Object? node, Scope scope) {
    if (node is String) return tmpl.render(node, scope);
    if (node is List) return [for (final e in node) _renderAny(e, scope)];
    if (node is Map) {
      return {
        for (final e in node.entries) '${e.key}': _renderAny(e.value, scope)
      };
    }
    return node;
  }

  Future<_StepOutcome> _executeStep(
    StepBase step,
    Scope scope,
    Map<String, Object?> vars,
    Map<String, Map<String, Object?>> stepsStore,
    void Function(EngineEvent)? onEvent, {
    bool inPoll = false,
  }) async {
    // StepBase 是抽象类（非 sealed），Dart 无法自动证明穷尽，
    // 因此用 if-else 链 + 末尾兜底，保证每条路径都有返回值。
    if (step is RequestStep) {
      return _runRequest(step, scope, stepsStore, inPoll: inPoll);
    }
    if (step is SetStep) {
      return _runSet(step, scope, vars);
    }
    if (step is UiStep) {
      return _runUi(step, scope, vars, onEvent);
    }
    if (step is PollStep) {
      return _runPoll(step, scope, vars, stepsStore, onEvent);
    }
    throw PluginError(
        ErrorCodes.schema, '未知的步骤类型 ${step.runtimeType}', stepId: step.id);
  }

  Future<_StepOutcome> _runSet(
    SetStep step,
    Scope scope,
    Map<String, Object?> vars,
  ) async {
    for (final e in step.set.vars.entries) {
      vars[e.key] = _renderAny(e.value, scope.copyWith(vars: vars));
    }
    final js = step.set.js;
    if (js != null) {
      final input = <String, Object?>{};
      for (final e in js.inputs.entries) {
        input[e.key] = _renderAny(e.value, scope.copyWith(vars: vars));
      }
      // 默认走内置纯 Dart 沙箱；hooks.libs / hooks.timeoutMs 由清单控制。
      final runner = jsRuntime;
      final Object? result;
      if (runner != null) {
        result = await runner(js.code, input, step.id);
      } else {
        final hooks = manifest.hooks;
        final timeout = Duration(
          milliseconds: hooks.timeoutMs.clamp(100, 60000),
        );
        // 与表达式共享同一 FnContext：随机/时钟同源，结果可复现（§4.4）
        final ctx = tmpl.ctx;
        result = runSetJs(
          code: js.code,
          inputs: input,
          fnContext: ctx,
          clock: ctx.clock,
          random: ctx.random,
          timeout: timeout,
          libs: hooks.libs,
        );
      }
      vars[js.output] = result;
    }
    return const _StepOutcome();
  }

  Future<_StepOutcome> _runUi(
    UiStep step,
    Scope scope,
    Map<String, Object?> vars,
    void Function(EngineEvent)? onEvent,
  ) async {
    final r = responder;
    if (r == null) {
      throw PluginError(ErrorCodes.schema,
          '此插件需要用户交互，但宿主未提供 UiResponder', stepId: step.id);
    }
    onEvent?.call(UiRequested(step.id, step.ui));
    final value = await r.ask(step.ui, scope.copyWith(vars: vars));
    if (value is UiCancelled) {
      return const _StepOutcome(cancelled: true);
    }
    // input 在 schema 中为必填，宿主直接写回 input 命名空间
    vars[step.ui.input] = value;
    return const _StepOutcome();
  }

  Future<_StepOutcome> _runRequest(
    RequestStep step,
    Scope scope,
    Map<String, Map<String, Object?>> stepsStore, {
    bool inPoll = false,
  }) async {
    final spec = step.request;
    final urlStr = tmpl.render(spec.url, scope);
    final uri = Uri.parse(urlStr);
    _checkHost(uri, step.id);
    _checkScheme(uri, step.id);

    // query
    Uri finalUri = uri;
    if (spec.query.isNotEmpty) {
      final q = <String, String>{};
      for (final e in spec.query.entries) {
        q[e.key] = tmpl.render(renderValue(e.value), scope);
      }
      finalUri = uri.replace(queryParameters: {...uri.queryParameters, ...q});
    }

    final headers = <String, String>{};
    for (final e in spec.headers.entries) {
      headers[e.key] = tmpl.render(renderValue(e.value), scope);
    }

    // body（§6.2 四种序列化）
    Uint8List? body;
    final b = spec.body;
    if (b != null) {
      switch (b.type) {
        case BodyType.json:
          if (!headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
            headers['Content-Type'] = 'application/json';
          }
          body = Uint8List.fromList(
              utf8Encode(_jsonEncode(tmpl.renderTree(b.value, scope))));
        case BodyType.form:
          body = Uint8List.fromList(utf8Encode(_formEncode(
              (tmpl.renderTree(b.value, scope) as Map).cast<String, Object?>())));
          if (!headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
            headers['Content-Type'] = 'application/x-www-form-urlencoded';
          }
        case BodyType.text:
          body = Uint8List.fromList(
              utf8Encode(renderValue(tmpl.renderTree(b.value, scope))));
        case BodyType.hex:
          body = hexToBytes(renderValue(tmpl.renderTree(b.value, scope)));
      }
    }

    final reqSpec = HttpRequestSpec(
      method: spec.method,
      uri: finalUri,
      headers: headers,
      body: body,
      followRedirects: spec.followRedirects,
    );

    final retry = spec.retry;
    final times = retry.times;
    final onCodes = retry.on;
    final backoff = retry.backoffMs;

    ResponseView? resp;
    Object? lastError;
    for (var attempt = 0; attempt <= times; attempt++) {
      try {
        resp = await transport.send(
            reqSpec, Duration(milliseconds: spec.timeoutMs));
        if (resp.statusCode >= 200 && resp.statusCode < 300) break;
        if (!onCodes.contains(resp.statusCode) || attempt == times) break;
        if (attempt < times) {
          await Future<void>.delayed(
              Duration(milliseconds: backoff * (attempt + 1)));
        }
      } on TimeoutException {
        lastError = const PluginError(ErrorCodes.timeout, '请求超时');
        if (attempt == times) rethrow;
      }
    }
    if (resp == null) {
      throw lastError is PluginError
          ? lastError
          : err(ErrorCodes.http, '请求失败：$lastError');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw PluginError(ErrorCodes.http,
          'HTTP ${resp.statusCode}（${spec.method} $finalUri）',
          stepId: step.id,
          detail: {'status': resp.statusCode, 'body': resp.bodyText});
    }

    // extract（§6.4）
    final store = <String, Object?>{};
    for (final ex in step.extract) {
      store[ex.name] = runExtract(ex, resp, step.id);
    }
    stepsStore[step.id] = store;

    // assert（§6.5）
    if (step.assertSpec != null) {
      runAssert(step.assertSpec!, resp, tmpl, scope, step.id);
    }

    return _StepOutcome(
      requestUrl: finalUri.toString(),
      statusCode: resp.statusCode,
    );
  }

  /// `type: "poll"`（§7.1）。语义完全按规范：
  ///  1. 每轮先按序执行 poll.steps 列出的步骤，再求 until；
  ///  2. until 为真 → 成功；为假 → 等 intervalMs（最后一轮不等）后下一轮；
  ///  3. 被 poll 的步骤自身失败：有 onFail 按其处理；无 onFail 视为本轮未就绪；
  ///  4. 达到 maxAttempts 仍未满足 → 按 onTimeout 处理（message 报 E_TIMEOUT / goto 跳转）。
  Future<_StepOutcome> _runPoll(
    PollStep step,
    Scope scope,
    Map<String, Object?> vars,
    Map<String, Map<String, Object?>> stepsStore,
    void Function(EngineEvent)? onEvent,
  ) async {
    final p = step.poll;

    for (var attempt = 0; attempt < p.maxAttempts; attempt++) {
      // 1) 按序执行被引用的步骤
      for (final subId in p.steps) {
        final sub = manifest.stepById(subId);
        if (sub == null) {
          throw PluginError(
              ErrorCodes.schema, 'poll.steps 引用了不存在的 step $subId',
              stepId: step.id);
        }
        try {
          final out =
              await _executeStep(sub, scope, vars, stepsStore, onEvent, inPoll: true);
          if (out.cancelled) return const _StepOutcome(cancelled: true);
        } on PluginError catch (e) {
          final handled = await _handlePollSubFailure(
              sub, e, step, scope, vars, stepsStore, onEvent);
          if (handled != null) return handled;
          // null：无 onFail → 本轮未就绪，继续等待
        }
      }

      // 2) 求 until（steps.<id>.<name> 取最新一轮值）
      final cur = scope.copyWith(vars: vars, steps: stepsStore);
      if (tmpl.evaluateBool(p.until, cur, stepId: step.id)) {
        return const _StepOutcome();
      }

      // 3) 等待（最后一轮不等）
      if (attempt < p.maxAttempts - 1) {
        await Future<void>.delayed(Duration(milliseconds: p.intervalMs));
      }
    }

    // 4) onTimeout
    final ot = p.onTimeout;
    if (ot.goto != null && ot.goto!.isNotEmpty) {
      return _StepOutcome(nextStepId: ot.goto);
    }
    final msg = ot.message ?? '轮询超时';
    final rendered = tmpl.render(
        msg, scope.copyWith(vars: vars, steps: stepsStore));
    throw PluginError(ErrorCodes.timeout, rendered, stepId: step.id);
  }

  /// 被 poll 的步骤失败时的处理（§7.1 细节）。
  /// 返回非 null 表示 poll 应以该结果结束；返回 null 表示本轮未就绪，继续等待。
  Future<_StepOutcome?> _handlePollSubFailure(
    StepBase sub,
    PluginError e,
    PollStep pollStep,
    Scope scope,
    Map<String, Object?> vars,
    Map<String, Map<String, Object?>> stepsStore,
    void Function(EngineEvent)? onEvent,
  ) async {
    final of = sub.onFail;
    if (of == null) return null; // 无 onFail → 视为本轮未就绪
    if (of.goto != null && of.goto!.isNotEmpty) {
      return _StepOutcome(nextStepId: of.goto);
    }
    // message 模式：直接失败终止
    final rendered = tmpl.render(
        of.message ?? e.message, scope.copyWith(vars: vars, steps: stepsStore));
    throw PluginError(e.code, rendered, stepId: sub.id, detail: e.detail);
  }

  // ---- 网络安全模型（§11）----------------------------------------------
  void _checkHost(Uri uri, String stepId) {
    final host = uri.hasPort && !_isDefaultPort(uri)
        ? '${uri.host}:${uri.port}'
        : uri.host;
    final bareHost = uri.host;
    final allowed = manifest.allowHosts;
    final ok = allowed.any((a) {
      final norm = a.toLowerCase();
      return norm == host.toLowerCase() || norm == bareHost.toLowerCase();
    });
    if (!ok) {
      throw PluginError(ErrorCodes.host,
          'host 不在 allowHosts：$host（允许：${allowed.join(', ')}）',
          stepId: stepId);
    }
  }

  bool _isDefaultPort(Uri uri) =>
      (uri.scheme == 'https' && uri.port == 443) ||
      (uri.scheme == 'http' && uri.port == 80);

  void _checkScheme(Uri uri, String stepId) {
    if (uri.scheme == 'https') return;
    if (uri.scheme == 'http') {
      final local = uri.host == '127.0.0.1' ||
          uri.host == 'localhost' ||
          uri.host == '::1';
      if (local && manifest.allowInsecureLocalhost) return;
      throw PluginError(ErrorCodes.insecure,
          '明文 HTTP 未授权：$uri（§11.2 强制 HTTPS）', stepId: stepId);
    }
    throw PluginError(ErrorCodes.insecure,
        '不支持的协议：${uri.scheme}', stepId: stepId);
  }
}

class _StepOutcome {
  final bool cancelled;

  /// 非 null 表示本步骤要求跳转到该 step id（poll.onTimeout.goto / onFail.goto）。
  final String? nextStepId;
  final String? requestUrl;
  final int? statusCode;
  const _StepOutcome({
    this.cancelled = false,
    this.nextStepId,
    this.requestUrl,
    this.statusCode,
  });
}

String _jsonEncode(Object? v) => jsonEncode(_toWire(v));

/// bytes 在 JSON body 里以契约的 `{"__bytes__":"<hex>"}` 线格式出现。
Object? _toWire(Object? v) {
  if (v is Uint8List) return {'__bytes__': bytesToHex(v)};
  if (v is Map) return {for (final e in v.entries) '${e.key}': _toWire(e.value)};
  if (v is List) return [for (final e in v) _toWire(e)];
  return v;
}

String _formEncode(Map<String, Object?> m) => m.entries
    .map((e) =>
        '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(renderValue(e.value))}')
    .join('&');

Uint8List utf8Encode(String s) => Uint8List.fromList(utf8.encode(s));
