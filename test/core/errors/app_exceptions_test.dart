import 'package:flutter_test/flutter_test.dart';

import 'package:novel_writer/core/errors/app_exceptions.dart';

void main() {
  group('AppException 类型契约', () {
    test('Storage/Engine/Export 暴露 message 与 cause，toString 含类型', () {
      final StorageException storage = StorageException(
        '存储失败',
        StateError('原因'),
      );
      expect(storage.message, '存储失败');
      expect(storage.cause, isA<StateError>());
      expect(storage.toString(), contains('StorageException'));
      expect(storage.toString(), contains('存储失败'));

      const EngineException engine = EngineException('引擎失败');
      expect(engine.message, '引擎失败');
      expect(engine.cause, isNull);
      expect(engine.toString(), contains('EngineException'));

      const ExportException export = ExportException('用户取消导出');
      expect(export.message, '用户取消导出');
      expect(export.toString(), contains('ExportException'));
    });

    test('GenerationCancelledException 是引擎异常并带默认中文文案', () {
      const GenerationCancelledException cancelled =
          GenerationCancelledException();
      expect(cancelled, isA<EngineException>());
      expect(cancelled, isA<AppException>());
      expect(cancelled.message, '生成已被取消');
      expect(cancelled.toString(), contains('生成已被取消'));

      const GenerationCancelledException custom = GenerationCancelledException(
        '自定义取消',
      );
      expect(custom.message, '自定义取消');
    });
  });

  group('LlmTransportException', () {
    test('携带状态码、等待时间、重试标记和原始 cause', () {
      final LlmTransportException e = LlmTransportException(
        '限流',
        statusCode: 429,
        retryAfter: const Duration(seconds: 21),
        retryable: true,
        cause: Exception('底层错误'),
      );
      expect(e.statusCode, 429);
      expect(e.retryAfter, const Duration(seconds: 21));
      expect(e.retryable, isTrue);
      expect(e.cause, isA<Exception>());
      expect(e.toString(), contains('LlmTransportException'));
      expect(e.toString(), contains('429'));
      expect(e.toString(), contains('限流'));
    });

    test('默认值：无状态码、不可重试', () {
      const LlmTransportException e = LlmTransportException('未知传输错误');
      expect(e.statusCode, isNull);
      expect(e.retryAfter, isNull);
      expect(e.retryable, isFalse);
      expect(e.toString(), contains('null'));
    });
  });
}
