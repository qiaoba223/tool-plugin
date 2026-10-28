#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
登录插件 manifest 校验器（零依赖，仅 Python 标准库）

用法：
    python validate.py <manifest.json>
    python validate.py --dir <plugins_dir>

职责分两层：
  1) Schema 层：用内置的 JSON Schema Draft 2020-12 子集求值器跑 manifest.schema.json
                （结构、类型、枚举、正则、长度、数值区间、必需字段、additionalProperties:false、
                  oneOf / allOf / if-then-else 等条件约束）
  2) 语义层：schema 表达不了的跨字段检查（见 SEMANTIC CHECKS 注释块）

退出码：0 = 全部通过（允许有 warning）；1 = 存在 error。

安全说明：manifest 一律当作**不可信数据**，本脚本只做静态分析，绝不执行其中任何内容。
"""

import argparse
import json
import os
import re
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SCHEMA = os.path.join(HERE, "manifest.schema.json")


# ---------------------------------------------------------------------------
# 函数库（照抄 CONTRACT.md §5.2）：名称 -> (最少参数, 最多参数, 返回类型)
#   返回类型：string / bytes / int / bool / any(不可静态判定) / same(同首参)
# ---------------------------------------------------------------------------
FN_SPECS = {
    # 编码 / 转换
    "b64": (1, 1, "string"),
    "b64d": (1, 1, "string"),
    "hex": (1, 1, "string"),
    "unhex": (1, 1, "bytes"),
    "utf8": (1, 1, "bytes"),
    "latin1": (1, 1, "string"),
    "urlenc": (1, 1, "string"),
    "gz": (1, 1, "bytes"),
    "gunz": (1, 1, "bytes"),
    # 哈希
    "md5": (1, 1, "string"),
    "sha1": (1, 1, "string"),
    "sha256": (1, 1, "string"),
    "hmacSha256": (2, 2, "string"),
    "crc32": (1, 1, "string"),
    # 加密
    "rsaPkcs1": (2, 2, "string"),
    "aesCbc": (3, 3, "string"),
    "aesEcb": (2, 2, "string"),
    # 逆向常用自定义编码
    "shift2": (1, 1, "string"),
    "shiftN": (2, 2, "string"),
    "padRight": (3, 3, "string"),
    "padLeft": (3, 3, "string"),
    "repeat": (2, 2, "string"),
    "substring": (2, 3, "string"),
    "concat": (1, 99, "same"),
    "len": (1, 1, "int"),
    "trim": (1, 1, "string"),
    "upper": (1, 1, "string"),
    "lower": (1, 1, "string"),
    # bytes 操作
    "bytesReplace": (3, 3, "bytes"),
    "be32Write": (3, 3, "bytes"),
    "be32Read": (2, 2, "int"),
    "slice": (2, 3, "same"),
    "indexOf": (2, 3, "int"),
    "at": (2, 2, "int"),
    "scanAscii": (3, 3, "string"),
    # 随机 / 时间
    "randomHex": (1, 1, "string"),
    "randomDigits": (1, 1, "string"),
    "randomOf": (1, 1, "any"),
    "randomInt": (2, 2, "int"),
    "randomModOffset": (2, 2, "string"),
    "uuid": (0, 0, "string"),
    "now": (0, 0, "int"),
    "ts14": (0, 0, "string"),
    "ts10": (0, 0, "string"),
    "ts13": (0, 0, "string"),
    # 其他
    "coalesce": (1, 99, "any"),
    "default": (2, 2, "any"),
    # ===== v1.3 新增 =====
    # ⚠️ 本表必须与 `engine/lib/src/functions.dart` 的 `functionNames` **完全同步**。
    #    v1.3/v1.4 加函数时漏了这张表，导致**完全合法的插件被判 E_UNDEF**：
    #      `未知函数 fn.unb64（是否想写 fn.b64？）` —— 提示还极具误导性。
    #    现有回归测试锁定：`schema/run_tests.py` 的 FN_SPECS 一致性检查。
    "unb64": (1, 1, "bytes"),
    "b64url": (1, 1, "string"),
    "unb64url": (1, 1, "bytes"),
    # ===== v1.4 新增 =====
    # 字符串处理
    "replace": (3, 3, "string"),
    "replaceRegex": (3, 3, "string"),
    "split": (2, 2, "list"),
    "startsWith": (2, 2, "bool"),
    "endsWith": (2, 2, "bool"),
    # 类型转换
    "toInt": (1, 1, "int"),
    "toFloat": (1, 1, "float"),
    "toString": (1, 1, "string"),
    # 编码 / 中文站点
    "charsetDecode": (2, 2, "string"),
    "htmlUnescape": (1, 1, "string"),
    "htmlEscape": (1, 1, "string"),
    # 集合操作
    "count": (1, 1, "int"),
    "first": (1, 1, "any"),
    "last": (1, 1, "any"),
    "nth": (2, 2, "any"),
    # ===== v1.6 日期处理 =====
    # ⚠️ 又是这张表漏同步 —— 幸好加了 FN_SPECS 一致性回归测试，
    #    它在 `python schema\run_tests.py` 里**立刻报错**（「FN_SPECS 缺 4 个函数」）。
    #    这就是那条回归测试的价值：加函数时忘了同步，CI 会拦住。
    "toDate": (1, 2, "string"),
    "dateFormat": (2, 2, "string"),
    "daysBeforeNow": (1, 1, "int"),
    "daysAfterNow": (1, 1, "int"),
    # ===== v1.7 二进制/JSON 处理 =====
    # 动机（docs/PLUGIN_DEV_EMPIRICAL_TEST.md 卡点 9/11 + gzip JSON body）：
    #   - be16Read/be16Write/u8Write：2 字节大端读写 + 单字节写入（be32 系列补齐）；
    #   - jsonParse：fn.gunz 解压出 JSON 文本后取字段。
    # 语义与 be32Write/be32Read 一致（copy-on-write、E_ARG 越界）。
    "jsonParse": (1, 1, "any"),
    "be16Write": (3, 3, "bytes"),
    "be16Read": (2, 2, "int"),
    "u8Write": (3, 3, "bytes"),
}

# CONTRACT.md §3.3 引擎必须提供的 env 键
ENV_KEYS = {"deviceModels", "appVersion", "platform", "locale"}

# §6.3 允许明文 HTTP 的 host
LOCALHOSTS = {"127.0.0.1", "localhost", "::1", "[::1]"}

# 步骤类型
STEP_TYPES = {"request", "poll", "ui", "set"}

IDENT_RE = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*$")
JSONPATH_RE = re.compile(r"^\$(?:\.[A-Za-z_][A-Za-z0-9_]*|\[\d+\])*$")
HOST_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)*(?::\d{1,5})?$")


# ===========================================================================
# 1. JSON 解析器（带重复键检测 + 行号）
# ===========================================================================
class JsonParseError(Exception):
    pass


class JsonParser(object):
    """手写递归下降 JSON 解析器：返回 (值, 重复键列表[(对象路径, 键, 行号)])。

    为什么不用 json.loads：标准库的 object_pairs_hook 拿不到重复键所在的路径，
    而「vars 里的重复键后者覆盖前者」是真实 bug 来源，需要精确定位。
    """

    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)
        self.dups = []

    def line_of(self, pos):
        return self.s.count("\n", 0, pos) + 1

    def fail(self, msg):
        raise JsonParseError("%s（第 %d 行）" % (msg, self.line_of(self.i)))

    def skip_ws(self):
        while self.i < self.n and self.s[self.i] in " \t\r\n":
            self.i += 1

    def parse(self):
        self.skip_ws()
        v = self.parse_value("$")
        self.skip_ws()
        if self.i != self.n:
            self.fail("顶层 JSON 之后还有多余内容")
        return v, self.dups

    def parse_value(self, path):
        self.skip_ws()
        if self.i >= self.n:
            self.fail("意外的输入结束")
        c = self.s[self.i]
        if c == "{":
            return self.parse_object(path)
        if c == "[":
            return self.parse_array(path)
        if c == '"':
            return self.parse_string()
        return self.parse_literal()

    def parse_object(self, path):
        self.i += 1  # 吃掉 '{'
        obj = {}
        self.skip_ws()
        if self.i < self.n and self.s[self.i] == "}":
            self.i += 1
            return obj
        while True:
            self.skip_ws()
            key_pos = self.i
            if self.i >= self.n or self.s[self.i] != '"':
                self.fail("对象的键必须是字符串")
            key = self.parse_string()
            self.skip_ws()
            if self.i >= self.n or self.s[self.i] != ":":
                self.fail("键 %r 之后缺少 ':'" % key)
            self.i += 1
            val = self.parse_value(path + "." + key)
            if key in obj:
                self.dups.append((path, key, self.line_of(key_pos)))
            obj[key] = val
            self.skip_ws()
            if self.i < self.n and self.s[self.i] == ",":
                self.i += 1
                continue
            if self.i < self.n and self.s[self.i] == "}":
                self.i += 1
                return obj
            self.fail("对象中缺少 ',' 或 '}'")

    def parse_array(self, path):
        self.i += 1  # 吃掉 '['
        arr = []
        self.skip_ws()
        if self.i < self.n and self.s[self.i] == "]":
            self.i += 1
            return arr
        idx = 0
        while True:
            arr.append(self.parse_value("%s[%d]" % (path, idx)))
            idx += 1
            self.skip_ws()
            if self.i < self.n and self.s[self.i] == ",":
                self.i += 1
                continue
            if self.i < self.n and self.s[self.i] == "]":
                self.i += 1
                return arr
            self.fail("数组中缺少 ',' 或 ']'")

    def parse_string(self):
        start = self.i
        self.i += 1
        while self.i < self.n:
            c = self.s[self.i]
            if c == "\\":
                self.i += 2
                continue
            if c == '"':
                self.i += 1
                try:
                    return json.loads(self.s[start:self.i])
                except ValueError as e:
                    self.fail("非法字符串转义：%s" % e)
            if c == "\n":
                self.fail("字符串中不允许出现裸换行")
            self.i += 1
        self.fail("字符串未闭合")

    def parse_literal(self):
        m = re.match(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?", self.s[self.i:])
        if m:
            text = m.group(0)
            self.i += len(text)
            return float(text) if ("." in text or "e" in text or "E" in text) else int(text)
        for lit, val in (("true", True), ("false", False), ("null", None)):
            if self.s.startswith(lit, self.i):
                self.i += len(lit)
                return val
        self.fail("无法识别的字面量")


# ===========================================================================
# 2. JSON Schema Draft 2020-12 子集求值器
# ===========================================================================
class SchemaValidator(object):
    """只实现 manifest.schema.json 用到的关键字，零依赖。

    返回值为错误字符串列表；空列表 = 通过。
    """

    def __init__(self, root):
        self.root = root

    def resolve(self, schema):
        """跟随本地 $ref（#/$defs/...）。"""
        hops = 0
        while isinstance(schema, dict) and "$ref" in schema:
            ref = schema["$ref"]
            if not isinstance(ref, str) or not ref.startswith("#/"):
                return schema
            node = self.root
            try:
                for part in ref[2:].split("/"):
                    part = part.replace("~1", "/").replace("~0", "~")
                    node = node[part]
            except Exception:
                return schema
            schema = node
            hops += 1
            if hops > 32:
                return schema
        return schema

    # -- 类型判定（注意 bool 是 int 的子类，必须排除） ---------------------
    @staticmethod
    def type_ok(inst, t):
        if t == "object":
            return isinstance(inst, dict)
        if t == "array":
            return isinstance(inst, list)
        if t == "string":
            return isinstance(inst, str)
        if t == "integer":
            return isinstance(inst, int) and not isinstance(inst, bool)
        if t == "number":
            return isinstance(inst, (int, float)) and not isinstance(inst, bool)
        if t == "boolean":
            return isinstance(inst, bool)
        if t == "null":
            return inst is None
        return True

    def check(self, inst, schema, path="$"):
        errs = []
        schema = self.resolve(schema)
        if not isinstance(schema, dict):
            return errs

        # ---- type -------------------------------------------------------
        if "type" in schema:
            types = schema["type"]
            if isinstance(types, str):
                types = [types]
            if not any(self.type_ok(inst, t) for t in types):
                errs.append("%s：类型应为 %s，实际为 %s" % (path, "/".join(types), jtype(inst)))
                return errs  # 类型不对，后续断言无意义

        # ---- const / enum ----------------------------------------------
        if "const" in schema and inst != schema["const"]:
            errs.append("%s：必须为 %s，实际为 %s" % (path, jrepr(schema["const"]), jrepr(inst)))
        if "enum" in schema and inst not in schema["enum"]:
            errs.append("%s：取值必须是 %s 之一，实际为 %s"
                        % (path, "/".join(jrepr(v) for v in schema["enum"]), jrepr(inst)))

        # ---- 字符串约束 --------------------------------------------------
        if isinstance(inst, str):
            if "minLength" in schema and len(inst) < schema["minLength"]:
                errs.append("%s：长度 %d < 最小长度 %d" % (path, len(inst), schema["minLength"]))
            if "maxLength" in schema and len(inst) > schema["maxLength"]:
                errs.append("%s：长度 %d > 最大长度 %d" % (path, len(inst), schema["maxLength"]))
            if "pattern" in schema:
                try:
                    if re.search(schema["pattern"], inst) is None:
                        errs.append("%s：不匹配正则 %s（实际 %s）"
                                    % (path, schema["pattern"], jrepr(inst)))
                except re.error as e:
                    errs.append("%s：schema 内正则非法（%s）" % (path, e))

        # ---- 数值约束 ----------------------------------------------------
        if isinstance(inst, (int, float)) and not isinstance(inst, bool):
            if "minimum" in schema and inst < schema["minimum"]:
                errs.append("%s：%s < 最小值 %s" % (path, jrepr(inst), jrepr(schema["minimum"])))
            if "maximum" in schema and inst > schema["maximum"]:
                errs.append("%s：%s > 最大值 %s" % (path, jrepr(inst), jrepr(schema["maximum"])))

        # ---- 数组约束 ----------------------------------------------------
        if isinstance(inst, list):
            if "minItems" in schema and len(inst) < schema["minItems"]:
                errs.append("%s：元素个数 %d < 最小 %d" % (path, len(inst), schema["minItems"]))
            if "maxItems" in schema and len(inst) > schema["maxItems"]:
                errs.append("%s：元素个数 %d > 最大 %d" % (path, len(inst), schema["maxItems"]))
            if schema.get("uniqueItems"):
                seen = {}
                for k, item in enumerate(inst):
                    key = json.dumps(item, sort_keys=True, ensure_ascii=False)
                    if key in seen:
                        errs.append("%s：元素 %s 与 %s 重复（uniqueItems）"
                                    % (path, jrepr(item), jrepr(inst[seen[key]])))
                    seen[key] = k
            if "items" in schema:
                for k, item in enumerate(inst):
                    errs.extend(self.check(item, schema["items"], "%s[%d]" % (path, k)))

        # ---- 对象约束 ----------------------------------------------------
        if isinstance(inst, dict):
            props = schema.get("properties", {})
            if "minProperties" in schema and len(inst) < schema["minProperties"]:
                errs.append("%s：属性个数 %d < 最小 %d" % (path, len(inst), schema["minProperties"]))
            if "maxProperties" in schema and len(inst) > schema["maxProperties"]:
                errs.append("%s：属性个数 %d > 最大 %d" % (path, len(inst), schema["maxProperties"]))
            for req in schema.get("required", []):
                if req not in inst:
                    errs.append("%s：缺少必需字段 %r" % (path, req))
            for k, v in inst.items():
                if k in props:
                    errs.extend(self.check(v, props[k], "%s.%s" % (path, k)))
                    continue
                ap = schema.get("additionalProperties", True)
                if ap is False:
                    hint = ""
                    if props:
                        near = closest(k, list(props.keys()))
                        if near:
                            hint = "（是否想写 %r？）" % near
                    errs.append("%s：不允许的未知字段 %r%s" % (path, k, hint))
                elif isinstance(ap, dict):
                    errs.extend(self.check(v, ap, "%s.%s" % (path, k)))
            pn = schema.get("propertyNames")
            if isinstance(pn, dict):
                for k in inst.keys():
                    errs.extend(self.check(k, pn, "%s.<键名 %s>" % (path, k)))

        # ---- 组合关键字 --------------------------------------------------
        if "allOf" in schema:
            for sub in schema["allOf"]:
                errs.extend(self.check(inst, sub, path))

        if "anyOf" in schema:
            branch = [self.check(inst, sub, path) for sub in schema["anyOf"]]
            if all(b for b in branch):
                errs.append("%s：不满足 anyOf 的任何分支（%s）"
                            % (path, first_msgs(branch)))

        if "oneOf" in schema:
            branches = schema["oneOf"]
            branch = [self.check(inst, sub, path) for sub in branches]
            ok = [i for i, b in enumerate(branch) if not b]
            if len(ok) == 0:
                errs.append(self._oneof_none_passed(path, inst, branches, branch))
            elif len(ok) > 1:
                labels = ["分支%d (%s)" % (i + 1, self._branch_label(branches[i], i))
                          for i in ok]
                errs.append("%s：同时满足 %d 个 oneOf 分支（%s），必须恰好一个"
                            % (path, len(ok), "、".join(labels)))

        if "not" in schema:
            if not self.check(inst, schema["not"], path):
                errs.append("%s：命中了被禁止的形态（not 约束）" % path)

        if "if" in schema:
            if not self.check(inst, schema["if"], path):
                if "then" in schema:
                    errs.extend(self.check(inst, schema["then"], path))
            else:
                if "else" in schema:
                    errs.extend(self.check(inst, schema["else"], path))

        return errs

    # ---- oneOf 诊断辅助 --------------------------------------------------
    def _branch_label(self, sub, i):
        """给 oneOf 分支一个人类可读标签：type.const > required[0] > const > type > 分支N。"""
        sub = self.resolve(sub)
        if isinstance(sub, dict):
            pc = sub.get("properties", {}).get("type", {})
            if isinstance(pc, dict) and "const" in pc:
                return str(pc["const"])
            req = sub.get("required", [])
            if req:
                return str(req[0])
            if "const" in sub:
                return jrepr(sub["const"])
            if "type" in sub:
                t = sub["type"]
                return t if isinstance(t, str) else "/".join(t)
        return "分支%d" % (i + 1)

    def _oneof_none_passed(self, path, inst, branches, branch_errs):
        """所有 oneOf 分支都失败时，生成「最相关分支优先」的诊断。

        策略：
          1. 若实例有 type 字段，按 properties.type.const 判别：
             - 命中某分支 → 该分支是用户「想写但写错」的，优先报告其具体错误
             - 未命中但有 type.const 存在 → type 值非法，直接指出合法类型列表
          2. 否则 fallback 到「失败约束数最少」的分支
        保留「不满足 oneOf 的任何分支」短语以兼容既有 expected 关键词。
        """
        legal_types = []
        type_match = None
        if isinstance(inst, dict) and "type" in inst:
            t = inst.get("type")
            for i, sub in enumerate(branches):
                sub_r = self.resolve(sub)
                if isinstance(sub_r, dict):
                    pc = sub_r.get("properties", {}).get("type", {})
                    if isinstance(pc, dict) and "const" in pc:
                        legal_types.append(str(pc["const"]))
                        if pc["const"] == t:
                            type_match = i

        if type_match is not None:
            return self._format_oneof_closest(path, branches, branch_errs, type_match)

        if legal_types:
            return ("%s：不满足 oneOf 的任何分支；type %r 不是合法类型"
                    "（合法：%s）"
                    % (path, inst.get("type"), "、".join(legal_types)))

        best = min(range(len(branch_errs)), key=lambda i: len(branch_errs[i]))
        return self._format_oneof_closest(path, branches, branch_errs, best)

    def _format_oneof_closest(self, path, branches, branch_errs, best):
        """格式化「最接近分支 + 其他分支简要」的多行诊断。"""
        best_label = self._branch_label(branches[best], best)
        lines = ["%s：不满足 oneOf 的任何分支；最接近的是 %s 分支，但仍失败："
                 % (path, best_label)]
        for e in branch_errs[best]:
            lines.append("  └─ %s" % e)
        other = []
        for i, b in enumerate(branch_errs):
            if i == best:
                continue
            other.append("%s(%d 条)" % (self._branch_label(branches[i], i), len(b)))
        if other:
            lines.append("  （其他分支：%s）" % "、".join(other))
        return "\n".join(lines)


