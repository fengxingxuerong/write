import 'package:flutter/material.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/core/utils/manuscript_parser.dart';
import 'package:novel_writer/core/utils/text_fmt.dart';
import 'package:novel_writer/storage/manuscript_import_service.dart';

/// 书架导入来源。
enum ImportSource {
  /// 墨匠 JSON 备份。
  backup,

  /// TXT / Markdown 原稿。
  manuscript,
}

/// 选择导入来源。
Future<ImportSource?> showImportSourceDialog(BuildContext context) {
  return showDialog<ImportSource>(
    context: context,
    builder: (BuildContext ctx) => SimpleDialog(
      title: const Text('导入到书架'),
      children: <Widget>[
        _SourceOption(
          icon: Icons.inventory_2_outlined,
          title: '墨匠 JSON 备份',
          subtitle: '恢复完整作品：章节、角色、世界观一次带回',
          onTap: () => Navigator.of(ctx).pop(ImportSource.backup),
        ),
        _SourceOption(
          icon: Icons.description_outlined,
          title: 'TXT / Markdown 原稿',
          subtitle: '自动识别「第 X 章」等标题，拆章后继续写',
          onTap: () => Navigator.of(ctx).pop(ImportSource.manuscript),
        ),
      ],
    ),
  );
}

class _SourceOption extends StatelessWidget {
  const _SourceOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    return SimpleDialogOption(
      onPressed: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppTokens.s4,
        vertical: AppTokens.s2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 22, color: ink.primary),
          const SizedBox(width: AppTokens.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: AppFonts.text(
                    ink.ink,
                    size: 14,
                    weight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: AppFonts.text(ink.inkFaint, size: 12, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 原稿导入表单的返回值。
class ManuscriptImportDraft {
  const ManuscriptImportDraft({
    required this.title,
    required this.genre,
    required this.tone,
  });

  final String title;
  final String genre;
  final String tone;
}

/// 展示解析结果，让用户确认作品名 / 题材 / 基调后再入库。
Future<ManuscriptImportDraft?> showManuscriptImportPreview(
  BuildContext context,
  ManuscriptImportPreview preview,
) {
  return showDialog<ManuscriptImportDraft>(
    context: context,
    builder: (BuildContext ctx) => _ManuscriptImportPreviewDialog(preview),
  );
}

class _ManuscriptImportPreviewDialog extends StatefulWidget {
  const _ManuscriptImportPreviewDialog(this.preview);

  final ManuscriptImportPreview preview;

  @override
  State<_ManuscriptImportPreviewDialog> createState() =>
      _ManuscriptImportPreviewDialogState();
}

class _ManuscriptImportPreviewDialogState
    extends State<_ManuscriptImportPreviewDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.preview.suggestedTitle,
  );
  String _genre = GenrePresets.defaultKey;
  late String _tone = GenrePresets.get(_genre).tones.first;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _submit() {
    final String title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先给作品起个名字')));
      return;
    }
    Navigator.of(
      context,
    ).pop(ManuscriptImportDraft(title: title, genre: _genre, tone: _tone));
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final ParsedManuscript manuscript = widget.preview.manuscript;
    final List<String> tones = GenrePresets.get(_genre).tones;
    // 窄窗口（例如把桌面窗口拖到 600px）下固定 680 会横向溢出。
    final double available = MediaQuery.sizeOf(context).width - 96;
    final double dialogWidth = available < 680 ? available : 680;
    return AlertDialog(
      scrollable: true,
      title: const Text('导入原稿'),
      content: SizedBox(
        width: dialogWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '${widget.preview.fileName} · ${manuscript.chapters.length} 章 · '
              '${TextFmt.words(manuscript.totalWords)} 字',
              style: AppFonts.text(ink.inkFaint, size: 12.5, height: 1.5),
            ),
            if (!manuscript.detectedHeadings) ...<Widget>[
              const SizedBox(height: AppTokens.s3),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppTokens.s3),
                decoration: BoxDecoration(
                  color: ink.warn.withValues(alpha: ink.dark ? 0.16 : 0.08),
                  borderRadius: BorderRadius.circular(AppTokens.r2),
                  border: Border.all(color: ink.warn.withValues(alpha: 0.28)),
                ),
                child: Text(
                  '没有识别到「第 X 章」这类章节标题，整篇会作为 1 章导入。'
                  '导入后仍可在编辑器里手动拆分。',
                  style: AppFonts.text(ink.ink, size: 12.5, height: 1.6),
                ),
              ),
            ],
            const SizedBox(height: AppTokens.s4),
            TextField(
              controller: _title,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '作品名',
                hintText: '例：碎星航线',
              ),
            ),
            const SizedBox(height: AppTokens.s3),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 170,
                  child: DropdownButtonFormField<String>(
                    initialValue: _genre,
                    decoration: const InputDecoration(labelText: '题材'),
                    items: GenrePresets.all
                        .map(
                          (GenrePreset preset) => DropdownMenuItem<String>(
                            value: preset.key,
                            child: Text(preset.label),
                          ),
                        )
                        .toList(),
                    onChanged: (String? value) {
                      if (value == null) return;
                      setState(() {
                        _genre = value;
                        _tone = GenrePresets.get(value).tones.first;
                      });
                    },
                  ),
                ),
                const SizedBox(width: AppTokens.s3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '基调',
                        style: AppFonts.text(
                          ink.inkFaint,
                          size: 12,
                          weight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: AppTokens.s2 - 2),
                      Wrap(
                        spacing: AppTokens.s2,
                        runSpacing: AppTokens.s2 - 4,
                        children: tones
                            .map(
                              (String tone) => ChoiceChip(
                                label: Text(tone),
                                selected: tone == _tone,
                                onSelected: (_) => setState(() => _tone = tone),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTokens.s3),
            Text(
              '章节预览',
              style: AppFonts.text(
                ink.inkFaint,
                size: 12,
                weight: FontWeight.w600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: AppTokens.s2 - 2),
            Container(
              height: 220,
              decoration: BoxDecoration(
                color: ink.surface,
                borderRadius: BorderRadius.circular(AppTokens.r2),
                border: Border.all(color: ink.border),
              ),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: AppTokens.s2),
                itemCount: manuscript.chapters.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  indent: AppTokens.s3,
                  endIndent: AppTokens.s3,
                  color: ink.divider,
                ),
                itemBuilder: (BuildContext context, int index) {
                  final ParsedManuscriptChapter chapter =
                      manuscript.chapters[index];
                  final String previewText = chapter.content.replaceAll(
                    RegExp(r'\s+'),
                    ' ',
                  );
                  return ListTile(
                    dense: true,
                    leading: SizedBox(
                      width: 28,
                      child: Text(
                        '${index + 1}',
                        textAlign: TextAlign.right,
                        style: AppFonts.text(
                          ink.inkFaint,
                          size: 11.5,
                          monoFace: true,
                        ),
                      ),
                    ),
                    title: Text(
                      chapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.text(
                        ink.ink,
                        size: 13,
                        weight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      previewText.length > 68
                          ? '${previewText.substring(0, 68)}…'
                          : previewText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.text(ink.inkFaint, size: 11.5),
                    ),
                    trailing: Text(
                      '${chapter.wordCount} 字',
                      style: AppFonts.text(
                        ink.inkFaint,
                        size: 11.5,
                        monoFace: true,
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
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _submit,
          icon: const Icon(Icons.check, size: 16),
          label: const Text('导入为新作品'),
        ),
      ],
    );
  }
}
