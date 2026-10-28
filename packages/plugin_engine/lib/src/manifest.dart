/// manifest 模型与结构校验。
///
/// 校验分两层，与上游一致：
/// 1. **结构层**（本文件）：字段是否已知、类型是否正确、枚举是否合法、
///    范围是否越界 —— 对应 `manifest.schema.json` 的
///    `additionalProperties: false` 与各 `type/pattern/min/max/enum`。
/// 2. **语义层**（`semantic.dart`）：step id 引用、模板变量作用域、重复键、
///    webview host 白名单等 schema 表达不了的检查 —— 对应 `validate.py`。
///
/// 两层失败都报 `E_SCHEMA`。
library;

import 'errors.dart';

/// 引擎支持的版本（`engine` 字段的版本范围必须包含它）。
const String engineVersion = '1.7.0';

// ===========================================================================
// 输入
// ===========================================================================

enum InputType { phone, text, password, number, select }

InputType _inputType(String s, String path) => switch (s) {
      'phone' => InputType.phone,
      'text' => InputType.text,
      'password' => InputType.password,
      'number' => InputType.number,
      'select' => InputType.select,
      _ => throw err(ErrorCodes.schema,
          '$path: type 必须是 phone/text/password/number/select，实际 "$s"'),
    };

class Option {
  final String label;
  final String value;
  const Option({required this.label, required this.value});
}

class InputItem {
  final String key;
  final String label;
  final InputType type;
  final bool required;
  final Object? defaultValue;
  final String? placeholder;
  final int? maxLength;
  final int? minLength;
  final String? pattern;
  final List<Option> options;
  final bool sensitive;

  const InputItem({
    required this.key,
    required this.label,
    required this.type,
    this.required = true,
    this.defaultValue,
    this.placeholder,
    this.maxLength,
    this.minLength,
    this.pattern,
    this.options = const [],
    this.sensitive = false,
  });
}

// ===========================================================================
// request
// ===========================================================================

enum ExtractFrom { json, raw, header, regex, binary }

enum ExtractEncoding { ascii, utf8, hex, be32, raw }

class ExtractItem {
  final String name;
  final ExtractFrom from;
  final String? path;
  final String? header;
  final String? pattern;
  final int group;
  final String? tag;
  final int offset;
  final int? length;
  final ExtractEncoding? encoding;
  final bool optional;
  final Object? defaultValue;
  final bool asJson;
  final String? innerPath;

  const ExtractItem({
    required this.name,
    required this.from,
    this.path,
    this.header,
    this.pattern,
    this.group = 1,
    this.tag,
    this.offset = 2,
    this.length,
    this.encoding,
    this.optional = false,
    this.defaultValue,
    this.asJson = false,
    this.innerPath,
  });
}

class AssertSpec {
  final String json;
  final String? equals;
  final String? notEquals;
  final String? contains;
  final String? matches;
  final String? message;
  final bool? isInteger;
  final bool? isNumeric;
  final bool? isEmpty;
  final bool? isNotEmpty;
  final bool? exists;
  final Object? greaterThan;
  final Object? lessThan;
  final String? startsWith;
  final String? endsWith;

  const AssertSpec({
    required this.json,
    this.equals,
    this.notEquals,
    this.contains,
    this.matches,
    this.message,
    this.isInteger,
    this.isNumeric,
    this.isEmpty,
    this.isNotEmpty,
    this.exists,
    this.greaterThan,
    this.lessThan,
    this.startsWith,
    this.endsWith,
  });
}

class RetrySpec {
  final int times;
  final int backoffMs;
  final List<int> on;
  const RetrySpec({
    this.times = 0,
    this.backoffMs = 1000,
    this.on = const [500, 502, 503, 504],
  });
}

enum BodyType { json, form, text, hex }

/// 请求体（schema `$defs.body`）。四种 type 的字段名统一为 `value`。
class BodySpec {
  final BodyType type;
  final Object? value;
  const BodySpec({required this.type, required this.value});
}

class RequestSpec {
  final String method;
  final String url;
  final Map<String, String> headers;
  final Map<String, String> query;
  final BodySpec? body;
  final int timeoutMs;
  final RetrySpec retry;
  final bool followRedirects;

  const RequestSpec({
    required this.method,
    required this.url,
    this.headers = const {},
    this.query = const {},
    this.body,
    this.timeoutMs = 20000,
    this.retry = const RetrySpec(),
    this.followRedirects = true,
  });
}

// ===========================================================================
// poll / ui / set
// ===========================================================================

class PollSpec {
  /// 要重复执行的 step id（1..5 个，§7.1）。
  final List<String> steps;
  final String until;
  final int intervalMs;

  /// 1..60，必需。
  final int maxAttempts;

  /// 达到 maxAttempts 仍未满足时的处理（message 或 goto，互斥）。
  final OnFail onTimeout;

  const PollSpec({
    required this.steps,
    required this.until,
    this.intervalMs = 1000,
    required this.maxAttempts,
    required this.onTimeout,
  });
}

enum UiType { text, image, confirm, select, webview }

class UiOption {
  final String value;
  final String label;
  const UiOption({required this.value, required this.label});
}

/// `ui` 对象（schema `$defs.uiStep.properties.ui`）。
/// 必填：type / label / input。各 type 的专属字段互斥由 allOf 约束。
class UiSpec {
  final UiType type;

  /// 界面标题（必填）。
  final String label;

  /// 写入 input 命名空间的键（必填，`^[a-zA-Z_][a-zA-Z0-9_]*$`）。
  final String input;

  /// 提示文案（可含模板）。
  final String? hint;

  /// text 专属：最大长度（webview/select 不适用）。
  final int? maxLength;

  /// text 专属：正则（webview/select 不适用）。
  final String? pattern;

  /// 可选：强制掩码 / 强制明文；省略时由宿主按键名判定。
  final bool? obscure;

  /// image 必填。
  final String? image;

  /// 仅 image 可用。
  final String? refreshStep;

  /// select 必填。
  final List<UiOption> options;

  /// webview：url 与 html 二选一；给了 html 则 baseUrl 必填。
  final String? url;
  final String? html;
  final String? baseUrl;
  final Map<String, String> bridge;

  /// confirm 专属（schema 中若存在）。
  final String? confirmText;

  const UiSpec({
    required this.type,
    required this.label,
    required this.input,
    this.hint,
    this.maxLength,
    this.pattern,
    this.obscure,
    this.image,
    this.refreshStep,
    this.options = const [],
    this.url,
    this.html,
    this.baseUrl,
    this.bridge = const {},
    this.confirmText,
  });
}

class JsSpec {
  final String code;
  final String output;
  final Map<String, String> inputs;
  const JsSpec({required this.code, required this.output, this.inputs = const {}});
}

class SetSpec {
  final Map<String, String> vars;
  final JsSpec? js;
  const SetSpec({this.vars = const {}, this.js});
}

// ===========================================================================
// 步骤
// ===========================================================================

enum StepType { request, poll, ui, set }

/// `end` 的四种取值（上游 §5.1）。
enum StepEnd { none, ok, error, cancelled }

// §5.1 终态映射：
//   true        -> ok        succeeded，渲染 output
//   false/缺省  -> none      不终止，继续下一步
//   "error"     -> error     failed，但仍渲染 output（E_END）
//   "cancelled" -> cancelled cancelled，不渲染 output


