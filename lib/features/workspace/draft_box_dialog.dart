import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/models/chapter_draft.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/chapter_repository.dart';

/// 存稿箱弹窗：查看暂存的草稿，可预览、转正为正式章节或删除。
class DraftBoxDialog extends ConsumerStatefulWidget {
  /// 构造存稿箱。
  const DraftBoxDialog({
    super.key,
    required this.novel,
  });

  /// 当前项目。
  final Novel novel;

  @override
  ConsumerState<DraftBoxDialog> createState() => _DraftBoxDialogState();
}

class _DraftBoxDialogState extends ConsumerState<DraftBoxDialog> {
  List<ChapterDraft> _drafts = const <ChapterDraft>[];
  bool _loading = true;

  ChapterRepository get _repo =>
      ref.read(chapterRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<ChapterDraft> drafts =
        await _repo.listDrafts(widget.novel.id);
    if (!mounted) return;
    setState(() {
      _drafts = drafts;
      _loading = false;
    });
  }

  Future<void> _promote(String draftId) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('转为正式章节'),
        content: const Text('将把该存稿作为新章节追加到章节列表末尾，并从存稿箱移除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('转正'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _repo.promoteDraft(widget.novel.id, draftId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ 已转为正式章节')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('转正失败：$e')),
      );
    }
  }

  Future<void> _delete(String draftId) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除存稿'),
        content: const Text('该存稿将被永久删除，确定？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _repo.deleteDraft(widget.novel.id, draftId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已删除存稿')),
    );
    await _load();
  }

  void _preview(ChapterDraft draft) {
    showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(draft.title),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              draft.content,
              style: const TextStyle(fontSize: 14, height: 1.6),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('存稿箱'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _drafts.isEmpty
                ? const Center(
                    child: Text(
                      '暂无存稿\n\n不满意的 AI 生成结果可先存入这里，\n之后决定保留或删除',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.separated(
                    itemCount: _drafts.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final ChapterDraft d = _drafts[index];
                      return ListTile(
                        dense: true,
                        title: Text(
                          d.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${d.wordCount()} 字 · ${d.createdAt.toLocal().toString().substring(0, 16)}',
                        ),
                        onTap: () => _preview(d),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              icon: const Icon(Icons.visibility, size: 18),
                              tooltip: '预览',
                              onPressed: () => _preview(d),
                            ),
                            IconButton(
                              icon: const Icon(Icons.library_add, size: 18),
                              tooltip: '转为正式章节',
                              onPressed: () => _promote(d.id),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18),
                              tooltip: '删除',
                              onPressed: () => _delete(d.id),
                            ),
                          ],
                        ),
                      );
                    },
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

/// 打开存稿箱弹窗。
Future<void> showDraftBoxDialog(BuildContext context, Novel novel) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => DraftBoxDialog(novel: novel),
  );
}
