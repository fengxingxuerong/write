import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/workspace/llm_settings_dialog.dart';
import 'package:novel_writer/features/workspace/statistics_panel.dart';
import 'package:novel_writer/features/workspace/style_ref_dialog.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/style_ref.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/setting_repository.dart';
import 'package:novel_writer/widgets/common.dart';

/// 右栏：角色 / 世界观编辑 + 一键生成入口（由工作区统一放置按钮）。
class SettingPanel extends ConsumerWidget {
  /// 构造设定面板。
  const SettingPanel({
    super.key,
    required this.novel,
    required this.onChanged,
  });

  /// 当前项目（提供角色与世界观数据）。
  final Novel novel;

  /// 数据变更后通知父级刷新。
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // settingRepositoryProvider 是 Provider（非 StateNotifier），值不会变，用 read 即可
    final SettingRepository repo = ref.read(settingRepositoryProvider);
    return SizedBox(
      width: 320,
      child: ListView(
        padding: const EdgeInsets.all(AppTokens.s2),
        children: <Widget>[
          StatisticsPanel(novel: novel),
          _llmCard(context, ref),
          _styleRefCard(context, ref, repo),
          SectionCard(
            title: '角色（${novel.characters.length}）',
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                tooltip: '新增角色',
                onPressed: () => _editCharacter(context, ref, repo, null),
              ),
            ],
            children: novel.characters.isEmpty
                ? const <Widget>[Text('还没有角色，点击 + 添加')]
                : novel.characters
                    .map((c) => _characterTile(context, ref, repo, c))
                    .toList(),
          ),
          SectionCard(
            title: '世界观（${novel.worldSettings.length}）',
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.add, size: 18),
                tooltip: '新增设定',
                onPressed: () => _editWorld(context, ref, repo, null),
              ),
            ],
            children: novel.worldSettings.isEmpty
                ? const <Widget>[Text('还没有世界观设定，点击 + 添加')]
                : novel.worldSettings
                    .map((w) => _worldTile(context, ref, repo, w))
                    .toList(),
          ),
        ],
      ),
    );
  }

  /// 文风参考卡片（P1-1）：显示当前参考并提供导入/清除入口。
  ///
  /// 只存**指纹分布**不存原文，故卡片里不显示任何参考文内容——用户想看原文
  /// 请回自己的文件。这一点在 UI 上必须说清，否则会让人以为可以在这里回看原文。
  Widget _styleRefCard(
    BuildContext context,
    WidgetRef ref,
    SettingRepository repo,
  ) {
    final StyleRef? ref0 = novel.styleRef;
    return SectionCard(
      title: '文风参考',
      children: <Widget>[
        if (ref0 == null)
          const Text('未设置：生成时不会注入文风指纹')
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('《${ref0.source}》· ${ref0.words.round()} 字'),
              Text(
                ref0.isUsable
                    ? '句长 ${(ref0.fingerprint['sent_len_mean'] ?? 0).toStringAsFixed(1)}｜'
                        '对白 ${((ref0.fingerprint['dialogue_ratio'] ?? 0) * 100).round()}%'
                    : '样本过少，已停用（需 ≥${StyleRef.minWords} 字）',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        const SizedBox(height: 6),
        Row(
          children: <Widget>[
            OutlinedButton.icon(
              onPressed: () => _openStyleRef(context, ref, repo),
              icon: const Icon(Icons.texture_outlined, size: 16),
              label: Text(ref0 == null ? '导入参考文' : '更换'),
            ),
            if (ref0 != null) ...<Widget>[
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  await repo.clearStyleRef(novel.id);
                  onChanged();
                },
                child: const Text('清除'),
              ),
            ],
          ],
        ),
      ],
    );
  }

  /// 打开文风参考弹窗。
  Future<void> _openStyleRef(
    BuildContext context,
    WidgetRef ref,
    SettingRepository repo,
  ) async {
    // 正文用于算「本书现有文风 vs 参考文」的距离：优先用章节库，拿不到时
    // 退化为空（弹窗会如实说明"本书还没有正文"）。
    String text = '';
    try {
      final List<Chapter> chapters = await ref.read(chapterRepositoryProvider)
          .listChapters(novel.id);
      text = chapters.map((Chapter c) => c.content).join('\n\n');
    } catch (_) {
      text = '';
    }
    if (!context.mounted) return;
    await StyleRefDialog.show(
      context,
      novelId: novel.id,
      currentRef: novel.styleRef,
      currentText: text,
      onSave: (StyleRef r) async {
        await repo.setStyleRef(novel.id, r);
        onChanged();
      },
      onClear: () async {
        await repo.clearStyleRef(novel.id);
        onChanged();
      },
    );
  }

  /// AI 生成设置卡片：引擎开关 + 配置入口。
  Widget _llmCard(BuildContext context, WidgetRef ref) {
    final LlmSettingsState llm = ref.watch(llmSettingsProvider);
    final bool configured = llm.config.isConfigured;
    return SectionCard(
      title: 'AI 生成',
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.settings, size: 18),
          tooltip: 'AI 设置',
          onPressed: () => showLlmSettingsDialog(context, ref),
        ),
      ],
      children: <Widget>[
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('使用 AI 生成'),
          subtitle: Text(
            llm.useLlm
                ? (configured
                    ? llm.config.label
                    : '⚠ 未配置，请点击右上角设置')
                : '关闭 = 纯模板引擎（零网络）',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          value: llm.useLlm,
          onChanged: (bool v) async {
            if (v && !configured) {
              // 未配置时先打开设置弹窗。
              await showLlmSettingsDialog(context, ref);
              final LlmSettingsState after = ref.read(llmSettingsProvider);
              if (!after.config.isConfigured) return;
            }
            await ref.read(llmSettingsProvider.notifier).setUseLlm(v);
          },
        ),
      ],
    );
  }

  Widget _characterTile(
    BuildContext context,
    WidgetRef ref,
    SettingRepository repo,
    Character c,
  ) {
    return ExpansionTile(
      dense: true,
      tilePadding: EdgeInsets.zero,
      childrenPadding:
          const EdgeInsets.only(left: AppTokens.s4, bottom: AppTokens.s2),
      title: Text(c.name.isEmpty ? '未命名角色' : c.name),
      subtitle: Text(
        '${c.role}${c.role.isNotEmpty && c.traits.isNotEmpty ? ' · ' : ''}${c.traits}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.edit, size: 18),
            tooltip: '编辑角色',
            onPressed: () => _editCharacter(context, ref, repo, c),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '删除角色',
            onPressed: () async {
              await repo.deleteCharacter(novel.id, c.id);
              onChanged();
            },
          ),
        ],
      ),
      children: <Widget>[
        if (c.background.isNotEmpty)
          _detailLine(context, '背景', c.background),
        if (c.relationships.isNotEmpty)
          _detailLine(context, '关系', c.relationships),
        if (c.background.isEmpty && c.relationships.isEmpty)
          const Text(
            '（无更多信息，点击编辑补充背景与关系）',
            style: TextStyle(fontSize: 12),
          ),
      ],
    );
  }

  Widget _detailLine(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTokens.s1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '$label：',
            style: AppFonts.text(AppInk.of(context).inkFaint,
                size: 12, weight: FontWeight.w600),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _worldTile(
    BuildContext context,
    WidgetRef ref,
    SettingRepository repo,
    WorldSetting w,
  ) {
    return ListTile(
      dense: true,
      title: Text(w.title.isEmpty ? '未命名设定' : w.title),
      subtitle: Text(
        '${w.category}${w.category.isNotEmpty ? '：' : ''}${w.content}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            icon: const Icon(Icons.edit, size: 18),
            tooltip: '编辑设定',
            onPressed: () => _editWorld(context, ref, repo, w),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '删除设定',
            onPressed: () async {
              await repo.deleteWorldSetting(novel.id, w.id);
              onChanged();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _editCharacter(
    BuildContext context,
    WidgetRef ref,
    SettingRepository repo,
    Character? existing,
  ) async {
    final Map<String, String> values = <String, String>{
      'name': existing?.name ?? '',
      'role': existing?.role ?? '',
      'traits': existing?.traits ?? '',
      'background': existing?.background ?? '',
      'relationships': existing?.relationships ?? '',
      'dialogueStyle': existing?.dialogueStyle ?? '',
    };
    final bool ok = await _showFormDialog(
      context,
      title: existing == null ? '新增角色' : '编辑角色',
      fields: values,
    );
    if (!ok) return;
    if (existing == null) {
      await repo.addCharacter(
        novel.id,
        name: values['name']!,
        role: values['role']!,
        traits: values['traits']!,
        background: values['background']!,
        relationships: values['relationships']!,
        dialogueStyle: values['dialogueStyle']!,
      );
    } else {
      await repo.updateCharacter(
        novel.id,
        existing.copyWith(
          name: values['name']!,
          role: values['role']!,
          traits: values['traits']!,
          background: values['background']!,
          relationships: values['relationships']!,
          dialogueStyle: values['dialogueStyle']!,
        ),
      );
    }
    onChanged();
  }

  Future<void> _editWorld(
    BuildContext context,
    WidgetRef ref,
    SettingRepository repo,
    WorldSetting? existing,
  ) async {
    final Map<String, String> values = <String, String>{
      'title': existing?.title ?? '',
      'category': existing?.category ?? '',
      'content': existing?.content ?? '',
    };
    final bool ok = await _showFormDialog(
      context,
      title: existing == null ? '新增设定' : '编辑设定',
      fields: values,
    );
    if (!ok) return;
    if (existing == null) {
      await repo.addWorldSetting(
        novel.id,
        title: values['title']!,
        category: values['category']!,
        content: values['content']!,
      );
    } else {
      await repo.updateWorldSetting(
        novel.id,
        existing.copyWith(
          title: values['title']!,
          category: values['category']!,
          content: values['content']!,
        ),
      );
    }
    onChanged();
  }

  /// 通用多字段表单对话框（键值对 -> 编辑后回填）。
  Future<bool> _showFormDialog(
    BuildContext context, {
    required String title,
    required Map<String, String> fields,
  }) async {
    final Map<String, TextEditingController> controllers =
        <String, TextEditingController>{
      for (final entry in fields.entries)
        entry.key: TextEditingController(text: entry.value),
    };
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final entry in controllers.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppTokens.s2),
                  child: TextField(
                    controller: entry.value,
                    decoration: InputDecoration(labelText: entry.key),
                    maxLines: entry.key == 'content' ||
                            entry.key == 'background' ||
                            entry.key == 'relationships' ||
                            entry.key == 'dialogueStyle'
                        ? 3
                        : 1,
                  ),
                ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == true) {
      for (final entry in controllers.entries) {
        fields[entry.key] = entry.value.text;
      }
    }
    for (final c in controllers.values) {
      c.dispose();
    }
    return result ?? false;
  }
}
