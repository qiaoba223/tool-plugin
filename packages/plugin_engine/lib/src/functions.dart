/// `fn.*` 函数库 —— 73 个，签名与语义对齐上游：
/// - 签名表 `FN_SPECS`（来自 `schema/validate.py`，上游注释明确要求它与
///   `engine/lib/src/functions.dart` 的 `functionNames` 完全同步）
/// - 行为描述 `docs/PLUGIN_JSON_GUIDE.md` 第 8 节
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:asn1lib/asn1lib.dart' as asn1;
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/export.dart' as pc;

import 'errors.dart';
import 'gbk_tables.dart';
import 'values.dart';

/// 函数签名表：名字 → (最少参数, 最多参数, 返回类型)。
/// 返回类型用于静态推断：`int` / `double` / `string` / `bool` / `bytes` /
/// `list` / `any` / `same`（同首参）。
const Map<String, (int, int, String)> fnSpecs = {
  // 编码 / 转换
  'b64': (1, 1, 'string'),
  'b64d': (1, 1, 'string'),
  'hex': (1, 1, 'string'),
  'unhex': (1, 1, 'bytes'),
  'utf8': (1, 1, 'bytes'),
  'latin1': (1, 1, 'string'),
  'urlenc': (1, 1, 'string'),
  'gz': (1, 1, 'bytes'),
  'gunz': (1, 1, 'bytes'),
  // 哈希
  'md5': (1, 1, 'string'),
  'sha1': (1, 1, 'string'),
  'sha256': (1, 1, 'string'),
  'hmacSha256': (2, 2, 'string'),
  'crc32': (1, 1, 'string'),
  // 加密
  // ★ 与上游 FN_SPECS 的已知偏差：上游表写 (2,2)，但规范 §8.3 定义
  //   fn.rsaPkcs1(pubB64, plaintext, bt?) 且 plugin-harbor/unicom.login 实际传 3 个参数。
  //   以规范正文 + 真实插件为准，接受 2..3。见 contract/ALIGNMENT.md「已知不一致」。
  'rsaPkcs1': (2, 3, 'string'),
  'aesCbc': (3, 3, 'string'),
  'aesEcb': (2, 2, 'string'),
  // 逆向常用自定义编码
  'shift2': (1, 1, 'string'),
  'shiftN': (2, 2, 'string'),
  'padRight': (3, 3, 'string'),
  'padLeft': (3, 3, 'string'),
  'repeat': (2, 2, 'string'),
  'substring': (2, 3, 'string'),
  'concat': (1, 99, 'same'),
  'len': (1, 1, 'int'),
  'trim': (1, 1, 'string'),
  'upper': (1, 1, 'string'),
  'lower': (1, 1, 'string'),
  // bytes 操作
  'bytesReplace': (3, 3, 'bytes'),
  'be32Write': (3, 3, 'bytes'),
  'be32Read': (2, 2, 'int'),
  'slice': (2, 3, 'same'),
  'indexOf': (2, 3, 'int'),
  'at': (2, 2, 'int'),
  'scanAscii': (3, 3, 'string'),
  // 随机 / 时间
  'randomHex': (1, 1, 'string'),
  'randomDigits': (1, 1, 'string'),
  'randomOf': (1, 1, 'any'),
  'randomInt': (2, 2, 'int'),
  'randomModOffset': (2, 2, 'string'),
  'uuid': (0, 0, 'string'),
  'now': (0, 0, 'int'),
  'ts14': (0, 0, 'string'),
  'ts10': (0, 0, 'string'),
  'ts13': (0, 0, 'string'),
  // 其他
  'coalesce': (1, 99, 'any'),
  'default': (2, 2, 'any'),
  // v1.3 新增
  'unb64': (1, 1, 'bytes'),
  'b64url': (1, 1, 'string'),
  'unb64url': (1, 1, 'bytes'),
  // v1.4 新增
  'replace': (3, 3, 'string'),
  'replaceRegex': (3, 3, 'string'),
  'split': (2, 2, 'list'),
  'startsWith': (2, 2, 'bool'),
  'endsWith': (2, 2, 'bool'),
  'toInt': (1, 1, 'int'),
  'toFloat': (1, 1, 'float'),
  'toString': (1, 1, 'string'),
  'charsetDecode': (2, 2, 'string'),
  'htmlUnescape': (1, 1, 'string'),
  'htmlEscape': (1, 1, 'string'),
  'count': (1, 1, 'int'),
  'first': (1, 1, 'any'),
  'last': (1, 1, 'any'),
  'nth': (2, 2, 'any'),
  // v1.6 日期处理
  'toDate': (1, 2, 'string'),
  'dateFormat': (2, 2, 'string'),
  'daysBeforeNow': (1, 1, 'int'),
  'daysAfterNow': (1, 1, 'int'),
  // v1.7 二进制 / JSON 处理
  'jsonParse': (1, 1, 'any'),
  'be16Write': (3, 3, 'bytes'),
  'be16Read': (2, 2, 'int'),
  'u8Write': (3, 3, 'bytes'),
};

/// 全部函数名（与 fnSpecs 键一致，用于 `E_UNDEF` 的「是否想写」提示与自检）。
Iterable<String> get functionNames => fnSpecs.keys;

/// 函数求值上下文：提供确定性的随机与时钟（上游 §4.4 确定性边界）。
class FnContext {
  final Random random;
  final DateTime Function() clock;

  FnContext({Random? random, DateTime Function()? clock})
      : random = random ?? Random(),
        clock = clock ?? DateTime.now;
}

/// 调用一个 `fn.*` 函数。
Object? callFn(String name, List<Object?> args, FnContext ctx) {
  final spec = fnSpecs[name];
  if (spec == null) {
    final hint = _closest(name);
    throw err(ErrorCodes.undef,
        '未知函数 fn.$name${hint == null ? '' : '（是否想写 fn.$hint？）'}');
  }
  final (minArity, maxArity, _) = spec;
  if (args.length < minArity || args.length > maxArity) {
    final expect = minArity == maxArity ? '$minArity' : '$minArity..$maxArity';
    throw err(ErrorCodes.arg,
        'fn.$name 需要 $expect 个参数，实际 ${args.length} 个');
  }
  return _dispatch(name, args, ctx);
}

