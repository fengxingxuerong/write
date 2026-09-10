import 'package:novel_writer/core/errors/app_exceptions.dart';
import 'package:novel_writer/engine/llm_retry.dart';

/// HTTP 错误 → 面向作者的中文提示。
///
/// 原来 LlmEngine 与 LlmChatClient 各写了一份状态码翻译，措辞不一致，
/// 而且都没带上「能不能重试」——现在统一在这里产出 [LlmTransportException]。
class LlmHttpErrors {
  const LlmHttpErrors._();

  /// 把非 2xx 响应翻译成异常。
  ///
  /// [body] 会截断到 160 字：网关返回的 HTML 错误页整段塞给作者毫无意义。
  static LlmTransportException fromStatus(
    int statusCode,
    String body, {
    String? retryAfterHeader,
  }) {
    final bool retryable = RetryPolicy.isRetryableStatus(statusCode);
    final String hint = _brief(body);
    final String message = switch (statusCode) {
      400 => '请求格式错误（400）$hint',
      401 => 'API 密钥无效（401），请在设置页检查 API Key',
      403 => '访问被拒绝（403），请检查 API Key 权限或配额$hint',
      404 => 'API 地址不存在（404），请检查设置页的 API 地址',
      408 => 'AI 服务响应超时（408），正在自动重试',
      413 => '请求内容过长（413），请降低目标字数或减少注入的设定',
      422 => '请求内容不被接受（422）$hint',
      429 => 'AI 服务并发已满（429），退避后自动重试$hint',
      500 => 'AI 服务暂时不可用（500），退避后自动重试',
      502 => '网关回源失败（502），退避后自动重试',
      503 => 'AI 服务过载（503），退避后自动重试',
      504 => '网关超时（504），AI 服务负载过高，退避后自动重试',
      _ => 'HTTP $statusCode$hint',
    };
    return LlmTransportException(
      message,
      statusCode: statusCode,
      retryAfter: RetryPolicy.parseRetryAfter(retryAfterHeader),
      retryable: retryable,
    );
  }

  /// 连接层失败（DNS / 拒绝连接 / TLS）。
  static LlmTransportException transport(Object error) {
    final String msg = error.toString().toLowerCase();
    if (msg.contains('certificate') || msg.contains('tls') || msg.contains('ssl')) {
      return LlmTransportException('TLS 证书验证失败，请检查 API 地址是否正确', cause: error);
    }
    if (msg.contains('failed host lookup') || msg.contains('nodename')) {
      return const LlmTransportException(
        '域名解析失败，请检查 API 地址或网络',
        retryable: true,
        cause: null,
      );
    }
    return LlmTransportException(
      '无法连接 AI 服务：$error',
      retryable: true,
      cause: error,
    );
  }

  /// 是否应当重试该错误（供 RetryPolicy 的 isRetryable 使用）。
  static bool retryable(Object error) =>
      error is LlmTransportException && error.retryable;

  static String _brief(String body) {
    if (body.trim().isEmpty) return '';
    final String flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    final String cut = flat.length > 160 ? '${flat.substring(0, 160)}…' : flat;
    return '：$cut';
  }
}
