/// 错误码与统一错误对象（对应上游 docs/PLUGIN_JSON_GUIDE.md 附录 A）。
library;

/// 16 个错误码，逐一对应上游附录 A。
class ErrorCodes {
  static const schema = 'E_SCHEMA';
  static const engine = 'E_ENGINE';
  static const template = 'E_TEMPLATE';
  static const undef = 'E_UNDEF';
  static const type = 'E_TYPE';
  static const arg = 'E_ARG';
  static const goto = 'E_GOTO';
  static const host = 'E_HOST';
  static const insecure = 'E_INSECURE';
  static const http = 'E_HTTP';
  static const timeout = 'E_TIMEOUT';
  static const extract = 'E_EXTRACT';
  static const assertFail = 'E_ASSERT';
  static const loop = 'E_LOOP';
  static const end = 'E_END';
  static const js = 'E_JS';
  static const pkgFormat = 'E_PKG_FORMAT';
}

/// 引擎统一异常。字段与上游「错误对象统一携带 code/message/stepId/detail」一致。
class PluginError implements Exception {
  final String code;
  final String message;

  /// 出错步骤 id（若有）。
  final String? stepId;

  /// 结构化补充。
  final Map<String, Object?>? detail;

  const PluginError(this.code, this.message, {this.stepId, this.detail});

  PluginError withStep(String? id) =>
      stepId == id ? this : PluginError(code, message, stepId: id, detail: detail);

  @override
  String toString() {
    final buf = StringBuffer('$code: $message');
    if (stepId != null) buf.write('（步骤 $stepId）');
    return buf.toString();
  }
}

/// 便捷构造。
PluginError err(String code, String message,
        {String? stepId, Map<String, Object?>? detail}) =>
    PluginError(code, message, stepId: stepId, detail: detail);
