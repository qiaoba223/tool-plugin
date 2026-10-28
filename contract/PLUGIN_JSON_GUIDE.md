# 登录插件 manifest.json 编写指南（面向 AI 代理）

本文面向**插件作者与 AI 代理**，讲清楚一件事：**如何从零写出一个能被「工具插件」App 加载并运行的插件**，以及每个字段为什么这样设计。目标是：一位从未接触过本框架的作者（人或 AI），仅凭本文即可写出**第一次就能通过校验、并按预期运行**的插件。

插件 = 一份 `manifest.json`（外加可选的图标）。它声明：

1. **输入**：运行前向用户收集哪些信息（手机号、验证码……）
2. **流程**：按什么顺序发哪些 HTTP 请求、中途如何与用户交互
3. **输出**：运行结束后向用户展示哪些结果

引擎负责执行；插件只负责声明。整份文件是纯数据，**不含任何可执行代码**。唯一的例外是两段受严格沙箱约束的 JS：可选的 `set.js` 逃生舱（[第 9 节](#9-setjs--js-逃生舱)）与 `ui.type=webview` 页面内的 bridge 回传（[第 7.3 节](#73-type-webview--网页交互滑块风控)）。

> 契约层权威定义见仓库根目录 `CONTRACT.md` 与 `schema/manifest.schema.json`；本文是面向作者的实操教程，三处冲突时以 schema 与引擎源码为准。
>
> 本文所有示例使用 `api.example.com`、`demo.invalid` 等保留域名与示例手机号 `13800138000`，可直接替换为目标站点的真实值。

## 目录

- [0. 阅读须知与快速开始](#0-阅读须知与快速开始)
- [1. 心智模型与执行语义](#1-心智模型与执行语义)
- [2. 顶层字段](#2-顶层字段)
- [3. inputs —— 用户输入表单](#3-inputs--用户输入表单)
- [4. 模板与表达式](#4-模板与表达式)
- [5. flow 与步骤通用机制](#5-flow-与步骤通用机制)
- [6. request 步骤](#6-request-步骤)
- [7. poll / ui / set 步骤](#7-poll--ui--set-步骤)
- [8. fn.* 函数库（73 个）](#8-fn-函数库73-个)
- [9. set.js —— JS 逃生舱](#9-setjs--js-逃生舱)
- [10. output —— 结果展示](#10-output--结果展示)
- [11. 网络安全模型](#11-网络安全模型)
- [12. hooks 与 JS 沙箱边界](#12-hooks-与-js-沙箱边界)
- [13. 打包、校验与分发](#13-打包校验与分发)
- [14. 任务配方（Recipes）](#14-任务配方recipes)
- [附录 A：错误码速查](#附录-a错误码速查)
- [附录 B：发布前检查清单](#附录-b发布前检查清单)

---

## 0. 阅读须知与快速开始

### 0.1 写插件的三步法

1. **定义输入**：把「运行前必须向用户收集的东西」列进 `inputs`（手机号、密码、验证码……），或者空数组。
2. **编排流程**：把「拿到登录凭证」这件事拆成一串步骤（`flow`），每步是一次 HTTP 请求、一次用户交互、一次轮询等待或一次变量计算。
3. **声明输出**：把「用户最终要看到/复制的东西」列进 `output.fields`（token、cookie……）。

### 0.2 最小可运行插件

下面这份 manifest 通过全部校验，可直接作为模板（保存为 `manifest.json`）：

```jsonc
{
  "id": "demo.hello",
  "name": "示例插件",
  "version": "1.0.0",
  "engine": ">=1.0 <2.0",
  "allowHosts": ["demo.invalid"],
  "inputs": [],
  "flow": [
    {
      "id": "fetch",
      "type": "request",
      "request": {
        "method": "GET",
        "url": "https://demo.invalid/hello"
      },
      "extract": [
        { "name": "token", "from": "json", "path": "$.data.token" }
      ],
      "end": true
    }
  ],
  "output": {
    "title": "获取结果",
    "fields": [
      { "label": "Token", "value": "{{steps.fetch.token}}" }
    ]
  }
}
```

要点：

- `allowHosts` 里必须包含 `request.url` 的 host，否则请求发出前就报 `E_HOST`。
- `extract` 把响应里的值挂到 `steps.<步骤id>.<name>` 下，供后续模板引用。
- `"end": true` 表示流程在这一步正常结束；没有它，流程会继续走 `flow` 数组的下一项。
- `output.fields[].value` 是模板，`{{steps.fetch.token}}` 引用上一步提取的值。

### 0.3 如何验证

写完 manifest 后，在仓库根目录运行（Python 3.9+）：

**先获取校验器**（两个文件，从本仓库下载）：

```bash
# 方式一：直接下载（推荐）
curl -O https://raw.githubusercontent.com/mtguowang/tool-plugin/main/schema/validate.py
curl -O https://raw.githubusercontent.com/mtguowang/tool-plugin/main/schema/manifest.schema.json

# 方式二：git clone 整个仓库
git clone https://github.com/mtguowang/tool-plugin.git
# 校验器在 tool-plugin/schema/ 下
```

> ⚠️ `validate.py` 与 `manifest.schema.json` **必须放在同一目录**（前者默认读同目录的 schema）。
> 零依赖，只需 Python 3.8+，不需要 `pip install` 任何东西。

**运行校验**：

```bash
python validate.py <你的插件目录>/manifest.json

# 也可以一次校验整个目录（批量）
python validate.py --dir <插件根目录>

# 只看错误不看统计
python validate.py manifest.json --quiet
```

它会做三类检查：

1. JSON 语法与重复键检测（`{"a":1,"a":2}` 这种肉眼难查的错误）；
2. JSON Schema 结构校验（字段名拼写、类型、取值范围、`additionalProperties: false`）；
3. 跨字段语义校验（`goto`/`branch`/`poll.steps` 指向的 step id 是否存在、extract 名是否唯一、allowHosts 是否为纯 host、webview 的 url/html 互斥等）。

**先让 validate.py 零报错，再上真机调试**——这一步能拦住绝大多数低级错误。

### 0.4 十条铁律（AI 代理请逐条自查）

1. **未知字段一律拒绝**。写错字段名（如 `retryTimes`、`timeout`）不会静默失效，而是直接 `E_SCHEMA` 拒绝加载。所有字段名以本文与 schema 为准。
2. **引用不存在的路径报 `E_UNDEF`，不会静默返回 null**。这是刻意设计：静默 null 会让协议错误极难排查。所以 `{{vars.foo}}` 在 `vars.foo` 未定义时是硬错误。
3. **bytes（字节串）不能直接渲染成字符串**。`{{fn.unhex(vars.hexStr)}}` 会报 `E_TYPE`，必须转成可见形式：`{{fn.hex(fn.unhex(vars.hexStr))}}` 或 `fn.b64(...)`、`fn.latin1(...)`。
4. **模板里写函数用 `fn.xxx()`**，命名空间只有 `fn` 一个；`Math.max(...)`、`JSON.parse(...)` 之类都不存在。
5. **`when`/`until`/assert 谓词必须求值为 bool**。`"when": "vars.code"`（非布尔表达式）会报错，要写 `"when": "vars.code != ''"`。
6. **allowHosts 是硬白名单**：host（可带端口），不含 scheme、不支持通配符；漏写任何会被访问的 host 都会在运行期报 `E_HOST`。
7. **步骤被访问超过 `flow.length * 3` 次报 `E_LOOP`**。被 `when` 跳过的步骤和被 poll 反复执行的步骤都计入访问次数。
8. **`output` 只引用 `vars.*` 和 `input.*`**。直接引用「可能没执行到的步骤」的提取值（如 `steps.login.token`）会在提前结束时炸 `E_UNDEF`；正确做法是先 `set` 进 `vars`（见 [第 10.3 节](#103-output-引用规则与-e_undef-陷阱)）。
9. **JSON 里没有注释**。本文用 `jsonc` 代码块讲解，实际文件必须去掉 `//` 注释，否则 JSON 解析直接失败。
10. **同一对象内字段顺序无关，但 `vars`/`set.vars` 例外**——它们按声明顺序求值，后面的键可以引用前面的键。

---

## 1. 心智模型与执行语义

### 1.1 执行模型：游标 + 声明式跳转

引擎从 `flow[0]` 开始，维护一个**游标**指向当前步骤。每步执行完后，按 **`branch` → `goto` → 顺序** 的优先级决定下一步：

```
┌─────────────────────────────────────────────────────┐
│ 取 flow[cursor]                                     │
│  ├─ 计入访问次数（含 when=false 的跳过）              │
│  ├─ when 求值：false → 跳过本步， goto 规则照常生效     │
│  ├─ 执行本步（request / poll / ui / set）             │
│  ├─ 失败且无 onFail → 整个流程失败终止                 │
│  ├─ end 为 true/"error"/"cancelled" → 终止流程        │
│  └─ 下一步 = branch（首个 when 为真者） ?? goto ?? 顺序 │
└─────────────────────────────────────────────────────┘
```

关键语义：

- **`when: false` 只是跳过，不算失败**；跳过的步骤不出现在宿主统计的「真正执行过的步骤」里，但**计入死循环检测的访问次数**——所以「每轮都被跳过的环」也会触发 `E_LOOP`。
- **步骤失败默认终止整个流程**，除非该步定义了 `onFail`（[第 6.7 节](#67-onfail失败处理)）。
- **流程走到数组末尾自然结束**（等价于最后一步 `end: true`）。

### 1.2 防死循环：E_LOOP

任何单个步骤的**访问次数**（含被跳过、被 poll 重复执行）超过 `flow.length * 3` → 报 `E_LOOP` 并终止。例如 10 步的 flow，每步最多被访问 30 次。

这意味着：**poll 的最大轮数受 `maxAttempts`（≤60）和 `flow.length * 3` 双重约束**，任一突破即终止，不会无限打接口。设计长轮询时，确保 `flow` 长度 × 3 ≥ 你期望的最大尝试次数。

### 1.3 变量与命名空间：五个只读区 + 一个临时区

模板表达式能引用的顶层标识符只有六个命名空间（`response` 仅在 `onFail` 消息内可用）：

| 命名空间 | 内容 | 可写 |
|---|---|---|
| `input.<key>` | 用户表单值（含 `ui` 步骤运行中写入的值） | 仅 `ui` 步可写 |
| `vars.<key>` | 顶层 `vars` + `set` 步骤写入 | 仅 `set` 可写 |
| `steps.<stepId>.<name>` | 某步骤 `extract` 出的值 | 引擎写 |
| `env.<key>` | 运行环境（`deviceModel` / `deviceModels` / `appVersion` / `platform` / `locale`） | 引擎写 |
| `secrets.<key>` | 安全存储读取的密钥 | 不可写 |
| `response.*` | **仅 `onFail.message` 内**可用的本次失败上下文 | 引擎写 |

引用不存在的路径 → `E_UNDEF`（不返回 null）。`env.deviceModels` 是引擎内置的 32 款 Android 机型列表（`CONTRACT.md` 附录 A），常用写法是顶层 `"vars": {"deviceModel": "{{fn.randomOf(env.deviceModels)}}"}` 随机选一款伪造 UA。

### 1.4 值类型与渲染

表达式求值结果有 7 种类型：`string` / `int` / `double` / `bool` / `null` / `bytes` / `list` / `map`（list/map 主要出现在 `jsonParse`、`split` 的返回值和 JSONPath 提取结果中）。

模板渲染（表达式值 → 字符串）规则：

| 值类型 | 渲染结果 |
|---|---|
| `string` | 原样 |
| `int` | 十进制（`42`、`-7`） |
| `double` | Dart `toString()` 语义：**保留 `.0`**（`3.0` → `"3.0"`）；极大值科学计数法（`1e21` → `"1e+21"`） |
| `bool` | `"true"` / `"false"` |
| `null` | **空串**（不是 `"null"`） |
| `list` / `map` | 紧凑 JSON（无空格） |
| `bytes` | **报 `E_TYPE`**，必须先经 `fn.b64` / `fn.hex` / `fn.latin1` 转换 |

⚠️ **`null → 空串`是模板拼接时最常见的意外来源**：`"Bearer {{steps.login.token}}"` 在 token 为 null 时会渲染成 `"Bearer "`，然后被 assert 或服务端拒收。若值可能缺失，用 `{{fn.default(steps.login.token, '')}}` 或 `optional: true` + `default` 显式兜底。

### 1.5 错误哲学

本框架的错误设计原则是**快速失败、可定位**：

- 每个错误带 `code`（如 `E_EXTRACT`）、`message`（含出错的表达式/路径原文）、`stepId`（出错步骤）、`detail`（结构化补充）。
- **同一插件里，错误码 + stepId 几乎总能唯一定位到一行 manifest**。看到 `E_EXTRACT: extract "token": 响应头 "Set-Cookie" 不存在`，去 `flow` 里找 id 对应步骤的 `extract` 数组即可。
- 与之配套的是第 0.4 节铁律 2（E_UNDEF 不静默）和铁律 1（未知字段拒绝）。

---

## 2. 顶层字段

全部顶层字段一览（★ 必填；类型/约束均由 `schema/manifest.schema.json` 强制）：

| 字段 | 类型 | 必填 | 约束与默认 | 说明 |
|---|---|---|---|---|
| `id` | string | ★ | `^[a-z0-9]+(\.[a-z0-9]+)+$`，至少两段 | 全局唯一标识，如 `demo.hello` |
| `name` | string | ★ | 1–64 字符 | 展示名 |
| `version` | string | ★ | `^\d+\.\d+\.\d+$` | 语义化版本，如 `1.0.0` |
| `engine` | string | ★ | 版本范围字符串 | 如 `">=1.0 <2.0"`，引擎不满足则拒绝加载 |
| `author` | string | — | 0–128 字符 | 作者名 |
| `description` | string | — | 0–512 字符 | 描述 |
| `allowHosts` | string[] | ★ | 非空数组；每项 `host` 或 `host:port` | 网络白名单，见[第 11 节](#11-网络安全模型) |
| `allowInsecureLocalhost` | bool | — | 默认 `false` | 仅测试用，见[第 11.3 节](#113-allowinsecurelocalhost) |
| `inputs` | array | ★ | 可为空数组 | 表单字段定义，见[第 3 节](#3-inputs--用户输入表单) |
| `vars` | object | — | — | 静态/模板变量，见[第 2.1 节](#21-vars) |
| `secrets` | string[] | — | — | 声明需从安全存储读取的键，见[第 11.4 节](#114-secrets-与敏感值分级) |
| `flow` | array | ★ | 非空数组 | 步骤序列，见[第 5 节](#5-flow-与步骤通用机制) |
| `output` | object | ★ | — | 结果声明，见[第 10 节](#10-output--结果展示) |
| `hooks` | object | — | `libs` ⊆ `["forge@1.4.0"]`，`timeoutMs` 100–60000 默认 5000 | JS 依赖声明，见[第 12 节](#12-hooks-与-js-沙箱边界) |

### 2.1 `vars`

顶层静态变量池。值可以是纯字面量，也可以是模板（运行开始时求值一次）：

```jsonc
"vars": {
  "base": "https://api.example.com",
  "deviceModel": "{{fn.randomOf(env.deviceModels)}}",
  "ua": "{{vars.deviceModel}}/1.0.0",
  "ts": "{{fn.ts14()}}"
}
```

**求值顺序**：键按 JSON 声明顺序逐个求值，**后面的键可以引用前面的键**（如上例 `ua` 引用 `deviceModel`）。`set` 步骤在运行中往 `vars` 里覆盖/新增键。

⚠️ `vars` 的值经过模板渲染后必须是字符串/数字/布尔等可渲染值；想存 bytes 请存其 hex/b64 文本形式。

### 2.2 `secrets`

```jsonc
"secrets": ["apiKey"],
"vars": { "authHeader": "{{secrets.apiKey}}" }
```

声明本插件需要从宿主**安全存储**读取的键。宿主在加载时弹窗询问用户或从安全存储注入；模板里用 `{{secrets.<key>}}` 引用。与 `inputs` 的区别：`secrets` 用于**不应明文出现在 manifest 或表单回显里**的值（如作者自建的转发服务密钥），且**错误消息强制脱敏**——渲染 `secrets.*` 失败时只回显模板原文，不回显密钥明文。

### 2.3 `id` 的命名建议

`id` 至少两段小写点分（`^[a-z0-9]+(\.[a-z0-9]+)+$`）。建议格式：`<作者或站点标识>.<功能>`，如 `demo.hello`、`demo.pipeline`。避免与已装插件撞 id——同 id 的插件会被视为「同一插件的另一个版本」。

---

## 3. inputs —— 用户输入表单

`inputs` 是一个数组，每项声明一个表单字段。宿主在**流程开始前**按声明顺序渲染表单，收集到的值写入 `input.<key>` 命名空间，供模板引用。

### 3.1 字段结构

```jsonc
{
  "key": "phone",            // ★ 必需。^[a-zA-Z_][a-zA-Z0-9_]*$，同 manifest 内唯一
  "label": "手机号",           // ★ 必需。展示文案
  "type": "phone",           // ★ 必需。phone | text | password | number | select
  "required": true,          // 可选，默认 true。false 时用户可留空
  "default": "",             // 可选。仅 string/number 类型；预填值
  "placeholder": "请输入手机号", // 可选。输入框占位文案
  "maxLength": 11,           // 可选。正整数
  "minLength": 0,            // 可选
  "pattern": "^1\\d{10}$",   // 可选。ECMA 正则字符串（不加定界符）
  "options": [               // type=select 时必需，其余类型禁止出现
    { "value": "sms", "label": "短信验证码登录" }
  ],
  "sensitive": false         // 可选，默认 false。true = 不写日志、不落盘、不回显
}
```

### 3.2 五种控件类型

| type | 控件 | 特有约束 | 常见用途 |
|---|---|---|---|
| `phone` | 手机号输入框 | 未显式给 `pattern` 时隐含 `"^1\\d{10}$"` | 手机号 |
| `text` | 普通文本框 | — | 验证码、账号等短文本 |
| `password` | 密码框 | 输入不明文回显 | 密码、二级密码 |
| `number` | 数字输入框 | 值以字符串形式进入 `input.<key>` | 金额、次数 |
| `select` | 下拉单选 | 必须有非空 `options`；`value`/`label` 均为 string 且**不支持模板** | 多选一入口 |

`select` 的 `options[].value` 是写入 `input.<key>` 的实际值，`label` 是显示文案。宿主把用户选中的 `value` 写入 input，引擎校验「值必须是 `options[].value` 之一」。

⚠️ **`input.*` 的值一律是字符串**（含 `number` 类型）。需要参与数值比较/计算时用 `fn.toInt` / `fn.toFloat` 转换：`{{fn.toInt(input.retryCount)}}`。

### 3.3 校验行为

- `required: true` 且值为空 → 宿主拒绝提交表单，提示 `label` + 原因。
- `pattern` 不匹配 → 同上。
- `minLength`/`maxLength` 对 `text`/`password` 生效；对 `select` 用 `options` 约束。
- 表单校验发生在**流程开始之前**，所以 `flow` 里可以放心假设 `input.<required 项>` 非空（`required: false` 的项仍可能是空串，模板里注意兜底）。

### 3.4 `ui` 步骤与 inputs 的关系

流程执行中，`ui` 步骤（[第 7 节](#7-poll--ui--set-步骤)）也可以向 `input` 命名空间写入值（如运行到一半弹验证码输入框）。**`ui` 写入会覆盖同名 `inputs` 预收集的值**——这是特性不是 bug：可以在 `inputs` 里先问「验证码」（用户可能已经拿到），流程中若发现验证码缺失/失效再用 `ui` 步重问。

判定「表单里是否已填」的惯用法：

```jsonc
{ "id": "askCode", "type": "ui", "when": "input.smsCode == ''",
  "ui": { "type": "text", "label": "短信验证码", "input": "smsCode",
           "maxLength": 6, "pattern": "^\\d{6}$" } }
```

用户已在表单填过 → `when` 为假，直接跳过弹窗。

---

## 4. 模板与表达式

### 4.1 模板语法

字符串中 `{{ ... }}` 之间是一个**表达式**，求值后渲染为字符串（规则见第 1.4 节）：

```
"url":  "{{vars.base}}/auth/login"          // 字面量 + 表达式拼接
"ts":    "{{fn.ts14()}}"                    // 函数调用
"token": "{{steps.login.token}}"            // 变量引用
"hdr":   "Bearer {{steps.login.accessToken}}" // 前后缀拼接
```

转义与边界规则（由 `engine/lib/src/template.dart` 实现）：

| 写法 | 含义 |
|---|---|
| `\{\{` | 字面量 `{{`（不解析为模板开头） |
| `\}\}` | 字面量 `}}` |
| `{{` 后找不到 `}}` | 报 `E_TEMPLATE` |
| `{{}}`（空表达式） | 报 `E_TEMPLATE` |
| 表达式两侧紧贴其他字符 | 合法，如 `x{{vars.a}}y` |

⚠️ 若正文里出现孤立的 `}}` 而前面没有 `{{`，它就是普通字符，无需转义。

### 4.2 表达式语法（EBNF）

用于 `{{ }}` 内部、`when`、`until`、assert 取值路径之外的谓词值：

```
expr      := or
or        := and ( "||" and )*
and       := cmp ( "&&" cmp )*
cmp       := unary ( ("=="|"!="|">="|"<="|">"|"<") unary )?
unary     := "!" unary | primary
primary   := number | string | "true" | "false" | "null"
           | path | call | "(" expr ")"
path      := ident ("." ident | "[" number "]")*
call      := ident "." ident "(" (expr ("," expr)*)? ")"
number    := "-"? digits ("." digits)?
string    := "'" (any except "'") * "'"     // 单引号字符串，无转义，不能内嵌单引号
```

要点：

- **字符串字面量用单引号**：`"when": "input.mode == 'sms'"`。不支持双引号字符串，不支持任何转义——需要单引号本身时只能换写法（如 `fn.concat`）。
- **比较运算的 bytes 语义**：两侧同为数字 → 数值比较；两侧同为 bytes → 逐字节比较（大小按字典序）；bytes 与 string 混合 → `==` 恒 false、`!=` 恒 true，**不做隐式转换**；其余 → 转字符串字典序比较。bytes 参与比较**不需要**先转 hex/b64。
- `&&` / `||` 短路求值，返回 bool。
- 函数调用的命名空间只有 `fn`（v1 仅此一个）。
- 路径里数组下标用 `[n]`：`steps.login.items[0].token`（也支持 `items.0` 的点写法用于 JSONPath 之外的表达式路径——表达式 path 段 `[number]` 与 `.ident` 均可）。

### 4.3 布尔上下文

`when`、`until`、assert 谓词值（`isInteger: true` 等除外）要求顶层表达式**求值为 bool**。`"when": "vars.code"` 在 `code` 是字符串时会报错；要写 `"when": "vars.code != ''"`。没有「truthy/falsy」宽松转换——这是刻意的，避免各引擎对 truthy 定义不一。

### 4.4 确定性边界

除以下**时间函数**外，同一输入必须产生同一输出（`CONTRACT.md` §9）：

`fn.now` / `fn.ts10` / `fn.ts13` / `fn.ts14` / `fn.daysBeforeNow` / `fn.daysAfterNow`（后两者依赖「今天」）。随机函数（`randomHex` 等）由引擎注入种子，每次运行不同，但同一次运行内可复现。

---

## 5. flow 与步骤通用机制

`flow` 是非空数组，每项是一步。四种步骤类型共享一组公共字段：

```jsonc
{
  "id": "login",               // ★ 必需。^[a-zA-Z_][a-zA-Z0-9_]*$，flow 内唯一
  "type": "request",           // ★ 必需。request | poll | ui | set
  "when": "input.phone != ''", // 可选。bool 表达式，false 则跳过本步
  "goto": "next",              // 可选。step id 或 "next"（= 顺序执行）
  "branch": [                  // 可选。按序求值，首个 when 为真者的 goto 生效；优先于 goto
    { "when": "steps.init.code == '1016'", "goto": "captcha" }
  ],
  "onFail": { "message": "{{response.message}}" }, // 可选。失败处理，见 6.7
  "end": false                 // 可选。true | false | "error" | "cancelled"，默认 false
}
```

### 5.1 `end` 的四种取值

| 取值 | 终态 | output 渲染 | 典型用途 |
|---|---|---|---|
| `true` | `succeeded` | ✅ 渲染 | 「拿到 token 就此打住」 |
| `false`（默认） | —（不终止） | — | 继续往下走 |
| `"error"` | `failed` | ✅ **仍渲染** | 「失败了也要把诊断信息展示给用户」（错误码 `E_END`） |
| `"cancelled"` | `cancelled` | ❌ 不渲染 | 「用户主动放弃」类分支（如确认框里点取消后走到的步骤） |

⚠️ `end: "error"` 的终态是 `failed` 而**不是** `succeeded`——宿主会把它当失败展示，只是 output 里声明的字段仍会渲染出来。

⚠️ `end: "cancelled"` 在 `CONTRACT.md` §4.1 的正文里尚未补录，但 schema（`manifest.schema.json` end 定义）、Dart 引擎（`manifest.dart` StepEndKind / `engine.dart` 对应分支）三处均已实现，可放心使用。

### 5.2 `goto` / `branch` / `when` 的执行细节

- `goto` 指向不存在的 step id → **加载期**报 `E_GOTO`（不是运行期才发现）。
- `branch` 按数组顺序求 `when`，**第一个为真者**的 `goto` 生效；全假则回落到 `goto`，再回落到顺序。
- `when` 为 false 时**跳过本步但仍计算跳转**（`branch`/`goto` 生效）——注意这与「直接执行下一步」不同：`when: false` + `goto: "back"` 依然会跳到 `back`。
- `goto: "next"` 与省略 `goto` 等价，都是顺序执行。

**回退重试的标准写法**（利用 goto 构成受 E_LOOP 保护的有限循环）：

```jsonc
{ "id": "fetchCode", "type": "request", "when": "vars.tries < 3",
  "goto": "checkCode", "onFail": { "goto": "bump" } },
{ "id": "bump", "type": "set",
  "set": { "vars": { "tries": "{{fn.toInt(vars.tries) + 1}}" } },
  "goto": "fetchCode" },
{ "id": "checkCode", "type": "request", "……": "…" }
```

`bump` 把计数 +1 后跳回 `fetchCode`；`when` 在第 4 次访问时为假跳过，流程落到 `checkCode`。整个环受 `flow.length * 3` 上限保护。

### 5.3 步骤类型的字段互斥

每种步骤类型有一组**专属字段**，出现于其他类型即 `E_SCHEMA`：

| type | 专属字段 |
|---|---|
| `request` | `request` |
| `poll` | `poll` |
| `ui` | `ui` |
| `set` | `set` |

`extract` / `assert` 属于 **request 步骤**的配套字段（提取/断言本步响应），写在其他类型上报错。

---

## 6. request 步骤

`request` 是最核心的步骤类型：渲染模板 → 发出 HTTP 请求 →（可选）断言响应 →（可选）提取值。

### 6.1 完整结构

```jsonc
{
  "id": "login",
  "type": "request",
  "request": {
    "method": "POST",                  // ★ 必需。GET | POST | PUT | PATCH | DELETE
    "url": "{{vars.base}}/auth/login", // ★ 必需。模板；必须 https（除非 11.3）
    "headers": {                       // 可选。键为字面量，值为模板
      "Content-Type": "application/json;charset=UTF-8",
      "User-Agent": "{{vars.ua}}"
    },
    "query": {                         // 可选。值为模板，自动 urlencode 后拼到 url
      "ts": "{{fn.ts13()}}"
    },
    "body": {                          // 可选。GET 时禁止出现
      "type": "json",                  // ★ 必需（有 body 时）。json | form | text | hex
      "value": { "phone": "{{input.phone}}", "code": "{{input.smsCode}}" }
    },
    "timeoutMs": 20000,                // 可选，默认 20000。1000..120000
    "retry": {                         // 可选。重试策略，见 6.6
      "times": 2,                      // 0..5，默认 0
      "backoffMs": 1000,               // 可选，默认 1000
      "on": [500, 502, 503, 504]       // 可选，默认这 4 个；可加 "network"
    },
    "followRedirects": true            // 可选，默认 true
  },
  "extract": [ /* 见 6.4 */ ],
  "assert": { /* 见 6.5 */ },
  "onFail": { /* 见 6.7 */ }
}
```

### 6.2 body.type 四种序列化

| type | `value` 要求 | 序列化 | 默认 Content-Type（未指定时补） |
|---|---|---|---|
| `json` | object / array | 递归渲染模板后 `jsonEncode`（紧凑） | `application/json` |
| `form` | object | `k=v&k=v`，值 urlencode | `application/x-www-form-urlencoded` |
| `text` | string | 原样 | `text/plain; charset=UTF-8` |
| `hex` | string（hex 文本） | hex 解码为字节作为请求体 | `application/octet-stream` |

**json body 的递归渲染**：`value` 里的每个字符串值（含嵌套对象/数组深层）都按模板处理，非字符串值（数字、布尔、null）原样输出。这是构造「部分字段动态、部分字段静态」的 JSON 的标准做法：

```jsonc
"body": { "type": "json", "value": {
  "appVersion": "3.2.1",                  // 静态
  "deviceId": "{{vars.deviceId}}",        // 动态
  "ts": "{{fn.ts13()}}",                  // 动态
  "nested": { "token": "{{steps.init.tk}}" } // 深层动态
} }
```

⚠️ 模板渲染结果是字符串。若某字段需要**JSON 数字/布尔**（如 `"ts": 1700000000` 而非 `"ts": "1700000000"`），要么手写死值，要么接受字符串——服务端不兼容时改用 `body.type: "text"` 手拼 JSON，或用 `set.js` 生成（第 9 节）。

### 6.3 headers / query 细节

- `headers` 键大小写敏感传入；常见做法是显式声明全部头，不依赖默认 UA（默认 UA 会暴露宿主身份）。
- `query` 值自动 urlencode：`"query": {"redirect": "https://api.example.com/cb"}` → `?redirect=https%3A%2F%2Fapi.example.com%2Fcb`。不需要也不应该自己再 `fn.urlenc` 一次（会双重编码）。
- `query` 与 `url` 内嵌的 `?a=b` 可共存，宿主按「url 原样 + query 拼接」处理。

### 6.4 `extract` 数组：五种取值来源

`extract` 把响应中的值挂到 `steps.<本步id>.<name>`。每项结构：

```jsonc
{ "name": "token",        // ★ 提取结果名，同一步骤内唯一
  "from": "json",         // ★ json | raw | header | regex | binary
  "……": "from 专属字段",
  "optional": false,      // 可选，默认 false。true 时失败不报错
  "default": ""           // 可选。optional 失败时写入的兜底值
}
```

五种 `from` 的语义（实现见 `engine/lib/src/extractor.dart`）：

#### (a) `from: "json"` —— JSONPath 子集

```jsonc
{ "name": "token", "from": "json", "path": "$.result.token" }
{ "name": "first", "from": "json", "path": "$.result.items[0].id" }
```

- JSONPath 只支持 `$` 根、`.key` 成员、`[n]` 非负下标三种子集；**不支持**通配 `*`、递归 `..`、过滤器、负索引、切片。
- 响应体不是合法 JSON → `E_EXTRACT`；路径不存在 → `E_EXTRACT`（`optional: true` 除外）。

**双层 JSON（网关套壳）**：有的网关把真正的内容 JSON 转义成**字符串**塞在外层字段里。用 `asJson` 做二次解析：

```jsonc
{ "name": "inner", "from": "json", "path": "$.data.payload",
  "asJson": true, "innerPath": "$.result.token" }
```

先取 `$.data.payload` 的字符串，再 `jsonDecode` 一次，再按 `innerPath` 在**内层 JSON** 里取值。`asJson: true` 而 `innerPath` 省略时，返回整个内层解析结果（list/map）。⚠️ `asJson` 要求外层取到的必须是字符串，取到 object 会报 `E_EXTRACT`。

#### (b) `from: "header"` —— 响应头

```jsonc
{ "name": "cookie", "from": "header", "header": "Set-Cookie" }
```

头名**大小写不敏感**；同名多值取**最后一个**。

#### (c) `from: "regex"` —— 正则捕获

```jsonc
{ "name": "tid", "from": "regex", "pattern": "token=([a-f0-9]{32})", "group": 1 }
```

- 对响应体按 UTF-8 解码后**全文找第一个匹配**（非多行模式）。
- `group` 默认 `1`；`0` 表示整个匹配串；组号未参与匹配（值为 null）→ `E_EXTRACT`。
- pattern 是普通正则字符串（**不是模板**，不会渲染 `{{}}`）。

#### (d) `from: "binary"` —— 二进制协议扫描

```jsonc
{ "name": "vs",  "from": "binary", "tag": "162b", "length": 43, "encoding": "ascii" }
{ "name": "uid", "from": "binary", "tag": "162b", "offset": -4, "length": 4, "encoding": "be32" }
```

语义（冻结，不可变更）：

1. `tag`（hex 字符串）解码为字节，在**响应体原始字节**中找**第一个**出现位置 `i`；
2. 未找到 → `optional` 用 `default`，否则 `E_EXTRACT`；
3. `offset`（**默认 2**，可为负）加到 `i` 上得到读取起点；
4. 读 `length` 字节，按 `encoding` 解码；
5. 越界（起点为负、或起点+长度超出响应体）→ `E_EXTRACT`。

| encoding | 输出 | 约束 |
|---|---|---|
| `ascii` | string（每字节 → 码位） | — |
| `utf8` | string | 非法 UTF-8 序列 → `E_EXTRACT` |
| `hex` | 小写 hex string | — |
| `be32` | 大端无符号 32 位整数 → 十进制 string | `length` 必须为 4 |
| `raw` | bytes | 值是 bytes，进模板前记得转 hex/b64 |

⚠️ `offset` 默认 2 是历史冻结值（对应「tag 长度 2」的常见协议）；tag 更长时要显式写 `offset`（或用 `fn.scanAscii` 的「跳过整个 tag」语义在 set.js 里处理）。

#### (e) `from: "raw"` —— 整个响应体

```jsonc
{ "name": "body", "from": "raw" }
```

结果是 **bytes**。模板里不能直接渲染，必须 `{{fn.b64(steps.fetch.body)}}` / `{{fn.hex(...)}}` / `{{fn.latin1(...)}}`。配合 `fn.indexOf` / `fn.slice` / `fn.scanAscii` 可在表达式里做结构化解析。

### 6.5 `assert`：断言响应

`assert` 是一个对象（不是数组），在 extract **之后**求值。先按 `json` 路径取值，再对取到的值应用**恰好一个**操作符（写 0 个或 ≥2 个 → `E_SCHEMA`）：

```jsonc
"assert": { "json": "$.code", "equals": "0", "message": "登录失败" }
```

13 个操作符：

| 操作符 | 期望值类型 | 语义 |
|---|---|---|
| `equals` | 模板 | 转字符串后精确相等 |
| `notEquals` | 模板 | 转字符串后不等 |
| `contains` | 模板 | 转字符串后包含子串 |
| `matches` | **纯字符串**（非模板） | 转字符串后匹配正则 |
| `isInteger` | bool | 整数形态（`"123"` true，`"1.5"` false；支持 `0x` 前缀） |
| `isNumeric` | bool | 数字形态（含小数） |
| `isEmpty` | bool | 空串 / 空列表 / 空对象 |
| `isNotEmpty` | bool | 非空 |
| `exists` | bool | 提取值非 null |
| `greaterThan` | **数字或模板** | 数值大于 |
| `lessThan` | **数字或模板** | 数值小于 |
| `startsWith` | 模板 | 前缀 |
| `endsWith` | 模板 | 后缀 |

- `json` 是 JSONPath 子集路径（同 6.4(a)），**只能**对 JSON 响应断言；要断言头或原文，先 extract 再用 `when` + 下一步校验。
- `message` 可选，是**模板**：失败时渲染并展示给用户，如 `"{{steps.fetch.msg}}"`。
- 比较前两侧都转字符串（object/array 用 JSON 编码）。
- 断言失败 → `E_ASSERT`，错误消息 = `message`（有则用之）或默认消息。

⚠️ `greaterThan` / `lessThan` 既接受数字字面量也接受模板字符串（`"{{vars.limit}}"`），两边引擎与 schema 均已对齐；若你的环境较老（v1.5 前），优先写数字字面量。

### 6.6 `retry`：重试策略

```jsonc
"retry": {
  "times": 2,                    // 额外重试次数（不含首次）。0..5，默认 0
  "backoffMs": 1000,             // 每次重试前固定等待毫秒。默认 1000
  "on": [500, 502, 503, 504]     // 触发重试的 HTTP 状态码；可含 "network"
}
```

- `on` 默认 `[500, 502, 503, 504]`；`"network"` 表示**网络层异常**（连接失败、超时）也触发重试。
- 命中重试条件 → 等 `backoffMs` 再重发；最多重试 `times` 次。
- 全部重试用尽仍非 2xx（或仍网络失败）→ `E_HTTP`（非 2xx）/ `E_TIMEOUT`（超时）。
- 未命中 `on` 的非 2xx（如 401、403）**不重试**，立即失败——凭据错误重试没有意义。
- 重试是**整个请求**级别的（含 body 重新渲染前已定型的模板不重算——模板只在步骤开始渲染一次，`fn.ts13()` 在重试时不会变化）。

### 6.7 `onFail`：失败处理

步骤失败（网络错误/`E_HTTP`/`E_ASSERT`/`E_EXTRACT` 等）且**未定义** `onFail` → 整个流程立即失败终止。定义了则二选一：

```jsonc
"onFail": { "message": "登录失败：{{response.message}}" }  // 终止并展示消息
"onFail": { "goto": "fallback" }                           // 跳到指定步骤继续（恢复流程）
```

- `message` 与 `goto` **互斥**，同时出现报 `E_SCHEMA`。
- `message` 是模板。**`response` 命名空间只在 `onFail` 内可用**：

| 引用 | 含义 |
|---|---|
| `{{response.message}}` | 响应体 JSON 的 `message`，依次回退 `msg` → `error` → HTTP 状态文本（如 `Internal Server Error`） |
| `{{response.status}}` | HTTP 状态码（无响应时不可用） |
| `{{response.body}}` | 响应体文本（无响应时不可用） |
| `{{response.headers}}` | 响应头（map；无响应时不可用） |
| `{{response.raw}}` | 原始错误信息（网络异常时为异常文本） |

- `onFail: { "goto": ... }` 是「失败恢复」的唯一机制：典型用法是风控拦截后跳去验证码分支。注意 goto 目标步骤同样受 E_LOOP 上限保护。
- assert 失败也走 `onFail`——所以「断言不过就转人工验证」可以这样写：`"onFail": { "goto": "askCaptcha" }`。

### 6.8 执行顺序小结

一个 request 步骤内部的处理顺序：

```
渲染模板（url/headers/query/body）
  → 发请求（超时 timeoutMs；按 retry 重试）
  → 状态非 2xx 且重试用尽 → E_HTTP（可被 onFail 接住）
  → extract 按数组顺序逐个提取（失败即中止，除非 optional）
  → assert 求值（失败 → E_ASSERT，可被 onFail 接住）
  → 按 branch → goto → 顺序 决定下一步
```

---

## 7. poll / ui / set 步骤

### 7.1 `type: "poll"` —— 轮询等待

用于「发起操作后反复查询直到就绪」的场景（等短信状态、等异步任务完成）。

```jsonc
{
  "id": "waitSms",
  "type": "poll",
  "poll": {
    "steps": ["smsStatus"],                        // ★ 必需。要重复执行的 step id（1..5 个）
    "until": "steps.smsStatus.status == '1'",      // ★ 必需。bool 表达式
    "intervalMs": 1000,                            // 可选，默认 1000。100..60000
    "maxAttempts": 5,                              // ★ 必需。1..60
    "onTimeout": { "message": "短信状态尚未就绪" }   // ★ 必需。message 或 goto
  }
}
```

执行语义（`engine/lib/src/engine.dart` `_executePoll`）：

1. 每轮**先按序执行 `steps` 列出的步骤**（通常是 request），再求 `until`；
2. `until` 为真 → poll 步骤成功，继续流程；
3. 为假 → 等 `intervalMs`（最后一轮不等）进入下一轮；
4. 达到 `maxAttempts` 仍未满足 → 按 `onTimeout` 处理：
   - `{"message": "…"}`：流程失败终止，展示消息（错误码 `E_TIMEOUT`）；
   - `{"goto": "fallback"}`：跳转到指定步骤（如降级路径）。

细节与陷阱：

- **被 poll 的步骤计入 E_LOOP 访问次数**：`maxAttempts × steps 数` 会累积到每个被引用步骤的访问计数上，上限仍是 `flow.length * 3`。
- 被 poll 的步骤**自身失败**时：若它有 `onFail` 则按其 `onFail` 处理（goto 交回主循环 / message 直接失败）；**无 `onFail` 则视为本轮未就绪**，等待后重试——「查询接口偶发 500」不会打断轮询。
- `until` 里引用的 `steps.<id>.<name>` 是**最新一轮**的提取值（每轮覆盖写）。
- `intervalMs` 上限 60000（1 分钟）、`maxAttempts` 上限 60，纯 JSON 轮询最长约 1 小时——设计长等待时确认服务端语义允许。

### 7.2 `type: "ui"` —— 用户交互

`ui` 步骤**阻塞等待用户**，超时由宿主决定（引擎不设超时）。用户取消 → 流程以「用户取消」终止（**非错误**，不触发 `onFail`）。

五种 `ui.type` 共享的结构：

```jsonc
{
  "id": "askSms", "type": "ui",
  "ui": {
    "type": "text",            // ★ text | image | confirm | webview | select
    "label": "短信验证码",       // ★ 展示标题（支持模板）
    "input": "smsCode",        // ★ 写入 input 命名空间的键（覆盖同名 input）
    "hint": "6 位数字",          // 可选。辅助文案（支持模板）
    "message": "…",            // 可选。confirm 的正文（支持模板）
    "obscure": false,          // 可选（v1.8）。界面是否掩码：省略走宿主自动判定
                               // （密码类掩码、验证码与手机号/邮箱明文）；
                               // true 强制掩码、false 强制明文。
                               // ★ 只影响界面显示，不影响日志脱敏
    "……": "type 专属字段"
  }
}
```

#### 7.2.1 各类型专属字段与约束

| type | 专属/适用字段 | 写入 input 的值 |
|---|---|---|
| `text` | `maxLength`、`pattern`（均可选，正则字符串） | 用户输入的文本（经 pattern/maxLength 校验） |
| `image` | `image`（★ base64 字符串，**支持模板**）、`refreshStep`（可选：点击「刷新」时重新执行的 step id，如重新请求验证码） | 用户输入的文本 |
| `confirm` | `message`（★ 正文，支持模板） | 固定 `"ok"`（用户点确认）；点取消 = 取消整个流程 |
| `webview` | `url` 或 `html`（★ 二选一）、`baseUrl`（html 时必需）、`bridge`（默认 `"FlutterBridge"`） | 网页 JS 经 bridge 回传的字符串 |
| `select` | `options`（★ 非空数组，`{value, label}` 静态字面量） | 所选项的 `options[].value` |

**支持模板的 ui 字段**：`label`、`hint`、`message`、`image`、`url`、`html`、`baseUrl`。
**不支持模板**（静态字面量）：`type`、`input`、`pattern`、`maxLength`、`obscure`、`refreshStep`、`bridge`、`options[].value`、`options[].label`。

**`obscure` 的语义**（v1.8 新增，五种 `ui.type` 通用）：

| 写法 | 界面显示 | 日志 |
|---|---|---|
| 省略（不写） | 宿主按 `input` 键名自动判定：密码类（password/pwd/passwd）掩码；验证码与手机号/邮箱键名明文 | 照常脱敏 |
| `"obscure": true` | **强制掩码**（即使键名是 mobile/smsCode） | 照常脱敏 |
| `"obscure": false` | **强制明文**（即使键名是 password —— 插件作者自己的选择） | **照常脱敏** |

典型用法：接口要求输入「服务密码」但键名不带 password 字样、宿主自动判定成了明文 → 写 `"obscure": true` 强制掩码；反之，想让某个敏感键在界面明文可见（用户需要核对）→ 写 `"obscure": false`。⚠️ 无论怎么写，**日志脱敏始终按 `sensitive` 语义走**，`obscure: false` 不会把值带进日志。

字段互斥（违反 → `E_SCHEMA`）：

- `options` 只允许出现在 `type: "select"`；
- `image`/`refreshStep` 只对 `image` 类型有意义（`refreshStep` 仅 image）；
- `maxLength`/`pattern` 不适用 `select` 与 `webview`（值非自由输入）；
- `url` 与 `html` **恰好一个**（都给或都不给 → `E_SCHEMA`）；`html` 出现时 `baseUrl` 必需。

#### 7.2.2 `type: "select"` —— 流程内多选一

```jsonc
{
  "id": "route", "type": "ui",
  "ui": {
    "type": "select", "label": "请选择操作", "input": "mode",
    "options": [
      { "value": "1", "label": "密码登录" },
      { "value": "2", "label": "注册新账号" },
      { "value": "3", "label": "找回密码" }
    ]
  }
}
```

宿主把用户选中的 `value` 交回引擎，引擎校验「值必须是 `options[].value` 之一」后写入 `input.mode`——非法回传值（宿主 bug）会报 `E_ARG`。与顶层 `inputs` 的 select 区别：这里在**流程执行中**出现，可被 `when` 守卫、可覆盖同名 input。典型用法见第 3.4 节（`when: "input.mode == ''"` 表单没选时才问）。

### 7.3 `type: "webview"` —— 网页交互（滑块/风控）

承载需要执行网页脚本的交互（滑块验证码、第三方风控）。两种模式：

```jsonc
// 模式 A：直接打开 URL（host 必须在 allowHosts）
"ui": { "type": "webview", "label": "安全验证", "input": "captchaToken",
        "url": "{{vars.sliderUrl}}", "hint": "请完成滑动验证" }

// 模式 B：内嵌 HTML（baseUrl 必需，决定相对路径解析与同源策略）
"ui": { "type": "webview", "label": "安全验证", "input": "captchaToken",
        "html": "<!DOCTYPE html><html>…</html>",
        "baseUrl": "https://captcha.example.com/" }
```

**JS ↔ 宿主回传协议（冻结）**：宿主注入名为 `bridge`（默认 `FlutterBridge`，可用 `bridge` 字段改名，须匹配 `^[A-Za-z_][A-Za-z0-9_]*$`）的通道：

```js
// 成功：值写入 input.<input 键>
window.FlutterBridge.postMessage(JSON.stringify({ action: 'success', value: '<字符串>' }))
// 取消：等价于用户取消（流程以「用户取消」终止，非错误）
window.FlutterBridge.postMessage(JSON.stringify({ action: 'close' }))
```

宿主侧规则：

- `action: "success"` 且 `value` 是字符串 → 写入 input，步骤成功；
- `value` 非字符串（数字/对象/null）→ `E_ARG`；
- 非法 JSON / 未知 action / 缺 value → **静默忽略**（网页可能发送其他内部消息）。

**安全边界**：

- 引擎只校验 `url` 与 `baseUrl` 的 host 在 `allowHosts` 内（含模板渲染后的运行期校验）；
- **HTML 内引用的外部子资源（script/css/图片/XHR）的 host 不在引擎强制拦截范围**——这是**插件作者的责任**：`allowHosts` 必须声明 HTML 会访问的**所有** host（CDN、风控服务域名等）；
- 宿主不得关闭 TLS 校验；bridge 只接受上述两种 action。

### 7.4 `type: "set"` —— 变量计算

```jsonc
{ "id": "calc", "type": "set",
  "set": {
    "vars": {                        // 与 js 二选一，也可同时出现（vars 先执行）
      "androidId": "{{fn.randomHex(16)}}",
      "ts": "{{fn.ts14()}}"
    }
  } }
```

- `set.vars` 的键**按声明顺序求值**，后面的键可引用刚算出的键（管道式写法）：

```jsonc
"set": { "vars": {
  "a": "{{vars.seed}}",
  "b": "{{vars.a}}-1",            // 引用刚算出的 a
  "c": "{{fn.concat(vars.b, '-2') }}"
} }
```

若 `seed = "abc"`，结果依次为 `a=abc`、`b=abc-1`、`c=abc-1-2`。这是**拆长表达式的官方手法**：把 5 层嵌套的巨型模板拆成多行管道。

- ⚠️ **bytes 不能存进 vars**（模板渲染结果必须是字符串）：

```jsonc
// ❌ E_TYPE：unhex 的结果是 bytes，渲染进 vars 时报错
"set": { "vars": { "b1": "{{fn.unhex(vars.inner)}}", "final": "{{fn.hex(vars.b1)}}" } }

// ✅ bytes 链在单个表达式内闭合，或经 hex/b64 文本中转
"set": { "vars": { "final": "{{fn.hex(fn.unhex(vars.inner))}}" } }
```

- `set.js` 子对象（JS 逃生舱）见[第 9 节](#9-setjs--js-逃生舱)；`vars` 与 `js` 同时出现时**先执行 vars 再执行 js**，js 的输出可覆盖同名 vars。

---

## 8. fn.* 函数库（73 个）

模板表达式里唯一的函数命名空间是 `fn`。v2.0 起全部函数由**内置 JS 沙箱**执行（`engine/lib/src/js/builtin.js`，生产宿主为 QuickJS），语义与历史 Dart 实现逐字一致。调用语法：`{{fn.函数名(参数, …)}}`，参数本身可以是表达式。

**通用规则**：

- 参数类型不符 → `E_TYPE`（不隐式转换）；参数值非法（空 list、越界下标、空串分隔符等）→ `E_ARG`。
- `string` 参数指 UTF-8 文本；`bytes` 指字节串（来自 `fn.unb64`/`fn.unhex`/`fn.utf8`/`fn.gunz`/`extract from:raw/binary encoding:raw` 等）。
- 哈希输出一律**小写 hex**；base64 默认标准字母表。

### 8.1 编码 / 转换（13 个）

| 函数 | 输入 → 输出 | 说明 |
|---|---|---|
| `fn.b64(x)` | string/bytes → string | UTF-8 编码后标准 base64 |
| `fn.b64d(s)` | string → **string** | base64 解码 + **UTF-8 解码**（`b64` 的逆） |
| `fn.unb64(s)` | string → **bytes** | 仅 base64 解码，不做 UTF-8 解码 |
| `fn.b64url(x)` | string/bytes → string | URL-safe base64：`+`→`-`、`/`→`_`、**去 `=` padding** |
| `fn.unb64url(s)` | string → **bytes** | 自动补 padding 后解码 |
| `fn.hex(x)` | string/bytes → string | UTF-8 字节的小写 hex |
| `fn.unhex(s)` | string → **bytes** | hex（偶数长度）→ 字节 |
| `fn.utf8(s)` | string → **bytes** | 文本 → UTF-8 字节 |
| `fn.latin1(b)` | bytes → string | 每字节 → 一个码位（ISO-8859-1 语义） |
| `fn.urlenc(s)` | string → string | RFC 3986 百分号编码（空格→`%20`，非 `+`） |
| `fn.gz(b)` | bytes → bytes | gzip 压缩，mtime=0 |
| `fn.gunz(b)` | bytes → bytes | 解**任意**标准 gzip 流 |
| `fn.jsonParse(s)` | string → list/map/… | JSON 解析；失败 `E_ARG` |

⚠️ **`b64d` 与 `unb64` 极易混淆**：`b64d` 返回**字符串**（要求解码结果是合法 UTF-8），`unb64` 返回 **bytes**。要解 base64 图片/二进制用 `unb64`；要解 base64 文本用 `b64d`。

⚠️ **`fn.gz` 的跨引擎差异**：压缩后字节在不同引擎实现上**不保证相同**（deflate 实现与 gzip OS 字节不同，契约 §9.1 明示）。**不要**把 `fn.gz` 输出当签名/校验值；可以压缩后发送（对方 `gunz` 解压与实现无关）。`fn.gunz(fn.gz(x)) == x` 恒成立。

### 8.2 哈希（5 个）

| 函数 | 输入 → 输出 |
|---|---|
| `fn.md5(s)` | string → 32 位小写 hex |
| `fn.sha1(s)` | string → 40 位小写 hex |
| `fn.sha256(s)` | string → 64 位小写 hex |
| `fn.hmacSha256(k, s)` | key string + msg string → 64 位小写 hex |
| `fn.crc32(x)` | string/bytes → 8 位小写 hex（左补零；CRC-32/ISO-HDLC，同 zlib） |

哈希入参是**字符串**（按 UTF-8 取字节）；要哈希 bytes 先经表达式组合（bytes 直接传入亦可，如 `fn.crc32(fn.unhex(vars.h))`）。

### 8.3 加密（3 个）

**`fn.rsaPkcs1(pubB64, plaintext, bt?)`** —— RSA 公钥加密（PKCS#1 v1.5 padding）：

| 参数 | 要求 |
|---|---|
| `pubB64` | X.509 SubjectPublicKeyInfo DER 的 base64（即标准 `-----BEGIN PUBLIC KEY-----` 块内容，**不含** PKCS#1 `BEGIN RSA PUBLIC KEY` 格式） |
| `plaintext` | string，按 UTF-8 取字节；最大长度 = 模长 k − 11 字节 |
| `bt` | 可选，块类型 `'01'` 或 `'02'`，默认 `'02'`；部分老站只认 `'01'`，先试默认 |

输出：**标准 base64 字符串**，长度固定为模长（1024 位密钥 → 172 字符）。不是 OAEP；需要 OAEP 的站点用 `set.js`（第 9 节）。

**`fn.aesCbc(keyHex, ivHex, dataB64)`** —— AES-CBC 加密：key/iv 是 hex 字符串（16/24/32 字节 key），数据是 base64；输出 base64。**`fn.aesEcb(keyHex, dataB64)`** 同理无 IV。解密方向未内置（v1 只做加密）。

⚠️ 加密函数依赖 forge 库：在**表达式**里可用（引擎为内置 JS 沙箱预载）；在 `set.js` 里使用时必须声明 `hooks.libs: ["forge@1.4.0"]`（第 12 节）。

### 8.4 字符串操作（11 个）

| 函数 | 说明 |
|---|---|
| `fn.shift2(s)` | 每个码位 +2（UTF-16 码位运算） |
| `fn.shiftN(s, n)` | 每个码位 +n |
| `fn.padRight(s, n, c)` / `fn.padLeft(s, n, c)` | 用 `c` 补齐到长度 n |
| `fn.repeat(c, n)` | 取 `c` 的**首个码位**重复 n 次（`c` 空串 / `n` 负 → `E_ARG`） |
| `fn.substring(s, a, b?)` | Dart `substring` 语义：越界截断、**无负索引**、`b` 省略到末尾 |
| `fn.concat(a, b, …)` | 首参 string → 字符串拼接（null→空串，bool/number 按渲染规则）；首参 bytes → 字节拼接（string 参数按 UTF-8 编码） |
| `fn.len(x)` | string/bytes/list 长度、map 键数 |
| `fn.trim(s)` / `fn.upper(s)` / `fn.lower(s)` | 常规语义 |

### 8.5 bytes 操作（10 个）

| 函数 | 说明 |
|---|---|
| `fn.bytesReplace(b, from, to)` | bytes 中全部 `from` 替换为 `to`（bytes） |
| `fn.be32Write(b, offset, value)` | 大端写 4 字节，返回**新 bytes**；越界/值域外 → `E_ARG` |
| `fn.be32Read(b, offset)` | 大端读 4 字节 → int |
| `fn.be16Write` / `fn.be16Read` | 同上 2 字节版 |
| `fn.u8Write(b, offset, value)` | 写单字节（0..255），返回新 bytes |
| `fn.slice(x, a, b?)` | **支持负索引**（`-1` = 最后一个）；string 按 UTF-16 code unit 计；两端 clamp；`b <= a` → 空 |
| `fn.indexOf(h, n, start?)` | string 或 bytes 均可；找到返回下标，找不到返回 `-1` |
| `fn.at(b, i)` | 读单字节 → int；越界 `E_ARG` |
| `fn.scanAscii(b, tagHex, length)` | 找 tag 后**跳过整个 tag**，读 length 字节按码位转 string；未找到 `E_EXTRACT`、越界 `E_EXTRACT` |

⚠️ `fn.slice` 与 `fn.substring` 的区别：`slice` 支持负索引（从末尾倒数）、语义对齐 Python；`substring` 是 Dart 语义（越界截断、无负索引）。去尾字节用 `fn.slice(x, 0, -1)`。

⚠️ `fn.scanAscii` 跳过**整个 tag**（不管 tag 多长），与 `extract from:binary` 的「offset 默认 2」不同——两者别混用规则。

### 8.6 随机 / 时间（10 个）

| 函数 | 输出 | 说明 |
|---|---|---|
| `fn.randomHex(n)` | string | n 位随机 hex 字符 |
| `fn.randomDigits(n)` | string | n 位随机数字 |
| `fn.randomOf(list)` | 任意 | 从 list 随机取一项；空 list → `E_ARG` |
| `fn.randomInt(min, max)` | int | 闭区间随机整数 |
| `fn.randomModOffset(mod, off)` | string | `off + random(0..mod-1)` 的十进制字符串（BigInt 运算，支持超大数） |
| `fn.uuid()` | string | UUID v4 |
| `fn.now()` | int | 当前毫秒时间戳（**number**，模板渲染为字符串） |
| `fn.ts10()` | string | 秒级 10 位时间戳 |
| `fn.ts13()` | string | 毫秒级 13 位时间戳 |
| `fn.ts14()` | string | **UTC** `yyyyMMddHHmmss` 14 位 |

⚠️ `fn.ts14()` 是 **UTC**——若站点要求本地时间（北京时间 +8），用 `{{fn.dateFormat(fn.now(), 'YYYYMMDDHHmmss')}}` 也不行（dateFormat 同样 UTC 输出），需要本地时间时在 `set.js` 里用 `Date` 处理，或直接与服务端约定 UTC。

`fn.randomOf(env.deviceModels)` 是伪造 Android 机型 UA 的惯用法（第 2.1 节）。

### 8.7 空值处理（2 个）

| 函数 | 说明 |
|---|---|
| `fn.coalesce(a, b, …)` | 返回首个**非 null 且非空串**的参数；全空返回 null |
| `fn.default(x, y)` | `x` 为 null 或空串时返回 `y`，否则返回 `x` |

用于兜底可能缺失的提取值：`{{fn.default(steps.fetch.token, vars.fallbackToken)}}`。

### 8.8 字符串处理 · v1.4 新增（5 个）

| 函数 | 说明 |
|---|---|
| `fn.replace(s, old, rep)` | 全部替换；`old` 空串 → `E_ARG` |
| `fn.replaceRegex(s, pat, rep)` | 全局正则替换；`rep` 里 `$1`/`$2` 引用捕获组；非法正则 → `E_ARG` |
| `fn.split(s, sep)` | 按分隔符拆成 list；`sep` 空串 → 按单字符拆 |
| `fn.startsWith(s, p)` / `fn.endsWith(s, p)` | 前缀/后缀判断，返回 bool |

`split` 返回 list，常配合 `fn.first` / `fn.nth` 取片段：`{{fn.first(fn.split(vars.raw, ','))}}`。

### 8.9 类型转换（3 个）

| 函数 | 说明 |
|---|---|
| `fn.toInt(x)` | number → 截断取整；string → 十进制解析（支持负号与 `0x` 前缀）；失败 `E_ARG` |
| `fn.toFloat(x)` | number 原样；string 按浮点解析；失败 `E_ARG` |
| `fn.toString(x)` | null→`''`、bytes→严格 UTF-8 解码（非法字节**回退 hex**）、list/map→紧凑 JSON、其余按渲染规则 |

### 8.10 编码 / HTML（3 个）

| 函数 | 说明 |
|---|---|
| `fn.charsetDecode(b, name)` | bytes 按字符集解码：`utf-8`/`utf8`、`latin-1`/`latin1`/`ascii`、`gb2312`/`gbk`/`gb18030`（GBK 表）；`big5` 暂不支持（`E_ARG`）；未知字符集 `E_ARG` |
| `fn.htmlUnescape(s)` | `&amp;` `&lt;` `&#x…;` 等实体还原 |
| `fn.htmlEscape(s)` | `<` `>` `&` `"` `'` 转实体 |

中文 GBK 站点的响应体解码：`{{fn.charsetDecode(steps.fetch.body, 'gbk')}}`（`from: "raw"` 取 bytes 后转码）。

### 8.11 集合操作（4 个）

| 函数 | 说明 |
|---|---|
| `fn.count(x)` | 同 `fn.len`（string/bytes/list/map） |
| `fn.first(x)` | string 首字符 / list 首项；空 → `E_ARG` |
| `fn.last(x)` | string 末字符 / list 末项；空 → `E_ARG` |
| `fn.nth(x, i)` | 按下标取；**支持负索引**（`-1` = 末项）；越界 `E_ARG` |

### 8.12 日期处理（4 个）

| 函数 | 输出 | 说明 |
|---|---|---|
| `fn.toDate(x, fmt?)` | string | 解析后输出 **ISO UTC** 字符串（`2024-01-02T03:04:05Z`） |
| `fn.dateFormat(x, fmt)` | string | 按 fmt 格式化（UTC） |
| `fn.daysBeforeNow(x)` | int | 「x 那天」比今天早几天（UTC 日界） |
| `fn.daysAfterNow(x)` | int | 「x 那天」比今天晚几天 |

**输入 `x` 的可接受形态**（自动识别）：

- 10 位数字串 → Unix 秒；13 位 → Unix 毫秒；14 位 → `yyyyMMddHHmmss`；8 位 → `yyyyMMdd`；
- ISO 风格字符串自动归一化：`2024/01/02` 的 `/`→`-`、日期时间之间的空格 → `T`；
- `fn.toDate` 的第二参 `fmt` 可指定自定义解析格式。

**格式化 token**（`fmt`）：`YYYY` `MM` `DD` `HH` `mm` `ss`（`dateFormat` 另支持 `SSS` 毫秒）。

```jsonc
"set": { "vars": {
  "loginTime": "{{fn.toDate(fn.ts13())}}",                     // → 2024-01-02T03:04:05Z
  "expireAt":  "{{fn.dateFormat(vars.loginTs, 'YYYY-MM-DD HH:mm:ss')}}",
  "daysHeld":  "{{fn.daysBeforeNow(input.registerDate)}}"
} }
```

⚠️ 全部按 **UTC** 计算与格式化（与 `fn.ts14` 一致）。`daysBeforeNow`/`daysAfterNow` 依赖「今天」，属契约 §9 豁免的非确定性函数。

---

## 9. set.js —— JS 逃生舱

当声明式表达式不够用（复杂解密、需要循环/分支的变换、第三方加密库）时，`set` 步骤里可以写一段受沙箱约束的 JS：

```jsonc
{
  "id": "buildToken",
  "type": "set",
  "set": {
    "vars": { "prefix": "v2" },                  // 可选：先执行的声明式 vars
    "js": {
      "code": "return prefix + '-' + fn.ts13();", // ★ JS 代码，1..20000 字符
      "output": "tokenV2",                       // ★ 结果写入 vars.<output>；^[A-Za-z_][A-Za-z0-9_]*$，≤64 字符
      "inputs": { "prefix": "{{vars.prefix}}" }  // 可选：输入映射（≤32 个键）
    }
  }
}
```

### 9.1 执行语义

1. `set.vars` 先按声明顺序执行（若同时存在）；
2. `js.inputs` 的每个值按模板渲染，作为 **Dart 值**传入沙箱，并绑定为**同名 JS 变量**（`inputs.prefix` → JS 里直接写 `prefix`）；
3. `code` 在函数体内执行，**必须 `return` 一个值**——返回 `undefined` 报 `E_JS`；
4. 返回值写回 `vars.<output>`（与 vars 同名时覆盖）。

**类型映射**（Dart ↔ JS，契约 §4）：bytes 在 JS 内是 `Uint8Array`，跨边界自动以 `{"__bytes__":"<hex>"}` 包装转换——所以 JS 里拿到的 `Uint8Array` 直接用，返回 `Uint8Array` 也直接 return，无需手工 wire。

### 9.2 沙箱能力与限制

| 能力 | 可用性 |
|---|---|
| `fn.*` 全部 73 个函数 | ✅（与表达式共享同一实现，`fn.hex(...)` 直接调） |
| `forge` 加密库 | ✅ **须声明 `hooks.libs: ["forge@1.4.0"]`**（第 12 节），否则 `forge` 未定义 |
| 纯 JS（var/函数/循环/正则/JSON） | ✅ |
| `eval` / `Function` / `setTimeout` / `setInterval` / `fetch` / `XMLHttpRequest` / `require` | ❌ 调用即 `E_JS`（生产宿主 QuickJS 已替换为禁用桩） |
| `Math.random` / `Date.now` | ✅（引擎注入种子/时钟，见第 4.4 节） |
| 网络访问、文件系统、宿主对象 | ❌ 完全不可见 |

- 超时：单次执行默认 5000ms（`hooks.timeoutMs` 可调，100..60000），超时报 `E_JS`。
- `inputs` 键必须是合法 JS 标识符，且**不得**是保留名（`fn`、`__sj_` 前缀、`__wireToBytes`、`__bytesToWire`）——写 `fn` 会被 `E_SCHEMA` 拒绝。
- `code` 内不要定义与 `fn` 同名的变量/函数，会遮蔽内置函数库。

### 9.3 何时用 set.js，何时用表达式

| 场景 | 首选 |
|---|---|
| 编码/哈希/拼接/截取等单表达式变换 | 声明式 `set.vars`（可读性好、可管道拆分） |
| RSA/AES 加密 | 表达式 `fn.rsaPkcs1` / `fn.aesCbc`；非标准 padding 才上 set.js + forge |
| 需要循环/条件分支的复杂变换 | `set.js` |
| 需要第三方 JS 库（仅 forge） | `set.js` + `hooks.libs` |
| 大段二进制协议手工拼装 | `set.js`（`Uint8Array` 直读直写比表达式链清晰） |

可运行示例见仓库 `plugins/demo.setjs.utf16le/manifest.json`（用 set.js 把文本编码为 UTF-16LE hex）。

---

## 10. output —— 结果展示

### 10.1 结构

```jsonc
"output": {
  "title": "登录凭证",                        // ★ 必需。结果页标题
  "fields": [                                // ★ 必需。1..32 项
    {
      "label": "Token",                      // ★ 展示名
      "value": "{{vars.token}}",             // ★ 模板
      "copyable": true,                      // 可选，默认 true。是否显示复制按钮
      "sensitive": false,                    // 可选，默认 false。true 则默认打码显示
      "multiline": false                     // 可选，默认 false。true 则多行展示
    }
  ]
}
```

- `sensitive: true`：值默认以打码形式展示，用户点击才明文——**cookie、完整凭证这类长敏感值务必打开**。
- `multiline: true`：适合大段文本（证书、JSON 原文）。
- 字段顺序即展示顺序；同一值多处展示没有限制。

### 10.2 渲染时机

- 流程正常结束（`end: true` / 走到 flow 末尾 / `end: "cancelled"` 之外的正常路径）→ 渲染 output。
- `end: "error"` → 终态 failed **但仍渲染 output**——把 `steps.*` 里的诊断字段（错误码、服务端 msg）放进 output 展示给用户。
- 流程失败（未定义 `end: "error"` 的失败）或用户取消 → 不渲染。
- 字段 `value` 渲染失败（`E_UNDEF` 等）会把已正常结束的流程**判为失败**——这是 output 最常见的翻车点，见下。

### 10.3 output 引用规则与 E_UNDEF 陷阱

> ⚠️ **`output` 只应引用 `vars.*` / `input.*`。**

直接引用 `steps.<id>.<name>` 的问题：引用**从未执行过**的步骤（因 `end: true` 提前结束、`when` 为假跳过、`branch` 走了别的分支）会报 `E_UNDEF`，把已经成功的流程判为失败。

**正确模式**——步骤产出先 `set` 进 `vars`，顶层 `vars` 给默认值：

```jsonc
"vars": { "token": "", "errorMsg": "" },        // ← 默认值兜底
"flow": [
  { "id": "login", "type": "request", "……": "…",
    "extract": [ { "name": "tk", "from": "json", "path": "$.data.token",
                    "optional": true, "default": "" } ],
    "onFail": { "goto": "markFail" } },
  { "id": "save", "type": "set",
    "set": { "vars": { "token": "{{steps.login.tk}}" } } },
  { "id": "markFail", "type": "set",
    "set": { "vars": { "errorMsg": "{{response.message}}" } },
    "end": "error" }
],
"output": { "title": "结果", "fields": [
  { "label": "Token", "value": "{{vars.token}}" },
  { "label": "失败原因", "value": "{{vars.errorMsg}}" }
] }
```

即使走了失败分支，`vars.token` 至少是空串（顶层默认值），output 渲染不会炸。

---

## 11. 网络安全模型

### 11.1 `allowHosts` —— 硬白名单

```jsonc
"allowHosts": ["api.example.com", "captcha.example.com:8443"]
```

- 每项格式：`host` 或 `host:port`，**不含 scheme**（写 `https://api.example.com` 直接 `E_SCHEMA`）、不允许路径、**不支持通配符**（`*.example.com` ❌）。
- 匹配规则：**小写精确匹配**；URL 显式写了非默认端口时，白名单项也须带同样端口。
- 每个 `request.url`（渲染后）的 host 在**发出请求前**校验，未命中报 `E_HOST`。
- `followRedirects: true` 时**每一跳重新校验**，跨 host 且目标不在白名单 → `E_HOST`；最多 5 跳。
- `ui.type=webview` 的 `url` / `baseUrl` 同样受白名单约束（含渲染后的运行期校验）；**HTML 内部子资源的 host 由作者负责声明**（第 7.3 节）。

**盘点 allowHosts 的清单**（写插件时逐项核对）：登录接口域、验证码/滑块域、重定向链路上的每个域、webview HTML 里引用的 CDN/风控域、轮询查询域。

### 11.2 HTTPS 强制

默认禁止 `http://`（`E_INSECURE`）；禁止关闭 TLS 证书校验（引擎无任何逃生口）。

### 11.3 `allowInsecureLocalhost`

```jsonc
"allowInsecureLocalhost": true   // 默认 false
```

仅当为 true 且 host ∈ {`127.0.0.1`, `localhost`, `::1`} 时放行明文 HTTP——**仅限本地联调**（如宿主 App 在本机起的测试服务）。正式分发的插件不得使用。

### 11.4 `secrets` 与敏感值分级

| 层级 | 机制 |
|---|---|
| 作者的固定密钥（转发服务 key 等） | `secrets` + `{{secrets.<key>}}`；错误消息强制脱敏（只回显模板原文） |
| 用户输入的敏感项 | `inputs[].sensitive: true`（不写日志、不落盘、不回显） |
| 展示层的敏感结果 | `output.fields[].sensitive: true`（默认打码） |
| 用户密码 | `inputs` 用 `type: "password"`；不要把密码提取进 `vars` 后再放进 output |

---

## 12. hooks 与 JS 沙箱边界

```jsonc
"hooks": {
  "libs": ["forge@1.4.0"],   // 内置库白名单；当前唯一可选项；最多 8 项、不可重复
  "timeoutMs": 5000          // 单次 JS 执行超时。100..60000，默认 5000
}
```

- `hooks` 省略 = 不启用任何 JS 库（表达式里的 `fn.*` 不受影响——它们由内置沙箱直接提供，无需声明）。
- 需要在 `set.js` 里用 `forge`（AES/RSA 非标准模式、X.509 解析等）时才声明 `hooks.libs`。
- `timeoutMs` 同时约束 set.js 单次执行与内置函数调用的 JS 耗时。

**沙箱边界总览**（生产宿主 QuickJS，`ui_flutter/lib/src/quickjs_runtime.dart`）：

| 类别 | 内容 |
|---|---|
| 可用 | 纯 ES5+/部分 ES6 语法、`JSON`、`Math`、`RegExp`、`Date`、`Uint8Array`、注入的 `fn`、（声明后的）`forge` |
| 替换为禁用桩（调用即 `E_JS`） | `eval`、`Function`、`setTimeout`、`setInterval`、`clearTimeout`、`clearInterval`、`fetch`、`XMLHttpRequest`、`require` |
| 别名 | `window` = `self` = `globalThis`（无 DOM/BOM） |
| 注入 | `Math.random` / `Date.now` 由引擎注入种子与时钟（可复现、可控） |

**为什么这么严**：插件是不可信第三方内容。沙箱保证一段恶意/有缺陷的 set.js **最多**浪费 CPU（有超时），无法访问网络、文件、宿主与用户数据。

---

## 13. 打包、校验与分发

### 13.1 磁盘形态

安装后：`plugins/<id>/manifest.json`（一个插件 = 一个只含 manifest 的目录）。图标等扩展暂不支持，manifest 是唯一内容。

### 13.2 分发格式：裸 manifest 与 `.qbpkg` 信封

两种**等价的纯文本**格式：

- **裸 manifest**：`manifest.json` 原文；
- **`.qbpkg` 信封**：

```json
{
  "qbpkg": "1.0",
  "manifest": { "id": "demo.hello", "...": "完整 manifest 原样内嵌" },
  "meta": { "exportedAt": "2024-01-02T03:04:05Z", "exportedBy": "author", "note": "" }
}
```

App 导入时自动识别两种格式（顶层有 `qbpkg` 键 → 信封；有 `id`/`flow` → 裸 manifest；都不是 → `E_PKG_FORMAT`）。导出时生成信封。`.qbpkg` 是**纯文本 JSON**——肉眼可读、可 diff、可粘贴，**不是** zip。

### 13.3 校验工具链

```bash
# 结构 + 跨字段语义校验（首选，先跑这个）
python schema/validate.py plugins/<id>/manifest.json

# 仅 JSON Schema 结构校验
python -m jsonschema -i plugins/<id>/manifest.json schema/manifest.schema.json
```

`validate.py` 额外做的跨字段检查（schema 表达不了的）：

- JSON **重复键**检测（`{"a":1,"a":2}`）；
- `goto` / `branch[].goto` / `poll.steps` / `poll.onTimeout.goto` / `onFail.goto` 指向的 step id 必须存在；
- step `id` 唯一、`extract[].name` 同步唯一、`inputs[].key` 唯一；
- `allowHosts` 每项是纯 host（可带端口）；
- `allowInsecureLocalhost` 时 localhost 集合 {`127.0.0.1`, `localhost`, `::1`, `[::1]`}；
- `assert` 恰好一个操作符（schema 的 oneOf 补强）。

### 13.4 JSON 语法自测表（导入器的 8 个判定用例）

| # | 输入 | 结果 | 原因 |
|---|---|---|---|
| 1 | `{"hello":"world"}` | ❌ `E_PKG_FORMAT` | 顶层既没有 `qbpkg` 也没有 `id`/`flow` |
| 2 | 只有 `id` + `flow` | ❌ `E_SCHEMA` | 缺少必需字段 `name` |
| 3 | `id` 只有一段（`myplugin`） | ❌ `E_SCHEMA` | `id` 须匹配 `^[a-z0-9]+(\.[a-z0-9]+)+$`（至少两段） |
| 4 | `version: "1.0"` | ❌ `E_SCHEMA` | 须匹配 `^\d+\.\d+\.\d+$`（必须三段） |
| 5 | `allowHosts: []` | ❌ `E_SCHEMA` | 必须非空数组 |
| 6 | `flow: []` | ❌ `E_SCHEMA` | 必须非空数组 |
| 7 | 多一个字段 `foo` | ❌ `E_SCHEMA` | 未知字段一律拒绝 |
| 8 | 完整结构 | ✅ 通过 | — |

### 13.5 发布到插件库（`index.json`）

想让别人能一键拉取你的插件，需要一个**插件库仓库**——任意一个公开 GitHub 仓库，
根目录放 `index.json` + 若干 `.qbpkg` 文件：

```
your-plugin-repo/
├── index.json                 ← 清单（必填）
└── dist/
    ├── demo.hello.qbpkg
    └── demo.hash.qbpkg
```

`index.json` 的结构：

```json
{
  "schemaVersion": 1,
  "name": "我的插件库",
  "updatedAt": "2026-01-02T03:04:05Z",
  "plugins": [
    {
      "id": "demo.hello",
      "name": "示例：打个招呼",
      "version": "1.0.0",
      "allowHosts": ["demo.invalid"],
      "path": "dist/demo.hello.qbpkg",
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "description": "一句话说明这个插件干什么",
      "author": "你的名字"
    }
  ]
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `schemaVersion` | ✅ | 固定 `1` |
| `name` | ✅ | 插件库显示名（App 里会显示） |
| `updatedAt` | ✅ | ISO 8601 UTC 时间戳 |
| `plugins` | ✅ | 插件条目数组 |
| `plugins[].id` | ✅ | 必须与插件 manifest 里的 `id` **完全一致** |
| `plugins[].name` | ✅ | 显示名（可与 manifest 不同，这里更简短） |
| `plugins[].version` | ✅ | 语义化版本，必须与 manifest 的 `version` 一致 |
| `plugins[].allowHosts` | ✅ | 与 manifest 的 `allowHosts` 一致（App 会对比，不一致会警告） |
| `plugins[].path` | ✅ | `.qbpkg` 文件相对仓库根的路径 |
| `plugins[].sha256` | ✅ | **`.qbpkg` 文件的 SHA-256（小写 hex）** —— App 下载后强制校验，不匹配就拒绝 |
| `plugins[].description` | 可选 | 一句话说明 |
| `plugins[].author` | 可选 | 作者 |

**生成 `sha256`**：

```bash
# Linux / macOS
sha256sum dist/demo.hello.qbpkg

# Windows PowerShell
(Get-FileHash dist\demo.hello.qbpkg -Algorithm SHA256).Hash.ToLower()
```

**用户怎么用**：App → 插件库 → 设置里填仓库地址（`https://github.com/你/仓库` 即可，
App 会自动转成 raw 地址；也可直接填 `.../main/index.json`）→ 刷新 → 勾选 → 导入。

**更新插件**：改 manifest → 重新导出 `.qbpkg` → 上传覆盖 → **更新 `index.json` 里的
`version` 和 `sha256`**（漏改 sha256 会导致所有用户下载失败，这是最常见的翻车点）。

**国内加速**：App 内置多级镜像（直连 → ghfast.top → gh-proxy.com → jsDelivr），
无需你额外配置。

### 13.6 手写 JSON 的五个高频坑

1. **正则里的反斜杠要双写**：`pattern: "^\\d{6}$"`（JSON 字符串层先吃一层）。
2. **UTF-8 无 BOM**：Windows 编辑器默认可能加 BOM，导入器会拒绝。
3. **无注释、无尾逗号**：`jsonc` 讲解代码块里的 `//` 注释必须删干净。
4. **模板字符串里的双引号**：`"value": "{{fn.concat('a', '\"b\"')}}"` 这类嵌套极难写对，优先用 `fn.concat` + 单引号表达式字符串。
5. **中文直接写**：manifest 是 UTF-8，`label`/`name` 里写中文没问题，不要自己转 `\uXXXX`。

---

## 14. 任务配方（Recipes）

以下配方覆盖常见任务形态，全部使用示例域名，可直接套改。

### 14.1 密码登录（JSON 断言 + token 提取）

```jsonc
{
  "id": "demo.passwordlogin", "name": "密码登录示例", "version": "1.0.0",
  "engine": ">=1.0 <2.0",
  "allowHosts": ["api.example.com"],
  "inputs": [
    { "key": "phone", "label": "手机号", "type": "phone" },
    { "key": "password", "label": "密码", "type": "password", "minLength": 6 }
  ],
  "vars": { "base": "https://api.example.com", "token": "" },
  "flow": [
    { "id": "login", "type": "request",
      "request": {
        "method": "POST", "url": "{{vars.base}}/v1/auth/login",
        "headers": { "Content-Type": "application/json;charset=UTF-8" },
        "body": { "type": "json",
          "value": { "phone": "{{input.phone}}", "password": "{{input.password}}" } }
      },
      "extract": [ { "name": "tk", "from": "json", "path": "$.data.token" } ],
      "assert": { "json": "$.code", "equals": "0", "message": "登录失败：{{response.message}}" } },
    { "id": "save", "type": "set", "set": { "vars": { "token": "{{steps.login.tk}}" } } }
  ],
  "output": { "title": "登录成功", "fields": [
    { "label": "Token", "value": "{{vars.token}}", "sensitive": true } ] }
}
```

### 14.2 图形验证码（image + 刷新）

```jsonc
"flow": [
  { "id": "captcha", "type": "request",
    "request": { "method": "GET", "url": "{{vars.base}}/captcha?ts={{fn.ts13()}}" },
    "extract": [ { "name": "img", "from": "json", "path": "$.data.imageBase64" },
                 { "name": "capId", "from": "json", "path": "$.data.captchaId" } ] },
  { "id": "ask", "type": "ui",
    "ui": { "type": "image", "label": "图形验证码", "input": "captchaCode",
            "image": "{{steps.captcha.img}}", "refreshStep": "captcha" } },
  { "id": "submit", "type": "request", "……": "带 captchaId + captchaCode 提交" }
]
```

`refreshStep: "captcha"` 让用户点「看不清」时**重新执行** `captcha` 步骤拿新图；`image` 是模板，自动引用最新提取值。

### 14.3 短信验证码（发送 → 轮询就绪 → 输入 → 提交）

```jsonc
"flow": [
  { "id": "sendSms", "type": "request",
    "request": { "method": "POST", "url": "{{vars.base}}/sms/send",
      "body": { "type": "form", "value": { "phone": "{{input.phone}}" } } },
    "assert": { "json": "$.code", "equals": "0" } },
  { "id": "waitReady", "type": "poll", "goto": "askCode",
    "poll": { "steps": ["smsStatus"], "until": "steps.smsStatus.state == '2'",
              "intervalMs": 2000, "maxAttempts": 10,
              "onTimeout": { "message": "短信通道未就绪，请稍后再试" } } },
  { "id": "smsStatus", "type": "request",
    "request": { "method": "GET", "url": "{{vars.base}}/sms/status?phone={{input.phone}}" },
    "extract": [ { "name": "state", "from": "json", "path": "$.data.state" } ] },
  { "id": "askCode", "type": "ui", "when": "input.smsCode == ''",
    "ui": { "type": "text", "label": "短信验证码", "input": "smsCode",
            "maxLength": 6, "pattern": "^\\d{6}$" } },
  { "id": "verify", "type": "request", "……": "提交 smsCode 换 token" }
]
```

注意 `smsStatus` 步骤在 flow 里只需声明一次——poll 通过 `steps: ["smsStatus"]` 引用执行它，不按数组位置走。poll 成功后用 `goto: "askCode"` 越过它在数组里的声明位，否则游标会顺序落回 `smsStatus` 再多执行一次。

### 14.4 滑块验证（webview + 多域名白名单）

```jsonc
"allowHosts": ["api.example.com", "captcha.example.com", "static.example-cdn.com"],
"flow": [
  { "id": "initSlider", "type": "request", "……": "拿滑块会话 sliderUrl" },
  { "id": "slider", "type": "ui",
    "ui": { "type": "webview", "label": "安全验证", "input": "sliderToken",
            "url": "{{steps.initSlider.sliderUrl}}", "hint": "请完成滑动验证" } },
  { "id": "login", "type": "request",
    "request": { "method": "POST", "url": "{{vars.base}}/v1/auth/login",
      "headers": { "X-Captcha-Token": "{{input.sliderToken}}" }, "……": "…" },
    "onFail": { "goto": "initSlider" } }
]
```

`onFail.goto: "initSlider"` 形成受 E_LOOP 保护的「滑块过期自动重来」。HTML 模式（`html` + `baseUrl`）时记得把 HTML 里引用的所有 CDN 域写进 `allowHosts`（作者责任，见 7.3）。

### 14.5 签名请求（set 管道拆长表达式）

```jsonc
"vars": { "base": "https://api.example.com", "appKey": "demo-key" },
"flow": [
  { "id": "sign", "type": "set",
    "set": { "vars": {
      "ts": "{{fn.ts13()}}",
      "nonce": "{{fn.randomHex(16)}}",
      "raw": "{{fn.concat('appKey=', vars.appKey, '&ts=', vars.ts, '&nonce=', vars.nonce)}}",
      "sign": "{{fn.md5(vars.raw)}}"
    } } },
  { "id": "fetch", "type": "request",
    "request": { "method": "GET", "url": "{{vars.base}}/data",
      "query": { "ts": "{{vars.ts}}", "nonce": "{{vars.nonce}}", "sign": "{{vars.sign}}" } } }
]
```

同一 `set` 内按声明顺序求值：`raw` 引用刚算出的 `ts`/`nonce`，`sign` 引用 `raw`——5 层嵌套的单行巨型表达式就这样拆成 4 行可读管道。

### 14.6 RSA 加密密码

```jsonc
"vars": { "rsaPub": "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8A……" },
"flow": [
  { "id": "enc", "type": "set",
    "set": { "vars": { "encPwd": "{{fn.rsaPkcs1(vars.rsaPub, input.password)}}" } } },
  { "id": "login", "type": "request",
    "request": { "method": "POST", "url": "{{vars.base}}/v1/auth/login",
      "body": { "type": "json", "value": { "phone": "{{input.phone}}", "encPwd": "{{vars.encPwd}}" } } } }
]
```

`rsaPub` 是 X.509 SubjectPublicKeyInfo 的 base64（标准 `BEGIN PUBLIC KEY` 内容）。加密失败（格式错、明文超 k−11 字节）报 `E_ARG`。

### 14.7 二进制协议（hex body + binary 提取）

```jsonc
"flow": [
  { "id": "probe", "type": "request",
    "request": { "method": "POST", "url": "{{vars.base}}/probe",
      "body": { "type": "hex", "value": "16de000400000001" } },
    "extract": [
      { "name": "vuid", "from": "binary", "tag": "162b", "offset": -4, "length": 4, "encoding": "be32" },
      { "name": "sid",  "from": "binary", "tag": "1630", "length": 32, "encoding": "ascii" },
      { "name": "rest", "from": "raw" }
    ] },
  { "id": "next", "type": "set",
    "set": { "vars": { "probeHex": "{{fn.hex(fn.slice(steps.probe.rest, 0, 16))}}" } } }
]
```

`tag` 定位 + `offset`（默认 2，可为负）+ `length` + `encoding` 五件套见第 6.4(d) 节；`from: "raw"` 拿整个响应体 bytes，配合 `fn.slice`/`fn.indexOf`/`fn.scanAscii` 做进一步解析。

### 14.8 双层 JSON（asJson + innerPath）

```jsonc
"extract": [
  { "name": "payload", "from": "json", "path": "$.data.payload",
    "asJson": true, "innerPath": "$.result.token", "optional": true, "default": "" }
]
```

网关把内层 JSON 转义成字符串塞在 `$.data.payload` 时：先取字符串 → 二次 `jsonDecode` → 在内层按 `innerPath` 取 `token`。内层缺字段时 `optional` 兜底。

### 14.9 GBK 编码站点

```jsonc
"extract": [ { "name": "body", "from": "raw" } ],
"……":
"set": { "vars": { "text": "{{fn.charsetDecode(steps.fetch.body, 'gbk')}}" } }
```

`from: "raw"` 取原始 bytes（不按 UTF-8 解码），再 `charsetDecode` 按 GBK 转中文文本；后续正则/断言在解码后的文本上做。

### 14.10 失败降级（onFail.goto + end:"error" 诊断输出）

```jsonc
"vars": { "token": "", "fallback": "", "diag": "" },
"flow": [
  { "id": "primary", "type": "request", "……": "主通道",
    "onFail": { "goto": "backup" } },
  { "id": "backup", "type": "request", "……": "备用通道",
    "onFail": { "goto": "diag" } },
  { "id": "diag", "type": "set",
    "set": { "vars": { "diag": "主/备通道均失败，请稍后再试" } },
    "end": "error" }
]
```

`end: "error"` 保证 output 里的诊断字段（`{{vars.diag}}`）仍然渲染展示，终态为 failed 提醒宿主按失败处理。

---

## 附录 A：错误码速查

| 码 | 触发 |
|---|---|
| `E_SCHEMA` | manifest 不符合 JSON Schema（未知字段、类型错、超范围……） |
| `E_ENGINE` | `engine` 版本范围不满足 |
| `E_TEMPLATE` | 模板语法错误（`{{` 无 `}}`、空表达式） |
| `E_UNDEF` | 引用不存在的路径（不返回 null） |
| `E_TYPE` | 函数参数类型错误；bytes 直接渲染成字符串 |
| `E_ARG` | 函数参数值非法（空 list、越界、非法正则/字符集……） |
| `E_GOTO` | `goto`/`branch`/`poll.steps` 指向不存在的 step id |
| `E_HOST` | URL host 不在 allowHosts（发出前拦截；含重定向每跳） |
| `E_INSECURE` | 明文 HTTP 且未授权 |
| `E_HTTP` | HTTP 状态非 2xx 且不在 retry.on（重试用尽） |
| `E_TIMEOUT` | 请求超时 |
| `E_EXTRACT` | 提取失败且非 optional |
| `E_ASSERT` | assert 不通过 |
| `E_LOOP` | 单步访问次数 > flow.length × 3 |
| `E_END` | `end: "error"` 显式失败终止（output 仍渲染） |
| `E_JS` | JS 沙箱错误：语法错/运行时异常/超时/调用禁用 API/返回值非法 |
| `E_PKG_FORMAT` | 导入内容既不是裸 manifest 也不是 `.qbpkg` 信封 |

错误对象统一携带：`code`、`message`、`stepId`（若有）、`detail`（可选）。

## 附录 B：发布前检查清单

逐项打勾后再分发：

- [ ] `python schema/validate.py` 零报错；
- [ ] JSON 无注释、无尾逗号、UTF-8 无 BOM；
- [ ] `allowHosts` 覆盖：登录域、验证码/滑块域、重定向每跳、webview HTML 内的 CDN 域、轮询域；
- [ ] 所有 `goto`/`branch`/`poll.steps` 目标 id 存在（validate.py 已查，手工再扫一遍拼写）；
- [ ] `output` 只引用 `vars.*`/`input.*`，且这些键在顶层 `vars` 有默认值；
- [ ] 敏感项：密码用 `inputs type=password`；输出凭证加 `sensitive: true`；作者密钥走 `secrets`；
- [ ] 模板中可能为 null 的引用都有兜底（`optional`+`default` / `fn.default`）；
- [ ] 长轮询的 `maxAttempts × 步数` 不会撞 `flow.length × 3` 上限；
- [ ] 手机号等示例值已替换为脱敏示例（如 `13800138000`），不含真实账号；
- [ ] **界面掩码符合预期**：手机号/验证码应让用户看到明文（省略 `obscure` 或写 `false`），
      真正的密码保持掩码；注意 `obscure` 只影响界面，日志仍按 `sensitive` 脱敏；
- [ ] 在测试环境（`allowInsecureLocalhost` 仅限本地）完整跑通主路径 + 失败路径；
- [ ] **若发布到插件库**：`index.json` 里的 `sha256` 与实际 `.qbpkg` 文件一致
      （改过插件必须重算，漏改会让所有用户下载失败——最常见的翻车点）；
- [ ] **若发布到插件库**：`index.json` 的 `id`/`version`/`allowHosts` 与 manifest 一致。

---

*本文基于 `CONTRACT.md`（v2.0）、`schema/manifest.schema.json` 与 Dart 引擎源码（`engine/lib/src/`）编写；示例均已脱敏。*