def closest(word, candidates):
    """给未知字段一个「是否想写 X」的提示（简单的编辑距离 <= 2）。"""
    best, best_d = None, 99
    for c in candidates:
        d = edit_distance(word.lower(), c.lower())
        if d < best_d:
            best, best_d = c, d
    return best if best_d <= 2 else None


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def jtype(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, int):
        return "integer"
    if isinstance(v, float):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    if isinstance(v, dict):
        return "object"
    return type(v).__name__


def jrepr(v):
    try:
        s = json.dumps(v, ensure_ascii=False)
    except Exception:
        s = repr(v)
    return s if len(s) <= 80 else s[:77] + "..."


def first_msgs(branch_errs):
    """把 oneOf/anyOf 各分支的首条错误压缩成一行提示。"""
    parts = []
    for i, e in enumerate(branch_errs):
        parts.append("分支%d: %s" % (i + 1, e[0] if e else "通过"))
    text = "；".join(parts)
    return text if len(text) <= 400 else text[:397] + "..."


# ===========================================================================
# 3. 表达式解析器（CONTRACT.md §5.1 语法）
# ===========================================================================
class ExprError(Exception):
    pass


TOKEN_RE = re.compile(r"""
    (?P<ws>\s+)
  | (?P<op>\|\||&&|==|!=|>=|<=|>|<|!|\(|\)|,|\.|\[|\])
  | (?P<num>-?\d+(?:\.\d+)?)
  | (?P<str>'[^']*')
  | (?P<ident>[A-Za-z_][A-Za-z0-9_]*)
""", re.X)


