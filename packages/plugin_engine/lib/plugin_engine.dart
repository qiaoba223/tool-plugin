/// 库入口：登录插件引擎（纯 Dart 实现，对齐上游 tool-plugin 契约）。
///
/// 上游契约来源见 `contract/`：`manifest.schema.json`、`validate.py`、
/// `PLUGIN_JSON_GUIDE.md`。已知偏差与推断点记录在 `contract/ALIGNMENT.md`。
library plugin_engine;

export 'src/conditions.dart' show runAssert;
export 'src/engine.dart';
export 'src/errors.dart';
export 'src/expr.dart' show Expr, ExprParser, walkExpr;
export 'src/extractor.dart' show ResponseView, jsonPath, runExtract;
export 'src/functions.dart' show FnContext, callFn, fnSpecs, functionNames;
export 'src/js/js_bridge.dart'
    show
        jsReservedInputNames,
        runSetJs,
        scanBannedIdentifiers,
        validateJsInputs,
        validateSetJsSyntax;
export 'src/manifest.dart';
export 'src/package.dart' show DecodedPackage, PluginPackage;
export 'src/template.dart' show Scope, TemplateEngine;
export 'src/values.dart'
    show bytesToHex, hexToBytes, renderValue, valuesEqual;
