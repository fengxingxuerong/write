import 'package:flutter/material.dart';

import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/models/novel.dart';

/// 作品信息编辑结果。
class NovelInfoDraft {
  const NovelInfoDraft({
    required this.title,
    required this.genre,
    required this.tone,
    required this.targetWordsPerChapter,
  });

  final String title;
  final String genre;
  final String tone;
  final int targetWordsPerChapter;
}

/// 编辑作品名 / 题材 / 基调 / 单章目标字数。
///
/// 题材与基调不是「创建时的一次性设置」：它们会进入生成提示词、封面配色与
/// 质检口径，后续改主意时必须有地方能改。
Future<NovelInfoDraft?> showNovelInfoDialog(
  BuildContext context, {
  required Novel novel,
}) {
  return showDialog<NovelInfoDraft>(
    context: context,
    builder: (BuildContext ctx) => _NovelInfoDialog(novel),
  );
}

class _NovelInfoDialog extends StatefulWidget {
  const _NovelInfoDialog(this.novel);

  final Novel novel;

  @override
  State<_NovelInfoDialog> createState() => _NovelInfoDialogState();
}

class _NovelInfoDialogState extends State<_NovelInfoDialog> {
  late final TextEditingController _title = TextEditingController(
    text: widget.novel.title,
  );
  late final TextEditingController _targetWords = TextEditingController(
    text: '${widget.novel.targetWordsPerChapter}',
  );
  late String _genre =
      GenrePresets.all.any(
        (GenrePreset preset) => preset.key == widget.novel.genre,
      )
      ? widget.novel.genre
      : GenrePresets.defaultKey;
  late String _tone = _initialTone();

  String _initialTone() {
    final List<String> tones = GenrePresets.get(_genre).tones;
    return tones.contains(widget.novel.tone) ? widget.novel.tone : tones.first;
  }

  @override
  void dispose() {
    _title.dispose();
    _targetWords.dispose();
    super.dispose();
  }

  void _submit() {
    final String title = _title.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('作品名不能为空')));
      return;
    }
    final int? target = int.tryParse(_targetWords.text.trim());
    if (target == null || target < 0 || target > 20000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('单章目标字数需在 0–20000 之间（0 = 不设目标）')),
      );
      return;
    }
    Navigator.of(context).pop(
      NovelInfoDraft(
        title: title,
        genre: _genre,
        tone: _tone,
        targetWordsPerChapter: target,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final List<String> tones = GenrePresets.get(_genre).tones;
    return AlertDialog(
      scrollable: true,
      title: const Text('作品信息'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            TextField(
              controller: _title,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '作品名',
                hintText: '例：碎星航线',
              ),
            ),
            const SizedBox(height: AppTokens.s4),
            DropdownButtonFormField<String>(
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
            const SizedBox(height: AppTokens.s3),
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
            const SizedBox(height: AppTokens.s3),
            TextField(
              controller: _targetWords,
              keyboardType: TextInputType.number,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: '单章目标字数',
                helperText: '用于章节进度与写作统计；0 = 不设目标',
              ),
            ),
            const SizedBox(height: AppTokens.s3),
            Text(
              '题材与基调会影响生成提示词与封面配色；改动不会重写已有正文。',
              style: AppFonts.text(ink.inkFaint, size: 12, height: 1.7),
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
          label: const Text('保存'),
        ),
      ],
    );
  }
}
