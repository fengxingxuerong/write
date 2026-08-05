import 'package:novel_writer/engine/corpus/plot_skeleton.dart';

/// 题材预设。
///
/// 描述某一网文题材的展示信息（label）、可选基调（tones）以及对情节骨架的引用提示。
/// 语料（姓名/地名/句式/骨架）由 [PlotSkeleton.forGenre] 与 CorpusManager 提供，
/// 此处仅保留 UI 与引擎共用的轻量元数据。
class GenrePreset {
  /// 题材 key（如 xuanhuan）。
  final String key;

  /// 题材中文名（如 玄幻）。
  final String label;

  /// 可选基调列表。
  final List<String> tones;

  /// 情节骨架引用提示（阶段名 -> 一句话说明）。
  final Map<String, String> skeletonRef;

  /// 构造题材预设。
  const GenrePreset({
    required this.key,
    required this.label,
    required this.tones,
    required this.skeletonRef,
  });

  /// 从 JSON 反序列化。
  factory GenrePreset.fromJson(Map<String, dynamic> json) {
    return GenrePreset(
      key: json['key'] as String,
      label: json['label'] as String,
      tones: List<String>.from(json['tones'] as List<dynamic>),
      skeletonRef: Map<String, String>.from(
        json['skeletonRef'] as Map<dynamic, dynamic>,
      ),
    );
  }

  /// 序列化为 JSON。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'label': label,
        'tones': tones,
        'skeletonRef': skeletonRef,
      };
}

/// 内置题材预设集合（玄幻 / 都市 / 科幻 / 言情 / 悬疑 / 仙侠 / 历史 / 游戏 / 竞技 / 恐怖）。
class GenrePresets {
  /// 私有构造。
  const GenrePresets._();

  /// 全部内置题材。
  static const List<GenrePreset> all = <GenrePreset>[
    GenrePreset(
      key: 'xuanhuan',
      label: '玄幻',
      tones: <String>['热血', '轻松', '暗黑', '恢弘'],
      skeletonRef: <String, String>{
        '起': '展示修炼世界与主角处境',
        '承': '奇遇或危机打破日常',
        '转': '实力/心境的转折与抉择',
        '合': '崭露头角并埋下更大阴谋',
      },
    ),
    GenrePreset(
      key: 'xianxia',
      label: '仙侠',
      tones: <String>['飘逸', '热血', '古风', '超然'],
      skeletonRef: <String, String>{
        '起': '仙缘开启与凡尘羁绊',
        '承': '拜入仙门或得遇传承',
        '转': '悟道与劫难的淬炼',
        '合': '剑心通明或携友登仙',
      },
    ),
    GenrePreset(
      key: 'dushi',
      label: '都市',
      tones: <String>['日常', '励志', '甜宠', '现实'],
      skeletonRef: <String, String>{
        '起': '平凡生活的切面',
        '承': '机遇或冲突出现',
        '转': '主角应对与成长',
        '合': '阶段性结果与情感落点',
      },
    ),
    GenrePreset(
      key: 'lishi',
      label: '历史',
      tones: <String>['权谋', '热血', '厚重', '传奇'],
      skeletonRef: <String, String>{
        '起': '时代背景与人物处境',
        '承': '卷入历史事件',
        '转': '抉择与生死考验',
        '合': '改变或顺应历史洪流',
      },
    ),
    GenrePreset(
      key: 'kehuan',
      label: '科幻',
      tones: <String>['硬核', '悬疑', '悲壮', '哲思'],
      skeletonRef: <String, String>{
        '起': '设定未来世界或科技背景',
        '承': '异常事件触发探索',
        '转': '真相揭示与人性考验',
        '合': '抉择与文明尺度的回响',
      },
    ),
    GenrePreset(
      key: 'game',
      label: '游戏/无限流',
      tones: <String>['热血', '轻松', '悬疑', '竞技'],
      skeletonRef: <String, String>{
        '起': '进入游戏世界或副本',
        '承': '任务与成长线展开',
        '转': '机制挑战与强敌',
        '合': '奖励与新的谜题',
      },
    ),
    GenrePreset(
      key: 'jingsai',
      label: '竞技',
      tones: <String>['热血', '励志', '燃', '温情'],
      skeletonRef: <String, String>{
        '起': '赛场或训练日常',
        '承': '挑战与低谷',
        '转': '突破自我的关键时刻',
        '合': '胜负之外的成长',
      },
    ),
    GenrePreset(
      key: 'yanqing',
      label: '言情',
      tones: <String>['甜宠', '虐恋', '治愈', '古风'],
      skeletonRef: <String, String>{
        '起': '相遇与心动',
        '承': '情感升温或误会',
        '转': '考验与抉择',
        '合': '相守或释然',
      },
    ),
    GenrePreset(
      key: 'xuanyi',
      label: '悬疑',
      tones: <String>['紧张', '诡谲', '推理', '压抑'],
      skeletonRef: <String, String>{
        '起': '异常事件与受害者',
        '承': '线索与疑云',
        '转': '反转与真相逼近',
        '合': '收束与余味',
      },
    ),
    GenrePreset(
      key: 'kongbu',
      label: '恐怖',
      tones: <String>['惊悚', '压抑', '诡谲', '心理'],
      skeletonRef: <String, String>{
        '起': '异常征兆与氛围营造',
        '承': '异象加深或探秘',
        '转': '真相的惊悚反转',
        '合': '余悸与细思极恐',
      },
    ),
  ];

  /// 默认题材 key。
  static const String defaultKey = 'xuanhuan';

  /// 按 key 取预设，未命中时回退到默认（玄幻）。
  static GenrePreset get(String key) {
    return all.firstWhere(
      (e) => e.key == key,
      orElse: () => all.first,
    );
  }

  /// 题材 key 列表。
  static List<String> get keys => all.map((e) => e.key).toList();
}
