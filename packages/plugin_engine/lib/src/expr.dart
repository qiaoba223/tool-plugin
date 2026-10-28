/// 表达式语法分析器 —— 与上游 `schema/validate.py` 的 `ExprParser` 逐条对齐。
///
/// 语法（上游 §4.2 EBNF）：
/// ```
/// expr    := or
/// or      := and ( "||" and )*
/// and     := cmp ( "&&" cmp )*
/// cmp     := unary ( ("=="|"!="|">="|"<="|">"|"<") unary )?
/// unary   := "!" unary | primary
/// primary := number | string | "true" | "false" | "null"
///          | path | call | "(" expr ")"
/// path    := ident ("." ident | "[" number "]")*
/// call    := ident "." ident "(" (expr ("," expr)*)? ")"
/// ```
library;

import 'errors.dart';
import 'lexer.dart';

sealed class Expr {
  const Expr();
}

class NumLit extends Expr {
  final num value;
  const NumLit(this.value);
}

class StrLit extends Expr {
  final String value;
  const StrLit(this.value);
}

class BoolLit extends Expr {
  final bool value;
  const BoolLit(this.value);
}

class NullLit extends Expr {
  const NullLit();
}

/// 变量路径。`segs` 只含 `.ident` 段（上游解析器丢弃 `[n]` 下标，
/// 仅用于语法校验与重复检查），`raw` 是源码原文。
class PathExpr extends Expr {
  final String raw;
  final List<String> segs;
  const PathExpr(this.raw, this.segs);
}

/// 函数调用：命名空间只有 `fn`。
class CallExpr extends Expr {
  final String ns;
  final String name;
  final List<Expr> args;
  final String raw;
  const CallExpr(this.ns, this.name, this.args, this.raw);
}

class BinExpr extends Expr {
  final String op;
  final Expr left;
  final Expr right;
  const BinExpr(this.op, this.left, this.right);
}

class UnExpr extends Expr {
  final String op;
  final Expr child;
  const UnExpr(this.op, this.child);
}

class ExprParser {
  final String src;
  final List<Token> toks;
  int p = 0;

  ExprParser._(this.src, this.toks);

  /// 解析一段表达式；语法错误统一报 `E_TEMPLATE`。
  static Expr parse(String src) {
    final parser = ExprParser._(src, tokenize(src));
    final node = parser._parseOr();
    if (parser._peek.kind != TokKind.eof) {
      final t = parser._peek;
      throw err(ErrorCodes.template,
          '表达式位置 ${t.pos} 出现多余记号 ${_show(t)}（原文：$src）');
    }
    return node;
  }

  Token get _peek => toks[p];

  bool _at(TokKind kind, [String? value]) =>
      _peek.kind == kind && (value == null || _peek.text == value);

  Token _take() => toks[p++];

  Token _expect(TokKind kind, [String? value]) {
    if (!_at(kind, value)) {
      final t = _peek;
      throw err(ErrorCodes.template,
          '表达式位置 ${t.pos} 期望 ${value ?? kind.name}，实际是 ${_show(t)}（原文：$src）');
    }
    return _take();
  }

  Expr _parseOr() {
    var node = _parseAnd();
    while (_at(TokKind.op, '||')) {
      _take();
      node = BinExpr('||', node, _parseAnd());
    }
    return node;
  }

  Expr _parseAnd() {
    var node = _parseCmp();
    while (_at(TokKind.op, '&&')) {
      _take();
      node = BinExpr('&&', node, _parseCmp());
    }
    return node;
  }

  Expr _parseCmp() {
    final node = _parseUnary();
    if (_at(TokKind.op) &&
        const {'==', '!=', '>=', '<=', '>', '<'}.contains(_peek.text)) {
      final op = _take().text;
      return BinExpr(op, node, _parseUnary());
    }
    return node;
  }

  Expr _parseUnary() {
    if (_at(TokKind.op, '!')) {
      _take();
      return UnExpr('!', _parseUnary());
    }
    return _parsePrimary();
  }

  Expr _parsePrimary() {
    final t = _peek;
    switch (t.kind) {
      case TokKind.num:
        _take();
        return NumLit(t.text.contains('.') ? double.parse(t.text) : int.parse(t.text));
      case TokKind.str:
        _take();
        return StrLit(t.text.substring(1, t.text.length - 1));
      case TokKind.ident:
        if (t.text == 'true') {
          _take();
          return const BoolLit(true);
        }
        if (t.text == 'false') {
          _take();
          return const BoolLit(false);
        }
        if (t.text == 'null') {
          _take();
          return const NullLit();
        }
        return _parsePathOrCall();
      case TokKind.op:
        if (t.text == '(') {
          _take();
          final node = _parseOr();
          _expect(TokKind.op, ')');
          return node;
        }
        throw err(ErrorCodes.template,
            '表达式位置 ${t.pos} 处出现非法记号 ${_show(t)}（原文：$src）');
      case TokKind.eof:
      case TokKind.ws:
        throw err(ErrorCodes.template,
            '表达式位置 ${t.pos} 处出现非法记号 ${_show(t)}（原文：$src）');
    }
  }

  Expr _parsePathOrCall() {
    final start = _peek.pos;
    final first = _take().text;

    // call: ident "." ident "(" ... ")"
    if (_at(TokKind.op, '.') &&
        toks[p + 1].kind == TokKind.ident &&
        toks[p + 2].kind == TokKind.op &&
        toks[p + 2].text == '(') {
      _take(); // .
      final fname = _take().text;
      _take(); // (
      final args = <Expr>[];
      if (!_at(TokKind.op, ')')) {
        args.add(_parseOr());
        while (_at(TokKind.op, ',')) {
          _take();
          args.add(_parseOr());
        }
      }
      _expect(TokKind.op, ')');
      final end = toks[p - 1].pos + 1;
      return CallExpr(first, fname, args, src.substring(start, end));
    }

    // path: ident ("." ident | "[" number "]")*
    final segs = <String>[first];
    while (true) {
      if (_at(TokKind.op, '.') && toks[p + 1].kind == TokKind.ident) {
        _take();
        segs.add(_take().text);
      } else if (_at(TokKind.op, '[')) {
        _take();
        _expect(TokKind.num);
        _expect(TokKind.op, ']');
      } else {
        break;
      }
    }
    final raw = src.substring(start, _peek.pos).trim();
    return PathExpr(raw, segs);
  }

  static String _show(Token t) => t.kind == TokKind.eof ? '输入结束' : "'${t.text}'";
}

/// 先序遍历 AST（对应上游 `walk_expr`）。
void walkExpr(Expr node, bool Function(Expr) visit) {
  if (visit(node) == false) return;
  switch (node) {
    case CallExpr(:final args):
      for (final a in args) {
        walkExpr(a, visit);
      }
    case BinExpr(:final left, :final right):
      walkExpr(left, visit);
      walkExpr(right, visit);
    case UnExpr(:final child):
      walkExpr(child, visit);
    default:
      break;
  }
}
