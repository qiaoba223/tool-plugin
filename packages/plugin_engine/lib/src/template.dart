/// 模板与表达式求值（对应上游第 4 节 + §1.3 五个命名空间）。
library;

import 'dart:typed_data';

import 'errors.dart';
import 'expr.dart';
import 'functions.dart';
import 'lexer.dart';
import 'values.dart';

/// 模板求值时可见的变量区（对应上游 §1.3）：
/// `input.*` / `vars.*` / `steps.<id>.<name>` / `env.*` / `secrets.*`，
/// 以及仅 `onFail` 内可用的 `response.*`。
class Scope {
  final Map<String, Object?> input;
  final Map<String, Object?> vars;
  final Map<String, Map<String, Object?>> steps;
  final Map<String, Object?> env;
  final Map<String, Object?> secrets;

  /// 仅在 onFail 内非 null。
  final Map<String, Object?>? response;

  const Scope({
    required this.input,
    required this.vars,
    required this.steps,
    required this.env,
    required this.secrets,
    this.response,
  });

  Scope copyWith({
    Map<String, Object?>? input,
    Map<String, Object?>? vars,
    Map<String, Map<String, Object?>>? steps,
    Map<String, Object?>? secrets,
    Map<String, Object?>? response,
  }) =>
      Scope(
        input: input ?? this.input,
        vars: vars ?? this.vars,
        steps: steps ?? this.steps,
        env: env,
        secrets: secrets ?? this.secrets,
        response: response ?? this.response,
      );
}

/// 模板渲染器：缓存表达式编译结果。
class TemplateEngine {
  final FnContext ctx;
  final Map<String, Expr> _cache = {};

  TemplateEngine({FnContext? fnContext}) : ctx = fnContext ?? FnContext();

  /// 渲染模板字符串（`{{ ... }}` 替换为求值结果的字符串形式）。
  String render(String template, Scope scope) {
    final found = findTemplates(template);
    final bodies = found.bodies;
    final errs = found.errors;
    if (errs.isNotEmpty) throw err(ErrorCodes.template, errs.first);
    if (bodies.isEmpty) {
      // 无需替换，但仍要还原字面量 \{\{
      return template.replaceAll(r'\{\{', '{{');
    }
    final sb = StringBuffer();
    var i = 0;
    final n = template.length;
    var bodyIndex = 0;
    while (i < n) {
      if (template.startsWith(r'\{\{', i)) {
        sb.write('{{');
        i += 4;
        continue;
      }
      if (template.startsWith('{{', i)) {
        final j = template.indexOf('}}', i + 2);
        if (j < 0) {
          throw err(ErrorCodes.template,
              '位置 $i 处的 \'{{\' 没有对应的 \'}}\'（E_TEMPLATE）');
        }
        final body = bodies[bodyIndex++];
        final value = evaluate(body, scope);
        sb.write(renderValue(value));
        i = j + 2;
        continue;
      }
      sb.write(template[i]);
      i++;
    }
    return sb.toString();
  }

  /// 渲染整个 JSON 树（对应 §6.2 json body 的递归渲染）：
  /// 字符串值按模板处理，非字符串值原样返回。
  Object? renderTree(Object? node, Scope scope) {
    if (node is String) return render(node, scope);
    if (node is List) return [for (final e in node) renderTree(e, scope)];
    if (node is Map) {
      return {for (final e in node.entries) '${e.key}': renderTree(e.value, scope)};
    }
    return node;
  }

  /// 求值一段表达式（不带 `{{ }}`）。
  Object? evaluate(String src, Scope scope) {
    final ast = _compile(src);
    return _eval(ast, scope, src);
  }

  /// 求值一段必须为 bool 的表达式（`when` / `until`）。
  bool evaluateBool(String src, Scope scope, {String? stepId}) {
    final v = evaluate(src, scope);
    if (v is! bool) {
      throw err(ErrorCodes.type,
          '表达式必须求值为 bool，实际是 ${_typeName(v)}（原文：$src）',
          stepId: stepId);
    }
    return v;
  }

  Expr _compile(String src) {
    if (src.isEmpty) {
      throw err(ErrorCodes.template, '模板出现空表达式 {{}}');
    }
    final cached = _cache[src];
    if (cached != null) return cached;
    final ast = ExprParser.parse(src);
    _cache[src] = ast;
    return ast;
  }

