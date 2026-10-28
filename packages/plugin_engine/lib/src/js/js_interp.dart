/// set.js 沙箱的求值器。
///
/// 职责：
/// - 变量作用域（函数作用域 + 闭包，`var` 提升到函数开头）；
/// - 运算符、成员访问、调用、`new`；
/// - 控制流（含 break/continue/return 信号）；
/// - 超时中断：每 [budget] 条语句检查一次，超时抛 E_JS。
///
/// 与 `fn.*` 的桥接在 [interp] 之外完成（宿主把 fn 命名空间作为全局对象注入），
/// 这样表达式求值与 set.js 共享同一套函数实现。
library;

import '../errors.dart';
import 'js_ast.dart';
import 'js_builtins.dart';
import 'js_value.dart';

/// 作用域链。
class JsScope {
  final Map<String, Object?> vars = <String, Object?>{};
  final JsScope? parent;
  final bool isFunctionScope;

  JsScope({this.parent, this.isFunctionScope = false});

  Object? lookup(String name) {
    JsScope? s = this;
    while (s != null) {
      if (s.vars.containsKey(name)) return s.vars[name];
      s = s.parent;
    }
    return _notFound;
  }

  bool has(String name) {
    JsScope? s = this;
    while (s != null) {
      if (s.vars.containsKey(name)) return true;
      s = s.parent;
    }
    return false;
  }

  /// 赋值：沿作用域链找到已声明变量则写那里，否则写到最外层（函数作用域/全局）。
  void assign(String name, Object? value) {
    JsScope? s = this;
    while (s != null) {
      if (s.vars.containsKey(name)) {
        s.vars[name] = value;
        return;
      }
      s = s.parent;
    }
    // 隐式全局（非严格模式）
    JsScope root = this;
    while (root.parent != null) {
      root = root.parent!;
    }
    root.vars[name] = value;
  }

  /// 声明：`var` 总是声明在当前函数作用域。
  void declare(String name, Object? value) {
    vars[name] = value;
  }
}

const Object _notFound = Object();

/// 控制流信号。
class _Break {
  const _Break();
}

class _Continue {
  const _Continue();
}

class _Return {
  final Object? value;
  const _Return(this.value);
}

/// 超时/步数上限。
class JsLimits {
  final int maxSteps;
  final Duration timeout;
  JsLimits({this.maxSteps = 4000000, this.timeout = const Duration(seconds: 5)});
}

class JsInterp {
  final JsObject global;
  final JsLimits limits;
  final DateTime Function() clock;
  int _steps = 0;
  final Stopwatch _watch = Stopwatch();

  JsInterp(this.global, {required this.limits, required this.clock});

  /// 执行一段代码；代码在函数体内运行，必须 `return` 一个值。
  Object? runProgram(List<Stmt> program, {JsScope? outer}) {
    _watch
      ..reset()
      ..start();
    _steps = 0;
    final scope = JsScope(parent: outer, isFunctionScope: true);
    // 顶层函数声明先提升
    _hoistFunctions(program, scope);
    try {
      for (final s in program) {
        _tick(s.line);
        final r = _exec(s, scope);
        if (r is _Return) return r.value;
        if (r is _Break || r is _Continue) {
          throw PluginError(ErrorCodes.js, 'break/continue 出现在循环之外（第 ${s.line} 行）');
        }
      }
      return jsUndefined;
    } on _JsThrow catch (e) {
      // 未被 try/catch 接住的 throw 冒泡到宿主 → E_JS
      throw PluginError(ErrorCodes.js, _throwMessage(e.value, e.line));
    } on PluginError {
      rethrow;
    } catch (e) {
      // 宿主内部异常统一转成 E_JS，避免把 Dart 栈泄给插件
      throw PluginError(ErrorCodes.js, 'JS 执行失败：$e');
    } finally {
      _watch.stop();
    }
  }

  void _tick(int line) {
    _steps++;
    if (_steps > limits.maxSteps) {
      throw PluginError(
        ErrorCodes.js,
        'JS 执行步数超过上限 ${limits.maxSteps}（疑似死循环，第 $line 行）',
      );
    }
    if ((_steps & 0xFFF) == 0 && _watch.elapsed > limits.timeout) {
      throw PluginError(
        ErrorCodes.js,
        'JS 执行超时（>${limits.timeout.inMilliseconds}ms，第 $line 行）',
      );
    }
  }

