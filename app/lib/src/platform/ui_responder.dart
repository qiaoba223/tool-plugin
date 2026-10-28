import 'package:flutter/material.dart';
import 'package:plugin_engine/plugin_engine.dart';

import '../widgets/ui_prompt.dart';

/// 把引擎的 `ui` 步骤映射成 Flutter 对话框。
///
/// 引擎只负责「需要问用户什么」，长什么样由宿主决定。
/// 用户取消时返回 [UiCancelled] 哨兵（引擎据此走 cancel 分支），
/// 而不是抛异常——异常会被当成引擎故障。
class DialogUiResponder implements UiResponder {
  DialogUiResponder({this.navigatorKey});

  /// 用于在没有 BuildContext 的地方弹窗。
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Future<Object?> ask(UiSpec spec, Scope scope) async {
    final ctx = navigatorKey?.currentContext;
    if (ctx == null) {
      throw PluginError(
        ErrorCodes.end,
        '无法显示输入界面（没有可用的 Navigator），请在前台运行',
        stepId: spec.input,
      );
    }
    final v = await showUiPrompt(ctx, spec);
    return v ?? const UiCancelled();
  }
}
