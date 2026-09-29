import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/models/style_ref.dart';
import 'package:novel_writer/widgets/app_feedback.dart';

/// 文风参考弹窗（P1-1 Dart 侧）：导入一篇参考文 → 抽**文风指纹** → 存入项目。
///
/// 设计要点（与 Python 侧 `--style-ref` 同构）：
/// - **只抽分布数值，不留原文**——弹窗里能看到九项指标与渲染出的注入块预览，
///   但项目里只存指纹，原文留在用户自己的磁盘上；
/// - 注入块预览让用户**看见会喂给模型什么**（含禁抄与「与准则冲突以准则为准」
///   两条），避免黑盒；
/// - 展示**当前正文与参考文的距离**，给出可执行的收敛提示。
class StyleRefDialog extends StatefulWidget {
  /// 构造。
  const StyleRefDialog({
    super.key,
    required this.novelId,
    required this.currentRef,
    required this.currentText,
    required this.onSave,
    required this.onClear,
  });

  /// 项目 id。
  final String novelId;

  /// 当前已存的文风参考（可空）。
  final StyleRef? currentRef;

  /// 当前项目正文（用于算与参考文的距离）。
  final String currentText;

  /// 保存回调。
  final Future<void> Function(StyleRef ref) onSave;

  /// 清除回调。
  final Future<void> Function() onClear;

  /// 打开弹窗。
  static Future<void> show(
    BuildContext context, {
    required String novelId,
    required StyleRef? currentRef,
    required String currentText,
    required Future<void> Function(StyleRef ref) onSave,
    required Future<void> Function() onClear,
  }) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext c) => StyleRefDialog(
        novelId: novelId,
        currentRef: currentRef,
        currentText: currentText,
        onSave: onSave,
        onClear: onClear,
      ),
    );
  }

  @override
  State<StyleRefDialog> createState() => _StyleRefDialogState();
}

class _StyleRefDialogState extends State<StyleRefDialog> {
  Map<String, double>? _fp;
  String _source = '';
  bool _busy = false;

  /// 九项指标的展示名与格式（与注入块里的表述一致，便于对照）。
  static const List<(String, String, String)> _rows = <(String, String, String)>[
    ('句长均值', 'sent_len_mean', '字'),
    ('句长变异', 'sent_len_cv', ''),
    ('对白占比', 'dialogue_ratio', '%'),
    ('段落均长', 'para_len_mean', '字'),
    ('单句成段', 'single_para_rate', '%'),
    ('的字密度', 'de_density', '%'),
    ('叠词', 'adverb_density', '/千字'),
    ('句首连接词', 'connector_rate', '%'),
    ('比喻', 'metaphor_density', '/千字'),
  ];

  String _fmt(String key, String unit) {
    final double v = _fp?[key] ?? 0;
    final double shown =
        (unit == '%' || key == 'connector_rate') ? v * 100 : v;
    final int digits = key == 'sent_len_mean' || key == 'para_len_mean' ? 1 : 2;
    return '${shown.toStringAsFixed(digits)}$unit';
  }

  Future<void> _importFile() async {
    setState(() => _busy = true);
    String? text;
    String name = '';
    try {
      final FilePickerResult? res = await FilePicker.platform.pickFiles(
        dialogTitle: '选择参考文（.txt）',
        type: FileType.custom,
        allowedExtensions: const <String>['txt', 'md'],
      );
      final PlatformFile? f = res?.files.singleOrNull;
      final String? path = f?.path;
      if (path != null) {
        text = await File(path).readAsString();
        name = f!.name;
      }
    } catch (_) {
      text = null;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (text == null) return;
    _apply(text, name.isEmpty ? '参考文' : name);
  }

  Future<void> _paste() async {
    final TextEditingController ctrl = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext c) => AlertDialog(
        title: const Text('粘贴参考文'),
        content: SizedBox(
          width: 460,
          height: 320,
          child: TextField(
            controller: ctrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: const InputDecoration(
              hintText: '粘贴你喜欢的网文章节（至少 500 字，越多越准）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, ctrl.text),
            child: const Text('提取指纹'),
          ),
        ],
      ),
    );
    if (!mounted || text == null) return;
    _apply(text, '粘贴的参考文');
  }

  void _apply(String text, String source) {
    final Map<String, double> fp = PipelineQa.styleFingerprint(text);
    setState(() {
      _fp = fp;
      _source = source;
    });
  }

