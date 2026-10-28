/// set.js 沙箱的内建对象与方法。
///
/// 覆盖规范 §12 承诺的：`String`、`Number`、`Boolean`、`Array`、`Object`、
/// `JSON`、`Math`、`Date`、`Uint8Array`、`parseInt`/`parseFloat`/`isNaN`。
/// 禁用项（`eval`/`Function`/`setTimeout`/`fetch` 等）在 [buildGlobals]
/// 里装成"调用即抛 E_JS"的桩。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../errors.dart';
import 'js_value.dart';

Never jsError(String msg) => throw PluginError(ErrorCodes.js, msg);

// ---------------------------------------------------------------------------
// String 方法
// ---------------------------------------------------------------------------

Object? callStringMethod(String s, String name, List<Object?> args) {
  switch (name) {
    case 'charAt':
      final i = _idx(args, 0);
      return (i < 0 || i >= s.length) ? '' : s[i];
    case 'charCodeAt':
      final i = _idx(args, 0);
      return (i < 0 || i >= s.length) ? double.nan : s.codeUnitAt(i);
    case 'codePointAt':
      final i = _idx(args, 0);
      if (i < 0 || i >= s.length) return jsUndefined;
      return s.runes.length == s.length
          ? s.codeUnitAt(i)
          : s.codeUnitAt(i); // 简化为码元，与 charCodeAt 一致
    case 'indexOf':
      final sub = jsToString(args.isEmpty ? jsUndefined : args[0]);
      final from = args.length > 1 ? _idx(args, 1) : 0;
      return s.indexOf(sub, from < 0 ? 0 : (from > s.length ? s.length : from));
    case 'lastIndexOf':
      final sub = jsToString(args.isEmpty ? jsUndefined : args[0]);
      return s.lastIndexOf(sub);
    case 'includes':
      return s.contains(jsToString(args.isEmpty ? jsUndefined : args[0]));
    case 'startsWith':
      final sub = jsToString(args.isEmpty ? jsUndefined : args[0]);
      final pos = args.length > 1 ? _idx(args, 1) : 0;
      return s.startsWith(sub, pos < 0 ? 0 : pos);
    case 'endsWith':
      final sub = jsToString(args.isEmpty ? jsUndefined : args[0]);
      return s.endsWith(sub);
    case 'substring':
      var start = _idx(args, 0);
      var end = args.length > 1 && args[1] is! JsUndefined ? _idx(args, 1) : s.length;
      start = start < 0 ? 0 : (start > s.length ? s.length : start);
      end = end < 0 ? 0 : (end > s.length ? s.length : end);
      if (start > end) {
        final t = start;
        start = end;
        end = t;
      }
      return s.substring(start, end);
    case 'substr':
      var start = _idx(args, 0);
      if (start < 0) start = math.max(0, s.length + start);
      if (start > s.length) start = s.length;
      var len = s.length - start;
      if (args.length > 1 && args[1] is! JsUndefined) {
        final l = _idx(args, 1);
        if (l < len) len = l < 0 ? 0 : l;
      }
      return s.substring(start, start + len);
    case 'slice':
      var start = _idx(args, 0);
      var end = args.length > 1 && args[1] is! JsUndefined ? _idx(args, 1) : s.length;
      if (start < 0) start = math.max(0, s.length + start);
      if (end < 0) end = math.max(0, s.length + end);
      if (start > s.length) start = s.length;
      if (end > s.length) end = s.length;
      if (end <= start) return '';
      return s.substring(start, end);
    case 'toUpperCase':
    case 'toLocaleUpperCase':
      return s.toUpperCase();
    case 'toLowerCase':
    case 'toLocaleLowerCase':
      return s.toLowerCase();
    case 'trim':
      return s.trim();
    case 'trimStart':
    case 'trimLeft':
      return s.replaceFirst(RegExp(r'^\s+'), '');
    case 'trimEnd':
    case 'trimRight':
      return s.replaceFirst(RegExp(r'\s+$'), '');
    case 'split':
      if (args.isEmpty || args[0] is JsUndefined) return JsArray([s]);
      final sep = args[0];
      final limit = args.length > 1 && args[1] is! JsUndefined
          ? toNumber(args[1]).toInt()
          : -1;
      List<Object?> parts;
      if (sep is String) {
        if (sep.isEmpty) {
          parts = s.split('').cast<Object?>();
        } else {
          parts = s.split(sep).cast<Object?>();
        }
      } else if (sep is JsRegExp) {
        parts = sep.split(s).cast<Object?>();
      } else {
        parts = <Object?>[s];
      }
      if (limit >= 0 && parts.length > limit) {
        parts = parts.sublist(0, limit);
      }
      return JsArray(parts);
    case 'replace':
      final pat = args.isEmpty ? '' : args[0];
      final rep = args.length > 1 ? args[1] : jsUndefined;
      if (pat is JsRegExp) {
        return pat.replace(s, rep, all: pat.global);
      }
      var needle = jsToString(pat);
      final idx = s.indexOf(needle);
      if (idx < 0) return s;
      return s.substring(0, idx) +
          _expandReplacement(rep, null, needle, s, idx) +
          s.substring(idx + needle.length);
    case 'replaceAll':
      final pat = jsToString(args.isEmpty ? jsUndefined : args[0]);
      final rep = args.length > 1 ? args[1] : jsUndefined;
      if (pat.isEmpty) return s;
      final out = StringBuffer();
      var pos = 0;
      while (true) {
        final idx = s.indexOf(pat, pos);
        if (idx < 0) {
          out.write(s.substring(pos));
          break;
        }
        out.write(s.substring(pos, idx));
        out.write(_expandReplacement(rep, null, pat, s, idx));
        pos = idx + pat.length;
      }
      return out.toString();
    case 'repeat':
      final n = args.isEmpty ? 0 : toNumber(args[0]).toInt();
      if (n < 0 || n > 1000000) jsError('String.repeat 参数越界：$n');
      return s * n;
    case 'padStart':
      return _pad(s, args, true);
    case 'padEnd':
      return _pad(s, args, false);
    case 'concat':
      final b = StringBuffer(s);
      for (final a in args) {
        b.write(jsToString(a));
      }
      return b.toString();
    case 'localeCompare':
      final o = jsToString(args.isEmpty ? jsUndefined : args[0]);
      return s.compareTo(o).sign;
    case 'valueOf':
    case 'toString':
      return s;
  }
  return jsUndefined;
}

