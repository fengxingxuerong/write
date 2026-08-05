import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/engine/story_memory.dart';
import 'package:novel_writer/models/chapter.dart';
import 'package:novel_writer/models/character.dart';
import 'package:novel_writer/models/llm_config.dart';
import 'package:novel_writer/models/novel.dart';
import 'package:novel_writer/models/world_setting.dart';
import 'package:novel_writer/storage/app_database.dart';
import 'package:novel_writer/storage/setting_repository.dart';

/// StoryMemory 全链路测试：本地 HTTP 假 LLM 服务 + 真实临时目录数据库。
void main() {
  late Directory tmpDir;
  late AppDatabase db;
  late SettingRepository settingRepo;
  late HttpServer server;
  late int port;
  late List<Map<String, dynamic>> receivedBodies;

  setUp(() async {
    tmpDir = Directory.systemTemp.createTempSync('novel_mem_');
    db = AppDatabase.initForTest(tmpDir.path);
    settingRepo = SettingRepository(db);
    receivedBodies = <Map<String, dynamic>>[];
    // 假 LLM 服务：返回预置 JSON。
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    server.listen((HttpRequest req) async {
      final String body = await utf8.decoder.bind(req).join();
      receivedBodies.add(jsonDecode(body) as Map<String, dynamic>);
      final String resp = jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'content': '''
{
  "characters": [
    {"name": "林晚", "role": "女主", "traits": "冷静果断", "background": "宗门大师姐", "relationships": "与主角青梅竹马"}
  ],
  "worldSettings": [
    {"title": "天玄大陆", "category": "地理", "content": "灵气复苏后的修仙大陆"}
  ],
  "characterUpdates": {"主角": "本章突破筑基期"}
}
''',
            },
          },
        ],
      });
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(resp);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (tmpDir.existsSync()) {
      tmpDir.deleteSync(recursive: true);
    }
  });

  /// 落库后返回，模拟真实项目已存在。
  Future<Novel> createNovel(Novel n) async {
    await db.writeNovel(n);
    return n;
  }

  Novel makeNovel({bool withProtagonist = true}) => Novel(
        id: 'n1',
        title: '测试小说',
        genre: 'xuanhuan',
        tone: '热血',
        targetWordsPerChapter: 2000,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        chapters: const <Chapter>[],
        characters: withProtagonist
            ? <Character>[
                const Character(
                  id: 'c1',
                  novelId: 'n1',
                  name: '主角',
                  role: '主角',
                  traits: '坚韧',
                  background: '',
                  relationships: '',
                ),
              ]
            : const <Character>[],
        worldSettings: const <WorldSetting>[],
      );

  test('extractAndMerge 提取新角色/设定并落库', () async {
    final LlmConfig config = LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: 'fake',
      baseUrl: 'http://127.0.0.1:$port/v1',
      maxTokens: 4096,
    );
    final StoryMemory memory = StoryMemory(
      config: config,
      settingRepo: settingRepo,
    );
    final MemoryWriteSummary summary = await memory.extractAndMerge(
      await createNovel(makeNovel()),
      '第一章正文：林晚登场……',
    );
    // 新角色 +1（林晚）、世界观 +1、主角更新 +1。
    expect(summary.addedCharacters, equals(1));
    expect(summary.addedWorldSettings, equals(1));
    expect(summary.updatedCharacters, equals(1));
    expect(summary.any, isTrue);

    // 验证落库。
    final Novel saved = await db.readNovel('n1');
    expect(saved.characters.length, equals(2)); // 主角 + 林晚
    expect(saved.characters.last.name, equals('林晚'));
    expect(saved.characters.last.traits, contains('冷静果断'));
    expect(saved.worldSettings.length, equals(1));
    expect(saved.worldSettings.first.title, equals('天玄大陆'));
    // 主角 traits 合并了「本章突破筑基期」。
    final Character protagonist =
        saved.characters.firstWhere((c) => c.name == '主角');
    expect(protagonist.traits, contains('本章突破筑基期'));
  });

  test('extractAndMerge 重复提取时按名去重合并', () async {
    final LlmConfig config = LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: 'fake',
      baseUrl: 'http://127.0.0.1:$port/v1',
      maxTokens: 4096,
    );
    final StoryMemory memory = StoryMemory(
      config: config,
      settingRepo: settingRepo,
    );
    final Novel n1 = await createNovel(makeNovel());
    await memory.extractAndMerge(n1, '第一章');
    await memory.extractAndMerge(n1, '第二章');
    final Novel saved = await db.readNovel('n1');
    // 林晚只出现一次（去重合并 traits）。
    expect(saved.characters.where((c) => c.name == '林晚').length, equals(1));
    // traits 两次合并：冷静果断；冷静果断。
    final Character linwan =
        saved.characters.firstWhere((c) => c.name == '林晚');
    expect(linwan.traits, contains('冷静果断'));
    // 重复内容不叠加（_mergeField 去重）。
    expect(
      RegExp('冷静果断').allMatches(linwan.traits).length,
      equals(1),
    );
  });

  test('LLM 返回空 JSON 时 isEmpty 且不落库', () async {
    // 换一个返回空结果的 server：重新 bind 覆盖当前 handler 不可行，
    // 直接用一个新 server 端口测试。
    final HttpServer emptyServer =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    emptyServer.listen((HttpRequest req) async {
      await utf8.decoder.bind(req).join();
      final String resp = jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{
              'content': '{"characters": [], "worldSettings": [], "characterUpdates": {}}',
            },
          },
        ],
      });
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(resp);
      await req.response.close();
    });
    final LlmConfig config = LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: 'fake',
      baseUrl: 'http://127.0.0.1:${emptyServer.port}/v1',
      maxTokens: 4096,
    );
    final StoryMemory memory = StoryMemory(
      config: config,
      settingRepo: settingRepo,
    );
    final MemoryWriteSummary summary = await memory.extractAndMerge(
      await createNovel(makeNovel()),
      '无信息正文',
    );
    expect(summary.any, isFalse);
    await emptyServer.close(force: true);
  });

  test('请求体带 enable_thinking:false 且 messages 含 system+user', () async {
    final LlmConfig config = LlmConfig(
      provider: LlmProvider.openaiCompatible,
      model: 'fake',
      baseUrl: 'http://127.0.0.1:$port/v1',
      maxTokens: 4096,
    );
    final StoryMemory memory = StoryMemory(
      config: config,
      settingRepo: settingRepo,
    );
    await memory.extractAndMerge(await createNovel(makeNovel()), '正文内容');
    expect(receivedBodies, isNotEmpty);
    final Map<String, dynamic> body = receivedBodies.first;
    expect(body['chat_template_kwargs'], equals(<String, dynamic>{
      'enable_thinking': false,
    }));
    final List<dynamic> messages = body['messages'] as List<dynamic>;
    expect(messages.length, equals(2));
    expect((messages[0] as Map<String, dynamic>)['role'], equals('system'));
    expect((messages[1] as Map<String, dynamic>)['role'], equals('user'));
    // user prompt 包含已有角色信息。
    final String user =
        (messages[1] as Map<String, dynamic>)['content'] as String;
    expect(user, contains('【已有角色】'));
    expect(user, contains('主角'));
  });
}
