// Reproduces the application's startup request exactly.
//
//   dart run tool/probe_api.dart
//
// It uses the real `ApiClient` — the same Dio options, the same headers, the same
// base URL resolution — so a failure here is a failure the application would hit,
// and a success here points the investigation at the UI layer instead of at the
// network. `ApiClient` deliberately has no Flutter dependency, which is what
// makes this possible.
import 'dart:io';

import 'package:scaleguard_mobile/config/app_config.dart';
import 'package:scaleguard_mobile/services/api_client.dart';

Future<void> main() async {
  print('API_URL resolved to: ${AppConfig.apiUrl}');

  final api = ApiClient();
  final stopwatch = Stopwatch()..start();
  try {
    final response = await api.get<Map<String, dynamic>>('/api/auth/config');
    stopwatch.stop();
    print('GET /api/auth/config -> HTTP ${response.statusCode} '
        'in ${stopwatch.elapsedMilliseconds} ms');
    print('body: ${response.data}');
  } catch (error) {
    stopwatch.stop();
    print('GET /api/auth/config FAILED in ${stopwatch.elapsedMilliseconds} ms');
    print('extracted error: ${api.extractError(error)}');
    print('raw: $error');
  }

  // The other endpoints the auth screen can reach, so a failure is attributed to
  // the right call.
  final stopwatch2 = Stopwatch()..start();
  try {
    final response = await api.post<Map<String, dynamic>>(
      '/api/auth/email-lookup',
      data: {'email': 'probe@example.invalid'},
    );
    stopwatch2.stop();
    print('POST /api/auth/email-lookup -> HTTP ${response.statusCode} '
        'in ${stopwatch2.elapsedMilliseconds} ms: ${response.data}');
  } catch (error) {
    stopwatch2.stop();
    print('POST /api/auth/email-lookup FAILED in '
        '${stopwatch2.elapsedMilliseconds} ms: ${api.extractError(error)}');
  }

  exit(0);
}
