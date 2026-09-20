// 全链路 E2E：多题材「写小说」全流程回归。
//
// 覆盖（全部离线、零 API 费）：
//   1. 5 大题材 × 模板引擎多章连写（续写承接 + 大纲驱动 + 角色/世界观注入）
//   2. 4 段落结构 × 4 文风组合轮转
//   3. 三道质检：NovelQualityChecker（文笔）+ FanqieGateChecker（过审，含
//      跨章 8-gram 重复与红线否决）+ NovelConsistencyChecker（跨章一致性）
//   4. 敏感词全量扫描（内置词库）
//   5. 存储层：落库 → 重读 → 索引同步 → 归档/恢复
//   6. 五格式导出：txt / md / epub / docx / json（含 ZIP 魔数与 JSON 往返校验）
//
// 产物：verify-logs/e2e_exports/ 下的成书与导出文件、verify-logs/e2e_report.txt 报告。
// 运行：flutter test test/features/full_novel_e2e_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/constants/genre_presets.dart';
import 'package:novel_writer/engine/corpus/plot_skeleton.dart';
import 'package:novel_writer/engine/generation_engine.dart';
import 'package:novel_writer/engine/quality/fanqie_gate_checker.dart';
import 'package:novel_writer/engine/quality/novel_consistency_checker.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/engine/template_engine.dart';
import 'package:novel_writer/features/export/export_service.dart';
import 'package:novel_writer/models/generation_config.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/services/sensitive_words.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/chapter_repository.dart';
import 'package:novel_writer/storage/novel_repository.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// 取上一章结尾作为续写承接（与 GenerateViewModel 同口径：取尾部裁到句首）。
String _tailForContinuation(String content, {int tailChars = 300}) {
  if (content.length <= tailChars) return content;
  final String tail = content.substring(content.length - tailChars);
  final RegExpMatch? m = RegExp(r'[。！？…]').firstMatch(tail);
  if (m == null) return tail;
  return tail.substring(m.end);
}

// ---- 各题材的书名 / 主角 / 卷纲（每行一章）----
const Map<String, (String, String, List<String>)> _specs =
    <String, (String, String, List<String>)>{
  'xuanhuan': (
    '开局退婚：我以剑魂镇九霄',
    '陆沉',
    <String>[
      '宗门大比被退婚羞辱，濒死觉醒上古剑魂，立誓三年后踏碎宗门大门',
      '藏书阁寻得残缺剑诀，遭师兄栽赃陷害，绝境反杀立威',
      '黑衣人夜袭宗门，主角护住同门被长老收为亲传，身世伏笔初现',
    ],
  ),
  'dushi': (
    '重生2010：从县城便利店开始',
    '陈越',
    <String>[
      '重生回到高中毕业夜，用未来记忆盘下街角便利店并定下三年规划',
      '连锁化遇资金链危机，靠预判一场行业风口拿到关键投资',
    ],
  ),
  'kehuan': (
    '深空回响：第七次戴森信标',
    '林晚舟',
    <String>[
      '深空中继站截获规律脉冲，主角破译出以质数排列的坐标',
      '抵达坐标发现废弃戴森云碎片，带回的数据里藏着太阳系的倒计时',
    ],
  ),
  'yanqing': (
    '心动预告：隔壁学霸是隐藏主唱',
    '苏念',
    <String>[
      '转学生苏念误闯天台撞见学霸校草偷偷练歌，被拉进地下乐队救场',
      '乐队首演爆红，两人被拍到同框，约定高考结束前只做默契搭档',
    ],
  ),
  'xuanyi': (
    '第七位证人',
    '程野',
    <String>[
      '旧案重审，六名证人证词严丝合缝，主角却发现第七份笔录被人抽走',
      '第七位证人浮出水面当晚坠楼，主角在遗物里找到第二把相同的钥匙',
    ],
  ),
};

