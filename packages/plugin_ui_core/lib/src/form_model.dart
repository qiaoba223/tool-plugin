/// 输入表单的模型层：校验、默认值、敏感字段判定。
///
/// 从 UI 里抽出这些规则的原因：它们是**契约**（哪些键名算敏感、
/// 校验失败该报什么），必须能被单测覆盖，而不是散落在 widget 里。
library;

import 'package:plugin_engine/plugin_engine.dart';

/// 单个字段的校验错误。
class FieldError {
  const FieldError(this.key, this.message);

  final String key;
  final String message;

  @override
  String toString() => '$key: $message';
}

/// 表单状态：键 → 当前文本值。
class FormModel {
  FormModel(this.inputs, {Map<String, String>? initial})
      : _values = {
          for (final i in inputs)
            i.key: initial?[i.key] ?? _defaultText(i),
        };

  final List<InputItem> inputs;
  final Map<String, String> _values;

  Map<String, String> get values => Map.unmodifiable(_values);

  String valueOf(String key) => _values[key] ?? '';

  void setValue(String key, String value) => _values[key] = value;

  /// 重置为默认值。
  void reset() {
    for (final i in inputs) {
      _values[i.key] = _defaultText(i);
    }
  }

  static String _defaultText(InputItem i) {
    final d = i.defaultValue;
    if (d == null) return '';
    return switch (i.type) {
      InputType.select => _selectDefault(i),
      InputType.number => d.toString(),
      _ => d.toString(),
    };
  }

  /// select 的默认值必须命中 options，否则回落第一项。
  static String _selectDefault(InputItem i) {
    final want = i.defaultValue?.toString() ?? '';
    for (final o in i.options) {
      if (o.value == want) return want;
    }
    return i.options.isNotEmpty ? i.options.first.value : want;
  }

  /// 校验全部字段，返回错误列表（空表示通过）。
  ///
  /// 只有 `required` 的字段缺失才报错；空的可选字段不校验格式。
  List<FieldError> validate() {
    final errors = <FieldError>[];
    for (final i in inputs) {
      final raw = _values[i.key] ?? '';
      final v = raw.trim();

      if (v.isEmpty) {
        if (i.required) {
          errors.add(FieldError(i.key, '请填写${i.label}'));
        }
        continue;
      }

      if (i.minLength != null && v.length < i.minLength!) {
        errors.add(FieldError(i.key, '${i.label}至少 ${i.minLength} 位'));
        continue;
      }
      if (i.maxLength != null && v.length > i.maxLength!) {
        errors.add(FieldError(i.key, '${i.label}最多 ${i.maxLength} 位'));
        continue;
      }
      if (i.type == InputType.phone && !RegExp(r'^1\d{10}$').hasMatch(v)) {
        errors.add(FieldError(i.key, '请输入 11 位手机号'));
        continue;
      }
      if (i.type == InputType.number) {
        if (int.tryParse(v) == null) {
          errors.add(FieldError(i.key, '${i.label}必须是整数'));
          continue;
        }
      }
      if (i.pattern != null && i.pattern!.isNotEmpty) {
        bool ok;
        try {
          ok = RegExp(i.pattern!).hasMatch(v);
        } catch (_) {
          // 插件给了非法正则：不拦用户，交给引擎在请求前报错
          ok = true;
        }
        if (!ok) {
          errors.add(FieldError(i.key, '${i.label}格式不正确'));
          continue;
        }
      }
    }
    return errors;
  }

  /// 校验并返回给引擎的输入命名空间。
  ///
  /// 抛 [FormInvalidException] 时携带全部错误，UI 一次显示完，
  /// 不用让用户改一个提交一次。
  Map<String, Object?> toInputNamespace() {
    final errors = validate();
    if (errors.isNotEmpty) throw FormInvalidException(errors);
    return {
      for (final e in _values.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    };
  }

  /// 日志展示用：敏感字段打码。
  Map<String, Object?> toDisplayNamespace() {
    return {
      for (final e in _values.entries)
        if (e.value.trim().isNotEmpty)
          e.key: isSensitiveKey(e.key) ? maskValue(e.value) : e.value.trim(),
    };
  }

  /// 该字段是否应掩码显示。
  ///
  /// 优先级：显式 `sensitive` > 键名启发式。手机号特殊处理——
  /// 用户需要核对自己输入的号码（输错一位就收不到短信），
  /// 因此**不掩码**，这与原版 v1.0 的行为一致。
  static bool isSensitive(InputItem i) {
    if (i.key.toLowerCase().contains('phone') || i.key.toLowerCase().contains('mobile')) {
      return false;
    }
    if (i.sensitive) return true;
    return isSensitiveKey(i.key);
  }

  static const _sensitiveHints = [
    'password', 'passwd', 'pwd', 'secret', 'token', 'cookie',
    'credential', 'apikey', 'api_key', 'session', 'auth',
  ];

  /// 仅按键名判断（没有 InputItem 上下文时用，如日志）。
  static bool isSensitiveKey(String key) {
    final k = key.toLowerCase();
    for (final h in _sensitiveHints) {
      if (k.contains(h)) return true;
    }
    return false;
  }

  /// 打码：保留首尾，中间用 `*`。短值全掩码。
  static String maskValue(String v) {
    if (v.isEmpty) return v;
    if (v.length <= 4) return '*' * v.length;
    final head = v.substring(0, 2);
    final tail = v.substring(v.length - 2);
    return '$head${'*' * (v.length - 4)}$tail';
  }
}

/// 表单校验失败。
class FormInvalidException implements Exception {
  FormInvalidException(this.errors);

  final List<FieldError> errors;

  String get message => errors.map((e) => e.message).join('；');

  @override
  String toString() => message;
}
