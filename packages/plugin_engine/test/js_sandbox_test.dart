/// set.js 沙箱测试：语法覆盖、语义正确性、边界与超时。
///
/// 与 `real_plugins_test.dart` 的分工：那边验证「清单能解析」，
/// 这边验证「JS 逃生舱能真的跑出正确结果」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:plugin_engine/plugin_engine.dart';
import 'package:test/test.dart';

Object? run(String code,
    {Map<String, Object?> inputs = const {},
    List<String> libs = const [],
    Duration timeout = const Duration(seconds: 5)}) {
  final ctx = FnContext(
    random: math.Random(7),
    clock: () => DateTime.utc(2024, 6, 1, 12, 0, 0),
  );
  return runSetJs(
    code: code,
    inputs: inputs,
    fnContext: ctx,
    clock: ctx.clock,
    random: ctx.random,
    timeout: timeout,
    libs: libs,
  );
}

Map<String, Object?> runManifest(String file) {
  final raw = File('test/fixtures/$file').readAsStringSync();
  final m = jsonDecode(raw)['manifest'] as Map<String, dynamic>;
  return m.cast<String, Object?>();
}

/// 取出 flow 里所有 set.js 步骤，按 id 索引。
Map<String, Map<String, Object?>> jsSteps(Map<String, Object?> manifest) {
  final out = <String, Map<String, Object?>>{};
  for (final s in (manifest['flow'] as List).cast<Map<String, dynamic>>()) {
    final set = s['set'] as Map<String, dynamic>?;
    final js = set?['js'] as Map<String, dynamic>?;
    if (js != null) out[s['id'] as String] = js.cast<String, Object?>();
  }
  return out;
}