// ===========================================================================
// 类型辅助
// ===========================================================================

Never _typeErr(String fn, String param, String want, Object? got) => throw err(
    ErrorCodes.type,
    'fn.$fn 的参数 $param 需要 $want，实际是 ${_typeName(got)}');

String _typeName(Object? v) {
  if (v == null) return 'null';
  if (v is Uint8List) return 'bytes';
  if (v is String) return 'string';
  if (v is int) return 'int';
  if (v is double) return 'double';
  if (v is bool) return 'bool';
  if (v is List) return 'list';
  if (v is Map) return 'map';
  return v.runtimeType.toString();
}

String _str(String fn, String param, Object? v) {
  if (v is String) return v;
  _typeErr(fn, param, 'string', v);
}

/// string 参数按 UTF-8 取字节；bytes 原样。
Uint8List _bytesOf(String fn, String param, Object? v) {
  if (v is Uint8List) return v;
  if (v is String) return Uint8List.fromList(utf8.encode(v));
  _typeErr(fn, param, 'string 或 bytes', v);
}

Uint8List _bytesStrict(String fn, String param, Object? v) {
  if (v is Uint8List) return v;
  _typeErr(fn, param, 'bytes', v);
}

int _int(String fn, String param, Object? v) {
  if (v is int) return v;
  if (v is double && v == v.truncateToDouble()) return v.toInt();
  if (v is double) {
    throw err(ErrorCodes.arg, 'fn.$fn 的参数 $param 需要整数，实际是 $v');
  }
  _typeErr(fn, param, 'int', v);
}

int _listIndex(String fn, String param, Object? v) {
  if (v is! int) {
    if (v is double && v == v.truncateToDouble()) return v.toInt();
    _typeErr(fn, param, 'int', v);
  }
  return v;
}

// ===========================================================================
// 分发
// ===========================================================================