  Object? _eval(Expr node, Scope scope, String src) {
    switch (node) {
      case NumLit(:final value):
        return value;
      case StrLit(:final value):
        return value;
      case BoolLit(:final value):
        return value;
      case NullLit():
        return null;

      case PathExpr(:final raw, :final segs):
        return _resolvePath(raw, segs, scope, src);

      case CallExpr(:final ns, :final name, :final args):
        if (ns != 'fn') {
          throw err(ErrorCodes.undef,
              '命名空间 $ns 不存在（只有 fn，原文：$src）');
        }
        final values = [for (final a in args) _eval(a, scope, src)];
        return callFn(name, values, ctx);

      case UnExpr(:final op, :final child):
        final v = _eval(child, scope, src);
        if (v is! bool) {
          throw err(ErrorCodes.type, '运算符 $op 需要 bool，实际是 ${_typeName(v)}（原文：$src）');
        }
        return !v;

      case BinExpr(:final op, :final left, :final right):
        return _evalBin(op, left, right, scope, src);
    }
  }

  Object? _evalBin(
      String op, Expr left, Expr right, Scope scope, String src) {
    // 短路求值
    if (op == '&&' || op == '||') {
      final l = _eval(left, scope, src);
      if (l is! bool) {
        throw err(ErrorCodes.type, '运算符 $op 需要 bool，实际是 ${_typeName(l)}（原文：$src）');
      }
      if (op == '&&' && !l) return false;
      if (op == '||' && l) return true;
      final r = _eval(right, scope, src);
      if (r is! bool) {
        throw err(ErrorCodes.type, '运算符 $op 需要 bool，实际是 ${_typeName(r)}（原文：$src）');
      }
      return r;
    }

    final l = _eval(left, scope, src);
    final r = _eval(right, scope, src);
    switch (op) {
      case '==':
        return valuesEqual(l, r);
      case '!=':
        return valuesNotEqual(l, r);
      case '>':
        return compareForOrder(l, r) > 0;
      case '<':
        return compareForOrder(l, r) < 0;
      case '>=':
        return compareForOrder(l, r) >= 0;
      case '<=':
        return compareForOrder(l, r) <= 0;
      default:
        throw err(ErrorCodes.template, '未知运算符 $op（原文：$src）');
    }
  }

  Object? _resolvePath(
      String raw, List<String> segs, Scope scope, String src) {
    final head = segs.first;
    Object? current;

    switch (head) {
      case 'input':
        current = scope.input;
      case 'vars':
        current = scope.vars;
      case 'steps':
        current = _stepsAsMap(scope.steps);
      case 'env':
        current = scope.env;
      case 'secrets':
        current = scope.secrets;
      case 'response':
        if (scope.response == null) {
          throw err(ErrorCodes.undef,
              'response 命名空间只在 onFail.message 内可用（原文：$src）');
        }
        current = scope.response;
      default:
        throw err(ErrorCodes.undef,
            '未知命名空间 $head（可用：input / vars / steps / env / secrets，原文：$src）');
    }

    for (var i = 1; i < segs.length; i++) {
      final key = segs[i];
      if (current is Map) {
        if (!current.containsKey(key)) {
          throw err(ErrorCodes.undef,
              '路径不存在：$raw（缺少 "$key"，原文：$src）');
        }
        current = current[key];
        continue;
      }
      if (current is List) {
        final idx = int.tryParse(key);
        if (idx == null || idx < 0 || idx >= current.length) {
          throw err(ErrorCodes.undef, '路径不存在：$raw（下标 "$key" 非法，原文：$src）');
        }
        current = current[idx];
        continue;
      }
      throw err(ErrorCodes.undef,
          '路径不存在：$raw（"$key" 前一级不是 map/list，原文：$src）');
    }
    return current;
  }

  Map<String, Object?> _stepsAsMap(Map<String, Map<String, Object?>> steps) {
    // steps.<id>.<name>：segs 是 ['steps', id, name]
    return steps;
  }
}

String _typeName(Object? v) {
  if (v == null) return 'null';
  if (v is Uint8List) return 'bytes';
  if (v is String) return 'string';
  if (v is bool) return 'bool';
  if (v is int) return 'int';
  if (v is double) return 'double';
  if (v is List) return 'list';
  if (v is Map) return 'map';
  return v.runtimeType.toString();
}
