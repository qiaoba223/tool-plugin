import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:plugin_engine/plugin_engine.dart';

import '../platform/http_transport.dart';
import '../platform/ui_responder.dart';
import '../state/plugin_store.dart';
import '../state/run_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';
import '../widgets/input_form.dart';
import '../widgets/log_view.dart';

/// 插件运行页：填参数 → 执行 → 看日志/结果。
class RunPage extends StatefulWidget {
  const RunPage({super.key, required this.plugin, required this.store});

  final InstalledPlugin plugin;
  final PluginStore store;

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  late final RunController _ctl;
  final _responder = DialogUiResponder();

  @override
  void initState() {
    super.initState();
    _ctl = RunController(
      plugin: widget.plugin,
      transport: HttpClientTransport(),
      responder: _responder,
    )..primeInputs();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.plugin.manifest;
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.name, style: const TextStyle(fontSize: 16)),
                Text(
                  '${m.id} · v${m.version}',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            actions: [
              if (_ctl.logs.isNotEmpty)
                IconButton(
                  tooltip: '清空日志',
                  icon: const Icon(Icons.cleaning_services_outlined, size: 19),
                  onPressed: _ctl.isRunning ? null : _ctl.clearLogs,
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
            children: [
              if ((m.description ?? '').isNotEmpty) _descCard(context, m),
              if (m.inputs.isNotEmpty) ...[
                const SizedBox(height: 4),
                SectionHeader('运行参数'),
                const SizedBox(height: 10),
                InputForm(
                  items: m.inputs,
                  values: _ctl.inputs,
                  enabled: !_ctl.isRunning,
                  onChanged: (k, v) => _ctl.inputs[k] = v,
                ),
              ],
              const SizedBox(height: 6),
              SectionHeader('运行状态'),
              const SizedBox(height: 10),
              _StatusCard(ctl: _ctl),
              const SizedBox(height: 16),
              SectionHeader('运行日志'),
              const SizedBox(height: 8),
              LogView(logs: _ctl.logs),
              if ((_ctl.result?.outputValues?.isNotEmpty ?? false)) ...[
                const SizedBox(height: 16),
                SectionHeader('输出'),
                const SizedBox(height: 8),
                _OutputCard(
                  outputValues: _ctl.result!.outputValues!,
                  ctl: _ctl,
                ),
              ],
            ],
          ),
          bottomNavigationBar: _BottomBar(ctl: _ctl),
        );
      },
    );
  }

  Widget _descCard(BuildContext context, Manifest m) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        m.description!,
        style: TextStyle(
          fontSize: 12.5,
          height: 1.45,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 运行状态卡片：显示阶段、错误、耗时。
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.ctl});
  final RunController ctl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, text) = switch (ctl.phase) {
      RunPhase.idle => (
        Icons.radio_button_unchecked_rounded,
        scheme.onSurfaceVariant,
        '待运行',
      ),
      RunPhase.running => (Icons.sync_rounded, scheme.primary, '运行中…'),
      RunPhase.collectingInput => (
        Icons.pending_actions_rounded,
        scheme.primary,
        '等待输入',
      ),
      RunPhase.succeeded => (
        Icons.check_circle_rounded,
        AppTheme.success(context),
        '成功',
      ),
      RunPhase.failed => (Icons.error_rounded, AppTheme.failure(context), '失败'),
      RunPhase.cancelled => (
        Icons.block_rounded,
        const Color(0xFFD89B2C),
        '已取消',
      ),
    };

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (ctl.phase == RunPhase.running)
                SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(icon, size: 17, color: color),
              const SizedBox(width: 9),
              Text(
                text,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
              const Spacer(),
              if (ctl.result != null)
                Text(
                  '${ctl.totalElapsed.inMilliseconds} ms',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          if (ctl.error != null) ...[
            const SizedBox(height: 9),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.failure(context).withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                '${ctl.error!.code}：${ctl.error!.message}'
                '${ctl.error!.stepId == null ? '' : '\n步骤：${ctl.error!.stepId}'}',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.45,
                  fontFamily: 'monospace',
                  color: AppTheme.failure(context),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 输出卡片：按 output 声明渲染，敏感值默认打码。
class _OutputCard extends StatelessWidget {
  const _OutputCard({required this.outputValues, required this.ctl});
  final List<OutputValue> outputValues;
  final RunController ctl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Column(
        children: [
          for (final o in outputValues) _OutputRow(value: o, scheme: scheme),
        ],
      ),
    );
  }
}

class _OutputRow extends StatefulWidget {
  const _OutputRow({required this.value, required this.scheme});
  final OutputValue value;
  final ColorScheme scheme;

  @override
  State<_OutputRow> createState() => _OutputRowState();
}

class _OutputRowState extends State<_OutputRow> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    final scheme = widget.scheme;
    final text = v.value;
    final masked = v.sensitive && !_shown && text.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: v.sensitive
          ? () => setState(() => _shown = !_shown)
          : () => _copy(context, text),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 96,
              child: Text(
                v.label.isEmpty ? '（未命名）' : v.label,
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                masked ? '••••••••' : text,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: 'monospace',
                  height: 1.4,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Icon(
              v.sensitive && !_shown
                  ? Icons.visibility_off_rounded
                  : Icons.copy_rounded,
              size: 14,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }

  void _copy(BuildContext context, String text) {
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }
}

/// 底部操作条：运行 / 取消。
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.ctl});
  final RunController ctl;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        MediaQuery.of(context).padding.bottom + 12,
      ),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ctl.isRunning
                ? OutlinedButton.icon(
                    onPressed: ctl.cancel,
                    icon: const Icon(Icons.stop_rounded, size: 18),
                    label: const Text('取消'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                      foregroundColor: AppTheme.failure(context),
                    ),
                  )
                : FilledButton.icon(
                    onPressed: ctl.run,
                    icon: const Icon(Icons.play_arrow_rounded, size: 20),
                    label: Text(ctl.phase == RunPhase.idle ? '开始运行' : '重新运行'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(46),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