def tokenize(src):
    toks = []
    i = 0
    while i < len(src):
        m = TOKEN_RE.match(src, i)
        if not m:
            raise ExprError("位置 %d 处出现非法字符 %r" % (i, src[i]))
        i = m.end()
        if m.lastgroup == "ws":
            continue
        toks.append((m.lastgroup, m.group(0), m.start()))
    toks.append(("eof", "", len(src)))
    return toks


class ExprParser(object):
    """解析 §5.1 表达式，产出轻量 AST。

    AST 节点：
      ("num", 值) ("str", 值) ("bool", 值) ("null",)
      ("path", 原文, [段名])  ("call", 命名空间, 函数名, [参数节点], 原文)
      ("bin", 运算符, 左, 右) ("un", "!", 子节点)
    """

    def __init__(self, src):
        self.src = src
        self.toks = tokenize(src)
        self.p = 0

    def peek(self):
        return self.toks[self.p]

    def at(self, kind, value=None):
        k, v, _ = self.toks[self.p]
        return k == kind and (value is None or v == value)

    def take(self):
        t = self.toks[self.p]
        self.p += 1
        return t

    def expect(self, kind, value=None):
        if not self.at(kind, value):
            k, v, pos = self.peek()
            raise ExprError("位置 %d 期望 %s，实际是 %r" % (pos, value or kind, v))
        return self.take()

    def parse(self):
        node = self.parse_or()
        if not self.at("eof"):
            k, v, pos = self.peek()
            raise ExprError("位置 %d 出现多余记号 %r" % (pos, v))
        return node

    def parse_or(self):
        node = self.parse_and()
        while self.at("op", "||"):
            self.take()
            node = ("bin", "||", node, self.parse_and())
        return node

    def parse_and(self):
        node = self.parse_cmp()
        while self.at("op", "&&"):
            self.take()
            node = ("bin", "&&", node, self.parse_cmp())
        return node

    def parse_cmp(self):
        node = self.parse_unary()
        if self.at("op") and self.peek()[1] in ("==", "!=", ">=", "<=", ">", "<"):
            op = self.take()[1]
            node = ("bin", op, node, self.parse_unary())
        return node

    def parse_unary(self):
        if self.at("op", "!"):
            self.take()
            return ("un", "!", self.parse_unary())
        return self.parse_primary()

    def parse_primary(self):
        k, v, pos = self.peek()
        if k == "num":
            self.take()
            return ("num", float(v) if "." in v else int(v))
        if k == "str":
            self.take()
            return ("str", v[1:-1])
        if k == "ident":
            if v in ("true", "false"):
                self.take()
                return ("bool", v == "true")
            if v == "null":
                self.take()
                return ("null",)
            return self.parse_path_or_call()
        if k == "op" and v == "(":
            self.take()
            node = self.parse_or()
            self.expect("op", ")")
            return node
        raise ExprError("位置 %d 处出现非法记号 %r" % (pos, v))

    def parse_path_or_call(self):
        start = self.toks[self.p][2]
        first = self.take()[1]
        # call: ident "." ident "(" ... ")"
        if self.at("op", ".") and self.toks[self.p + 1][0] == "ident" \
                and self.toks[self.p + 2][0] == "op" and self.toks[self.p + 2][1] == "(":
            self.take()  # .
            fname = self.take()[1]
            self.take()  # (
            args = []
            if not self.at("op", ")"):
                args.append(self.parse_or())
                while self.at("op", ","):
                    self.take()
                    args.append(self.parse_or())
            self.expect("op", ")")
            end = self.toks[self.p - 1][2] + 1
            return ("call", first, fname, args, self.src[start:end])
        # path: ident ("." ident | "[" number "]")*
        segs = [first]
        while True:
            if self.at("op", ".") and self.toks[self.p + 1][0] == "ident":
                self.take()
                segs.append(self.take()[1])
            elif self.at("op", "["):
                self.take()
                self.expect("num")
                self.expect("op", "]")
            else:
                break
        return ("path", self.src[start:self.toks[self.p][2]].strip(), segs)


