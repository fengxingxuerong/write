import 'dart:io';

import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/llm_chat_client.dart';
import 'package:novel_writer/engine/llm_retry.dart';
import 'package:novel_writer/models/llm_config.dart';

/// 一次链式路由调用的结果。
class LlmRouteResult {
  /// 构造结果。
  const LlmRouteResult({required this.content, this.used});

  /// 模型返回正文（已 trim；链上全部失败时为空串）。
  final String content;

  /// 实际命中的端点；null = 链上无可用端点。
  ///
  /// 可用于日志/审计「本次走了主还是备」。
  final LlmConfig? used;

  /// 是否拿到非空正文。
  bool get ok => content.isNotEmpty;
}

/// 多模型链式路由抽象（对齐 Python `scripts/novel_pipeline.py` 的 `call_chain`）。
///
/// 语义：
/// 1. 沿有序链逐个尝试，**冷却中的端点直接跳过**；
/// 2. 端点失败或返回空正文 → 自动落到下一个；
/// 3. 返回**第一个非空结果**；链上全部失败返回空正文。
///
/// whats-that：全家「配额感知 failover」——同一个角色可以配置主 + 多个备用
/// 端点，主端点配额耗尽/限流时不用整章停工，而是无缝切到备用。
abstract interface class LlmRouter {
  /// 沿 [chain]（主 → 备）路由一次对话，返回首个非空结果。
  ///
  /// [temperature] 非空时覆盖各端点自身温度（null 则用端点自带的温度，
  /// 对齐 Python 每个 provider 独立 temp 的语义）。
  Future<LlmRouteResult> call(
    List<LlmConfig> chain, {
    required String system,
    required String user,
    double? temperature,
    void Function(String logLine)? onLog,
  });
}

/// 配额感知的链式路由默认实现。
///
/// 与 Python 端 `_HEALTH` 健康池语义一致：
/// - 以 `provider|baseUrl|model` 为粒度记录连续失败/冷却；
/// - 连续失败达到 [maxFailures] 次后进入 [cooldown] 冷却，冷却期间跳过该端点；
/// - 命中一次非空正文即清零失败计数（自愈）。
///
/// 每个端点复用独立 [LlmChatClient]（连接池化 + 内部 429/5xx 退避重试），
/// 路由层负责「跨端点」的 failover，客户端层负责「单端点内」的重试，
/// 两层层叠后与 Python 的 `retry(3 次) + 链切换` 行为一致。
class ChainLlmRouter implements LlmRouter {
  /// 构造路由器。
  ///
  /// [retry] 透传给每个端点的 [LlmChatClient]（测试可注入快速重试）；
  /// [clientFactory]、[timeout] 同理。`maxFailures`/`cooldown` 为健康池调参。
  ChainLlmRouter({
    this.clientFactory,
    this.timeout = const Duration(minutes: 3),
    this.retry,
    this.maxFailures = 3,
    this.cooldown = const Duration(minutes: 5),
  });

  /// HttpClient 工厂（测试可注入假连接）。
  final HttpClient Function()? clientFactory;

  /// 单次请求超时（每个端点内部每次尝试）。
  final Duration timeout;

  /// 单端点内部重试策略；null 用 [LlmChatClient] 默认（3 次指数退避）。
  final RetryPolicy? retry;

  /// 连续失败达到此次数后进入冷却。
  final int maxFailures;

  /// 冷却时长（达到失败阈值后跳过该端点的时间）。
  final Duration cooldown;

  /// 健康池：`端点 key → (连续失败, 冷却截止)`。
  final Map<String, _EndpointHealth> _health = <String, _EndpointHealth>{};

  /// 端点 client 缓存（按 key 复用，连接池化）。
  final Map<String, LlmChatClient> _clients = <String, LlmChatClient>{};

  @override
  Future<LlmRouteResult> call(
    List<LlmConfig> chain, {
    required String system,
    required String user,
    double? temperature,
    void Function(String logLine)? onLog,
  }) async {
    final List<LlmConfig> usable =
        chain.where((LlmConfig c) => c.isConfigured).toList();
    if (usable.isEmpty) {
      onLog?.call('链上无已配置端点');
      return const LlmRouteResult(content: '');
    }
    for (final LlmConfig cfg in usable) {
      final String key = _key(cfg);
      if (_inCooldown(key)) {
        onLog?.call('${cfg.model} 冷却中，跳过');
        continue;
      }
      final LlmChatClient client = _clients.putIfAbsent(
        key,
        () => LlmChatClient(
          config: cfg,
          timeout: timeout,
          retry: retry,
          clientFactory: clientFactory,
        ),
      );
      try {
        final LlmChatResult r = await client.chat(
          system,
          user,
          temperature: temperature ?? cfg.temperature,
        );
        final String content = r.content.trim();
        if (content.isNotEmpty) {
          _markOk(key);
          return LlmRouteResult(content: content, used: cfg);
        }
        onLog?.call('${cfg.model} 返回为空，尝试下一个');
      } on LlmTransportException catch (e) {
        final bool enteredCooldown = _markFail(key);
        onLog?.call('${cfg.model} 失败：${e.message}'
            '${enteredCooldown ? '（进入冷却 ${cooldown.inMinutes} 分钟）' : ''}');
      } catch (e) {
        onLog?.call('${cfg.model} 异常：${e.toString().substring(0, 80)}');
      }
    }
    return const LlmRouteResult(content: '');
  }

  /// 端点身份 key（cooldown 按端点而非角色，跨角色共享健康状态）。
  String _key(LlmConfig cfg) =>
      '${cfg.provider.name}|${cfg.baseUrl}|${cfg.model}';

  /// 是否处于冷却。
  bool _inCooldown(String key) {
    final _EndpointHealth? h = _health[key];
    if (h == null) return false;
    return h.cooldownUntil != null &&
        DateTime.now().isBefore(h.cooldownUntil!);
  }

  /// 记录失败：达到阈值进入冷却并返回 true。
  bool _markFail(String key) {
    final _EndpointHealth h = _health.putIfAbsent(
      key,
      () => _EndpointHealth(),
    );
    h.failures++;
    if (h.failures >= maxFailures) {
      h.cooldownUntil = DateTime.now().add(cooldown);
      return true;
    }
    return false;
  }

  /// 记录成功：清零失败计数（冷却期满了自动消失，无需额外清理）。
  void _markOk(String key) {
    final _EndpointHealth? h = _health[key];
    if (h != null) {
      h.failures = 0;
    }
  }
}

/// 单端点健康状态。
class _EndpointHealth {
  int failures = 0;

  /// 冷却截止时间；null 表示未冷却。
  DateTime? cooldownUntil;
}