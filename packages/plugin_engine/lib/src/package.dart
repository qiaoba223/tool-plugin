/// `.qbpkg` 信封与裸 manifest 的识别（对应上游 §13.2）。
///
/// 上游实现参考 `plugin-harbor/tools/build_index.py` 头部注释：
/// ```dart
/// const String kQbpkgVersion = '1.0';
/// const String kQbpkgExportedBy = '登录插件框架';
/// // encode():
/// {
///   'qbpkg': kQbpkgVersion,
///   'manifest': manifest,
///   'meta': {'exportedAt': ..., 'exportedBy': ..., 'note': ...},  // 空值字段省略
/// }
/// ```
/// 解码侧识别规则：顶层含 `qbpkg` 键 → 视为信封，取 `manifest` 继续；
/// 否则视为裸 manifest（向后兼容）。
library;

import 'dart:convert';

import 'errors.dart';

const String kQbpkgVersion = '1.0';
const String kQbpkgExportedBy = '登录插件框架';

/// 解码结果：原始 manifest map + 信封元信息（裸 manifest 时 meta 为 null）。
class DecodedPackage {
  final Map<String, dynamic> manifest;
  final Map<String, dynamic>? meta;
  final bool isEnvelope;
  const DecodedPackage({
    required this.manifest,
    required this.meta,
    required this.isEnvelope,
  });
}

/// 解析导入内容：既接受裸 manifest，也接受 `.qbpkg` 信封。
///
/// 两者都不是时报 `E_PKG_FORMAT`（上游附录 A）。
DecodedPackage decodePackage(String text) {
  // UTF-8 BOM 会被上游导入器拒绝（§13.6 坑 2）
  if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF) {
    throw err(ErrorCodes.pkgFormat, '内容以 UTF-8 BOM 开头，请保存为无 BOM 的 UTF-8');
  }
  final trimmed = text.trimLeft();
  if (!trimmed.startsWith('{')) {
    throw err(ErrorCodes.pkgFormat, '内容既不是裸 manifest 也不是 .qbpkg 信封（不是 JSON 对象）');
  }

  dynamic decoded;
  try {
    decoded = jsonDecode(text);
  } catch (e) {
    throw err(ErrorCodes.pkgFormat, 'JSON 解析失败：$e');
  }
  if (decoded is! Map) {
    throw err(ErrorCodes.pkgFormat, '顶层必须是 JSON 对象');
  }
  final map = Map<String, dynamic>.from(decoded);

  if (map.containsKey('qbpkg')) {
    final version = map['qbpkg'];
    if (version is! String) {
      throw err(ErrorCodes.pkgFormat, 'qbpkg 字段必须是字符串，实际是 ${version.runtimeType}');
    }
    final inner = map['manifest'];
    if (inner is! Map) {
      throw err(ErrorCodes.pkgFormat, '信封缺少 manifest 对象');
    }
    final meta = map['meta'];
    return DecodedPackage(
      manifest: Map<String, dynamic>.from(inner),
      meta: meta is Map ? Map<String, dynamic>.from(meta) : null,
      isEnvelope: true,
    );
  }

  return DecodedPackage(manifest: map, meta: null, isEnvelope: false);
}

/// 打包成 `.qbpkg` 信封（与上游 `PluginPackage.encode` 逐字一致）。
String encodePackage(
  Map<String, dynamic> manifest, {
  required String exportedAt,
  String exportedBy = kQbpkgExportedBy,
  String? note,
}) {
  final meta = <String, dynamic>{
    'exportedAt': exportedAt,
    'exportedBy': exportedBy,
    if (note != null && note.isNotEmpty) 'note': note,
  };
  return const JsonEncoder.withIndent('  ').convert({
    'qbpkg': kQbpkgVersion,
    'manifest': manifest,
    'meta': meta,
  });
}

/// 便捷类，供 UI 层使用。
class PluginPackage {
  const PluginPackage._();

  static DecodedPackage decode(String text) => decodePackage(text);
  static String encode(Map<String, dynamic> manifest,
          {required String exportedAt, String exportedBy = kQbpkgExportedBy, String? note}) =>
      encodePackage(manifest,
          exportedAt: exportedAt, exportedBy: exportedBy, note: note);
}
