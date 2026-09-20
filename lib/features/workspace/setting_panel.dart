import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:novel_writer/core/di/providers.dart';
import 'package:novel_writer/core/theme/app_tokens.dart';
import 'package:novel_writer/features/workspace/llm_settings_dialog.dart';
import 'package:novel_writer/features/workspace/statistics_panel.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
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
