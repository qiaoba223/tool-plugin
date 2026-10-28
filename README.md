# tool-plugin

登录插件引擎的 **Flutter / 纯 Dart 实现**（Android + iOS），逻辑对齐上游
[`mtguowang/tool-plugin`](https://github.com/mtguowang/tool-plugin) 的 JSON 插件契约。

## 结构

```
packages/plugin_engine/   纯 Dart 引擎（无 Flutter 依赖，可直接 dart test）
contract/                 上游契约基线（schema / validate.py / 规范正文）+ ALIGNMENT.md
app/                      Flutter UI（Android + iOS）
```

## 与上游的关系

上游 `tool-plugin` 只公开了**规范与校验器**，引擎源码未开源（`ui_core/`、
`ui_flutter/` 不在仓库内）。因此本实现是**按规范复现**，不是移植。

- 逐字对齐：`lexer` / `expr` 对照 `validate.py`，`fnSpecs` 对照 `FN_SPECS`
- 已知偏差：见 [`contract/ALIGNMENT.md`](contract/ALIGNMENT.md)
- 同步上游：见 ALIGNMENT.md 的「同步流程」

## 验证基线

用 [`mtguowang/plugin-harbor`](https://github.com/mtguowang/plugin-harbor) 的
4 个真实插件作为回归用例（`packages/plugin_engine/test/fixtures/`）。
