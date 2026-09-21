import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  // ---- 以下为 2026-09-20 深度审查修复的针对性回归 ----

  group('深度审查修复回归', () {
    test('zip 内每个条目的 CRC-32 字段与标准算法一致（修复缺 final XOR）',
        () {
      final Uint8List bytes = service.buildEpub(makeNovel());
      final List<ZipEntry> entries = _parseZipEntries(bytes);
      expect(entries.length, greaterThanOrEqualTo(5));
      for (final ZipEntry e in entries) {
        expect(e.crc, equals(_refCrc32(e.data)),
            reason: '条目 ${e.name} 的 CRC 必须等于标准 CRC-32（含 final XOR）');
      }
    });

    test('docx 的 styles 经文档级关系连接（修复 rId 结构错误）', () {
      final Uint8List bytes = service.buildDocx(makeNovel());
      final Map<String, String> byName = <String, String>{};
      for (final ZipEntry e in _parseZipEntries(bytes)) {
        byName[e.name] = utf8.decode(e.data, allowMalformed: true);
      }
      // 包级 rels 只声明主文档。
      expect(byName['_rels/.rels'],
          isNot(contains('relationships/styles')));
      // 文档级 rels 声明 document → styles。
      final String? docRels = byName['word/_rels/document.xml.rels'];
      expect(docRels, isNotNull, reason: '必须存在 word/_rels/document.xml.rels');
      expect(docRels, contains('relationships/styles'));
      expect(docRels, contains('Target="styles.xml"'));
    });

    test('docx includeSettings 时正文后追加附录标题', () {
      final Uint8List bytes =
          service.buildDocx(makeNovel(), includeSettings: true);
      final Map<String, String> byName = <String, String>{};
      for (final ZipEntry e in _parseZipEntries(bytes)) {
        byName[e.name] = utf8.decode(e.data, allowMalformed: true);
      }
      final String xml = byName['word/document.xml']!;
      expect(xml, contains('附录：角色与设定'));
      expect(xml, contains('林晚'));
      // 附录标题段落使用 Heading2 段落样式（document.xml 内为 w:pStyle）。
      expect(xml, contains('w:pStyle w:val="Heading2"'));
    });

    test('XML 非法控制字符被替换为 U+FFFD（修复 Word/阅读器拒收）', () {
      final Novel evil = makeNovel().copyWith(
        chapters: <Chapter>[
          makeNovel().chapters.first.copyWith(
                content: '正文\u0000含\u000B非法\u001F控制\u007F字符。',
              ),
        ],
      );
      final Uint8List bytes = service.buildDocx(evil);
      final Map<String, String> byName = <String, String>{};
      for (final ZipEntry e in _parseZipEntries(bytes)) {
        byName[e.name] = utf8.decode(e.data, allowMalformed: true);
      }
      final String xml = byName['word/document.xml']!;
      // \x00、\x0B、\x1F 属 XML 1.0 非法控制字符，应替换为 U+FFFD；
      // \x7F 落在合法区间 [#x20-#xD7FF] 内，XML 1.0 允许，保持原样。
      expect(xml, contains('正文\uFFFD含\uFFFD非法\uFFFD控制\u007F字符。'));
      // 合法 XML 1.0 字符范围内不得再出现控制字符。
      for (final int r in xml.runes) {
        final bool legal = r == 0x9 ||
            r == 0xA ||
            r == 0xD ||
            (r >= 0x20 && r <= 0xD7FF) ||
            (r >= 0xE000 && r <= 0xFFFD) ||
            (r >= 0x10000 && r <= 0x10FFFF);
        expect(legal, isTrue, reason: 'XML 中出现非法字符 U+${r.toRadixString(16)}');
      }
    });

    test('epub dc:identifier 随项目 id 变化（修复全项目恒定 uuid）', () {
      final Novel a = makeNovel();
      final Novel b = makeNovel().copyWith(id: 'n2');
      final String rawA =
          utf8.decode(service.buildEpub(a), allowMalformed: true);
      final String rawA2 =
          utf8.decode(service.buildEpub(a), allowMalformed: true);
      final String rawB =
          utf8.decode(service.buildEpub(b), allowMalformed: true);
      final String uuidA =
          RegExp(r'urn:uuid:([0-9a-f-]+)').firstMatch(rawA)!.group(1)!;
      final String uuidA2 =
          RegExp(r'urn:uuid:([0-9a-f-]+)').firstMatch(rawA2)!.group(1)!;
      final String uuidB =
          RegExp(r'urn:uuid:([0-9a-f-]+)').firstMatch(rawB)!.group(1)!;
      expect(uuidA, equals(uuidA2), reason: '同项目多次导出应幂等一致');
      expect(uuidA, isNot(equals(uuidB)), reason: '不同项目必须不同标识');
    });

    test('导出按 order 排序，不受上游数组乱序影响', () async {
      final Novel shuffled = makeNovel().copyWith(
        chapters: <Chapter>[
          makeNovel().chapters[1], // order=1 在前
          makeNovel().chapters[0], // order=0 在后
        ],
      );
      final String content =
          await service.buildContent(shuffled, ExportFormat.txt);
      expect(content.indexOf('第1章 第一章'), lessThan(content.indexOf('第2章 第二章')),
          reason: '正文必须先按 order 升序输出');
    });
  });
}

/// zip 条目（local file header 解析用，条目为 stored 存储式）。
class ZipEntry {
  const ZipEntry(this.name, this.data, this.crc);

  final String name;
  final Uint8List data;
  final int crc;
}

/// 解析 zip 的 local file headers（mimetype 首条 + 后续条目）。
List<ZipEntry> _parseZipEntries(Uint8List bytes) {
  final List<ZipEntry> out = <ZipEntry>[];
  const int localHeaderMagic = 0x04034b50;
  int offset = 0;
  while (offset + 30 <= bytes.length) {
    final int sig = (bytes[offset]) |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
    if (sig != localHeaderMagic) break;
    final int nameLen = bytes[offset + 26] | (bytes[offset + 27] << 8);
    final int extraLen = bytes[offset + 28] | (bytes[offset + 29] << 8);
    final int size = (bytes[offset + 18]) |
        (bytes[offset + 19] << 8) |
        (bytes[offset + 20] << 16) |
        (bytes[offset + 21] << 24);
    final int crc = (bytes[offset + 14]) |
        (bytes[offset + 15] << 8) |
        (bytes[offset + 16] << 16) |
        (bytes[offset + 17] << 24);
    final int dataStart = offset + 30 + nameLen + extraLen;
    final String name =
        utf8.decode(bytes.sublist(offset + 30, offset + 30 + nameLen));
    out.add(ZipEntry(
      name,
      Uint8List.sublistView(bytes, dataStart, dataStart + size),
      crc,
    ));
    offset = dataStart + size;
  }
  return out;
}

/// 标准 CRC-32（IEEE 802.3，含 final XOR）——独立实现，用于对照 zip 字段。
int _refCrc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final int b in data) {
    crc ^= b;
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