void main() {
  group('语法覆盖面', () {
    test('var / 函数 / 闭包', () {
      final r = run(r'''
function adder(x) { return function (y) { return x + y; }; }
var add5 = adder(5);
return add5(37);
''');
      expect(r, 42);
    });

    test('if / else if / else', () {
      final r = run(r'''
function grade(n) {
  if (n >= 90) return 'A';
  else if (n >= 80) return 'B';
  else if (n >= 60) return 'C';
  else return 'F';
}
return grade(85) + grade(95) + grade(30);
''');
      expect(r, 'BAF');
    });

    test('for 三段式 + while + do/while', () {
      final r = run(r'''
var sum = 0;
for (var i = 0; i < 10; i++) { sum += i; }
var j = 0;
while (j < 5) { sum += 1; j++; }
var k = 0;
do { sum += 100; k++; } while (k < 2);
return sum;
''');
      expect(r, 45 + 5 + 200);
    });

    test('break / continue', () {
      final r = run(r'''
var out = [];
for (var i = 0; i < 10; i++) {
  if (i === 3) continue;
  if (i === 6) break;
  out.push(i);
}
return out.join(',');
''');
      expect(r, '0,1,2,4,5');
    });

    test('for-in 遍历对象', () {
      final r = run(r'''
var o = {a: 1, b: 2, c: 3};
var keys = [];
for (var k in o) { keys.push(k); }
return keys.join('');
''');
      expect(r, 'abc');
    });

    test('try / catch / throw', () {
      final r = run(r'''
function boom() { throw new Error('x'); }
try {
  boom();
  return 'no';
} catch (e) {
  return 'caught:' + e.message;
}
''');
      expect(r, 'caught:x');
    });

    test('try / finally 会执行 finally', () {
      final r = run(r'''
var log = [];
try { log.push('a'); } finally { log.push('b'); }
return log.join('');
''');
      expect(r, 'ab');
    });

    test('对象字面量 + 方法简写 + 数组字面量', () {
      final r = run(r'''
var o = {
  n: 7,
  double: function () { return this.n * 2; },
  triple() { return this.n * 3; }
};
return [o.double(), o.triple(), [1,2,3].length].join('|');
''');
      expect(r, '14|21|3');
    });

    test('三元、逻辑短路、逗号表达式', () {
      final r = run(r'''
var a = 1 > 0 ? 'y' : 'n';
var b = null || 'fallback';
var c = 0 && 'never';
var d = (1, 2, 3);
return [a, b, c === 0, d].join('|');
''');
      expect(r, 'y|fallback|true|3');
    });

    test('位运算含无符号右移', () {
      final r = run(r'''
var x = 0xFF;
var a = x >> 4;
var b = x << 2;
var c = x & 0x0F;
var d = x | 0x100;
var e = -1 >>> 28;
return [a, b, c, d, e].join(',');
''');
      expect(r, '15,1020,15,511,15');
    });

    test('原型链上的方法继承', () {
      final r = run(r'''
function Counter() { this.n = 0; }
Counter.prototype.inc = function () { this.n++; return this; };
Counter.prototype.value = function () { return this.n; };
var c = new Counter();
c.inc().inc().inc();
return c.value();
''');
      expect(r, 3);
    });

    test('instanceof / typeof / in', () {
      final r = run(r'''
var a = [];
var b = {};
var s = 'x';
return [
  a instanceof Array,
  typeof s,
  typeof undefinedThing,
  'k' in {k: 1}
].join('|');
''');
      expect(r, 'true|string|undefined|true');
    });
  });

  group('内建对象', () {
    test('String 方法', () {
      final r = run(r'''
var s = 'Hello,World';
return [
  s.length,
  s.toUpperCase(),
  s.toLowerCase(),
  s.indexOf('World'),
  s.substring(0, 5),
  s.slice(-5),
  s.split(',').join('-'),
  s.replace('World', 'JS'),
  s.charAt(1),
  s.charCodeAt(0),
  '  pad  '.trim()
].join('|');
''');
      expect(r, '11|HELLO,WORLD|hello,world|6|Hello|World|Hello-World|Hello,JS|e|72|pad');
    });

    test('String.fromCharCode', () {
      expect(run("return String.fromCharCode(72, 105);"), 'Hi');
    });

    test('Array 方法', () {
      final r = run(r'''
var a = [3, 1, 2];
a.push(4);
var p = a.pop();
a.unshift(0);
var sh = a.shift();
var b = a.reverse();
var c = a.slice(0, 2);
return [p, sh, a.length, c.join(''), a.indexOf(2)].join('|');
''');
      expect(r, '4|0|3|21|0');
    });

    test('Array.isArray / concat / join', () {
      final r = run(r'''
return [
  Array.isArray([]),
  Array.isArray('x'),
  [1,2].concat([3,4]).join('-'),
  [1,2,3].join(',')
].join('|');
''');
      expect(r, 'true|false|1-2-3-4|1,2,3');
    });

    test('Math', () {
      final r = run(r'''
return [
  Math.floor(3.7), Math.ceil(3.2), Math.abs(-5),
  Math.max(1, 9, 4), Math.min(1, 9, 4),
  Math.pow(2, 10), Math.round(3.5)
].join(',');
''');
      expect(r, '3,4,5,9,1,1024,4');
    });

    test('JSON 往返', () {
      final r = run(r'''
var o = {a: 1, b: [1,2], c: 'x'};
var s = JSON.stringify(o);
var back = JSON.parse(s);
return [s, back.a, back.b.length, back.c].join('|');
''');
      expect(r, '{"a":1,"b":[1,2],"c":"x"}|1|2|x');
    });

    test('Date（时钟由引擎注入，可复现）', () {
      final r = run(r'''
var d = new Date();
return [d.getFullYear(), d.getMonth(), d.getDate(), d.getHours()].join(',');
''');
      // 注入的时钟是 2024-06-01 12:00:00 UTC
      expect(r, '2024,5,1,12');
    });

    test('Uint8Array 构造、索引写入、subarray、set', () {
      final r = run(r'''
var a = new Uint8Array(4);
a[0] = 1; a[1] = 255; a[2] = 256;  // 256 & 0xFF = 0
var b = a.subarray(1, 3);
var c = new Uint8Array(3);
c.set(b);
return [a.length, a[0], a[1], a[2], b.length, c[0], c[1]].join(',');
''');
      expect(r, '4,1,255,0,2,255,0');
    });

    test('Uint8Array.from 与 length 越界读', () {
      final r = run(r'''
var a = new Uint8Array([10, 20, 30]);
return [a.length, a[0], a[5] === undefined, a.byteLength].join(',');
''');
      expect(r, '3,10,true,3');
    });

    test('parseInt / parseFloat / isNaN', () {
      final r = run(r'''
return [
  parseInt('42'), parseInt('ff', 16), parseFloat('3.14'),
  isNaN(NaN), isNaN(1)
].join(',');
''');
      expect(r, '42,255,3.14,true,false');
    });
  });

  group('fn 命名空间', () {
    test('直接调用 fn.hex / fn.unhex', () {
      final r = run(r'''
var b = new Uint8Array([1, 2, 255]);
var h = fn.hex(b);
var back = fn.unhex(h);
return h + '|' + back.length;
''');
      expect(r, '0102ff|3');
    });

    test('fn.* 返回 bytes 在 JS 里是 Uint8Array', () {
      final r = run(r'''
var b = fn.unhex('deadbeef');
return (b instanceof Uint8Array) + '|' + b.length;
''');
      expect(r, 'true|4');
    });

    test('未知 fn 报 E_UNDEF', () {
      expect(
        () => run('return fn.noSuchFn(1);'),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.undef)),
      );
    });

    test('参数个数错误报 E_ARG', () {
      expect(
        () => run('return fn.hex();'),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.arg)),
      );
    });

    test('fn 可被用于循环里反复调用', () {
      final r = run(r'''
var s = '';
for (var i = 0; i < 5; i++) { s += fn.hex(new Uint8Array([i])); }
return s;
''');
      expect(r, '0001020304');
    });
  });

  group('bytes 边界', () {
    test('input 传入的 bytes 在 JS 里是 Uint8Array', () {
      final r = run(
        'return (x instanceof Uint8Array) + "|" + x.length + "|" + x[0];',
        inputs: {'x': Uint8List.fromList([7, 8, 9])},
      );
      expect(r, 'true|3|7');
    });

    test('返回 Uint8Array 变成 Dart bytes', () {
      final r = run('return new Uint8Array([1, 2, 3]);');
      expect(r, isA<Uint8List>());
      expect((r as Uint8List).toList(), [1, 2, 3]);
    });

    test('__bytes__ 包装可还原为 bytes', () {
      final r = run("return {v: {__bytes__: '0a0b'}};");
      expect(r, isA<Map>());
      final m = r as Map;
      expect(m['v'], isA<Uint8List>());
      expect((m['v'] as Uint8List).toList(), [10, 11]);
    });

    test('非法 __bytes__ 报 E_JS', () {
      expect(
        () => run("return {__bytes__: 'zz'};"),
        throwsA(isA<PluginError>().having((e) => e.code, 'code', ErrorCodes.js)),
      );
    });
  });

  group('沙箱边界', () {
    test('返回 undefined 报 E_JS', () {
      expect(
        () => run('var x = 1;'),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.js)
            .having((e) => e.message, 'message', contains('undefined'))),
      );
    });

    test('死循环被超时中断', () {
      expect(
        () => run('while (true) {}', timeout: const Duration(milliseconds: 200)),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.js)),
      );
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('语法错误报 E_JS 且带行号', () {
      expect(
        () => run('var a = ;'),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.js)
            .having((e) => e.message, 'message', contains('第'))),
      );
    });

    test('switch / class / 箭头函数给出明确不支持提示', () {
      for (final code in [
        'switch (1) { }',
        'class A {}',
      ]) {
        expect(
          () => run(code),
          throwsA(isA<PluginError>()
              .having((e) => e.code, 'code', ErrorCodes.js)),
          reason: code,
        );
      }
    });

    test('inputs 保留名与非法标识符被拒绝', () {
      expect(
        () => run('return 1;', inputs: {'fn': 1}),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.schema)),
      );
      expect(
        () => run('return 1;', inputs: {'1bad': 1}),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.schema)),
      );
    });

    test('code 长度上限 20000', () {
      final long = 'var a = 1;' * 3000;
      expect(
        () => run(long),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.schema)),
      );
    });

    test('scanBannedIdentifiers 能识别禁用 API 且不误伤', () {
      expect(scanBannedIdentifiers('eval("1")'), contains('eval'));
      expect(scanBannedIdentifiers('fetch("http://x")'), contains('fetch'));
      expect(scanBannedIdentifiers('var evalCount = 1;'), isEmpty);
      expect(scanBannedIdentifiers('var require2 = 1;'), isEmpty);
    });
  });

  group('确定性', () {
    test('同种子下 Math.random 可复现', () {
      final a = run('return Math.random();');
      final b = run('return Math.random();');
      expect(a, b);
    });

    test('Date.now 来自注入时钟', () {
      final r = run('return Date.now();');
      expect(r, DateTime.utc(2024, 6, 1, 12).millisecondsSinceEpoch);
    });
  });

  group('真实插件：unicom.login', () {
    late Map<String, Map<String, Object?>> steps;

    setUpAll(() {
      steps = jsSteps(runManifest('unicom.login.json'));
    });

    test('四个 JS 步骤都存在于清单中', () {
      expect(steps.keys, containsAll(['buildSend', 'parseSend', 'buildLogin', 'parseLogin']));
    });

    test('buildSend 拼出完整请求体（含 RSA 加密与 urlSafe 转义）', () {
      final manifest = runManifest('unicom.login.json');
      final pub = (manifest['vars'] as Map)['rsaPub'] as String;
      final r = run(
        steps['buildSend']!['code'] as String,
        inputs: {
          'phone': '13800138000',
          'pub': pub,
          'uaPrefix': 'Mozilla/5.0',
          'deviceId': 'dev123',
          'appId': 'app1',
        },
      ) as Map;
      expect(r['body'], isA<String>());
      final body = r['body'] as String;
      expect(body, contains('timestamp=20240601120000'));
      expect(body, contains('deviceId=dev123'));
      expect(body, contains('mobile='));
      // 插件的 urlSafe 只转 '=' 与 '+'（源码注释 L167-168），'/' 保持原样
      final mobile = RegExp(r'mobile=([^&]*)').firstMatch(body)!.group(1)!;
      expect(mobile, isNot(contains('+')));
      expect(mobile, isNot(contains('=')));
      expect(r['ua'], contains('desmobile:13800138000'));
      expect(r['androidId'], isA<String>());
    });

    test('parseSend 在 code=空 时按成功处理（源码注释：非 JSON → code=\'\' → 成功）', () {
      final r = run(
        steps['parseSend']!['code'] as String,
        inputs: {'code': '', 'msg': '', 'message': '', 'desc': '', 'resultMsg': ''},
      ) as Map;
      expect(r['ok'], true);
      expect(r['err'], '验证码下发失败');
    });

    test('parseSend 在 code=非零 时判为失败，err 按 msg→message→desc→resultMsg 优先级取', () {
      final r = run(
        steps['parseSend']!['code'] as String,
        inputs: {
          'code': '1001',
          'msg': '',
          'message': '短信通道异常',
          'desc': '不应被选中',
          'resultMsg': '也不应',
        },
      ) as Map;
      expect(r['ok'], false);
      expect(r['err'], '短信通道异常');
    });

    test('parseSend 在 code=0000 时按成功处理', () {
      final r = run(
        steps['parseSend']!['code'] as String,
        inputs: {'code': '0000'},
      ) as Map;
      expect(r['ok'], true);
    });

    test('parseLogin 带回 token 且所有键恒存在', () {
      final r = run(
        steps['parseLogin']!['code'] as String,
        inputs: {
          'token_online': 'TOK', 'ecs_token': '',
          'msg': '', 'message': '', 'desc': '', 'resultMsg': '',
        },
      ) as Map;
      expect(r.containsKey('ok'), true);
      expect(r.containsKey('err'), true);
      expect(r['token_online'], 'TOK');
    });
  });

  group('真实插件：ysp.ck（JCE 二进制协议）', () {
    late Map<String, Map<String, Object?>> steps;
    late String tpl;
    const guid = 'fae6d360866f105c23d7ce8dbfef705d';

    setUpAll(() {
      final manifest = runManifest('ysp.ck.json');
      steps = jsSteps(manifest);
      tpl = (manifest['vars'] as Map)['jaccTplB64'] as String;
    });

    test('buildSend 产出合法 JACC 包（0x13 头、0x03 尾、长度字段自洽）', () {
      final r = run(
        steps['buildSend']!['code'] as String,
        inputs: {
          'tplB64': tpl, 'mode': 'send', 'guid': guid, 'phone': '13800138000',
        },
      ) as Map;
      final pkt = r['packet'] as String;
      final bytes = Uint8List.fromList([
        for (var i = 0; i < pkt.length; i += 2)
          int.parse(pkt.substring(i, i + 2), radix: 16)
      ]);
      expect(bytes[0], 0x13);
      expect(bytes.last, 0x03);
      // 第 1..4 字节是总长度（大端），应与实际一致
      final declared =
          (bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4];
      expect(declared, bytes.length);
      // rqid 落在合法范围内
      final rqid = int.parse(r['rqid'] as String);
      expect(rqid, inInclusiveRange(1, 2147483646));
    });

    test('三个构建步骤（send/login/renew）都能出包且长度自洽', () {
      for (final mode in ['send', 'login', 'renew']) {
        final r = run(
          steps['build${
              mode[0].toUpperCase()}${mode.substring(1)}']!['code'] as String,
          inputs: {
            'tplB64': tpl, 'mode': mode, 'guid': guid,
            'phone': '13800138000', 'smsCode': '123456',
            'openid': 'OID', 'access': 'ACC', 'refresh': 'REF',
          },
        ) as Map;
        final bytes = Uint8List.fromList([
          for (var i = 0; i < (r['packet'] as String).length; i += 2)
            int.parse((r['packet'] as String).substring(i, i + 2), radix: 16)
        ]);
        expect(bytes[0], 0x13, reason: mode);
        expect(bytes.last, 0x03, reason: mode);
        final declared =
            (bytes[1] << 24) | (bytes[2] << 16) | (bytes[3] << 8) | bytes[4];
        expect(declared, bytes.length, reason: mode);
      }
    });

    test('parseSend 收到自造成功响应时返回 ok', () {
      // 用插件自身的编码器造一个 errCode=0 的合法响应
      const mk = r'''
function __mkOkResp() {
  var __hdr = { t: JCE_SBEGIN, tag: 0, v: [ jceField(0, 0), jceField(0, 1) ] };
  var __errNode = jceField(0, 2);
  var __inner = encStruct([ jceField(0, 0) ]);
  var __outer = [__hdr, __errNode, bytesField(__inner, 1)];
  var __bb = new BB();
  for (var i = 0; i < __outer.length; i++) encValue(__bb, __outer[i]);
  return jaccRewrap(fn.unb64(tplB64), 24680, __bb.out(), 12345);
}
''';
      final code = mk +
          (steps['parseSend']!['code'] as String)
              .replaceFirst('var __raw = fn.unhex(respHex);',
                  'var __raw = __mkOkResp();');
      final r = run(code,
          inputs: {'respHex': '', 'mode': 'send', 'tplB64': tpl}) as Map;
      expect(r['ok'], true);
      expect(r['err'], '');
    });

    test('parseRenew 返回状态字符串而非对象', () {
      final r = run(
        steps['parseRenew']!['code'] as String,
        inputs: {'respHex': '', 'mode': 'renew'},
      );
      expect(r, isA<String>());
      expect(r as String, contains('响应异常'));
    });

    test('cookie 步骤拼出完整 Cookie 串', () {
      final r = run(
        steps['cookie']!['code'] as String,
        inputs: {
          'openid': 'OID', 'access': 'ACC', 'refresh': 'REF',
          'vusession': 'VUS', 'vuserid': '100', 'endtime': 1717200000,
          'guid': 'GUID123',
        },
      );
      expect(r, isA<String>());
      final s = r as String;
      for (final k in [
        'openid=OID', 'access_token=ACC', 'refresh_token=REF',
        'vusession=VUS', 'vuserid=100', 'endtime=1717200000', 'guid=GUID123',
      ]) {
        expect(s, contains(k));
      }
    });
  });

  group('forge 最小实现', () {
    test('未声明 hooks.libs 时 forge 未定义', () {
      expect(
        () => run('return forge.util.bytesToHex(new Uint8Array([1]));'),
        throwsA(isA<PluginError>().having((e) => e.code, 'code', ErrorCodes.js)),
      );
    });

    test('声明后可用的子集', () {
      final r = run(
        r'''
var b = forge.util.encodeUtf8('AB');
var h = forge.util.bytesToHex(b);
var back = forge.util.decodeUtf8(forge.util.hexToBytes('4142'));
return h + '|' + back;
''',
        libs: ['forge@1.4.0'],
      );
      expect(r, '4142|AB');
    });

    test('非法 lib 被拒绝', () {
      expect(
        () => run('return 1;', libs: ['lodash@1.0']),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.schema)),
      );
    });
  });

  group('解析器', () {
    test('validateSetJsSyntax 在安装期就能发现语法错误', () {
      expect(() => validateSetJsSyntax('var a = ;'),
          throwsA(isA<PluginError>()));
      expect(() => validateSetJsSyntax('var a = 1;'), returnsNormally);
    });

    test('ASI：省略分号也能解析', () {
      final r = run('''
var a = 1
var b = 2
return a + b
''');
      expect(r, 3);
    });

    test('return 后换行按 ASI 处理（返回 undefined）', () {
      expect(
        () => run('''
function f() {
  return
  42;
}
return f();
'''),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.js)),
      );
    });

    test('parseProgram 能处理注释', () {
      final r = run(r'''
// 行注释
var a = 1; /* 块注释 */
/* 多行
   注释 */
return a;
''');
      expect(r, 1);
    });
  });
}
