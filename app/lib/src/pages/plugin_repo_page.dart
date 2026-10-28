/// 插件库浏览页：从远端仓库拉取 index.json，勾选后批量安装。
///
/// 与原版行为对齐的要点：
/// - 已安装同 id 的条目显示"已安装/可更新"，不隐藏；
/// - 安装前用 SHA-256 校验，校验失败**不落库**；
/// - 单条失败不影响其它条目，最后汇总报告；
/// - 空库不是错误，显示引导文案而不是红色报错。
library;

import 'package:flutter/material.dart';
import 'package:plugin_engine/plugin_engine.dart';
import 'package:plugin_ui_core/plugin_ui_core.dart';

import '../platform/plugin_repo_service.dart';
import '../state/plugin_store.dart';
import '../theme/app_theme.dart';

class PluginRepoPage extends StatefulWidget {
  const PluginRepoPage({
    super.key,
    required this.store,
    required this.settings,
  });

  final PluginStore store;
  final SettingsStore settings;

  @override
  State<PluginRepoPage> createState() => _PluginRepoPageState();
}

class _PluginRepoPageState extends State<PluginRepoPage> {
  final _service = PluginRepoService();

  PluginRepoIndex? _index;
  String? _mirrorLabel;
  String? _error;
  bool _loading = false;

  /// 勾选的插件 id。
  final Set<String> _selected = {};

