/// set.js 沙箱的运行时值模型。
///
/// 设计要点：
/// - Dart 侧用少量原生类型直接表示 JS 值：num（num）、String、bool、JsUndefined、
///   JsNull、List（JS Array）、JsObject、JsFunction/Uint8Array。
/// - JS 的数字语义遵循 Double：所有 number 运算结果经 [_toNumber] 收敛，
///   整数值仍以 int 保存（避免大整数运算退化成浮点误差）。
/// - bytes 跨边界用 `{"__bytes__":"<hex>"}` 包装（契约 §4），在 interp 里转换。
library;

import 'dart:typed_data';

/// JS `undefined`
class JsUndefined {
  const JsUndefined._();
  @override
  String toString() => 'undefined';
}

/// JS `null`
class JsNull {
  const JsNull._();
  @override
  String toString() => 'null';
}

const JsUndefined jsUndefined = JsUndefined._();
const JsNull jsNull = JsNull._();

/// JS 普通对象。
class JsObject {
  final Map<String, Object?> props;

  JsObject([Map<String, Object?>? props]) : props = props ?? <String, Object?>{};

  /// 构造函数的原型对象（用于 `new` 出来的实例查方法）。
  JsObject? proto;

  Object? getProp(String key) {
    if (props.containsKey(key)) return props[key];
    final p = proto;
    if (p != null) return p.getProp(key);
    return null; // 由调用方决定是否给出 Object.prototype 上的方法
  }

  bool hasOwn(String key) => props.containsKey(key);

  void setProp(String key, Object? value) {
    props[key] = value;
  }

  bool deleteProp(String key) => props.remove(key) != null;
}

/// JS 数组（语义接近 Array，length 由 Dart List 长度承载）。
class JsArray {
  final List<Object?> items;

  JsArray([List<Object?>? items]) : items = items ?? <Object?>[];

  int get length => items.length;
}

/// JS 函数（用户定义或内建）。
abstract class JsFunctionBase {
  String get name;
  Object? call(Object? thisVal, List<Object?> args);
}

/// 由 AST 定义的用户函数。
class JsUserFunction extends JsFunctionBase {
  @override
  final String name;
  final List<String> params;
  final Object body; // List<Stmt>，为避免循环依赖用 Object
  final Object? closureScope; // JsScope，同上
  final JsObject prototype;
  final JsObject props; // 函数自身的属性（自定义静态成员）

  JsUserFunction(
    this.name,
    this.params,
    this.body,
    this.closureScope, {
    JsObject? prototype,
  })  : prototype = prototype ?? JsObject(),
        props = JsObject();

  @override
  Object? call(Object? thisVal, List<Object?> args) =>
      throw UnsupportedError('由 interp 调用');
}

/// 内建函数（宿主提供）。JS 里函数也是对象，故带 [props] 承载静态成员
/// （如 `String.fromCharCode`、`Array.isArray`）。
class JsNativeFunction extends JsFunctionBase {
  @override
  final String name;
  final Object? Function(Object? thisVal, List<Object?> args) fn;
  final JsObject props;

  JsNativeFunction(this.name, this.fn, {JsObject? props})
      : props = props ?? JsObject();

  @override
  Object? call(Object? thisVal, List<Object?> args) => fn(thisVal, args);
}

/// JS `Uint8Array`。数据在 [bytes] 中，[offset]/[length] 支持 subarray 视图。
class JsUint8Array {
  final Uint8List bytes;
  final int offset;
  final int length;

  JsUint8Array(this.bytes, [this.offset = 0, int? length])
      : length = length ?? (bytes.length - offset);

  factory JsUint8Array.ofLength(int n) => JsUint8Array(Uint8List(n), 0, n);

  factory JsUint8Array.fromList(List<Object?> items) {
    final b = Uint8List(items.length);
    for (var i = 0; i < items.length; i++) {
      b[i] = toUint8(items[i]);
    }
    return JsUint8Array(b, 0, b.length);
  }

  int get(int i) {
    if (i < 0 || i >= length) return 0; // 越界读返回 undefined，由 interp 处理
    return bytes[offset + i];
  }

  bool inRange(int i) => i >= 0 && i < length;

  void set(int i, int v) {
    if (i >= 0 && i < length) bytes[offset + i] = v & 0xFF;
  }