Object? _dispatch(String name, List<Object?> a, FnContext ctx) {
  switch (name) {
    // ---- 编码 / 转换 ----
    case 'b64':
      return base64.encode(_bytesOf(name, 'x', a[0]));
    case 'b64d':
      final raw = _strictB64(name, _str(name, 's', a[0]));
      try {
        return utf8.decode(raw);
      } on FormatException {
        throw err(ErrorCodes.arg, 'fn.b64d 解码结果不是合法 UTF-8（二进制请用 fn.unb64）');
      }
    case 'unb64':
      return _strictB64(name, _str(name, 's', a[0]));
    case 'b64url':
      return _stripPad(base64Url.encode(_bytesOf(name, 'x', a[0])));
    case 'unb64url':
      return _strictB64Url(name, _str(name, 's', a[0]));
    case 'hex':
      return bytesToHex(_bytesOf(name, 'x', a[0]));
    case 'unhex':
      return hexToBytes(_str(name, 's', a[0]));
    case 'utf8':
      return Uint8List.fromList(utf8.encode(_str(name, 's', a[0])));
    case 'latin1':
      final b = _bytesStrict(name, 'b', a[0]);
      return String.fromCharCodes(b);
    case 'urlenc':
      return Uri.encodeComponent(_str(name, 's', a[0]));
    case 'gz':
      final input = _bytesStrict(name, 'b', a[0]);
      final gz = GZipEncoder().encode(input);
      if (gz == null) {
        throw err(ErrorCodes.arg, 'fn.gz 压缩失败');
      }
      return Uint8List.fromList(gz);
    case 'gunz':
      final input = _bytesStrict(name, 'b', a[0]);
      try {
        final out = GZipDecoder().decodeBytes(input);
        return out is Uint8List ? out : Uint8List.fromList(out);
      } catch (_) {
        throw err(ErrorCodes.arg, 'fn.gunz 输入不是合法 gzip 流');
      }

    // ---- 哈希 ----
    case 'md5':
      return _digest(crypto.md5, _bytesOf(name, 's', a[0]));
    case 'sha1':
      return _digest(crypto.sha1, _bytesOf(name, 's', a[0]));
    case 'sha256':
      return _digest(crypto.sha256, _bytesOf(name, 's', a[0]));
    case 'hmacSha256':
      final key = _bytesOf(name, 'k', a[0]);
      final msg = _bytesOf(name, 's', a[1]);
      final mac = crypto.Hmac(crypto.sha256, key).convert(msg);
      return bytesToHex(Uint8List.fromList(mac.bytes));
    case 'crc32':
      return _crc32Hex(_bytesOf(name, 'x', a[0]));

    // ---- 加密 ----
    case 'rsaPkcs1':
      return _rsaPkcs1(
        _str(name, 'pubB64', a[0]),
        _str(name, 'plaintext', a[1]),
        a.length > 2 ? _str(name, 'bt', a[2]) : '02',
      );
    case 'aesCbc':
      return _aesCbc(
        _str(name, 'keyHex', a[0]),
        _str(name, 'ivHex', a[1]),
        _str(name, 'dataB64', a[2]),
      );
    case 'aesEcb':
      return _aesEcb(_str(name, 'keyHex', a[0]), _str(name, 'dataB64', a[1]));

    // ---- 字符串 / 自定义编码 ----
    case 'shift2':
      return _shift(_str(name, 's', a[0]), 2);
    case 'shiftN':
      return _shift(_str(name, 's', a[0]), _int(name, 'n', a[1]));
    case 'padRight':
      return _pad(_str(name, 's', a[0]), _int(name, 'n', a[1]),
          _str(name, 'c', a[2]), right: true);
    case 'padLeft':
      return _pad(_str(name, 's', a[0]), _int(name, 'n', a[1]),
          _str(name, 'c', a[2]), right: false);
    case 'repeat':
      final c = _str(name, 'c', a[0]);
      final n = _int(name, 'n', a[1]);
      if (c.isEmpty) throw err(ErrorCodes.arg, 'fn.repeat 的 c 不能是空串');
      if (n < 0) throw err(ErrorCodes.arg, 'fn.repeat 的 n 不能为负');
      final cp = c.runes.first;
      return String.fromCharCode(cp) * n;
    case 'substring':
      final s = _str(name, 's', a[0]);
      final from = _int(name, 'a', a[1]);
      final to = a.length > 2 ? _int(name, 'b', a[2]) : s.length;
      // §8.4：Dart substring 语义 —— 越界截断，**无负索引**（负数报 E_ARG）。
      // 负索引是 fn.slice 的能力，不要把两者混淆。
      if (from < 0) {
        throw err(ErrorCodes.arg, 'fn.substring 不支持负索引（a=$from），请用 fn.slice');
      }
      if (to < 0) {
        throw err(ErrorCodes.arg, 'fn.substring 不支持负索引（b=$to），请用 fn.slice');
      }
      final start = from > s.length ? s.length : from;
      final end0 = to > s.length ? s.length : to;
      final end = end0 < start ? start : end0;
      return s.substring(start, end);
    case 'concat':
      return _concat(a);
    case 'len':
      return _len(name, a[0]);
    case 'count':
      return _len(name, a[0]);
    case 'trim':
      return _str(name, 's', a[0]).trim();
    case 'upper':
      return _str(name, 's', a[0]).toUpperCase();
    case 'lower':
      return _str(name, 's', a[0]).toLowerCase();
    case 'replace':
      final s = _str(name, 's', a[0]);
      final old = _str(name, 'old', a[1]);
      final rep = _str(name, 'rep', a[2]);
      if (old.isEmpty) throw err(ErrorCodes.arg, 'fn.replace 的 old 不能是空串');
      return s.replaceAll(old, rep);
    case 'replaceRegex':
      final s = _str(name, 's', a[0]);
      final pat = _str(name, 'pat', a[1]);
      final rep = _str(name, 'rep', a[2]);
      try {
        return s.replaceAll(RegExp(pat), _expandDollar(rep));
      } on FormatException catch (e) {
        throw err(ErrorCodes.arg, 'fn.replaceRegex 正则非法：${e.message}');
      }
    case 'split':
      final s = _str(name, 's', a[0]);
      final sep = _str(name, 'sep', a[1]);
      if (sep.isEmpty) return s.split('').toList();
      return s.split(sep).toList();
    case 'startsWith':
      return _str(name, 's', a[0]).startsWith(_str(name, 'p', a[1]));
    case 'endsWith':
      return _str(name, 's', a[0]).endsWith(_str(name, 'p', a[1]));

    // ---- bytes 操作 ----
    case 'bytesReplace':
      return _bytesReplace(
        _bytesStrict(name, 'b', a[0]),
        _bytesOf(name, 'from', a[1]),
        _bytesOf(name, 'to', a[2]),
      );
    case 'be32Write':
      return _writeBE(_bytesStrict(name, 'b', a[0]), _int(name, 'offset', a[1]),
          _int(name, 'value', a[2]), 4, name);
    case 'be32Read':
      return _readBE(_bytesStrict(name, 'b', a[0]), _int(name, 'offset', a[1]), 4,
          name);
    case 'be16Write':
      return _writeBE(_bytesStrict(name, 'b', a[0]), _int(name, 'offset', a[1]),
          _int(name, 'value', a[2]), 2, name);
    case 'be16Read':
      return _readBE(_bytesStrict(name, 'b', a[0]), _int(name, 'offset', a[1]), 2,
          name);
    case 'u8Write':
      return _writeBE(_bytesStrict(name, 'b', a[0]), _int(name, 'offset', a[1]),
          _int(name, 'value', a[2]), 1, name);
    case 'at':
      final b = _bytesStrict(name, 'b', a[0]);
      final i = _int(name, 'i', a[1]);
      if (i < 0 || i >= b.length) {
        throw err(ErrorCodes.arg, 'fn.at 下标 $i 越界（长度 ${b.length}）');
      }
      return b[i];
    case 'slice':
      return _slice(name, a[0], _int(name, 'a', a[1]),
          a.length > 2 ? _int(name, 'b', a[2]) : null);
    case 'indexOf':
      return _indexOf(name, a[0], a[1], a.length > 2 ? _int(name, 'start', a[2]) : 0);
    case 'scanAscii':
      return _scanAscii(_bytesStrict(name, 'b', a[0]), _str(name, 'tagHex', a[1]),
          _int(name, 'length', a[2]));

    // ---- 随机 / 时间 ----
    case 'randomHex':
      return _randomHex(ctx, _int(name, 'n', a[0]), name);
    case 'randomDigits':
      return _randomDigits(ctx, _int(name, 'n', a[0]), name);
    case 'randomOf':
      final list = a[0];
      if (list is! List) _typeErr(name, 'list', 'list', list);
      if (list.isEmpty) throw err(ErrorCodes.arg, 'fn.randomOf 的 list 不能为空');
      return list[ctx.random.nextInt(list.length)];
    case 'randomInt':
      final lo = _int(name, 'min', a[0]);
      final hi = _int(name, 'max', a[1]);
      if (hi < lo) throw err(ErrorCodes.arg, 'fn.randomInt 的 max($hi) < min($lo)');
      return lo + ctx.random.nextInt(hi - lo + 1);
    case 'randomModOffset':
      return _randomModOffset(ctx, a[0], a[1]);
    case 'uuid':
      return _uuid(ctx);
    case 'now':
      return ctx.clock().millisecondsSinceEpoch;
    case 'ts10':
      return (ctx.clock().millisecondsSinceEpoch ~/ 1000).toString();
    case 'ts13':
      return ctx.clock().millisecondsSinceEpoch.toString();
    case 'ts14':
      return _utcFormat(ctx.clock().toUtc(), 'YYYYMMDDHHmmss');

    // ---- 空值处理 ----
    case 'coalesce':
      for (final v in a) {
        if (v != null && !(v is String && v.isEmpty)) return v;
      }
      return null;
    case 'default':
      final v = a[0];
      if (v == null || (v is String && v.isEmpty)) return a[1];
      return v;

    // ---- 类型转换 ----
    case 'toInt':
      return _toInt(name, a[0]);
    case 'toFloat':
      return _toFloat(name, a[0]);
    case 'toString':
      return _toString(name, a[0]);

    // ---- 编码 / HTML ----
    case 'charsetDecode':
      return _charsetDecode(_bytesStrict(name, 'b', a[0]), _str(name, 'name', a[1]));
    case 'htmlUnescape':
      return _htmlUnescape(_str(name, 's', a[0]));
    case 'htmlEscape':
      return _htmlEscape(_str(name, 's', a[0]));

    // ---- 集合 ----
    case 'first':
      return _edge(name, a[0], first: true);
    case 'last':
      return _edge(name, a[0], first: false);
    case 'nth':
      return _nth(name, a[0], _listIndex(name, 'i', a[1]));

    // ---- JSON ----
    case 'jsonParse':
      final s = _str(name, 's', a[0]);
      try {
        return jsonDecode(s);
      } catch (_) {
        throw err(ErrorCodes.arg, 'fn.jsonParse 解析失败：不是合法 JSON');
      }

    // ---- 日期 ----
    case 'toDate':
      final fmt = a.length > 1 ? _str(name, 'fmt', a[1]) : null;
      return _utcFormat(_parseDateInput(name, a[0], fmt), 'YYYY-MM-DDTHH:mm:ssZ');
    case 'dateFormat':
      final dt = _parseDateInput(name, a[0], null);
      return _utcFormat(dt, _str(name, 'fmt', a[1]), allowMillis: true);
    case 'daysBeforeNow':
      final dt = _parseDateInput(name, a[0], null);
      final today = _utcDay(ctx.clock());
      return (today.difference(_utcDay(dt)).inDays);
    case 'daysAfterNow':
      final dt = _parseDateInput(name, a[0], null);
      final today = _utcDay(ctx.clock());
      return _utcDay(dt).difference(today).inDays;

    default:
      throw err(ErrorCodes.undef, '未知函数 fn.$name');
  }
}

