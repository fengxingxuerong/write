/// 统一异常体系。
///
/// 所有 Repository / Engine 在执行失败时抛出 [AppException] 的具体子类，
/// UI 层统一捕获并以 SnackBar 提示，**生成或存储失败不得导致 App 崩溃**。
sealed class AppException implements Exception {
  /// 人类可读的错误信息。
  final String message;

  /// 原始异常（可选），便于排查。
  final Object? cause;

  const AppException(this.message, [this.cause]);

  @override
  String toString() => 'AppException($runtimeType): $message';
}

/// 本地存储相关异常（JSON 文件读写、文件损坏等）。
final class StorageException extends AppException {
  const StorageException(super.message, [super.cause]);
}

/// 生成引擎相关异常（模板填充、约束越界、语料缺失等）。
final class EngineException extends AppException {
  const EngineException(super.message, [super.cause]);
}

/// 导出相关异常（写文件失败、用户取消等）。
final class ExportException extends AppException {
  const ExportException(super.message, [super.cause]);
}

/// 生成被用户取消时抛出，UI 据此显示「已取消」而非错误。
final class GenerationCancelledException extends EngineException {
  const GenerationCancelledException([super.message = '生成已被取消']);
}

/// LLM 传输层错误（HTTP 状态码 / 连接失败）。
///
/// 单独开一个类是为了把「能不能重试」这个判断带在异常上：
/// 429/5xx 该退避重来，401/400/413 重试只是浪费时间。规则由抛出方
/// （engine 层）用 `RetryPolicy.isRetryableStatus` 填好，core 不反向依赖 engine。
final class LlmTransportException extends EngineException {
  /// 构造传输错误。
  const LlmTransportException(
    String message, {
    this.statusCode,
    this.retryAfter,
    this.retryable = false,
    Object? cause,
  }) : super(message, cause);

  /// HTTP 状态码（网络层失败时为 null）。
  final int? statusCode;

  /// 服务端 `Retry-After` 解析出的等待时长（没给就为 null）。
  final Duration? retryAfter;

  /// 是否值得退避后重试。
  final bool retryable;

  @override
  String toString() => 'LlmTransportException($statusCode): $message';
}
