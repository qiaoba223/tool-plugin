# 与上游契约的对齐记录

上游 [`mtguowang/tool-plugin`](https://github.com/mtguowang/tool-plugin) **只公开规范与校验器，
引擎源码（`login-plugin-framework/ui_core/`、`ui_flutter/`）未开源。**

因此本实现是**按规范复现**，不是移植。本文件记录三件事：

1. 哪些部分做到了逐字对齐（可信）
2. 哪些部分是推断的（需要真实插件验证）
3. 上游更新时怎么同步

---

## 一、逐字对齐（可信度高）

| 本实现 | 上游来源 | 对齐方式 |
|---|---|---|
| `src/lexer.dart` | `validate.py` 的 `TOKEN_RE` | 正则逐字照抄，含顺序（先匹配者胜） |
| `src/lexer.dart` `findTemplates` | `validate.py` 的 `find_templates` | 逐行翻译，含 `\{\{` 字面量跳过 |
| `src/expr.dart` `ExprParser` | `validate.py` 的 `ExprParser` | 每个方法逐个翻译（`parse_or`/`parse_and`/`parse_cmp`/`parse_unary`/`parse_primary`/`parse_path_or_call`） |
| `src/functions.dart` `fnSpecs` | `validate.py` 的 `FN_SPECS` | 73 项逐项照抄（数量、参数个数、返回类型） |
| `src/errors.dart` | 规范附录 A | 17 个错误码逐个照抄 |
| `src/manifest.dart` 结构校验 | `manifest.schema.json` | 必填、枚举、范围、`additionalProperties: false` |
| `src/package.dart` | `plugin-harbor/tools/build_index.py` 头部 | `.qbpkg` 信封字段逐字对齐 |
| `src/engine.dart` 跳转语义 | 规范 §5.1 / §5.2 | `when` 为假仍计算跳转等细节 |

**关键**：`lexer` / `expr` / `fnSpecs` 三处是唯一能对照上游**真实代码**的地方
（`validate.py` 是公开的上游实现），所以这三处可信度最高。

---

## 二、已知上游不一致（★ 重要）

### 1. `fn.rsaPkcs1` 的参数个数

| 来源 | 说法 |
|---|---|
| `validate.py` `FN_SPECS` | `(2, 2, "string")` —— 严格 2 个参数 |
| 规范 §8.3 正文 | `fn.rsaPkcs1(pubB64, plaintext, bt?)` —— 2 到 3 个 |
| `plugin-harbor` 的 `unicom.login` 实际用法 | `fn.rsaPkcs1(pub, phone, '02')` —— **传了 3 个** |

**本实现取 `(2, 3)`**，以规范正文 + 真实插件为准。

按 `FN_SPECS` 的说法，上游自己发布的 `unicom.login` 应该是非法的 —— 但它显然能跑。
结论：`FN_SPECS` 表漏了可选参数，是上游的 bug。

---

## 三、推断实现（需真实插件验证）

规范只描述了行为、没给精确算法的地方。这些是**最可能出偏差**的位置。

| 函数 | 我的实现 | 风险 |
|---|---|---|
| `fn.shift2(s)` | 每个字符码点 +2 | 规范只说「+2 位移」。`ct.login` 用它产出「转换后 Android ID」，需用真实结果对拍 |
| `fn.shiftN(s, n)` | 同上，n 可正可负 | 规范未定义负数行为 |
| `fn.padRight/padLeft(s, len, ch)` | 按字符（rune）补齐 | 若上游按 UTF-16 code unit 补，中文会不一致 |
| `fn.scanAscii(b, start, len)` | 取可打印 ASCII 连续段 | 规范只有一句话描述 |
| `fn.charsetDecode(b, 'gbk')` | 内置 252 条范围表，覆盖约 2 万字符，简中常用字正确解码 | 未能覆盖 GBK 全码位；罕用字/繁体仍回退 U+FFFD |
| `fn.aesCbc/aesEcb` | pointycastle，PKCS7 填充 | 规范未写明填充模式 |
| `fn.crc32` | 标准 CRC-32（IEEE，多项式 0xEDB88320） | 规范只说「crc32」 |
| `fn.gzip/gunz` | `archive` 包 | 压缩级别可能不同 |
| `fn.randomModOffset` | 未充分理解语义 | **需确认** |
| `fn.randomOf(list)` | 均匀随机取一项 | — |
| `fn.dateFormat/toDate` | UTC，`YYYY/MM/DD/HH/mm/ss/SSS` | 规范明确 UTC，但 token 全集未列全 |
| `jsonPath` | 只支持 `.a.b[0]` 点路径与下标 | 规范 `check_jsonpath` 明确不支持过滤器/通配符 |
| `raw` extract 的 offset | 按**字节**计算 | 规范说「body 是 bytes」，但未明确 offset 单位 |
| `poll.until` 求值时机 | 子步骤全跑完后求值 | §7.1 描述为「每轮结束」，已对齐 |

### 待补的硬缺口

- ~~**GBK 表**~~：已补全。`gbk_tables.dart` 收录 252 条压缩范围，覆盖约 2 万字符，
  简中常用字已验证正确（`中文测试简体字符`）。仍存的限制是 GBK 罕用字与繁体区
  未全部收录，遇到时回退 `U+FFFD`。
- **`set.js` 沙箱**：`Engine.jsRuntime` 是注入点，未注入时抛 `E_JS`（不静默降级）。
  Flutter 侧接 `flutter_js`（QuickJS 内核）。**4 个真实插件里有 2 个依赖它。**

---

## 四、上游更新时的同步流程

```bash
# 1. 拉取上游最新契约，看有什么变了
curl -sO https://raw.githubusercontent.com/mtguowang/tool-plugin/main/schema/manifest.schema.json
curl -sO https://raw.githubusercontent.com/mtguowang/tool-plugin/main/schema/validate.py
curl -sO https://raw.githubusercontent.com/mtguowang/tool-plugin/main/docs/PLUGIN_JSON_GUIDE.md

# 2. 与本地基线对比
diff contract/manifest.schema.json 新/manifest.schema.json
diff contract/validate.py          新/validate.py
diff contract/PLUGIN_JSON_GUIDE.md 新/PLUGIN_JSON_GUIDE.md
```

按 diff 结果改对应位置：

| 上游改动 | 要改本实现 |
|---|---|
| schema 加字段 / 改枚举 / 改范围 | `src/manifest.dart` |
| `FN_SPECS` 加函数 / 改参数个数 | `src/functions.dart` 的 `fnSpecs` + `callFn` |
| 规范正文改函数语义 | `src/functions.dart` 对应实现 |
| 规范改执行语义（goto/end/poll） | `src/engine.dart` |
| 错误码增删 | `src/errors.dart` |
| `.qbpkg` 信封格式 | `src/package.dart` |

### 自动拦截

- `test/fn_specs_test.dart` —— 断言 `fnSpecs` 恰好 73 项且与上游表逐项一致。
  上游加第 74 个函数、我忘了加，CI 立刻红。
- `test/contract_test.dart` —— 断言 schema 的关键约束（未知字段拒绝、步骤类型互斥）
  在 `manifest.dart` 里确实生效。

---

## 五、验证基线

`test/fixtures/` 里是从 `plugin-harbor` 的 `.qbpkg` 解出的 **4 个真实插件**：

| 插件 | 用途 |
|---|---|
| `ct.login` | 验证 RSA + 验证码 + poll + 多分支 |
| `unicom.login` | 验证 `set.js` + 3 参 `rsaPkcs1` + 失败分支 |
| `zto.member` | 验证 32 步长流程 + `ui` 4 种控件 + 3 条链路 |
| `ysp.ck` | 验证 `set.js` 二进制 JCE 协议 + `hex`/`unhex`/`be16` |

**这 4 个插件是唯一的验收标准。** 光读规范写出来的代码，不算对齐。

---

## 六、set.js 沙箱：为什么自己写解释器

规范 §12 说生产宿主是 **QuickJS**。但 Flutter 生态里的 QuickJS 绑定（`flutter_js`）
在 **iOS 上不可用**：iOS 禁止 JIT，且需要把 QuickJS 静态链进 Xcode 工程、
改 Podfile，产物还要过审。而本项目的硬性目标是 **Android + iOS 都能构建**。

**决策：在引擎内实现一个纯 Dart 的 ES5 子集解释器**
（`lib/src/js/`：`js_token` / `js_parser` / `js_value` / `js_builtins` / `js_interp` / `js_bridge`）。

这样做的理由：

1. **零原生依赖** —— Android/iOS 同一份代码，`dart test` 能直接跑，不需要设备。
2. **能力边界是规范给定的** —— §12 已把沙箱限定成 ES5 + `JSON`/`Math`/`Date`/
   `Uint8Array` + 注入的 `fn`，且明确禁用 `eval`/`Function`/`fetch`/`require`。
   这是一个封闭、可控的子集，不是「实现整个 JS」。
3. **超时可控** —— 解释器每执行一条语句就检查一次截止时间（`_tick`），
   `hooks.timeoutMs` 能真正生效；死循环会被中断而不是拖死 UI 线程。

`Engine.jsRuntime` 注入点保留：想换成 QuickJS 或其他实现，宿主传一个回调即可，
引擎其余部分不用动。

### 6.1 已知不支持项（都会明确报 `E_JS`，不会静默出错）

| 特性 | 原因 |
|---|---|
| 正则字面量 `/re/g` | §12 未承诺；需要正则时用 `new RegExp(pattern, flags)` |
| `switch` / `class` / 箭头函数 / 解构 / 模板字符串 / 展开 | 4 个真实插件均未使用；实现成本高、收益低 |
| `getter`/`setter`、`Symbol`、`Proxy`、迭代器协议 | 同上 |

判断依据是先统计了 `unicom.login` 与 `ysp.ck` 的 11 段 set.js（最长 17656 字符）
实际用到的语法与内建，再据此定实现范围 —— 见 §五 的验收基线。

### 6.2 forge

§12 只允许 `forge@1.4.0`。完整移植体量过大，这里提供**最小实现**：
`forge.util.encodeUtf8/decodeUtf8/bytesToHex/hexToBytes`、`forge.md.sha1/sha256/md5`。
未覆盖的 API **调用即报错**，不会返回 undefined 让插件生成错误密文却无人察觉。
若后续插件真的需要 forge 的 AES/RSA 高级模式，再按需补齐。