// ===========================================================================
// 各函数实现
// ===========================================================================

String _digest(crypto.Hash h, Uint8List data) =>
    bytesToHex(Uint8List.fromList(h.convert(data).bytes));

Uint8List _strictB64(String fn, String s) {
  final t = s.replaceAll(RegExp(r'\s'), '');
  // 严格校验：Dart 的 base64.decode 会静默跳过非法字符，
  // 与契约「非法输入报 E_ARG」不符，因此先做字符集与长度检查。
  if (!RegExp(r'^[A-Za-z0-9+/]*={0,2}$').hasMatch(t)) {
    throw err(ErrorCodes.arg, 'fn.$fn 输入含非 base64 字符');
  }
  var body = t;
  if (body.endsWith('==')) {
    body = body.substring(0, body.length - 2);
  } else if (body.endsWith('=')) {
    body = body.substring(0, body.length - 1);
  }
  if (body.length % 4 == 1) {
    throw err(ErrorCodes.arg, 'fn.$fn 输入长度非法');
  }
  try {
    return base64.decode(base64.normalize(t));
  } catch (_) {
    throw err(ErrorCodes.arg, 'fn.$fn 输入不是合法 base64');
  }
}

Uint8List _strictB64Url(String fn, String s) {
  final trimmed = s.replaceAll(RegExp(r'\s'), '');
  if (!RegExp(r'^[A-Za-z0-9\-_]*={0,2}$').hasMatch(trimmed)) {
    throw err(ErrorCodes.arg, 'fn.$fn 输入含非 base64url 字符');
  }
  var t = trimmed.replaceAll('-', '+').replaceAll('_', '/');
  final pad = t.length % 4;
  if (pad == 1) throw err(ErrorCodes.arg, 'fn.$fn 输入不是合法 base64url');
  if (pad > 0) t = t.padRight(t.length + (4 - pad), '=');
  try {
    return base64.decode(t);
  } catch (_) {
    throw err(ErrorCodes.arg, 'fn.$fn 输入不是合法 base64url');
  }
}

String _stripPad(String s) => s.replaceAll('=', '');

/// 每个 **UTF-16 码位** +n（§8.1）。
///
/// 注意：用 `codeUnits` 而非 `runes`。`runes` 是 Unicode 码点，
/// 对 BMP 外字符（emoji 等）会得到一个码点而非两个代理项，
/// 加 n 后可能与上游（按 UTF-16 处理）结果不同，且会改变字符串长度。
String _shift(String s, int n) {
  final units = s.codeUnits;
  final out = StringBuffer();
  for (final u in units) {
    final v = u + n;
    if (v < 0 || v > 0xFFFF) {
      throw err(ErrorCodes.arg,
          'fn.shift 结果超出 UTF-16 范围（码位 $u + $n = $v）');
    }
    out.writeCharCode(v);
  }
  return out.toString();
}

String _pad(String s, int n, String c, {required bool right}) {
  if (c.isEmpty) throw err(ErrorCodes.arg, 'pad 函数的 c 不能是空串');
  // §8.1：取 c 的**首个码位**（UTF-16 码元）
  final ch = String.fromCharCode(c.codeUnitAt(0));
  final buf = StringBuffer();
  if (!right) {
    while (buf.length + s.length < n) {
      buf.write(ch);
    }
  }
  buf.write(s);
  if (right) {
    while (buf.length < n) {
      buf.write(ch);
    }
  }
  return buf.toString();
}

Object? _concat(List<Object?> a) {
  // 首参 string → 字符串拼接（null→空串，bool/number 按渲染规则）
  // 首参 bytes → 字节拼接（string 参数按 UTF-8 编码）
  final first = a[0];
  if (first is Uint8List) {
    final out = BytesBuilder(copy: false);
    for (final v in a) {
      if (v is Uint8List) {
        out.add(v);
      } else if (v == null) {
        // null → 空
      } else {
        out.add(utf8.encode(renderValue(v)));
      }
    }
    return out.toBytes();
  }
  final sb = StringBuffer();
  for (final v in a) {
    sb.write(renderValue(v));
  }
  return sb.toString();
}

