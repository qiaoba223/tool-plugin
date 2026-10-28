import 'package:flutter/foundation.dart';
import 'package:plugin_engine/plugin_engine.dart';

import 'plugin_store.dart';

/// 运行阶段的粗粒度状态，用于驱动 UI。
enum RunPhase { idle, collectingInput, running, succeeded, failed, cancelled }

enum LogLevel { info, request, response, ok, warn, error }

/// 一次运行产生的日志行。
class LogLine {
  LogLine(this.level, this.text, {this.stepId}) : at = DateTime.now();
  final LogLevel level;
  final String text;
  final String? stepId;
  final DateTime at;
}

/// 单个插件的运行会话。
class RunController extends ChangeNotifier {
  RunController({
    required this.plugin,
    required this.transport,
    required this.responder,
    this.env = const {},
    this.secrets = const {},
  });

  final InstalledPlugin plugin;
  final Transport transport;
  final UiResponder responder;
  final Map<String, Object?> env;
  final Map<String, Object?> secrets;

  final List<LogLine> _logs = [];
  List<LogLine> get logs => List.unmodifiable(_logs);

  RunPhase _phase = RunPhase.idle;
  RunPhase get phase => _phase;

  RunResult? _result;
  RunResult? get result => _result;

  /// 整个流程的总耗时（各步骤耗时之和，含网络等待）。
  Duration get totalElapsed {
    final r = _result;
    if (r == null) return Duration.zero;
    var total = Duration.zero;
    for (final rec in r.records) {
      total += rec.elapsed;
    }
    return total;
  }

  PluginError? _error;
  PluginError? get error => _error;

  /// 输入表单值（映射到 `input.*` 命名空间）。
  final Map<String, Object?> inputs = {};

  bool _cancelRequested = false;
  bool get isRunning => _phase == RunPhase.running;

  /// 预填声明了默认值的输入项。
  void primeInputs() {
    for (final spec in plugin.manifest.inputs) {
      final d = spec.defaultValue;
      if (d != null && !inputs.containsKey(spec.key)) {
        inputs[spec.key] = d;
      }
    }
  }

  void _log(LogLevel lv, String text, {String? stepId}) {
    _logs.add(LogLine(lv, text, stepId: stepId));
    notifyListeners();
  }

  void clearLogs() {
    _logs.clear();
    notifyListeners();
  }

  void cancel() {
    if (!isRunning) return;
    _cancelRequested = true;
    _log(LogLevel.warn, '用户已取消');
    notifyListeners();
  }

  Future<void> run() async {
    if (isRunning) return;
    _cancelRequested = false;
    _logs.clear();
    _result = null;
    _error = null;
    _phase = RunPhase.running;
    notifyListeners();

    final engine = Engine(
      manifest: plugin.manifest,
      transport: transport,
      responder: responder,
      env: env,
      secrets: secrets,
      // 在步骤边界检查取消标志，避免「点了取消但流程继续跑到结束」
      shouldAbort: () => _cancelRequested,
    );

    try {
      final r = await engine.run(
        inputs,
        onEvent: (e) {
          if (_cancelRequested) return;
          switch (e) {
            case StepStarted(:final stepId, :final type):
              _log(LogLevel.info, '▶ $stepId（${type.name}）', stepId: stepId);
            case StepFinished(
              :final stepId,
              :final status,
              :final elapsed,
              :final message,
            ):
              final ok = status == StepStatus.succeeded;
              _log(
                ok ? LogLevel.ok : LogLevel.warn,
                '${ok ? '✓' : '!'} $stepId '
                '${elapsed.inMilliseconds}ms（${status.name}）'
                '${message == null ? '' : '：$message'}',
                stepId: stepId,
              );
            case UiRequested(:final stepId, :final spec):
              _log(
                LogLevel.info,
                '… $stepId 等待「${spec.label}」',
                stepId: stepId,
              );
          }
        },
      );
      _result = r;
      _phase = switch (r.outcome) {
        RunOutcome.succeeded => RunPhase.succeeded,
        RunOutcome.failed => RunPhase.failed,
        RunOutcome.cancelled => RunPhase.cancelled,
      };
      _error = r.error;
      final err = r.error;
      if (err != null) {
        _log(LogLevel.error, '${err.code}：${err.message}', stepId: err.stepId);
      }
    } on PluginError catch (e) {
      _error = e;
      _phase = _cancelRequested ? RunPhase.cancelled : RunPhase.failed;
      _log(LogLevel.error, '${e.code}：${e.message}', stepId: e.stepId);
    } catch (e) {
      _phase = RunPhase.failed;
      _log(LogLevel.error, '未预期错误：$e');
    } finally {
      notifyListeners();
    }
  }
}