/// 分支项：`when` 求值通过则跳 `goto`。
class BranchItem {
  final String when;
  final String goto;
  const BranchItem({required this.when, required this.goto});
}

/// 失败处理（上游 §6.7）：`message` 与 `goto` 互斥。
class OnFail {
  final String? message;
  final String? goto;
  const OnFail({this.message, this.goto});
}

/// 所有步骤的公共字段（上游 §5）。
abstract class StepBase {
  final String id;
  final String? when;
  final String? goto;
  final List<BranchItem> branch;
  final OnFail? onFail;
  final StepEnd end;

  const StepBase({
    required this.id,
    this.when,
    this.goto,
    this.branch = const [],
    this.onFail,
    this.end = StepEnd.none,
  });

  /// 步骤类型，用于 StepRecord / UI 展示。
  StepType get type;
}

/// `type: "request"`（上游 §6）。
class RequestStep extends StepBase {
  final RequestSpec request;
  final List<ExtractItem> extract;
  final AssertSpec? assertSpec;

  const RequestStep({
    required super.id,
    super.when,
    super.goto,
    super.branch,
    super.onFail,
    super.end,
    required this.request,
    this.extract = const [],
    this.assertSpec,
  });

  @override
  StepType get type => StepType.request;
}

/// `type: "poll"`（上游 §7.1）：重复执行子步骤直到 `until` 为真。
class PollStep extends StepBase {
  final PollSpec poll;
  const PollStep({
    required super.id,
    super.when,
    super.goto,
    super.branch,
    super.onFail,
    super.end,
    required this.poll,
  });

  @override
  StepType get type => StepType.poll;
}

/// `type: "ui"`（上游 §7.2/§7.3）。
class UiStep extends StepBase {
  final UiSpec ui;
  const UiStep({
    required super.id,
    super.when,
    super.goto,
    super.branch,
    super.onFail,
    super.end,
    required this.ui,
  });

  @override
  StepType get type => StepType.ui;
}

/// `type: "set"`（上游 §7.4）：声明式 vars，可选 set.js。
class SetStep extends StepBase {
  final SetSpec set;
  const SetStep({
    required super.id,
    super.when,
    super.goto,
    super.branch,
    super.onFail,
    super.end,
    required this.set,
  });

  @override
  StepType get type => StepType.set;
}

class OutputField {
  final String label;
  final String value;
  final bool copyable;
  final bool sensitive;
  final bool multiline;
  const OutputField({
    required this.label,
    required this.value,
    this.copyable = true,
    this.sensitive = false,
    this.multiline = false,
  });
}

class OutputSpec {
  final String title;
  final List<OutputField> fields;
  const OutputSpec({required this.title, required this.fields});
}

class Hooks {
  final List<String> libs;
  final int timeoutMs;
  final int memoryLimitMb;
  const Hooks({this.libs = const [], this.timeoutMs = 5000, this.memoryLimitMb = 16});
}

/// 一份解析完成的插件 manifest。
class Manifest {
  final String id;
  final String name;
  final String version;
  final String engine;
  final String? author;
  final String? description;
  final List<String> allowHosts;
  final bool allowInsecureLocalhost;
  final List<InputItem> inputs;
  final Map<String, Object?> vars;
  final List<String> secrets;
  final List<StepBase> flow;
  final OutputSpec output;
  final Hooks hooks;

  const Manifest({
    required this.id,
    required this.name,
    required this.version,
    required this.engine,
    this.author,
    this.description,
    required this.allowHosts,
    this.allowInsecureLocalhost = false,
    required this.inputs,
    this.vars = const {},
    this.secrets = const [],
    required this.flow,
    required this.output,
    this.hooks = const Hooks(),
  });

  StepBase? stepById(String id) {
    for (final s in flow) {
      if (s.id == id) return s;
    }
    return null;
  }
}

// ===========================================================================
// 解析器
// ===========================================================================

/// 把 JSON map 解析为 [Manifest]；结构不符一律 `E_SCHEMA`。
Manifest parseManifest(Map<String, Object?> json) => _ManifestParser().parse(json);

class _ManifestParser {
  static const _rootKeys = {
    'id', 'name', 'version', 'engine', 'author', 'description', 'allowHosts',
    'allowInsecureLocalhost', 'inputs', 'vars', 'secrets', 'flow', 'output', 'hooks',
  };