def walk_expr(node, visit):
    """先序遍历 AST，visit(node) 可返回 False 以停止下钻。"""
    if visit(node) is False:
        return
    kind = node[0]
    if kind == "call":
        for a in node[3]:
            walk_expr(a, visit)
    elif kind == "bin":
        walk_expr(node[2], visit)
        walk_expr(node[3], visit)
    elif kind == "un":
        walk_expr(node[2], visit)


def infer_type(node):
    """静态推断表达式类型：int/double/string/bool/null/bytes/path/unknown。"""
    kind = node[0]
    if kind == "num":
        return "double" if isinstance(node[1], float) else "int"
    if kind == "str":
        return "string"
    if kind == "bool":
        return "bool"
    if kind == "null":
        return "null"
    if kind == "path":
        return "path"
    if kind == "un":
        return "bool"
    if kind == "bin":
        return "bool" if node[1] in ("==", "!=", ">=", "<=", ">", "<", "&&", "||") else "unknown"
    if kind == "call":
        name = node[2]
        spec = FN_SPECS.get(name)
        if not spec:
            return "unknown"
        ret = spec[2]
        if ret == "same":
            return infer_type(node[3][0]) if node[3] else "unknown"
        return ret
    return "unknown"


# ===========================================================================
# 4. 模板扫描
# ===========================================================================
def find_templates(s):
    """从字符串里取出所有 {{ ... }} 模板体。返回 (模板体列表, 语法错误列表)。

    字面量 {{ 写作 \\{\\{（§3.1），扫描时跳过。
    """
    out, errs = [], []
    i, n = 0, len(s)
    while i < n:
        if s.startswith("\\{\\{", i):
            i += 4
            continue
        if s.startswith("{{", i):
            j = s.find("}}", i + 2)
            if j < 0:
                errs.append("位置 %d 处的 '{{' 没有对应的 '}}'（E_TEMPLATE）" % i)
                break
            out.append(s[i + 2:j])
            i = j + 2
            continue
        i += 1
    return out, errs


