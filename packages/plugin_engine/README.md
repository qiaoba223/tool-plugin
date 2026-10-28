# plugin_engine

登录插件引擎的纯 Dart 实现，对齐上游 [`mtguowang/tool-plugin`](https://github.com/mtguowang/tool-plugin)
的**契约**（`contract/` 下的 schema、校验脚本、规范文档）。

上游 App 源码未开源，因此这里的对齐标准是「契约一致 + 官方插件跑通」，
而不是逐行移植。已知推断点与偏差全部记录在 [`contract/ALIGNMENT.md`](../../contract/ALIGNMENT.md)。

## 组成

| 模块 | 说明 |
|---|---|
| `lexer` / `expr` / `template` | 模板表达式 `{{...}}` 的词法、语法与求值 |
| `functions` | 73 个 `fn.*` 函数（编码/哈希/加密/字符串/bytes/随机/日期…） |
| `manifest` | 清单解析与校验（严格对齐 `manifest.schema.json`） |
| `engine` | 流程执行：request / set / ui / poll 四类步骤、分支、重试、断言 |
| `extractor` / `conditions` | 响应取值（JSONPath 子集）与 `assert` 条件 |
| `package` | `.qbpkg` 信封的编解码 |
| `js/` | **set.js 沙箱**：纯 Dart 实现的 ES5 子集解释器（见下） |

## 关于 set.js 沙箱

上游生产宿主是 QuickJS，但它在 iOS 上不可用（无 JIT、需静态链入 Xcode 工程）。
为满足「Android + iOS 同一份代码」的目标，这里自己实现了 ES5 子集解释器：

- 零原生依赖，`dart test` 可直接跑
- 覆盖 `var`/`function`/`if`/`for`/`while`/`try-catch`/闭包/原型链/位运算
- 内建 `String`/`Array`/`Math`/`JSON`/`Date`/`Uint8Array`/`RegExp`
- 注入 `fn.*` 全部 73 个函数，bytes 跨边界自动映射为 `Uint8Array`
- `hooks.timeoutMs` 真正生效（逐语句检查截止时间，死循环会被中断）

不支持项（正则字面量、`switch`、`class`、箭头函数等）**一律明确报 `E_JS`**，
不会静默出错。想换成 QuickJS？传 `Engine.jsRuntime` 即可，其余不用动。

## 测试

```bash
dart test        # 104 项
dart analyze     # 0 issue
```

验收基线是 `test/fixtures/` 下从 `plugin-harbor` 解出的 **4 个真实插件**：
`ct.login`、`unicom.login`、`zto.member`、`ysp.ck`。其中 `unicom.login` 与 `ysp.ck`
的 11 段 set.js 被逐段执行验证（含 JCE 二进制协议往返）。
