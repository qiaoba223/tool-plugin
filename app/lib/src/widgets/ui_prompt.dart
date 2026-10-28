import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_engine/plugin_engine.dart';

/// 按 [UiSpec] 弹出对应的输入界面，返回用户填入的值；取消返回 null。
///
/// 覆盖引擎支持的 5 种控件：text / confirm / select / image / webview。
/// 其中 image 与 webview 需要截图或网页交互，宿主未接入时明确提示，
/// 而不是假装成功——静默返回空值会让插件拿到错误凭据却继续往下跑。
Future<Object?> showUiPrompt(BuildContext context, UiSpec spec) async {
  switch (spec.type) {
    case UiType.text:
      return _text(context, spec);
    case UiType.confirm:
      return _confirm(context, spec);
    case UiType.select:
      return _select(context, spec);
    case UiType.image:
    case UiType.webview:
      return _unsupported(context, spec);
  }
}

Future<String?> _text(BuildContext context, UiSpec spec) async {
  final ctrl = TextEditingController();
  String? err;
  final obscure = spec.obscure ?? false;
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: Text(spec.label, style: const TextStyle(fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (spec.hint != null && spec.hint!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  spec.hint!,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Theme.of(c).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: obscure,
              keyboardType: TextInputType.text,
              inputFormatters: [
                if (spec.maxLength != null)
                  LengthLimitingTextInputFormatter(spec.maxLength),
              ],
              decoration: InputDecoration(errorText: err, hintText: '请输入'),
              onSubmitted: (_) => _submitText(c, spec, ctrl.text, (e) {
                setState(() => err = e);
              }),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => _submitText(c, spec, ctrl.text, (e) {
              setState(() => err = e);
            }),
            child: const Text('确定'),
          ),
        ],
      ),
    ),
  );
}

void _submitText(
  BuildContext c,
  UiSpec spec,
  String raw,
  void Function(String?) onError,
) {
  final v = raw.trim();
  if (v.isEmpty) {
    onError('内容不能为空');
    return;
  }
  if (spec.pattern != null) {
    try {
      if (!RegExp(spec.pattern!).hasMatch(v)) {
        onError('格式不正确');
        return;
      }
    } on FormatException {
      // 清单里的正则非法不属于用户输入错误，放行交由校验工具报告
    }
  }
  Navigator.pop(c, v);
}

Future<String?> _confirm(BuildContext context, UiSpec spec) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(spec.label, style: const TextStyle(fontSize: 17)),
      content: spec.hint == null ? null : Text(spec.hint!),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('确定'),
        ),
      ],
    ),
  );
  return ok == true ? 'true' : null;
}

Future<String?> _select(BuildContext context, UiSpec spec) async {
  return showDialog<String>(
    context: context,
    builder: (c) => SimpleDialog(
      title: Text(spec.label, style: const TextStyle(fontSize: 17)),
      children: [
        for (final o in spec.options)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(c, o.value),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(o.label),
            ),
          ),
      ],
    ),
  );
}

Future<Object?> _unsupported(BuildContext context, UiSpec spec) async {
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.extension_off_rounded),
      title: Text(spec.label, style: const TextStyle(fontSize: 16)),
      content: Text(
        spec.type == UiType.image
            ? '此插件需要图形验证码，但当前版本尚未接入图片验证码识别。'
                  '请在支持该能力的设备上运行，或联系插件作者更换验证方式。'
            : '此插件需要内嵌网页完成验证，当前版本尚未接入。',
        style: const TextStyle(fontSize: 13, height: 1.5),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('知道了')),
      ],
    ),
  );
  return null;
}
