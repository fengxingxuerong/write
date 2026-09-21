import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/features/export/export_service.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';

// 本工具刻意放 tool/ 下（而非 test/）避免全量回归误跑，
// 因此复用 initForTest 属预期用法，豁免 visible-for-testing 检查。
// ignore_for_file: invalid_use_of_visible_for_testing_member

/// T6 导出兼容性探测（工具脚本，不放 test/ 避免全量回归误跑）：
/// 生成样例 docx/epub 到 verify-logs/，供外部解析器（zipfile/XML/python-docx）开包冒烟。
void main() {
  test('生成 docx/epub 样例产物', () async {
    final Directory tmpDir = Directory.systemTemp.createTempSync('exp_probe_');
    final AppDatabase db = AppDatabase.initForTest(tmpDir.path);
    final ExportService svc = ExportService(NovelRepository(db));

    final Novel novel = Novel(
      id: 'probe-novel-20260920',
      title: '剑出昆仑·测试卷',
      genre: 'xuanhuan',
      tone: '热血',
      targetWordsPerChapter: 2000,
      createdAt: DateTime(2026, 9, 20),
      updatedAt: DateTime(2026, 9, 20, 12),
      chapters: <Chapter>[
        Chapter(
          id: 'ch1',
          novelId: 'probe-novel-20260920',
          title: '第一章 破晓',
          order: 0,
          content: '晨曦刺破云层，剑客踏上昆仑之巅。\n\n他握紧剑柄，喃喃道："十年了。"',
          createdAt: DateTime(2026, 9, 20),
          updatedAt: DateTime(2026, 9, 20, 12),
        ),
        Chapter(
          id: 'ch2',
          novelId: 'probe-novel-20260920',
          title: '第二章 惊变',
          order: 1,
          content: '山门外传来急促的钟声，夹杂着喧哗与尖叫。',
          createdAt: DateTime(2026, 9, 20),
          updatedAt: DateTime(2026, 9, 20, 12),
        ),
      ],
      characters: <Character>[
        const Character(
          id: 'c1',
          novelId: 'probe-novel-20260920',
          name: '沈孤鸿',
          role: '男主',
          traits: '冷峻',
          background: '昆仑剑阁弟子',
          relationships: '',
          dialogueStyle: '寡言',
        ),
      ],
      worldSettings: <WorldSetting>[
        const WorldSetting(
          id: 'w1',
          novelId: 'probe-novel-20260920',
          title: '昆仑剑阁',
          category: '势力',
          content: '天下剑道正统，山门在昆仑之巅。',
        ),
      ],
    );

    final Directory out = Directory('verify-logs');
    if (!out.existsSync()) out.createSync(recursive: true);

    final Uint8List docx = svc.buildDocx(novel, includeSettings: true);
    File('${out.path}${Platform.pathSeparator}export-probe.docx')
        .writeAsBytesSync(docx);
    final Uint8List epub = svc.buildEpub(novel);
    File('${out.path}${Platform.pathSeparator}export-probe.epub')
        .writeAsBytesSync(epub);

    expect(docx, isNotEmpty);
    expect(epub, isNotEmpty);
  });
}