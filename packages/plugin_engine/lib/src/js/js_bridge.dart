/// `set.js` 逃生舱：把沙箱接到引擎上。
///
/// 三件事：
/// 1. 把 73 个 `fn.*` 以 JS 函数形式注入全局 `fn` 对象（与表达式共享实现）；
/// 2. 处理 Dart ↔ JS 的 bytes 边界（§9.1：bytes 在 JS 内是 `Uint8Array`）；
/// 3. 执行 `set.js` 并做输出类型校验（必须 return，`undefined` 报 E_JS）。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../errors.dart';
import '../functions.dart';
import 'js_ast.dart';
import 'js_builtins.dart';
import 'js_interp.dart';
import 'js_parser.dart';
import 'js_value.dart';

/// 输入键的保留名（§9.2：这些名字不得作为 inputs 的键）。
const Set<String> jsReservedInputNames = {
  'fn',
  '__sj_',
  '__wireToBytes',
  '__bytesToWire',
};

/// 校验 `set.js.inputs` 的键是否合法。
void validateJsInputs(Map<String, Object?> inputs) {
  if (inputs.length > 32) {
    throw err(ErrorCodes.schema, 'set.js.inputs 最多 32 个键，实际 ${inputs.length}');
  }
  for (final k in inputs.keys) {
    if (!_isJsIdentifier(k)) {
      throw err(ErrorCodes.schema, 'set.js.inputs 的键 "$k" 不是合法 JS 标识符');
    }
    if (jsReservedInputNames.contains(k) || k.startsWith('__sj_')) {
      throw err(ErrorCodes.schema, 'set.js.inputs 的键 "$k" 是保留名');
    }
  }
}

bool _isJsIdentifier(String s) {
  if (s.isEmpty || s.length > 64) return false;
  final first = s.codeUnitAt(0);
  final okFirst = (first >= 0x41 && first <= 0x5A) ||
      (first >= 0x61 && first <= 0x7A) ||
      s[0] == r'$' ||
      s[0] == '_';
  if (!okFirst) return false;
  for (var i = 1; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    final ok = (u >= 0x41 && u <= 0x5A) ||
        (u >= 0x61 && u <= 0x7A) ||
        (u >= 0x30 && u <= 0x39) ||
        s[i] == r'$' ||
        s[i] == '_';
    if (!ok) return false;
  }
  return true;
}

/// 一次 `set.js` 执行的完整结果。
class JsRunResult {
  final Object? value;

  JsRunResult(this.value);
}

/// 执行 `set.js`。返回的 Dart 值已按 §9.1 转换回引擎值类型。
Object? runSetJs({
  required String code,
  required Map<String, Object?> inputs,
  required FnContext fnContext,
  required DateTime Function() clock,
  required math.Random random,
  Duration timeout = const Duration(milliseconds: 5000),
  List<String> libs = const [],
}) {
  if (code.isEmpty || code.length > 20000) {
    throw err(ErrorCodes.schema,
        'set.js.code 长度必须在 1..20000 之间，实际 ${code.length}');
  }
  validateJsInputs(inputs);

  final globals = buildGlobals(now: clock, random: random);
  _installFnNamespace(globals, fnContext);
  if (libs.isNotEmpty) {
    _installForgeStub(globals, libs);
  }

  // inputs 按 Dart 值转换后绑定为同名全局变量
  inputs.forEach((k, v) {
    globals.setProp(k, toJsValue(v));
  });

  final program = JsParser.parseProgram(code);
  final interp = JsInterp(
    globals,
    limits: JsLimits(timeout: timeout),
    clock: clock,
  );

  final raw = interp.runProgram(program);
  if (raw is JsUndefined) {
    throw err(ErrorCodes.js, 'set.js 必须 return 一个值，实际返回 undefined');
  }
  return fromJsValue(raw);
}

/// `fn` 命名空间对象。
///
/// 访问不存在的函数名时直接报 `E_UNDEF`（§8/§13），而不是返回 undefined 让
/// 后续调用栈再报一个含糊的 `E_JS` —— 插件作者看到的应是「函数名写错了」。
class _FnNamespace extends JsObject {
  @override
  Object? getProp(String key) {
    if (props.containsKey(key)) return props[key];
    final hint = functionNames.firstWhere(
      (n) => n.toLowerCase() == key.toLowerCase() || n.startsWith(key),
      orElse: () => '',
    );
    throw PluginError(
      ErrorCodes.undef,
      '未知函数 fn.$key${hint.isEmpty ? '' : '（是否想写 fn.$hint？）'}',
    );
  }
}

/// 把 `fn.*` 注入为全局 `fn` 对象。
void _installFnNamespace(JsObject globals, FnContext ctx) {
  final fnObj = _FnNamespace();
  for (final name in functionNames) {
    fnObj.setProp(
      name,
      JsNativeFunction('fn.$name', (thisVal, args) {
        final dartArgs = [for (final a in args) fromJsValue(a)];
        final r = callFn(name, dartArgs, ctx);
        return toJsValue(r);
      }),
    );
  }
  globals.setProp('fn', fnObj);
}

