/// set.js 沙箱的语法分析器（递归下降 + 优先级爬升）。
///
/// 支持规范 §12 承诺的 ES5 子集。`switch`/`class`/箭头函数/模板字符串等
/// 不在承诺范围内，命中时抛 E_JS 并给出明确提示，而不是静默误解析。
library;

import '../errors.dart';
import 'js_ast.dart';
import 'js_token.dart';

class JsParser {
  final String source;
  final List<Token> _toks;
  int _pos = 0;

  JsParser(String source)
      : source = source,
        _toks = tokenize(source);

  /// 解析整段脚本，返回语句列表。
  static List<Stmt> parseProgram(String source) => JsParser(source)._program();

  Token get _cur => _toks[_pos];
  Token get _prev => _toks[_pos - 1];

  Token _advance() => _toks[_pos++];

  bool _eatPunct(String p) {
    if (_cur.isPunct(p)) {
      _pos++;
      return true;
    }
    return false;
  }

  bool _eatKw(String k) {
    if (_cur.isKw(k)) {
      _pos++;
      return true;
    }
    return false;
  }

  Never _fail(String msg, [Token? at]) {
    final t = at ?? _cur;
    throw PluginError(
      ErrorCodes.js,
      'JS 语法错误（第 ${t.line} 行第 ${t.col} 列）：$msg'
      '，遇到 ${t.type == TokType.eof ? '输入末尾' : '"${t.text}"'}',
    );
  }

  void _expectPunct(String p) {
    if (!_eatPunct(p)) _fail('期望 "$p"');
  }

  void _expectKw(String k) {
    if (!_eatKw(k)) _fail('期望关键字 "$k"');
  }

  /// 自动分号插入的近似实现：当前是 `}`、EOF，或与上一 token 之间跨行。
  bool _asiAllowed() {
    if (_cur.type == TokType.eof) return true;
    if (_cur.isPunct('}')) return true;
    // 跨行判断：比较行号
    if (_pos > 0 && _cur.line > _prev.line) return true;
    return false;
  }

  void _semicolon() {
    if (_eatPunct(';')) return;
    if (_asiAllowed()) return;
    _fail('期望 ";"');
  }

  // -------------------------------------------------------------------------
  // 语句
  // -------------------------------------------------------------------------

  List<Stmt> _program() {
    final out = <Stmt>[];
    while (_cur.type != TokType.eof) {
      out.add(_statement());
    }
    return out;
  }

  Stmt _statement() {
    final t = _cur;

    if (t.isPunct('{')) return _block();
    if (t.isPunct(';')) {
      _advance();
      return EmptyStmt(t.line);
    }
    if (t.type == TokType.keyword) {
      switch (t.text) {
        case 'var':
          final d = _varDecl();
          _semicolon();
          return d;
        case 'function':
          return _funcDecl();
        case 'if':
          return _ifStmt();
        case 'while':
          return _whileStmt();
        case 'do':
          return _doWhileStmt();
        case 'for':
          return _forStmt();
        case 'return':
          _advance();
          Expr? v;
          if (!_cur.isPunct(';') &&
              !_cur.isPunct('}') &&
              _cur.type != TokType.eof &&
              _cur.line == t.line) {
            v = _expression();
          } else if (!_cur.isPunct(';') &&
              !_cur.isPunct('}') &&
              _cur.type != TokType.eof &&
              _cur.line > t.line) {
            // `return` 后换行 → ASI，返回 undefined
          }
          _semicolon();
          return ReturnStmt(v, t.line);
        case 'break':
          _advance();
          _semicolon();
          return BreakStmt(t.line);
        case 'continue':
          _advance();
          _semicolon();
          return ContinueStmt(t.line);
        case 'throw':
          _advance();
          final e = _expression();
          _semicolon();
          return ThrowStmt(e, t.line);
        case 'try':
          return _tryStmt();
        case 'switch':
          _fail('不支持 switch（规范 §12 只承诺 ES5 基础子集，请改用 if/else）');
        case 'class':
          _fail('不支持 class（请用 function + prototype）');
        case 'const':
        case 'let':
          _fail('不支持 const/let（请用 var）');
        case 'import':
        case 'export':
          _fail('不支持 ES Module 语法');
      }
    }

    // 表达式语句
    final e = _expression();
    _semicolon();
    return ExprStmt(e, t.line);
  }

  Block _block() {
    final line = _cur.line;
    _expectPunct('{');
    final body = <Stmt>[];
    while (!_cur.isPunct('}')) {
      if (_cur.type == TokType.eof) _fail('块未闭合，缺少 "}"');
      body.add(_statement());
    }
    _expectPunct('}');
    return Block(body, line);
  }

