import 'dart:convert';
import 'dart:typed_data';

import 'package:plugin_engine/plugin_engine.dart';
import 'package:test/test.dart';

/// 用最小 fn 调用取结果（自有 callFn 与库内同名，故重命名）。
Object? fx(String name, List<Object?> args) =>
    callFn(name, args, FnContext());

void main() {
  group('字符串操作（§8.4）', () {
    test('shift2 按 UTF-16 码元 +2', () {
      expect(fx('shift2', ['abc']), 'cde');
      // 中文：0x4E2D +2 = 0x4E2F
      expect(fx('shift2', ['中']), String.fromCharCode(0x4E2F));
    });

    test('shift2 保持 UTF-16 长度（emoji 两个代理项各 +2）', () {
      const s = '😀'; // U+1F600 -> D83D DE00
      final out = fx('shift2', [s]) as String;
      expect(out.length, s.length, reason: '不能变成 1 个码点');
      expect(out.codeUnitAt(0), 0xD83D + 2);
      expect(out.codeUnitAt(1), 0xDE00 + 2);
    });

    test('shiftN 越界报 E_ARG', () {
      expect(
        () => fx('shiftN', ['\uFFFF', 1]),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.arg)),
      );
    });

    test('padRight / padLeft', () {
      expect(fx('padRight', ['ab', 5, '0']), 'ab000');
      expect(fx('padLeft', ['ab', 5, '0']), '000ab');
      // 已够长则不截断
      expect(fx('padRight', ['abcdef', 3, '0']), 'abcdef');
    });

    test('pad 空串 c 报 E_ARG', () {
      expect(() => fx('padRight', ['a', 3, '']),
          throwsA(isA<PluginError>()));
    });

    test('repeat 取首个码位', () {
      expect(fx('repeat', ['ab', 3]), 'aaa');
      expect(fx('repeat', ['x', 0]), '');
      expect(() => fx('repeat', ['x', -1]), throwsA(isA<PluginError>()));
    });

    test('substring 越界截断、无负索引', () {
      expect(fx('substring', ['abcdef', 2]), 'cdef');
      expect(fx('substring', ['abcdef', 1, 3]), 'bc');
      // 越界截断：end 超长时裁到末尾
      expect(fx('substring', ['abc', 1, 999]), 'bc');
      // 无负索引 -> E_ARG
      expect(() => fx('substring', ['abc', -1]),
          throwsA(isA<PluginError>()));
    });

    test('concat 首参决定类型', () {
      expect(fx('concat', ['a', 'b', 'c']), 'abc');
      expect(fx('concat', ['a', 1, true]), 'a1true');
      // null 渲染为空串
      expect(fx('concat', ['a', null]), 'a');
    });
  });

  group('编码 / 转换（§8.1）', () {
    test('b64 / unb64 往返', () {
      final b = fx('b64', ['hello']) as String;
      expect(b, 'aGVsbG8=');
      // §8.2：unb64 返回 bytes，不做 UTF-8 解码
      final raw = fx('unb64', [b]) as Uint8List;
      expect(utf8.decode(raw), 'hello');
    });

    test('b64 后 unb64 得到原 bytes', () {
      final b64 = fx('b64', ['中文']) as String;
      final raw = fx('unb64', [b64]);
      expect(raw, isA<Uint8List>());
      expect(utf8.decode(raw as Uint8List), '中文');
    });

    test('unb64 拒绝非法字符（上游默认宽松，这里按 E_ARG）', () {
      expect(() => fx('unb64', ['a*b']), throwsA(isA<PluginError>()));
    });

    test('b64url 无 padding、用 - _', () {
      final s = fx('b64url', ['\u00ff\u00fe']) as String;
      expect(s.contains('+'), isFalse);
      expect(s.contains('/'), isFalse);
      expect(fx('unb64url', [s]), isA<Uint8List>());
    });

    test('hex / unhex', () {
      expect(fx('hex', ['AB']), '4142');
      expect(utf8.decode(fx('unhex', ['e4b8ad']) as Uint8List), '中');
    });

    test('urlenc 用 %20 而非 +', () {
      expect(fx('urlenc', ['a b']), 'a%20b');
    });

    test('charsetDecode gbk 中文', () {
      // "中" 的 GBK 是 D6 D0
      final bytes = Uint8List.fromList([0xD6, 0xD0]);
      expect(fx('charsetDecode', [bytes, 'gbk']), '中');
      expect(fx('charsetDecode', [bytes, 'gb2312']), '中');
    });

    test('charsetDecode 未知字符集报 E_ARG', () {
      expect(() => fx('charsetDecode', [Uint8List(0), 'koi8']),
          throwsA(isA<PluginError>()));
    });
  });

  group('bytes 操作（§8.5）', () {
    test('be32Write / be32Read 往返（签名 b, offset, value）', () {
      final buf = Uint8List(4);
      final b = fx('be32Write', [buf, 0, 0x01020304]) as Uint8List;
      expect(b, [1, 2, 3, 4]);
      expect(fx('be32Read', [b, 0]), 0x01020304);
    });

    test('u8Write（签名 b, offset, value）', () {
      final buf = Uint8List(1);
      final b = fx('u8Write', [buf, 0, 255]) as Uint8List;
      expect(b, [255]);
    });

    test('be32Read 越界报 E_ARG', () {
      expect(() => fx('be32Read', [Uint8List(2), 0]),
          throwsA(isA<PluginError>()));
    });
  });

  group('随机 / 时间（§8.6）', () {
    test('ts13 / ts14 位数正确', () {
      expect((fx('ts13', []) as String).length, 13);
      expect((fx('ts14', []) as String).length, 14);
    });

    test('ts10 秒级', () {
      expect((fx('ts10', []) as String).length, 10);
    });
  });

  group('随机 / 时间·随机（§8.6）', () {
    test('randomHex 长度', () {
      expect((fx('randomHex', [16]) as String).length, 16);
    });

    test('randomInt 范围', () {
      for (var i = 0; i < 50; i++) {
        final v = fx('randomInt', [1, 6]) as int;
        expect(v, inInclusiveRange(1, 6));
      }
    });

    test('randomOf 命中集合（参数为 list）', () {
      final v = fx('randomOf', [
        ['a', 'b', 'c']
      ]) as String;
      expect(['a', 'b', 'c'], contains(v));
    });

    test('randomOf 空 list 报 E_ARG', () {
      expect(() => fx('randomOf', [<Object?>[]]),
          throwsA(isA<PluginError>()));
    });
  });

  group('参数个数校验（上游 FN_SPECS）', () {
    test('rsaPkcs1 接受 2 和 3 个参数', () {
      // 参数个数校验通过后才会因公钥非法而报 E_ARG
      expect(() => fx('rsaPkcs1', ['notb64', 'x']),
          throwsA(isA<PluginError>()));
      expect(() => fx('rsaPkcs1', ['notb64', 'x', '02']),
          throwsA(isA<PluginError>()));
    });

    test('substring 拒绝 1 个参数', () {
      expect(() => fx('substring', ['abc']),
          throwsA(isA<PluginError>()));
    });

    test('未知函数报 E_UNDEF', () {
      expect(
        () => fx('nopeFn', []),
        throwsA(isA<PluginError>()
            .having((e) => e.code, 'code', ErrorCodes.undef)),
      );
    });
  });
}
