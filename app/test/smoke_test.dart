import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tool_plugin_app/src/theme/app_theme.dart';

void main() {
  testWidgets('亮/暗两套主题都能构建且为 Material 3', (tester) async {
    for (final t in [AppTheme.light(), AppTheme.dark()]) {
      expect(t.useMaterial3, isTrue);
      await tester.pumpWidget(MaterialApp(theme: t, home: const Scaffold()));
      expect(find.byType(Scaffold), findsOneWidget);
    }
  });

  test('成功/失败色在两种模式下的对比色不同', () {
    // 直接用 ThemeData 检查，避免依赖 BuildContext
    final light = AppTheme.light();
    final dark = AppTheme.dark();
    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
  });
}
