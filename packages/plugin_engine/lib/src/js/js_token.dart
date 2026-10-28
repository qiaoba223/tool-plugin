/// set.js 沙箱的词法分析器。
///
/// 只覆盖规范 §12 承诺的 ES5 子集：不做模板字符串、装饰器、可选链等语法。
/// 关键字集合刻意保持最小——除这里列出的词，其余一律按标识符处理，
/// 这样 `of`、`let`、`async` 之类可以合法地当变量名（老式 JS 代码常见）。
library;

import '../errors.dart';

enum TokType {
  num,
  str,
  ident,
  keyword,
  punct,
  eof,
}

class Token {
  final TokType type;
  final String text;
  final num? numValue;
  final int line;
  final int col;

  const Token(this.type, this.text, this.line, this.col, {this.numValue});

  bool isPunct(String p) => type == TokType.punct && text == p;
  bool isKw(String k) => type == TokType.keyword && text == k;

  @override
  String toString() => '$type($text)@$line:$col';
}

/// ES5 保留字（含字面量 null/true/false）。
const Set<String> jsKeywords = {
  'var', 'function', 'return', 'if', 'else', 'while', 'for', 'do', 'break',
  'continue', 'new', 'typeof', 'instanceof', 'in', 'try', 'catch', 'finally',
  'throw', 'delete', 'this', 'null', 'true', 'false', 'void',
  // 保留但本实现不支持，命中时给出明确报错而不是当成变量
  'switch', 'case', 'default', 'class', 'const', 'let', 'extends', 'super',
  'import', 'export', 'yield', 'with', 'debugger',
};

/// 多字符运算符按长度降序排列，保证最长匹配。
const List<String> _puncts = [
  '>>>=', '===', '!==', '>>>', '<<=', '>>=',
  '==', '!=', '<=', '>=', '&&', '||', '++', '--', '<<', '>>',
  '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=',
  '{', '}', '(', ')', '[', ']', ';', ',', '<', '>', '+', '-', '*', '/', '%',
  '&', '|', '^', '!', '~', '?', ':', '.', '=',
];