  JsUint8Array subarray(int start, [int? end]) {
    var s = start < 0 ? length + start : start;
    if (s < 0) s = 0;
    if (s > length) s = length;
    var e = end == null ? length : (end < 0 ? length + end : end);
    if (e < s) e = s;
    if (e > length) e = length;
    return JsUint8Array(bytes, offset + s, e - s);
  }

  Uint8List toBytes() => Uint8List.sublistView(bytes, offset, offset + length);
}

/// 把任意 JS 值收敛为 Uint8（用于 TypedArray 赋值）。
int toUint8(Object? v) {
  final n = toNumber(v);
  if (n.isNaN || n.isInfinite) return 0;
  return n.toInt() & 0xFF;
}

/// JS ToNumber 语义。
num toNumber(Object? v) {
  if (v is num) return v;
  if (v is bool) return v ? 1 : 0;
  if (v == null || v is JsUndefined || v is JsNull) {
    return v is JsUndefined ? double.nan : 0;
  }
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return 0;
    final parsed = double.tryParse(s);
    if (parsed != null) return _normalizeInt(parsed);
    if (s.startsWith('0x') || s.startsWith('0X')) {
      final i = int.tryParse(s.substring(2), radix: 16);
      if (i != null) return i;
    }
    return double.nan;
  }
  if (v is JsUint8Array) {
    // `'' + typedArray` 在 JS 里是逗号拼接，但 ToNumber 场景极少，按 NaN 处理
    return double.nan;
  }
  return double.nan;
}

num _normalizeInt(double d) {
  if (d == d.truncate() && d.abs() < 9007199254740992) return d.toInt();
  return d;
}

/// 把结果收敛：整数值存为 int，其余保留 double。
num jsNum(num v) => v is double ? _normalizeInt(v) : v;

/// JS ToInt32（用于位运算）。
int toInt32(Object? v) {
  final n = toNumber(v);
  if (n.isNaN || n.isInfinite) return 0;
  final t = n.truncate();
  return (t & 0xFFFFFFFF).toSigned(32);
}

/// JS ToUint32（用于 `>>>`）。
int toUint32(Object? v) {
  final n = toNumber(v);
  if (n.isNaN || n.isInfinite) return 0;
  return n.truncate() & 0xFFFFFFFF;
}

/// JS ToString（对象走 [object Object]，数组走逗号拼接）。
String jsToString(Object? v) {
  if (v is String) return v;
  if (v is num) return numToJsString(v);
  if (v is bool) return v ? 'true' : 'false';
  if (v == null || v is JsNull) return 'null';
  if (v is JsUndefined) return 'undefined';
  if (v is JsArray) {
    final parts = <String>[];
    for (final item in v.items) {
      if (item == null || item is JsUndefined || item is JsNull) {
        parts.add('');
      } else {
        parts.add(jsToString(item));
      }
    }
    return parts.join(',');
  }
  if (v is JsUint8Array) {
    final parts = <String>[];
    for (var i = 0; i < v.length; i++) {
      parts.add(v.get(i).toString());
    }
    return parts.join(',');
  }
  if (v is JsFunctionBase) return 'function ${v.name}() { [native code] }';
  if (v is JsObject) return '[object Object]';
  return v.toString();
}

/// JS 数字字面量格式（整数值不带 `.0`）。
String numToJsString(num v) {
  if (v is int) return v.toString();
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
  if (v == v.truncate() && v.abs() < 1e21) return v.toInt().toString();
  return v.toString();
}

/// JS 真值判断。
bool jsTruthy(Object? v) {
  if (v == null || v is JsUndefined || v is JsNull) return false;
  if (v is bool) return v;
  if (v is num) return v != 0 && !v.isNaN;
  if (v is String) return v.isNotEmpty;
  return true;
}

/// `typeof` 结果。
String jsTypeOf(Object? v) {
  if (v == null || v is JsNull) return 'object';
  if (v is JsUndefined) return 'undefined';
  if (v is bool) return 'boolean';
  if (v is num) return 'number';
  if (v is String) return 'string';
  if (v is JsFunctionBase) return 'function';
  return 'object';
}

/// 严格相等 `===`。
bool jsStrictEquals(Object? a, Object? b) {
  // undefined 与 null 严格不等
  if (a is JsUndefined) return b is JsUndefined;
  if (a is JsNull) return b is JsNull;
  if (b is JsUndefined || b is JsNull) return false;
  if (a == null) return false;
  if (a is num) return b is num && a == b;
  if (a is String) return b is String && a == b;
  if (a is bool) return b is bool && a == b;
  return identical(a, b);
}