  VarDecl _varDecl() {
    final line = _cur.line;
    _expectKw('var');
    final decls = <(String, Expr?)>[];
    do {
      final nameTok = _cur;
      if (nameTok.type != TokType.ident) _fail('期望变量名');
      _advance();
      Expr? init;
      if (_eatPunct('=')) init = _assignment();
      decls.add((nameTok.text, init));
    } while (_eatPunct(','));
    return VarDecl(decls, line);
  }

  FuncDecl _funcDecl() {
    final line = _cur.line;
    _expectKw('function');
    final nameTok = _cur;
    if (nameTok.type != TokType.ident) _fail('函数声明缺少函数名');
    _advance();
    final params = _paramList();
    final body = _block();
    return FuncDecl(
      FuncLit(params, body.body, line, name: nameTok.text),
      line,
    );
  }

  List<String> _paramList() {
    _expectPunct('(');
    final params = <String>[];
    if (!_cur.isPunct(')')) {
      do {
        if (_cur.type != TokType.ident) _fail('期望参数名');
        params.add(_advance().text);
      } while (_eatPunct(','));
    }
    _expectPunct(')');
    return params;
  }

  Stmt _ifStmt() {
    final line = _cur.line;
    _expectKw('if');
    _expectPunct('(');
    final test = _expression();
    _expectPunct(')');
    final cons = _statement();
    Stmt? alt;
    if (_eatKw('else')) alt = _statement();
    return IfStmt(test, cons, line, alternate: alt);
  }

  Stmt _whileStmt() {
    final line = _cur.line;
    _expectKw('while');
    _expectPunct('(');
    final test = _expression();
    _expectPunct(')');
    final body = _statement();
    return WhileStmt(test, body, line);
  }

  Stmt _doWhileStmt() {
    final line = _cur.line;
    _expectKw('do');
    final body = _statement();
    _expectKw('while');
    _expectPunct('(');
    final test = _expression();
    _expectPunct(')');
    _eatPunct(';');
    return DoWhileStmt(body, test, line);
  }

  Stmt _forStmt() {
    final line = _cur.line;
    _expectKw('for');
    _expectPunct('(');

    // for (var k in obj)
    if (_cur.isKw('var')) {
      final save = _pos;
      _advance();
      if (_cur.type == TokType.ident) {
        final name = _advance().text;
        if (_cur.isKw('in')) {
          _advance();
          final obj = _expression();
          _expectPunct(')');
          final body = _statement();
          return ForInStmt(name, null, obj, body, line);
        }
      }
      _pos = save;
    } else if (_cur.type == TokType.ident) {
      final save = _pos;
      final name = _advance().text;
      if (_cur.isKw('in')) {
        _advance();
        final obj = _expression();
        _expectPunct(')');
        final body = _statement();
        return ForInStmt(null, Ident(name, line), obj, body, line);
      }
      _pos = save;
    }

    Stmt? init;
    if (_cur.isKw('var')) {
      init = _varDecl();
    } else if (!_cur.isPunct(';')) {
      init = ExprStmt(_expression(), line);
    }
    _expectPunct(';');

    Expr? test;
    if (!_cur.isPunct(';')) test = _expression();
    _expectPunct(';');

    Expr? update;
    if (!_cur.isPunct(')')) update = _expression();
    _expectPunct(')');

    final body = _statement();
    return ForStmt(init, test, update, body, line);
  }

  Stmt _tryStmt() {
    final line = _cur.line;
    _expectKw('try');
    final block = _block();
    String? param;
    Block? catchBlock;
    Block? finallyBlock;
    if (_eatKw('catch')) {
      _expectPunct('(');
      if (_cur.type != TokType.ident) _fail('catch 缺少异常变量名');
      param = _advance().text;
      _expectPunct(')');
      catchBlock = _block();
    }
    if (_eatKw('finally')) finallyBlock = _block();
    if (catchBlock == null && finallyBlock == null) {
      _fail('try 后面必须跟 catch 或 finally');
    }
    return TryStmt(block, param, catchBlock, finallyBlock, line);
  }

  // -------------------------------------------------------------------------
  // 表达式（优先级从低到高）
  // -------------------------------------------------------------------------

  Expr _expression() {
    final e = _assignment();
    if (_cur.isPunct(',')) {
      // 逗号表达式：只有最后一个值有意义
      final list = <Expr>[e];
      while (_eatPunct(',')) {
        list.add(_assignment());
      }
      var acc = list.last;
      for (var i = list.length - 2; i >= 0; i--) {
        acc = Binary(',', list[i], acc, list[i].line);
      }
      return acc;
    }
    return e;
  }