int _len(String fn, Object? v) {
  if (v is String) return v.length;
  if (v is Uint8List) return v.length;
  if (v is List) return v.length;
  if (v is Map) return v.length;
  _typeErr(fn, 'x', 'string/bytes/list/map', v);
}

Uint8List _bytesReplace(Uint8List b, Uint8List from, Uint8List to) {
  if (from.isEmpty) throw err(ErrorCodes.arg, 'fn.bytesReplace 的 from 不能为空');
  final out = BytesBuilder(copy: false);
  var i = 0;
  while (i < b.length) {
    if (i + from.length <= b.length && _matchesAt(b, from, i)) {
      out.add(to);
      i += from.length;
    } else {
      out.addByte(b[i]);
      i++;
    }
  }
  return out.toBytes();
}

bool _matchesAt(Uint8List b, Uint8List pat, int at) {
  for (var k = 0; k < pat.length; k++) {
    if (b[at + k] != pat[k]) return false;
  }
  return true;
}

Uint8List _writeBE(Uint8List b, int offset, int value, int width, String fn) {
  final maxValue = (1 << (width * 8)) - 1;
  if (value < 0 || value > maxValue) {
    throw err(ErrorCodes.arg, 'fn.$fn 的 value($value) 超出 $width 字节无符号范围');
  }
  if (offset < 0 || offset + width > b.length) {
    throw err(ErrorCodes.arg,
        'fn.$fn 写入越界：offset=$offset width=$width 长度=${b.length}');
  }
  final out = Uint8List.fromList(b); // copy-on-write
  for (var k = 0; k < width; k++) {
    out[offset + k] = (value >> (8 * (width - 1 - k))) & 0xFF;
  }
  return out;
}

int _readBE(Uint8List b, int offset, int width, String fn) {
  if (offset < 0 || offset + width > b.length) {
    throw err(ErrorCodes.arg,
        'fn.$fn 读取越界：offset=$offset width=$width 长度=${b.length}');
  }
  var v = 0;
  for (var k = 0; k < width; k++) {
    v = (v << 8) | b[offset + k];
  }
  return v;
}

Object? _slice(String fn, Object? x, int a, int? b) {
  if (x is String) {
    final units = x.codeUnits;
    final len = units.length;
    var start = a < 0 ? len + a : a;
    var end = b == null ? len : (b < 0 ? len + b : b);
    start = start.clamp(0, len);
    end = end.clamp(0, len);
    if (end <= start) return '';
    return String.fromCharCodes(units.sublist(start, end));
  }
  if (x is Uint8List) {
    final len = x.length;
    var start = a < 0 ? len + a : a;
    var end = b == null ? len : (b < 0 ? len + b : b);
    start = start.clamp(0, len);
    end = end.clamp(0, len);
    if (end <= start) return Uint8List(0);
    return Uint8List.sublistView(x, start, end);
  }
  _typeErr(fn, 'x', 'string 或 bytes', x);
}

int _indexOf(String fn, Object? h, Object? n, int start) {
  if (h is String && n is String) {
    return h.indexOf(n, start.clamp(0, h.length));
  }
  if (h is Uint8List && n is Uint8List) {
    if (start < 0) start = 0;
    if (n.isEmpty) return start <= h.length ? start : -1;
    for (var i = start; i + n.length <= h.length; i++) {
      if (_matchesAt(h, n, i)) return i;
    }
    return -1;
  }
  throw err(ErrorCodes.type,
      'fn.$fn 需要 (string,string) 或 (bytes,bytes)，实际 (${_typeName(h)},${_typeName(n)})');
}

String _scanAscii(Uint8List b, String tagHex, int length) {
  final tag = hexToBytes(tagHex);
  var found = -1;
  if (tag.isEmpty) {
    found = 0;
  } else {
    for (var i = 0; i + tag.length <= b.length; i++) {
      if (_matchesAt(b, tag, i)) {
        found = i;
        break;
      }
    }
  }
  if (found < 0) {
    throw err(ErrorCodes.extract, 'fn.scanAscii 未找到 tag 0x$tagHex');
  }
  final start = found + tag.length; // 跳过整个 tag
  if (start + length > b.length) {
    throw err(ErrorCodes.extract,
        'fn.scanAscii 读取越界：start=$start length=$length 长度=${b.length}');
  }
  return String.fromCharCodes(b.sublist(start, start + length));
}

String _randomHex(FnContext ctx, int n, String fn) {
  if (n < 0) throw err(ErrorCodes.arg, 'fn.$fn 的 n 不能为负');
  const chars = '0123456789abcdef';
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(chars[ctx.random.nextInt(16)]);
  }
  return sb.toString();
}

String _randomDigits(FnContext ctx, int n, String fn) {
  if (n < 0) throw err(ErrorCodes.arg, 'fn.$fn 的 n 不能为负');
  final sb = StringBuffer();
  for (var i = 0; i < n; i++) {
    sb.write(ctx.random.nextInt(10));
  }
  return sb.toString();
}

String _randomModOffset(FnContext ctx, Object? modArg, Object? offArg) {
  // off + random(0..mod-1)，BigInt 运算，支持超大数
  final mod = _bigFrom(modArg, 'mod');
  final off = _bigFrom(offArg, 'off');
  if (mod <= BigInt.zero) throw err(ErrorCodes.arg, 'fn.randomModOffset 的 mod 必须为正');
  // 均匀随机需要 mod 位宽；用两个 32 位随机拼 64 位后取模（mod 极大时也够用）
  final r = BigInt.from(ctx.random.nextInt(1 << 32)) << 32 |
      BigInt.from(ctx.random.nextInt(1 << 32));
  return (off + (r % mod)).toString();
}

BigInt _bigFrom(Object? v, String param) {
  if (v is BigInt) return v;
  if (v is int) return BigInt.from(v);
  if (v is double) return BigInt.from(v.truncate());
  if (v is String) {
    final p = BigInt.tryParse(v.trim());
    if (p == null) {
      throw err(ErrorCodes.arg, 'fn.randomModOffset 的参数 $param 不是合法整数：$v');
    }
    return p;
  }
  throw err(ErrorCodes.type, 'fn.randomModOffset 的参数 $param 需要整数，实际 ${_typeName(v)}');
}