  /// 正在安装的 id → 进度文案。
  final Map<String, String> _installing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _index = null;
      _selected.clear();
    });
    try {
      final client = _service.clientFor(
        url: widget.settings.pluginRepoUrl,
        mirrorPrefix: widget.settings.pluginRepoMirror,
        branch: widget.settings.pluginRepoBranch,
      );
      final r = await client.fetchIndex();
      if (!mounted) return;
      setState(() {
        _index = r.index;
        _mirrorLabel = r.mirror.label;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = describeRepoError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  InstalledPlugin? _installedOf(String id) {
    for (final p in widget.store.items) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 已安装且版本相同 → up-to-date。
  bool _isUpToDate(PluginRepoEntry e) {
    final p = _installedOf(e.id);
    return p != null && p.version == e.version;
  }

  Future<void> _installSelected() async {
    final idx = _index;
    if (idx == null || _selected.isEmpty) return;

    final client = _service.clientFor(
      url: widget.settings.pluginRepoUrl,
      mirrorPrefix: widget.settings.pluginRepoMirror,
      branch: widget.settings.pluginRepoBranch,
    );

    final targets = idx.entries.where((e) => _selected.contains(e.id)).toList();
    final failed = <String>[];

    for (final e in targets) {
      if (!mounted) return;
      setState(() => _installing[e.id] = '下载中…');
      try {
        // downloadPackage 内部已做 SHA-256 校验，不符会抛 checksum
        final pkg = await client.downloadPackage(e);
        if (!mounted) return;
        setState(() => _installing[e.id] = '安装中…');
        await widget.store.installRaw(pkg.text, source: PluginSource.imported);
        if (!mounted) return;
        setState(() => _installing.remove(e.id));
      } catch (err) {
        failed.add('${e.name}：${describeRepoError(err)}');
        if (mounted) setState(() => _installing.remove(e.id));
      }
    }

    if (!mounted) return;
    setState(() {
      _selected.removeWhere(
        (id) => !failed.any((f) => f.startsWith(_nameOf(id))),
      );
    });

    if (failed.isEmpty) {
      _toast('已安装 ${targets.length} 个插件');
    } else {
      _showFailures(failed);
    }
  }

  String _nameOf(String id) {
    for (final e in _index?.entries ?? const <PluginRepoEntry>[]) {
      if (e.id == id) return e.name;
    }
    return id;
  }

  void _toast(String s) {
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  void _showFailures(List<String> failed) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${failed.length} 个插件安装失败'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in failed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(f, style: const TextStyle(fontSize: 13)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('插件库'),
        actions: [
          IconButton(
            tooltip: '插件库设置',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PluginRepoSettingsPage(settings: widget.settings),
                ),
              );
              // 设置改完回来立刻按新配置重拉
              if (mounted) _load();
            },
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _buildBody(scheme),
      bottomNavigationBar: (_index != null && _index!.entries.isNotEmpty)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '已选 ${_selected.length} 个',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _selected.isEmpty || _installing.isNotEmpty
                          ? null
                          : _installSelected,
                      icon: const Icon(Icons.download),
                      label: const Text('安装所选'),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildBody(ColorScheme scheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _ErrorView(
        message: _error!,
        repoUrl: widget.settings.pluginRepoUrl,
        onRetry: _load,
        onOpenSettings: () async {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PluginRepoSettingsPage(settings: widget.settings),
            ),
          );
          if (mounted) _load();
        },
      );
    }
    final idx = _index;
    if (idx == null) return const SizedBox.shrink();
    if (idx.entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_outlined, size: 56, color: scheme.outline),
              const SizedBox(height: 12),
              const Text('这个插件库还没有插件'),
              const SizedBox(height: 6),
              Text(
                '在仓库根目录放 index.json 即可发布插件',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        itemCount: idx.entries.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
              child: Text(
                '${idx.name} · ${idx.entries.length} 个插件'
                '${_mirrorLabel != null ? ' · 镜像 $_mirrorLabel' : ''}',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            );
          }
          final e = idx.entries[i - 1];
          return _entryTile(e, scheme);
        },
      ),
    );
  }

  Widget _entryTile(PluginRepoEntry e, ColorScheme scheme) {
    final installing = _installing[e.id];
    final upToDate = _isUpToDate(e);
    final installed = _installedOf(e.id);
    final selected = _selected.contains(e.id);

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: installing != null
            ? null
            : () => setState(() {
                if (selected) {
                  _selected.remove(e.id);
                } else {
                  _selected.add(e.id);
                }
              }),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: selected,
                onChanged: installing != null
                    ? null
                    : (v) => setState(() {
                        if (v == true) {
                          _selected.add(e.id);
                        } else {
                          _selected.remove(e.id);
                        }
                      }),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            e.name,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        _badge(e, installed, upToDate, scheme),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${e.id} · v${e.version}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    if (e.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        e.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                    if (installing != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            installing,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(
    PluginRepoEntry e,
    InstalledPlugin? installed,
    bool upToDate,
    ColorScheme scheme,
  ) {
    if (upToDate) {
      return Chip(
        visualDensity: VisualDensity.compact,
        label: const Text('已安装', style: TextStyle(fontSize: 11)),
        backgroundColor: scheme.surfaceContainerHighest,
        side: BorderSide.none,
      );
    }
    if (installed != null) {
      return Chip(
        visualDensity: VisualDensity.compact,
        label: Text('可更新 v${e.version}', style: const TextStyle(fontSize: 11)),
        backgroundColor: scheme.primaryContainer,
        side: BorderSide.none,
      );
    }
    return const SizedBox.shrink();
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.message,
    required this.repoUrl,
    required this.onRetry,
    required this.onOpenSettings,
  });

  final String message;
  final String repoUrl;
  final VoidCallback onRetry;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 52, color: scheme.error),
            const SizedBox(height: 14),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            Text(
              repoUrl,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: onOpenSettings,
                  child: const Text('改地址'),
                ),
                const SizedBox(width: 12),
                FilledButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 插件库设置：地址、分支、镜像。
class PluginRepoSettingsPage extends StatefulWidget {
  const PluginRepoSettingsPage({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<PluginRepoSettingsPage> createState() => _PluginRepoSettingsPageState();
}

class _PluginRepoSettingsPageState extends State<PluginRepoSettingsPage> {
  late final TextEditingController _url;
  late final TextEditingController _branch;
  late final TextEditingController _mirrorCustom;

  static const _presets = <({String label, String prefix})>[
    (label: '自动（依次尝试）', prefix: ''),
    (label: 'ghproxy.net', prefix: 'https://ghproxy.net/'),
    (label: 'ghfast.top', prefix: 'https://ghfast.top/'),
    (label: 'gh-proxy.com', prefix: 'https://gh-proxy.com/'),
    (label: 'jsDelivr CDN', prefix: 'https://fastly.jsdelivr.net/gh/'),
  ];

  String _selectedPreset = '';

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.settings.pluginRepoUrl);
    _branch = TextEditingController(text: widget.settings.pluginRepoBranch);
    final cur = widget.settings.pluginRepoMirror;
    final hit = _presets.where((p) => p.prefix == cur).toList();
    if (hit.isNotEmpty) {
      _selectedPreset = hit.first.prefix;
      _mirrorCustom = TextEditingController();
    } else {
      _selectedPreset = cur.isEmpty ? '' : '__custom__';
      _mirrorCustom = TextEditingController(text: cur);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _branch.dispose();
    _mirrorCustom.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.settings.setPluginRepoUrl(_url.text);
    await widget.settings.setPluginRepoBranch(_branch.text);
    final mirror = _selectedPreset == '__custom__'
        ? _mirrorCustom.text.trim()
        : _selectedPreset;
    await widget.settings.setPluginRepoMirror(mirror);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('已保存')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final urlOk = looksLikeRepoUrl(_url.text);

    return Scaffold(
      appBar: AppBar(
        title: const Text('插件库设置'),
        actions: [TextButton(onPressed: _save, child: const Text('保存'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          TextField(
            controller: _url,
            // 必须是普通键盘：URL 里要输入 /*- 等字符，数字键盘打不出来
            keyboardType: TextInputType.url,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '仓库地址',
              hintText: 'https://github.com/用户名/仓库名',
              helperText: urlOk || _url.text.isEmpty ? null : '地址格式看起来不对',
              helperStyle: TextStyle(color: scheme.error),
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _branch,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '分支',
              hintText: 'main',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),
          Text('下载加速', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Text(
            '插件库在 GitHub 上，国内直连常常失败。选"自动"会依次尝试下面的镜像。',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          for (final p in _presets)
            RadioListTile<String>(
              value: p.prefix,
              groupValue: _selectedPreset,
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(p.label),
              onChanged: (v) => setState(() => _selectedPreset = v ?? ''),
            ),
          RadioListTile<String>(
            value: '__custom__',
            groupValue: _selectedPreset,
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('自定义前缀'),
            onChanged: (v) => setState(() => _selectedPreset = v ?? ''),
          ),
          if (_selectedPreset == '__custom__')
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 4),
              child: TextField(
                controller: _mirrorCustom,
                keyboardType: TextInputType.url,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  hintText: 'https://your-proxy.example/',
                  helperText: '会拼成 <前缀><完整原始地址>',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          const SizedBox(height: 24),
          Card(
            margin: EdgeInsets.zero,
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '插件库是什么',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '任何 GitHub 仓库，只要根目录有 index.json 并附上 .qbpkg 包，就能作为插件库。'
                    'App 不内置任何插件，装什么完全由你决定。'
                    '每个包都会按 index.json 里的 SHA-256 校验后再安装。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