  Future<void> _save() async {
    final Map<String, double>? fp = _fp;
    if (fp == null) return;
    if ((fp['words'] ?? 0) < StyleRef.minWords) {
      AppToast.warn(context,
          '参考文不足 ${StyleRef.minWords} 字，指纹噪声过大，请换更长的文本');
      return;
    }
    setState(() => _busy = true);
    await widget.onSave(
      StyleRef(
        source: _source,
        fingerprint: fp,
        savedAt: DateTime.now(),
      ),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    AppToast.info(context, '文风参考已保存，生成时会注入写手提示词');
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final AppInk ink = AppInk.of(context);
    final Map<String, double>? fp = _fp;
    final StyleRef? cur = widget.currentRef;
    return AlertDialog(
      title: const Row(
        children: <Widget>[
          Icon(Icons.texture_outlined),
          SizedBox(width: 8),
          Text('文风参考'),
        ],
      ),
      content: SizedBox(
        width: 560,
        height: 460,
        child: ListView(
          children: <Widget>[
            Text(
              '导入一篇你喜欢的网文，只提取它的**句长/对白/段落呼吸**等分布，'
              '不存原文、不学句子——生成时让本书向它的节奏靠拢。',
              style: AppFonts.text(ink.inkSoft, size: 12, height: 1.5),
            ),
            const SizedBox(height: AppTokens.s3),
            Row(
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importFile,
                  icon: const Icon(Icons.folder_open, size: 18),
                  label: const Text('选择文件'),
                ),
                const SizedBox(width: AppTokens.s2),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _paste,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('粘贴文本'),
                ),
              ],
            ),
            if (cur != null) ...<Widget>[
              const SizedBox(height: AppTokens.s2),
              Text('当前：${cur.source}（${cur.words.round()} 字）',
                  style: AppFonts.text(ink.inkFaint, size: 12)),
            ],
            if (fp != null) ...<Widget>[
              const SizedBox(height: AppTokens.s3),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppTokens.s3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text('《$_source》文风指纹 · ${(fp['words'] ?? 0).round()} 字',
                          style: AppFonts.text(ink.ink,
                              size: 13, weight: FontWeight.bold)),
                      const SizedBox(height: AppTokens.s2),
                      for (final (String, String, String) r in _rows)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: <Widget>[
                              SizedBox(
                                width: 84,
                                child: Text(r.$1,
                                    style: AppFonts.text(ink.inkSoft,
                                        size: 12)),
                              ),
                              Text(_fmt(r.$2, r.$3),
                                  style: AppFonts.text(ink.ink,
                                      size: 12,
                                      weight: FontWeight.w600)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppTokens.s2),
              _distanceCard(context, ink, fp),
              const SizedBox(height: AppTokens.s2),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('查看将注入模型的提示块',
                    style: AppFonts.text(ink.ink, size: 13)),
                children: <Widget>[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppTokens.s2),
                    decoration: BoxDecoration(
                      color: ink.inkFaint.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(AppTokens.r1),
                    ),
                    child: Text(
                      PipelineQa.styleFingerprintBlock(fp, source: _source),
                      style: AppFonts.text(ink.inkSoft, size: 11, height: 1.5),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        if (cur != null)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await widget.onClear();
                    if (context.mounted) {
                      AppToast.info(context, '已清除文风参考');
                      Navigator.pop(context);
                    }
                  },
            child: const Text('清除'),
          ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: (fp == null || _busy) ? null : _save,
          child: const Text('保存并用于生成'),
        ),
      ],
    );
  }

  /// 当前正文与参考文的距离卡（含噪声带提醒——单点不判收敛）。
  Widget _distanceCard(
      BuildContext context, AppInk ink, Map<String, double> fp) {
    final String text = widget.currentText.trim();
    if (text.isEmpty) {
      return Text('本书还没有正文，导入后将用于后续生成。',
          style: AppFonts.text(ink.inkFaint, size: 12));
    }
    final double d = PipelineQa.fingerprintDistance(
        fp, PipelineQa.styleFingerprint(text));
    return Container(
      padding: const EdgeInsets.all(AppTokens.s2),
      decoration: BoxDecoration(
        color: ink.inkFaint.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(AppTokens.r1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('本书现有正文与参考文的距离：${d.toStringAsFixed(2)}'
              '（0=同分布，越大越远）',
              style: AppFonts.text(ink.ink, size: 12)),
          const SizedBox(height: 4),
          Text('距离会随新章生成逐步变化；单次波动不代表收敛，'
              '看多章趋势。',
              style: AppFonts.text(ink.inkFaint, size: 11, height: 1.4)),
        ],
      ),
    );
  }
}
