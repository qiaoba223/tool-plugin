import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_engine/plugin_engine.dart';

/// 插件输入表单（对应清单里的 `inputs`）。
///
/// 校验规则取自清单（required/minLength/maxLength/pattern），
/// 不做额外臆测——上游 schema 没承诺的规则不在这里加。
class InputForm extends StatefulWidget {
  const InputForm({
    super.key,
    required this.items,
    required this.values,
    required this.onChanged,
    this.enabled = true,
  });

  final List<InputItem> items;

  /// 外部持有的值表（key -> value），组件直接写入。
  final Map<String, Object?> values;
  final void Function(String key, Object? value) onChanged;
  final bool enabled;

  @override
  State<InputForm> createState() => _InputFormState();
}

class _InputFormState extends State<InputForm> {
  final _controllers = <String, TextEditingController>{};
  final _errors = <String, String?>{};
  final _obscured = <String, bool>{};

  @override
  void initState() {
    super.initState();
    for (final it in widget.items) {
      final v = widget.values[it.key];
      _controllers[it.key] = TextEditingController(text: v?.toString() ?? '');
      _obscured[it.key] = it.sensitive || it.type == InputType.password;
    }
  }

  @override
  void didUpdateWidget(InputForm old) {
    super.didUpdateWidget(old);
    // 外部重置了值（例如「清空」），同步回输入框
    for (final it in widget.items) {
      final v = widget.values[it.key]?.toString() ?? '';
      final c = _controllers[it.key];
      if (c != null && c.text != v && !c.selection.isValid) {
        c.text = v;
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  String? _validate(InputItem it, String raw) {
    if (it.required && raw.trim().isEmpty) {
      return '${it.label}不能为空';
    }
    if (raw.isEmpty) return null;
    if (it.minLength != null && raw.length < it.minLength!) {
      return '至少 ${it.minLength} 位';
    }
    if (it.maxLength != null && raw.length > it.maxLength!) {
      return '最多 ${it.maxLength} 位';
    }
    if (it.pattern != null) {
      try {
        if (!RegExp(it.pattern!).hasMatch(raw)) return '格式不正确';
      } on FormatException {
        // 清单里的正则本身非法：不在 UI 层抛，留给校验工具报告
      }
    }
    if (it.type == InputType.phone && !RegExp(r'^\+?\d{6,15}$').hasMatch(raw)) {
      return '手机号格式不正确';
    }
    return null;
  }

  void _onChanged(InputItem it, String raw) {
    final err = _validate(it, raw);
    setState(() => _errors[it.key] = err);
    final v = switch (it.type) {
      InputType.number => int.tryParse(raw) ?? (raw.isEmpty ? null : raw),
      _ => raw,
    };
    widget.onChanged(it.key, v);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final it in widget.items) ...[
          _labelRow(it),
          const SizedBox(height: 6),
          _field(it),
          const SizedBox(height: 14),
        ],
      ],
    );
  }

  Widget _labelRow(InputItem it) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Text(
          it.label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (!it.required)
          Text(
            '  可选',
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _field(InputItem it) {
    if (it.type == InputType.select) {
      return DropdownButtonFormField<String>(
        // Flutter 3.33 起 value 废弃，initialValue 语义相同
        initialValue: (widget.values[it.key]?.toString().isNotEmpty ?? false)
            ? widget.values[it.key].toString()
            : null,
        isExpanded: true,
        decoration: InputDecoration(
          hintText: it.placeholder ?? '请选择',
          errorText: _errors[it.key],
        ),
        items: [
          for (final o in it.options)
            DropdownMenuItem(value: o.value, child: Text(o.label)),
        ],
        onChanged: widget.enabled
            ? (v) {
                if (v == null) return;
                setState(() => _errors[it.key] = null);
                widget.onChanged(it.key, v);
              }
            : null,
      );
    }

    final obscure = it.type == InputType.password || it.sensitive;
    return TextField(
      controller: _controllers[it.key],
      enabled: widget.enabled,
      obscureText: obscure ? (_obscured[it.key] ?? true) : false,
      keyboardType: switch (it.type) {
        InputType.phone => TextInputType.phone,
        InputType.number => TextInputType.number,
        _ => TextInputType.text,
      },
      inputFormatters: [
        if (it.maxLength != null)
          LengthLimitingTextInputFormatter(it.maxLength),
        if (it.type == InputType.number) FilteringTextInputFormatter.digitsOnly,
      ],
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        hintText: it.placeholder ?? _hintFor(it.type),
        errorText: _errors[it.key],
        suffixIcon: obscure
            ? IconButton(
                icon: Icon(
                  (_obscured[it.key] ?? true)
                      ? Icons.visibility_off_rounded
                      : Icons.visibility_rounded,
                  size: 19,
                ),
                onPressed: () => setState(
                  () => _obscured[it.key] = !(_obscured[it.key] ?? true),
                ),
              )
            : null,
      ),
      onChanged: widget.enabled ? (v) => _onChanged(it, v) : null,
    );
  }

  String? _hintFor(InputType t) => switch (t) {
    InputType.phone => '请输入手机号',
    InputType.password => '请输入密码',
    InputType.number => '请输入数字',
    _ => null,
  };
}