# ===========================================================================
# 5. manifest 语义检查器
# ===========================================================================
class ManifestChecker(object):
    """schema 表达不了的跨字段 / 跨文件语义检查。"""

    def __init__(self, data, dups, label):
        self.d = data if isinstance(data, dict) else {}
        self.dups = dups
        self.label = label
        self.errors = []    # (code, 位置, 说明)
        self.warnings = []  # (code, 位置, 说明)
        self.stats = {"templates": 0, "exprs": 0, "urls": 0}

    # ---- 记录 ------------------------------------------------------------
    def err(self, code, path, msg):
        self.errors.append((code, path, msg))

    def warn(self, code, path, msg):
        self.warnings.append((code, path, msg))

    # ---- 主入口 ----------------------------------------------------------
    def run(self):
        d = self.d
        self.flow = d.get("flow") if isinstance(d.get("flow"), list) else []
        self.inputs = d.get("inputs") if isinstance(d.get("inputs"), list) else []
        self.top_vars = d.get("vars") if isinstance(d.get("vars"), dict) else {}
        self.secrets = d.get("secrets") if isinstance(d.get("secrets"), list) else []
        self.allow_hosts = d.get("allowHosts") if isinstance(d.get("allowHosts"), list) else []

        self.check_duplicate_keys()
        self.check_encoding_notes()
        self.index_steps()
        self.index_namespaces()
        self.check_allow_hosts()
        self.check_inputs()
        self.check_vars_object(self.top_vars, "$.vars", top_level=True)
        self.check_flow()
        self.check_output()
        self.check_reachability()
        return self

    # ---- 1) 重复键 -------------------------------------------------------
    def check_duplicate_keys(self):
        """⭐ JSON 允许重复键但后者覆盖前者 —— 真实 bug 来源，必须单独报。"""
        for obj_path, key, line in self.dups:
            where = obj_path
            if obj_path == "$.vars":
                where = "顶层 vars"
            elif obj_path.endswith(".vars") and obj_path.startswith("$.flow["):
                where = "%s 的 set.vars" % obj_path[:-5]
            self.err("E_SCHEMA", where,
                     "重复键 %r（第 %d 行）：JSON 规范下后者覆盖前者，前面的定义会被静默丢弃" % (key, line))

    def check_encoding_notes(self):
        if self.d.get("allowInsecureLocalhost") is True:
            self.warn("E_INSECURE", "$.allowInsecureLocalhost",
                      "为 true：§6.3 明确「该字段在正式插件中不得使用」，仅测试包可保留")
        # ---- v2.0：hooks 已启用（契约 §5.2.5）----
        # v1 时这里是「必须为 null」；v2.0 起 hooks 是 JS 沙箱配置对象。
        # 字段合法性由 JSON Schema 保证（additionalProperties:false），
        # 这里只做**语义**检查（白名单库、超时范围）。
        hooks = self.d.get("hooks", None)
        if isinstance(hooks, dict):
            libs = hooks.get("libs")
            if isinstance(libs, list):
                # 与 schema 的 enum 保持一致（白名单，不支持运行时安装）
                allowed = {"forge@1.4.0"}
                for i, lib in enumerate(libs):
                    if isinstance(lib, str) and lib not in allowed:
                        self.err(
                            "E_JS", "$.hooks.libs[%d]" % i,
                            "内置库 %r 不在白名单内（可选：%s）。"
                            "不支持运行时从网络安装依赖（供应链安全，契约 §5.2.5）"
                            % (lib, ", ".join(sorted(allowed))),
                        )
            tmo = hooks.get("timeoutMs")
            if isinstance(tmo, int) and not isinstance(tmo, bool):
                if tmo < 100 or tmo > 60000:
                    self.err("E_JS", "$.hooks.timeoutMs",
                             "超时必须在 100~60000 毫秒之间，实际 %d" % tmo)

    # ---- 2) 建索引 -------------------------------------------------------
    def index_steps(self):
        self.step_ids = []
        self.step_by_id = {}
        seen = {}
        for i, st in enumerate(self.flow):
            if not isinstance(st, dict):
                continue
            sid = st.get("id")
            if not isinstance(sid, str):
                continue
            if sid in seen:
                self.err("E_SCHEMA", "$.flow[%d].id" % i,
                         "step id %r 重复（首次出现在 $.flow[%d]）；flow 内 id 必须唯一" % (sid, seen[sid]))
            else:
                seen[sid] = i
            self.step_ids.append(sid)
            self.step_by_id[sid] = (i, st)

        # 每个步骤 extract 出的名字
        self.extracts = {}
        for i, st in enumerate(self.flow):
            if not isinstance(st, dict):
                continue
            sid = st.get("id")
            if not isinstance(sid, str):
                continue
            names = set()
            ex = st.get("extract")
            if isinstance(ex, list):
                local = {}
                for k, item in enumerate(ex):
                    if not isinstance(item, dict):
                        continue
                    nm = item.get("name")
                    if not isinstance(nm, str):
                        continue
                    if nm in local:
                        self.err("E_SCHEMA", "$.flow[%d].extract[%d].name" % (i, k),
                                 "extract name %r 在同一步骤内重复（首次出现在 extract[%d]）" % (nm, local[nm]))
                    local[nm] = k
                    names.add(nm)
            self.extracts[sid] = names

    def index_namespaces(self):
        """汇总所有可静态确定的命名空间成员。"""
        self.input_keys = set()
        for k, item in enumerate(self.inputs):
            if isinstance(item, dict) and isinstance(item.get("key"), str):
                key = item["key"]
                if key in self.input_keys:
                    self.err("E_SCHEMA", "$.inputs[%d].key" % k, "input key %r 重复" % key)
                self.input_keys.add(key)

        self.var_keys = set()
        if isinstance(self.top_vars, dict):
            self.var_keys |= set(self.top_vars.keys())
        for i, st in enumerate(self.flow):
            if not isinstance(st, dict):
                continue
            s = st.get("set")
            if isinstance(s, dict) and isinstance(s.get("vars"), dict):
                self.var_keys |= set(s["vars"].keys())
            # ---- v2.0：set.js 的 output 也会写入 vars（契约 §5.2.6）----
            # 此前只认 set.vars 的键，导致 {{vars.<js output>}} 被误判为 E_UNDEF。
            if isinstance(s, dict) and isinstance(s.get("js"), dict):
                js_out = s["js"].get("output")
                if isinstance(js_out, str) and js_out:
                    self.var_keys.add(js_out)
            ui = st.get("ui")
            if isinstance(ui, dict) and isinstance(ui.get("input"), str):
                self.input_keys.add(ui["input"])  # ui 步骤会写入 input 命名空间

        # 可静态解析的 vars 字面量（用于 url host 检查）
        self.vars_literal = {}
        if isinstance(self.top_vars, dict):
            for k, v in self.top_vars.items():
                if isinstance(v, str) and "{{" not in v:
                    self.vars_literal[k] = v

    # ---- 3) allowHosts ---------------------------------------------------
    def check_allow_hosts(self):
        if not isinstance(self.allow_hosts, list):
            return
        seen = set()
        for k, h in enumerate(self.allow_hosts):
            p = "$.allowHosts[%d]" % k
            if not isinstance(h, str):
                continue
            if h != h.lower():
                self.err("E_HOST", p,
                         "%r 含大写字母：§6.1 要求校验用「小写精确匹配」，白名单请写小写" % h)
            if "://" in h:
                self.err("E_HOST", p, "%r 含 scheme：allowHosts 只写 host 或 host:port" % h)
            if "/" in h or "?" in h or "#" in h:
                self.err("E_HOST", p, "%r 含路径/查询串：allowHosts 不允许路径" % h)
            if "*" in h:
                self.err("E_HOST", p, "%r 含通配符：§6.1 明确不支持子域通配" % h)
            if not HOST_RE.match(h):
                self.err("E_HOST", p, "%r 不是合法的 host 或 host:port" % h)
            if h in seen:
                self.warn("E_HOST", p, "%r 重复出现" % h)
            seen.add(h)

    # ---- 4) inputs -------------------------------------------------------
    def check_inputs(self):
        for k, item in enumerate(self.inputs):
            if not isinstance(item, dict):
                continue
            p = "$.inputs[%d]" % k
            pat = item.get("pattern")
            if isinstance(pat, str):
                try:
                    re.compile(pat)
                except re.error as e:
                    self.err("E_SCHEMA", p + ".pattern", "正则无法编译：%s" % e)
            mn, mx = item.get("minLength"), item.get("maxLength")
            if isinstance(mn, int) and isinstance(mx, int) and mn > mx:
                self.err("E_SCHEMA", p, "minLength(%d) > maxLength(%d)" % (mn, mx))
            if item.get("type") == "select":
                opts = item.get("options")
                if not isinstance(opts, list) or not opts:
                    self.err("E_SCHEMA", p + ".options",
                             "type=select 必须有非空 options（§2：type=select ⟺ 有 options 且非空）")
                else:
                    vals = [o.get("value") for o in opts if isinstance(o, dict)]
                    if len(vals) != len(set(map(str, vals))):
                        self.warn("E_SCHEMA", p + ".options", "option.value 存在重复")

    # ---- 5) vars 对象 ----------------------------------------------------
    def check_vars_object(self, obj, path, top_level=False, enclosing=None):
        """检查一个 vars 对象：键名合法性、同对象内的求值顺序（§3.4）。"""
        if not isinstance(obj, dict):
            return
        enclosing = set(enclosing or ())
        keys = list(obj.keys())
        for k in keys:
            if not IDENT_RE.match(k):
                self.err("E_SCHEMA", "%s.%s" % (path, k),
                         "变量名 %r 不匹配 ^[a-zA-Z_][a-zA-Z0-9_]*$" % k)
        for idx, k in enumerate(keys):
            v = obj[k]
            if not isinstance(v, str):
                continue
            local_prior = set(keys[:idx])
            self.check_template(
                v, "%s.%s" % (path, k),
                scope={"vars_prior": local_prior | enclosing},
                where="vars",
            )

    # ---- 6) flow ---------------------------------------------------------
    def check_flow(self):
        for i, st in enumerate(self.flow):
            if not isinstance(st, dict):
                continue
            base = "$.flow[%d]" % i
            sid = st.get("id") if isinstance(st.get("id"), str) else "<step%d>" % i
            label = "%s(id=%s)" % (base, sid)

            # 引用类字段
            self.check_ref(st.get("goto"), base + ".goto", sid)
            for k, b in enumerate(st.get("branch") or []):
                if not isinstance(b, dict):
                    continue
                self.check_expr(b.get("when"), "%s.branch[%d].when" % (base, k), where="when")
                self.check_ref(b.get("goto"), "%s.branch[%d].goto" % (base, k), sid)
            self.check_on_fail(st.get("onFail"), base + ".onFail", sid)
            if isinstance(st.get("when"), str):
                self.check_expr(st["when"], base + ".when", where="when")

            t = st.get("type")
            if t == "request":
                self.check_request(st, base, sid)
            elif t == "poll":
                self.check_poll(st, base, sid)
            elif t == "ui":
                self.check_ui(st, base, sid)
            elif t == "set":
                self.check_set(st, base, sid)

    def check_ref(self, target, path, owner):
        if target is None or target == "next":
            return
        if not isinstance(target, str):
            return
        if target not in self.step_by_id:
            self.err("E_GOTO", path,
                     "%s 引用了不存在的 step id %r（E_GOTO）；现有 id：%s"
                     % (owner, target, ", ".join(self.step_ids) or "无"))

    def check_on_fail(self, of, path, sid):
        if not isinstance(of, dict):
            return
        if "message" in of and "goto" in of:
            self.err("E_SCHEMA", path, "onFail 的 message 与 goto 互斥（§4.6）")
        if isinstance(of.get("message"), str):
            self.check_template(of["message"], path + ".message",
                                scope={"allow_response": True}, where="onFail")
        self.check_ref(of.get("goto"), path + ".goto", sid)

    def check_request(self, st, base, sid):
        req = st.get("request")
        if not isinstance(req, dict):
            return
        rp = base + ".request"
        self.check_template(req.get("url"), rp + ".url", where="url")
        self.check_url_host(req.get("url"), rp + ".url")
        for name, obj in (("headers", req.get("headers")), ("query", req.get("query"))):
            if isinstance(obj, dict):
                for k, v in obj.items():
                    self.check_template(v, "%s.%s.%s" % (rp, name, k), where=name)

        body = req.get("body")
        if isinstance(body, dict):
            if req.get("method") == "GET":
                self.err("E_SCHEMA", rp + ".body", "GET 请求禁止出现 body（§4.2）")
            self.check_template_tree(body.get("value"), rp + ".body.value", where="body")

        for k, item in enumerate(st.get("extract") or []):
            if not isinstance(item, dict):
                continue
            ep = "%s.extract[%d]" % (base, k)
            fr = item.get("from")
            if fr == "json":
                self.check_jsonpath(item.get("path"), ep + ".path")
            elif fr == "header":
                h = item.get("header")
                if isinstance(h, str) and (" " in h or h != h.strip()):
                    self.err("E_SCHEMA", ep + ".header", "响应头名 %r 含空白字符" % h)
            elif fr == "regex":
                self.check_regex(item.get("pattern"), ep + ".pattern")
                g = item.get("group")
                if isinstance(g, int) and isinstance(item.get("pattern"), str):
                    try:
                        n = re.compile(item["pattern"]).groups
                        if g > n:
                            self.err("E_EXTRACT", ep + ".group",
                                     "group=%d 超出正则的捕获组数量 %d" % (g, n))
                    except re.error:
                        pass
            elif fr == "binary":
                enc = item.get("encoding")
                ln = item.get("length")
                if enc == "be32" and ln != 4:
                    self.err("E_EXTRACT", ep,
                             "encoding=be32 时 length 必须为 4（§4.7），实际为 %r" % (ln,))
                if enc in ("ascii", "utf8", "hex") and isinstance(ln, int) and ln <= 0:
                    self.err("E_EXTRACT", ep, "encoding=%s 时 length 必须为正整数" % enc)
                tag = item.get("tag")
                if isinstance(tag, str) and len(tag) % 2 != 0:
                    self.err("E_EXTRACT", ep + ".tag", "tag 的 hex 长度必须为偶数")
                if item.get("optional") and "default" not in item:
                    self.warn("E_EXTRACT", ep, "optional=true 但未给 default，提取失败时值为 null")

        a = st.get("assert")
        if isinstance(a, dict):
            self.check_jsonpath(a.get("json"), base + ".assert.json")
            for key in ("equals", "notEquals", "contains"):
                if key in a:
                    self.check_template(a[key], "%s.assert.%s" % (base, key), where="assert")
            if "matches" in a:
                self.check_regex(a["matches"], base + ".assert.matches")

    def check_poll(self, st, base, sid):
        poll = st.get("poll")
        if not isinstance(poll, dict):
            return
        pp = base + ".poll"
        subs = poll.get("steps")
        if isinstance(subs, list):
            if not (1 <= len(subs) <= 5):
                self.err("E_SCHEMA", pp + ".steps", "poll.steps 长度必须在 1..5，实际 %d" % len(subs))
            for k, t in enumerate(subs):
                self.check_ref(t, "%s.steps[%d]" % (pp, k), sid)
                if t == sid:
                    self.warn("E_LOOP", "%s.steps[%d]" % (pp, k),
                              "poll 的 steps 里包含它自己 %r，可能造成死循环" % t)
        self.check_expr(poll.get("until"), pp + ".until", where="until")
        self.check_on_fail(poll.get("onTimeout"), pp + ".onTimeout", sid)

    def check_ui(self, st, base, sid):
        ui = st.get("ui")
        if not isinstance(ui, dict):
            return
        up = base + ".ui"
        ut = ui.get("type")
        if ut == "image":
            if not ui.get("image"):
                self.err("E_SCHEMA", up, "ui.type=image 时 image 必需（§4.4）")
            self.check_template(ui.get("image"), up + ".image", where="ui")
        elif ut == "webview":
            self.check_ui_webview(ui, up, sid)
        elif "refreshStep" in ui:
            self.err("E_SCHEMA", up + ".refreshStep",
                     "refreshStep 仅 type=image 可用（§4.4）")
        if "refreshStep" in ui:
            self.check_ref(ui.get("refreshStep"), up + ".refreshStep", sid)
        if isinstance(ui.get("pattern"), str):
            self.check_regex(ui["pattern"], up + ".pattern")
        inp = ui.get("input")
        if isinstance(inp, str) and not IDENT_RE.match(inp):
            self.err("E_SCHEMA", up + ".input",
                     "ui.input %r 不匹配 ^[a-zA-Z_][a-zA-Z0-9_]*$" % inp)

    # §4.4.1 webview（v1.2 新增）—— 结构互斥已由 schema 表达，
    # 这里补 schema 表达不了的部分：模板扫描、url/baseUrl 的 host 白名单、
    # 「不适用字段」的可读原因、bridge 标识符校验。
    def check_ui_webview(self, ui, up, sid):
        has_url = "url" in ui
        has_html = "html" in ui

        # ① url 与 html 恰好一个
        if has_url and has_html:
            self.err("E_SCHEMA", up,
                     "ui.type=webview 的 url 与 html 必须恰好一个，不能同时给出（§4.4.1）")
        elif not has_url and not has_html:
            self.err("E_SCHEMA", up,
                     "ui.type=webview 必须给出 url 或 html 之一，两者都没有（§4.4.1）")

        # ② html 出现时 baseUrl 必需
        if has_html and not ui.get("baseUrl"):
            self.err("E_SCHEMA", up + ".baseUrl",
                     "ui.html 出现时 baseUrl 必需（§4.4.1）：它决定相对路径与同源策略")

        # ③ 模板扫描（html / url / baseUrl 都是模板字符串）
        for k in ("html", "url", "baseUrl"):
            if k in ui:
                self.check_template(ui.get(k), "%s.%s" % (up, k), where="ui")

        # ④ host 白名单：§4.4.1 明确「引擎只校验 url 的 host 与 baseUrl 是否在 allowHosts 内」。
        #    注意：HTML 内引用的外部子资源（script/css/XHR）的 host **不在**强制拦截范围，
        #    由插件作者在 allowHosts 里自行声明（契约原文如此）。
        if has_url:
            self.check_url_host(ui.get("url"), up + ".url")
        if "baseUrl" in ui:
            self.check_url_host(ui.get("baseUrl"), up + ".baseUrl")

        # ⑤ 不适用字段（§4.4.1 约束表）
        for k, why in (("image", "值来自 JS 回传，非图片输入"),
                       ("refreshStep", "webview 没有刷新语义"),
                       ("maxLength", "值来自 JS 回传，非用户输入"),
                       ("pattern", "值来自 JS 回传，非用户输入")):
            if k in ui:
                self.err("E_SCHEMA", "%s.%s" % (up, k),
                         "ui.type=webview 不适用 %s（§4.4.1：%s）" % (k, why))

        # ⑥ bridge 标识符
        b = ui.get("bridge")
        if isinstance(b, str) and not IDENT_RE.match(b):
            self.err("E_SCHEMA", up + ".bridge",
                     "ui.bridge %r 不匹配 ^[A-Za-z_][A-Za-z0-9_]*$（§4.4.1）" % b)

    def check_set(self, st, base, sid):
        s = st.get("set")
        if not isinstance(s, dict):
            return
        vs = s.get("vars")
        if isinstance(vs, dict):
            self.check_vars_object(vs, base + ".set.vars", enclosing=self.var_keys)

    # ---- 7) output -------------------------------------------------------
    def check_output(self):
        out = self.d.get("output")
        if not isinstance(out, dict):
            return
        fields = out.get("fields")
        if not isinstance(fields, list):
            return
        for k, f in enumerate(fields):
            if not isinstance(f, dict):
                continue
            self.check_template(f.get("value"), "$.output.fields[%d].value" % k, where="output")

    # ---- 8) 可达性（warning） -------------------------------------------
    def check_reachability(self):
        if not self.step_ids:
            return
        idx = {}
        for i, st in enumerate(self.flow):
            if isinstance(st, dict) and isinstance(st.get("id"), str):
                idx.setdefault(st["id"], i)
        order = [st.get("id") for st in self.flow if isinstance(st, dict)]
        seen = set()
        stack = [0]
        while stack:
            i = stack.pop()
            if i in seen or not (0 <= i < len(self.flow)):
                continue
            seen.add(i)
            st = self.flow[i]
            if not isinstance(st, dict):
                continue
            nxt = []
            for b in st.get("branch") or []:
                if isinstance(b, dict) and b.get("goto") in idx:
                    nxt.append(idx[b["goto"]])
            g = st.get("goto")
            if isinstance(g, str) and g != "next" and g in idx:
                nxt.append(idx[g])
            elif i + 1 < len(self.flow):
                nxt.append(i + 1)
            of = st.get("onFail")
            if isinstance(of, dict) and of.get("goto") in idx:
                nxt.append(idx[of["goto"]])
            poll = st.get("poll")
            if isinstance(poll, dict):
                for t in poll.get("steps") or []:
                    if t in idx:
                        nxt.append(idx[t])
                nxt.append(i + 1)
            stack.extend(nxt)
        for i, st in enumerate(self.flow):
            if i not in seen and isinstance(st, dict):
                self.warn("E_LOOP", "$.flow[%d](id=%s)" % (i, st.get("id")),
                          "该步骤从 flow[0] 出发不可达（无 goto/branch 指向它，也不会顺序执行到）")

    # ---- 9) 模板 / 表达式 ------------------------------------------------
    def check_template_tree(self, v, path, where="value"):
        """递归检查 object/array 里的模板字符串。"""
        if isinstance(v, str):
            self.check_template(v, path, where=where)
        elif isinstance(v, dict):
            for k, x in v.items():
                self.check_template_tree(x, "%s.%s" % (path, k), where=where)
        elif isinstance(v, list):
            for k, x in enumerate(v):
                self.check_template_tree(x, "%s[%d]" % (path, k), where=where)

    def check_template(self, s, path, scope=None, where="value"):
        """⭐ 模板静态解析：{{ }} 里的路径 / 函数名是否真实存在。"""
        if not isinstance(s, str) or "{{" not in s:
            return
        scope = scope or {}
        bodies, errs = find_templates(s)
        for e in errs:
            self.err("E_TEMPLATE", path, e)
        for body in bodies:
            self.stats["templates"] += 1
            expr = body.strip()
            if expr == "":
                self.err("E_TEMPLATE", path, "空的模板表达式 {{}}")
                continue
            self.check_expr(expr, path, scope=scope, where=where, in_template=True)

    def check_expr(self, src, path, scope=None, where="expr", in_template=False):
        if not isinstance(src, str):
            return
        scope = scope or {}
        self.stats["exprs"] += 1
        try:
            ast = ExprParser(src).parse()
        except ExprError as e:
            self.err("E_TEMPLATE", path, "表达式语法错误：%s（原文 %r）" % (e, src))
            return

        self._walk_refs(ast, path, scope)

        t = infer_type(ast)
        if in_template and t == "bytes":
            self.err("E_TYPE", path,
                     "顶层表达式返回 bytes，不能直接渲染为字符串（§3.1），"
                     "请用 fn.b64 / fn.hex / fn.latin1 转换：%r" % src)
        if where in ("when", "until") and t in ("int", "double", "string", "null", "bytes"):
            self.err("E_TYPE", path,
                     "%s 的顶层表达式必须求值为 bool（§5.1），静态推断为 %s：%r" % (where, t, src))

    def _walk_refs(self, ast, path, scope):
        def visit(node):
            if node[0] == "path":
                self.check_path(node[1], node[2], path, scope)
            elif node[0] == "call":
                self.check_call(node, path)
        walk_expr(ast, visit)

    def check_path(self, raw, segs, path, scope):
        if not segs:
            return
        root = segs[0]
        if root == "input":
            if len(segs) < 2:
                self.err("E_UNDEF", path, "路径 %r 不完整：应为 input.<key>" % raw)
            elif segs[1] not in self.input_keys:
                self.err("E_UNDEF", path,
                         "引用了不存在的 input.%s（E_UNDEF）；已声明：%s"
                         % (segs[1], ", ".join(sorted(self.input_keys)) or "无"))
        elif root == "vars":
            if len(segs) < 2:
                self.err("E_UNDEF", path, "路径 %r 不完整：应为 vars.<key>" % raw)
            elif segs[1] not in self.var_keys:
                self.err("E_UNDEF", path,
                         "引用了不存在的 vars.%s（E_UNDEF）；已声明：%s"
                         % (segs[1], ", ".join(sorted(self.var_keys)) or "无"))
            else:
                prior = scope.get("vars_prior")
                if prior is not None and segs[1] not in prior:
                    self.err("E_UNDEF", path,
                             "vars.%s 在声明之前被引用：§3.4 规定 vars 按声明顺序求值，"
                             "后面的键才能引用前面的键" % segs[1])
        elif root == "steps":
            if len(segs) < 3:
                self.err("E_UNDEF", path, "路径 %r 不完整：应为 steps.<stepId>.<name>" % raw)
                return
            sid, name = segs[1], segs[2]
            if sid not in self.step_by_id:
                self.err("E_UNDEF", path,
                         "引用了不存在的 step id %r（E_UNDEF）；现有 id：%s"
                         % (sid, ", ".join(self.step_ids) or "无"))
            elif name not in self.extracts.get(sid, set()):
                self.err("E_UNDEF", path,
                         "step %r 没有名为 %r 的 extract（E_UNDEF）；它有：%s"
                         % (sid, name, ", ".join(sorted(self.extracts.get(sid, set()))) or "无"))
        elif root == "env":
            if len(segs) < 2:
                self.err("E_UNDEF", path, "路径 %r 不完整：应为 env.<key>" % raw)
            elif segs[1] not in ENV_KEYS:
                self.err("E_UNDEF", path,
                         "未知的 env 键 %r；§3.3 只有：%s" % (segs[1], ", ".join(sorted(ENV_KEYS))))
        elif root == "secrets":
            if len(segs) < 2:
                self.err("E_UNDEF", path, "路径 %r 不完整：应为 secrets.<key>" % raw)
            elif segs[1] not in self.secrets:
                self.err("E_UNDEF", path,
                         "引用了未在顶层 secrets 声明的 secrets.%s" % segs[1])
        elif root == "response":
            if not scope.get("allow_response"):
                self.err("E_UNDEF", path,
                         "{{response.*}} 仅在 onFail 内可用（§4.6）：%r" % raw)
            elif len(segs) < 2 or segs[1] != "message":
                self.err("E_UNDEF", path, "response 只提供 response.message：%r" % raw)
        else:
            self.err("E_UNDEF", path,
                     "未知命名空间 %r（E_UNDEF）：合法根只有 input / vars / steps / env / secrets / fn" % root)

    def check_call(self, node, path):
        ns, name, args = node[1], node[2], node[3]
        if ns != "fn":
            self.err("E_UNDEF", path,
                     "函数命名空间必须是 fn（§5.1），实际为 %r：%s" % (ns, node[4]))
            return
        spec = FN_SPECS.get(name)
        if spec is None:
            near = closest(name, list(FN_SPECS.keys()))
            hint = "（是否想写 fn.%s？）" % near if near else ""
            self.err("E_UNDEF", path,
                     "未知函数 fn.%s%s；CONTRACT.md §5.2 函数库共 %d 个"
                     % (name, hint, len(FN_SPECS)))
            return
        lo, hi, _ = spec
        if not (lo <= len(args) <= hi):
            want = str(lo) if lo == hi else ("%d..%s" % (lo, "N" if hi >= 99 else hi))
            self.err("E_ARG", path,
                     "fn.%s 需要 %s 个参数，实际给了 %d 个：%s" % (name, want, len(args), node[4]))

    # ---- 10) jsonpath / regex / url --------------------------------------
    def check_jsonpath(self, p, path):
        if not isinstance(p, str):
            return
        if not p.startswith("$"):
            self.err("E_EXTRACT", path, "JSONPath 必须以 $ 开头（§4.8）：%r" % p)
            return
        if not JSONPATH_RE.match(p):
            self.err("E_EXTRACT", path,
                     "JSONPath 只支持 $ / .key / [n]（§4.8），不支持通配/递归/过滤器/切片：%r" % p)

    def check_regex(self, pat, path):
        if not isinstance(pat, str):
            return
        try:
            re.compile(pat)
        except re.error as e:
            self.err("E_SCHEMA", path, "正则无法编译：%s（%r）" % (e, pat))

    def check_url_host(self, tmpl, path):
        """静态解析 url 模板，检查 scheme 与 allowHosts（§6.1 / §6.3）。"""
        if not isinstance(tmpl, str):
            return
        resolved, complete = self.static_resolve(tmpl)
        if resolved is None:
            return
        if not complete:
            self.warn("E_HOST", path,
                      "url 含无法静态解析的模板，host 白名单需运行期校验：%r" % tmpl)
            return
        m = re.match(r"^([A-Za-z][A-Za-z0-9+.\-]*)://([^/?#]*)", resolved)
        if not m:
            self.warn("E_HOST", path, "无法从 %r 解析出 scheme/host" % resolved)
            return
        self.stats["urls"] += 1
        scheme = m.group(1).lower()
        hostport = m.group(2).lower()
        host = hostport.split(":")[0] if not hostport.startswith("[") else hostport
        if scheme == "http":
            if self.d.get("allowInsecureLocalhost") is True and host in LOCALHOSTS:
                self.warn("E_INSECURE", path, "明文 HTTP 但 allowInsecureLocalhost=true 且 host 为本地回环")
            else:
                self.err("E_INSECURE", path,
                         "明文 HTTP 被禁止（§6.3）：%r；只有 allowInsecureLocalhost=true "
                         "且 host ∈ {127.0.0.1, localhost, ::1} 才放行" % resolved)
        elif scheme != "https":
            self.err("E_INSECURE", path, "url scheme 必须是 https，实际为 %r" % scheme)
        allowed = set(h.lower() for h in self.allow_hosts if isinstance(h, str))
        if hostport not in allowed:
            self.err("E_HOST", path,
                     "host %r 不在 allowHosts（E_HOST）；白名单：%s"
                     % (hostport, ", ".join(sorted(allowed)) or "空"))

    def static_resolve(self, tmpl):
        """把 {{vars.X}} 换成字面量；其他模板换成 \\x00。返回 (文本, 是否全部可解析)。"""
        out, i, n = [], 0, len(tmpl)
        complete = True
        while i < n:
            if tmpl.startswith("\\{\\{", i):
                out.append("{{")
                i += 4
                continue
            if tmpl.startswith("{{", i):
                j = tmpl.find("}}", i + 2)
                if j < 0:
                    return None, False
                expr = tmpl[i + 2:j].strip()
                m = re.fullmatch(r"vars\.([A-Za-z_][A-Za-z0-9_]*)", expr)
                lit = self.vars_literal.get(m.group(1)) if m else None
                if isinstance(lit, str) and "{{" not in lit:
                    out.append(lit)
                else:
                    out.append("\x00")
                    complete = False
                i = j + 2
                continue
            out.append(tmpl[i])
            i += 1
        return "".join(out), complete


