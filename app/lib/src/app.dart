import 'dart:async';

import 'package:flutter/material.dart';

import 'pages/home_page.dart';
import 'pages/settings_page.dart';
import 'platform/app_version.dart';
import 'platform/update_service.dart';
import 'state/plugin_store.dart';
import 'theme/app_theme.dart';

/// 应用根：持有全局 Store，并把主题模式接到 MaterialApp。
class ToolPluginApp extends StatefulWidget {
  const ToolPluginApp({super.key});

  @override
  State<ToolPluginApp> createState() => _ToolPluginAppState();
}

class _ToolPluginAppState extends State<ToolPluginApp> {
  PluginStore? _plugins;
  SettingsStore? _settings;
  bool _ready = false;
  final _navKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final settings = await SettingsStore.load();
    final plugins = await PluginStore.open();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _plugins = plugins;
      _ready = true;
    });
    // 启动后静默检查一次更新；失败不打扰用户（国内直连成功率低，
    // 用户可在设置里配镜像后手动检查）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_silentUpdateCheck(settings));
    });
  }

  Future<void> _silentUpdateCheck(SettingsStore settings) async {
    try {
      final service = UpdateService(allowBadCertificate: settings.allowBadCert);
      final info = await service.fetchLatest(mirror: settings.updateMirror);
      if (info == null || !mounted) return;
      if (compareVersions(info.version, kAppVersion) <= 0) return;
      final ctx = _navKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      await showUpdateDialog(ctx, info, service, settings);
    } catch (_) {
      // 静默失败：不弹提示，用户可手动检查
    }
  }

  @override
  void dispose() {
    _settings?.dispose();
    _plugins?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    final plugins = _plugins;
    if (!_ready || settings == null || plugins == null) {
      return const MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) {
        return MaterialApp(
          navigatorKey: _navKey,
          title: '工具插件',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: settings.mode,
          home: HomePage(store: plugins, settings: settings),
        );
      },
    );
  }
}
