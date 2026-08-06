import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/setting_repository.dart';
import 'package:novel_writer/features/export/export_service.dart';
import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';

/// 全功能冒烟测试：真实 AppDatabase（临时目录）走完整用户流程。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('mojiang-smoke-');
    db = AppDatabase.initForTest(tempDir.path);
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test('完整用户流程：创建项目→写章节→角色设定→导出 5 格式→归档', () async {
    final novelRepo = NovelRepository(db);
    final chapterRepo = ChapterRepository(db);
    final settingRepo = SettingRepository(db);
    final exportService = ExportService(novelRepo);

    // 1. 创建项目
    final novel = await novelRepo.createNovel(
      title: '测试之巅',
      genre: '玄幻',
      tone: '热血',
    );
    expect(novel.id, isNotEmpty);
    expect(novel.title, '测试之巅');
    expect(novel.chapters, isEmpty);

    // 2. 写章节（saveGeneratedChapter：novelId, order, title, content）
    await chapterRepo.saveGeneratedChapter(
      novel.id, 0, '第一章 觉醒', '林风在断崖边觉醒血脉，惊鸿剑出鞘。' * 5);
    await chapterRepo.saveGeneratedChapter(
      novel.id, 1, '第二章 拜师', '林风来到青云宗，拜入外门。' * 5);

    final chapters = await chapterRepo.listChapters(novel.id);
    expect(chapters.length, 2);
    expect(chapters[0].title, contains('觉醒'));
    expect(chapters[1].order, 1);

    // 3. 添加角色 + 世界观
    await settingRepo.addCharacter(
      novel.id,
      name: '林风',
      role: '主角',
      traits: '坚毅果敢',
      background: '孤儿，身负血脉之秘',
      relationships: '与苏婉亦师亦友',
      dialogueStyle: '话少而锋利',
    );
    await settingRepo.addWorldSetting(
      novel.id,
      title: '青云宗',
      category: '门派',
      content: '坐落于青云山巅，外门弟子三千',
    );

    final updated = await novelRepo.getNovel(novel.id);
    expect(updated.characters.length, 1);
    expect(updated.characters[0].dialogueStyle, '话少而锋利');
    expect(updated.worldSettings.length, 1);

    // 4. 章节拆分（splitChapter：novelId, chapterId, parts → List<Chapter>）
    final longChapter = await chapterRepo.saveGeneratedChapter(
      novel.id, 2, '第三章 试炼', '第一段：入门试炼开始。');
    expect(longChapter.order, 2);
    final split = await chapterRepo.splitChapter(novel.id, longChapter.id, <String>[
      '第一段：入门试炼开始。',
      '第二段：林风击败对手。',
      '第三段：晋级内门。',
    ]);
    expect(split.length, 5); // 返回拆分后的完整章节列表（原2 + 拆3）
    final chaptersAfterSplit = await chapterRepo.listChapters(novel.id);
    expect(chaptersAfterSplit.length, 5); // 原2章 + 拆分新增3章

    // 5. 字数统计（性能优化后的 countWords）
    final allChapters = await chapterRepo.listChapters(novel.id);
    final totalWords = allChapters.fold<int>(
        0, (sum, c) => sum + AppConstants.countWords(c.content));
    expect(totalWords, greaterThan(0));

    // 6. 导出 5 种格式（buildContent：Future<String>)
    final exportNovel = await novelRepo.getNovel(novel.id);
    final txt = await exportService.buildContent(exportNovel, ExportFormat.txt);
    final md = await exportService.buildContent(exportNovel, ExportFormat.markdown);
    expect(txt, contains('测试之巅'));
    expect(txt, contains('第一章'));
    expect(md, contains('# 测试之巅'));

    // epub/docx 二进制结构（buildEpub/buildDocx：Uint8List）
    final epub = exportService.buildEpub(exportNovel);
    expect(epub.length, greaterThan(1000));
    // ZIP 文件头 "PK"
    expect(utf8.decode(epub.sublist(0, 2), allowMalformed: true), 'PK');

    final docx = exportService.buildDocx(exportNovel);
    expect(docx.length, greaterThan(1000));
    // DOCX 也是 ZIP
    expect(utf8.decode(docx.sublist(0, 2), allowMalformed: true), 'PK');

    // backup JSON（backup 走 FilePicker 保存，buildContent 返回 txt 文本；直接验证 JSON 序列化）
    final backup = jsonEncode(exportNovel.toJson());
    final parsed = jsonDecode(backup) as Map<String, dynamic>;
    expect(parsed['title'], '测试之巅');

    // 7. 归档 / 取消归档
    await novelRepo.setArchived(novel.id, true);
    var archived = await novelRepo.getNovel(novel.id);
    expect(archived.archived, isTrue);
    await novelRepo.setArchived(novel.id, false);
    archived = await novelRepo.getNovel(novel.id);
    expect(archived.archived, isFalse);

    // 8. 列表索引（含字数/章数）
    final summaries = await novelRepo.listNovels();
    expect(summaries.length, 1);
    expect(summaries[0].wordCount, greaterThan(0));
    expect(summaries[0].chapterCount, 5);

    // 9. 重命名 + 删除
    await novelRepo.renameNovel(novel.id, '测试之巅2');
    var renamed = await novelRepo.getNovel(novel.id);
    expect(renamed.title, '测试之巅2');

    await novelRepo.deleteNovel(novel.id);
    // getNovel 在项目不存在时抛 StorageException（而非返回 null）
    await expectLater(
      novelRepo.getNovel(novel.id),
      throwsA(isA<AppException>()),
    );
    // 删除后访问章节列表同样抛 StorageException
    await expectLater(
      chapterRepo.listChapters(novel.id),
      throwsA(isA<AppException>()),
    );
  });

  test('数据可靠性：写入后自动备份 + 损坏自愈', () async {
    final novelRepo = NovelRepository(db);
    final novel = await novelRepo.createNovel(
        title: '可靠性测试', genre: '都市', tone: '轻松');

    // 写两次，备份应为最新
    await novelRepo.saveNovel(novel.copyWith(title: '可靠性测试v2'));
    final bakFile = File('${db.directory.path}/${novel.id}.bak.json');
    expect(await bakFile.exists(), isTrue);
    final bakContent = await bakFile.readAsString();
    expect(bakContent, contains('可靠性测试v2'));

    // 损坏主文件 → 自愈
    final mainFile = File('${db.directory.path}/${novel.id}.json');
    await mainFile.writeAsString('{{{corrupted json');
    final recovered = await novelRepo.getNovel(novel.id);
    expect(recovered.title, '可靠性测试v2');
  });
}