# ===========================================================================
# 6. 单文件校验入口
# ===========================================================================
class FileReport(object):
    def __init__(self, path):
        self.path = path
        self.errors = []
        self.warnings = []
        self.schema_errors = []
        self.semantic_errors = []
        self.parse_error = None
        self.stats = {}

    @property
    def ok(self):
        return not self.errors


def load_manifest(path):
    """读文件 + BOM/编码检查。返回 (文本, 错误列表)。"""
    errs = []
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError as e:
        return None, ["无法读取文件：%s" % e]
    if raw.startswith(b"\xef\xbb\xbf"):
        errs.append("文件带 UTF-8 BOM；§0 要求 UTF-8 无 BOM")
        raw = raw[3:]
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as e:
        errs.append("不是合法 UTF-8：%s" % e)
        return None, errs
    return text, errs


def validate_file(path, schema, seen_ids=None):
    rep = FileReport(path)
    text, enc_errs = load_manifest(path)
    if text is None:
        rep.errors = enc_errs
        rep.parse_error = enc_errs[0] if enc_errs else "读取失败"
        return rep

    try:
        data, dups = JsonParser(text).parse()
    except JsonParseError as e:
        rep.errors = list(enc_errs) + ["JSON 解析失败：%s" % e]
        rep.parse_error = str(e)
        return rep

    rep.errors.extend(enc_errs)
    if not isinstance(data, dict):
        rep.errors.append("顶层必须是 object，实际为 %s" % jtype(data))
        return rep

    # --- schema 层 ---
    sv = SchemaValidator(schema)
    rep.schema_errors = sv.check(data, schema, "$")
    rep.errors.extend(rep.schema_errors)

    # --- 语义层 ---
    checker = ManifestChecker(data, dups, path).run()
    rep.semantic_errors = ["[%s] %s：%s" % (c, p, m) for c, p, m in checker.errors]
    rep.errors.extend(rep.semantic_errors)
    rep.warnings = ["[%s] %s：%s" % (c, p, m) for c, p, m in checker.warnings]
    rep.stats = checker.stats

    # --- 跨文件 id 查重 ---
    if seen_ids is not None:
        pid = data.get("id")
        if isinstance(pid, str):
            if pid in seen_ids:
                msg = "插件 id %r 与 %s 重复（批量导入时 id 必须唯一）" % (pid, seen_ids[pid])
                rep.semantic_errors.append(msg)
                rep.errors.append(msg)
            else:
                seen_ids[pid] = path
    return rep