String _uuid(FnContext ctx) {
  final b = List<int>.generate(16, (_) => ctx.random.nextInt(256));
  b[6] = (b[6] & 0x0F) | 0x40;
  b[8] = (b[8] & 0x3F) | 0x80;
  final h = bytesToHex(Uint8List.fromList(b));
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

int _toInt(String fn, Object? v) {
  if (v is int) return v;
  if (v is double) return v.truncate();
  if (v is String) {
    final t = v.trim();
    if (t.toLowerCase().startsWith('0x') || t.toLowerCase().startsWith('-0x')) {
      final neg = t.startsWith('-');
      final body = neg ? t.substring(3) : t.substring(2);
      final parsed = int.tryParse(body, radix: 16);
      if (parsed == null) {
        throw err(ErrorCodes.arg, 'fn.$fn 无法解析为整数：$v');
      }
      return neg ? -parsed : parsed;
    }
    final parsed = int.tryParse(t);
    if (parsed == null) {
      throw err(ErrorCodes.arg, 'fn.$fn 无法解析为整数：$v');
    }
    return parsed;
  }
  _typeErr(fn, 'x', 'number 或 string', v);
}

double _toFloat(String fn, Object? v) {
  if (v is double) return v;
  if (v is int) return v.toDouble();
  if (v is String) {
    final parsed = double.tryParse(v.trim());
    if (parsed == null) throw err(ErrorCodes.arg, 'fn.$fn 无法解析为浮点数：$v');
    return parsed;
  }
  _typeErr(fn, 'x', 'number 或 string', v);
}

String _toString(String fn, Object? v) {
  if (v is Uint8List) {
    try {
      return utf8.decode(v); // 严格解码
    } on FormatException {
      return bytesToHex(v); // 非法字节 → 回退 hex
    }
  }
  return renderValue(v);
}

Object? _edge(String fn, Object? x, {required bool first}) {
  if (x is String) {
    if (x.isEmpty) throw err(ErrorCodes.arg, 'fn.$fn 的字符串为空');
    final runes = x.runes.toList();
    return String.fromCharCode(first ? runes.first : runes.last);
  }
  if (x is List) {
    if (x.isEmpty) throw err(ErrorCodes.arg, 'fn.$fn 的 list 为空');
    return first ? x.first : x.last;
  }
  _typeErr(fn, 'x', 'string 或 list', x);
}

Object? _nth(String fn, Object? x, int i) {
  if (x is String) {
    final runes = x.runes.toList();
    final idx = i < 0 ? runes.length + i : i;
    if (idx < 0 || idx >= runes.length) {
      throw err(ErrorCodes.arg, 'fn.$fn 下标 $i 越界（长度 ${runes.length}）');
    }
    return String.fromCharCode(runes[idx]);
  }
  if (x is List) {
    final idx = i < 0 ? x.length + i : i;
    if (idx < 0 || idx >= x.length) {
      throw err(ErrorCodes.arg, 'fn.$fn 下标 $i 越界（长度 ${x.length}）');
    }
    return x[idx];
  }
  _typeErr(fn, 'x', 'string 或 list', x);
}

String _expandDollar(String rep) {
  // Dart 的 replaceAll 不认 $1，转成 ${m[n]} 形式
  return rep.replaceAllMapped(RegExp(r'\$(\d+)'), (m) => '\${${m[1]}}');
}

// ---- 哈希 / 校验 ----

String _crc32Hex(Uint8List data) {
  final v = _crc32(data);
  return v.toRadixString(16).padLeft(8, '0');
}

int _crc32(Uint8List data) {
  var table = _crcTable;
  if (table == null) {
    table = List<int>.generate(256, (n) {
      var c = n;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      return c;
    });
    _crcTable = table;
  }
  var crc = 0xFFFFFFFF;
  for (final b in data) {
    crc = table[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

List<int>? _crcTable;

// ---- RSA / AES ----

String _rsaPkcs1(String pubB64, String plaintext, String bt) {
  final derBytes = _strictB64('rsaPkcs1', pubB64);
  final pc.RSAPublicKey pub;
  try {
    // X.509 SubjectPublicKeyInfo:
    //   SEQUENCE { SEQUENCE { OID rsaEncryption, NULL }, BIT STRING { SEQUENCE{ INTEGER n, INTEGER e } } }
    final root = asn1.ASN1Parser(derBytes).nextObject() as asn1.ASN1Sequence;
    final bitString = root.elements.last as asn1.ASN1BitString;
    final keySeq =
        asn1.ASN1Parser(Uint8List.fromList(bitString.stringValue)).nextObject()
            as asn1.ASN1Sequence;
    final n = keySeq.elements[0] as asn1.ASN1Integer;
    final e = keySeq.elements[1] as asn1.ASN1Integer;
    pub = pc.RSAPublicKey(n.valueAsBigInteger, e.valueAsBigInteger);
  } catch (_) {
    throw err(ErrorCodes.arg,
        'fn.rsaPkcs1 的公钥不是合法的 X.509 SubjectPublicKeyInfo DER base64');
  }
  final k = (pub.modulus!.bitLength + 7) ~/ 8;
  final msg = utf8.encode(plaintext);
  if (msg.length > k - 11) {
    throw err(ErrorCodes.arg,
        'fn.rsaPkcs1 明文过长：${msg.length} 字节，密钥 ${k * 8} 位最多 ${k - 11} 字节');
  }

  // PKCS#1 v1.5 填充：BT || PS || 0x00 || M
  final blockType = bt == '01' ? 1 : 2;
  final em = Uint8List(k);
  em[0] = 0x00;
  em[1] = blockType;
  final psLen = k - msg.length - 3;
  if (psLen < 8) {
    throw err(ErrorCodes.arg, 'fn.rsaPkcs1 填充空间不足（PS 至少 8 字节）');
  }
  final rnd = Random.secure();
  for (var i = 0; i < psLen; i++) {
    em[2 + i] = blockType == 1 ? 0xFF : _nonzeroByte(rnd);
  }
  em[2 + psLen] = 0x00;
  em.setRange(2 + psLen + 1, k, msg);

  final m = _os2ip(em);
  final c = m.modPow(pub.publicExponent!, pub.modulus!);
  return base64.encode(_i2osp(c, k));
}

int _nonzeroByte(Random r) {
  while (true) {
    final b = r.nextInt(256);
    if (b != 0) return b;
  }
}

BigInt _os2ip(Uint8List b) {
  var v = BigInt.zero;
  for (final x in b) {
    v = (v << 8) | BigInt.from(x);
  }
  return v;
}

Uint8List _i2osp(BigInt v, int len) {
  final out = Uint8List(len);
  var x = v;
  for (var i = len - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xFF)).toInt();
    x = x >> 8;
  }
  return out;
}

String _aesCbc(String keyHex, String ivHex, String dataB64) {
  final key = hexToBytes(keyHex);
  final iv = hexToBytes(ivHex);
  if (![16, 24, 32].contains(key.length)) {
    throw err(ErrorCodes.arg, 'fn.aesCbc 的 key 必须是 16/24/32 字节，实际 ${key.length}');
  }
  if (iv.length != 16) {
    throw err(ErrorCodes.arg, 'fn.aesCbc 的 iv 必须是 16 字节，实际 ${iv.length}');
  }
  final data = _strictB64('aesCbc', dataB64);
  final cipher = pc.CBCBlockCipher(pc.AESEngine())
    ..init(true, pc.ParametersWithIV(pc.KeyParameter(key), iv));
  return base64.encode(_aesProcess(cipher, data));
}

String _aesEcb(String keyHex, String dataB64) {
  final key = hexToBytes(keyHex);
  if (![16, 24, 32].contains(key.length)) {
    throw err(ErrorCodes.arg, 'fn.aesEcb 的 key 必须是 16/24/32 字节，实际 ${key.length}');
  }
  final data = _strictB64('aesEcb', dataB64);
  final cipher = pc.ECBBlockCipher(pc.AESEngine())
    ..init(true, pc.KeyParameter(key));
  return base64.encode(_aesProcess(cipher, data));
}

/// PKCS#7 填充 + 分块加密（与 forge 默认 padding 一致）。
Uint8List _aesProcess(pc.BlockCipher cipher, Uint8List data) {
  final blockSize = cipher.blockSize;
  final padLen = blockSize - (data.length % blockSize);
  final padded = Uint8List(data.length + padLen)
    ..setRange(0, data.length, data)
    ..fillRange(data.length, data.length + padLen, padLen);

  final out = Uint8List(padded.length);
  final block = Uint8List(blockSize);
  for (var off = 0; off < padded.length; off += blockSize) {
    block.setRange(0, blockSize, padded, off);
    cipher.processBlock(block, 0, out, off);
  }
  return out;
}

// ---- 字符集 / HTML ----

String _charsetDecode(Uint8List b, String nameArg) {
  final name = nameArg.toLowerCase();
  switch (name) {
    case 'utf-8':
    case 'utf8':
      try {
        return utf8.decode(b);
      } on FormatException {
        throw err(ErrorCodes.arg, 'fn.charsetDecode 输入不是合法 UTF-8');
      }
    case 'latin-1':
    case 'latin1':
    case 'iso-8859-1':
    case 'ascii':
      return String.fromCharCodes(b);
    case 'gb2312':
    case 'gbk':
    case 'gb18030':
      return _gbkDecode(b);
    case 'big5':
      throw err(ErrorCodes.arg, 'fn.charsetDecode 暂不支持 big5');
    default:
      throw err(ErrorCodes.arg, 'fn.charsetDecode 未知字符集：$nameArg');
  }
}

/// GBK 解码（含 GB2312/GBK/GB18030 双字节区，表见 gbk_tables.dart）。
/// 单字节 0x00-0x7F 按 ASCII；双字节查表；表外序列回退 U+FFFD。
String _gbkDecode(Uint8List b) {
  final sb = StringBuffer();
  var i = 0;
  while (i < b.length) {
    final c = b[i];
    if (c < 0x80) {
      sb.writeCharCode(c);
      i++;
      continue;
    }
    if (i + 1 < b.length) {
      final cp = _gbkPairToUnicode(c, b[i + 1]);
      if (cp != null) {
        sb.writeCharCode(cp);
      } else {
        // 无映射：回退原始字节（U+FFFD 会丢信息，这里保留可逆性）
        sb.writeCharCode(0xFFFD);
      }
      i += 2;
      continue;
    }
    sb.writeCharCode(0xFFFD);
    i++;
  }
  return sb.toString();
}

/// GBK 双字节 → Unicode 码点；表外返回 null。
int? _gbkPairToUnicode(int b1, int b2) => gbkTable[(b1 << 8) | b2];

String _htmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _htmlUnescape(String s) {
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z]+);'), (m) {
    final body = m[1]!;
    if (body.startsWith('#x') || body.startsWith('#X')) {
      final v = int.tryParse(body.substring(2), radix: 16);
      return v == null ? m[0]! : String.fromCharCode(v);
    }
    if (body.startsWith('#')) {
      final v = int.tryParse(body.substring(1));
      return v == null ? m[0]! : String.fromCharCode(v);
    }
    switch (body) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      case 'nbsp':
        return '\u00A0';
      default:
        return m[0]!;
    }
  });
}

