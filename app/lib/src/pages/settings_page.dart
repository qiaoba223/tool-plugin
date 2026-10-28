import 'dart:io';

import 'package:flutter/material.dart';

import '../platform/app_version.dart';
import '../platform/update_service.dart';
import '../state/plugin_store.dart';
import '../theme/app_theme.dart';
import '../widgets/common.dart';

/// 设置页：外观、网络策略、更新镜像。
///
/// 更新相关的开关和镜像地址都放这里——镜像需要用户自己改，
/// 不能写死在代码里（不同地区可用性差别很大）。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.settings});

  final SettingsStore settings;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        return Scaffold(
          appBar: AppBar(
            title: const Text('设置'),
            backgroundColor: Colors.transparent,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              const SectionHeader('外观'),
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    SwitchListTile(
                      title: const Text('深色模式'),
                      subtitle: Text(
                        settings.mode == ThemeMode.system
                            ? '跟随系统'
                            : (settings.isDark ? '已固定为深色' : '已固定为浅色'),
                        style: const TextStyle(fontSize: 12),
                      ),
                      value: settings.isDark,
                      onChanged: (_) => settings.toggleTheme(),
                    ),
                    if (settings.mode != ThemeMode.system)
                      ListTile(
                        dense: true,
                        leading: const Icon(
                          Icons.brightness_auto_rounded,
                          size: 20,
                        ),
                        title: const Text(
                          '恢复跟随系统',
                          style: TextStyle(fontSize: 13.5),
                        ),
                        onTap: () => settings.setMode(ThemeMode.system),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const SectionHeader('网络'),
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SwitchListTile(
                  title: const Text('允许自签名证书'),
                  subtitle: const Text(
                    '部分运营商网关证书链不规范，开启后才能连接。\n'
                    '开启意味着放弃该连接的身份校验，仅在你信任的网络下使用。',
                    style: TextStyle(fontSize: 12, height: 1.45),
                  ),
                  value: settings.allowBadCert,
                  onChanged: settings.setAllowBadCert,
                ),
              ),
              const SizedBox(height: 20),
              const SectionHeader('更新'),
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.speed_rounded, size: 20),
                      title: const Text(
                        '镜像加速地址',
                        style: TextStyle(fontSize: 14),
                      ),
                      subtitle: Text(
                        settings.updateMirror.isEmpty
                            ? '未配置（直连 GitHub，国内可能很慢）'
                            : settings.updateMirror,
                        style: const TextStyle(fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.edit_rounded, size: 18),
                      onTap: () => _editMirror(context),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.info_outline_rounded, size: 20),
                      title: const Text('当前版本', style: TextStyle(fontSize: 14)),
                      trailing: Text(
                        'v$kAppVersion',
                        style: TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.refresh_rounded, size: 20),
                      title: const Text('检查更新', style: TextStyle(fontSize: 14)),
                      subtitle: const Text(
                        '从 GitHub Releases 获取最新版本',
                        style: TextStyle(fontSize: 12),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                      ),
                      onTap: () async {
                        await checkForUpdate(context, settings);
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const SectionHeader('关于'),
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  children: [
                    const ListTile(
                      leading: Icon(Icons.shield_outlined, size: 20),
                      title: Text('隐私', style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                        '本应用不上报任何数据，不含统计/崩溃收集 SDK。\n'
                        '插件运行时只会访问插件清单中声明的主机。',
                        style: TextStyle(fontSize: 12, height: 1.45),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.link_rounded, size: 20),
                      title: const Text('项目主页', style: TextStyle(fontSize: 14)),
                      subtitle: const Text(
                        'github.com/$kRepoOwner/$kRepoName',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _editMirror(BuildContext context) async {
    final ctrl = TextEditingController(text: settings.updateMirror);
    final saved = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('镜像加速地址', style: TextStyle(fontSize: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '下载更新包时，在该地址后拼接原始 GitHub 链接。\n'
              '留空表示直连。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                hintText: 'https://ghproxy.net/',
                helperText: '需以 http:// 或 https:// 开头',
                helperStyle: TextStyle(fontSize: 11),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final t = ctrl.text.trim();
              if (t.isNotEmpty) {
                final scheme = Uri.tryParse(t)?.scheme;
                if (scheme != 'http' && scheme != 'https') {
                  return; // 非法地址不关闭对话框
                }
              }
              Navigator.pop(c, t);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (saved != null) await settings.setUpdateMirror(saved);
  }
}

/// 检查更新并提示。
///
/// 单独抽出来，供"关于"页与启动时复用。
Future<UpdateInfo?> checkForUpdate(
  BuildContext context,
  SettingsStore settings,
) async {
  final service = UpdateService(allowBadCertificate: settings.allowBadCert);
  try {
    final info = await service.fetchLatest(mirror: settings.updateMirror);
    if (info == null) return null;
    if (compareVersions(info.version, kAppVersion) <= 0) return null;
    if (!context.mounted) return null;
    await showUpdateDialog(context, info, service, settings);
    return info;
  } on UpdateException catch (e) {
    if (!context.mounted) return null;
    _snack(context, e.message, isError: true);
    return null;
  }
}

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info,
  UpdateService service,
  SettingsStore settings,
) {
  return showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Row(
        children: [
          Icon(
            Icons.system_update_rounded,
            size: 20,
            color: AppTheme.success(c),
          ),
          const SizedBox(width: 8),
          Text('发现新版本 v${info.version}', style: const TextStyle(fontSize: 16)),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (info.notes.isNotEmpty) ...[
                Text(
                  info.notes,
                  style: const TextStyle(fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 12),
              ],
              if (info.assets.isEmpty)
                Text(
                  '该版本没有提供 ${_platformLabel()} 安装包',
                  style: TextStyle(fontSize: 12, color: AppTheme.failure(c)),
                )
              else
                Text(
                  '安装包：${info.assets.first.name}'
                  '${info.assets.first.sizeBytes > 0 ? '（${_fmtSize(info.assets.first.sizeBytes)}）' : ''}',
                  style: const TextStyle(fontSize: 12),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('以后再说'),
        ),
        if (info.assets.isNotEmpty)
          FilledButton(
            onPressed: () {
              Navigator.pop(c);
              _downloadAndInstall(
                context,
                info.assets.first,
                service,
                settings,
              );
            },
            child: const Text('下载更新'),
          ),
      ],
    ),
  );
}

Future<void> _downloadAndInstall(
  BuildContext context,
  UpdateAsset asset,
  UpdateService service,
  SettingsStore settings,
) async {
  final progress = ValueNotifier<double>(0);
  final dlg = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: const Text('正在下载', style: TextStyle(fontSize: 16)),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (c, v, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: v > 0 ? v : null),
            const SizedBox(height: 10),
            Text(
              v > 0 ? '${(v * 100).toStringAsFixed(1)}%' : '连接中…',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    ),
  );

  final dir = Directory.systemTemp;
  final dest = '${dir.path}/${asset.name}';
  try {
    await service.download(
      asset,
      dest,
      onProgress: (r, t) {
        if (t > 0) progress.value = r / t;
      },
    );
    if (context.mounted) {
      Navigator.pop(context);
      // iOS 的未签名 IPA 系统安装器无法直接装（需要 TrollStore / 侧载工具），
      // 文案必须说清楚，否则用户会以为下载坏了。
      _snack(
        context,
        Platform.isAndroid
            ? '已下载到 $dest\n用文件管理器打开即可安装'
            : '已下载到 $dest\n未签名 IPA 需用 TrollStore 或 AltStore 安装，\n系统「文件」无法直接安装',
      );
    }
  } on UpdateException catch (e) {
    if (context.mounted) {
      Navigator.pop(context);
      _snack(context, e.message, isError: true);
    }
  } finally {
    progress.dispose();
    await dlg;
  }
}

String _platformLabel() {
  if (Platform.isAndroid) return 'Android';
  if (Platform.isIOS) return 'iOS';
  return '当前平台';
}

String _fmtSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '$bytes B';
}

void _snack(BuildContext context, String msg, {bool isError = false}) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(msg, style: const TextStyle(fontSize: 13)),
      backgroundColor: isError ? AppTheme.failure(context) : null,
    ),
  );
}