  static const Set<String> _assignOps = {
    '=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=', '>>>=',
  };

  Expr _assignment() {
    final left = _conditional();
    if (_cur.type == TokType.punct && _assignOps.contains(_cur.text)) {
      final op = _advance().text;
      final right = _assignment();
      if (left is! Ident && left is! Member) {
        _fail('赋值左侧必须是变量或成员访问');
      }
      return Binary(op, left, right, left.line);
    }
    return left;
  }

  Expr _conditional() {
    final test = _binary(0);
    if (_eatPunct('?')) {
      final thenExpr = _assignment();
      _expectPunct(':');
      final elseExpr = _assignment();
      return Cond(test, thenExpr, elseExpr, test.line);
    }
    return test;
  }

  /// 二元运算符优先级表（数值越大越紧）。
  static const Map<String, int> _binPrec = {
    '||': 1,
    '&&': 2,
    '|': 3,
    '^': 4,
    '&': 5,
    '==': 6, '!=': 6, '===': 6, '!==': 6,
    '<': 7, '>': 7, '<=': 7, '>=': 7, 'instanceof': 7, 'in': 7,
    '<<': 8, '>>': 8, '>>>': 8,
    '+': 9, '-': 9,
    '*': 10, '/': 10, '%': 10,
  };

  Expr _binary(int minPrec) {
    var left = _unary();
    while (true) {
      final t = _cur;
      String? op;
      if (t.type == TokType.punct && _binPrec.containsKey(t.text)) {
        op = t.text;
      } else if (t.type == TokType.keyword &&
          (t.text == 'instanceof' || t.text == 'in')) {
        op = t.text;
      }
      if (op == null) break;
      final prec = _binPrec[op]!;
      if (prec < minPrec) break;
      _advance();
      final right = _binary(prec + 1);
      left = Binary(op, left, right, left.line);
    }
    return left;
  }

  Expr _unary() {
    final t = _cur;
    if (t.type == TokType.punct &&
        (t.text == '-' ||
            t.text == '+' ||
            t.text == '!' ||
            t.text == '~')) {
      _advance();
      return Unary(t.text, _unary(), t.line);
    }
    if (t.type == TokType.punct && (t.text == '++' || t.text == '--')) {
      _advance();
      final operand = _unary();
      if (operand is! Ident && operand is! Member) {
        _fail('++/-- 的操作数必须是变量或成员访问', t);
      }
      return Unary(t.text, operand, t.line);
    }
    if (t.type == TokType.keyword &&
        (t.text == 'typeof' || t.text == 'void' || t.text == 'delete')) {
      _advance();
      return Unary(t.text, _unary(), t.line);
    }
    return _postfix();
  }

  Expr _postfix() {
    var expr = _callMember();
    final t = _cur;
    if (t.type == TokType.punct && (t.text == '++' || t.text == '--')) {
      // 后缀 ++/-- 不能跨行（否则按 ASI 视为下一语句）
      if (t.line == _prev.line) {
        _advance();
        if (expr is! Ident && expr is! Member) {
          _fail('++/-- 的操作数必须是变量或成员访问', t);
        }
        expr = Unary(t.text, expr, t.line, prefix: false);
      }
    }
    return expr;
  }

  Expr _callMember() {
    Expr expr;
    if (_cur.isKw('new')) {
      expr = _newExpr();
    } else {
      expr = _primary();
    }

    while (true) {
      if (_cur.isPunct('.')) {
        _advance();
        final t = _cur;
        if (t.type != TokType.ident && t.type != TokType.keyword) {
          _fail('"." 之后期望属性名');
        }
        _advance();
        expr = Member(expr, StrLit(t.text, t.line), t.line, computed: false);
      } else if (_cur.isPunct('[')) {
        final line = _cur.line;
        _advance();
        final prop = _expression();
        _expectPunct(']');
        expr = Member(expr, prop, line, computed: true);
      } else if (_cur.isPunct('(')) {
        final line = _cur.line;
        final args = _argList();
        expr = Call(expr, args, line);
      } else {
        break;
      }
    }
    return expr;
  }

