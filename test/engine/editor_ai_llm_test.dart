import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/editor_ai.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/quality/novel_quality_checker.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/llm_config.dart';

/// EditorAi LLM 路径单元测试。
///
/// 通过注入 [_FakeChatClient]（覆写 [LlmChatClient.chat]）驱动
/// continueWrite / rewrite / polish / proofread 及请求合并、
/// 超时与异常包装等分支，不发起真实网络请求。
void main() {
  group('EditorAi.continueWrite', () {
    test('短文本：返回 原文+续写，system 含续写要求，user 含未指定题材/基调', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final String result = await editor.continueWrite(
        text: '第一章。\n\n他推开门。',
        targetWords: 200,
      );

      expect(result, '第一章。\n\n他推开门。\n\nAI 回复内容');
      expect(fake.lastSystem, contains('续写'));
      expect(fake.lastUser, contains('【题材】未指定'));
      expect(fake.lastUser, contains('【基调】未指定'));
      expect(fake.lastUser, isNot(contains('【主角】')));
      expect(fake.lastUser, isNot(contains('【角色说话风格】')));
    });

    test('带主角/题材/基调/角色风格：user 含对应区块', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );
      const Character hero = Character(
        id: 'c1',
        novelId: 'n1',
        name: '韩立',
        role: '主角',
        traits: '',
        background: '',
        relationships: '',
        dialogueStyle: '寡言少语，称呼对方为道友',
      );

      await editor.continueWrite(
        text: '正文。',
        targetWords: 100,
        genre: 'xuanhuan',
        tone: '热血',
        protagonistName: '韩立',
        characters: const <Character>[hero],
      );

      expect(fake.lastUser, contains('【题材】xuanhuan'));
      expect(fake.lastUser, contains('【基调】热血'));
      expect(fake.lastUser, contains('【主角】韩立'));
      expect(fake.lastUser, contains('【角色说话风格（对话必须严格贴合）】'));
      expect(fake.lastUser, contains('韩立：寡言少语，称呼对方为道友'));
    });

    test('角色风格为空字符串/纯空白时被过滤，不生成风格区块', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );
      const Character noStyle = Character(
        id: 'c1',
        novelId: 'n1',
        name: '路人甲',
        role: '配角',
        traits: '',
        background: '',
        relationships: '',
        dialogueStyle: '   ',
      );

      await editor.continueWrite(
        text: '正文。',
        targetWords: 100,
        characters: const <Character>[noStyle],
      );

      expect(fake.lastUser, isNot(contains('【角色说话风格】')));
    });

    test('超长正文（>6000 字符）截取末尾作为输入', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );
      final String longText = '头部${'字' * 6100}尾部';

      await editor.continueWrite(text: longText, targetWords: 100);

      // 输入被截断：不再包含最开头，但保留结尾“尾部”
      expect(fake.lastUser, isNot(contains('头部')));
      expect(fake.lastUser, contains('尾部'));
      expect(fake.lastUser, contains('【已有正文（结尾部分）】'));
    });
  });

  group('EditorAi.rewrite', () {
    test('按修改意见重写：user 含指令、题材、原文', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final String result = await editor.rewrite(
        text: '原稿正文。',
        instruction: '把主角改成冷酷寡言',
        genre: 'xuanhuan',
        tone: '热血',
        protagonistName: '韩立',
      );

      expect(result, 'AI 回复内容');
      expect(fake.lastUser, contains('【修改意见】'));
      expect(fake.lastUser, contains('把主角改成冷酷寡言'));
      expect(fake.lastUser, contains('【题材】xuanhuan'));
      expect(fake.lastUser, contains('【主角】韩立'));
      expect(fake.lastUser, contains('【原文（5 字）】'));
      expect(fake.lastSystem, contains('修改意见'));
    });
  });

  group('EditorAi.polish', () {
    const QualityReport reportWithViolations = QualityReport(
      aiEchoScore: 5,
      repetitionScore: 0,
      rhythmScore: 0,
      sensoryScore: 0,
      dialogueRatio: 0.3,
      totalWords: 100,
      hardViolations: <QualityViolation>[
        QualityViolation(
          type: QualityViolationType.aiEcho,
          description: '万能表情直陈',
          position: 0,
          matchedText: '嘴角勾起一抹',
        ),
      ],
    );

    test('无违规：直接返回原文，不调用 LLM', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );
      const QualityReport clean = QualityReport(
        aiEchoScore: 0,
        repetitionScore: 0,
        rhythmScore: 0,
        sensoryScore: 0,
        dialogueRatio: 0.5,
        totalWords: 100,
        hardViolations: <QualityViolation>[],
      );

      final String result =
          await editor.polish(text: '  干净正文。  ', qualityReport: clean);

      expect(result, '干净正文。');
      expect(fake.calls, 0);
    });

    test('有违规：调用 rewrite 路径，instruction 含违规片段与替换方向', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final String result = await editor.polish(
        text: '他嘴角勾起一抹冷笑。',
        qualityReport: reportWithViolations,
      );

      expect(result, 'AI 回复内容');
      expect(fake.calls, 1);
      expect(fake.lastUser, contains('「嘴角勾起一抹」 → 「万能表情直陈，请改写」'));
      expect(fake.lastUser, contains('仿佛/似乎/宛如'));
    });

    test('违规超过 10 条：只传前 10 条', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );
      final List<QualityViolation> many = <QualityViolation>[
        for (int i = 0; i < 12; i++)
          QualityViolation(
            type: QualityViolationType.aiEcho,
            description: 'AI 腔 $i',
            position: i,
            matchedText: '片段$i',
          ),
      ];
      final QualityReport report = QualityReport(
        aiEchoScore: 9,
        repetitionScore: 0,
        rhythmScore: 0,
        sensoryScore: 0,
        dialogueRatio: 0.3,
        totalWords: 200,
        hardViolations: many,
      );

      await editor.polish(text: '正文。', qualityReport: report);

      expect(fake.lastUser, contains('片段0'));
      expect(fake.lastUser, contains('片段9'));
      expect(fake.lastUser, isNot(contains('片段10')));
      expect(fake.lastUser, isNot(contains('片段11')));
    });
  });

  group('EditorAi.proofread', () {
    test('正常 JSON：解析出 issues 并应用修正', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) async =>
            const LlmChatResult('''
[
  {"type": "错别字", "original": "光茫", "suggestion": "光芒", "reason": "错别字"},
  {"type": "病句", "original": "非常非常", "suggestion": "非常", "reason": "重复啰嗦"}
]
'''),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final ProofreadResult result =
          await editor.proofread(text: '他握着光茫的剑。非常非常冷。');

      expect(result.issues, hasLength(2));
      expect(result.issues.first.type, '错别字');
      expect(result.issues.first.original, '光茫');
      expect(result.revised, '他握着光芒的剑。非常冷。');
      expect(result.hasIssues, isTrue);
    });

    test('空数组：无问题，revised 与原文一致', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) async =>
            const LlmChatResult('[]'),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final ProofreadResult result =
          await editor.proofread(text: '完全正确的正文。');

      expect(result.issues, isEmpty);
      expect(result.revised, '完全正确的正文。');
      expect(result.hasIssues, isFalse);
    });

    test('模型输出被包裹文本：从首个 [ 到末个 ] 截取解析', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) async =>
            const LlmChatResult('好的，以下是问题：\n[{"type": "逻辑矛盾", "original": "白天", "suggestion": "夜晚", "reason": "时间冲突"}]\n请查收。'),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final ProofreadResult result =
          await editor.proofread(text: '他在白天醒来，窗外却是满天星斗。');

      expect(result.issues, hasLength(1));
      expect(result.issues.first.type, '逻辑矛盾');
    });

    test('无方括号的文本：返回空 issues', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) async =>
            const LlmChatResult('未发现问题'),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final ProofreadResult result =
          await editor.proofread(text: '正文。');

      expect(result.issues, isEmpty);
    });

    test('非法 JSON：容错返回空 issues', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) async =>
            const LlmChatResult('[{"type": "错别字", "original": "没有闭合'),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final ProofreadResult result =
          await editor.proofread(text: '正文。');

      expect(result.issues, isEmpty);
    });

    test('非 map 元素与空 original/reason 项被过滤', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) async =>
            const LlmChatResult('''["噪声", {"type": "错别字"}, {"type": "病句", "original": "", "suggestion": "", "reason": ""}, {"type": "重复啰嗦", "original": "重复", "suggestion": "简洁", "reason": "啰嗦"}]'''),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final ProofreadResult result =
          await editor.proofread(text: '正文有重复重复。');

      expect(result.issues, hasLength(1));
      expect(result.issues.first.type, '重复啰嗦');
      expect(result.issues.first.original, '重复');
    });
  });

  group('EditorAi 请求合并与异常路径', () {
    test('同秒内相同请求只发一次（缓存命中）', () async {
      final _FakeChatClient fake = _FakeChatClient(config: const LlmConfig());
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      final Future<String> a = editor.continueWrite(
        text: '相同的正文。',
        targetWords: 100,
      );
      final Future<String> b = editor.continueWrite(
        text: '相同的正文。',
        targetWords: 100,
      );
      final List<String> results = await Future.wait(<Future<String>>[a, b]);

      expect(fake.calls, 1);
      expect(results[0], results[1]);
    });

    test('空回复：抛 EngineException 提示未返回内容', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) async =>
            const LlmChatResult('   '),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      await expectLater(
        editor.continueWrite(text: '正文。', targetWords: 100),
        throwsA(isA<EngineException>()
            .having((EngineException e) => e.message, 'message', contains('未返回内容'))),
      );
    });

    test('超时：抛 EngineException 提示超时', () async {
      final Completer<LlmChatResult> never = Completer<LlmChatResult>();
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) => never.future,
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        timeout: const Duration(milliseconds: 50),
        chatClient: fake,
      );

      await expectLater(
        editor.continueWrite(text: '正文。', targetWords: 100),
        throwsA(isA<EngineException>()
            .having((EngineException e) => e.message, 'message', contains('超时'))),
      );
      // 避免挂起 future 干扰后续断言：无关紧要，completer 无 timer 不阻塞退出
    });

    test('底层 EngineException 直接透传', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) =>
            throw const EngineException('底层模型错误'),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      await expectLater(
        editor.rewrite(text: '正文。', instruction: '改'),
        throwsA(isA<EngineException>()
            .having((EngineException e) => e.message, 'message', '底层模型错误')),
      );
    });

    test('其他异常包装为 EngineException（含原因说明）', () async {
      final _FakeChatClient fake = _FakeChatClient(
        config: const LlmConfig(),
        handler: (String system, String user) =>
            throw StateError('连接被重置'),
      );
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: fake,
      );

      await expectLater(
        editor.continueWrite(text: '正文。', targetWords: 100),
        throwsA(isA<EngineException>()
            .having((EngineException e) => e.message, 'message', contains('AI 请求失败'))),
      );
    });

    test('dispose 不抛异常', () {
      final EditorAi editor = EditorAi(
        config: const LlmConfig(),
        chatClient: _FakeChatClient(config: const LlmConfig()),
      );
      expect(editor.dispose, returnsNormally);
    });
  });
}

/// 可注入响应内容的 [LlmChatClient] 测试替身。
class _FakeChatClient extends LlmChatClient {
  _FakeChatClient({required super.config, this.handler});

  /// 自定义响应；为 null 时返回固定文本。
  final Future<LlmChatResult> Function(String system, String user)? handler;

  /// 被调用的次数。
  int calls = 0;

  /// 最近一次请求的 system prompt。
  String lastSystem = '';

  /// 最近一次请求的 user prompt。
  String lastUser = '';

  @override
  Future<LlmChatResult> chat(
    String system,
    String user, {
    String? role,
    double? temperature,
    int? maxTokens,
    Duration? timeoutOverride,
    void Function(int attempt, Duration delay, Object error)? onRetry,
    bool Function()? isCancelled,
  }) {
    calls++;
    lastSystem = system;
    lastUser = user;
    final Future<LlmChatResult> Function(String, String)? h = handler;
    if (h != null) {
      return h(system, user);
    }
    return Future<LlmChatResult>.value(const LlmChatResult('AI 回复内容'));
  }
}