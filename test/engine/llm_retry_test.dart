import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/llm_http_errors.dart';
import 'package:novel_writer/engine/llm_retry.dart';

/// 记录等待时长的假 sleep（不真等）。
class _Recorder {
  final List<Duration> waits = <Duration>[];
  Future<void> call(Duration d) async => waits.add(d);
}

void main() {
  group('RetryPolicy', () {
    test('429 之后成功：只多等一次，退避按基数', () async {
      final _Recorder rec = _Recorder();
      final RetryPolicy p = RetryPolicy(
        maxAttempts: 3,
        baseBackoff: const Duration(milliseconds: 900),
        sleep: rec.call,
      );
      int calls = 0;
      final String out = await p.run(
        (int attempt) async {
          calls++;
          if (attempt == 0) {
            throw const LlmTransportException('限流',
                statusCode: 429, retryable: true);
          }
          return 'ok';
        },
        isRetryable: LlmHttpErrors.retryable,
      );
      expect(out, 'ok');
      expect(calls, 2);
      expect(rec.waits, const <Duration>[Duration(milliseconds: 900)]);
    });

    test('不可重试的错误立刻抛出，一次都不等', () async {
      final _Recorder rec = _Recorder();
      final RetryPolicy p = RetryPolicy(
          maxAttempts: 4, baseBackoff: const Duration(seconds: 1), sleep: rec.call);
      int calls = 0;
      await expectLater(
        p.run(
          (int attempt) async {
            calls++;
            throw const LlmTransportException('密钥无效',
                statusCode: 401, retryable: false);
          },
          isRetryable: LlmHttpErrors.retryable,
        ),
        throwsA(isA<LlmTransportException>()),
      );
      expect(calls, 1);
      expect(rec.waits, isEmpty);
    });

    test('重试用尽后把最后一次的错误原样抛出（不吞掉）', () async {
      final _Recorder rec = _Recorder();
      final RetryPolicy p = RetryPolicy(
        maxAttempts: 3,
        baseBackoff: const Duration(milliseconds: 100),
        sleep: rec.call,
      );
      int calls = 0;
      Object? caught;
      try {
        await p.run((int attempt) async {
          calls++;
          throw LlmTransportException('第 $attempt 次失败',
              statusCode: 503, retryable: true);
        }, isRetryable: LlmHttpErrors.retryable);
      } catch (e) {
        caught = e;
      }
      expect(calls, 3);
      expect(rec.waits.length, 2);
      expect(caught, isA<LlmTransportException>());
      expect((caught as LlmTransportException).message, contains('第 2 次失败'));
    });

    test('退避是指数增长并被 maxBackoff 截住', () {
      const RetryPolicy p = RetryPolicy(
        baseBackoff: Duration(milliseconds: 1000),
        maxBackoff: Duration(seconds: 5),
      );
      expect(p.backoffFor(0), const Duration(milliseconds: 1000));
      expect(p.backoffFor(1), const Duration(milliseconds: 2000));
      expect(p.backoffFor(2), const Duration(milliseconds: 4000));
      expect(p.backoffFor(3), const Duration(seconds: 5));
      expect(p.backoffFor(30), const Duration(seconds: 5));
    });

    test('服务器给了 Retry-After 就听它的，但仍不超上限', () {
      const RetryPolicy p = RetryPolicy(
        baseBackoff: Duration(milliseconds: 500),
        maxBackoff: Duration(seconds: 10),
      );
      expect(p.backoffFor(0, serverHint: const Duration(seconds: 6)),
          const Duration(seconds: 6));
      expect(p.backoffFor(0, serverHint: const Duration(minutes: 9)),
          const Duration(seconds: 10));
      // 0 秒（有些网关这么回）不该被当成有效提示。
      expect(p.backoffFor(1, serverHint: Duration.zero),
          const Duration(milliseconds: 1000));
    });

    test('抖动只在 0~25% 之间，且同种子可复现', () {
      final RetryPolicy p = RetryPolicy(
        baseBackoff: const Duration(milliseconds: 1000),
        maxBackoff: const Duration(milliseconds: 1000),
        random: math.Random(7),
      );
      final RetryPolicy same = RetryPolicy(
        baseBackoff: const Duration(milliseconds: 1000),
        maxBackoff: const Duration(milliseconds: 1000),
        random: math.Random(7),
      );
      for (int i = 0; i < 5; i++) {
        final Duration d = p.backoffFor(0);
        expect(d.inMilliseconds, inInclusiveRange(1000, 1250));
        expect(d.inMilliseconds, same.backoffFor(0).inMilliseconds);
      }
    });

    test('onRetry 回调拿到尝试序号、等待时长与原始错误', () async {
      final _Recorder rec = _Recorder();
      final List<String> notes = <String>[];
      final RetryPolicy p = RetryPolicy(
          maxAttempts: 2,
          baseBackoff: const Duration(milliseconds: 300),
          sleep: rec.call);
      await p.run((int attempt) async {
        if (attempt == 0) {
          throw const LlmTransportException('忙',
              statusCode: 429, retryable: true);
        }
        return 1;
      }, isRetryable: LlmHttpErrors.retryable,
          onRetry: (int a, Duration d, Object e) =>
              notes.add('$a|${d.inMilliseconds}|${(e as LlmTransportException).statusCode}'));
      expect(notes, <String>['0|300|429']);
    });
  });

  group('状态码判定', () {
    test('限流与服务端错误可重试，客户端错误不可', () {
      for (final int code in <int>[408, 409, 425, 429, 500, 502, 503, 504]) {
        expect(RetryPolicy.isRetryableStatus(code), isTrue, reason: '$code');
      }
      for (final int code in <int>[400, 401, 403, 404, 413, 422]) {
        expect(RetryPolicy.isRetryableStatus(code), isFalse, reason: '$code');
      }
    });
  });

  group('Retry-After 解析', () {
    test('秒数形式', () {
      expect(RetryPolicy.parseRetryAfter('12'), const Duration(seconds: 12));
      expect(RetryPolicy.parseRetryAfter('0'), Duration.zero);
      expect(RetryPolicy.parseRetryAfter(null), isNull);
      expect(RetryPolicy.parseRetryAfter('   '), isNull);
      expect(RetryPolicy.parseRetryAfter('soon'), isNull);
    });

    test('HTTP-date 已过期时给 0（而不是负数等待）', () {
      final DateTime now = DateTime.utc(1994, 11, 6, 8, 50, 0);
      expect(
          RetryPolicy.parseRetryAfter('Sun, 06 Nov 1994 08:49:37 GMT', now: now),
          Duration.zero);
    });

    test('HTTP-date 在未来时给出正差值', () {
      final DateTime now = DateTime.utc(1994, 11, 6, 8, 49, 0);
      expect(
        RetryPolicy.parseRetryAfter('Sun, 06 Nov 1994 08:49:37 GMT', now: now),
        const Duration(seconds: 37),
      );
    });

    test('HttpDate 只认 IMF-fixdate，乱码返回 null', () {
      expect(HttpDate.tryParse('Sun, 06 Nov 1994 08:49:37 GMT')!.toUtc(),
          DateTime.utc(1994, 11, 6, 8, 49, 37));
      expect(HttpDate.tryParse('06 Nov 1994'), isNull);
      expect(HttpDate.tryParse('Sun, 06 Xyz 1994 08:49:37 GMT'), isNull);
    });
  });

  group('LlmHttpErrors', () {
    test('429 翻译成人话，并带上退避提示', () {
      final LlmTransportException e = LlmHttpErrors.fromStatus(
        429,
        '{"error":{"message":"at concurrency limit"}}',
        retryAfterHeader: '21',
      );
      expect(e.retryable, isTrue);
      expect(e.statusCode, 429);
      expect(e.retryAfter, const Duration(seconds: 21));
      expect(e.message, contains('并发已满'));
      expect(e.message, contains('自动重试'));
    });

    test('401 不可重试，且不会把整页 HTML 甩给作者', () {
      final LlmTransportException e =
          LlmHttpErrors.fromStatus(401, '<html>${'x' * 5000}</html>');
      expect(e.retryable, isFalse);
      expect(e.message, contains('API 密钥无效'));
      expect(e.message.length, lessThan(260));
    });

    test('连接层错误：证书问题不重试，拒绝连接可重试', () {
      final LlmTransportException tls = LlmHttpErrors
          .transport(Exception('Handshake failed: certificate verify failed'));
      expect(tls.message, contains('证书'));
      expect(tls.retryable, isFalse);

      final LlmTransportException refused =
          LlmHttpErrors.transport(const SocketException('Connection refused'));
      expect(refused.retryable, isTrue);

      final LlmTransportException dns = LlmHttpErrors.transport(
          const SocketException('Failed host lookup: api.example.com'));
      expect(dns.message, contains('域名解析失败'));
    });

    test('retryable() 只认带标记的传输异常', () {
      expect(LlmHttpErrors.retryable(const EngineException('x')), isFalse);
      expect(
          LlmHttpErrors.retryable(
              const LlmTransportException('x', retryable: true)),
          isTrue);
      expect(
          LlmHttpErrors.retryable(
              const LlmTransportException('x', retryable: false)),
          isFalse);
    });
  });

  group('取消中断', () {
    test('失败后等待退避前先询问 isCancelled：已取消立即抛异常且不再重试', () async {
      final _Recorder rec = _Recorder();
      final RetryPolicy p = RetryPolicy(
        maxAttempts: 3,
        baseBackoff: const Duration(milliseconds: 800),
        sleep: rec.call,
      );
      int calls = 0;
      await expectLater(
        p.run(
          (int attempt) async {
            calls++;
            throw const LlmTransportException('限流',
                statusCode: 429, retryable: true);
          },
          isRetryable: LlmHttpErrors.retryable,
          isCancelled: () => true,
        ),
        throwsA(isA<GenerationCancelledException>()),
      );
      // 只尝试了第一次；退避一次都没等（不被 sleep 卡住）。
      expect(calls, 1);
      expect(rec.waits, isEmpty);
    });

    test('退避等待期间取消会立即结束，不等待完整 backoff', () async {
      bool cancelled = false;
      final Completer<void> never = Completer<void>();
      final RetryPolicy p = RetryPolicy(
        maxAttempts: 3,
        baseBackoff: const Duration(seconds: 5),
        sleep: (_) => never.future,
      );
      final Future<void> pending = p.run<void>(
        (int attempt) async {
          throw const LlmTransportException('限流',
              statusCode: 429, retryable: true);
        },
        isRetryable: LlmHttpErrors.retryable,
        isCancelled: () => cancelled,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancelled = true;
      await expectLater(
        pending,
        throwsA(isA<GenerationCancelledException>()),
      );
    });

    test('取消发生在第二次失败后：第一次退避照常，第二次失败即中断', () async {
      final _Recorder rec = _Recorder();
      final RetryPolicy p = RetryPolicy(
        maxAttempts: 4,
        baseBackoff: const Duration(milliseconds: 500),
        sleep: rec.call,
      );
      int calls = 0;
      await expectLater(
        p.run(
          (int attempt) async {
            calls++;
            throw const LlmTransportException('服务端错误',
                statusCode: 500, retryable: true);
          },
          isRetryable: LlmHttpErrors.retryable,
          isCancelled: () => calls >= 2,
        ),
        throwsA(isA<GenerationCancelledException>()),
      );
      // 第二次失败后直接中断：尝试 2 次，只等了 1 次退避。
      expect(calls, 2);
      expect(rec.waits, hasLength(1));
    });
  });
}
