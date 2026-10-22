import 'package:dio/dio.dart';

import 'package:scaleguard_mobile/core/device_identity.dart';
import 'package:scaleguard_mobile/core/vpn_engine.dart';

/// A subscription download that succeeded.
class SubscriptionDownload {
  const SubscriptionDownload({
    required this.body,
    required this.strategy,
    this.userInfo,
    this.title,
  });

  final String body;

  /// Which request produced the body, for diagnostics.
  final String strategy;

  /// Raw `subscription-userinfo` header, when the panel sent one.
  final String? userInfo;

  /// `profile-title` header, when the panel sent one.
  final String? title;
}

/// Downloads a subscription from a deployed Remnawave panel.
///
/// This mirrors the application's own strategy chain
/// (`VpnService.loadProfilesFromSubscription`): the same explicit client type,
/// the same User-Agents, and the same HWID headers. It lives here so the
/// command-line tools can exercise the real behaviour without instantiating the
/// Flutter-facing service.
///
/// The HWID headers matter more than they look: a panel with the device limit
/// enabled answers **200 with an empty body** when `x-hwid` is missing, so a
/// client that omits it appears to work but receives no servers at all.
Future<SubscriptionDownload> fetchSubscription(
  String url, {
  DeviceIdentity? device,
}) async {
  final baseUri = Uri.parse(url.trim());
  final strategies = <({String label, Uri uri, String userAgent, String accept})>[
    (
      label: 'clientType=mihomo',
      uri: Uri.parse(deriveMihomoSubscriptionUrl(url)),
      userAgent: 'mihomo/1.19.32',
      accept: 'text/yaml, application/json, text/plain, */*',
    ),
    (
      label: 'User-Agent=mihomo',
      uri: baseUri,
      userAgent: 'mihomo/1.19.32',
      accept: 'text/yaml, application/json, text/plain, */*',
    ),
    (
      label: 'fallback',
      uri: baseUri,
      userAgent: 'v2rayNG/1.10.11',
      accept: 'text/plain, application/json, */*',
    ),
  ];

  final dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: true,
      responseType: ResponseType.plain,
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  final notes = <String>[];
  for (final strategy in strategies) {
    try {
      final response = await dio.get<String>(
        strategy.uri.toString(),
        options: Options(
          headers: {
            'User-Agent': strategy.userAgent,
            'Accept': strategy.accept,
            ...?device?.headers,
          },
        ),
      );
      final body = (response.data ?? '').trim();
      final userInfo = response.headers.value('subscription-userinfo');
      if (body.isEmpty) {
        notes.add('${strategy.label}: HTTP ${response.statusCode}, пустое тело'
            '${device == null ? ' (без x-hwid панель отдаёт пустой профиль)' : ''}');
        continue;
      }
      return SubscriptionDownload(
        body: body,
        strategy: strategy.label,
        userInfo: userInfo,
        title: response.headers.value('profile-title'),
      );
    } catch (error) {
      notes.add('${strategy.label}: $error');
    }
  }

  throw StateError('Подписка недоступна. ${notes.join("; ")}');
}
