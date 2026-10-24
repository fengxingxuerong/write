import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/features/export/export_service.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/manuscript_import_service.dart';
import 'package:novel_writer/storage/novel_repository.dart';

void main() {
  late Directory tempDir;
  late AppDatabase db;
  late NovelRepository repo;
  late ManuscriptImportService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('manuscript_import_');
    db = AppDatabase.initForTest('${tempDir.path}/app');
    repo = NovelRepository(db);
    service = ManuscriptImportService(repo);
  });

  tearDown(() {
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {
      // 忽略清理失败。
    }
  });

  test('导入原稿创建新作品、拆章并写入书架索引', () async {
    final File source = File('${tempDir.path}/碎星航线.txt');
    const String text =
        '序言。\n\n'
        '第一章 起航\n\n飞船离港。\n\n'
        '第二章 星尘\n\n前方出现星尘带。';
    await source.writeAsString(text);

    final ManuscriptImportPreview preview = await service.readFile(source);
    expect(preview.fileName, '碎星航线.txt');
    expect(preview.suggestedTitle, '碎星航线');
    expect(preview.manuscript.chapters, hasLength(3));

    final Novel novel = await service.save(
      preview,
      title: '碎星航线',
      genre: 'kehuan',
      tone: '硬核',
    );

    expect(novel.id, isNotEmpty);
    expect(novel.title, '碎星航线');
    expect(novel.genre, 'kehuan');
    expect(novel.tone, '硬核');
    expect(novel.chapters, hasLength(3));
    expect(novel.chapters.map((c) => c.title), <String>[
      '序章',
      '第一章 起航',
      '第二章 星尘',
    ]);
    expect(novel.chapters.map((c) => c.order), <int>[0, 1, 2]);
    expect(novel.chapters.every((c) => c.novelId == novel.id), isTrue);
    expect(novel.wordCount(), greaterThan(0));
    // 短样章的章均不足 500 字，目标按下限 500，避免进度条刻度失真。
    expect(novel.targetWordsPerChapter, 500);

    final List<NovelSummary> shelf = await repo.listNovels();
    expect(shelf, hasLength(1));
    expect(shelf.single.id, novel.id);
    expect(shelf.single.chapterCount, 3);
    expect(shelf.single.wordCount, novel.wordCount());
  });

  test('导入只读源文件，不改动原稿内容', () async {
    final File source = File('${tempDir.path}/原稿.md');
    const String text = '# 第一章\n\n正文。';
    await source.writeAsString(text);
    final List<int> before = await source.readAsBytes();

    final ManuscriptImportPreview preview = await service.readFile(source);
    await service.save(preview, title: '原稿', genre: 'dushi', tone: '日常');

    expect(await source.readAsBytes(), before);
  });

  test('没有章节标题时整篇作为一章导入', () async {
    final File source = File('${tempDir.path}/短篇.txt');
    await source.writeAsString('开头。\n\n结尾。');

    final ManuscriptImportPreview preview = await service.readFile(source);
    expect(preview.manuscript.detectedHeadings, isFalse);
    expect(preview.manuscript.chapters, hasLength(1));

    final Novel novel = await service.save(
      preview,
      title: '',
      genre: '',
      tone: '',
    );
    expect(novel.title, '未命名作品');
    expect(novel.genre, 'xuanhuan');
    expect(novel.tone, '热血');
    expect(novel.chapters.single.title, '第1章');
  });

  test('导入后可以接着改并导出，和用户真实路径一致', () async {
    final File source = File('${tempDir.path}/旧稿.txt');
    await source.writeAsString('第一章 旧章\n\n旧正文。\n\n第二章 未完\n\n写到这里。');

    final ManuscriptImportPreview preview = await service.readFile(source);
    final Novel imported = await service.save(
      preview,
      title: '旧稿',
      genre: 'dushi',
      tone: '日常',
    );

    final ChapterRepository chapterRepo = ChapterRepository(db);
    await chapterRepo.updateChapterContent(
      imported.id,
      imported.chapters.first.id,
      '旧正文。\n\n这是导入后继续写的新段落。',
    );

    final Novel edited = await repo.getNovel(imported.id);
    expect(edited.chapters.first.content, contains('继续写的新段落'));

    final ExportService export = ExportService(repo);
    final String txt = await export.buildContent(edited, ExportFormat.txt);
    expect(txt, contains('旧稿'));
    expect(txt, contains('第一章 旧章'));
    expect(txt, contains('继续写的新段落'));
    expect(txt, contains('第二章 未完'));
  });

  test('同一份原稿导入两次得到两个独立作品', () async {
    final File source = File('${tempDir.path}/两次.txt');
    await source.writeAsString('第一章\n\n正文。');

    for (int i = 0; i < 2; i++) {
      final ManuscriptImportPreview preview = await service.readFile(source);
      await service.save(preview, title: '两次', genre: 'xuanhuan', tone: '热血');
    }

    final List<NovelSummary> shelf = await repo.listNovels();
    expect(shelf, hasLength(2));
    expect(shelf.map((NovelSummary n) => n.id).toSet(), hasLength(2));
  });

  test('Windows 上 GBK 原稿可直接导入', () async {
    final File source = File('${tempDir.path}/GBK.txt');
    await source.writeAsBytes(<int>[
      0xB5,
      0xDA,
      0xD2,
      0xBB,
      0xD5,
      0xC2,
      0x20,
      0xB3,
      0xF5,
      0xBC,
      0xFB,
      0x0A,
      0xD5,
      0xFD,
      0xCE,
      0xC4,
      0xA1,
      0xA3,
    ]);

    final ManuscriptImportPreview preview = await service.readFile(source);
    expect(preview.manuscript.chapters, hasLength(1));
    expect(preview.manuscript.chapters.single.title, '第一章 初见');
    expect(preview.manuscript.chapters.single.content, '正文。');

    final Novel novel = await service.save(
      preview,
      title: 'GBK 旧稿',
      genre: 'dushi',
      tone: '日常',
    );
    expect(novel.chapters.single.title, '第一章 初见');
    expect(novel.chapters.single.content, '正文。');
  }, skip: !Platform.isWindows);

  test('无法识别的编码明确失败且不留下半本作品', () async {
    final File source = File('${tempDir.path}/unknown.txt');
    await source.writeAsBytes(<int>[0x81]);

    await expectLater(
      service.readFile(source),
      throwsA(
        isA<StorageException>().having(
          (StorageException e) => e.message,
          'message',
          contains('UTF-8'),
        ),
      ),
    );
    expect(await repo.listNovels(), isEmpty);
  });

  test('空文件与不存在文件被拒绝', () async {
    final File empty = File('${tempDir.path}/empty.txt');
    await empty.writeAsString('');
    await expectLater(
      service.readFile(empty),
      throwsA(isA<StorageException>()),
    );
    await expectLater(
      service.readFile(File('${tempDir.path}/missing.txt')),
      throwsA(isA<StorageException>()),
    );
  });
}
