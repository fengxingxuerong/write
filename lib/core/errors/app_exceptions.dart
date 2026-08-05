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
