import 'package:flutter/material.dart';

import '../state/run_controller.dart';
import '../theme/app_theme.dart';

/// 运行日志。等宽字体、按级别着色、自动滚到底部。
class LogView extends StatefulWidget {
  const LogView({super.key, required this.logs, this.autoScroll = true});

  final List<LogLine> logs;
  final bool autoScroll;

  @override
  State<LogView> createState() => _LogViewState();
}

class _LogViewState extends State<LogView> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(LogView old) {
    super.didUpdateWidget(old);
    if (widget.autoScroll && widget.logs.length != old.logs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        // 用户手动上滑查看历史时不硬拉回来
        final pos = _scroll.position;
        if (pos.pixels >= pos.maxScrollExtent - 80) {
          _scroll.jumpTo(pos.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.logs.isEmpty) {
      return Text(
        '暂无日志',
        style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
      );
    }
    return Container(
      constraints: const BoxConstraints(maxHeight: 300, minHeight: 80),
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Scrollbar(
        controller: _scroll,
        child: ListView.builder(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          itemCount: widget.logs.length,
          itemBuilder: (c, i) => _row(context, widget.logs[i]),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, LogLine l) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (l.level) {
      LogLevel.error => AppTheme.failure(context),
      LogLevel.ok => AppTheme.success(context),
      LogLevel.warn => const Color(0xFFD89B2C),
      LogLevel.request => scheme.primary,
      LogLevel.response => scheme.primary.withValues(alpha: 0.75),
      LogLevel.info => scheme.onSurfaceVariant,
    };
    final t = l.at;
    final hhmmss =
        '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hhmmss,
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: 'monospace',
              height: 1.45,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.65),
            ),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: SelectableText(
              l.text,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                height: 1.45,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
