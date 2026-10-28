/// set.js 沙箱的 AST 定义。
///
/// 刻意只用一层抽象：解释器直接对 AST 求值，不做字节码编译，
/// 这样错误定位能精确到行号，也便于超时中断时报告当前位置。
library;

/// 表达式节点。
abstract class Expr {
  final int line;
  const Expr(this.line);
}

class NumLit extends Expr {
  final num value;
  const NumLit(this.value, super.line);
}

class StrLit extends Expr {
  final String value;
  const StrLit(this.value, super.line);
}

class BoolLit extends Expr {
  final bool value;
  const BoolLit(this.value, super.line);
}

class NullLit extends Expr {
  const NullLit(super.line);
}

class UndefinedLit extends Expr {
  const UndefinedLit(super.line);
}

class ThisExpr extends Expr {
  const ThisExpr(super.line);
}

class Ident extends Expr {
  final String name;
  const Ident(this.name, super.line);
}

/// 一元：`-x` `+x` `!x` `~x` `typeof x` `void x` `delete x` `++x` `--x`
class Unary extends Expr {
  final String op;
  final Expr operand;
  final bool prefix; // false 表示后缀 `x++`
  const Unary(this.op, this.operand, int line, {this.prefix = true})
      : super(line);
}

/// 二元运算（含赋值、逻辑、位运算、比较、`instanceof`、`in`）。
class Binary extends Expr {
  final String op;
  final Expr left;
  final Expr right;
  const Binary(this.op, this.left, this.right, int line) : super(line);
}

/// 三元 `a ? b : c`
class Cond extends Expr {
  final Expr test;
  final Expr thenExpr;
  final Expr elseExpr;
  const Cond(this.test, this.thenExpr, this.elseExpr, int line) : super(line);
}

/// 成员访问：`obj.name` / `obj[expr]`
class Member extends Expr {
  final Expr object;
  final Expr property; // StrLit 或任意表达式
  final bool computed;
  const Member(this.object, this.property, int line, {required this.computed})
      : super(line);
}

/// 函数调用：`callee(args)`
class Call extends Expr {
  final Expr callee;
  final List<Expr> args;
  const Call(this.callee, this.args, int line) : super(line);
}

/// `new Callee(args)`（无参时 args 为空）
class New extends Expr {
  final Expr callee;
  final List<Expr> args;
  const New(this.callee, this.args, int line) : super(line);
}

/// 数组字面量 `[a, b, , c]`（洞用 null 表示）
class ArrayLit extends Expr {
  final List<Expr?> items;
  const ArrayLit(this.items, int line) : super(line);
}

/// 对象字面量 `{a: 1, 'b': 2, [k]: 3}`
class ObjectLit extends Expr {
  final List<ObjectProp> props;
  const ObjectLit(this.props, int line) : super(line);
}

class ObjectProp {
  final Expr key; // StrLit / NumLit / 计算键表达式
  final bool computed;
  final Expr value;
  const ObjectProp(this.key, this.value, {required this.computed});
}

/// 函数表达式 / 函数声明共用的函数体描述。
class FuncLit extends Expr {
  final String? name;
  final List<String> params;
  final List<Stmt> body;
  const FuncLit(this.params, this.body, int line, {this.name}) : super(line);
}

// ---------------------------------------------------------------------------
// 语句
// ---------------------------------------------------------------------------

abstract class Stmt {
  final int line;
  const Stmt(this.line);
}

class Block extends Stmt {
  final List<Stmt> body;
  const Block(this.body, int line) : super(line);
}

class VarDecl extends Stmt {
  /// 每个元素是 (变量名, 初始化表达式或 null)
  final List<(String, Expr?)> decls;
  const VarDecl(this.decls, int line) : super(line);
}

class FuncDecl extends Stmt {
  final FuncLit fn;
  const FuncDecl(this.fn, int line) : super(line);
}

class ExprStmt extends Stmt {
  final Expr expr;
  const ExprStmt(this.expr, int line) : super(line);
}

class IfStmt extends Stmt {
  final Expr test;
  final Stmt consequent;
  final Stmt? alternate;
  const IfStmt(this.test, this.consequent, int line, {this.alternate})
      : super(line);
}

class WhileStmt extends Stmt {
  final Expr test;
  final Stmt body;
  const WhileStmt(this.test, this.body, int line) : super(line);
}

class DoWhileStmt extends Stmt {
  final Stmt body;
  final Expr test;
  const DoWhileStmt(this.body, this.test, int line) : super(line);
}

class ForStmt extends Stmt {
  final Stmt? init; // VarDecl 或 ExprStmt
  final Expr? test;
  final Expr? update;
  final Stmt body;
  const ForStmt(this.init, this.test, this.update, this.body, int line)
      : super(line);
}

/// `for (var k in obj)` / `for (k in obj)`
class ForInStmt extends Stmt {
  final String? varName; // 非 null 表示 `var k in`
  final Expr? target; // varName 为 null 时的赋值目标（Ident/Member）
  final Expr object;
  final Stmt body;
  const ForInStmt(this.varName, this.target, this.object, this.body, int line)
      : super(line);
}

class ReturnStmt extends Stmt {
  final Expr? value;
  const ReturnStmt(this.value, int line) : super(line);
}

class BreakStmt extends Stmt {
  const BreakStmt(super.line);
}

class ContinueStmt extends Stmt {
  const ContinueStmt(super.line);
}

class ThrowStmt extends Stmt {
  final Expr value;
  const ThrowStmt(this.value, int line) : super(line);
}

class TryStmt extends Stmt {
  final Block block;
  final String? catchParam;
  final Block? catchBlock;
  final Block? finallyBlock;
  const TryStmt(this.block, this.catchParam, this.catchBlock,
      this.finallyBlock, int line)
      : super(line);
}

/// `switch` —— 规范未承诺，但解析器认识它以便给出明确报错。
class EmptyStmt extends Stmt {
  const EmptyStmt(super.line);
}
