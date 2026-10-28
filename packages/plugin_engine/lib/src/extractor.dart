/// extract 提取器（对应上游 §6.4「五种取值来源」）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';
import 'manifest.dart';
import 'values.dart';

/// 一次 HTTP 响应的上下文，供 extract 使用。
class ResponseView {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List bodyBytes;

  ResponseView({
    required this.statusCode,
    required this.headers,
    required this.bodyBytes,
  });

  /// body 文本（按 UTF-8 解码，非法字节回退 latin-1）。
  late final String bodyText = _decodeUtf8Lenient(bodyBytes);

  String get bodyHex => bytesToHex(bodyBytes);

  String? header(String name) {
    final lower = name.toLowerCase();
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == lower) return e.value;
    }
    return null;
  }
}

String _decodeUtf8Lenient(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return String.fromCharCodes(bytes);
  }
}

/// 执行一条 extract 规则，返回提取到的值。
///
/// 失败时：`optional` 为 true 则返回 `defaultValue`（缺省为 null），
/// 否则抛 `E_EXTRACT`。
Object? runExtract(ExtractItem spec, ResponseView resp, String? stepId) {
  try {
    return _extract(spec, resp);
  } on PluginError catch (e) {
    if (e.code == ErrorCodes.arg || e.code == ErrorCodes.type) rethrow;
    if (spec.optional) return spec.defaultValue;
    throw PluginError(ErrorCodes.extract,
        '提取 "${spec.name}" 失败：${e.message}', stepId: stepId);
  } catch (e) {
    if (spec.optional) return spec.defaultValue;
    throw PluginError(ErrorCodes.extract, '提取 "${spec.name}" 失败：$e', stepId: stepId);
  }
}

Object? _extract(ExtractItem spec, ResponseView resp) {
  switch (spec.from) {
    case ExtractFrom.json:
      final parsed = _safeJsonDecode(resp.bodyText);
      if (parsed == null) {
        throw err(ErrorCodes.extract, '响应不是合法 JSON');
      }
      final v = jsonPath(parsed, spec.path ?? '');
      var out = v;
      // asJson + innerPath：双层 JSON（§14.8）
      if (spec.asJson) {
        if (out is! String) {
          throw err(ErrorCodes.extract, 'asJson 要求提取结果是 string，实际是 ${out.runtimeType}');
        }
        final inner = _safeJsonDecode(out);
        if (inner == null) {
          throw err(ErrorCodes.extract, 'asJson：内层文本不是合法 JSON');
        }
        out = inner;
      }
      if (spec.innerPath != null) {
        out = jsonPath(out, spec.innerPath!);
      }
      return out;

    case ExtractFrom.raw:
      // raw：关键字 + 偏移 + 长度（§6.4）。
      // 偏移按【字节】计算，与上游「body 视为 bytes」一致。
      final tag = spec.tag;
      final tagBytes = tag == null ? 0 : utf8.encode(tag).length;
      final int base;
      if (tag == null || tag.isEmpty) {
        base = 0;
      } else {
        final found = _byteIndexOf(resp.bodyBytes, utf8.encode(tag));
        if (found < 0) throw err(ErrorCodes.extract, 'raw 未找到标记 "$tag"');
        base = found + tagBytes;
      }
      final begin = base + spec.offset;
      if (begin < 0 || begin > resp.bodyBytes.length) {
        throw err(ErrorCodes.extract,
            'raw 偏移越界（begin=$begin，总长 ${resp.bodyBytes.length}）');
      }
      final end = spec.length == null ? resp.bodyBytes.length : begin + spec.length!;
      if (end > resp.bodyBytes.length) {
        throw err(ErrorCodes.extract,
            'raw 长度越界（end=$end，总长 ${resp.bodyBytes.length}）');
      }
      final slice = Uint8List.sublistView(resp.bodyBytes, begin, end);
      // length 未给时返回 bytes；给了则按 encoding 转值
      if (spec.length == null) return slice;
      return _decodeWithEncoding(slice, spec.encoding);

    case ExtractFrom.header:
      final name = spec.header;
      if (name == null || name.isEmpty) {
        throw err(ErrorCodes.extract, 'header 提取缺少 header 名');
      }
      final v = resp.header(name);
      if (v == null) throw err(ErrorCodes.extract, '响应头 "$name" 不存在');
      return v;

    case ExtractFrom.regex:
      final pattern = spec.pattern;
      if (pattern == null || pattern.isEmpty) {
        throw err(ErrorCodes.extract, 'regex 提取缺少 pattern');
      }
      final re = RegExp(pattern, multiLine: true, dotAll: true);
      final m = re.firstMatch(resp.bodyText);
      if (m == null) throw err(ErrorCodes.extract, '正则未匹配：$pattern');
      final g = spec.group;
      if (g > m.groupCount) {
        throw err(ErrorCodes.extract, '捕获组 $g 不存在（共 ${m.groupCount} 组）');
      }
      final v = m.group(g);
      if (v == null) throw err(ErrorCodes.extract, '捕获组 $g 未参与匹配');
      return v;

    case ExtractFrom.binary:
      // 二进制切片：offset + length + encoding（§14.7）
      final offset = spec.offset;
      final length = spec.length;
      if (length == null) {
        throw err(ErrorCodes.extract, 'binary 提取必须给 length');
      }
      if (offset < 0 || offset + length > resp.bodyBytes.length) {
        throw err(ErrorCodes.extract,
            'binary 越界（offset=$offset, length=$length, 总长 ${resp.bodyBytes.length}）');
      }
      final slice = Uint8List.sublistView(resp.bodyBytes, offset, offset + length);
      return _decodeWithEncoding(slice, spec.encoding);
  }
}