  Expr _newExpr() {
    final line = _cur.line;
    _expectKw('new');
    Expr callee;
    if (_cur.isKw('new')) {
      callee = _newExpr();
    } else {
      callee = _primary();
      // new a.b.c(...)
      while (true) {
        if (_cur.isPunct('.')) {
          _advance();
          final t = _cur;
          if (t.type != TokType.ident && t.type != TokType.keyword) {
            _fail('"." 之后期望属性名');
          }
          _advance();
          callee = Member(callee, StrLit(t.text, t.line), t.line, computed: false);
        } else if (_cur.isPunct('[')) {
          final l2 = _cur.line;
          _advance();
          final prop = _expression();
          _expectPunct(']');
          callee = Member(callee, prop, l2, computed: true);
        } else {
          break;
        }
      }
    }
    final args = _cur.isPunct('(') ? _argList() : <Expr>[];
    return New(callee, args, line);
  }

  List<Expr> _argList() {
    _expectPunct('(');
    final args = <Expr>[];
    if (!_cur.isPunct(')')) {
      do {
        args.add(_assignment());
      } while (_eatPunct(','));
    }
    _expectPunct(')');
    return args;
  }

  Expr _primary() {
    final t = _cur;
    switch (t.type) {
      case TokType.num:
        _advance();
        return NumLit(t.numValue!, t.line);
      case TokType.str:
        _advance();
        return StrLit(t.text, t.line);
      case TokType.ident:
        _advance();
        return Ident(t.text, t.line);
      case TokType.keyword:
        switch (t.text) {
          case 'true':
            _advance();
            return BoolLit(true, t.line);
          case 'false':
            _advance();
            return BoolLit(false, t.line);
          case 'null':
            _advance();
            return NullLit(t.line);
          case 'this':
            _advance();
            return ThisExpr(t.line);
          case 'function':
            return _funcExpr();
          case 'void':
            _advance();
            return Unary('void', _unary(), t.line);
        }
        _fail('意外的关键字 "${t.text}"');
      case TokType.punct:
        if (t.text == '(') {
          _advance();
          final e = _expression();
          _expectPunct(')');
          return e;
        }
        if (t.text == '[') return _arrayLit();
        if (t.text == '{') return _objectLit();
        if (t.text == '/') {
          _fail('不支持正则字面量（规范 §12 未承诺 RegExp 字面量语法）');
        }
        _fail('意外的符号 "${t.text}"');
      case TokType.eof:
        _fail('表达式未结束');
    }
  }

  Expr _funcExpr() {
    final line = _cur.line;
    _expectKw('function');
    String? name;
    if (_cur.type == TokType.ident) name = _advance().text;
    final params = _paramList();
    final body = _block();
    return FuncLit(params, body.body, line, name: name);
  }

  Expr _arrayLit() {
    final line = _cur.line;
    _expectPunct('[');
    final items = <Expr?>[];
    while (!_cur.isPunct(']')) {
      if (_cur.isPunct(',')) {
        // 数组洞
        _advance();
        items.add(null);
        continue;
      }
      items.add(_assignment());
      if (!_cur.isPunct(']')) _expectPunct(',');
    }
    _expectPunct(']');
    return ArrayLit(items, line);
  }

  Expr _objectLit() {
    final line = _cur.line;
    _expectPunct('{');
    final props = <ObjectProp>[];
    while (!_cur.isPunct('}')) {
      final kt = _cur;
      Expr key;
      var computed = false;
      if (kt.isPunct('[')) {
        _advance();
        key = _expression();
        _expectPunct(']');
        computed = true;
      } else if (kt.type == TokType.ident || kt.type == TokType.keyword) {
        _advance();
        key = StrLit(kt.text, kt.line);
      } else if (kt.type == TokType.str) {
        _advance();
        key = StrLit(kt.text, kt.line);
      } else if (kt.type == TokType.num) {
        _advance();
        key = StrLit(_numToJsString(kt.numValue!), kt.line);
      } else {
        _fail('对象字面量的键不合法');
      }
      Expr value;
      if (_eatPunct(':')) {
        value = _assignment();
      } else if (kt.type == TokType.ident && _cur.isPunct('(')) {
        // 方法简写 `{ foo(a) { ... } }`
        final params = _paramList();
        final body = _block();
        value = FuncLit(params, body.body, kt.line, name: kt.text);
      } else {
        // 简写属性 `{ a }` → `{ a: a }`
        if (key is! StrLit) _fail('简写属性必须是标识符');
        value = Ident(key.value, kt.line);
      }
      props.add(ObjectProp(key, value, computed: computed));
      if (!_cur.isPunct('}')) _expectPunct(',');
    }
    _expectPunct('}');
    return ObjectLit(props, line);
  }
}

String _numToJsString(num v) {
  if (v is int) return v.toString();
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
  if (v == v.truncate() && v.abs() < 1e21) return v.toInt().toString();
  return v.toString();
}