String _expandReplacement(
    Object? rep, List<String>? groups, String matched, String whole, int idx) {
  if (rep is JsFunctionBase) {
    final args = <Object?>[matched];
    if (groups != null) {
      for (final g in groups) {
        args.add(g == '' ? jsUndefined : g);
      }
    }
    args.add(idx);
    args.add(whole);
    return jsToString(rep.call(jsUndefined, args));
  }
  final r = jsToString(rep);
  final out = StringBuffer();
  for (var i = 0; i < r.length; i++) {
    if (r[i] == r'$' && i + 1 < r.length) {
      final c = r[i + 1];
      if (c == r'$') {
        out.write(r'$');
        i++;
        continue;
      }
      if (c == '&') {
        out.write(matched);
        i++;
        continue;
      }
      if (c == '`') {
        out.write(whole.substring(0, idx));
        i++;
        continue;
      }
      if (c == "'") {
        out.write(whole.substring(idx + matched.length));
        i++;
        continue;
      }
      if (groups != null && c.codeUnitAt(0) >= 0x31 && c.codeUnitAt(0) <= 0x39) {
        final gi = int.parse(c) - 1;
        if (gi < groups.length) {
          out.write(groups[gi]);
          i++;
          continue;
        }
      }
    }
    out.write(r[i]);
  }
  return out.toString();
}

String _pad(String s, List<Object?> args, bool start) {
  final target = args.isEmpty ? 0 : toNumber(args[0]).toInt();
  final fill = args.length > 1 && args[1] is! JsUndefined
      ? jsToString(args[1])
      : ' ';
  if (target <= s.length || fill.isEmpty) return s;
  final need = target - s.length;
  final b = StringBuffer();
  while (b.length < need) {
    b.write(fill);
  }
  final pad = b.toString().substring(0, need);
  return start ? pad + s : s + pad;
}

int _idx(List<Object?> args, int i) {
  if (i >= args.length) return 0;
  final n = toNumber(args[i]);
  if (n.isNaN) return 0;
  return n.truncate();
}

// ---------------------------------------------------------------------------
// Array 方法
// ---------------------------------------------------------------------------

