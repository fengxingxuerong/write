import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/editor/sensitive_check_dialog.dart';
import 'package:novel_writer/services/sensitive_words.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mojiang-sens-');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  Widget wrap(Widget child) =>
      ProviderScope(
        child: MaterialApp(
          // NoSplash 绕开 flutter_tester 无法解码 ink_sparkle.frag 的环境问题。
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(body: child),
        ),
      );

  testWidgets('干净结果：显示「内容安全」徽标与未发现提示', (tester) async {
    const result = SensitiveCheckResult(<SensitiveHit>[]);
    final service = SensitiveWordsService(
      customPath: '${tempDir.path}/custom.txt',
      statsPath: '${tempDir.path}/stats.json',
    );
    await tester.pumpWidget(
      wrap(SensitiveCheckDialog(result: result, service: service)),
    );
    expect(find.text('内容安全检查（0 处命中）'), findsOneWidget);
    expect(find.text('✓ 未发现敏感词'), findsOneWidget);
  });

  testWidgets('命中结果：显示分类统计与命中词', (tester) async {
    const result = SensitiveCheckResult(<SensitiveHit>[
      SensitiveHit(
        word: '暴力',
        category: '暴力血腥',
        start: 0,
        context: '画面血腥暴力',
      ),
    ]);
    final service = SensitiveWordsService(
      customPath: '${tempDir.path}/custom.txt',
      statsPath: '${tempDir.path}/stats.json',
    );
    await tester.pumpWidget(
      wrap(SensitiveCheckDialog(result: result, service: service)),
    );
    expect(find.text('内容安全检查（1 处命中）'), findsOneWidget);
    expect(find.text('暴力血腥 ×1'), findsOneWidget);
    expect(find.text('暴力'), findsOneWidget);
    expect(find.text('画面血腥暴力'), findsOneWidget);
  });

  testWidgets('历史命中统计区：有数据时显示 TOP 区', (tester) async {
    const result = SensitiveCheckResult(<SensitiveHit>[]);
    final service = SensitiveWordsService(
      customPath: '${tempDir.path}/custom.txt',
      statsPath: '${tempDir.path}/stats.json',
    );
    service.recordStats(result); // 空结果无命中
    // 手动注入历史统计
    await tester.pumpWidget(
      wrap(SensitiveCheckDialog(result: result, service: service)),
    );
    // 空统计时不显示历史区
    expect(find.textContaining('历史累计命中'), findsNothing);
  });

  testWidgets('添加自定义词并显示在列表', (tester) async {
    const result = SensitiveCheckResult(<SensitiveHit>[]);
    final service = SensitiveWordsService(
      customPath: '${tempDir.path}/custom.txt',
      statsPath: '${tempDir.path}/stats.json',
    );
    await tester.pumpWidget(
      wrap(SensitiveCheckDialog(result: result, service: service)),
    );
    await tester.enterText(find.byType(TextField), '测试敏感词');
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await tester.pump();
    expect(find.text('测试敏感词'), findsOneWidget);
    // 关闭对话框
    await tester.tap(find.text('关闭'));
    await tester.pump();
  });
}