  void _hoistFunctions(List<Stmt> body, JsScope scope) {
    for (final s in body) {
      if (s is FuncDecl) {
        scope.declare(s.fn.name!, _makeFunction(s.fn, scope));
      }
    }
  }

  JsUserFunction _makeFunction(FuncLit fn, JsScope scope) {
    final f = JsUserFunction(
      fn.name ?? '<anonymous>',
      fn.params,
      fn.body,
      scope,
    );
    // 原型对象的 constructor 指回函数自身
    f.prototype.setProp('constructor', f);
    return f;
  }

  // -------------------------------------------------------------------------
  // 语句执行
  // -------------------------------------------------------------------------

  Object? _exec(Stmt s, JsScope scope) {
    if (s is Block) {
      final inner = JsScope(parent: scope);
      _hoistFunctions(s.body, inner);
      for (final st in s.body) {
        _tick(st.line);
        final r = _exec(st, inner);
        if (r != null) return r;
      }
      return null;
    }
    if (s is EmptyStmt) return null;
    if (s is VarDecl) {
      for (final (name, init) in s.decls) {
        final v = init == null ? jsUndefined : _eval(init, scope);
        // var 提升：已声明则赋值，否则声明在当前函数作用域
        var target = scope;
        while (!target.isFunctionScope && target.parent != null) {
          target = target.parent!;
        }
        if (target.vars.containsKey(name)) {
          target.vars[name] = v;
        } else {
          scope.declare(name, v);
        }
      }
      return null;
    }
    if (s is FuncDecl) return null; // 已提升
    if (s is ExprStmt) {
      _eval(s.expr, scope);
      return null;
    }
    if (s is IfStmt) {
      if (jsTruthy(_eval(s.test, scope))) {
        return _exec(s.consequent, scope);
      } else if (s.alternate != null) {
        return _exec(s.alternate!, scope);
      }
      return null;
    }
    if (s is WhileStmt) {
      while (jsTruthy(_eval(s.test, scope))) {
        _tick(s.line);
        final r = _exec(s.body, scope);
        if (r is _Break) break;
        if (r is _Return) return r;
      }
      return null;
    }
    if (s is DoWhileStmt) {
      do {
        _tick(s.line);
        final r = _exec(s.body, scope);
        if (r is _Break) break;
        if (r is _Return) return r;
        if (!jsTruthy(_eval(s.test, scope))) break;
      } while (true);
      return null;
    }
    if (s is ForStmt) {
      final loopScope = JsScope(parent: scope);
      if (s.init != null) _exec(s.init!, loopScope);
      while (true) {
        _tick(s.line);
        if (s.test != null && !jsTruthy(_eval(s.test!, loopScope))) break;
        final r = _exec(s.body, loopScope);
        if (r is _Break) break;
        if (r is _Return) return r;
        if (s.update != null) _eval(s.update!, loopScope);
      }
      return null;
    }
    if (s is ForInStmt) {
      final obj = _eval(s.object, scope);
      final keys = _enumerableKeys(obj);
      for (final k in keys) {
        _tick(s.line);
        if (s.varName != null) {
          scope.declare(s.varName!, k);
        } else {
          _assignTo(s.target!, k, scope);
        }
        final r = _exec(s.body, scope);
        if (r is _Break) break;
        if (r is _Return) return r;
      }
      return null;
    }
    if (s is ReturnStmt) {
      return _Return(s.value == null ? jsUndefined : _eval(s.value!, scope));
    }
    if (s is BreakStmt) return const _Break();
    if (s is ContinueStmt) return const _Continue();
    if (s is ThrowStmt) {
      final v = _eval(s.value, scope);
      throw _JsThrow(v, s.line);
    }
    if (s is TryStmt) {
      Object? pending; // _Break/_Continue/_Return
      try {
        final r = _exec(s.block, scope);
        if (r != null) pending = r;
      } on _JsThrow catch (e) {
        if (s.catchBlock == null) {
          if (s.finallyBlock != null) _exec(s.finallyBlock!, scope);
          rethrow;
        }
        final cs = JsScope(parent: scope);
        cs.declare(s.catchParam ?? '_', e.value);
        final r = _exec(s.catchBlock!, cs);
        if (r != null) pending = r;
      } finally {
        if (s.finallyBlock != null) {
          final fr = _exec(s.finallyBlock!, scope);
          if (fr != null) pending = fr; // finally 中的 return/break 覆盖
        }
      }
      return pending;
    }
    throw PluginError(ErrorCodes.js, '不支持的语句类型：${s.runtimeType}');
  }

