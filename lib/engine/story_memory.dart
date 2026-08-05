import 'dart:convert';

import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// AI 记忆提取结果：从一章正文中提炼的新设定。
class MemoryExtractResult {
  /// 新角色（含姓名/身份/性格/背景/关系，可能为空字符串）。
  final List<Character> newCharacters;

  /// 新世界观条目。
  final List<WorldSetting> newWorldSettings;

  /// 已有角色的信息补充（name → 追加描述），用于合并进原角色。
  final Map<String, String> characterUpdates;

  /// 构造结果。
  const MemoryExtractResult({
    this.newCharacters = const <Character>[],
    this.newWorldSettings = const <WorldSetting>[],
    this.characterUpdates = const <String, String>{},
  });

  /// 是否为空（没有任何可写入内容）。
  bool get isEmpty =>
      newCharacters.isEmpty && newWorldSettings.isEmpty && characterUpdates.isEmpty;
}

/// AI 故事记忆：生成后自动从章节正文提取角色与世界观设定，去重合并后落库。
///
/// 闭环：生成章节 → 提取设定 → 更新角色/世界观 → 下次生成自动带上 →
/// 保持长篇小说的人物与世界观一致性。仅 AI 引擎启用时运行。
class StoryMemory {
  /// 构造记忆器。
  StoryMemory({required this.config, required this.settingRepo});

  /// LLM 配置。
  final LlmConfig config;

  /// 设定仓库（落库用）。
  final SettingRepository settingRepo;

  /// 从一章正文提取并合并设定。
  ///
  /// [novel] 当前项目（提供已有角色/世界观用于去重）；
  /// [chapterContent] 新生成章节正文。
  /// 返回写入摘要（新增角色数 / 新增设定数 / 更新角色数），供 UI 提示。
  Future<MemoryWriteSummary> extractAndMerge(
    Novel novel,
    String chapterContent,
  ) async {
    final LlmChatClient client = LlmChatClient(config: config);
    final LlmChatResult res = await client.chat(
      _systemPrompt,
      _userPrompt(novel, chapterContent),
    );
    final MemoryExtractResult result = _parseJson(res.content);
    if (result.isEmpty) {
      return const MemoryWriteSummary();
    }

    // 去重合并并落库。
    final Novel current = await settingRepo.db.readNovel(novel.id);
    int addedChars = 0;
    int addedWorlds = 0;
    int updatedChars = 0;

    for (final Character c in result.newCharacters) {
      if (c.name.trim().isEmpty) continue;
      // 按名字去重：已存在则合并 traits/background，否则新增。
      final Character? existing = _findByName(current.characters, c.name);
      if (existing == null) {
        await settingRepo.addCharacter(
          novel.id,
          name: c.name.trim(),
          role: c.role,
          traits: c.traits,
          background: c.background,
          relationships: c.relationships,
        );
        addedChars++;
      } else {
        final Character merged = existing.copyWith(
          traits: _mergeField(existing.traits, c.traits),
          background: _mergeField(existing.background, c.background),
          relationships: _mergeField(existing.relationships, c.relationships),
        );
        if (merged != existing) {
          await settingRepo.updateCharacter(novel.id, merged);
          updatedChars++;
        }
      }
    }

    for (final WorldSetting w in result.newWorldSettings) {
      if (w.title.trim().isEmpty) continue;
      final WorldSetting? existing = _findWorld(current.worldSettings, w.title);
      if (existing == null) {
        await settingRepo.addWorldSetting(
          novel.id,
          title: w.title.trim(),
          category: w.category,
          content: w.content,
        );
        addedWorlds++;
      } else {
        final WorldSetting merged = existing.copyWith(
          content: _mergeField(existing.content, w.content),
        );
        if (merged != existing) {
          await settingRepo.updateWorldSetting(novel.id, merged);
          updatedChars++; // 设定更新也算一次「更新」。
        }
      }
    }

    // 已有角色的信息补充（按名字）。
    for (final MapEntry<String, String> entry in result.characterUpdates.entries) {
      final String name = entry.key;
      final String extra = entry.value;
      if (name.trim().isEmpty || extra.trim().isEmpty) continue;
      final Character? existing = _findByName(current.characters, name);
      if (existing == null) continue;
      final Character merged =
          existing.copyWith(traits: _mergeField(existing.traits, extra));
      if (merged != existing) {
        await settingRepo.updateCharacter(novel.id, merged);
        updatedChars++;
      }
    }

    return MemoryWriteSummary(
      addedCharacters: addedChars,
      addedWorldSettings: addedWorlds,
      updatedCharacters: updatedChars,
    );
  }

  /// 按名字找已有角色（大小写/空白不敏感）。
  Character? _findByName(List<Character> list, String name) {
    final String n = name.trim().toLowerCase();
    for (final Character c in list) {
      if (c.name.trim().toLowerCase() == n) return c;
    }
    return null;
  }

  /// 按标题找已有世界观条目。
  WorldSetting? _findWorld(List<WorldSetting> list, String title) {
    final String t = title.trim().toLowerCase();
    for (final WorldSetting w in list) {
      if (w.title.trim().toLowerCase() == t) return w;
    }
    return null;
  }

  /// 合并两个文本字段：去重拼接（同内容不重复）。
  String _mergeField(String a, String b) {
    final String aa = a.trim();
    final String bb = b.trim();
    if (aa.isEmpty) return bb;
    if (bb.isEmpty) return aa;
    if (aa.contains(bb)) return aa;
    return '$aa；$bb';
  }

