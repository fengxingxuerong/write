import 'package:uuid/uuid.dart';

import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';

/// 设定仓库：角色 / 世界观的 CRUD（同样落盘到单 json）。
///
/// 与 [ChapterRepository] 写的是同一个文件，因此每个读-改-写同样必须
/// 跑在 [AppDatabase.withNovelLock] 里——尤其是生成后「自动维护设定」
/// 与编辑器自动保存并发的场景。
class SettingRepository {
  /// 构造仓库。
  const SettingRepository(this.db);

  /// 数据库句柄。
  final AppDatabase db;

  // ---- 角色 ----

  /// 新增角色。
  Future<Character> addCharacter(
    String novelId, {
    String name = '',
    String role = '',
    String traits = '',
    String background = '',
    String relationships = '',
    String dialogueStyle = '',
  }) async {
    return db.withNovelLock(novelId, () async {
      final Novel novel = await db.readNovel(novelId);
      final Character ch = Character(
        id: const Uuid().v4(),
        novelId: novelId,
        name: name,
        role: role,
        traits: traits,
        background: background,
        relationships: relationships,
        dialogueStyle: dialogueStyle,
      );
      await db.writeNovel(novel.copyWith(characters: <Character>[
        ...novel.characters,
        ch,
      ]));
      return ch;
    });
  }

  /// 更新角色。
  Future<void> updateCharacter(String novelId, Character ch) {
    return db.withNovelLock(novelId, () async {
      final Novel novel = await db.readNovel(novelId);
      final List<Character> list =
          novel.characters.map((c) => c.id == ch.id ? ch : c).toList();
      await db.writeNovel(novel.copyWith(characters: list));
    });
  }

  /// 删除角色。
  Future<void> deleteCharacter(String novelId, String id) {
    return db.withNovelLock(novelId, () async {
      final Novel novel = await db.readNovel(novelId);
      await db.writeNovel(novel.copyWith(
        characters: novel.characters.where((c) => c.id != id).toList(),
      ));
    });
  }

  // ---- 世界观设定 ----

  /// 新增世界观设定。
  Future<WorldSetting> addWorldSetting(
    String novelId, {
    String title = '',
    String category = '',
    String content = '',
  }) async {
    return db.withNovelLock(novelId, () async {
      final Novel novel = await db.readNovel(novelId);
      final WorldSetting w = WorldSetting(
        id: const Uuid().v4(),
        novelId: novelId,
        title: title,
        category: category,
        content: content,
      );
      await db.writeNovel(novel.copyWith(worldSettings: <WorldSetting>[
        ...novel.worldSettings,
        w,
      ]));
      return w;
    });
  }

  /// 更新世界观设定。
  Future<void> updateWorldSetting(String novelId, WorldSetting w) {
    return db.withNovelLock(novelId, () async {
      final Novel novel = await db.readNovel(novelId);
      final List<WorldSetting> list =
          novel.worldSettings.map((x) => x.id == w.id ? w : x).toList();
      await db.writeNovel(novel.copyWith(worldSettings: list));
    });
  }

  /// 删除世界观设定。
  Future<void> deleteWorldSetting(String novelId, String id) {
    return db.withNovelLock(novelId, () async {
      final Novel novel = await db.readNovel(novelId);
      await db.writeNovel(novel.copyWith(
        worldSettings: novel.worldSettings.where((w) => w.id != id).toList(),
      ));
    });
  }
}
