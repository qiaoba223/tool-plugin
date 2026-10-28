/// 插件宿主的平台无关层。
///
/// 只放**不依赖 Flutter** 的逻辑：插件库访问、表单校验规则。
/// 依赖 Flutter 的状态管理（ChangeNotifier 等）留在 app 层。
library plugin_ui_core;

export 'src/form_model.dart';
export 'src/plugin_repo.dart';