  /// 解析 LLM 输出的 JSON。
  ///
  /// 容忍代码块包裹（```json ... ```）与前后多余文本；
  /// 解析失败返回空结果（不阻塞生成流程）。
  MemoryExtractResult _parseJson(String raw) {
    String text = raw.trim();
    // 去掉 ```json ... ``` 包裹。
    final RegExp fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```');
    final Match? m = fence.firstMatch(text);
    if (m != null) text = m.group(1)!.trim();
    // 取第一个 { 到最后一个 }。
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return const MemoryExtractResult();
    text = text.substring(start, end + 1);
    try {
      final Map<String, dynamic> json = jsonDecode(text) as Map<String, dynamic>;
      return MemoryExtractResult(
        newCharacters: _parseCharacters(json['characters']),
        newWorldSettings: _parseWorlds(json['worldSettings']),
        characterUpdates: _parseUpdates(json['characterUpdates']),
      );
    } catch (_) {
      return const MemoryExtractResult();
    }
  }

  List<Character> _parseCharacters(dynamic v) {
    if (v is! List) return const <Character>[];
    final List<Character> out = <Character>[];
    for (final dynamic e in v) {
      if (e is! Map<String, dynamic>) continue;
      out.add(Character(
        id: '',
        novelId: '',
        name: (e['name'] as String?) ?? '',
        role: (e['role'] as String?) ?? '',
        traits: (e['traits'] as String?) ?? '',
        background: (e['background'] as String?) ?? '',
        relationships: (e['relationships'] as String?) ?? '',
      ));
    }
    return out;
  }

  List<WorldSetting> _parseWorlds(dynamic v) {
    if (v is! List) return const <WorldSetting>[];
    final List<WorldSetting> out = <WorldSetting>[];
    for (final dynamic e in v) {
      if (e is! Map<String, dynamic>) continue;
      out.add(WorldSetting(
        id: '',
        novelId: '',
        title: (e['title'] as String?) ?? '',
        category: (e['category'] as String?) ?? '',
        content: (e['content'] as String?) ?? '',
      ));
    }
    return out;
  }

  Map<String, String> _parseUpdates(dynamic v) {
    if (v is! Map<String, dynamic>) return const <String, String>{};
    final Map<String, String> out = <String, String>{};
    v.forEach((String k, dynamic value) {
      final String name = k.trim();
      if (name.isEmpty) return;
      final String desc = value is String ? value.trim() : '$value'.trim();
      if (desc.isNotEmpty) out[name] = desc;
    });
    return out;
  }

  /// 系统提示词：要求 LLM 结构化提取。
  static const String _systemPrompt = '''
你是小说设定管理器。阅读一章正文，提取其中出现的角色与世界观设定，输出严格 JSON（不要 Markdown，不要多余文字）。

JSON 结构：
{
  "characters": [
    {"name": "角色名", "role": "身份/定位", "traits": "性格特征", "background": "背景", "relationships": "与其他人物的关系"}
  ],
  "worldSettings": [
    {"title": "设定标题", "category": "地理/势力/规则/物品/功法/其他", "content": "设定说明"}
  ],
  "characterUpdates": {"已有角色名": "本章新增的关于该角色的信息（性格变化/新关系/新事迹）"}
}

规则：
- characters 只放本章新出现、或第一次被详细描写的角色；主角若已在设定中则不重复，放入 characterUpdates；
- worldSettings 只放本章首次明确介绍的新设定；
- characterUpdates 只放本章中已有角色（已在原文设定列表中出现过的）的新信息；
- 没有则给空数组/空对象；
- 全部使用中文。
''';

  /// 用户提示词：带上已有设定 + 本章正文。
  String _userPrompt(Novel novel, String chapterContent) {
    final StringBuffer b = StringBuffer();
    b.writeln('【项目】${novel.title}（题材：${novel.genre}）');
    if (novel.characters.isNotEmpty) {
      b.writeln('【已有角色】');
      for (final Character c in novel.characters) {
        b.writeln('- ${c.name}（${c.role}）：${c.traits}${c.background.isNotEmpty ? '；背景：${c.background}' : ''}');
      }
    }
    if (novel.worldSettings.isNotEmpty) {
      b.writeln('【已有世界观】');
      for (final WorldSetting w in novel.worldSettings) {
        b.writeln('- ${w.title}（${w.category}）：${w.content}');
      }
    }
    b.writeln();
    b.writeln('【本章正文】');
    b.writeln(chapterContent.length > 6000
        ? chapterContent.substring(chapterContent.length - 6000)
        : chapterContent);
    return b.toString();
  }
}

/// 记忆写入摘要。
class MemoryWriteSummary {
  /// 新增角色数。
  final int addedCharacters;

  /// 新增世界观设定数。
  final int addedWorldSettings;

  /// 更新角色/设定数。
  final int updatedCharacters;

  /// 构造摘要。
  const MemoryWriteSummary({
    this.addedCharacters = 0,
    this.addedWorldSettings = 0,
    this.updatedCharacters = 0,
  });

  /// 是否有任何写入。
  bool get any =>
      addedCharacters > 0 || addedWorldSettings > 0 || updatedCharacters > 0;

  /// 展示文本。
  String get describe {
    final List<String> parts = <String>[];
    if (addedCharacters > 0) parts.add('新增 $addedCharacters 个角色');
    if (addedWorldSettings > 0) parts.add('新增 $addedWorldSettings 条设定');
    if (updatedCharacters > 0) parts.add('更新 $updatedCharacters 条');
    return parts.join('，');
  }
}