Object? callArrayMethod(JsArray arr, String name, List<Object?> args) {
  final a = arr.items;
  switch (name) {
    case 'push':
      a.addAll(args);
      return a.length;
    case 'pop':
      return a.isEmpty ? jsUndefined : a.removeLast();
    case 'shift':
      return a.isEmpty ? jsUndefined : a.removeAt(0);
    case 'unshift':
      a.insertAll(0, args);
      return a.length;
    case 'slice':
      final len = a.length;
      var start = args.isEmpty ? 0 : _idx(args, 0);
      var end = args.length > 1 && args[1] is! JsUndefined ? _idx(args, 1) : len;
      if (start < 0) start = math.max(0, len + start);
      if (end < 0) end = math.max(0, len + end);
      if (start > len) start = len;
      if (end > len) end = len;
      if (end <= start) return JsArray();
      return JsArray(a.sublist(start, end));
    case 'splice':
      final len = a.length;
      var start = args.isEmpty ? 0 : _idx(args, 0);
      if (start < 0) start = math.max(0, len + start);
      if (start > len) start = len;
      var delCount = args.length > 1
          ? math.max(0, _idx(args, 1)).clamp(0, len - start)
          : len - start;
      final removed = a.sublist(start, start + delCount);
      final insert = args.length > 2 ? args.sublist(2) : <Object?>[];
      a.replaceRange(start, start + delCount, insert);
      return JsArray(removed);
    case 'join':
      final sep = args.isEmpty || args[0] is JsUndefined ? ',' : jsToString(args[0]);
      final parts = <String>[];
      for (final v in a) {
        parts.add(v == null || v is JsUndefined || v is JsNull
            ? ''
            : jsToString(v));
      }
      return parts.join(sep);
    case 'concat':
      final out = <Object?>[...a];
      for (final v in args) {
        if (v is JsArray) {
          out.addAll(v.items);
        } else {
          out.add(v);
        }
      }
      return JsArray(out);
    case 'indexOf':
      final target = args.isEmpty ? jsUndefined : args[0];
      for (var i = 0; i < a.length; i++) {
        if (jsStrictEquals(a[i], target)) return i;
      }
      return -1;
    case 'lastIndexOf':
      final target = args.isEmpty ? jsUndefined : args[0];
      for (var i = a.length - 1; i >= 0; i--) {
        if (jsStrictEquals(a[i], target)) return i;
      }
      return -1;
    case 'includes':
      final target = args.isEmpty ? jsUndefined : args[0];
      for (final v in a) {
        if (jsStrictEquals(v, target)) return true;
        if (v is num && target is num && v.isNaN && target.isNaN) return true;
      }
      return false;
    case 'forEach':
      final fn = _fnArg(args, 'forEach');
      for (var i = 0; i < a.length; i++) {
        fn.call(jsUndefined, [a[i], i, arr]);
      }
      return jsUndefined;
    case 'map':
      final fn = _fnArg(args, 'map');
      final out = <Object?>[];
      for (var i = 0; i < a.length; i++) {
        out.add(fn.call(jsUndefined, [a[i], i, arr]));
      }
      return JsArray(out);
    case 'filter':
      final fn = _fnArg(args, 'filter');
      final out = <Object?>[];
      for (var i = 0; i < a.length; i++) {
        if (jsTruthy(fn.call(jsUndefined, [a[i], i, arr]))) out.add(a[i]);
      }
      return JsArray(out);
    case 'find':
      final fn = _fnArg(args, 'find');
      for (var i = 0; i < a.length; i++) {
        if (jsTruthy(fn.call(jsUndefined, [a[i], i, arr]))) return a[i];
      }
      return jsUndefined;
    case 'findIndex':
      final fn = _fnArg(args, 'findIndex');
      for (var i = 0; i < a.length; i++) {
        if (jsTruthy(fn.call(jsUndefined, [a[i], i, arr]))) return i;
      }
      return -1;
    case 'some':
      final fn = _fnArg(args, 'some');
      for (var i = 0; i < a.length; i++) {
        if (jsTruthy(fn.call(jsUndefined, [a[i], i, arr]))) return true;
      }
      return false;
    case 'every':
      final fn = _fnArg(args, 'every');
      for (var i = 0; i < a.length; i++) {
        if (!jsTruthy(fn.call(jsUndefined, [a[i], i, arr]))) return false;
      }
      return true;
    case 'reduce':
      final fn = _fnArg(args, 'reduce');
      if (a.isEmpty && args.length < 2) {
        jsError('Array.reduce 对空数组没有初始值');
      }
      var acc = args.length > 1 ? args[1] : a[0];
      for (var i = args.length > 1 ? 0 : 1; i < a.length; i++) {
        acc = fn.call(jsUndefined, [acc, a[i], i, arr]);
      }
      return acc;
    case 'reverse':
      // JS 语义：原地反转并返回同一数组
      final rev = a.reversed.toList();
      for (var i = 0; i < a.length; i++) {
        a[i] = rev[i];
      }
      return arr;
    case 'sort':
      final cmp = args.isEmpty ? null : args[0];
      final copy = <Object?>[...a];
      if (cmp is JsFunctionBase) {
        copy.sort((x, y) {
          final r = toNumber(cmp.call(jsUndefined, [x, y]));
          if (r.isNaN) return 0;
          return r.sign.toInt();
        });
      } else {
        copy.sort((x, y) => jsToString(x).compareTo(jsToString(y)));
      }
      a
        ..clear()
        ..addAll(copy);
      return arr;
    case 'fill':
      final v = args.isEmpty ? jsUndefined : args[0];
      final len = a.length;
      var start = args.length > 1 ? _idx(args, 1) : 0;
      var end = args.length > 2 && args[2] is! JsUndefined ? _idx(args, 2) : len;
      if (start < 0) start = math.max(0, len + start);
      if (end < 0) end = math.max(0, len + end);
      for (var i = start; i < end && i < len; i++) {
        a[i] = v;
      }
      return arr;
    case 'flat':
      final depth = args.isEmpty ? 1 : toNumber(args[0]).toInt();
      List<Object?> rec(List<Object?> src, int d) {
        final out = <Object?>[];
        for (final v in src) {
          if (v is JsArray && d > 0) {
            out.addAll(rec(v.items, d - 1));
          } else {
            out.add(v);
          }
        }
        return out;
      }

      return JsArray(rec(a, depth));
    case 'toString':
    case 'join_':
      return jsToString(arr);
    case 'at':
      final i = args.isEmpty ? 0 : _idx(args, 0);
      final idx = i < 0 ? a.length + i : i;
      return (idx < 0 || idx >= a.length) ? jsUndefined : a[idx];
    case 'keys':
      return JsArray([for (var i = 0; i < a.length; i++) i]);
    case 'values':
      return JsArray([...a]);
  }
  return jsUndefined;
}

