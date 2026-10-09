import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 假 HTTP 栈：让「只允许 HTTPS」或「必须注入可控错误」的代码路径
/// 在**无证书、无真实网络**的前提下被完整测试。
///
/// 为什么需要它（2026-10-05）：
/// - `uploadCrashLog` 只允许 HTTPS，而测试环境起 HTTPS 服务需要证书与
///   `HttpOverrides`，此前整段上传主体（203~234 行）零覆盖；
/// - `LlmEngine` 的流中途错误分类（`_classifyError`）只能靠真实网络
///   制造错误，TLS / 401 / 429 等分支无法稳定复现。
///
/// 用法：`withFakeHttpClient(client, () async { ... })` 区域内，
/// 被测代码里 `HttpClient()` 拿到的就是 [FakeHttpClient]，请求不会出网。
///
/// 只实现被测代码用到的成员（postUrl / 请求头 / 请求体 / close /
/// statusCode / transform / drain），其余成员一律 `noSuchMethod` 抛错
/// ——这样一旦被测代码新增了未预料的用法，测试会立刻报出具体成员名，
/// 而不是悄悄走空实现让断言失真。

/// 假请求头：记录通过 [set] 与 [contentType] 写入的值。
class FakeHttpHeaders implements HttpHeaders {
  /// `request.headers.contentType = ...` 的落点。
  @override
  ContentType? contentType;

  /// 记录通过 [set] 写入的请求头（键统一小写）。
  final Map<String, String> values = <String, String>{};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = '$value';
  }

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('FakeHttpHeaders.${invocation.memberName}');
}

/// 假请求：累计请求体字节，[close] 时由工厂产出响应。
class FakeHttpRequest implements HttpClientRequest {
  /// 构造。[_respond] 在 [close] 时被调用一次。
  FakeHttpRequest(this._respond);

  final Future<FakeHttpResponse> Function() _respond;

  @override
  final FakeHttpHeaders headers = FakeHttpHeaders();

  @override
  bool followRedirects = true;

  /// `add` / `write` 累计的请求体字节。
  final List<int> bodyBytes = <int>[];

  /// 请求体 UTF-8 文本（断言上报载荷用）。
  String get bodyText => utf8.decode(bodyBytes, allowMalformed: true);

  @override
  void add(List<int> data) => bodyBytes.addAll(data);

  @override
  void write(Object? object) => bodyBytes.addAll(utf8.encode('$object'));

  @override
  Future<HttpClientResponse> close() async => _respond();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('FakeHttpRequest.${invocation.memberName}');
}

/// 假响应：可返回固定字节、可控错误，或一个永不结束的流（测超时用）。
class FakeHttpResponse implements HttpClientResponse {
  /// 构造。
  ///
  /// [body] 为响应体字节；[streamError] 非空时响应流以该错误结束；
  /// [rawStream] 非空时直接作为响应流（用于「永不结束」的超时场景）。
  FakeHttpResponse({
    this.statusCode = 200,
    this.body = const <int>[],
    this.streamError,
    this.rawStream,
    this.onDrain,
  });

  @override
  final int statusCode;

  /// 响应头（状态码非 2xx 时被测代码会读 `retry-after`）。
  @override
  final FakeHttpHeaders headers = FakeHttpHeaders();

  /// 响应体字节（[rawStream] 为空时使用）。
  final List<int> body;

  /// 响应流中途抛出的错误（触发被测方的流错误分支）。
  final Object? streamError;

  /// 自定义响应流（优先于 [body] / [streamError]）。
  final Stream<List<int>>? rawStream;

  /// [drain] 被调用时回调（断言「读完响应体再判状态码」）。
  final void Function()? onDrain;

  Stream<List<int>> get _stream =>
      rawStream ??
      (streamError != null
          ? Stream<List<int>>.error(streamError!)
          : Stream<List<int>>.fromIterable(<List<int>>[body]));

  @override
  Stream<S> transform<S>(StreamTransformer<List<int>, S> streamTransformer) =>
      _stream.transform(streamTransformer);

  @override
  Future<T> drain<T>([FutureOr<T>? future]) {
    onDrain?.call();
    return Future<T>.value(future);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('FakeHttpResponse.${invocation.memberName}');
}

/// 假客户端：按 [respond] 处理 POST；记录全部请求与 URL。
class FakeHttpClient implements HttpClient {
  /// 构造。
  ///
  /// [postError] 非空时 `postUrl` 直接抛该错误（模拟 DNS 失败 / 拒连）。
  FakeHttpClient({required this.respond, this.postError});

  /// 每次 POST 的响应工厂。
  final Future<FakeHttpResponse> Function(FakeHttpRequest request, Uri url)
      respond;

  /// 非空时 `postUrl` 抛出该错误。
  final Object? postError;

  @override
  Duration? connectionTimeout;

  @override
  Duration idleTimeout = const Duration(seconds: 15);

  /// `close(force: true)` 是否被调用（断言连接释放）。
  bool closed = false;

  /// 收到的请求 URL（按序）。
  final List<Uri> requestUrls = <Uri>[];

  /// 收到的请求对象（按序）。
  final List<FakeHttpRequest> requests = <FakeHttpRequest>[];

  @override
  Future<HttpClientRequest> postUrl(Uri url) async {
    final Object? error = postError;
    if (error != null) throw error;
    requestUrls.add(url);
    late final FakeHttpRequest request;
    request = FakeHttpRequest(() => respond(request, url));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) => closed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('FakeHttpClient.${invocation.memberName}');
}

/// 在 [HttpOverrides] 区域内执行 [body]：区域内 `HttpClient()` 一律返回 [client]。
Future<T> withFakeHttpClient<T>(FakeHttpClient client, Future<T> Function() body) {
  return HttpOverrides.runZoned<Future<T>>(
    body,
    createHttpClient: (SecurityContext? context) => client,
  );
}