  List<String> _enumerableKeys(Object? obj) {
    if (obj is JsObject) {
      final keys = <String>[];
      final seen = <String>{};
      JsObject? o = obj;
      while (o != null) {
        for (final k in o.props.keys) {
          if (seen.add(k)) keys.add(k);
        }
        o = o.proto;
      }
      return keys;
    }
    if (obj is JsArray) {
      return [for (var i = 0; i < obj.length; i++) i.toString()];
    }
    if (obj is JsUint8Array) {
      return [for (var i = 0; i < obj.length; i++) i.toString()];
    }
    if (obj is String) {
      return [for (var i = 0; i < obj.length; i++) i.toString()];
    }
    return const [];
  }

  // -------------------------------------------------------------------------
  // 表达式求值
  // -------------------------------------------------------------------------

  Object? _eval(Expr e, JsScope scope) {
    _tick(e.line);

    if (e is NumLit) return e.value;
    if (e is StrLit) return e.value;
    if (e is BoolLit) return e.value;
    if (e is NullLit) return jsNull;
    if (e is UndefinedLit) return jsUndefined;
    if (e is ThisExpr) {
      final t = scope.lookup('this');
      return identical(t, _notFound) ? jsUndefined : t;
    }
    if (e is Ident) {
      final v = scope.lookup(e.name);
      if (identical(v, _notFound)) {
        final g = global.props[e.name];
        if (g != null) return g;
        // 未声明标识符：JS 会抛 ReferenceError；这里按 undefined 更宽容，
        // 但对 `fn` 命名空间缺失要显式报错（插件最常犯的错）
        if (e.name == 'fn') {
          throw PluginError(ErrorCodes.js, 'fn 命名空间缺失（引擎未注入）');
        }
        return jsUndefined;
      }
      return v;
    }
    if (e is FuncLit) return _makeFunction(e, scope);
    if (e is Unary) return _evalUnary(e, scope);
    if (e is Binary) return _evalBinary(e, scope);
    if (e is Cond) {
      return jsTruthy(_eval(e.test, scope))
          ? _eval(e.thenExpr, scope)
          : _eval(e.elseExpr, scope);
    }
    if (e is ArrayLit) {
      final items = <Object?>[];
      for (final it in e.items) {
        items.add(it == null ? jsUndefined : _eval(it, scope));
      }
      return JsArray(items);
    }
    if (e is ObjectLit) {
      final o = JsObject();
      for (final p in e.props) {
        final key = p.computed
            ? jsToString(_eval(p.key, scope))
            : (p.key as StrLit).value;
        o.setProp(key, _eval(p.value, scope));
      }
      return o;
    }
    if (e is Member) return _evalMember(e, scope);
    if (e is Call) return _evalCall(e, scope);
    if (e is New) return _evalNew(e, scope);

    throw PluginError(ErrorCodes.js, '不支持的表达式类型：${e.runtimeType}'
        '（第 ${e.line} 行）');
  }

  Object? _evalUnary(Unary e, JsScope scope) {
    switch (e.op) {
      case 'typeof':
        if (e.operand is Ident) {
          final name = (e.operand as Ident).name;
          if (!scope.has(name) && !global.props.containsKey(name)) {
            return 'undefined';
          }
        }
        return jsTypeOf(_eval(e.operand, scope));
      case 'void':
        _eval(e.operand, scope);
        return jsUndefined;
      case 'delete':
        final op = e.operand;
        if (op is Member) {
          final obj = _eval(op.object, scope);
          final key = op.computed
              ? jsToString(_eval(op.property, scope))
              : (op.property as StrLit).value;
          if (obj is JsObject) return obj.deleteProp(key);
          return true;
        }
        return true;
      case '!':
        return !jsTruthy(_eval(e.operand, scope));
      case '-':
        return jsNum(-toNumber(_eval(e.operand, scope)));
      case '+':
        return toNumber(_eval(e.operand, scope));
      case '~':
        return ~toInt32(_eval(e.operand, scope));
      case '++':
      case '--':
        final delta = e.op == '++' ? 1 : -1;
        final old = toNumber(_readTarget(e.operand, scope));
        final v = jsNum(old + delta);
        _assignTo(e.operand, v, scope);
        return e.prefix ? v : old;
    }
    throw PluginError(ErrorCodes.js, '不支持的一元运算符 ${e.op}');
  }

