import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/workspace/workspace_shortcuts.dart';

void main() {
  Future<void> sendChord(
    WidgetTester tester,
    List<LogicalKeyboardKey> modifiers,
    LogicalKeyboardKey key,
  ) async {
    for (final LogicalKeyboardKey modifier in modifiers) {
      await tester.sendKeyDownEvent(modifier);
    }
    await tester.sendKeyDownEvent(key);
    await tester.sendKeyUpEvent(key);
    for (final LogicalKeyboardKey modifier in modifiers.reversed) {
      await tester.sendKeyUpEvent(modifier);
    }
    await tester.pump();
  }

  testWidgets('每个键位都真的触发对应动作，Ctrl+F 与 Ctrl+Shift+F 都可搜全书', (
    WidgetTester tester,
  ) async {
    final List<String> calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceShortcuts(
            onSave: () => calls.add('save'),
            onGenerate: () => calls.add('generate'),
            onExport: () => calls.add('export'),
            onNewChapter: () => calls.add('newChapter'),
            onSearch: () => calls.add('search'),
            onToggleFocus: () => calls.add('focus'),
            onShowHelp: () => calls.add('help'),
            child: const Focus(autofocus: true, child: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();

    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.keyS);
    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.keyB);
    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.keyE);
    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.keyN);
    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.keyF);
    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
      LogicalKeyboardKey.shiftLeft,
    ], LogicalKeyboardKey.keyF);
    await sendChord(
      tester,
      const <LogicalKeyboardKey>[],
      LogicalKeyboardKey.f11,
    );
    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.slash);

    expect(calls, <String>[
      'save',
      'generate',
      'export',
      'newChapter',
      'search',
      'search',
      'focus',
      'help',
    ]);
  });

  test('键位速查包含用户真正能按到的快捷键', () {
    final Map<String, String> items = <String, String>{
      for (final (String keys, String desc) in shortcutHelpItems) keys: desc,
    };
    expect(
      items.keys,
      containsAll(<String>[
        'Ctrl+S',
        'Ctrl+B',
        'Ctrl+E',
        'Ctrl+N',
        'Ctrl+F',
        'Ctrl+Shift+F',
        'F11',
        'Ctrl+/',
      ]),
    );
  });

  testWidgets('编辑器内 Ctrl+F 优先于工作区的全书搜索', (WidgetTester tester) async {
    int editorFind = 0;
    int bookSearch = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceShortcuts(
            onSave: () {},
            onGenerate: () {},
            onExport: () {},
            onNewChapter: () {},
            onSearch: () => bookSearch++,
            onToggleFocus: () {},
            onShowHelp: () {},
            child: Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.keyF, control: true):
                    ActivateIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      editorFind++;
                      return null;
                    },
                  ),
                },
                child: const Focus(autofocus: true, child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await sendChord(tester, <LogicalKeyboardKey>[
      LogicalKeyboardKey.controlLeft,
    ], LogicalKeyboardKey.keyF);

    expect(editorFind, 1);
    expect(bookSearch, 0);
  });
}