// ---- 日期 ----

DateTime _utcDay(DateTime t) {
  final u = t.toUtc();
  return DateTime.utc(u.year, u.month, u.day);
}

/// 解析 `fn.toDate` / `fn.dateFormat` / `days*Now` 的输入。
DateTime _parseDateInput(String fn, Object? x, String? fmt) {
  if (x is int) {
    return _fromMillisOrSeconds(BigInt.from(x), fn);
  }
  if (x is String) {
    final t = x.trim();
    if (fmt != null) {
      final parsed = _parseWithFormat(t, fmt);
      if (parsed == null) {
        throw err(ErrorCodes.arg, 'fn.$fn 无法按格式 $fmt 解析：$x');
      }
      return parsed;
    }
    // 10 位 → 秒，13 位 → 毫秒，14 位 → yyyyMMddHHmmss，8 位 → yyyyMMdd
    if (RegExp(r'^\d{10}$').hasMatch(t)) {
      return DateTime.fromMillisecondsSinceEpoch(int.parse(t) * 1000, isUtc: true);
    }
    if (RegExp(r'^\d{13}$').hasMatch(t)) {
      return DateTime.fromMillisecondsSinceEpoch(int.parse(t), isUtc: true);
    }
    if (RegExp(r'^\d{14}$').hasMatch(t)) {
      return DateTime.utc(
        int.parse(t.substring(0, 4)),
        int.parse(t.substring(4, 6)),
        int.parse(t.substring(6, 8)),
        int.parse(t.substring(8, 10)),
        int.parse(t.substring(10, 12)),
        int.parse(t.substring(12, 14)),
      );
    }
    if (RegExp(r'^\d{8}$').hasMatch(t)) {
      return DateTime.utc(
          int.parse(t.substring(0, 4)), int.parse(t.substring(4, 6)), int.parse(t.substring(6, 8)));
    }
    // ISO 风格归一化：/ → -，日期时间之间的空格 → T
    var norm = t.replaceAll('/', '-');
    if (norm.contains(' ') && !norm.contains('T')) {
      norm = norm.replaceFirst(' ', 'T');
    }
    final dt = DateTime.tryParse(norm);
    if (dt == null) throw err(ErrorCodes.arg, 'fn.$fn 无法解析日期：$x');
    return dt.isUtc ? dt : DateTime.utc(
        dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second, dt.millisecond);
  }
  throw err(ErrorCodes.type, 'fn.$fn 的 x 需要 string 或 int，实际 ${_typeName(x)}');
}

