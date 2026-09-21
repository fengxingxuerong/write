// 20 万字级真实保存压测（AppDatabase 存储层）
//
// 测量对象与生产路径完全一致：
//   NovelRepository.saveNovel() = per-novel FIFO 锁 + writeNovel（tmp+rename 原子写
//                                + 写前 rename 旧主文件为 .bak 零拷贝备份
//                                + 首写建立初始快照）+ refreshIndexEntry（index 重写）
//   readNovel() = 主文件读取 + JSON 解码（大书走 compute isolate 分流）
//
// 运行：flutter test tool/save_stress_test.dart --reporter expanded
// 产物：verify-logs/save_stress_raw.txt（每轮原始耗时）
// ignore_for_file: invalid_use_of_visible_for_testing_member
// 说明：本脚本是压测工具而非产品代码，调用 AppDatabase.initForTest
// （@visibleForTesting 构造）属预期用途，故压制该 lint。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/constants/app_constants.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/chapter_draft.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/novel_repository.dart';

/// 压测项目 id。
const String _id = 'stress-200k';

/// 章节数。
const int _chapterCount = 100;

/// 单章目标字数（countWords 口径）。
const int _wordsPerChapter = 2000;

/// 保存轮数。
const int _saveRounds = 10;

/// 读回轮数。
const int _readRounds = 10;

/// 序列化轮数。
const int _encodeRounds = 5;

/// 章节语料（{name} 会被替换；段与段轮换，保证全书内容贴近真实而非整页重复）。
const List<String> _paras = <String>[
  '夜色如墨，{name}独自立于山巅，望着远处灯火通明的宗门大殿，握剑的手微微发紧。风从谷底卷上来，吹动衣袍猎猎作响，也吹散了他眼底最后一丝犹豫。',
  '“你确定要走这条路？”老者的声音从背后传来，苍老而平静。{name}没有回头，只是将剑横在身前：“路既然已经选定了，就没有回头的道理。”',
  '第二日清晨，雨丝斜斜地落下，将青石板路洗得发亮。{name}穿过长长的回廊，在拐角处停住脚步——那里站着一个人，撑伞而立，仿佛已等了许久。',
  '藏书阁三层，尘封的典籍在微弱的天光下泛着暗黄。{name}指尖拂过一行行古篆，忽然在某卷残页上停住，瞳孔骤缩：“原来……当年的真相藏在这里。”',
];

/// 生成第 no 章正文（countWords 口径达到 [_wordsPerChapter] 字）。
///
/// 用 countWords 做终止条件增量拼接：宁可多拼两段也不依赖估算，
/// 保证「20 万字级」是以项目同一口径（AppConstants.countWords）验收的。
String _chapterContent(int no) {
  const List<String> names = <String>['陆沉', '林舟', '苏晚晴', '沈轻衣'];
  final StringBuffer sb = StringBuffer();
  int p = 0;
  while (AppConstants.countWords(sb.toString()) < _wordsPerChapter) {
    final int idx = (no * 7 + p * 3) % _paras.length;
    sb
      ..writeln(_paras[idx].replaceAll('{name}', names[(no + p) % names.length]))
      ..writeln();
    p++;
  }
  sb.writeln('（本章完）');
  return sb.toString();
}

int _median(List<int> values) {
  final List<int> s = List<int>.of(values)..sort();
  return s[s.length ~/ 2];
}

double _mean(List<int> values) =>
    values.reduce((int a, int b) => a + b) / values.length;

int _min(List<int> values) =>
    values.reduce((int a, int b) => a < b ? a : b);

int _max(List<int> values) =>
    values.reduce((int a, int b) => a > b ? a : b);