JsFunctionBase _fnArg(List<Object?> args, String who) {
  if (args.isEmpty || args[0] is! JsFunctionBase) {
    jsError('Array.$who 的第一个参数必须是函数');
  }
  return args[0] as JsFunctionBase;
}

// ---------------------------------------------------------------------------
// Uint8Array 方法
// ---------------------------------------------------------------------------

Object? callU8Method(JsUint8Array u, String name, List<Object?> args) {
  switch (name) {
    case 'set':
      final src = args.isEmpty ? jsUndefined : args[0];
      final off = args.length > 1 ? toNumber(args[1]).toInt() : 0;
      List<int> vals;
      if (src is JsUint8Array) {
        vals = [for (var i = 0; i < src.length; i++) src.get(i)];
      } else if (src is JsArray) {
        vals = [for (final v in src.items) toUint8(v)];
      } else {
        jsError('Uint8Array.set 需要数组或 Uint8Array');
      }
      if (off < 0 || off + vals.length > u.length) {
        jsError('Uint8Array.set 越界：offset=$off, len=${vals.length}, '
            'capacity=${u.length}');
      }
      for (var i = 0; i < vals.length; i++) {
        u.set(off + i, vals[i]);
      }
      return jsUndefined;
    case 'subarray':
      final s = args.isEmpty ? 0 : toNumber(args[0]).toInt();
      final e = args.length > 1 && args[1] is! JsUndefined
          ? toNumber(args[1]).toInt()
          : null;
      return u.subarray(s, e);
    case 'slice':
      final s = args.isEmpty ? 0 : toNumber(args[0]).toInt();
      final e = args.length > 1 && args[1] is! JsUndefined
          ? toNumber(args[1]).toInt()
          : u.length;
      final sub = u.subarray(s, e);
      return JsUint8Array(Uint8List.fromList(sub.toBytes()));
    case 'fill':
      final v = args.isEmpty ? 0 : toUint8(args[0]);
      for (var i = 0; i < u.length; i++) {
        u.set(i, v);
      }
      return u;
    case 'indexOf':
      final v = args.isEmpty ? 0 : toUint8(args[0]);
      for (var i = 0; i < u.length; i++) {
        if (u.get(i) == v) return i;
      }
      return -1;
    case 'join':
      final sep = args.isEmpty ? ',' : jsToString(args[0]);
      return [for (var i = 0; i < u.length; i++) u.get(i)].join(sep);
    case 'toString':
      return jsToString(u);
  }
  return jsUndefined;
}

// ---------------------------------------------------------------------------
// Date
// ---------------------------------------------------------------------------

class JsDate {
  final DateTime dt;
  JsDate(this.dt);
}

Object? callDateMethod(JsDate d, String name, List<Object?> args) {
  final t = d.dt; // 已按本地时区构造
  switch (name) {
    case 'getFullYear':
      return t.year;
    case 'getMonth':
      return t.month - 1;
    case 'getDate':
      return t.day;
    case 'getDay':
      return t.weekday % 7;
    case 'getHours':
      return t.hour;
    case 'getMinutes':
      return t.minute;
    case 'getSeconds':
      return t.second;
    case 'getMilliseconds':
      return t.millisecond ~/ 1000;
    case 'getTime':
    case 'valueOf':
      return t.millisecondsSinceEpoch;
    case 'toISOString':
      return t.toUtc().toIso8601String();
    case 'toJSON':
      return t.toUtc().toIso8601String();
    case 'toString':
      return _formatLocal(t);
    case 'getTimezoneOffset':
      return -t.timeZoneOffset.inMinutes;
    case 'setTime':
      return jsUndefined;
  }
  return jsUndefined;
}