int _byteIndexOf(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return 0;
  final limit = haystack.length - needle.length;
  outer:
  for (var i = 0; i <= limit; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

Object? _decodeWithEncoding(Uint8List bytes, ExtractEncoding? encoding) {
  switch (encoding) {
    case null:
    case ExtractEncoding.raw:
      return bytes;
    case ExtractEncoding.ascii:
      return String.fromCharCodes(bytes);
    case ExtractEncoding.utf8:
      return _decodeUtf8Lenient(bytes);
    case ExtractEncoding.hex:
      return bytesToHex(bytes);
    case ExtractEncoding.be32:
      if (bytes.length < 4) {
        throw err(ErrorCodes.arg, 'be32 需要至少 4 字节，实际 ${bytes.length}');
      }
      var v = 0;
      for (var i = 0; i < 4; i++) {
        v = (v << 8) | bytes[i];
      }
      return v;
  }
}

Map<String, dynamic>? _safeJsonDecode(String s) {
  try {
    final v = jsonDecode(s);
    return v is Map<String, dynamic> ? v : (v is Map ? Map<String, dynamic>.from(v) : null);
  } catch (_) {
    return null;
  }
}

/// JSONPath 子集求值：`$.a.b[0].c`。
///
/// 上游 §6.4 只支持点路径与数组下标（`check_jsonpath` 校验），不支持
/// 过滤器 / 通配符。路径不存在时报错，由调用方决定是否 optional。
Object? jsonPath(Object? root, String path) {
  if (path.isEmpty || path == r'$') return root;
  var p = path;
  if (p.startsWith(r'$')) p = p.substring(1);
  if (p.startsWith('.')) p = p.substring(1);

  Object? cur = root;
  var i = 0;
  final n = p.length;
  while (i < n) {
    // 读一个段
    final sb = StringBuffer();
    while (i < n && p[i] != '.' && p[i] != '[') {
      sb.write(p[i]);
      i++;
    }
    final seg = sb.toString();
    if (seg.isNotEmpty) {
      if (cur is Map) {
        if (!cur.containsKey(seg)) {
          throw err(ErrorCodes.extract, 'JSON 路径 "$path" 不存在（缺少 "$seg"）');
        }
        cur = cur[seg];
      } else if (cur is List) {
        final idx = int.tryParse(seg);
        if (idx == null || idx < 0 || idx >= cur.length) {
          throw err(ErrorCodes.extract, 'JSON 路径 "$path" 下标非法："$seg"');
        }
        cur = cur[idx];
      } else {
        throw err(ErrorCodes.extract, 'JSON 路径 "$path" 在 "$seg" 处无法继续');
      }
    }
    // 处理 [n]
    if (i < n && p[i] == '[') {
      final close = p.indexOf(']', i);
      if (close < 0) throw err(ErrorCodes.extract, 'JSON 路径 "$path" 方括号未闭合');
      final inner = p.substring(i + 1, close).trim();
      i = close + 1;
      if (cur is! List) {
        throw err(ErrorCodes.extract, 'JSON 路径 "$path" 的 "$inner" 前不是数组');
      }
      final idx = int.tryParse(inner);
      if (idx == null || idx < 0 || idx >= cur.length) {
        throw err(ErrorCodes.extract, 'JSON 路径 "$path" 下标越界："$inner"');
      }
      cur = cur[idx];
    }
    if (i < n && p[i] == '.') i++;
  }
  return cur;
}