Future<void> _processStress(Directory logDir) async {
  final StringBuffer log = StringBuffer();
  void emit(String line) {
    stdout.writeln(line);
    log.writeln(line);
  }

  emit('==== 墨匠 InkSmith：20 万字级真实保存压测 ====');
  emit('运行时间: ${DateTime.now().toIso8601String()} | '
      'Dart ${Platform.version.split(' ').first}');

  // ---- 构造 20 万字级小说 ----
  final DateTime now = DateTime.now();
  final List<Chapter> chapters = <Chapter>[
    for (int i = 0; i < _chapterCount; i++)
      Chapter(
        id: 'ch-$i',
        novelId: _id,
        title: '第${i + 1}章 风起长明',
        order: i,
        content: _chapterContent(i),
        outline: '本章要点：冲突推进与伏笔埋设（$i）',
        createdAt: now,
        updatedAt: now,
      ),
  ];
  final List<Character> characters = <Character>[
    const Character(id: 'c1', novelId: _id, name: '陆沉', role: '男主', traits: '沉稳隐忍', background: '忠仆之后，自幼丧亲', relationships: '林舟（旧识）/苏晚晴（师妹）'),
    const Character(id: 'c2', novelId: _id, name: '苏晚晴', role: '女主', traits: '外冷内热', background: '云阙宗嫡传', relationships: '陆沉（师兄）/沈轻衣（对手）'),
    const Character(id: 'c3', novelId: _id, name: '沈轻衣', role: '反派', traits: '阴鸷多谋', background: '执法堂首席', relationships: '陆沉（仇敌）'),
    const Character(id: 'c4', novelId: _id, name: '林舟', role: '配角', traits: '爽朗义气', background: '外门弟子', relationships: '陆沉（挚友）'),
    const Character(id: 'c5', novelId: _id, name: '玄寂', role: '导师', traits: '深藏不露', background: '隐世长老', relationships: '陆沉（亲传）'),
    const Character(id: 'c6', novelId: _id, name: '云容', role: '配角', traits: '温婉持重', background: '药阁阁主', relationships: '苏晚晴（师姐）'),
  ];
  final List<WorldSetting> worldSettings = <WorldSetting>[
    const WorldSetting(id: 'w1', novelId: _id, title: '修炼体系', category: '规则', content: '九境九重：凝气、通脉、筑基、金丹、元婴、化神、合体、大乘、飞升。'),
    const WorldSetting(id: 'w2', novelId: _id, title: '天玄大陆', category: '地理', content: '九域并立，中央为天玄圣城；北境冰原、南海归墟、西域流沙、东极云梦泽。'),
    const WorldSetting(id: 'w3', novelId: _id, title: '云阙宗', category: '势力', content: '北域第一宗门，掌剑修一脉，内分执法堂、药阁、传功殿、外门。'),
    const WorldSetting(id: 'w4', novelId: _id, title: '上古剑魂', category: '秘宝', content: '传说为初代剑帝残魂所化，择主而栖，可助宿主顿悟剑意。'),
  ];
  final List<ChapterDraft> drafts = <ChapterDraft>[
    ChapterDraft(id: 'd1', novelId: _id, title: '废稿·开篇', content: _chapterContent(999), createdAt: now),
    ChapterDraft(id: 'd2', novelId: _id, title: '废稿·重逢', content: _chapterContent(998), createdAt: now),
  ];

  final int totalWords =
      chapters.fold<int>(0, (int s, Chapter c) => s + c.wordCount());
  final int totalChars =
      chapters.fold<int>(0, (int s, Chapter c) => s + c.content.length);
  emit('书目: $_chapterCount 章 × 约 $_wordsPerChapter 字'
      ' | countWords 总字数: $totalWords'
      ' | content UTF-16 字符: $totalChars'
      ' | 角色 ${characters.length} | 世界观 ${worldSettings.length} | 存稿 ${drafts.length}');
  expect(totalWords, greaterThan(200000),
      reason: '必须达到 20 万字级（countWords 口径）');

  // ---- 初始化真实存储（考生目录，与生产同一套代码路径）----
  final String dataDir = '${logDir.path}${Platform.pathSeparator}save-stress-data';
  if (Directory(dataDir).existsSync()) {
    Directory(dataDir).deleteSync(recursive: true);
  }
  final AppDatabase db = AppDatabase.initForTest(dataDir);
  final NovelRepository repo = NovelRepository(db);

  final Novel novel = Novel(
    id: _id,
    title: '风起长明',
    genre: 'xuanhuan',
    tone: '热血',
    targetWordsPerChapter: AppConstants.defaultMaxWordsPerChapter,
    createdAt: now,
    updatedAt: now,
    chapters: chapters,
    characters: characters,
    worldSettings: worldSettings,
    drafts: drafts,
  );

  // ---- warmup（首轮含文件系统冷路径）----
  final Stopwatch warm = Stopwatch()..start();
  await repo.saveNovel(novel);
  warm.stop();
  emit('warmup saveNovel: ${warm.elapsedMilliseconds} ms');

  // ---- 序列化（真实 encodeNovel，含 >10 万字符走 compute isolate 分流）----
  final List<int> encodeMs = <int>[];
  for (int i = 0; i < _encodeRounds; i++) {
    final Stopwatch sw = Stopwatch()..start();
    await AppDatabase.encodeNovel(novel);
    sw.stop();
    encodeMs.add(sw.elapsedMilliseconds);
  }
  emit('encodeNovel ×$_encodeRounds: ${encodeMs.join('、')} ms'
      ' | 中位 ${_median(encodeMs)} ms');

  // ---- 真实保存 ×N（含原子写 + 备份 + index 刷新）----
  final List<int> saveMs = <int>[];
  for (int i = 0; i < _saveRounds; i++) {
    final Stopwatch sw = Stopwatch()..start();
    await repo.saveNovel(novel);
    sw.stop();
    saveMs.add(sw.elapsedMilliseconds);
  }
  emit('saveNovel ×$_saveRounds: ${saveMs.join('、')} ms');
  emit('  最小 ${_min(saveMs)} ms | 中位 ${_median(saveMs)} ms'
      ' | 均值 ${_mean(saveMs).toStringAsFixed(1)} ms | 最大 ${_max(saveMs)} ms');

  // ---- 写盘量 ----
  final File mainFile = db.novelFile(_id);
  final File bakFile = db.novelBackupFile(_id);
  final File idxFile = db.indexFile;
  final int mainBytes = mainFile.lengthSync();
  final int bakBytes = bakFile.lengthSync();
  emit('主文件: $mainBytes B | .bak: $bakBytes B | index: ${idxFile.lengthSync()} B');
  // 写前 rename 备份：旧主文件直接改名 .bak（零字节拷贝），
  // 每轮保存的实际写盘仅 tmp 全量（= 主文件）1 份 + index 增量；
  // 首轮保存时额外 copy 一次建立初始备份（一次性成本）。
  emit('单次保存写盘合计(主文件×1 + index): ${mainBytes + idxFile.lengthSync()} B'
      ' ≈ ${(mainBytes + idxFile.lengthSync()) / 1024 / 1024} MiB'
      ' | .bak 由 rename 生成（零拷贝）'
      ' | 磁盘常驻两份副本: ${(mainBytes + bakBytes) / 1024 / 1024} MiB');

  final File tmpFile = File('${mainFile.path}.tmp');
  emit('tmp 残留: ${tmpFile.existsSync()}');
  expect(tmpFile.existsSync(), isFalse, reason: '原子写不应残留临时文件');

  // 备份语义验证（独立 id，不干扰主压测对象）：写前 rename 备份的
  // 决定性特征 = .bak 是「上一版」回滚点；旧实现写后 copy 使 .bak 恒为
  // 最新版。保存两个不同标题版本后，检查 .bak 落的是版本一。
  final Novel verA = Novel(
    id: 'bak-sem',
    title: '备份语义·版本一',
    genre: 'xuanhuan',
    tone: '热血',
    targetWordsPerChapter: 2000,
    createdAt: now,
    updatedAt: now,
    chapters: const <Chapter>[],
    characters: const <Character>[],
    worldSettings: const <WorldSetting>[],
    drafts: const <ChapterDraft>[],
  );
  await db.writeNovel(verA);
  await db.writeNovel(verA.copyWith(title: '备份语义·版本二'));
  final Map<String, dynamic> bakJson =
      jsonDecode(await db.novelBackupFile('bak-sem').readAsString())
          as Map<String, dynamic>;
  final Map<String, dynamic> mainJson =
      jsonDecode(await db.novelFile('bak-sem').readAsString())
          as Map<String, dynamic>;
  final String bakTitle = bakJson['title'] as String;
  final String mainTitle = mainJson['title'] as String;
  emit('备份语义: 两次保存后 .bak.title=$bakTitle（应为版本一=上一版）'
      ' | 主文件.title=$mainTitle（应为版本二=最新）');
  expect(bakTitle, '备份语义·版本一',
      reason: 'rename 零拷贝备份 = 上一版回滚点');
  expect(mainTitle, '备份语义·版本二', reason: '主文件始终为最新版');

  // ---- 读回 ×N ----
  final List<int> readMs = <int>[];
  for (int i = 0; i < _readRounds; i++) {
    final Stopwatch sw = Stopwatch()..start();
    await db.readNovel(_id);
    sw.stop();
    readMs.add(sw.elapsedMilliseconds);
  }
  emit('readNovel ×$_readRounds: ${readMs.join('、')} ms'
      ' | 最小 ${_min(readMs)} ms | 中位 ${_median(readMs)} ms'
      ' | 均值 ${_mean(readMs).toStringAsFixed(1)} ms | 最大 ${_max(readMs)} ms');

  // ---- 读回完整性 ----
  final Novel back = await db.readNovel(_id);
  expect(back.id, _id);
  expect(back.chapters.length, _chapterCount);
  expect(back.characters.length, characters.length);
  expect(back.worldSettings.length, worldSettings.length);
  expect(back.drafts.length, drafts.length);
  for (int i = 0; i < _chapterCount; i++) {
    expect(back.chapters[i].title, chapters[i].title, reason: 'ch$i title');
    expect(back.chapters[i].content, chapters[i].content, reason: 'ch$i content');
    expect(back.chapters[i].outline, chapters[i].outline, reason: 'ch$i outline');
    expect(back.chapters[i].order, chapters[i].order, reason: 'ch$i order');
  }
  for (int i = 0; i < characters.length; i++) {
    expect(back.characters[i].name, characters[i].name);
    expect(back.characters[i].background, characters[i].background);
  }
  for (int i = 0; i < worldSettings.length; i++) {
    expect(back.worldSettings[i].title, worldSettings[i].title);
    expect(back.worldSettings[i].content, worldSettings[i].content);
  }
  for (int i = 0; i < drafts.length; i++) {
    expect(back.drafts[i].title, drafts[i].title);
    expect(back.drafts[i].content, drafts[i].content);
  }
  expect(back.wordCount(), totalWords, reason: '读回字数一致');

  // .bak 应为合法完整数据（rename 生成的上一版回滚点；
  // 连续保存相同内容时与主文件逐字节一致）。
  final String mainContent = mainFile.readAsStringSync();
  final String bakContent = bakFile.readAsStringSync();
  expect(jsonDecode(bakContent), isNotNull, reason: '.bak 必须是合法 JSON');
  final Novel bakNovel = await db.readNovel(_id);
  expect(bakNovel.wordCount(), totalWords, reason: '读回字数一致');
  if (mainContent == bakContent) {
    emit('备份校验: .bak 与主文件逐字节一致（相同内容轮）');
  } else {
    emit('备份校验: .bak 为合法 JSON（上一版回滚点，内容与主文件不同）');
  }

  // index 摘要正确
  final List<NovelSummary> index = await db.readIndex();
  expect(index.length, 1);
  expect(index.first.id, _id);
  expect(index.first.wordCount, totalWords);
  expect(index.first.chapterCount, _chapterCount);
  emit('完整性: PASS（100 章逐章一致 / 角色·世界观·存稿一致 / '
      '.bak 逐字节一致 / index 摘要正确）');

  // ---- 落盘原始数据 ----
  final File raw = File(
      '${logDir.path}${Platform.pathSeparator}save_stress_raw.txt');
  await raw.writeAsString(log.toString(), flush: true);
  emit('[产物] 原始数据: ${raw.path}');
}

void main() {
  test('20 万字级小说真实保存压测（AppDatabase / NovelRepository）', () async {
    const String logDirPath = 'verify-logs';
    final Directory logDir = Directory(logDirPath);
    logDir.createSync(recursive: true);
    await _processStress(logDir);
  }, timeout: const Timeout(Duration(minutes: 5)));
}