  Object? _evalBinary(Binary e, JsScope scope) {
    // 短路
    if (e.op == '&&') {
      final l = _eval(e.left, scope);
      return jsTruthy(l) ? _eval(e.right, scope) : l;
    }
    if (e.op == '||') {
      final l = _eval(e.left, scope);
      return jsTruthy(l) ? l : _eval(e.right, scope);
    }
    if (e.op == ',') {
      _eval(e.left, scope);
      return _eval(e.right, scope);
    }

    // 复合赋值
    const assignOps = {
      '=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=', '>>>=',
    };
    if (assignOps.contains(e.op)) {
      Object? value;
      if (e.op == '=') {
        value = _eval(e.right, scope);
      } else {
        final cur = _readTarget(e.left, scope);
        final rhs = _eval(e.right, scope);
        value = _applyBinOp(e.op.substring(0, e.op.length - 1), cur, rhs);
      }
      _assignTo(e.left, value, scope);
      return value;
    }

    final l = _eval(e.left, scope);
    final r = _eval(e.right, scope);
    return _applyBinOp(e.op, l, r);
  }

  Object? _applyBinOp(String op, Object? l, Object? r) {
    switch (op) {
      case '+':
        // 任一侧是 string 就做拼接
        if (l is String || r is String) {
          return jsToString(l) + jsToString(r);
        }
        if (l is JsUint8Array || r is JsUint8Array) {
          return jsToString(l) + jsToString(r);
        }
        return jsNum(toNumber(l) + toNumber(r));
      case '-':
        return jsNum(toNumber(l) - toNumber(r));
      case '*':
        return jsNum(toNumber(l) * toNumber(r));
      case '/':
        return jsNum(toNumber(l) / toNumber(r));
      case '%':
        final a = toNumber(l);
        final b = toNumber(r);
        if (b == 0 || a.isNaN || b.isNaN) return double.nan;
        return jsNum(a % b);
      case '===':
        return jsStrictEquals(l, r);
      case '!==':
        return !jsStrictEquals(l, r);
      case '==':
        return _looseEquals(l, r);
      case '!=':
        return !_looseEquals(l, r);
      case '<':
        return _compare(l, r) < 0;
      case '>':
        return _compare(l, r) > 0;
      case '<=':
        return _compare(l, r) <= 0;
      case '>=':
        return _compare(l, r) >= 0;
      case '&':
        return toInt32(l) & toInt32(r);
      case '|':
        return toInt32(l) | toInt32(r);
      case '^':
        return toInt32(l) ^ toInt32(r);
      case '<<':
        return (toInt32(l) << (toUint32(r) & 31)).toSigned(32);
      case '>>':
        return toInt32(l) >> (toUint32(r) & 31);
      case '>>>':
        return toUint32(l) >> (toUint32(r) & 31);
      case 'instanceof':
        return _instanceOf(l, r);
      case 'in':
        return _inOperator(l, r);
    }
    throw PluginError(ErrorCodes.js, '不支持的运算符 $op');
  }

  bool _looseEquals(Object? l, Object? r) {
    final lNull = l is JsNull || l is JsUndefined || l == null;
    final rNull = r is JsNull || r is JsUndefined || r == null;
    if (lNull || rNull) return lNull && rNull;
    if (l is num && r is num) return l == r;
    if (l is String && r is String) return l == r;
    if (l is bool && r is bool) return l == r;
    if (l is num && r is String) return l == toNumber(r);
    if (l is String && r is num) return toNumber(l) == r;
    return jsStrictEquals(l, r);
  }

  int _compare(Object? l, Object? r) {
    if (l is String && r is String) return l.compareTo(r);
    final a = toNumber(l);
    final b = toNumber(r);
    if (a.isNaN || b.isNaN) return 0; // 比较 NaN 恒 false，这里用 0 近似
    return a.compareTo(b);
  }

