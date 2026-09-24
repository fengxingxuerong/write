import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/project_list/crash_logs_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory crashDir;
  late Directory supportDir;

  setUp(() async {
    // 在 testWidgets 外执行（普通 zone），真实 IO 正常。
    tempDir = await Directory.systemTemp.createTemp('mojiang-crash-');
    supportDir = Directory('${tempDir.path}/support');
    supportDir.createSync(recursive: true);
    crashDir = Directory('${tempDir.path}/crash_logs');
    crashDir.createSync(recursive: true);
  });

  tearDown(() async {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget wrap(Widget child) =>
      // NoSplash 绕开 flutter_tester 无法解码 ink_sparkle.frag 的环境问题。
      MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(body: child),
      );

  void seedLog(String name, String content) {
    File('${crashDir.path}/$name').writeAsStringSync(content);
  }

  testWidgets('无日志时显示空态提示', (tester) async {
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    expect(find.text('🎉 暂无崩溃日志，运行一切正常'), findsOneWidget);
    expect(find.text('崩溃日志（0）'), findsOneWidget);
  });

  testWidgets('有日志时显示列表，点击查看内容', (tester) async {
    seedLog('crash-20260806-100000.log', '===== 崩溃日志 =====\nerror: test');
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    expect(find.text('崩溃日志（1）'), findsOneWidget);
    expect(find.text('crash-20260806-100000.log'), findsOneWidget);
    await tester.tap(find.text('crash-20260806-100000.log'));
    await tester.pump();
    expect(find.textContaining('===== 崩溃日志 ====='), findsOneWidget);
    expect(find.text('复制'), findsOneWidget);
  });

  testWidgets('点击复制按钮复制内容到剪贴板', (tester) async {
    // mock 剪贴板平台通道（否则 Clipboard.getData 的 Future 永不完成）。
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map<dynamic, dynamic>)['text']
              as String?;
        }
        return null;
      },
    );
    seedLog('crash-a.log', 'content-to-copy');
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    await tester.tap(find.text('crash-a.log'));
    await tester.pump();
    await tester.tap(find.text('复制'));
    await tester.pump();
    expect(clipboardText, contains('content-to-copy'));
  });

  testWidgets('删除单条日志后列表刷新', (tester) async {
    seedLog('crash-1.log', 'one');
    seedLog('crash-2.log', 'two');
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    expect(find.text('崩溃日志（2）'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('崩溃日志（1）'), findsOneWidget);
  });

  testWidgets('全部清除按钮删除所有日志', (tester) async {
    seedLog('crash-1.log', 'one');
    seedLog('crash-2.log', 'two');
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    await tester.tap(find.text('全部清除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(find.text('🎉 暂无崩溃日志，运行一切正常'), findsOneWidget);
    expect(find.text('崩溃日志（0）'), findsOneWidget);
  });

  testWidgets('未配置上报时显示「上报设置」按钮且可打开设置弹窗', (tester) async {
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    expect(find.text('上报设置'), findsOneWidget);
    await tester.tap(find.text('上报设置'));
    await tester.pumpAndSettle();
    expect(find.text('崩溃上报设置'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('保存上报 URL 后按钮显示已配置状态', (tester) async {
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    await tester.tap(find.text('上报设置'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://s.example.com/crash');
    await tester.tap(find.text('保存'));
    // 等待对话框 pop 动画完成 + SnackBar 结束
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    // 配置已保存：按钮显示 ✓
    expect(find.text('上报设置 ✓'), findsOneWidget);
    // 配置文件已落盘
    final File cfg = File('${supportDir.path}/crash_report_config.json');
    expect(cfg.existsSync(), isTrue);
    expect(cfg.readAsStringSync(), contains('https://s.example.com/crash'));
  });

    testWidgets('拒绝保存非 HTTPS 上报 URL', (tester) async {
      await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
      await tester.pump();
      await tester.tap(find.text('上报设置'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'http://s.example.com/crash');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('必须是有效的 HTTPS URL'), findsOneWidget);
      expect(File('${supportDir.path}/crash_report_config.json').existsSync(), isFalse);
    });


  testWidgets('未配置上报时点「上报」提示先配置 URL', (tester) async {
    seedLog('crash-1.log', 'some crash content');
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir, supportDir: supportDir)));
    await tester.pump();
    await tester.tap(find.text('crash-1.log'));
    await tester.pump();
    expect(find.text('上报'), findsOneWidget);
    await tester.tap(find.text('上报'));
    await tester.pump();
    expect(find.textContaining('请先点击'), findsOneWidget);
    // 推进 SnackBar 生命周期
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
