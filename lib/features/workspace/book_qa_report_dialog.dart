import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:novel_writer/ai_pipeline/services/book_qa_service.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/widgets/app_feedback.dart';
import 'package:novel_writer/widgets/page_shell.dart';

/// 打开全书体检弹窗（书架入口）。
Future<void> showBookQaReportDialog(BuildContext context, Novel novel) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => Dialog(
      child: SizedBox(
        width: 720,
        height: 640,
        child: BookQaReportDialog(novel: novel),
      ),
    ),
  );
}

/// 全书体检报告弹窗：本地零成本扫全书，输出总分卡 + 章节问题 + 定点修。
class BookQaReportDialog extends StatefulWidget {
  /// 构造弹窗。
  const BookQaReportDialog({super.key, required this.novel});

  /// 被检项目。
  final Novel novel;

  @override
  State<BookQaReportDialog> createState() => _BookQaReportDialogState();
}

class _BookQaReportDialogState extends State<BookQaReportDialog> {
  final BookQaService _service = const BookQaService();
  BookQaReport? _report;
  bool _running = false;
  bool _exporting = false;
  final Set<int> _expanded = <int>{};

  @override
  void initState() {
    super.initState();
    if (widget.novel.chapters.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _run());
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _expanded.clear();
    });
    // 计算放下一帧，让「体检中」先渲染。
    await Future<void>.delayed(Duration.zero);
    final BookQaReport r = _service.check(widget.novel);
    if (!mounted) return;
    setState(() {
      _report = r;
      _running = false;
      // 默认展开第一个不达标章，直达要修的地方。
      if (r.failing.isNotEmpty) _expanded.add(r.failing.first.chapter.order);
    });
  }

  Future<void> _export() async {
    final BookQaReport? r = _report;
    if (r == null || _exporting) return;
    final String? path = await FilePicker.platform.saveFile(
      dialogTitle: '导出体检报告',
      fileName: '${r.novel.title}_体检报告.txt',
      type: FileType.custom,
      allowedExtensions: const <String>['txt'],
    );
    if (path == null || !mounted) return;
    setState(() => _exporting = true);
    try {
      await r.exportText(path);
      if (!mounted) return;
      AppToast.success(context, '已导出：$path');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  void _copyFixPrompt(BookChapterQa row) {
    Clipboard.setData(ClipboardData(text: row.fixPrompt));
    AppToast.success(context, '定点修指令已复制，可粘贴给编辑器 AI');
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final BookQaReport? r = _report;
    return Column(
      children: <Widget>[
        // 标题栏。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '全书体检 · ${widget.novel.title}',
                  style: Theme.of(context).textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (widget.novel.chapters.isEmpty)
          const Expanded(
            child: Center(child: Text('这本书还没有章节，先写或生成一章再体检')),
          )
        else if (_running)
          const Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  CircularProgressIndicator(strokeWidth: 2.2),
                  SizedBox(height: AppTokens.s3),
                  Text('正在逐章体检（本地规则，不调 API）…'),
                ],
              ),
            ),
          )
        else if (r != null)
          Expanded(child: _buildReport(r, ink)),
        // 底部操作。
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0x1A000000))),
          ),
          child: Row(
            children: <Widget>[
              TextButton.icon(
                onPressed:
                    _running || widget.novel.chapters.isEmpty ? null : _run,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重新体检'),
              ),
              const Spacer(),
              ToolButton(
                icon: Icons.save_alt,
                label: _exporting ? '导出中…' : '导出报告 (.txt)',
                onPressed: (_report == null || _exporting) ? null : _export,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReport(BookQaReport r, AppInk ink) {
    return ListView(
      padding: const EdgeInsets.all(AppTokens.s4),
      children: <Widget>[
        // ---- 总分卡 ----
        Row(
          children: <Widget>[
            _scoreCard(
              '全书平均分',
              r.avgScore.toStringAsFixed(0),
              sub: r.allPass ? '全部达线' : '${r.failing.length} 章需处理',
              color: _scoreColor(r.avgScore, ink),
            ),
            const SizedBox(width: AppTokens.s3),
            _scoreCard(
              '达线章节',
              '${r.passCount}/${r.totalChapters}',
              sub: '阈值 ${BookQaService.passThreshold.toStringAsFixed(0)} 分',
              color: r.allPass ? ink.success : ink.warn,
            ),
            const SizedBox(width: AppTokens.s3),
            _scoreCard(
              '合规红线',
              '${r.vetoCount} 章',
              sub: r.vetoCount == 0 ? '未命中' : '需人工复核',
              color: r.vetoCount == 0 ? ink.success : ink.danger,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '共 ${r.totalChapters} 章 · ${r.totalWords} 字 · 纯本地规则质检（零 API 成本）',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 24),

        // ---- 章节列表 ----
        if (r.rows.isEmpty)
          const Center(child: Text('没有可体检的章节'))
        else
          ...r.rows.map((BookChapterQa row) => _buildChapterTile(row, ink)),
      ],
    );
  }

  Widget _buildChapterTile(BookChapterQa row, AppInk ink) {
    final int order = row.chapter.order;
    final bool expanded = _expanded.contains(order);
    final Color statusColor = row.hasVeto
        ? ink.danger
        : (row.pass ? ink.success : ink.warn);
    return Card(
      margin: const EdgeInsets.only(bottom: AppTokens.s2),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTokens.r2),
        onTap: () => setState(() {
          if (!expanded) {
            _expanded.add(order);
          } else {
            _expanded.remove(order);
          }
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppTokens.r3),
                      border:
                          Border.all(color: statusColor.withValues(alpha: 0.5)),
                    ),
                    child: Text(
                      row.statusLabel,
                      style: AppFonts.text(
                        statusColor,
                        size: 11,
                        weight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '第 $order 章 ${row.chapter.title}',
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.text(ink.ink,
                          weight: FontWeight.w600, height: 1.3),
                    ),
                  ),
                  Text(
                    '${row.score.toStringAsFixed(0)} 分 · ${row.words} 字',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20),
                ],
              ),
              if (expanded) ...<Widget>[
                const SizedBox(height: 8),
                if (row.allIssues.isEmpty)
                  const Text('未发现问题')
                else
                  ...row.allIssues.map(
                    (String i) => Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('· '),
                          Expanded(
                            child: Text(
                              i,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (row.fixPrompt.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => _copyFixPrompt(row),
                      icon: const Icon(Icons.copy, size: 15),
                      label: Text('复制定点修指令',
                          style: AppFonts.text(ink.ink, size: 12, height: 1.3)),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _scoreCard(
    String label,
    String value, {
    required String sub,
    required Color color,
  }) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(AppTokens.s3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(AppTokens.r3),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 2),
            Text(
              value,
              style: AppFonts.text(
                color,
                size: 22,
                weight: FontWeight.w700,
                height: 1.2,
              ),
            ),
            Text(sub, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }

  Color _scoreColor(double score, AppInk ink) {
    if (score >= 80) return ink.success;
    if (score >= 60) return ink.warn;
    return ink.danger;
  }
}