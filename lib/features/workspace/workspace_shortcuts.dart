import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 工作区快捷键绑定。
///
/// 抽成独立组件是为了能单独挂载测试：整页工作区依赖真实文件 I/O，
/// 在 widget 测试的假时钟下无法可靠完成加载。
class WorkspaceShortcuts extends StatelessWidget {
  /// 构造快捷键容器。
  const WorkspaceShortcuts({
    super.key,
    required this.child,
    required this.onSave,
    required this.onGenerate,
    required this.onExport,
    required this.onNewChapter,
    required this.onSearch,
    required this.onToggleFocus,
    required this.onShowHelp,
  });

  final Widget child;
  final VoidCallback onSave;
  final VoidCallback onGenerate;
  final VoidCallback onExport;
  final VoidCallback onNewChapter;
  final VoidCallback onSearch;
  final VoidCallback onToggleFocus;
  final VoidCallback onShowHelp;

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): onSave,
        const SingleActivator(LogicalKeyboardKey.keyB, control: true):
            onGenerate,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): onExport,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true):
            onNewChapter,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true): onSearch,
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): onSearch,
        const SingleActivator(LogicalKeyboardKey.f11): onToggleFocus,
        const SingleActivator(LogicalKeyboardKey.slash, control: true):
            onShowHelp,
      },
      child: child,
    );
  }
}

/// 键位速查表：应用内与 README 共用同一份口径。
const List<(String, String)> shortcutHelpItems = <(String, String)>[
  ('Ctrl+S', '保存全部章节'),
  ('Ctrl+B', '一键生成续写'),
  ('Ctrl+E', '导出当前小说'),
  ('Ctrl+N', '新增章节'),
  ('Ctrl+F', '编辑器内查找替换'),
  ('Ctrl+Shift+F', '全书搜索'),
  ('F11', '专注模式：收起左右栏'),
  ('Ctrl+/', '本键位速查'),
];
