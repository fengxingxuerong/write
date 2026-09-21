import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/ai_pipeline/models/ai_pipeline_models.dart';
import 'package:novel_writer/ai_pipeline/services/ai_pipeline_service.dart';
import 'package:novel_writer/ai_pipeline/services/llm_router.dart';
import 'package:novel_writer/engine/llm_retry.dart';
import 'package:novel_writer/models/llm_config.dart';

/// LlmRouter 多链 failover 测试：本地多个 HttpServer 模拟主/备 LLM 端点。
///
/// 语义对齐 Python `novel_pipeline.py` 的 `call_chain`：
/// 冷却跳过 → 沿链尝试 → 空/失败切下一个 → 首个非空返回。
void main() {
  group('ChainLlmRouter', () {
    test('主端点成功直接返回，不碰备用', () async {
      final _Endpoint main =
          await _startFake(statusCode: 200, content: '主文');
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      final LlmRouteResult r = await router.call(
        <LlmConfig>[_endpoint(main, 'main')],
        system: 's',
        user: 'u',
      );
      expect(r.ok, isTrue);
      expect(r.content, '主文');
      expect(r.used?.model, 'main');
      expect(main.count, 1);
      await main.close();
    });

    test('主端点 429 → 自动切备用并返回备用内容', () async {
      final _Endpoint main =
          await _startFake(statusCode: 429, content: '');
      final _Endpoint backup =
          await _startFake(statusCode: 200, content: '备用内容');
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      final LlmRouteResult r = await router.call(
        <LlmConfig>[_endpoint(main, 'main'), _endpoint(backup, 'backup')],
        system: 's',
        user: 'u',
      );
      expect(r.ok, isTrue);
      expect(r.content, '备用内容');
      expect(r.used?.model, 'backup');
      await main.close();
      await backup.close();
    });

    test('主端点空响应 → 切备用', () async {
      final _Endpoint main =
          await _startFake(statusCode: 200, content: '');
      final _Endpoint backup =
          await _startFake(statusCode: 200, content: '备用正文');
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      final LlmRouteResult r = await router.call(
        <LlmConfig>[_endpoint(main, 'main'), _endpoint(backup, 'backup')],
        system: 's',
        user: 'u',
      );
      expect(r.ok, isTrue);
      expect(r.content, '备用正文');
      expect(r.used?.model, 'backup');
      await main.close();
      await backup.close();
    });

    test('主备全部失败 → 空响应', () async {
      final _Endpoint bad1 =
          await _startFake(statusCode: 500, content: '');
      final _Endpoint bad2 =
          await _startFake(statusCode: 429, content: '');
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      final LlmRouteResult r = await router.call(
        <LlmConfig>[_endpoint(bad1, 'bad1'), _endpoint(bad2, 'bad2')],
        system: 's',
        user: 'u',
      );
      expect(r.ok, isFalse);
      expect(r.content, isEmpty);
      expect(r.used, isNull);
      await bad1.close();
      await bad2.close();
    });

    test('主端点连续失败进入冷却，冷却期直接跳过主', () async {
      final _Endpoint main = _Endpoint.plan(
        statusCode: 429,
        content: '',
        statuses: <int>[429, 429],
      );
      final int port = await main.start();
      final _Endpoint backup =
          await _startFake(statusCode: 200, content: '备用正文');
      final ChainLlmRouter router = ChainLlmRouter(
        retry: _singleTry,
        maxFailures: 2,
        cooldown: const Duration(minutes: 5),
      );

      await router.call(
        <LlmConfig>[
          _endpoint(main, 'main', port: port),
          _endpoint(backup, 'backup'),
        ],
        system: 's',
        user: 'u',
      );
      await router.call(
        <LlmConfig>[
          _endpoint(main, 'main', port: port),
          _endpoint(backup, 'backup'),
        ],
        system: 's',
        user: 'u',
      );
      final int failedRequests = main.count;

      // 第三次：主已冷却 → 直接跳过，只打备用；主不再新增请求。
      final LlmRouteResult r = await router.call(
        <LlmConfig>[
          _endpoint(main, 'main', port: port),
          _endpoint(backup, 'backup'),
        ],
        system: 's',
        user: 'u',
      );
      expect(r.content, '备用正文');
      expect(main.count, failedRequests);
      await main.close();
      await backup.close();
    });

    test('显式 temperature 覆盖端点自带温度', () async {
      final _Endpoint main =
          await _startFake(statusCode: 200, content: '主正文');
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      await router.call(
        <LlmConfig>[_endpoint(main, 'main', temperature: 1.0)],
        system: 's',
        user: 'u',
        temperature: 0.7,
      );
      expect(main.temperatures, contains(0.7));
      await main.close();
    });

    test('temperature 为 null 时用端点自带温度', () async {
      final _Endpoint main =
          await _startFake(statusCode: 200, content: '主正文');
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      await router.call(
        <LlmConfig>[_endpoint(main, 'main', temperature: 1.0)],
        system: 's',
        user: 'u',
      );
      expect(main.temperatures, contains(1.0));
      await main.close();
    });

    test('链上无已配置端点 → 空响应', () async {
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      final LlmRouteResult r = await router.call(
        const <LlmConfig>[LlmConfig()], // 默认 Ollama 空 baseUrl → 未配置。
        system: 's',
        user: 'u',
      );
      expect(r.ok, isFalse);
    });
  });

  group('AiRoleConfig 备用链', () {
    test('序列化往返保留 fallbacks 顺序', () {
      const AiRoleConfig cfg = AiRoleConfig(
        role: AiRole.writer,
        llm: LlmConfig(model: 'main'),
        fallbacks: <LlmConfig>[
          LlmConfig(model: 'backup-a'),
          LlmConfig(model: 'backup-b'),
        ],
      );
      final AiRoleConfig restored = AiRoleConfig.fromJson(cfg.toJson());
      expect(restored.chain.length, 3);
      expect(restored.chain[0].model, 'main');
      expect(restored.chain[1].model, 'backup-a');
      expect(restored.chain[2].model, 'backup-b');
    });

    test('旧配置（无 fallbacks 字段）向后兼容', () {
      final AiRoleConfig restored =
          AiRoleConfig.fromJson(<String, dynamic>{
        'role': 'titler',
        'enabled': true,
        'llm': <String, dynamic>{'model': 'lite'},
        // 无 fallbacks key —— 模拟旧版序列化产物。
      });
      expect(restored.chain.length, 1);
      expect(restored.fallbacks, isEmpty);
      expect(restored.llm.model, 'lite');
    });
  });

  group('AiPipelineService.missingRoles 感知备用链', () {
    test('只配主且全部角色配置 → 无缺失', () {
      final AiPipelineConfig config = AiPipelineConfig(
        useEditor: true,
        useVerifier: true,
        roles: <AiRole, AiRoleConfig>{
          for (final AiRole r in AiRole.values)
            r: AiRoleConfig(
              role: r,
              llm: LlmConfig(
                provider: LlmProvider.openaiCompatible,
                model: '${r.name}-m',
                apiKey: 'k',
                baseUrl: 'http://localhost:9999/v1',
              ),
            ),
        },
      );
      expect(AiPipelineService.missingRoles(config), isEmpty);
    });

    test('主未配置但备用已配置 → 不算缺失', () {
      final AiPipelineConfig config = AiPipelineConfig(
        roles: <AiRole, AiRoleConfig>{
          for (final AiRole r in AiRole.values)
            r: AiRoleConfig(
              role: r,
              llm: const LlmConfig(), // 未配置（默认 Ollama 空 baseUrl）。
              fallbacks: <LlmConfig>[
                LlmConfig(
                  provider: LlmProvider.openaiCompatible,
                  model: '${r.name}-backup',
                  apiKey: 'k',
                  baseUrl: 'http://localhost:9999/v1',
                ),
              ],
            ),
        },
      );
      expect(AiPipelineService.missingRoles(config), isEmpty);
    });
  });
  group('链式路由日志与健康池自愈', () {
    test('链上无已配置端点 → 日志记录且不发起请求', () async {
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      final List<String> logs = <String>[];
      final LlmRouteResult r = await router.call(
        const <LlmConfig>[LlmConfig()], // 默认 Ollama 空 baseUrl → 未配置。
        system: 's',
        user: 'u',
        onLog: logs.add,
      );
      expect(r.ok, isFalse);
      expect(logs.join('\n'), contains('链上无已配置端点'));
    });

    test('端点空响应 → 日志提示并继续切下一个', () async {
      final _Endpoint main = await _startFake(statusCode: 200, content: '');
      final _Endpoint backup =
          await _startFake(statusCode: 200, content: '备用正文');
      final ChainLlmRouter router = ChainLlmRouter(retry: _singleTry);
      final List<String> logs = <String>[];
      final LlmRouteResult r = await router.call(
        <LlmConfig>[_endpoint(main, 'main'), _endpoint(backup, 'backup')],
        system: 's',
        user: 'u',
        onLog: logs.add,
      );
      expect(r.content, '备用正文');
      expect(logs.join('\n'), contains('返回为空，尝试下一个'));
      await main.close();
      await backup.close();
    });

    test('失败达阈值 → 日志带冷却提示；冷却期跳过也有日志', () async {
      final _Endpoint main = await _startFake(statusCode: 429, content: '');
      final _Endpoint backup =
          await _startFake(statusCode: 200, content: '备用正文');
      final ChainLlmRouter router = ChainLlmRouter(
        retry: _singleTry,
        maxFailures: 1,
        cooldown: const Duration(minutes: 5),
      );
      final List<String> logs = <String>[];
      await router.call(
        <LlmConfig>[_endpoint(main, 'main'), _endpoint(backup, 'backup')],
        system: 's',
        user: 'u',
        onLog: logs.add,
      );
      expect(logs.join('\n'), contains('失败：'));
      expect(logs.join('\n'), contains('进入冷却 5 分钟'));

      // 第二次：主已冷却 → 跳过日志 + 只打备用。
      logs.clear();
      await router.call(
        <LlmConfig>[_endpoint(main, 'main'), _endpoint(backup, 'backup')],
        system: 's',
        user: 'u',
        onLog: logs.add,
      );
      expect(logs.join('\n'), contains('冷却中，跳过'));
      await main.close();
      await backup.close();
    });

    test('非传输异常 → 截断记录到日志，不中断整条链', () async {
      final _Endpoint main = await _startFake(statusCode: 200, content: '正文');
      // clientFactory 抛 StateError（非传输异常）→ 走「异常」兜底分支。
      final ChainLlmRouter router = ChainLlmRouter(
        retry: _singleTry,
        clientFactory: () => throw StateError('假连接工厂故障${'x' * 200}'),
      );
      final List<String> logs = <String>[];
      final LlmRouteResult r = await router.call(
        <LlmConfig>[_endpoint(main, 'main')],
        system: 's',
        user: 'u',
        onLog: logs.add,
      );
      expect(r.ok, isFalse);
      expect(logs.join('\n'), contains('异常：'));
      expect(logs.join('\n'), isNot(contains('x' * 200))); // 超长错误已截断
      expect(main.count, 0); // 连接根本没建立起来
      await main.close();
    });

    test('成功一次即清零失败计数（防误冷却自愈）', () async {
      final _Endpoint main = _Endpoint.plan(
        statusCode: 429,
        content: '正文', // 非空正文才会触发「成功清零失败计数」
        statuses: <int>[429, 200, 429],
      );
      final int port = await main.start();
      final ChainLlmRouter router = ChainLlmRouter(
        retry: _singleTry,
        maxFailures: 2,
        cooldown: const Duration(minutes: 5),
      );
      final List<String> logs = <String>[];
      List<LlmConfig> chain() =>
          <LlmConfig>[_endpoint(main, 'main', port: port)];

      await router.call(chain(), system: 's', user: 'u', onLog: logs.add);
      await router.call(chain(), system: 's', user: 'u', onLog: logs.add);
      logs.clear();
      // 若上一次成功没清零计数，这里就会凑满 2 次失败进入冷却。
      await router.call(chain(), system: 's', user: 'u', onLog: logs.add);
      expect(logs.join('\n'), isNot(contains('进入冷却')));

      // 第 4 次仍应打到端点（未被冷却跳过）。
      final int before = main.count;
      logs.clear();
      await router.call(chain(), system: 's', user: 'u', onLog: logs.add);
      expect(main.count, before + 1);
      expect(logs.join('\n'), isNot(contains('冷却中，跳过')));
      await main.close();
    });
  });

}

