import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/plugin_store.dart';
import '../theme/app_theme.dart';
import 'run_page.dart';
import 'settings_page.dart';

/// 首页：已安装插件列表。
class HomePage extends StatelessWidget {
  const HomePage({super.key, required this.store, required this.settings});

  final PluginStore store;
  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        final items = store.items;
        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _Header(store: store, settings: settings),
                ),
                if (items.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
                    sliver: SliverList.separated(
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (c, i) => _PluginCard(
                        plugin: items[i],
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                RunPage(plugin: items[i], store: store),
                          ),
                        ),
                        onRemove: () => _confirmRemove(context, items[i]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _confirmRemove(BuildContext context, InstalledPlugin p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移除插件'),
        content: Text('确定移除「${p.manifest.name}」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true) await store.remove(p.id);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.store, required this.settings});
  final PluginStore store;
  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '插件库',
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  store.items.isEmpty
                      ? '还没有插件，导入 .qbpkg 开始'
                      : '共 ${store.items.length} 个插件',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: isDark ? '切换到亮色' : '切换到暗色',
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              size: 20,
            ),
            onPressed: settings.toggleTheme,
          ),
          IconButton(
            tooltip: '导入 .qbpkg',
            icon: const Icon(Icons.add_rounded, size: 22),
            onPressed: () => _showImportSheet(context, store),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined, size: 20),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SettingsPage(settings: settings),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showImportSheet(BuildContext context, PluginStore store) async {
    final ctrl = TextEditingController();
    final errNotifier = ValueNotifier<String?>(null);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          MediaQuery.of(c).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '导入插件',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '粘贴 .qbpkg 内容，或直接粘贴插件清单 JSON',
              style: TextStyle(
                fontSize: 12.5,
                color: Theme.of(c).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: ctrl,
              minLines: 5,
              maxLines: 9,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                hintText: '{"qbpkg":1,"manifest":{…}}',
              ),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: errNotifier,
              builder: (c2, err, _) => err == null
                  ? const SizedBox(height: 12)
                  : Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        err,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.failure(c2),
                        ),
                      ),
                    ),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final data = await Clipboard.getData(
                        Clipboard.kTextPlain,
                      );
                      if (data?.text != null) ctrl.text = data!.text!;
                    },
                    icon: const Icon(Icons.content_paste_rounded, size: 17),
                    label: const Text('从剪贴板'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      final text = ctrl.text.trim();
                      if (text.isEmpty) {
                        errNotifier.value = '内容为空';
                        return;
                      }
                      final r = await store.importText(text);
                      if (!c.mounted) return;
                      if (r.ok) {
                        Navigator.pop(c);
                      } else {
                        errNotifier.value = r.message;
                      }
                    },
                    child: const Text('导入'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    errNotifier.dispose();
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.extension_outlined,
            size: 46,
            color: scheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 14),
          Text(
            '暂无插件',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '点击右上角 + 导入 .qbpkg',
            style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _PluginCard extends StatelessWidget {
  const _PluginCard({
    required this.plugin,
    required this.onTap,
    required this.onRemove,
  });

  final InstalledPlugin plugin;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = plugin.manifest;
    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        onLongPress: onRemove,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  Icons.vpn_key_rounded,
                  size: 19,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${m.id} · v${m.version}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if ((m.description ?? '').isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        m.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
