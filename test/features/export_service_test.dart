import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/features/export/export_service.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 导出服务测试：buildContent / 附录 / epub / docx / backup。
void main() {
  late Directory tmpDir;
  late ExportService service;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('novel_exp_');
    final AppDatabase db = AppDatabase.initForTest(tmpDir.path);
    service = ExportService(NovelRepository(db));
  });

  tearDown(() {
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  Novel makeNovel() => Novel(
        id: 'n1',
        title: '测试小说',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 2, 3, 4, 5),
        chapters: <Chapter>[
          Chapter(
            id: 'ch1',
            novelId: 'n1',
            title: '第一章',
            order: 0,
            content: '第一段内容。\n\n第二段内容。',
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
          Chapter(
            id: 'ch2',
            novelId: 'n1',
            title: '第二章',
            order: 1,
            content: '第二章内容。',
            createdAt: DateTime(2026, 1, 1),
            updatedAt: DateTime(2026, 1, 1),
          ),
        ],
        characters: <Character>[
          const Character(
            id: 'c1',
            novelId: 'n1',
            name: '林晚',
            role: '女主',
            traits: '冷静',
            background: '大师姐',
            relationships: '主角青梅',
          ),
        ],
        worldSettings: const <WorldSetting>[
          WorldSetting(
            id: 'w1',
            novelId: 'n1',
            title: '天玄大陆',
            category: '地理',
            content: '修仙大陆',
          ),
        ],
      );

  test('txt 导出含书名与章节（含空行分段）', () async {
    final String content =
        await service.buildContent(makeNovel(), ExportFormat.txt);
    expect(content, contains('测试小说'));
    expect(content, contains('第1章 第一章'));
    expect(content, contains('第2章 第二章'));
    expect(content, contains('第一段内容。'));
    expect(content, contains('第二段内容。'));
    // 无附录时不含角色信息。
    expect(content, isNot(contains('林晚')));
  });

  test('markdown 导出用 #/## 标题', () async {
    final String content =
        await service.buildContent(makeNovel(), ExportFormat.markdown);
    expect(content, startsWith('# 测试小说'));
    expect(content, contains('## 第一章'));
    expect(content, contains('> 题材：'));
  });

  test('includeSettings 时附录含角色与世界观', () async {
    final String content = await service.buildContent(
      makeNovel(),
      ExportFormat.txt,
      includeSettings: true,
    );
    expect(content, contains('附录：角色与设定'));
    expect(content, contains('林晚（女主）'));
    expect(content, contains('性格：冷静'));
    expect(content, contains('天玄大陆（地理）'));
  });

  test('epub 二进制含 mimetype/container/章节 xhtml', () async {
    final List<int> bytes = service.buildEpub(makeNovel());
    // zip 内文件名/ASCII 用 latin1 解码可读（中文会乱但不影响 ASCII 断言）。
    final String raw = latin1.decode(bytes);
    expect(raw, contains('application/epub+zip'));
    expect(raw, contains('META-INF/container.xml'));
    expect(raw, contains('OEBPS/content.opf'));
    expect(raw, contains('OEBPS/ch1.xhtml'));
    expect(raw, contains('OEBPS/ch2.xhtml'));
    // dcterms:modified 用 updatedAt（转 UTC，动态计算避免时区依赖）。
    expect(
      raw,
      contains(DateTime(2026, 1, 2, 3, 4, 5).toUtc().toIso8601String()),
    );
    // zip 魔数 PK。
    expect(bytes.sublist(0, 2), equals(<int>[0x50, 0x4B]));
  });

  test('docx 二进制含 document.xml 与章节标题', () async {
    final List<int> bytes = service.buildDocx(makeNovel());
    // zip 内文件名/ASCII 用 latin1 解码可读（中文会乱但不影响 ASCII 断言）。
    // XML 内容 UTF-8 编码，zip 头部字节容错解码。
    final String raw = utf8.decode(bytes, allowMalformed: true);
    expect(raw, contains('[Content_Types].xml'));
    expect(raw, contains('word/document.xml'));
    expect(raw, contains('第1章 第一章'));
    expect(raw, contains('wordprocessingml'));
    expect(bytes.sublist(0, 2), equals(<int>[0x50, 0x4B]));
  });

  test('epub 中文标题做 XML 转义', () async {
    final Novel novel = makeNovel();
    // 构造含特殊字符的标题。
    final Novel evil = novel.copyWith(
      title: '测试<&>小说',
      chapters: <Chapter>[
        novel.chapters.first.copyWith(title: '章<&>节'),
      ],
    );
    final String raw =
        utf8.decode(service.buildEpub(evil), allowMalformed: true);
    expect(raw, contains('测试&lt;&amp;&gt;小说'));
    expect(raw, contains('章&lt;&amp;&gt;节'));
    expect(raw, isNot(contains('测试<&>小说')));
  });

  test('backup JSON 可反序列化还原', () async {
    // 走 export 的 buildContent 不可行（backup 走 FilePicker），
    // 直接验证 toJson 往返（backup 内容即 toJson）。
    final Map<String, dynamic> json = makeNovel().toJson();
    final Novel restored = Novel.fromJson(json);
    expect(restored.title, equals('测试小说'));
    expect(restored.chapters.length, equals(2));
    expect(restored.characters.length, equals(1));
  });

  test('GenrePresets 题材名出现在导出中', () async {
    final String content =
        await service.buildContent(makeNovel(), ExportFormat.markdown);
    expect(
      content,
      contains(GenrePresets.get('xuanhuan').label),
    );
  });
}