String _formatLocal(DateTime t) {
  const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  String two(int v) => v.toString().padLeft(2, '0');
  final off = t.timeZoneOffset;
  final sign = off.isNegative ? '-' : '+';
  final absMin = off.inMinutes.abs();
  return '${wd[t.weekday - 1]} ${mo[t.month - 1]} ${two(t.day)} ${t.year} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)} '
      'GMT$sign${two(absMin ~/ 60)}${two(absMin % 60)}';
}

// ---------------------------------------------------------------------------
// RegExp（最小实现：字面量不承诺，但 String.split/replace 的常见用法要能用）
// ---------------------------------------------------------------------------

class JsRegExp {
  final RegExp re;
  final bool global;
  JsRegExp(String pattern, {this.global = false, bool ignoreCase = false})
      : re = RegExp(pattern, caseSensitive: !ignoreCase);

  List<String> split(String s) =>
      s.split(re).map((e) => e).toList();

  String replace(String s, Object? rep, {required bool all}) {
    final out = StringBuffer();
    var last = 0;
    for (final m in re.allMatches(s)) {
      out.write(s.substring(last, m.start));
      final groups = <String>[
        for (var i = 1; i <= m.groupCount; i++) m.group(i) ?? ''
      ];
      out.write(_expandReplacement(rep, groups, m.group(0)!, s, m.start));
      last = m.end;
      if (!all) break;
    }
    out.write(s.substring(last));
    return out.toString();
  }
}

// ---------------------------------------------------------------------------
// JSON
// ---------------------------------------------------------------------------

Object? jsonParse(String text) {
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (e) {
    jsError('JSON.parse 失败：${e.message}');
  }
  return _fromDart(decoded);
}

Object? _fromDart(Object? v) {
  if (v == null) return jsNull;
  if (v is List) return JsArray(v.map(_fromDart).toList());
  if (v is Map) {
    final o = JsObject();
    v.forEach((k, val) => o.setProp(k.toString(), _fromDart(val)));
    return o;
  }
  return v;
}

String jsonStringify(Object? v) {
  final b = StringBuffer();
  void write(Object? x, int depth, Set<Object> seen) {
    if (x == null || x is JsNull) {
      b.write('null');
      return;
    }
    if (x is JsUndefined) return;
    if (x is bool) {
      b.write(x ? 'true' : 'false');
      return;
    }
    if (x is num) {
      if (x.isNaN || x.isInfinite) {
        b.write('null');
      } else {
        b.write(numToJsString(x));
      }
      return;
    }
    if (x is String) {
      b.write(jsonEncode(x));
      return;
    }
    if (x is JsFunctionBase) return;
    if (seen.contains(x)) jsError('JSON.stringify 遇到循环引用');
    seen.add(x);
    if (x is JsArray) {
      b.write('[');
      for (var i = 0; i < x.items.length; i++) {
        if (i > 0) b.write(',');
        write(x.items[i], depth + 1, seen);
      }
      b.write(']');
    } else if (x is JsObject) {
      b.write('{');
      var first = true;
      x.props.forEach((k, val) {
        if (val is JsUndefined || val is JsFunctionBase) return;
        if (!first) b.write(',');
        first = false;
        b.write(jsonEncode(k));
        b.write(':');
        write(val, depth + 1, seen);
      });
      b.write('}');
    } else if (x is JsUint8Array) {
      b.write('{');
      b.write(jsonEncode('__bytes__'));
      b.write(':');
      b.write(jsonEncode(_hex(x.toBytes())));
      b.write('}');
    } else {
      b.write('null');
    }
    seen.remove(x);
  }

  write(v, 0, <Object>{});
  return b.toString();
}

const _hexDigits = '0123456789abcdef';

String _hex(List<int> bytes) {
  final b = StringBuffer();
  for (final x in bytes) {
    b.write(_hexDigits[(x >> 4) & 0xF]);
    b.write(_hexDigits[x & 0xF]);
  }
  return b.toString();
}

// ---------------------------------------------------------------------------
// 全局环境
// ---------------------------------------------------------------------------

