import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';

/// 编辑器查找替换逻辑（Ctrl+F 搜索条）。
///
/// 作为 mixin 混入 [ConsumerState]：提供查找/替换状态与全部操作，
/// 宿主类持有正文 [TextEditingController]（[editorController]）与
/// 保存/复查回调（[onApplyEdit]），其余依赖（敏感词复查）由宿主实现。
mixin EditorSearchMixin<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  /// 正文输入控制器（宿主提供）。
  TextEditingController get editorController;

  /// 文本被替换/应用后触发（宿主负责保存 + 敏感词复查）。
  void onApplyEdit(String newText);

  // ---- 查找替换状态 ----
  final TextEditingController searchCtrl = TextEditingController();
  final TextEditingController replaceCtrl = TextEditingController();
  final FocusNode searchFocus = FocusNode();
  bool searchOpen = false;
  List<Match> matches = <Match>[];
  int matchIndex = 0;

  /// 查找：收集所有匹配，跳转到当前索引并选中。
  void doSearch(String query, {bool select = true}) {
    final String text = editorController.text;
    if (query.isEmpty) {
      setState(() => matches = <Match>[]);
      return;
    }
    final List<Match> ms = <Match>[];
    try {
      for (final Match m in RegExp(RegExp.escape(query)).allMatches(text)) {
        ms.add(m);
      }
    } catch (_) {}
    setState(() {
      matches = ms;
      if (matchIndex >= ms.length) matchIndex = 0;
      if (select && ms.isNotEmpty) selectMatch(ms[matchIndex]);
    });
  }

  /// 选中第 [idx] 个匹配（用 selection 让用户直接看到）。
  void selectMatch(Match m) {
    editorController.selection = TextSelection(
      baseOffset: m.start,
      extentOffset: m.end,
    );
  }

  /// 跳到下一个/上一个匹配（循环）。
  void jumpMatch(int delta) {
    if (matches.isEmpty) return;
    final int next = (matchIndex + delta + matches.length) % matches.length;
    setState(() {
      matchIndex = next;
      selectMatch(matches[next]);
    });
  }

  /// 替换当前匹配（保持选中下一个）。
  void replaceCurrent() {
    if (matches.isEmpty) return;
    final Match m = matches[matchIndex];
    final String replacement = replaceCtrl.text;
    final TextEditingValue v = editorController.value;
    final String replaced = v.text.replaceRange(m.start, m.end, replacement);
    editorController.value = TextEditingValue(
      text: replaced,
      selection: TextSelection.collapsed(offset: m.start + replacement.length),
    );
    onApplyEdit(replaced);
    // 宿主 onApplyEdit 内已按新文本重建 matches（select: false），
    // 这里只校准索引到「替换位置之后第一个匹配」，不再重复全量搜索，
    // 也避免 jumpMatch(0) 因 delta=0 停留在替换位置上的旧匹配。
    final int anchor = m.start + replacement.length;
    int next = 0;
    while (next < matches.length && matches[next].start < anchor) {
      next++;
    }
    if (next >= matches.length) next = 0;
    setState(() {
      matchIndex = next;
      if (matches.isNotEmpty) selectMatch(matches[next]);
    });
  }

  /// 全部替换。
  void replaceAll() {
    final String query = searchCtrl.text;
    if (query.isEmpty) return;
    final String replacement = replaceCtrl.text;
    final String text = editorController.text;
    final String replaced =
        text.replaceAll(RegExp(RegExp.escape(query)), replacement);
    if (replaced == text) return;
    editorController.value = TextEditingValue(
      text: replaced,
      selection: const TextSelection.collapsed(offset: 0),
    );
    onApplyEdit(replaced);
    setState(() => matches = <Match>[]);
  }

  /// 切换查找条开合。
  void toggleSearch() {
    setState(() {
      searchOpen = !searchOpen;
      if (searchOpen) {
        matches = <Match>[];
        matchIndex = 0;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          searchFocus.requestFocus();
        });
      }
    });
  }

  /// 查找条 UI（展开时显示在工具栏下方）。
  Widget buildSearchBar(BuildContext context) {
    final bool hasMatch = matches.isNotEmpty;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: searchCtrl,
              focusNode: searchFocus,
              decoration: InputDecoration(
                isDense: true,
                hintText: '查找…',
                border: const OutlineInputBorder(),
                suffixIcon: searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        tooltip: '清空搜索',
                        onPressed: () {
                          searchCtrl.clear();
                          doSearch('');
                        },
                      ),
              ),
              style: AppFonts.text(Theme.of(context).colorScheme.onSurface,
                  size: 13),
              onChanged: (v) {
                setState(() => matchIndex = 0);
                doSearch(v);
              },
              onSubmitted: (_) => jumpMatch(1),
            ),
          ),
          const SizedBox(width: 8),
          // 匹配计数：x / y。
          SizedBox(
            width: 52,
            child: Text(
              hasMatch
                  ? '${matchIndex + 1} / ${matches.length}'
                  : (searchCtrl.text.isEmpty ? '' : '0 / 0'),
              textAlign: TextAlign.center,
              style: AppFonts.text(
                  Theme.of(context).colorScheme.onSurfaceVariant,
                  size: 12),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
            tooltip: '上一个',
            visualDensity: VisualDensity.compact,
            onPressed: hasMatch ? () => jumpMatch(-1) : null,
          ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 18),
            tooltip: '下一个',
            visualDensity: VisualDensity.compact,
            onPressed: hasMatch ? () => jumpMatch(1) : null,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: TextField(
              controller: replaceCtrl,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '替换为…',
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: hasMatch ? replaceCurrent : null,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('替换', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: hasMatch ? replaceAll : null,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('全部替换', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 释放查找替换资源。
  void disposeSearch() {
    searchCtrl.dispose();
    replaceCtrl.dispose();
    searchFocus.dispose();
  }
}
