import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scaleguard_mobile/services/api_client.dart';

void main() {
  group('ApiClient.isOfflineError', () {
    final options = RequestOptions(path: '/api/auth/profile');

    DioException failure(DioExceptionType type, {Response<dynamic>? response}) =>
        DioException(
          requestOptions: options,
          type: type,
          response: response,
        );

    test('a connection failure means the network is down', () {
      final api = ApiClient(dio: Dio());
      expect(api.isOfflineError(failure(DioExceptionType.connectionError)), isTrue);
      expect(api.isOfflineError(failure(DioExceptionType.connectionTimeout)), isTrue);
      expect(api.isOfflineError(failure(DioExceptionType.receiveTimeout)), isTrue);
      expect(api.isOfflineError(failure(DioExceptionType.unknown)), isTrue);
    });

    test('an answer from the server is never "offline"', () {
      final api = ApiClient(dio: Dio());
      final unauthorized = Response<dynamic>(
        requestOptions: options,
        statusCode: 401,
      );
      expect(
        api.isOfflineError(
          failure(DioExceptionType.badResponse, response: unauthorized),
        ),
        isFalse,
      );
      // A connection error that still carries a response was answered in some
      // way, so the sign-in screen is the right place for it.
      expect(
        api.isOfflineError(
          failure(DioExceptionType.connectionError, response: unauthorized),
        ),
        isFalse,
      );
    });

    test('anything that is not a Dio failure is left to the caller', () {
      expect(ApiClient(dio: Dio()).isOfflineError(StateError('boom')), isFalse);
    });
  });
}
