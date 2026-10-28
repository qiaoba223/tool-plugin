import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:plugin_engine/plugin_engine.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/http_transport.dart';

/// 已安装插件条目：清单 + 原始 JSON（便于重新导出）。
class InstalledPlugin {
  InstalledPlugin({
    required this.manifest,
    required this.rawJson,
    required this.installedAt,
    this.source = PluginSource.imported,
  });

  final Manifest manifest;
  final Map<String, Object?> rawJson;
  final DateTime installedAt;
  final PluginSource source;

  String get id => manifest.id;
  String get name => manifest.name;
  String get version => manifest.version;

  Map<String, Object?> toJson() => {
    'raw': rawJson,
    'installedAt': installedAt.toIso8601String(),
    'source': source.name,
  };

  static InstalledPlugin fromJson(Map<String, Object?> j) {
    final raw = (j['raw'] as Map).cast<String, Object?>();
    return InstalledPlugin(
      manifest: parseManifest(raw),
      rawJson: raw,
      installedAt:
          DateTime.tryParse(j['installedAt'] as String? ?? '') ??
          DateTime.now(),
      source: PluginSource.values.firstWhere(
        (s) => s.name == j['source'],
        orElse: () => PluginSource.imported,
      ),
    );
  }
}

enum PluginSource { imported }

/// 插件库：负责加载/导入/删除，并持久化到 SharedPreferences。
class PluginStore extends ChangeNotifier {
  PluginStore._(this._prefs);