# ===========================================================================
# 7. CLI
# ===========================================================================
def collect_dir(dirpath):
    """收集 <dir>/*/manifest.json（跳过以 _ 开头的目录）。"""
    found = []
    if not os.path.isdir(dirpath):
        return found
    for name in sorted(os.listdir(dirpath)):
        if name.startswith("_") or name.startswith("."):
            continue
        sub = os.path.join(dirpath, name)
        if not os.path.isdir(sub):
            continue
        mf = os.path.join(sub, "manifest.json")
        if os.path.isfile(mf):
            found.append(mf)
    return found


def print_report(rep, verbose=True):
    print("─" * 78)
    print("文件：%s" % rep.path)
    if rep.ok and not rep.warnings:
        print("  结果：✅ 通过")
    elif rep.ok:
        print("  结果：✅ 通过（%d 条警告）" % len(rep.warnings))
    else:
        print("  结果：❌ 失败（%d 个错误）" % len(rep.errors))
    st = rep.stats or {}
    if st:
        print("  统计：模板 %d 个 / 表达式 %d 个 / 静态校验 URL %d 个"
              % (st.get("templates", 0), st.get("exprs", 0), st.get("urls", 0)))
    if rep.errors:
        print("  错误：")
        for e in rep.errors:
            print("    - %s" % e)
    if rep.warnings and verbose:
        print("  警告（不影响退出码）：")
        for w in rep.warnings:
            print("    - %s" % w)


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="validate.py",
        description="登录插件 manifest 校验器（零依赖；schema + 语义两层检查）")
    ap.add_argument("path", nargs="?", help="要校验的 manifest.json 路径")
    ap.add_argument("--dir", dest="dirpath", help="批量校验该目录下每个子目录里的 manifest.json")
    ap.add_argument("--schema", default=DEFAULT_SCHEMA, help="schema 文件路径（默认同目录 manifest.schema.json）")
    ap.add_argument("--quiet-warnings", action="store_true", help="不打印警告明细")
    args = ap.parse_args(argv)

    if not args.path and not args.dirpath:
        ap.print_help()
        return 2

    try:
        with open(args.schema, "r", encoding="utf-8") as f:
            schema = json.load(f)
    except Exception as e:
        print("无法加载 schema %s：%s" % (args.schema, e))
        return 2

    targets = []
    if args.dirpath:
        targets = collect_dir(args.dirpath)
        if not targets:
            print("目录 %s 下没有找到任何 */manifest.json" % args.dirpath)
            return 2
    if args.path:
        targets.append(args.path)

    seen_ids = {}
    reports = [validate_file(p, schema, seen_ids) for p in targets]

    print("=" * 78)
    print("登录插件 manifest 校验报告")
    print("schema：%s" % args.schema)
    print("目标：%d 个 manifest" % len(reports))
    print("=" * 78)

    for rep in reports:
        print_report(rep, verbose=not args.quiet_warnings)

    n_ok = sum(1 for r in reports if r.ok)
    n_bad = len(reports) - n_ok
    n_warn = sum(len(r.warnings) for r in reports)
    n_err = sum(len(r.errors) for r in reports)

    print("=" * 78)
    print("汇总：%d 个文件，通过 %d，失败 %d；错误 %d 条，警告 %d 条"
          % (len(reports), n_ok, n_bad, n_err, n_warn))
    if n_bad:
        print("失败文件：")
        for r in reports:
            if not r.ok:
                print("  - %s" % r.path)
    print("退出码：%d" % (1 if n_bad else 0))
    return 1 if n_bad else 0


if __name__ == "__main__":
    sys.exit(main())