  bool _instanceOf(Object? l, Object? r) {
    if (r is JsUserFunction) {
      if (l is JsObject) {
        var p = l.proto;
        while (p != null) {
          if (identical(p, r.prototype)) return true;
          p = p.proto;
        }
      }
      return false;
    }
    if (r is JsNativeFunction) {
      if (r.name == 'Array') return l is JsArray;
      if (r.name == 'Uint8Array') return l is JsUint8Array;
      if (r.name == 'String') return l is String;
      if (r.name == 'Number') return l is num;
      if (r.name == 'Boolean') return l is bool;
      if (r.name == 'Date') return l is JsDate;
      if (r.name == 'RegExp') return l is JsRegExp;
      if (r.name == 'Object') return l is JsObject;
    }
    return false;
  }

  bool _inOperator(Object? l, Object? r) {
    final key = jsToString(l);
    if (r is JsObject) {
      JsObject? o = r;
      while (o != null) {
        if (o.props.containsKey(key)) return true;
        o = o.proto;
      }
      return false;
    }
    if (r is JsArray) {
      final i = int.tryParse(key);
      return i != null && i >= 0 && i < r.length || key == 'length';
    }
    if (r is JsUint8Array) {
      final i = int.tryParse(key);
      return i != null && i >= 0 && i < r.length || key == 'length';
    }
    return false;
  }

  Object? _readTarget(Expr target, JsScope scope) {
    if (target is Ident) {
      final v = scope.lookup(target.name);
      return identical(v, _notFound) ? global.props[target.name] : v;
    }
    if (target is Member) {
      final obj = _eval(target.object, scope);
      final key = target.computed
          ? jsToString(_eval(target.property, scope))
          : (target.property as StrLit).value;
      return _getMember(obj, key);
    }
    throw PluginError(ErrorCodes.js, '非法的赋值目标（第 ${target.line} 行）');
  }

  void _assignTo(Expr target, Object? value, JsScope scope) {
    if (target is Ident) {
      if (scope.has(target.name)) {
        scope.assign(target.name, value);
      } else if (global.props.containsKey(target.name)) {
        global.setProp(target.name, value);
      } else {
        scope.assign(target.name, value);
      }
      return;
    }
    if (target is Member) {
      final obj = _eval(target.object, scope);
      final key = target.computed
          ? jsToString(_eval(target.property, scope))
          : (target.property as StrLit).value;
      _setMember(obj, key, value, target.line);
      return;
    }
    throw PluginError(ErrorCodes.js, '非法的赋值目标（第 ${target.line} 行）');
  }

  Object? _evalMember(Member e, JsScope scope) {
    final obj = _eval(e.object, scope);
    final key = e.computed
        ? jsToString(_eval(e.property, scope))
        : (e.property as StrLit).value;
    return _getMember(obj, key);
  }

