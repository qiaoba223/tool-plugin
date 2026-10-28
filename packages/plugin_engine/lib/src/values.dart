/// 值的内部表示与渲染规则（对应上游 §1.4「值类型与渲染」）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

/// 表达式求值结果的 7 种类型：string / int / double / bool / null / bytes /
/// list / map。Dart 侧用 `Object?` 承载，`Uint8List` 表示 bytes。
typedef PinValue = Object?;

/// 是否为 bytes。
bool isBytes(Object? v) => v is Uint8List;

/// 按上游 §1.4 的规则把值渲染为字符串。
///
/// - string → 原样
/// - int → 十进制
/// - double → Dart `toString()` 语义（`3.0` → `"3.0"`，`1e21` → `"1e+21"`）
/// - bool → `"true"` / `"false"`
/// - null → 空串
/// - list / map → 紧凑 JSON（无空格）
/// - bytes → 报 `E_TYPE`
String renderValue(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is bool) return v ? 'true' : 'false';
  if (v is int) return v.toString();
  if (v is double) return v.toString();
  if (v is Uint8List) {
    throw err(ErrorCodes.type, 'bytes 不能直接渲染成字符串，请先经 '
        'fn.b64 / fn.hex / fn.latin1 转换');
  }
  if (v is List) return jsonEncode(v);
  if (v is Map) return jsonEncode(_jsonSafe(v));
  return v.toString();
}

/// jsonEncode 无法直接处理 Uint8List，转为契约的 `{"__bytes__":"<hex>"}` 线格式。
Object? _jsonSafe(Object? v) {
  if (v is Uint8List) return {'__bytes__': bytesToHex(v)};
  if (v is Map) {
    return {for (final e in v.entries) '${e.key}': _jsonSafe(e.value)};
  }
  if (v is List) return [for (final e in v) _jsonSafe(e)];
  return v;
}

/// bytes → 小写 hex。
String bytesToHex(Uint8List b) {
  const hexChars = '0123456789abcdef';
  final sb = StringBuffer();
  for (final byte in b) {
    sb.write(hexChars[(byte >> 4) & 0xF]);
    sb.write(hexChars[byte & 0xF]);
  }
  return sb.toString();
}

/// hex → bytes。奇数长度 / 非法字符报 `E_ARG`。
Uint8List hexToBytes(String s) {
  if (s.length.isOdd) {
    throw err(ErrorCodes.arg, 'hex 字符串长度必须为偶数，实际 ${s.length}');
  }
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final hi = _hexDigit(s.codeUnitAt(i * 2));
    final lo = _hexDigit(s.codeUnitAt(i * 2 + 1));
    if (hi < 0 || lo < 0) {
      throw err(ErrorCodes.arg, 'hex 字符串含非法字符：$s');
    }
    out[i] = (hi << 4) | lo;
  }
  return out;
}

int _hexDigit(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return -1;
}

/// 上游 §4.2 的比较语义：
/// - 两侧同为数字 → 数值比较
/// - 两侧同为 bytes → 逐字节字典序
/// - bytes 与 string 混合 → `==` 恒 false、`!=` 恒 true，不做隐式转换
/// - 其余 → 转字符串字典序
int compareValues(Object? a, Object? b) {
  if (a is num && b is num) return a.compareTo(b);

  final ab = a is Uint8List;
  final bb = b is Uint8List;
  if (a is Uint8List && b is Uint8List) return _compareBytes(a, b);
  if (ab != bb) {
    // §4.3：bytes 与非 bytes 混合不做隐式转换。
    // `<`/`>` 排序需要一个稳定结果：bytes 一侧恒小，保证可比且不抛异常。
    return ab ? -1 : 1;
  }
  return renderValue(a).compareTo(renderValue(b));
}

/// `==` 语义（含混合 bytes 规则）。
bool valuesEqual(Object? a, Object? b) {
  if (a is Uint8List && b is Uint8List) return _compareBytes(a, b) == 0;
  if ((a is Uint8List) != (b is Uint8List)) {
    // 一侧 bytes 一侧非 bytes：恒 false
    return false;
  }
  if (a is num && b is num) return a == b;
  if (a == null && b == null) return true;
  if (a == null || b == null) {
    // null 与非 null：按渲染规则（null → 空串）比较，与上游 toString 语义一致
    return renderValue(a) == renderValue(b);
  }
  return renderValue(a) == renderValue(b);
}

bool valuesNotEqual(Object? a, Object? b) {
  if ((a is Uint8List) != (b is Uint8List)) return true;
  return !valuesEqual(a, b);
}

/// 通用比较（`>` `<` `>=` `<=`），混合 bytes 时按字典序退化。
int compareForOrder(Object? a, Object? b) => compareValues(a, b);

int _compareBytes(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}