void main() {
  test(
    '全链路 E2E：5 题材 × 生成/三道质检/敏感词/存储/五格式导出',
    () async {
      final Directory tmp = Directory.systemTemp.createTempSync('e2e_novel_');
      final Directory out = Directory(
          'verify-logs${Platform.pathSeparator}e2e_exports')
        ..createSync(recursive: true);

      final AppDatabase db = AppDatabase.initForTest(tmp.path);
      final NovelRepository novelRepo = NovelRepository(db);
      final ChapterRepository chapterRepo = ChapterRepository(db);
      final SettingRepository settingRepo = SettingRepository(db);
      final ExportService exportService = ExportService(novelRepo);
      const GenerationEngine engine = TemplateEngine();

      final StringBuffer report = StringBuffer()
        ..writeln('==== 全链路 E2E 写作测试报告 ====')
        ..writeln();

      // 段落结构 × 文风：五本书轮转覆盖 4×4 组合的代表样本。
      const List<(WritingStyle, ProseStyle)> styleMatrix =
          <(WritingStyle, ProseStyle)>[
        (WritingStyle.crisp, ProseStyle.web),
        (WritingStyle.standard, ProseStyle.guluo),
        (WritingStyle.detailed, ProseStyle.jinyong),
        (WritingStyle.dialogue, ProseStyle.lightNovel),
        (WritingStyle.standard, ProseStyle.web),
      ];
      const List<double> randomLevels = <double>[0.35, 0.5, 0.65, 0.8, 0.95];

      int vetoTotal = 0;
      int chapterTotal = 0;
      int wordTotal = 0;

      // 只跑准备好的 5 种题材（GenrePresets.all 共 10 种，其余题材留待扩充）。
      // 文风与随机度按「第几本书」轮转取 5 项矩阵，避免依赖 GenrePresets.all 的全局顺序。
      int bookIdx = 0;
      for (final String key in _specs.keys) {
        final GenrePreset preset = GenrePresets.get(key);
        final (String title, String protagonist, List<String> outline) = _specs[key]!;
        final int styleIdx = bookIdx % styleMatrix.length;
        bookIdx++;
        final (WritingStyle style, ProseStyle prose) = styleMatrix[styleIdx];

        final Novel novel = await novelRepo.createNovel(
          title: title,
          genre: preset.key,
          tone: preset.tones.first,
        );
        // 角色 + 世界观：走 useExistingSettings=true 的注入路径。
        await settingRepo.addCharacter(
          novel.id,
          name: protagonist,
          role: '主角',
          traits: '执着，嘴硬心软',
          background: '出身寒微，有一段不为人知的旧事',
          relationships: '与师父亦父亦友',
          dialogueStyle: '短句，偶尔冷幽默',
        );
        await settingRepo.addWorldSetting(
          novel.id,
          title: '力量体系',
          category: '基础设定',
          content: '${preset.label}世界的核心规则与成长阶梯，代价与收益对等。',
        );

        final List<String> contents = <String>[];
        for (int i = 0; i < outline.length; i++) {
          final GenerationConfig cfg = GenerationConfig(
            genre: preset.key,
            tone: preset.tones.first,
            targetWords: 1600,
            useExistingSettings: true,
            protagonistName: protagonist,
            randomLevel: randomLevels[styleIdx],
            continuation: i == 0 ? null : _tailForContinuation(contents.last),
            style: style,
            proseStyle: prose,
            constraints: const GenerationConstraints(),
          );
          final ContextBundle ctx = ContextBundle(
            characters: novel.characters,
            worldSettings: novel.worldSettings,
            genrePreset: preset,
            plotSkeleton: PlotSkeleton.forGenre(preset.key),
            outline: outline[i],
          );
          final GenerationResult r = await engine.generate(cfg, ctx);
          // 引擎契约：actualWords 不超过约束上限、正文非空。
          expect(
            r.actualWords,
            allOf(
              lessThanOrEqualTo(cfg.constraints.maxWordsPerChapter),
              isNonZero,
            ),
            reason: '${preset.label} 第 ${i + 1} 章 actualWords 越界',
          );
          expect(r.content.length, greaterThanOrEqualTo(500),
              reason: '${preset.label} 第 ${i + 1} 章正文过短');
          contents.add(r.content);
          await chapterRepo.saveGeneratedChapter(
              novel.id, i + 1, '第${i + 1}章', r.content);
          chapterTotal++;
          wordTotal += r.actualWords;
        }

        final Novel reloaded = await novelRepo.getNovel(novel.id);
        final String fullText = contents.join('\n');

        // ---- 三道质检 ----
        double gateSum = 0;
        int vetoInBook = 0;
        for (int i = 0; i < contents.length; i++) {
          final FanqieGateReport gr = FanqieGateChecker(
            genre: preset.key,
            protagonist: protagonist,
          ).check(contents[i],
              prevContent: i == 0 ? '' : contents[i - 1],
              chapterIndex: i + 1);
          gateSum += gr.score;
          vetoInBook +=
              gr.redlines.where((FanqieRedlineHit h) => h.veto).length;
        }
        vetoTotal += vetoInBook;
        final QualityReport qr = NovelQualityChecker.check(fullText);
        final ConsistencyReport cr =
            NovelConsistencyChecker.check(reloaded.chapters);

        // ---- 敏感词全量扫描 ----
        final SensitiveCheckResult sr = SensitiveWordsService().check(fullText);

        // ---- 索引同步与归档 ----
        await novelRepo.setArchived(novel.id, true);
        final List<NovelSummary> archived = (await novelRepo.listNovels())
            .where((e) => e.id == novel.id)
            .toList();
        expect(archived, isNotEmpty, reason: '归档后索引不应丢条目');
        expect(archived.first.archived, isTrue);
        await novelRepo.setArchived(novel.id, false);

        // ---- 五格式导出（落盘 + 完整性校验）----
        final String txt = await exportService
            .buildContent(reloaded, ExportFormat.txt, includeSettings: true);
        final String md = await exportService.buildContent(
            reloaded, ExportFormat.markdown,
            includeSettings: true);
        final String json = jsonEncode(reloaded.toJson());
        final Uint8List epub = exportService.buildEpub(reloaded);
        final Uint8List docx = exportService.buildDocx(reloaded);
        final Map<String, int> sizes = <String, int>{
          'txt': txt.length,
          'md': md.length,
          'json': json.length,
          'epub': epub.length,
          'docx': docx.length,
        };
        await File('${out.path}${Platform.pathSeparator}${preset.key}.txt')
            .writeAsString(txt, flush: true);
        await File('${out.path}${Platform.pathSeparator}${preset.key}.epub')
            .writeAsBytes(epub, flush: true);
        await File('${out.path}${Platform.pathSeparator}${preset.key}.docx')
            .writeAsBytes(docx, flush: true);
        await File('${out.path}${Platform.pathSeparator}${preset.key}.json')
            .writeAsString(json, flush: true);

        // 导出完整性：ZIP 魔数 PK / JSON 往返。
        expect(utf8.decode(epub.sublist(0, 2)), 'PK',
            reason: '${preset.label} EPUB 不是合法 ZIP');
        expect(utf8.decode(docx.sublist(0, 2)), 'PK',
            reason: '${preset.label} DOCX 不是合法 ZIP');
        final Novel roundtrip =
            Novel.fromJson(jsonDecode(json) as Map<String, dynamic>);
        expect(roundtrip.title, reloaded.title);
        expect(roundtrip.chapters.length, reloaded.chapters.length);

        report
          ..writeln('《$title》[${preset.label}/${style.label}/${prose.label}] '
              '随机度 ${randomLevels[styleIdx]}')
          ..writeln('  生成：${outline.length} 章，'
              '均 ${(wordTotal / chapterTotal).round()} 字/章（累计 $wordTotal）')
          ..writeln('  质检：文笔 ${qr.overallScore.toStringAsFixed(0)}/100 | '
              'AI味 ${qr.aiEchoScore.toStringAsFixed(2)}% | '
              '重复率 ${(qr.repetitionScore * 100).toStringAsFixed(1)}% | '
              '番茄闸门均分 ${(gateSum / contents.length).toStringAsFixed(1)} | '
              '红线否决 $vetoInBook')
          ..writeln('  一致性：${cr.summary}')
          ..writeln(
              '  敏感词：${sr.clean ? "干净" : "命中 ${sr.count} 处 ${sr.byCategory}"}')
          ..writeln('  导出：$sizes')
          ..writeln();
      }

      report
        ..writeln('==== 汇总 ====')
        ..writeln('题材 5 种 / 章节 $chapterTotal 章 / 正文累计 $wordTotal 字 / '
            '红线否决 $vetoTotal 处')
        ..writeln('产物目录：${out.path}');

      // 硬性断言：内容安全红线（否决级）必须为零。
      expect(vetoTotal, 0, reason: '生成正文触达否决级红线，属于内容安全事故');
      await File('verify-logs${Platform.pathSeparator}e2e_report.txt')
          .writeAsString(report.toString(), flush: true);
      stdout.writeln(report);
      tmp.deleteSync(recursive: true);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