DateTime _fromMillisOrSeconds(BigInt v, String fn) {
  final s = v.toString();
  if (s.length <= 10) {
    return DateTime.fromMillisecondsSinceEpoch(v.toInt() * 1000, isUtc: true);
  }
  return DateTime.fromMillisecondsSinceEpoch(v.toInt(), isUtc: true);
}

DateTime? _parseWithFormat(String input, String fmt) {
  final buf = StringBuffer('^');
  final order = <String>[];
  var i = 0;
  while (i < fmt.length) {
    if (fmt.startsWith('YYYY', i)) {
      buf.write(r'(\d{4})');
      order.add('Y');
      i += 4;
    } else if (fmt.startsWith('SSS', i)) {
      buf.write(r'(\d{3})');
      order.add('S');
      i += 3;
    } else if (fmt.startsWith('MM', i)) {
      buf.write(r'(\d{2})');
      order.add('M');
      i += 2;
    } else if (fmt.startsWith('DD', i)) {
      buf.write(r'(\d{2})');
      order.add('D');
      i += 2;
    } else if (fmt.startsWith('HH', i)) {
      buf.write(r'(\d{2})');
      order.add('H');
      i += 2;
    } else if (fmt.startsWith('mm', i)) {
      buf.write(r'(\d{2})');
      order.add('m');
      i += 2;
    } else if (fmt.startsWith('ss', i)) {
      buf.write(r'(\d{2})');
      order.add('s');
      i += 2;
    } else {
      buf.write(RegExp.escape(fmt[i]));
      i++;
    }
  }
  buf.write(r'$');
  final m = RegExp(buf.toString()).firstMatch(input);
  if (m == null) return null;
  var y = 1970, mo = 1, d = 1, h = 0, mi = 0, se = 0, ms = 0;
  for (var k = 0; k < order.length; k++) {
    final v = int.parse(m.group(k + 1)!);
    switch (order[k]) {
      case 'Y':
        y = v;
      case 'M':
        mo = v;
      case 'D':
        d = v;
      case 'H':
        h = v;
      case 'm':
        mi = v;
      case 's':
        se = v;
      case 'S':
        ms = v;
    }
  }
  return DateTime.utc(y, mo, d, h, mi, se, ms);
}

String _utcFormat(DateTime t, String fmt, {bool allowMillis = false}) {
  final u = t.toUtc();
  String p2(int v) => v.toString().padLeft(2, '0');
  final sb = StringBuffer();
  var i = 0;
  while (i < fmt.length) {
    if (fmt.startsWith('YYYY', i)) {
      sb.write(u.year.toString().padLeft(4, '0'));
      i += 4;
    } else if (allowMillis && fmt.startsWith('SSS', i)) {
      sb.write(u.millisecond.toString().padLeft(3, '0'));
      i += 3;
    } else if (fmt.startsWith('MM', i)) {
      sb.write(p2(u.month));
      i += 2;
    } else if (fmt.startsWith('DD', i)) {
      sb.write(p2(u.day));
      i += 2;
    } else if (fmt.startsWith('HH', i)) {
      sb.write(p2(u.hour));
      i += 2;
    } else if (fmt.startsWith('mm', i)) {
      sb.write(p2(u.minute));
      i += 2;
    } else if (fmt.startsWith('ss', i)) {
      sb.write(p2(u.second));
      i += 2;
    } else {
      sb.write(fmt[i]);
      i++;
    }
  }
  return sb.toString();
}

/// 编辑距离最近的函数名（`E_UNDEF` 提示用，对应上游 `closest`）。
String? _closest(String name) {
  String? best;
  var bestD = 1 << 30;
  final lower = name.toLowerCase();
  for (final cand in fnSpecs.keys) {
    final d = _editDistance(lower, cand.toLowerCase());
    if (d < bestD) {
      bestD = d;
      best = cand;
    }
  }
  return bestD <= 2 ? best : null;
}

int _editDistance(String a, String b) {
  final m = a.length, n = b.length;
  var prev = List<int>.generate(n + 1, (i) => i);
  var cur = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    cur[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      cur[j] = [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost]
          .reduce((x, y) => x < y ? x : y);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[n];
}