  /// 读取本机已安装插件列表。
  static Future<PluginStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    final store = PluginStore._(prefs);
    await store._restore();
    return store;
  }

  static const _key = 'installed_plugins_v1';

  final SharedPreferences _prefs;
  final List<InstalledPlugin> _items = [];
  bool _loaded = false;

  List<InstalledPlugin> get items => List.unmodifiable(_items);
  bool get isLoaded => _loaded;

  /// 读取本机已安装插件列表。
  Future<void> _restore() async {
    final raw = _prefs.getString(_key);
    if (raw != null) {
      try {
        final list = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
        _items
          ..clear()
          ..addAll(list.map(InstalledPlugin.fromJson));
      } catch (e) {
        // 记录损坏时不要静默清空用户数据：保留原始串另存一份再重建
        await _prefs.setString(
          '${_key}_corrupt_${DateTime.now().millisecondsSinceEpoch}',
          raw,
        );
        _items.clear();
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 从 `.qbpkg`（或其裸 manifest）文本导入。
  Future<ImportResult> importText(String text) async {
    final DecodedPackage pkg;
    try {
      pkg = PluginPackage.decode(text);
    } on PluginError catch (e) {
      return ImportResult.error('${e.code}：${e.message}');
    }
    return importRaw(pkg.manifest.cast<String, Object?>());
  }

  /// 从 `.qbpkg` 字节导入（按 UTF-8 解码）。
  Future<ImportResult> importBytes(Uint8List bytes) async {
    final String text;
    try {
      text = utf8.decode(bytes);
    } on FormatException {
      return ImportResult.error('E_PKG_FORMAT：文件不是合法的 UTF-8 文本');
    }
    return importText(text);
  }

  /// 直接导入已解析的清单。
  ///
  /// 必须等落盘成功才报成功：否则用户看到「已安装」，
  /// 重启后插件却消失（磁盘满/权限不足时静默丢数据）。
  Future<ImportResult> importRaw(Map<String, Object?> raw) async {
    final Manifest m;
    try {
      m = parseManifest(raw);
    } on PluginError catch (e) {
      return ImportResult.error('${e.code}：${e.message}');
    }
    final existing = _items.indexWhere((p) => p.id == m.id);
    final old = existing >= 0 ? _items[existing] : null;
    final item = InstalledPlugin(
      manifest: m,
      rawJson: raw,
      installedAt: DateTime.now(),
      source: PluginSource.imported,
    );
    if (existing >= 0) {
      _items[existing] = item;
    } else {
      _items.add(item);
    }
    try {
      await _persist();
    } catch (e) {
      // 回滚内存状态，保持与磁盘一致
      if (existing >= 0) {
        _items[existing] = old!;
      } else {
        _items.remove(item);
      }
      notifyListeners();
      return ImportResult.error('保存失败：$e');
    }
    notifyListeners();
    return ImportResult.ok(item, replaced: existing >= 0);
  }

  Future<bool> remove(String id) async {
    final before = _items.length;
    _items.removeWhere((p) => p.id == id);
    if (_items.length == before) return false;
    await _persist();
    notifyListeners();
    return true;
  }

  Future<void> _persist() async {
    final data = jsonEncode(_items.map((e) => e.toJson()).toList());
    final ok = await _prefs.setString(_key, data);
    if (!ok) {
      throw StateError('写入 SharedPreferences 失败（${data.length} 字节）');
    }
  }
}

class ImportResult {
  ImportResult.ok(this.plugin, {this.replaced = false}) : error = null;
  ImportResult.error(this.error) : plugin = null, replaced = false;

  bool get ok => error == null;

  /// 供 UI 直接显示的文案。
  String get message => ok
      ? (replaced
            ? '已更新「${plugin!.manifest.name}」'
            : '已安装「${plugin!.manifest.name}」')
      : error!;

  final InstalledPlugin? plugin;
  final String? error;
  final bool replaced;
  bool get isOk => error == null;
}

/// 外观设置。
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._prefs, this._systemIsDark);

  /// 读取持久化设置。`systemIsDark` 由调用方根据当前系统主题传入
  /// （`ThemeMode.system` 模式下用于判断实际明暗）。
  static Future<SettingsStore> load({bool systemIsDark = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = SettingsStore._(prefs, systemIsDark);
    store._restore();
    return store;
  }

  static const _themeKey = 'theme_mode';
  static const _badCertKey = 'allow_bad_cert';
  static const _updateMirrorKey = 'update_mirror';

  final SharedPreferences _prefs;
  bool _systemIsDark;
  ThemeMode _mode = ThemeMode.system;
  bool _allowBadCert = false;
  String _updateMirror = '';

  ThemeMode get mode => _mode;
  bool get allowBadCert => _allowBadCert;

  /// 更新下载的镜像前缀（空串表示直连 GitHub）。
  String get updateMirror => _updateMirror;

  /// 当前实际是否深色（供状态栏图标等使用）。
  bool get isDark => switch (_mode) {
    ThemeMode.dark => true,
    ThemeMode.light => false,
    ThemeMode.system => _systemIsDark,
  };

  void _restore() {
    _mode = switch (_prefs.getString(_themeKey)) {
      'dark' => ThemeMode.dark,
      'light' => ThemeMode.light,
      _ => ThemeMode.system,
    };
    _allowBadCert = _prefs.getBool(_badCertKey) ?? false;
    _updateMirror = _prefs.getString(_updateMirrorKey) ?? '';
  }

  /// 系统外观变化时更新（仅 system 模式生效）。
  void updateSystemBrightness(bool isDark) {
    if (_systemIsDark == isDark) return;
    _systemIsDark = isDark;
    if (_mode == ThemeMode.system) notifyListeners();
  }

  Future<void> setMode(ThemeMode m) async {
    if (_mode == m) return;
    _mode = m;
    // SharedPreferences 不接受 null 值，回到 system 时用 remove
    if (m == ThemeMode.system) {
      await _prefs.remove(_themeKey);
    } else {
      await _prefs.setString(_themeKey, m.name);
    }
    notifyListeners();
  }

  /// 在亮/暗之间切换（跳过 system，点击即得到明确结果）。
  Future<void> toggleTheme() =>
      setMode(isDark ? ThemeMode.light : ThemeMode.dark);

  Future<void> setUpdateMirror(String v) async {
    final t = v.trim();
    if (_updateMirror == t) return;
    _updateMirror = t;
    // 空串表示"直连"，直接删 key，避免把空值当成配置存下来
    if (t.isEmpty) {
      await _prefs.remove(_updateMirrorKey);
    } else {
      await _prefs.setString(_updateMirrorKey, t);
    }
    notifyListeners();
  }

  Future<void> setAllowBadCert(bool v) async {
    if (_allowBadCert == v) return;
    _allowBadCert = v;
    await _prefs.setBool(_badCertKey, v);
    notifyListeners();
  }

  /// 供 transport 使用的当前配置。
  HttpClientTransport buildTransport() =>
      HttpClientTransport(allowBadCertificate: _allowBadCert);
}
