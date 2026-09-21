import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/engine/editor_ai.dart';
import 'package:novel_writer/models/character.dart';

/// 全文 AI 校对结果（问题列表 + 修正全文）的弹窗交互结果。
class ProofreadDialogResult {
  /// 构造结果。
  const ProofreadDialogResult({
    required this.revised,
    required this.appliedCount,
  });

  /// 应用后的完整正文（用户勾选应用的问题已替换；全部拒绝则与原文相同）。
  final String revised;

  /// 实际应用的问题数。
  final int appliedCount;
}

/// 全文 AI 校对弹窗。
///
/// 调用 [EditorAi.proofread] 获取问题清单与修正全文，逐条展示
/// （原文片段 → 类型 / 说明 / 修正建议），用户可勾选后批量应用。
class ProofreadDialog extends ConsumerStatefulWidget {
  /// 构造弹窗。
  const ProofreadDialog({
    super.key,
    required this.initialText,
    this.genre,
    this.tone,
    this.protagonistName,
    this.characters = const <Character>[],
  });

  /// 当前章节正文。
  final String initialText;

  /// 项目题材 / 基调 / 主角名（注入提示词）。
  final String? genre;
  final String? tone;
  final String? protagonistName;

  /// 项目角色（提供说话风格，校对时识别对话与角色不符处）。
  final List<Character> characters;

  @override
  ConsumerState<ProofreadDialog> createState() => _ProofreadDialogState();
}

class _ProofreadDialogState extends ConsumerState<ProofreadDialog> {
  bool _loading = false;
  String? _error;
  ProofreadResult? _result;
  final Set<int> _selected = <int>{};

  Future<void> _run() async {
    final LlmSettingsState llm = ref.read(llmSettingsProvider);
    if (!llm.useLlm || !llm.config.isConfigured) {
      setState(() => _error = 'AI 未配置：请先在「设置 → AI 生成设置」中配置本地模型');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _result = null;
      _selected.clear();
    });
    try {
      final EditorAi ai = EditorAi(config: llm.config);
      final ProofreadResult result = await ai.proofread(
        text: widget.initialText,
        genre: widget.genre,
        tone: widget.tone,
        protagonistName: widget.protagonistName,
        characters: widget.characters,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _result = result;
        // 默认选中所有可自动应用的条目。
        for (int i = 0; i < result.issues.length; i++) {
          if (result.issues[i].applicable) _selected.add(i);
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '校对失败：$e';
      });
    }
  }

  /// 应用选中的问题：在原文基础上，把勾选条目的修正应用（replaceFirst）。
  /// 未勾选的条目保持原文。
  String _buildRevised() {
    final ProofreadResult result = _result!;
    final List<ProofreadIssue> selected = <ProofreadIssue>[
      for (int i = 0; i < result.issues.length; i++)
        if (_selected.contains(i)) result.issues[i],
    ];
    return ProofreadResult.applyFixes(widget.initialText, selected).revised;
  }

  void _apply() {
    final ProofreadResult? result = _result;
    if (result == null) return;
    final String revised = _buildRevised();
    Navigator.of(context).pop(ProofreadDialogResult(
      revised: revised,
      appliedCount: _selected.length,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(AppTokens.s4 + 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.fact_check_outlined, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '全文 AI 校对',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '关闭',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const SizedBox(height: AppTokens.s3),
              // 状态区。
              if (_loading)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: <Widget>[
                      const CircularProgressIndicator(strokeWidth: 2),
                      const SizedBox(height: AppTokens.s3),
                      Text('AI 正在通读全文，检查错别字 / 病句 / 逻辑矛盾…',
                          style: AppFonts.text(AppInk.of(context).inkSoft, size: 13)),
                    ],
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.s2),
                  child: Text(
                    _error!,
                    style: AppFonts.text(Theme.of(context).colorScheme.error, size: 13),
                  ),
                ),
              // 结果区。
              if (_result != null) ...<Widget>[
                if (_result!.issues.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Column(
                      children: <Widget>[
                        Icon(Icons.verified_outlined,
                            size: 40, color: AppInk.of(context).success),
                        const SizedBox(height: 8),
                        Text('未发现问题，全文流畅。',
                            style: AppFonts.text(AppInk.of(context).ink, size: 14)),
                        const SizedBox(height: AppTokens.s3),
                        FilledButton.tonal(
                          onPressed: () => Navigator.of(context).pop(
                            ProofreadDialogResult(
                              revised: widget.initialText,
                              appliedCount: 0,
                            ),
                          ),
                          child: const Text('好的'),
                        ),
                      ],
                    ),
                  )
                else ...[
                  Text(
                    '发现 ${_result!.issues.length} 处问题（已勾选 ${_selected.length} 处可自动修正）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  // 问题列表。
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _result!.issues.length,
                      itemBuilder: (BuildContext context, int index) {
                        final ProofreadIssue issue = _result!.issues[index];
                        final bool enabled = issue.applicable;
                        return Card(
                          margin: const EdgeInsets.only(bottom: AppTokens.s2),
                          child: ListTile(
                            dense: true,
                            leading: Checkbox(
                              value: _selected.contains(index),
                              onChanged: enabled
                                  ? (bool? v) => setState(() {
                                        if (v == true) {
                                          _selected.add(index);
                                        } else {
                                          _selected.remove(index);
                                        }
                                      })
                                  : null,
                            ),
                            title: Text(
                              issue.original,
                              style: AppFonts.text(
                                AppInk.of(context).ink,
                                size: 13,
                              ).copyWith(
                                decoration: TextDecoration.lineThrough,
                                decorationColor: AppInk.of(context).danger,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                if (issue.applicable)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      '→ ${issue.suggestion}',
                                      style: AppFonts.text(
                                          AppInk.of(context).success, size: 12),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '【${issue.type}】${issue.reason}',
                                    style: AppFonts.text(
                                        AppInk.of(context).inkFaint, size: 11),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: AppTokens.s3),
                  // 操作按钮。
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: _loading ? null : _run,
                        child: const Text('重新校对'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _selected.isEmpty ? null : _apply,
                        child: Text('应用 ${_selected.length} 处修正'),
                      ),
                    ],
                  ),
                ],
              ] else if (!_loading && _error == null) ...<Widget>[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Text(
                    '将通读当前章节全文，找出错别字、病句、逻辑矛盾与重复啰嗦，'
                    '并逐条给出修正建议。\n\n可勾选要应用的问题，一键替换回正文。',
                    style: AppFonts.text(
                      AppInk.of(context).inkSoft,
                      size: 13,
                      height: 1.5,
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _run,
                    icon: const Icon(Icons.fact_check_outlined, size: 18),
                    label: const Text('开始校对'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 打开全文 AI 校对弹窗，返回应用结果；用户关闭返回 null。
Future<ProofreadDialogResult?> showProofreadDialog(
  BuildContext context, {
  required String text,
  String? genre,
  String? tone,
  String? protagonistName,
  List<Character> characters = const <Character>[],
}) {
  return showDialog<ProofreadDialogResult>(
    context: context,
    builder: (BuildContext ctx) => ProofreadDialog(
      initialText: text,
      genre: genre,
      tone: tone,
      protagonistName: protagonistName,
      characters: characters,
    ),
  );
}