/// 构建全局作用域对象：内建函数与对象。
///
/// [now] 与 [random] 由引擎注入（规范 §12：时钟与种子可控、可复现）。
JsObject buildGlobals({
  required DateTime Function() now,
  required math.Random random,
}) {
  final g = JsObject();

  // 禁用桩：调用即 E_JS
  for (final banned in [
    'eval', 'Function', 'setTimeout', 'setInterval',
    'clearTimeout', 'clearInterval', 'fetch', 'XMLHttpRequest', 'require',
  ]) {
    g.setProp(
      banned,
      JsNativeFunction(banned, (t, a) {
        jsError('沙箱禁用 $banned（规范 §12）');
      }),
    );
  }

  g.setProp('undefined', jsUndefined);
  g.setProp('NaN', double.nan);
  g.setProp('Infinity', double.infinity);

  g.setProp(
    'parseInt',
    JsNativeFunction('parseInt', (t, a) {
      if (a.isEmpty) return double.nan;
      final s = jsToString(a[0]).trim();
      var radix = a.length > 1 ? toNumber(a[1]).toInt() : 10;
      var body = s;
      var sign = 1;
      if (body.startsWith('-')) {
        sign = -1;
        body = body.substring(1);
      } else if (body.startsWith('+')) {
        body = body.substring(1);
      }
      if ((radix == 0 || radix == 16) &&
          (body.startsWith('0x') || body.startsWith('0X'))) {
        body = body.substring(2);
        radix = 16;
      }
      if (radix == 0) radix = 10;
      if (radix < 2 || radix > 36) return double.nan;
      final m = RegExp('^[0-9a-zA-Z]+').firstMatch(body);
      if (m == null) return double.nan;
      var digits = m.group(0)!;
      // 截掉超出基数范围的尾部字符
      var valid = 0;
      for (var i = 0; i < digits.length; i++) {
        final c = digits.codeUnitAt(i);
        int d;
        if (c >= 0x30 && c <= 0x39) {
          d = c - 0x30;
        } else if (c >= 0x61 && c <= 0x7A) {
          d = c - 0x61 + 10;
        } else if (c >= 0x41 && c <= 0x5A) {
          d = c - 0x41 + 10;
        } else {
          break;
        }
        if (d >= radix) break;
        valid++;
      }
      digits = digits.substring(0, valid);
      if (digits.isEmpty) return double.nan;
      final v = int.tryParse(digits, radix: radix);
      return v == null ? double.nan : sign * v;
    }),
  );

  g.setProp(
    'parseFloat',
    JsNativeFunction('parseFloat', (t, a) {
      if (a.isEmpty) return double.nan;
      final s = jsToString(a[0]).trim();
      final m =
          RegExp(r'^[+-]?(\d+\.?\d*([eE][+-]?\d+)?|\.\d+([eE][+-]?\d+)?)')
              .firstMatch(s);
      if (m == null) return double.nan;
      final v = double.tryParse(m.group(0)!);
      return v == null ? double.nan : jsNum(v);
    }),
  );

  g.setProp('isNaN', JsNativeFunction('isNaN', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    return n.isNaN;
  }));
  g.setProp('isFinite', JsNativeFunction('isFinite', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    return !n.isNaN && !n.isInfinite;
  }));

  // String 构造器
  final JsNativeFunction stringCtor = JsNativeFunction('String', (t, a) {
    if (a.isEmpty) return '';
    if (a[0] is JsUint8Array) return jsToString(a[0]);
    return jsToString(a[0]);
  });
  final stringProto = JsObject();
  stringProto.setProp('fromCharCode', JsNativeFunction('fromCharCode', (t, a) {
    final b = StringBuffer();
    for (final x in a) {
      b.writeCharCode(toUint32(x) & 0xFFFF);
    }
    return b.toString();
  }));
  stringProto.setProp('fromCodePoint', JsNativeFunction('fromCodePoint', (t, a) {
    final b = StringBuffer();
    for (final x in a) {
      b.writeCharCode(toUint32(x));
    }
    return b.toString();
  }));
  g.setProp('String', stringCtor);
  _attachStatics(stringCtor, stringProto);

  // Number / Boolean / Object
  g.setProp('Number', JsNativeFunction('Number', (t, a) {
    return toNumber(a.isEmpty ? 0 : a[0]);
  }));
  g.setProp('Boolean', JsNativeFunction('Boolean', (t, a) {
    return jsTruthy(a.isEmpty ? jsUndefined : a[0]);
  }));
  g.setProp(
    'Object',
    JsNativeFunction('Object', (t, a) {
      if (a.isEmpty) return JsObject();
      final v = a[0];
      if (v is JsObject) return v;
      if (v is JsArray || v is JsUint8Array) return v;
      final o = JsObject();
      o.setProp('valueOf', JsNativeFunction('valueOf', (_, __) => v));
      return o;
    }),
  );

  // Array
  final JsNativeFunction arrayCtor = JsNativeFunction('Array', (t, a) {
    if (a.length == 1 && a[0] is num) {
      final n = toNumber(a[0]).toInt();
      if (n < 0) jsError('Array 长度不能为负');
      return JsArray(List<Object?>.filled(n, jsUndefined));
    }
    return JsArray([...a]);
  });
  final arrayProto = JsObject();
  arrayProto.setProp(
    'isArray',
    JsNativeFunction('isArray', (t, a) => a.isNotEmpty && a[0] is JsArray),
  );
  arrayProto.setProp('from', JsNativeFunction('from', (t, a) {
    if (a.isEmpty) return JsArray();
    final v = a[0];
    if (v is JsArray) return JsArray([...v.items]);
    if (v is JsUint8Array) {
      return JsArray([for (var i = 0; i < v.length; i++) v.get(i)]);
    }
    if (v is String) return JsArray(v.split('').cast<Object?>());
    return JsArray();
  }));
  _attachStatics(arrayCtor, arrayProto);
  g.setProp('Array', arrayCtor);

  // Uint8Array
  final JsNativeFunction u8Ctor = JsNativeFunction('Uint8Array', (t, a) {
    if (a.isEmpty) return JsUint8Array.ofLength(0);
    final x = a[0];
    if (x is num) {
      final n = x.toInt();
      if (n < 0) jsError('Uint8Array 长度不能为负');
      return JsUint8Array.ofLength(n);
    }
    if (x is JsArray) return JsUint8Array.fromList(x.items);
    if (x is JsUint8Array) return JsUint8Array(Uint8List.fromList(x.toBytes()));
    jsError('Uint8Array 构造参数不支持该类型');
  });
  final u8Proto = JsObject();
  u8Proto.setProp('from', JsNativeFunction('from', (t, a) {
    if (a.isEmpty) return JsUint8Array.ofLength(0);
    final v = a[0];
    if (v is JsArray) return JsUint8Array.fromList(v.items);
    if (v is JsUint8Array) {
      return JsUint8Array(Uint8List.fromList(v.toBytes()));
    }
    return JsUint8Array.ofLength(0);
  }));
  _attachStatics(u8Ctor, u8Proto);
  g.setProp('Uint8Array', u8Ctor);
  // Int8Array 等别名到 Uint8Array（插件里少见，但避免直接报未定义）
  g.setProp('Int8Array', u8Ctor);
  g.setProp('Uint8ClampedArray', u8Ctor);

  // Math
  final m = JsObject();
  m.setProp('PI', math.pi);
  m.setProp('E', math.e);
  m.setProp('LN10', math.ln10);
  m.setProp('LN2', math.ln2);
  m.setProp('SQRT2', math.sqrt2);
  m.setProp('floor', JsNativeFunction('floor', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    return n.isNaN || n.isInfinite ? n : n.floorToDouble().toInt();
  }));
  m.setProp('ceil', JsNativeFunction('ceil', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    return n.isNaN || n.isInfinite ? n : n.ceilToDouble().toInt();
  }));
  m.setProp('round', JsNativeFunction('round', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    if (n.isNaN || n.isInfinite) return n;
    // JS 的 round 是 floor(x + 0.5)
    return (n + 0.5).floorToDouble().toInt();
  }));
  m.setProp('trunc', JsNativeFunction('trunc', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    return n.isNaN || n.isInfinite ? n : n.truncateToDouble().toInt();
  }));
  m.setProp('abs', JsNativeFunction('abs', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    return jsNum(n.abs());
  }));
  m.setProp('sqrt', JsNativeFunction('sqrt', (t, a) {
    return jsNum(math.sqrt(toNumber(a.isEmpty ? jsUndefined : a[0])));
  }));
  m.setProp('pow', JsNativeFunction('pow', (t, a) {
    final b = toNumber(a.isEmpty ? jsUndefined : a[0]);
    final e = toNumber(a.length < 2 ? jsUndefined : a[1]);
    final r = math.pow(b, e);
    return jsNum(r.toDouble());
  }));
  m.setProp('log', JsNativeFunction('log', (t, a) {
    return jsNum(math.log(toNumber(a.isEmpty ? jsUndefined : a[0])));
  }));
  m.setProp('exp', JsNativeFunction('exp', (t, a) {
    return jsNum(math.exp(toNumber(a.isEmpty ? jsUndefined : a[0])));
  }));
  m.setProp('min', JsNativeFunction('min', (t, a) {
    if (a.isEmpty) return double.infinity;
    var best = toNumber(a[0]);
    for (var i = 1; i < a.length; i++) {
      final v = toNumber(a[i]);
      if (v.isNaN) return double.nan;
      if (v < best) best = v;
    }
    return jsNum(best);
  }));
  m.setProp('max', JsNativeFunction('max', (t, a) {
    if (a.isEmpty) return double.negativeInfinity;
    var best = toNumber(a[0]);
    for (var i = 1; i < a.length; i++) {
      final v = toNumber(a[i]);
      if (v.isNaN) return double.nan;
      if (v > best) best = v;
    }
    return jsNum(best);
  }));
  m.setProp('sign', JsNativeFunction('sign', (t, a) {
    final n = toNumber(a.isEmpty ? jsUndefined : a[0]);
    if (n.isNaN) return double.nan;
    return n > 0 ? 1 : (n < 0 ? -1 : n);
  }));
  // Math.random 由注入的种子驱动（规范 §12：可复现）
  m.setProp(
    'random',
    JsNativeFunction('random', (t, a) => random.nextDouble()),
  );
  g.setProp('Math', m);

  // Date
  final JsNativeFunction dateCtor = JsNativeFunction('Date', (t, a) {
    if (a.isEmpty) return JsDate(now());
    if (a.length == 1) {
      final v = a[0];
      if (v is num) {
        return JsDate(
          DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: false),
        );
      }
      final parsed = DateTime.tryParse(jsToString(v));
      if (parsed == null) return JsDate(DateTime.fromMillisecondsSinceEpoch(0));
      return JsDate(parsed.toLocal());
    }
    final y = toNumber(a[0]).toInt();
    final mo = a.length > 1 ? toNumber(a[1]).toInt() : 0;
    final d = a.length > 2 ? toNumber(a[2]).toInt() : 1;
    final h = a.length > 3 ? toNumber(a[3]).toInt() : 0;
    final mi = a.length > 4 ? toNumber(a[4]).toInt() : 0;
    final s = a.length > 5 ? toNumber(a[5]).toInt() : 0;
    final ms = a.length > 6 ? toNumber(a[6]).toInt() : 0;
    return JsDate(DateTime(y, mo + 1, d, h, mi, s, ms));
  });
  final dateProto = JsObject();
  dateProto.setProp(
    'now',
    JsNativeFunction('now', (t, a) => now().millisecondsSinceEpoch),
  );
  dateProto.setProp('parse', JsNativeFunction('parse', (t, a) {
    final p = DateTime.tryParse(jsToString(a.isEmpty ? jsUndefined : a[0]));
    return p == null ? double.nan : p.millisecondsSinceEpoch;
  }));
  _attachStatics(dateCtor, dateProto);
  g.setProp('Date', dateCtor);

  // ES5 标准错误构造器：new Error(msg) / new TypeError(msg) …
  for (final errName in [
    'Error', 'TypeError', 'RangeError', 'ReferenceError', 'SyntaxError',
    'EvalError', 'URIError',
  ]) {
    g.setProp(
      errName,
      JsNativeFunction(errName, (t, a) {
        final o = JsObject();
        o.setProp('name', errName);
        o.setProp('message', a.isEmpty ? '' : jsToString(a[0]));
        o.setProp('toString', JsNativeFunction('toString', (t2, a2) {
          final msg = jsToString(o.getProp('message') ?? '');
          return msg.isEmpty ? errName : '$errName: $msg';
        }));
        return o;
      }),
    );
  }

  // RegExp（字面量语法不承诺，但 String.split/replace 传 RegExp 对象要能用）
  final regExpCtor = JsNativeFunction('RegExp', (t, a) {
    final pattern = a.isEmpty ? '' : jsToString(a[0]);
    final flags = a.length > 1 ? jsToString(a[1]) : '';
    return JsRegExp(pattern,
        global: flags.contains('g'), ignoreCase: flags.contains('i'));
  });
  g.setProp('RegExp', regExpCtor);

  // JSON
  final json = JsObject();
  json.setProp('parse', JsNativeFunction('parse', (t, a) {
    final s = jsToString(a.isEmpty ? jsUndefined : a[0]);
    return jsonParse(s);
  }));
  json.setProp('stringify', JsNativeFunction('stringify', (t, a) {
    if (a.isEmpty) return jsUndefined;
    return jsonStringify(a[0]);
  }));
  g.setProp('JSON', json);

  // 自引用：window = self = globalThis
  g.setProp('window', g);
  g.setProp('self', g);
  g.setProp('globalThis', g);

  return g;
}

/// 把静态方法挂到构造函数对象上（JS 里 `String.fromCharCode` 就是构造器属性）。
void _attachStatics(Object ctor, JsObject statics) {
  final target = (ctor as JsNativeFunction).props;
  statics.props.forEach(target.setProp);
}
