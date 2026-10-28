import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 应用主题。
///
/// 设计取向：深色为主（运营商/网络类工具多在弱光环境下用）、
/// 低饱和背景 + 单一强调色，避免花哨渐变盖住状态信息。
abstract final class AppTheme {
  /// 强调色：青蓝。深浅模式只调整明度，保持品牌一致。
  static const _seed = Color(0xFF2AA9C9);

  /// 页面留白与圆角，两套主题共用，保证布局不随模式抖动。
  static const spacing = 16.0;
  static const radius = 14.0;

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme =
        ColorScheme.fromSeed(seedColor: _seed, brightness: brightness).copyWith(
          // 深色底不用纯黑，留一点蓝味，长时间看不发闷
          surface: isDark ? const Color(0xFF0F1418) : const Color(0xFFFAFAFA),
          surfaceContainerHighest: isDark
              ? const Color(0xFF1A2127)
              : const Color(0xFFEFF1F3),
          outlineVariant: isDark
              ? const Color(0xFF2A333B)
              : const Color(0xFFDCE0E4),
        );

    final base = ThemeData(
      colorScheme: scheme,
      brightness: brightness,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
    );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        centerTitle: false,
        systemOverlayStyle: isDark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        titleTextStyle: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: scheme.surfaceContainerHighest.withValues(
          alpha: isDark ? 0.55 : 0.7,
        ),
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outlineVariant, width: 0.8),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(50),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
            : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 1.2),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.8,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      listTileTheme: const ListTileThemeData(
        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      ),
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),
    );
  }

  /// 状态色：成功/失败/进行中。刻意不用 M3 默认色板，
  /// 保证与品牌青蓝并排时不打架。
  static Color success(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark
      ? const Color(0xFF4ECB71)
      : const Color(0xFF1F8A47);

  static Color failure(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark
      ? const Color(0xFFFF6B6B)
      : const Color(0xFFC62828);

  static Color pending(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark
      ? const Color(0xFF8B9AA6)
      : const Color(0xFF6B7780);
}
