/// 表达式词法分析器。
///
/// 与上游 `schema/validate.py` 的 `TOKEN_RE` **逐字一致**（这是唯一可对照的上游
/// 实现，因为引擎源码未开源）：
///
/// ```python
/// (?P<ws>\s+)
/// | (?P<op>\|\||&&|==|!=|>=|<=|>|<|!|\(|\)|,|\.|\[|\])
/// | (?P<num>-?\d+(?:\.\d+)?)
/// | (?P<str>'[^']*')
/// | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
/// ```
library;

import 'errors.dart';

enum TokKind { ws, op, num, str, ident, eof }

class Token {
  final TokKind kind;
  final String text;
  final int pos;
  const Token(this.kind, this.text, this.pos);

  @override
  String toString() => '${kind.name}($text)@$pos';
}

final RegExp _tokenRe = RegExp(
  r'''\s+'''
  r'''|\|\||&&|==|!=|>=|<=|>|<|!|\(|\)|,|\.|\[|\]'''
  r'''|-?\d+(?:\.\d+)?'''
  r"""|'[^']*'"""
  r'''|[A-Za-z_][A-Za-z0-9_]*''',
);

/// 按上游顺序尝试匹配；上游用带命名组的单个正则，先匹配者胜。
/// Dart 无法按 group 名直接得知命中了哪一支，因此逐支判定。
List<Token> tokenize(String src) {
  final toks = <Token>[];
  var i = 0;
  while (i < src.length) {
    final m = _tokenRe.matchAsPrefix(src, i);
    if (m == null) {
      throw err(ErrorCodes.template, '表达式位置 $i 处出现非法字符 ${_repr(src[i])}');
    }
    final text = m.group(0)!;
    final kind = _classify(text);
    if (kind != TokKind.ws) toks.add(Token(kind, text, i));
    i = m.end;
  }
  toks.add(Token(TokKind.eof, '', src.length));
  return toks;
}

TokKind _classify(String t) {
  final c = t.codeUnitAt(0);
  // ws
  if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) return TokKind.ws;
  // str
  if (t.startsWith("'")) return TokKind.str;
  // num：以 - 或数字开头
  if (c == 0x2D || (c >= 0x30 && c <= 0x39)) return TokKind.num;
  // ident：字母或下划线
  if (c == 0x5F || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
    return TokKind.ident;
  }
  return TokKind.op;
}

String _repr(String s) => "'$s'";

/// 上游 `find_templates`：从字符串里取出所有 `{{ ... }}` 模板体。
/// 字面量 `\{\{`（4 个字符）跳过。返回 (模板体列表, 错误列表)。
({List<String> bodies, List<String> errors}) findTemplates(String s) {
  final out = <String>[];
  final errs = <String>[];
  var i = 0;
  final n = s.length;
  while (i < n) {
    if (s.startsWith(r'\{\{', i)) {
      i += 4;
      continue;
    }
    if (s.startsWith('{{', i)) {
      final j = s.indexOf('}}', i + 2);
      if (j < 0) {
        errs.add('位置 $i 处的 \'{{\' 没有对应的 \'}}\'（E_TEMPLATE）');
        break;
      }
      out.add(s.substring(i + 2, j));
      i = j + 2;
      continue;
    }
    i++;
  }
  return (bodies: out, errors: errs);
}
