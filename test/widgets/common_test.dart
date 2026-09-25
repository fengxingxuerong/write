import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/widgets/common.dart';

/// 通用组件单元测试
///
/// 覆盖：EmptyState、SavedBadge、SectionCard、showConfirmDialog。

void main() {
  group('EmptyState', () {
    testWidgets('使用默认参数渲染', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: EmptyState())),
      );

      expect(find.byIcon(Icons.inbox_outlined), findsOneWidget);
      expect(find.text('暂无内容'), findsOneWidget);
    });

    testWidgets('自定义参数渲染', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmptyState(message: '没有找到数据', icon: Icons.search_off),
          ),
        ),
      );

      expect(find.byIcon(Icons.search_off), findsOneWidget);
      expect(find.text('没有找到数据'), findsOneWidget);
    });
  });

  group('SavedBadge', () {
    testWidgets('渲染已保存标签', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SavedBadge())),
      );

      expect(find.text('已保存'), findsOneWidget);
      // 设计改成不抢注意力的静默小圆点（以前是一个带图的 Chip）。
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      expect(find.byType(Chip), findsNothing);
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
        findsOneWidget,
      );
    });
  });

  group('SectionCard', () {
    testWidgets('渲染标题', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionCard(title: '测试卡片', children: [Text('内容')]),
          ),
        ),
      );

      expect(find.text('测试卡片'), findsOneWidget);
      expect(find.text('内容'), findsOneWidget);
    });

    testWidgets('渲染操作按钮', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SectionCard(
              title: '带操作的卡片',
              actions: [
                IconButton(icon: const Icon(Icons.add), onPressed: () {}),
              ],
              children: const [Text('正文')],
            ),
          ),
        ),
      );

      expect(find.text('带操作的卡片'), findsOneWidget);
      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('无操作按钮时不渲染空位', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SectionCard(title: '无操作', actions: null, children: []),
          ),
        ),
      );

      expect(find.text('无操作'), findsOneWidget);
    });
  });

  group('EmptyState 动作', () {
    testWidgets('主行动与次行动分别触发回调', (tester) async {
      int primary = 0;
      int secondary = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EmptyState(
              message: '还没有内容',
              hint: '先创建一条再回来',
              actionLabel: '立即创建',
              onAction: () => primary++,
              secondaryLabel: '稍后再说',
              onSecondary: () => secondary++,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('还没有内容'), findsOneWidget);
      expect(find.text('先创建一条再回来'), findsOneWidget);
      await tester.tap(find.text('立即创建'));
      await tester.pump();
      expect(primary, 1);
      await tester.tap(find.text('稍后再说'));
      await tester.pump();
      expect(secondary, 1);
    });
  });

  group('showConfirmDialog danger 分支', () {
    testWidgets('danger 默认使用删除图标且确认返回 true', (tester) async {
      late bool result;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showConfirmDialog(
                    context,
                    title: '删除作品',
                    content: '不可恢复',
                    danger: true,
                    confirmLabel: '删除',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_forever_outlined), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });
  });

  group('showTextPromptDialog', () {
    Widget host(Future<void> Function(BuildContext) open) => MaterialApp(
      theme: ThemeData(splashFactory: NoSplash.splashFactory),
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => open(context),
            child: const Text('打开输入框'),
          ),
        ),
      ),
    );

    testWidgets('取消返回 null，空值提交给出校验错误', (tester) async {
      String? result = '未调用';
      await tester.pumpWidget(
        host((context) async {
          result = await showTextPromptDialog(
            context,
            title: '新建作品',
            label: '作品名',
            hint: '例如：长夜灯未灭',
          );
        }),
      );
      await tester.tap(find.text('打开输入框'));
      await tester.pumpAndSettle();

      expect(find.text('新建作品'), findsOneWidget);
      expect(find.text('例如：长夜灯未灭'), findsOneWidget);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('不能为空'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('自定义校验错误会显示，合法值 trim 后返回', (tester) async {
      String? result;
      await tester.pumpWidget(
        host((context) async {
          result = await showTextPromptDialog(
            context,
            title: '重命名',
            label: '作品名',
            initial: '旧名',
            validate: (String value) => value.length < 3 ? '至少 3 个字' : null,
          );
        }),
      );
      await tester.tap(find.text('打开输入框'));
      await tester.pumpAndSettle();

      final Finder field = find.byType(TextField);
      await tester.enterText(field, '新');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.text('至少 3 个字'), findsOneWidget);

      await tester.enterText(field, '  新作品名  ');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(result, '新作品名');
    });
  });
  group('showConfirmDialog', () {
    testWidgets('点击确定返回 true', (tester) async {
      late bool result;

      await tester.pumpWidget(
        MaterialApp(
          // NoSplash 绕开 flutter_tester 无法解码 ink_sparkle.frag 的环境问题。
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showConfirmDialog(
                    context,
                    title: '确认删除',
                    content: '确定要删除这条数据吗？',
                  );
                },
                child: const Text('打开弹窗'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开弹窗'));
      await tester.pumpAndSettle();

      expect(find.text('确认删除'), findsOneWidget);
      expect(find.text('确定要删除这条数据吗？'), findsOneWidget);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      expect(result, isTrue);
    });

    testWidgets('点击取消返回 false', (tester) async {
      late bool result;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showConfirmDialog(
                    context,
                    title: '提示',
                    content: '内容',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });

    testWidgets('自定义按钮文案', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showConfirmDialog(
                  context,
                  title: '提示',
                  content: '内容',
                  confirmLabel: '确认删除',
                  cancelLabel: '返回',
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('确认删除'), findsOneWidget);
      expect(find.text('返回'), findsOneWidget);
    });

    testWidgets('点击外部（barrier）返回 false', (tester) async {
      late bool result;

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(splashFactory: NoSplash.splashFactory),
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showConfirmDialog(
                    context,
                    title: '提示',
                    content: '内容',
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      // 点击 barrier（弹窗外部区域）
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(result, isFalse);
    });
  });
}
