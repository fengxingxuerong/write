import 'dart:async';
import 'dart:math' as math;

import 'package:novel_writer/core/errors/app_exceptions.dart';

/// 退避等待函数（测试里换成即时返回，避免真等 20 秒）。
typedef Sleeper = Future<void> Function(Duration delay);

/// LLM 传输层重试策略。
///
/// 为什么需要它：共享推理端点（尤其免费额度）会返回 429 `model_concurrency_rate_limit_exceeded`
/// 或 5xx，而写作是「一次几分钟」的长任务——一次限流就把整章打掉，用户看到的是白等的进度条。
///
/// 三条硬规矩：
/// 1. **只重试还没吐出内容的请求**。流式生成中途断开不重试，否则会把半章重复拼上；
/// 2. **服务器给了 Retry-After 就听它的**，不要自己瞎猜；
/// 3. **4xx（除 408/409/425/429）永不重试**，密钥错、内容过长重试一百次也是错。
class RetryPolicy {
  /// 构造策略。
  const RetryPolicy({
    this.maxAttempts = 3,
    this.baseBackoff = const Duration(milliseconds: 800),
    this.maxBackoff = const Duration(seconds: 20),
    this.sleep = _defaultSleep,
    this.random,
  });

  /// 总尝试次数（含第一次）。
  final int maxAttempts;

  /// 指数退避基数。
  final Duration baseBackoff;

  /// 单次等待上限（服务器要求更久也截到这里，避免整晚卡住）。
  final Duration maxBackoff;

  /// 等待实现（可注入，测试用）。
  final Sleeper sleep;

  /// 抖动随机源（可注入以保证测试确定性）。
  final math.Random? random;

  static Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

  /// 第 [attempt] 次失败后应等待多久（0 基）。
  ///
  /// [serverHint] 来自 Retry-After：有则优先，但仍受 [maxBackoff] 上限约束。
  Duration backoffFor(int attempt, {Duration? serverHint}) {
    if (serverHint != null && serverHint > Duration.zero) {
      return serverHint > maxBackoff ? maxBackoff : serverHint;
    }
    final int exp = math.pow(2, math.min(attempt, 10)).toInt();
    int ms = baseBackoff.inMilliseconds * exp;
    if (ms > maxBackoff.inMilliseconds) ms = maxBackoff.inMilliseconds;
    final math.Random? rng = random;
    if (rng != null && ms > 0) {
      // 0~25% 抖动：避免多个任务被同一次限流打齐后同时重试。
      ms += (rng.nextDouble() * 0.25 * ms).round();
    }
    return Duration(milliseconds: ms);
  }

  /// 执行 [body]，失败且可重试时按退避序列重来。
  ///
  /// [body] 收到当前尝试序号（0 基），便于自己决定是否要“第二次换个模型”。
  /// [isCancelled] 非空时，每次失败后等待退避前先询问一次：
  /// 已取消则立即抛 [GenerationCancelledException]，不再白等退避时间。
  Future<T> run<T>(
    Future<T> Function(int attempt) body, {
    required bool Function(Object error) isRetryable,
    void Function(int attempt, Duration delay, Object error)? onRetry,
    bool Function()? isCancelled,
  }) async {
    Object? lastError;
    StackTrace? lastStack;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        return await body(attempt);
      } catch (e, s) {
        lastError = e;
        lastStack = s;
        if (attempt >= maxAttempts - 1 || !isRetryable(e)) rethrow;
        if (isCancelled?.call() ?? false) {
          throw const GenerationCancelledException();
        }
        final Duration delay =
            backoffFor(attempt, serverHint: retryAfterOf(e));
        onRetry?.call(attempt, delay, e);
        await _sleepOrCancel(delay, isCancelled);
      }
    }
    // 循环正常结束只会在 maxAttempts<=0 时发生。
    throw lastError is Exception
        ? lastError
        : EngineException('重试策略未产生结果', lastError ?? lastStack);
  }

  /// 等待退避；取消信号到达时立即结束，不等待完整 sleep。
  Future<void> _sleepOrCancel(
    Duration delay,
    bool Function()? isCancelled,
  ) async {
    if (isCancelled == null) {
      await sleep(delay);
      return;
    }
    if (isCancelled()) {
      throw const GenerationCancelledException();
    }
    final Completer<void> cancelled = Completer<void>();
    final Timer poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (isCancelled() && !cancelled.isCompleted) {
        cancelled.completeError(const GenerationCancelledException());
      }
    });
    try {
      await Future.any<void>(<Future<void>>[sleep(delay), cancelled.future]);
      if (isCancelled()) throw const GenerationCancelledException();
    } finally {
      poll.cancel();
      if (!cancelled.isCompleted) cancelled.complete();
    }
  }

  /// HTTP 状态码是否值得重试。
  static bool isRetryableStatus(int code) =>
      code == 408 || // Request Timeout
      code == 409 || // 并发写冲突（部分网关用）
      code == 425 || // Too Early
      code == 429 || // 限流
      code >= 500; // 网关/服务端

  /// 从错误对象里取服务器建议的等待时间。
  static Duration? retryAfterOf(Object error) =>
      error is LlmTransportException ? error.retryAfter : null;

  /// 解析 `Retry-After`：既支持秒数，也支持 HTTP-date。
  static Duration? parseRetryAfter(String? headerValue, {DateTime? now}) {
    final String? v = headerValue?.trim();
    if (v == null || v.isEmpty) return null;
    final int? seconds = int.tryParse(v);
    if (seconds != null) {
      return seconds <= 0 ? Duration.zero : Duration(seconds: seconds);
    }
    final DateTime? when = HttpDate.tryParse(v);
    if (when == null) return null;
    final Duration d = when.difference(now ?? DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }
}

/// 极简 HTTP-date 解析（`IMF-fixdate`：`Sun, 06 Nov 1994 08:49:37 GMT`）。
///
/// 不引 `http` 包（项目约束：零网络库依赖），只认这一种格式，解析失败返回 null。
class HttpDate {
  const HttpDate._();

  static const List<String> _months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// 解析失败返回 null。
  static DateTime? tryParse(String value) {
    final RegExpMatch? m = RegExp(
      r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
    ).firstMatch(value.trim());
    if (m == null) return null;
    final int? day = int.tryParse(m.group(1)!);
    final int month = _months.indexOf(m.group(2)!);
    final int? year = int.tryParse(m.group(3)!);
    final int? hour = int.tryParse(m.group(4)!);
    final int? minute = int.tryParse(m.group(5)!);
    final int? second = int.tryParse(m.group(6)!);
    if (month < 0 ||
        day == null ||
        year == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }
    return DateTime.utc(year, month + 1, day, hour, minute, second);
  }
}
