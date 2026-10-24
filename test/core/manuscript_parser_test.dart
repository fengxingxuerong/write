import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/core/utils/manuscript_parser.dart';

void main() {
  group('解码', () {
    test('UTF-8 BOM 会被去掉', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xEF,
        0xBB,
        0xBF,
        ...utf8.encode('第一章 初见'),
      ]);
      expect(ManuscriptParser.decodeBytes(bytes), '第一章 初见');
    });

    test('UTF-16 LE 带 BOM 可解码', () {
      final Uint8List bytes = _utf16('第一章 初见', littleEndian: true, bom: true);
      expect(ManuscriptParser.decodeBytes(bytes), '第一章 初见');
    });

    test('UTF-16 BE 带 BOM 可解码', () {
      final Uint8List bytes = _utf16('第一章 初见', littleEndian: false, bom: true);
      expect(ManuscriptParser.decodeBytes(bytes), '第一章 初见');
    });

    test('无 BOM 的 UTF-16 LE 按零字节分布嗅探', () {
      final Uint8List bytes = _utf16(
        'Chapter One',
        littleEndian: true,
        bom: false,
      );
      expect(ManuscriptParser.decodeBytes(bytes), 'Chapter One');
    });

    test('Windows 上 GBK 原稿可直接解码', () {
      // GBK 的「第一章 初见\n正文。」
      final Uint8List bytes = Uint8List.fromList(<int>[
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
      expect(ManuscriptParser.decodeBytes(bytes), '第一章 初见\n正文。');
    }, skip: !Platform.isWindows);

    test('无法识别的编码给出可执行的另存为提示', () {
      // 0x81 是 GBK 前导字节但没有合法后继，UTF-8/GBK 都应失败。
      final Uint8List bytes = Uint8List.fromList(<int>[0x81]);
      expect(
        () => ManuscriptParser.decodeBytes(bytes),
        throwsA(
          isA<StorageException>().having(
            (StorageException e) => e.message,
            'message',
            contains('UTF-8'),
          ),
        ),
      );
    });

    test('空文件被拒绝', () {
      expect(
        () => ManuscriptParser.decodeBytes(Uint8List(0)),
        throwsA(isA<StorageException>()),
      );
    });
  });

  group('章节识别', () {
    test('中文章节标题 + 前置内容生成序章', () {
      final ParsedManuscript parsed = ManuscriptParser.parse(
        '这是一段序言。\n\n'
        '第一章 初见\n\n山门之外。\n\n'
        '第二章：风起\n\n风起于青萍之末。\n\n'
        '第3章 雨落\n\n雨落下来。',
      );

      expect(parsed.detectedHeadings, isTrue);
      expect(parsed.chapters, hasLength(4));
      expect(parsed.chapters[0].title, '序章');
      expect(parsed.chapters[0].content, '这是一段序言。');
      expect(parsed.chapters[1].title, '第一章 初见');
      expect(parsed.chapters[1].content, '山门之外。');
      expect(parsed.chapters[2].title, '第二章 风起');
      expect(parsed.chapters[3].title, '第3章 雨落');
      expect(parsed.totalWords, greaterThan(0));
    });

    test('Markdown 标题可识别，井号会被清理', () {
      final ParsedManuscript parsed = ManuscriptParser.parse(
        '# 第一章 初见\n\n正文一。\n\n## Chapter 2\n\n正文二。',
      );

      expect(parsed.detectedHeadings, isTrue);
      expect(parsed.chapters.map((c) => c.title), <String>[
        '第一章 初见',
        'Chapter 2',
      ]);
      expect(parsed.chapters[1].content, '正文二。');
    });

    test('没有章节标题时整篇作为一章，并明确标记未识别', () {
      final ParsedManuscript parsed = ManuscriptParser.parse(
        '第一段。\n\n第二段。\n\n第三段。',
      );

      expect(parsed.detectedHeadings, isFalse);
      expect(parsed.chapters, hasLength(1));
      expect(parsed.chapters.single.title, '第1章');
      expect(parsed.chapters.single.content, '第一段。\n\n第二段。\n\n第三段。');
    });

    test('正文句「第一章说的就是……」不会被误判成标题', () {
      final ParsedManuscript parsed = ManuscriptParser.parse(
        '第一章说的就是……\n\n他转身离开。',
      );

      expect(parsed.detectedHeadings, isFalse);
      expect(parsed.chapters.single.content, contains('第一章说的就是'));
    });

    test('「第一章的标题」也不会被误判成标题', () {
      final ParsedManuscript parsed = ManuscriptParser.parse(
        '第一章的标题\n\n其实是正文。',
      );

      expect(parsed.detectedHeadings, isFalse);
    });

    test('楔子 / 番外等特殊章节名可识别', () {
      final ParsedManuscript parsed = ManuscriptParser.parse(
        '楔子\n\n很久以前。\n\n番外 一\n\n后来。',
      );

      expect(parsed.detectedHeadings, isTrue);
      expect(parsed.chapters.map((c) => c.title), <String>['楔子', '番外 一']);
    });

    test('章节标题之间的空行被保留、三连空行压成两连', () {
      final ParsedManuscript parsed = ManuscriptParser.parse(
        '第一章\n\n甲\n\n\n\n乙\n\n第二章\n\n丙',
      );

      expect(parsed.chapters.first.content, '甲\n\n乙');
    });

    test('只有标题没有正文时拒绝导入', () {
      expect(
        () => ManuscriptParser.parse('第一章\n\n第二章'),
        throwsA(isA<FormatException>()),
      );
    });

    test('空白文本被拒绝', () {
      expect(
        () => ManuscriptParser.parse('  \n\n  '),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('标题建议', () {
    test('从 Windows / POSIX 路径取文件名并去掉扩展名', () {
      expect(ManuscriptParser.suggestTitle(r'C:\books\碎星航线.txt'), '碎星航线');
      expect(ManuscriptParser.suggestTitle('/tmp/碎星航线.markdown'), '碎星航线');
      expect(ManuscriptParser.suggestTitle('   '), '未命名作品');
    });
  });
}

Uint8List _utf16(String text, {required bool littleEndian, required bool bom}) {
  final BytesBuilder builder = BytesBuilder();
  if (bom) {
    builder.add(littleEndian ? <int>[0xFF, 0xFE] : <int>[0xFE, 0xFF]);
  }
  for (final int unit in text.codeUnits) {
    if (littleEndian) {
      builder.addByte(unit & 0xFF);
      builder.addByte((unit >> 8) & 0xFF);
    } else {
      builder.addByte((unit >> 8) & 0xFF);
      builder.addByte(unit & 0xFF);
    }
  }
  return builder.toBytes();
}
