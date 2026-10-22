import 'dart:io';

import 'package:dio/dio.dart';

import '../config/app_config.dart';

/// HTTP client for the ScaleGuard backend.
///
/// Two behaviours here exist because of how the backend is deployed:
///
///  * **Retries.** The API sits behind nginx and Cloudflare, and a cold container
///    or a dropped keep-alive connection produces a transient failure that
///    succeeds on the next attempt. A single failure used to surface as a login
///    screen error even though the server was healthy.
///  * **Readable errors.** Dio's own messages are long technical sentences
///    ("The request connection took longer than…"). They are useful in a log and
///    useless in the UI, so [extractError] maps them to something a user can act
///    on while [extractDiagnostics] keeps the original for the log.
class ApiClient {
  ApiClient({String? token, Dio? dio}) {
    _dio = dio ??
        Dio(
          BaseOptions(
            baseUrl: AppConfig.apiUrl,
            // Chosen so a genuinely unreachable server fails in seconds rather
            // than twenty, and a slow-but-alive one still completes.
            connectTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 40),
            sendTimeout: const Duration(seconds: 30),
            responseType: ResponseType.json,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              // A stable client marker: the backend uses it to skip hCaptcha for
              // first-party mobile and desktop clients.
              'X-ScaleGuard-Client': 'mobile',
              if (token != null && token.isNotEmpty)
                'Authorization': 'Bearer $token',
            },
          ),
        );

    _dio.interceptors.add(
      InterceptorsWrapper(
        onError: (error, handler) async {
          if (!_isRetryable(error)) {
            handler.next(error);
            return;
          }
          final attempt = (error.requestOptions.extra['sg_attempt'] as int?) ?? 0;
          if (attempt >= _maxRetries) {
            handler.next(error);
            return;
          }
          error.requestOptions.extra['sg_attempt'] = attempt + 1;
          // Linear backoff: the failures this guards against are sub-second, so
          // waiting longer would only delay a successful login.
          await Future<void>.delayed(Duration(milliseconds: 400 * (attempt + 1)));
          try {
            final response = await _dio.fetch<dynamic>(error.requestOptions);
            handler.resolve(response);
          } catch (_) {
            handler.next(error);
          }
        },
      ),
    );
  }

  static const int _maxRetries = 2;

  late final Dio _dio;

  /// Exposed for the development harness, which reproduces a startup request
  /// with exactly these settings.
  Dio get raw => _dio;

  void setToken(String? token) {
    if (token == null || token.isEmpty) {
      _dio.options.headers.remove('Authorization');
      return;
    }
    _dio.options.headers['Authorization'] = 'Bearer $token';
  }

  Future<Response<T>> get<T>(String path, {Map<String, dynamic>? query}) =>
      _dio.get<T>(path, queryParameters: query);

  Future<Response<T>> post<T>(
    String path, {
    Map<String, dynamic>? data,
    Duration? receiveTimeout,
  }) =>
      _dio.post<T>(
        path,
        data: data,
        options: receiveTimeout == null
            ? null
            : Options(receiveTimeout: receiveTimeout),
      );

  /// A network hiccup worth retrying.
  ///
  /// Only transport-level failures qualify. A 4xx is a real answer from the
  /// server (a wrong password, a missing device binding) and retrying it would
  /// just delay the message the user needs to see.
  bool _isRetryable(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionError:
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      // A transform timeout means the response body could not be decoded in
      // time, which a retry can also resolve.
      case DioExceptionType.transformTimeout:
      case DioExceptionType.badCertificate:
        return true;
      case DioExceptionType.badResponse:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        // `unknown` wraps low-level socket errors on some platforms.
        return error.response == null &&
            error.error is! FormatException &&
            error.message != 'Cancelled';
    }
  }

  /// A quick answer to "is there a network at all".
  ///
  /// The launch sequence must not spend three connect timeouts (about forty
  /// seconds) on a phone that is in airplane mode or a laptop with Wi-Fi off:
  /// the user sees a splash that looks hung instead of the offline page with a
  /// retry button. A DNS lookup for the API host costs milliseconds when there
  /// is no network, because the resolver fails immediately.
  Future<bool> hasNetwork() async {
    final host = Uri.tryParse(AppConfig.apiUrl)?.host;
    if (host == null || host.isEmpty) return true;
    try {
      final addresses = await InternetAddress.lookup(host)
          .timeout(const Duration(seconds: 3));
      return addresses.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Whether the request never reached the server at all.
  ///
  /// Used to tell "the internet is down" from "the server said no": only the
  /// first case deserves the offline page with a retry button — a 401 has to
  /// lead to the sign-in screen, and a 500 to the error message.
  bool isOfflineError(Object error) {
    if (error is DioException) {
      if (error.response != null) return false;
      switch (error.type) {
        case DioExceptionType.connectionError:
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.transformTimeout:
        case DioExceptionType.unknown:
          return true;
        case DioExceptionType.badCertificate:
        case DioExceptionType.badResponse:
        case DioExceptionType.cancel:
          return false;
      }
    }
    return false;
  }

  /// A message suitable for display.
  String extractError(Object error) {    if (error is DioException) {
      return _dioMessage(error);
    }
    if (error is StateError) return error.message;
    if (error is ArgumentError) return '${error.message}';
    return _humanize(error.toString());
  }

  /// The technical original, for logs and bug reports.
  String extractDiagnostics(Object error) {
    if (error is DioException) {
      final buffer = StringBuffer()
        ..write('${error.requestOptions.method} ')
        ..write(error.requestOptions.uri)
        ..write(' -> ${error.type.name}');
      final status = error.response?.statusCode;
      if (status != null) buffer.write(' HTTP $status');
      if (error.message != null) buffer.write(': ${error.message}');
      return buffer.toString();
    }
    return error.toString();
  }

  /// The parsed error body, when the backend sent one.
  Map<String, dynamic>? tryExtractErrorPayload(Object error) {
    if (error is DioException) {
      final data = error.response?.data;
      if (data is Map<String, dynamic>) return data;
      if (data is Map) return Map<String, dynamic>.from(data);
    }
    return null;
  }

  String _dioMessage(DioException error) {
    // The backend answers with `{error: "…"}` in Russian; prefer it verbatim.
    final payload = error.response?.data;
    if (payload is Map && payload['error'] != null) {
      return payload['error'].toString();
    }

    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return 'Сервер ${AppConfig.apiUrl} не ответил вовремя. '
            'Проверьте соединение и повторите.';
      case DioExceptionType.connectionError:
        return 'Нет связи с ${AppConfig.apiUrl}. '
            'Проверьте интернет или попробуйте позже.';
      case DioExceptionType.badCertificate:
        return 'Сертификат сервера не принят. '
            'Возможно, соединение перехватывается прокси.';
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        if (status == 429) {
          return 'Слишком много попыток. Подождите минуту и повторите.';
        }
        if (status != null && status >= 500) {
          return 'Сервер временно недоступен (HTTP $status). '
              'Попробуйте ещё раз через минуту.';
        }
        return 'Сервер вернул ошибку${status == null ? '' : ' HTTP $status'}.';
      case DioExceptionType.cancel:
        return 'Запрос отменён.';
      case DioExceptionType.unknown:
        return _humanize(error.message ?? error.toString());
    }
  }

  /// Strips the parts of a Dart exception that mean nothing to a user.
  String _humanize(String raw) {
    var text = raw;
    if (text.startsWith('Exception: ')) text = text.substring(11);
    if (text.startsWith('DioException [')) {
      final close = text.indexOf(']: ');
      if (close > 0) text = text.substring(close + 3);
    }
    // Collapse the multi-line advice Dio appends to timeout messages.
    text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > 220) text = '${text.substring(0, 217)}…';
    return text;
  }
}
