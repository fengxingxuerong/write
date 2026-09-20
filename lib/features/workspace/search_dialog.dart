import 'dart:async';

import 'package:flutter/material.dart';

import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/services/search_service.dart';

/// 全文搜索弹窗：输入关键词，实时列出命中章节与上下文片段。
class SearchDialog extends StatefulWidget {
  /// 构造搜索弹窗。
  const SearchDialog({super.key, required this.novel, required this.onSelect});

  /// 目标项目。
  final Novel novel;

  /// 点击命中时回调（跳转到对应章节）。
  final void Function(String chapterId, int offset) onSelect;

  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  final TextEditingController _controller = TextEditingController();
  final SearchService _service = SearchService();
  List<SearchHit> _hits = <SearchHit>[];

  /// 输入防抖句柄：全书扫描是同步 O(正文总长)，逐键直搜在大书上会拖慢输入。
  Timer? _debounce;

  void _search(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      setState(() => _hits = _service.search(widget.novel, query));
    });
  }

  /// 立即搜索（清空按钮等需要即时反馈的场景）。
  void _searchNow(String query) {
    _debounce?.cancel();
    setState(() => _hits = _service.search(widget.novel, query));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return AlertDialog(
      title: const Text('全文搜索'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          children: <Widget>[
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '搜索章节内容…',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: '清空',
                        onPressed: () {
                          _controller.clear();
                          _searchNow('');
                        },
                      ),
              ),
              onChanged: _search,
            ),
            const SizedBox(height: AppTokens.s3),
            Expanded(
              child: _hits.isEmpty
                  ? Center(
                      child: Text(
                        _controller.text.trim().isEmpty
                            ? '输入关键词开始搜索'
                            : '未找到「${_controller.text.trim()}」',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _hits.length,
                      separatorBuilder: (_, __) => const Divider(height: 8),
                      itemBuilder: (context, i) {
                        final SearchHit h = _hits[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(AppTokens.r2),
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onSelect(h.chapter.id, h.index);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(AppTokens.s2),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    Icon(Icons.article_outlined,
                                        size: 16,
                                        color: theme.colorScheme.primary),
                                    const SizedBox(width: 6),
                                    Expanded(
                                      child: Text(
                                        h.chapter.title,
                                        style: theme.textTheme.titleSmall,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      '第${h.chapter.order + 1}章',
                                      style: theme.textTheme.labelSmall,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  h.snippet,
                                  style: theme.textTheme.bodySmall,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
