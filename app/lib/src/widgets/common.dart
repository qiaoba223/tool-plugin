import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// 小型状态标签。用于插件卡片、运行结果等。
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.text,
    required this.color,
    this.icon,
  });

  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              height: 1.2,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区标题：左侧竖条 + 文字，用于结果/日志等区块。
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.1,
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 键值行，用于展示 output 与变量。
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.monospace = false,
    this.onCopy,
  });

  final String label;
  final String value;
  final bool monospace;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.35,
                fontFamily: monospace ? 'monospace' : null,
                color: value.isEmpty ? scheme.onSurfaceVariant : null,
              ),
            ),
          ),
          if (onCopy != null)
            InkWell(
              onTap: onCopy,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.copy_rounded,
                  size: 14,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 空状态占位。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 44,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
      ),
    );
  }
}

/// 顶部进度条；运行中显示不确定进度。
class RunProgressBar extends StatelessWidget {
  const RunProgressBar({super.key, required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    if (!active) return const SizedBox(height: 2);
    return LinearProgressIndicator(
      minHeight: 2,
      backgroundColor: Colors.transparent,
      color: Theme.of(context).colorScheme.primary,
    );
  }
}

/// 结果横幅：成功/失败/取消。
class OutcomeBanner extends StatelessWidget {
  const OutcomeBanner({
    super.key,
    required this.title,
    required this.detail,
    required this.color,
    required this.icon,
  });

  final String title;
  final String detail;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radius),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                if (detail.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  SelectableText(
                    detail,
                    style: const TextStyle(fontSize: 12.5, height: 1.45),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