// ============================================================
// 测试基建：本地假 LLM 端点
// ============================================================

/// 可控的假端点：收到请求后按预设状态码/正文响应。
/// 若 [statuses] 非空，则按顺序 pop 作为状态码（测多次失败→冷却）。
class _Endpoint {
  _Endpoint.plan({
    required this.statusCode,
    required this.content,
    this.statuses,
  });

  final int statusCode;
  final String content;
  final List<int>? statuses;

  HttpServer? _server;
  int _count = 0;

  /// 收到的请求数。
  int get count => _count;

  /// 收到的 temperature 列表（用于断言透传）。
  final List<double> temperatures = <double>[];

  int get port => _server!.port;

  Future<int> start() async {
    final HttpServer server =
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((HttpRequest req) async {
      _count++;
      // 必须读完整请求体（join）再写响应：只用 first 会导致客户端
      // 仍在接收 body 时连接被关（"Connection closed while receiving data"）。
      final String body = await utf8.decoder.bind(req).join();
      try {
        final Map<String, dynamic> payload =
            jsonDecode(body) as Map<String, dynamic>;
        if (payload.containsKey('temperature')) {
          temperatures.add((payload['temperature'] as num).toDouble());
        }
      } catch (_) {/* 非 JSON 忽略 */}
      final int code =
          (statuses != null && statuses!.isNotEmpty)
              ? statuses!.removeAt(0)
              : statusCode;
      final String resp = jsonEncode(<String, dynamic>{
        'choices': <Map<String, dynamic>>[
          <String, dynamic>{
            'message': <String, dynamic>{'content': content},
          },
        ],
      });
      req.response
        ..statusCode = code
        ..headers.contentType = ContentType.json
        ..write(resp);
      await req.response.close();
    });
    return server.port;
  }

  Future<void> close() async {
    await _server?.close(force: true);
  }
}

/// 启动一个假端点并返回。
Future<_Endpoint> _startFake({
  required int statusCode,
  required String content,
  List<int>? statuses,
}) async {
  final _Endpoint e = _Endpoint.plan(
    statusCode: statusCode,
    content: content,
    statuses: statuses,
  );
  await e.start();
  return e;
}

/// 构造指向假端点的 LlmConfig。
LlmConfig _endpoint(_Endpoint e, String model,
    {double temperature = 0.8, int? port}) {
  return LlmConfig(
    provider: LlmProvider.openaiCompatible,
    model: model,
    apiKey: 'sk-test',
    baseUrl: 'http://127.0.0.1:${port ?? e.port}/v1',
    temperature: temperature,
  );
}

/// 单次尝试、不入睡的最大快重试策略（测试用）。
const RetryPolicy _singleTry = RetryPolicy(
  maxAttempts: 1,
  baseBackoff: Duration.zero,
  sleep: _instant,
);

Future<void> _instant(Duration _) async {}