List<Token> tokenize(String src) {
  final out = <Token>[];
  var i = 0;
  var line = 1;
  var lineStart = 0;

  int col(int pos) => pos - lineStart + 1;

  Never fail(String msg, int pos) {
    throw PluginError(
      ErrorCodes.js,
      'JS 语法错误（第 $line 行第 ${col(pos)} 列）：$msg',
    );
  }

  while (i < src.length) {
    final c = src[i];

    // 空白
    if (c == ' ' || c == '\t' || c == '\r' || c == '\u000b' || c == '\f') {
      i++;
      continue;
    }
    if (c == '\n') {
      i++;
      line++;
      lineStart = i;
      continue;
    }

    // 注释
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      final startLine = line;
      i += 2;
      var closed = false;
      while (i + 1 < src.length) {
        if (src[i] == '*' && src[i + 1] == '/') {
          i += 2;
          closed = true;
          break;
        }
        if (src[i] == '\n') {
          line++;
          lineStart = i + 1;
        }
        i++;
      }
      if (!closed) fail('块注释未闭合（起始于第 $startLine 行）', i);
      continue;
    }

    // 数字：十进制 / 0x / 0o / 0b / 小数 / 指数
    if (_isDigit(c) || (c == '.' && i + 1 < src.length && _isDigit(src[i + 1]))) {
      final start = i;
      num? value;
      if (c == '0' && i + 1 < src.length && (src[i + 1] == 'x' || src[i + 1] == 'X')) {
        i += 2;
        final s = i;
        while (i < src.length && _isHex(src[i])) {
          i++;
        }
        if (i == s) fail('十六进制字面量缺少数字', start);
        value = int.parse(src.substring(s, i), radix: 16);
      } else if (c == '0' && i + 1 < src.length && (src[i + 1] == 'o' || src[i + 1] == 'O')) {
        i += 2;
        final s = i;
        while (i < src.length && '01234567'.contains(src[i])) {
          i++;
        }
        if (i == s) fail('八进制字面量缺少数字', start);
        value = int.parse(src.substring(s, i), radix: 8);
      } else if (c == '0' && i + 1 < src.length && (src[i + 1] == 'b' || src[i + 1] == 'B')) {
        i += 2;
        final s = i;
        while (i < src.length && (src[i] == '0' || src[i] == '1')) {
          i++;
        }
        if (i == s) fail('二进制字面量缺少数字', start);
        value = int.parse(src.substring(s, i), radix: 2);
      } else {
        while (i < src.length && _isDigit(src[i])) {
          i++;
        }
        if (i < src.length && src[i] == '.') {
          i++;
          while (i < src.length && _isDigit(src[i])) {
            i++;
          }
        }
        if (i < src.length && (src[i] == 'e' || src[i] == 'E')) {
          i++;
          if (i < src.length && (src[i] == '+' || src[i] == '-')) i++;
          final es = i;
          while (i < src.length && _isDigit(src[i])) {
            i++;
          }
          if (i == es) fail('指数部分缺少数字', start);
        }
        final text = src.substring(start, i);
        value = double.tryParse(text);
        if (value == null) fail('无法解析数字 "$text"', start);
      }
      out.add(Token(TokType.num, src.substring(start, i), line, col(start),
          numValue: value));
      continue;
    }

    // 字符串
    if (c == '"' || c == "'") {
      final start = i;
      final quote = c;
      i++;
      final buf = StringBuffer();
      var closed = false;
      while (i < src.length) {
        final ch = src[i];
        if (ch == quote) {
          i++;
          closed = true;
          break;
        }
        if (ch == '\n') fail('字符串未闭合（跨行）', start);
        if (ch == r'\') {
          i++;
          if (i >= src.length) fail('字符串未闭合', start);
          final e = src[i];
          switch (e) {
            case 'n':
              buf.write('\n');
              i++;
            case 't':
              buf.write('\t');
              i++;
            case 'r':
              buf.write('\r');
              i++;
            case 'b':
              buf.write('\b');
              i++;
            case 'f':
              buf.write('\f');
              i++;
            case 'v':
              buf.write('\u000b');
              i++;
            case '0':
              // \0 后若紧跟数字则按八进制处理，否则 NUL
              if (i + 1 < src.length && _isDigit(src[i + 1])) {
                i++;
                var oct = 0;
                var n = 0;
                while (n < 3 && i < src.length && '01234567'.contains(src[i])) {
                  oct = oct * 8 + int.parse(src[i]);
                  i++;
                  n++;
                }
                buf.writeCharCode(oct);
              } else {
                buf.write('\u0000');
                i++;
              }
            case 'x':
              if (i + 2 >= src.length ||
                  !_isHex(src[i + 1]) ||
                  !_isHex(src[i + 2])) {
                fail(r'\x 转义需要两位十六进制', i);
              }
              buf.writeCharCode(int.parse(src.substring(i + 1, i + 3), radix: 16));
              i += 3;
            case 'u':
              if (i + 4 >= src.length ||
                  !_isHex(src[i + 1]) ||
                  !_isHex(src[i + 2]) ||
                  !_isHex(src[i + 3]) ||
                  !_isHex(src[i + 4])) {
                fail(r'\u 转义需要四位十六进制', i);
              }
              buf.writeCharCode(int.parse(src.substring(i + 1, i + 5), radix: 16));
              i += 5;
            default:
              buf.write(e);
              i++;
          }
          continue;
        }
        buf.write(ch);
        i++;
      }
      if (!closed) fail('字符串未闭合', start);
      out.add(Token(TokType.str, buf.toString(), line, col(start)));
      continue;
    }

    // 标识符 / 关键字
    if (_isIdentStart(c)) {
      final start = i;
      while (i < src.length && _isIdentPart(src[i])) {
        i++;
      }
      final word = src.substring(start, i);
      out.add(Token(
        jsKeywords.contains(word) ? TokType.keyword : TokType.ident,
        word,
        line,
        col(start),
      ));
      continue;
    }

    // 标点 / 运算符（最长匹配）
    var matched = false;
    for (final p in _puncts) {
      if (src.startsWith(p, i)) {
        out.add(Token(TokType.punct, p, line, col(i)));
        i += p.length;
        matched = true;
        break;
      }
    }
    if (matched) continue;

    fail('无法识别的字符 "$c"', i);
  }

  out.add(Token(TokType.eof, '<eof>', line, col(i)));
  return out;
}

bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

bool _isHex(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x30 && u <= 0x39) ||
      (u >= 0x41 && u <= 0x46) ||
      (u >= 0x61 && u <= 0x66);
}

bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5A) ||
      (u >= 0x61 && u <= 0x7A) ||
      c == r'$' ||
      c == '_' ||
      u > 0x7F; // 允许非 ASCII 标识符
}

bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);