/// `hooks.libs: ["forge@1.4.0"]` 的落点。
///
/// 规范只允许 forge 一项。完整 forge 移植体量过大，这里提供**最小实现**：
/// 覆盖插件最常用的 `forge.util.encodeUtf8/decodeUtf8`、`forge.md.sha256/sha1/md5`、
/// `forge.util.bytesToHex/hexToBytes`。未覆盖的 API 调用时报明确错误，
/// 而不是静默返回 undefined（避免生成错误的密文却无人察觉）。
void _installForgeStub(JsObject globals, List<String> libs) {
  for (final lib in libs) {
    if (!lib.startsWith('forge@')) {
      throw err(ErrorCodes.schema,
          'hooks.libs 只允许 "forge@1.4.0"，实际 "$lib"');
    }
  }
  final forge = JsObject();
  final util = JsObject();
  util.setProp('encodeUtf8', JsNativeFunction('encodeUtf8', (t, a) {
    final s = jsToString(a.isEmpty ? jsUndefined : a[0]);
    return JsUint8Array.fromList(utf8.encode(s));
  }));
  util.setProp('decodeUtf8', JsNativeFunction('decodeUtf8', (t, a) {
    final v = a.isEmpty ? jsUndefined : a[0];
    if (v is JsUint8Array) return utf8.decode(v.toBytes(), allowMalformed: true);
    return '';
  }));
  util.setProp('bytesToHex', JsNativeFunction('bytesToHex', (t, a) {
    final v = a.isEmpty ? jsUndefined : a[0];
    if (v is JsUint8Array) {
      return v
          .toBytes()
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    }
    return '';
  }));
  util.setProp('hexToBytes', JsNativeFunction('hexToBytes', (t, a) {
    final s = jsToString(a.isEmpty ? jsUndefined : a[0]);
    final out = <int>[];
    for (var i = 0; i + 1 < s.length; i += 2) {
      out.add(int.parse(s.substring(i, i + 2), radix: 16));
    }
    return JsUint8Array.fromList(out);
  }));
  forge.setProp('util', util);

  // forge.md.* 摘要通过 fn.sha256 系列实现（纯 Dart 已有），保持语义一致
  final md = JsObject();
  void addMd(String algo, String fnName) {
    md.setProp(algo, JsNativeFunction(algo, (t, a) {
      final hasher = JsObject();
      final buf = StringBuffer();
      hasher.setProp('update', JsNativeFunction('update', (t2, a2) {
        final v = a2.isEmpty ? jsUndefined : a2[0];
        buf.write(v is JsUint8Array
            ? utf8.decode(v.toBytes(), allowMalformed: true)
            : jsToString(v));
        return hasher;
      }));
      hasher.setProp('digest', JsNativeFunction('digest', (t2, a2) {
        throw err(
          ErrorCodes.js,
          'forge.md.$algo.digest() 需要宿主实现，请改用 fn.$fnName(text)',
        );
      }));
      return hasher;
    }));
  }

  addMd('sha256', 'sha256');
  addMd('sha1', 'sha1');
  addMd('md5', 'md5');
  forge.setProp('md', md);

  // 明确标注哪些可用，便于插件作者排错
  forge.setProp('__partial__', true);
  globals.setProp('forge', forge);
}

// ---------------------------------------------------------------------------
// 值转换：Dart ↔ JS
// ---------------------------------------------------------------------------

/// Dart 值 → JS 值。bytes 变 `Uint8Array`（§9.1）。
Object? toJsValue(Object? v) {
  if (v == null) return jsNull;
  if (v is Uint8List) return JsUint8Array.fromList(v);
  if (v is List) return JsArray([for (final e in v) toJsValue(e)]);
  if (v is Map) {
    final o = JsObject();
    v.forEach((k, val) => o.setProp(k.toString(), toJsValue(val)));
    return o;
  }
  if (v is int || v is double || v is String || v is bool) return v;
  return jsUndefined;
}

/// JS 值 → Dart 值。`Uint8Array` 变 `Uint8List`；`{__bytes__: hex}` 还原为 bytes。
Object? fromJsValue(Object? v) {
  if (v is JsUndefined || v is JsNull) return null;
  if (v is JsUint8Array) return v.toBytes();
  if (v is JsArray) return [for (final e in v.items) fromJsValue(e)];
  if (v is JsObject) {
    final hex = v.props['__bytes__'];
    if (hex is String && v.props.length == 1) {
      return _hexToBytes(hex);
    }
    final out = <String, Object?>{};
    v.props.forEach((k, val) => out[k] = fromJsValue(val));
    return out;
  }
  if (v is JsDate) return v.dt.millisecondsSinceEpoch;
  if (v is JsFunctionBase) {
    throw err(ErrorCodes.js, 'set.js 不能返回函数');
  }
  return v;
}

Uint8List _hexToBytes(String hex) {
  if (hex.length.isOdd) {
    throw err(ErrorCodes.js, '__bytes__ 的 hex 长度为奇数：${hex.length}');
  }
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) {
      throw err(ErrorCodes.js, '__bytes__ 含非法 hex 字符：$hex');
    }
    out[i] = v;
  }
  return out;
}

/// 供 manifest 静态检查复用：判断代码是否含规范禁止的模式（§9.2）。
///
/// 只做粗筛，真正的拦截在运行时。返回命中的禁用标识符列表。
List<String> scanBannedIdentifiers(String code) {
  final found = <String>[];
  final banned = [
    'eval', 'Function', 'setTimeout', 'setInterval',
    'clearTimeout', 'clearInterval', 'fetch', 'XMLHttpRequest', 'require',
    'importScripts', 'WebAssembly',
  ];
  for (final b in banned) {
    // 词边界匹配，避免误伤 `evalCount` 这类变量
    final re = RegExp('(?<![A-Za-z0-9_\$])${RegExp.escape(b)}(?![A-Za-z0-9_\$])');
    if (re.hasMatch(code)) found.add(b);
  }
  return found;
}

/// 暴露给引擎：解析并检查 set.js 的语法（安装期即可发现错误，而非运行期）。
void validateSetJsSyntax(String code) {
  if (code.length > 20000) {
    throw err(ErrorCodes.schema,
        'set.js.code 超过 20000 字符上限（实际 ${code.length}）');
  }
  JsParser.parseProgram(code);
}

/// 仅解析、不执行——供 manifest 校验使用。
List<Stmt> parseOnly(String code) => JsParser.parseProgram(code);