  Object? _getMember(Object? obj, String key) {
    if (obj == null || obj is JsUndefined || obj is JsNull) {
      throw _JsThrow(
        JsObject({
          'name': 'TypeError',
          'message': '无法读取 $key（对象为 ${jsToString(obj)}）',
        }),
      );
    }
    if (obj is String) {
      if (key == 'length') return obj.length;
      if (key == 'constructor') return global.props['String'];
      final idx = int.tryParse(key);
      if (idx != null) {
        return (idx >= 0 && idx < obj.length) ? obj[idx] : jsUndefined;
      }
      return JsNativeFunction(key, (t, a) => callStringMethod(obj, key, a));
    }
    if (obj is JsArray) {
      if (key == 'length') return obj.length;
      if (key == 'constructor') return global.props['Array'];
      final idx = int.tryParse(key);
      if (idx != null) {
        return (idx >= 0 && idx < obj.length) ? obj.items[idx] : jsUndefined;
      }
      final statics = global.props['Array'];
      if (statics is JsNativeFunction && statics.props.props.containsKey(key)) {
        return statics.props.props[key];
      }
      return JsNativeFunction(key, (t, a) => callArrayMethod(obj, key, a));
    }
    if (obj is JsUint8Array) {
      if (key == 'length') return obj.length;
      if (key == 'byteLength') return obj.length;
      if (key == 'buffer') return obj.toBytes();
      if (key == 'constructor') return global.props['Uint8Array'];
      final idx = int.tryParse(key);
      if (idx != null) {
        return obj.inRange(idx) ? obj.get(idx) : jsUndefined;
      }
      final statics = global.props['Uint8Array'];
      if (statics is JsNativeFunction && statics.props.props.containsKey(key)) {
        return statics.props.props[key];
      }
      return JsNativeFunction(key, (t, a) => callU8Method(obj, key, a));
    }
    if (obj is JsDate) {
      final statics = global.props['Date'];
      if (statics is JsNativeFunction && statics.props.props.containsKey(key)) {
        return statics.props.props[key];
      }
      return JsNativeFunction(key, (t, a) => callDateMethod(obj, key, a));
    }
    if (obj is JsRegExp) {
      if (key == 'source') return obj.re.pattern;
      if (key == 'global') return obj.global;
      return jsUndefined;
    }
    if (obj is JsObject) {
      final v = obj.getProp(key);
      if (v != null) return v;
      // Object.prototype 上的通用方法
      if (key == 'hasOwnProperty') {
        return JsNativeFunction(key, (t, a) {
          return obj.hasOwn(jsToString(a.isEmpty ? jsUndefined : a[0]));
        });
      }
      if (key == 'toString') {
        return JsNativeFunction(key, (t, a) => '[object Object]');
      }
      if (key == 'valueOf') {
        return JsNativeFunction(key, (t, a) => obj);
      }
      return jsUndefined;
    }
    if (obj is JsNativeFunction) {
      if (key == 'prototype') return obj.props;
      final v = obj.props.getProp(key);
      return v ?? jsUndefined;
    }
    if (obj is JsUserFunction) {
      if (key == 'prototype') return obj.prototype;
      if (key == 'name') return obj.name;
      if (key == 'length') return obj.params.length;
      if (key == 'call') {
        return JsNativeFunction(key, (t, a) {
          final self = a.isEmpty ? jsUndefined : a[0];
          return obj.call(self, a.length > 1 ? a.sublist(1) : <Object?>[]);
        });
      }
      if (key == 'apply') {
        return JsNativeFunction(key, (t, a) {
          final self = a.isEmpty ? jsUndefined : a[0];
          final arr = a.length > 1 ? a[1] : null;
          final list = arr is JsArray ? arr.items : <Object?>[];
          return obj.call(self, list);
        });
      }
      if (key == 'bind') {
        return JsNativeFunction(key, (t, a) {
          final self = a.isEmpty ? jsUndefined : a[0];
          final bound = a.length > 1 ? a.sublist(1) : <Object?>[];
          return JsNativeFunction(obj.name, (t2, a2) {
            return obj.call(self, [...bound, ...a2]);
          });
        });
      }
      return obj.props.getProp(key) ?? jsUndefined;
    }
    if (obj is num || obj is bool) {
      if (key == 'toString') {
        return JsNativeFunction(key, (t, a) {
          if (obj is num && a.isNotEmpty) {
            final radix = toNumber(a[0]).toInt();
            if (radix >= 2 && radix <= 36 && obj is int) {
              return obj.toRadixString(radix);
            }
          }
          return jsToString(obj);
        });
      }
      if (key == 'toFixed') {
        return JsNativeFunction(key, (t, a) {
          final d = a.isEmpty ? 0 : toNumber(a[0]).toInt();
          return toNumber(obj).toDouble().toStringAsFixed(d);
        });
      }
      if (key == 'valueOf') {
        return JsNativeFunction(key, (t, a) => obj);
      }
      return jsUndefined;
    }
    return jsUndefined;
  }

  void _setMember(Object? obj, String key, Object? value, int line) {
    if (obj is JsObject) {
      obj.setProp(key, value);
      return;
    }
    if (obj is JsArray) {
      if (key == 'length') {
        final n = toNumber(value).toInt();
        if (n < 0) {
          throw PluginError(ErrorCodes.js, '数组长度不能为负（第 $line 行）');
        }
        while (obj.items.length < n) {
          obj.items.add(jsUndefined);
        }
        if (obj.items.length > n) {
          obj.items.removeRange(n, obj.items.length);
        }
        return;
      }
      final idx = int.tryParse(key);
      if (idx != null) {
        if (idx < 0) {
          throw PluginError(ErrorCodes.js, '数组索引不能为负（第 $line 行）');
        }
        while (obj.items.length <= idx) {
          obj.items.add(jsUndefined);
        }
        obj.items[idx] = value;
        return;
      }
      // 数组上的自定义属性：忽略（JS 里可以挂，但插件代码几乎不用）
      return;
    }
    if (obj is JsUint8Array) {
      final idx = int.tryParse(key);
      if (idx != null) {
        if (!obj.inRange(idx)) {
          // JS 中等价于静默忽略（越界写不报错）
          return;
        }
        obj.set(idx, toUint8(value));
        return;
      }
      return;
    }
    throw PluginError(
      ErrorCodes.js,
      '无法给 ${jsTypeOf(obj)} 设置属性 "$key"（第 $line 行）',
    );
  }

