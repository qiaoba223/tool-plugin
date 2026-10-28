/// assert 断言（对应上游 §6.5，13 个操作符）。
library;

import 'dart:convert';

import 'errors.dart';
import 'extractor.dart';
import 'manifest.dart';
import 'template.dart';
import 'values.dart';

/// 断言求值器。`json` 是必填的 JSONPath，其余操作符可选组合，全部通过才算通过。
void runAssert(
  AssertSpec spec,
  ResponseView resp,
  TemplateEngine tmpl,
  Scope scope,
  String? stepId,
) {
  final parsed = _decodeJson(resp.bodyText);
  Object? actual;
  try {
    actual = jsonPath(parsed, spec.json);
  } catch (e) {
    // exists=false 时「取不到」本身就是期望结果
    if (spec.exists == false) return;
    throw PluginError(ErrorCodes.assertFail,
        '断言失败：JSONPath "${spec.json}" 不存在', stepId: stepId);
  }

  void fail(String what) {
    final msg = spec.message;
    throw PluginError(
      ErrorCodes.assertFail,
      msg != null && msg.isNotEmpty
          ? msg
          : '断言失败：${spec.json} $what（实际值：${_preview(actual)}）',
      stepId: stepId,
      detail: {'path': spec.json, 'actual': _preview(actual)},
    );
  }

  Object? tpl(Object? v) => v is String ? tmpl.render(v, scope) : v;

  if (spec.exists == true && actual == null) fail('不存在');
  if (spec.exists == false) fail('意外存在');

  if (spec.equals != null && !valuesEqual(actual, tpl(spec.equals))) {
    fail('不等于 ${_preview(tpl(spec.equals))}');
  }
  if (spec.notEquals != null && valuesEqual(actual, tpl(spec.notEquals))) {
    fail('等于了不该等于的 ${_preview(tpl(spec.notEquals))}');
  }
  if (spec.contains != null &&
      !renderValue(actual).contains(renderValue(tpl(spec.contains)))) {
    fail('不包含 ${_preview(tpl(spec.contains))}');
  }
  if (spec.matches != null) {
    final re = RegExp(spec.matches!);
    if (!re.hasMatch(renderValue(actual))) fail('不匹配正则 ${spec.matches}');
  }
  if (spec.startsWith != null &&
      !renderValue(actual).startsWith(renderValue(tpl(spec.startsWith)))) {
    fail('不以 ${_preview(tpl(spec.startsWith))} 开头');
  }
  if (spec.endsWith != null &&
      !renderValue(actual).endsWith(renderValue(tpl(spec.endsWith)))) {
    fail('不以 ${_preview(tpl(spec.endsWith))} 结尾');
  }

  if (spec.isInteger == true && actual is! int) fail('不是整数');
  if (spec.isNumeric == true && actual is! num) fail('不是数字');

  if (spec.isEmpty == true) {
    final empty = actual == null ||
        (actual is String && actual.isEmpty) ||
        (actual is List && actual.isEmpty) ||
        (actual is Map && actual.isEmpty);
    if (!empty) fail('不为空');
  }
  if (spec.isNotEmpty == true) {
    final empty = actual == null ||
        (actual is String && actual.isEmpty) ||
        (actual is List && actual.isEmpty) ||
        (actual is Map && actual.isEmpty);
    if (empty) fail('为空了');
  }

  if (spec.greaterThan != null) {
    final bound = spec.greaterThan;
    final boundValue =
        bound is num ? bound : num.tryParse(renderValue(tpl(bound)));
    if (boundValue == null) {
      throw PluginError(ErrorCodes.arg,
          'greaterThan 必须是数字，实际是 ${_preview(bound)}', stepId: stepId);
    }
    if (actual is! num) fail('不是数字，无法比较');
    if ((actual as num) <= boundValue) fail('不大于 $boundValue');
  }
  if (spec.lessThan != null) {
    final bound = spec.lessThan;
    final boundValue =
        bound is num ? bound : num.tryParse(renderValue(tpl(bound)));
    if (boundValue == null) {
      throw PluginError(ErrorCodes.arg,
          'lessThan 必须是数字，实际是 ${_preview(bound)}', stepId: stepId);
    }
    if (actual is! num) fail('不是数字，无法比较');
    if ((actual as num) >= boundValue) fail('不小于 $boundValue');
  }
}

Object? _decodeJson(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    throw err(ErrorCodes.assertFail, '断言对象不是合法 JSON');
  }
}

String _preview(Object? v) {
  final s = v is String ? v : renderValue(v);
  if (s.length <= 80) return '"$s"';
  return '"${s.substring(0, 77)}..."';
}
