import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/services/pipeline_qa.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/style_ref.dart';

/// 文风参考（P1-1）模型与序列化回归。
///
/// 重点在**向后兼容与脏数据容错**：项目 JSON 是单文件聚合根，任一子结构解析抛
/// 异常都会导致整本打不开，故 tryFromJson 必须对任何坏输入都返回 null 而不是抛。
void main() {
  Novel novelWith(StyleRef? ref) => Novel(
        id: 'n1',
        title: '测试书',
        genre: '玄幻',
        tone: '热血',
        targetWordsPerChapter: 3000,
        createdAt: DateTime.utc(2026, 1, 1),
        updatedAt: DateTime.utc(2026, 1, 1),
        chapters: const [],
        characters: const [],
        worldSettings: const [],
        styleRef: ref,
      );

  StyleRef refOf(String source) => StyleRef(
        source: source,
        fingerprint: PipelineQa.styleFingerprint(
            List<String>.filled(40, '他推开门，众人哑口无言。').join('\n')),
        savedAt: DateTime.utc(2026, 9, 29),
      );

  group('StyleRef', () {
    test('序列化往返一致', () {
      final StyleRef a = refOf('我的参考文.txt');
      final StyleRef? b = StyleRef.tryFromJson(a.toJson());
      expect(b, isNotNull);
      expect(b!.source, a.source);
      expect(b.words, a.words);
      expect(b.fingerprint['sent_len_mean'],
          a.fingerprint['sent_len_mean']);
      expect(b.savedAt, a.savedAt);
    });

    test('脏数据一律返回 null（不抛）', () {
      expect(StyleRef.tryFromJson(null), isNull);
      expect(StyleRef.tryFromJson('不是 map'), isNull);
      expect(StyleRef.tryFromJson(<String, dynamic>{}), isNull);
      expect(StyleRef.tryFromJson(<String, dynamic>{'source': 'x'}), isNull);
      expect(
          StyleRef.tryFromJson(
              <String, dynamic>{'source': 'x', 'fingerprint': '不是 map'}),
          isNull);
    });

    test('fingerprint 里的非数值项被忽略而不是崩', () {
      final StyleRef? r = StyleRef.tryFromJson(<String, dynamic>{
        'source': 'x',
        'fingerprint': <String, dynamic>{'words': 1234, '坏项': <int>[1]},
        'savedAt': '不是日期',
      });
      expect(r, isNotNull);
      expect(r!.fingerprint['words'], 1234.0);
      expect(r.fingerprint.containsKey('坏项'), isFalse);
      // 非法日期降级为 epoch，不抛
      expect(r.savedAt.millisecondsSinceEpoch, 0);
    });

    test('isUsable：样本过少视为无效（与 Python 降级语义一致）', () {
      final StyleRef small = StyleRef(
        source: 's',
        fingerprint: <String, double>{'words': 100},
        savedAt: DateTime.utc(2026),
      );
      expect(small.isUsable, isFalse);
      final StyleRef big = StyleRef(
        source: 's',
        fingerprint: <String, double>{'words': 5000},
        savedAt: DateTime.utc(2026),
      );
      expect(big.isUsable, isTrue);
    });
  });

  group('Novel.styleRef 持久化', () {
    test('往返一致', () {
      final StyleRef r = refOf('ref.txt');
      final Novel n = novelWith(r);
      final Novel back = Novel.fromJson(n.toJson());
      expect(back.styleRef, isNotNull);
      expect(back.styleRef!.source, 'ref.txt');
      expect(back.styleRef!.words, r.words);
    });

    test('老项目无该字段 → null，行为与旧版一致', () {
      final Map<String, dynamic> legacy = novelWith(null).toJson()
        ..remove('styleRef');
      expect(Novel.fromJson(legacy).styleRef, isNull);
    });

    test('copyWith 能改也能显式清空', () {
      final Novel n = novelWith(refOf('ref.txt'));
      final Novel replaced =
          n.copyWith(styleRef: refOf('other.txt'));
      expect(replaced.styleRef!.source, 'other.txt');
      // 不给参数时保持原值
      expect(n.copyWith(title: '改名').styleRef!.source, 'ref.txt');
      // clearStyleRef 显式清空（copyWith 无法用 null 表示「要写 null」）
      expect(n.copyWith(clearStyleRef: true).styleRef, isNull);
    });
  });
}