  // -------------------------------------------------------------------------
  // 调用
  // -------------------------------------------------------------------------

  // 注意：这里**不能**把 _JsThrow 转成 PluginError。
  // JS 的 throw 必须能冒泡到插件自己的 try/catch（§9 逃生舱语义），
  // 只有一路冒到 runProgram 最外层、没人接住时才算 E_JS。
  Object? _evalCall(Call e, JsScope scope) {
    // 方法调用需要 this 绑定
    if (e.callee is Member) {
      final m = e.callee as Member;
      final self = _eval(m.object, scope);
      final key = m.computed
          ? jsToString(_eval(m.property, scope))
          : (m.property as StrLit).value;
      final f = _getMember(self, key);
      final args = [for (final a in e.args) _eval(a, scope)];
      return _invoke(f, self, args, e.line, key);
    }
    final f = _eval(e.callee, scope);
    final args = [for (final a in e.args) _eval(a, scope)];
    return _invoke(f, jsUndefined, args, e.line, null);
  }

  Object? _evalNew(New e, JsScope scope) {
    final callee = _eval(e.callee, scope);
    final args = [for (final a in e.args) _eval(a, scope)];
    if (callee is JsNativeFunction) {
      final r = callee.call(jsUndefined, args);
      // 内建构造器返回对象（JsObject/JsArray/JsUint8Array/JsDate/JsRegExp…）直接用
      if (r is! num && r is! String && r is! bool && r is! JsUndefined &&
          r is! JsNull && r != null) {
        return r;
      }
      // 返回原始值时才包一层对象（如 new Number(1)）
      final o = JsObject();
      o.setProp('valueOf', JsNativeFunction('valueOf', (t, a) => r));
      return o;
    }
    if (callee is JsUserFunction) {
      final instance = JsObject()..proto = callee.prototype;
      final r = _callUser(callee, instance, args, e.line);
      // 构造函数返回对象则用它，否则用 instance
      if (r is JsObject || r is JsArray || r is JsUint8Array) return r;
      return instance;
    }
    throw PluginError(
      ErrorCodes.js,
      'new 的目标不是构造函数（第 ${e.line} 行）',
    );
  }

  Object? _invoke(
      Object? f, Object? thisVal, List<Object?> args, int line, String? name) {
    if (f is JsNativeFunction) return f.call(thisVal, args);
    if (f is JsUserFunction) return _callUser(f, thisVal, args, line);
    throw PluginError(
      ErrorCodes.js,
      '${name == null ? '表达式' : '"$name"'} 不是函数（第 $line 行）',
    );
  }

  Object? _callUser(
      JsUserFunction fn, Object? thisVal, List<Object?> args, int line) {
    final parent = fn.closureScope as JsScope?;
    final scope = JsScope(parent: parent, isFunctionScope: true);
    scope.declare('this', thisVal);
    scope.declare('arguments', JsArray([...args]));
    for (var i = 0; i < fn.params.length; i++) {
      scope.declare(fn.params[i], i < args.length ? args[i] : jsUndefined);
    }
    final body = fn.body as List<Stmt>;
    _hoistFunctions(body, scope);
    for (final s in body) {
      _tick(s.line);
      final r = _exec(s, scope);
      if (r is _Return) return r.value;
      if (r is _Break || r is _Continue) {
        throw PluginError(
          ErrorCodes.js,
          'break/continue 出现在循环之外（函数 ${fn.name}，第 ${s.line} 行）',
        );
      }
    }
    return jsUndefined;
  }

  String _throwMessage(Object? v, int line) {
    if (v is JsObject) {
      final msg = v.getProp('message');
      final name = v.getProp('name');
      if (msg != null) {
        return 'JS 抛出 ${name == null ? 'Error' : jsToString(name)}：'
            '${jsToString(msg)}（第 $line 行）';
      }
    }
    return 'JS 抛出 ${jsToString(v)}（第 $line 行）';
  }
}

/// JS `throw` 的载体（用于与宿主 PluginError 区分）。
class _JsThrow implements Exception {
  final Object? value;
  final int line;
  _JsThrow(this.value, [this.line = 0]);
}
