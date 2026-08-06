import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/project_list/crash_logs_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late Directory crashDir;

  setUp(() async {
    // 在 testWidgets 外执行（普通 zone），真实 IO 正常。
    tempDir = await Directory.systemTemp.createTemp('mojiang-crash-');
    crashDir = Directory('${tempDir.path}/crash_logs');
    crashDir.createSync(recursive: true);
  });

  tearDown(() async {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget wrap(Widget child) =>
      MaterialApp(home: Scaffold(body: child));

  void seedLog(String name, String content) {
    File('${crashDir.path}/$name').writeAsStringSync(content);
  }

  testWidgets('无日志时显示空态提示', (tester) async {
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir)));
    await tester.pump();
    expect(find.text('🎉 暂无崩溃日志，运行一切正常'), findsOneWidget);
    expect(find.text('崩溃日志（0）'), findsOneWidget);
  });

  testWidgets('有日志时显示列表，点击查看内容', (tester) async {
    seedLog('crash-20260806-100000.log', '===== 崩溃日志 =====\nerror: test');
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir)));
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
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir)));
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
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir)));
    await tester.pump();
    expect(find.text('崩溃日志（2）'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.delete_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('崩溃日志（1）'), findsOneWidget);
  });

  testWidgets('全部清除按钮删除所有日志', (tester) async {
    seedLog('crash-1.log', 'one');
    seedLog('crash-2.log', 'two');
    await tester.pumpWidget(wrap(CrashLogsDialog(crashDir: crashDir)));
    await tester.pump();
    await tester.tap(find.text('全部清除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(find.text('🎉 暂无崩溃日志，运行一切正常'), findsOneWidget);
    expect(find.text('崩溃日志（0）'), findsOneWidget);
  });
}