  Manifest parse(Map<String, Object?> j) {
    _rejectUnknown(j, _rootKeys, r'$');

    final id = _reqStr(j, 'id', r'$');
    if (!RegExp(r'^[a-z0-9]+(\.[a-z0-9]+)+$').hasMatch(id)) {
      throw err(ErrorCodes.schema,
          r'$.id: 必须至少两段小写点分（如 demo.hello），实际 "' + id + '"');
    }
    final name = _reqStr(j, 'name', r'$');
    if (name.isEmpty || name.length > 64) {
      throw err(ErrorCodes.schema, r'$.name: 长度必须在 1..64，实际 ${name.length}');
    }
    final version = _reqStr(j, 'version', r'$');
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version)) {
      throw err(ErrorCodes.schema, r'$.version: 必须形如 1.0.0，实际 "' + version + '"');
    }
    final engine = _reqStr(j, 'engine', r'$');
    _checkEngine(engine);

    final author = _optStr(j, 'author', r'$');
    if (author != null && author.length > 128) {
      throw err(ErrorCodes.schema, r'$.author: 最长 128 字符');
    }
    final description = _optStr(j, 'description', r'$');
    if (description != null && description.length > 512) {
      throw err(ErrorCodes.schema, r'$.description: 最长 512 字符');
    }

    final allowHosts = _parseAllowHosts(j);
    final allowInsecureLocalhost = _optBool(j, 'allowInsecureLocalhost', r'$') ?? false;
    final inputs = _parseInputs(j);
    final vars = _parseVars(j);
    final secrets = _parseSecrets(j);
    final flow = _parseFlow(j);
    final output = _parseOutput(j);
    final hooks = _parseHooks(j);

    return Manifest(
      id: id,
      name: name,
      version: version,
      engine: engine,
      author: author,
      description: description,
      allowHosts: allowHosts,
      allowInsecureLocalhost: allowInsecureLocalhost,
      inputs: inputs,
      vars: vars,
      secrets: secrets,
      flow: flow,
      output: output,
      hooks: hooks,
    );
  }

  // ---- 顶层 ----

  void _checkEngine(String range) {
    // 上游格式形如 ">=1.0 <2.0"。支持 >= > <= < == 与空格分隔多条件（AND）。
    final parts = range.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty);
    final current = _parseVersion(engineVersion);
    for (final p in parts) {
      final m = RegExp(r'^(>=|<=|==|>|<)?\s*(\d+\.\d+(?:\.\d+)?)$').firstMatch(p);
      if (m == null) {
        throw err(ErrorCodes.schema,
            r'$.engine: 无法解析版本约束 "' + p + r'"（形如 ">=1.0 <2.0"）');
      }
      final op = m[1] ?? '==';
      final want = _parseVersion(m[2]!);
      final cmp = _compareVersion(current, want);
      final ok = switch (op) {
        '>=' => cmp >= 0,
        '>' => cmp > 0,
        '<=' => cmp <= 0,
        '<' => cmp < 0,
        '==' => cmp == 0,
        _ => false,
      };
      if (!ok) {
        throw err(ErrorCodes.engine,
            '插件要求引擎 $range，当前引擎 $engineVersion 不满足');
      }
    }
  }

  static List<int> _parseVersion(String s) {
    final parts = s.split('.');
    final out = [0, 0, 0];
    for (var i = 0; i < parts.length && i < 3; i++) {
      out[i] = int.tryParse(parts[i]) ?? 0;
    }
    return out;
  }

  static int _compareVersion(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return 0;
  }

  List<String> _parseAllowHosts(Map<String, Object?> j) {
    if (!j.containsKey('allowHosts')) {
      throw err(ErrorCodes.schema, r'$: 缺少必填字段 allowHosts');
    }
    final raw = j['allowHosts'];
    if (raw is! List) {
      throw err(ErrorCodes.schema, r'$.allowHosts: 必须是数组');
    }
    if (raw.isEmpty) {
      throw err(ErrorCodes.schema, r'$.allowHosts: 不能为空数组');
    }
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final v = raw[i];
      if (v is! String || v.isEmpty) {
        throw err(ErrorCodes.schema, '\$.allowHosts[$i]: 必须是非空字符串');
      }
      if (v.contains('://') || v.contains('/')) {
        throw err(
            ErrorCodes.schema, '\$.allowHosts[$i]: 只写 host 或 host:port，不要带协议或路径（"$v"）');
      }
      out.add(v.toLowerCase());
    }
    return out;
  }

  List<InputItem> _parseInputs(Map<String, Object?> j) {
    if (!j.containsKey('inputs')) {
      throw err(ErrorCodes.schema, r'$: 缺少必填字段 inputs');
    }
    final raw = j['inputs'];
    if (raw is! List) throw err(ErrorCodes.schema, r'$.inputs: 必须是数组');
    final out = <InputItem>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final path = '\$.inputs[$i]';
      final m = raw[i];
      if (m is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
      final map = m.cast<String, Object?>();
      _rejectUnknown(
          map,
          {
            'key', 'label', 'type', 'required', 'default', 'placeholder',
            'maxLength', 'minLength', 'pattern', 'options', 'sensitive',
          },
          path);
      final key = _reqStr(map, 'key', path);
      if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(key)) {
        throw err(ErrorCodes.schema, '$path.key: 必须是合法标识符，实际 "$key"');
      }
      if (!seen.add(key)) {
        throw err(ErrorCodes.schema, '$path.key: 重复的 input key "$key"');
      }
      final label = _reqStr(map, 'label', path);
      if (label.isEmpty) throw err(ErrorCodes.schema, '$path.label: 不能为空');
      final type = _inputType(_reqStr(map, 'type', path), '$path.type');
      final required = _optBool(map, 'required', path) ?? true;
      final def = map['default'];
      if (def != null && def is! String && def is! num) {
        throw err(ErrorCodes.schema, '$path.default: 只允许 string 或 number');
      }
      final placeholder = _optStr(map, 'placeholder', path);
      final maxLength = _optInt(map, 'maxLength', path);
      final minLength = _optInt(map, 'minLength', path);
      final pattern = _optStr(map, 'pattern', path);
      if (pattern != null) {
        try {
          RegExp(pattern);
        } on FormatException catch (e) {
          throw err(ErrorCodes.schema, '$path.pattern: 正则无法编译：${e.message}');
        }
      }
      if (minLength != null && maxLength != null && minLength > maxLength) {
        throw err(ErrorCodes.schema,
            '$path: minLength($minLength) > maxLength($maxLength)');
      }
      final options = _parseOptions(map, path, type);
      final sensitive = _optBool(map, 'sensitive', path) ?? false;

      out.add(InputItem(
        key: key,
        label: label,
        type: type,
        required: required,
        defaultValue: def,
        placeholder: placeholder,
        maxLength: maxLength,
        minLength: minLength,
        pattern: pattern,
        options: options,
        sensitive: sensitive,
      ));
    }
    return out;
  }

  List<Option> _parseOptions(Map<String, Object?> map, String path, InputType type) {
    if (!map.containsKey('options')) {
      if (type == InputType.select) {
        throw err(ErrorCodes.schema, '$path: type=select 时 options 必需');
      }
      return const [];
    }
    if (type != InputType.select) {
      throw err(ErrorCodes.schema, '$path: options 只能用于 type=select');
    }
    final raw = map['options'];
    if (raw is! List) throw err(ErrorCodes.schema, '$path.options: 必须是数组');
    if (raw.isEmpty) throw err(ErrorCodes.schema, '$path.options: 不能为空');
    final out = <Option>[];
    for (var i = 0; i < raw.length; i++) {
      final p = '$path.options[$i]';
      final o = raw[i];
      if (o is! Map) throw err(ErrorCodes.schema, '$p: 必须是对象');
      final om = o.cast<String, Object?>();
      _rejectUnknown(om, {'label', 'value'}, p);
      out.add(Option(
        label: _reqStr(om, 'label', p),
        value: _reqStr(om, 'value', p),
      ));
    }
    return out;
  }

  Map<String, Object?> _parseVars(Map<String, Object?> j) {
    if (!j.containsKey('vars')) return const {};
    final raw = j['vars'];
    if (raw is! Map) throw err(ErrorCodes.schema, r'$.vars: 必须是对象');
    final out = <String, Object?>{};
    for (final e in raw.entries) {
      final k = '${e.key}';
      if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(k)) {
        throw err(ErrorCodes.schema, '\$.vars.$k: 键必须是合法标识符');
      }
      final v = e.value;
      if (v != null && v is! String && v is! num && v is! bool) {
        throw err(ErrorCodes.schema, '\$.vars.$k: 值只允许 string/number/bool/null');
      }
      out[k] = v;
    }
    return out;
  }

  List<String> _parseSecrets(Map<String, Object?> j) {
    if (!j.containsKey('secrets')) return const [];
    final raw = j['secrets'];
    if (raw is! List) throw err(ErrorCodes.schema, r'$.secrets: 必须是数组');
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final v = raw[i];
      if (v is! String || !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(v)) {
        throw err(ErrorCodes.schema, '\$.secrets[$i]: 必须是合法标识符');
      }
      if (out.contains(v)) {
        throw err(ErrorCodes.schema, '\$.secrets[$i]: 重复的 secret "$v"');
      }
      out.add(v);
    }
    return out;
  }

  List<StepBase> _parseFlow(Map<String, Object?> j) {
    if (!j.containsKey('flow')) {
      throw err(ErrorCodes.schema, r'$: 缺少必填字段 flow');
    }
    final raw = j['flow'];
    if (raw is! List) throw err(ErrorCodes.schema, r'$.flow: 必须是数组');
    if (raw.isEmpty) throw err(ErrorCodes.schema, r'$.flow: 不能为空数组');
    final out = <StepBase>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final step = _parseStep(raw[i], r'$.flow[' '$i]');
      if (!seen.add(step.id)) {
        throw err(ErrorCodes.schema, '\$.flow[$i].id: 重复的 step id "${step.id}"');
      }
      out.add(step);
    }
    return out;
  }

  static const _stepCommonKeys = {
    'id', 'type', 'when', 'goto', 'branch', 'onFail', 'end',
  };
  static const _typeSpecific = {
    StepType.request: {'request', 'extract', 'assert'},
    StepType.poll: {'poll'},
    StepType.ui: {'ui'},
    StepType.set: {'set'},
  };

  StepBase _parseStep(Object? raw, String path) {
    if (raw is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
    final m = raw.cast<String, Object?>();

    final typeStr = _reqStr(m, 'type', path);
    final type = switch (typeStr) {
      'request' => StepType.request,
      'poll' => StepType.poll,
      'ui' => StepType.ui,
      'set' => StepType.set,
      _ => throw err(
          ErrorCodes.schema, '$path.type: 必须是 request/poll/ui/set，实际 "$typeStr"'),
    };

    final allowed = {..._stepCommonKeys, ..._typeSpecific[type]!};
    _rejectUnknown(m, allowed, path);

    final id = _reqStr(m, 'id', path);
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(id)) {
      throw err(ErrorCodes.schema, '$path.id: 必须匹配 ^[A-Za-z_][A-Za-z0-9_]*\$，实际 "$id"');
    }
    if (id == 'next') {
      throw err(ErrorCodes.schema, '$path.id: "next" 是保留字，不能用作 step id');
    }

    final when = _optStr(m, 'when', path);
    final gotoTarget = _parseGoto(m, path);
    final branch = _parseBranch(m, path);
    final onFail = _parseOnFail(m, path);
    final end = _parseEnd(m, path);

    RequestSpec? request;
    List<ExtractItem> extract = const [];
    AssertSpec? assertSpec;
    PollSpec? poll;
    UiSpec? ui;
    SetSpec? set;

    switch (type) {
      case StepType.request:
        if (!m.containsKey('request')) {
          throw err(ErrorCodes.schema, '$path: type=request 时 request 必需');
        }
        request = _parseRequest(m['request'], '$path.request');
        extract = _parseExtract(m, path);
        assertSpec = _parseAssert(m, path);
      case StepType.poll:
        if (!m.containsKey('poll')) {
          throw err(ErrorCodes.schema, '$path: type=poll 时 poll 必需');
        }
        poll = _parsePoll(m['poll'], '$path.poll');
      case StepType.ui:
        if (!m.containsKey('ui')) {
          throw err(ErrorCodes.schema, '$path: type=ui 时 ui 必需');
        }
        ui = _parseUi(m['ui'], '$path.ui');
      case StepType.set:
        if (!m.containsKey('set')) {
          throw err(ErrorCodes.schema, '$path: type=set 时 set 必需');
        }
        set = _parseSet(m['set'], '$path.set');
    }

    return switch (type) {
      StepType.request => RequestStep(
          id: id,
          when: when,
          goto: gotoTarget,
          branch: branch,
          onFail: onFail,
          end: end,
          request: request!,
          extract: extract,
          assertSpec: assertSpec,
        ),
      StepType.poll => PollStep(
          id: id,
          when: when,
          goto: gotoTarget,
          branch: branch,
          onFail: onFail,
          end: end,
          poll: poll!,
        ),
      StepType.ui => UiStep(
          id: id,
          when: when,
          goto: gotoTarget,
          branch: branch,
          onFail: onFail,
          end: end,
          ui: ui!,
        ),
      StepType.set => SetStep(
          id: id,
          when: when,
          goto: gotoTarget,
          branch: branch,
          onFail: onFail,
          end: end,
          set: set!,
        ),
    };
  }

  String? _parseGoto(Map<String, Object?> m, String path) {
    if (!m.containsKey('goto')) return null;
    final v = m['goto'];
    if (v is! String || v.isEmpty) {
      throw err(ErrorCodes.schema, '$path.goto: 必须是非空字符串');
    }
    return v;
  }

  List<BranchItem> _parseBranch(Map<String, Object?> m, String path) {
    if (!m.containsKey('branch')) return const [];
    final raw = m['branch'];
    if (raw is! List) throw err(ErrorCodes.schema, '$path.branch: 必须是数组');
    final out = <BranchItem>[];
    for (var i = 0; i < raw.length; i++) {
      final p = '$path.branch[$i]';
      final b = raw[i];
      if (b is! Map) throw err(ErrorCodes.schema, '$p: 必须是对象');
      final bm = b.cast<String, Object?>();
      _rejectUnknown(bm, {'when', 'goto'}, p);
      out.add(BranchItem(
        when: _reqStr(bm, 'when', p),
        goto: _reqStr(bm, 'goto', p),
      ));
    }
    return out;
  }

  OnFail? _parseOnFail(Map<String, Object?> m, String path) {
    if (!m.containsKey('onFail')) return null;
    return _parseOnFailMap(m['onFail'], '$path.onFail');
  }

  /// `onFail` / `onTimeout` 共用结构：message 与 goto 互斥且至少给一个。
  OnFail _parseOnFailMap(Object? raw, String path) {
    if (raw is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
    final om = raw.cast<String, Object?>();
    _rejectUnknown(om, {'message', 'goto'}, path);
    final message = _optStr(om, 'message', path);
    final goto = _optStr(om, 'goto', path);
    if (message != null && goto != null) {
      throw err(ErrorCodes.schema, '$path: message 与 goto 互斥（§4.6）');
    }
    if (message == null && goto == null) {
      throw err(ErrorCodes.schema, '$path: message 与 goto 至少给一个');
    }
    return OnFail(message: message, goto: goto);
  }

  /// `end`：`true | false | "error" | "cancelled"`（schema anyOf，§5.1）。
  StepEnd _parseEnd(Map<String, Object?> m, String path) {
    if (!m.containsKey('end')) return StepEnd.none;
    final v = m['end'];
    if (v is bool) return v ? StepEnd.ok : StepEnd.none;
    if (v is! String) {
      throw err(ErrorCodes.schema,
          '$path.end: 必须是布尔或 "error"/"cancelled"');
    }
    return switch (v) {
      'error' => StepEnd.error,
      'cancelled' => StepEnd.cancelled,
      _ => throw err(ErrorCodes.schema,
          r'$path.end: 取值非法 "'
          '$v' r'"（只允许 true / false / "error" / "cancelled"）'),
    };
  }

  RequestSpec _parseRequest(Object? raw, String path) {
    if (raw is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
    final m = raw.cast<String, Object?>();
    _rejectUnknown(
        m,
        {'method', 'url', 'headers', 'query', 'body', 'timeoutMs', 'retry',
         'followRedirects'},
        path);

    final method = _reqStr(m, 'method', path);
    if (!const {'GET', 'POST', 'PUT', 'PATCH', 'DELETE'}.contains(method)) {
      throw err(ErrorCodes.schema,
          '$path.method: 必须是 GET/POST/PUT/PATCH/DELETE，实际 "$method"');
    }
    final url = _reqStr(m, 'url', path);
    final headers = _parseStrMap(m, 'headers', path);
    final query = _parseStrMap(m, 'query', path);

    BodySpec? body;
    if (m.containsKey('body')) {
      if (method == 'GET') {
        throw err(ErrorCodes.schema, '$path.body: GET 请求禁止出现 body（§4.2）');
      }
      body = _parseBody(m['body'], '$path.body');
    }

    final timeoutMs = _optInt(m, 'timeoutMs', path) ?? 20000;
    if (timeoutMs < 1 || timeoutMs > 120000) {
      throw err(ErrorCodes.schema, '$path.timeoutMs: 范围 1..120000，实际 $timeoutMs');
    }
    final followRedirects = _optBool(m, 'followRedirects', path) ?? true;
    final retry = _parseRetry(m, path);

    return RequestSpec(
      method: method,
      url: url,
      headers: headers,
      query: query,
      body: body,
      timeoutMs: timeoutMs,
      retry: retry,
      followRedirects: followRedirects,
    );
  }

  RetrySpec _parseRetry(Map<String, Object?> m, String path) {
    if (!m.containsKey('retry')) return const RetrySpec();
    final p = '$path.retry';
    final raw = m['retry'];
    if (raw is! Map) throw err(ErrorCodes.schema, '$p: 必须是对象');
    final rm = raw.cast<String, Object?>();
    _rejectUnknown(rm, {'times', 'backoffMs', 'on'}, p);
    final times = _optInt(rm, 'times', p) ?? 0;
    if (times < 0 || times > 5) {
      throw err(ErrorCodes.schema, '$p.times: 范围 0..5，实际 $times');
    }
    final backoffMs = _optInt(rm, 'backoffMs', p) ?? 1000;
    if (backoffMs < 0 || backoffMs > 60000) {
      throw err(ErrorCodes.schema, '$p.backoffMs: 范围 0..60000，实际 $backoffMs');
    }
    var on = const [500, 502, 503, 504];
    if (rm.containsKey('on')) {
      final rawOn = rm['on'];
      if (rawOn is! List) throw err(ErrorCodes.schema, '$p.on: 必须是数组');
      final list = <int>[];
      for (var i = 0; i < rawOn.length; i++) {
        final v = rawOn[i];
        if (v is! int || v < 100 || v > 599) {
          throw err(ErrorCodes.schema, '$p.on[$i]: 必须是 100..599 的整数');
        }
        list.add(v);
      }
      on = list;
    }
    return RetrySpec(times: times, backoffMs: backoffMs, on: on);
  }

  BodySpec _parseBody(Object? raw, String path) {
    if (raw is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
    final m = raw.cast<String, Object?>();
    _rejectUnknown(m, {'type', 'value'}, path);
    final typeStr = _reqStr(m, 'type', path);
    final type = switch (typeStr) {
      'json' => BodyType.json,
      'form' => BodyType.form,
      'text' => BodyType.text,
      'hex' => BodyType.hex,
      _ => throw err(
          ErrorCodes.schema, '$path.type: 必须是 json/form/text/hex，实际 "$typeStr"'),
    };
    if (!m.containsKey('value')) {
      throw err(ErrorCodes.schema, '$path.value: 必需');
    }
    final data = m['value'];
    if (data == null) {
      throw err(ErrorCodes.schema, '$path.value: 不能为 null');
    }
    switch (type) {
      case BodyType.json:
      case BodyType.form:
        if (data is Map) {
          for (final e in data.entries) {
            if (e.value is Map || e.value is List) {
              // 允许嵌套（json），form 由执行器扁平化
              if (type == BodyType.form) {
                throw err(ErrorCodes.schema,
                    '$path.data.${e.key}: form 的值必须是标量（string/number/bool）');
              }
            }
          }
        } else if (data is! String) {
          throw err(ErrorCodes.schema,
              '$path.data: type=$typeStr 时 data 必须是对象或模板字符串');
        }
      case BodyType.text:
        if (data is! String) {
          throw err(ErrorCodes.schema, '$path.data: type=text 时 data 必须是模板字符串');
        }
      case BodyType.hex:
        if (data is! String) {
          throw err(ErrorCodes.schema, '$path.data: type=hex 时 data 必须是 hex 模板字符串');
        }
    }
    return BodySpec(type: type, value: data);
  }

  Map<String, String> _parseStrMap(Map<String, Object?> m, String key, String path) {
    if (!m.containsKey(key)) return const {};
    final raw = m[key];
    if (raw is! Map) throw err(ErrorCodes.schema, '$path.$key: 必须是对象');
    final out = <String, String>{};
    for (final e in raw.entries) {
      final v = e.value;
      if (v is! String) {
        throw err(ErrorCodes.schema, '$path.$key.${e.key}: 值必须是模板字符串');
      }
      out['${e.key}'] = v;
    }
    return out;
  }

  List<ExtractItem> _parseExtract(Map<String, Object?> m, String path) {
    if (!m.containsKey('extract')) return const [];
    final raw = m['extract'];
    if (raw is! List) throw err(ErrorCodes.schema, '$path.extract: 必须是数组');
    final out = <ExtractItem>[];
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final p = '$path.extract[$i]';
      final e = raw[i];
      if (e is! Map) throw err(ErrorCodes.schema, '$p: 必须是对象');
      final em = e.cast<String, Object?>();
      _rejectUnknown(
          em,
          {'name', 'from', 'path', 'header', 'pattern', 'group', 'tag', 'offset',
           'length', 'encoding', 'optional', 'default', 'asJson', 'innerPath'},
          p);
      final name = _reqStr(em, 'name', p);
      if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(name)) {
        throw err(ErrorCodes.schema, '$p.name: 必须是合法标识符，实际 "$name"');
      }
      if (!seen.add(name)) {
        throw err(ErrorCodes.schema, '$p.name: 同一步骤内重复的 extract name "$name"');
      }
      final fromStr = _reqStr(em, 'from', p);
      final from = switch (fromStr) {
        'json' => ExtractFrom.json,
        'raw' => ExtractFrom.raw,
        'header' => ExtractFrom.header,
        'regex' => ExtractFrom.regex,
        'binary' => ExtractFrom.binary,
        _ => throw err(ErrorCodes.schema,
            '$p.from: 必须是 json/raw/header/regex/binary，实际 "$fromStr"'),
      };

      final jsonPath = _optStr(em, 'path', p);
      final header = _optStr(em, 'header', p);
      final pattern = _optStr(em, 'pattern', p);
      final group = _optInt(em, 'group', p) ?? 1;
      final tag = _optStr(em, 'tag', p);
      final offset = _optInt(em, 'offset', p) ?? 2;
      final length = _optInt(em, 'length', p);
      final optional = _optBool(em, 'optional', p) ?? false;
      final def = em['default'];
      final asJson = _optBool(em, 'asJson', p) ?? false;
      final innerPath = _optStr(em, 'innerPath', p);

      ExtractEncoding? encoding;
      if (em.containsKey('encoding')) {
        final es = _reqStr(em, 'encoding', p);
        encoding = switch (es) {
          'ascii' => ExtractEncoding.ascii,
          'utf8' => ExtractEncoding.utf8,
          'hex' => ExtractEncoding.hex,
          'be32' => ExtractEncoding.be32,
          'raw' => ExtractEncoding.raw,
          _ => throw err(ErrorCodes.schema,
              '$p.encoding: 必须是 ascii/utf8/hex/be32/raw，实际 "$es"'),
        };
      }

      // 每种的必需配套字段
      switch (from) {
        case ExtractFrom.json:
          if (jsonPath == null) {
            throw err(ErrorCodes.schema, '$p: from=json 时 path 必需');
          }
          _checkJsonPath(jsonPath, '$p.path');
        case ExtractFrom.header:
          if (header == null) {
            throw err(ErrorCodes.schema, '$p: from=header 时 header 必需');
          }
          if (header.trim() != header || RegExp(r'\s').hasMatch(header)) {
            throw err(ErrorCodes.schema, '$p.header: 响应头名不能含空白字符');
          }
        case ExtractFrom.regex:
          if (pattern == null) {
            throw err(ErrorCodes.schema, '$p: from=regex 时 pattern 必需');
          }
          try {
            RegExp(pattern);
          } on FormatException catch (e) {
            throw err(ErrorCodes.schema, '$p.pattern: 正则无法编译：${e.message}');
          }
          if (group < 0) throw err(ErrorCodes.schema, '$p.group: 不能为负');
        case ExtractFrom.binary:
          if (tag == null) throw err(ErrorCodes.schema, '$p: from=binary 时 tag 必需');
          if (!RegExp(r'^[0-9a-fA-F]*$').hasMatch(tag) || tag.length.isOdd) {
            throw err(ErrorCodes.schema,
                '$p.tag: 必须是偶数长度的 hex 字符串（可以是空串）');
          }
          if (offset < 0) throw err(ErrorCodes.schema, '$p.offset: 不能为负');
          if (length != null && length < 0) {
            throw err(ErrorCodes.schema, '$p.length: 不能为负');
          }
        case ExtractFrom.raw:
          break;
      }
      if (encoding != null && from != ExtractFrom.binary) {
        throw err(ErrorCodes.schema, '$p.encoding: 只用于 from=binary');
      }
      if (encoding != null && length == null) {
        throw err(ErrorCodes.schema, '$p.length: from=binary 且指定 encoding 时 length 必需');
      }
      if (asJson && innerPath != null) {
        throw err(ErrorCodes.schema, '$p: asJson 与 innerPath 互斥');
      }

      out.add(ExtractItem(
        name: name,
        from: from,
        path: jsonPath,
        header: header,
        pattern: pattern,
        group: group,
        tag: tag,
        offset: offset,
        length: length,
        encoding: encoding,
        optional: optional,
        defaultValue: def,
        asJson: asJson,
        innerPath: innerPath,
      ));
    }
    return out;
  }

  void _checkJsonPath(String p, String path) {
    if (!p.startsWith(r'$')) {
      throw err(ErrorCodes.schema, '$path: JSONPath 必须以 \$ 开头，实际 "$p"');
    }
    // 支持 $.a.b / $["a"] / $[0] / $[*]
    final valid = RegExp(r'^\$(\.[A-Za-z_][A-Za-z0-9_]*|\[(\d+|\*|"[^"]*")])*$');
    if (!valid.hasMatch(p)) {
      throw err(ErrorCodes.schema,
          '$path: 不支持的 JSONPath 语法 "$p"（支持 \$.a.b、\$[0]、\$[*]、\$["k"]）');
    }
  }

  AssertSpec? _parseAssert(Map<String, Object?> m, String path) {
    if (!m.containsKey('assert')) return null;
    final p = '$path.assert';
    final raw = m['assert'];
    if (raw is! Map) throw err(ErrorCodes.schema, '$p: 必须是对象');
    final am = raw.cast<String, Object?>();
    _rejectUnknown(
        am,
        {'json', 'equals', 'notEquals', 'contains', 'matches', 'message',
         'isInteger', 'isNumeric', 'isEmpty', 'isNotEmpty', 'exists',
         'greaterThan', 'lessThan', 'startsWith', 'endsWith'},
        p);
    final json = _reqStr(am, 'json', p);
    _checkJsonPath(json, '$p.json');

    String? optTmpl(String key) {
      if (!am.containsKey(key)) return null;
      final v = am[key];
      if (v is! String) {
        throw err(ErrorCodes.schema, '$p.$key: 必须是模板字符串');
      }
      return v;
    }

    final matches = optTmpl('matches');
    if (matches != null) {
      try {
        RegExp(matches);
      } on FormatException catch (e) {
        throw err(ErrorCodes.schema, '$p.matches: 正则无法编译：${e.message}');
      }
    }

    final spec = AssertSpec(
      json: json,
      equals: optTmpl('equals'),
      notEquals: optTmpl('notEquals'),
      contains: optTmpl('contains'),
      matches: matches,
      message: optTmpl('message'),
      isInteger: _optBool(am, 'isInteger', p),
      isNumeric: _optBool(am, 'isNumeric', p),
      isEmpty: _optBool(am, 'isEmpty', p),
      isNotEmpty: _optBool(am, 'isNotEmpty', p),
      exists: _optBool(am, 'exists', p),
      greaterThan: am['greaterThan'],
      lessThan: am['lessThan'],
      startsWith: optTmpl('startsWith'),
      endsWith: optTmpl('endsWith'),
    );

    final opCount = [
      spec.equals, spec.notEquals, spec.contains, spec.matches,
      spec.isInteger, spec.isNumeric, spec.isEmpty, spec.isNotEmpty,
      spec.exists, spec.greaterThan, spec.lessThan, spec.startsWith, spec.endsWith,
    ].where((e) => e != null).length;
    if (opCount == 0) {
      throw err(ErrorCodes.schema, '$p: 至少要有一个断言操作符');
    }
    return spec;
  }

  PollSpec _parsePoll(Object? raw, String path) {
    if (raw is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
    final m = raw.cast<String, Object?>();
    _rejectUnknown(
        m, {'steps', 'until', 'intervalMs', 'maxAttempts', 'onTimeout'}, path);

    // steps：被重复执行的 step id 列表（1..5 个字符串，§7.1）
    final rawSteps = m['steps'];
    if (rawSteps is! List) {
      throw err(ErrorCodes.schema, '$path.steps: 必须是数组');
    }
    if (rawSteps.isEmpty || rawSteps.length > 5) {
      throw err(
          ErrorCodes.schema, '$path.steps: 长度必须在 1..5，实际 ${rawSteps.length}');
    }
    final steps = <String>[];
    for (var i = 0; i < rawSteps.length; i++) {
      final v = rawSteps[i];
      if (v is! String || v.isEmpty) {
        throw err(ErrorCodes.schema, '$path.steps[$i]: 必须是 step id 字符串');
      }
      if (steps.contains(v)) {
        throw err(ErrorCodes.schema, '$path.steps[$i]: 重复引用 "$v"');
      }
      steps.add(v);
    }

    final until = _reqStr(m, 'until', path);

    final intervalMs = _optInt(m, 'intervalMs', path) ?? 1000;
    if (intervalMs < 100 || intervalMs > 60000) {
      throw err(
          ErrorCodes.schema, '$path.intervalMs: 范围 100..60000，实际 $intervalMs');
    }

    if (!m.containsKey('maxAttempts')) {
      throw err(ErrorCodes.schema, '$path: 缺少必填字段 maxAttempts');
    }
    final maxAttempts = _optInt(m, 'maxAttempts', path)!;
    if (maxAttempts < 1 || maxAttempts > 60) {
      throw err(
          ErrorCodes.schema, '$path.maxAttempts: 范围 1..60，实际 $maxAttempts');
    }

    if (!m.containsKey('onTimeout')) {
      throw err(ErrorCodes.schema, '$path: 缺少必填字段 onTimeout');
    }
    final onTimeout = _parseOnFailMap(m['onTimeout'], '$path.onTimeout');

    return PollSpec(
      steps: steps,
      until: until,
      intervalMs: intervalMs,
      maxAttempts: maxAttempts,
      onTimeout: onTimeout,
    );
  }

  UiSpec _parseUi(Object? raw, String path) {
    if (raw is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
    final m = raw.cast<String, Object?>();
    _rejectUnknown(
        m,
        {
          'type', 'label', 'input', 'hint', 'maxLength', 'pattern', 'obscure',
          'image', 'refreshStep', 'options', 'url', 'html', 'baseUrl', 'bridge',
          'confirmText',
        },
        path);

    final typeStr = _reqStr(m, 'type', path);
    final type = switch (typeStr) {
      'text' => UiType.text,
      'image' => UiType.image,
      'confirm' => UiType.confirm,
      'select' => UiType.select,
      'webview' => UiType.webview,
      _ => throw err(ErrorCodes.schema,
          '$path.type: 必须是 text/image/confirm/select/webview，实际 "$typeStr"'),
    };

    // 三个必填字段
    if (!m.containsKey('label')) {
      throw err(ErrorCodes.schema, '$path: 缺少必填字段 label');
    }
    final label = _reqStr(m, 'label', path);
    if (!m.containsKey('input')) {
      throw err(ErrorCodes.schema, '$path: 缺少必填字段 input');
    }
    final input = _reqStr(m, 'input', path);
    if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(input)) {
      throw err(ErrorCodes.schema,
          '$path.input: 必须是合法标识符（^[a-zA-Z_][a-zA-Z0-9_]*\$），实际 "$input"');
    }

    final hint = _optStr(m, 'hint', path);
    final maxLength = _optInt(m, 'maxLength', path);
    if (maxLength != null && maxLength < 1) {
      throw err(ErrorCodes.schema, '$path.maxLength: 必须 >= 1');
    }
    final pattern = _optStr(m, 'pattern', path);
    if (pattern != null && pattern.isEmpty) {
      throw err(ErrorCodes.schema, '$path.pattern: 不能为空串');
    }
    final obscure = m['obscure'] as bool?;
    if (m.containsKey('obscure') && m['obscure'] is! bool) {
      throw err(ErrorCodes.schema, '$path.obscure: 必须是布尔');
    }
    final image = _optStr(m, 'image', path);
    final refreshStep = _optStr(m, 'refreshStep', path);
    final url = _optStr(m, 'url', path);
    final html = _optStr(m, 'html', path);
    final baseUrl = _optStr(m, 'baseUrl', path);
    final bridge = _parseStrMap(m, 'bridge', path);
    final confirmText = _optStr(m, 'confirmText', path);

    // select 的 options
    final options = <UiOption>[];
    if (m.containsKey('options')) {
      final rawOpts = m['options'];
      if (rawOpts is! List) {
        throw err(ErrorCodes.schema, '$path.options: 必须是数组');
      }
      for (var i = 0; i < rawOpts.length; i++) {
        final o = rawOpts[i];
        if (o is! Map) {
          throw err(ErrorCodes.schema, '$path.options[$i]: 必须是对象');
        }
        final om = o.cast<String, Object?>();
        _rejectUnknown(om, {'value', 'label'}, '$path.options[$i]');
        options.add(UiOption(
          value: _reqStr(om, 'value', '$path.options[$i]'),
          label: _reqStr(om, 'label', '$path.options[$i]'),
        ));
      }
    }

    void forbid(List<String> keys, String why) {
      for (final k in keys) {
        if (m.containsKey(k)) {
          throw err(ErrorCodes.schema, '$path.$k: 不适用于 $why');
        }
      }
    }

    switch (type) {
      case UiType.image:
        if (image == null) {
          throw err(ErrorCodes.schema, '$path.image: type=image 时必需');
        }
        forbid(['url', 'html', 'baseUrl', 'bridge', 'options', 'confirmText'],
            'type=image');
      case UiType.webview:
        // url 与 html 二选一；html 时必须给 baseUrl
        if (url == null && html == null) {
          throw err(ErrorCodes.schema, '$path: type=webview 需要 url 或 html 之一');
        }
        if (url != null && html != null) {
          throw err(ErrorCodes.schema, '$path: url 与 html 只能二选一');
        }
        if (html != null && baseUrl == null) {
          throw err(ErrorCodes.schema, '$path.baseUrl: 给了 html 时必需');
        }
        forbid(['image', 'refreshStep', 'maxLength', 'pattern', 'options',
                'confirmText'], 'type=webview');
      case UiType.select:
        if (options.isEmpty) {
          throw err(ErrorCodes.schema, '$path.options: type=select 时必需');
        }
        forbid(['maxLength', 'pattern', 'image', 'refreshStep', 'url', 'html',
                'baseUrl', 'bridge', 'confirmText'], 'type=select');
      case UiType.text:
      case UiType.confirm:
        forbid(['url', 'html', 'baseUrl', 'bridge', 'options'],
            'type=$typeStr');
        if (type == UiType.confirm) {
          forbid(['image', 'refreshStep'], 'type=confirm');
        }
    }

    // refreshStep 仅 image 可用（schema: else not required refreshStep）
    if (type != UiType.image && refreshStep != null) {
      throw err(ErrorCodes.schema, '$path.refreshStep: 只能用于 type=image');
    }

    return UiSpec(
      type: type,
      label: label,
      input: input,
      hint: hint,
      maxLength: maxLength,
      pattern: pattern,
      obscure: obscure,
      image: image,
      refreshStep: refreshStep,
      options: options,
      url: url,
      html: html,
      baseUrl: baseUrl,
      bridge: bridge,
      confirmText: confirmText,
    );
  }

  SetSpec _parseSet(Object? raw, String path) {
    if (raw is! Map) throw err(ErrorCodes.schema, '$path: 必须是对象');
    final m = raw.cast<String, Object?>();
    _rejectUnknown(m, {'vars', 'js'}, path);

    final vars = <String, String>{};
    if (m.containsKey('vars')) {
      final rawVars = m['vars'];
      if (rawVars is! Map) throw err(ErrorCodes.schema, '$path.vars: 必须是对象');
      for (final e in rawVars.entries) {
        final k = '${e.key}';
        if (!RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(k)) {
          throw err(ErrorCodes.schema, '$path.vars.$k: 键必须是合法标识符');
        }
        final v = e.value;
        if (v is! String) {
          throw err(ErrorCodes.schema, '$path.vars.$k: 值必须是模板字符串');
        }
        vars[k] = v;
      }
    }

    JsSpec? js;
    if (m.containsKey('js')) {
      final rawJs = m['js'];
      if (rawJs is! Map) throw err(ErrorCodes.schema, '$path.js: 必须是对象');
      final jm = rawJs.cast<String, Object?>();
      _rejectUnknown(jm, {'code', 'output', 'inputs'}, '$path.js');
      final code = _reqStr(jm, 'code', '$path.js');
      if (code.isEmpty || code.length > 20000) {
        throw err(ErrorCodes.schema,
            '$path.js.code: 长度必须在 1..20000，实际 ${code.length}');
      }
      final output = _reqStr(jm, 'output', '$path.js');
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(output) ||
          output.length > 64) {
        throw err(ErrorCodes.schema,
            '$path.js.output: 必须匹配 ^[A-Za-z_][A-Za-z0-9_]*\$ 且 ≤64 字符，实际 "$output"');
      }
      final inputs = <String, String>{};
      if (jm.containsKey('inputs')) {
        final rawIn = jm['inputs'];
        if (rawIn is! Map) throw err(ErrorCodes.schema, '$path.js.inputs: 必须是对象');
        if (rawIn.length > 32) {
          throw err(ErrorCodes.schema, '$path.js.inputs: 最多 32 个键');
        }
        for (final e in rawIn.entries) {
          final k = '${e.key}';
          if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(k)) {
            throw err(ErrorCodes.schema,
                '$path.js.inputs.$k: 键必须是合法 JS 标识符');
          }
          if (k == 'fn' || k.startsWith('__sj_') || k == '__wireToBytes' ||
              k == '__bytesToWire') {
            throw err(ErrorCodes.schema,
                '$path.js.inputs.$k: 保留名，不能作为 inputs 键（§9.2）');
          }
          final v = e.value;
          if (v is! String) {
            throw err(ErrorCodes.schema, '$path.js.inputs.$k: 值必须是模板字符串');
          }
          inputs[k] = v;
        }
      }
      js = JsSpec(code: code, output: output, inputs: inputs);
    }

    if (vars.isEmpty && js == null) {
      throw err(ErrorCodes.schema, '$path: set 步骤必须至少含 vars 或 js');
    }
    return SetSpec(vars: vars, js: js);
  }

  OutputSpec _parseOutput(Map<String, Object?> j) {
    if (!j.containsKey('output')) {
      throw err(ErrorCodes.schema, r'$: 缺少必填字段 output');
    }
    final raw = j['output'];
    if (raw is! Map) throw err(ErrorCodes.schema, r'$.output: 必须是对象');
    final m = raw.cast<String, Object?>();
    _rejectUnknown(m, {'title', 'fields'}, r'$.output');
    final title = _reqStr(m, 'title', r'$.output');
    if (title.isEmpty) throw err(ErrorCodes.schema, r'$.output.title: 不能为空');

    final rawFields = m['fields'];
    if (rawFields is! List) throw err(ErrorCodes.schema, r'$.output.fields: 必须是数组');
    if (rawFields.isEmpty || rawFields.length > 32) {
      throw err(ErrorCodes.schema,
          r'$.output.fields: 长度必须在 1..32，实际 ${rawFields.length}');
    }
    final fields = <OutputField>[];
    for (var i = 0; i < rawFields.length; i++) {
      final p = '\$.output.fields[$i]';
      final f = rawFields[i];
      if (f is! Map) throw err(ErrorCodes.schema, '$p: 必须是对象');
      final fm = f.cast<String, Object?>();
      _rejectUnknown(fm, {'label', 'value', 'copyable', 'sensitive', 'multiline'}, p);
      final label = _reqStr(fm, 'label', p);
      if (label.isEmpty) throw err(ErrorCodes.schema, '$p.label: 不能为空');
      fields.add(OutputField(
        label: label,
        value: _reqStr(fm, 'value', p),
        copyable: _optBool(fm, 'copyable', p) ?? true,
        sensitive: _optBool(fm, 'sensitive', p) ?? false,
        multiline: _optBool(fm, 'multiline', p) ?? false,
      ));
    }
    return OutputSpec(title: title, fields: fields);
  }

  Hooks _parseHooks(Map<String, Object?> j) {
    if (!j.containsKey('hooks') || j['hooks'] == null) return const Hooks();
    final raw = j['hooks'];
    if (raw is! Map) throw err(ErrorCodes.schema, r'$.hooks: 必须是对象或 null');
    final m = raw.cast<String, Object?>();
    _rejectUnknown(m, {'libs', 'timeoutMs', 'memoryLimitMb'}, r'$.hooks');

    var libs = const <String>[];
    if (m.containsKey('libs')) {
      final rawLibs = m['libs'];
      if (rawLibs is! List) throw err(ErrorCodes.schema, r'$.hooks.libs: 必须是数组');
      final list = <String>[];
      for (var i = 0; i < rawLibs.length; i++) {
        final v = rawLibs[i];
        if (v != 'forge@1.4.0') {
          throw err(ErrorCodes.schema,
              '\$.hooks.libs[$i]: 只支持 "forge@1.4.0"，实际 "$v"');
        }
        list.add(v);
      }
      libs = list;
    }
    final timeoutMs = _optInt(m, 'timeoutMs', r'$.hooks') ?? 5000;
    if (timeoutMs < 100 || timeoutMs > 60000) {
      throw err(
          ErrorCodes.schema, '\$.hooks.timeoutMs: 范围 100..60000，实际 $timeoutMs');
    }
    final memoryLimitMb = _optInt(m, 'memoryLimitMb', r'$.hooks') ?? 16;
    if (memoryLimitMb < 1 || memoryLimitMb > 256) {
      throw err(ErrorCodes.schema,
          '\$.hooks.memoryLimitMb: 范围 1..256，实际 $memoryLimitMb');
    }
    return Hooks(libs: libs, timeoutMs: timeoutMs, memoryLimitMb: memoryLimitMb);
  }

  // ---- 小工具 ----

  void _rejectUnknown(Map<String, Object?> m, Set<String> allowed, String path) {
    for (final k in m.keys) {
      if (!allowed.contains(k)) {
        final hint = _closestKey(k, allowed);
        throw err(ErrorCodes.schema,
            '$path: 未知字段 "$k"${hint == null ? '' : '（是否想写 "$hint"？）'}');
      }
    }
  }

  String _reqStr(Map<String, Object?> m, String key, String path) {
    if (!m.containsKey(key)) {
      throw err(ErrorCodes.schema, '$path: 缺少必填字段 $key');
    }
    final v = m[key];
    if (v is! String) {
      throw err(ErrorCodes.schema, '$path.$key: 必须是字符串，实际 ${_jtype(v)}');
    }
    return v;
  }

  String? _optStr(Map<String, Object?> m, String key, String path) {
    if (!m.containsKey(key)) return null;
    final v = m[key];
    if (v is! String) {
      throw err(ErrorCodes.schema, '$path.$key: 必须是字符串，实际 ${_jtype(v)}');
    }
    return v;
  }

  int? _optInt(Map<String, Object?> m, String key, String path) {
    if (!m.containsKey(key)) return null;
    final v = m[key];
    if (v is! int) {
      throw err(ErrorCodes.schema, '$path.$key: 必须是整数，实际 ${_jtype(v)}');
    }
    return v;
  }

  bool? _optBool(Map<String, Object?> m, String key, String path) {
    if (!m.containsKey(key)) return null;
    final v = m[key];
    if (v is! bool) {
      throw err(ErrorCodes.schema, '$path.$key: 必须是布尔值，实际 ${_jtype(v)}');
    }
    return v;
  }

  String _jtype(Object? v) {
    if (v == null) return 'null';
    if (v is String) return 'string';
    if (v is bool) return 'bool';
    if (v is int) return 'int';
    if (v is double) return 'number';
    if (v is List) return 'array';
    if (v is Map) return 'object';
    return v.runtimeType.toString();
  }

  String? _closestKey(String k, Set<String> allowed) {
    String? best;
    var bestD = 1 << 30;
    for (final c in allowed) {
      final d = _editDistance(k.toLowerCase(), c.toLowerCase());
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return bestD <= 2 ? best : null;
  }
}

int _editDistance(String a, String b) {
  final m = a.length, n = b.length;
  var prev = List<int>.generate(n + 1, (i) => i);
  var cur = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    cur[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[n];
}
